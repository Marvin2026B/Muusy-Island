# Release checks: Muusy Island v1.5.0

These results were recorded for the v1.5.0 release on July 29, 2026. They describe that release and do not cover later changes.

## Local bridge

- A request from a website origin was rejected with HTTP 403.
- Requests from a bundled browser extension were accepted.
- Requests without the bridge header were rejected; oversized request bodies were rejected with HTTP 413.
- The host listens on `127.0.0.1` and does not expose a remote API.

## Release package and repository checks

- The release archive was extracted to a temporary folder and launched.
- The archive did not contain local settings or Git metadata.
- Gitleaks reported no secrets in the source tree or archive.
- OSV-Scanner found no package sources and reported no issues.
- The GitHub workflows passed `actionlint`; workflow actions were pinned to commit SHAs.

## Browser coverage

Opera GX was loaded on the test machine. Chrome and regular Opera were not installed; their extension folders were checked by manifest parsing, JavaScript syntax validation, and comparison with the Opera GX bridge.
