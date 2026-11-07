# Wiederverwendbare Aufnahme-Pipeline: RAW-Aufnahme, Import/Index und belegte Synthese.
# Die Funktionen arbeiten ausschliesslich mit der aktiven Wissensbasis-Konfiguration.
# CLI und Web-App rufen dieselbe Logik ueber pipeline.ps1 auf.

function Get-PocNow { [DateTime]::UtcNow.ToString('o') }

function Get-PocConfiguration {
    $config = Get-Content -LiteralPath $WissensbasisConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $config.poc) { throw 'Diese Wissensbasis-Konfiguration enthaelt keinen PoC-Abschnitt.' }
    return $config
}

function Get-PocStatePath($config) { [string]$config.poc.state_file }
function Get-PocSynthesisPath($config) { [string]$config.poc.synthesis_file }

function Write-PocJson([string]$Path, $Value) {
    $directory = [IO.Path]::GetDirectoryName($Path)
    if ($directory) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 15), [Text.UTF8Encoding]::new($false))
}

function Read-PocState($config) {
    $path = Get-PocStatePath $config
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Write-PocState($config, $State) {
    Write-PocJson (Get-PocStatePath $config) $State
}

function Repair-PocStateFields($State) {
    foreach ($name in @('jobId', 'attempt', 'resumeCount', 'lastError', 'permissions', 'warnings', 'resume')) {
        $value = switch ($name) {
            'jobId' { 'job-' + [guid]::NewGuid().ToString('N') }
            'attempt' { 1 }
            'resumeCount' { 0 }
            'lastError' { '' }
            'warnings' { @() }
            'resume' { $false }
            default { $null }
        }
        if ($State -is [System.Collections.IDictionary]) {
            if (-not $State.Contains($name)) { $State[$name] = $value }
        } elseif (-not $State.PSObject.Properties[$name]) {
            $State | Add-Member -NotePropertyName $name -NotePropertyValue $value
        }
    }
    return $State
}

function New-PocState($config) {
    $now = Get-PocNow
    $ai = $script:aiConfiguration
    return [ordered]@{
        schema = 'ai-os/poc-run/v1'
        jobId = 'job-' + [guid]::NewGuid().ToString('N')
        state = 'running'
        startedAt = $now
        updatedAt = $now
        lastRunAt = $now
        finishedAt = $null
        attempt = 1
        resumeCount = 0
        lastError = ''
        resume = $false
        pid = $PID
        currentStep = 'raw'
        steps = @(
            [ordered]@{ name = 'raw'; label = 'RAW'; status = 'pending'; detail = ''; startedAt = $null; endedAt = $null }
            [ordered]@{ name = 'import'; label = 'Import'; status = 'pending'; detail = ''; startedAt = $null; endedAt = $null }
            [ordered]@{ name = 'index'; label = 'Index'; status = 'pending'; detail = ''; startedAt = $null; endedAt = $null }
            [ordered]@{ name = 'synthesis'; label = 'Synthese'; status = 'pending'; detail = ''; startedAt = $null; endedAt = $null }
            [ordered]@{ name = 'ready'; label = 'Bereit'; status = 'pending'; detail = ''; startedAt = $null; endedAt = $null }
        )
        documents = 0
        pages = 0
        needsReview = 0
        knowledgeId = ''
        versionId = ''
        permissions = $null
        reused = $false
        fingerprint = ''
        error = ''
        warnings = @()
        ai = [ordered]@{
            configured = [bool]($ai -and $ai.configured)
            provider = [string]($ai.provider)
            model = [string]($ai.model)
            external = (Test-PocExternal $ai)
        }
        raw = [ordered]@{ root = [string]$config.poc.raw_root; files = 0; provenance = 0 }
        store = [string]$config.store_root
    }
}

function Set-PocStep($config, $State, [string]$Name, [string]$Status, [string]$Detail = '') {
    $now = Get-PocNow
    $steps = @($State.steps)
    $found = $false
    foreach ($step in $steps) {
        if ([string]$step.name -eq $Name) {
            $step.status = $Status
            $step.detail = $Detail
            if ($Status -eq 'running' -and -not $step.startedAt) { $step.startedAt = $now }
            if ($Status -in @('completed', 'failed', 'blocked', 'skipped')) { $step.endedAt = $now }
            $found = $true
        }
    }
    if (-not $found) {
        $steps += [ordered]@{ name = $Name; label = $Name; status = $Status; detail = $Detail; startedAt = $now; endedAt = $now }
    }
    $State.steps = $steps
    $State.currentStep = $Name
    $State.updatedAt = $now
    Write-PocState $config $State
}

function Test-PocExternal($ai) {
    if (-not $ai -or -not $ai.configured) { return $false }
    if ([string]$ai.provider -eq 'ollama') { return $false }
    $endpoint = [string]$ai.endpoint
    return -not ($endpoint -match '^https?://(127\.0\.0\.1|localhost|\[::1\])(?::|/|$)')
}

function Get-PocKnowledgePermissions([string]$KnowledgeId) {
    if (-not $KnowledgeId) { return $null }
    $detail = Invoke-Wb @('knowledge', 'show', $KnowledgeId)
    return [ordered]@{
        space = [string]$detail.knowledge.space
        confidentiality = [string]$detail.version.effective_confidentiality
        effective_space = [string]$detail.version.effective_space
        basis_hash = [string]$detail.basis_hash
        review_state = [string]$detail.version.review_state
    }
}

function Get-PocSourceCode([string]$Path) {
    $stem = [IO.Path]::GetFileNameWithoutExtension([string]$Path)
    $match = [regex]::Match($stem, '^([A-Z]{2,}(?:-[A-Z]+)*-\d{3})(?=-|$)')
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Get-PocSourceLabel([string]$Path) {
    $code = Get-PocSourceCode $Path
    if ($code) { return $code }
    $stem = [IO.Path]::GetFileNameWithoutExtension([string]$Path)
    if ($stem -match '^\d{4}-\d{2}-\d{2}') { return 'E-Mail ' + $Matches[0] }
    if ($stem -match '^(?i)(nrp-mail-\d+)') { return $Matches[1].ToUpperInvariant() }
    return $stem
}

function Get-PocCounts {
    $documents = 0
    $pages = 0
    $needsReview = 0
    try { $documents = @(Invoke-Wb @('item', 'list', '--limit', '500')).Count } catch { }
    try {
        $notes = @(Invoke-Wb @('note', 'list'))
        $pages = $notes.Count
        foreach ($note in $notes) {
            try {
                $detail = Invoke-Wb @('knowledge', 'show', [string]$note.knowledge_id)
                if ([string]$detail.version.review_state -ne 'confirmed') { $needsReview++ }
            } catch { $needsReview++ }
        }
    } catch { }
    return [ordered]@{ documents = $documents; pages = $pages; needsReview = $needsReview }
}

function Copy-PocRaw($config) {
    $poc = $config.poc
    $sourceRoot = [IO.Path]::GetFullPath([string]$poc.source_root).TrimEnd('\') + '\'
    $rawRoot = [IO.Path]::GetFullPath([string]$poc.raw_root).TrimEnd('\') + '\'
    $manifestPath = Join-Path ([string]$poc.raw_root) 'manifest.json'
    $existing = @{}
    $createdAt = Get-PocNow
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $old = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($old.created_at) { $createdAt = [string]$old.created_at }
            foreach ($entry in @($old.files)) { if ($entry.raw_path) { $existing[[string]$entry.raw_path] = $entry } }
        } catch { }
    }
    $files = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[object]]::new()
    foreach ($relativeValue in @($poc.files)) {
        $relative = ([string]$relativeValue).Replace('/', '\').TrimStart('\')
        $source = [IO.Path]::GetFullPath((Join-Path $sourceRoot $relative))
        if (-not $source.StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add([ordered]@{ path = [string]$relativeValue; reason = 'Pfad ausserhalb des Quellordners' })
            continue
        }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            $errors.Add([ordered]@{ path = [string]$relativeValue; reason = 'Datei nicht gefunden' })
            continue
        }
        $sourceItem = Get-Item -LiteralPath $source -Force
        if ($sourceItem.PSIsContainer) {
            $errors.Add([ordered]@{ path = [string]$relativeValue; reason = 'Keine Datei' })
            continue
        }
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        $rawRelative = 'files/' + ($relative -replace '\\', '/')
        $target = Join-Path ([string]$poc.raw_root) ($rawRelative -replace '/', '\')
        $targetFull = [IO.Path]::GetFullPath($target)
        if (-not $targetFull.StartsWith($rawRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add([ordered]@{ path = [string]$relativeValue; reason = 'RAW-Pfad ausserhalb des Ziels' })
            continue
        }
        $directory = [IO.Path]::GetDirectoryName($targetFull)
        if ($directory) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
        $copiedAt = Get-PocNow
        $action = 'copied'
        if (Test-Path -LiteralPath $targetFull -PathType Leaf) {
            $targetHashBefore = (Get-FileHash -LiteralPath $targetFull -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($targetHashBefore -eq $sourceHash) {
                $action = 'unchanged'
                if ($existing.ContainsKey($rawRelative) -and $existing[$rawRelative].copied_at) {
                    $copiedAt = [string]$existing[$rawRelative].copied_at
                }
            } else {
                [IO.File]::Copy($source, $targetFull, $true)
                $action = 'replaced'
            }
        } else {
            [IO.File]::Copy($source, $targetFull, $false)
        }
        $targetHash = (Get-FileHash -LiteralPath $targetFull -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($targetHash -ne $sourceHash) {
            Remove-Item -LiteralPath $targetFull -Force -ErrorAction SilentlyContinue
            $errors.Add([ordered]@{ path = [string]$relativeValue; reason = 'RAW-Hash stimmt nicht mit Original ueberein' })
            continue
        }
        $sourceHashAfter = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sourceHashAfter -ne $sourceHash) {
            $errors.Add([ordered]@{ path = [string]$relativeValue; reason = 'Original waehrend der Kopie veraendert' })
            continue
        }
        $files.Add([ordered]@{
            source_path = $source
            raw_path = $rawRelative
            sha256 = $sourceHash
            size = [long]$sourceItem.Length
            copied_at = $copiedAt
            action = $action
        })
    }
    $manifest = [ordered]@{
        schema = 'ai-os/poc-raw/v1'
        created_at = $createdAt
        updated_at = Get-PocNow
        source_root = [string]$poc.source_root
        source_id = [string]$poc.source_id
        files = @($files.ToArray())
    }
    Write-PocJson $manifestPath $manifest
    return [ordered]@{ manifest = $manifest; files = @($files.ToArray()); errors = @($errors.ToArray()) }
}

function Copy-PocProvenance($config) {
    $poc = $config.poc
    $inventoryPath = [string]$poc.inventory_file
    if (-not $inventoryPath -or -not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) { return @() }
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sourceRoot = [IO.Path]::GetFullPath([string]$poc.source_root).TrimEnd('\') + '\'
    $provenanceRoot = Join-Path ([string]$poc.raw_root) 'provenance\duplicates'
    [IO.Directory]::CreateDirectory($provenanceRoot) | Out-Null
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($group in @($inventory.duplicate_groups)) {
        foreach ($pathValue in @($group.paths)) {
            $relative = ([string]$pathValue).Replace('\', '/').TrimStart('/')
            if ($relative -eq [string]$group.canonical) { continue }
            $source = [IO.Path]::GetFullPath((Join-Path ([string]$poc.source_root) ($relative -replace '/', '\')))
            if (-not $source.StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
            $target = Join-Path $provenanceRoot ($relative -replace '/', '\')
            $targetDirectory = [IO.Path]::GetDirectoryName($target)
            if ($targetDirectory) { [IO.Directory]::CreateDirectory($targetDirectory) | Out-Null }
            $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
            if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash) {
                [IO.File]::Copy($source, $target, $true)
            }
            $entries.Add([ordered]@{ path = $relative; canonical = [string]$group.canonical; sha256 = $sourceHash; bytes = [long](Get-Item -LiteralPath $source).Length; provenance_copy = $target })
        }
    }
    Write-PocJson (Join-Path ([string]$poc.raw_root) 'provenance\duplicates.json') ([ordered]@{
        schema = 'ai-os/ingestion-provenance/v1'
        created_at = Get-PocNow
        note = 'Byte-identische Dubletten; nicht in den Store importiert, aber als Herkunft im RAW erhalten.'
        duplicates = @($entries.ToArray())
    })
    return @($entries.ToArray())
}

function Ensure-PocStore($config) {
    $poc = $config.poc
    $storeRoot = [string]$config.store_root
    if (-not (Test-Path -LiteralPath (Join-Path $storeRoot 'MANIFEST.json') -PathType Leaf)) {
        $null = Invoke-Wb @('init', '--root', $storeRoot)
    }
    $sources = @(Invoke-Wb @('source', 'list'))
    $existing = @($sources | Where-Object { [string]$_.id -eq [string]$poc.source_id })
    if (-not $existing.Count) {
        $sourceName = if ($poc.source_name) { [string]$poc.source_name } else { [string]$poc.name + ' RAW' }
        $sourceSpace = if ($poc.source_space) { [string]$poc.source_space } else { 'private' }
        $sourceConfidentiality = if ($poc.source_confidentiality) { [string]$poc.source_confidentiality } else { 'confidential' }
        $sourceOrganisation = if ($poc.source_organization) { [string]$poc.source_organization } else { 'local' }
        $arguments = @('source', 'add', '--id', [string]$poc.source_id, '--name', $sourceName,
            '--space', $sourceSpace, '--kind', 'folder', '--path', (Join-Path ([string]$poc.raw_root) 'files'),
            '--confidentiality', $sourceConfidentiality, '--organisation', $sourceOrganisation,
            '--authorization', [string]$poc.authorization)
        $null = Invoke-Wb $arguments
    }
}

function Invoke-PocImport($config) {
    $poc = $config.poc
    Ensure-PocStore $config
    $formats = @($poc.formats | ForEach-Object { [string]$_ })
    if (-not $formats.Count) { $formats = @('pdf') }
    $import = Invoke-Wb @('import', '--source', [string]$poc.source_id, '--formats', ($formats -join ','), '--no-index')
    $index = Invoke-Wb @('index', 'rebuild')
    return [ordered]@{ import = $import; index = $index }
}

function Get-PocEvidence($config) {
    $poc = $config.poc
    $results = [Collections.Generic.List[object]]::new()
    $seen = @{}
    $queries = if ($poc.queries -and @($poc.queries).Count) { @($poc.queries | ForEach-Object { [string]$_ }) } else { @([string]$poc.topic) }
    $allow = @{}
    foreach ($allowedPath in @($poc.evidence_allow)) {
        $allowedKey = ([string]$allowedPath).Replace('\', '/').TrimStart('/').ToLowerInvariant()
        if ($allowedKey) { $allow[$allowedKey] = $true }
    }
    $queryLimit = if ($poc.query_limit) { [int]$poc.query_limit } else { 8 }
    $evidenceLimit = if ($poc.evidence_limit) { [int]$poc.evidence_limit } else { 12 }
    $searchLimit = if ($poc.search_limit) { [int]$poc.search_limit } else { 20 }
    foreach ($query in $queries) {
        try { $found = Invoke-Wb @('search', $query, '--limit', [string]$searchLimit) } catch { $found = $null }
        foreach ($result in @($found.results)) {
            if (-not $result.version_id -or -not $result.display_path) { continue }
            if ([int]$result.page -le 0) { continue }
            $resultPath = ([string]$result.display_path).Replace('\', '/').TrimStart('/').ToLowerInvariant()
            if ($allow.Count -and -not $allow.ContainsKey($resultPath)) { continue }
            $key = [string]$result.version_id + '|' + [string]$result.page + '|' + [string]$result.citation.start
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $results.Add($result)
        }
        if ($results.Count -ge $queryLimit) { break }
    }
    $evidence = [Collections.Generic.List[object]]::new()
    $number = 0
    foreach ($result in @($results | Select-Object -First $evidenceLimit)) {
        $number++
        $snippet = [string]$result.snippet
        if ($snippet.Length -gt 1400) { $snippet = $snippet.Substring(0, 1400) }
        $evidence.Add([ordered]@{
            id = 'E' + $number
            versionId = [string]$result.version_id
            path = [string]$result.display_path
            page = [int]$result.page
            start = if ($result.citation) { [int]$result.citation.start } else { 0 }
            end = if ($result.citation) { [int]$result.citation.end } else { 0 }
            snippet = $snippet
            extractionStatus = [string]$result.extraction_status
        })
    }
    return @($evidence.ToArray())
}

function Get-PocFingerprint($config, $manifest, $ai) {
    $fileEntries = @($manifest.files | Sort-Object raw_path | ForEach-Object {
        [ordered]@{ raw_path = [string]$_.raw_path; sha256 = [string]$_.sha256 }
    })
    $data = [ordered]@{
        schema = 'ai-os/poc-synthesis-input/v1'
        topic = [string]$config.poc.topic
        page_title = [string]$config.poc.page_title
        provider = [string]($ai.provider)
        model = [string]($ai.model)
        prompt_version = 'poc-synthesis-v2'
        queries = @($config.poc.queries)
        evidence_limit = [int]($config.poc.evidence_limit)
        query_limit = [int]($config.poc.query_limit)
        search_limit = [int]($config.poc.search_limit)
        files = $fileEntries
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($data | ConvertTo-Json -Depth 8 -Compress))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Invoke-PocAiSynthesis($config, $evidence) {
    $ai = $script:aiConfiguration
    if (-not $ai -or -not $ai.configured) { throw 'Kein nutzbarer KI-Zugang konfiguriert.' }
    if (-not $ai.endpoint -or -not $ai.model) { throw 'KI-Endpunkt oder Modell fehlt.' }
    $context = for ($index = 0; $index -lt @($evidence).Count; $index++) {
        $item = $evidence[$index]
        ('[' + $item.id + '] Datei: ' + $item.path + ' | Fassung: ' + $item.versionId + ' | Seite: ' + $item.page + ' | Text: ' + $item.snippet)
    }
    $system = 'Du erstellst ausschliesslich aus den bereitgestellten Belegen eine Wissensseite auf Deutsch. Erfinde keine Tatsachen. Jede belegpflichtige Aussage muss mindestens eine gueltige Beleg-ID nennen. Fasse Zahlen nur zusammen, wenn die Belege dies ausdruecklich und mit gleichem Bezug tun; erfinde keine Gesamtsummen. Antworte ausschliesslich als JSON: {"summary":"...", "summary_evidence":["E1"], "statements":[{"text":"...", "evidence":["E1"]}], "open_questions":["..."]}.'
    $user = 'Thema: ' + [string]$config.poc.topic + "`n`nBELEGE:`n" + ($context -join "`n`n") + "`n`nNutze nur diese Belege. Wenn eine Aussage nicht belegt ist, formuliere sie nicht als belegte Aussage."
    $messages = @(@{ role = 'system'; content = $system }, @{ role = 'user'; content = $user })
    $content = $null
    if ([string]$ai.provider -eq 'ollama') {
        $uri = ([string]$ai.endpoint).TrimEnd('/') + '/api/chat'
        $body = @{ model = $ai.model; messages = $messages; stream = $false; format = 'json'; options = @{ temperature = 0; num_predict = 1800 } } | ConvertTo-Json -Depth 10
        $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $ai.timeoutSeconds
        $content = [string]$response.message.content
    } else {
        $key = if ($ai.apiKeyEnv) { [Environment]::GetEnvironmentVariable([string]$ai.apiKeyEnv) } else { $null }
        if (-not $key) { throw ('Kein API-Schluessel in der Umgebungsvariable ' + [string]$ai.apiKeyEnv + ' gesetzt.') }
        $uri = ([string]$ai.endpoint).TrimEnd('/') + '/chat/completions'
        $body = @{ model = $ai.model; messages = $messages; temperature = 0; max_tokens = 1800 } | ConvertTo-Json -Depth 10
        $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Headers @{ Authorization = 'Bearer ' + $key } -Body $body -TimeoutSec $ai.timeoutSeconds
        $content = [string]$response.choices[0].message.content
    }
    if (-not $content) { throw 'Die KI-Anbindung lieferte keine Antwort.' }
    $content = $content.Trim()
    if ($content -match '(?s)^```json\s*(.*?)\s*```$') { $content = $Matches[1] }
    try { return ($content | ConvertFrom-Json) } catch { throw 'Die KI-Anbindung lieferte kein gueltiges JSON.' }
}

function Build-PocPage($config, $parsed, $evidence) {
    $allowed = @{}
    foreach ($item in @($evidence)) { $allowed[[string]$item.id] = $item }
    $invalid = [Collections.Generic.List[string]]::new()
    $statements = [Collections.Generic.List[object]]::new()
    $firstEvidence = $null
    foreach ($statement in @($parsed.statements)) {
        $text = ([string]$statement.text).Trim()
        if (-not $text) { continue }
        $refs = [Collections.Generic.List[object]]::new()
        foreach ($idValue in @($statement.evidence)) {
            $id = [string]$idValue
            if (-not $allowed.ContainsKey($id)) { $invalid.Add('Unbekannter Beleg: ' + $id); continue }
            $item = $allowed[$id]
            if ([int]$item.page -le 0) { $invalid.Add('Beleg ohne Seitenbezug: ' + $id); continue }
            if (-not @($refs | Where-Object { [string]$_.id -eq $id }).Count) { $refs.Add($item) }
        }
        if (-not $refs.Count) { $invalid.Add('Aussage ohne gueltigen Beleg verworfen: ' + $text); continue }
        $citations = @($refs | ForEach-Object { '(' + (Get-PocSourceLabel $_.path) + ' S. ' + [string]$_.page + ')' } | Select-Object -Unique)
        if (-not $citations.Count) { $invalid.Add('Aussage ohne aufloesbare Fundstelle verworfen: ' + $text); continue }
        if (-not $firstEvidence) { $firstEvidence = $refs[0] }
        $statements.Add([ordered]@{ text = $text; citations = $citations })
    }
    if (-not $statements.Count) { throw 'Die KI lieferte keine gueltige belegte Aussage.' }
    $summary = ([string]$parsed.summary).Trim()
    if (-not $summary) { throw 'Die KI lieferte keine Zusammenfassung.' }
    $summaryRefs = [Collections.Generic.List[object]]::new()
    foreach ($idValue in @($parsed.summary_evidence)) {
        $id = [string]$idValue
        if ($allowed.ContainsKey($id) -and [int]$allowed[$id].page -gt 0) { $summaryRefs.Add($allowed[$id]) }
    }
    if (-not $summaryRefs.Count -and $firstEvidence) { $summaryRefs.Add($firstEvidence) }
    if (-not $summaryRefs.Count) { throw 'Die Zusammenfassung hat keinen gueltigen Belegbezug.' }
    $summaryCitations = @($summaryRefs | ForEach-Object { '(' + (Get-PocSourceLabel $_.path) + ' S. ' + [string]$_.page + ')' } | Select-Object -Unique)
    $open = @($parsed.open_questions | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# ' + [string]$config.poc.page_title)
    $lines.Add('')
    $lines.Add('## Zusammenfassung')
    $lines.Add('')
    $lines.Add($summary + ' ' + ($summaryCitations -join ' '))
    $lines.Add('')
    $lines.Add('## Belegte Aussagen')
    $lines.Add('')
    foreach ($statement in $statements) { $lines.Add('- ' + $statement.text + ' ' + ($statement.citations -join ' ')) }
    $lines.Add('')
    $lines.Add('## Offene Fragen')
    $lines.Add('')
    if ($open.Count) { foreach ($question in $open) { $lines.Add('- ' + $question) } } else { $lines.Add('- Keine offenen Fragen aus den ausgewaehlten Belegen.') }
    $lines.Add('')
    $lines.Add('## Grenzen')
    $lines.Add('')
    $lines.Add('- Automatisch aus ' + $evidence.Count + ' ausgewaehlten Belegabschnitten erzeugt; fachlich zu pruefen.')
    $body = ($lines -join "`n") + "`n"
    return [ordered]@{
        body = $body
        summary = $summary
        statements = @($statements.ToArray())
        openQuestions = @($open)
        invalidReferences = @($invalid.ToArray())
        summaryCitations = @($summaryCitations)
    }
}

function Save-PocKnowledge($config, $page, $evidence, $Existing) {
    $basis = @($evidence | ForEach-Object { [string]$_.versionId } | Select-Object -Unique)
    if (-not $basis.Count) { throw 'Keine Belegfassung fuer die Wissensseite vorhanden.' }
    $directory = [IO.Path]::GetDirectoryName((Get-PocSynthesisPath $config))
    if ($directory) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    $pageFile = Join-Path $directory ('poc-page-' + [guid]::NewGuid().ToString('N') + '.md')
    try {
        [IO.File]::WriteAllText($pageFile, [string]$page.body, [Text.UTF8Encoding]::new($false))
        if ($Existing) {
            $existingId = if ($Existing.knowledge_id) { [string]$Existing.knowledge_id } else { [string]$Existing.knowledge.id }
            $baseVersion = if ($Existing.knowledge_version_id) { [string]$Existing.knowledge_version_id } else { [string]$Existing.version.id }
            $arguments = @('knowledge', 'revise', $existingId, '--file', $pageFile,
                '--base-version', $baseVersion, '--basis') + $basis + @(
                '--reason', 'Synthese aus den aktuellen Belegen aktualisiert', '--author', 'poc-synthesis')
        } else {
            $arguments = @('knowledge', 'add', '--kind', 'summary', '--title', [string]$config.poc.page_title,
                '--file', $pageFile, '--basis') + $basis + @('--author', 'poc-synthesis')
        }
        return Invoke-Wb $arguments
    } finally {
        if (Test-Path -LiteralPath $pageFile) { Remove-Item -LiteralPath $pageFile -Force }
    }
}

function Get-PocExistingResult($config, [string]$Fingerprint) {
    $path = Get-PocSynthesisPath $config
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $result = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $result.knowledge_id -or -not $result.knowledge_version_id) { return $null }
        $detail = Invoke-Wb @('knowledge', 'show', [string]$result.knowledge_id)
        if ([string]$result.fingerprint -ne $Fingerprint) {
            return [ordered]@{ status = 'changed'; result = $result; detail = $detail }
        }
        return [ordered]@{ status = 'reuse'; result = $result; detail = $detail }
    } catch { return $null }
}

function Write-PocSynthesisResult($config, $Fingerprint, $Saved, $Page, $Evidence, $Ai, [bool]$Reused, $Existing, $Permissions) {
    $result = [ordered]@{
        schema = 'ai-os/poc-synthesis/v1'
        fingerprint = $Fingerprint
        knowledge_id = if ($Saved) { [string]$Saved.knowledge_id } else { [string]$Existing.knowledge_id }
        knowledge_version_id = if ($Saved) { [string]$Saved.knowledge_version_id } else { [string]$Existing.knowledge_version_id }
        created_at = if ($Existing -and $Existing.created_at) { [string]$Existing.created_at } else { Get-PocNow }
        reused = $Reused
        permissions = $Permissions
        source_access = 'read_only'
        topic = [string]$config.poc.topic
        provider = [string]$Ai.provider
        model = [string]$Ai.model
        evidence = @($Evidence | ForEach-Object { [ordered]@{ id = $_.id; versionId = $_.versionId; path = $_.path; page = $_.page; start = $_.start; end = $_.end } })
        invalid_references = if ($Page) { @($Page.invalidReferences) } else { @() }
        statements = if ($Page) { @($Page.statements) } else { @() }
        summary = if ($Page) { [string]$Page.summary } else { '' }
        open_questions = if ($Page) { @($Page.openQuestions) } else { @() }
    }
    Write-PocJson (Get-PocSynthesisPath $config) $result
}

function Invoke-PocRun {
    param([switch]$ConfirmExternalAi, [switch]$Resume)
    $config = Get-PocConfiguration
    $poc = $config.poc
    if ($Resume) {
        $previous = Read-PocState $config
        if (-not $previous) { throw 'Kein vorheriger Auftrag fuer die Wiederaufnahme vorhanden.' }
        $state = Repair-PocStateFields $previous
        if (-not $state.jobId) { $state.jobId = 'job-' + [guid]::NewGuid().ToString('N') }
        $state.state = 'running'
        $state.pid = $PID
        $state.updatedAt = Get-PocNow
        $state.finishedAt = $null
        $state.attempt = [int]$state.attempt + 1
        $state.resumeCount = [int]$state.resumeCount + 1
        $state.lastError = [string]$state.error
        $state.error = ''
        $steps = @($state.steps)
        foreach ($step in $steps) {
            if ([string]$step.status -in @('failed', 'blocked')) { $step.status = 'pending'; $step.detail = ''; $step.endedAt = $null }
        }
        $state.steps = $steps
        $state.currentStep = 'raw'
    } else {
        $state = New-PocState $config
    }
    Write-PocState $config $state
    $partial = $false
    if ($state.raw -and -not $state.raw.PSObject.Properties['provenance']) {
        $state.raw | Add-Member -NotePropertyName provenance -NotePropertyValue 0
    }
    try {
        Set-PocStep $config $state 'raw' 'running'
        $raw = Copy-PocRaw $config
        $provenance = Copy-PocProvenance $config
        $state.raw.files = @($raw.files).Count
        $state.raw.provenance = @($provenance).Count
        if (@($raw.errors).Count) {
            $partial = $true
            $state.warnings = @($state.warnings) + @($raw.errors | ForEach-Object { 'RAW: ' + $_.path + ': ' + $_.reason })
        }
        if (-not @($raw.files).Count) { throw 'Keine ausgewaehlten Dateien konnten in RAW aufgenommen werden.' }
        Set-PocStep $config $state 'raw' 'completed' ([string](@($raw.files).Count) + ' Dateien, hashgeprueft')

        Set-PocStep $config $state 'import' 'running'
        $run = Invoke-PocImport $config
        $report = $run.import.report
        $counts = Get-PocCounts
        $state.documents = [int]$counts.documents
        if ([int]$report.failed -gt 0 -or [int]$report.unsupported -gt 0 -or @($report.skipped).Count -gt 0) {
            $partial = $true
            $state.warnings = @($state.warnings) + @('Import: ' + [string]$report.failed + ' fehlgeschlagen, ' + [string]$report.unsupported + ' nicht unterstuetzt, ' + (@($report.skipped).Count) + ' uebersprungen')
        }
        Set-PocStep $config $state 'import' 'completed' ([string]$report.new_items + ' neu, ' + [string]$report.new_versions + ' Fassungen, ' + [string]$report.unchanged + ' unveraendert')
        Set-PocStep $config $state 'index' 'running'
        Set-PocStep $config $state 'index' 'completed' ('Index: ' + [string]$run.index.evidence_chunks + ' Belegabschnitte')
        Set-PocStep $config $state 'synthesis' 'running'

        $fingerprint = Get-PocFingerprint $config $raw.manifest $state.ai
        $state.fingerprint = $fingerprint
        $existing = Get-PocExistingResult $config $fingerprint
        if ($existing -and $existing.status -eq 'reuse') {
            $state.reused = $true
            $state.knowledgeId = [string]$existing.result.knowledge_id
            $state.versionId = [string]$existing.result.knowledge_version_id
            $state.permissions = Get-PocKnowledgePermissions $state.knowledgeId
            $state.pages = [int]$counts.pages
            $state.needsReview = [int]$counts.needsReview
            Set-PocStep $config $state 'synthesis' 'completed' 'Unveraenderte Eingaben: vorhandenes Ergebnis wiederverwendet'
            Set-PocStep $config $state 'ready' 'completed' 'Bereit'
            $state.state = if ($partial) { 'partial' } else { 'completed' }
            $state.finishedAt = Get-PocNow
            Write-PocState $config $state
            Write-Host ('PoC: ' + $state.state + ' (Synthese wiederverwendet)')
            return $(if ($partial) { 3 } else { 0 })
        }
        if ($existing -and $existing.status -eq 'changed') {
            $state.warnings = @($state.warnings) + @('Synthese-Konfiguration geaendert: neue Fassung wird erzeugt.')
        }

        $ai = $script:aiConfiguration
        if (-not $ai -or -not $ai.configured) { throw 'Synthese blockiert: kein nutzbarer KI-Zugang konfiguriert.' }
        $external = Test-PocExternal $ai
        if ($external -and -not $ConfirmExternalAi) { throw 'Synthese blockiert: externe KI-Nutzung wurde nicht bestaetigt.' }
        $evidence = Get-PocEvidence $config
        if (-not @($evidence).Count) { throw 'Keine Belegabschnitte fuer die Synthese gefunden.' }
        $parsed = Invoke-PocAiSynthesis $config $evidence
        $page = Build-PocPage $config $parsed $evidence
        if (@($page.invalidReferences).Count) {
            $partial = $true
            $state.warnings = @($state.warnings) + @('Synthese: ' + (@($page.invalidReferences).Count) + ' ungueltige/verworfene Belegbezuege')
        }
        $existingDetail = if ($existing -and $existing.status -eq 'changed') { $existing.detail } else { $null }
        $saved = Save-PocKnowledge $config $page $evidence $existingDetail
        $state.knowledgeId = [string]$saved.knowledge_id
        $state.versionId = [string]$saved.knowledge_version_id
        $permissions = Get-PocKnowledgePermissions $state.knowledgeId
        $state.permissions = $permissions
        Write-PocSynthesisResult $config $fingerprint $saved $page $evidence $ai $false $(if ($existing) { $existing.result } else { $null }) $permissions
        $counts = Get-PocCounts
        $state.documents = [int]$counts.documents
        $state.pages = [int]$counts.pages
        $state.needsReview = [int]$counts.needsReview
        $savedLabel = if ($existing) { 'Neue Fassung erzeugt: ' } else { 'Wissensseite erzeugt: ' }
        Set-PocStep $config $state 'synthesis' 'completed' ($savedLabel + $state.versionId)
        Set-PocStep $config $state 'ready' 'completed' 'Bereit'
        $state.state = if ($partial) { 'partial' } else { 'completed' }
        $state.finishedAt = Get-PocNow
        Write-PocState $config $state
        Write-Host ('PoC: ' + $state.state + '; Seite ' + $state.knowledgeId)
        return $(if ($partial) { 3 } else { 0 })
    } catch {
        $state.error = $_.Exception.Message
        $state.lastError = $state.error
        $current = [string]$state.currentStep
        $step = @($state.steps | Where-Object { [string]$_.name -eq $current })[0]
        if ($step) {
            $step.status = if ($state.error -match 'blockiert') { 'blocked' } else { 'failed' }
            $step.detail = $state.error
            $step.endedAt = Get-PocNow
            $state.steps = @($state.steps)
        }
        $state.state = if ($state.error -match 'blockiert') { 'blocked' } else { 'failed' }
        $state.finishedAt = Get-PocNow
        $state.updatedAt = $state.finishedAt
        Write-PocState $config $state
        Write-Host ('PoC: ' + $state.state + ': ' + $state.error)
        return $(if ($state.state -eq 'blocked') { 2 } else { 1 })
    }
}

function Select-PocBasePath {
    $config = Get-PocConfiguration
    $counts = Get-PocCounts
    if ([int]$counts.documents -gt 0 -or [int]$counts.pages -gt 0) {
        throw 'Der Basisordner kann nur vor dem ersten Lauf bzw. bei leerem Ziel geaendert werden.'
    }
    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = 'Basisordner fuer RAW, Store und Status auswaehlen'
    $picker.ShowNewFolderButton = $true
    try {
        if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { throw 'Ordnerauswahl abgebrochen.' }
        $base = [IO.Path]::GetFullPath($picker.SelectedPath)
    } finally { $picker.Dispose() }
    if ($base.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Der Basisordner muss ausserhalb des Repository liegen.' }
    if ($base.TrimEnd('\') -eq [IO.Path]::GetFullPath([string]$config.poc.source_root).TrimEnd('\')) { throw 'Quellordner und Zielordner muessen getrennt sein.' }
    if (Test-Path -LiteralPath $base) {
        $entries = @(Get-ChildItem -LiteralPath $base -Force -ErrorAction Stop)
        if ($entries.Count) { throw 'Der gewaehlte Basisordner ist nicht leer.' }
    } else {
        [IO.Directory]::CreateDirectory($base) | Out-Null
    }
    $raw = Join-Path $base 'RAW'
    $store = Join-Path $base 'store'
    $state = Join-Path $base 'state'
    [IO.Directory]::CreateDirectory($raw) | Out-Null
    [IO.Directory]::CreateDirectory($store) | Out-Null
    [IO.Directory]::CreateDirectory($state) | Out-Null
    $config.poc | Add-Member -NotePropertyName base_root -NotePropertyValue $base -Force
    $config.poc.raw_root = $raw
    $config.poc.state_file = Join-Path $state 'poc-run.json'
    $config.poc.synthesis_file = Join-Path $state 'synthesis.json'
    $config.poc.log_file = Join-Path $state 'poc-run.log'
    $config.store_root = $store
    if (@($config.bindings).Count) { $config.bindings[0].locator = Join-Path $raw 'files' }
    [IO.File]::WriteAllText($WissensbasisConfig, ($config | ConvertTo-Json -Depth 15), [Text.UTF8Encoding]::new($false))
    Ensure-PocStore $config
    $script:knowledgeSnapshot = $null
    $null = Get-KnowledgeSession -Refresh
    return Get-PocPublicState
}

function Get-PocPublicState {
    $config = Get-PocConfiguration
    $state = Read-PocState $config
    if (-not $state) {
        $state = [ordered]@{
            schema = 'ai-os/poc-run/v1'; state = 'idle'; currentStep = ''; steps = @();
            startedAt = $null; updatedAt = $null; lastRunAt = $null; finishedAt = $null;
            documents = 0; pages = 0; needsReview = 0; error = ''; warnings = @(); reused = $false
        }
    }
    $state = Repair-PocStateFields $state
    if ([string]$state.state -eq 'running' -and $state.pid) {
        $alive = $false
        try { $alive = [bool](Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue) } catch { }
        if (-not $alive) {
            $state.state = 'failed'
            $state.error = 'Lauf ist nicht mehr aktiv; letzter Stand wurde beibehalten.'
            $state.updatedAt = Get-PocNow
            Write-PocState $config $state
        }
    }
    if ($state.finishedAt -and [string]$state.finishedAt -ne [string]$script:pocLastFinished) {
        $script:pocLastFinished = [string]$state.finishedAt
        try { $null = Get-KnowledgeSession -Refresh } catch { }
    }
    $counts = Get-PocCounts
    if (-not $state.permissions -and $state.knowledgeId) {
        try { $state.permissions = Get-PocKnowledgePermissions ([string]$state.knowledgeId); Write-PocState $config $state } catch { }
    }
    $sourceReachable = 'unbekannt'
    try {
        $sources = @(Invoke-Wb @('source', 'list'))
        $source = @($sources | Where-Object { [string]$_.id -eq [string]$config.poc.source_id })[0]
        if ($source) { $sourceReachable = [string]$source.binding.state }
    } catch { }
    $canResume = [string]$state.state -in @('failed', 'blocked', 'partial')
    return [ordered]@{
        poc = [ordered]@{
            name = [string]$config.poc.name
            topic = [string]$config.poc.topic
            sourceRoot = [string]$config.poc.source_root
            rawRoot = [string]$config.poc.raw_root
            storeRoot = [string]$config.store_root
            baseRoot = [string]$config.poc.base_root
            pageTitle = [string]$config.poc.page_title
            files = @($config.poc.files)
            authorization = [string]$config.poc.authorization
            sourceAccess = 'read_only'
        }
        ai = [ordered]@{
            configured = [bool]($script:aiConfiguration -and $script:aiConfiguration.configured)
            provider = [string]$script:aiConfiguration.provider
            model = [string]$script:aiConfiguration.model
            external = (Test-PocExternal $script:aiConfiguration)
        }
        sourceReachable = $sourceReachable
        counts = $counts
        canResume = $canResume
        permissions = $state.permissions
        state = $state
    }
}

function Start-PocBackgroundRun([bool]$ConfirmExternalAi, [switch]$Resume) {
    $config = Get-PocConfiguration
    $current = Read-PocState $config
    if ($Resume -and -not $current) { throw 'Kein vorheriger Auftrag fuer die Wiederaufnahme vorhanden.' }
    if ($current -and [string]$current.state -in @('running', 'starting') -and $current.pid) {
        $alive = $false
        try { $alive = [bool](Get-Process -Id ([int]$current.pid) -ErrorAction SilentlyContinue) } catch { }
        if ($alive) { throw 'Fuer diesen Testwissensraum laeuft bereits eine Aufbereitung.' }
    }
    $ai = $script:aiConfiguration
    if (-not $ai -or -not $ai.configured) { throw 'Synthese blockiert: kein nutzbarer KI-Zugang konfiguriert.' }
    if ((Test-PocExternal $ai) -and -not $ConfirmExternalAi) { throw 'Externe KI-Nutzung muss vor dem Start bestaetigt werden.' }
    $initial = if ($Resume) { Repair-PocStateFields $current } else { New-PocState $config }
    if (-not $initial.jobId) { $initial.jobId = 'job-' + [guid]::NewGuid().ToString('N') }
    $initial.state = 'starting'
    $initial.lastRunAt = Get-PocNow
    $initial.updatedAt = $initial.lastRunAt
    $initial.finishedAt = $null
    $initial.resume = [bool]$Resume
    $initial.lastError = if ($Resume) { [string]$initial.error } else { [string]$initial.lastError }
    $initial.error = ''
    Write-PocState $config $initial
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:ConnectorScriptPath,
        '-Origin', $Origin, '-WissensbasisConfig', $WissensbasisConfig, '-RunPoc')
    if ($script:AiConfigPath) { $arguments += @('-AiConfig', $script:AiConfigPath) }
    if ($ConfirmExternalAi) { $arguments += '-ConfirmExternalAi' }
    if ($Resume) { $arguments += '-ResumePoc' }
    $log = [string]$config.poc.log_file
    $logDir = [IO.Path]::GetDirectoryName($log)
    if ($logDir) { [IO.Directory]::CreateDirectory($logDir) | Out-Null }
    $process = Start-Process -FilePath (Get-Command pwsh -ErrorAction Stop).Source -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError ($log + '.err') -PassThru
    $initial.pid = $process.Id
    $initial.updatedAt = Get-PocNow
    Write-PocState $config $initial
    return Get-PocPublicState
}
