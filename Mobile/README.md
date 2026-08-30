# Codex Monitor Mobile

This is an independent iPhone container app and small WidgetKit extension.
It intentionally does not depend on the macOS app for its UI or data model.

## Data source

The app uses the device-code authorization flow and quota endpoint used
by the official open-source Codex client. The iPhone signs in independently and
does not need the macOS app. OAuth credentials are kept in an iOS shared
Keychain access group; only the non-sensitive usage snapshot is written to the
App Group for widget fallback.

The widget refresh button and timeline request live weekly quota data directly.
Transient interruptions during the Safari authorization round-trip are retried,
and the last successful snapshot remains visible during network failures.

This integration follows the official Codex implementation but the ChatGPT
quota endpoint is not a separately documented public third-party API, so a
future upstream change may require a compatibility update.

## Open and build

Open `CodexMonitorMobile.xcodeproj` directly. The generated project is checked
in, so XcodeGen is not required for normal development.

```sh
xcodebuild \
  -project Mobile/CodexMonitorMobile.xcodeproj \
  -scheme CodexMonitorMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

After editing `project.yml`, regenerate from this directory with
`xcodegen generate --spec project.yml`.

The current iPhone 17 Pro simulator rendering is stored at
`../docs/images/mobile-v1.2-preview.png`.

Before signing, replace every `com.example.codexmonitor` identifier with values
unique to your Apple Development team. The app and widget must share the same
App Group and Keychain access group. A complete bilingual procedure, including
signing, login, widget installation, storage boundaries, and troubleshooting,
is available in [`../docs/setup-ios.md`](../docs/setup-ios.md).
