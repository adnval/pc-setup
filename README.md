# pc-setup

Sets up my Windows 11 gaming PC after a clean install: installs my programs from their
official sources (no winget or other package manager), puts my config files back, and
finishes the setup (shortcuts, file types, OBS autostart).

```powershell
irm https://raw.githubusercontent.com/adnval/pc-setup/main/bootstrap.ps1 | iex
```

**Contents**
[Before wiping](#before-wiping-back-up-configs) ·
[Running setup](#running-setup) ·
[The apps](#the-apps) ·
[Troubleshooting](#troubleshooting) ·
[Editing apps.json](#editing-appsjson) ·
[Files](#files)

---

## Before wiping: back up configs

Do this on the old install. Only the configs listed in `apps.json` are saved
(OBS and LosslessCut).

1. Download this repo (**Code → Download ZIP**) and extract it.
2. Close OBS and LosslessCut.
3. Open PowerShell inside the extracted folder (the one with `apps.json`) and run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\backup-configs.ps1
   ```
4. **Delete every `service.json` under `configs\obs-studio\basic\profiles\`.** It holds your
   stream key, and this repo is public.
5. Upload the `configs` folder to GitHub (**Add file → Upload files**, drag the folder in).

## Running setup

Open PowerShell and run the one-liner at the top.

- **Normal PowerShell:** you get a UAC prompt, and setup runs in a new admin window.
- **PowerShell already running as admin:** setup runs right there, in the same window.

For each app, in order, setup:

1. **installs it**, or skips it if it's already installed;
2. **restores its configs** from `configs\`, keeping whatever was there as `.bak`;
3. **runs its finishing steps**, such as a Start Menu shortcut or the OBS logon task.

```
==> [2/13] OBS
    Source: https://github.com/obsproject/obs-studio/releases/download/...
    Downloaded OBS-Studio-33.0.1-Windows-x64-Installer.exe  152.4 MB  (0:06)
    SHA256 verified
    Installing... done (0:38)
    Installed
    Restored obs-studio/basic
    Scheduled task 'OBS Studio (replay buffer)' starts OBS at logon for PC\Kevin
```

At the end you get a summary table and a pop-up saying everything worked, or listing what
failed. **To retry, run the one-liner again.** Finished apps are skipped.

### Options

Run these from the copy the one-liner downloaded. First go there and allow scripts for
this PowerShell window only (Windows blocks `.ps1` files by default). Setup still asks
for admin itself.

```powershell
cd $env:TEMP\pc-setup\pc-setup-main
```
```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

| Command | What it does |
|---|---|
| `.\setup.ps1 -DryRun` | List every download link and step; change nothing |
| `.\setup.ps1 -Only OBS,Discord` | Only these apps |
| `.\setup.ps1 -Skip Office` | Everything except these apps |
| `.\setup.ps1 -ConfigsOnly` | Only copy configs back |
| `.\setup.ps1 -SkipConfigs` | Install, but leave configs alone |
| `.\setup.ps1 -Force` | Reinstall apps that are already installed |

## The apps

Installed in this order. Use the **name** with `-Only` and `-Skip`.

| Name | App | Source | Extras |
|---|---|---|---|
| `7zip` | 7-Zip | GitHub | First, to unpack LosslessCut and mpv |
| `OBS` | OBS Studio | GitHub | Configs, [logon task](#obs-logon-task) |
| `Discord` | Discord | discord.com | |
| `SpotX` | Spotify + SpotX | SpotX script | Opens its own normal-user window (Spotify won't install as admin) |
| `NotepadPP` | Notepad++ | GitHub | |
| `Lightshot` | Lightshot | prntscr.com | |
| `LosslessCut` | LosslessCut | GitHub | [Portable](#portable-apps), config |
| `mpv` | mpv | GitHub | [Portable](#portable-apps), [file types](#mpv-file-types) |
| `PaintNET` | Paint.NET | GitHub | |
| `Revo` | Revo Uninstaller Free | revouninstaller.com | |
| `HWiNFO` | HWiNFO64 | SourceForge | Must be signed by REALiX |
| `ZenTimings` | ZenTimings | GitHub | [Portable](#portable-apps) |
| `Office` | Microsoft 365 apps | Microsoft | Must be signed by Microsoft; apps chosen in `configs\Office\Configuration.xml` |

GitHub downloads are checked against the SHA256 GitHub publishes, when it publishes one.

### Portable apps

LosslessCut, mpv and ZenTimings go in `C:\Program Files\<name>`, with a shortcut in the
Start Menu (`C:\ProgramData\Microsoft\Windows\Start Menu\Programs\<name>.lnk`). Every run
of setup re-creates the shortcut, so a deleted one comes back.

### mpv file types

Setup runs mpv's own `installer\mpv-install.bat /u`, which adds mpv to "Open with" and to
Default Apps for video and audio files. It's skipped if mpv is already registered
(`-Force` runs it again).

Windows doesn't let scripts change your default apps. To make mpv the default player, go
to **Settings → Apps → Default apps → mpv**.

### OBS logon task

The scheduled task **OBS Studio (replay buffer)** is in the Task Scheduler Library. At
each logon it starts OBS as admin (no UAC prompt), minimized to the tray, with the replay
buffer running:

| | |
|---|---|
| Program | `C:\Program Files\obs-studio\bin\64bit\obs64.exe` |
| Arguments | `--startreplaybuffer --minimize-to-tray` |
| Start in | `C:\Program Files\obs-studio\bin\64bit` |

To remove it, run this in an admin PowerShell:

```powershell
Unregister-ScheduledTask 'OBS Studio (replay buffer)'
```

### How "already installed" is decided

- **Portable apps:** their `.exe` exists in `C:\Program Files\<name>`.
- **Everything else:** Windows' installed-programs list (what Settings → Apps shows) has a
  name matching the app's `detect` pattern in `apps.json`.

## Troubleshooting

| Problem | Fix |
|---|---|
| An app sits on `Installing...` for a long time | Its installer may be stuck. End it in Task Manager; setup continues with the next app. |
| Office was skipped as "already installed" | Some Windows 11 installs come with a "Microsoft 365" placeholder that matches. Run `.\setup.ps1 -Only Office -Force` (see [Options](#options)). |
| `Access denied` on a file in `%TEMP%\pc-setup` | An installer from an earlier run is still open. End it in Task Manager, then run again. |
| OBS asks for the stream key | Expected, since `service.json` isn't backed up. Enter it in **Settings → Stream**. |
| OBS recordings fail | The recording folder is `D:\[-] System Folders\Videos`. If that drive or folder changed, set it in **Settings → Output**. |
| mpv isn't the default player | Set it in **Settings → Apps → Default apps → mpv** (see [mpv file types](#mpv-file-types)). |

## Editing apps.json

`apps.json` drives everything. Each app is one entry:

```jsonc
{
  "name": "OBS",
  "detect": "^OBS Studio",
  "source": { "github": "obsproject/obs-studio", "asset": "Windows-x64-Installer\\.exe$" },
  "install": { "args": "/S" },
  "configs": [
    { "repo": "obs-studio/basic", "target": "%APPDATA%\\obs-studio\\basic", "closeFirst": ["obs64"] }
  ],
  "after": ["obsLogonTask"]
}
```

Remember that JSON needs every `\` written as `\\`.

| Field | Meaning |
|---|---|
| `name` | Used with `-Only` / `-Skip`, and as the folder name for portable apps |
| `detect` | Regex for the app's name in Settings → Apps. Not needed for portable apps. |
| `note` | Free text; ignored |
| `source` | Where to download it. One of the three forms below. |
| `install` / `portable` / `runUnelevated` | How to install it. One of the three forms below. |
| `configs` | Config files to restore: `repo` (path inside `configs\`), `target` (where it goes; `%VARS%` allowed), `closeFirst` (processes to close first) |
| `after` | Finishing steps written in `setup.ps1`: `mpvFileTypes`, `obsLogonTask`. Portable apps get `startMenuShortcut` automatically. |

**`source`**, where to download it:

| Form | Picks |
|---|---|
| `{ "github": "owner/repo", "asset": "<regex>" }` | The file in the latest release whose name matches |
| `{ "sourceforge": "<project>", "folder": "<folder>", "file": "<regex>" }` | The matching file with the highest number in its name |
| `{ "url": "<link>", "file": "<save as>" }` | That exact link |

**How to install it:**

| Form | Does |
|---|---|
| `"install": { "args": "...", "signer": "<regex>", "hidden": true }` | Runs an `.exe` with `args`, an `.msi` silently, or the `.msi` inside a `.zip`. `signer`: refuse to run unless it's validly signed by a matching publisher. `hidden`: no console window. `{configs}` in `args` becomes the `configs` folder's path. All three are optional. |
| `"portable": { "exe": "<program>.exe" }` | Unpacks the `.zip`/`.7z` into `C:\Program Files\<name>` and adds a Start Menu shortcut |
| `"runUnelevated": "<PowerShell command>"` | Runs the command in a normal-user window (used for SpotX) |

To back up a new config file, add it to the app's `configs`, then run
`backup-configs.ps1` again.

## Files

| File | What it is |
|---|---|
| `apps.json` | The list of apps, their configs and finishing steps |
| `setup.ps1` | Does everything in `apps.json` |
| `backup-configs.ps1` | Copies the configs listed in `apps.json` from this PC into `configs\` |
| `bootstrap.ps1` | Target of the one-liner: downloads this repo, then starts `setup.ps1` |
| `configs\` | Backed-up config files, plus `Office\Configuration.xml` |
