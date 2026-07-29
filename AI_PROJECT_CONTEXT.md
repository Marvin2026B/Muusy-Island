# AI Project Context

> This file is part of the project handoff context and must be kept up to date. Whenever architecture, deployment, data storage, security posture, external services, or major features change, update this file in the same session.

## Project identity and purpose

Windows 11 system-wide music Dynamic Island for YouTube Music in Google Chrome, Opera, and Opera GX, plus Spotify and VLC. It provides media controls, live metadata, quick app switching, queue preview, ratings, global hotkeys, volume control, layout profiles, and optional login startup.

## Current status

Version 1.5.0 is the latest working local build. The WPF host, hardened local browser bridge, native Windows media-session fallback, stable cover handling, interpolated playback clock, simplified settings, and separate Chrome/Opera/Opera GX extension folders are implemented. Existing browser extensions must be reloaded after updating from 1.4.

## Tech stack and runtime

- Windows PowerShell 5.1 and WPF
- Windows Global System Media Transport Controls
- Inline C# for the loopback bridge, window focus, global hotkeys, and Core Audio
- Opera/Chromium Manifest V3 extension
- Local-only HTTP bridge on `127.0.0.1:8765`

Start command:

```text
start-dynamic-island.bat
```

## Main files

- `dynamic_island.ps1`: desktop UI, media sessions, animation, settings, hotkeys, audio, and bridge server
- `NativeMediaThumbnail.dll`: WinRT thumbnail reader used by the PowerShell host
- `Chrome Bridge/`: unpacked Google Chrome extension
- `Opera Bridge/`: unpacked regular Opera extension
- `Entpackte Browser-Erweiterung/`: unpacked Opera GX extension kept at its established path
- `manifest.json`: compatibility manifest for installations that point at the project root
- `README.md`: installation and usage
- `build-release.ps1`: deterministic release archive and checksum builder
- `RELEASE_AUDIT_v1.5.0.md`: evidence-backed security and release-readiness record

## Storage and startup

`island-settings.json` is generated beside the script and stores user-local app paths, profiles, enabled media sources, hotkey state, and autostart state. It is intentionally excluded from release ZIP files.

Optional autostart uses the per-user registry value:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run\YouTubeMusicDynamicIsland
```

## Security and external services

There is no remote backend, account system, database, telemetry, or cloud deployment. The bridge binds to loopback only. Version 1.5 requires a versioned custom header, accepts only Chromium extension origins, limits request sizes, and restricts remote cover images to HTTPS on known YouTube/Google image CDNs. No secret values are required. User-specific executable paths in `island-settings.json` must not be included in shared archives.

## Recent changes

### 2026-07-29

- Renamed the public product to Muusy Island and added a per-user installer that copies the app to `%LOCALAPPDATA%\Muusy Island`, creates a Start Menu shortcut, preserves existing settings, and starts the app.
- Added a click-through bottom-center drag-to-close target. It appears only after a downward drag, arms when the Island overlaps it, closes with a short fade, and leaves normal custom-position saving unchanged outside the target.
- Replaced the redundant compact Play/Pause button with a borderless nine-line waveform using frame-rate-independent smoothing. Playback control remains in the expanded transport controls and global hotkeys.
- Reworked settings into three focused views for appearance, playback, and app shortcuts. Dock placement is now selected with separate edge and alignment controls instead of six repetitive position buttons.
- Added separate Chrome and regular Opera bridges while preserving the existing Opera GX extension path.
- Hardened the loopback bridge against cross-origin websites, oversized requests, unsafe cover schemes, and the unused HTTP command endpoint.
- Prepared the MIT-licensed v1.5.0 GitHub release with changelog, security policy, pinned CI actions, release automation, and deterministic SHA-256 output.

### 2026-07-28

- Added Core Audio volume adjustment via mouse wheel.
- Added global media and island hotkeys.
- Added automatic selection between YouTube Music, Spotify, and VLC sessions.
- Added YouTube Music queue preview and Like/Dislike commands.
- Added six docked position profiles, three width profiles, and custom drag persistence.
- Added optional per-user Windows login startup.
- Expanded the clean settings UI without default blue Windows control states.
- Kept cover sources pinned per track and playback time interpolated per frame.

## Known limitations and open tasks

- Queue preview and Like/Dislike depend on YouTube Music DOM selectors and require the Opera extension to be loaded and current.
- Spotify and VLC expose transport controls and metadata through Windows, but not a portable queue or rating API.
- Global hotkeys can fail if another application already owns the same key combination.

## Next recommended action

Reload the chosen v1.5.0 browser bridge, refresh the YouTube Music tab, and run a real-session smoke test for queue and rating selectors after future YouTube Music UI changes.
