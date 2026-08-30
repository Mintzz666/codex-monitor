# Contributing

Thanks for helping improve Codex Monitor.

## Before you start

- Search existing issues before opening a new one.
- Keep changes focused and avoid unrelated refactors.
- Do not include account data, tokens, cookies, local paths, or screenshots
  containing personal information.
- Use [SECURITY.md](SECURITY.md) for vulnerabilities.

## Development requirements

- macOS 13 or later
- Swift 6.3 toolchain
- A local Codex installation for optional integration checks
- Xcode with the iOS 17 SDK for mobile changes

## Local workflow

```bash
git clone https://github.com/Mintzz666/codex-monitor.git
cd codex-monitor

make test
make package
make public-release-check
```

Run the live integration check only when Codex is installed and signed in:

```bash
make integration-test
```

Format Swift sources before committing:

```bash
swift format --in-place --recursive Sources Tests Mobile/Sources Package.swift
swift format lint --recursive Sources Tests Mobile/Sources Package.swift
```

## Pull requests

A pull request should include:

1. A concise problem statement.
2. The implementation approach.
3. Verification commands and observed results.
4. Screenshots for visible UI changes.
5. Compatibility notes for Codex protocol changes.

All pull requests must pass the macOS CI workflow.

## Protocol changes

The app intentionally communicates through the local Codex app-server instead
of reading authentication material. Preserve that boundary when adding
features.

If a Codex response shape changes:

- update the decoding models
- keep unknown fields forward-compatible
- add a deterministic verifier fixture
- run the live integration check when possible

For iPhone changes, never commit device-authorization codes, OAuth responses,
Keychain exports, provisioning profiles, Apple Team IDs, or personal bundle
identifiers. For EPD changes, include a deterministic plane/orientation check
and state the exact hardware model used for physical verification.
