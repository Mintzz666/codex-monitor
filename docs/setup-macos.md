# macOS reproduction / macOS 复现指南

## 1. Requirements / 环境要求

- macOS 13 or later / macOS 13 或更高版本
- Full Xcode with a Swift 6.3-capable toolchain / 完整 Xcode 与支持 Swift 6.3 的工具链
- The official Codex CLI/app installed and signed in / 已安装并登录官方 Codex CLI/App
- XcodeGen only when project files must be regenerated / 仅重新生成工程时需要 XcodeGen

Check the local toolchain:

```sh
xcodebuild -version
swift --version
codex --version
```

Codex Monitor searches common application and command-line locations. For a
custom installation, set `CODEX_BINARY_PATH` when running a development build.

## 2. Clone and verify / 克隆与验证

```sh
git clone https://github.com/Mintzz666/codex-monitor.git
cd codex-monitor

make test
```

`make test` uses deterministic fixtures and does not require account data. The
optional live check launches the local Codex app-server and therefore requires
an existing Codex login:

```sh
make integration-test
```

The verifier prints only structural assertions. Do not attach live command
output to public issues without reviewing it first.

## 3. Bundle and App Group identifiers / 标识符

The public source uses non-personal placeholders:

- `com.example.codexmonitor`
- `com.example.codexmonitor.widget`
- `group.com.example.codexmonitor`

For local ad-hoc builds they may remain unchanged. For Apple Developer signing,
replace them with identifiers unique to your team in `project.yml`, then update
the matching shared constants and regenerate the Xcode project:

```sh
brew install xcodegen
make xcode-project
```

Keep the main app and widget App Group values identical. A mismatch makes the
widget fall back to the loopback bridge or show stale data.

## 4. Build / 构建

SwiftPM development build:

```sh
make build
make widget-build
```

Universal application bundle:

```sh
make package
```

DMG:

```sh
make dmg
```

Artifacts are written to `dist/`, which is intentionally ignored by Git.

To run from Xcode, open `CodexUsageBar.xcodeproj`, select the
`CodexUsageBar` scheme and **My Mac**, choose a Development Team if desired,
then Run. The built product is `Codex Monitor.app`.

## 5. Install and widgets / 安装与小组件

1. Move `Codex Monitor.app` to `/Applications` and launch it once.
2. Wait for a successful usage refresh.
3. Open Notification Center, choose **Edit Widgets**, search for
   **Codex Monitor**, and add a medium or large widget.
4. The application registers launch at login by default. It can be disabled in
   the menu panel.

The menu refreshes once per minute. WidgetKit controls widget scheduling; the
app publishes only a sanitized quota snapshot.

## 6. Common failures / 常见问题

### No Codex data

- Confirm the official Codex CLI/app is installed and signed in.
- Run `codex --version` in Terminal.
- Run `make integration-test` from the repository.
- If using a custom binary, launch with a valid `CODEX_BINARY_PATH`.

### Widget does not update

- Launch the container app once and refresh successfully.
- Confirm both targets use the same App Group.
- Remove and re-add the widget after changing bundle identifiers.

### Gatekeeper warning

The public community DMG is ad-hoc signed unless the release maintainer provides
Apple signing and notarization credentials. Right-click **Open** for the first
launch, or build locally with your own Development Team.

## 中文摘要

Mac 端不保存 Codex 登录令牌。它启动本机 Codex app-server，读取周额度和
Token 用量，再把脱敏快照交给小组件。菜单每分钟刷新；小组件由 WidgetKit
安排刷新。公开源码使用 `com.example` 占位标识，正式签名时必须替换为你自己
团队下的唯一 Bundle ID 与 App Group。

