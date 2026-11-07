<#
.SYNOPSIS
    Run this on the CURRENT install, before wiping. It copies the config files
    listed in configs\map.json into this folder so you can commit and push them.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Download.ps1')
$map = Get-Content (Join-Path $PSScriptRoot 'configs\map.json') -Raw | ConvertFrom-Json

foreach ($entry in $map) {
    $from = Expand-ConfigPath $entry.Target
    $to = Join-Path $PSScriptRoot $entry.Repo
    if (-not (Test-Path $from)) { Write-Host "skip   $($entry.App): $from not found" -ForegroundColor Yellow; continue }

    $running = @($entry.StopProcesses | Where-Object { $_ } | ForEach-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
    if ($running) {
        Write-Host "Close $($entry.App) first (running: $(($running.Name | Sort-Object -Unique) -join ', ')), then press Enter." -ForegroundColor Yellow
        [void](Read-Host)
    }

    if (Test-Path $to) { Remove-Item $to -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
    Copy-Item $from $to -Recurse -Force
    if ($entry.Scrub) { Remove-Secrets -File $to -Pattern $entry.Scrub }   # keep API keys out of the public repo
    Write-Host "saved  $($entry.App): $from" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done. Check the configs folder for anything private, then commit and push:' -ForegroundColor Cyan
Write-Host '  git add configs; git commit -m "Back up configs"; git push'
