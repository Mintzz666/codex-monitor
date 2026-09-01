# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 1.4.x | Yes |

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** flow on the repository Security
page. Do not open a public issue for vulnerabilities involving authentication,
local process execution, credential exposure, or malicious Codex protocol
responses.

Include:

- affected version or commit
- macOS and Codex versions
- reproduction steps
- impact
- suggested mitigation, if available

Please remove tokens, cookies, email addresses, account identifiers, and
private filesystem paths from reports and attachments.

## Security boundaries

Codex Monitor is designed to:

- communicate only with a locally launched Codex app-server
- avoid reading Codex authentication files
- avoid browser cookies
- avoid persisting access tokens
- treat app-server responses as untrusted input
- keep iPhone OAuth credentials in a ThisDeviceOnly Keychain group
- send only rendered pixels, never account data, to the BLE display

Changes that weaken these boundaries require explicit security review.
