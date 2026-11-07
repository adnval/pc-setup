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

# --- Downloading -------------------------------------------------------------

function Save-Download {
    param([string]$Url, [string]$FileName, [string]$Sha256)
    New-Item -ItemType Directory -Force -Path $script:Downloads | Out-Null
    $out = Join-Path $script:Downloads $FileName
    Invoke-WebRequest -UseBasicParsing -UserAgent $script:UA -Uri $Url -OutFile $out
    if ($out -match '\.(exe|msi)$') {
        $head = [IO.File]::ReadAllBytes($out)[0..1]
        if ($out -like '*.exe' -and -not ($head[0] -eq 0x4D -and $head[1] -eq 0x5A)) {
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

function Invoke-Installer {
    param([string]$Path, [string]$Arguments)
    if ($Path -like '*.msi') {
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$Path`" /qn /norestart" -Wait -PassThru
    } elseif ($Arguments) {
        $p = Start-Process $Path -ArgumentList $Arguments -Wait -PassThru
    } else {
        $p = Start-Process $Path -Wait -PassThru
    }
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

function New-StartMenuShortcut {
    param([string]$Name, [string]$Target)
    $dir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path $dir "$Name.lnk"))
    $lnk.TargetPath = $Target
    $lnk.WorkingDirectory = Split-Path $Target
    $lnk.Save()
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
