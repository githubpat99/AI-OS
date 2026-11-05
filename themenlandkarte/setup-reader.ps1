param()
$ErrorActionPreference = 'Stop'
$homeDirectory = Join-Path $env:LOCALAPPDATA 'AI-OS\Themenlandkarte'
$tools = Join-Path $homeDirectory 'tools'
$runtime = Join-Path $homeDirectory 'runtime'
$uv = Join-Path $tools 'uv.exe'
[IO.Directory]::CreateDirectory($tools) | Out-Null
if (-not (Test-Path -LiteralPath $uv)) {
    $archive = Join-Path $tools 'uv.zip'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/astral-sh/uv/releases/download/0.9.9/uv-x86_64-pc-windows-msvc.zip' -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $tools -Force
    Remove-Item -LiteralPath $archive -Force
}
$pythonDirectory = Join-Path $homeDirectory 'python'
$python = Join-Path $pythonDirectory 'python/python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    [IO.Directory]::CreateDirectory($pythonDirectory) | Out-Null
    $archive = Join-Path $tools 'python.tar.gz'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/astral-sh/python-build-standalone/releases/download/20251031/cpython-3.12.12%2B20251031-x86_64-pc-windows-msvc-install_only_stripped.tar.gz' -OutFile $archive -TimeoutSec 180
    & tar.exe -xzf $archive -C $pythonDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Lokale Python-Installation fehlgeschlagen' }
    Remove-Item -LiteralPath $archive -Force
}
& {
    if (-not (Test-Path -LiteralPath (Join-Path $runtime 'Scripts/python.exe'))) {
        & $uv venv $runtime --python $python --no-python-downloads
        if ($LASTEXITCODE -ne 0) { throw 'Leser-Laufzeit konnte nicht erstellt werden' }
    }
    $target = [Uri]'https://pypi.org/simple/'
    $proxy = [Net.WebRequest]::DefaultWebProxy.GetProxy($target)
    $previousProxy = $env:HTTPS_PROXY
    try {
        if ($proxy.AbsoluteUri -ne $target.AbsoluteUri) { $env:HTTPS_PROXY = $proxy.AbsoluteUri }
        & $uv --native-tls pip install --python (Join-Path $runtime 'Scripts/python.exe') -r (Join-Path $PSScriptRoot 'requirements.txt')
        if ($LASTEXITCODE -ne 0) { throw 'Dokumentparser konnten nicht installiert werden' }
    } finally { $env:HTTPS_PROXY = $previousProxy }
    Write-Output 'READER_RUNTIME_READY: Lokale Parser und OCR installiert; keine Dokumente hochgeladen.'
}