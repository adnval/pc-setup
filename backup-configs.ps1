<#
.SYNOPSIS
    Run on the current install, before wiping: copies each app's configs (its "configs"
    in apps.json) from this PC into the configs\ folder, ready to upload. No admin needed.
    Shortcut for: .\setup.ps1 -Backup

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\backup-configs.ps1
#>
$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }   # empty when pasted or run from the ISE
& (Join-Path $here 'setup.ps1') -Backup @args
