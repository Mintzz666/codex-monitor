# iPhone app and widget / iPhone App 与小组件复现

The iPhone target is source-only in public releases because every installer must
sign it with their own Apple Development team. It does not depend on the Mac app.

## 1. Requirements / 环境要求

- Xcode with the iOS 17 SDK or later
- iOS 17 or later
- An Apple Development team whose provisioning supports App Groups and
  Keychain Sharing
- A Codex-enabled ChatGPT account

## 2. Choose unique identifiers / 设置唯一标识

The checked-in project uses placeholders:

- app: `com.example.codexmonitor.mobile`
- widget: `com.example.codexmonitor.mobile.widget`
- App Group: `group.com.example.codexmonitor.mobile`
- shared Keychain suffix: `com.example.codexmonitor.mobile.shared`

Replace `com.example` with a reverse-domain prefix controlled by your Apple
Development team. Update these locations together:

- `Mobile/project.yml`
- `Mobile/Resources/CodexMonitorMobile.entitlements`
- `Mobile/Resources/CodexMonitorMobileWidget.entitlements`
- `Mobile/Resources/WidgetInfo.plist`
- `Mobile/Sources/Shared/MobileUsage.swift`

Regenerate the checked-in mobile project:

```sh
brew install xcodegen
cd Mobile
xcodegen generate --spec project.yml
```

## 3. Configure signing / 配置签名

1. Open `Mobile/CodexMonitorMobile.xcodeproj`.
2. Select the **CodexMonitorMobile** app target and your Development Team.
3. Select the **CodexMonitorMobileWidget** target and the same team.
4. Confirm both targets contain the same App Group.
5. Confirm both targets contain the same Keychain access group.
6. Resolve any provisioning warning before running on a physical iPhone.

Command-line compile check without signing:

```sh
xcodebuild \
  -project Mobile/CodexMonitorMobile.xcodeproj \
  -scheme CodexMonitorMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 4. Sign in / 登录

1. Install and open the app on the iPhone.
2. Tap **使用 OpenAI 登录**.
3. The app opens the OpenAI device-authorization page and displays a temporary
   code.
4. Approve the request in the browser. The app polls for completion and loads
   the weekly quota.

The app never sees the account password. Access, refresh, and ID tokens are
stored using `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` in the shared
Keychain access group. Signing out deletes that Keychain item.

## 5. Add the widget / 添加小组件

1. Long-press the iPhone Home Screen and choose **Add Widget**.
2. Search for **Codex Monitor**.
3. Add the small widget.
4. Tap its refresh icon for an immediate request.

The widget requests a new timeline about every 15 minutes. iOS may coalesce or
delay background refreshes. If the network is unavailable, the last successful
non-sensitive snapshot remains visible.

## 6. Compatibility note / 兼容性说明

The mobile implementation follows the device-code authorization and account
usage behavior found in the official open-source Codex client. The account
usage endpoint is not a separately documented stable third-party API. A future
upstream change may require an update. Never replace the checked-in public
client ID with a private client secret, and never commit captured tokens.

## 中文摘要

iPhone 端独立登录，不需要 Mac 常开。凭据只进入 iOS 钥匙串，App Group
只保存额度百分比、重置时间和更新时间。要在真机复现，必须给 App 与 Widget
配置同一 Apple Team、App Group 和 Keychain Group；公开仓库中的
`com.example` 只是占位符。

