# Release audit: Music Dynamic Island v1.5.0

Date: 2026-07-29

## Release-readiness summary

- Project type: local Windows desktop utility with a loopback HTTP bridge and
  unpacked Chromium browser extensions
- Domains checked: network infrastructure, dependency hygiene, local personal
  data, secret exposure, release packaging, and GitHub Actions
- Critical findings open: none
- High findings open: none
- External human security review required: no account, payment, or remote
  personal-data service is present
- Legal review required: no; the copyright holder explicitly selected MIT
- Going-live status: ready after the tests documented below

## Audit: Loopback browser bridge

- Scope: `IslandBridge` request handling and all browser `background.js` clients
- Domain(s): network infrastructure
- Mode: 2, explicit release-readiness check
- Original finding: wildcard CORS and unauthenticated loopback routes allowed a
  website to read media state and submit requests to the desktop bridge
- Original severity: High
- Evidence: a live request with `Origin: https://example.invalid` returned
  HTTP 200, `Access-Control-Allow-Origin: *`, and title/artist/queue fields
- Approval: bridge hardening approved by Marvin on 2026-07-29
- Fix: removed wildcard CORS, added the versioned bridge header, restricted
  accepted browser origins to extension schemes, capped headers and request
  bodies, restricted cover URLs to HTTPS on known YouTube/Google image CDNs,
  and removed the unused HTTP media-command endpoint
- Verification: missing header = 403, website origin = 403, extension origin =
  200, extension preflight = 204, website preflight = 403, oversized payload =
  413, unsafe file cover was ignored, and Unicode state payload returned 200
- Pattern sweep: no wildcard CORS header or `/command/` route remains

## Audit: Dependencies and licenses

- Scope: PowerShell, JavaScript, native helper source/DLL, manifests, and CI
- Domain(s): dependency hygiene
- Mode: 2, explicit release-readiness check
- Result: checked, no vulnerable package dependency found
- Evidence: OSV-Scanner 2.4.0 completed with `--allow-no-lockfiles` and reported
  no package sources and no issues. The native helper references only Windows
  and .NET runtime assemblies and exports only `NativeMediaThumbnail`.
- License: project released under MIT with explicit owner approval
- Fix: no dependency fix required
- Verification: all four manifests parse and report version 1.5.0
- Pattern sweep: no npm, NuGet, Python, Go, Docker, or vendored package tree is
  present

## Audit: Secrets and personal paths

- Scope: complete source tree plus nested release archives
- Domain(s): dependency hygiene and local personal data
- Mode: 2, explicit release-readiness check
- Result: checked, no secret found
- Evidence: Gitleaks 8.30.1 scanned the source and nested ZIP content with zero
  findings. Manual pattern checks found no absolute Marvin user path outside
  the intentionally local and excluded `island-settings.json`.
- Fix: `.gitignore` and the release builder explicitly exclude local settings
- Verification: release archive inspection reports zero blocked entries
- Pattern sweep: API keys, bearer tokens, passwords, private keys, and absolute
  user-specific source paths were checked

## Audit: GitHub workflows

- Scope: validate, secret-scan, Dependabot, and tagged-release automation
- Domain(s): dependency hygiene and CI supply chain
- Mode: 2, explicit release-readiness check
- Result: checked, no workflow syntax finding
- Evidence: actionlint 1.7.12 completed with exit code 0. Checkout,
  upload-artifact, and Gitleaks actions are pinned to verified tag commit SHAs.
- Fix: workflows use explicit minimal permissions and do not use
  `pull_request_target` or `workflow_run`
- Verification: the local release builder completed while the desktop app was
  running and produced a SHA-256 checksum
- Pattern sweep: all workflow `uses:` entries are full commit SHAs

## Audit: Clean release archive

- Scope: generated `Music-Dynamic-Island-v1.5.0.zip`
- Domain(s): release packaging and runtime stability
- Mode: 2, explicit release-readiness check
- Result: checked, no release blocker found
- Evidence: the ZIP was extracted into a new temporary directory and launched
  directly from that directory. The process stayed responsive, all six
  JavaScript files passed `node --check`, no user settings were present, a
  website-origin request returned 403, and an extension-origin request returned
  200.
- Fix: the native helper DLL is loaded from memory so a running Island no
  longer locks the file and blocks release creation
- Verification: the final builder completed successfully while the source
  Island process was running
- Pattern sweep: all 25 archive entries were checked; zero matched personal
  settings, Git metadata, Python cache files, or temporary release folders

## Known verification boundary

Opera GX is installed on the test machine. Google Chrome and regular Opera are
not installed, so their unpacked folders were validated by manifest parsing,
JavaScript syntax checks, and byte-identical bridge-code comparison rather than
a live browser load. All three use the same Chromium Manifest V3 bridge code.
