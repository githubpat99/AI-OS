param(
    [string]$ReportPath = 'C:\AI-OS-Pilot\flurgenossenschaft\reports\ask-five.json'
)
$ErrorActionPreference = 'Stop'
$connector = 'http://127.0.0.1:43127'
$origin = 'http://127.0.0.1:43128'

# Pair with the running connector (the connector must be started with -WissensbasisConfig).
$html = curl.exe -s "$connector/pair?app=$([uri]::EscapeDataString($origin + '/'))"
$nonce = [regex]::Match($html, "X-Pairing':'([^']+)'").Groups[1].Value
if (-not $nonce) { throw 'Pairing-Nonce nicht gefunden; laeuft connector.ps1?' }
$null = curl.exe -s -X POST -H "Origin: $connector" -H "X-Pairing: $nonce" -H "Content-Length: 0" "$connector/approve"
$token = $null
for ($i = 0; $i -lt 40 -and -not $token; $i++) {
    Start-Sleep -Milliseconds 300
    $progress = curl.exe -s -H "Origin: $connector" -H "X-Pairing: $nonce" "$connector/progress" | ConvertFrom-Json
    if ($progress.state -eq 'failed') { throw $progress.error }
    $token = $progress.token
}
if (-not $token) { throw 'Kein Token vom Connector erhalten.' }

$headers = @{ Origin = $origin; Authorization = 'Bearer ' + $token }
$questions = @(
    'Welche Strassensanierung ist vorgesehen und in welche Etappen ist sie gegliedert?',
    'Welche Kosten sind für die Strassensanierung dokumentiert?',
    'Was ist bei der Strassensanierung bereits beschlossen und was ist nur vorgeschlagen?',
    'Was ist bei Retention und Etappierung noch offen?',
    'Ist die Einladung zur HV 2026 nachweislich versandt worden?'
)
$results = @()
foreach ($question in $questions) {
    $body = @{ question = $question; history = @() } | ConvertTo-Json -Depth 4
    $answer = Invoke-RestMethod -Uri "$connector/kb/ask" -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 120
    $results += [ordered]@{
        question = $question
        mode = $answer.mode
        answer = $answer.answer
        citations = @($answer.citations).Count
        citationPaths = @($answer.citations | ForEach-Object { $_.path }) -join '; '
        missing = @($answer.missing) -join ' | '
        follow_up = $answer.follow_up
    }
    Write-Output ('=== ' + $question)
    Write-Output ('MODE ' + $answer.mode + ' | CITATIONS ' + @($answer.citations).Count)
    Write-Output ([string]$answer.answer).Substring(0, [Math]::Min(360, ([string]$answer.answer).Length))
    Write-Output ('PATHS: ' + (@($answer.citations | ForEach-Object { $_.path }) -join '; '))
    Write-Output ('MISSING: ' + (@($answer.missing) -join ' | '))
}
$results | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
Write-Output ('REPORT: ' + $ReportPath)
