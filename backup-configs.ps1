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

$saved = 0; $skippedList = @(); $failedList = @()
foreach ($entry in $map) {
    $from = Expand-ConfigPath $entry.Target
    $to = Join-Path $root $entry.Repo
    if (-not (Test-Path $from)) {
        Write-Host "skip   $($entry.App): $from not found" -ForegroundColor Yellow
        $skippedList += "  - $($entry.App): $(Split-Path $from -Leaf) not found"
        continue
    }

    $running = @($entry.StopProcesses | Where-Object { $_ } | ForEach-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
    if ($running) {
        Write-Host "Close $($entry.App) first (running: $(($running.Name | Sort-Object -Unique) -join ', ')), then press Enter." -ForegroundColor Yellow
        [void](Read-Host)
    }

    try {
        if (Test-Path $to) { Remove-Item $to -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
        Copy-Item $from $to -Recurse -Force
        Write-Host "saved  $($entry.App): $from" -ForegroundColor Green
        $saved++
    } catch {
        Write-Host "FAILED $($entry.App): $($_.Exception.Message)" -ForegroundColor Red
        $failedList += "  - $($entry.App): $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host 'Done. Check the configs folder for anything private, then commit and push:' -ForegroundColor Cyan
Write-Host '  git add configs; git commit -m "Back up configs"; git push'

$msg = "$saved config item(s) saved to the configs folder."
if ($skippedList) { $msg += "`n`nNot found on this PC (skipped):`n" + ($skippedList -join "`n") }
if ($failedList)  { $msg += "`n`nFailed:`n" + ($failedList -join "`n") + "`n`nClose those apps and run the backup again." }
$msg += "`n`nBefore uploading, delete any service.json in configs\obs-studio\basic\profiles (it holds your stream key)."
if ($failedList) {
    Show-FinalMessage -Warning -Title 'pc-setup backup: finished with problems' -Message $msg
} else {
    Show-FinalMessage -Title 'pc-setup backup: completed successfully' -Message $msg
}
