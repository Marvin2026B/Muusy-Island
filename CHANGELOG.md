# Changelog

All notable changes to Muusy Island are documented here.

## [1.5.0] - 2026-07-29

### Added

- Separate unpacked bridges for Google Chrome, Opera, and Opera GX.
- Browser bridge reconnects automatically after reloads, startup, and existing-tab recovery.
- Per-user installer with Start Menu and Desktop shortcuts.
- Native Windows media-session detection for Chrome and regular Opera.
- Three focused settings views for appearance, playback, and app shortcuts.
- Borderless compact waveform with frame-rate-independent smoothing.
- Bottom-center drag-to-close target with an animated armed state.
- GitHub release builder, release workflow, validation workflow, and secret scan.

### Changed

- Simplified dock positioning into screen edge and alignment controls.
- Improved settings labels and app-slot setup.
- Preserved custom-position saving when a drag ends outside the close target.
- Updated browser manifests and documentation for all supported Chromium browsers.

### Security

- Removed wildcard CORS access from the loopback bridge.
- Required the versioned bridge header for all state and command-poll requests.
- Restricted browser origins to extension schemes.
- Limited request headers and request bodies.
- Restricted remote cover loading to HTTPS URLs on known YouTube/Google image CDNs.
- Removed the unused HTTP media-command endpoint.

## [1.4.0] - 2026-07-28

- Added Windows media-session fallback, stable cover handling, queue preview,
  ratings, global hotkeys, volume control, profiles, app shortcuts, and optional
  per-user autostart.
