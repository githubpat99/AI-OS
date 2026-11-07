# Wiederverwendbare Bearbeitung von Nachweisluecken.
# Arbeitet ausschliesslich im aktiven Wissensraum und verwendet vorhandene
# Import-/Index-Funktionen. Es wird nie eine automatische Synthese gestartet.

function Get-GapStatePath([string]$Name) {
    $config = Get-PocConfiguration
    $directory = [IO.Path]::GetDirectoryName([string]$config.poc.state_file)
    if (-not $directory) { throw 'Zustandsverzeichnis des Wissensraums fehlt.' }
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    return (Join-Path $directory $Name)
}

function Get-GapTerms([string]$Text) {
    $stop = @('welche','welcher','welches','sind','ist','was','wurde','wurden','werden','wird','bitte','oder','und','der','die','das','den','dem','des','ein','eine','einer','eines','einem','mit','für','fuer','von','vom','zum','zur','im','in','auf','aus','bei','nach','über','ueber','unter','wie','wo','wann','warum','sich','nicht','auch','noch','schon','kann','können','koennen','fehlt','fehlen','dokument','dokumente','gelten','gilt','vorhanden','belegen','belegt','enthalten','konkreter','konkreten','samt','höhe','hoehe','traktandenliste','traktanden','auszugsweise','vollständiger','vollstaendiger','allfälligen','allfaelligen')
    return @([regex]::Matches(([string]$Text).ToLowerInvariant(), '[a-zäöüß0-9]{4,}') | ForEach-Object { $_.Value } | Where-Object { $_ -notin $stop } | Select-Object -Unique | Select-Object -First 10)
}

function Get-GapRecordsPath {
    return (Get-GapStatePath 'gap-records.json')
}

function Read-GapRecords {
    $path = Get-GapRecordsPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try {
        $value = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($value.records)
    } catch { return @() }
}

function Get-GapRecordId([string]$WorkspaceKey, [string]$Question, [string]$Statement) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $text = ([string]$WorkspaceKey) + '|' + ([string]$Question) + '|' + ([string]$Statement)
        return 'gap-' + ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '').Substring(0, 16).ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-GapStatementTokens([string]$Text) {
    $generic = @(
        'kein','keine','keinen','keiner','ohne','nicht','nur','sowie','oder','und','der','die','das','den','dem','des',
        'ein','eine','einer','eines','für','fuer','von','vom','zum','zur','mit','auf','aus','bei','nach','über','ueber','unter',
        'dokument','dokumente','dokumentiert','dokumentierter','dokumentierte','nachweis','nachweise','beleg','belege','belegen',
        'unterlage','unterlagen','quelle','quellen','angabe','angaben','information','informationen','auskunft','auskuenfte',
        'vorhanden','fehlt','fehlen','vollständig','vollstaendig','vollständiger','vollstaendiger','konkret','konkrete','konkreten',
        'insbesondere','allfällig','allfaellig','allfällige','allfaellige','weiter','weitere','weiterer','dessen','deren',
        'enthält','enthaelt','enthalten','regelt','abschliessend','abschliessende','verbindlich','verbindliche','verbindlicher','rechtsverbindlich','rechtsverbindliche',
        'frage','fragen','bezug','betreffend','hinsichtlich','sowie','sowie','bereits','bisher','allerdings','jedoch'
    )
    return @([regex]::Matches(([string]$Text).ToLowerInvariant(), '[a-zäöüß0-9]{4,}') | ForEach-Object { $_.Value } | Where-Object { $_ -notin $generic } | Select-Object -Unique)
}

function Test-GapTokenOverlap([string]$Left, [string]$Right) {
    if (-not $Left -or -not $Right) { return $false }
    if ($Left -eq $Right) { return $true }
    if ($Left.Length -ge 6 -and $Right.Length -ge 6) {
        $prefix = 0
        $limit = [Math]::Min($Left.Length, $Right.Length)
        while ($prefix -lt $limit -and $Left[$prefix] -eq $Right[$prefix]) { $prefix++ }
        if ($prefix -ge 7) { return $true }
    }
    if ($Left.Length -ge 8 -and $Right.Contains($Left)) { return $true }
    if ($Right.Length -ge 8 -and $Left.Contains($Right)) { return $true }
    return $false
}

function Get-GapCategory([string]$Text) {
    if ($Text -match '(?i)statut|satzung|reglement|gesetz|artikel') { return 'statute' }
    if ($Text -match '(?i)beschluss|genehmigung|zustimmung|freigabe|protokoll|traktandum|versammlung') { return 'decision' }
    if ($Text -match '(?i)vertrag|vereinbarung|dienstbarkeit') { return 'contract' }
    return ''
}

function Find-GapRecordForStatement([string]$WorkspaceKey, [string]$Question, [string]$Statement) {
    $newTokens = @(Get-GapStatementTokens $Statement)
    if ($newTokens.Count -lt 2) { return $null }
    $newCategory = Get-GapCategory $Statement
    $best = $null
    $bestScore = 0.0
    foreach ($record in @(Read-GapRecords)) {
        if ([string]$record.question -ne $Question) { continue }
        $recordRoot = ''
        try { $recordRoot = [IO.Path]::GetFullPath([string]$record.store_root).ToLowerInvariant() } catch { }
        if ($recordRoot -and $WorkspaceKey -and $recordRoot -ne $WorkspaceKey) { continue }
        if ($newCategory -in @('statute', 'decision') -and (Get-GapCategory ([string]$record.statement)) -eq $newCategory) {
            return $record
        }
        $oldTokens = @(Get-GapStatementTokens ([string]$record.statement))
        if ($oldTokens.Count -lt 2) { continue }
        $overlap = 0
        foreach ($token in $newTokens) {
            if (@($oldTokens | Where-Object { Test-GapTokenOverlap $token $_ }).Count) { $overlap++ }
        }
        if ($overlap -lt 2) { continue }
        $score = $overlap / [double][Math]::Min($newTokens.Count, $oldTokens.Count)
        if ($score -ge 0.4 -and $score -gt $bestScore) {
            $best = $record
            $bestScore = $score
        }
    }
    return $best
}

function Get-GapRecord([string]$GapId) {
    if (-not $GapId) { return $null }
    $found = @(Read-GapRecords | Where-Object { [string]$_.id -eq $GapId })[0]
    if (-not $found) { return $null }
    if ($found -is [System.Collections.IDictionary]) { return $found }
    $record = [ordered]@{}
    foreach ($property in $found.PSObject.Properties) { $record[$property.Name] = $property.Value }
    return $record
}

function Save-GapRecord($Record) {
    if (-not $Record -or -not $Record.id) { return }
    $records = @(Read-GapRecords)
    $found = $false
    foreach ($item in $records) {
        if ([string]$item.id -eq [string]$Record.id) {
            $item.status = [string]$Record.status
            $item.inspection = $Record.inspection
            $item.upload = $Record.upload
            $item.link = $Record.link
            $item.attempts = [int]$Record.attempts
            $item.last_answer = $Record.last_answer
            $item.updated_at = Get-PocNow
            $found = $true
        }
    }
    if (-not $found) {
        $Record.created_at = if ($Record.created_at) { [string]$Record.created_at } else { Get-PocNow }
        $Record.updated_at = Get-PocNow
        $records = @($records) + @($Record)
    }
    [ordered]@{ schema = 'ai-os/gap-records/v1'; records = $records } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Get-GapRecordsPath) -Encoding UTF8
}

function New-GapRecord([string]$GapId, [string]$Question, [string]$Statement, [string]$PageId) {
    $config = Get-PocConfiguration
    return [ordered]@{
        schema = 'ai-os/gap-record/v1'
        id = $GapId
        workspace = [string]$config.poc.name
        store_root = [string]$config.store_root
        question = $Question
        statement = $Statement
        page_id = $PageId
        status = 'open'
        attempts = 0
        inspection = $null
        upload = $null
        link = $null
        last_answer = $null
        created_at = Get-PocNow
        updated_at = Get-PocNow
    }
}

function Merge-GapRecord([string]$GapId, [string]$Question, [string]$Statement, [string]$PageId, $Changes) {
    $record = Get-GapRecord $GapId
    if (-not $record) { $record = New-GapRecord $GapId $Question $Statement $PageId }
    foreach ($key in @('status', 'inspection', 'upload', 'link', 'attempts', 'last_answer')) {
        if ($Changes.Keys -contains $key) { $record[$key] = $Changes[$key] }
    }
    Save-GapRecord $record
    return $record
}

function Get-GapItems {
    return @(Invoke-Wb @('item', 'list', '--limit', '500'))
}

function Find-GapCandidates([string]$Text) {
    $items = @(Get-GapItems)
    $terms = @(Get-GapTerms $Text)
    if (-not $terms.Count) { return @() }
    $common = @{}
    foreach ($term in $terms) {
        $matchCount = @($items | Where-Object { ([string]$_.display_path).ToLowerInvariant().Contains($term) }).Count
        if ($matchCount -gt [Math]::Max(5, [int]($items.Count * 0.25))) { $common[$term] = $true }
    }
    $terms = @($terms | Where-Object { -not $common.ContainsKey($_) })
    if (-not $terms.Count) { return @() }
    $variants = [Collections.Generic.List[string]]::new()
    foreach ($term in $terms) {
        if (-not $variants.Contains($term)) { $variants.Add($term) }
        foreach ($suffix in @('entext', 'text', 'ungen', 'ung', 'en', 'er', 'es')) {
            if ($term.EndsWith($suffix) -and ($term.Length - $suffix.Length) -ge 5) {
                $stem = $term.Substring(0, $term.Length - $suffix.Length)
                if (-not $variants.Contains($stem)) { $variants.Add($stem) }
                break
            }
        }
    }
    $terms = @($variants.ToArray())
    $termFrequency = @{}
    foreach ($term in $terms) {
        $termFrequency[$term] = @($items | Where-Object { ([string]$_.display_path).ToLowerInvariant().Contains($term) }).Count
    }
    $candidates = [Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($item in $items) {
        $path = [string]$item.display_path
        $lower = $path.ToLowerInvariant()
        $matched = 0
        $score = 0.0
        foreach ($term in $terms) {
            if (-not $lower.Contains($term)) { continue }
            $matched++
            $score += 1.0 / [Math]::Max(1, [int]$termFrequency[$term])
        }
        if ($matched -eq 0) { continue }
        $strong = @($terms | Where-Object { $_.Length -ge 8 -and $lower.Contains($_) }).Count -gt 0
        if ($seen.ContainsKey($path)) { continue }
        $seen[$path] = $true
        $candidates.Add([ordered]@{ item = $item; matched = $matched; score = $score; strong_match = $strong })
    }
    return @($candidates | Sort-Object { $_.score } -Descending | Select-Object -First 8)
}

function Inspect-IngestionGap([string]$Text, [string]$Query = '', [string]$GapId = '', [string]$Question = '', [string]$PageId = '') {
    $config = Get-PocConfiguration
    $inventoryChecked = $false
    if ($config.poc.inventory_file -and (Test-Path -LiteralPath ([string]$config.poc.inventory_file) -PathType Leaf)) { $inventoryChecked = $true }
    $searchText = (([string]$Text) + ' ' + ([string]$Query)).Trim()
    $terms = @(Get-GapTerms $searchText)
    $hitTerms = @($terms)
    if ($searchText -match '(?i)statut|artikel|art\.|regel') { $hitTerms = @('Art.', 'Kostenverteilung', 'Beitrag') + @($hitTerms) }
    $hitTerms = @($hitTerms | Select-Object -Unique)
    $candidates = @(Find-GapCandidates $searchText)
    $hitByPath = @{}
    foreach ($term in @($hitTerms | Select-Object -First 8)) {
        try {
            $found = Get-KnowledgeSearch $term
            foreach ($r in @($found.results)) {
                $hitPath = [string]$r.display_path
                if (-not $hitPath) { continue }
                if (-not $hitByPath.ContainsKey($hitPath)) { $hitByPath[$hitPath] = [Collections.Generic.List[object]]::new() }
                if ($hitByPath[$hitPath].Count -lt 20) { $hitByPath[$hitPath].Add($r) }
            }
        } catch { }
    }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $candidates) {
        $item = $candidate.item
        $chars = 0
        $pages = 0
        $ocr = $false
        try {
            $evidence = Invoke-Wb @('evidence', [string]$item.version_id)
            $chars = ([string]$evidence.text).Length
            $pages = @($evidence.pages).Count
            $ocr = [string]$evidence.extraction.reason -match 'OCR ausstehend'
        } catch { }
        $itemPath = [string]$item.display_path
        $hits = if ($hitByPath.ContainsKey($itemPath)) { @($hitByPath[$itemPath] | Select-Object -First 3) } else { @() }
        $indexed = @($hits).Count -gt 0
        $results.Add([ordered]@{
            path = [string]$item.display_path
            version_id = [string]$item.version_id
            extraction_status = [string]$item.extraction_status
            extraction_reason = [string]$item.extraction_reason
            chars = $chars
            pages = $pages
            ocr_pending = $ocr
            indexed = $indexed
            strong_match = [bool]$candidate.strong_match
            search_hits = @($hits | Select-Object -First 3 | ForEach-Object { [ordered]@{ page = $_.page; snippet = [string]$_.snippet } })
        })
    }
    $verdict = if (-not $results.Count) {
        'no_match'
    } elseif (@($results | Where-Object { $_.chars -gt 0 -and $_.indexed }).Count) {
        'indexed'
    } elseif (@($results | Where-Object { $_.chars -le 0 }).Count) {
        'unreadable'
    } elseif (@($results | Where-Object { $_.chars -gt 0 -and $_.strong_match }).Count) {
        'not_indexed'
    } else {
        'no_match'
    }
    if ($verdict -eq 'no_match') { $results = [Collections.Generic.List[object]]::new() }
    $label = switch ($verdict) {
        'no_match' { 'Keine passende Quelle gefunden' }
        'indexed' { 'Dokument vorhanden, relevante Stellen lesbar' }
        'not_indexed' { 'Dokument vorhanden, aber nicht im Suchindex' }
        'unreadable' { 'Dokument vorhanden, Text unvollständig' }
        default { 'Ungeklärt' }
    }
    $nextStep = switch ($verdict) {
        'indexed' { 'reanswer' }
        'unreadable' { 'run_ocr' }
        'not_indexed' { 'rebuild_index' }
        default { 'upload' }
    }
    $message = switch ($verdict) {
        'indexed' { 'Das Dokument ist vorhanden und die relevanten Stellen sind über die Suche erreichbar. Die Quelle kann für die erneute Antwort verwendet werden.' }
        'unreadable' { 'Das Dokument ist erfasst, besitzt aber keinen auswertbaren Text. Extraktion prüfen beziehungsweise OCR erneut ausführen.' }
        'not_indexed' { 'Das Dokument ist vorhanden, wurde aber bei der Suche nicht als Treffer geführt. Index prüfen.' }
        default { 'Die Suche hat keine passende Quelle gefunden. Das ist keine Aussage über den gesamten Bestand; eine Aufnahme kann angeboten werden.' }
    }
    $recordStatus = switch ($verdict) {
        'indexed' { 'source_assigned' }
        'unreadable' { 'extraction_needed' }
        'not_indexed' { 'index_needed' }
        default { 'open' }
    }
    $inspection = [ordered]@{
        schema = 'ai-os/gap-inspection/v1'
        text = $Text
        query = $Query
        inventory_checked = $inventoryChecked
        verdict = $verdict
        label = $label
        message = $message
        next_step = $nextStep
        terms = $terms
        candidates = @($results.ToArray())
        can_upload = $verdict -in @('no_match', 'unreadable', 'not_indexed')
    }
    if ($GapId) {
        $existingRecord = Get-GapRecord $GapId
        if ($existingRecord -and [string]$existingRecord.status -eq 'proof_found') { $recordStatus = 'proof_found' }
        $changes = @{ status = $recordStatus; inspection = $inspection }
        $record = Merge-GapRecord $GapId $Question $Text $PageId $changes
        $inspection.record = [ordered]@{ id = $record.id; status = $record.status; attempts = $record.attempts }
    }
    return $inspection
}

function Get-GapFileName([string]$Name) {
    $base = [IO.Path]::GetFileName([string]$Name)
    if (-not $base) { throw 'Dateiname fehlt.' }
    $base = ($base -replace '[^a-zA-Z0-9._\-äöüÄÖÜß ]', '_').Trim()
    if (-not $base) { throw 'Dateiname ist ungueltig.' }
    return $base
}

function Add-IngestionGapFile([string]$Name, [string]$Base64, [string]$GapId, [string]$Text = '', [string]$Question = '') {
    $config = Get-PocConfiguration
    $formats = @($config.poc.formats | ForEach-Object { [string]$_ })
    if (-not $formats.Count) { $formats = @('pdf') }
    $fileName = Get-GapFileName $Name
    $extension = [IO.Path]::GetExtension($fileName).ToLowerInvariant().TrimStart('.')
    if (-not $extension -or $extension -notin $formats) { throw ('Dateityp wird in diesem Wissensraum nicht aufgenommen: ' + $extension) }
    $bytes = $null
    try { $bytes = [Convert]::FromBase64String([string]$Base64) } catch { throw 'Dateiinhalt ist kein gueltiges Base64.' }
    if (-not $bytes -or $bytes.Length -eq 0) { throw 'Datei ist leer.' }
    if ($bytes.Length -gt 40MB) { throw 'Datei ist fuer den direkten Upload zu gross (max. 40 MB).' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    $items = @(Get-GapItems)
    $existing = @($items | Where-Object { [string]$_.content_hash -eq $hash })[0]
    if ($existing) {
        $upload = [ordered]@{
            status = 'reused'
            message = 'Das Dokument ist bereits importiert; es wurde nicht dupliziert.'
            item_id = [string]$existing.item_id
            version_id = [string]$existing.version_id
            path = [string]$existing.display_path
            sha256 = $hash
            extraction_status = [string]$existing.extraction_status
            extraction_reason = [string]$existing.extraction_reason
            permissions = [ordered]@{ space = if ($config.poc.source_space) { [string]$config.poc.source_space } else { 'private' }; confidentiality = if ($config.poc.source_confidentiality) { [string]$config.poc.source_confidentiality } else { 'confidential' } }
            reanswer_available = $true
        }
        $record = Merge-GapRecord $GapId $Question $Text '' @{ status = 'evaluation_needed'; upload = $upload }
        $upload.record_status = $record.status
        return $upload
    }
    $rawRoot = [IO.Path]::GetFullPath([string]$config.poc.raw_root).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath((Join-Path $rawRoot ('files\imports\' + $fileName)))
    if (-not $target.StartsWith($rawRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Zieldatei liegt ausserhalb des Wissensraums.' }
    $directory = [IO.Path]::GetDirectoryName($target)
    if ($directory) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $existingHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingHash -ne $hash) { $target = [IO.Path]::GetFullPath((Join-Path $rawRoot ('files\imports\' + [IO.Path]::GetFileNameWithoutExtension($fileName) + '-' + $hash.Substring(0, 8) + '.' + $extension))) }
    }
    [IO.File]::WriteAllBytes($target, $bytes)
    $manifestPath = Join-Path ([string]$config.poc.raw_root) 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $relative = 'files/' + ($target.Substring([IO.Path]::GetFullPath([string]$config.poc.raw_root).TrimEnd('\').Length + 1) -replace '\\', '/')
            $manifest.files = @($manifest.files) + @([ordered]@{ source_path = $null; raw_path = $relative; sha256 = $hash; size = $bytes.Length; copied_at = Get-PocNow; action = 'uploaded'; origin = $fileName })
            Write-PocJson $manifestPath $manifest
        } catch { }
    }
    $statePath = Get-GapStatePath 'gap-uploads.json'
    $records = @()
    if (Test-Path -LiteralPath $statePath -PathType Leaf) { try { $records = @((Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json).uploads) } catch { } }
    $record = [ordered]@{ id = 'upl-' + [guid]::NewGuid().ToString('N'); gap_id = $GapId; original_name = $fileName; target = $target; sha256 = $hash; bytes = $bytes.Length; uploaded_at = Get-PocNow; status = 'importing'; error = '' }
    try {
        $import = Invoke-PocImport $config
        $items = @(Get-GapItems)
        $imported = @($items | Where-Object { [string]$_.content_hash -eq $hash })[0]
        if (-not $imported) { throw 'Die Datei wurde geschrieben, aber nicht im Store gefunden.' }
        $record.status = 'imported'
        $record.item_id = [string]$imported.item_id
        $record.version_id = [string]$imported.version_id
        $record.display_path = [string]$imported.display_path
        $record.extraction_status = [string]$imported.extraction_status
        $record.extraction_reason = [string]$imported.extraction_reason
        $evidence = Invoke-Wb @('evidence', [string]$imported.version_id)
        $record.permissions = [ordered]@{ space = if ($config.poc.source_space) { [string]$config.poc.source_space } else { 'private' }; confidentiality = if ($config.poc.source_confidentiality) { [string]$config.poc.source_confidentiality } else { 'confidential' } }
    } catch {
        $record.status = 'failed'
        $record.error = $_.Exception.Message
        $records = @($records) + @($record)
        $records | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
        throw
    }
    $records = @($records) + @($record)
    [ordered]@{ schema = 'ai-os/gap-uploads/v1'; uploads = $records } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
    $upload = [ordered]@{
        status = 'imported'
        message = 'Datei wurde im ausgewählten Wissensraum aufgenommen und indexiert.'
        item_id = [string]$imported.item_id
        version_id = [string]$imported.version_id
        path = [string]$imported.display_path
        sha256 = $hash
        extraction_status = [string]$imported.extraction_status
        extraction_reason = [string]$imported.extraction_reason
        permissions = $record.permissions
        reanswer_available = $true
    }
    $gapRecord = Merge-GapRecord $GapId $Question $Text '' @{ status = 'evaluation_needed'; upload = $upload }
    $upload.record_status = $gapRecord.status
    return $upload
}

function Add-IngestionGapLink([string]$Url, [string]$GapId, [string]$Label = '', [string]$Question = '') {
    $uri = $null
    if (-not [Uri]::TryCreate([string]$Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) { throw 'Nur absolute HTTP(S)-Links koennen verknuepft werden.' }
    $path = Get-GapStatePath 'gap-links.json'
    $records = @()
    if (Test-Path -LiteralPath $path -PathType Leaf) { try { $records = @((Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).links) } catch { } }
    $existing = @($records | Where-Object { [string]$_.url -eq [string]$uri.AbsoluteUri })[0]
    if ($existing) { return $existing }
    $record = [ordered]@{
        id = 'lnk-' + [guid]::NewGuid().ToString('N')
        gap_id = $GapId
        url = [string]$uri.AbsoluteUri
        label = if ($Label) { [string]$Label } else { [string]$uri.Host }
        status = 'linked_not_extracted'
        message = 'Verknüpft, Inhalt noch nicht ausgewertet'
        created_at = Get-PocNow
    }
    $records = @($records) + @($record)
    [ordered]@{ schema = 'ai-os/gap-links/v1'; links = $records } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    $gapRecord = Merge-GapRecord $GapId $Question $Label '' @{ status = 'linked_not_extracted'; link = $record }
    $record.record_status = $gapRecord.status
    return $record
}
