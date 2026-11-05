param([int]$Port = 43128, [int]$ConnectorPort = 43127)
$ErrorActionPreference = 'Stop'
$public = Join-Path $PSScriptRoot 'public'
if (-not (Test-Path (Join-Path $public 'index.html'))) { throw 'Zuerst publish.ps1 ausfuehren.' }
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
    Write-Host "Themenlandkarte: http://127.0.0.1:$Port"
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $response = $context.Response
        $response.Headers['Cache-Control'] = 'no-store'
        if ($context.Request.Url.AbsolutePath -in @('/', '/index.html')) {
            $response.ContentType = 'text/html; charset=utf-8'
            $html = [System.IO.File]::ReadAllText((Join-Path $public 'index.html')).Replace('http://127.0.0.1:43127', "http://127.0.0.1:$ConnectorPort")
            $bytes = [Text.Encoding]::UTF8.GetBytes($html)
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else { $response.StatusCode = 404 }
        $response.Close()
    }
} finally { $listener.Close() }