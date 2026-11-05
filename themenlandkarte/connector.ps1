param(
    [Parameter(Mandatory = $true)][string]$Origin,
    [string]$Root,
    [int]$Port = 43127
)

$ErrorActionPreference = 'Stop'
$originUri = [Uri]$Origin
if ($originUri.Scheme -notin @('http', 'https') -or $originUri.AbsolutePath -ne '/' -or $originUri.Query -or $originUri.Fragment -or $originUri.UserInfo) { throw 'Origin muss ein HTTP(S)-Ursprung ohne Pfad sein.' }
if ($originUri.Scheme -ne 'https' -and $originUri.Host -notin @('127.0.0.1', 'localhost')) { throw 'Oeffentliche Urspruenge erfordern HTTPS.' }
$Origin = $originUri.GetLeftPart([UriPartial]::Authority)
$localOrigin = "http://127.0.0.1:$Port"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("$localOrigin/")
$token = ''
$expires = [DateTime]::MinValue
$nonce = [Guid]::NewGuid().ToString('N')
$snapshot = $null
$documents = @{}
$fixedRoot = [bool]$Root
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('ai-os-connector-' + [Guid]::NewGuid().ToString('N'))
$worker = $null
$workProgress = @{ state = 'idle'; phase = 0; processed = 0; total = -1 }
$directorySyncedAt = $null
$directoryWatcher = $null
$watchEventIds = @()
$observedChanges = @{}
$pendingReconciliation = $false
. (Join-Path $PSScriptRoot 'document-state.ps1')

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
    if ($Refresh -and $script:documents.Count) {
        [IO.File]::WriteAllText($previousPath, (@($script:documents.Values) | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
    } elseif (Test-Path -LiteralPath $previousPath) { Remove-Item -LiteralPath $previousPath -Force }
    $started = [DateTime]::UtcNow.ToString('o')
    $script:workProgress = @{ state = 'running'; phase = 0; processed = 0; total = -1; started = $started; updated = $started; directory = $script:Root }
    $script:worker = Start-Job -ArgumentList (Join-Path $PSScriptRoot 'build.ps1'), $script:Root, $temporary, $started -ScriptBlock {
        param($buildPath, $selectedRoot, $outputDirectory, $started)
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
            $progress.directory = $selectedRoot
            $progress.events = @($events.ToArray())
            $pending = Join-Path $outputDirectory 'progress.pending'
            $destination = Join-Path $outputDirectory 'progress.json'
            [IO.File]::WriteAllText($pending, ($progress | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
            if ([IO.File]::Exists($destination)) { [IO.File]::Replace($pending, $destination, [System.Management.Automation.Language.NullString]::Value) }
            else { [IO.File]::Move($pending, $destination) }
        }
        try {
            Save-Progress @{ state = 'running'; phase = 0; processed = 0; total = -1; updated = [DateTime]::UtcNow.ToString('o') }
            if (-not $selectedRoot) {
                Add-Type -AssemblyName System.Windows.Forms
                $picker = New-Object System.Windows.Forms.FolderBrowserDialog
                $owner = New-Object System.Windows.Forms.Form
                $owner.TopMost = $true
                $owner.ShowInTaskbar = $false
                $picker.Description = 'Internes AI-OS-Verzeichnis auswaehlen'
                try {
                    $owner.Show()
                    if ($picker.ShowDialog($owner) -ne 'OK') { throw 'Auswahl abgebrochen' }
                    $selectedRoot = $picker.SelectedPath
                } finally { $picker.Dispose(); $owner.Dispose() }
            }
            $selectedRoot = (Resolve-Path -LiteralPath $selectedRoot).Path
            . (Join-Path (Split-Path $buildPath -Parent) 'document-state.ps1')
            $previousPath = Join-Path $outputDirectory 'previous.json'
            if (-not (Test-Path -LiteralPath $previousPath)) {
                $historyPath = Get-ReaderHistoryPath $selectedRoot
                if (Test-Path -LiteralPath $historyPath) {
                    $history = Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    [IO.File]::WriteAllText($previousPath, ($history.documents | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
                }
            }
            & $buildPath -Root $selectedRoot -OutputDirectory $outputDirectory -OnProgress {
                param($progress)
                $progress.state = 'running'
                Save-Progress $progress
            } -PreviousDocumentsPath $previousPath | Out-Null
            $inventory = Get-Content -LiteralPath (Join-Path $outputDirectory 'inventory.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $result = @{ directory = $selectedRoot; updated = $inventory.generated; inventory = $inventory } | ConvertTo-Json -Depth 20 -Compress
            [IO.File]::WriteAllText((Join-Path $outputDirectory 'snapshot.json'), $result, [Text.UTF8Encoding]::new($false))
            Remove-Item -LiteralPath (Join-Path $outputDirectory 'inventory.json') -Force
            Save-Progress @{ state = 'completed'; phase = 5; processed = 1; total = 1; updated = [DateTime]::UtcNow.ToString('o'); evaluated = @($inventory.files | Where-Object status -eq 'evaluated').Count; partial = @($inventory.files | Where-Object status -eq 'partial').Count; skipped = @($inventory.files | Where-Object status -eq 'skipped').Count; failedDocuments = @($inventory.files | Where-Object processingState -eq 'error').Count }
        } catch {
            Save-Progress @{ state = 'failed'; phase = [Math]::Max(0, $state.phase); processed = 0; total = -1; updated = [DateTime]::UtcNow.ToString('o'); errorId = $_.FullyQualifiedErrorId; error = 'Verzeichnisauswahl abgebrochen oder Indexaufbau fehlgeschlagen. Verzeichnis, Leserechte und lokale Dateien pruefen.' }
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
            Save-ReaderHistory -Directory $nextState.directory -Documents $nextDocuments -DirectorySyncedAt $nextState.directorySyncedAt
            $script:Root = $nextState.directory
            $script:directorySyncedAt = $nextState.directorySyncedAt
            $script:snapshot = $nextState | ConvertTo-Json -Depth 20 -Compress
            $script:documents = $nextDocuments
            Remove-Item -LiteralPath (Join-Path $temporary 'snapshot.json') -Force
            Remove-Item -LiteralPath (Join-Path $temporary 'documents.json') -Force
            if ($script:workKind -eq 'pair') {
                Start-ReaderWatcher
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
    $absolute = [IO.Path]::GetFullPath((Join-Path $Root $path))
    if (-not $absolute.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Pfad ausserhalb der Freigabe' }
    $entry = Get-Item -LiteralPath $absolute -Force
    if ($entry.PSIsContainer) { throw 'Keine Datei' }
    $ancestor = $entry
    while ($ancestor -and $ancestor.FullName -ne $Root.TrimEnd('\')) {
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
</style>
<h1>AI-OS lokal verbinden</h1><p>Freigabe fuer <strong id="origin"></strong></p>
<p class="detail">Lokale Verarbeitung &middot; Keine Veroeffentlichung auf GitHub</p>
<p class="directory" id="directory">Verzeichnis wird bei der Freigabe ausgewaehlt.</p>
<button id="approve">Verzeichnis freigeben</button>
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
async function request(path,method='GET'){const response=await fetch(path,{method,headers,cache:'no-store',signal:AbortSignal.timeout(5000)});const result=await response.json();if(!response.ok)throw Error(result.error||'Lokaler Dienst antwortet mit HTTP '+response.status);return result;}
function renderTopicProgress(result){renderTopicBuild(result);for(const [id,key] of [['topics-found','topicsFound'],['text-assignments','textAssignments'],['reference-assignments','referenceAssignments'],['topic-documents','documentsWithTopics']])element(id).textContent=result[key]??0;const separator=' \u00b7 ';element('topic-audit').textContent=(result.topicCandidates||0)+' Themenregeln'+separator+(result.rulesChecked||0)+' Regelpruefungen'+separator+(result.linksChecked||0)+' Dateiverweise geprueft';element('topic-labels').textContent=result.topicLabels?.length?'Zuletzt erkannt: '+result.topicLabels.slice(-3).join(separator):'Noch keine Themen mit Beleg';element('current').textContent=(result.detail?result.detail+'. ':'')+(result.current?'Aktuell: '+result.current:'');}
function renderZurichEvents(result){const items=[...element('events').children];(result.events||[]).forEach((event,index)=>{if(items[index])items[index].textContent=zurichTime(event.at)+' \u00b7 '+(event.state==='failed'?'Fehlgeschlagen':event.state==='completed'?'Index bereit':event.phase?labels[event.phase-1]:'Freigabe gestartet');});}
async function poll(){if(polling)return;polling=true;try{const result=await request('/progress');if(result.state==='idle')return;render(result);renderTopicProgress(result);if(result.state==='completed'&&result.token){location.replace(returnTarget+'#ai-os-token='+encodeURIComponent(result.token));return;}if(result.state==='running')setTimeout(poll,750);}catch(error){element('stale').textContent='Statusabfrage unterbrochen: '+error.message+'. Verarbeitung kann weiterlaufen; erneuter Versuch folgt.';element('stale').classList.add('error');if(active)setTimeout(poll,1500);}finally{polling=false;}}
const renderWithLocalTime=render;render=result=>{renderWithLocalTime(result);renderZurichEvents(result);};
element('approve').onclick=async()=>{element('approve').disabled=true;element('stale').classList.remove('error');try{render(await request('/approve','POST'));poll();}catch(error){element('status').textContent=error.message;element('status').classList.add('error');element('approve').disabled=false;}};
setInterval(timing,1000);poll();
</script></html>
'@
                $topicBuild = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'topic-progress.html'))
                $html = $html.Replace('__ORIGIN__', $target.Replace('<', '\u003c')).Replace('__RETURN__', $returnTarget.Replace('<', '\u003c')).Replace('__PAIRING__', $nonce).Replace('__TOPIC_BUILD__', $topicBuild)
                Send-Response $context 200 $html 'text/html; charset=utf-8'
                continue
            }
            if ($path -eq '/progress' -and $request.HttpMethod -eq 'GET' -and ($requestOrigin -eq $localOrigin -or -not $requestOrigin) -and $request.Headers['X-Pairing'] -eq $nonce) {
                Send-Response $context 200 (Get-IndexProgress)
                continue
            }
            if ($path -eq '/approve' -and $request.HttpMethod -eq 'POST' -and $requestOrigin -eq $localOrigin -and $request.Headers['X-Pairing'] -eq $nonce) {
                if ($worker) { Send-Response $context 409 '{"error":"Indexaufbau laeuft bereits"}'; continue }
                if (-not $fixedRoot) { $Root = '' }
                Start-IndexWorker
                Send-Response $context 202 (Get-IndexProgress)
                continue
            }
            if ($requestOrigin -ne $Origin -or -not $token -or $request.Headers['Authorization'] -cne "Bearer $token" -or [DateTime]::UtcNow -gt $expires) {
                Send-Response $context 403 '{"error":"Keine gueltige lokale Freigabe"}'
                continue
            }
            if ($path -eq '/document' -and $request.HttpMethod -eq 'GET') {
                $documentPath = $request.QueryString['path']
                if (-not $documentPath -or -not $documents.ContainsKey($documentPath)) { Send-Response $context 404 '{"error":"Dokument nicht im freigegebenen Index"}'; continue }
                $document = $documents[$documentPath]
                $result = @{ path = $document.path; title = $document.title; status = $document.status; reason = $document.reason; extraction = $document.extraction; text = $document.text; modified = $document.modified; headings = @(Get-DocumentHeadings $document.text); documentState = (Get-ReaderFileState $documentPath); canEditInCode = ([IO.Path]::GetExtension($documentPath).ToLowerInvariant() -in @('.md', '.txt', '.json', '.yaml', '.yml', '.csv', '.html', '.htm', '.xml', '.eml')) }
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
                        $results.Add(@{ path = $document.path; status = $document.status; snippets = $snippets })
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
            if ($path -eq '/session' -and $request.HttpMethod -eq 'GET') { Send-Response $context 200 $snapshot }
            elseif ($path -eq '/status' -and $request.HttpMethod -eq 'GET') {
                $null = Get-IndexProgress
                Check-ReaderChanges $request.QueryString['path']
                $currentSnapshot = $snapshot | ConvertFrom-Json
                $result = @{ connected = $true; revision = $currentSnapshot.revision; directorySyncedAt = $directorySyncedAt; processing = [bool]$worker; processingState = $workProgress.state; error = $workProgress.error }
                if ($request.QueryString['path']) { $result.documentState = Get-ReaderFileState $request.QueryString['path'] }
                Send-Response $context 200 ($result | ConvertTo-Json -Depth 8 -Compress)
            }
            elseif ($path -eq '/progress' -and $request.HttpMethod -eq 'GET' -and $workKind -eq 'refresh') { Send-Response $context 200 (Get-IndexProgress) }
            elseif ($path -eq '/refresh' -and $request.HttpMethod -eq 'POST') {
                if ($worker) { Send-Response $context 409 '{"error":"Indexaufbau laeuft bereits"}'; continue }
                Start-IndexWorker -Refresh
                Send-Response $context 202 (Get-IndexProgress)
            }
            elseif ($path -eq '/disconnect' -and $request.HttpMethod -eq 'POST') {
                Stop-ReaderWatcher
                if ($worker) { Remove-Job -Job $worker -Force; $worker = $null }
                $token = ''; $snapshot = $null; $documents = @{}; $observedChanges = @{}; $pendingReconciliation = $false; $nonce = [Guid]::NewGuid().ToString('N')
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