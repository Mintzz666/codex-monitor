# Codex Monitor → Windows 移植交接说明

> **当前状态：** Codex Monitor 1.4.9（Build 46）只有 macOS 应用和 DMG。
> 本文是后续 Windows 移植的项目说明和验收合同，不代表已有 Windows 版，
> 也不包含 Windows 实现。

## 给接手 Agent 的任务边界

目标是在单独的 Windows 分支上评估并实现 Codex Monitor 的 Windows 版本，
同时保留现有 macOS 行为。开始前先核实 Windows 上官方 Codex CLI、桌面端、
`codex app-server` 和 ChatGPT 桌面端注入能力；不得把 macOS API 或 Badge
上游的 Windows 代码直接当作已验证的 Monitor 实现。

移植起点：仓库 `Mintzz666/codex-monitor` 的 `v1.4.9` 标签，
对应提交 `4ec031d5ccd485e3dd571feb36eef4a0adeaee5e`；这不是对当前 `main` 的固定声明。
使用独立 worktree/分支开发，不改写 macOS 发布标签，不把账号数据带入
测试样例或提交。

## 产品职责和现有功能

Codex Monitor 是本地运行的 Codex 用量看板与管理入口：

- 在菜单栏显示当前额度和刷新状态；提供剩余额度、额度重置时间、
  订阅/计划信息、近期 Token 用量及错误状态。
- 提供中型和大型用量 WidgetKit 小组件，并在系统允许时登录后启动。
- 显示每日 Token 历史、社区已确认的全局重置记录和重置概率预测。
  记录和预测来自公开数据，只说明全球社区事件，不代表某个账号一定已重置。
- 统一管理定制版 Codex Usage Badge：查看 Monitor、共享额度快照、
  Badge 服务、ChatGPT CDP 和页面注入状态，并提供安装、更新、修复入口。
- 保留用户的文件夹颜色继承、会话 Recent 映射、五级 Token 色阶、
  Chat/Work 页面布局和最近重置卡定制。
- 提供只读链路健康检查和网络诊断；修复由用户明确触发。若 ChatGPT
  调试接口不可用，提示用户手动重启 ChatGPT，不由 Monitor 关闭或重开它。

目前 Windows 用户可参考的 Badge 上游文件位于
`ThirdParty/codex-usage-badge/windows`。它属于 jaykinhoo9 的开源
Codex Usage Badge 项目，不是 Codex Monitor 的 Windows 版本，也未验证
与这里的额度桥、外观定制或 Monitor 管理页兼容。个人 Codex 客户端中
安装的 `codex-monitor-health` Skill 不在当前公开仓库或 DMG 内；不能把它
当成这份公开安装包自带的功能。

## 组件与代码地图

| 目录 / 文件 | 当前职责 | Windows 移植提示 |
|---|---|---|
| `Sources/CodexUsageBar/App`、`Sources/CodexUsageBar/UI` | SwiftUI/AppKit 菜单栏、窗口、设置和生命周期 | 重新实现 Windows 托盘入口、窗口和生命周期；不可直接编译 |
| `Sources/CodexUsageBar/State/UsageViewModel.swift` | 刷新、缓存、额度历史、语言、登录启动和快照发布 | 以产品行为为基线，避免把平台 API 一并照搬 |
| `Sources/CodexUsageCore/CodexAppServerClient.swift` | 启动 app-server、stdio JSON-RPC、额度和 Token 解码 | 先实测 Windows CLI 的路径、参数、编码和协议 |
| `Sources/CodexUsageCore/CodexExecutableLocator.swift` | macOS CLI 候选路径和 `CODEX_BINARY_PATH` 覆盖 | 编写 Windows 路径发现；继续支持明确的可执行文件覆盖 |
| `Sources/CodexUsageCore/CredentialIdentity.swift` | 在刷新前后检查当前账号身份，防止串号 | 使用 Windows 当前支持的最小身份字段，禁止复制令牌 |
| `Sources/CodexUsageCore/CodexModels.swift` | app-server 响应、额度窗口和日 Token 模型 | 保留同等数据含义，容忍数字/字符串及可选字段变化 |
| `Sources/CodexUsageCore/ResetRadar.swift` | 社区重置历史和预测客户端、缓存、限流 | 与本机额度链路分离；只请求公开 JSON |
| `Sources/CodexUsageShared/SharedUsageSnapshot.swift` | 菜单、Widget、Badge 共用的快照数据合同 | 作为跨平台 UI 的语义参考 |
| `Sources/CodexUsageShared/SharedUsageStore.swift` | App Group 快照和小组件偏好持久化 | 用 Windows 用户范围的本地存储替代 App Group |
| `Sources/CodexUsageShared/LocalUsageSnapshotBridge.swift` | 只绑定 loopback 的本地快照桥 | 如保留 Badge 消费端，明确 Windows IPC 与访问边界 |
| `Sources/CodexUsageWidget` | 原生 WidgetKit 小组件 | Windows 小组件是独立范围；首版可以明确暂不提供 |
| `Sources/CodexUsageBar/State/BadgeIntegrationViewModel.swift` | Monitor 内的 Badge 状态页和修复按钮 | 将界面与健康协议保留；由 Windows 管理器实现操作 |
| `Resources/CodexUsageBadge` | 固定哈希的 macOS 定制运行版、管理器、健康和网络脚本 | macOS LaunchAgent、`launchctl`、ChatGPT 路径和启动助手都不能原样使用 |
| `ThirdParty/codex-usage-badge` | Badge fork 的上游完整源码快照，含原始 MIT 许可 | 可阅读其 Windows 子目录；保留上游作者和许可归属 |
| 本机 `codex-monitor-health` Skill | 用户本机的诊断流程；没有放入本公开仓库 | 不可依赖本机私有 Skill；以应用健康接口和公开文档为准 |

## 数据读取、身份和隐私合同

### 额度读取

macOS 版本通过本机官方 `codex app-server` 的标准输入/输出 JSON-RPC
读取 `account/read`、`account/rateLimits/read` 和
`account/usage/read`。CLI 定位优先考虑 ChatGPT App 随附 CLI 和常见
macOS 安装位置，并允许用 `CODEX_BINARY_PATH` 覆盖。启动参数尝试
`codex app-server --stdio`，再兼容 `codex app-server --listen stdio://`。

一次刷新总预算约 45 秒；对瞬时传输或服务错误重试，连续失败按 15、30、
60 秒退避；认证失败不循环启动。可选的 Token 用量请求失败时，不丢弃
已经成功的额度响应。正常后台刷新约每分钟一次，网络恢复和唤醒会检查
过期数据。

不要改成直接访问网页私有接口，也不要读取浏览器 Cookie 或把额度转发到
项目运营的云端。Codex 负责登录和令牌刷新。当前客户端为避免并发换号导致
串号，只从所选 Codex home 的本地 `auth.json` 提取 `auth_mode` 和
account ID 到内存用于匹配；实际访问令牌和刷新令牌不参与快照，不应记录、
复制或上传。身份指纹是
`SHA-256("codex-quota-v1" + NUL + canonical Codex home + NUL + account ID)`，
原始 account ID 不进入快照。发现账号切换时丢弃此次响应并清除旧缓存。

### 快照与 Badge 桥接

`SharedUsageSnapshot` 包含额度百分比、重置时间、计划名称、采集时间、
窗口长度、语言、多个额度窗口、日 Token 桶和累计 Token；Badge 所需的
Quota metadata 已剔除 account ID 与 token 字段。JSON 字段允许缺失，
额度应限制在 0–100%，负 Token 数不得进入 UI。

当前 macOS 实现按顺序尝试 TCP 端口 `51872`、`51873`、`51874`，
服务仅绑定 loopback。每个连接接收一次 JSON 字节流后关闭，不是 HTTP
服务；上限 64 KiB，最多 8 个并发连接，客户端连接超时约 750 ms。
Badge 依次尝试这些端口，只消费 Monitor 的额度快照，不再启动第二个
额度采集器。共享快照约 150 秒后视为过期，账号指纹不匹配、JSON 无效、
过大或过期均应拒绝。

Windows 端可采用有用户 ACL 的 Named Pipe，或其他经过论证的本机 IPC。
若选择 loopback TCP，必须只监听 `127.0.0.1`，限制并发、长度、超时，
并写清版本化数据协议；不要把本机额度桥暴露到局域网、加防火墙入站规则
或改系统代理。更换传输方式时必须同时适配 Badge 消费端并通过共享数据
验收。

### 外观和 ChatGPT 注入

定制 Badge 以固定 SHA-256 校验，当前 pinned agent 为
`d6e1b2d1cff2ef63964fe7b31797357d0ff25c397bdb66de351c87b1a48541db`。
验收接口要求同时核对 bundle、安装版、管理器、后台进程、额度快照和实际
页面注入标记。当前页面检查至少确认 Badge 唯一显示，项目颜色版本为 5，
会话 Token 版本为 12。

macOS 通过 ChatGPT 的 CDP 地址
`http://127.0.0.1:39222/json/list` 检查页面。若不可达，提示用户按原方式
退出并重新打开 ChatGPT；不要强制退出或循环重开。Windows 上 ChatGPT
桌面端路径、CDP 启动参数、页面结构、Work/Chat 页面对应关系都需要实机
验证。上游 Badge 的 Windows 管理器可作参考，不能据此宣称定制外观已经
注入成功。

## Windows 端需要重新选择的系统实现

macOS 当前依赖 SwiftUI/AppKit、WidgetKit、ServiceManagement、
LaunchAgent/`launchctl`、Network.framework、SystemConfiguration、
App Group、`PlistBuddy`、`codesign` 和 Xcode 构建。Windows 端应按其
生命周期和安全模型重新实现，例如：

- 菜单栏入口 → 通知区域托盘与原生状态窗口。
- 登录启动 → Windows 用户级启动任务或经核实的受支持机制；支持关闭、
  查询状态和修复。
- App Group/共享文件 → 仅当前用户可访问的本地状态存储或受限 IPC。
- Network.framework / SystemConfiguration → Windows 网络状态、代理、
  DNS、默认路由的只读检测；不要设置或改写用户的代理、防火墙、DNS。
- Xcode/DMG → 明确的 Windows 构建、安装、更新、回退与卸载包。
- WidgetKit → 单独评估 Windows Widget 支持；没有可靠验收前可以不列入
  Windows 首版功能。

不要把 macOS 路径硬编码迁移为猜测的 Windows 路径。先检查实际安装的官方
Codex CLI/桌面端及其版本；保留 CLI 路径覆盖；测试 Windows 参数引用、
UTF-8、stdio 生命周期和退出码。代理检查只能报告状态，不主动切换节点或
重写系统设置。

## Windows 移植验收清单

1. **平台边界：** README、Release 和安装器准确写明 Windows 支持状态；在
   未完成下列验收前不标记为支持。
2. **真实额度：** 在已登录的 Windows Codex CLI/桌面端读取实际用量，核对
   主要与次要窗口、重置时间、计划类型和 Token 历史；同时覆盖缺少 CLI、
   未登录、超时、升级后的协议差异。
3. **账号隔离：** 使用两个测试账号或可控 fixture 验证账号切换会立即清理
   旧快照；日志、崩溃报告、IPC 和测试产物不含令牌或原始账号 ID。
4. **单一采集源：** Badge 只消费 Monitor 的新鲜本机快照；Monitor 停止时
   Badge 明确显示不可用，Monitor 恢复后可自行恢复，不额外启动第二个
   app-server/quota 进程。
5. **IPC 安全：** 只允许本机同用户路径，覆盖端口/管道冲突、恶意长度、
   无效 JSON、过期、身份不匹配、并发和关闭重连。
6. **外观 UI：** 在 ChatGPT Windows 桌面端实机检查 Chat 和 Work 模式、
   文件夹颜色继承、Recent 重复行映射、五级 Token 色阶、重置提醒和
   唯一注入；不能以后台进程运行代替页面可见验收。
7. **安装维护：** 覆盖新装、升级、校验失败回退、修复、停止/启动后台、
   登录启动关闭和卸载。只移动/删除应用自己拥有的文件；保留用户配置。
8. **网络分类：** 分别模拟本机服务停止、代理不可达、DNS 故障、超时、
   认证失败和额度服务错误；认证/额度错误不得报告成网络故障。体检默认
   只读，不打印代理凭据，不更改代理/DNS/路由/防火墙。
9. **公开发布：** 构建 Windows 专属包，校验签名或哈希，提供清晰的系统
   要求、升级/回退说明和许可归属；不要覆盖 macOS 发行包。

## 可直接交给未来 Agent 的任务说明

> 请从 `Mintzz666/codex-monitor` 的 `v1.4.9` 基线开始评估 Windows 移植。
> 先阅读本文件、`docs/architecture-and-privacy.md`、`docs/setup-macos.md`
> 和 Badge 上游的 `ThirdParty/codex-usage-badge/windows`，再核实目标机器上
> 的官方 Codex CLI、app-server 和 ChatGPT 桌面端能力。先提交平台兼容性报告、
> 拟采用的 Windows 技术栈、最小里程碑和未验证项，之后才实施。开发使用新
> worktree/分支，不修改 macOS 功能、签名材料、发行标签或 Badge pinned
> hash；不读取、复制、日志化或上传凭据，不调整用户代理、DNS、路由或防火墙。
> 按本文件的验收清单提供脚本结果与实际 Windows UI 证据。若没有目标 Windows
> 设备，明确标记未验收，不宣称移植完成。保留 Codex Monitor 与 jaykinhoo9
> Codex Usage Badge 的许可和来源说明。
