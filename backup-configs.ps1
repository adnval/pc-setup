<#
.SYNOPSIS
    Run this on the CURRENT install, before wiping. It copies every app's config files
    (the "configs" of each app in apps.json) from this PC into the configs\ folder, so you
    can commit and push them. No admin needed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\backup-configs.ps1
#>
$ErrorActionPreference = 'Stop'

# The repo folder. $PSScriptRoot is empty if the script was pasted in or run from the ISE.
$root = $PSScriptRoot
if (-not $root -and $MyInvocation.MyCommand.Path) { $root = Split-Path $MyInvocation.MyCommand.Path }
if (-not $root) { $root = (Get-Location).Path }

$appsFile   = Join-Path $root 'apps.json'
$configsDir = Join-Path $root 'configs'
if (-not (Test-Path -LiteralPath $appsFile -PathType Leaf)) {
    Write-Host "Can't find $appsFile" -ForegroundColor Red
    Write-Host 'Run this from inside the pc-setup folder (the one with apps.json):' -ForegroundColor Yellow
    Write-Host '  powershell -ExecutionPolicy Bypass -File .\backup-configs.ps1'
    exit 1
}
$apps = ([IO.File]::ReadAllText($appsFile) | ConvertFrom-Json).apps

$saved = 0; $notFound = @(); $failed = @()
foreach ($app in $apps) {
    if (-not $app.configs) { continue }

    # The app must be closed, or its files may be half-written or locked.
    $running = @($app.close | Where-Object { $_ } | ForEach-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
    if ($running) {
        Write-Host "Close $($app.name) first (running: $(($running.Name | Sort-Object -Unique) -join ', ')), then press Enter." -ForegroundColor Yellow
        [void](Read-Host)
    }

    # configs: "path inside configs\": "path on this PC"
    foreach ($config in $app.configs.PSObject.Properties) {
        $from = [Environment]::ExpandEnvironmentVariables($config.Value)
        $to   = Join-Path $configsDir $config.Name

        if (-not (Test-Path $from)) {
            Write-Host "skip   $($app.name): $from not found" -ForegroundColor Yellow
            $notFound += "  - $($app.name): $(Split-Path $from -Leaf)"
            continue
        }
        try {
            if (Test-Path $to) { Remove-Item $to -Recurse -Force }
            New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
            Copy-Item $from $to -Recurse -Force
            Write-Host "saved  $($app.name): $from" -ForegroundColor Green
            $saved++
        } catch {
            Write-Host "FAILED $($app.name): $($_.Exception.Message)" -ForegroundColor Red
            $failed += "  - $($app.name): $($_.Exception.Message)"
        }
    }
}

Write-Host ''
Write-Host 'Done. Check the configs folder for anything private, then commit and push:' -ForegroundColor Cyan
Write-Host '  git add configs; git commit -m "Back up configs"; git push'

# Final pop-up, on top of all windows.
$message = "$saved config item(s) saved to the configs folder."
if ($notFound) { $message += "`n`nNot found on this PC (skipped):`n" + ($notFound -join "`n") }
if ($failed)   { $message += "`n`nFailed:`n" + ($failed -join "`n") + "`n`nClose those apps and run the backup again." }
$message += "`n`nBefore uploading, delete any service.json in configs\obs-studio\basic\profiles (it holds your stream key)."
$title = if ($failed) { 'pc-setup backup: finished with problems' } else { 'pc-setup backup: completed successfully' }
try {
    Add-Type -AssemblyName System.Windows.Forms
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    $icon = if ($failed) { 'Warning' } else { 'Information' }
    [void][System.Windows.Forms.MessageBox]::Show($owner, $message, $title, 'OK', $icon)
    $owner.Dispose()
} catch {
    Write-Host "`n$message"
    [void](Read-Host "$title - press Enter to close")
}
