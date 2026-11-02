# Public release process

This repository publishes the macOS app and desktop widgets as source plus a
universal macOS DMG.

## 1. Update versions

Keep these values aligned:

- `project.yml`: `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`
- checked-in macOS Xcode project
- `Scripts/package.sh`
- `Scripts/create_dmg.sh`
- `Scripts/release_package.sh`
- `Scripts/notarize.sh`

Regenerate the project with XcodeGen when available.

## 2. Privacy and verification

```sh
make public-release-check
make test
make badge-test
make integration-test
```

The integration check is optional in CI but expected before a manual release on
a Mac with a signed-in Codex installation.

Inspect every changed screenshot. Do not publish real account IDs, OAuth codes,
access/refresh tokens, private paths, device-specific identifiers, Apple Team
IDs, provisioning profiles, or personal email addresses.

## 3. Build artifacts

The prepared package version is 1.4.10, Build 47. The published 1.4.9 release
remains unchanged until a new release is explicitly published.

```sh
VERSION=1.4.10 BUILD_NUMBER=47 make release-package
```

This creates:

- `dist/Codex Monitor.app`
- `dist/Codex-Monitor-v1.4.10-universal.dmg`
- `dist/Codex-Monitor-v1.4.10-universal.dmg.sha256`

Without signing environment variables, the output is ad-hoc signed. Optional
notarization runs only when `APPLE_NOTARY_KEY_BASE64` and the related notary
configuration are supplied by the release environment. Never store those
credentials in the repository.

Verify the checksum:

```sh
cd dist
shasum -a 256 -c Codex-Monitor-v1.4.10-universal.dmg.sha256
```

## 4. Tag and GitHub Release

The checked-in release workflow runs for tags matching `v*`, repeats the public
release check and deterministic verifier, builds the DMG, and uploads the DMG
and checksum to a GitHub Release.

```sh
git tag -a v1.4.10 -m "Codex Monitor 1.4.10"
git push origin v1.4.10
```

For a manual release, use the text in `docs/release-notes/v1.4.10.md` and upload
only the current DMG and its matching checksum.

## 5. Post-release verification

- Open the public repository in a signed-out browser.
- Verify README images and all documentation links.
- Download the release assets and verify SHA-256.
- Confirm the source archive contains no ignored build or credential files.
- Confirm the DMG reports the intended version and contains the widget.
- Confirm the release contains only the macOS app and desktop widget extension.
- Verify the app's `CFBundleShortVersionString`, `CFBundleVersion`, and public
  `com.example` bundle identifiers from the newly built DMG before upload.
- Verify the embedded Badge agent hash against the pinned value in
  `Resources/CodexUsageBadge/manifest.json`.
- Never upload a pre-existing DMG by filename alone. Build and checksum the
  release asset in the same clean checkout, then verify the downloaded asset
  and the app inside it.
- State explicitly that the current release is macOS-only. Link the
  [Windows porting handoff](windows-porting-handoff.md); do not describe the
  upstream Badge Windows files as a Codex Monitor port.
