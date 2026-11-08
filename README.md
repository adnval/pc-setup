# pc-setup

Sets up my Windows 11 PC after a clean install: installs my apps from their official
sources, restores their configs, and finishes setup (shortcuts, file types, start at
logon). Everything it does is listed in `apps.json`.

## Usage

**Before wiping**, back up configs. Download this repo (Code → Download ZIP) and in
PowerShell inside the extracted folder run:

```powershell
powershell -ExecutionPolicy Bypass -File .\backup-configs.ps1
```

It waits for you to close any app whose configs it copies, and lists any `service.json`
(OBS's stream key) to delete. Then upload the `configs` folder to this repo.

**After wiping**, run this in PowerShell:

```powershell
irm https://raw.githubusercontent.com/adnval/pc-setup/main/bootstrap.ps1 | iex
```

Run it again to retry anything that failed; installed apps are skipped.

### Options

From `$env:TEMP\pc-setup\pc-setup-main`, after `Set-ExecutionPolicy -Scope Process Bypass`:

| Command | Does |
|---|---|
| `.\setup.ps1 -DryRun` | Show what would happen, change nothing |
| `.\setup.ps1 -Only OBS,Discord` | Only these apps |
| `.\setup.ps1 -Skip Office` | All apps except these |
| `.\setup.ps1 -ConfigsOnly` | Only restore configs |
| `.\setup.ps1 -SkipConfigs` | Don't restore configs |
| `.\setup.ps1 -Force` | Reinstall apps that are already installed |
| `.\setup.ps1 -Backup` | Copy configs from this PC into `configs\` (what `backup-configs.ps1` runs) |

`-Only` and `-Skip` also work with `backup-configs.ps1`, e.g. `.\backup-configs.ps1 -Only OBS`.

## Apps

Installed in this order (7-Zip first, because it unpacks the .7z downloads). Downloads from
GitHub are checked against the SHA256 that GitHub publishes.

| Name | App | Source | Extras |
|---|---|---|---|
| `7zip` | 7-Zip | GitHub | |
| `Helium` | Helium browser | GitHub | Installed for all users (`C:\Program Files\imput\Helium`) |
| `OBS` | OBS Studio | GitHub | Configs; starts at logon as admin, minimized to tray with the replay buffer running |
| `Discord` | Discord | discord.com | |
| `SpotX` | Spotify + SpotX | SpotX script | Runs in its own normal-user window |
| `NotepadPP` | Notepad++ | GitHub | |
| `Lightshot` | Lightshot | prntscr.com | |
| `LosslessCut` | LosslessCut | GitHub | Portable; config; Start Menu shortcut |
| `mpv` | mpv | GitHub | Portable; Start Menu shortcut; registers its file types* |
| `PaintNET` | Paint.NET | GitHub | |
| `Revo` | Revo Uninstaller | revouninstaller.com | |
| `HWiNFO` | HWiNFO64 | SourceForge | Must be signed by REALiX |
| `ZenTimings` | ZenTimings | GitHub | Portable; Start Menu shortcut |
| `Office` | Microsoft 365 | Microsoft | Must be signed by Microsoft; apps chosen in `configs\Office\Configuration.xml` |

\* To make mpv the default player: Settings → Apps → Default apps → mpv.

## apps.json

Each app lists only the fields it needs; everything else uses the default. In JSON,
write each `\` as `\\`.

```json
{
  "name": "OBS",
  "source": "github:obsproject/obs-studio",
  "file": "Windows-x64-Installer\\.exe$",
  "args": "/S",
  "detect": "^OBS Studio",
  "exe": "%ProgramFiles%\\obs-studio\\bin\\64bit\\obs64.exe",
  "startAtLogon": true,
  "startArgs": "--startreplaybuffer --minimize-to-tray",
  "startAsAdmin": true,
  "close": ["obs64"],
  "configs": {
    "obs-studio/basic": "%APPDATA%\\obs-studio\\basic"
  }
}
```

| Field | Default | Meaning |
|---|---|---|
| `name` | required | Unique. Used with `-Only` / `-Skip`, and to name the shortcut and logon task |
| `source` | required* | `github:owner/repo` (latest release), `sourceforge:project/folder` (newest file), or a direct `https://` link |
| `file` | required* | Regex for the file to pick, or the name to save a direct link as |
| `args` | `""` | Install arguments. `{configs}` is replaced with the path of the `configs` folder. |
| `signer` | `""` | Only run the download if it's signed by a publisher matching this regex |
| `hidden` | `false` | Hide the installer's window |
| `command` | `""` | PowerShell command to run instead of downloading (*replaces `source` and `file`) |
| `runAsUser` | `false` | Run `command` as the normal user, in its own window |
| `portable` | `false` | Unpack the .zip/.7z into the folder of `exe` instead of running an installer |
| `exe` | `""` | The app's main program. Needed by `portable`, `shortcut`, `startAtLogon` and `afterInstall`. |
| `detect` | `""` | Regex on the app's name in Settings → Apps, to tell whether it's installed. If empty, setup checks whether `exe` exists. |
| `shortcut` | `false` | Add a Start Menu shortcut to `exe` |
| `startAtLogon` | `false` | Start `exe` at logon (scheduled task "*name* at logon") |
| `startArgs` | `""` | Arguments for `startAtLogon` |
| `startAsAdmin` | `false` | Run `startAtLogon` as admin, without a UAC prompt |
| `afterInstall` | `[]` | Commands to run in `exe`'s folder after installing |
| `close` | `[]` | Processes to close before configs are backed up or restored |
| `configs` | none | `"path inside configs\\": "path on this PC"` pairs, restored by setup and saved by `backup-configs.ps1` |

Before changing anything, setup checks `apps.json` and the `-Only` / `-Skip` names, and reports
unknown or missing fields, duplicate names and names that don't match an app.
