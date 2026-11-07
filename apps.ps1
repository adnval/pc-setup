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

    # 64-bit build with the 64-bit VST. It is an NSIS installer, so /S is its silent switch.
    @{ Name = 'Clownfish'; Detect = 'Clownfish'; Type = 'exe'; Args = '/S'
       Resolve = {
           try {
               $u = Get-LinkFromPage 'https://clownfish-translator.com/voicechanger/download.html' '[^"''\s]*download64f\.php[^"''\s]*'
           } catch {
               $u = 'https://clownfish-translator.com/voicechanger/download/download64f.php'
           }
           @{ Url = $u; Name = 'ClownfishSetup64.exe' } } }

    @{ Name = 'LGHub'; Detect = '^Logitech G HUB'; Type = 'exe'; Args = '--silent'
       Resolve = { @{ Url = 'https://download01.logitech.com/web/ftp/pub/techsupport/gaming/lghub_installer.exe'; Name = 'lghub_installer.exe' } } }

    @{ Name = 'LosslessCut'; Detect = "$env:ProgramFiles\LosslessCut\LosslessCut.exe"; Type = 'portable'; Exe = 'LosslessCut.exe'
       Resolve = { Get-GitHubAsset 'mifi/lossless-cut' '^LosslessCut-win-x64\.7z$' } }

    # v3 build needs a CPU from roughly 2015 or later (AVX2). Use the plain build on older CPUs.
    @{ Name = 'mpv'; Detect = "$env:ProgramFiles\mpv\mpv.exe"; Type = 'portable'; Exe = 'mpv.exe'
       Resolve = { Get-GitHubAsset 'shinchiro/mpv-winbuild-cmake' '^mpv-x86_64-v3-\d+-git-.*\.7z$' } }

    @{ Name = 'PaintNET'; Detect = '^paint\.net'; Type = 'zipmsi'
       Resolve = { Get-GitHubAsset 'paintdotnet/release' '\.winmsi\.x64\.zip$' } }

    @{ Name = 'Revo'; Detect = '^Revo Uninstaller'; Type = 'exe'; Args = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
       Resolve = { @{ Url = 'https://download.revouninstaller.com/download/revosetup.exe'; Name = 'revosetup.exe' } } }

    # Newest installer linked from https://www.hwinfo.com/download/ (file name like hwi64_834.exe).
    # hwinfo.com is behind Cloudflare, which can refuse scripts. If it does, the download
    # page opens in your browser so you can install HWiNFO from there.
    @{ Name = 'HWiNFO'; Detect = '^HWiNFO'; Type = 'exe'; Args = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
       Resolve = {
           $page = 'https://www.hwinfo.com/download/'
           try {
               $u = Get-LinkFromPage $page '[^"''\s<>]*hwi(64)?_\d+\.exe'
           } catch {
               Start-Process $page
               throw 'hwinfo.com blocked the script (Cloudflare check). Its download page is open in your browser; install HWiNFO from there.'
           }
           @{ Url = $u; Name = 'hwinfo_setup.exe' } } }

    @{ Name = 'ZenTimings'; Detect = "$env:ProgramFiles\ZenTimings\ZenTimings.exe"; Type = 'portable'; Exe = 'ZenTimings.exe'
       Resolve = { Get-GitHubAsset 'irusanov/ZenTimings' '^ZenTimings_.*\.zip$' } }

    # Microsoft 365 apps via the Office Deployment Tool and office\Configuration.xml.
    @{ Name = 'Office'; Detect = '^Microsoft (365|Office)'; Type = 'script'
       Run = { & (Join-Path $PSScriptRoot 'office\install-office.ps1') } }
)
