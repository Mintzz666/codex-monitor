# Authors and attribution / 作者与来源

**Mintzz is the primary author and maintainer of Codex Monitor’s current
integration and customizations.** The original authors retain credit for
their upstream work.

**Mintzz 是当前 Codex Monitor 整合与定制版本的主要作者和维护者。**
以下同时保留上游项目的作者、来源和版权归属。

| Role / 角色 | Author / 作者 | Contribution / 贡献 |
|---|---|---|
| Primary author & maintainer / 主要作者与维护者 | [Mintzz](https://github.com/Mintzz666) | Product integration, quota sharing, widgets, appearance customizations and maintenance / 产品整合、额度共享、小组件、外观定制与维护 |
| Original Monitor foundation / Monitor 原始基础 | [CMMUU](https://github.com/CMMUU/codex-usage-bar) | Original codex-usage-bar project / 原始菜单栏用量项目 |
| Appearance foundation / 外观增强基础 | [jaykinhoo9 and contributors](https://github.com/jaykinhoo9/codex-usage-badge) | Original Codex Usage Badge / 原始 Badge 项目 |

## Codex Monitor

Derived from [CMMUU/codex-usage-bar](https://github.com/CMMUU/codex-usage-bar).
The original copyright notice and MIT terms are preserved in [LICENSE](LICENSE),
alongside a copyright notice for Mintzz’s modifications. Changes include the
Codex-focused product surface, dynamic quota windows, weekly-remaining menu bar
semantics, macOS widgets, token activity, shared quota delivery and integrated
appearance management.

基于 CMMUU 的 codex-usage-bar 开发。根目录 LICENSE 保留原始版权声明和
MIT 条款，并补充 Mintzz 修改部分的版权声明；上游代码的作者归属仍予保留。

## Codex Usage Badge

The complete source snapshot from Mintzz’s fork is preserved in
[ThirdParty/codex-usage-badge](ThirdParty/codex-usage-badge), with its pinned
revision documented in [UPSTREAM.md](ThirdParty/codex-usage-badge/UPSTREAM.md).
The fork history remains available at
[Mintzz666/codex-usage-badge](https://github.com/Mintzz666/codex-usage-badge).

The installed Monitor package bundles a separately pinned, customized macOS
runtime based on upstream v0.9.1, under the MIT License. Its original license
is included at [Resources/CodexUsageBadge/LICENSE](Resources/CodexUsageBadge/LICENSE).
Mintzz’s changes add folder-color inheritance, Recent thread matching, five
Token shades, Work layout fixes and reset-time labels. Monitor is the single
installation and management entry; the included helper runs as a separate
local process and reads Monitor’s quota snapshot.

仓库保留 Mintzz fork 的完整源码快照；安装包使用单独固定哈希的 macOS
定制运行版本。Mintzz 的定制包含文件夹颜色继承、Recent 会话匹配、五级
Token 色阶、Work 排版和重置时间显示。安装和管理入口统一在 Monitor；
后台助手仍作为本地进程运行，读取 Monitor 的共享额度快照。

## Names and affiliation / 名称与隶属关系

Codex, ChatGPT, OpenAI and Apple are trademarks of their respective owners.
This independent community project is not affiliated with or endorsed by
OpenAI, Apple or the upstream maintainers.

相关名称归各自权利人所有。本项目与 OpenAI、Apple 或上游维护者不存在
隶属或背书关系。
