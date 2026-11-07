<#
.SYNOPSIS
    Run this on the CURRENT install, before wiping. It copies the config files
    listed in configs\map.json into this folder so you can commit and push them.
#>
$ErrorActionPreference = 'Stop'

# The repo folder (the one holding configs\ and lib\). $PSScriptRoot is empty when
# the script is pasted in or run from the ISE, so fall back to other options.
$root = $PSScriptRoot
if (-not $root -and $MyInvocation.MyCommand.Path) { $root = Split-Path $MyInvocation.MyCommand.Path }
if (-not $root) { $root = (Get-Location).Path }

$mapFile = Join-Path $root 'configs\map.json'
$libFile = Join-Path $root 'lib\Download.ps1'
foreach ($need in $mapFile, $libFile) {
    if (-not (Test-Path -LiteralPath $need -PathType Leaf)) {
        Write-Host "Can't find $need" -ForegroundColor Red
        Write-Host 'Run this from inside the extracted pc-setup-main folder (the one with the configs and lib folders):' -ForegroundColor Yellow
        Write-Host '  powershell -ExecutionPolicy Bypass -File .\backup-configs.ps1'
        exit 1
    }
}

. $libFile
# [IO.File]::ReadAllText instead of Get-Content -Raw: works in every PowerShell version.
$map = [IO.File]::ReadAllText($mapFile) | ConvertFrom-Json

foreach ($entry in $map) {
    $from = Expand-ConfigPath $entry.Target
    $to = Join-Path $root $entry.Repo
    if (-not (Test-Path $from)) { Write-Host "skip   $($entry.App): $from not found" -ForegroundColor Yellow; continue }

    $running = @($entry.StopProcesses | Where-Object { $_ } | ForEach-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
    if ($running) {
        Write-Host "Close $($entry.App) first (running: $(($running.Name | Sort-Object -Unique) -join ', ')), then press Enter." -ForegroundColor Yellow
        [void](Read-Host)
    }

    if (Test-Path $to) { Remove-Item $to -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
    Copy-Item $from $to -Recurse -Force
    Write-Host "saved  $($entry.App): $from" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done. Check the configs folder for anything private, then commit and push:' -ForegroundColor Cyan
Write-Host '  git add configs; git commit -m "Back up configs"; git push'
