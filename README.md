# pc-setup

Sets up my Windows 11 PC after a clean install: installs my apps from their official
sources, restores their configs, and finishes setup (shortcuts, file types, start at
logon). Everything it does is listed in `apps.json`.

## Usage

**Before wiping**, back up configs. Download this repo (Code → Download ZIP), close OBS
and LosslessCut, and in PowerShell inside the extracted folder run:

```powershell
powershell -ExecutionPolicy Bypass -File .\backup-configs.ps1
```

Then delete any `service.json` under `configs\obs-studio\basic\profiles\` (it holds your
stream key) and upload the `configs` folder to this repo.

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

## Apps

Installed in this order (7-Zip first, because it unpacks the .7z downloads).

| Name | App | Source | Extras |
|---|---|---|---|
| `7zip` | 7-Zip | GitHub | |
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

Every app has the same fields. Leave a field empty (`""`, `false`, `[]`) when it doesn't
apply. In JSON, write each `\` as `\\`.

```json
{
  "name": "OBS",
  "type": "installer",
  "source": { "from": "github", "location": "obsproject/obs-studio", "file": "Windows-x64-Installer\\.exe$" },
  "install": { "args": "/S", "hidden": false, "signer": "", "command": "", "runAsUser": false },
  "exe": "%ProgramFiles%\\obs-studio\\bin\\64bit\\obs64.exe",
  "detect": "^OBS Studio",
  "startMenuShortcut": false,
  "startAtLogon": { "enabled": true, "args": "--startreplaybuffer --minimize-to-tray", "admin": true },
  "afterInstall": [],
  "configs": [
    { "repo": "obs-studio/basic", "target": "%APPDATA%\\obs-studio\\basic", "closeFirst": ["obs64"] }
  ]
}
```

| Field | Meaning |
|---|---|
| `name` | Used with `-Only` / `-Skip` and for shortcut and task names |
| `type` | `installer` runs the download (`.exe`, `.msi`, or the `.msi` in a `.zip`). `portable` unpacks the `.zip`/`.7z` into the folder of `exe`. `command` runs `install.command` instead of downloading. |
| `source.from` | `github` (latest release), `sourceforge` (newest file), or `url` (a direct link) |
| `source.location` | `owner/repo`, `project/folder`, or the URL |
| `source.file` | Regex for the file name to pick (`github`, `sourceforge`), or the name to save as (`url`) |
| `install.args` | Silent-install arguments. `{configs}` becomes the path of the `configs` folder. |
| `install.hidden` | Hide the installer's or command's window |
| `install.signer` | Regex; only run the download if it's validly signed by a matching publisher |
| `install.command` | PowerShell command for `type: command` |
| `install.runAsUser` | Run the command as the normal user in its own window instead of as admin |
| `exe` | The app's main program (`%VARS%` allowed). Needed for portable apps, shortcuts, start at logon and `afterInstall`. |
| `detect` | Regex on the app's name in Settings → Apps, to tell whether it's installed. If empty, setup checks whether `exe` exists. |
| `startMenuShortcut` | Add a Start Menu shortcut to `exe` |
| `startAtLogon` | `enabled`: create the scheduled task "*name* at logon" that starts `exe` with `args` at logon. `admin`: run it as admin without a UAC prompt. |
| `afterInstall` | Commands run (hidden, in `exe`'s folder) after the app is installed |
| `configs` | Files to restore: `repo` (path inside `configs\`), `target` (where it goes on the PC), `closeFirst` (processes to close first). `backup-configs.ps1` copies them the other way. |

Shortcuts, start at logon and `afterInstall` run on every setup run, so they're kept
up to date. Setup checks `apps.json` before changing anything and names any field it
can't use.
