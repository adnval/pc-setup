# Installs Microsoft 365 apps with the Office Deployment Tool (ODT), using
# Configuration.xml next to this script. Called by setup.ps1 (-Only Office).
#
# Configuration.xml: 64-bit, Current channel, Microsoft 365 Apps (no Teams),
# without Access, OneDrive, OneNote, Outlook, Publisher, Skype/Lync and Groove.
# Office auto-updates are turned off, older MSI Office is removed, and the
# installer window is shown with the license already accepted.

$ErrorActionPreference = 'Stop'
$config = Join-Path $PSScriptRoot 'Configuration.xml'
if (-not (Test-Path $config)) { throw "Missing $config" }

# Microsoft's permanent link to the latest ODT setup.exe.
$work = Join-Path $env:TEMP 'pc-setup\office'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$setup = Join-Path $work 'setup.exe'
Invoke-WebRequest -UseBasicParsing -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile $setup

$sig = Get-AuthenticodeSignature $setup
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw "ODT setup.exe signature check failed ($($sig.Status), $($sig.SignerCertificate.Subject))"
}

Write-Host '    Installing Office (it downloads ~3 GB; the Office window shows progress)...'
$p = Start-Process $setup -ArgumentList "/configure `"$config`"" -WorkingDirectory $work -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "Office Deployment Tool exited with code $($p.ExitCode)" }
