# Public release process

This repository publishes source plus a universal macOS DMG. The iPhone target
is distributed as source because Apple signing belongs to each installer.

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
make integration-test
```

The integration check is optional in CI but expected before a manual release on
a Mac with a signed-in Codex installation.

Inspect every changed screenshot. Do not publish real account IDs, OAuth codes,
access/refresh tokens, private paths, Bluetooth UUIDs unique to a device, Apple
Team IDs, provisioning profiles, or personal email addresses.

## 3. Build artifacts

```sh
VERSION=1.4.1 BUILD_NUMBER=30 make release-package
```

This creates:

- `dist/Codex Monitor.app`
- `dist/Codex-Monitor-v1.4.1-universal.dmg`
- `dist/Codex-Monitor-v1.4.1-universal.dmg.sha256`

Without signing environment variables, the output is ad-hoc signed. Optional
notarization runs only when `APPLE_NOTARY_KEY_BASE64` and the related notary
configuration are supplied by the release environment. Never store those
credentials in the repository.

Verify the checksum:

```sh
cd dist
shasum -a 256 -c Codex-Monitor-v1.4.1-universal.dmg.sha256
```

## 4. Tag and GitHub Release

The checked-in release workflow runs for tags matching `v*`, repeats the public
release check and deterministic verifier, builds the DMG, and uploads the DMG
and checksum to a GitHub Release.

```sh
git tag -a v1.4.1 -m "Codex Monitor 1.4.1"
git push origin v1.4.1
```

For a manual release, use the text in `docs/release-notes/v1.4.1.md` and upload
only the current DMG and its matching checksum.

## 5. Post-release verification

- Open the public repository in a signed-out browser.
- Verify README images and all documentation links.
- Download the release assets and verify SHA-256.
- Confirm the source archive contains no ignored build or credential files.
- Confirm the DMG reports the intended version and contains the widget.
- Confirm the release states that the iPhone app requires local Apple signing.
