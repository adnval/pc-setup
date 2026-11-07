# pc-setup

Sets up my Windows 11 gaming PC after a clean install. Every program is downloaded
from its official source (GitHub releases or the vendor's site), so no package
manager like winget is used. My config files are copied back into place at the end.

## 1. Before wiping: back up configs

On the old install, clone this repo, then in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\backup-configs.ps1
git add configs
git commit -m "Back up configs"
git push
```

This copies the files listed in `configs/map.json`:

| App | What | Where |
|---|---|---|
| OBS Studio | profiles, scene collections, global settings | `%APPDATA%\obs-studio\basic`, `global.ini` |
| LosslessCut | settings | `%APPDATA%\LosslessCut\config.json` |
| Logitech G HUB | device profiles, macros, lighting | `%LOCALAPPDATA%\LGHUB\settings.db` |

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

To run it again from the downloaded copy with options:

```powershell
cd $env:TEMP\pc-setup\pc-setup-main
.\setup.ps1 -DryRun                 # list every download link and size, change nothing
.\setup.ps1 -Only OBS,Discord       # install just these
.\setup.ps1 -Skip LGHub,Clownfish   # everything except these
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
| `Clownfish` | Clownfish Voice Changer | clownfish-translator.com |
| `LGHub` | Logitech G HUB | logitech.com |
| `LosslessCut` | LosslessCut (portable, `C:\Tools`) | GitHub `mifi/lossless-cut` |
| `mpv` | mpv (portable, `C:\Tools`) | GitHub `shinchiro/mpv-winbuild-cmake` |
| `PaintNET` | Paint.NET | GitHub `paintdotnet/release` |
| `Revo` | Revo Uninstaller Free | revouninstaller.com |
| `HWiNFO` | HWiNFO64 | HWiNFO's SourceForge mirror, then hwinfo.com |
| `ZenTimings` | ZenTimings (portable, `C:\Tools`) | GitHub `irusanov/ZenTimings` |
| `Office` | Microsoft Office | coming soon; see `office/README.md` |

GitHub downloads are checked against the SHA256 GitHub publishes, where there is one.
Portable apps get a Start Menu shortcut.

## Adding a program

Add an entry to `apps.ps1`. Example for a GitHub release:

```powershell
@{ Name = 'MyApp'; Detect = '^MyApp'; Type = 'exe'; Args = '/S'
   Resolve = { Get-GitHubAsset 'owner/repo' 'Setup-x64\.exe$' } }
```

`Detect` is a regex for the name shown in *Installed apps*. For portable apps, use the
exe's path instead. To add a config, add an entry to `configs/map.json` and run
`backup-configs.ps1` again.
