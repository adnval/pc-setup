<#
.SYNOPSIS
    Sets up this PC from apps.json: installs each app from its official source,
    restores its config files from configs\, and runs its finishing touches
    (shortcut, start at logon, after-install commands).

.EXAMPLE
    .\setup.ps1                     # everything
    .\setup.ps1 -Only OBS,Discord   # just these apps
    .\setup.ps1 -Skip Office        # everything except these
    .\setup.ps1 -ConfigsOnly        # only copy configs back
    .\setup.ps1 -SkipConfigs        # install, but leave configs alone
    .\setup.ps1 -DryRun             # show what would happen, change nothing
    .\setup.ps1 -Force              # reinstall apps that are already installed
#>
param(
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$ConfigsOnly,
    [switch]$SkipConfigs,
    [switch]$DryRun,
    [switch]$Force
)

# "-Only OBS,Discord" arrives as one string when relaunched with -File, so split it.
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Skip = @($Skip | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # PowerShell's own download progress bar is very slow
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AppsFile    = Join-Path $PSScriptRoot 'apps.json'
$ConfigsDir  = Join-Path $PSScriptRoot 'configs'
$DownloadDir = Join-Path $env:TEMP 'pc-setup\downloads'
$StartMenu   = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
$UserAgent   = 'pc-setup-script'


# =============================================================================
#  Run as administrator
# =============================================================================
# Installing to Program Files, registering file types and creating the OBS task all
# need admin. Windows can't raise a running window to admin, so start a new one.

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    foreach ($param in $PSBoundParameters.GetEnumerator()) {
        if ($param.Value -is [switch]) { if ($param.Value) { $argList += "-$($param.Key)" } }
        else { $argList += "-$($param.Key)", ($param.Value -join ',') }
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    return
}


# =============================================================================
#  Console output
# =============================================================================

function Write-Step($text)    { Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Info($text)    { Write-Host "    $text" -ForegroundColor Green }
function Write-Problem($text) { Write-Host "    $text" -ForegroundColor Yellow }

# Rewrites the current console line (live download and install status).
function Write-Status {
    param([string]$Text, [switch]$Done, [string]$Color = 'Gray')
    $width = 79
    try { if ([Console]::WindowWidth -gt 20) { $width = [Console]::WindowWidth - 1 } } catch { }
    $line = "    $Text"
    if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
    Write-Host ("`r" + $line.PadRight($width)) -NoNewline -ForegroundColor $Color
    if ($Done) { Write-Host '' }
}

function Format-Elapsed([TimeSpan]$time) { '{0}:{1:00}' -f [int][math]::Floor($time.TotalMinutes), $time.Seconds }

# Overall bar at the top of the window, redrawn once per app.
function Show-OverallProgress {
    param([int]$Index, [int]$Total, [string]$Name, [switch]$Completed)
    $ProgressPreference = 'Continue'   # only inside this function; see the top of the script
    if ($Completed) { Write-Progress -Id 1 -Activity 'Setting up apps' -Completed; return }
    Write-Progress -Id 1 -Activity 'Setting up apps' -Status "$Index of ${Total}: $Name" `
        -PercentComplete ([int](($Index - 1) * 100 / [math]::Max($Total, 1)))
}

# Message box that stays on top of every window, so the end of the run gets noticed.
function Show-FinalMessage {
    param([string]$Title, [string]$Message, [switch]$Warning)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
        $icon = if ($Warning) { 'Warning' } else { 'Information' }
        [void][System.Windows.Forms.MessageBox]::Show($owner, $Message, $Title, 'OK', $icon)
        $owner.Dispose()
    } catch {
        Write-Host "`n$Message"
        [void](Read-Host "$Title - press Enter to close")
    }
}

# =============================================================================
#  Reading and checking apps.json
# =============================================================================

# %ProgramFiles%, %APPDATA% and other environment variables in a path.
function Expand-Path($path) { [Environment]::ExpandEnvironmentVariables("$path") }

# Every field an app can have, with its default. Apps only list what differs.
$AppDefaults = [ordered]@{
    name = ''; source = ''; file = ''; args = ''; signer = ''; hidden = $false
    command = ''; runAsUser = $false; portable = $false; exe = ''; detect = ''
    shortcut = $false; startAtLogon = $false; startArgs = ''; startAsAdmin = $false
    afterInstall = @(); close = @(); configs = $null
}

# Returns the app with every field filled in (defaults for the missing ones).
function Complete-App($entry) {
    $app = [pscustomobject]$AppDefaults
    foreach ($field in $entry.PSObject.Properties) {
        if ($AppDefaults.Contains($field.Name)) { $app.($field.Name) = $field.Value }   # unknown ones are reported by Test-AppEntry
    }
    $app.afterInstall = @($app.afterInstall | Where-Object { $_ })
    $app.close = @($app.close | Where-Object { $_ })
    $app
}

# Lists problems in one apps.json entry, naming the app and field, so typos are
# caught before anything is installed.
function Test-AppEntry($entry) {
    $name = if ($entry.name) { $entry.name } else { '(no name)' }
    $problems = @($entry.PSObject.Properties.Name | Where-Object { -not $AppDefaults.Contains($_) } |
        ForEach-Object { "unknown field '$_' (typo?)" })
    $app = Complete-App $entry
    if (-not $app.name) { $problems += 'name is missing' }
    if ($app.command) {
        if ($app.source)   { $problems += 'use either command or source, not both' }
    } else {
        if ($app.source -notmatch '^(github|sourceforge):[^/]+/.+|^https?://') { $problems += "source must be github:owner/repo, sourceforge:project/folder or a https:// link (not '$($app.source)')" }
        if (-not $app.file) { $problems += 'file is missing' }
    }
    if ($app.portable -and -not $app.exe) { $problems += 'portable needs exe (it decides the folder)' }
    if (($app.shortcut -or $app.startAtLogon -or $app.afterInstall) -and -not $app.exe) { $problems += 'shortcut, startAtLogon and afterInstall need exe' }
    if (-not $app.detect -and -not $app.exe) { $problems += 'needs detect or exe, to tell whether it is installed' }
    $problems | ForEach-Object { "${name}: $_" }
}


# =============================================================================
#  Finding the download  (source)
# =============================================================================

# Turns source + file into @{ Url; FileName; Sha256 } (Sha256 only when GitHub publishes one).
function Resolve-Source($app) {
    if ($app.source -match '^github:(.+)$')      { return Get-GitHubAsset $Matches[1] $app.file }
    if ($app.source -match '^sourceforge:(.+)$') { return Get-SourceForgeFile $Matches[1] $app.file }
    @{ Url = $app.source; FileName = $app.file }
}

# github:owner/repo: the latest release's file whose name matches the regex.
function Get-GitHubAsset($repo, $pattern) {
    $release = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = $UserAgent } `
        -Uri "https://api.github.com/repos/$repo/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $asset) { throw "No file matching '$pattern' in $repo $($release.tag_name)" }
    $sha256 = $null
    if ($asset.PSObject.Properties['digest'] -and $asset.digest -match '^sha256:(.+)$') { $sha256 = $Matches[1] }
    @{ Url = $asset.browser_download_url; FileName = $asset.name; Sha256 = $sha256 }
}

# sourceforge:project/folder: the matching file with the highest number in its name.
function Get-SourceForgeFile($location, $pattern) {
    [xml]$rss = (Invoke-WebRequest -UseBasicParsing -UserAgent $UserAgent `
        -Uri "https://sourceforge.net/projects/$($location -replace '/', '/rss?path=/')").Content
    $name = $rss.rss.channel.item |
        ForEach-Object { $_.SelectSingleNode('title').InnerText.Trim().Split('/')[-1] } |
        Where-Object { $_ -match $pattern } |
        Sort-Object { [int]($_ -replace '\D', '') } -Descending |
        Select-Object -First 1
    if (-not $name) { throw "No file matching '$pattern' in SourceForge $location" }
    $project, $folder = $location -split '/', 2
    @{ Url = "https://downloads.sourceforge.net/project/$project/$folder/$name"; FileName = $name }
}


# =============================================================================
#  Downloading and installing
# =============================================================================

# Downloads with a live "63%  95.9 / 152.4 MB  24.1 MB/s" line, then checks the file.
function Save-Download($url, $fileName, $sha256) {
    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    $path = Join-Path $DownloadDir $fileName

    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    [void]$client.DefaultRequestHeaders.UserAgent.TryParseAdd($UserAgent)
    try {
        $response = $client.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "Download failed: HTTP $([int]$response.StatusCode) $($response.ReasonPhrase)" }
        $total      = $response.Content.Headers.ContentLength
        $webStream  = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fileStream = [IO.File]::Create($path)
        try {
            $buffer = New-Object byte[] (1MB)
            $done = 0L
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $lastDraw = -1000
            while (($read = $webStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $read)
                $done += $read
                if ($timer.ElapsedMilliseconds - $lastDraw -ge 500) {
                    $lastDraw = $timer.ElapsedMilliseconds
                    $speed = $done / 1MB / [math]::Max($timer.Elapsed.TotalSeconds, 0.001)
                    if ($total) {
                        Write-Status ('Downloading {0}  {1,3}%  {2:N1} / {3:N1} MB  {4:N1} MB/s' -f $fileName, [int]($done * 100 / $total), ($done / 1MB), ($total / 1MB), $speed)
                    } else {
                        Write-Status ('Downloading {0}  {1:N1} MB  {2:N1} MB/s' -f $fileName, ($done / 1MB), $speed)
                    }
                }
            }
            Write-Status ('Downloaded {0}  {1:N1} MB  ({2})' -f $fileName, ($done / 1MB), (Format-Elapsed $timer.Elapsed)) -Done -Color Green
        } finally { $fileStream.Dispose(); $webStream.Dispose() }
    } finally { $client.Dispose() }

    # A web page saved as .exe means the site didn't hand out the real file.
    if ($path -like '*.exe') {
        $header = [IO.File]::ReadAllBytes($path)[0..1]
        if (-not ($header[0] -eq 0x4D -and $header[1] -eq 0x5A)) { throw "$fileName is not a Windows program (the site returned a web page)" }
    }
    if ($sha256) {
        $actual = (Get-FileHash -Algorithm SHA256 -Path $path).Hash
        if ($actual -ne $sha256.ToUpper()) { throw "SHA256 mismatch for $fileName (expected $sha256, got $actual)" }
        Write-Info 'SHA256 verified'
    }
    $path
}

# signer: refuse to continue unless the file is validly signed by a matching publisher.
function Assert-Signature($path, $signer) {
    $signature = Get-AuthenticodeSignature $path
    $subject = $signature.SignerCertificate.Subject
    if ($signature.Status -ne 'Valid' -or $subject -notmatch $signer) {
        throw "Signature check failed ($($signature.Status), signer: $subject). Not running it."
    }
    Write-Info "Signed by: $subject"
}

# Starts a program and shows "Installing... 0:45" until it exits. Waits for that process
# only, so an app the installer opens at the end (like Discord) doesn't hold things up.
function Invoke-Installer {
    param([string]$Path, [string]$Arguments, [switch]$Hidden, [string]$WorkingDirectory)
    $start = @{ FilePath = $Path; PassThru = $true; WindowStyle = $(if ($Hidden) { 'Hidden' } else { 'Normal' }) }
    if ($Path -like '*.msi') { $start.FilePath = 'msiexec.exe'; $start.ArgumentList = "/i `"$Path`" /qn /norestart" }
    elseif ($Arguments)      { $start.ArgumentList = $Arguments }
    if ($WorkingDirectory)   { $start.WorkingDirectory = $WorkingDirectory }
    $process = Start-Process @start
    $null = $process.Handle   # keeps ExitCode readable after the process ends (PowerShell 5.1 quirk)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.WaitForExit(1000)) { Write-Status "Running... $(Format-Elapsed $timer.Elapsed)" }
    $process.WaitForExit()
    Write-Status "Running... done ($(Format-Elapsed $timer.Elapsed))" -Done
    if ($process.ExitCode -notin 0, 3010, 1641) { throw "Exited with code $($process.ExitCode)" }
}

# Installers: run the .exe with args, an .msi silently, or the .msi inside a .zip.
# {configs} in args becomes this repo's configs folder.
function Install-Package($app, $path) {
    if ($path -like '*.zip') {
        $unzipped = Join-Path $DownloadDir "$($app.name)-unzipped"
        Expand-Archive -Path $path -DestinationPath $unzipped -Force
        $msi = Get-ChildItem $unzipped -Recurse -Filter *.msi | Select-Object -First 1
        if (-not $msi) { throw "No .msi inside $(Split-Path $path -Leaf)" }
        $path = $msi.FullName
    }
    $arguments = "$($app.args)".Replace('{configs}', $ConfigsDir)
    Invoke-Installer -Path $path -Arguments $arguments -Hidden:$app.hidden
}

# portable: unpack the .zip or .7z into the folder that holds exe.
function Install-Portable($app, $archive) {
    $folder = Split-Path (Expand-Path $app.exe)
    Write-Info "Extracting to $folder"
    if (Test-Path $folder) { Remove-Item $folder -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    if ($archive -like '*.zip') {
        Expand-Archive -Path $archive -DestinationPath $folder -Force
    } else {
        $7zip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
        if (-not (Test-Path $7zip)) { throw '7-Zip is needed to unpack .7z files but is not installed' }
        & $7zip x $archive "-o$folder" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7-Zip failed with code $LASTEXITCODE" }
    }
    # If everything sits in one top-level folder, move it up a level.
    $items = @(Get-ChildItem $folder)
    if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
        Get-ChildItem $items[0].FullName -Force | Move-Item -Destination $folder
        Remove-Item $items[0].FullName -Recurse -Force
    }
}

# command: run it in PowerShell instead of downloading. With runAsUser it runs as the
# normal desktop user in its own window (Explorer always starts programs un-elevated);
# otherwise it runs as admin and setup waits for it.
function Invoke-InstallCommand($app) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($app.command))
    $powershell = "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    if ($app.runAsUser) {
        $cmdFile = Join-Path $env:TEMP "pc-setup\$($app.name).cmd"
        New-Item -ItemType Directory -Force -Path (Split-Path $cmdFile) | Out-Null
        Set-Content -Path $cmdFile -Encoding ASCII -Value "@echo off`r`n$powershell`r`n"
        Start-Process explorer.exe -ArgumentList "`"$cmdFile`""
    } else {
        Invoke-Installer -Path 'powershell.exe' -Arguments ($powershell -replace '^powershell ', '') -Hidden:$app.hidden
    }
}


# =============================================================================
#  Is it already installed?  (detect, or else exe)
# =============================================================================

# detect: a regex matched against Windows' installed-programs list (the registry behind
# Settings > Apps). Without detect: the exe exists.
function Test-AppInstalled($app) {
    if (-not $app.detect) { return [bool]($app.exe -and (Test-Path (Expand-Path $app.exe))) }
    $uninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    [bool](Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match $app.detect })
}


# =============================================================================
#  Finishing touches  (shortcut, startAtLogon, afterInstall)
# =============================================================================
# These run on every setup run once the app is installed, so each is safe to repeat
# (and a deleted shortcut or task comes back).

function Get-AppExe($app) {
    $exe = Expand-Path $app.exe
    if (-not (Test-Path -LiteralPath $exe)) { throw "exe not found: $exe" }
    $exe
}

# shortcut: C:\ProgramData\Microsoft\Windows\Start Menu\Programs\<name>.lnk
function Add-StartMenuShortcut($app) {
    $exe = Get-AppExe $app
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $StartMenu "$($app.name).lnk"))
    $shortcut.TargetPath = $exe
    $shortcut.WorkingDirectory = Split-Path $exe
    $shortcut.IconLocation = "$exe,0"
    $shortcut.Save()
    Write-Info "Start Menu shortcut: $($app.name).lnk"
}

# startAtLogon: a scheduled task "<name> at logon" that starts exe with startArgs when
# you log on; as admin without a UAC prompt if startAsAdmin. "Start in" is exe's folder.
function Register-LogonTask($app) {
    $exe = Get-AppExe $app
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskName = "$($app.name) at logon"
    $actionArgs = @{ Execute = $exe; WorkingDirectory = (Split-Path $exe) }
    if ($app.startArgs) { $actionArgs.Argument = $app.startArgs }
    $action    = New-ScheduledTaskAction @actionArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $runLevel  = if ($app.startAsAdmin) { 'Highest' } else { 'Limited' }
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel $runLevel
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force -Description "Starts $($app.name) at logon. Created by pc-setup." | Out-Null
    Write-Info "Scheduled task '$taskName'"
}

# afterInstall: each command runs hidden in cmd.exe, from exe's folder.
function Invoke-AfterInstall($app, $command) {
    $folder = Split-Path (Get-AppExe $app)
    Write-Info "Running: $command"
    Invoke-Installer -Path $env:ComSpec -Arguments "/c $command" -WorkingDirectory $folder -Hidden
}


# =============================================================================
#  Configs
# =============================================================================

# configs: "path inside configs\": "path on this PC". Returns the ones backed up so far.
function Get-AppConfigs($app) {
    if (-not $app.configs) { return @() }
    @($app.configs.PSObject.Properties | Where-Object { Test-Path (Join-Path $ConfigsDir $_.Name) } |
        ForEach-Object { [pscustomobject]@{ Repo = $_.Name; Target = $_.Value } })
}

# Copies one backed-up config to its place on this PC, keeping whatever was there as .bak.
function Restore-Config($config) {
    $from = Join-Path $ConfigsDir $config.Repo
    $to = Expand-Path $config.Target
    if (Test-Path $to) {
        if (Test-Path "$to.bak") { Remove-Item "$to.bak" -Recurse -Force }
        Copy-Item $to "$to.bak" -Recurse -Force
    }
    if ((Get-Item $from).PSIsContainer) {
        New-Item -ItemType Directory -Force -Path $to | Out-Null
        Copy-Item (Join-Path $from '*') $to -Recurse -Force
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
        Copy-Item $from $to -Force
    }
    Write-Info "Restored $($config.Repo)"
}


# =============================================================================
#  One app, start to finish
# =============================================================================

$Results = New-Object System.Collections.Generic.List[object]
function Add-Result($app, $step, $result, $detail) {
    $Results.Add([pscustomobject]@{ App = $app.name; Step = $step; Result = $result; Detail = $detail })
}

# Returns $true if the app is installed afterwards (or was already), so its configs
# and finishing touches can follow.
function Install-App($app) {
    if ((Test-AppInstalled $app) -and -not $Force) {
        Write-Info 'Already installed'
        Add-Result $app 'install' 'Skipped' 'already installed'
        return $true
    }

    if ($app.command) {
        if ($DryRun) { Add-Result $app 'install' 'DryRun' 'would run command'; return $false }
        Invoke-InstallCommand $app
        if ($app.runAsUser) {
            Write-Problem "$($app.name) opened in its own window; it finishes on its own."
            Add-Result $app 'install' 'OK' 'started in its own window'
            return $false   # still running, so configs and finishing touches would be too early
        }
        Add-Result $app 'install' 'OK' 'command finished'
        return $true
    }

    $download = Resolve-Source $app
    Write-Info "Source: $($download.Url)"
    if ($DryRun) {
        $size = ''
        try {
            $head = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $download.Url
            $length = @($head.Headers['Content-Length'])[0]   # a string in PowerShell 5.1, a list in 7
            if ($length) { $size = '{0:N1} MB' -f ([double]$length / 1MB) }
        } catch { $size = "(link check failed: $($_.Exception.Message))" }
        Add-Result $app 'install' 'DryRun' "$($download.FileName) $size"
        return $true   # as if installed, so the dry run also lists the later steps
    }

    $file = Save-Download $download.Url $download.FileName $download.Sha256
    if ($app.signer)   { Assert-Signature $file $app.signer }
    if ($app.portable) { Install-Portable $app $file } else { Install-Package $app $file }
    Write-Info 'Installed'
    Add-Result $app 'install' 'OK' $download.FileName
    return $true
}

# Runs one finishing touch and records the result.
function Invoke-Step($app, $step, [scriptblock]$action) {
    if ($DryRun) { Add-Result $app $step 'DryRun' 'would run'; return }
    try   { & $action; Add-Result $app $step 'OK' '' }
    catch { Write-Problem "FAILED: $step`: $($_.Exception.Message)"; Add-Result $app $step 'FAILED' $_.Exception.Message }
}

function Invoke-App($app) {
    # 1. Install (or confirm it's already installed)
    $installed = $true
    if (-not $ConfigsOnly) {
        try { $installed = [bool](Install-App $app | Select-Object -Last 1) }   # last value = the result
        catch {
            Write-Problem "FAILED: $($_.Exception.Message)"
            Add-Result $app 'install' 'FAILED' $_.Exception.Message
            return   # configs and finishing touches need the app
        }
    }

    # 2. Restore configs (the ones that have been backed up into configs\)
    $configs = @(Get-AppConfigs $app)   # @() keeps a single config as a list
    if ($configs -and -not $SkipConfigs) {
        if ($DryRun) {
            Add-Result $app 'configs' 'DryRun' "would restore $($configs.Count) item(s)"
        } else {
            foreach ($process in $app.close) { Get-Process -Name $process -ErrorAction SilentlyContinue | Stop-Process -Force }
            Start-Sleep -Milliseconds 500
            $errors = @()
            foreach ($config in $configs) {
                try { Restore-Config $config }
                catch { Write-Problem "FAILED: $($config.Repo): $($_.Exception.Message)"; $errors += "$($config.Repo): $($_.Exception.Message)" }
            }
            if ($errors) { Add-Result $app 'configs' 'FAILED' ($errors -join '; ') }
            else         { Add-Result $app 'configs' 'OK' "$($configs.Count) restored" }
        }
    }

    # 3. Finishing touches
    if ($ConfigsOnly -or -not $installed) { return }
    if ($app.shortcut)     { Invoke-Step $app 'shortcut' { Add-StartMenuShortcut $app } }
    if ($app.startAtLogon) { Invoke-Step $app 'startAtLogon' { Register-LogonTask $app } }
    foreach ($command in $app.afterInstall) {
        Invoke-Step $app 'afterInstall' { Invoke-AfterInstall $app $command }
    }
}


# =============================================================================
#  Main
# =============================================================================

if (-not (Test-Path -LiteralPath $AppsFile -PathType Leaf)) { throw "Can't find $AppsFile" }
$entries = @(([IO.File]::ReadAllText($AppsFile) | ConvertFrom-Json).apps)
$problems = @($entries | ForEach-Object { Test-AppEntry $_ })
if ($problems) {
    Write-Host 'apps.json has problems; nothing was changed:' -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Show-FinalMessage -Warning -Title 'pc-setup: apps.json has problems' -Message ("Nothing was changed. Fix these in apps.json:`n`n" + ($problems -join "`n"))
    return
}

$apps = @($entries | ForEach-Object { Complete-App $_ } | Where-Object {
    (-not $Only -or $Only -contains $_.name) -and -not ($Skip -contains $_.name) -and
    (-not $ConfigsOnly -or $_.configs)
})

$number = 0
foreach ($app in $apps) {
    $number++
    Show-OverallProgress -Index $number -Total $apps.Count -Name $app.name
    Write-Step "[$number/$($apps.Count)] $($app.name)"
    Invoke-App $app
}
Show-OverallProgress -Completed

Write-Host ($Results | Format-Table -AutoSize | Out-String -Width 160)
$failed  = @($Results | Where-Object Result -eq 'FAILED')
$done    = @($Results | Where-Object Result -eq 'OK').Count
$skipped = @($Results | Where-Object Result -eq 'Skipped').Count
$ownWindow = @($Results | Where-Object Detail -eq 'started in its own window' | ForEach-Object App)

if ($DryRun) {
    Write-Host 'Dry run finished. Nothing was installed or changed.' -ForegroundColor Green
    Show-FinalMessage -Title 'pc-setup: dry run finished' -Message "Dry run finished. Nothing was installed or changed.`n`nThe console window lists every download link."
} elseif ($failed) {
    Write-Host 'Some steps failed. Fix the cause and run again; finished apps are skipped.' -ForegroundColor Yellow
    $list = ($failed | ForEach-Object { "  - $($_.App) ($($_.Step)): $($_.Detail)" }) -join "`n"
    Show-FinalMessage -Warning -Title 'pc-setup: finished with problems' -Message (
        "$($failed.Count) step(s) failed:`n`n$list`n`n$done succeeded and $skipped app(s) were already installed.`n" +
        'Run the script again to retry; finished apps are skipped.')
} else {
    Write-Host 'All done. A restart is recommended.' -ForegroundColor Green
    $note = ''
    if ($ownWindow) { $note = "`n`nStill finishing in their own window: $($ownWindow -join ', ')." }
    Show-FinalMessage -Title 'pc-setup: all done' -Message (
        "Everything completed successfully.`n`n$done step(s) done and $skipped app(s) already installed.$note`n`nA restart is recommended.")
}
