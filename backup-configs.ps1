<#
.SYNOPSIS
    Run on the current install, before wiping. Copies each app's configs (its "configs"
    in apps.json) from this PC into the configs\ folder, ready to upload. No admin needed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\backup-configs.ps1
#>
$ErrorActionPreference = 'Stop'

# The repo folder. $PSScriptRoot is empty if the script was pasted in or run from the ISE.
$root = $PSScriptRoot
if (-not $root -and $MyInvocation.MyCommand.Path) { $root = Split-Path $MyInvocation.MyCommand.Path }
if (-not $root) { $root = (Get-Location).Path }

$AppsFile   = Join-Path $root 'apps.json'
$ConfigsDir = Join-Path $root 'configs'


# =============================================================================
#  Console output  (same look as setup.ps1)
# =============================================================================

function Write-Step($text)    { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Write-Done($text)    { Write-Host "    $text" }
function Write-Note($text)    { Write-Host "    $text" -ForegroundColor DarkGray }
function Write-Failure($text) { Write-Host "    FAILED $text" -ForegroundColor Red }

# Message box on top of every window, so the end of the run gets noticed.
function Show-FinalMessage {
    param([string]$Title, [string]$Message, [switch]$Warning)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
        $icon = if ($Warning) { 'Warning' } else { 'Information' }
        [void][System.Windows.Forms.MessageBox]::Show($owner, $Message, $Title, 'OK', $icon)
        $owner.Dispose()
    } catch {
        [void](Read-Host "`n$Title - press Enter to close")
    }
}


# =============================================================================
#  Backing up
# =============================================================================

# Waits until none of the app's "close" processes are running: an open app may have
# its files half-written or locked.
function Wait-AppClosed($app) {
    while ($true) {
        $running = @($app.close | Where-Object { $_ } | ForEach-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
        if (-not $running) { return }
        Write-Host "    Close $($app.name) ($(($running.Name | Sort-Object -Unique) -join ', ')), then press Enter." -ForegroundColor Yellow
        [void](Read-Host)
    }
}

# Copies one config ("path inside configs\": "path on this PC") into the repo.
function Save-Config($from, $to) {
    if (Test-Path $to) { Remove-Item $to -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
    Copy-Item $from $to -Recurse -Force
}


# =============================================================================
#  Main
# =============================================================================

if (-not (Test-Path -LiteralPath $AppsFile -PathType Leaf)) {
    Write-Host "Can't find $AppsFile" -ForegroundColor Red
    Write-Host 'Run this from inside the pc-setup folder (the one with apps.json):'
    Write-Host '  powershell -ExecutionPolicy Bypass -File .\backup-configs.ps1'
    exit 1
}
$apps = @(([IO.File]::ReadAllText($AppsFile) | ConvertFrom-Json).apps | Where-Object { $_.configs })

$saved = @(); $notFound = @(); $failed = @()
foreach ($app in $apps) {
    Write-Step $app.name
    Wait-AppClosed $app
    foreach ($config in $app.configs.PSObject.Properties) {
        $from = [Environment]::ExpandEnvironmentVariables($config.Value)
        $to   = Join-Path $ConfigsDir $config.Name
        if (-not (Test-Path $from)) {
            Write-Note "Not on this PC: $from"
            $notFound += "$($app.name): $($config.Name)"
            continue
        }
        try {
            Save-Config $from $to
            Write-Done "Saved $($config.Name)"
            $saved += $config.Name
        } catch {
            Write-Failure "$($config.Name): $($_.Exception.Message)"
            $failed += "$($app.name): $($config.Name): $($_.Exception.Message)"
        }
    }
}

# OBS keeps the stream key in service.json, which must not go into a public repo.
$streamKeys = @(Get-ChildItem $ConfigsDir -Recurse -Filter 'service.json' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('\', '/') })

# Summary
Write-Step 'Summary'
Write-Done ('{0,-15} {1}' -f 'Saved:', $saved.Count)
if ($notFound) { Write-Note ('{0,-15} {1}' -f 'Not on this PC:', ($notFound -join ', ')) }
foreach ($line in $failed) { Write-Failure $line }
foreach ($file in $streamKeys) { Write-Host "    Delete before uploading (stream key): $file" -ForegroundColor Yellow }
Write-Done 'Next: upload the configs folder to GitHub (Add file > Upload files).'

$message = "$($saved.Count) config(s) saved to the configs folder."
if ($notFound)   { $message += "`n`nNot on this PC (skipped):`n" + (($notFound | ForEach-Object { "  - $_" }) -join "`n") }
if ($failed)     { $message += "`n`nFailed:`n" + (($failed | ForEach-Object { "  - $_" }) -join "`n") + "`n`nClose those apps and run the backup again." }
if ($streamKeys) { $message += "`n`nDelete before uploading (it holds your stream key):`n" + (($streamKeys | ForEach-Object { "  - $_" }) -join "`n") }
$title = if ($failed) { 'pc-setup backup: finished with problems' } else { 'pc-setup backup: done' }
Show-FinalMessage -Title $title -Message $message -Warning:([bool]($failed -or $streamKeys))
