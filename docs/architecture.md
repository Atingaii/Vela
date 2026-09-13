# 当前架构

Vela 的当前开发分支在 Swift/AppKit/WKWebView/SQLite 基础上扩展三参考产品的完整能力。原有轻量默认运行时继续保留；可选远端能力通过明确的网络与身份边界接入。当前源码尚未发布，完整范围仍未验收。功能状态见 [status](status.md)，完整范围见 [parity](parity/README.md)，初始选择见 [ADR 0001](adr/0001-native-macos-core.md)。

## 进程与请求

```text
Vela.app — AppKit + 系统 WKWebView + 随包 UI
    │ 明确 RPC allowlist / 请求 ID / 双语固定文案
    ▼
vela rpc — 本地 JSONL stdin/stdout（EOF 排空已接收请求；SIGINT/SIGTERM 有界收束本地 child 并保留中断账本）
    ├─ Foundation queue：项目、Setup、Session、Memory、Library
    ├─ Automation queue：Workflow、Approval、Improve、Lab、Connector
    ├─ Provider queue：用户请求的 Codex 额度读取
    ├─ History utility queue：用户显式发起的历史回填短批次
    ├─ Control queue：运行中 Ask/Loop/Replay 详情与取消，独立实例锁与准入额度
    ├─ FSEvents：来源变化 → 有界读取 → Session 索引提交
    └─ SQLite WAL + Markdown / 版本 / 运行与审批 ledger

用户显式启用 launchd → vela daemon run → 调度 tick / 持久化事件
本地 SDK → vela rpc --no-watch --no-schedule
MCP → 独立只读或候选贡献入口，不启动调度
可选 Walrus SDK → 单独按需 worker → 明确的远端与签名请求
```

RPC 响应可乱序，按 ID 匹配。Foundation 与长自动化分队列，但共享 helper 与数据库，不是独立故障域。默认不增加常驻 Node、Chromium 或 Python 服务；可选 Walrus 包的 Node 依赖不进入默认 Mac 应用。后台服务显式安装和启动，不因打开设置、SDK 或 MCP 被启用。

多个 helper/daemon/CLI 可以使用同一 store，因此执行授权、事件领取和恢复依赖 SQLite CAS 与跨进程 lease，不能只用 Swift 对象锁。关闭窗口和退出应用的行为与独立 launchd 服务分开；停止服务在信号控制队列关闭启动 gate，清理拥有的进程组，等待有界状态持久化，不能提前伪报已停止。详见 [ADR 0006](adr/0006-independent-scheduling.md)。

## 模块责任

| 位置 | 责任与决策 |
| --- | --- |
| `Sources/VelaApp` | 指定 Antigravity 作者实现的窗口、菜单、通知与 bridge；没有任意 shell/file/network API。固定文案只支持 zh-CN/en，正文保持原文；[ADR 0005](adr/0005-desktop-localization.md) |
| `Sources/VelaCLI/main.swift` | JSONL/JSON-RPC framing、队列准入、方法路由、一次性 call 与 daemon 生命周期；敏感 JSON 可经 `call METHOD --params-stdin` 提交，避免出现在 argv |
| `MCPTools.swift` / `MCPToolAccess.swift` | stdio 协议协商、严格工具 schema、只读/候选贡献目录、按来源重新核验的窄分页与完整脱敏后正文分块；[ADR 0029](adr/0029-typed-stdio-mcp-tools.md) |
| `Store.swift` | 系统 sqlite3、WAL、参数化窄查询、Markdown 人工编辑、版本、批次补偿、CAS 与持久化变化/完成事件 |
| `SessionEngine.swift` / `PiSessionReader.swift` | Claude/Codex、已知 Cursor、版本感知 Pi/OMP；流式偏移、增长前已索引前缀 SHA-256、分支来源、文件身份、轮转与截断诊断；增长检查以 O(已完成偏移) 流式 I/O 换取旧区重写不复用陈旧投影；[ADR 0009](adr/0009-session-provider-compatibility.md)、[ADR 0040](adr/0040-indexed-prefix-integrity-for-growing-session-sources.md) |
| `IngestionExclusionService.swift` | 已登记项目或已知来源的持久排除、规则/代际/派生撤回原子提交、投影写入 CAS 与历史入口重验；[ADR 0042](adr/0042-atomic-ingestion-exclusions.md) |
| `SessionHistory*.swift` | 显式来源清单、固定epoch、分批回填、断点/分页原文与分支关系；不扩大dashboard尾窗；[ADR 0025](adr/0025-explicit-session-history.md) |
| `SessionPlanProjection.swift` / `SessionPlanService.swift` | 从已确认工具结果投影计划及有界变更事件；未知、提议与确认空计划分开，不将声明完成视为工作验证；[ADR 0027](adr/0027-observed-session-plans.md) |
| `SessionRelationProjection.swift` / `SessionRelationService.swift` | 从 Codex 来源头与结构化工具事件观察父子关系；重验来源身份、项目与隐私，分页和保留窗口明确，未知存活状态不推断为运行中；[ADR 0030](adr/0030-observed-codex-session-relations.md) |
| `FoundationService.swift` | 项目、harness发现、dashboard、脱敏 Setup、日志 token 聚合；[ADR 0004](adr/0004-nullable-observed-usage.md) |
| `ProviderQuotaService.swift` | 显式 Codex app-server 只读额度请求；来源时间、失败/stale、多个 bucket/window，独立于日志 token；[ADR 0011](adr/0011-provider-quota-observation.md) |
| `MemoryService.swift` / `SemanticMemory.swift` | 作用域与生命周期；词面或系统已安装语义模型的索引与召回、受限本地 embedding 与 recent/vector SDK API；每次批量读取共享有界排除策略快照，执行入口另做当前资格核验；已索引同项目 Session 消息可经 hash/identity 重验后捕获为候选 observation，普通编辑不会伪造其来源；受控 ingestion exclusion 可限制自动使用而不删除管理中的 Memory；[ADR 0013](adr/0013-local-semantic-recall.md)、[ADR 0031](adr/0031-local-embedding-and-recent-matches.md)、[ADR 0036](adr/0036-observed-session-memory-capture.md)、[ADR 0043](adr/0043-exclusion-aware-memory-recall.md) |
| `LibraryService.swift` / `LibraryIndex.swift` | 来源版本、审阅后编辑/归档/恢复/重抓、严格公开资料边界、可重建FTS5段落索引与引用；[ADR 0022](adr/0022-paragraph-library-retrieval.md) |
| `SetupInventoryService.swift` / `SetupCatalog.swift` | 五harness公开路径、脱敏历史/差异、删除痕迹与不完整扫描；[ADR 0018](adr/0018-observed-setup-inventory.md) |
| `StoreBackupService.swift` / `StoreBackupFiles.swift` | CLI 独占的完整本地 Store bundle；写屏障、受限流式文件、只恢复到新根、旧执行资格撤销与无覆盖发布；[ADR 0044](adr/0044-complete-local-store-backup-and-recovery.md) |
| `MemoryArchiveService.swift` / `sdk/typescript` / `sdk/python` | 明文可移植候选归档与实际可安装本地 SDK；[ADR 0007](adr/0007-portable-memory-archives.md)、[ADR 0010](adr/0010-local-client-sdks.md) |
| `sdk/walrus` | 固定官方依赖的可选远端 adapter，公开接口、受限 worker、冻结 profile 和身份/网络边界；[ADR 0017](adr/0017-optional-walrus-adapter.md) |
| `MemoryIntegrationService.swift` / `sdk/openclaw` | 显式宿主agent/workspace→namespace、权限复核、受限上下文与候选捕获、操作去重；[ADR 0023](adr/0023-scoped-openclaw-memory-integration.md) |
| `sdk/ai` / `sdk/python-ai` / `sdk/python-langchain` | 按需安装的 AI SDK v4、Python Responses 与 LangChain ChatOpenAI 适配；冻结调用配置、有界召回、完整终态后的可选候选捕获和不确定回执，不进入默认 Mac runtime；[ADR 0026](adr/0026-optional-model-memory-middleware.md) |
| `ContextService.swift` / `WorkflowContext.swift` | Guideline、证据贡献、Workflow 输入与真正送入 argv 的冻结 prompt；[ADR 0008](adr/0008-workflow-context-execution.md) |
| `AskRouteService.swift` / `KnowledgeQueryService.swift` | 持久化 Ask 决定与经显式 approval 的受限模型分类；冻结候选在 provider 前重验，结果只为建议，不会自动问答、规划或执行；[ADR 0032](adr/0032-persisted-safe-ask-routing.md)、[ADR 0021](adr/0021-reviewed-knowledge-answers.md) |
| `AutomationService.swift` / `WorkflowComposition.swift` | Workflow 定义/版本、逐工具审批与账本、冻结依赖图、子运行、恢复、根产物；[ADR 0015](adr/0015-workflow-composition.md) |
| `WorkflowRetry.swift` | 仅固定 Git 只读工具可显式开启有界 retry/backoff，逐 attempt 持久化；异常结果与中断证据不自动重放；[ADR 0033](adr/0033-bounded-read-step-retry.md) |
| `WorkflowHealth.swift` | 按工作流/版本分析已记录运行与审批，明确采样缺失、扫描上限和项目范围；只读诊断不自动修改定义；[ADR 0034](adr/0034-structured-workflow-health-evidence.md) |
| `RunFeedback.swift` | 对终态非私有运行以审阅哈希 CAS 记录人工观察；Health 单列观察，不改成功率或执行；[ADR 0038](adr/0038-manual-run-feedback-observation.md) |
| `LabService.swift` | 冻结 Recall OFF/ON 变体及实际检索状态；语义降级、不可用或索引不完整会在审批前拒绝；[ADR 0039](adr/0039-lab-recall-variants.md) |
| `WorkflowHealthProposal.swift` | 完整 timeout 观察→冻结候选提案→显式确认后原子创建新 ID 的停用工作流；保留原运行与权限，不自动执行；[ADR 0037](adr/0037-health-timeout-disabled-candidates.md) |
| `WorkflowManagement.swift` | 逐资产验证、克隆、审阅后启停/归档/恢复、依赖和活跃运行保护；[ADR 0019](adr/0019-reviewed-workflow-management.md) |
| `AgentLoopService.swift` | 受限多轮决策、实际只读工具结果、独立外部动作审批与取消；[ADR 0020](adr/0020-reviewed-model-tool-loops.md) |
| `KnowledgeQueryService.swift` | 独立审批的来源问答、真实段落引用、重新核验的续问与原文隔离；[ADR 0021](adr/0021-reviewed-knowledge-answers.md) |
| `WorkflowPlanning.swift` / `RestrictedCodexProposal.swift` | 审批后的受限结构化模型提案；问题/草案与执行分离，禁工具的协议验证；[ADR 0012](adr/0012-reviewed-workflow-planning.md) |
| `ConnectorService.swift` / `ConnectorTransport.swift` | Keychain 代际凭据、分页目录、账户/工具 schema 绑定、冻结动作、无自动重试的 HTTPS 传输；[ADR 0016](adr/0016-reviewed-external-connectors.md) |
| `ImproveService.swift` / `ModelImprovement.swift` | 确定性检测及显式三阶段模型证据提案、候选 hash、审阅/Apply/Undo；[ADR 0014](adr/0014-model-improvement-proposals.md) |
| `SafeApply.swift` | 明确目标路径、inode/hash、staging/fsync/rename、journal、补偿恢复与 Undo |
| `AutomationProcess.swift` / `RuntimeShutdown.swift` | 明确 executable/argv、净化环境、进程组、时间/输出限额、停止 gate 与后代清理 |
| `SchedulerService.swift` / `SchedulePolicy.swift` / `ScheduleControl.swift` | cron 时区、补跑策略、去重、完成事件游标、活动运行阻重叠、需核对事件与原子确认 |
| `WorkflowWatch.swift` / `WorkflowFileWatch.swift` | 受限只读工具轮询或单FSEvents提示；有界快照与净变化积累、首轮基线、重启/丢事件标记、逐工具审批；[ADR 0024](adr/0024-durable-read-tool-watches.md) |
| `DaemonService.swift` / `RuntimeLease.swift` | 用户 launchd 服务的精确身份、生命周期及跨进程短期 lease |
| `LabService.swift` / `AgentEvaluation.swift` / `ReuseService.swift` | 同提交独立 verifier、版本化指标、候选晋升、项目 Hook 和后续来源收据；[ADR 0003](adr/0003-evaluation-and-reuse-evidence.md) |
| `ReplayFixture.swift` / `WorkflowReplay.swift` / `ReplayExecutableSnapshot.swift` | 显式保留历史输入、审批后比较两个固定工作流版本、同一原生执行文件快照及有界清理；未知结果停止后续执行，不推断语义胜出；[ADR 0028](adr/0028-historical-workflow-replay.md) |
| `Preferences.swift` / `NotificationPolicy.swift` | 严格偏好类型、通知来源/静默基线/去重；原生壳承担 OS 投递；[ADR 0002](adr/0002-native-notification-policy.md) |
| `website/dist` | 独立静态官网，不连接用户本地数据库 |

## 本地数据与模型

CLI 默认 `~/.vela`，`--home`/`VELA_HOME` 可显式选择。桌面 stable/canary/dev 采用独立应用身份和 store；CLI/MCP 必须选中实际目标，通道名称不赋予发布资格。SQLite 为 `vela.sqlite3`，WAL、NORMAL synchronous；长期资产位于 `assets/{memory,workflow,guideline,library,checkpoint}`。运行对象、审批和版本单独存储。JSON frontmatter 是当前 Markdown Workflow 支持的 YAML 子集，执行前重新读取人工更改并校验增版。

`vela.sqlite3` 使用 `PRAGMA user_version` 管理 schema，当前版本为 1。历史未 versioned store 由显式 `0 → 1` registry 在单个 SQLite 事务中迁移，成功后才写版本；取得写锁后再次读取版本，防止等待锁期间的另一 helper 升级被旧 helper 降级回写。更高或负版本在 schema/data 写入前由当前 helper 拒绝；已标为 v1 但缺必要 schema 对象也拒绝而不自动修补。迁移失败 rollback 后可重试。WAL sidecar/checkpoint 使 raw database 文件字节不稳定，因此迁移验收检查已提交的 schema 与逻辑记录；它不代替 Markdown 资产补偿、完整备份或派生索引灾后恢复。[ADR 0041](adr/0041-versioned-sqlite-store-migrations.md) 记录该边界。

Session 通用 revision 用于无变化时跳过后台分析。完成事件另有单调 sequence 与 `(project,session_id,activity)` 唯一身份，不复制会话正文；调度首次建立基线、之后分页推进持久化游标。跨连接写入同样生效，超过一页的突发完成不会由固定最近列表遗漏；private、删除、迁移与内部会话不能触发错误项目执行。

Session 来源仍有明确保留预算，不宣称完整历史已索引。Pi 按版本解析父子链，展示最后持久化分支及覆盖范围；O_NOFOLLOW 和前后 inode/size/mtime/ctime 检查防止将并发修改的文件误记为完整版本。日志状态与实时进程状态分开；缺失用量为 null，真实 0 为 0。Codex 账户额度来自单独只读 app-server 请求，不读取 auth 文件、不调用 reset，也不从 token 推算剩余额度。

摄取排除是可逆的访问策略。规则命中的普通 Session 投影会撤回，历史原始缓存与 Memory 保留；规则有效期间旧 History ID 不能绕过读取限制。解除规则本身不重读来源，保留的旧 epoch 可再次访问；Session 投影在后续 refresh 或新来源事件时重建。RPC 已实现，桌面配置入口仍待实现。详见[摄取排除合同](implementation/ingestion-exclusions-contract.md)。

单独的历史回填按配置来源ID启动，保存固定epoch、字节checkpoint及归一化记录；分页游标与epoch绑定，来源变化使当前回填stale，不把新旧版本拼成“完整”。原文完整性、消息解析与分支完整性分别报告。该模块正在分provider验收，未知Cursor私有格式不能用raw保存替代功能解析。

Memory 的 private、scope、Active 状态在召回前检查。语义索引仅使用系统已安装的选定语言模型，记录 provider/revision/维度/pooling 算法与源 hash，查询时排除失效向量。默认词面可离线工作，hybrid 标明回退，cosine 不是置信度。索引由用户明确触发并分页，既有模型不需要另一个向量服务。Library 默认私有；公开检索要求明确false并重新验证实际Markdown。段落FTS5索引采用Unicode/CJK词面匹配和BM25/覆盖/邻近度重排，原文与位置不变。Ask每轮单独审批、核验引用原文和来源版本；引用存在不证明回答的语义正确性。

本地归档排除 private/global，导入只创建目标项目 candidate，不能覆盖后续人工修改或自动激活。SDK 选择明确 store/project/executable，关闭 watcher/scheduler，未知结果不重发。可选 Walrus 是另一信任边界：客户端 SEAL 加密不隐藏给嵌入服务的明文，官方远端恢复可能要求 relayer 解密；真实账户/交易/费用的验收必须独立记录。

OpenClaw插件使用宿主明确的workspace与agent映射，工具调用参数不能改变namespace。自动捕获默认关闭；本地路径只保存原文候选，远端提取必须另外允许明文处理与预算。真实宿主turn已经验证上下文和工具生命周期，但本地合成provider不证明真实模型采纳或远端权限。

## 授权、执行与恢复

Renderer 的 CSP 禁止业务网络，原生 bridge 使用精确方法白名单。系统保存归档总是由 NSSavePanel 选位置，网页不能给任意路径。MCP 只读或贡献候选，不暴露执行、激活或 Apply；私有过滤在服务端执行，工具注解本身不是授权。

MCP 初始化和工具调用在同一串行入口处理，按协商协议版本返回兼容字段。工具参数不允许静默丢弃未知字段；项目、范围和来源在服务端核验。索引分页只查询需要的 ID，正文先对完整可见文本脱敏再按字符分页，后续分块绑定来源 hash；元数据同样脱敏。stdio 接口不隐含 HTTP、OAuth 或远端客户端兼容承诺。

Workflow Context 将选定输入、Guideline 和 Active Memory 冻结并记录 hash；仅显式使用完整 `{{vela.prompt}}` argv 槽位的 Agent 命令接收最终文本。旧命令不静默重写。自然语言规划与 ModelImprove 使用冻结请求、明确模型/程序和受限结构化输出；提案不自动成为活动工作流或文件修改。

Ask 路由与模型分类提案分别持久化。通用审批与运行账本仅引用 proposal ID/hash，候选变私有或失效后，读取接口也撤去冻结来源与结果；模型启动前再次核验。分类建议仍需用户选择后续问答、规划或运行入口。路由不是自动完成任务的会话代理。

只读重试默认关闭，仅允许固定 `git.status`、`git.diff`、`git.log`，最多三次；写入、模型和外部连接操作不能借此重放。停止信号和退避检查不等于已有通用运行取消界面，attempt 之间的 deadline 也不替代单个进程的超时。Health 的成功率、可用耗时与状态计数各自保留分母和来源限制，不从未记录的数据推断零、不把跨版本差异当作因果改善。

业务工具动作保存确切参数、项目、run、step 和 hash，经 pending→executing 的事务抢占后执行。pipeline/子输入冻结同项目依赖图，每个子动作仍独立审批。`runs.get` 纯读，显式 resume 只推进未启动结构或恢复已有确切账本；executing/needs_review 不重试。根产物可返回调用方、写 store 内 output 路径或进入产物 Inbox，子运行只返回 memory 文本。确定性组合不等同模型自主选工具循环。

Composio 固定 HTTPS v3.1 endpoint、禁 redirect、无 cookie/cache、限时间与大小。Keychain 项绑定随机 generation；轮换不改变已有审批身份。执行前重查选定账户、版本和 schema。已知凭据回显在任何持久化前拒绝，普通输出凭据字段显式脱敏。`successful:false` 或非明确拒绝的失败不能证明无部分副作用；保存 needs_review、不继续依赖步骤。单次 CAS 不等于任意外部系统全局 exactly-once。

SafeApply 通过规范项目根、目录描述符、O_NOFOLLOW、inode/device 和 before hash 拒绝越界/链接/陈旧写入；staging/fsync/rename 与 journal 记录 before/after。单 rename 原子，多文件依靠补偿和恢复；如果用户后来修改，保留需核对而不覆盖。Undo 同样验证 after hash。SQLite/Markdown 批次补偿与文件 journal 是不同机制，不能混称跨介质原子事务。

执行使用 posix_spawn、明确参数、净化环境、独立进程组和限额。临时目录不是 OS 沙箱，已经批准的命令仍可能访问其他路径。Git 读取禁 hook、fsmonitor、external diff/textconv。停止控制与调度/执行队列分离，避免慢 Git 或模型请求阻止清理已启动的进程组。

## 调度、评测与交付

cron 以 UTC 分钟建立身份，按 IANA 时区判断触发；skip/latest/all 与有界补跑窗口显式保存。活动 run、审批、waiting_child 和未知结果阻止同工作流重叠；未解 claim 必须显式核对。launchd 可在窗口/app 关闭后运行 helper，不会免除业务审批。usage_reset 仍未接通。

确定性后台分析默认关闭，依据 revision 做有界扫描，不自动调用模型/Apply。显式模型 Improve 以最多三次提案请求完成提取、聚类、规划，证据 ID 和源 hash 必须可回查。Lab 保留同提交、独立 verifier、缺失/null 和计量版本；局部同分不能晋升，收据与一次比较不能证明未来纠错下降。

历史 Replay 只比较已保存的两个单步 Agent 工作流版本，冻结输入与 Context，不重新读取今日 Git 状态。获批的原生 Mach-O 文件复制到只属于本次执行的受限目录并核验 hash，两个变体使用同一份字节；脚本包装器被明确拒绝，动态依赖仍是独立边界。原文 payload 与元数据分开存放，删除先持久化 tombstone，再有界清理实际关联 payload，未清完明确报告 pending。

SPM 构建 VelaCore、vela、VelaDesktop，打包脚本只装允许的应用资源，测试/源码/内部材料不入包。Developer ID、公证、签名更新、系统通知和其他机器/架构分别验收。没有这些证据时，ad-hoc 包仍是开发预览。官网与应用分发相互独立。

CI 配置存在不等于当前代码通过。Portable fallback 编译真实同步测试但不是 XCTest；最终测试必须绑定源码与 helper 快照。冷启动、RSS、CPU、事件延迟、大历史查询、长期并发稳定性使用独立测量，不由技术栈或包体推导。更多工具循环、完整历史/插件/维护/同步权限与产品 Golden Scenario 持续在 228 项台账中关闭，不再用原 MVP 范围将它们排除。
