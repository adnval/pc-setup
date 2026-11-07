# One-line entry point. On a fresh Windows install, open PowerShell and run:
#   irm https://raw.githubusercontent.com/adnval/pc-setup/main/bootstrap.ps1 | iex
#
# Downloads this repo as a zip, unpacks it to %TEMP%\pc-setup, and starts setup.ps1 (as admin).

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

Start-Process powershell.exe -Verb RunAs -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$root\setup.ps1`""
)
