# Muusy Island

Muusy Island is a system-wide Windows 11 music controller with a compact glass interface. It can control YouTube Music, Spotify, and VLC without keeping the browser in the foreground.

## Features

- YouTube Music support for Google Chrome, Opera, and Opera GX
- Windows media-session support for Spotify and VLC
- Play/pause, previous, next, volume, queue preview, and ratings
- Global hotkeys and mouse-wheel volume control
- App shortcuts that focus an existing app or start it when needed
- Profiles for position and size, optional autostart, and drag-to-close
- Per-user installation with no administrator rights
- No account, cloud service, telemetry, or API key required

## Requirements

- Windows 11
- Windows PowerShell 5.1
- One supported browser or media player

## Install and start

1. Download the latest `Muusy-Island-v1.5.0.zip` from the GitHub Releases page.
2. Extract the ZIP to a temporary folder.
3. Double-click `Install-MuusyIsland.bat`.
4. The installer copies Muusy Island to `%LOCALAPPDATA%\Muusy Island`, creates a Start Menu shortcut, and starts the app.

After installation, start it from the Windows Start Menu by searching for **Muusy Island**. The extracted release folder can be deleted after installation.

The installer is per-user and does not require administrator access. It keeps the local settings file out of the release archive and does not overwrite it during updates.

## Install the browser bridge

The bridge is only required for YouTube Music. Spotify and VLC use Windows media sessions directly.

### Google Chrome

1. Open `chrome://extensions`.
2. Enable **Developer mode**.
3. Select **Load unpacked**.
4. Choose the `Chrome Bridge` folder from the extracted release.

### Opera

1. Open `opera://extensions`.
2. Enable **Developer mode**.
3. Select **Load unpacked**.
4. Choose the `Opera Bridge` folder from the extracted release.

### Opera GX

1. Open `opera://extensions`.
2. Enable **Developer mode**.
3. Select **Load unpacked**.
4. Choose the `Entpackte Browser-Erweiterung` folder from the extracted release.

Open YouTube Music after loading the bridge. After an update, click **Reload** on the bridge and refresh the YouTube Music tab.

## Controls

- Mouse wheel over the Island: adjust system volume
- `Ctrl+Alt+Space`: play/pause
- `Ctrl+Alt+Left`: previous track
- `Ctrl+Alt+Right`: next track
- `Ctrl+Alt+I`: expand or collapse the Island
- Drag the Island down onto the X target to close it

The settings button in the expanded Island opens the configuration. Settings are grouped into appearance, playback, and app shortcuts.

## Local data and security

The local bridge listens on `127.0.0.1:8765` and accepts requests only from the bundled browser extensions. There is no remote backend or telemetry. Cover images are fetched only from the supported YouTube and Google image hosts over HTTPS.

Personal settings are stored in `island-settings.json` next to the application and are excluded from Git and release archives. Please report security issues privately using [SECURITY.md](SECURITY.md).

## Build a release

```powershell
.\build-release.ps1 -Version 1.5.0
```

The script validates all four manifests, parses the PowerShell source, creates `release\Muusy-Island-v1.5.0.zip`, and writes `SHA256SUMS.txt`.

## License

MIT. See [LICENSE](LICENSE).
