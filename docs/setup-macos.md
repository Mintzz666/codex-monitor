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
make badge-test
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

For a local update, run `make install`. It preserves the identifiers of the app
already in `/Applications`, saves a rollback copy under `dist/backups/`, then
verifies the staged and installed signatures, then replaces and opens the
application in the background. A failed replacement, signature check or launch
restores the previous application. `SKIP_BUILD=1 BUILT_APP_PATH=... make install`
can install an already verified build; it refuses different app/widget/App Group
identities before stopping Monitor.
Use `BUILD_ARCHS="$(uname -m)" make install` for a faster build for this Mac only.
Full Xcode is still required.


1. Move `Codex Monitor.app` to `/Applications` and launch it once.
2. Wait for a successful usage refresh.
3. Open Notification Center, choose **Edit Widgets**, search for
   **Codex Monitor**, and add a medium or large widget.
4. The application registers launch at login by default. It can be disabled in
   the menu panel.

The reset label includes a countdown that updates once per minute while the
menu is open. The appearance panel checks the injection agent and login watcher
separately. Successful status checks are reused for 30 seconds (5 seconds when
attention is needed); **Check now** bypasses that cache.

The menu refreshes once per minute, checks stale data after wake, and supports
manual refresh with Command-R. The panel height adapts to its contents and stays
scrollable on displays with limited height. Turning off launch at login is
remembered after restarting the app. WidgetKit controls widget scheduling; the
app publishes only a sanitized quota snapshot.

The daily Token chart can show `RESET` markers for confirmed global events in
the community history. Dates follow the Mac's local time zone, and selecting a
marker opens the original Tibo post. These records describe public global
events; they do not confirm that an individual account received a reset. The
forecast below the chart shows only codex-reset.com's raw 24-hour and 48-hour
probabilities, with confidence and source update time. The app reads public JSON
without authentication and does not send account, credential, or quota-usage
data. It checks about every five minutes while running; Command-R can refresh
manually. A forecast older than 30 minutes or a failed source check hides the
percentages while preserving cached history.

## 6. Common failures / 常见问题

### No Codex data

- Confirm the official Codex CLI/app is installed and signed in.
- Run `codex --version` in Terminal.
- Run `make integration-test` from the repository.
- If using a custom binary, launch with a valid `CODEX_BINARY_PATH`.
- When using Clash, keep its normal system proxy enabled. GUI launches now
  inherit the active macOS HTTP/HTTPS proxy without shell configuration or a
  fixed port. Explicit proxy environment variables still take precedence.
- Allow up to 45 seconds for a refresh during slow upstream responses. The app
  retries transient failures and refreshes when network connectivity returns.
  It does not change Clash rules, subscriptions, nodes, or TUN settings.

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
Token 用量，再把脱敏快照通过 App Group 提供给小组件；受支持的开发和临时
签名构建也可使用本机回环 usage bridge。正常读取后每分钟刷新；连接失败时
按 15、30、60 秒退避重试，网络恢复后立即刷新。Clash 用户可继续使用系统
代理，应用自动读取当前端口，不修改全局网络设置。面板高度随内容
调整，在屏幕高度不足时可滚动；小组件由 WidgetKit 安排刷新。公开源码使用
`com.example` 占位标识，正式签名时必须替换为你自己团队下的唯一 Bundle ID
与 App Group。每日 Token 图表会按本机时区标记社区记录中已确认的全局
重置，点击可查看 Tibo 原帖；这不代表个人账号已获得重置。图表下方只显示
codex-reset.com 提供的 24 小时和 48 小时预测与置信度、更新时间。应用每约
5 分钟检查一次，支持手动刷新；不向来源发送账号、凭据或用量数据。数据
过期或来源检查失败时隐藏百分比，并保留缓存的历史记录。
