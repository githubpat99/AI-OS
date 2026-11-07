$ErrorActionPreference = 'Stop'
$port = 43129
$origin = 'https://example.github.io'
$base = "http://127.0.0.1:$port"
$work = Join-Path $env:TEMP ('ai-os-service-work-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $work 'first'
$second = Join-Path $work 'second'
$missing = Join-Path $work 'missing'
[IO.Directory]::CreateDirectory($fixture) | Out-Null
[IO.Directory]::CreateDirectory($second) | Out-Null
Get-ChildItem (Join-Path $PSScriptRoot 'tests/fixture') -File | Copy-Item -Destination $fixture
[IO.File]::WriteAllText((Join-Path $second 'notiz.md'), "# Zweite Quelle`nPRIVATE_NOTE_519", [Text.UTF8Encoding]::new($false))
$configPath = Join-Path $work 'config\sources.json'
[IO.Directory]::CreateDirectory((Split-Path $configPath -Parent)) | Out-Null
$initialConfig = @{ version = 1; computerId = 'test-computer'; computerName = 'TEST-PC'; sources = @(@{ id = 'fixture'; name = 'Fixture'; space = 'business'; type = 'directory'; path = $fixture; read = $true; write = $true; flat = $true }) }
[IO.File]::WriteAllText($configPath, ($initialConfig | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
$process = [System.Diagnostics.Process]::new()
$process.StartInfo.FileName = 'powershell.exe'
$process.StartInfo.Arguments = '-NoProfile -File "' + (Join-Path $PSScriptRoot 'connector.ps1') + '" -Origin ' + $origin + ' -Port ' + $port + ' -ConfigurationPath "' + $configPath + '"'
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.CreateNoWindow = $true

function Request([string]$path, [string]$method = 'GET', [hashtable]$headers = @{}, [string]$body = '') {
    $request = [System.Net.HttpWebRequest]::Create($base + $path)
    $request.Method = $method
    $request.Timeout = 60000
    $request.ContentType = 'application/json; charset=utf-8'
    foreach ($key in $headers.Keys) { $request.Headers[$key] = $headers[$key] }
    if ($body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    } elseif ($method -eq 'POST') { $request.ContentLength = 0 }
    try { $response = $request.GetResponse() } catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if (-not $response) { throw }
    }
    $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
    try { return @{ status = [int]$response.StatusCode; headers = $response.Headers; body = $reader.ReadToEnd() } }
    finally { $reader.Dispose(); $response.Close() }
}
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Wait-Refresh([hashtable]$headers) {
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $state = (Request '/progress' 'GET' $headers).body | ConvertFrom-Json
        Assert ($state.state -ne 'failed') ('Hintergrundauftrag fehlgeschlagen: ' + $state.error + ' / ' + $state.errorId)
        Assert ([DateTime]::UtcNow -lt $deadline) 'Hintergrundauftrag laeuft zu lange'
        Start-Sleep -Milliseconds 200
    } while ($state.state -ne 'completed')
    $state
}
. (Join-Path $PSScriptRoot 'document-state.ps1')

$buildAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'build.ps1'), [ref]$null, [ref]$null)
$metadataAssignment = $buildAst.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$metadataPattern' }, $true)
. ([scriptblock]::Create($metadataAssignment.Extent.Text))
$metadataRegex = [regex]::new($metadataPattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(1))
$whitespaceSample = (' ' * 20000) + "Kein Metadatenfeld`r`n`r`n- source_path: privat/test.pdf`r`nZielarchitektur"
$cleaned = $metadataRegex.Replace($whitespaceSample, '')
Assert ($cleaned.Contains('Kein Metadatenfeld') -and $cleaned.Contains('Zielarchitektur') -and -not $cleaned.Contains('privat/test.pdf')) 'Metadatenbereinigung falsch oder zu langsam'

$stateTest = Join-Path $env:TEMP ('ai-os-document-state-' + [guid]::NewGuid().ToString('N'))
try {
    $stateRoot = Join-Path $stateTest 'source'
    $stateOutput = Join-Path $stateTest 'index'
    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    $stateFile = Join-Path $stateRoot 'sample.md'
    $stateCache = Join-Path $stateTest 'previous.json'
    [IO.File]::WriteAllText($stateFile, "# Fixture`nZielarchitektur Alpha", [Text.UTF8Encoding]::new($false))
    & (Join-Path $PSScriptRoot 'build.ps1') -Root $stateRoot -OutputDirectory $stateOutput | Out-Null
    $firstState = @(Get-Content (Join-Path $stateOutput 'documents.json') -Raw -Encoding UTF8 | ConvertFrom-Json)[0]
    Copy-Item (Join-Path $stateOutput 'documents.json') $stateCache -Force
    & (Join-Path $PSScriptRoot 'build.ps1') -Root $stateRoot -OutputDirectory $stateOutput -PreviousDocumentsPath $stateCache | Out-Null
    $unchangedState = @(Get-Content (Join-Path $stateOutput 'documents.json') -Raw -Encoding UTF8 | ConvertFrom-Json)[0]
    Assert ($unchangedState.evaluatedAt -eq $firstState.evaluatedAt -and $unchangedState.hash -eq $firstState.hash) 'Unveraenderte Datei erhielt neuen Auswertungszeitpunkt'
    $originalDate = (Get-Item $stateFile).LastWriteTimeUtc
    [IO.File]::WriteAllText($stateFile, "# Fixture`nZielarchitektur Bravo", [Text.UTF8Encoding]::new($false))
    [IO.File]::SetLastWriteTimeUtc($stateFile, $originalDate)
    & (Join-Path $PSScriptRoot 'build.ps1') -Root $stateRoot -OutputDirectory $stateOutput -PreviousDocumentsPath $stateCache | Out-Null
    $changedState = @(Get-Content (Join-Path $stateOutput 'documents.json') -Raw -Encoding UTF8 | ConvertFrom-Json)[0]
    Assert ($changedState.hash -ne $firstState.hash -and $changedState.modified -eq $firstState.modified -and $changedState.text.Contains('Bravo')) 'Hash erkennt Aenderung bei gleichem Dateidatum nicht'
    Copy-Item (Join-Path $stateOutput 'documents.json') $stateCache -Force
    [IO.File]::WriteAllBytes($stateFile, [byte[]]@(195, 40))
    & (Join-Path $PSScriptRoot 'build.ps1') -Root $stateRoot -OutputDirectory $stateOutput -PreviousDocumentsPath $stateCache | Out-Null
    $failedState = @(Get-Content (Join-Path $stateOutput 'documents.json') -Raw -Encoding UTF8 | ConvertFrom-Json)[0]
    Assert ($failedState.processingState -eq 'error' -and $failedState.evaluatedAt -eq $changedState.evaluatedAt -and $failedState.hash -eq $changedState.hash -and $failedState.sourceHash -ne $failedState.hash -and $failedState.text.Contains('Bravo')) 'Fehler ueberschreibt erfolgreichen Dokumentstand'
} finally { if (Test-Path $stateTest) { Remove-Item -LiteralPath $stateTest -Recurse -Force } }

try {
    $process.Start() | Out-Null
    $ready = $process.StandardOutput.ReadLine()
    Assert ($ready -like 'AI-OS-Verbindungsdienst:*') 'Dienst startet nicht'
    $health = Request '/health' 'GET' @{ Origin = $origin }
    Assert ($health.status -eq 200 -and $health.headers['Access-Control-Allow-Origin'] -eq $origin) 'Health/CORS'
    $preflight = Request '/session' 'OPTIONS' @{ Origin = $origin; 'Access-Control-Request-Headers' = 'authorization'; 'Access-Control-Request-Method' = 'GET'; 'Access-Control-Request-Private-Network' = 'true' }
    Assert ($preflight.status -eq 204 -and $preflight.headers['Access-Control-Allow-Private-Network'] -eq 'true') 'Preflight'
    Assert ((Request '/session' 'GET' @{ Origin = $origin }).status -eq 403) 'Index ohne Token lesbar'
    Assert ((Request '/document?path=sample.md' 'GET' @{ Origin = $origin }).status -eq 403) 'Dokument ohne Token lesbar'
    Assert ((Request '/search?q=Transformation' 'GET' @{ Origin = $origin }).status -eq 403) 'Volltextsuche ohne Token lesbar'
    Assert ((Request '/original?path=sample.md' 'GET' @{ Origin = $origin }).status -eq 403) 'Original ohne Token lesbar'
    Assert ((Request '/open-code?path=sample.md' 'POST' @{ Origin = $origin }).status -eq 403) 'VS-Code-Aktion ohne Token moeglich'
    $foreign = Request '/health' 'GET' @{ Origin = 'https://untrusted.example' }
    Assert ($foreign.status -eq 403 -and -not $foreign.headers['Access-Control-Allow-Origin']) 'Fremder Ursprung freigegeben'
    Assert ((Request '/approve' 'POST' @{ Origin = $base; 'X-Pairing' = 'invalid' }).status -eq 403) 'Freigabe ohne Nonce'
    Assert ((Request '/pair?app=https%3A%2F%2Funtrusted.example%2F').status -eq 400) 'Fremde Rueckkehradresse akzeptiert'
    $pair = Request ('/pair?app=' + [Uri]::EscapeDataString($origin + '/topic-map/'))
    Assert ($pair.body -match "'X-Pairing':'([a-f0-9]+)'") 'Freigabeseite fehlt'
    $nonce = $Matches[1]
    Assert ($pair.body.Contains('Verarbeitungsfortschritt') -and $pair.body.Contains('Letzte Meldung')) 'Fortschrittsoberflaeche fehlt'
    Assert ($pair.body.Contains('topics-found') -and $pair.body.Contains('renderTopicProgress(result)')) 'Live-Themenzaehler auf Freigabeseite fehlen'
    Assert ($pair.body.Contains('topic-build-table') -and -not $pair.body.Contains('__TOPIC_BUILD__')) 'Visueller Themenaufbau auf Freigabeseite fehlt'
    Assert ((Request '/progress' 'GET' @{ Origin = $base; 'X-Pairing' = 'invalid' }).status -eq 403) 'Fortschritt ohne Nonce lesbar'
    Assert ((Request '/progress' 'GET' @{ 'X-Pairing' = $nonce }).status -eq 200) 'Lokale Browser-GET-Abfrage ohne Origin abgelehnt'
    $approval = Request '/approve' 'POST' @{ Origin = $base; 'X-Pairing' = $nonce }
    Assert ($approval.status -eq 202) 'Lokale Freigabe startet keinen Hintergrundauftrag'
    Assert ((Request '/health' 'GET' @{ Origin = $origin }).status -eq 200) 'Dienst waehrend Indexaufbau blockiert'
    Assert ((Request '/approve' 'POST' @{ Origin = $base; 'X-Pairing' = $nonce }).status -eq 409) 'Doppelter Indexaufbau moeglich'
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $progress = (Request '/progress' 'GET' @{ Origin = $base; 'X-Pairing' = $nonce }).body | ConvertFrom-Json
        Assert ($progress.state -ne 'failed') ('Hintergrundauftrag fehlgeschlagen: ' + $progress.errorId)
        Assert ([DateTime]::UtcNow -lt $deadline) 'Hintergrundauftrag laeuft zu lange'
    } while ($progress.state -ne 'completed')
    Assert ($progress.phase -eq 5 -and $progress.processed -eq $progress.total -and $progress.evaluated -eq 1) ('Abschlusszaehler falsch: ' + ($progress | ConvertTo-Json -Depth 2 -Compress))
    Assert ($progress.topicsFound -eq 2 -and $progress.topicCandidates -eq 19 -and $progress.topicLabels.Count -eq 2) 'Themenzaehler oder Themenliste falsch'
    $expectedReferences = if ($progress.partial -gt 0) { 0 } else { 2 }
    $expectedTopicDocuments = if ($progress.partial -gt 0) { 1 } else { 2 }
    Assert ($progress.textAssignments -eq 2 -and $progress.referenceAssignments -eq $expectedReferences -and $progress.documentsWithTopics -eq $expectedTopicDocuments) 'Zuordnungszaehler falsch'
    Assert ($progress.rulesChecked -in @(19, 38) -and $progress.linksChecked -eq 1) 'Regel- oder Verweispruefungszaehler falsch'
    Assert ($progress.topicBuild.Count -eq 19) 'Themenaufbau enthaelt nicht alle Kandidaten'
    $architectureBuild = $progress.topicBuild | Where-Object id -eq 'architektur'
    Assert ($architectureBuild.documents -ge 1 -and $architectureBuild.textAssignments -eq 1 -and $architectureBuild.state -eq 'ready') 'Themenaufbau-Zaehler oder Abschlusszustand falsch'
    Assert (@($progress.topicBuild | Where-Object state -eq 'empty').Count -eq 17) 'Themen ohne Beleg falsch dargestellt'
    Assert (@($progress.events | Where-Object phase -gt 0 | Select-Object -ExpandProperty phase -Unique).Count -eq 5) 'Nicht alle fuenf Phasen gemeldet'
    Assert ((Request '/progress' 'GET' @{ Origin = $origin; 'X-Pairing' = $nonce }).status -eq 403) 'Lokaler Fortschritt fuer Seiten-Ursprung lesbar'
    $secret = $progress.token
    $auth = @{ Origin = $origin; Authorization = 'Bearer ' + $secret }
    $session = Request '/session' 'GET' $auth
    Assert ($session.status -eq 200) 'Sitzung nicht lesbar'
    $snapshot = $session.body | ConvertFrom-Json
    Assert ($snapshot.inventory.files.Count -eq 2 -and $snapshot.inventory.files[0].title -eq 'CONNECTOR_TEST_ONLY') 'Falsches Verzeichnis inventarisiert'
    $source = $snapshot.inventory.files | Where-Object path -eq 'source.eml'
    if ($source.status -eq 'skipped') {
        Assert ($source.topics.Count -eq 2 -and @($source.topics | Where-Object basis -eq 'Dokumentverweis').Count -eq 2) 'Verweiszuordnungen fehlen'
        Assert ($source.topics[0].evidence.Contains('Architektur') -and $source.topics[0].evidence.Contains('Quellenregister')) 'Ueberschriftenkontexte beim Caching veraendert'
    } else { Assert ($source.status -eq 'partial' -and $source.reason.Contains('Anhaenge')) 'Mail-Extraktionsgrenzen fehlen' }
    Assert (-not ($snapshot.inventory.files[0].PSObject.Properties.Name -contains 'text')) 'Volltext im Index'
    $readerDocument = (Request '/document?path=sample.md' 'GET' $auth).body | ConvertFrom-Json
    Assert ($readerDocument.text.Contains('Fiktive Zielarchitektur') -and $readerDocument.headings.Count -eq 3) 'Dokumentleser-Inhalt oder Navigation falsch'
    $search = (Request '/search?q=FULLTEXT_ONLY_NEEDLE_742' 'GET' $auth).body | ConvertFrom-Json
    Assert ($search.results.Count -eq 1 -and $search.results[0].snippets[0].text.Contains('FULLTEXT_ONLY_NEEDLE_742')) 'Volltextsuche ohne belegten Textauszug'
    $snippet = $search.results[0].snippets[0]
    Assert ($readerDocument.text.Substring($snippet.start, $snippet.text.Length) -ceq $snippet.text) 'Suchbeleg stammt nicht exakt aus gelesenem Inhalt'
    Assert ((Request '/document?path=..%2FAGENTS.md' 'GET' $auth).status -eq 404) 'Dokument-Pfadgrenze verletzt'
    Assert ((Request '/original?path=..%2FAGENTS.md' 'GET' $auth).status -eq 403) 'Original-Pfadgrenze verletzt'
    Assert ((Request '/open-original?path=..%2FAGENTS.md' 'POST' $auth).status -eq 409) 'Original-Oeffnen umgeht Pfadgrenze'
    Assert ((Request '/open-code?path=..%2FAGENTS.md' 'POST' $auth).status -eq 409) 'VS-Code-Aktion umgeht Pfadgrenze'
    Assert ((Request '/original?path=sample.md' 'GET' $auth).body.Contains('CONNECTOR_TEST_ONLY')) 'Original wird nicht lokal bereitgestellt'
    Assert ($readerDocument.documentState.evaluatedAt -and $readerDocument.documentState.directorySyncedAt -and $readerDocument.documentState.sourceHash -eq $readerDocument.documentState.indexedHash) 'Getrennte Dokument-/Indexstaende fehlen'
    $samplePath = Join-Path $fixture 'sample.md'
    $sampleText = [IO.File]::ReadAllText($samplePath)
    $sampleDate = [IO.File]::GetLastWriteTimeUtc($samplePath)
    $mailBeforeSave = (Request '/document?path=source.eml' 'GET' $auth).body | ConvertFrom-Json
    [IO.File]::WriteAllText($samplePath, $sampleText + "`nAUTO_RELOADED_TOKEN_815", [Text.UTF8Encoding]::new($false))
    [IO.File]::SetLastWriteTimeUtc($samplePath, $sampleDate)
    $saveState = (Request '/status?path=sample.md' 'GET' $auth).body | ConvertFrom-Json
    Assert ($saveState.processing -and $saveState.documentState.state -eq 'processing' -and $saveState.documentState.stale) 'Speichern startet keine automatische Neubearbeitung'
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $saveState = (Request '/status?path=sample.md' 'GET' $auth).body | ConvertFrom-Json
        Assert ([DateTime]::UtcNow -lt $deadline) 'Automatisches Neueinlesen laeuft zu lange'
    } while ($saveState.processing)
    $savedDocument = (Request '/document?path=sample.md' 'GET' $auth).body | ConvertFrom-Json
    $mailAfterSave = (Request '/document?path=source.eml' 'GET' $auth).body | ConvertFrom-Json
    Assert ($savedDocument.text.Contains('AUTO_RELOADED_TOKEN_815') -and $savedDocument.documentState.sourceHash -eq $savedDocument.documentState.indexedHash -and $savedDocument.documentState.evaluatedAt -ne $readerDocument.documentState.evaluatedAt) 'Gespeicherte Datei nicht erfolgreich neu eingelesen'
    Assert ($mailAfterSave.documentState.evaluatedAt -eq $mailBeforeSave.documentState.evaluatedAt) 'Unveraenderte Mail unnoetig neu ausgewertet'
    [IO.File]::WriteAllBytes($samplePath, [byte[]]@(195, 40))
    $null = Request '/status?path=sample.md' 'GET' $auth
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $failureState = (Request '/status?path=sample.md' 'GET' $auth).body | ConvertFrom-Json
        Assert ([DateTime]::UtcNow -lt $deadline) 'Fehlerverarbeitung laeuft zu lange'
    } while ($failureState.processing)
    $failedDocument = (Request '/document?path=sample.md' 'GET' $auth).body | ConvertFrom-Json
    Assert ($failedDocument.documentState.state -eq 'error' -and $failedDocument.documentState.stale -and $failedDocument.documentState.evaluatedAt -eq $savedDocument.documentState.evaluatedAt -and $failedDocument.text.Contains('AUTO_RELOADED_TOKEN_815')) 'Verarbeitungsfehler ueberschreibt erfolgreichen Dokumentstand'
    $history = Get-Content -LiteralPath (Get-ReaderHistoryPath $fixture) -Raw -Encoding UTF8 | ConvertFrom-Json
    $historicalSample = $history.documents | Where-Object path -eq 'sample.md'
    Assert ($historicalSample.evaluatedAt -eq $savedDocument.documentState.evaluatedAt -and -not ($historicalSample.PSObject.Properties.Name -contains 'text')) 'Auswertungszeitpunkt nicht privat ohne Volltext gespeichert'
    Remove-Item -LiteralPath $samplePath -Force
    $null = Request '/status?path=sample.md' 'GET' $auth
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $missingState = (Request '/status?path=sample.md' 'GET' $auth).body | ConvertFrom-Json
        Assert ([DateTime]::UtcNow -lt $deadline) 'Abgleich nach Entfernen laeuft zu lange'
    } while ($missingState.processing)
    $missingDocument = (Request '/document?path=sample.md' 'GET' $auth).body | ConvertFrom-Json
    Assert ($missingDocument.documentState.state -eq 'error' -and $missingDocument.documentState.evaluatedAt -eq $savedDocument.documentState.evaluatedAt) 'Entfernte Quelldatei verliert letzten Erfolgszeitpunkt'
    $missingSearch = (Request '/search?q=AUTO_RELOADED_TOKEN_815' 'GET' $auth).body | ConvertFrom-Json
    Assert ($missingSearch.results.Count -eq 0) 'Entfernte Datei wird weiter als aktueller Suchtreffer angeboten'
    [IO.File]::WriteAllText($samplePath, $sampleText, [Text.UTF8Encoding]::new($false))
    Assert ((Request '/sources' 'GET' @{ Origin = $origin }).status -eq 403) 'Quellen ohne Token lesbar'
    $sourceState = (Request '/sources' 'GET' $auth).body | ConvertFrom-Json
    Assert ($sourceState.sourceEditing -eq $true -and @($sourceState.sources).Count -eq 1) 'Quellenregister oder Bearbeitungsrecht falsch'
    Assert ($sourceState.computer.id -eq 'test-computer' -and $sourceState.computer.name -eq 'TEST-PC') 'Rechnerkennung fehlt im Quellenregister'
    $fixtureProbe = @($sourceState.sources)[0]
    Assert ($fixtureProbe.id -eq 'fixture' -and $fixtureProbe.name -eq 'Fixture' -and $fixtureProbe.space -eq 'business' -and $fixtureProbe.type -eq 'directory') 'Quellenmetadaten unvollstaendig'
    Assert ($fixtureProbe.read -eq $true -and $fixtureProbe.write -eq $true -and $fixtureProbe.reachable -eq 'reachable') 'Rechte oder Erreichbarkeit der Quelle falsch'
    Assert ($fixtureProbe.lastSuccess -and $null -ne $fixtureProbe.pending -and $fixtureProbe.updateState -in @('current', 'error')) ('Quellenzustand nicht tatsaechlich ermittelt: ' + ($fixtureProbe | ConvertTo-Json -Depth 4 -Compress))
    $tokenField = Request '/sources/save' 'POST' $auth (@{ name = 'X'; space = 'private'; type = 'directory'; path = $second; read = $true; write = $false; token = 'geheim' } | ConvertTo-Json -Compress)
    Assert ($tokenField.status -eq 400 -and $tokenField.body.Contains('Unbekanntes Feld')) 'Zugangsdaten ueber die App speicherbar'
    Assert (-not [IO.File]::ReadAllText($configPath).Contains('geheim')) 'Zugangsdaten in lokaler Konfiguration abgelegt'
    $relativePath = Request '/sources/save' 'POST' $auth (@{ name = 'Rel'; space = 'private'; type = 'directory'; path = 'relativ\pfad'; read = $true; write = $false } | ConvertTo-Json -Compress)
    Assert ($relativePath.status -eq 400) 'Relativer Quellenpfad akzeptiert'
    $writeWithoutRead = Request '/sources/save' 'POST' $auth (@{ name = 'OhneLesen'; space = 'private'; type = 'directory'; path = $second; read = $false; write = $true } | ConvertTo-Json -Compress)
    Assert ($writeWithoutRead.status -eq 400) 'Schreibrecht ohne Leserecht akzeptiert'
    $saved = Request '/sources/save' 'POST' $auth (@{ name = 'Privat'; space = 'private'; type = 'onedrive'; path = $second; read = $true; write = $false } | ConvertTo-Json -Compress)
    Assert ($saved.status -eq 202) ('Quelle speichern fehlgeschlagen: ' + $saved.body)
    $savedSource = ($saved.body | ConvertFrom-Json).source
    $secondId = $savedSource.id
    Assert ($secondId -match '^[a-zA-Z0-9][a-zA-Z0-9_-]{1,63}$' -and $savedSource.space -eq 'private' -and $savedSource.write -eq $false) 'Gespeicherte Quelle falsch'
    $null = Wait-Refresh $auth
    $sourceSession = (Request '/session' 'GET' $auth).body | ConvertFrom-Json
    Assert (@($sourceSession.inventory.sources).Count -eq 2 -and $sourceSession.sourceEditing -eq $true) 'Zweite Quelle nicht uebernommen'
    $fixtureFile = $sourceSession.inventory.files | Where-Object { $_.path -eq 'sample.md' }
    Assert ($fixtureFile.sourceId -eq 'fixture' -and $fixtureFile.space -eq 'business' -and $fixtureFile.citation.path -eq 'sample.md' -and $fixtureFile.citation.hash -eq $fixtureFile.hash) 'Quellenbeleg pro Dokument fehlt'
    $citationDocument = (Request '/document?path=sample.md' 'GET' $auth).body | ConvertFrom-Json
    Assert ($citationDocument.source.name -eq 'Fixture' -and $citationDocument.citation.sourceId -eq 'fixture' -and $citationDocument.canEditInCode -eq $true) 'Dokument nennt Quelle, Beleg oder Schreibrecht nicht'
    $secondFile = $sourceSession.inventory.files | Where-Object { $_.sourceId -eq $secondId }
    Assert (@($secondFile).Count -eq 1 -and $secondFile.path -eq ($secondId + '/notiz.md') -and $secondFile.space -eq 'private') 'Pfadpraefix oder Wissensraum der zweiten Quelle falsch'
    Assert ($secondFile.citation.path -eq 'notiz.md' -and $secondFile.citation.sourceId -eq $secondId) 'Beleg der zweiten Quelle falsch'
    $secondDocument = (Request ('/document?path=' + [Uri]::EscapeDataString($secondId + '/notiz.md')) 'GET' $auth).body | ConvertFrom-Json
    Assert ($secondDocument.source.name -eq 'Privat' -and $secondDocument.space -eq 'private' -and $secondDocument.canEditInCode -eq $false) 'Leserecht der zweiten Quelle falsch'
    $secondSearch = (Request '/search?q=PRIVATE_NOTE_519' 'GET' $auth).body | ConvertFrom-Json
    Assert (@($secondSearch.results).Count -eq 1 -and $secondSearch.results[0].citation.sourceId -eq $secondId -and $secondSearch.results[0].source.name -eq 'Privat') 'Volltexttreffer ohne Quellenbeleg'
    $secondNote = Join-Path $second 'notiz.md'
    [IO.File]::WriteAllText($secondNote, "# Zweite Quelle`nPRIVATE_NOTE_519 AUTO_SECOND_380", [Text.UTF8Encoding]::new($false))
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $secondSaveState = (Request '/status' 'GET' $auth).body | ConvertFrom-Json
        Assert ([DateTime]::UtcNow -lt $deadline) 'Automatisches Neueinlesen der zweiten Quelle laeuft zu lange'
    } while ($secondSaveState.processing)
    $secondAfterSave = (Request ('/document?path=' + [Uri]::EscapeDataString($secondId + '/notiz.md')) 'GET' $auth).body | ConvertFrom-Json
    Assert ($secondAfterSave.text.Contains('AUTO_SECOND_380')) 'Aenderung in der zweiten Quelle wird nicht automatisch eingelesen'
    $unreachable = Request '/sources/save' 'POST' $auth (@{ name = 'Nirgends'; space = 'business'; type = 'network'; path = $missing; read = $true; write = $false } | ConvertTo-Json -Compress)
    Assert ($unreachable.status -eq 202) 'Nicht erreichbare Quelle nicht speicherbar'
    $unreachableId = ($unreachable.body | ConvertFrom-Json).source.id
    $null = Wait-Refresh $auth
    $unreachableState = (Request '/sources' 'GET' $auth).body | ConvertFrom-Json
    $unreachableProbe = $unreachableState.sources | Where-Object { $_.id -eq $unreachableId }
    Assert ($unreachableProbe.reachable -eq 'unreachable' -and $null -eq $unreachableProbe.lastSuccess -and $null -eq $unreachableProbe.pending -and $unreachableProbe.updateState -eq 'unknown') 'Unbekannter Zustand nicht als unbekannt gemeldet'
    Assert ($unreachableProbe.error) 'Fehler der nicht erreichbaren Quelle fehlt'
    $removed = Request '/sources/remove' 'POST' $auth (@{ id = $secondId } | ConvertTo-Json -Compress)
    Assert ($removed.status -eq 202) 'Quelle entfernen fehlgeschlagen'
    $null = Wait-Refresh $auth
    $removedSession = (Request '/session' 'GET' $auth).body | ConvertFrom-Json
    Assert (@($removedSession.inventory.sources).Count -eq 2 -and -not ($removedSession.inventory.files | Where-Object { $_.sourceId -eq $secondId })) 'Entfernte Quelle bleibt im Index'
    Assert ((Request '/sources/remove' 'POST' $auth (@{ id = $unreachableId } | ConvertTo-Json -Compress)).status -eq 202) 'Zweite Quelle nicht entfernbar'
    $null = Wait-Refresh $auth
    $lastRemoval = Request '/sources/remove' 'POST' $auth (@{ id = 'fixture' } | ConvertTo-Json -Compress)
    Assert ($lastRemoval.status -eq 400 -and $lastRemoval.body.Contains('Mindestens eine Quelle')) 'Letzte Quelle entfernbar'
    $finalConfig = [IO.File]::ReadAllText($configPath)
    Assert (-not $finalConfig.Contains('geheim') -and -not $finalConfig.Contains('PRIVATE_NOTE_519')) 'Zugangsdaten oder Volltext in lokaler Konfiguration'
    Assert ($finalConfig -match '"id"\s*:\s*"fixture"') 'Stabile Quellen-ID nicht gespeichert'
    Assert (-not $configPath.StartsWith($PSScriptRoot, [StringComparison]::OrdinalIgnoreCase)) 'Quellenkonfiguration liegt im Repository'
    Assert ((Request '/session' 'GET' @{ Origin = 'https://untrusted.example'; Authorization = 'Bearer ' + $secret }).status -eq 403) 'Token fuer fremden Ursprung akzeptiert'
    Assert ((Request '/progress' 'GET' @{ Origin = $origin }).status -eq 403) 'Aktualisierungsfortschritt ohne Token lesbar'
    Assert ((Request '/refresh' 'POST' $auth).status -eq 202) 'Aktualisieren startet keinen Hintergrundauftrag'
    Assert ((Request '/refresh' 'POST' $auth).status -eq 409) 'Doppelte Aktualisierung moeglich'
    Assert ((Request '/status' 'GET' $auth).status -eq 200) 'Dienst waehrend Aktualisieren blockiert'
    Assert ((Request '/session' 'GET' $auth).status -eq 200) 'Bisheriger Index waehrend Aktualisieren nicht lesbar'
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $refreshProgress = (Request '/progress' 'GET' $auth).body | ConvertFrom-Json
        Assert ($refreshProgress.state -ne 'failed') ('Aktualisieren fehlgeschlagen: ' + $refreshProgress.errorId)
        Assert ([DateTime]::UtcNow -lt $deadline) 'Aktualisieren laeuft zu lange'
    } while ($refreshProgress.state -ne 'completed')
    Assert ($refreshProgress.phase -eq 5 -and $refreshProgress.evaluated -eq 1) 'Aktualisierungsfortschritt falsch'
    Assert ($refreshProgress.topicsFound -eq 2 -and $refreshProgress.textAssignments -eq 2 -and $refreshProgress.referenceAssignments -eq $expectedReferences) 'Live-Themenzaehler beim Aktualisieren falsch'
    Assert ((Request '/session' 'GET' $auth).status -eq 200) 'Token nach Aktualisieren ungueltig'
    Assert ((Request '/refresh' 'POST' $auth).status -eq 202) 'Weitere Aktualisierung fehlgeschlagen'
    Assert ((Request '/disconnect' 'POST' $auth).status -eq 200) 'Trennen fehlgeschlagen'
    Assert ((Request '/session' 'GET' $auth).status -eq 403) 'Token nach Trennen gueltig'
    Assert ((Request '/document?path=sample.md' 'GET' $auth).status -eq 403) 'Dokument nach Trennen lesbar'
    Assert ((Request '/approve' 'POST' @{ Origin = $base; 'X-Pairing' = $nonce }).status -eq 403) 'Alte Freigabe nach Trennen gueltig'
    Assert ((Request '/progress' 'GET' @{ Origin = $base; 'X-Pairing' = $nonce }).status -eq 403) 'Fortschritt nach Trennen lesbar'
    & (Join-Path $PSScriptRoot 'publish.ps1')
    $html = Get-Content (Join-Path $PSScriptRoot 'public/index.html') -Raw
    Assert (-not $html.Contains('CONNECTOR_TEST_ONLY')) 'Testindex im Public-Build'
    Assert (-not $html.Contains($fixture)) 'Verzeichnispfad im Public-Build'
    Assert (-not $html.Contains('localStorage.setItem')) 'Interne Daten koennten persistiert werden'
    Assert ($html.Contains('Fortschritt der Aktualisierung') -and $html.Contains("request('/progress')")) 'Aktualisierungsanzeige fehlt im Public-Build'
    Assert ($html.Contains('id="refresh-details"') -and $html.Contains('refreshElement(''details'').open=!done')) 'Fortschritt wird nach Abschluss nicht einklappbar'
    Assert ($html.Contains('&#10003; Abgeschlossen') -and $html.Contains('Durchlauf 2 von 2')) 'Abschlusshaken oder Zuordnungsdetails fehlen'
    Assert ($html.Contains('refresh-topics-found') -and $html.Contains('showTopicProgress(result);')) 'Live-Themenzaehler beim Aktualisieren fehlen'
    Assert ($html.Contains('id="document-reader"') -and $html.Contains('keine KI-Anbindung') -and -not $html.Contains('__DOCUMENT_READER__')) 'Dokumentleser oder KI-Verfuegbarkeitsstatus fehlt'
    Assert (-not $html.Contains('FULLTEXT_ONLY_NEEDLE_742')) 'Privater Volltext im Public-Build'
    Assert ($html.Contains('topic-build-table') -and -not $html.Contains('__TOPIC_BUILD__')) 'Visueller Themenaufbau im Public-Build fehlt'
    Assert ($html.Contains('In VS Code bearbeiten') -and $html.Contains('Europe/Zurich') -and $html.Contains('Letzte erfolgreiche Auswertung') -and $html.Contains('pollConnection')) 'Editoraktion, Zeitzone oder getrennte Staende fehlen'
    Assert ($html.Contains('id="workspace-computer"') -and $html.Contains('id="workspace-space"') -and $html.Contains('Letzter Abgleich') -and $html.Contains('Aktiver Wissensraum')) 'Rechner-, Wissensraum- oder Abgleichsanzeige fehlt im Public-Build'
    Assert ($html.Contains('data-view="sources"') -and $html.Contains('renderSources') -and $html.Contains('source-facts') -and $html.Contains('Stabile ID')) 'Quellenansicht fehlt im Public-Build'
    Assert ($html.Contains('id="source-dialog"') -and $html.Contains("request('/sources/save'") -and $html.Contains("'/sources/remove'")) 'Quellenverwaltung fehlt im Public-Build'
    Assert ($html.Contains('Unbekannt (noch kein Indexstand)') -and $html.Contains('als Unbekannt angezeigt')) 'Unbekannte Zustaende nicht ausdruecklich gekennzeichnet'
    Assert ($html.Contains('Zugangsdaten bleiben in der lokalen Konfiguration') -and -not $html.Contains('PRIVATE_NOTE_519')) 'Zugangsdatenhinweis fehlt oder privater Inhalt veroeffentlicht'
    Write-Output 'TESTS_OK: CORS, Preflight, Origin, Token, lokale Freigabe, Index, Quellenverwaltung, Wissensraeume, Aktualisieren, Widerruf, Public-Isolation.'
} finally {
    if ($process.Id -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
    foreach ($directory in @($fixture, $second)) { $history = Get-ReaderHistoryPath $directory; if (Test-Path -LiteralPath $history) { Remove-Item -LiteralPath $history -Force } }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}