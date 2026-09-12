# 功能状态与限制

**版本：0.1.0-preview.2 · 开发者预览版。** 本文描述当前实现与验证边界，不代表[完整需求矩阵](requirements.md)已经完成，也不是稳定版本承诺。

源码仓库：[Atingaii/Vela](https://github.com/Atingaii/Vela)；预览下载：[版本发布页](https://github.com/Atingaii/Vela/releases/tag/v0.1.0-preview.2)；官网：[Vela](https://vela-engineering.zzzsssaa.chatgpt.site)。官网当前使用托管子域名。

## 当前实现

| 模块 | 当前可用内容 | 预览边界 |
| --- | --- | --- |
| macOS 客户端 | AppKit + 系统 WKWebView，独立 `vela` helper；按任务分组的导航、独立工程记忆入口、全局搜索、审批 Inbox、菜单栏与设置入口 | 首发 Apple Silicon、macOS 13+。GUI SwiftPM 产品名为 `VelaDesktop`，安装包为 `Vela.app`；不承诺 Intel、Windows 或 Linux 兼容性 |
| Session | Claude Code、Codex JSONL 摄取，支持的消息/工具事件和来源；FSEvents、偏移游标、半行与轮转处理 | 初始每个 provider 最多选择 60 个近期文件，按需读取 256 KB 尾窗及 32 KB 文件头；转录最多保留 1,000 条消息且文本总量最多 1 MB。没有完整历史回填、完整旧会话分页或原生 Session Transfer |
| Cursor | JSON/JSONL 导出、部分已知 `composerData` SQLite 记录的只读导入 | 私有 schema 随版本变化；拆分 bubble 记录等未适配格式需要导出。支持导入不等于覆盖 Cursor 全部内部数据库 |
| 运行状态 | 支持明确终止事件；根据最近日志活动推断 Running/Idle/Needs Approval，保留推断来源 | 没有独立进程存活证明。导出记录与历史最后活动不能作为实时运行状态；未知保持 Unknown |
| Setup | 明确项目及已知全局配置扫描；指令、Rules、Skills、Hooks/MCP 配置清单；敏感字段脱敏 | 审计检查包括格式、重复内容与保守上下文大小，不是完整语义冲突、Skill 有效性或 MCP 漂移分析；不会自动修复用户配置 |
| Memory / Recall | 九类 Memory、七类作用域、Candidate → Active → Superseded → Archived 生命周期；来源字段与手动编辑 Markdown；Active-only Recall | 使用确定性文本匹配与作用域筛选，未实现语义检索或模型判断。Token 为保守估算；Recall 上限 4,000，来源不明不会自动补造 |
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
| Usage | 从已索引日志汇总 provider/project/session token，处理支持的累计/重复事件 | 不是账户订阅额度。价格、配额、重置时间及分析精确成本不可用；历史未完整索引。按日统计归属会话开始日期，不是逐事件消耗的完整重建 |
| Lab | baseline/candidate 在同一 Git 提交的独立 worktree 中执行配对命令，记录退出码、输出、耗时和变更，执行前审批 | 当前是 command-paired comparison，不是完整 Agent Benchmark。尚无可靠的自动任务成功、规则遵循、模型质量或 token 收益结论 |
| 通知 | 审批、完成和错误分类开关；首次历史加载静默、重复事件去重、三个原创短提示音 | 默认关闭；使用 macOS 通知权限与声音策略。推断事件保留标签；应用/helper 停止期间不承诺通知投递 |
| 官方网站 | 静态 HTML/CSS/JavaScript 产品介绍、开发预览说明和下载入口 | 网站展示不构成实现或测试证据；下载与签名状态以具体发布记录为准 |

## 本地验证状态

本轮已有 **54/54 个真实核心测试方法通过** portable runner，覆盖 SQLite、文件系统、增量日志、FSEvents、项目与私有数据边界、文档提取、Git、审批竞争、Workflow、Apply/Undo、配对命令执行及通知分类、静默基线、去重、偏好校验。Portable runner 编译真实核心和原同步测试方法，只提供小型断言兼容层，**不是 XCTest**。

本机为 Command Line Tools 环境，`swift build` 可用；缺少 XCTest 模块，因此不能将本机验证写成“`swift test` 已通过”。完整 Xcode 环境使用 `swift test`，仓库 macOS CI 也配置为该路径。

JSONL RPC/MCP 黑盒检查已通过，使用编译后的 CLI 和一次性数据目录，验证持久化设置、私有检索、候选贡献与 Dry Run 等边界。相关复验入口：

```sh
swift build
python3 scripts/test-portable.py
python3 scripts/test-rpc.py
python3 scripts/check-repository.py
```

这些结果验证的是相应 fixture 和测试边界，不代表任意 provider 版本、任意项目或全部需求已经覆盖。性能目标与实际测量分开记录；小规模本地样本不能外推为大历史、并发任务或长期稳定性保证。

## 发布与数据边界

- 本预览开发包使用 **ad-hoc 签名**；没有 Developer ID 签名，**尚未 Apple notarized**。未实现经过完整验证的签名自动更新通道。
- `dev`、`canary`、`stable` 通道用于隔离应用身份和数据目录；选择 `stable` 字符串不会自动获得稳定性、签名或公证。
- 索引与记录存于 SQLite WAL；长期资产位于所选 Vela store 的 `assets/memory`、`assets/workflow`、`assets/guideline`、`assets/library`、`assets/checkpoint`，采用可读 Markdown。
- 本地优先不意味着完全无网络：明确导入 URL 会请求该文档；用户批准执行的远程 Coding Agent 可能向其 provider 发送指定上下文。Vela 不自动将会话历史提交给模型。
- 预览格式尚未声明长期兼容；重要资产需自行备份。测试、内部材料和一次性缓存不属于安装包交付内容。

完整历史回填、完整 Agent Eval、Guideline 实际注入、原生 Session Transfer、真实配额接入、成熟后台调度、外部 SaaS 工具、加密同步与团队能力仍是后续工作。请使用[需求矩阵](requirements.md)讨论范围，避免将本预览版视为 P0–P2 或全部路线图已经完成。

## Notification acceptance boundary

The preview implements optional native notification policy and routing, with three working Settings sound previews. On the build host, macOS refused notification authorization for the ad-hoc application; OS banner delivery and click-through remain unverified. Notification preferences stay off when authorization fails. See [verification](verification.md#explicit-environment-limitation).
