# pc-setup

Sets up my Windows 11 gaming PC after a clean install. Every program is downloaded
from its official source (GitHub releases or the vendor's site), so no package
manager like winget is used. My config files are copied back into place at the end.

## 1. Before wiping: back up configs

On the old install, clone this repo (or download it with **Code → Download ZIP** and
extract it). Open PowerShell **inside the repo folder**, the one with the `configs` and
`lib` folders (`pc-setup` or `pc-setup-main`), and run the script as a file. Don't paste
its contents or run it from the ISE:

```powershell
powershell -ExecutionPolicy Bypass -File .\backup-configs.ps1
git add configs
git commit -m "Back up configs"
git push
```

This copies the files listed in `configs/map.json`:

| App | What | Where |
|---|---|---|
| OBS Studio | profiles, scene collections, app settings and window layout | `%APPDATA%\obs-studio\basic`, `global.ini`, `user.ini` |
| LosslessCut | settings | `%APPDATA%\LosslessCut\config.json` |

> **This repo is public.** Before you push, check that nothing private is in `configs/`.
> OBS stores stream keys in `basic\profiles\<name>\service.json`, so delete that file
> or make the repo private. If the repo is private, the one-liner below needs a token.

## 2. After wiping: run setup

Open **PowerShell** (no admin needed; it asks for admin itself) and run:

```powershell
irm https://raw.githubusercontent.com/adnval/pc-setup/main/bootstrap.ps1 | iex
```

A new admin window installs everything and prints a summary table. If something
fails, run it again: programs that are already installed are skipped.

While it runs, a bar at the top shows overall progress (`Installing apps: 5 of 14`),
and each app looks like this (the download and install lines update in place):

```
==> [5/14] OBS
    Source: https://github.com/obsproject/obs-studio/releases/download/...
    Downloaded OBS-Studio-33.0.1-Windows-x64-Installer.exe  152.4 MB  (0:06)
    SHA256 verified
    Installing... done (0:38)
    Installed
```

At the end, a pop-up box (on top of all other windows) confirms that everything
completed successfully, or lists exactly which steps failed. The backup script ends
with the same kind of pop-up, listing what was saved and what wasn't found.

To run it again from the downloaded copy with options:

```powershell
cd $env:TEMP\pc-setup\pc-setup-main
.\setup.ps1 -DryRun                 # list every download link and size, change nothing
.\setup.ps1 -Only OBS,Discord       # install just these
.\setup.ps1 -Skip Office,Revo       # everything except these
.\setup.ps1 -ConfigsOnly            # only copy configs back
.\setup.ps1 -Force                  # reinstall even if already installed
```

## Programs

| Name (for -Only/-Skip) | Program | Source |
|---|---|---|
| `7zip` | 7-Zip | GitHub `ip7z/7zip` |
| `OBS` | OBS Studio | GitHub `obsproject/obs-studio` |
| `Discord` | Discord | discord.com |
| `SpotX` | Spotify + SpotX | SpotX `run.ps1` (opens in its own window) |
| `NotepadPP` | Notepad++ | GitHub `notepad-plus-plus/notepad-plus-plus` |
| `Lightshot` | Lightshot | app.prntscr.com |
| `LosslessCut` | LosslessCut (portable, `C:\Program Files`) | GitHub `mifi/lossless-cut` |
| `mpv` | mpv (portable, `C:\Program Files`) | GitHub `shinchiro/mpv-winbuild-cmake` |
| `PaintNET` | Paint.NET | GitHub `paintdotnet/release` |
| `Revo` | Revo Uninstaller Free | revouninstaller.com |
| `HWiNFO` | HWiNFO64 | SourceForge `hwinfo` (signature checked before running) |
| `ZenTimings` | ZenTimings (portable, `C:\Program Files`) | GitHub `irusanov/ZenTimings` |
| `Office` | Microsoft 365 apps (no Teams/Outlook/OneDrive/OneNote/Access/Publisher) | Office Deployment Tool + `office/Configuration.xml` |

GitHub downloads are checked against the SHA256 GitHub publishes, where there is one.
Portable apps (LosslessCut, mpv, ZenTimings) go in `C:\Program Files\<Name>`, with a
Start Menu shortcut in `C:\ProgramData\Microsoft\Windows\Start Menu\Programs\<Name>.lnk`.
Re-running setup recreates a missing shortcut even if the app is already installed.

**mpv file types:** after unpacking, setup runs mpv's own `installer\mpv-install.bat /u`
(unattended). It registers mpv for video/audio files, "Open with" and Default Apps, and is
skipped if mpv is already registered at that path (`-Force` re-runs it). Windows doesn't let
scripts change your *default* apps, so to make mpv the default player, go to
**Settings → Apps → Default apps → mpv** and pick the file types.
To change which Office apps are installed, edit `office/Configuration.xml`
(or make a new one at config.office.com).

**OBS autostart:** setup creates the scheduled task **OBS Studio (replay buffer)**. At each
logon it starts `obs64.exe --startreplaybuffer --minimize-to-tray` as admin (no UAC
prompt), with *Start in* set to `C:\Program Files\obs-studio\bin\64bit`. Re-running
setup replaces the task. To remove it, delete it in Task Scheduler or run
`Unregister-ScheduledTask 'OBS Studio (replay buffer)'` in an admin PowerShell.

## Adding a program

Add an entry to `apps.ps1`. Example for a GitHub release:

```powershell
@{ Name = 'MyApp'; Detect = '^MyApp'; Type = 'exe'; Args = '/S'
   Resolve = { Get-GitHubAsset 'owner/repo' 'Setup-x64\.exe$' } }
```

`Detect` is a regex for the name shown in *Installed apps*. For portable apps, use the
exe's path instead. To add a config, add an entry to `configs/map.json` and run
`backup-configs.ps1` again.
