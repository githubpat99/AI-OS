param()
$ErrorActionPreference = 'Stop'
$public = Join-Path $PSScriptRoot 'public'
$allowed = @('index.html', '.nojekyll', '.github/workflows/pages.yml')
if (Test-Path -LiteralPath $public) {
    foreach ($file in (Get-ChildItem -LiteralPath $public -File -Recurse -Force)) {
        $relative = $file.FullName.Substring($public.Length + 1).Replace('\', '/')
        if ($relative -notin $allowed) { throw "Unerwartete Datei im Veroeffentlichungsordner: $relative" }
    }
}
$definitions = @(
    @('architektur', 'Architektur und Transformation', 'Technologie', 'Zielbild 2030', 'Architekturentscheid', 'Zielarchitektur und Transformation des fiktiven Beispielbetriebs.'),
    @('pv', 'Photovoltaik und Speicher', 'Private Dossiers', 'Solardach Musterhaus', 'Speichervergleich', 'Photovoltaik und Batteriespeicher fuer ein fiktives Musterhaus.'),
    @('entscheidung', 'Entscheidungs- und Risikobewertung', 'Entscheidung und Lieferung', 'Investitionsentscheid', 'Risikobewertung', 'Fiktive Entscheidungsgrundlage mit Risiken und Alternativen.'),
    @('quellen', 'Quellenarbeit und Wissenspflege', 'Arbeitsorganisation', 'Wissensregister', 'Quellenpruefung', 'Fiktives Quellenregister fuer nachvollziehbare Wissenspflege.')
)
$topics = @(); $files = @()
foreach ($definition in $definitions) {
    $paths = @()
    foreach ($title in $definition[3..4]) {
        $path = 'AI-Beispiel-OS/' + $definition[0] + '/' + $title.Replace(' ', '-') + '.md'
        $paths += $path
        $files += [ordered]@{
            path = $path; title = $title; name = $title + '.md'; organisation = 'AI-Beispiel-OS'
            extension = '.md'; bytes = 1024; modified = '2026-01-01T00:00:00Z'; status = 'evaluated'
            reason = ''; extraction = 'Kuenstliche Beispieldaten'; hash = ''; roles = @('Wissen')
            topics = @(@{ id = $definition[0]; proposed = $true; basis = 'Textbeleg'; evidence = $definition[5]; evidencePath = $path; hits = 1 })
            links = @(); externalLinks = @()
        }
    }
    $topics += @{ id = $definition[0]; label = $definition[1]; group = $definition[2]; count = 2; evidenceFiles = $paths }
}
$demo = @{ generated = '2026-01-01T00:00:00Z'; method = 'Kuenstliche Beispieldaten, keine internen Inhalte.'; topics = $topics; files = $files; excludedDirectories = @() }
$json = ($demo | ConvertTo-Json -Depth 15 -Compress).Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
$template = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'map.template.html'))
if (-not $template.Contains('__MAP_DATA__')) { throw 'Datenmarker fehlt' }
[System.IO.Directory]::CreateDirectory((Join-Path $public '.github/workflows')) | Out-Null
$encoding = [System.Text.UTF8Encoding]::new($false)
$reader = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'document-reader.html'))
$topicBuild = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'topic-progress.html'))
$html = $template.Replace('__MAP_DATA__', $json).Replace('__DOCUMENT_READER__', $reader).Replace('__TOPIC_BUILD__', $topicBuild)
[System.IO.File]::WriteAllText((Join-Path $public 'index.html'), $html, $encoding)
[System.IO.File]::WriteAllText((Join-Path $public '.nojekyll'), '', $encoding)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'deploy.pages.yml') -Destination (Join-Path $public '.github/workflows/pages.yml') -Force
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'index.html'), $html, $encoding)
Write-Output 'PUBLIC_BUILD_OK: Nur feste Beispieldaten; public/ ist das separate GitHub-Pages-Paket.'