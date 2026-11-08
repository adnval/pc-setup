# pc-setup

Sets up my Windows 11 PC after a clean install: installs my apps from their official
sources, restores their configs, and finishes setup (shortcuts, mpv file types, OBS
autostart).

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

7-Zip, OBS Studio, Discord, Spotify + SpotX, Notepad++, Lightshot, LosslessCut, mpv,
Paint.NET, Revo Uninstaller, HWiNFO64, ZenTimings, Microsoft 365 (apps chosen in
`configs\Office\Configuration.xml`).

- **Portable apps** (LosslessCut, mpv, ZenTimings) go in `C:\Program Files\<name>` with a
  Start Menu shortcut.
- **mpv** is registered for video and audio files. Set it as the default in
  Settings → Apps → Default apps → mpv.
- **OBS** starts at logon from the scheduled task *OBS Studio (replay buffer)*, minimized
  to the tray with the replay buffer running.

## apps.json

Each app is one entry; the order is the install order. Remember `\\` for `\` in JSON.

```jsonc
{
  "name": "OBS",                    // for -Only / -Skip
  "detect": "^OBS Studio",          // regex on its name in Settings → Apps (not for portable apps)
  "source": { "github": "obsproject/obs-studio", "asset": "Windows-x64-Installer\\.exe$" },
  "install": { "args": "/S" },
  "configs": [
    { "repo": "obs-studio/basic", "target": "%APPDATA%\\obs-studio\\basic", "closeFirst": ["obs64"] }
  ],
  "after": ["obsLogonTask"]
}
```

- **`source`:** `{ "github", "asset" }` (latest release), `{ "sourceforge", "folder", "file" }`
  (newest matching file) or `{ "url", "file" }`.
- **How it installs:**
  - `"install": { "args", "signer", "hidden" }` runs an .exe, an .msi, or the .msi in a .zip.
    `signer` requires a matching signature, and `{configs}` in `args` is the configs folder.
  - `"portable": { "exe" }` unpacks into Program Files and adds a shortcut.
  - `"runUnelevated": "<command>"` runs in a normal-user window.
- **`after`:** the finishing steps defined in `setup.ps1`, `mpvFileTypes` and `obsLogonTask`.
