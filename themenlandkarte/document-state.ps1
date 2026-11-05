function Get-ReaderHistoryPath([string]$Directory) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Directory.TrimEnd('\').ToLowerInvariant()))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
    $stateDirectory = Join-Path $env:LOCALAPPDATA 'AI-OS\Themenlandkarte\state'
    [IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
    Join-Path $stateDirectory ($key + '.json')
}

function Save-ReaderHistory([string]$Directory, [hashtable]$Documents, [string]$DirectorySyncedAt) {
    $destination = Get-ReaderHistoryPath $Directory
    $pending = $destination + '.' + [guid]::NewGuid().ToString('N') + '.pending'
    $historyByPath = @{}
    if (Test-Path -LiteralPath $destination) {
        foreach ($previous in ((Get-Content -LiteralPath $destination -Raw -Encoding UTF8 | ConvertFrom-Json).documents)) { $historyByPath[$previous.path] = $previous }
    }
    foreach ($document in $Documents.Values) { $historyByPath[$document.path] = $document }
    $metadata = @($historyByPath.Values | Sort-Object path | Select-Object path, name, status, hash, sourceHash, modified, indexedModified, evaluatedAt, processingState, error)
    $json = @{ directorySyncedAt = $DirectorySyncedAt; documents = $metadata } | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::WriteAllText($pending, $json, [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($destination)) { [IO.File]::Replace($pending, $destination, [Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($pending, $destination) }
}

function Stop-ReaderWatcher {
    if ($script:directoryWatcher) { $script:directoryWatcher.EnableRaisingEvents = $false; $script:directoryWatcher.Dispose(); $script:directoryWatcher = $null }
    foreach ($eventId in @($script:watchEventIds)) {
        Unregister-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue
        Get-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    }
    $script:watchEventIds = @()
}

function Start-ReaderWatcher {
    Stop-ReaderWatcher
    $script:directoryWatcher = [IO.FileSystemWatcher]::new($script:Root)
    $script:directoryWatcher.IncludeSubdirectories = $true
    $script:directoryWatcher.NotifyFilter = [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::DirectoryName -bor [IO.NotifyFilters]::Size
    $script:directoryWatcher.InternalBufferSize = 32768
    $script:watchEventIds = @()
    foreach ($eventName in @('Changed', 'Created', 'Deleted', 'Renamed', 'Error')) {
        $eventId = 'ai-os-reader-' + [guid]::NewGuid().ToString('N')
        Register-ObjectEvent -InputObject $script:directoryWatcher -EventName $eventName -SourceIdentifier $eventId | Out-Null
        $script:watchEventIds += $eventId
    }
    $script:directoryWatcher.EnableRaisingEvents = $true
}

function Get-ReaderFileState([string]$Path) {
    if (-not $script:documents.ContainsKey($Path)) { return @{ path = $Path; state = 'missing'; error = 'Dokument nicht im freigegebenen Index' } }
    $document = $script:documents[$Path]
    $result = @{
        path = $Path; sourceModified = $null; sourceHash = $null
        indexedModified = $document.indexedModified; indexedHash = $document.hash; evaluatedAt = $document.evaluatedAt
        directorySyncedAt = $script:directorySyncedAt; state = $document.processingState; stale = $false; error = $document.error
        checkedAt = [DateTime]::UtcNow.ToString('o')
    }
    try {
        $absolute = Get-ApprovedOriginal -path $Path -AllowChanged
        $entry = Get-Item -LiteralPath $absolute -Force
        $result.sourceModified = $entry.LastWriteTimeUtc.ToString('o')
        if ($entry.Length -le 8MB) { $result.sourceHash = (Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant() }
        $result.stale = [bool]($document.hash -and $result.sourceHash -ne $document.hash)
        if ($result.stale -and $result.state -ne 'error') { $result.state = 'stale' }
        if ($script:worker) { $result.state = 'processing' }
        elseif ($result.stale -and $script:workProgress.state -eq 'failed') { $result.state = 'error'; $result.error = $script:workProgress.error }
    } catch { $result.state = 'error'; $result.stale = $true; $result.error = 'Quelldatei nicht mehr vorhanden oder nicht freigegeben' }
    $result
}

function Check-ReaderChanges([string]$DocumentPath) {
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rescan = $false
    foreach ($eventId in @($script:watchEventIds)) {
        foreach ($event in @(Get-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue)) {
            if ($event.SourceEventArgs -is [IO.ErrorEventArgs]) { $rescan = $true }
            else {
                foreach ($name in @($event.SourceEventArgs.Name, $event.SourceEventArgs.OldName)) {
                    if (-not $name) { continue }
                    $relative = $name.Replace('\', '/')
                    if ($relative -notmatch '(^|/)(\.git|node_modules|\.venv|venv|__pycache__|themenlandkarte)(/|$)') { $paths.Add($relative) | Out-Null }
                }
            }
            Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
        }
    }
    if ($DocumentPath -and $script:documents.ContainsKey($DocumentPath)) { $paths.Add($DocumentPath) | Out-Null }
    $changed = $rescan
    foreach ($path in $paths) {
        if (-not $script:documents.ContainsKey($path)) { $changed = $true; continue }
        $state = Get-ReaderFileState $path
        $fingerprint = [string]$state.sourceHash + '|' + [string]$state.sourceModified
        $previousFingerprint = [string]$script:documents[$path].sourceHash + '|' + [string]$script:documents[$path].modified
        if ($fingerprint -ne $previousFingerprint -and $script:observedChanges[$path] -ne $fingerprint) {
            $script:observedChanges[$path] = $fingerprint
            $changed = $true
        }
    }
    if ($changed) { $script:pendingReconciliation = $true }
    if ($script:pendingReconciliation -and -not $script:worker) {
        $script:pendingReconciliation = $false
        Start-IndexWorker -Refresh
    }
}