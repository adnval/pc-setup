<#
.SYNOPSIS
    Sets up this PC from apps.json: installs each app from its official source,
    restores its config files from configs\, and runs its finishing steps.

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
$PortableDir = $env:ProgramFiles                 # portable apps go in C:\Program Files\<name>
$StartMenu   = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
$UserAgent   = 'pc-setup-script'
$ObsTaskName = 'OBS Studio (replay buffer)'


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
#  Finding the download  (an app's "source" in apps.json)
# =============================================================================

# Returns @{ Url; FileName; Sha256 } (Sha256 only when GitHub publishes one).
function Resolve-Source($source) {
    if ($source.github)      { return Get-GitHubAsset $source.github $source.asset }
    if ($source.sourceforge) { return Get-SourceForgeFile $source.sourceforge $source.folder $source.file }
    if ($source.url)         { return @{ Url = $source.url; FileName = $source.file } }
    throw 'Unknown "source" in apps.json (expected github, sourceforge or url)'
}

# The latest GitHub release's file whose name matches a regex.
function Get-GitHubAsset($repo, $pattern) {
    $release = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = $UserAgent } `
        -Uri "https://api.github.com/repos/$repo/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $asset) { throw "No file matching '$pattern' in $repo $($release.tag_name)" }
    $sha256 = $null
    if ($asset.PSObject.Properties['digest'] -and $asset.digest -match '^sha256:(.+)$') { $sha256 = $Matches[1] }
    @{ Url = $asset.browser_download_url; FileName = $asset.name; Sha256 = $sha256 }
}

# The newest file (highest number in its name) in a SourceForge project folder.
function Get-SourceForgeFile($project, $folder, $pattern) {
    $feed = "https://sourceforge.net/projects/$project/rss?path=/$folder"
    [xml]$rss = (Invoke-WebRequest -UseBasicParsing -UserAgent $UserAgent -Uri $feed).Content
    $name = $rss.rss.channel.item |
        ForEach-Object { $_.SelectSingleNode('title').InnerText.Trim().Split('/')[-1] } |
        Where-Object { $_ -match $pattern } |
        Sort-Object { [int]($_ -replace '\D', '') } -Descending |
        Select-Object -First 1
    if (-not $name) { throw "No file matching '$pattern' in SourceForge $project/$folder" }
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

# Refuses to continue unless the file has a valid signature whose signer matches the regex.
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
    param([string]$Path, [string]$Arguments, [switch]$Hidden)
    $start = @{ FilePath = $Path; PassThru = $true; WindowStyle = $(if ($Hidden) { 'Hidden' } else { 'Normal' }) }
    if ($Path -like '*.msi') { $start.FilePath = 'msiexec.exe'; $start.ArgumentList = "/i `"$Path`" /qn /norestart" }
    elseif ($Arguments)      { $start.ArgumentList = $Arguments }
    $process = Start-Process @start
    $null = $process.Handle   # keeps ExitCode readable after the process ends (PowerShell 5.1 quirk)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.WaitForExit(1000)) { Write-Status "Installing... $(Format-Elapsed $timer.Elapsed)" }
    $process.WaitForExit()
    Write-Status "Installing... done ($(Format-Elapsed $timer.Elapsed))" -Done
    if ($process.ExitCode -notin 0, 3010, 1641) { throw "Installer exited with code $($process.ExitCode)" }
}

# An app's "install" in apps.json: run the .exe with its args, an .msi silently,
# or the .msi inside a .zip. {configs} in args becomes this repo's configs folder.
function Install-Package($app, $path) {
    $options = $app.install
    if ($options.signer) { Assert-Signature $path $options.signer }
    if ($path -like '*.zip') {
        $unzipped = Join-Path $DownloadDir "$($app.name)-unzipped"
        Expand-Archive -Path $path -DestinationPath $unzipped -Force
        $msi = Get-ChildItem $unzipped -Recurse -Filter *.msi | Select-Object -First 1
        if (-not $msi) { throw "No .msi inside $(Split-Path $path -Leaf)" }
        $path = $msi.FullName
    }
    $arguments = "$($options.args)".Replace('{configs}', $ConfigsDir)
    Invoke-Installer -Path $path -Arguments $arguments -Hidden:([bool]$options.hidden)
}

function Get-PortableFolder($app) { Join-Path $PortableDir $app.name }

# An app's "portable" in apps.json: unpack the .zip or .7z into C:\Program Files\<name>.
function Install-Portable($app, $archive) {
    $folder = Get-PortableFolder $app
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

# Runs a PowerShell command as the normal desktop user (not admin). Explorer always
# starts programs un-elevated, so this goes through a temporary .cmd file.
function Start-Unelevated($name, $command) {
    $cmdFile = Join-Path $env:TEMP "pc-setup\$name.cmd"
    New-Item -ItemType Directory -Force -Path (Split-Path $cmdFile) | Out-Null
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Set-Content -Path $cmdFile -Encoding ASCII -Value "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded`r`n"
    Start-Process explorer.exe -ArgumentList "`"$cmdFile`""
}


# =============================================================================
#  Is it already installed?
# =============================================================================

# Portable apps: their exe exists. Others: an entry in Windows' installed-programs list
# (the registry behind Settings > Apps) has a name matching the app's "detect" regex.
function Test-AppInstalled($app) {
    if ($app.portable) { return Test-Path (Join-Path (Get-PortableFolder $app) $app.portable.exe) }
    $uninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    [bool](Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match $app.detect })
}


# =============================================================================
#  Finishing steps  (an app's "after" in apps.json; portable apps also get a shortcut)
# =============================================================================
# These run after installing, and again on later runs when the app is already
# installed, so each one is safe to repeat.

function Invoke-AfterStep($step, $app) {
    switch ($step) {
        'startMenuShortcut' { Add-StartMenuShortcut $app }
        'mpvFileTypes'      { Register-MpvFileTypes $app }
        'obsLogonTask'      { Register-ObsLogonTask }
        default             { throw "Unknown step '$step' in apps.json" }
    }
}

# C:\ProgramData\Microsoft\Windows\Start Menu\Programs\<name>.lnk for a portable app.
function Add-StartMenuShortcut($app) {
    $folder = Get-PortableFolder $app
    $exe = Join-Path $folder $app.portable.exe
    if (-not (Test-Path -LiteralPath $exe)) { throw "$($app.portable.exe) not found in $folder" }
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $StartMenu "$($app.name).lnk"))
    $shortcut.TargetPath = $exe
    $shortcut.WorkingDirectory = $folder
    $shortcut.IconLocation = "$exe,0"
    $shortcut.Save()
    Write-Info "Start Menu shortcut: $($app.name).lnk"
}

# Runs the mpv build's own installer\mpv-install.bat /u (unattended): registers mpv's
# file types, "Open with" entries and Default Apps entry. Skipped if mpv is already
# registered at this path, unless -Force.
function Register-MpvFileTypes($app) {
    $folder = Get-PortableFolder $app
    $bat = Join-Path $folder 'installer\mpv-install.bat'
    $exe = Join-Path $folder 'mpv.exe'
    if (-not (Test-Path -LiteralPath $bat)) { throw "installer\mpv-install.bat not found in $folder" }
    $appPath = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe' -ErrorAction SilentlyContinue).'(default)'
    $listed  = Get-ItemProperty 'HKLM:\SOFTWARE\RegisteredApplications' -Name 'mpv' -ErrorAction SilentlyContinue
    if ($appPath -eq $exe -and $listed -and -not $Force) { Write-Info 'mpv file types already registered'; return }
    Write-Info 'Registering mpv file types'
    Invoke-Installer -Path $env:ComSpec -Arguments ('/c ""' + $bat + '" /u"') -Hidden
}

# Scheduled task: at logon, start OBS as admin (no UAC prompt), minimized to the tray
# with the replay buffer running. "Start in" must be OBS's own folder, or OBS can't
# find its language files and won't start.
function Register-ObsLogonTask {
    $folder = Join-Path $env:ProgramFiles 'obs-studio\bin\64bit'
    $exe = Join-Path $folder 'obs64.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "OBS not found at $exe" }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    $action    = New-ScheduledTaskAction -Execute $exe -Argument '--startreplaybuffer --minimize-to-tray' -WorkingDirectory $folder
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $ObsTaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force -Description 'Starts OBS at logon, minimized to the tray, with the replay buffer running. Created by pc-setup.' | Out-Null
    Write-Info "Scheduled task '$ObsTaskName' starts OBS at logon for $user"
}


# =============================================================================
#  Configs  (an app's "configs" in apps.json)
# =============================================================================

# Copies one backed-up config from configs\ to its place on this PC. Closes the app
# first, and keeps whatever was there as <name>.bak.
function Restore-Config($config) {
    $from = Join-Path $ConfigsDir $config.repo
    $to = [Environment]::ExpandEnvironmentVariables($config.target)
    foreach ($process in @($config.closeFirst)) {
        if ($process) { Get-Process -Name $process -ErrorAction SilentlyContinue | Stop-Process -Force }
    }
    Start-Sleep -Milliseconds 500
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
    Write-Info "Restored $($config.repo)"
}


# =============================================================================
#  One app, start to finish
# =============================================================================

$Results = New-Object System.Collections.Generic.List[object]
function Add-Result($app, $step, $result, $detail) {
    $Results.Add([pscustomobject]@{ App = $app.name; Step = $step; Result = $result; Detail = $detail })
}

# Returns $true if the app is installed afterwards (or was already), so its configs
# and finishing steps can follow.
function Install-App($app) {
    if ((Test-AppInstalled $app) -and -not $Force) {
        Write-Info 'Already installed'
        Add-Result $app 'install' 'Skipped' 'already installed'
        return $true
    }

    if ($app.runUnelevated) {
        if ($DryRun) { Add-Result $app 'install' 'DryRun' 'opens its own window'; return $false }   # nothing follows SpotX
        Start-Unelevated $app.name $app.runUnelevated
        Write-Problem "$($app.name) opened in its own window; it finishes on its own."
        Add-Result $app 'install' 'OK' 'started in its own window'
        return $false   # not finished yet, so no configs or finishing steps
    }

    $download = Resolve-Source $app.source
    Write-Info "Source: $($download.Url)"
    if ($DryRun) {
        $size = ''
        try {
            $head = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $download.Url
            $length = @($head.Headers['Content-Length'])[0]   # a string in PowerShell 5.1, a list in 7
            if ($length) { $size = '{0:N1} MB' -f ([double]$length / 1MB) }
        } catch { $size = "(link check failed: $($_.Exception.Message))" }
        Add-Result $app 'install' 'DryRun' "$($download.FileName) $size"
        return $true   # as if installed, so the dry run also lists the configs and finishing steps
    }

    $file = Save-Download $download.Url $download.FileName $download.Sha256
    if ($app.portable) { Install-Portable $app $file } else { Install-Package $app $file }
    Write-Info 'Installed'
    Add-Result $app 'install' 'OK' $download.FileName
    return $true
}

function Invoke-App($app) {
    # 1. Install (or confirm it's already installed)
    $installed = $true
    if (-not $ConfigsOnly) {
        try { $installed = [bool](Install-App $app | Select-Object -Last 1) }   # last value = the result
        catch {
            Write-Problem "FAILED: $($_.Exception.Message)"
            Add-Result $app 'install' 'FAILED' $_.Exception.Message
            return   # configs and finishing steps need the app
        }
    }

    # 2. Restore configs
    $configs = @($app.configs | Where-Object { $_ -and (Test-Path (Join-Path $ConfigsDir $_.repo)) })
    if ($configs -and -not $SkipConfigs) {
        if ($DryRun) {
            Add-Result $app 'configs' 'DryRun' "would restore $($configs.Count) item(s)"
        } else {
            $errors = @()
            foreach ($config in $configs) {
                try { Restore-Config $config }
                catch { Write-Problem "FAILED: $($config.repo): $($_.Exception.Message)"; $errors += "$($config.repo): $($_.Exception.Message)" }
            }
            if ($errors) { Add-Result $app 'configs' 'FAILED' ($errors -join '; ') }
            else         { Add-Result $app 'configs' 'OK' "$($configs.Count) restored" }
        }
    }

    # 3. Finishing steps
    if ($ConfigsOnly -or -not $installed) { return }
    $steps = @()
    if ($app.portable) { $steps += 'startMenuShortcut' }
    $steps += @($app.after | Where-Object { $_ })
    foreach ($step in $steps) {
        if ($DryRun) { Add-Result $app $step 'DryRun' 'would run'; continue }
        try   { Invoke-AfterStep $step $app; Add-Result $app $step 'OK' '' }
        catch { Write-Problem "FAILED: $step`: $($_.Exception.Message)"; Add-Result $app $step 'FAILED' $_.Exception.Message }
    }
}


# =============================================================================
#  Main
# =============================================================================

if (-not (Test-Path -LiteralPath $AppsFile -PathType Leaf)) { throw "Can't find $AppsFile" }
$apps = @(([IO.File]::ReadAllText($AppsFile) | ConvertFrom-Json).apps | Where-Object {
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
    if ($Results | Where-Object Detail -eq 'started in its own window') { $note = "`n`nSpotX finishes in its own window if it is still open." }
    Show-FinalMessage -Title 'pc-setup: all done' -Message (
        "Everything completed successfully.`n`n$done step(s) done and $skipped app(s) already installed.$note`n`nA restart is recommended.")
}
