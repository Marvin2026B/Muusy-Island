# Changelog

All notable changes to Muusy Island are documented here.

## [Unreleased]

### Added

- Discord Rich Presence for currently playing media, with background IPC reconnects and a configurable Discord Application ID.
- Use the active media source name in Discord activity labels.

### Changed

- Fix the invalid WPF animation duration type that caused the Island to close when a track transition animation ran.
- Use YouTube Music's fresh browser video position for accurate elapsed time when the Island starts during a song.
- Keep queue tokens stable when YouTube Music replaces queue rows, retry brief DOM updates, and expose the bridge build so stale extensions cannot silently accept clicks.
- Make queue selection target the row's play control, including controls inside open shadow roots, and allow commands more time to reach the browser.
- Simplified the Island's compact surface and made its audio visualizer respond more clearly to media-session peaks.
- Added a visible directional cover and title transition for next and previous tracks.
- Reasserted the Island's topmost position without stealing focus.
- Added single-instance startup protection for manual and login launches.
- Added a square Muusy Island logo mark for Windows shortcuts.

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
