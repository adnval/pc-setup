<#
.SYNOPSIS
    Sets up this PC from apps.json. For each app: install it from its official source,
    restore its configs from configs\, then add its shortcut, logon task and
    after-install commands.

.EXAMPLE
    .\setup.ps1                     # everything
    .\setup.ps1 -Only OBS,Discord   # just these apps
    .\setup.ps1 -Skip Office        # everything except these
    .\setup.ps1 -ConfigsOnly        # only restore configs
    .\setup.ps1 -SkipConfigs        # don't restore configs
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
# Installing to Program Files, registering file types and creating logon tasks need
# admin. Windows can't raise a running window to admin, so relaunch in a new one.

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

# One app = a heading, then one indented line per thing that happened.
function Write-Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Write-Done($text) { Write-Host "    $text" }
function Write-Note($text) { Write-Host "    $text" -ForegroundColor DarkGray }

function Get-ConsoleWidth {
    try { if ([Console]::WindowWidth -gt 20) { return [Console]::WindowWidth - 1 } } catch { }
    79
}

# Rewrites the current line while something runs ("Downloading... 63%"). With -Done it
# writes the final text in full and moves to the next line.
function Write-Status([string]$text, [switch]$Done) {
    $width = Get-ConsoleWidth
    $line = "    $text"
    if ($Done) { Write-Host ("`r" + $line.PadRight($width)); return }
    if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }   # must fit to be redrawn
    Write-Host ("`r" + $line.PadRight($width)) -NoNewline -ForegroundColor DarkGray
}

# Starts at the beginning of the line, so it also replaces a half-drawn status line.
function Write-Failure($text) { Write-Host ("`r    FAILED $text".PadRight((Get-ConsoleWidth) + 1)) -ForegroundColor Red }

function Format-Elapsed([TimeSpan]$time) { '{0}:{1:00}' -f [int][math]::Floor($time.TotalMinutes), $time.Seconds }

# Overall bar at the top of the window, redrawn once per app.
function Show-OverallProgress {
    param([int]$Index, [int]$Total, [string]$Name, [switch]$Completed)
    $ProgressPreference = 'Continue'   # only inside this function; see the top of the script
    if ($Completed) { Write-Progress -Id 1 -Activity 'Setting up apps' -Completed; return }
    Write-Progress -Id 1 -Activity 'Setting up apps' -Status "$Index of ${Total}: $Name" `
        -PercentComplete ([int](($Index - 1) * 100 / [math]::Max($Total, 1)))
}

# Message box on top of every window, so the end of the run gets noticed.
function Show-FinalMessage {
    param([string]$Title, [string]$Message, [switch]$Warning)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
        $icon = if ($Warning) { 'Warning' } else { 'Information' }
        [void][System.Windows.Forms.MessageBox]::Show($owner, $Message, $Title, 'OK', $icon)
        $owner.Dispose()
    } catch {
        [void](Read-Host "`n$Title - press Enter to close")
    }
}


# =============================================================================
#  apps.json
# =============================================================================

# Every field an app can have, with its default. Apps only list what differs.
$AppDefaults = [ordered]@{
    name = ''
    source = ''; file = ''; command = ''                                    # what to get or run
    args = ''; signer = ''; hidden = $false; runAsUser = $false; portable = $false   # how to install it
    exe = ''; detect = ''                                                    # where it ends up
    shortcut = $false; startAtLogon = $false; startArgs = ''; startAsAdmin = $false; afterInstall = @()
    close = @(); configs = $null
}

# The app with every field filled in (defaults for the ones it leaves out).
function Complete-App($entry) {
    $app = [pscustomobject]$AppDefaults
    foreach ($field in $entry.PSObject.Properties) {
        if ($AppDefaults.Contains($field.Name)) { $app.($field.Name) = $field.Value }
    }
    $app.afterInstall = @($app.afterInstall | Where-Object { $_ })
    $app.close = @($app.close | Where-Object { $_ })
    $app
}

# Problems in one apps.json entry, each naming the app and the field.
function Test-AppEntry($entry) {
    $name = if ($entry.name) { $entry.name } else { '(no name)' }
    $problems = @($entry.PSObject.Properties.Name | Where-Object { -not $AppDefaults.Contains($_) } |
        ForEach-Object { "unknown field '$_' (typo?)" })
    $app = Complete-App $entry
    if (-not $app.name) { $problems += 'name is missing' }
    if ($app.command) {
        if ($app.source) { $problems += 'use either command or source, not both' }
    } else {
        if ($app.source -notmatch '^(github|sourceforge):[^/]+/.+|^https?://') {
            $problems += "source must be github:owner/repo, sourceforge:project/folder or a https:// link (not '$($app.source)')"
        }
        if (-not $app.file) { $problems += 'file is missing' }
    }
    if ($app.portable -and -not $app.exe) { $problems += 'portable needs exe (it decides the folder)' }
    if (($app.shortcut -or $app.startAtLogon -or $app.afterInstall) -and -not $app.exe) { $problems += 'shortcut, startAtLogon and afterInstall need exe' }
    if (-not $app.detect -and -not $app.exe) { $problems += 'needs detect or exe, to tell whether it is installed' }
    $problems | ForEach-Object { "${name}: $_" }
}

# %ProgramFiles%, %APPDATA% and other environment variables in a path.
function Expand-Path($path) { [Environment]::ExpandEnvironmentVariables("$path") }

# The app's exe, which must exist.
function Resolve-AppExe($app) {
    $exe = Expand-Path $app.exe
    if (-not (Test-Path -LiteralPath $exe)) { throw "exe not found: $exe" }
    $exe
}


# =============================================================================
#  1. Already installed?
# =============================================================================

# detect: a regex on the names in Windows' installed-programs list (the registry behind
# Settings > Apps). Without detect: whether exe exists.
function Test-AppInstalled($app) {
    if (-not $app.detect) { return [bool]($app.exe -and (Test-Path (Expand-Path $app.exe))) }
    $uninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    [bool](Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match $app.detect })
}


# =============================================================================
#  2. Finding the download  (source + file)
# =============================================================================

# Returns @{ Url; FileName; Sha256 } (Sha256 only when GitHub publishes one).
function Resolve-Download($app) {
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
    $project, $folder = $location -split '/', 2
    [xml]$rss = (Invoke-WebRequest -UseBasicParsing -UserAgent $UserAgent `
        -Uri "https://sourceforge.net/projects/$project/rss?path=/$folder").Content
    $name = $rss.rss.channel.item |
        ForEach-Object { $_.SelectSingleNode('title').InnerText.Trim().Split('/')[-1] } |
        Where-Object { $_ -match $pattern } |
        Sort-Object { [int]($_ -replace '\D', '') } -Descending |
        Select-Object -First 1
    if (-not $name) { throw "No file matching '$pattern' in SourceForge $location" }
    @{ Url = "https://downloads.sourceforge.net/project/$project/$folder/$name"; FileName = $name }
}

# For -DryRun: checks the link and returns the download's size, without downloading it.
function Get-DownloadSize($url) {
    try {
        $head = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $url
        $length = @($head.Headers['Content-Length'])[0]   # a string in PowerShell 5.1, a list in 7
        if ($length) { '{0:N1} MB' -f ([double]$length / 1MB) } else { 'size unknown' }
    } catch { "link check failed: $($_.Exception.Message)" }
}


# =============================================================================
#  3. Downloading and installing
# =============================================================================

# Downloads with a live "63%  95.9 / 152.4 MB  24.1 MB/s" line, checks the file, and
# ends with one line: "Downloaded <file>  (152.4 MB, 0:06, SHA256 OK)".
function Save-Download($url, $fileName, $sha256, $signer) {
    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    $path = Join-Path $DownloadDir $fileName

    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    [void]$client.DefaultRequestHeaders.UserAgent.TryParseAdd($UserAgent)
    try {
        $response = $client.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "download failed: HTTP $([int]$response.StatusCode) $($response.ReasonPhrase) ($url)" }
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
        } finally { $fileStream.Dispose(); $webStream.Dispose() }
    } finally { $client.Dispose() }

    $details = @(('{0:N1} MB' -f ($done / 1MB)), (Format-Elapsed $timer.Elapsed))
    try {
        # A web page saved as .exe means the site didn't hand out the real file.
        if ($path -like '*.exe') {
            $header = [IO.File]::ReadAllBytes($path)[0..1]
            if (-not ($header[0] -eq 0x4D -and $header[1] -eq 0x5A)) { throw "$fileName is not a Windows program (the site returned a web page)" }
        }
        if ($sha256) {
            $actual = (Get-FileHash -Algorithm SHA256 -Path $path).Hash
            if ($actual -ne $sha256.ToUpper()) { throw "SHA256 mismatch for $fileName (expected $sha256, got $actual)" }
            $details += 'SHA256 OK'
        }
        if ($signer) { $details += "signed by $(Assert-Signature $path $signer)" }
    } finally {
        Write-Status "Downloaded $fileName  ($($details -join ', '))" -Done
    }
    $path
}

# signer: stop unless the file is validly signed by a publisher matching the regex.
# Returns the publisher's name.
function Assert-Signature($path, $signer) {
    $signature = Get-AuthenticodeSignature $path
    $subject = $signature.SignerCertificate.Subject
    if ($signature.Status -ne 'Valid' -or $subject -notmatch $signer) {
        throw "signature check failed ($($signature.Status), signer: $subject); not running it"
    }
    if ($subject -match 'CN=("[^"]+"|[^,]+)') { $Matches[1].Trim('"') } else { $subject }
}

# Runs a program, showing "<Doing>... 0:12" until it exits, then "<Done>  (0:38)".
# Waits for that process only, so an app an installer opens at the end (like Discord)
# doesn't hold things up. An .msi is run silently through msiexec.
function Invoke-Program {
    param([string]$Path, [string]$Arguments, [switch]$Hidden, [string]$WorkingDirectory,
          [string]$Doing = 'Running', [string]$Done = 'Finished')
    $start = @{ FilePath = $Path; PassThru = $true; WindowStyle = $(if ($Hidden) { 'Hidden' } else { 'Normal' }) }
    if ($Path -like '*.msi') { $start.FilePath = 'msiexec.exe'; $start.ArgumentList = "/i `"$Path`" /qn /norestart" }
    elseif ($Arguments)      { $start.ArgumentList = $Arguments }
    if ($WorkingDirectory)   { $start.WorkingDirectory = $WorkingDirectory }
    $process = Start-Process @start
    $null = $process.Handle   # keeps ExitCode readable after the process ends (PowerShell 5.1 quirk)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.WaitForExit(1000)) { Write-Status "$Doing... $(Format-Elapsed $timer.Elapsed)" }
    if ($process.ExitCode -notin 0, 3010, 1641) {
        Write-Status "$Doing... stopped ($(Format-Elapsed $timer.Elapsed))" -Done
        throw "exited with code $($process.ExitCode)"
    }
    Write-Status "$Done  ($(Format-Elapsed $timer.Elapsed))" -Done
}

# Runs the installer: an .exe with args, an .msi, or the .msi inside a .zip.
# {configs} in args becomes this repo's configs folder.
function Install-Package($app, $path) {
    if ($path -like '*.zip') {
        $unzipped = Join-Path $DownloadDir "$($app.name)-unzipped"
        Expand-Archive -Path $path -DestinationPath $unzipped -Force
        $msi = Get-ChildItem $unzipped -Recurse -Filter *.msi | Select-Object -First 1
        if (-not $msi) { throw "No .msi inside $(Split-Path $path -Leaf)" }
        $path = $msi.FullName
    }
    Invoke-Program -Path $path -Arguments "$($app.args)".Replace('{configs}', $ConfigsDir) -Hidden:$app.hidden `
        -Doing 'Installing' -Done 'Installed'
}

# portable: unpacks the .zip or .7z into the folder that holds exe.
function Install-Portable($app, $archive) {
    $folder = Split-Path (Expand-Path $app.exe)
    Write-Status "Unpacking to $folder..."
    if (Test-Path $folder) { Remove-Item $folder -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    if ($archive -like '*.zip') {
        Expand-Archive -Path $archive -DestinationPath $folder -Force
    } else {
        $7zip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
        if (-not (Test-Path $7zip)) { throw '7-Zip is needed to unpack .7z files but is not installed' }
        & $7zip x $archive "-o$folder" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Status 'Unpacking failed' -Done; throw "7-Zip failed with code $LASTEXITCODE" }
    }
    # If everything sits in one top-level folder, move it up a level.
    $items = @(Get-ChildItem $folder)
    if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
        Get-ChildItem $items[0].FullName -Force | Move-Item -Destination $folder
        Remove-Item $items[0].FullName -Recurse -Force
    }
    Write-Status "Unpacked to $folder" -Done
}

# command: runs it in PowerShell instead of downloading anything. With runAsUser it runs
# as the normal desktop user in its own window (Explorer always starts programs
# un-elevated), and setup doesn't wait for it. Otherwise it runs as admin and setup waits.
function Invoke-InstallCommand($app) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($app.command))
    $arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    if ($app.runAsUser) {
        $cmdFile = Join-Path $env:TEMP "pc-setup\$($app.name).cmd"
        New-Item -ItemType Directory -Force -Path (Split-Path $cmdFile) | Out-Null
        Set-Content -Path $cmdFile -Encoding ASCII -Value "@echo off`r`npowershell $arguments`r`n"
        Start-Process explorer.exe -ArgumentList "`"$cmdFile`""
        Write-Done 'Started in its own window; it finishes on its own'
    } else {
        Invoke-Program -Path 'powershell.exe' -Arguments $arguments -Hidden:$app.hidden -Doing 'Running command' -Done 'Ran command'
    }
}


# =============================================================================
#  4. Configs
# =============================================================================

# configs: "path inside configs\": "path on this PC". Only the ones backed up so far.
function Get-AppConfigs($app) {
    if (-not $app.configs) { return @() }
    @($app.configs.PSObject.Properties | Where-Object { Test-Path (Join-Path $ConfigsDir $_.Name) } |
        ForEach-Object { [pscustomobject]@{ Repo = $_.Name; Target = $_.Value } })
}

# Copies one config to its place on this PC, keeping whatever was there as .bak.
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
}


# =============================================================================
#  5. Finishing touches  (shortcut, startAtLogon, afterInstall)
# =============================================================================
# These run on every setup run once the app is installed, so each is safe to repeat,
# and a deleted shortcut or task comes back.

# shortcut: C:\ProgramData\Microsoft\Windows\Start Menu\Programs\<name>.lnk
function Add-StartMenuShortcut($app) {
    $exe = Resolve-AppExe $app
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $StartMenu "$($app.name).lnk"))
    $shortcut.TargetPath = $exe
    $shortcut.WorkingDirectory = Split-Path $exe
    $shortcut.IconLocation = "$exe,0"
    $shortcut.Save()
    Write-Done "Added Start Menu shortcut '$($app.name)'"
}

# startAtLogon: scheduled task "<name> at logon" that starts exe with startArgs when you
# log on; as admin without a UAC prompt if startAsAdmin. "Start in" is exe's folder.
function Register-LogonTask($app) {
    $exe = Resolve-AppExe $app
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskName = "$($app.name) at logon"
    $actionArgs = @{ Execute = $exe; WorkingDirectory = (Split-Path $exe) }
    if ($app.startArgs) { $actionArgs.Argument = $app.startArgs }
    $runLevel = if ($app.startAsAdmin) { 'Highest' } else { 'Limited' }

    $task = @{
        TaskName    = $taskName
        Action      = New-ScheduledTaskAction @actionArgs
        Trigger     = New-ScheduledTaskTrigger -AtLogOn -User $user
        Principal   = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel $runLevel
        Settings    = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
                          -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
        Description = "Starts $($app.name) at logon. Created by pc-setup."
    }
    Register-ScheduledTask @task -Force | Out-Null
    Write-Done "Created logon task '$taskName'"
}

# afterInstall: runs one command hidden in cmd.exe, from exe's folder.
function Invoke-AfterInstall($app, $command) {
    Invoke-Program -Path $env:ComSpec -Arguments "/c $command" -WorkingDirectory (Split-Path (Resolve-AppExe $app)) -Hidden `
        -Doing "Running $command" -Done "Ran $command"
}


# =============================================================================
#  One app, start to finish
# =============================================================================

$Results = New-Object System.Collections.Generic.List[object]
function Add-Result($app, $step, $result, $detail = '') {
    $Results.Add([pscustomobject]@{ App = $app.name; Step = $step; Result = $result; Detail = $detail })
}

# Installs the app (or finds it already installed). Returns $true when its configs and
# finishing touches can follow, $false when they can't yet.
function Install-App($app) {
    if ((Test-AppInstalled $app) -and -not $Force) {
        Write-Note 'Already installed'
        Add-Result $app 'install' 'Skipped' 'already installed'
        return $true
    }

    if ($app.command) {
        if ($DryRun) { Add-Result $app 'install' 'DryRun' 'would run command'; return $false }
        Invoke-InstallCommand $app
        if ($app.runAsUser) {
            Add-Result $app 'install' 'OK' 'started in its own window'
            return $false   # still running, so the rest would come too early
        }
        Add-Result $app 'install' 'OK' 'command finished'
        return $true
    }

    $download = Resolve-Download $app
    if ($DryRun) {
        $size = Get-DownloadSize $download.Url
        Write-Done "Would download $($download.FileName)  ($size)"   # size, or why the link failed
        Write-Note $download.Url
        Add-Result $app 'install' 'DryRun' "$($download.FileName) $size"
        return $true   # as if installed, so the dry run also lists the later steps
    }

    $file = Save-Download $download.Url $download.FileName $download.Sha256 $app.signer
    if ($app.portable) { Install-Portable $app $file } else { Install-Package $app $file }
    Add-Result $app 'install' 'OK' $download.FileName
    return $true
}

# Closes the app's processes and restores its backed-up configs.
function Restore-AppConfigs($app) {
    $configs = @(Get-AppConfigs $app)   # @() keeps a single config as a list
    if (-not $configs) { return }
    $names = ($configs | ForEach-Object Repo) -join ', '
    if ($DryRun) { Write-Done "Would restore configs: $names"; Add-Result $app 'configs' 'DryRun' "would restore $($configs.Count)"; return }

    foreach ($process in $app.close) { Get-Process -Name $process -ErrorAction SilentlyContinue | Stop-Process -Force }
    Start-Sleep -Milliseconds 500
    $errors = @()
    foreach ($config in $configs) {
        try { Restore-Config $config }
        catch { Write-Failure "restoring $($config.Repo): $($_.Exception.Message)"; $errors += "$($config.Repo): $($_.Exception.Message)" }
    }
    if ($errors) { Add-Result $app 'configs' 'FAILED' ($errors -join '; ') }
    else         { Write-Done "Restored configs: $names"; Add-Result $app 'configs' 'OK' "$($configs.Count) restored" }
}

# Runs one finishing touch and records the result. $description finishes the sentence
# "Would ..." in a dry run.
function Invoke-FinishingTouch($app, $name, $description, [scriptblock]$action) {
    if ($DryRun) { Write-Done "Would $description"; Add-Result $app $name 'DryRun' 'would run'; return }
    try   { & $action; Add-Result $app $name 'OK' }
    catch { Write-Failure "${name}: $($_.Exception.Message)"; Add-Result $app $name 'FAILED' $_.Exception.Message }
}

function Invoke-App($app) {
    $readyForRest = $true
    if (-not $ConfigsOnly) {
        try { $readyForRest = Install-App $app }
        catch {
            Write-Failure "install: $($_.Exception.Message)"
            Add-Result $app 'install' 'FAILED' $_.Exception.Message
            return
        }
    }

    if (-not $SkipConfigs) { Restore-AppConfigs $app }

    if ($ConfigsOnly -or -not $readyForRest) { return }
    if ($app.shortcut) {
        Invoke-FinishingTouch $app 'shortcut' "add Start Menu shortcut '$($app.name)'" { Add-StartMenuShortcut $app }
    }
    if ($app.startAtLogon) {
        Invoke-FinishingTouch $app 'startAtLogon' "create logon task '$($app.name) at logon'" { Register-LogonTask $app }
    }
    foreach ($command in $app.afterInstall) {
        Invoke-FinishingTouch $app 'afterInstall' "run $command" { Invoke-AfterInstall $app $command }
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
    Show-FinalMessage -Warning -Title 'pc-setup: apps.json has problems' -Message (
        "Nothing was changed. Fix these in apps.json:`n`n" + ($problems -join "`n"))
    return
}

$apps = @($entries | ForEach-Object { Complete-App $_ } | Where-Object {
    (-not $Only -or $Only -contains $_.name) -and -not ($Skip -contains $_.name) -and
    (-not $ConfigsOnly -or $_.configs)
})

for ($i = 0; $i -lt $apps.Count; $i++) {
    Show-OverallProgress -Index ($i + 1) -Total $apps.Count -Name $apps[$i].name
    Write-Step "[$($i + 1)/$($apps.Count)] $($apps[$i].name)"
    Invoke-App $apps[$i]
}
Show-OverallProgress -Completed

# Summary: apps grouped by what happened, then failures with their reasons.
function Get-AppNames($filter) { @($Results | Where-Object $filter | ForEach-Object App | Select-Object -Unique) }
$groups = [ordered]@{
    'Installed'               = Get-AppNames { $_.Step -eq 'install' -and $_.Result -eq 'OK' -and $_.Detail -ne 'started in its own window' }
    'Already installed'       = Get-AppNames { $_.Step -eq 'install' -and $_.Result -eq 'Skipped' }
    'Finishing in own window' = Get-AppNames { $_.Detail -eq 'started in its own window' }
    'Configs restored'        = Get-AppNames { $_.Step -eq 'configs' -and $_.Result -eq 'OK' }
    'Would install'           = Get-AppNames { $_.Step -eq 'install' -and $_.Result -eq 'DryRun' }
}
Write-Step 'Summary'
foreach ($group in $groups.GetEnumerator()) {
    if ($group.Value) { Write-Done ('{0,-24} {1}' -f "$($group.Key):", ($group.Value -join ', ')) }
}
$failed    = @($Results | Where-Object Result -eq 'FAILED')
foreach ($row in $failed) { Write-Failure "$($row.App) ($($row.Step)): $($row.Detail)" }
$done      = @($Results | Where-Object Result -eq 'OK').Count
$skipped   = @($Results | Where-Object Result -eq 'Skipped').Count
$ownWindow = @($Results | Where-Object Detail -eq 'started in its own window' | ForEach-Object App)

if ($DryRun) {
    Show-FinalMessage -Title 'pc-setup: dry run finished' -Message 'Dry run finished. Nothing was installed or changed.'
} elseif ($failed) {
    $list = ($failed | ForEach-Object { "  - $($_.App) ($($_.Step)): $($_.Detail)" }) -join "`n"
    Show-FinalMessage -Warning -Title 'pc-setup: finished with problems' -Message (
        "$($failed.Count) step(s) failed:`n`n$list`n`n$done succeeded and $skipped app(s) were already installed.`n" +
        'Run setup again to retry; finished apps are skipped.')
} else {
    $note = if ($ownWindow) { "`n`nStill finishing in their own window: $($ownWindow -join ', ')." } else { '' }
    Show-FinalMessage -Title 'pc-setup: all done' -Message (
        "Everything completed successfully.`n`n$done step(s) done and $skipped app(s) already installed.$note`n`nA restart is recommended.")
}
