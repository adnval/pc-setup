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
# Save-Download and Invoke-Installer come from lib\Download.ps1 (loaded by setup.ps1).
$setup = Save-Download -Url 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -FileName 'odt-setup.exe'

$sig = Get-AuthenticodeSignature $setup
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw "ODT setup.exe signature check failed ($($sig.Status), $($sig.SignerCertificate.Subject))"
}

Write-Host '    Office downloads ~3 GB; its own window shows detailed progress.'
# -Hidden: the ODT setup.exe is a console program and would otherwise open an empty
# console window. Office's own installer window (Display Level="Full") still appears.
Invoke-Installer -Path $setup -Arguments "/configure `"$config`"" -Hidden
