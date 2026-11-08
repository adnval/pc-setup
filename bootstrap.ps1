# One-line entry point. On a fresh Windows install, open PowerShell and run:
#   irm https://raw.githubusercontent.com/adnval/pc-setup/main/bootstrap.ps1 | iex
#
# Downloads this repo as a zip and unpacks it to %TEMP%\pc-setup, then runs setup.ps1:
#   - from a PowerShell that is already running as admin: right here, in this window
#   - otherwise: in a new admin window (Windows can't raise an existing window to admin)
#
# Everything runs inside & { } so its settings don't leak into your PowerShell session.

& {
    $Repo   = 'adnval/pc-setup'
    $Branch = 'main'

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $work = Join-Path $env:TEMP 'pc-setup'
    $zip  = Join-Path $env:TEMP 'pc-setup.zip'
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }

    Write-Host "Downloading $Repo ($Branch)..." -ForegroundColor Cyan
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $work -Force
    Remove-Item $zip

    $root = (Get-ChildItem $work -Directory | Select-Object -First 1).FullName
    Get-ChildItem $root -Recurse -File | Unblock-File
    $setup = Join-Path $root 'setup.ps1'

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        Write-Host 'Already running as admin: starting setup in this window.' -ForegroundColor Cyan
        # Allow running the downloaded .ps1 files for this PowerShell session only.
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
        & $setup
    } else {
        Write-Host 'Opening an admin PowerShell window for setup (approve the UAC prompt)...' -ForegroundColor Cyan
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$setup`""
        )
    }
}
