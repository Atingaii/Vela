# 功能状态与限制

**当前开发分支：基于 0.1.0-preview.2 的未发布验收重构。完整产品 No-Go。** 发布下载仍是 preview.2，以下区分当前源码与已发布包。本文描述当前实现与验证边界，不代表[完整需求矩阵](requirements.md)已经完成，也不是稳定版本承诺。

源码仓库：[Atingaii/Vela](https://github.com/Atingaii/Vela)；预览下载：[版本发布页](https://github.com/Atingaii/Vela/releases/tag/v0.1.0-preview.2)；官网：[Vela](https://vela-engineering.zzzsssaa.chatgpt.site)。官网当前使用托管子域名。

## 当前实现

| 模块 | 当前可用内容 | 预览边界 |
| --- | --- | --- |
| macOS 客户端 | AppKit + 系统 WKWebView，独立 `vela` helper；按任务分组的导航、独立工程记忆入口、全局搜索、审批 Inbox、菜单栏与设置入口 | 首发 Apple Silicon、macOS 13+。GUI SwiftPM 产品名为 `VelaDesktop`，安装包为 `Vela.app`；不承诺 Intel、Windows 或 Linux 兼容性 |
| 界面语言 | 开发版提供简体中文与 English，可从设置和 Vela 原生菜单选择；语言偏好本地持久化，固定界面文案原地切换 | 项目正文、路径、命令和 Agent 输出保留原文。此功能尚未包含在 preview.2 下载中 |
| Session | Claude Code、Codex JSONL 摄取，支持的消息/工具事件和来源；FSEvents、偏移游标、半行与轮转处理 | 初始每个 provider 最多选择 60 个近期文件，按需读取 256 KB 尾窗及 32 KB 文件头；转录最多保留 1,000 条消息且文本总量最多 1 MB。没有完整历史回填、完整旧会话分页或原生 Session Transfer |
| Cursor | JSON/JSONL 导出、部分已知 `composerData` SQLite 记录的只读导入 | 私有 schema 随版本变化；拆分 bubble 记录等未适配格式需要导出。支持导入不等于覆盖 Cursor 全部内部数据库 |
| 运行状态 | 支持明确终止事件；根据最近日志活动推断 Running/Idle/Needs Approval，保留推断来源 | 没有独立进程存活证明。导出记录与历史最后活动不能作为实时运行状态；未知保持 Unknown |
| Setup | 明确项目及已知全局配置扫描；指令、Rules、Skills、Hooks/MCP 配置清单；敏感字段脱敏 | 审计检查包括格式、重复内容与保守上下文大小，不是完整语义冲突、Skill 有效性或 MCP 漂移分析；不会自动修复用户配置 |
| Memory / Recall | 九类 Memory、七类作用域、Candidate → Active → Superseded → Archived 生命周期；五类过滤、精确来源消息导航与手动编辑 Markdown；Active-only Recall | 使用确定性文本匹配与作用域筛选，未实现语义检索或模型判断。Token 为保守估算；Recall 上限 4,000，来源不明不会自动补造 |
| Checkpoint | Goal、Completed、Pending、Tests、Next Actions 等用户记录，加上实际读取的 Git branch/commit/status；中立 Markdown 交接文件 | 用户填写的完成事项与测试描述不等于执行验证；导出不会启动 Agent，也不改写 provider 私有历史 |
| Guidelines | 项目/全局 Guideline 保存、版本记录，以及 Workflow Run 中冻结的关联快照 | 当前模式是 `snapshot_only_not_injected`：尚未将 Guideline 注入 Agent 提示词，不能据此声称它影响了结果 |
| Library | UTF-8 文本、HTML、可提取文字的 PDF、DOCX，以及显式 HTTP/HTTPS 文档 URL；保留来源 | 导入与提取有 2 MB 上限；PDF 不做 OCR，URL 不递归抓取。默认 private；用户资料目录中的 `private/`、`.private/` 强制作为私有资料，排除于 Agent 检索 |
| Search / Ask | 本地证据检索；Ask 返回匹配对象，标明未调用外部模型 | Ask 是检索入口，不是基于模型的综合问答；没有外部知识补全 |
| MCP | 默认只读；显式贡献模式可创建候选 Memory、Checkpoint、绑定实际会话的 Signal 和 Suggestion Draft | 请求必须明确指定已登记项目。不能通过 MCP 激活已有 Memory、Apply、执行 Workflow 或任意写项目；私有资料在服务端过滤 |
| Workflow | Markdown 定义和版本、真实只读工具、Dry Run、冻结审批、运行记录、健康统计和重放入口 | 当前工具集有限，未知外部工具明确拒绝。项目脚本、文件写入和 Agent 命令需要审批；自然语言 Draft 是基于关键词与项目现有脚本的确定性生成，不是通用规划器 |
| Improve | 从真实会话提取确定性纠错信号，去重聚类、生成有证据的建议；Diff 预览、hash 校验、Apply/Undo 与恢复记录 | 不是模型驱动的多阶段分析/规划管线。建议需要审阅；不会因为出现信号就宣称改进有效，也不保证覆盖需求矩阵的全部信号类型 |
| 后台证据分析 | 默认关闭；开启后按持久化会话变更计数触发确定性分析，成功才记录处理水位，失败可重试 | 与 RPC helper 同生命周期；没有 OS 空闲检测；当前分析窗口最多 500 条会话，不保证完整历史回填；只生成建议，不自动 Apply |
| 审批与写入 | 冻结动作参数、持久化 Inbox、跨进程原子状态抢占；受支持文件写入有路径与 hash 校验，Apply/Undo 记录前后状态 | 原子抢占避免同一待审批动作被两个进程同时启动，不代表任意外部命令都具备端到端 exactly-once 语义。崩溃后的外部副作用仍需结合记录核对 |
| Scheduler | 已实现的 cron、启动、会话完成及 Git 事件使用持久化标识去重 | 只在应用或 RPC helper 运行时检查；没有独立系统 daemon，休眠/关机错过的时机不补跑。`usage_reset` 不可用，不制造重置事件 |
| Usage | 从已索引日志汇总 provider/project/session token，处理支持的累计/重复事件；界面区分缺失、已观测子集和真实零值 | 不是账户订阅额度。价格、配额、重置时间及分析精确成本不可用；历史未完整索引。按日统计归属会话开始日期，不是逐事件消耗的完整重建 |
| Lab | 同提交命令对照及 Codex Agent 对照；冻结同一任务/模型请求、候选上下文、验证/输出清单，审批后运行；独立干净目录验证 | 首次真实六次任务均成功且测试观察同分，判定 Inconclusive，晋升拒绝。计分缺陷与更正保留；没有未来纠错率改善证据 |
| Reuse | Memory-only 受测候选显式晋升；项目 SessionStart Hook 提案、SafeApply/Undo、已安装无变更预览、已应用事务 Diff、Active Memory 收据与后续来源关联 | 已应用预览展示提交时快照，Undo 仍校验当前文件 hash。需在 Codex `/hooks` 信任确切定义；没有自动改 provider 信任。收据不证明 Agent 采纳；完整真实下一会话链尚未通过 |
| 通知 | 审批、完成和错误分类开关；首次历史加载静默、重复事件去重、三个原创短提示音 | 默认关闭；使用 macOS 通知权限与声音策略。推断事件保留标签；应用/helper 停止期间不承诺通知投递 |
| 官方网站 | 静态 HTML/CSS/JavaScript 首页、场景目录、四个独立场景指南、附来源的产品对比、文档、发行和隐私页面；公开部署 | 网站展示不构成实现或测试证据；下载与签名状态以具体发布记录为准 |

## 本地验证状态

本轮语言切换的最终版本通过 **24/24 组真实 helper 界面检查**，包括旧有 18 组和新增 6 组双语验收；词典、草稿、原文、焦点、选区及存量会话辅助文字切换均已验证。最终开发包为 **1,453,375 bytes**，包含新的翻译资源，仍未公证且未作为新 release 发布。[本轮记录](verification.md#website-expansion-and-desktop-localization--13-september-2026)区分官网、核心、界面、原生与打包证据。

当前验收分支已有 **99/99 个真实核心测试方法通过** portable runner，其中包含四项新增语言偏好测试，覆盖 SQLite、文件系统、增量日志、FSEvents、项目与私有数据边界、文档提取、Git、审批竞争、Workflow、Apply/Undo、配对命令执行及通知分类、静默基线、去重、偏好校验。新增两项回归验证已安装 Hook 的只读预览及已应用事务预览，空 Apply 与冲突 Undo 仍被拒绝。Portable runner 编译真实核心和原同步测试方法，只提供小型断言兼容层，**不是 XCTest**。

本机为 Command Line Tools 环境，`swift build` 可用；缺少 XCTest 模块，因此不能将本机验证写成“`swift test` 已通过”。完整 Xcode 环境使用 `swift test`。此前验收阶段提交 `91d34e2` 的 [macOS CI](https://github.com/Atingaii/Vela/actions/runs/34709059008)已实际通过 **95 项 XCTest、18 组 renderer 检查**、RPC/MCP、输入边界、重启恢复与打包；[公开记录](evidence/2026-09-13-ci-final.json)保留精确提交和 job。较早提交 `8929967` 的 93 项结果只作为历史检查点。

JSONL RPC/MCP 黑盒检查已通过，使用编译后的 CLI 和一次性数据目录，验证持久化设置、私有检索、候选贡献与 Dry Run 等边界。相关复验入口：

```sh
swift build
python3 scripts/test-portable.py
python3 scripts/test-rpc.py
python3 scripts/check-repository.py
```

新增测试覆盖 Improve 明确纠错/重复程序及近似负例、Library 身份和符号链接、Agent 独立 verifier 防篡改、旧结果重算与拒绝晋升、跨 provider Recall 关联、缺失用量和整数溢出。六次真实 Codex 比较单独记录在[公开证据](evidence/2026-09-13-agent-lab.json)，没有用受控协议 fixture 代替模型实验。

新增[六组 renderer→真实 CLI 验收](verification.md#six-renderer-to-cli-acceptance-checks)在同一次全新隔离 fixture 中 **6/6 通过**：Memory 生命周期、精确来源、跨项目同 provider ID 导航、源 Suggestion→Lab 冻结待审批、Reuse 预览/Apply/重复预览/Undo、用量缺失→真实零。实际修复了空操作预览报错与已应用记录无法重开预览两项缺陷；56 次 Core RPC 无错误，UI 文件前后哈希一致。最后一行 Reuse 文案调整后已全量再验，最终本地记录为 `output/playwright/acceptance-flow-final/results.json`，UI `app.js` hash 为 `01104e7f…ee3af0b`；之前失败与中间通过记录保留。该套件没有执行真实 Agent、Hook 或 OS 通知，不代表整条 Golden Scenario 完成；原生、开发包和 CI 证据见下方记录。

最终原生开发 wrapper 已通过 LaunchServices 启动，在 1250 × 800 和 900 × 623 窗口检查分栏、抽屉及 Escape。原生 Reuse 的预览不写、Apply 精确写入、重开事务 Diff、Undo 还原均经独立 CLI 确认。[UI 证据](evidence/2026-09-13-ui.json)和[开发包静态审查](evidence/2026-09-13-package.json)分别记录验证范围；1,370,679 bytes 的本地 ZIP 未作为新 release 发布。

这些结果验证的是相应 fixture 和测试边界，不代表任意 provider 版本、任意项目或全部需求已经覆盖。性能目标与实际测量分开记录；小规模本地样本不能外推为大历史、并发任务或长期稳定性保证。

## 发布与数据边界

- 本预览开发包使用 **ad-hoc 签名**；没有 Developer ID 签名，**尚未 Apple notarized**。未实现经过完整验证的签名自动更新通道。
- `dev`、`canary`、`stable` 通道用于隔离应用身份和数据目录；选择 `stable` 字符串不会自动获得稳定性、签名或公证。
- 索引与记录存于 SQLite WAL；长期资产位于所选 Vela store 的 `assets/memory`、`assets/workflow`、`assets/guideline`、`assets/library`、`assets/checkpoint`，采用可读 Markdown。
- 本地优先不意味着完全无网络：明确导入 URL 会请求该文档；用户批准执行的远程 Coding Agent 可能向其 provider 发送指定上下文。Vela 不自动将会话历史提交给模型。
- 预览格式尚未声明长期兼容；重要资产需自行备份。测试、内部材料和一次性缓存不属于安装包交付内容。

完整历史回填、纵向 Agent 效果验证、Guideline 实际注入、原生 Session Transfer、真实配额接入、成熟后台调度、外部 SaaS 工具、加密同步与团队能力仍是后续工作。请使用[需求矩阵](requirements.md)讨论范围，避免将本预览版视为 P0–P2 或全部路线图已经完成。

## Notification acceptance boundary

The preview implements optional native notification policy and routing, with three working Settings sound previews. On the build host, macOS refused notification authorization for the ad-hoc application; OS banner delivery and click-through remain unverified. Notification preferences stay off when authorization fails. See [verification](verification.md#explicit-environment-limitation).
