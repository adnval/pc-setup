# pc-setup

Sets up my Windows 11 gaming PC after a clean install. Every program is downloaded from
its official source (GitHub releases, SourceForge or the vendor's site). No package
manager like winget is used. My config files are put back afterwards.

## What's in here

| File | What it is |
|---|---|
| `apps.json` | **The list.** Every app: where to download it, how to install it, its config files and finishing steps. |
| `setup.ps1` | Does everything in `apps.json`. |
| `backup-configs.ps1` | Run on the old PC before wiping: copies the config files listed in `apps.json` into `configs/`. |
| `bootstrap.ps1` | The target of the one-line command. Downloads this repo and starts `setup.ps1`. |
| `configs/` | My backed-up config files, plus `Office/Configuration.xml` (which Office apps to install). |

## 1. Before wiping: back up configs

Download this repo (**Code → Download ZIP**, then extract it), open PowerShell **inside
the extracted folder** (the one with `apps.json`), and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\backup-configs.ps1
```

Close the apps first; the script reminds you if one is still open. Then check `configs/`
and **delete any `service.json` under `configs/obs-studio/basic/profiles/`**, because it
holds your stream key and this repo is public. Upload the `configs` folder to GitHub.

## 2. After wiping: run setup

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/adnval/pc-setup/main/bootstrap.ps1 | iex
```

If that PowerShell is already running as admin, setup runs in the same window.
Otherwise you get a UAC prompt and setup runs in a new admin window. Windows can't switch
an open window to admin.

For each app, in order, setup:
1. **installs it**, or skips it if it's already installed;
2. **restores its configs** from `configs/` (anything already there is kept as `.bak`);
3. **runs its finishing steps**, e.g. the OBS logon task or a Start Menu shortcut.

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

At the end you get a summary table and a pop-up that says everything worked, or lists
what failed. Run it again to retry: finished apps are skipped.

### Options

From the downloaded copy (`cd $env:TEMP\pc-setup\pc-setup-main`):

```powershell
.\setup.ps1 -DryRun              # show every download link and step, change nothing
.\setup.ps1 -Only OBS,Discord    # just these apps
.\setup.ps1 -Skip Office         # everything except these
.\setup.ps1 -ConfigsOnly         # only copy configs back
.\setup.ps1 -SkipConfigs         # install, but leave configs alone
.\setup.ps1 -Force               # reinstall apps that are already installed
```

## The apps

| Name | App | Notes |
|---|---|---|
| `7zip` | 7-Zip | First, because LosslessCut and mpv are .7z archives |
| `OBS` | OBS Studio | Configs restored; logon task (see below) |
| `Discord` | Discord | |
| `SpotX` | Spotify + SpotX | Runs in its own normal-user window (Spotify won't install as admin) |
| `NotepadPP` | Notepad++ | |
| `Lightshot` | Lightshot | |
| `LosslessCut` | LosslessCut | Portable; config restored |
| `mpv` | mpv | Portable; registers its file types (see below) |
| `PaintNET` | Paint.NET | |
| `Revo` | Revo Uninstaller Free | |
| `HWiNFO` | HWiNFO64 | From SourceForge; must be signed by REALiX |
| `ZenTimings` | ZenTimings | Portable |
| `Office` | Microsoft 365 apps | Office Deployment Tool + `configs/Office/Configuration.xml`; must be signed by Microsoft |

**Portable apps** go in `C:\Program Files\<name>` with a Start Menu shortcut
(`C:\ProgramData\Microsoft\Windows\Start Menu\Programs\<name>.lnk`). Re-running setup
recreates a missing shortcut.

**mpv file types:** setup runs mpv's own `installer\mpv-install.bat /u`, which registers mpv
for video and audio files, "Open with" and Default Apps. It's skipped when mpv is already
registered (`-Force` re-runs it). Windows doesn't let scripts change your *default* apps,
so pick mpv in **Settings → Apps → Default apps → mpv**.

**OBS logon task:** the scheduled task **OBS Studio (replay buffer)** starts
`obs64.exe --startreplaybuffer --minimize-to-tray` at logon, as admin (no UAC prompt),
with *Start in* set to `C:\Program Files\obs-studio\bin\64bit`. To remove it, run
`Unregister-ScheduledTask 'OBS Studio (replay buffer)'` in an admin PowerShell.

**Already installed?** Portable apps count as installed when their exe exists. Other apps
count as installed when Windows' installed-programs list has a name matching their
`detect` pattern.

## Adding or changing an app in apps.json

```jsonc
{
  "name": "OBS",                          // used with -Only / -Skip
  "detect": "^OBS Studio",                // regex on the name in Settings > Apps (not needed for portable apps)
  "source": { "github": "obsproject/obs-studio", "asset": "Windows-x64-Installer\\.exe$" },
  "install": { "args": "/S" },            // silent-install arguments
  "configs": [
    { "repo": "obs-studio/basic",         // path inside configs/
      "target": "%APPDATA%\\obs-studio\\basic",
      "closeFirst": ["obs64"] }           // processes to close before copying
  ],
  "after": ["obsLogonTask"]               // finishing steps (see below)
}
```

- **`source`**: one of
  - `{ "github": "owner/repo", "asset": "<regex for the file name>" }`: the latest release; SHA256 checked when GitHub publishes one
  - `{ "sourceforge": "<project>", "folder": "<folder>", "file": "<regex>" }`: the file with the highest number in its name
  - `{ "url": "<direct link>", "file": "<name to save it as>" }`
- **How it's installed**: one of
  - `"install": { "args": "...", "signer": "<regex>", "hidden": true }`: runs an `.exe` with `args`, an `.msi` silently, or the `.msi` inside a `.zip`. `signer` (optional) refuses to run it unless it's validly signed by a matching publisher. `hidden` hides the installer's console window. `{configs}` in `args` becomes the path of the `configs` folder.
  - `"portable": { "exe": "<program>.exe" }`: unpacks the `.zip` / `.7z` into `C:\Program Files\<name>` and adds a Start Menu shortcut
  - `"runUnelevated": "<PowerShell command>"`: runs the command in a normal-user window (used for SpotX)
- **`after`** steps (written in `setup.ps1`, safe to repeat): `mpvFileTypes`, `obsLogonTask`.
- **`note`**: free text, ignored by the script.

To back up a new config, add it to the app's `configs` and run `backup-configs.ps1` again.
