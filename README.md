# Codex Monitor

[简体中文](README.zh-CN.md)

Codex Monitor is an unofficial, local-first dashboard for Codex usage. It focuses on
the Mac, with these surfaces:

- a native macOS menu bar app with medium and large WidgetKit widgets.
- an optional ChatGPT appearance integration managed from the Monitor menu.

![macOS menu](docs/images/usage-popover.png)

## What is included

| Component | Data source | Default refresh |
|---|---|---|
| macOS menu | locally launched `codex app-server` | every minute |
| macOS widgets | sanitized App Group snapshot, with a loopback fallback for ad-hoc builds | WidgetKit timeline |
| ChatGPT appearance | Monitor's sanitized local quota snapshot; an included Badge helper injects the appearance | Monitor-managed helper polls the local snapshot about every 5 seconds |
| Global reset history and forecast | public community records and forecast from [codex-reset.com](https://codex-reset.com/) | about every 5 minutes while the app is running; manual refresh is available |

The daily Token chart marks confirmed global resets on the local calendar date.
Each marker opens Tibo's original post. It reflects a community-recorded event,
not confirmation that an individual account received a reset. Below the chart,
the app shows the source's raw 24-hour and 48-hour global-reset probabilities,
along with confidence and source update time. It does not show 12-hour or
36-hour probabilities. Forecast percentages are hidden when the source data is
over 30 minutes old or a source check fails; cached reset history remains visible.

The appearance integration packages jaykinhoo9's open-source Codex Usage Badge
with Mintzz's folder-color inheritance, Recent thread mapping, Token shades,
Work layout, and reset-time customizations. Install, update, and repair it from
Codex Monitor; no separate Badge installation is required. The full fork source
is preserved in [`ThirdParty/codex-usage-badge`](ThirdParty/codex-usage-badge).
The managed helper reads Monitor's local loopback snapshot and does not start a
second quota collector. See [NOTICE.md](NOTICE.md).

## Quick start

### macOS app

1. Download the DMG from [Releases](https://github.com/Mintzz666/codex-monitor/releases).
2. Drag **Codex Monitor** to `/Applications`.
3. Make sure the official Codex CLI/app is installed and signed in.
4. Start Codex Monitor. It refreshes locally and offers launch at login.
   Disabling launch at login is remembered across restarts.

Community DMGs are ad-hoc signed unless a maintainer supplies Apple signing and
notarization credentials. If Gatekeeper blocks the first launch, right-click the
app and choose **Open**, or build it from source.

## Build from source

Requirements:

- macOS 13 or later;
- a full Xcode installation with a Swift 6.3-capable toolchain;
- the official Codex CLI/app for the live macOS integration test;
- XcodeGen only when regenerating checked-in Xcode projects.

```sh
git clone https://github.com/Mintzz666/codex-monitor.git
cd codex-monitor

make test
make package
make dmg
```

Before signing with an Apple Development team, replace every
`com.example.codexmonitor` and `group.com.example.codexmonitor` identifier with
values unique to your team, then regenerate the projects:

```sh
brew install xcodegen
make xcode-project
```

Full instructions: [macOS build guide](docs/setup-macos.md).

## Data and privacy

On macOS, Codex Monitor launches the locally installed `codex app-server` and
uses `account/read`, `account/rateLimits/read`, and `account/usage/read`.
Authentication and refresh-token handling remain inside Codex. The app does
not read browser cookies or copy Codex credentials.

No analytics, advertising SDK, cloud database, or Codex Monitor-operated backend
is included. Reset history and forecasts come from unauthenticated public JSON
requests to codex-reset.com. Those requests do not include account details,
Codex credentials, or quota usage. See [architecture and privacy](docs/architecture-and-privacy.md).

## Reproduction map

- [macOS app and widgets](docs/setup-macos.md)
- [architecture, data flow, and privacy](docs/architecture-and-privacy.md)
- [release process](docs/releasing.md)
- [contributing](CONTRIBUTING.md)
- [security policy](SECURITY.md)

## License and attribution

MIT licensed. This project is derived from
[`CMMUU/codex-usage-bar`](https://github.com/CMMUU/codex-usage-bar). The
original copyright notice and MIT terms are preserved in [LICENSE](LICENSE),
with additional attribution in [NOTICE.md](NOTICE.md).

Codex, ChatGPT, OpenAI, and Apple are trademarks of their respective owners.
This community project is not affiliated with or endorsed by OpenAI or Apple.
