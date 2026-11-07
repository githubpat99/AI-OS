# Wiederverwendbare Backend-Fassade fuer die Aufnahme-Pipeline.
# Alle Funktionen arbeiten ausschliesslich mit der uebergebenen bzw. aktiven
# Wissensbasis-Konfiguration. Es gibt keine kundenspezifischen Pfade.

function Get-IngestionConfig {
    return Get-PocConfiguration
}

function Invoke-IngestionCapture {
    param($Config)
    if (-not $Config) { $Config = Get-PocConfiguration }
    $raw = Copy-PocRaw $Config
    $provenance = Copy-PocProvenance $Config
    return [ordered]@{ raw = $raw; provenance = $provenance }
}

function Invoke-IngestionIndex {
    param($Config)
    if (-not $Config) { $Config = Get-PocConfiguration }
    return Invoke-PocImport $Config
}

function Invoke-IngestionSynthesis {
    param($Config, $Evidence)
    if (-not $Config) { $Config = Get-PocConfiguration }
    return Invoke-PocAiSynthesis $Config $Evidence
}

function Build-IngestionPage {
    param($Config, $Parsed, $Evidence)
    if (-not $Config) { $Config = Get-PocConfiguration }
    return Build-PocPage $Config $Parsed $Evidence
}

function Save-IngestionKnowledge {
    param($Config, $Page, $Evidence, $Existing)
    if (-not $Config) { $Config = Get-PocConfiguration }
    return Save-PocKnowledge $Config $Page $Evidence $Existing
}

function Invoke-IngestionRun {
    param([switch]$ConfirmExternalAi, [switch]$Resume)
    return Invoke-PocRun -ConfirmExternalAi:$ConfirmExternalAi -Resume:$Resume
}

function Start-IngestionJob {
    param([bool]$ConfirmExternalAi, [switch]$Resume)
    return Start-PocBackgroundRun -ConfirmExternalAi:$ConfirmExternalAi -Resume:$Resume
}

function Get-IngestionJob {
    return Get-PocPublicState
}

function Resume-IngestionJob {
    param([bool]$ConfirmExternalAi)
    return Start-PocBackgroundRun -ConfirmExternalAi:$ConfirmExternalAi -Resume
}
