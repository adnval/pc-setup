# The list of programs to install, in order. setup.ps1 reads this file.
#
# Each entry:
#   Name      short name used with -Only / -Skip
#   Detect    regex for the Add/Remove Programs name, or a file path (portable apps)
#   Resolve   scriptblock returning @{ Url; Name; Sha256 } (Sha256 optional)
#   Type      exe | msi | zipmsi (zip that holds an .msi) | portable (unpack to C:\Program Files\<Name>) | script
#   Args      silent-install arguments for Type = exe
#   Exe       for portable: the program inside the folder to make a Start Menu shortcut for
#   Run       for Type = script: scriptblock that does the whole install

$Apps = @(
    # 7-Zip goes first: LosslessCut and mpv are .7z archives.
    @{ Name = '7zip'; Detect = '^7-Zip'; Type = 'exe'; Args = '/S'
       Resolve = { Get-GitHubAsset 'ip7z/7zip' '^7z\d+-x64\.exe$' } }

    @{ Name = 'OBS'; Detect = '^OBS Studio'; Type = 'exe'; Args = '/S'
       Resolve = { Get-GitHubAsset 'obsproject/obs-studio' 'Windows-x64-Installer\.exe$' } }

    @{ Name = 'Discord'; Detect = '^Discord$'; Type = 'exe'; Args = '-s'
       Resolve = { @{ Url = 'https://discord.com/api/downloads/distributions/app/installers/latest?channel=stable&platform=win&arch=x64'; Name = 'DiscordSetup.exe' } } }

    # Installs Spotify and patches it with SpotX, using the exact command from the user.
    # Spotify refuses to install as admin, so this runs in a separate, normal-user window.
    @{ Name = 'SpotX'; Detect = '^Spotify'; Type = 'script'
       Run = {
           $spotx = @'
iex "& { $(iwr -useb 'https://raw.githubusercontent.com/SpotX-Official/SpotX/refs/heads/main/run.ps1') } -confirm_uninstall_ms_spoti -confirm_spoti_recomended_over -podcasts_off -block_update_on -start_spoti -new_theme -adsections_off -lyrics_stat spotify"
'@
           Start-Unelevated -Name 'spotx' -PowerShellCommand $spotx
           Write-Warn2 'SpotX opened in its own window; it finishes on its own.'
       } }

    @{ Name = 'NotepadPP'; Detect = '^Notepad\+\+'; Type = 'exe'; Args = '/S'
       Resolve = { Get-GitHubAsset 'notepad-plus-plus/notepad-plus-plus' '\.Installer\.x64\.exe$' } }

    @{ Name = 'Lightshot'; Detect = '^Lightshot'; Type = 'exe'; Args = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
       Resolve = { @{ Url = 'https://app.prntscr.com/build/setup-lightshot.exe'; Name = 'setup-lightshot.exe' } } }

    @{ Name = 'LosslessCut'; Detect = "$env:ProgramFiles\LosslessCut\LosslessCut.exe"; Type = 'portable'; Exe = 'LosslessCut.exe'
       Resolve = { Get-GitHubAsset 'mifi/lossless-cut' '^LosslessCut-win-x64\.7z$' } }

    # v3 build needs a CPU from roughly 2015 or later (AVX2). Use the plain build on older CPUs.
    @{ Name = 'mpv'; Detect = "$env:ProgramFiles\mpv\mpv.exe"; Type = 'portable'; Exe = 'mpv.exe'
       Resolve = { Get-GitHubAsset 'shinchiro/mpv-winbuild-cmake' '^mpv-x86_64-v3-\d+-git-.*\.7z$' } }

    @{ Name = 'PaintNET'; Detect = '^paint\.net'; Type = 'zipmsi'
       Resolve = { Get-GitHubAsset 'paintdotnet/release' '\.winmsi\.x64\.zip$' } }

    @{ Name = 'Revo'; Detect = '^Revo Uninstaller'; Type = 'exe'; Args = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
       Resolve = { @{ Url = 'https://download.revouninstaller.com/download/revosetup.exe'; Name = 'revosetup.exe' } } }

    # HWiNFO64 from its official SourceForge project (newest hwi64_XXX.exe in Windows_Installer).
    # The installer must carry a valid signature from HWiNFO's developer (REALiX / Martin Malik).
    @{ Name = 'HWiNFO'; Detect = '^HWiNFO'; Type = 'script'
       Run = {
           [xml]$rss = (Invoke-WebRequest -UseBasicParsing -UserAgent $script:UA -Uri 'https://sourceforge.net/projects/hwinfo/rss?path=/Windows_Installer').Content
           $name = $rss.rss.channel.item | ForEach-Object { $_.SelectSingleNode('title').InnerText.Trim().Split('/')[-1] } |
               Where-Object { $_ -match '^hwi64_\d+\.exe$' } |
               Sort-Object { [int]($_ -replace '\D', '') } -Descending | Select-Object -First 1
           if (-not $name) { throw 'No hwi64_XXX.exe found on SourceForge' }
           $u = "https://downloads.sourceforge.net/project/hwinfo/Windows_Installer/$name"
           Write-Ok "Source: $u"
           $file = Save-Download -Url $u -FileName $name   # rejects web pages
           $sig = Get-AuthenticodeSignature $file
           if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'REALiX|Mal[ií]k') {
               throw "HWiNFO installer signature check failed ($($sig.Status), signer: $($sig.SignerCertificate.Subject)). Not running it."
           }
           Write-Ok "Signed by: $($sig.SignerCertificate.Subject)"
           Invoke-Installer -Path $file -Arguments '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
       } }

    @{ Name = 'ZenTimings'; Detect = "$env:ProgramFiles\ZenTimings\ZenTimings.exe"; Type = 'portable'; Exe = 'ZenTimings.exe'
       Resolve = { Get-GitHubAsset 'irusanov/ZenTimings' '^ZenTimings_.*\.zip$' } }

    # Microsoft 365 apps via the Office Deployment Tool and office\Configuration.xml.
    @{ Name = 'Office'; Detect = '^Microsoft (365|Office)'; Type = 'script'
       Run = { & (Join-Path $PSScriptRoot 'office\install-office.ps1') } }
)
