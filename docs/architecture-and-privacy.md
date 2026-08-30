# Architecture and privacy / 架构与隐私

## Data flow

```text
macOS Codex login
      │ local JSON-RPC/stdin-stdout
      ▼
codex app-server ──► macOS menu model ──► App Group snapshot ──► macOS Widget
                           │
                           └──► 400×300 renderer ──► short BLE session ──► EPD

iPhone OpenAI device authorization
      │ credentials in shared iOS Keychain only
      ▼
iPhone account service ──► non-sensitive App Group snapshot ──► iPhone Widget
```

The macOS and iPhone authentication paths are independent. The Bluetooth board
never receives account credentials or raw server responses; it receives only
two one-bit image planes.

## macOS boundary

The app launches the locally installed Codex app-server and requests account,
rate-limit, and usage data. Codex owns authentication and token refresh. Codex
Monitor does not parse browser storage or credential files.

Persisted macOS data is limited to display-oriented values such as quota
percentage, reset time, recent daily token counts, language, remembered BLE
device metadata, last EPD sync time, and a rendered-frame fingerprint. The
repository contains no live account snapshot.

## iPhone boundary

The iPhone app completes device authorization in the OpenAI browser flow.
Credentials are encoded only for an iOS Keychain item shared between the app and
widget, using a ThisDeviceOnly accessibility class. App Group storage contains
only `usedPercent`, `resetsAt`, and `updatedAt`.

The source contains a public OAuth client identifier used by the official
open-source flow. It is not a client secret. Do not add a client secret to a
mobile application or commit live OAuth responses.

## Bluetooth boundary

The EPD receives final black and red pixels, not quota JSON, account IDs, access
tokens, filenames, or computer information. BLE connections exist only while
probing or transferring. Successful transfers end with an explicit disconnect.

## Network behavior

- macOS: local Codex app-server; Codex itself may contact its service.
- iPhone: OpenAI authorization and ChatGPT account-usage endpoints.
- EPD: local Bluetooth only.
- Project: no analytics, ads, telemetry SDK, cloud database, or maintainer API.

## Public-release privacy controls

The public repository is assembled without the original Git history so personal
commit email addresses are not republished. It excludes build directories,
DMG history, local Xcode user data, provisioning profiles, Keychain exports,
environment files, and workspace paths. Bundle and App Group identifiers use
`com.example` placeholders.

`Scripts/public_release_check.py` scans the publication tree for absolute user
paths, common token formats, private keys, personal bundle markers, and risky
credential files. It is a defense-in-depth check, not a substitute for manual
review.

## User responsibilities / 使用者责任

- Review screenshots and logs before posting them publicly.
- Never attach Codex app-server traffic containing account-specific data.
- Use unique Apple identifiers rather than committing a personal Team ID.
- Revoke credentials immediately if a token or provisioning secret is exposed.
- Report security issues privately as described in `SECURITY.md`.

