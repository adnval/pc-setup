# Helper functions used by setup.ps1. Windows PowerShell 5.1 compatible.

$script:UA = 'pc-setup-script'
$script:ToolsDir = $env:ProgramFiles   # portable apps go in C:\Program Files\<Name>
$script:Downloads = Join-Path $env:TEMP 'pc-setup\downloads'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }

# --- Resolving download URLs -------------------------------------------------

# Latest GitHub release asset whose name matches a regex.
# Returns @{ Url; Name; Sha256 } (Sha256 is $null if GitHub has no digest).
function Get-GitHubAsset {
    param([string]$Repo, [string]$Pattern, [string]$Exclude)
    $rel = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = $script:UA } `
        -Uri "https://api.github.com/repos/$Repo/releases/latest"
    $asset = $rel.assets | Where-Object {
        $_.name -match $Pattern -and (-not $Exclude -or $_.name -notmatch $Exclude)
    } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching '$Pattern' in $Repo $($rel.tag_name)" }
    $sha = $null
    if ($asset.PSObject.Properties['digest'] -and $asset.digest -match '^sha256:(.+)$') { $sha = $Matches[1] }
    @{ Url = $asset.browser_download_url; Name = $asset.name; Sha256 = $sha; Version = $rel.tag_name }
}

# First link on a web page whose href matches a regex (relative links are made absolute).
function Get-LinkFromPage {
    param([string]$Page, [string]$Pattern)
    $html = (Invoke-WebRequest -UseBasicParsing -UserAgent $script:UA -Uri $Page).Content
    $m = [regex]::Match($html, $Pattern)
    if (-not $m.Success) { throw "No link matching '$Pattern' on $Page" }
    $link = $m.Value
    if ($link -notmatch '^https?://') { $link = ([Uri]::new([Uri]$Page, $link)).AbsoluteUri }
    $link
}

# --- Progress display --------------------------------------------------------

# Rewrites the current console line (used for live download / install status).
function Write-Status {
    param([string]$Text, [switch]$Done, [string]$Color = 'Gray')
    $w = 79
    try { if ([Console]::WindowWidth -gt 20) { $w = [Console]::WindowWidth - 1 } } catch { }
    $t = "    $Text"
    if ($t.Length -gt $w) { $t = $t.Substring(0, $w) }
    Write-Host ("`r" + $t.PadRight($w)) -NoNewline -ForegroundColor $Color
    if ($Done) { Write-Host '' }
}

function Format-Elapsed([TimeSpan]$t) { '{0}:{1:00}' -f [int][math]::Floor($t.TotalMinutes), $t.Seconds }

# Overall bar at the top of the window. It is redrawn once per app, so it costs nothing.
# ($ProgressPreference is turned on only inside this function; setup.ps1 keeps it off
# because PowerShell's own download progress bar makes downloads very slow.)
function Show-OverallProgress {
    param([int]$Index, [int]$Total, [string]$Name, [switch]$Completed)
    $ProgressPreference = 'Continue'
    if ($Completed) { Write-Progress -Id 1 -Activity 'Installing apps' -Completed; return }
    Write-Progress -Id 1 -Activity 'Installing apps' -Status "$Index of ${Total}: $Name" `
        -PercentComplete ([int](($Index - 1) * 100 / [math]::Max($Total, 1)))
}

# --- Downloading -------------------------------------------------------------

# Downloads with a live "63%  95.9 / 152.4 MB  24.1 MB/s" line, updated twice a second.
function Save-Download {
    param([string]$Url, [string]$FileName, [string]$Sha256)
    New-Item -ItemType Directory -Force -Path $script:Downloads | Out-Null
    $out = Join-Path $script:Downloads $FileName

    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    [void]$client.DefaultRequestHeaders.UserAgent.TryParseAdd($script:UA)
    try {
        $resp = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) { throw "Download failed: HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase)" }
        $total = $resp.Content.Headers.ContentLength
        $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fs = [IO.File]::Create($out)
        try {
            $buf = New-Object byte[] (1MB)
            $done = 0L
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $lastDraw = -1000
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $fs.Write($buf, 0, $n)
                $done += $n
                if ($sw.ElapsedMilliseconds - $lastDraw -ge 500) {
                    $lastDraw = $sw.ElapsedMilliseconds
                    $speed = $done / 1MB / [math]::Max($sw.Elapsed.TotalSeconds, 0.001)
                    if ($total) {
                        Write-Status ('Downloading {0}  {1,3}%  {2:N1} / {3:N1} MB  {4:N1} MB/s' -f $FileName, [int]($done * 100 / $total), ($done / 1MB), ($total / 1MB), $speed)
                    } else {
                        Write-Status ('Downloading {0}  {1:N1} MB  {2:N1} MB/s' -f $FileName, ($done / 1MB), $speed)
                    }
                }
            }
            Write-Status ('Downloaded {0}  {1:N1} MB  ({2})' -f $FileName, ($done / 1MB), (Format-Elapsed $sw.Elapsed)) -Done -Color Green
        } finally { $fs.Dispose(); $in.Dispose() }
    } finally { $client.Dispose() }

    if ($out -like '*.exe') {
        $head = [IO.File]::ReadAllBytes($out)[0..1]
        if (-not ($head[0] -eq 0x4D -and $head[1] -eq 0x5A)) {
            throw "$FileName is not a Windows program (the site probably returned a web page)"
        }
    }
    if ($Sha256) {
        $actual = (Get-FileHash -Algorithm SHA256 -Path $out).Hash
        if ($actual -ne $Sha256.ToUpper()) { throw "SHA256 mismatch for $FileName (expected $Sha256, got $actual)" }
        Write-Ok "SHA256 verified"
    }
    $out
}

# --- Installing --------------------------------------------------------------

# Runs an installer and shows "Installing... 0:45" until it exits (checked once a second).
# Waits for the installer process itself, so an app it launches when finished
# (e.g. Discord opening) does not hold up the script.
function Invoke-Installer {
    param([string]$Path, [string]$Arguments, [switch]$Hidden)
    $style = if ($Hidden) { 'Hidden' } else { 'Normal' }
    if ($Path -like '*.msi') {
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$Path`" /qn /norestart" -PassThru
    } elseif ($Arguments) {
        $p = Start-Process $Path -ArgumentList $Arguments -WindowStyle $style -PassThru
    } else {
        $p = Start-Process $Path -WindowStyle $style -PassThru
    }
    $null = $p.Handle   # keeps the exit code readable after the process ends (PowerShell 5.1 quirk)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.WaitForExit(1000)) { Write-Status "Installing... $(Format-Elapsed $sw.Elapsed)" }
    $p.WaitForExit()
    Write-Status "Installing... done ($(Format-Elapsed $sw.Elapsed))" -Done
    if ($p.ExitCode -notin 0, 3010, 1641) { throw "Installer exited with code $($p.ExitCode)" }
}

# Extracts .zip (built in) or .7z (needs 7-Zip) into C:\Program Files\<Name>.
function Expand-ToTools {
    param([string]$Archive, [string]$Name)
    $dest = Join-Path $script:ToolsDir $Name
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    if ($Archive -like '*.zip') {
        Expand-Archive -Path $Archive -DestinationPath $dest -Force
    } else {
        $7z = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
        if (-not (Test-Path $7z)) { throw '7-Zip is required to extract .7z files but is not installed' }
        & $7z x $Archive "-o$dest" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7-Zip failed with code $LASTEXITCODE" }
    }
    # If the archive had a single top-level folder, flatten it.
    $items = @(Get-ChildItem $dest)
    if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
        Get-ChildItem $items[0].FullName -Force | Move-Item -Destination $dest
        Remove-Item $items[0].FullName -Recurse -Force
    }
    $dest
}

# Creates (or repairs) C:\ProgramData\Microsoft\Windows\Start Menu\Programs\<Name>.lnk
# for a portable app in C:\Program Files\<Name>. Start in = the app folder.
function Install-PortableShortcut {
    param([string]$Name, [string]$Exe)
    $dir = Join-Path $script:ToolsDir $Name
    $target = Join-Path $dir $Exe
    if (-not (Test-Path -LiteralPath $target)) { throw "$Exe not found in $dir" }
    $lnkPath = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$Name.lnk"
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath = $target
    $lnk.WorkingDirectory = $dir
    $lnk.IconLocation = "$target,0"
    $lnk.Save()
    Write-Ok "Shortcut: Start Menu\$Name.lnk"
}

# True if an entry in Add/Remove Programs has a DisplayName matching the regex.
function Test-Installed {
    param([string]$DisplayName)
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    [bool](Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match $DisplayName })
}

# Runs a command as the normal (non-admin) desktop user. Explorer always
# starts programs un-elevated, so this goes through a temporary .cmd file.
function Start-Unelevated {
    param([string]$Name, [string]$PowerShellCommand)
    $cmd = Join-Path $env:TEMP "pc-setup\$Name.cmd"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($PowerShellCommand))
    Set-Content -Path $cmd -Encoding ASCII -Value "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded`r`n"
    Start-Process explorer.exe -ArgumentList "`"$cmd`""
}

# --- Config paths ------------------------------------------------------------

# Expands %VARS% in a map.json path. %DOCUMENTS% is the real Documents folder,
# which is right even when Windows has moved it into OneDrive.
function Expand-ConfigPath([string]$Path) {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    [Environment]::ExpandEnvironmentVariables(($Path -replace '%DOCUMENTS%', $docs.Replace('$', '$$')))
}

# --- Final confirmation -------------------------------------------------------

# Pops up a message box that stays on top of every other window, so the end of the
# run is noticed even when installer windows are in front. Falls back to a console
# prompt where no message box can be shown.
function Show-FinalMessage {
    param([string]$Title, [string]$Message, [switch]$Warning)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
        $icon = if ($Warning) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information }
        [void][System.Windows.Forms.MessageBox]::Show($owner, $Message, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
        $owner.Dispose()
    } catch {
        Write-Host ''
        Write-Host $Message
        [void](Read-Host "$Title - press Enter to close")
    }
}

# --- OBS autostart --------------------------------------------------------------

$script:ObsTaskName = 'OBS Studio (replay buffer)'

function Get-CurrentUserName { [Security.Principal.WindowsIdentity]::GetCurrent().Name }

# Scheduled task: at logon of the current user, start OBS as admin (no UAC prompt),
# minimized to the tray with the replay buffer running. "Start in" must be OBS's
# own folder or OBS can't find its language files and won't start.
function Register-ObsLogonTask {
    $dir = Join-Path $env:ProgramFiles 'obs-studio\bin\64bit'
    $exe = Join-Path $dir 'obs64.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "OBS not found at $exe" }
    $user = Get-CurrentUserName

    $action    = New-ScheduledTaskAction -Execute $exe -Argument '--startreplaybuffer --minimize-to-tray' -WorkingDirectory $dir
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $script:ObsTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force `
        -Description 'Starts OBS at logon, minimized to the tray, with the replay buffer running. Created by pc-setup.' | Out-Null
    $user
}
