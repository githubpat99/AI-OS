param(
    [Parameter(Mandatory = $true)][string]$Origin,
    [string]$Root,
    [string]$ConfigurationPath,
    [string]$WissensbasisConfig,
    [string]$AiConfig,
    [string]$WorkspaceRegistry,
    [int]$Port = 43127,
    [switch]$RunPoc,
    [switch]$ResumePoc,
    [switch]$ConfirmExternalAi
)

$ErrorActionPreference = 'Stop'
$originUri = [Uri]$Origin
if ($originUri.Scheme -notin @('http', 'https') -or $originUri.AbsolutePath -ne '/' -or $originUri.Query -or $originUri.Fragment -or $originUri.UserInfo) { throw 'Origin muss ein HTTP(S)-Ursprung ohne Pfad sein.' }
if ($originUri.Scheme -ne 'https' -and $originUri.Host -notin @('127.0.0.1', 'localhost')) { throw 'Oeffentliche Urspruenge erfordern HTTPS.' }
$Origin = $originUri.GetLeftPart([UriPartial]::Authority)
$script:ConnectorScriptPath = $PSCommandPath
$localOrigin = "http://127.0.0.1:$Port"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("$localOrigin/")
$token = ''
$expires = [DateTime]::MinValue
$nonce = [Guid]::NewGuid().ToString('N')
$snapshot = $null
$documents = @{}
$workspaceRoot = (Split-Path $PSScriptRoot -Parent).TrimEnd('\') + '\'
$knowledgeMode = [bool]$WissensbasisConfig
$knowledgeSnapshot = $null
$knowledgeRevision = ''
if ($knowledgeMode) {
    $WissensbasisConfig = [IO.Path]::GetFullPath($WissensbasisConfig)
    if (-not (Test-Path -LiteralPath $WissensbasisConfig -PathType Leaf)) { throw 'Wissensbasis-Konfiguration nicht gefunden.' }
    if ($WissensbasisConfig.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Wissensbasis-Konfiguration muss ausserhalb des Repository liegen.' }
    if ($Root -or $ConfigurationPath) { throw 'Wissensbasis-Modus nicht mit -Root oder -ConfigurationPath kombinieren.' }
}
$script:AiConfigPath = if ($AiConfig) { [IO.Path]::GetFullPath($AiConfig) } else { '' }
if ($script:AiConfigPath) {
    if (-not (Test-Path -LiteralPath $script:AiConfigPath -PathType Leaf)) { throw 'KI-Konfiguration nicht gefunden.' }
    if ($script:AiConfigPath.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'KI-Konfiguration muss ausserhalb des Repository liegen.' }
}
$script:WorkspaceRegistryPath = if ($WorkspaceRegistry) { [IO.Path]::GetFullPath($WorkspaceRegistry) } else { '' }
if ($script:WorkspaceRegistryPath) {
    if (-not (Test-Path -LiteralPath $script:WorkspaceRegistryPath -PathType Leaf)) { throw 'Wissensraum-Registry nicht gefunden.' }
    if ($script:WorkspaceRegistryPath.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Wissensraum-Registry muss ausserhalb des Repository liegen.' }
}
$script:aiConfiguration = $null
$fixedRoot = [bool]($Root -or $ConfigurationPath -or $WissensbasisConfig)
$sourceConfiguration = $null
$sourceEditing = -not [bool]($Root -or $WissensbasisConfig)
if ($ConfigurationPath) {
    $ConfigurationPath = [IO.Path]::GetFullPath($ConfigurationPath)
    if ($ConfigurationPath.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Lokale Rechnerkonfiguration muss ausserhalb des Repository liegen.' }
}
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('ai-os-connector-' + [Guid]::NewGuid().ToString('N'))
$worker = $null
$workProgress = @{ state = 'idle'; phase = 0; processed = 0; total = -1 }
$directorySyncedAt = $null
$directoryWatcher = $null
$watchEventIds = @()
$observedChanges = @{}
$pendingReconciliation = $false
. (Join-Path $PSScriptRoot 'document-state.ps1')
. (Join-Path $PSScriptRoot 'source-state.ps1')
. (Join-Path $PSScriptRoot 'poc.ps1')
. (Join-Path $PSScriptRoot 'pipeline.ps1')
. (Join-Path $PSScriptRoot 'gap.ps1')
$sourceConfigurationPath = if ($ConfigurationPath) { $ConfigurationPath } else { Get-SourceConfigurationPath }

function Send-Response($context, [int]$status, [string]$body, [string]$type = 'application/json; charset=utf-8') {
    $response = $context.Response
    $response.StatusCode = $status
    $response.ContentType = $type
    $response.Headers['Cache-Control'] = 'no-store'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'
    $response.Headers['Vary'] = 'Origin'
    $response.Headers['Content-Security-Policy'] = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
    if ($context.Request.Headers['Origin'] -eq $Origin) {
        $response.Headers['Access-Control-Allow-Origin'] = $Origin
        $response.Headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
        $response.Headers['Access-Control-Allow-Headers'] = 'Authorization, Content-Type'
        $response.Headers['Access-Control-Allow-Private-Network'] = 'true'
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $response.ContentLength64 = $bytes.Length
    try { $response.OutputStream.Write($bytes, 0, $bytes.Length) } finally { $response.Close() }
}

function Read-JsonRequest($context, [int]$maximum = 8192) {
    if ($context.Request.ContentLength64 -gt $maximum) { throw 'Anfrage ist zu gross' }
    $reader = [IO.StreamReader]::new($context.Request.InputStream, [Text.Encoding]::UTF8)
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ($text.Length -gt $maximum) { throw 'Anfrage ist zu gross' }
    if (-not $text.Trim()) { throw 'Anfrage enthaelt kein JSON' }
    try { $text | ConvertFrom-Json } catch { throw 'Anfrage ist kein gueltiges JSON' }
}

function Get-MergedSourceConfiguration {
    $saved = Get-SavedSourceConfiguration
    $previous = @{}
    if ($script:sourceConfiguration) { foreach ($source in @($script:sourceConfiguration.sources)) { $previous[[string]$source.id] = $source } }
    foreach ($source in @($saved.sources)) {
        $before = $previous[[string]$source.id]
        if (-not $before) { continue }
        if (-not (Test-SameDirectory $before.path $source.path)) { continue }
        foreach ($key in @('lastSuccess', 'pending', 'pendingBasis', 'failed', 'documents', 'updateState', 'error')) {
            $value = $before.$key
            if ($null -ne $value) { $source | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force }
        }
    }
    $saved
}

function Start-IndexWorker([switch]$Refresh) {
    if ($script:worker) { Remove-Job -Job $script:worker -Force; $script:worker = $null }
    $script:workKind = if ($Refresh) { 'refresh' } else { 'pair' }
    if (-not $Refresh) { Stop-ReaderWatcher; $script:token = ''; $script:snapshot = $null; $script:documents = @{}; $script:observedChanges = @{}; $script:pendingReconciliation = $false }
    [System.IO.Directory]::CreateDirectory($temporary) | Out-Null
    foreach ($name in @('progress.json', 'snapshot.json', 'inventory.json', 'documents.json')) {
        $file = Join-Path $temporary $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    $previousPath = Join-Path $temporary 'previous.json'
    $previousInventoryPath = Join-Path $temporary 'previous-inventory.json'
    if ($Refresh -and $script:snapshot) {
        $previousInventory = ($script:snapshot | ConvertFrom-Json).inventory
        [IO.File]::WriteAllText($previousInventoryPath, ($previousInventory | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
    } elseif (Test-Path -LiteralPath $previousInventoryPath) { Remove-Item -LiteralPath $previousInventoryPath -Force }
    if ($Refresh -and $script:documents.Count) {
        [IO.File]::WriteAllText($previousPath, (@($script:documents.Values) | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
    } elseif (Test-Path -LiteralPath $previousPath) { Remove-Item -LiteralPath $previousPath -Force }
    $started = [DateTime]::UtcNow.ToString('o')
    $startLabel = if ($script:Root) { $script:Root } else { 'Lokales Quellenregister' }
    $script:workProgress = @{ state = 'running'; phase = 0; processed = 0; total = -1; started = $started; updated = $started; directory = $startLabel }
    $script:worker = Start-Job -ArgumentList (Join-Path $PSScriptRoot 'build.ps1'), $script:Root, $temporary, $started, $ConfigurationPath -ScriptBlock {
        param($buildPath, $rootPath, $outputDirectory, $started, $configurationPath)
        $ErrorActionPreference = 'Stop'
        $events = [System.Collections.Generic.List[object]]::new()
        $state = @{ phase = -1; latest = $null }
        function Save-Progress($progress) {
            foreach ($key in @('topicsFound', 'topicCandidates', 'textAssignments', 'referenceAssignments', 'documentsWithTopics', 'topicLabels', 'rulesChecked', 'linksChecked', 'detail', 'topicBuild')) {
                if (-not $progress.Contains($key) -and $state.latest -and $state.latest.Contains($key)) { $progress[$key] = $state.latest[$key] }
            }
            $state.latest = $progress
            if ($progress.phase -ne $state.phase -or $progress.state -in @('completed', 'failed')) {
                $events.Add(@{ phase = $progress.phase; state = $progress.state; at = [DateTime]::UtcNow.ToString('o') })
                $state.phase = $progress.phase
            }
            $progress.started = $started
            $progress.events = @($events.ToArray())
            $pending = Join-Path $outputDirectory 'progress.pending'
            $destination = Join-Path $outputDirectory 'progress.json'
            [IO.File]::WriteAllText($pending, ($progress | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
            if ([IO.File]::Exists($destination)) { [IO.File]::Replace($pending, $destination, [System.Management.Automation.Language.NullString]::Value) }
            else { [IO.File]::Move($pending, $destination) }
        }
        try {
            Save-Progress @{ state = 'running'; phase = 0; processed = 0; total = -1; updated = [DateTime]::UtcNow.ToString('o'); directory = $(if ($rootPath) { $rootPath } else { 'Lokales Quellenregister' }) }
            . (Join-Path (Split-Path $buildPath -Parent) 'document-state.ps1')
            . (Join-Path (Split-Path $buildPath -Parent) 'source-state.ps1')
            $script:sourceConfigurationPath = if ($configurationPath) { $configurationPath } else { Get-SourceConfigurationPath }
            $rootMode = [bool]$rootPath
            if ($rootMode) {
                $selectedRoot = (Resolve-Path -LiteralPath $rootPath).Path
                $configuration = Read-SourceConfiguration $configurationPath $selectedRoot
                $directoryLabel = $selectedRoot
                $nextRoot = $selectedRoot
            } else {
                $configuration = Read-SourceConfiguration $configurationPath ''
                if (@($configuration.sources).Count -eq 0) {
                    Add-Type -AssemblyName System.Windows.Forms
                    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
                    $owner = New-Object System.Windows.Forms.Form
                    $owner.TopMost = $true
                    $owner.ShowInTaskbar = $false
                    $picker.Description = 'Erste AI-OS-Quelle auswaehlen'
                    try {
                        $owner.Show()
                        if ($picker.ShowDialog($owner) -ne 'OK') { throw 'Auswahl abgebrochen' }
                        $selectedRoot = $picker.SelectedPath
                    } finally { $picker.Dispose(); $owner.Dispose() }
                    $configuration = Read-SourceConfiguration $configurationPath $selectedRoot
                    $directoryLabel = $selectedRoot
                } else {
                    $sourceCount = @($configuration.sources).Count
                    $directoryLabel = 'Lokales Quellenregister (' + $sourceCount + $(if ($sourceCount -eq 1) { ' Quelle)' } else { ' Quellen)' })
                }
                $nextRoot = ''
            }
            Save-Progress @{ state = 'running'; phase = 0; processed = 0; total = -1; updated = [DateTime]::UtcNow.ToString('o'); directory = $directoryLabel }
            $inventory = Invoke-SourceIndex $configuration $buildPath $outputDirectory {
                param($progress)
                $progress.state = 'running'
                $progress.directory = $directoryLabel
                Save-Progress $progress
            }
            $result = @{ directory = $directoryLabel; root = $nextRoot; updated = $inventory.generated; inventory = $inventory } | ConvertTo-Json -Depth 20 -Compress
            [IO.File]::WriteAllText((Join-Path $outputDirectory 'snapshot.json'), $result, [Text.UTF8Encoding]::new($false))
            Remove-Item -LiteralPath (Join-Path $outputDirectory 'inventory.json') -Force
            Save-Progress @{
                state = 'completed'; phase = 5; processed = 1; total = 1; updated = [DateTime]::UtcNow.ToString('o'); directory = $directoryLabel
                evaluated = @($inventory.files | Where-Object { $_.status -eq 'evaluated' }).Count
                partial = @($inventory.files | Where-Object { $_.status -eq 'partial' }).Count
                skipped = @($inventory.files | Where-Object { $_.status -eq 'skipped' }).Count
                failedDocuments = @($inventory.files | Where-Object { $_.processingState -eq 'error' }).Count
                sources = @($inventory.sources).Count
            }
        } catch {
            Save-Progress @{ state = 'failed'; phase = [Math]::Max(0, $state.phase); processed = 0; total = -1; updated = [DateTime]::UtcNow.ToString('o'); errorId = $_.FullyQualifiedErrorId; error = 'Quellenauswahl abgebrochen oder Indexaufbau fehlgeschlagen. Pfade, Leserechte und lokale Dateien pruefen.' }
        }
    }
}

function Get-IndexProgress {
    $progressPath = Join-Path $temporary 'progress.json'
    if ($script:worker -and (Test-Path -LiteralPath $progressPath)) {
        try {
            $stream = [IO.FileStream]::new($progressPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader = [IO.StreamReader]::new($stream)
            try { $script:workProgress = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        } catch { }
    }
    if ($script:worker -and $script:worker.State -in @('Completed', 'Failed', 'Stopped')) {
        try {
            Receive-Job -Job $script:worker -ErrorAction Stop | Out-Null
            $script:workProgress = Get-Content -LiteralPath $progressPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($script:workProgress.state -ne 'completed') { throw 'Indexaufbau fehlgeschlagen' }
            $nextSnapshot = [IO.File]::ReadAllText((Join-Path $temporary 'snapshot.json'))
            $nextDocuments = @{}
            foreach ($document in (Get-Content -LiteralPath (Join-Path $temporary 'documents.json') -Raw -Encoding UTF8 | ConvertFrom-Json)) { $nextDocuments[$document.path] = $document }
            foreach ($previous in $script:documents.Values) {
                if (-not $nextDocuments.ContainsKey($previous.path) -and $previous.evaluatedAt) {
                    $missing = $previous.PSObject.Copy()
                    $missing.processingState = 'error'; $missing.error = 'Quelldatei nicht mehr vorhanden; letzter erfolgreicher Stand'
                    $missing | Add-Member -NotePropertyName missing -NotePropertyValue $true -Force
                    $nextDocuments[$previous.path] = $missing
                }
            }
            $nextState = $nextSnapshot | ConvertFrom-Json
            $nextState | Add-Member -NotePropertyName revision -NotePropertyValue ([guid]::NewGuid().ToString('N')) -Force
            $nextState.updated = [DateTime]::UtcNow.ToString('o')
            $nextState | Add-Member -NotePropertyName directorySyncedAt -NotePropertyValue $nextState.inventory.directorySyncedAt -Force
            if ($nextState.root) { $script:Root = [string]$nextState.root }
            $script:sourceConfiguration = [pscustomobject]@{ sources = @($nextState.inventory.sources) }
            $script:directorySyncedAt = $nextState.directorySyncedAt
            $script:snapshot = $nextState | ConvertTo-Json -Depth 20 -Compress
            $script:documents = $nextDocuments
            $script:observedChanges = @{}
            $script:pendingReconciliation = $false
            Remove-Item -LiteralPath (Join-Path $temporary 'snapshot.json') -Force
            Remove-Item -LiteralPath (Join-Path $temporary 'documents.json') -Force
            Start-ReaderWatcher
            if ($script:workKind -eq 'pair') {
                $random = [byte[]]::new(32)
                $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
                try { $rng.GetBytes($random) } finally { $rng.Dispose() }
                $script:token = [Convert]::ToBase64String($random)
                $script:expires = [DateTime]::UtcNow.AddHours(8)
            }
        } catch {
            if ($script:workProgress.state -ne 'failed') {
                $script:workProgress = @{ state = 'failed'; phase = $script:workProgress.phase; errorId = $_.FullyQualifiedErrorId; error = 'Indexaufbau fehlgeschlagen oder abgebrochen. Verzeichnis und Leserechte pruefen.'; updated = [DateTime]::UtcNow.ToString('o') }
            }
        } finally { Remove-Job -Job $script:worker -Force; $script:worker = $null }
    }
    $result = @{}
    if ($script:workProgress -is [hashtable]) { foreach ($key in $script:workProgress.Keys) { $result[$key] = $script:workProgress[$key] } }
    else { foreach ($property in $script:workProgress.PSObject.Properties) { $result[$property.Name] = $property.Value } }
    if ($result.state -eq 'completed' -and $script:worker) {
        $result.state = 'running'; $result.processed = 0; $result.total = -1
    }
    if ($result.state -eq 'completed' -and $script:token) { $result.token = $script:token }
    $result | ConvertTo-Json -Depth 6 -Compress
}

function Get-DocumentHeadings([string]$text) {
    $number = 0
    @([regex]::Matches($text, '(?m)^(#{1,6})\s+(.+)$') | ForEach-Object {
        $number++
        @{ id = 'section-' + $number; title = $_.Groups[2].Value.Trim(); level = $_.Groups[1].Length; offset = $_.Index }
    })
}

function Get-ApprovedOriginal([string]$path, [switch]$AllowChanged) {
    if (-not $documents.ContainsKey($path)) { throw 'Datei nicht im freigegebenen Index' }
    $document = $documents[$path]
    if ($document.name -match '^\.env($|\.)|credentials|secrets|\.pem$|\.key$') { throw 'Geschuetzte Datei' }
    $source = $sourceConfiguration.sources | Where-Object id -eq $document.sourceId | Select-Object -First 1
    if (-not $source -or -not $source.read) { throw 'Quelle nicht zum Lesen freigegeben' }
    $sourceRoot = $source.path
    $absolute = [IO.Path]::GetFullPath((Join-Path $sourceRoot $document.relativePath))
    if (-not $absolute.StartsWith($sourceRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Pfad ausserhalb der Freigabe' }
    $entry = Get-Item -LiteralPath $absolute -Force
    if ($entry.PSIsContainer) { throw 'Keine Datei' }
    $ancestor = $entry
    while ($ancestor -and $ancestor.FullName -ne $sourceRoot.TrimEnd('\')) {
        $ancestor = Get-Item -LiteralPath $ancestor.FullName -Force
        if ($ancestor.LinkType -in @('SymbolicLink', 'Junction')) { throw 'Symbolischer Verweis' }
        $ancestor = if ($ancestor -is [IO.FileInfo]) { $ancestor.Directory } else { $ancestor.Parent }
    }
    if (-not $AllowChanged) {
        if ($entry.Length -ne $document.bytes -or $entry.LastWriteTimeUtc.ToString('o') -ne $document.modified) { throw 'Original seit Indexaufbau veraendert. Bitte aktualisieren.' }
        if ($document.hash -and (Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash -ine $document.hash) { throw 'Original seit Indexaufbau veraendert. Bitte aktualisieren.' }
    }
    $absolute
}

function Invoke-Wb {
    param([string[]]$WbArguments)
    $toolPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'shared\tools\wissensbasis'
    if (-not (Test-Path -LiteralPath $toolPath)) { throw 'wb-Zugriffsschicht nicht gefunden.' }
    $python = (Get-Command python -ErrorAction Stop).Source
    $oldConfig = $env:WB_CONFIG
    $oldPythonPath = $env:PYTHONPATH
    $env:WB_CONFIG = $script:WissensbasisConfig
    $env:PYTHONPATH = $toolPath
    try {
        Push-Location $toolPath
        $output = & $python -m wb @WbArguments --json 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
        $env:WB_CONFIG = $oldConfig
        $env:PYTHONPATH = $oldPythonPath
    }
    $text = (@($output) | ForEach-Object { $_.ToString() }) -join "`n"
    $jsonLine = @($text -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
    $payload = $null
    if ($jsonLine.Count) {
        try { $payload = $jsonLine[0] | ConvertFrom-Json } catch { $payload = $null }
    }
    if ($exitCode -ne 0 -or -not $payload -or -not $payload.ok) {
        $message = if ($payload -and $payload.error -and $payload.error.message) { [string]$payload.error.message } else { 'wb-Aufruf fehlgeschlagen.' }
        throw $message
    }
    $payload.data
}

function Get-WorkspaceCardSummary([string]$ConfigPath, $Entry) {
    $summary = [ordered]@{
        available = $false
        kind = [string]$Entry.kind
        label = ''
        topic = ''
        sourceRoot = ''
        storeRoot = ''
        documents = 0
        pages = 0
        needsReview = 0
        partial = 0
        found = 0
        selected = 0
        imported = 0
        full = 0
        none = 0
        ocrPending = 0
        usedInSynthesis = 0
        coverageAvailable = $false
        lastRun = ''
        status = 'unreachable'
        hasPoc = $false
        pocState = $null
    }
    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $summary.hasPoc = [bool]$config.poc
        $summary.storeRoot = [string]$config.store_root
        if ($config.poc) {
            $summary.topic = [string]$config.poc.topic
            $summary.label = [string]$config.poc.workspace_label
            $summary.sourceRoot = [string]$config.poc.source_root
            $statePath = [string]$config.poc.state_file
            if ($statePath -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
                try {
                    $pocState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $summary.pocState = $pocState
                    $summary.status = [string]$pocState.state
                    $summary.lastRun = if ($pocState.lastRunAt) { [string]$pocState.lastRunAt } elseif ($pocState.finishedAt) { [string]$pocState.finishedAt } else { '' }
                } catch { }
            }
        } else {
            $binding = @($config.bindings | Select-Object -First 1)
            if ($binding.Count) { $summary.sourceRoot = [string]$binding[0].locator }
        }
        $previous = $script:WissensbasisConfig
        try {
            $script:WissensbasisConfig = $ConfigPath
            $status = Invoke-Wb @('status')
            $items = @(Invoke-Wb @('item', 'list', '--limit', '500'))
            $notes = @(Invoke-Wb @('note', 'list'))
            $summary.available = $true
            $summary.documents = [int]$status.summary.items
            $summary.pages = $notes.Count
            $summary.needsReview = @($notes | Where-Object { [string]$_.review_state -in @('needs_review', 'confirmation_stale') }).Count
            $summary.partial = @($items | Where-Object { [string]$_.extraction_status -eq 'partial' }).Count
            $summary.imported = $items.Count
            $summary.full = @($items | Where-Object { [string]$_.extraction_status -eq 'full' }).Count
            $summary.none = @($items | Where-Object { [string]$_.extraction_status -in @('none', 'unsupported') }).Count
            $summary.ocrPending = @($items | Where-Object { [string]$_.extraction_reason -match 'OCR ausstehend' }).Count
            $inventoryPath = [string]$config.poc.inventory_file
            if ($inventoryPath -and (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) {
                try { $inventory = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json; $summary.found = [int]$inventory.summary.files_found; $summary.selected = [int]$inventory.summary.selected_default; $summary.coverageAvailable = $true } catch { }
            }
            $selectionPath = [string]$config.poc.selection_file
            if ($selectionPath -and (Test-Path -LiteralPath $selectionPath -PathType Leaf)) {
                try { $selection = Get-Content -LiteralPath $selectionPath -Raw -Encoding UTF8 | ConvertFrom-Json; $summary.selected = @($selection.selected_primary).Count + @($selection.selected_context).Count; $summary.coverageAvailable = $true } catch { }
            }
            if ($summary.coverageAvailable) {
                $usedPaths = @{}
                foreach ($note in $notes) {
                    try {
                        $pageDetail = Invoke-Wb @('knowledge', 'show', [string]$note.knowledge_id)
                        foreach ($prov in @($pageDetail.provenance)) { if ($prov.display_path) { $usedPaths[[string]$prov.display_path] = $true } }
                    } catch { }
                }
                $summary.usedInSynthesis = $usedPaths.Count
            }
            if (-not $summary.lastRun) {
                $summary.lastRun = if ($status.index -and $status.index.built_at) { [string]$status.index.built_at } elseif ($status.summary -and $status.summary.last_event) { [string]$status.summary.last_event } else { '' }
            }
            if (-not $summary.pocState) { $summary.status = 'connected' }
        } finally {
            $script:WissensbasisConfig = $previous
        }
    } catch {
        $summary.available = $false
        $summary.status = 'unreachable'
    }
    return $summary
}

function Get-WorkspaceCatalog {
    param([switch]$SkipSummaries)
    $current = [IO.Path]::GetFullPath($WissensbasisConfig)
    if (-not $script:WorkspaceRegistryPath) {
        $name = [IO.Path]::GetFileNameWithoutExtension($current)
        try {
            $cfg = Get-Content -LiteralPath $current -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.poc -and $cfg.poc.name) { $name = [string]$cfg.poc.name }
        } catch { }
        $entry = [ordered]@{ id = 'current'; name = $name; config = $current; kind = 'single'; active = $true }
        if (-not $SkipSummaries) { $entry.summary = Get-WorkspaceCardSummary $current $entry }
        return @($entry)
    }
    $registry = Get-Content -LiteralPath $script:WorkspaceRegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $result = [Collections.Generic.List[object]]::new()
    $activeId = [string]$registry.active
    foreach ($item in @($registry.workspaces)) {
        $configPath = [string]$item.config
        if (-not [IO.Path]::IsPathRooted($configPath)) {
            $configPath = Join-Path ([IO.Path]::GetDirectoryName($script:WorkspaceRegistryPath)) $configPath
        }
        $configPath = [IO.Path]::GetFullPath($configPath)
        if ($configPath.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $active = $configPath -eq $current
        if ($active) { $activeId = [string]$item.id }
        $entry = [ordered]@{
            id = [string]$item.id
            name = [string]$item.name
            config = $configPath
            kind = [string]$item.kind
            active = $active
        }
        if (-not $SkipSummaries) { $entry.summary = Get-WorkspaceCardSummary $configPath $entry }
        $result.Add($entry)
    }
    return @($result.ToArray())
}

function Switch-Workspace([string]$WorkspaceId) {
    if (-not $WorkspaceId) { throw 'Wissensraum-ID fehlt.' }
    $catalog = @(Get-WorkspaceCatalog -SkipSummaries)
    $entry = @($catalog | Where-Object { [string]$_.id -eq $WorkspaceId })[0]
    if (-not $entry) { throw 'Wissensraum nicht in der Registry gefunden.' }
    $target = [IO.Path]::GetFullPath([string]$entry.config)
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'Konfiguration des Wissensraums fehlt.' }
    if ($target.StartsWith($workspaceRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Wissensraum-Konfiguration muss ausserhalb des Repository liegen.' }
    $script:WissensbasisConfig = $target
    $WissensbasisConfig = $target
    $script:knowledgeSnapshot = $null
    $script:knowledgeRevision = ''
    if ($script:WorkspaceRegistryPath) {
        try {
            $registry = Get-Content -LiteralPath $script:WorkspaceRegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $registry.active = $WorkspaceId
            [IO.File]::WriteAllText($script:WorkspaceRegistryPath, ($registry | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        } catch { }
    }
    $snapshot = Get-KnowledgeSession -Refresh
    return $snapshot
}


function Get-KnowledgeSession {
    param([switch]$Refresh)
    if (-not $Refresh -and $script:knowledgeSnapshot) { return $script:knowledgeSnapshot }
    $status = Invoke-Wb @('status')
    $pages = [Collections.Generic.List[object]]::new()
    foreach ($row in @(Invoke-Wb @('note', 'list'))) {
        $detail = Invoke-Wb @('knowledge', 'show', [string]$row.knowledge_id)
        $provenance = @($detail.provenance | ForEach-Object {
            [ordered]@{
                path = $_.display_path
                versionId = $_.evidence_version_id
                itemId = $_.item_id
                contentHash = $_.content_hash
                relation = $_.relation
            }
        })
        $pages.Add([ordered]@{
            id = [string]$detail.knowledge.id
            title = [string]$detail.knowledge.title
            versionId = [string]$detail.version.id
            versionNo = [int]$detail.version.version_no
            reviewState = [string]$detail.version.review_state
            lifecycle = [string]$detail.version.lifecycle
            space = [string]$detail.knowledge.space
            confidentiality = [string]$detail.knowledge.confidentiality
            createdAt = [string]$detail.version.created_at
            basisHash = [string]$detail.basis_hash
            body = [string]$detail.body
            provenance = $provenance
            reviews = @($detail.reviews | ForEach-Object {
                [ordered]@{
                    reviewer = [string]$_.reviewer
                    decision = [string]$_.decision
                    note = [string]$_.note
                    decidedAt = [string]$_.decided_at
                    basisHash = [string]$_.basis_hash
                    invalidatedAt = [string]$_.invalidated_at
                    invalidatedReason = [string]$_.invalidated_reason
                }
            })
            versions = @($detail.versions | ForEach-Object {
                [ordered]@{
                    id = [string]$_.id
                    versionNo = [int]$_.versionNo
                    createdAt = [string]$_.createdAt
                    author = [string]$_.author
                    reviewState = [string]$_.reviewState
                    lifecycle = [string]$_.lifecycle
                    basisHash = [string]$_.basisHash
                    changeReason = [string]$_.changeReason
                    supersedesVersionId = [string]$_.supersedesVersionId
                }
            })
            history = @($detail.history | ForEach-Object {
                [ordered]@{
                    type = [string]$_.type
                    at = [string]$_.at
                    versionId = [string]$_.versionId
                    versionNo = [int]$_.versionNo
                    reviewState = [string]$_.reviewState
                    actor = [string]$_.actor
                    reason = [string]$_.reason
                    reviewer = [string]$_.reviewer
                    reviewerName = [string]$_.reviewerName
                    legacyReviewerName = [string]$_.legacyReviewerName
                    note = [string]$_.note
                    basisHash = [string]$_.basisHash
                    newVersionId = [string]$_.newVersionId
                    newVersionNo = [int]$_.newVersionNo
                }
            })
        })
    }
    $sources = [Collections.Generic.List[object]]::new()
    foreach ($source in @(Invoke-Wb @('source', 'list'))) {
        $sources.Add([ordered]@{
            id = [string]$source.id
            name = [string]$source.name
            space = [string]$source.space
            type = [string]$source.kind
            typeLabel = 'Wissensbasis-Quelle'
            path = $null
            connection = 'Lokale wb-Zugriffsschicht'
            read = [bool]$source.binding.read
            write = $false
            reachable = [string]$source.binding.state
            lastSuccess = $source.binding.last_success_at
            pending = $null
            documents = [int]$source.items
            versions = [int]$source.versions
            updateState = 'unknown'
            error = $source.binding.last_error
        })
    }
    $items = [Collections.Generic.List[object]]::new()
    foreach ($item in @(Invoke-Wb @('item', 'list', '--limit', '500'))) {
        $items.Add([ordered]@{
            itemId = [string]$item.item_id
            path = [string]$item.display_path
            versionId = [string]$item.version_id
            sourceId = [string]$item.source_id
            sourceName = [string]$item.source_name
            space = [string]$item.space
            status = [string]$item.extraction_status
            reason = [string]$item.extraction_reason
            size = [int]$item.size
            contentHash = [string]$item.content_hash
        })
    }
    $summary = $status.summary
    $index = $status.index
    $rawRoot = ''
    $poc = $null
    try {
        $config = Get-Content -LiteralPath $WissensbasisConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        $binding = @($config.bindings | Where-Object { $_.kind -eq 'local_path' } | Select-Object -First 1)
        if ($binding.Count) { $rawRoot = [string]$binding[0].locator }
        if ($config.poc) {
            $poc = [ordered]@{
                name = [string]$config.poc.name
                topic = [string]$config.poc.topic
                pageTitle = [string]$config.poc.page_title
                sourceRoot = [string]$config.poc.source_root
                rawRoot = [string]$config.poc.raw_root
                storeRoot = [string]$config.store_root
                baseRoot = [string]$config.poc.base_root
                files = @($config.poc.files)
                authorization = [string]$config.poc.authorization
            }
        }
    } catch { }
    $store = [ordered]@{
        root = [string]$summary.root
        rawRoot = $rawRoot
        configPath = [string]$WissensbasisConfig
        storeId = [string]$summary.store_id
        role = [string]$summary.role
        actor = [string]$status.actor
        schemaVersion = [int]$index.schema_version
        items = [int]$summary.items
        versions = [int]$summary.versions
        reviews = [int]$summary.reviews
        pages = $pages.Count
        index = $index
    }
    $workspaceCatalog = @(Get-WorkspaceCatalog)
    $activeWorkspace = @($workspaceCatalog | Where-Object { $_.active } | Select-Object -First 1)
    $activeWorkspaceId = if ($activeWorkspace.Count) { [string]$activeWorkspace[0].id } else { '' }
    $inventory = [ordered]@{
        mode = 'wissensbasis'
        topics = @()
        files = @()
        sources = @($sources.ToArray())
        items = @($items.ToArray())
        knowledge = @($pages.ToArray())
        store = $store
        poc = $poc
        workspaces = $workspaceCatalog
        activeWorkspace = $activeWorkspaceId
        ai = @{
            configured = [bool]$script:aiConfiguration.configured
            provider = [string]$script:aiConfiguration.provider
            model = [string]$script:aiConfiguration.model
            endpoint = [string]$script:aiConfiguration.endpoint
            mode = if ($script:aiConfiguration.configured) { 'ai' } else { 'retrieval' }
        }
        computer = @{ id = [string]$summary.computer.id; name = [string]$summary.computer.name }
        method = 'Wissensbasis-Store ueber die wb-Zugriffsschicht; keine Verzeichnisindexierung.'
        excludedDirectories = @()
    }
    $revision = [guid]::NewGuid().ToString('N')
    $now = [DateTime]::UtcNow.ToString('o')
    $snapshot = [ordered]@{
        directory = 'Wissensbasis: ' + [string]$summary.root
        updated = $now
        directorySyncedAt = $index.built_at
        revision = $revision
        sourceEditing = $false
        inventory = $inventory
    }
    $script:knowledgeSnapshot = $snapshot
    $script:knowledgeRevision = $revision
    $snapshot
}

function Get-KnowledgeSearch([string]$Query, [switch]$Any) {
    $arguments = @('search', $Query)
    if ($Any) { $arguments += '--any' }
    $arguments += @('--limit', '50')
    $data = Invoke-Wb $arguments
    [ordered]@{
        query = [string]$data.query
        results = @($data.results)
        mode = [string]$data.mode
        filtered = [int]$data.filtered_by_access
    }
}

function Get-KnowledgeEvidence([string]$VersionId) {
    Invoke-Wb @('evidence', $VersionId)
}

function Get-AiConfiguration {
    if (-not $script:AiConfigPath -or -not (Test-Path -LiteralPath $script:AiConfigPath -PathType Leaf)) {
        if ([Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY')) {
            return [ordered]@{ configured = $true; provider = 'openai-compatible'; model = 'deepseek-chat'; endpoint = 'https://api.deepseek.com/v1'; apiKeyEnv = 'DEEPSEEK_API_KEY'; timeoutSeconds = 60 }
        }
        if ([Environment]::GetEnvironmentVariable('OPENAI_API_KEY')) {
            return [ordered]@{ configured = $true; provider = 'openai-compatible'; model = 'gpt-4o-mini'; endpoint = 'https://api.openai.com/v1'; apiKeyEnv = 'OPENAI_API_KEY'; timeoutSeconds = 60 }
        }
        return [ordered]@{ configured = $false; provider = 'retrieval'; model = ''; endpoint = ''; apiKeyEnv = ''; timeoutSeconds = 60 }
    }
    try { $value = Get-Content -LiteralPath $script:AiConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw ('KI-Konfiguration ist nicht lesbar: ' + $_.Exception.Message) }
    if ($value.schema -ne 'wb/ai/v1') { throw 'KI-Konfiguration hat ein unbekanntes Format.' }
    $provider = [string]$value.provider
    if ($provider -notin @('openai-compatible', 'ollama', 'extractive')) { throw 'Unbekannter KI-Provider.' }
    [ordered]@{
        configured = ($provider -ne 'extractive')
        provider = $provider
        model = [string]$value.model
        endpoint = [string]$value.endpoint
        apiKeyEnv = [string]$value.api_key_env
        timeoutSeconds = if ($value.timeout_seconds) { [int]$value.timeout_seconds } else { 60 }
    }
}

function Get-RetrievalAnswer([object[]]$Evidence, [string]$Question, [object[]]$History) {
    $lines = @()
    $used = @()
    $questionTerms = [regex]::Matches($Question.ToLowerInvariant(), '[a-zäöüß0-9]{4,}') | ForEach-Object { $_.Value } | Select-Object -Unique
    foreach ($item in @($Evidence | Select-Object -First 6)) {
        $candidates = @([regex]::Split([string]$item.snippet, '(?<=[.!?])\s+|\r?\n+') | Where-Object { $_.Trim().Length -ge 25 })
        $best = $null
        $bestScore = -1
        foreach ($candidate in $candidates) {
            $lower = $candidate.ToLowerInvariant()
            $score = @($questionTerms | Where-Object { $lower.Contains($_) }).Count
            if ($lower -match 'CHF|Franken|kosten|budget|beschlossen|entscheid|etappe|retention|offen') { $score += 1 }
            if ($score -gt $bestScore) { $bestScore = $score; $best = $candidate.Trim() }
        }
        if (-not $best) { $best = ([string]$item.snippet).Trim() }
        if ($best.Length -gt 420) { $best = $best.Substring(0, 420) + '...' }
        $lines += ('• ' + $best + ' [' + $item.id + ']')
        $used += [string]$item.id
    }
    $answer = if ($lines.Count) { 'Belegte Angaben aus der Volltextsuche (kein Sprachmodell konfiguriert):' + "`n`n" + ($lines -join "`n`n") } else { 'Im Store wurde keine passende Belegstelle gefunden.' }
    [ordered]@{
        answer = $answer
        used_evidence = $used
        missing = if ($lines.Count) { @('Eine formulierte KI-Antwort ist nicht verfuegbar, weil keine KI-Anbindung konfiguriert ist. Die zitierten Stellen sind der aktuelle Belegstand.') } else { @('Keine passende Belegstelle im Store; die Information ist nicht belegt.') }
        follow_up = if ($lines.Count) { 'Soll ich eine bestimmte Belegstelle oder Seite naeher eingrenzen?' } else { 'Welche Quelle oder welcher Zeitraum ist gemeint?' }
        mode = 'retrieval'
    }
}

function Invoke-AiAnswer([string]$Question, [object[]]$Evidence, [object[]]$History, [string]$PageTitle = '') {
    $ai = $script:aiConfiguration
    if (-not $ai -or -not $ai.configured) { return Get-RetrievalAnswer $Evidence $Question $History }
    if (-not $ai.endpoint -or -not $ai.model) { throw 'KI-Endpunkt oder Modell fehlt in der Konfiguration.' }
    $context = for ($index = 0; $index -lt @($Evidence).Count; $index++) {
        $item = $Evidence[$index]
        ('[' + $item.id + '] Datei: ' + $item.path + ' | Fassung: ' + $item.versionId + ' | Seite: ' + $item.page + ' | Quelle: ' + $item.sourceKind + ' | Zeichen: ' + $item.start + '-' + $item.end + "`n" + $item.snippet)
    }
    $historyText = (@($History | Select-Object -Last 6 | ForEach-Object {
        $role = [string]$_.role
        $text = [string]$_.text
        $label = if ($role -eq 'assistant') { 'Bisherige Antwort (kein Beleg)' } elseif ($role -eq 'user' -and (Test-AskUserObservation $text)) { 'Nutzerbeobachtung (kein Beleg)' } else { 'Nutzerfrage' }
        ($label + ': ' + $text)
    }) -join "`n")
    $system = 'Du beantwortest Fragen ausschliesslich aus den bereitgestellten Belegen und der ausgewaehlten Wissensseite. Erfinde nichts. Wenn die Belege nicht reichen, benenne die fehlende Information ausdruecklich. Schreibe "Dokument fehlt" nur, wenn eine Bestandspruefung das Fehlen ausdruecklich bestaetigt; sonst schreibe "In den gefundenen Belegen nicht enthalten". Belege sind ausschliesslich die Eintraege unter BELEGE; fruehere Antworten und Nutzerbeobachtungen sind Gespraechskontext, keine Belege, und duerfen nicht als Tatsachenbeleg verwendet werden. Bei Personen, Anlaessen und Zeitraeumen nur Belege verwenden, die dieselbe Person, denselben Anlass und den relevanten Zeitraum betreffen; gleiche Namen oder aehnliche Woerter genuegen nicht. Dokumentdatum und Datum des beschriebenen Ereignisses unterscheiden. Wenn der Ereignisbezug unklar ist, benenne die Unsicherheit, statt einen Bezug zu einem anderen Termin zu konstruieren. Wenn ein Statutentext als Beleg mit Seiten geliefert wird, pruefe alle gelieferten Seiten und behaupte nicht, der Text sei unvollstaendig; unterscheide "keine ausdrueckliche Regel" von "Text nicht enthalten". Antworte auf Deutsch und im Kontext des bisherigen Verlaufs. Ein blosses "Ja" ist bei mehreren sinnvollen Anschlussmoeglichkeiten mehrdeutig; frage dann zuerst nach, statt eine Moeglichkeit zu raten. Wenn nach Statuten, Regeln oder rechtlicher Zulässigkeit gefragt wird, unterscheide im Antworttext klar zwischen "Statutarische Regel", "Dokumentierter Beschluss", "Planungsannahme" und "Ungeklärte Frage". Zitiere Statutenartikel nur, wenn der Statutentext tatsächlich im Beleg steht, mit [E#] und Artikel-/Seitenangabe. Ohne ausreichenden Statutentext keine eigene Aussage "rechtens" oder "gemäss Statuten zulässig"; nenne stattdessen die Nachweislücke. Protokollaussagen als dokumentierte Aussagen/Beschlüsse wiedergeben, nicht als Rechtsnorm. Gib ausschliesslich JSON zurueck: {"answer":"...", "used_evidence":["E1"], "missing":["..."], "follow_up":"...", "follow_up_options":[{"label":"Baukosten","message":"Bitte nach Baukosten aufschluesseln."}]}. Jede wesentliche Aussage muss auf mindestens einen Beleg verweisen. follow_up_options ist optional; liefere hoechstens drei konkrete, aus strukturierten Angaben (Tabellen, Listen, expliziten Optionen) ableitbare Optionen mit kurzem Label und vollstaendiger Nachricht. Leite Optionen nicht aus beliebigem Fliesstext ab und erfinde keine Optionen.'
    $pageContext = if ($PageTitle) { 'Ausgewaehlte Wissensseite: ' + $PageTitle + "`n" } else { '' }
    $user = $pageContext + 'Frage: ' + $Question + "`n`nBisheriger Verlauf:`n" + $(if ($historyText) { $historyText } else { '(kein Verlauf)' }) + "`n`nBELEGE:`n" + ($context -join "`n`n")
    $messages = @(@{ role = 'system'; content = $system }, @{ role = 'user'; content = $user })
    $content = $null
    if ($ai.provider -eq 'ollama') {
        $uri = $ai.endpoint.TrimEnd('/') + '/api/chat'
        $body = @{ model = $ai.model; messages = $messages; stream = $false; format = 'json' } | ConvertTo-Json -Depth 10
        $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $ai.timeoutSeconds
        $content = [string]$response.message.content
    } else {
        $key = if ($ai.apiKeyEnv) { [Environment]::GetEnvironmentVariable($ai.apiKeyEnv) } else { $null }
        if (-not $key) { throw ('Kein API-Schluessel in der Umgebungsvariable ' + $ai.apiKeyEnv + ' gesetzt.') }
        $uri = $ai.endpoint.TrimEnd('/') + '/chat/completions'
        $body = @{ model = $ai.model; messages = $messages; temperature = 0 } | ConvertTo-Json -Depth 10
        $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Headers @{ Authorization = 'Bearer ' + $key } -Body $body -TimeoutSec $ai.timeoutSeconds
        $content = [string]$response.choices[0].message.content
    }
    if (-not $content) { throw 'Die KI-Anbindung lieferte keine Antwort.' }
    $content = $content.Trim()
    if ($content -match '^```json\s*(.*?)\s*```$') { $content = $Matches[1] }
    try { $parsed = $content | ConvertFrom-Json } catch { throw 'Die KI-Anbindung lieferte kein gueltiges JSON.' }
    $allowed = @{}
    foreach ($item in @($Evidence)) { $allowed[[string]$item.id] = $item }
    $used = @()
    foreach ($id in @($parsed.used_evidence)) {
        if ($allowed.ContainsKey([string]$id)) { $used += $allowed[[string]$id] }
    }
    $missing = @($parsed.missing | ForEach-Object { [string]$_ })
    if (-not $used.Count) { $missing += 'Die Antwort enthielt keinen gueltigen Belegverweis.' }
    $followUpOptions = [Collections.Generic.List[object]]::new()
    $seenOptions = @{}
    foreach ($option in @($parsed.follow_up_options)) {
        if ($null -eq $option -or $option -is [string]) { continue }
        $label = ([string]$option.label).Trim()
        $message = ([string]$option.message).Trim()
        if (-not $label -or -not $message) { continue }
        if ($label.Length -gt 60 -or $message.Length -gt 300) { continue }
        if ($message.Length -lt 8) { continue }
        if ($seenOptions.ContainsKey($message.ToLowerInvariant())) { continue }
        $seenOptions[$message.ToLowerInvariant()] = $true
        $followUpOptions.Add([ordered]@{ label = $label; message = $message })
        if ($followUpOptions.Count -ge 3) { break }
    }
    [ordered]@{
        answer = [string]$parsed.answer
        used_evidence = @($used | ForEach-Object { [string]$_.id })
        missing = $missing
        follow_up = [string]$parsed.follow_up
        follow_up_options = @($followUpOptions.ToArray())
        mode = 'ai'
    }
}

function Get-KnowledgeEvidenceAllowSet {
    $set = @{}
    try {
        if (-not $script:WissensbasisConfig -or -not (Test-Path -LiteralPath $script:WissensbasisConfig -PathType Leaf)) { return $set }
        $config = Get-Content -LiteralPath $script:WissensbasisConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($path in @($config.poc.evidence_allow)) {
            $key = ([string]$path).Replace('\', '/').TrimStart('/').ToLowerInvariant()
            if ($key) { $set[$key] = $true }
        }
    } catch { }
    return $set
}

function Get-AskSourceKind([string]$Path) {
    $value = ([string]$Path).Replace('\', '/')
    if ($value -match '(?i)statut') { return 'Statutarische Regel' }
    if ($value -match '(?i)/regelungen/|/reglement') { return 'Regelwerk / vertragliche Regelung' }
    if ($value -match '(?i)/protokolle/|/protokoll') { return 'Dokumentierter Beschluss / Protokoll' }
    if ($value -match '(?i)/finanzen/|/budget|/kosten|/finanz') { return 'Finanzbeleg / Rechnung' }
    if ($value -match '(?i)/vorprojekt|/kostensch|/offert|/etappier') { return 'Planungsannahme / Projektunterlage' }
    if ($value -match '(?i)\.eml$') { return 'Korrespondenz' }
    return 'Weitere Primärquelle'
}

function Get-AskMonthNumber([string]$Name) {
    switch (([string]$Name).ToLowerInvariant()) {
        'januar' { return 1 } 'februar' { return 2 } 'märz' { return 3 } 'maerz' { return 3 }
        'april' { return 4 } 'mai' { return 5 } 'juni' { return 6 } 'juli' { return 7 }
        'august' { return 8 } 'september' { return 9 } 'oktober' { return 10 }
        'november' { return 11 } 'dezember' { return 12 }
        default { return 0 }
    }
}

function Get-AskDates([string]$Text, [int]$DefaultYear = 0, [bool]$IncludeMonthOnly = $false) {
    $monthPattern = 'januar|februar|märz|maerz|april|mai|juni|juli|august|september|oktober|november|dezember'
    if ($DefaultYear -le 0) { $DefaultYear = (Get-Date).Year }
    $dates = [Collections.Generic.List[object]]::new()
    $seen = @{}
    $add = {
        param($year, $month, $day, $kind, $index)
        if ($year -lt 1900 -or $month -lt 1 -or $month -gt 12 -or $day -lt 1 -or $day -gt 31) { return }
        try { $value = [datetime]::new($year, $month, $day) } catch { return }
        $key = $value.ToString('yyyy-MM-dd')
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $dates.Add([ordered]@{ start = $value; end = $value; kind = $kind; text = $key; index = [int]$index })
    }
    foreach ($match in [regex]::Matches($Text, '(?i)\b(\d{1,2})\.\s*(' + $monthPattern + ')\s+(\d{4})\b')) {
        $month = Get-AskMonthNumber $match.Groups[2].Value
        & $add ([int]$match.Groups[3].Value) $month ([int]$match.Groups[1].Value) 'exact' $match.Index
    }
    foreach ($match in [regex]::Matches($Text, '\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b')) {
        & $add ([int]$match.Groups[3].Value) ([int]$match.Groups[2].Value) ([int]$match.Groups[1].Value) 'exact' $match.Index
    }
    foreach ($match in [regex]::Matches($Text, '\b(20\d{2})-(\d{2})-(\d{2})\b')) {
        & $add ([int]$match.Groups[1].Value) ([int]$match.Groups[2].Value) ([int]$match.Groups[3].Value) 'exact' $match.Index
    }
    foreach ($match in [regex]::Matches($Text, '(?i)\b(' + $monthPattern + ')\s+(\d{4})\b')) {
        $month = Get-AskMonthNumber $match.Groups[1].Value
        $year = [int]$match.Groups[2].Value
        $start = [datetime]::new($year, $month, 1)
        $end = $start.AddMonths(1).AddDays(-1)
        $key = 'month:' + $start.ToString('yyyy-MM')
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $dates.Add([ordered]@{ start = $start; end = $end; kind = 'month'; text = $start.ToString('yyyy-MM'); index = [int]$match.Index })
        }
    }
    if ($IncludeMonthOnly) {
        foreach ($match in [regex]::Matches($Text, '(?i)\b(' + $monthPattern + ')\b')) {
            $month = Get-AskMonthNumber $match.Groups[1].Value
            if ($month -le 0) { continue }
            $start = [datetime]::new($DefaultYear, $month, 1)
            $end = $start.AddMonths(1).AddDays(-1)
            $key = 'month:' + $start.ToString('yyyy-MM')
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $dates.Add([ordered]@{ start = $start; end = $end; kind = 'month'; text = $start.ToString('yyyy-MM'); index = [int]$match.Index })
            }
        }
    }
    return @($dates.ToArray())
}

function Get-AskPrimaryEventDate([string]$Text, [object[]]$Dates) {
    if (-not $Dates.Count) { return $null }
    $eventMatches = @([regex]::Matches($Text, '(?i)\b(sitzung|versammlung|hauptversammlung|hv|anlass|treffen|zusammenkunft|pause)\b'))
    if ($eventMatches.Count) {
        $best = $null
        $bestDistance = [int]::MaxValue
        foreach ($date in $Dates) {
            $dateIndex = [int]$date.index
            foreach ($eventMatch in $eventMatches) {
                $distance = [Math]::Abs($dateIndex - [int]$eventMatch.Index)
                if ($distance -lt $bestDistance) { $bestDistance = $distance; $best = $date }
            }
        }
        if ($best) { return $best }
    }
    return $Dates[0]
}

function Get-AskTimeWindow([string]$Text) {
    $dates = @(Get-AskDates $Text 0 $true)
    if ($dates.Count) {
        $exactDates = @($dates | Where-Object { [string]$_.kind -eq 'exact' })
        $last = if ($exactDates.Count) { $exactDates[-1] } else { $dates[-1] }
        $start = $last.start
        $end = $last.end
        $monthMatch = [regex]::Match($Text, '(?i)\b(Ende|Anfang|Mitte)\s+(januar|februar|märz|maerz|april|mai|juni|juli|august|september|oktober|november|dezember)(?:\s+(\d{4}))?\b')
        if ($monthMatch.Success) {
            $month = Get-AskMonthNumber $monthMatch.Groups[2].Value
            $year = if ($monthMatch.Groups[3].Success) { [int]$monthMatch.Groups[3].Value } else { $start.Year }
            $monthStart = [datetime]::new($year, $month, 1)
            $monthEnd = $monthStart.AddMonths(1).AddDays(-1)
            switch ($monthMatch.Groups[1].Value.ToLowerInvariant()) {
                'ende' { $start = [datetime]::new($year, $month, 20); $end = $monthEnd }
                'anfang' { $start = $monthStart; $end = [datetime]::new($year, $month, 10) }
                'mitte' { $start = [datetime]::new($year, $month, 11); $end = [datetime]::new($year, $month, 20) }
            }
            return [ordered]@{ has = $true; start = $start; end = $end; label = $monthMatch.Value }
        }
        return [ordered]@{ has = $true; start = $start; end = $end; label = $last.text }
    }
    if ($Text -match '(?i)\bletzte[rn]?\s+Sitzung|letzte[rn]?\s+Versammlung') {
        $now = Get-Date
        return [ordered]@{ has = $true; start = $now.AddDays(-90); end = $now; label = 'letzte Sitzung (jüngster Zeitraum)' }
    }
    return [ordered]@{ has = $false; start = $null; end = $null; label = '' }
}

function Get-AskPersons([string]$Text) {
    $stop = @('Sitzung','Versammlung','Hauptversammlung','Ende','Anfang','Mitte','Oktober','November','Dezember','Januar','Februar','März','April','Mai','Juni','Juli','August','September','Montag','Dienstag','Mittwoch','Donnerstag','Freitag','Samstag','Sonntag','Was','Wie','Warum','Welche','Welcher','Welches','Bitte','Herr','Frau','E-Mail','Email','Statuten','Protokoll')
    $names = [Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Text, '\b[A-ZÄÖÜ][a-zäöüß]{2,}(?:\s+[A-ZÄÖÜ][a-zäöüß]{2,})+\b')) {
        $value = $match.Value.Trim()
        if ($value -notmatch '\s') { continue }
        if (@($value -split '\s+' | Where-Object { $_ -in $stop }).Count) { continue }
        if (-not $names.Contains($value)) { $names.Add($value) }
    }
    foreach ($word in @([regex]::Matches($Text, '\b[A-ZÄÖÜ][a-zäöüß]{3,}\b') | ForEach-Object { $_.Value })) {
        if ($word -in $stop) { continue }
        if (-not $names.Contains($word)) { $names.Add($word) }
    }
    return @($names | Select-Object -First 3)
}

function Get-AskOccasions([string]$Text) {
    $occasions = [Collections.Generic.List[string]]::new()
    foreach ($term in @('Sitzung','Versammlung','Hauptversammlung','HV','Pause','Zusammenkunft','Treffen','Anlass','Rüge','Verabschiedung')) {
        if ($Text -match ('(?i)\b' + [regex]::Escape($term) + '\b')) { $occasions.Add($term) }
    }
    return @($occasions.ToArray())
}

function Get-AskContext([string]$Question, [object[]]$History) {
    $userTexts = @($Question)
    $userTexts += @($History | Where-Object { $_.role -eq 'user' } | Select-Object -Last 4 | ForEach-Object { [string]$_.text })
    $contextText = ($userTexts -join "`n")
    $time = Get-AskTimeWindow $contextText
    $persons = @(Get-AskPersons $contextText)
    $occasions = @(Get-AskOccasions $Question)
    if (-not $occasions.Count) { $occasions = @(Get-AskOccasions $contextText) }
    $behavior = $Question -match '(?i)verlassen|verliess|verließ|verhalten|wirkte|schien|bestellte|trank|ass|aß|rügen|rüge|entschuldig|anwesend|gekommen|gegangen'
    $personFilter = $persons.Count -gt 0 -and ($behavior -or $occasions.Count -gt 0 -or ($time.has -and $Question -match '(?i)\b(mit|über|ueber|von|bei|zu|für|fuer)\b'))
    [ordered]@{
        has_constraint = [bool]($personFilter -or $occasions.Count -gt 0 -or $time.has)
        person_filter = $personFilter
        persons = @($persons)
        occasion_filter = $occasions.Count -gt 0
        occasions = @($occasions)
        time_filter = [bool]$time.has
        start = $time.start
        end = $time.end
        label = [string]$time.label
    }
}

function Get-AskDocumentDate([string]$Path) {
    $leaf = [IO.Path]::GetFileName([string]$Path)
    $match = [regex]::Match($leaf, '(20\d{2})-(\d{2})-(\d{2})')
    if (-not $match.Success) { return $null }
    try { return [datetime]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, [int]$match.Groups[3].Value) } catch { return $null }
}

function Test-AskEvidenceRelevance($Item, $Context) {
    $text = (([string]$Item.snippet) + ' ' + ([string]$Item.path)).ToLowerInvariant()
    if ($Context.person_filter) {
        $personHit = $false
        foreach ($person in @($Context.persons)) {
            foreach ($token in @(([string]$person).ToLowerInvariant() -split '\s+')) {
                if ($token.Length -ge 4 -and $text.Contains($token)) { $personHit = $true; break }
            }
            if ($personHit) { break }
        }
        if (-not $personHit) { return $false }
    }
    if ($Context.occasion_filter -and $text -notmatch '(?i)\bsitzung|versammlung|hauptversammlung|\bhv\b|pause|zusammenkunft|treffen|anlass|rüge|verabschiedung') { return $false }
    if ($Context.time_filter) {
        if ($Item.eventDate) {
            try { $primary = [datetime]::ParseExact([string]$Item.eventDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } catch { return $false }
            if ($primary -lt $Context.start -or $primary -gt $Context.end) { return $false }
        } elseif ($Item.documentDate) {
            $parsed = [datetime]$Item.documentDate
            if ($parsed -lt $Context.start -or $parsed -gt $Context.end) { return $false }
        } else {
            return $false
        }
    }
    return $true
}

function Test-AskUserObservation([string]$Text) {
    $value = ([string]$Text).Trim()
    if (-not $value -or $value.EndsWith('?')) { return $false }
    if ($value -match '(?i)\b(soll|sollte|sollen|was|wie|warum|welche|welcher|welches|kann|könnte|koennte|ist|sind|darf|dürfte|duerfte|gilt|gibt)\b') { return $false }
    return $value -match '(?i)\b(wirkte|schien|sah|hörte|hoerte|bemerkte|bestellte|trank|ass|aß|verliess|verließ|ging|kam|war|hat|hatte)\b'
}

function Get-AskEvidenceResults([string]$Question, [object[]]$History) {
    $allow = Get-KnowledgeEvidenceAllowSet
    $stop = @('welche','welcher','welches','sind','ist','was','wurde','wurden','werden','wird','bleibt','bleiben','dokumentiert','bitte','oder','und','der','die','das','den','dem','des','ein','eine','einer','eines','mit','für','fuer','von','vom','zum','zur','im','in','auf','aus','bei','nach','über','ueber','unter','wie','wo','wann','warum','sich','nicht','auch','noch','schon','kann','können','koennen')
    $terms = [regex]::Matches($Question.ToLowerInvariant(), '[a-zäöüß0-9]{4,}') | ForEach-Object { $_.Value } | Where-Object { $_ -notin $stop } | Select-Object -Unique | Select-Object -First 8
    if ($History.Count) {
        $lastUser = @($History | Where-Object { $_.role -eq 'user' } | Select-Object -Last 1)
        if ($lastUser.Count -and -not (Test-AskUserObservation ([string]$lastUser[0].text))) {
            $terms += [regex]::Matches([string]$lastUser[0].text.ToLowerInvariant(), '[a-zäöüß0-9]{5,}') | ForEach-Object { $_.Value } | Where-Object { $_ -notin $stop } | Select-Object -First 3
        }
    }
    $all = [Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($term in $terms) {
        $search = Get-KnowledgeSearch $term
        foreach ($result in @($search.results | Where-Object { $_.type -eq 'evidence' -and (-not $allow.Count -or $allow.ContainsKey(([string]$_.display_path).Replace('\', '/').TrimStart('/').ToLowerInvariant())) } | Select-Object -First 6)) {
            $resultPath = ([string]$result.display_path).Replace('\', '/').TrimStart('/').ToLowerInvariant()
            if ($allow.Count -and -not $allow.ContainsKey($resultPath)) { continue }
            $key = [string]$result.version_id + '|' + [string]$result.page + '|' + [string]$result.citation.start
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $all.Add($result)
        }
    }
    if (-not $all.Count) {
        $search = Get-KnowledgeSearch $Question -Any
        foreach ($result in @($search.results | Where-Object { $_.type -eq 'evidence' -and (-not $allow.Count -or $allow.ContainsKey(([string]$_.display_path).Replace('\', '/').TrimStart('/').ToLowerInvariant())) } | Select-Object -First 12)) {
            $resultPath = ([string]$result.display_path).Replace('\', '/').TrimStart('/').ToLowerInvariant()
            if ($allow.Count -and -not $allow.ContainsKey($resultPath)) { continue }
            $key = [string]$result.version_id + '|' + [string]$result.page + '|' + [string]$result.citation.start
            if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $all.Add($result) }
        }
    }
    @($all.ToArray())
}


function Get-KnowledgePageAnswer([string]$Question, [string]$KnowledgeId = '') {
    $stop = @('welche','welcher','welches','sind','ist','was','wurde','wurden','werden','wird','bleibt','bleiben','dokumentiert','bitte','oder','und','der','die','das','den','dem','des','ein','eine','einer','eines','mit','für','fuer','von','vom','zum','zur','im','in','auf','aus','bei','nach','über','ueber','unter','wie','wo','wann','warum','sich','nicht','auch','noch','schon','kann','können','koennen')
    $terms = @([regex]::Matches($Question.ToLowerInvariant(), '[a-zäöüß0-9]{4,}') | ForEach-Object { $_.Value } | Where-Object { $_ -notin $stop } | Select-Object -Unique)
    if (-not $terms.Count) { return $null }
    $probes = @($terms)
    if ($Question -match '(?i)statut|artikel|art\.|regel|recht|zulässig|rechtens') {
        $probes += @('Art.', 'Art. 3', 'Kostenverteilung', 'Beitrag', 'Beschluss')
    }
    $probes = @($probes | Select-Object -Unique)
    $pages = [Collections.Generic.List[object]]::new()
    foreach ($row in @(Invoke-Wb @('note', 'list'))) {
        if ($KnowledgeId -and [string]$row.knowledge_id -ne $KnowledgeId) { continue }
        try { $detail = Invoke-Wb @('knowledge', 'show', [string]$row.knowledge_id) } catch { continue }
        $body = [string]$detail.body
        $lower = $body.ToLowerInvariant()
        $title = [string]$detail.knowledge.title
        $titleLower = $title.ToLowerInvariant()
        $bodyHits = 0
        foreach ($probe in $probes) { if ($lower.Contains($probe)) { $bodyHits++ } }
        if ($bodyHits -eq 0) { continue }
        $titleHits = 0
        foreach ($probe in $probes) { if ($titleLower.Contains($probe)) { $titleHits++ } }
        $pages.Add([pscustomobject]@{ Detail = $detail; Body = $body; Title = $title; Score = [double]($bodyHits * 10 + $titleHits * 6) })
    }
    if (-not $pages.Count) { return $null }
    $rankedPages = @($pages | Sort-Object Score -Descending)
    $bestPageScore = [double]$rankedPages[0].Score
    $chosenPages = @($rankedPages | Where-Object { $_.Score -ge [Math]::Max(2.0, $bestPageScore * 0.7) } | Select-Object -First 2)
    $sections = [Collections.Generic.List[object]]::new()
    foreach ($page in $chosenPages) {
        $parts = @([regex]::Split([string]$page.Body, '(?m)^##\s+') | Where-Object { $_.Trim() })
        $pageSections = [Collections.Generic.List[object]]::new()
        foreach ($part in $parts) {
            if ($part.TrimStart().StartsWith('# ')) { continue }
            $lines = @($part -split "`r?`n", 2)
            $heading = if ($lines.Count -gt 1) { $lines[0].Trim() } else { [string]$page.Title }
            $text = if ($lines.Count -gt 1) { $lines[1].Trim() } else { $part.Trim() }
            $lower = ($heading + ' ' + $text).ToLowerInvariant()
            $hits = 0
            foreach ($probe in $probes) { if ($lower.Contains($probe)) { $hits++ } }
            if ($hits -gt 0) {
                $pageSections.Add([pscustomobject]@{ Title = [string]$page.Title; Detail = $page.Detail; Heading = $heading; Text = $text; Score = [double]$hits })
            }
        }
        foreach ($section in @($pageSections | Sort-Object Score -Descending)) { $sections.Add($section) }
    }
    if (-not $sections.Count) { return $null }
    $chosenSections = @($sections | Sort-Object Score -Descending | Select-Object -First 4)
    if ($Question -match '(?i)offen|beschlossen|vorgeschlagen|entschieden|nachweis|belegt|versandt') {
        $extraSections = @($sections | Where-Object { $_.Heading -match '^(Grenzen|Abgrenzung)' -and @($chosenSections.Heading) -notcontains $_.Heading })
        if ($extraSections.Count) { $chosenSections = @(@($chosenSections) + @($extraSections) | Sort-Object Score -Descending | Select-Object -First 5) }
    }
    $answerParts = foreach ($section in $chosenSections) {
        'Aus der bestehenden Wissensseite «' + $section.Title + '» (Synthese, unbestätigt), Abschnitt ' + $section.Heading + ':' + "`n" + $section.Text
    }
    $citations = [Collections.Generic.List[object]]::new()
    $seenCitations = @{}
    foreach ($page in $chosenPages) {
        foreach ($item in @($page.Detail.provenance)) {
            if (-not $item -or -not $item.evidence_version_id) { continue }
            $key = [string]$item.evidence_version_id + '|' + [string]$item.item_id
            if ($seenCitations.ContainsKey($key)) { continue }
            $seenCitations[$key] = $true
            $citations.Add([ordered]@{
                versionId = [string]$item.evidence_version_id
                path = [string]$item.display_path
                page = 0
                start = 0
                end = 0
                itemId = [string]$item.item_id
            })
        }
    }
    [ordered]@{
        answer = ($answerParts -join "`n`n")
        used_evidence = @()
        missing = @('Die Antwort ist ein Auszug aus einer bestehenden, noch unbestätigten Wissensseite (Status needs_review). Eine KI-Anbindung ist nicht konfiguriert; die Seite ersetzt keine eigene Prüfung der Originale.')
        follow_up = 'Soll ich die zugrunde liegende Originalstelle oder eine bestimmte Etappe naeher eingrenzen?'
        mode = 'retrieval'
        citations = @($citations)
    }
}

function Get-KnowledgeAsk([string]$Question, [object[]]$History, [string]$KnowledgeId = '', [string]$GapId = '') {
    $history = @($History | Select-Object -Last 6 | ForEach-Object { [ordered]@{ role = [string]$_.role; text = [string]$_.text } })
    if (Test-AskUserObservation $Question) {
        $aiState = if ($script:aiConfiguration) { $script:aiConfiguration } else { Get-AiConfiguration }
        return [ordered]@{
            question = $Question
            answer = ('Als Ihre Beobachtung notiert: „' + $Question.Trim() + '“. Sie ergänzt den Gesprächskontext; ich behandle sie nicht als dokumentarischen Beleg und starte dazu keine neue Suche.')
            citations = @()
            missing = @()
            gaps = @()
            follow_up = ''
            follow_up_options = @()
            mode = 'observation'
            evidence = @()
            user_observation = $true
            ai = $aiState
        }
    }
    $pageTitle = ''
    $selectedPage = $null
    if ($KnowledgeId) {
        try {
            $selectedPage = Invoke-Wb @('knowledge', 'show', $KnowledgeId)
            $pageTitle = [string]$selectedPage.knowledge.title
        } catch { $pageTitle = ''; $selectedPage = $null }
    }
    $results = Get-AskEvidenceResults $Question $history
    $askContext = Get-AskContext $Question $history
    if ($askContext.time_filter -and $askContext.start) {
        $months = @('Januar','Februar','März','April','Mai','Juni','Juli','August','September','Oktober','November','Dezember')
        $startDate = [datetime]$askContext.start
        $endDate = [datetime]$askContext.end
        $dateQuery = if ($startDate.Date -eq $endDate.Date) {
            ('{0}. {1} {2}' -f $startDate.Day, $months[$startDate.Month - 1], $startDate.Year)
        } else {
            ('{0} {1}' -f $months[$startDate.Month - 1], $startDate.Year)
        }
        try {
            $dateSearch = Get-KnowledgeSearch $dateQuery
            $allow = Get-KnowledgeEvidenceAllowSet
            $dateResults = @($dateSearch.results | Where-Object {
                $_.type -eq 'evidence' -and
                (-not $allow.Count -or $allow.ContainsKey(([string]$_.display_path).Replace('\', '/').TrimStart('/').ToLowerInvariant()))
            } | Select-Object -First 20)
            if ($dateResults.Count) { $results = @($dateResults) + @($results) }
        } catch { }
    }
    if ($Question -match '(?i)statut|artikel|art\.|regel|recht|zulässig|rechtens') {
        $allow = Get-KnowledgeEvidenceAllowSet
        try { $statuteSearch = Get-KnowledgeSearch 'Art.' } catch { $statuteSearch = $null }
        $statuteResults = @($statuteSearch.results | Where-Object {
            $_.type -eq 'evidence' -and
            ([string]$_.display_path -match '(?i)statut') -and
            (-not $allow.Count -or $allow.ContainsKey(([string]$_.display_path).Replace('\', '/').TrimStart('/').ToLowerInvariant()))
        } | Select-Object -First 3)
        if ($statuteResults.Count) { $results = @($statuteResults) + @($results) }
    }
    $seen = @{}
    $evidence = @()
    $index = 0
    $evidenceCache = @{}
    $selectedResults = [Collections.Generic.List[object]]::new()
    $perPath = @{}
    foreach ($result in @($results)) {
        $resultPath = ([string]$result.display_path).Replace('\', '/').TrimStart('/').ToLowerInvariant()
        $usedForPath = if ($perPath.ContainsKey($resultPath)) { [int]$perPath[$resultPath] } else { 0 }
        if ($usedForPath -ge 2) { continue }
        $perPath[$resultPath] = $usedForPath + 1
        $selectedResults.Add($result)
        if ($selectedResults.Count -ge 12) { break }
    }
    foreach ($result in @($selectedResults)) {
        $key = [string]$result.version_id + '|' + [string]$result.page + '|' + [string]$result.citation.start
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $index++
        $versionId = [string]$result.version_id
        if (-not $evidenceCache.ContainsKey($versionId)) {
            try { $evidenceCache[$versionId] = Get-KnowledgeEvidence $versionId } catch { $evidenceCache[$versionId] = $null }
        }
        $document = $evidenceCache[$versionId]
        $snippet = [string]$result.snippet
        $start = if ($result.citation) { [int]$result.citation.start } else { 0 }
        $end = if ($result.citation) { [int]$result.citation.end } else { 0 }
        if ($document -and $document.text) {
            $contextStart = [Math]::Max(0, $start - 450)
            $contextEnd = [Math]::Min($document.text.Length, $start + 1500)
            $snippet = [string]$document.text.Substring($contextStart, $contextEnd - $contextStart)
        }
        $evidence += [ordered]@{
            id = 'E' + $index
            path = [string]$result.display_path
            versionId = $versionId
            page = $result.page
            start = $start
            end = $end
            snippet = $snippet
            extractionStatus = [string]$result.extraction_status
            sourceKind = Get-AskSourceKind ([string]$result.display_path)
        }
    }
    $ai = if ($script:aiConfiguration) { $script:aiConfiguration } else { Get-AiConfiguration }
    $answer = $null
    $aiError = ''
    if ($selectedPage) {
        $allow = Get-KnowledgeEvidenceAllowSet
        $seenVersions = @{}
        foreach ($item in @($evidence)) { if ($item.versionId) { $seenVersions[[string]$item.versionId] = $true } }
        $addedFromPage = 0
        foreach ($prov in @($selectedPage.provenance | Select-Object -First 20)) {
            if ($addedFromPage -ge 12) { break }
            $versionId = [string]$prov.evidence_version_id
            $pathValue = [string]$prov.display_path
            if (-not $versionId -or -not $pathValue) { continue }
            $pathKey = $pathValue.Replace('\', '/').TrimStart('/').ToLowerInvariant()
            if ($allow.Count -and -not $allow.ContainsKey($pathKey)) { continue }
            if ($seenVersions.ContainsKey($versionId)) { continue }
            try {
                $document = Get-KnowledgeEvidence $versionId
                $page = @($document.pages | Where-Object { [int]$_.chars -gt 0 } | Select-Object -First 1)[0]
                if (-not $page) { continue }
                $text = [string]$document.text
                $start = [int]$page.start
                $end = [Math]::Min($text.Length, [int]$page.end)
                if ($end -le $start) { continue }
                $snippet = $text.Substring($start, [Math]::Min(1800, $end - $start))
                $seenVersions[$versionId] = $true
                $evidence += [ordered]@{
                    id = 'E' + ([string](@($evidence).Count + 1))
                    path = $pathValue
                    versionId = $versionId
                    page = [int]$page.page
                    start = $start
                    end = $end
                    snippet = $snippet
                    extractionStatus = [string]$document.extraction.status
                    sourceKind = Get-AskSourceKind $pathValue
                }
                $addedFromPage++
            } catch { }
        }
    }
    if ($GapId) {
        try {
            $gapRecord = Get-GapRecord $GapId
            $gapVersionId = ''
            if ($gapRecord) {
                if ($gapRecord.upload -and $gapRecord.upload.version_id) { $gapVersionId = [string]$gapRecord.upload.version_id }
                elseif ($gapRecord.inspection -and @($gapRecord.inspection.candidates).Count) {
                    $gapCandidates = @($gapRecord.inspection.candidates)
                    $preferredCandidate = $null
                    if ((Get-GapCategory ([string]$gapRecord.statement)) -eq 'statute') {
                        $preferredCandidate = @($gapCandidates | Where-Object { ([string]$_.path) -match '(?i)statut|satzung|reglement' })[0]
                    }
                    if (-not $preferredCandidate) { $preferredCandidate = $gapCandidates[0] }
                    $gapVersionId = [string]$preferredCandidate.version_id
                }
            }
            if ($gapVersionId) {
                $gapDocument = Get-KnowledgeEvidence $gapVersionId
                $gapText = [string]$gapDocument.text
                $presentPages = @{}
                foreach ($item in @($evidence)) {
                    if ([string]$item.versionId -eq $gapVersionId) { $presentPages[[string]$item.page] = $true }
                }
                $gapPages = @($gapDocument.pages | Where-Object { [int]$_.chars -gt 0 } | Select-Object -First 24)
                foreach ($gapPage in $gapPages) {
                    $pageKey = [string]$gapPage.page
                    if ($presentPages.ContainsKey($pageKey)) { continue }
                    $start = [int]$gapPage.start
                    $end = [Math]::Min($gapText.Length, [int]$gapPage.end)
                    if ($end -le $start) { continue }
                    $gapPath = [string]$gapDocument.item.display_path
                    $evidence += [ordered]@{
                        id = 'E' + ([string](@($evidence).Count + 1))
                        path = $gapPath
                        versionId = $gapVersionId
                        page = [int]$gapPage.page
                        start = $start
                        end = $end
                        snippet = $gapText.Substring($start, $end - $start)
                        extractionStatus = [string]$gapDocument.extraction.status
                        sourceKind = Get-AskSourceKind $gapPath
                    }
                    $presentPages[$pageKey] = $true
                }
            }
        } catch { }
    }
    foreach ($item in @($evidence)) {
        $documentDate = Get-AskDocumentDate ([string]$item.path)
        $documentYear = if ($documentDate) { [int]$documentDate.Year } else { 0 }
        $rawDates = @(Get-AskDates ([string]$item.snippet) $documentYear)
        $exactDates = @($rawDates | Where-Object { [string]$_.kind -eq 'exact' })
        $chosenDates = if ($exactDates.Count) { $exactDates } else { $rawDates }
        $eventDates = @($chosenDates | ForEach-Object { $_.start.ToString('yyyy-MM-dd') } | Sort-Object -Unique)
        $primaryDate = Get-AskPrimaryEventDate ([string]$item.snippet) $chosenDates
        $item['documentDate'] = $documentDate
        $item['eventDates'] = @($eventDates)
        $item['eventDate'] = if ($primaryDate) { $primaryDate.start.ToString('yyyy-MM-dd') } else { $null }
    }
    $eventBlocked = $false
    if ($askContext.has_constraint) {
        $evidence = @($evidence | Where-Object { Test-AskEvidenceRelevance $_ $askContext })
        for ($i = 0; $i -lt @($evidence).Count; $i++) { $evidence[$i]['id'] = 'E' + ($i + 1) }
        if (-not @($evidence).Count) { $eventBlocked = $true }
    }
    if ($eventBlocked) {
        $answer = [ordered]@{
            answer = 'Für den genannten Anlass und Zeitraum enthält der Bestand keine passende Quelle. Ich verwende keine Belege zu anderen Terminen oder Anlässen und leite daraus keinen Ereignisbezug ab.'
            used_evidence = @()
            missing = @('Keine passende Quelle für den genannten Anlass/Zeitraum gefunden.')
            follow_up = ''
            mode = 'retrieval'
        }
    }
    if ($ai.configured -and -not $eventBlocked) {
        try { $answer = Invoke-AiAnswer $Question $evidence $history $pageTitle } catch { $aiError = $_.Exception.Message }
    }
    if (-not $answer -and -not $eventBlocked) {
        $answer = Get-KnowledgePageAnswer $Question $KnowledgeId
        if (-not $answer) { $answer = Get-RetrievalAnswer $evidence $Question $history }
        if ($aiError) { $answer.missing = @(@($answer.missing) + ('KI-Antwort fehlgeschlagen: ' + $aiError)) }
    }
    $citations = @()
    foreach ($citation in @($answer.citations)) { if ($citation) { $citations += $citation } }
    foreach ($id in @($answer.used_evidence)) {
        $item = @($evidence | Where-Object { $_.id -eq $id } | Select-Object -First 1)
        if ($item.Count) { $citations += $item[0] }
    }
    $followUpOptions = [Collections.Generic.List[object]]::new()
    $optionKeys = @{}
    $hasStructuredPageData = $selectedPage -and [string]$selectedPage.body -match '(?m)^\|.+\|'
    if ($hasStructuredPageData) {
        foreach ($option in @($answer.follow_up_options)) {
            if ($null -eq $option -or $option -is [string]) { continue }
            $label = ([string]$option.label).Trim()
            $message = ([string]$option.message).Trim()
            if (-not $label -or -not $message -or $message.Length -lt 8) { continue }
            $key = $message.ToLowerInvariant()
            if ($optionKeys.ContainsKey($key)) { continue }
            $optionKeys[$key] = $true
            $origin = if ($option.origin) { [string]$option.origin } else { 'answer' }
            $followUpOptions.Add([ordered]@{ label = $label; message = $message; origin = $origin })
            if ($followUpOptions.Count -ge 3) { break }
        }
    }
    $answerText = [string]$answer.answer
    $answerText = $answerText -replace '(?i)\b(?:das\s+)?dokument\s+fehlt\b', 'In den gefundenen Belegen nicht enthalten'
    $answerText = $answerText -replace '(?i)\bfehlt\s+das\s+dokument\b', 'In den gefundenen Belegen nicht enthalten'
    $inventoryChecked = $false
    try {
        $configForGaps = Get-PocConfiguration
        $inventoryChecked = [bool]($configForGaps.poc.inventory_file -and (Test-Path -LiteralPath ([string]$configForGaps.poc.inventory_file) -PathType Leaf))
    } catch { }
    $missingOut = @($answer.missing | ForEach-Object {
        ([string]$_).Replace('Dokument fehlt', 'In den gefundenen Belegen nicht enthalten').Replace('Das Dokument fehlt', 'In den gefundenen Belegen nicht enthalten').Replace('fehlt das Dokument', 'In den gefundenen Belegen nicht enthalten')
    })
    $gaps = [Collections.Generic.List[object]]::new()
    $gapWorkspaceKey = ''
    try { $gapWorkspaceKey = [IO.Path]::GetFullPath([string]$configForGaps.store_root).ToLowerInvariant() } catch { }
    $targetRecord = $null
    if ($GapId) { $targetRecord = Get-GapRecord $GapId }
    $seenGapIds = @{}
    if (-not $eventBlocked) {
    foreach ($missingText in @($missingOut)) {
        $textValue = ([string]$missingText).Trim()
        if (-not $textValue) { continue }
        if ($textValue -match '(?i)^\s*ob\s' -or $textValue -match '(?i)nicht abschliessend geklärt|nicht abschliessend geklaert|ungeklärt|ungeklaert|offene frage') { continue }
        if ($textValue -match '(?i)\b(ausdrückliche|ausdrueckliche|rechtsverbindliche|rechtsverbindlicher)\b.*\b(regel|bestätigung|bestaetigung|beurteilung|einschätzung|einschaetzung)\b') { continue }
        if ($textValue -notmatch '(?i)\b(dokument\w*|dokumentier\w*|beschluss\w*|statut\w*|vertrag\w*|vereinbarung\w*|protokoll\w*|unterlage\w*|beleg(e|en)?|quelle\w*|datei\w*|wortlaut|nachweis\w*|schriftlich\w*|urkunde\w*|auszug\w*|artikel\w*)\b') { continue }
        if ($targetRecord -and $targetRecord.inspection -and [string]$targetRecord.inspection.verdict -eq 'indexed' -and
            $textValue -match '(?i)statut|satzung|reglement|gesetz|artikel' -and
            ([string]$targetRecord.statement -match '(?i)statut|satzung|reglement|gesetz|artikel')) { continue }
        $computedGapId = Get-GapRecordId $gapWorkspaceKey $Question $textValue
        $matchedGap = Find-GapRecordForStatement $gapWorkspaceKey $Question $textValue
        if ($matchedGap) { $computedGapId = [string]$matchedGap.id }
        if ($seenGapIds.ContainsKey($computedGapId)) { continue }
        $seenGapIds[$computedGapId] = $true
        $mergeStatus = 'open'
        if (-not $GapId -and $matchedGap -and [string]$matchedGap.status -in @('proof_found', 'source_assigned', 'evaluation_needed')) { $mergeStatus = [string]$matchedGap.status }
        $record = Merge-GapRecord $computedGapId $Question $textValue $KnowledgeId @{ status = $mergeStatus }
        $gaps.Add([ordered]@{
            id = $computedGapId
            type = 'document'
            statement = $textValue
            question = $Question
            page_id = $KnowledgeId
            status = [string]$record.status
            record_status = [string]$record.status
            inspection = $record.inspection
            upload = $record.upload
            link = $record.link
            inventory_checked = $inventoryChecked
            initial_label = 'In den gefundenen Belegen nicht enthalten'
        })
    }
    }
    if ($GapId) {
        $targetRecord = if ($targetRecord) { $targetRecord } else { Get-GapRecord $GapId }
        if ($targetRecord) {
            $stillOpen = @($gaps | Where-Object { [string]$_.id -eq $GapId }).Count -gt 0
            $targetCategory = Get-GapCategory ([string]$targetRecord.statement)
            if ($targetCategory -eq 'statute' -and $targetRecord.inspection -and [string]$targetRecord.inspection.verdict -eq 'indexed') {
                $stillOpen = $false
            } elseif ($targetCategory -and @($missingOut | Where-Object {
                (Get-GapCategory ([string]$_)) -eq $targetCategory -and
                ([string]$_ -notmatch '(?i)keine ausdrückliche|keine ausdrueckliche|keine spezifische|nicht ausdrücklich|nicht ausdruecklich|keine regel')
            }).Count) { $stillOpen = $true }
            $nextStatus = if ($stillOpen) {
                if ($targetRecord.inspection -and [string]$targetRecord.inspection.verdict -eq 'indexed') { 'source_assigned' }
                elseif ($targetRecord.upload) { 'evaluation_needed' }
                else { 'open' }
            } else { 'proof_found' }
            $attempts = [int]$targetRecord.attempts + 1
            $null = Merge-GapRecord $GapId ([string]$targetRecord.question) ([string]$targetRecord.statement) ([string]$targetRecord.page_id) @{
                status = $nextStatus
                attempts = $attempts
                last_answer = $answerText.Substring(0, [Math]::Min(1200, $answerText.Length))
                inspection = $targetRecord.inspection
                upload = $targetRecord.upload
                link = $targetRecord.link
            }
        }
    }
    [ordered]@{
        question = $Question
        answer = $answerText
        citations = @($citations)
        missing = @($missingOut)
        gaps = @($gaps.ToArray())
        follow_up = [string]$answer.follow_up
        follow_up_options = @($followUpOptions.ToArray())
        mode = [string]$answer.mode
        evidence = @($evidence)
        event_context = $askContext
        event_blocked = [bool]$eventBlocked
        ai = $ai
    }
}

function Invoke-KnowledgeReview([string]$KnowledgeId, [string]$VersionId, [string]$Decision, [string]$Note, [string]$BasisHash, $Checks) {
    if ($Decision -notin @('confirm', 'reject')) { throw 'Unbekannte Review-Entscheidung.' }
    $note = $Note.Trim()
    if ($note.Length -gt 2000) { throw 'Notiz ist zu lang.' }
    $snapshot = if ($script:knowledgeSnapshot) { $script:knowledgeSnapshot } else { Get-KnowledgeSession }
    $role = [string]$snapshot.inventory.store.role
    if ($role -ne 'leader') { throw 'Dieser Store ist nicht schreibbar; Review ist nur mit Rolle leader moeglich.' }
    $actor = [string]$snapshot.inventory.store.actor
    if (-not $actor) { $actor = 'owner' }
    $detail = Invoke-Wb @('knowledge', 'show', $KnowledgeId)
    $currentVersion = [string]$detail.version.id
    if ($currentVersion -ne $VersionId) { throw 'Die Wissensfassung ist nicht mehr aktuell; Seite neu laden.' }
    $currentState = [string]$detail.version.review_state
    $currentBasis = [string]$detail.basis_hash
    if ($BasisHash -and $BasisHash -ne $currentBasis) { throw 'Die Belegbasis hat sich geaendert; Seite neu pruefen.' }
    if ($Decision -eq 'confirm') {
        if ($currentState -eq 'confirmation_stale') { throw 'Die Bestaetigung ist ueberholt; die Seite muss mit der neuen Belegbasis neu erstellt werden.' }
        if ($currentState -eq 'confirmed') { throw 'Diese Fassung ist bereits bestaetigt.' }
        $checkList = @($Checks)
        if ($checkList.Count -ne 4 -or @($checkList | Where-Object { -not $_ }).Count -gt 0) {
            throw 'Bitte alle vier Pruefpunkte bestaetigen.'
        }
        $arguments = @('review', 'confirm', $VersionId, '--basis-hash', $currentBasis)
        if ($note) { $arguments += @('--note', $note) }
        $result = Invoke-Wb $arguments
    } else {
        if ($currentState -eq 'confirmed') { throw 'Eine bestaetigte Fassung wird ueber eine neue Fassung ueberarbeitet.' }
        if ($currentState -eq 'confirmation_stale') { throw 'Die Bestaetigung ist bereits ueberholt.' }
        if (-not $note) { throw 'Begruendung fehlt.' }
        $result = Invoke-Wb @('review', 'reject', $VersionId, '--note', $note)
    }
    $null = Get-KnowledgeSession -Refresh
    [ordered]@{
        review = $result
        reviewState = [string]$result.review_state
        knowledgeId = $KnowledgeId
        versionId = $VersionId
        decision = if ($Decision -eq 'confirm') { 'confirmed' } else { 'rejected' }
        reviewerName = $actor
    }
}

function Invoke-KnowledgeRevision([string]$KnowledgeId, [string]$BaseVersionId, [string]$Body, [string]$Reason, [string]$BasisHash) {
    if (-not $KnowledgeId -or -not $BaseVersionId) { throw 'Wissensseite oder Ausgangsfassung fehlt.' }
    if (-not $Body.Trim()) { throw 'Der neue Text fehlt.' }
    if ($Body.Length -gt 200000) { throw 'Der neue Text ist zu lang.' }
    if ($Reason.Length -gt 2000) { throw 'Der Aenderungsgrund ist zu lang.' }
    $snapshot = if ($script:knowledgeSnapshot) { $script:knowledgeSnapshot } else { Get-KnowledgeSession }
    $role = [string]$snapshot.inventory.store.role
    if ($role -ne 'leader') { throw 'Dieser Store ist nicht schreibbar; Bearbeitung ist nur mit Rolle leader moeglich.' }
    $actor = [string]$snapshot.inventory.store.actor
    if (-not $actor) { $actor = 'owner' }
    [IO.Directory]::CreateDirectory($temporary) | Out-Null
    $bodyPath = Join-Path $temporary ('kb-revision-' + [guid]::NewGuid().ToString('N') + '.md')
    try {
        [IO.File]::WriteAllText($bodyPath, $Body, [Text.UTF8Encoding]::new($false))
        $arguments = @('knowledge', 'revise', $KnowledgeId, '--file', $bodyPath,
            '--base-version', $BaseVersionId, '--author', $actor)
        if ($Reason.Trim()) { $arguments += @('--reason', $Reason.Trim()) }
        if ($BasisHash) { $arguments += @('--basis-hash', $BasisHash) }
        $result = Invoke-Wb $arguments
    } finally {
        if (Test-Path -LiteralPath $bodyPath) { Remove-Item -LiteralPath $bodyPath -Force }
    }
    $null = Get-KnowledgeSession -Refresh
    [ordered]@{
        knowledgeId = [string]$result.knowledge_id
        versionId = [string]$result.knowledge_version_id
        previousVersionId = [string]$result.previous_version_id
        versionNo = [int]$result.version_no
        reviewState = [string]$result.review_state
        basisHash = [string]$result.basis_hash
        reason = [string]$result.reason
    }
}

$script:aiConfiguration = Get-AiConfiguration

if ($RunPoc) {
    $pocExitCode = Invoke-IngestionRun -ConfirmExternalAi:$ConfirmExternalAi -Resume:$ResumePoc
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
    exit $pocExitCode
}

try {
    $listener.Start()
    Write-Host "AI-OS-Verbindungsdienst: $localOrigin | Erlaubter Ursprung: $Origin"
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $request = $context.Request
            $path = $request.Url.AbsolutePath
            $requestOrigin = $request.Headers['Origin']
            if ($request.Headers['Host'] -ne "127.0.0.1:$Port") { Send-Response $context 403 '{"error":"Host abgelehnt"}'; continue }
            if ($request.HttpMethod -eq 'OPTIONS') {
                if ($requestOrigin -eq $Origin) { Send-Response $context 204 '' } else { Send-Response $context 403 '{}' }
                continue
            }
            if ($path -eq '/health' -and $request.HttpMethod -eq 'GET' -and $requestOrigin -eq $Origin) {
                Send-Response $context 200 '{"service":"ai-os-connector","version":1}'
                continue
            }
            if ($path -eq '/pair' -and $request.HttpMethod -eq 'GET') {
                $returnUri = $null
                if (-not [Uri]::TryCreate($request.QueryString['app'], [UriKind]::Absolute, [ref]$returnUri) -or $returnUri.GetLeftPart([UriPartial]::Authority) -ne $Origin -or $returnUri.UserInfo -or $returnUri.Fragment) {
                    Send-Response $context 400 '{"error":"Rueckkehradresse nicht erlaubt"}'
                    continue
                }
                $target = $Origin | ConvertTo-Json -Compress
                $returnTarget = $returnUri.AbsoluteUri | ConvertTo-Json -Compress
                $html = @'
<!doctype html><html lang="de"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AI-OS lokal verbinden</title>
<style>
*{box-sizing:border-box}body{font:15px/1.55 Bahnschrift,Segoe UI,sans-serif;max-width:780px;margin:32px auto;padding:0 24px;color:#202b28;background:#fafbf9;letter-spacing:0}h1{font-size:28px;line-height:1.2;margin:0 0 20px}p{overflow-wrap:anywhere}button{font:inherit;padding:11px 16px;border:1px solid #18674b;border-radius:4px;background:#18674b;color:white;cursor:pointer}button:disabled{opacity:.6;cursor:wait}.directory{border-left:3px solid #aebfba;padding:10px 14px;background:#f0f3f2;overflow-wrap:anywhere}.worker{margin-top:24px;border-top:2px solid #39745e;padding-top:16px}.heading,.timing{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}#status{font-weight:600}small,.timing,.detail{color:#53645f;font-size:13px}progress{display:block;width:100%;height:12px;margin:14px 0;accent-color:#287556}#current{min-height:42px;overflow-wrap:anywhere;font-size:13px}dl{display:flex;gap:24px;flex-wrap:wrap;margin:16px 0}dl div{display:flex;gap:6px}dt{color:#53645f}dd{margin:0;font-weight:600}ol{list-style:none;padding:0;counter-reset:phase;margin:24px 0}li{counter-increment:phase;position:relative;padding:13px 0 13px 38px;border-bottom:1px solid #d8e1de}li:before{content:counter(phase);position:absolute;left:0;top:14px;width:25px;height:25px;text-align:center;border-radius:50%;background:#edf1ef;font-size:13px;line-height:25px}li[data-state=active]:before{background:#287556;color:white}li[data-state=done]:before{background:#dcebe3;color:#19563e}li[data-state=active] strong{color:#19563e}.step-state{font-size:12px;color:#53645f;float:right;margin-left:12px}.detail{display:block}.error{color:#a32b25!important}#stale{min-height:20px;margin-top:8px}details{margin:20px 0}summary{cursor:pointer}#events{padding-left:20px;font-size:13px}#events li{padding:3px 0;border:0}#events li:before{display:none}@media(max-width:480px){body{margin:22px auto;padding:0 16px}h1{font-size:25px}dl{gap:12px}.step-state{float:none;display:block;margin:2px 0}}
li[data-state=done]:before{content:'\2713';font-weight:700}
body.kb-approval .worker .timing,body.kb-approval .worker progress,body.kb-approval .worker #current,body.kb-approval .worker dl,body.kb-approval .worker #stale,body.kb-approval ol#phases,body.kb-approval details{display:none!important}
</style>
<body class="__APPROVAL_CLASS__">
<h1>AI-OS lokal verbinden</h1><p>Freigabe fuer <strong id="origin"></strong></p>
<p class="detail">Lokale Verarbeitung &middot; Keine Veroeffentlichung auf GitHub</p>
<p class="directory" id="directory">__APPROVAL_DETAIL__</p>
<button id="approve">__APPROVAL_LABEL__</button>
<section class="worker" aria-label="Verarbeitungsfortschritt"><div class="heading"><span id="status" role="status" aria-live="polite">Lokaler Dienst bereit</span><small id="phase">Wartet auf Freigabe</small></div>
<progress id="progress" max="100" value="0" aria-label="Fortschritt der aktuellen Phase"></progress>
<div class="timing"><span id="counter">Noch nicht gestartet</span><span id="elapsed">Laufzeit: 0 s</span><span id="updated">Noch keine Verarbeitung</span></div>
<p id="current"></p><dl><div><dt>Ausgewertet</dt><dd id="evaluated">0</dd></div><div><dt>Teilweise</dt><dd id="partial">0</dd></div><div><dt>Uebersprungen</dt><dd id="skipped">0</dd></div></dl>
<dl aria-label="Erkannte Themen und Zuordnungen"><div><dt>Themen mit Beleg</dt><dd id="topics-found">0</dd></div><div><dt>Textzuordnungen</dt><dd id="text-assignments">0</dd></div><div><dt>Verweiszuordnungen</dt><dd id="reference-assignments">0</dd></div><div><dt>Dokumente mit Thema</dt><dd id="topic-documents">0</dd></div></dl>
<p id="topic-audit" class="detail"></p><p id="topic-labels" class="detail"></p>
<p id="stale" class="detail" role="status"></p></section>
__TOPIC_BUILD__
<ol id="phases">
<li><span class="step-state">Ausstehend</span><strong>Bestand erfassen</strong><span class="detail">Ordner und Dateien auflisten.</span></li>
<li><span class="step-state">Ausstehend</span><strong>Inhalte lesen</strong><span class="detail">Unterstuetzte Dateien auslesen; andere mit Begruendung auslassen.</span></li>
<li><span class="step-state">Ausstehend</span><strong>Themen zuordnen</strong><span class="detail">Textbelege und dokumentierte Verweise pruefen.</span></li>
<li><span class="step-state">Ausstehend</span><strong>Wissensindex pruefen</strong><span class="detail">Dateipfade, Originalhashes und Zuordnungsbelege validieren.</span></li>
<li><span class="step-state">Ausstehend</span><strong>Landkarte bereitstellen</strong><span class="detail">Geprueften Index an die verbundene App uebergeben.</span></li>
</ol><details><summary>Verarbeitungsprotokoll</summary><ul id="events"></ul></details>
<script>
const target=__ORIGIN__;const returnTarget=__RETURN__;const headers={'X-Pairing':'__PAIRING__'};
const element=id=>document.getElementById(id);const steps=[...element('phases').children];const labels=steps.map(step=>step.querySelector('strong').textContent);
let latest=null;let polling=false;let active=false;
element('origin').textContent=target;
function duration(seconds){return seconds<60?seconds+' s':Math.floor(seconds/60)+' min '+seconds%60+' s';}
function zurichTime(value){return new Intl.DateTimeFormat('de-CH',{timeZone:'Europe/Zurich',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',timeZoneName:'short',hour12:false}).format(new Date(value));}
function timing(){if(!latest||!latest.started)return;const now=Date.now();element('elapsed').textContent='Laufzeit: '+duration(Math.max(0,Math.floor((now-Date.parse(latest.started))/1000)));const age=Math.max(0,Math.floor((now-Date.parse(latest.updated))/1000));element('updated').textContent='Letzte Meldung vor '+duration(age);if(active)element('stale').textContent=age>=15?'Seit '+duration(age)+' keine neue Fortschrittsmeldung. Der aktuelle Arbeitsschritt ist noch nicht abgeschlossen.':'';}
function render(result){latest=result;active=result.state==='running';element('approve').disabled=active;const phase=result.phase||0;const done=result.state==='completed';element('stale').classList.remove('error');element('status').classList.toggle('error',result.state==='failed');element('status').textContent=result.state==='failed'?result.error:done?'Index bereit':phase?labels[phase-1]:'Verzeichnis auswaehlen';element('phase').textContent=phase?'Phase '+phase+' von 5':active?'Ordnerauswahl offen':'Wartet auf Freigabe';if(result.directory)element('directory').textContent=result.directory;const known=result.total>0;if(known){const percent=Math.min(100,Math.floor(result.processed/result.total*100));element('progress').value=percent;element('counter').textContent=result.processed+' / '+result.total+(phase===3?' Zuordnungsschritte':' Dateien')+' \u00b7 '+percent+' % dieser Phase';}else{element('progress').removeAttribute('value');element('counter').textContent=phase===1?result.processed+' Dateien gefunden \u00b7 Gesamtzahl wird ermittelt':phase===0?'Bitte lokale Ordnerauswahl abschliessen':'Abschluss wird vorbereitet';}if(done||result.state==='failed'){element('progress').value=done?100:0;if(done)element('counter').textContent='Verarbeitung abgeschlossen';}element('current').textContent=result.current?'Aktuell: '+result.current:'';for(const key of ['evaluated','partial','skipped'])if(result[key]!==undefined)element(key).textContent=result[key];steps.forEach((step,index)=>{const state=done||index+1<phase?'done':index+1===phase?'active':'pending';step.dataset.state=state;step.querySelector('.step-state').textContent=state==='done'?'Abgeschlossen':state==='active'?(result.state==='failed'?'Fehlgeschlagen':'In Arbeit'):'Ausstehend';});element('events').replaceChildren();for(const event of result.events||[]){const item=document.createElement('li');item.textContent=new Date(event.at).toLocaleTimeString()+' \u00b7 '+(event.state==='failed'?'Fehlgeschlagen':event.state==='completed'?'Index bereit':event.phase?labels[event.phase-1]:'Freigabe gestartet');element('events').append(item);}timing();}
async function request(path,method='GET'){const response=await fetch(path,{method,headers,cache:'no-store',signal:AbortSignal.timeout(20000)});const result=await response.json();if(!response.ok)throw Error(result.error||'Lokaler Dienst antwortet mit HTTP '+response.status);return result;}
function renderTopicProgress(result){renderTopicBuild(result);for(const [id,key] of [['topics-found','topicsFound'],['text-assignments','textAssignments'],['reference-assignments','referenceAssignments'],['topic-documents','documentsWithTopics']])element(id).textContent=result[key]??0;const separator=' \u00b7 ';element('topic-audit').textContent=(result.topicCandidates||0)+' Themenregeln'+separator+(result.rulesChecked||0)+' Regelpruefungen'+separator+(result.linksChecked||0)+' Dateiverweise geprueft';element('topic-labels').textContent=result.topicLabels?.length?'Zuletzt erkannt: '+result.topicLabels.slice(-3).join(separator):'Noch keine Themen mit Beleg';element('current').textContent=(result.detail?result.detail+'. ':'')+(result.current?'Aktuell: '+result.current:'');}
function renderZurichEvents(result){const items=[...element('events').children];(result.events||[]).forEach((event,index)=>{if(items[index])items[index].textContent=zurichTime(event.at)+' \u00b7 '+(event.state==='failed'?'Fehlgeschlagen':event.state==='completed'?'Index bereit':event.phase?labels[event.phase-1]:'Freigabe gestartet');});}
async function poll(){if(polling)return;polling=true;try{const result=await request('/progress');if(result.state==='idle')return;render(result);renderTopicProgress(result);if(result.state==='completed'&&result.token){location.replace(returnTarget+'#ai-os-token='+encodeURIComponent(result.token));return;}if(result.state==='running')setTimeout(poll,750);}catch(error){element('stale').textContent='Statusabfrage unterbrochen: '+error.message+'. Verarbeitung kann weiterlaufen; erneuter Versuch folgt.';element('stale').classList.add('error');if(active)setTimeout(poll,1500);}finally{polling=false;}}
const renderWithLocalTime=render;render=result=>{renderWithLocalTime(result);renderZurichEvents(result);};
element('approve').onclick=async()=>{element('approve').disabled=true;element('stale').classList.remove('error');try{render(await request('/approve','POST'));poll();}catch(error){element('status').textContent=error.message;element('status').classList.add('error');element('approve').disabled=false;}};
setInterval(timing,1000);poll();
</script></body></html>
'@
                $topicBuild = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'topic-progress.html'))
                if ($knowledgeMode) {
                    $approvalLabel = 'Wissensbasis verbinden'
                    $approvalDetail = 'Der vorhandene Store wird ausschliesslich ueber die lokale wb-Zugriffsschicht gelesen. Kein Verzeichnis wird indexiert.'
                    $approvalClass = 'kb-approval'
                } else {
                    $approvalLabel = if ($Root) { 'Verzeichnis freigeben' } elseif ($ConfigurationPath) { 'Quellenregister einlesen' } else { 'Quellen freigeben' }
                    $approvalDetail = if ($Root) { 'Das angegebene Verzeichnis wird nach der Freigabe gelesen.' } elseif ($ConfigurationPath) { 'Die lokale Quellenkonfiguration wird eingelesen; weitere Verzeichnisse werden nicht freigegeben.' } else { 'Das lokale Quellenregister dieses Rechners wird eingelesen; bei leerem Register oeffnet sich eine Ordnerauswahl.' }
                    $approvalClass = ''
                }
                $script:token = ''
                $script:expires = [DateTime]::MinValue
                $script:workProgress = @{ state = 'idle'; phase = 0; processed = 0; total = -1 }
                $html = $html.Replace('__ORIGIN__', $target.Replace('<', '\u003c')).Replace('__RETURN__', $returnTarget.Replace('<', '\u003c')).Replace('__PAIRING__', $nonce).Replace('__TOPIC_BUILD__', $topicBuild).Replace('__APPROVAL_LABEL__', $approvalLabel).Replace('__APPROVAL_DETAIL__', $approvalDetail).Replace('__APPROVAL_CLASS__', $approvalClass)
                Send-Response $context 200 $html 'text/html; charset=utf-8'
                continue
            }
            if ($path -eq '/progress' -and $request.HttpMethod -eq 'GET' -and ($requestOrigin -eq $localOrigin -or -not $requestOrigin) -and $request.Headers['X-Pairing'] -eq $nonce) {
                Send-Response $context 200 (Get-IndexProgress)
                continue
            }
            if ($path -eq '/approve' -and $request.HttpMethod -eq 'POST' -and $requestOrigin -eq $localOrigin -and $request.Headers['X-Pairing'] -eq $nonce) {
                if ($worker) { Send-Response $context 409 '{"error":"Indexaufbau laeuft bereits"}'; continue }
                if ($knowledgeMode) {
                    $snapshot = Get-KnowledgeSession -Refresh
                    $random = [byte[]]::new(32)
                    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
                    try { $rng.GetBytes($random) } finally { $rng.Dispose() }
                    $script:token = [Convert]::ToBase64String($random)
                    $script:expires = [DateTime]::UtcNow.AddHours(8)
                    $now = [DateTime]::UtcNow.ToString('o')
                    $script:workProgress = @{ state = 'completed'; phase = 5; processed = 1; total = 1; started = $now; updated = $now; directory = $snapshot.directory; detail = 'Wissensbasis-Store ueber wb gelesen; keine Verzeichnisindexierung.'; evaluated = $snapshot.inventory.store.items; partial = 0; skipped = 0 }
                    Send-Response $context 202 (Get-IndexProgress)
                    continue
                }
                if (-not $fixedRoot) { $Root = '' }
                Start-IndexWorker
                Send-Response $context 202 (Get-IndexProgress)
                continue
            }
            if ($requestOrigin -ne $Origin -or -not $token -or $request.Headers['Authorization'] -cne "Bearer $token" -or [DateTime]::UtcNow -gt $expires) {
                Send-Response $context 403 '{"error":"Keine gueltige lokale Freigabe"}'
                continue
            }
            if ($knowledgeMode -and $path -eq '/kb/search' -and $request.HttpMethod -eq 'GET') {
                $query = [string]$request.QueryString['q']
                if ($query.Length -gt 300) { Send-Response $context 400 '{"error":"Suchanfrage zu lang"}'; continue }
                $wordCount = @($query.Trim() -split '\s+' | Where-Object { $_ }).Count
                if ($wordCount -gt 12) { Send-Response $context 400 '{"error":"Hoechstens 12 Suchwoerter pro Anfrage"}'; continue }
                if (-not $query.Trim()) { Send-Response $context 400 '{"error":"Leere Suchanfrage"}'; continue }
                try {
                    $result = Get-KnowledgeSearch $query
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 12 -Compress)
                } catch { Send-Response $context 500 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/kb/evidence' -and $request.HttpMethod -eq 'GET') {
                $versionId = [string]$request.QueryString['version']
                if (-not $versionId) { Send-Response $context 400 '{"error":"Fassungs-ID fehlt"}'; continue }
                try {
                    $result = Get-KnowledgeEvidence $versionId
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 16 -Compress)
                } catch { Send-Response $context 404 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/kb/ask' -and $request.HttpMethod -eq 'POST') {
                try {
                    $body = Read-JsonRequest $context 30000
                    $question = [string]$body.question
                    if (-not $question.Trim()) { Send-Response $context 400 '{"error":"Frage fehlt"}'; continue }
                    if ($question.Length -gt 2000) { Send-Response $context 400 '{"error":"Frage zu lang"}'; continue }
                    $history = @($body.history)
                    $knowledgeId = [string]$body.knowledgeId
                    $result = Get-KnowledgeAsk $question $history $knowledgeId ([string]$body.gapId)
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 14 -Compress)
                } catch { Send-Response $context 500 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/kb/review' -and $request.HttpMethod -eq 'POST') {
                try {
                    $body = Read-JsonRequest $context 30000
                    $knowledgeId = [string]$body.knowledgeId
                    $versionId = [string]$body.versionId
                    $decision = [string]$body.decision
                    $note = [string]$body.note
                    $basisHash = [string]$body.basisHash
                    $checks = @($body.checks)
                    if (-not $knowledgeId -or -not $versionId) { throw 'Wissensseite oder Fassung fehlt.' }
                    $result = Invoke-KnowledgeReview $knowledgeId $versionId $decision $note $basisHash $checks
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 10 -Compress)
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/kb/revision' -and $request.HttpMethod -eq 'POST') {
                try {
                    $body = Read-JsonRequest $context 400000
                    $knowledgeId = [string]$body.knowledgeId
                    $baseVersionId = [string]$body.baseVersionId
                    $revisionBody = [string]$body.body
                    $reason = [string]$body.reason
                    $basisHash = [string]$body.basisHash
                    $result = Invoke-KnowledgeRevision $knowledgeId $baseVersionId $revisionBody $reason $basisHash
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 10 -Compress)
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/kb/version' -and $request.HttpMethod -eq 'GET') {
                $versionId = [string]$request.QueryString['version']
                if (-not $versionId) { Send-Response $context 400 '{"error":"Fassungs-ID fehlt"}'; continue }
                try {
                    $result = Invoke-Wb @('knowledge', 'version', $versionId)
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 12 -Compress)
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/workspace/select' -and $request.HttpMethod -eq 'POST') {
                try {
                    $body = Read-JsonRequest $context 8192
                    $workspaceId = [string]$body.id
                    $snapshot = Switch-Workspace $workspaceId
                    Send-Response $context 200 ($snapshot | ConvertTo-Json -Depth 20 -Compress)
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/poc/path' -and $request.HttpMethod -eq 'POST') {
                try {
                    $null = Read-JsonRequest $context 8192
                    $result = Select-PocBasePath
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 15 -Compress)
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/poc/state' -and $request.HttpMethod -eq 'GET') {
                try {
                    $result = Get-IngestionJob
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 15 -Compress)
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/poc/run' -and $request.HttpMethod -eq 'POST') {
                try {
                    $body = Read-JsonRequest $context 8192
                    $confirmExternalAi = [bool]$body.confirmExternalAi
                    $resume = [bool]$body.resume
                    $result = Start-IngestionJob -ConfirmExternalAi $confirmExternalAi -Resume:$resume
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 15 -Compress)
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/poc/resume' -and $request.HttpMethod -eq 'POST') {
                try {
                    $body = Read-JsonRequest $context 8192
                    $confirmExternalAi = [bool]$body.confirmExternalAi
                    $result = Resume-IngestionJob -ConfirmExternalAi $confirmExternalAi
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 15 -Compress)
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/kb/gap/inspect' -and $request.HttpMethod -eq 'POST') {
                try {
                    $body = Read-JsonRequest $context 16384
                    $result = Inspect-IngestionGap ([string]$body.text) ([string]$body.query) ([string]$body.gapId) ([string]$body.question) ([string]$body.pageId)
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 12 -Compress)
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/kb/gap/add-file' -and $request.HttpMethod -eq 'POST') {
                try {
                    $body = Read-JsonRequest $context 60000000
                    $result = Add-IngestionGapFile ([string]$body.name) ([string]$body.contentBase64) ([string]$body.gapId) ([string]$body.text) ([string]$body.question)
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 12 -Compress)
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/kb/gap/link' -and $request.HttpMethod -eq 'POST') {
                try {
                    $body = Read-JsonRequest $context 16384
                    $result = Add-IngestionGapLink ([string]$body.url) ([string]$body.gapId) ([string]$body.label) ([string]$body.question)
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 8 -Compress)
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/kb/gap/links' -and $request.HttpMethod -eq 'GET') {
                try {
                    $pathValue = Get-GapStatePath 'gap-links.json'
                    $links = if (Test-Path -LiteralPath $pathValue -PathType Leaf) { (Get-Content -LiteralPath $pathValue -Raw -Encoding UTF8 | ConvertFrom-Json).links } else { @() }
                    Send-Response $context 200 (@{ links = @($links) } | ConvertTo-Json -Depth 8 -Compress)
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/kb/gap/records' -and $request.HttpMethod -eq 'GET') {
                try {
                    Send-Response $context 200 (@{ records = @(Read-GapRecords) } | ConvertTo-Json -Depth 12 -Compress)
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($knowledgeMode -and $path -eq '/kb/original' -and $request.HttpMethod -eq 'GET') {
                $itemId = [string]$request.QueryString['item']
                if (-not $itemId) { Send-Response $context 400 '{"error":"Item-ID fehlt"}'; continue }
                $originalDirectory = $null
                try {
                    [IO.Directory]::CreateDirectory($temporary) | Out-Null
                    $originalDirectory = Join-Path $temporary ('kb-original-' + [guid]::NewGuid().ToString('N'))
                    [IO.Directory]::CreateDirectory($originalDirectory) | Out-Null
                    $original = Invoke-Wb @('original', $itemId, '--out', $originalDirectory)
                    $target = [string]$original.target
                    if (-not $target -or -not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'Original wurde nicht bereitgestellt.' }
                    $response = $context.Response
                    $response.Headers['Access-Control-Allow-Origin'] = $Origin
                    $response.Headers['Cache-Control'] = 'no-store'
                    $response.Headers['X-Content-Type-Options'] = 'nosniff'
                    $response.Headers['Content-Disposition'] = "attachment; filename*=UTF-8''" + [Uri]::EscapeDataString([IO.Path]::GetFileName($target))
                    $response.ContentType = 'application/octet-stream'
                    $stream = [IO.File]::OpenRead($target)
                    try { $response.ContentLength64 = $stream.Length; $stream.CopyTo($response.OutputStream) } finally { $stream.Dispose(); $response.Close() }
                } catch {
                    Send-Response $context 404 (@{ error = ('Original nicht verfuegbar: ' + $_.Exception.Message) } | ConvertTo-Json -Compress)
                } finally {
                    if ($originalDirectory -and (Test-Path -LiteralPath $originalDirectory)) { Remove-Item -LiteralPath $originalDirectory -Recurse -Force -ErrorAction SilentlyContinue }
                }
                continue
            }
            if ($knowledgeMode -and $path -notin @('/session','/status','/progress','/refresh','/disconnect','/kb/search','/kb/evidence','/kb/ask','/kb/review','/kb/revision','/kb/version','/workspace/select','/poc/state','/poc/run','/poc/resume','/poc/path','/kb/gap/inspect','/kb/gap/add-file','/kb/gap/link','/kb/gap/links','/kb/gap/records','/kb/original')) {
                Send-Response $context 404 '{"error":"Nur Wissensbasis-Routen im Store-Modus"}'
                continue
            }
            if ($path -eq '/document' -and $request.HttpMethod -eq 'GET') {
                $documentPath = $request.QueryString['path']
                if (-not $documentPath -or -not $documents.ContainsKey($documentPath)) { Send-Response $context 404 '{"error":"Dokument nicht im freigegebenen Index"}'; continue }
                $document = $documents[$documentPath]
                $result = @{ path = $document.path; title = $document.title; status = $document.status; reason = $document.reason; extraction = $document.extraction; text = $document.text; modified = $document.modified; headings = @(Get-DocumentHeadings $document.text); documentState = (Get-ReaderFileState $documentPath); canEditInCode = ([IO.Path]::GetExtension($documentPath).ToLowerInvariant() -in @('.md', '.txt', '.json', '.yaml', '.yml', '.csv', '.html', '.htm', '.xml', '.eml')) }
                $source = $sourceConfiguration.sources | Where-Object { [string]$_.id -eq [string]$document.sourceId } | Select-Object -First 1
                $result.source = if ($source) { Get-LiveSourceState $source } else { $null }
                $result.space = $document.space
                $result.citation = $document.citation
                $result.targetFile = if ($source -and $source.path) { Join-Path $source.path $document.relativePath } else { $null }
                $result.canEditInCode = $result.canEditInCode -and [bool]$source.write -and $result.source.reachable -eq 'reachable'
                Send-Response $context 200 ($result | ConvertTo-Json -Depth 8 -Compress)
                continue
            }
            if ($path -eq '/search' -and $request.HttpMethod -eq 'GET') {
                $query = [string]$request.QueryString['q']
                if ($query.Length -gt 300) { Send-Response $context 400 '{"error":"Suchanfrage zu lang"}'; continue }
                $terms = @($query.Trim() -split '\s+' | Where-Object { $_ } | Select-Object -Unique)
                if ($terms.Count -gt 12) { Send-Response $context 400 '{"error":"Hoechstens 12 Suchwoerter pro Anfrage"}'; continue }
                $results = [Collections.Generic.List[object]]::new()
                if ($terms.Count) {
                    foreach ($document in ($documents.Values | Sort-Object path)) {
                        if (-not $document.text -or $document.missing) { continue }
                        $positions = @($terms | ForEach-Object { $document.text.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) })
                        if (@($positions | Where-Object { $_ -lt 0 }).Count) { continue }
                        $snippets = @()
                        for ($termIndex = 0; $termIndex -lt [Math]::Min(3, $terms.Count); $termIndex++) {
                            $offset = $positions[$termIndex]
                            $start = [Math]::Max(0, $offset - 90)
                            $length = [Math]::Min(250, $document.text.Length - $start)
                            $snippets += @{ text = $document.text.Substring($start, $length); start = $start; offset = $offset; length = $terms[$termIndex].Length }
                        }
                        $source = $sourceConfiguration.sources | Where-Object id -eq $document.sourceId | Select-Object -First 1
                        $results.Add(@{ path = $document.path; status = $document.status; sourceId = $document.sourceId; citation = $document.citation; source = (Get-LiveSourceState $source); snippets = $snippets })
                    }
                }
                Send-Response $context 200 (@{ query = $query; results = @($results.ToArray()) } | ConvertTo-Json -Depth 8 -Compress)
                continue
            }
            if ($path -eq '/original' -and $request.HttpMethod -eq 'GET') {
                try { $absolute = Get-ApprovedOriginal $request.QueryString['path'] } catch { Send-Response $context 403 (@{ error = 'Original nicht verfuegbar: ' + $_.Exception.Message } | ConvertTo-Json -Compress); continue }
                $response = $context.Response
                $response.Headers['Access-Control-Allow-Origin'] = $Origin
                $response.Headers['Cache-Control'] = 'no-store'
                $response.Headers['X-Content-Type-Options'] = 'nosniff'
                $response.Headers['Content-Disposition'] = "attachment; filename*=UTF-8''" + [Uri]::EscapeDataString([IO.Path]::GetFileName($absolute))
                $response.ContentType = 'application/octet-stream'
                $stream = [IO.File]::OpenRead($absolute)
                try { $response.ContentLength64 = $stream.Length; $stream.CopyTo($response.OutputStream) } finally { $stream.Dispose(); $response.Close() }
                continue
            }
            if ($path -in @('/open-original', '/open-code') -and $request.HttpMethod -eq 'POST') {
                try {
                    $absolute = Get-ApprovedOriginal -path $request.QueryString['path'] -AllowChanged
                    if ($path -eq '/open-code') {
                        $document = $documents[$request.QueryString['path']]
                        $source = $sourceConfiguration.sources | Where-Object { [string]$_.id -eq [string]$document.sourceId } | Select-Object -First 1
                        if (-not $source -or -not $source.write) { throw 'Schreiben nicht freigegeben' }
                        if ([IO.Path]::GetExtension($absolute).ToLowerInvariant() -notin @('.md', '.txt', '.json', '.yaml', '.yml', '.csv', '.html', '.htm', '.xml', '.eml')) { throw 'Kein freigegebenes Textformat' }
                        $code = @((Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'), (Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                        if (-not $code) { throw 'VS Code nicht gefunden' }
                        Start-Process -FilePath $code -ArgumentList ('--reuse-window -- "' + $absolute + '"') -ErrorAction Stop | Out-Null
                    } else {
                        if ([IO.Path]::GetExtension($absolute).ToLowerInvariant() -notin @('.md', '.txt', '.csv', '.pdf', '.docx', '.xlsx', '.pptx', '.doc', '.xls', '.ppt', '.eml', '.msg', '.rtf', '.odt', '.ods', '.odp', '.html', '.htm', '.json', '.yaml', '.yml', '.xml')) { throw 'Format nicht fuer Original-Oeffnen freigegeben' }
                        Start-Process -FilePath $absolute -ErrorAction Stop | Out-Null
                    }
                    Send-Response $context 200 '{"opened":true}'
                } catch { Send-Response $context 409 '{"error":"Original konnte nicht geoeffnet werden. Bitte aktualisieren oder Original herunterladen."}' }
                continue
            }
            if ($path -eq '/sources' -and $request.HttpMethod -eq 'GET') {
                $currentSnapshot = $snapshot | ConvertFrom-Json
                Send-Response $context 200 (@{ computer = $currentSnapshot.inventory.computer; sourceEditing = [bool]$script:sourceEditing; sources = @(Get-LiveSources) } | ConvertTo-Json -Depth 8 -Compress)
                continue
            }
            if ($path -in @('/sources/save', '/sources/remove') -and $request.HttpMethod -eq 'POST') {
                if (-not $script:sourceEditing) { Send-Response $context 409 '{"error":"Quellenverwaltung ist bei Start mit -Root nicht verfuegbar. Dienst ohne -Root starten."}'; continue }
                if ($worker) { Send-Response $context 409 '{"error":"Indexaufbau laeuft bereits; Quellen erst danach aendern"}'; continue }
                try {
                    $body = Read-JsonRequest $context
                    if ($path -eq '/sources/save') {
                        $fields = @{}
                        foreach ($property in $body.PSObject.Properties) {
                            if ($property.Name -notin @('id', 'name', 'space', 'type', 'path', 'read', 'write', 'connection')) { throw ('Unbekanntes Feld: ' + $property.Name + '. Rechnerabhaengige Angaben und Zugangsdaten bleiben in der lokalen Konfiguration.') }
                            $fields[$property.Name] = $property.Value
                        }
                        if (-not $fields.ContainsKey('read')) { throw 'Leserecht fehlt' }
                        if (-not $fields.ContainsKey('write')) { $fields['write'] = $false }
                        $saved = Save-SourceEntry $fields
                        $script:sourceConfiguration = Get-MergedSourceConfiguration
                        Start-IndexWorker -Refresh
                        Send-Response $context 202 (@{ saved = $true; source = (Get-SourceProbe $saved); progress = (Get-IndexProgress | ConvertFrom-Json) } | ConvertTo-Json -Depth 8 -Compress)
                    } else {
                        $id = [string]$body.id
                        if (-not $id) { throw 'Quellen-ID fehlt' }
                        if (-not (Remove-SourceEntry $id)) { Send-Response $context 404 '{"error":"Quelle nicht gefunden"}'; continue }
                        $remaining = @{}
                        foreach ($document in @($documents.Values | Where-Object { -not [string]::Equals([string]$_.sourceId, $id, [StringComparison]::OrdinalIgnoreCase) })) { $remaining[$document.path] = $document }
                        $script:documents = $remaining
                        $script:sourceConfiguration = Get-MergedSourceConfiguration
                        Start-IndexWorker -Refresh
                        Send-Response $context 202 (@{ removed = $true; progress = (Get-IndexProgress | ConvertFrom-Json) } | ConvertTo-Json -Depth 8 -Compress)
                    }
                } catch { Send-Response $context 400 (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
                continue
            }
            if ($path -eq '/session' -and $request.HttpMethod -eq 'GET') {
                if ($knowledgeMode) {
                    Send-Response $context 200 ((Get-KnowledgeSession) | ConvertTo-Json -Depth 20 -Compress)
                    continue
                }
                $currentSnapshot = $snapshot | ConvertFrom-Json
                $currentSnapshot.inventory.sources = @(Get-LiveSources)
                $currentSnapshot | Add-Member -NotePropertyName sourceEditing -NotePropertyValue ([bool]$script:sourceEditing) -Force
                Send-Response $context 200 ($currentSnapshot | ConvertTo-Json -Depth 20 -Compress)
            }
            elseif ($path -eq '/status' -and $request.HttpMethod -eq 'GET') {
                if ($knowledgeMode) {
                    $kb = Get-KnowledgeSession
                    $store = $kb.inventory.store
                    $result = @{
                        connected = $true
                        revision = $kb.revision
                        directorySyncedAt = $kb.directorySyncedAt
                        processing = $false
                        processingState = 'idle'
                        computer = $kb.inventory.computer
                        sourceEditing = $false
                        sources = @($kb.inventory.sources)
                        store = $store
                    }
                    Send-Response $context 200 ($result | ConvertTo-Json -Depth 12 -Compress)
                    continue
                }
                $null = Get-IndexProgress
                Check-ReaderChanges $request.QueryString['path']
                $currentSnapshot = $snapshot | ConvertFrom-Json
                $result = @{ connected = $true; revision = $currentSnapshot.revision; directorySyncedAt = $directorySyncedAt; processing = [bool]$worker; processingState = $workProgress.state; error = $workProgress.error; computer = $currentSnapshot.inventory.computer; sourceEditing = [bool]$script:sourceEditing }
                $result.sources = @(Get-LiveSources)
                if ($request.QueryString['path']) { $result.documentState = Get-ReaderFileState $request.QueryString['path'] }
                Send-Response $context 200 ($result | ConvertTo-Json -Depth 8 -Compress)
            }
            elseif ($knowledgeMode -and $path -eq '/progress' -and $request.HttpMethod -eq 'GET') { Send-Response $context 200 (Get-IndexProgress) }
            elseif ($path -eq '/progress' -and $request.HttpMethod -eq 'GET' -and $workKind -eq 'refresh') { Send-Response $context 200 (Get-IndexProgress) }
            elseif ($path -eq '/refresh' -and $request.HttpMethod -eq 'POST') {
                if ($knowledgeMode) {
                    $kb = Get-KnowledgeSession -Refresh
                    $now = [DateTime]::UtcNow.ToString('o')
                    $script:workProgress = @{ state = 'completed'; phase = 5; processed = 1; total = 1; started = $now; updated = $now; directory = $kb.directory; detail = 'Wissensbasis-Store neu gelesen; kein erneuter Import.'; evaluated = $kb.inventory.store.items; partial = 0; skipped = 0 }
                    Send-Response $context 200 (Get-IndexProgress)
                    continue
                }
                if ($worker) { Send-Response $context 409 '{"error":"Indexaufbau laeuft bereits"}'; continue }
                Start-IndexWorker -Refresh
                Send-Response $context 202 (Get-IndexProgress)
            }
            elseif ($path -eq '/disconnect' -and $request.HttpMethod -eq 'POST') {
                Stop-ReaderWatcher
                if ($worker) { Remove-Job -Job $worker -Force; $worker = $null }
                $token = ''; $snapshot = $null; $documents = @{}; $sourceConfiguration = $null; $observedChanges = @{}; $pendingReconciliation = $false; $nonce = [Guid]::NewGuid().ToString('N')
                $knowledgeSnapshot = $null; $knowledgeRevision = ''
                $workProgress = @{ state = 'idle'; phase = 0; processed = 0; total = -1 }
                if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
                Send-Response $context 200 '{}'
            } else { Send-Response $context 404 '{"error":"Route nicht vorhanden"}' }
        } catch {
            Write-Warning 'Lokale Anfrage fehlgeschlagen; keine Inhalte werden protokolliert.'
            try { Send-Response $context 500 '{"error":"Lokales Lesen fehlgeschlagen. Verzeichnis und Leserechte pruefen."}' } catch { }
        }
    }
} finally {
    Stop-ReaderWatcher
    $listener.Close()
    if ($worker) { Remove-Job -Job $worker -Force }
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
