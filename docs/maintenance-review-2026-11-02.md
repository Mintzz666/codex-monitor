# Codex Monitor 1.4.9 maintenance review / 整合版审查

Reviewed on 2026-11-02 against public main `8e09ae9`, release `v1.4.9`
(Build 46). This review first recorded proposed changes. After approval, runtime-only
packaging was implemented and measured; see the implementation results below.
Local cache cleanup has not been performed.

本次以公开整合版为基线，检查构建入口、主要数据链路、内置助手、源码归属、
安装包组成和现有测试。以下是定向审查，不是完整安全审计或长期性能基准。

## 结论 / Findings

整合后的产品结构合理：菜单栏和 WidgetKit 共享 Swift 数据模块，Monitor
负责额度采集，Badge 通过本机回环快照复用额度，没有必要为减少进程数量而立即
重写整条链路。原生启动桥和后台助手各自承担页面注入与客户端启动观察职责。
第三方完整源码只保存在仓库中，没有装入 DMG。

当前有价值的第一步是精简**打包内容**，再考虑减少轮询或重构。删除开发缓存
只能释放开发机磁盘，不会降低安装后应用的内存或 CPU 占用。

## 体积与可精简项 / Size opportunities

样本：当前已安装的 1.4.9 应用。按文件逻辑长度合计为 8,497,433 bytes
（约 8.10 MiB）；`du` 的文件系统占用约为 8.2 MiB。压缩 DMG 为 4,588,711 bytes。
以下收益按文件长度估算，不是已完成的新构建实测。

| 项目 | 证据与职责 | 建议 | 预计收益与边界 |
|---|---|---|---|
| `Resources/AppIcon/AppIcon-1024.png` | `project.yml` 将它和 `AppIcon.icns` 一起复制到应用；当前 Swift 代码未引用 PNG，Info.plist 使用 ICNS | 保留源码 PNG 供 README/开发使用，停止将 PNG 装入应用；验证 Finder 图标和启动 | 1,015,787 bytes；不影响运行内存的收益需另测 |
| `Resources/CodexUsageBadge/local-customization/` | 打包时整目录复制，`manage.cjs` 还会递归安装；其中 `agent-folder-color.cjs` 与根目录 agent 完全同哈希，另含历史版本、补丁和回退脚本 | 源码与回退资料保留在仓库；发布包只装运行依赖 | 当前样本共 303,693 bytes；与上一项合计约 1.26 MiB，占应用文件长度约 15.5% |
| `ThirdParty/codex-usage-badge/` | 73 文件，约 1.67 MB；最大的是上游封面。未被 `project.yml` 或打包脚本复制 | 保留完整来源、测试和 Windows 移植参考；如有需要再压缩封面 | 精简这里不减少安装后的应用体积；删源码或改写 Git 历史收益有限 |
| `.build/` | 审查开始时约 546 MiB，主要为 Xcode 与 Swift 模块缓存、索引和中间产物 | 完成构建验收后可按需移入废纸篓；下次构建重建 | 开发机磁盘空间；不会减少 DMG 或用户运行内存 |
| `dist/backups/` | 审查开始时约 23 MiB 的历史回退包 | 经选择后归档或移入废纸篓；保持当前安装的回退能力 | 仅开发机磁盘空间；不永久删除 |

**实施条件：**不能只删 `local-customization`。应同时把 manifest 的
`runtimeFiles`、`manage.cjs` 的安装清单与打包脚本改为明确的运行文件清单；
`health.cjs` 目前按 manifest 核验文件，直接删会造成健康检查失败。
保留 LICENSE、NOTICE、启动桥、共享快照适配器和诊断脚本；原始资料与已安装
用户数据不应被自动清除。

## 运行占用与代码结构 / Runtime and structure

- 单次采样的 Monitor 主进程 RSS 约 55.2 MiB、CPU 0.0%。这不包含独立 Badge/
  启动观察进程，也不是长期峰值、能耗或物理内存的测试结果。
- `Package.swift` 没有外部 Swift 包依赖；没有发现为了普通 UI 引入的大型 SDK。
- `network-agent.cjs` 仍保留旧网络适配功能；当前入口只启用
  `installSharedQuotaAdapter()`。这部分是潜在维护冗余，但应先查调用方和回归
  覆盖，再拆分或移除，预期磁盘收益小。
- 主应用成功读取后每分钟刷新；失败按 15/30/60 秒退避。Badge 约每 5 秒读取
  本机快照。可考虑按窗口可见性降低页面处理频率，或缓存身份指纹，但必须保留
  账号切换及时失效，不能只为省一次文件读取而接受旧账号额度。
- 每次打开菜单会触发 Badge 健康检查，包含签名和文件哈希检查；若后续发现
  打开延迟，可短时缓存结果，并让“立即检查”强制更新。尚未做打开延迟基准，
  当前不据此宣称性能问题。
- 外观管理窗口标题目前固定中文，错误和部分管理消息仍是英文；属于后续应用
  内双语完善项，本次 GitHub 双语更新不等于应用所有字符串已经双语化。

## 发布与维护问题 / Release maintenance

1. CI 的包版本和验证路径仍硬编码 `1.4.4`，而当前发布为 `1.4.9`。
   现有 CI 能通过，但其产物标签可能误导维护者。建议统一版本来源后再发布新包。
2. CI 的 `make test` 运行 Swift 验证器，没有执行根目录 Badge Node 测试。
   建议将 Node 测试与固定版本清单校验作为显式步骤。
3. `Scripts/package.sh` 每次打包保留一份旧包 ZIP，`Scripts/install.sh` 另存已安装包。
   这是回退保护，也会逐步累积空间。建议后续提供显式查看和清理入口；不自动
   永久删除历史回退文件。
4. 本次已修正发布指南残留的 1.4.6 文件名、与现行实现不符的认证文件说明，
   并明确主要维护者与上游角色。第三方版权文本保留。

## 实际验证 / Validation performed

- `make test`：80 项 PASS，含账号切换、共享快照、超时预算、协议兼容与网络配置。
- `node --test Tests/codex_usage_badge_health.test.cjs`：7 项通过。
- `python3 Scripts/verify_badge_bundle.py`：31 个文件及固定 agent 哈希通过。
- `make public-release-check`：通过。
- `swift build --product CodexUsageBar`：构建通过；用现有演示入口生成中英文截图并检查。
- 已安装 1.4.9 只读健康检查：签名、共享额度、固定版本和 ChatGPT 页面注入均通过。
- 从 GitHub 下载当前 DMG 和校验文件：SHA-256 一致；只读挂载确认版本
  1.4.9 / Build 46、应用和小组件均含 arm64 + x86_64、签名校验通过。
- 未运行新的真实账号采集集成测试，未重新打包发布、重装应用或清理开发缓存。

The estimated 15.5% saving concerns uncompressed file sizes. A smaller DMG,
lower RSS or lower energy use remains unverified until implementation and a
matched before/after measurement. Existing public release assets are unchanged.

## 获批后的实施与实测 / Approved implementation results

2026-11-02：用户批准实施发布包瘦身并验证构建。已准备本地候选包
**1.4.10 / Build 47**，没有替换公开 1.4.9 附件或本机安装。

- PNG 留在源码和 README 中，从 Xcode 资源阶段移除；安装包仍使用 ICNS 图标。
- Badge 发布包改为 12 个运行/诊断/许可文件加 manifest；源码保留完整 31 文件。
  manifest 的运行清单和管理器安装清单同步缩小，旧开发资料不会再被递归安装。
  用户已安装的回退资料不会被清除。
- 发布清单按源文件哈希核验，拒绝缺失、篡改、意外混入的旧文件及覆盖已有暂存目录。
- CI 从 project.yml 读取版本；新增 Node 24 和 Badge/打包回归检查。

实测以下载的公开 1.4.9 DMG 和本地新 DMG **各自内部的双架构应用**比较：

| 项目 | 1.4.9 / Build 46 | 1.4.10 / Build 47 | 减少 |
|---|---:|---:|---:|
| 应用文件逻辑长度 | 8,495,361 bytes | 7,165,892 bytes | **15.65%** |
| 压缩 DMG | 4,588,711 bytes | 3,592,823 bytes | **21.7%** |

验证：80 项 Swift 检查、7 项 Badge 测试、5 项打包回归检查通过；新 DMG 的
SHA-256、版本、应用及 Widget 的 arm64/x86_64 架构、签名均通过。只读挂载
新 DMG 后确认 PNG/开发资料未进入应用，LICENSE/NOTICE/ICNS 仍在；包内
健康检查的资源哈希和安装器只读 preflight 通过。

本轮没有调用安装或修复，也未测量长期能耗/内存。新的后台管理器尚未替换
已安装版本，因此本轮结论覆盖构建、包内容及只读安装预检；不宣称已完成
新版本安装后的真实服务切换或页面注入验收。
