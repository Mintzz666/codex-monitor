# Architecture and privacy / 架构与隐私

## Data flow

```text
macOS Codex login
      │ local JSON-RPC/stdin-stdout
      ▼
codex app-server ──► macOS menu model ──┬──► App Group snapshot ──► macOS Widget
                                        └──► loopback usage bridge ──► macOS Widget (fallback)

Codex Monitor ── unauthenticated public JSON ──► codex-reset.com
```

WidgetKit reads a sanitized App Group snapshot. Supported development and ad-hoc
configurations can provide widget data through the local loopback usage bridge.

## macOS boundary

The app launches the locally installed Codex app-server and requests account,
rate-limit, and usage data. Codex owns authentication and token refresh. Codex
Monitor does not read browser storage. To detect an account change during a
refresh, it reads only `auth_mode` and the account ID from the selected Codex
home's local `auth.json` into process memory. It does not use, persist, log, or
send access or refresh token values; the raw account ID is not included in
snapshots or network requests. The included Badge helper uses the same minimal
identity check before accepting a shared quota snapshot.

Persisted macOS usage data is limited to display-oriented values such as quota
percentage, reset time, recent daily token counts, and language. The repository
contains no live account snapshot.

## Global reset history and forecast

The app reads the public `GET /api/timeline` and `GET /api/forecast` endpoints
from [codex-reset.com](https://codex-reset.com/developers). These requests need
no authentication, use a marked `User-Agent`, and send no cookies, account
identifiers, Codex credentials, or quota-usage values.

The daily Token chart marks only community-history records that are confirmed,
global resets. Banked resets and announcements or forecasts are excluded. Event
dates are shown in the Mac's local time zone, and selecting a marker opens the
original Tibo post. A marker documents a community-recorded global event; it
does not verify delivery to any individual account.

Below the chart, the app displays the source's raw 24-hour and 48-hour reset
probabilities, plus its confidence and update time. It does not invent 12-hour
or 36-hour values. While the app runs, it checks the source about every five
minutes; manual refresh can request an update sooner. The client honors
`Retry-After` on HTTP 429 responses. If a forecast is over 30 minutes old or a
source check fails, the app hides the probability values and keeps cached reset
history available.

## Network behavior

- macOS: local Codex app-server and local widget data delivery; Codex itself may
  contact its service.
- GUI launches translate the active macOS HTTP/HTTPS proxy settings into the
  app-server's process environment (including Clash's configured port). Explicit
  environment proxies take precedence. Proxy ports and nodes are not hard-coded;
  the app does not change Clash rules, nodes, TUN, or the system proxy. There is
  no automatic ChatGPT or wildcard proxy bypass.
- A refresh has a 45-second budget, divided between two attempts, and supports
  both stdio CLI argument forms. Transient errors can retry; authentication
  failures are reported without repeated launches. Quota polling skips the
  separate reset-credit detail request, with a compatibility fallback for older
  CLIs. Optional token-activity failures do not discard a successful quota read.
- Successful background refreshes wait one minute between polls. Failed reads
  retry after 15, 30, then 60 seconds. Network recovery triggers a refresh, and
  the existing wake handler refreshes stale data. These hooks run inside the app.
- Reset data: unauthenticated public JSON requests to codex-reset.com; no
  account-specific data is sent.
- Project: no analytics, ads, telemetry SDK, cloud database, or Codex
  Monitor-operated backend.

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
