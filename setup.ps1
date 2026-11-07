<#
.SYNOPSIS
    Installs my programs from their official sources and restores my config files.
.EXAMPLE
    .\setup.ps1                     # everything
    .\setup.ps1 -Only OBS,Discord   # just these
    .\setup.ps1 -Skip LGHub         # everything except these
    .\setup.ps1 -ConfigsOnly        # only copy configs back
    .\setup.ps1 -DryRun             # show what would be downloaded, change nothing
#>
param(
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$ConfigsOnly,
    [switch]$SkipConfigs,
    [switch]$DryRun,
    [switch]$Force   # reinstall even if already installed
)

# Allow "-Only OBS,Discord" to arrive as one string (it does when relaunched with -File).
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Skip = @($Skip | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the progress bar makes downloads much slower in PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Re-launch as administrator if needed ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value) { $argList += "-$($kv.Key)" } }
        else { $argList += "-$($kv.Key)"; $argList += ($kv.Value -join ',') }
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    return
}

. (Join-Path $PSScriptRoot 'lib\Download.ps1')
. (Join-Path $PSScriptRoot 'apps.ps1')

$results = @()

function Add-Result($name, $status, $detail) {
    $script:results += [pscustomobject]@{ App = $name; Result = $status; Detail = $detail }
}

# --- Install programs ---
if (-not $ConfigsOnly) {
    foreach ($app in $Apps) {
        if ($Only -and $Only -notcontains $app.Name) { continue }
        if ($Skip -and $Skip -contains $app.Name) { continue }

        Write-Step $app.Name
        try {
            $installed = if ($app.Detect -match '^[A-Za-z]:\\') { Test-Path $app.Detect } else { Test-Installed $app.Detect }
            if ($installed -and -not $Force) { Write-Ok 'Already installed, skipping'; Add-Result $app.Name 'Skipped' 'already installed'; continue }

            if ($app.Type -eq 'script') {
                if ($DryRun) { Add-Result $app.Name 'DryRun' 'runs its own install script'; continue }
                & $app.Run
                Add-Result $app.Name 'OK' 'started'
                continue
            }

            $src = & $app.Resolve
            Write-Ok "Source: $($src.Url)"
            if ($DryRun) {
                $size = ''
                try {
                    $h = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $src.Url
                    if ($h.Headers['Content-Length']) { $size = '{0:N1} MB' -f ([double]$h.Headers['Content-Length'] / 1MB) }
                } catch { $size = "HEAD failed: $($_.Exception.Message)" }
                Add-Result $app.Name 'DryRun' "$($src.Name) $size"
                continue
            }

            $file = Save-Download -Url $src.Url -FileName $src.Name -Sha256 $src.Sha256

            switch ($app.Type) {
                'exe'    { Invoke-Installer -Path $file -Arguments $app.Args }
                'msi'    { Invoke-Installer -Path $file }
                'zipmsi' {
                    $dir = Join-Path $script:Downloads ($app.Name + '_msi')
                    Expand-Archive -Path $file -DestinationPath $dir -Force
                    $msi = Get-ChildItem $dir -Recurse -Filter *.msi | Select-Object -First 1
                    if (-not $msi) { throw 'No .msi found inside the zip' }
                    Invoke-Installer -Path $msi.FullName
                }
                'portable' {
                    $dest = Expand-ToTools -Archive $file -Name $app.Name
                    New-StartMenuShortcut -Name $app.Name -Target (Join-Path $dest $app.Exe)
                }
                default  { throw "Unknown type $($app.Type)" }
            }
            Write-Ok 'Installed'
            Add-Result $app.Name 'OK' $src.Name
        } catch {
            Write-Warn2 "FAILED: $($_.Exception.Message)"
            Add-Result $app.Name 'FAILED' $_.Exception.Message
        }
    }
}

# --- Office (placeholder) ---
$officeScript = Join-Path $PSScriptRoot 'office\install-office.ps1'
if (-not $ConfigsOnly -and -not $DryRun -and (Test-Path $officeScript) -and
    (-not $Only -or $Only -contains 'Office') -and -not ($Skip -contains 'Office')) {
    Write-Step 'Office'
    try { & $officeScript; Add-Result 'Office' 'OK' '' } catch { Add-Result 'Office' 'FAILED' $_.Exception.Message }
}

# --- Restore configs ---
if (-not $SkipConfigs -and -not $DryRun) {
    $mapFile = Join-Path $PSScriptRoot 'configs\map.json'
    $map = Get-Content $mapFile -Raw | ConvertFrom-Json
    foreach ($entry in $map) {
        if ($Only -and $Only -notcontains $entry.App) { continue }
        if ($Skip -and $Skip -contains $entry.App) { continue }
        $src = Join-Path $PSScriptRoot $entry.Repo
        if (-not (Test-Path $src)) { continue }   # nothing backed up for this entry
        Write-Step "Config: $($entry.App) -> $($entry.Target)"
        try {
            foreach ($p in @($entry.StopProcesses)) {
                if ($p) { Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force }
            }
            if ($entry.StopServices) {
                foreach ($s in @($entry.StopServices)) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
            }
            Start-Sleep -Seconds 1
            $dest = [Environment]::ExpandEnvironmentVariables($entry.Target)
            if (Test-Path $dest) {
                $bak = "$dest.bak"
                if (Test-Path $bak) { Remove-Item $bak -Recurse -Force }
                Copy-Item $dest $bak -Recurse -Force
            }
            if ((Get-Item $src).PSIsContainer) {
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                Copy-Item (Join-Path $src '*') $dest -Recurse -Force
            } else {
                New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
                Copy-Item $src $dest -Force
            }
            if ($entry.StopServices) {
                foreach ($s in @($entry.StopServices)) { Start-Service -Name $s -ErrorAction SilentlyContinue }
            }
            Write-Ok 'Restored'
            Add-Result "$($entry.App) config" 'OK' $dest
        } catch {
            Write-Warn2 "FAILED: $($_.Exception.Message)"
            Add-Result "$($entry.App) config" 'FAILED' $_.Exception.Message
        }
    }
}

Write-Host ''
$results | Format-Table -AutoSize
if ($results.Result -contains 'FAILED') {
    Write-Host 'Some steps failed. Fix the cause and run again; finished apps are skipped.' -ForegroundColor Yellow
} else {
    Write-Host 'All done. A restart is recommended.' -ForegroundColor Green
}
