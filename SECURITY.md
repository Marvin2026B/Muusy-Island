# Security policy

## Supported versions

Only the latest `1.5.x` release receives security fixes.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature in the repository's
**Security** tab. Do not publish exploitable details in a public issue.

Include the affected version, reproduction steps, expected impact, and any
relevant logs with personal paths or media data removed.

## Local bridge boundary

The desktop host listens only on `127.0.0.1:8765`. Version 1.5 requires a
versioned bridge header and accepts browser origins only from Chromium extension
schemes. It does not provide a remote API and must not be exposed through port
forwarding, a reverse proxy, or a firewall rule.

The project has no telemetry, remote backend, account system, or cloud storage.
`island-settings.json` contains local executable paths and is intentionally
excluded from Git and release archives.
