# Codex Monitor

[English](README.md)

Codex Monitor 是一个非官方、本地优先的 Codex 用量看板。现在专注于这台 Mac 的日常使用，包含：

- 原生 macOS 菜单栏应用，以及中型/大型 WidgetKit 小组件。
- 可选的 ChatGPT 外观增强联动：在 Monitor 菜单查看连接状态，并安装或修复定制版 Badge。

![macOS 菜单](docs/images/usage-popover.png)

## 包含内容

| 组件 | 数据来源 | 默认刷新策略 |
|---|---|---|
| macOS 菜单 | 本机启动的 `codex app-server` | 每分钟 |
| macOS 小组件 | App Group 内的脱敏快照；临时签名构建可回退到本机回环 | WidgetKit 时间线 |
| ChatGPT 外观增强 | Monitor 的本机脱敏额度快照；由随 Monitor 安装并管理的 Badge 助手注入页面样式 | 后台助手约每 5 秒读取本地快照 |
| 全局重置历史与预测 | [codex-reset.com](https://codex-reset.com/) 的公开社区记录与预测 | 应用运行时约每 5 分钟；支持手动刷新 |

每日 Token 图表会在本机日期下标出已确认的全局重置。点击标记可打开
Tibo 原帖。标记表示社区记录中有这次事件，不代表某个个人账号已收到重置。
图表下方会显示来源提供的 24 小时和 48 小时全局重置原始概率、置信度及
来源更新时间；不显示 12 小时或 36 小时概率。预测数据超过 30 分钟或来源
检查失败时会隐藏百分比，已缓存的重置历史仍会保留。

ChatGPT 外观增强使用 jaykinhoo9 的开源 Codex Usage Badge，并集成 Mintzz 的
文件夹颜色继承、Recent 会话映射、Token 色阶、Work 排版和重置时间定制。
安装、更新和修复都从 Codex Monitor 操作，无需单独安装 Badge。完整 fork
源码保存在 [`ThirdParty/codex-usage-badge`](ThirdParty/codex-usage-badge)。后台
助手通过 Monitor 的本机回环快照共享额度，不启动第二个额度采集器。详情见
[NOTICE.md](NOTICE.md) 和应用内“外观增强”页面。

## 快速开始

### macOS 应用

1. 从 [Releases](https://github.com/Mintzz666/codex-monitor/releases) 下载 DMG。
2. 将 **Codex Monitor** 拖入 `/Applications`。
3. 确认官方 Codex CLI/App 已安装并登录。
4. 启动 Codex Monitor；应用会读取本机数据并默认注册登录时启动。
   关闭登录时启动后会记住选择；菜单支持手动刷新（⌘R），唤醒后会检查数据。

社区构建默认使用临时签名。若 Gatekeeper 阻止首次启动，可以右键应用选择
**打开**，或按文档自行从源码构建。

## 从源码构建

需要：

- macOS 13 或更高版本；
- 完整 Xcode，以及支持 Swift 6.3 的工具链；
- 运行真实 macOS 数据测试时，需要官方 Codex CLI/App；
- 只有重新生成已检入的 Xcode 工程时才需要 XcodeGen。

```sh
git clone https://github.com/Mintzz666/codex-monitor.git
cd codex-monitor

make test
make package
make dmg
```

使用 Apple Development Team 签名前，请把
`com.example.codexmonitor` 和 `group.com.example.codexmonitor`
全部替换成属于你团队的唯一标识，然后重新生成工程：

```sh
brew install xcodegen
make xcode-project
```

完整步骤：[macOS 构建指南](docs/setup-macos.md)。

## 数据与隐私

macOS 端只启动本机已经安装的 `codex app-server`，调用 `account/read`、
`account/rateLimits/read` 和 `account/usage/read`。登录与令牌刷新仍由 Codex
负责；本应用不读取浏览器 Cookie，也不复制 Codex 凭据。

项目不包含统计分析、广告 SDK、云数据库或 Codex Monitor 自行运营的后端。
重置历史与预测通过未认证的公开 JSON 请求读取 codex-reset.com；请求不会
包含账号信息、Codex 凭据或用量数据。详见：[架构、数据流与隐私](docs/architecture-and-privacy.md)。

## 复现文档

- [macOS 应用和小组件](docs/setup-macos.md)
- [架构、数据流与隐私](docs/architecture-and-privacy.md)
- [发布流程](docs/releasing.md)
- [参与贡献](CONTRIBUTING.md)
- [安全策略](SECURITY.md)

## 许可与归属

项目使用 MIT 协议，基于
[`CMMUU/codex-usage-bar`](https://github.com/CMMUU/codex-usage-bar) 改造。
原项目版权和 MIT 条款保留在 [LICENSE](LICENSE)，其他说明见
[NOTICE.md](NOTICE.md)。

Codex、ChatGPT、OpenAI 和 Apple 等名称归各自权利人所有。
本项目是社区项目，与 OpenAI 或 Apple 不存在隶属或背书关系。
