param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [switch]$IndexOnly,
    [scriptblock]$OnProgress,
    [string]$PreviousDocumentsPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
if ($outputPath.StartsWith($PSScriptRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Private Indizes duerfen nicht im App-Verzeichnis liegen.' }
if ($outputPath -eq $root -or $outputPath.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Ausgabeverzeichnis muss ausserhalb des eingelesenen AI-OS liegen.' }
[System.IO.Directory]::CreateDirectory($outputPath) | Out-Null
$excluded = @('.git', 'node_modules', '.venv', 'venv', '__pycache__', 'themenlandkarte')
$records = [System.Collections.Generic.List[object]]::new()
$omitted = [System.Collections.Generic.List[object]]::new()
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$previousDocuments = @{}
if ($PreviousDocumentsPath -and (Test-Path -LiteralPath $PreviousDocumentsPath)) {
    foreach ($previousDocument in (Get-Content -LiteralPath $PreviousDocumentsPath -Raw -Encoding UTF8 | ConvertFrom-Json)) { $previousDocuments[$previousDocument.path] = $previousDocument }
}
$progressClock = [Diagnostics.Stopwatch]::StartNew()
$progressState = @{ phase = 0; sent = -1000; discovered = 0; collecting = $true }
$counts = @{ evaluated = 0; partial = 0; skipped = 0 }
$topicProgress = @{
    found = [Collections.Generic.HashSet[string]]::new()
    documents = [Collections.Generic.HashSet[string]]::new()
    labels = [Collections.Generic.List[string]]::new()
    candidates = 0; textAssignments = 0; referenceAssignments = 0
    rulesChecked = 0; linksChecked = 0; detail = ''; activeTopic = ''; rows = @()
    timings = @{ links = 0.0; preparation = 0.0; rules = 0.0; references = 0.0 }
}

function Report-BuildProgress([int]$phase, [int]$processed, [int]$total, [string]$current = '') {
    if (-not $OnProgress) { return }
    if ($phase -eq $progressState.phase -and $processed -ne $total -and $progressClock.ElapsedMilliseconds - $progressState.sent -lt 250) { return }
    $progressState.phase = $phase
    $progressState.sent = $progressClock.ElapsedMilliseconds
    & $OnProgress ([ordered]@{
        phase = $phase; processed = $processed; total = $total; current = $current
        evaluated = $counts.evaluated; partial = $counts.partial; skipped = $counts.skipped
        topicsFound = $topicProgress.found.Count; topicCandidates = $topicProgress.candidates
        textAssignments = $topicProgress.textAssignments; referenceAssignments = $topicProgress.referenceAssignments
        documentsWithTopics = $topicProgress.documents.Count; topicLabels = @($topicProgress.labels.ToArray())
        rulesChecked = $topicProgress.rulesChecked; linksChecked = $topicProgress.linksChecked
        timings = $topicProgress.timings
        topicBuild = @($topicProgress.rows | ForEach-Object {
            [ordered]@{
                id = $_.id; label = $_.label; group = $_.group; documents = $_.count
                textAssignments = $_.textCount; referenceAssignments = $_.referenceCount
                state = $(if ($phase -ge 4 -or ($phase -eq 3 -and $processed -eq $total)) { if ($_.count -gt 0) { 'ready' } else { 'empty' } } elseif ($_.id -eq $topicProgress.activeTopic) { 'active' } elseif ($_.count -gt 0) { 'found' } else { 'pending' })
            }
        })
        detail = $(if ($phase -eq 3) { $topicProgress.detail } else { '' })
        updated = [DateTime]::UtcNow.ToString('o')
    })
}

function Get-WorkspaceFiles([string]$directory) {
    if ($progressState.collecting) { Report-BuildProgress 1 $progressState.discovered -1 ($directory.Substring($root.Length).TrimStart('\')) }
    foreach ($entry in (Get-ChildItem -LiteralPath $directory -Force | Sort-Object Name)) {
        $relative = $entry.FullName.Substring($root.Length + 1).Replace('\', '/')
        if ($entry.LinkType -in @('SymbolicLink', 'Junction')) {
            $omitted.Add([pscustomobject]@{ path = $relative; reason = 'Symbolischer Verweis: kein Verfolgen externer oder zyklischer Ziele' })
        } elseif ($entry.PSIsContainer) {
            if ($entry.Name -in $excluded) {
                $omitted.Add([pscustomobject]@{ path = $relative + '/'; reason = 'Technisches Verzeichnis oder eigene Ausgabe; nicht rekursiv inventarisiert' })
            } else {
                Get-WorkspaceFiles $entry.FullName
            }
        } else {
            if ($progressState.collecting) { $progressState.discovered++ }
            $entry
        }
    }
}

function Get-OfficeText([string]$path, [string]$extension) {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($path)
    try {
        $parts = switch ($extension) {
            '.docx' { $archive.Entries | Where-Object { $_.FullName -match '^word/(document|header\d+|footer\d+|footnotes|endnotes)\.xml$' } }
            '.pptx' { $archive.Entries | Where-Object { $_.FullName -match '^ppt/(slides/slide\d+|notesSlides/notesSlide\d+)\.xml$' } }
            '.xlsx' { $archive.Entries | Where-Object { $_.FullName -match '^xl/(sharedStrings|worksheets/sheet\d+)\.xml$' } }
        }
        $texts = foreach ($part in $parts) {
            $reader = [System.IO.StreamReader]::new($part.Open())
            try {
                $xml = [xml]$reader.ReadToEnd()
                foreach ($element in $xml.SelectNodes('//*[local-name()="t" or local-name()="v"]')) {
                    $element.InnerText
                }
            } finally { $reader.Dispose() }
        }
        $texts -join "`n"
    } finally { $archive.Dispose() }
}

$documentParser = $null
function Read-LocalDocument([string]$path) {
    $python = Join-Path $env:LOCALAPPDATA 'AI-OS\Themenlandkarte\runtime\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python)) { return $null }
    if (-not $script:documentParser -or $script:documentParser.HasExited) {
        if ($script:documentParser) { $script:documentParser.Dispose() }
        $script:documentParser = [Diagnostics.Process]::new()
        $script:documentParser.StartInfo.FileName = $python
        $script:documentParser.StartInfo.Arguments = '-I -u "' + (Join-Path $PSScriptRoot 'extract-document.py') + '" --server'
        $script:documentParser.StartInfo.UseShellExecute = $false
        $script:documentParser.StartInfo.CreateNoWindow = $true
        $script:documentParser.StartInfo.RedirectStandardInput = $true
        $script:documentParser.StartInfo.RedirectStandardOutput = $true
        $script:documentParser.StartInfo.RedirectStandardError = $true
        $script:documentParser.Start() | Out-Null
        $script:documentParser.BeginErrorReadLine()
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($path))
    $script:documentParser.StandardInput.WriteLine((@{ pathBase64 = $encoded } | ConvertTo-Json -Compress))
    $response = $script:documentParser.StandardOutput.ReadLineAsync()
    if (-not $response.Wait(120000)) {
        $script:documentParser.Kill()
        throw 'Lokale Extraktion nach 120 Sekunden abgebrochen; Inhalt nicht ausgelesen'
    }
    if (-not $response.Result) { throw 'Lokaler Dokumentparser unerwartet beendet' }
    $response.Result | ConvertFrom-Json
}

Report-BuildProgress 1 0 -1
$workspaceFiles = @(Get-WorkspaceFiles $root)
$directorySyncedAt = [DateTime]::UtcNow.ToString('o')
$progressState.collecting = $false
Report-BuildProgress 1 $workspaceFiles.Count $workspaceFiles.Count
try {
foreach ($file in $workspaceFiles) {
    $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
    Report-BuildProgress 2 $records.Count $workspaceFiles.Count $relative
    $extension = $file.Extension.ToLowerInvariant()
    $record = [ordered]@{
        path = $relative; name = $file.Name; organisation = ($relative -split '/')[0]
        extension = $extension; bytes = $file.Length; modified = $file.LastWriteTimeUtc.ToString('o')
        status = 'skipped'; reason = ''; extraction = ''; hash = ''; title = $file.BaseName
        sourceHash = ''; evaluatedAt = $null; indexedModified = $null; processingState = 'unread'; error = ''; rawLinks = @()
        text = ''; headings = @(); topics = @(); roles = @(); links = @(); externalLinks = @(); linkContexts = @{}
    }
    $previous = $previousDocuments[$relative]
    $reused = $false
    try {
        if ($file.Length -le 8MB -and $file.Name -notmatch '^\.env($|\.)|credentials|secrets|\.pem$|\.key$') {
            $record.sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        if ($file.Name -match '^\.env($|\.)|credentials|secrets|\.pem$|\.key$') {
            $record.reason = 'Moeglicherweise vertrauliche Zugangsdaten; Inhalt nicht gelesen'
        } elseif ($file.Length -gt 8MB) {
            $record.reason = 'Datei groesser als 8 MiB; Inhalt nicht gelesen'
        } elseif ($previous -and $previous.text -and $previous.hash -eq $record.sourceHash -and $previous.evaluatedAt -and $previous.processingState -ne 'error') {
            foreach ($key in @('text', 'title', 'status', 'reason', 'extraction', 'hash', 'evaluatedAt', 'indexedModified')) { $record[$key] = $previous.$key }
            $record.links = @($previous.rawLinks)
            $reused = $true
        } elseif ($extension -in @('.md', '.txt', '.yaml', '.yml', '.json', '.csv')) {
            $text = [System.IO.File]::ReadAllText($file.FullName, $utf8)
            if ($text.Contains([char]0)) { throw 'Binaerinhalt trotz Text-Endung' }
            $record.links = @([regex]::Matches($text, '\]\(([^\s)]+)(?:\s+"[^"]*")?\)|href\s*=\s*["'']([^"'']+)["'']') | ForEach-Object {
                if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
            } | Sort-Object -Unique)
            if ($extension -in @('.html', '.htm')) {
                $text = [regex]::Replace($text, '(?is)<(script|style)\b[^>]*>.*?</\1>', ' ')
                $text = [System.Net.WebUtility]::HtmlDecode([regex]::Replace($text, '<[^>]+>', ' '))
                $record.extraction = 'HTML-Text ohne Script/Style; keine Layout- oder Bildauswertung'
            } else { $record.extraction = 'Vollstaendiger UTF-8-Text' }
            $record.text = $text
            $record.status = 'evaluated'
        } elseif ($extension -in @('.docx', '.pptx', '.xlsx', '.pdf', '.eml', '.msg', '.rtf', '.html', '.htm')) {
            $extracted = Read-LocalDocument $file.FullName
            if ($extracted) {
                $record.text = [string]$extracted.text
                $record.status = $extracted.status
                $record.extraction = $extracted.extraction
                $record.reason = $extracted.reason
                if ($extracted.metadata.title) { $record.title = [string]$extracted.metadata.title }
            } elseif ($extension -in @('.docx', '.pptx', '.xlsx')) {
                $record.text = Get-OfficeText $file.FullName $extension
                $record.status = 'partial'
                $record.extraction = 'Office-XML-Text als Rueckfall'
                $record.reason = 'Reader-Laufzeit fehlt; nur XML-Text ohne Bilder und Layout gelesen. setup-reader.ps1 ausfuehren.'
            } else {
                $record.reason = 'Lokale Reader-/OCR-Laufzeit fehlt. setup-reader.ps1 ausfuehren; Inhalt nicht ausgelesen.'
            }
        } else {
            $record.reason = 'Technisches, leeres oder nicht unterstuetztes Dateiformat; Inhalt nicht ausgewertet'
        }
        if ($record.status -ne 'skipped') {
            $record.hash = $record.sourceHash
            if (-not $reused) { $record.evaluatedAt = [DateTime]::UtcNow.ToString('o'); $record.indexedModified = $record.modified }
            $record.processingState = 'current'
            $record.headings = @([regex]::Matches($record.text, '(?m)^#{1,3}\s+(.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() })
            if ($record.headings.Count -gt 0 -and $extension -notin @('.pdf', '.xlsx', '.pptx')) { $record.title = $record.headings[0] }
        }
    } catch {
        $record.status = 'skipped'
        $record.reason = 'Auslesefehler: ' + $_.Exception.Message
        $record.text = ''
    }
    if ($record.status -eq 'skipped') {
        if ($previous.evaluatedAt) {
            $record.evaluatedAt = $previous.evaluatedAt
            $record.indexedModified = $previous.indexedModified
            $record.hash = $previous.hash
        }
        if ($previous.evaluatedAt -or $record.reason -match 'fehlgeschlagen|Auslesefehler|abgebrochen|verschluesselt|Parser|Reader-/OCR') {
            $record.processingState = 'error'
            $record.error = $record.reason
            if ($previous.text) {
                foreach ($key in @('text', 'title', 'status', 'reason', 'extraction')) { $record[$key] = $previous.$key }
                $record.links = @($previous.rawLinks)
            }
        }
    }
    $record.rawLinks = @($record.links)
    $records.Add([pscustomobject]$record)
    $counts[$record.status]++
}
} finally {
    if ($documentParser) {
        if (-not $documentParser.HasExited) { $documentParser.StandardInput.Close(); if (-not $documentParser.WaitForExit(2000)) { $documentParser.Kill() } }
        $documentParser.Dispose()
    }
}
Report-BuildProgress 2 $records.Count $workspaceFiles.Count

$result = [ordered]@{
    generated = [DateTime]::UtcNow.ToString('o'); directorySyncedAt = $directorySyncedAt; root = $root
    method = 'Lokale Textauswertung; automatische Zuordnungen sind Vorschlaege, keine bestaetigten Fachentscheidungen'
    excludedDirectories = @($omitted.ToArray()); topics = @(); files = @($records.ToArray())
}
$records | Group-Object status | Select-Object Count, Name | Format-Table -AutoSize
if ($IndexOnly) {
    [System.IO.File]::WriteAllText((Join-Path $outputPath 'inventory.json'), ($result | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
    $records | Where-Object { $_.status -ne 'skipped' } | ForEach-Object { $_.headings } |
        Group-Object | Sort-Object Count -Descending | Select-Object -First 45 Count, Name | Format-Table -AutoSize
    return
}

function Normalize-Content([string]$text) {
    $text = $text.ToLowerInvariant().Replace([string][char]0xE4, 'ae').Replace([string][char]0xF6, 'oe').Replace([string][char]0xFC, 'ue').Replace([string][char]0xDF, 'ss')
    $text.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
}

$definitions = @(
    @('individual', 'Individualbesteuerung', 'Steuern', 'individualbesteuer|ehepaarbesteuer|heiratsstrafe'),
    @('steuerrecht', 'Kantonales Steuerrecht', 'Steuern', 'steuergesetz|steuerbuch|steuerrecht|steuerharmonisierung|zh-lex|rechtsgrundlage.{0,25}steuer'),
    @('steuerverfahren', 'Steuerdeklaration und Verfahren', 'Steuern', 'steuererklaer|steuerdeklar|veranlag|steuerverfahr|quellensteuer|kryptowaehr|schenkungssteuer|erbschaftssteuer|grundstueckgewinnsteuer'),
    @('steuerzinsen', 'Steuerzinsen und Bezug', 'Steuern', 'verguetungszins|verzugszins|ausgleichszins|steuerzins|steuerbezug|steuern bezahlen|pilot zinsen'),
    @('taxa', 'TAXA und Natural/Adabas', 'Technologie', '\btaxa\b|\bnatural\b|\badabas\b|zueriprimo|zueri primo'),
    @('systemlandschaft', 'ZP-Systemlandschaft und Betrieb', 'Technologie', 'zp-systemlandschaft|systemlandschaft|betriebsleistung|dashboard abp|\babp\s+202[56]|batchverarbeit|bestands.{0,15}verarbeitungsuebersicht'),
    @('legacy', 'Legacy-Ablosung und Lifecycle', 'Technologie', '\blegacy\b|end.of.life|lifecycle|life.cycle|host.abloes|host.ausstieg|natural.adabas.ausstieg'),
    @('architektur', 'Architektur und Transformation', 'Technologie', 'zielarchitektur|target.architecture|transformationsroadmap|transformation.roadmap|architecture|architektur|transformation'),
    @('flur', 'Flurgenossenschaft und Statuten', 'Private Dossiers', 'flurgenossenschaft|gruenaustrasse|strassenkommission|\bstatuten\b'),
    @('sanierung', 'Strassensanierung und Finanzierung', 'Private Dossiers', 'strassensanierung|querleitung|sanierungsprojekt|ern.hochrechnung|\bnrp\b|kostenteiler|sanierung.{0,35}finanzierung'),
    @('hv', 'Hauptversammlung und Beschlusse', 'Private Dossiers', 'hauptversammlung|traktanden|beschlussantraeg|\bhv[ -]202[56]|praesidentenbericht|bericht des praesidenten'),
    @('pv', 'Photovoltaik und Speicher', 'Private Dossiers', 'photovolta|\bpv[ -]anlage|\bkwp\b|wechselrichter|batteriespeicher|solaranlage'),
    @('fahrzeug', 'Fahrzeugwechsel und Mobilitat', 'Private Dossiers', 'fahrzeugwechsel|fahrzeugkauf|elektroauto|leasing|ladeinfrastruktur'),
    @('offerten', 'Offerten und Wirtschaftlichkeit', 'Entscheidung und Lieferung', 'offertenvergleich|angebotsvergleich|compare.offers|wirtschaftlichkeit|amortisation|anbieterangebot|querleitung.{0,40}vergleich'),
    @('entscheidung', 'Entscheidungs- und Risikobewertung', 'Entscheidung und Lieferung', 'management.decision|decision.brief|entscheidungsgrundlage|entscheidungsvorlage|risikobewertung|risk.assessment|risk.quality|management.summary'),
    @('delivery', 'Beratung, Stakeholder und Delivery', 'Entscheidung und Lieferung', 'engagement.lifecycle|engagement.lead|stakeholder.analysis|stakeholderanalyse|delivery|auftragsklaerung|abteilungsinformation'),
    @('ai', 'AI-Arbeitsmodell und Governance', 'Arbeitsorganisation', 'ai.os|ai.consulting|ai.private|ai.engineering|agenten|agent.modus|\bgovernance\b|target.operating.model|definition.of.done'),
    @('quellen', 'Quellenarbeit und Wissenspflege', 'Arbeitsorganisation', 'quellenregister|quellenverzeichnis|quellenpruefung|wissensregister|wissensluecken|mailwissen|mail.knowledge|quellenimport|source.ingestion|quellenherkunft|korrespondenzanalyse'),
    @('dokumente', 'Dokumentfuhrung und Synchronisation', 'Arbeitsorganisation', 'dokumentformate|fuehrende.fassung|google.docs|google.sheet|synchronis|repository.content|git.clone|mehreren rechnern|document.formats')
)
$topics = @($definitions | ForEach-Object { [pscustomobject]@{ id = $_[0]; label = $_[1]; group = $_[2]; pattern = $_[3]; count = 0; textCount = 0; referenceCount = 0; evidenceFiles = @() } })
$topicProgress.candidates = $topics.Count
$topicProgress.rows = $topics
$byPath = @{}
foreach ($record in $records) { $byPath[$record.path] = $record }

$metadataPattern = '(?m)^(?>[\t ]*)(?:[-*](?>[\t ]*))?(source_path|local_path|path|url|source_url|original_url)(?>[\t ]*):[^\r\n]*\r?$'
$assigned = 0
foreach ($record in $records) {
    $topicProgress.activeTopic = ''
    $topicProgress.detail = 'Durchlauf 1 von 2: Dokumentrollen und Dateiverweise pruefen'
    Report-BuildProgress 3 $assigned ($records.Count * 2) $record.path
    $assigned++
    $path = $record.path
    if ($path -match '(^|/)(templates?|06_TEMPLATES|01_ROLES|02_SKILLS|03_PLAYBOOKS|00_OPERATING_MODEL|skills|shared)(/|$)' -or $record.name -match '(^|[_-])template([_.-]|$)' -or $record.name -eq 'AGENTS.md') {
        $record.roles = @('Arbeitsmittel')
    } elseif ($path -match '\.meta\.(yaml|json)$|09_SYSTEM|(^|/)(INDEX|CURRENT_STATE|README|CATALOG|CONTENT_REGISTER|SOURCE_REGISTER|document-register|mail-register|working-documents)\.md$') {
        $record.roles = @('Kontext und Register')
    } elseif ($path -match '(^|/)(deliverables|analysis|meetings)(/|$)|management.summary|praesentation|offertenvergleich|hochrechnung|correspondence-analysis|querleitung-offertenvergleich') {
        $record.roles = @('Ergebnis')
    } elseif ($path -match '(^|/)(05_SOURCE_MATERIAL|inbox|documents|correspondence|assets|sources|mail-archive)(/|$)' -or $record.extension -in @('.pdf', '.eml', '.msg')) {
        $record.roles = @('Originalquelle')
        if ($record.extension -in @('.md', '.txt') -and $record.text -match '(?i)snapshot|auszug|uebertragung|\u00fcbertragung|verdichtet|quellenregister') {
            $record.roles = @('Wissen', 'Quellenauszug')
        }
    } elseif ($record.status -ne 'skipped') { $record.roles = @('Wissen') }
    else { $record.roles = @('Sonstiges') }

    $linkClock = [Diagnostics.Stopwatch]::StartNew()
    $resolved = [System.Collections.Generic.List[string]]::new()
    $sourceLines = $null
    $sourceHeadings = $null
    $sourceContexts = $null
    foreach ($link in $record.links) {
        $topicProgress.linksChecked++
        Report-BuildProgress 3 ($assigned - 1) ($records.Count * 2) $record.path
        if ($link -match '^https?://') { $record.externalLinks += $link; continue }
        if ($link -match '^([a-z]+:|#|//)') { continue }
        try {
            $clean = [Uri]::UnescapeDataString(($link -split '[?#]')[0])
            $absolute = [System.IO.Path]::GetFullPath((Join-Path (Split-Path (Join-Path $root $path) -Parent) $clean))
            if ($absolute.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                $target = $absolute.Substring($root.Length + 1).Replace('\', '/')
                if ($byPath.ContainsKey($target)) {
                    $resolved.Add($target)
                    if ($null -eq $sourceLines) {
                        $sourceLines = $record.text -split '\r?\n'
                        $sourceHeadings = [string[]]::new($sourceLines.Count)
                        $sourceContexts = [string[]]::new($sourceLines.Count)
                        $heading = $record.title
                        for ($sourceIndex = 0; $sourceIndex -lt $sourceLines.Count; $sourceIndex++) {
                            if ($sourceLines[$sourceIndex] -match '^#{1,3}\s+(.+)$') { $heading = $Matches[1] }
                            $sourceHeadings[$sourceIndex] = $heading
                        }
                    }
                    $contexts = [System.Collections.Generic.List[string]]::new()
                    for ($sourceIndex = 0; $sourceIndex -lt $sourceLines.Count; $sourceIndex++) {
                        if ($sourceLines[$sourceIndex].Contains($link)) {
                            if ($null -eq $sourceContexts[$sourceIndex]) {
                                $caption = [regex]::Replace($sourceLines[$sourceIndex], '\]\([^)]*\)', ']')
                                $sourceContexts[$sourceIndex] = $record.title + ' / ' + $sourceHeadings[$sourceIndex] + ' / ' + $caption
                            }
                            $contexts.Add($sourceContexts[$sourceIndex])
                        }
                    }
                    $record.linkContexts[$target] = $contexts -join ' '
                }
            }
        } catch { }
    }
    $record.links = @($resolved.ToArray() | Sort-Object -Unique)
    $topicProgress.timings.links += $linkClock.Elapsed.TotalMilliseconds
    if ($record.status -eq 'skipped') { continue }
    $preparationClock = [Diagnostics.Stopwatch]::StartNew()
    $content = [regex]::Replace($record.text, '\]\([^)]*\)', ']')
    $content = [regex]::Replace($content, $metadataPattern, '')
    $normalized = Normalize-Content $content
    $contentLines = $content -split '\r?\n'
    $lineStarts = [int[]]@(0; foreach ($lineBreak in [regex]::Matches($normalized, "`n")) { $lineBreak.Index + 1 })
    $topicProgress.timings.preparation += $preparationClock.Elapsed.TotalMilliseconds
    $ruleClock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($topic in $topics) {
        $topicProgress.activeTopic = $topic.id
        $topicProgress.detail = 'Durchlauf 1 von 2: Themenregel ' + $topic.label + ' pruefen'
        Report-BuildProgress 3 ($assigned - 1) ($records.Count * 2) $record.path
        $hits = [regex]::Matches($normalized, $topic.pattern)
        $topicProgress.rulesChecked++
        if ($hits.Count -eq 0) { continue }
        $excerpt = ''
        foreach ($hit in $hits) {
            if ($hit.Value.Contains("`n")) { continue }
            $lineIndex = [Array]::BinarySearch($lineStarts, [int]$hit.Index)
            if ($lineIndex -lt 0) { $lineIndex = -$lineIndex - 2 }
            $excerpt = ($contentLines[$lineIndex] -replace '\s+', ' ').Trim()
            break
        }
        if ($excerpt.Length -gt 220) { $excerpt = $excerpt.Substring(0, 217) + '...' }
        $record.topics += [pscustomobject]@{
            id = $topic.id; proposed = $true; basis = 'Textbeleg'; evidence = $excerpt
            evidencePath = $record.path; hits = $hits.Count
        }
        if ($topicProgress.found.Add($topic.id)) { $topicProgress.labels.Add($topic.label) }
        $topicProgress.documents.Add($record.path) | Out-Null
        $topicProgress.textAssignments++
        $topic.textCount++
        $topic.count++
    }
    $topicProgress.timings.rules += $ruleClock.Elapsed.TotalMilliseconds
}

$referenceClock = [Diagnostics.Stopwatch]::StartNew()
foreach ($record in $records) {
    $topicProgress.activeTopic = ''
    $topicProgress.detail = 'Durchlauf 2 von 2: Themen ueber dokumentierte Originalquellen-Verweise zuordnen'
    Report-BuildProgress 3 $assigned ($records.Count * 2) $record.path
    $assigned++
    foreach ($target in $record.links) {
        $linked = $byPath[$target]
        if ($linked.status -ne 'skipped' -or $linked.roles -notcontains 'Originalquelle') { continue }
        foreach ($assignment in @($record.topics | Where-Object { $_.basis -eq 'Textbeleg' })) {
            $topicProgress.activeTopic = $assignment.id
            Report-BuildProgress 3 ($assigned - 1) ($records.Count * 2) $record.path
            $definition = $topics | Where-Object id -eq $assignment.id | Select-Object -First 1
            $context = $record.linkContexts[$target]
            if ((Normalize-Content $context) -notmatch $definition.pattern) { continue }
            if ($linked.topics.id -contains $assignment.id) { continue }
            $excerpt = ($context -replace '\s+', ' ').Trim()
            if ($excerpt.Length -gt 220) { $excerpt = $excerpt.Substring(0, 217) + '...' }
            $linked.topics += [pscustomobject]@{
                id = $assignment.id; proposed = $true; basis = 'Dokumentverweis'
                evidence = 'Verweiskontext: ' + $excerpt + ' Originalinhalt nicht ausgewertet.'
                evidencePath = $record.path; hits = 0
            }
            $topicProgress.documents.Add($linked.path) | Out-Null
            $topicProgress.referenceAssignments++
            $definition.referenceCount++
            $definition.count++
        }
    }
}
$topicProgress.timings.references = $referenceClock.Elapsed.TotalMilliseconds
$topicProgress.activeTopic = ''
Report-BuildProgress 3 ($records.Count * 2) ($records.Count * 2)

foreach ($topic in $topics) {
    $members = @($records | Where-Object { $_.topics.id -contains $topic.id })
    $topic.count = $members.Count
    $topic.evidenceFiles = @($members | Where-Object { @($_.topics | Where-Object { $_.id -eq $topic.id -and $_.basis -eq 'Textbeleg' }).Count -gt 0 } | Select-Object -First 3 -ExpandProperty path)
}
$result.topics = @($topics | Where-Object { $_.count -gt 0 } | Select-Object id, label, group, count, evidenceFiles)
$result.method = '19 regelbasierte Themenkandidaten aus gelesenen Titeln und wiederkehrenden Inhaltsbegriffen. Aufnahme nur mit Texttreffer; Originaldateien ohne Text koennen ueber direkte dokumentierte Verweise zugeordnet sein. Keine semantische Vollpruefung, keine bestaetigten Zuordnungen. Dokumentrollen ebenfalls automatisch aus Ablage und Inhalt vorgeschlagen.'
$privateDocuments = @($records | Select-Object path, name, title, status, reason, extraction, hash, sourceHash, bytes, modified, indexedModified, evaluatedAt, processingState, error, rawLinks, text)
[System.IO.File]::WriteAllText((Join-Path $outputPath 'documents.json'), ($privateDocuments | ConvertTo-Json -Depth 8 -Compress), [System.Text.UTF8Encoding]::new($false))
foreach ($record in $records) {
    $record.PSObject.Properties.Remove('text')
    $record.PSObject.Properties.Remove('headings')
    $record.PSObject.Properties.Remove('linkContexts')
    $record.PSObject.Properties.Remove('rawLinks')
}
$result.Remove('root')
$json = $result | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText((Join-Path $outputPath 'inventory.json'), $json, [System.Text.UTF8Encoding]::new($false))
$result.topics | Select-Object label, count | Format-Table -AutoSize

$checks = [System.Collections.Generic.List[string]]::new()
Report-BuildProgress 4 0 $records.Count
$diskPaths = @(Get-WorkspaceFiles $root | ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') })
if (@($diskPaths | Where-Object { -not $byPath.ContainsKey($_) }).Count -gt 0) { $checks.Add('Dateien fehlen im Register') }
if (@($records.path | Sort-Object -Unique).Count -ne $records.Count) { $checks.Add('Doppelte Registerpfade') }
$verified = 0
foreach ($record in $records) {
    Report-BuildProgress 4 $verified $records.Count $record.path
    $verified++
    if ($record.status -notin @('evaluated', 'partial', 'skipped')) { $checks.Add('Ungueltiger Status: ' + $record.path) }
    if ($record.status -eq 'skipped' -and -not $record.reason) { $checks.Add('Fehlender Auslassungsgrund: ' + $record.path) }
    if ($record.status -ne 'skipped') {
        $currentHash = (Get-FileHash -LiteralPath (Join-Path $root $record.path) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentHash -ne $record.sourceHash) { $checks.Add('Original waehrend Auswertung veraendert: ' + $record.path) }
    }
    foreach ($assignment in $record.topics) {
        if (-not $assignment.evidence -or -not $byPath.ContainsKey($assignment.evidencePath) -or $assignment.id -notin $result.topics.id -or -not $assignment.proposed) {
            $checks.Add('Unbelegte Zuordnung: ' + $record.path)
        }
    }
    foreach ($target in $record.links) {
        if (-not $byPath.ContainsKey($target)) { $checks.Add('Unaufgeloester Dateiverweis: ' + $target) }
    }
    if ($record.PSObject.Properties.Name -contains 'text') { $checks.Add('Volltext in Endausgabe: ' + $record.path) }
}
if ($checks.Count -gt 0) { throw ($checks -join "`n") }
Report-BuildProgress 4 $records.Count $records.Count
Report-BuildProgress 5 0 -1
Write-Output ('VALIDIERUNG OK: ' + $diskPaths.Count + ' Dateipfade, ' + $records.Count + ' Registereintraege, ' + @($records | Where-Object status -ne 'skipped').Count + ' Originalhashes, alle Themenbelege und Dateiverweise geprueft.')