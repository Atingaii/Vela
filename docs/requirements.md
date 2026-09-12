# Vela 功能需求与验收矩阵

本文将用户的 Vela 定义和三份用户提供的 Blume 产品工程报告转化为可实施、可验收的需求。它不代表实现状态，不是对 Blume 的独立核验，也不批准某种技术栈。每项交付须在实现清单中补上代码入口、验证方式、验证结果与未完成边界；界面占位、模拟数据和可点击按钮不构成完成。

## 1. 来源、范围与事实边界

| 标识 | 来源 | 用途 |
| --- | --- | --- |
| V | 用户附件 `pasted-text.txt`，标题《Vela / The engineering layer for coding agents》，第 1–73 节 | 产品需求的主要依据 |
| B1 | 用户提供的 `Blume-Sidecar-完整逆向报告.md` | 参考产品功能全景、隐私与打包风险 |
| B2 | 用户提供的 `Blume-Sidecar-模块详细说明.md` | 摄取、状态、审计、Improve、安全与运维边界 |
| B3 | 用户提供的 `Blume-Sidecar-技术架构与细节处理.md` | 故障隔离、幂等、背压、证据、成本控制手法 |
| U | 本轮用户直接要求 | 可在 Mac 使用的软件、官方网站；所有前端 UI 与样式由 Antigravity CLI 3.8 Flash (High) 实现，官网参考 `https://px0.ai/` 风格 |

资料原路径：

- `用户提供的 Vela 产品草案（未随仓库发布）`
- `用户提供的分析报告：Blume-Sidecar-完整逆向报告.md`
- `用户提供的分析报告：Blume-Sidecar-模块详细说明.md`
- `用户提供的分析报告：Blume-Sidecar-技术架构与细节处理.md`

Blume 报告中的版本、实现细节、内部接口和性能取舍只属于报告陈述。Vela 应以独立实现和自己的测试为准，不复制其品牌、界面、私有提示词或私有源码，不依赖其私有服务。报告中附带的私有代码位置不作为读取目标。

用户附件第 49–58 节包含暂定实现设想。技术栈和长期接口由工程 ADR 单独比较、记录；本文保留其用户结果、安全属性与可观测指标，不把参考产品的包结构、worker 数量、表数量直接转成需求。

## 2. 核心目标和交付定义

Vela 是 macOS 上本地优先的 Coding Agent 工程层，统一观察 Claude Code、Codex 和 Cursor，把工程事实转成有来源、可恢复的 Memory，把重复纠正转成可审阅的建议，把重复过程转成可执行 Workflow，并用真实运行验证改善。

主闭环：`Session → Memory → Improve / Workflow → Lab → Verified Context → Future Session`。

六个一级模块为 Agents、Workflows、Setup、Usage、Improve、Lab。全局提供搜索 / Ask Vela、Inbox 和 Settings。Memory 位于 Setup 内，与 Rules、Skills、Hooks、MCP、Guidelines、Library 并列。

最终交付至少包含可启动的 macOS 应用、可重建的源工程、可部署并可浏览的官方网站、安装与使用说明、功能覆盖清单、真实验证证据。对签名、公证、更新发布源、线上域名和托管账号等外部条件逐项记录：本地构建成功不等于公开发行完成，静态站点构建成功不等于网站已上线。

V 的 P0–P2 构成核心产品实施主线。P3 是高级功能，P4 明确是以后才考虑的分布式能力；必须单独标记为路线图，不能用后续范围掩盖 P0–P2 的缺项，也不能宣称 P3/P4 已完成。

## 3. 功能验收矩阵

“阶段”表示最早可交付阶段，不表示允许只做界面。以下均为需求，状态默认“待实现 / 待验证”。

### 3.1 Foundation 与 Observe

| ID | 阶段 | 能力 | 可验收结果与边界 | 来源 |
| --- | --- | --- | --- | --- |
| OBS-01 | P0 | Harness 检测 | 分别检测安装、可读取会话、可运行分析能力；目录由 Vela 创建不应被误当成 provider 已安装；缺少 CLI 或授权有真实原因 | V §9；B2 B2 |
| OBS-02 | P0/P1 | 三家会话适配 | P0 Claude / Codex，P1 Cursor；用真实格式样本验证发现和解析，记录格式版本、来源路径和不支持字段；无法解析时明确报告，不伪装为空历史 | V §7–9,65–66 |
| OBS-03 | P0 | 统一会话 | Messages、Tool Calls / Results、Todos、Subagents、Approvals、Model、Usage、Git Context、Project 有统一结构；来源定位可回到原始事件；缺字段保留 unknown | V §7；B2 B5 |
| OBS-04 | P0 | Agent 状态 | Running、Idle、Needs Approval、Completed、Error、Stopped 可复现转换；明确事件与超时推断分开；历史最后一句话不能直接证明进程仍在运行 | V §5；B2 B8 |
| OBS-05 | P0 | Agent 卡片内容 | 显示 harness、project、cwd、branch、worktree、model、起始及最近活动时间、Todo、Approval、Subagents；未知数值不填假默认值 | V §5 |
| OBS-06 | P0 | 状态归并正确性 | 重复与迟到事件幂等；已终止轮不被旧事件恢复为运行中；父任务与子任务不重复计数；无任务时不制造 0/N 进度 | B3 T1–T5；B2 O7 |
| OBS-07 | P0 | 增量摄取 | 初次发现后仅处理变更文件；以文件身份、偏移量和解析版本保存游标；处理半行 JSONL、截断、轮转、重命名、删除、重启和损坏行；偏移仅在已提交解析后推进 | V §8；B2 B3–B5 |
| OBS-08 | P0 | 大会话与历史回填 | 流式解析、尾部窗口、分页时间线；新活动优先于历史；回填可取消可续；超长行、输出、单批文件数均有上限和截断说明 | V §8,62；B3 T6,T8 |
| OBS-09 | P0 | 项目身份 | 项目、仓库、branch、worktree 分开建模；同仓库子目录会话归属一致；保留用户排除项目/路径的控制，排除后不再摄取、分析或召回 | V §5,14；B2 B6,B10 |
| OBS-10 | P0 | 自我运行隔离 | Vela 的 Improve、Workflow、Lab 会话标记为内部运行，含 realpath 后仍隔离，不进入重复摩擦分析形成反馈循环 | B2 B7,E13 |
| OBS-11 | P0 | 时间线与历史 | 统一浏览 user → assistant → tool → result；过滤 project / harness，分页打开历史、查看证据；解析错误不导致其他会话不可用 | V §7,40 |
| OBS-12 | P0 | 菜单栏与通知 | 窗口关闭后菜单栏仍可使用，显示运行和待注意数量及可用配额；仅 Needs Approval / Completed / Error 默认通知；跳转到对应真实对象 | V §6 |
| OBS-13 | P0 | 常驻设置与故障说明 | 管理扫描目录、项目排除、通知、启动行为、后台任务；worker 故障可恢复且用户获知陈旧状态；不在主/UI线程偷偷回退重任务 | V §50–51；B3 D3 |

### 3.2 Setup、Memory、Recall、MCP、Search 与 Usage

| ID | 阶段 | 能力 | 可验收结果与边界 | 来源 |
| --- | --- | --- | --- | --- |
| CTX-01 | P0 | Setup 工件扫描 | 统一发现 AGENTS.md、CLAUDE.md、Cursor Rules、Skills、Hooks、MCP、Guidelines、Memory、Reference Docs；支持 global/project scope，保留 provider 与实际加载差异 | V §10 |
| CTX-02 | P0 | Artifact 身份 | type、scope、provider、path、version、hash、relationships、diagnostics、context cost 可读取；扫描顺序不同不改变同一内容的状态 hash | V §10；B2 D6 |
| CTX-03 | P1 | Setup Audit | 覆盖冲突/重复规则、过时命令、包管理器不符、失效 Skill/Hook、MCP drift、跨 harness 差异、过时 Memory、常驻上下文膨胀；每项有证据、适用范围、正例、负例与 near-miss；干净配置输出零发现 | V §11；B2 D1–D10 |
| CTX-04 | P1 | 审计抑制与治理 | 已处理且相同 scope / 工件版本的发现不重复打扰；内容变更后可重新审计；无来源 hash 不安全抑制；只检查实际使用的 harness | B2 D4–D8 |
| CTX-05 | P0/P2 | Context Cost | 展示常驻与按需成本，说明 tokenizer 或估算方式；规则修改展示增量；不能把字数估算伪称精确 token；P2 预算联动 Recall / Planner | V §12,68 |
| MEM-01 | P0 | Memory CRUD 与所有权 | 用户拥有 Markdown 资产；支持 Decision、Constraint、Preference、Failure、Fact、Workflow Knowledge、Observation、Hypothesis、Checkpoint；普通会话摘要不自动等同长期事实 | V §13,54 |
| MEM-02 | P0 | Scope 隔离 | Global、Project、Repository、Branch、Worktree、Task、Session 可定位；项目 A 默认不能读取 B 的非全局 Memory；未知项目身份 fail-closed | V §14 |
| MEM-03 | P0 | 状态与版本 | Candidate → Active → Superseded → Archived；supersedes 关系可追溯；默认 Recall 只返回 Active；更新不得丢失旧证据 | V §15 |
| MEM-04 | P0 | 来源证明 | source session/message/file/commit、createdAt、lastConfirmed 可空但须明确未知；支持 View Evidence；不自动编造不存在的 commit / message；人工创建标为用户来源 | V §16 |
| MEM-05 | P1 | Recall | 输入 project/task/branch/files/symbols/budget；综合相关性、scope、authority、freshness、importance、任务匹配和冲突；返回原因和证据；结果确定、去重、只取获准范围 | V §17 |
| MEM-06 | P1/P2 | Recall Budget | 500/1k/2k/4k 及合法自定义预算；包含上下文包装开销；优先少而准；截断不得删除安全/来源标记或把过期事实当 Active | V §17,67 |
| MEM-07 | P0 | Checkpoint | 保存 Goal、Completed、Pending、Changed Files、Decisions、Known Failures、Tests、Next Actions、Git State；重开仍可恢复；区分已验证与用户/模型陈述 | V §18 |
| MEM-08 | P0 | 中立交接 | 生成 provider-neutral 交接资产，并能在已安装的 Claude / Codex 继续或给出可执行恢复命令；不得宣称原生 Session 迁移已完成；不改写 provider 私有历史 | V §18 |
| MCP-01 | P0 | MCP Read | 外部 agent 可 Search、Recall、Read Memory/Setup/Eval/Workflow、取 Checkpoint；工具描述与实际权限一致；stdio/协议初始化、错误、大小上限可测试 | V §19；B2 J |
| MCP-02 | P1 | MCP Contribute | 仅 Create Candidate Memory、Record Signal、Save Checkpoint、Create Suggestion Draft；输入校验并标记来源；不能调用 Apply、修改项目、删除长期 Memory 或执行 destructive workflow | V §19 |
| MCP-03 | P1 | MCP 配置接入 | 输出可审阅的各 harness 接入配置；安装修改经过同一安全文件服务、保留原内容并可撤销；权限持久化，不依赖远程 feature flag | V §19；B2 J6 |
| FIND-01 | P0 | 人类 Search | ⌘K 搜索 Projects、Sessions、Messages、Memory、Rules、Skills、Guidelines、Workflows、Suggestions、Eval、Library；支持精确/前缀/子串/结构过滤/人工权重，结果可导航 | V §40 |
| FIND-02 | P2 | Ask Vela | 通过获准搜索结果作答，附对象来源；未知时明确无依据；不让回答过程绕过 private / scope 隔离 | V §40,67 |
| USE-01 | P0/P1 | Provider 配额 | Claude/Codex P0、Cursor P1；真实配额窗口与 reset 统一显示；区分账户配额与会话 token 统计；未登录、unsupported、rate-limited、stale 明示，不填假的百分比 | V §20；B2 F |
| USE-02 | P0 | 用量聚合 | provider/model/project/session/day 维度归并，避免累计事件被重复累加；unknown 不等于 0；按本地日期边界聚合并保留时区 | V §20 |
| USE-03 | P1 | 分析成本 | Improve / Lab 前后 Usage Snapshot 持久化，失败也记录；标记缺快照、跨 reset、并发用户活动的归因限制；差值不能无条件声称为单次精确成本 | V §20；B2 E2.3 |
| USE-04 | P0 | Usage 接入可靠性 | 超时、取消、缓存、单飞刷新、指数退避、两种 Retry-After；不在 UI渲染中直接请求；凭证不得打印或放进数据库 | B2 F3–F6 |

### 3.3 Improve、Evidence、Workflow 与 Inbox

| ID | 阶段 | 能力 | 可验收结果与边界 | 来源 |
| --- | --- | --- | --- | --- |
| IMP-01 | P1 | 分阶段 Improve | Extraction → Signal → Candidate Retrieval → Clustering → Promotion → Planning → Suggestion；每阶段持久化状态并可取消；基于真实会话，模型响应严格校验 | V §21 |
| IMP-02 | P1 | Signal 证据 | Correction、Steering、Frustration、Repeated Workflow、Verification Failure、Setup Mismatch、Memory Conflict；证据绑定真实消息/文件版本；查不到证据不能进入可靠晋升 | V §22；B2 E3.4 |
| IMP-03 | P1/P2 | 行为旁证 | 支持明确下一轮否定、同文件重做、Done 后测试失败、立即 Rollback、相同指令再现、Apply 后立即 Undo；与模型 pain/confidence 分列 | V §22 |
| IMP-04 | P1 | 幂等与聚类 | 同 transcript / extractor 版本重跑不重复增加证据；精确键代码归并，语义候选有限额；簇计数从去重成员重建而非盲目累加 | V §21；B2 E2,E5；B3 D16 |
| IMP-05 | P1 | Promotion | 代码按 signal 数、不同 session/day、pain、confidence、行为证据决定；阈值可见且版本化；单次情绪不能自动固化为 Rule；planner 可拒绝晋升簇 | V §23 |
| IMP-06 | P1 | Planner | 区分 knowledge / procedure；procedure 生成 Workflow；按 Hook → Workflow → Reference → Guideline → Skill → Rule 选择较窄载体，说明上下文成本与理由 | V §12,24 |
| IMP-07 | P1 | Suggestion 生命周期 | 展示证据次数、不同会话、操作 diff、影响路径、成本；Test / Preview / Apply / Snooze / Dismiss / Undo 有实际语义；修改建议产生新版本 | V §25–26 |
| IMP-08 | P1 | Safe Apply | 重新读文件，校验所有 base hash 和目标路径，先 staging 再 fsync/rename；多操作全有或全无；任何 base 缺失/变化均无覆盖并转 needs_review | V §26；B2 E8 |
| IMP-09 | P1 | Safe Undo | 记录 before/after；Undo 校验当前仍为刚应用的 after hash，避免覆盖后续人工修改；中断后可恢复事务或明确失败，不能宣称已恢复但丢数据 | V §26；B3 D18–D20 |
| EVD-01 | P1 | Evidence Graph | Message → Memory → Signal → Cluster → Suggestion → Rule/Workflow → Run → Eval → Outcome 都有稳定 ID / 边；Why 可追溯到原始来源，缺环节标记未知 | V §34 |
| WF-01 | P1 | Markdown Workflow | 含 id/version、scope、trigger、tools、guidelines、approval、步骤的可读资产；编辑、保存、校验、版本回看、导入导出后语义一致 | V §28–30 |
| WF-02 | P1 | Guideline 区分 | Memory 是事实，Guideline 是偏好做法，Rule 是约束，Workflow 是顺序；可单独管理且在 Run 中冻结所用版本 | V §29 |
| WF-03 | P1 | Builder | 自然语言/结构输入 → 理解意图 → 补全输入 → 工具选择 → 权限分析 → 生成 → 预览 → 保存；保存未获批准的草案不触发执行 | V §30 |
| WF-04 | P1 | 执行引擎 | 真实工具调用、顺序、条件/失败停止、取消、超时、输出限额；不能把任意 shell 描述标为 READ；运行执行者与权限、workdir 固定 | V §27–33 |
| WF-05 | P1 | Dry Run | READ 的许可操作真实运行，WRITE/DESTRUCTIVE 创建 stub 并列明 would-execute；测试命令可能写文件/运行脚本，不能只按名称当无副作用 READ | V §31 |
| WF-06 | P1 | Approval Inbox | Push、Release、Deploy、Send Message、Create Issue、Delete 及写操作需策略审批；展示目标、payload、风险；Approve/Edit/Reject 持久化 | V §32 |
| WF-07 | P1 | Frozen Action | 审批绑定不可变 action ID、内容 hash、工具、目标和参数；批准后执行同一 payload，不能再让模型重写；编辑产生新快照；一次批准不重复发送 | V §32 |
| WF-08 | P1 | Run Ledger | 冻结 workflow、inputs、memory、guidelines、tools、agent/model、approval、output、tokens、runtime、result；重启后能说明每步发生了什么 | V §33 |
| WF-09 | P2 | 重复工作发现 | 从多次真实 session/run 中形成证据，生成 draft workflow；不把只出现一次的任意命令序列自动执行 | V §27,67 |
| WF-10 | P2 | Health 与改进 | 真实统计 success/failure/timeout/tokens/runtime/unused tool/unused guideline/empty input/approval reject/edit；无样本时无百分比；“影响输出”若不可观测则不作确定结论 | V §35 |
| WF-11 | P2 | Replay | 用过去真实 Run 的冻结 inputs 比较指定 workflow 版本；记录工具/外界状态差异；WRITE/DESTRUCTIVE 仍遵守 dry-run/审批，历史批准不得复用 | V §36 |
| WF-12 | P2 | Scheduler | Manual、Cron、Agent Finished、Session Completed、App Start、Usage Reset、Git Event；持久化游标、触发去重、错过执行策略、并发限制；重启/休眠恢复不重复执行外部动作 | V §37 |

### 3.4 Library 与 Agent Lab

| ID | 阶段 | 能力 | 可验收结果与边界 | 来源 |
| --- | --- | --- | --- | --- |
| LIB-01 | P2 | 工程资料库 | Markdown、PDF、DOCX、HTML、URL、ADR、RFC、Architecture、Postmortem、API Docs 可导入、提取、搜索，保留来源/版本/提取状态；URL 内容视不可信资料 | V §38 |
| LIB-02 | P2 | Private Library | `private/` 资料仅 Human Search；Agent Recall、Workflow、外部模型、MCP 不可取；在 retrieval engine 强制执行，不能靠 UI 隐藏或 prompt 要求 | V §39 |
| LAB-01 | P1 | 三类对照 | Context v1/v2、Memory OFF/ON、Workflow v6/v7 三类任务可创建；真实执行结果可追溯；尚未运行时不显示成功分数 | V §41–44 |
| LAB-02 | P1 | 隔离与配对 | baseline/candidate 使用独立 git worktree；相同 commit/task/harness/model/reasoning/timeout/budget，差异变量明确；不覆盖原仓库未提交内容 | V §45 |
| LAB-03 | P1 | 真实执行 | 通过已安装且获准的 harness 运行，捕获退出码、stdout/stderr、测试、diff、模型与调用用量；不可用时返回 unavailable，不能用模板生成假结果 | V §45–47 |
| LAB-04 | P1/P2 | Eval 来源 | 优先历史任务、真实 correction、git commit、现有 tests、workflow history；synthetic 单列；固定输入版本，避免对照过程中任务变更 | V §46 |
| LAB-05 | P1 | 多维指标 | 分别列 Task Success、Tests、Rule Compliance、Corrections、Tokens、Runtime、Tool Calls、Retries、Unrelated Changes；主观判断与机械测量分开 | V §47 |
| LAB-06 | P2 | 重复运行统计 | 展示样本数、pass rate、pass@k、variance；方法和 k 可见；不能凭单次运行宣称整体成功率提升 | V §47 |
| LAB-07 | P2 | Regression | Rule/Skill/Memory/Workflow/Model/Harness 变更可触发回归；来源、对比、Replay/Rollback 可导航；相关变化只列 possible cause，不自动宣称因果 | V §48 |
| LAB-08 | P1/P2 | Promote / Reject | 提升或拒绝候选依据可读的对照结果，保留评价版本与数据；apply/promote 经适用审批及安全服务，不把模型综合分当唯一闸门 | V §2,41–48 |

### 3.5 官方网站、发布与后续边界

| ID | 阶段 | 能力 | 可验收结果与边界 | 来源 |
| --- | --- | --- | --- | --- |
| WEB-01 | 并行 | 官网视觉 | 浏览 `px0.ai` 的真实参考并形成原创 Vela 页面；所有 UI/样式实现须通过用户指定 Antigravity CLI 3.8 Flash (High)，保留调用记录；工具/模型不可用要明确阻塞 | U |
| WEB-02 | 并行 | 官网内容 | 说明核心闭环、真实已支持 harness、隐私边界、安装要求与下载；不能把 roadmap 写为已上线能力；无虚假用户、数字、证言和空下载链接 | U；V §59,73 |
| WEB-03 | 并行 | 官网使用 | 桌面与移动端响应式，键盘操作可达，导航和 CTA 实际工作，静态资源精简；独立本地运行与生产构建可验证；正式托管 URL 单列验证 | U |
| REL-01 | P0+ | Mac 应用产物 | Apple Silicon 真机启动、菜单栏和窗口生命周期、重启后本地数据恢复；安装和构建可重复；声明 macOS最低版本、CPU 架构和签名状态 | U；V §60,64 |
| REL-02 | 公开发行前 | 签名、公证、更新 | Developer ID、Hardened Runtime、Notarization、更新签名校验；Stable/Canary/Dev 的 bundle ID/userData/DB/protocol/feed 分离；无凭据时明确未发布 | V §64 |
| REL-03 | 每次打包 | 打包卫生 | 显式 allowlist；测试/内部 docs/plans/source TS/.env/私有元信息不进安装包；自动检查并保留清单；不得只凭配置文件宣称已检查产物 | V §63；B1 §10 |
| NEXT-01 | P3 | 高级本地与外部连接 | Best Harness/Model、Native Session Handoff、External Tool Providers、GitHub/Linear/Slack、Conflict Radar、Canonical Context；单独立项并扩展权限契约 | V §68 |
| NEXT-02 | P4 | 分布式能力 | Encrypted Sync、Self-hosted Sync、Walrus Backend、Team Memory/Workflow；不作为 V1 的隐含云依赖 | V §69 |
| OUT-01 | 排除 | 非目标 | 前几个版本不做 Windows/Linux/Mobile/IDE/自有 Coding Agent/通用多智能体框架/邮件日历 CRM 助理/cloud-first SaaS/Workflow Marketplace | V §70 |

## 4. 安全与可靠性强制门槛

| ID | 不变量 | 必须覆盖的反例 |
| --- | --- | --- |
| SEC-01 | 渲染层只能调用枚举能力，全部入口校验输入、长度、枚举与授权 scope | 任意 IPC 名、超大 payload、非法路径、未知对象、跨项目 ID |
| SEC-02 | 如果采用 Electron，`nodeIntegration=false`、`contextIsolation=true`、`sandbox=true`，禁止暴露原始 ipcRenderer | 通过页面脚本直接读文件/启动进程；远程页面导航进入特权 renderer |
| SEC-03 | 所有写入经过 allowed root、realpath、symlink/文件身份校验、staging、fsync、原子替换 | `../`、绝对路径注入、symlink escape、路径组件交换、目标在审批后被替换 |
| SEC-04 | 多文件 Apply / Undo 全有或全无，文件内容与操作 ledger 一致 | 第二个操作失败、磁盘满、权限变化、进程中断、Undo 前人工修改 |
| SEC-05 | READ/CONTRIBUTE/执行/审批是服务层权限，不靠前端或模型自觉 | MCP 越权 apply、篡改 action payload、重放已批准 action、私有 library 间接拼入 prompt |
| SEC-06 | 秘密保存在 macOS Keychain 或用户已授权的原 provider 存储，不明文写本地业务库/日志 | OAuth/API key/password 经字段名、异常堆栈、子进程 env 或导出泄露 |
| SEC-07 | V1 无账号要求，无云会话/Memory/Workflow state；telemetry 默认关闭 | 未开启遥测已有请求；遥测包含 prompt/message/file/path/memory/project name |
| SEC-08 | 开启遥测也只允许固定 enum/count/duration/version/error category | 把任意用户字符串塞进 error category 或 enum；只做正则清洗却无 schema allowlist |
| SEC-09 | agent CLI 输入输出和工程资料均是不可信数据 | prompt injection 引导拓宽路径、增加外发动作、修改 approval、编造 evidence ID |
| SEC-10 | 外部链接只支持批准协议；网络出口有明确归属和超时 | javascript/file/自定义危险 scheme；不必要的任意 HTTP 放行 |
| SEC-11 | 后台子进程有最小环境、输出/时间/队列限额、取消和退出清理 | 环境秘密继承、stdout 无限增长、子进程残留、重试风暴 |
| SEC-12 | DB 迁移与索引重建不损坏用户 Markdown 资产，失败可诊断可恢复 | 中断升级、迁移版本不兼容、损坏缓存导致长期 Memory 丢失 |

本地优先不等于模型调用绝不出机：用户自己的远程模型 CLI 仍可能把经批准的内容发送给对应模型提供方。官网和设置应清楚说明此边界，不复述报告中“用了本地 CLI 所以内容不离开本机”的推论。

## 5. 性能预算与测量方式

所有数字均来自 V §60–62，是待实测的产品目标，不能写成已达标结果。基线注明硬件、macOS、构建类型、session/record 数、文件体积、冷热缓存、采样数；开发模式数据不替代签名生产构建的数据。

| 项目 | 目标 | 验证边界 |
| --- | --- | --- |
| 冷启动窗口可见 | p95 ≤ 1.5 s | 进程启动到首个可见窗口；不得以后台进程预热冒充冷启动 |
| 冷启动可用 | p95 ≤ 2 s | 主要导航、近期真实状态可交互；历史回填可继续 |
| 空闲 CPU | < 0.5% | 无新事件时稳定常驻采样；说明按进程还是全应用合计 |
| Main + Watcher RSS | < 120 MB | 按所选架构对应宿主与 watcher 统计，不能漏算后台 worker |
| 普通窗口总内存 | < 220 MB | 合计 app 所有进程；标明 RSS 与共享内存计数口径 |
| Agent 事件到界面 | p95 < 300 ms | 从本地可观察事件到UI状态呈现；provider自身写盘延迟分列 |
| 页签切换 | p95 < 50 ms | 交互开始到新内容可见，不以空骨架充当实际内容 |
| Session 打开 | p95 < 150 ms | 打开已有索引会话的第一屏时间线；长历史分页 |
| Search | p95 < 120 ms @ 100k records | 真实索引、代表性查询、scope/权限过滤开启 |

后台优先级：Session ingestion → User Interaction → Search → Usage → Memory → Improve → Workflow Background → Lab。历史回填、Improve、Lab 有有界队列和并发，取消及时生效；高负载下可以延迟后台分析，不能饿死实时状态。worker 按需启停，idle shutdown；故障与过载要有明确状态，不能通过主线程兜底破坏性能边界。

界面计时采用共享 tick，后台隐藏窗口降低更新频率；长时间线虚拟化或分页，昂贵高亮和内容解析按需加载。验收这些实现属性仍须服从 U：UI/样式由指定 Antigravity 模型完成。

## 6. 阶段依赖与最小可验证闭环

| 阶段 | 先决条件 | 实际交付闭环 | 离开阶段的闸门 |
| --- | --- | --- | --- |
| P0-A 数据基础 | 独立工程、版本化数据模型、允许读取的本地目录 | Claude/Codex 真实日志 → 增量解析 → SQLite/索引 → Agents/Session/Search | 坏行/半行/轮转/重启不重计；真实状态和未知状态分清 |
| P0-B Sidecar | P0-A、Mac shell、Antigravity UI 可用 | 菜单栏/通知、Setup、Usage、项目身份、设置 | 真实 Mac 应用可启动；来源可检查；无假 usage；冷启动/常驻性能记录 |
| P0-C Context | 稳定 scope 与 evidence ID | Session → 人工/候选 Memory → Active → MCP Read/Recall基础；Checkpoint → 外部 harness 恢复 | 跨项目隔离与 private 预留策略生效；中立交接可实用 |
| P1-A 治理安全 | P0、文件安全服务、证据关系、真实 CLI 执行接口 | Setup Audit / Improve → Evidence → Diff → Apply → Undo | 良好配置零发现；hash变化不写；多操作失败回滚；不靠模型晋升 |
| P1-B 自动化 | 工具能力注册、权限分类、版本化 Markdown | Workflow → Dry Run → Frozen Approval → Run → Ledger | 真实任务可跑完；审批前不外发/删除；编辑和重放不复用旧批准 |
| P1-C 核心身份 | P1-A/B、worktree隔离与运行账本 | Context/Memory/Workflow baseline-candidate → 真实 Lab → Promote/Reject | 原仓库不改；关键变量匹配；结果无编造；Cursor可观测支持范围明确 |
| P2-A 连续改善 | 足够真实历史、稳定 ledger | Discovery/Health/Replay/Scheduler/Regression → 下一次真实运行 | 触发去重与恢复可靠；统计带样本量；审批在重放中仍有效 |
| P2-B 知识入口 | Recall budget、统一检索授权 | Library → Human Search / Agent Recall → Ask Vela / Raycast | Private在所有agent路径不可达；归因与上下文预算真实 |
| 官网与发行 | 产品描述准确、指定UI工具、可安装产物 | 官网 → 实际下载 → 安装 → 第一次发现agent → 获取帮助 | 下载对应可用产物；线上与本地状态分开；公开发行签名/公证/更新验证 |

推荐按独立垂直闭环交付，不先做全部导航假页。一个模块能从真实输入走到实际结果后再扩展场景。所有暂不可用入口显示具体原因和恢复方式，避免“coming soon”隐藏必需流程。

## 7. 参考报告中不能直接沿用的结论

1. **调度时机叙述矛盾。** B3 T16 说“重置后 15 分钟”，B2 E9.1 所引条件却为 `0 < resetsAt-now <= 15min`，即重置前。Vela 应自主定义用户可见的时机策略并测试时间边界，不复用矛盾陈述。
2. **报告实时常量不满足 Vela 目标。** B2 B8 的 5 秒最小刷新/1 秒推送等数据不能支持 Vela 的 p95 < 300 ms；须将实时尾部状态与完整历史摄取分离并重新测量。
3. **订阅额度接口可能不是公共稳定 API。** B2 F 描述依赖 provider 凭据及内部端点；上线前依据当前公开支持能力验证适配，故障降级为 unavailable/stale，不硬编码报告里记录的 client ID 来假装长期兼容。
4. **快照差值存在归因限制。** 分析时用户也可能在同 provider 运行任务，或跨过额度 reset。差值只能在条件满足时估算，不能自动当成分析精确消耗。
5. **参考产品已实现不等于 Vela 已实现。** 尤其原生会话迁移、MCP 完整协议、真实 agent eval、签名/公证和更新；必须各自跑通验证。
6. **Clean-room 范围不扩张到 Blume 商业系统。** 账号门控、推荐、反馈板、客服、招聘、花朵主题和云控制面没有进入 Vela 核心要求，无需为“完整功能”一并复制。
7. **删除缓存不是删除用户资产。** 任务临时目录、解析中间文件、测试 worktree 可清理；长期 Memory/Workflow/Library、真实 session、依赖与用户工作区不得当缓存清理。

## 8. 完成报告要求

每次交付注明：已实现能力及真实数据路径、验证命令/样本、测试结果、性能实测与缺测项、所用 Antigravity 版本/模型、Mac安装包路径/签名状态、官网本地/线上 URL、外部条件与剩余工作。交付文档与 UI 不应将 mock、估算、草案和真实验证混为一谈。

北极星指标是 Repeated Friction Rate：一个已识别的问题在未来适用 session 中再次发生的比例。分子、分母、观察窗口、scope、检测规则版本与样本量需明确；Memory / Suggestion / Workflow 数量只能做活动统计，不能当改善效果。
