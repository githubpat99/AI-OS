$script:sourceTypes = @('directory', 'onedrive', 'network')
$script:sourceTypeLabels = @{ directory = 'Lokaler Ordner'; onedrive = 'OneDrive-Synchronisation'; network = 'Netzwerkordner' }
$script:sourceSpaces = @('business', 'private')

function Get-SourceConfigurationPath {
    if ($script:sourceConfigurationPath) { return [string]$script:sourceConfigurationPath }
    Join-Path $env:LOCALAPPDATA 'AI-OS\Themenlandkarte\config\sources.json'
}

function New-SourceId {
    ([guid]::NewGuid().ToString('N')).Substring(0, 12)
}

function Get-SourceTypeLabel([string]$Type) {
    if ($script:sourceTypeLabels.ContainsKey($Type)) { return $script:sourceTypeLabels[$Type] }
    'Unbekannter Typ'
}

function Get-SourcePrefix($Source) {
    if ($Source.flat) { '' } else { [string]$Source.id + '/' }
}

function Test-SameDirectory([string]$Left, [string]$Right) {
    if (-not $Left -or -not $Right) { return $false }
    [string]::Equals($Left.TrimEnd('\'), $Right.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

function Assert-SourceEntry($Entry, [string]$SelfId = '') {
    $id = [string]$Entry.id
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{1,63}$') { throw 'Quellen-ID: 2 bis 64 Zeichen aus Buchstaben, Ziffern, Bindestrich oder Unterstrich' }
    $name = ([string]$Entry.name).Trim()
    if (-not $name -or $name.Length -gt 120) { throw 'Anzeigename fehlt oder ist laenger als 120 Zeichen' }
    if ([string]$Entry.space -notin $script:sourceSpaces) { throw 'Wissensraum muss business oder private sein' }
    if ([string]$Entry.type -notin $script:sourceTypes) { throw 'Quellentyp muss directory, onedrive oder network sein' }
    if ($Entry.read -isnot [bool] -or $Entry.write -isnot [bool]) { throw 'Lese- und Schreibrecht muessen Wahrheitswerte sein' }
    if ($Entry.write -and -not $Entry.read) { throw 'Schreibrecht setzt Leserecht voraus' }
    $path = [string]$Entry.path
    if ($path) {
        if (-not [IO.Path]::IsPathRooted($path)) { throw 'Quellenpfade muessen absolut sein' }
        if ($path.Length -gt 500) { throw 'Quellenpfad ist zu lang' }
    }
    $connection = [string]$Entry.connection
    if ($connection.Length -gt 200) { throw 'Anbindungsbezeichnung ist zu lang' }
    if (-not $path -and -not $connection) { throw 'Quelle braucht lokalen Pfad oder Anbindung' }
    if ($Entry.credentialRef -and ([string]$Entry.credentialRef).Length -gt 200) { throw 'Zugangsdatenverweis ist zu lang' }
}

function Write-SourceConfiguration([string]$ConfigurationPath, $Configuration) {
    $destination = if ($ConfigurationPath) { $ConfigurationPath } else { Get-SourceConfigurationPath }
    [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
    $pending = $destination + '.' + [guid]::NewGuid().ToString('N') + '.pending'
    $json = $Configuration | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($pending, $json, [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($destination)) { [IO.File]::Replace($pending, $destination, [Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($pending, $destination) }
}

function Read-SourceConfiguration([string]$ConfigurationPath, [string]$Directory) {
    $path = if ($ConfigurationPath) { $ConfigurationPath } else { Get-SourceConfigurationPath }
    $configuration = $null
    if (Test-Path -LiteralPath $path) {
        try { $configuration = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { throw 'Lokale Quellenkonfiguration ist kein gueltiges JSON' }
        if (-not $configuration -or -not $configuration.computerId -or -not $configuration.computerName) { throw 'Rechnerkennung fehlt in lokaler Quellenkonfiguration' }
        $configuration.sources = @($configuration.sources)
        $kept = @()
        foreach ($source in $configuration.sources) {
            if (-not $source.id) { throw 'Quellen-ID fehlt in lokaler Quellenkonfiguration' }
            if ($source.legacy -eq $true -and -not ($source.PSObject.Properties.Name -contains 'flat')) { $source | Add-Member -NotePropertyName flat -NotePropertyValue $true -Force }
            Assert-SourceEntry $source
            $isCurrent = $Directory -and (Test-SameDirectory $source.path $Directory)
            if ($source.flat -and -not $isCurrent -and $source.path -and -not (Test-Path -LiteralPath $source.path)) { continue }
            foreach ($other in $kept) { if ([string]::Equals([string]$other.id, [string]$source.id, [StringComparison]::OrdinalIgnoreCase)) { throw 'Quellen-ID ist in lokaler Konfiguration doppelt' } }
            $kept += $source
        }
        if ($kept.Count -ne @($configuration.sources).Count) { $configuration.sources = $kept; Write-SourceConfiguration $ConfigurationPath $configuration }
        else { $configuration.sources = $kept }
    } elseif ($ConfigurationPath) { throw 'Angegebene lokale Quellenkonfiguration wurde nicht gefunden' }
    else {
        $configuration = [pscustomobject]@{ version = 1; computerId = ([guid]::NewGuid().ToString('N')); computerName = $env:COMPUTERNAME; sources = @() }
    }
    if ($Directory) {
        $directorySource = $configuration.sources | Where-Object { Test-SameDirectory $_.path $Directory } | Select-Object -First 1
        if (-not $directorySource) {
            $directorySource = [pscustomobject]@{
                id = (New-SourceId); name = (Split-Path $Directory -Leaf); space = 'business'; type = 'directory'
                path = $Directory; read = $true; write = $false; flat = $true
            }
            $configuration.sources = @($configuration.sources) + $directorySource
            Write-SourceConfiguration $ConfigurationPath $configuration
        }
        return [pscustomobject]@{ version = 1; computerId = $configuration.computerId; computerName = $configuration.computerName; sources = @($directorySource) }
    }
    $configuration
}

function Get-SavedSourceConfiguration {
    $configuration = Read-SourceConfiguration '' ''
    if (-not $configuration) { throw 'Lokale Quellenkonfiguration nicht lesbar' }
    $configuration
}

function Save-SourceEntry($Fields) {
    $configuration = Get-SavedSourceConfiguration
    $existing = $null
    if ($Fields.id) { $existing = $configuration.sources | Where-Object { [string]::Equals([string]$_.id, [string]$Fields.id, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1 }
    $entry = if ($existing) { $existing.PSObject.Copy() }
    else {
        [pscustomobject]@{
            id = if ($Fields.id) { [string]$Fields.id } else { New-SourceId }
            name = ''; space = ''; type = ''; path = $null; connection = $null
            read = $false; write = $false
        }
    }
    foreach ($key in @('name', 'space', 'type', 'connection')) { if ($Fields.ContainsKey($key)) { $entry | Add-Member -NotePropertyName $key -NotePropertyValue $Fields[$key] -Force } }
    if ($Fields.ContainsKey('path')) { $entry | Add-Member -NotePropertyName 'path' -NotePropertyValue $Fields['path'] -Force }
    foreach ($key in @('read', 'write')) { if ($Fields.ContainsKey($key)) { $entry | Add-Member -NotePropertyName $key -NotePropertyValue ([bool]$Fields[$key]) -Force } }
    Assert-SourceEntry $entry
    if (-not $entry.connection) { $entry | Add-Member -NotePropertyName connection -NotePropertyValue $null -Force }
    foreach ($other in $configuration.sources) {
        if (-not [string]::Equals([string]$other.id, [string]$entry.id, [StringComparison]::OrdinalIgnoreCase) -and $entry.flat -and $other.flat) { throw 'Nur eine Quelle darf direkt ohne Praefix eingebunden sein' }
    }
    if ($existing) { $replaced = $false; $configuration.sources = @(foreach ($other in $configuration.sources) { if ([string]::Equals([string]$other.id, [string]$entry.id, [StringComparison]::OrdinalIgnoreCase)) { $replaced = $true; $entry } else { $other } }) }
    else { $configuration.sources = @($configuration.sources) + $entry }
    Write-SourceConfiguration '' $configuration
    $entry
}

function Remove-SourceEntry([string]$Id) {
    $configuration = Get-SavedSourceConfiguration
    $match = $configuration.sources | Where-Object { [string]::Equals([string]$_.id, [string]$Id, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if (-not $match) { return $false }
    if (@($configuration.sources).Count -le 1) { throw 'Mindestens eine Quelle muss bestehen bleiben' }
    $configuration.sources = @($configuration.sources | Where-Object { -not [string]::Equals([string]$_.id, [string]$Id, [StringComparison]::OrdinalIgnoreCase) })
    Write-SourceConfiguration '' $configuration
    $true
}

function Get-SourceProbe($Source) {
    $probe = [pscustomobject]@{
        id = [string]$Source.id; name = [string]$Source.name; space = [string]$Source.space
        type = [string]$Source.type; typeLabel = Get-SourceTypeLabel ([string]$Source.type)
        path = if ($Source.path) { [string]$Source.path } else { $null }
        connection = if ($Source.connection) { [string]$Source.connection } else { $null }
        flat = [bool]$Source.flat; read = [bool]$Source.read; write = [bool]$Source.write
        reachable = 'unknown'; writeAccess = 'unknown'; checkedAt = [DateTime]::UtcNow.ToString('o')
        lastSuccess = $null; pending = $null; pendingBasis = 'unknown'; queued = $null; failed = 0; documents = 0
        updateState = 'unknown'; error = $null
    }
    if (-not $probe.read) {
        $probe.error = 'Lesen nicht freigegeben; Erreichbarkeit unbekannt'
        return $probe
    }
    if (-not $probe.path) {
        $probe.error = 'Keine lokale Anbindung hinterlegt; Zustand unbekannt'
        return $probe
    }
    if ($probe.type -notin $script:sourceTypes) {
        $probe.error = 'Quellentyp nicht implementiert; Zustand unbekannt'
        return $probe
    }
    try {
        $entry = Get-Item -LiteralPath $probe.path -Force -ErrorAction Stop
        if (-not $entry.PSIsContainer) { throw 'Kein Verzeichnis' }
        if ($entry.LinkType -in @('SymbolicLink', 'Junction')) { throw 'Symbolischer Verweis wird nicht verfolgt' }
        $enumerator = [IO.Directory]::EnumerateFileSystemEntries($probe.path).GetEnumerator()
        try { $null = $enumerator.MoveNext() } finally { if ($enumerator -is [IDisposable]) { $enumerator.Dispose() } }
        $probe.reachable = 'reachable'
    } catch {
        $probe.reachable = 'unreachable'
        $probe.error = 'Verzeichnis nicht erreichbar oder nicht lesbar: ' + $_.Exception.Message
    }
    $probe
}

function Get-SourceQueuedCount($Source) {
    if (-not $script:directoryWatcher) { return $null }
    $prefix = Get-SourcePrefix $Source
    $others = @()
    foreach ($other in @($script:sourceConfiguration.sources)) { if (-not $other.flat -and -not [string]::Equals([string]$other.id, [string]$Source.id, [StringComparison]::OrdinalIgnoreCase)) { $others += [string]$other.id + '/' } }
    $count = 0
    foreach ($key in @($script:observedChanges.Keys)) {
        if ($Source.flat) {
            $foreign = $false
            foreach ($otherPrefix in $others) { if ($key.StartsWith($otherPrefix, [StringComparison]::OrdinalIgnoreCase)) { $foreign = $true; break } }
            if (-not $foreign) { $count++ }
        } elseif ($key.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $count++ }
    }
    $count
}

function Get-LiveSourceState($Source) {
    if (-not $Source) { return $null }
    $probe = Get-SourceProbe $Source
    $state = [string]$Source.updateState
    if (-not $state) { $state = 'unknown' }
    $queued = Get-SourceQueuedCount $Source
    if ($probe.reachable -ne 'reachable') { $state = if ($Source.lastSuccess) { 'stale' } else { 'unknown' } }
    elseif ($script:worker) { $state = 'processing' }
    elseif ($null -ne $queued -and $queued -gt 0) { $state = 'stale' }
    if (-not $probe.error -and $Source.error) { $probe.error = [string]$Source.error }
    $probe.lastSuccess = if ($Source.lastSuccess) { [string]$Source.lastSuccess } else { $null }
    $probe.pending = if ($null -ne $Source.pending) { [int]$Source.pending } else { $null }
    $probe.pendingBasis = if ($null -ne $probe.pending) { 'index' } else { 'unknown' }
    $probe.queued = $queued
    $probe.documents = if ($null -ne $Source.documents) { [int]$Source.documents } else { 0 }
    $probe.failed = if ($null -ne $Source.failed) { [int]$Source.failed } else { 0 }
    $probe.updateState = $state
    $probe
}

function Get-LiveSources {
    if (-not $script:sourceConfiguration) { return @() }
    foreach ($source in @($script:sourceConfiguration.sources)) { Get-LiveSourceState $source }
}

function Invoke-SourceIndex($Configuration, [string]$BuildPath, [string]$OutputDirectory, [scriptblock]$OnProgress) {
    $previousDocuments = @()
    $previousPath = Join-Path $OutputDirectory 'previous.json'
    if (Test-Path -LiteralPath $previousPath) { $previousDocuments = @((Get-Content -LiteralPath $previousPath -Raw -Encoding UTF8 | ConvertFrom-Json)) }
    $previousInventory = $null
    $inventoryPath = Join-Path $OutputDirectory 'previous-inventory.json'
    if (Test-Path -LiteralPath $inventoryPath) { $previousInventory = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    $files = @(); $allDocuments = @(); $sources = @(); $topics = @{}; $excluded = @(); $method = ''
    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($source in @($Configuration.sources)) {
        $probe = Get-SourceProbe $source
        $prefix = Get-SourcePrefix $source
        $cachedFiles = @($previousInventory.files | Where-Object { $_.sourceId -eq $source.id })
        $cachedDocuments = @($previousDocuments | Where-Object { $_.path -and $_.sourceId -eq $source.id })
        $lastSource = $previousInventory.sources | Where-Object { $_.id -eq $source.id } | Select-Object -First 1
        $lastSuccess = if ($lastSource) { $lastSource.lastSuccess } else { $null }
        $pending = $null; $failed = 0; $updateState = 'unknown'
        if ($probe.reachable -eq 'reachable') {
            try {
                $sourceOutput = Join-Path $OutputDirectory ('source-' + $source.id)
                [IO.Directory]::CreateDirectory($sourceOutput) | Out-Null
                $cachePath = Join-Path $sourceOutput 'previous.json'
                if ($cachedDocuments.Count) {
                    $localDocuments = foreach ($document in $cachedDocuments) { $copy = $document.PSObject.Copy(); $copy.path = $document.relativePath; $copy }
                    [IO.File]::WriteAllText($cachePath, ($localDocuments | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
                } else {
                    $historyPath = Get-ReaderHistoryPath $source.path
                    if (Test-Path -LiteralPath $historyPath) {
                        $history = Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        [IO.File]::WriteAllText($cachePath, (ConvertTo-Json -InputObject @($history.documents) -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
                    }
                }
                & $BuildPath -Root $source.path -OutputDirectory $sourceOutput -PreviousDocumentsPath $cachePath -OnProgress $OnProgress | Out-Null
                $inventory = Get-Content -LiteralPath (Join-Path $sourceOutput 'inventory.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                $sourceDocuments = @((Get-Content -LiteralPath (Join-Path $sourceOutput 'documents.json') -Raw -Encoding UTF8 | ConvertFrom-Json)) | Where-Object { $_.path }
                $historyDocuments = @{}; foreach ($document in $sourceDocuments) { $historyDocuments[$document.path] = $document }
                Save-ReaderHistory $source.path $historyDocuments $inventory.directorySyncedAt
                foreach ($file in @($inventory.files) + @($sourceDocuments)) {
                    $relative = $file.path
                    $file | Add-Member -NotePropertyMembers @{ sourceId = $source.id; relativePath = $relative; space = $source.space; citation = @{ sourceId = $source.id; path = $relative; hash = $file.hash; evaluatedAt = $file.evaluatedAt } } -Force
                    $file.path = $prefix + $relative
                }
                foreach ($file in $inventory.files) {
                    $file.links = @($file.links | ForEach-Object { $prefix + $_ })
                    foreach ($assignment in $file.topics) { $assignment.evidencePath = $prefix + $assignment.evidencePath }
                }
                foreach ($topic in $inventory.topics) { $topic.evidenceFiles = @($topic.evidenceFiles | ForEach-Object { $prefix + $_ }); $topics[$topic.id] = $topic }
                foreach ($entry in @($inventory.excludedDirectories)) { $entry.path = $prefix + $entry.path; $excluded += $entry }
                $cachedFiles = @($inventory.files); $cachedDocuments = @($sourceDocuments); $method = $inventory.method
                $lastSuccess = $inventory.directorySyncedAt
                $failed = @($sourceDocuments | Where-Object { $_.processingState -eq 'error' }).Count
                $pending = $failed
                $updateState = if ($failed) { 'error' } else { 'current' }
                if ($failed) { $probe.error = 'Dokumentverarbeitung fehlgeschlagen: ' + $failed + $(if ($failed -eq 1) { ' Datei; ' } else { ' Dateien; ' }) + 'bisheriger erfolgreicher Stand bleibt sichtbar' }
            } catch {
                $updateState = 'error'
                $probe.error = 'Indexaufbau der Quelle fehlgeschlagen: ' + $_.Exception.Message
            }
        }
        if ($updateState -ne 'current') {
            foreach ($file in $cachedFiles) { $file | Add-Member -NotePropertyName sourceStale -NotePropertyValue $true -Force }
        }
        if ($probe.reachable -ne 'reachable') {
            $updateState = if ($cachedFiles.Count) { 'stale' } else { 'unknown' }
            if (-not $probe.error) {
                $probe.error = if ($lastSuccess) { 'Quelle nicht erreichbar; letzter erfolgreicher Abgleich bleibt sichtbar' } else { 'Quelle nicht erreichbar; kein erfolgreicher Abgleich bekannt' }
            }
        }
        $probe | Add-Member -NotePropertyMembers @{
            lastSuccess = $lastSuccess; pending = $pending; pendingBasis = if ($null -ne $pending) { 'index' } else { 'unknown' }
            failed = $failed; documents = @($cachedFiles).Count; updateState = $updateState
        } -Force
        $sources += $probe; $files += $cachedFiles; $allDocuments += $cachedDocuments
    }
    foreach ($file in $files) {
        if (-not $seenPaths.Add([string]$file.path)) { throw ('Doppelter Dokumentpfad ueber Quellen hinweg: ' + $file.path + '. Quellen-IDs und Pfade pruefen.') }
    }
    foreach ($topic in @($previousInventory.topics | Where-Object { $_.id })) { if (-not $topics.ContainsKey($topic.id)) { $topics[$topic.id] = $topic } }
    foreach ($topic in $topics.Values) { $members = @($files | Where-Object { @($_.topics.id) -contains $topic.id }); $topic.count = $members.Count; $topic.evidenceFiles = @($members.path) }
    $now = [DateTime]::UtcNow.ToString('o')
    $inventory = @{
        generated = $now; directorySyncedAt = $now; method = $method; files = $files; topics = @($topics.Values | Sort-Object id)
        excludedDirectories = $excluded; sources = $sources; computer = @{ id = $Configuration.computerId; name = $Configuration.computerName }
    }
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'inventory.json'), ($inventory | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'documents.json'), (ConvertTo-Json -InputObject @($allDocuments) -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
    $inventory
}
