# Vela 需求追踪 / Traceability

**基线：2026-09-12，`6c2bf54` / `0.1.0-preview.2`。** 本表是源码审查与既有运行报告的对照，未把本次写文档当成重新执行测试。后续改动须记录新的版本与证据才能升级。`Missing` 表示没有所要求的路径；`Partial` 表示存在子集；`Implemented` 仅描述窄项实现，仍须独立通过 [ACCEPTANCE](ACCEPTANCE.md)。

**English:** Each original requirement maps to a PRD requirement, a design rule, code, a named test and an evidence record. Partial test support is not complete acceptance. All 78 functional and 35 non-functional requirements are retained, including gaps and implementation-equivalent architecture choices.

追踪链：`Goal (PRODUCT_PRINCIPLES) → R-* (PRD) → D-* (PRD) → C-* (code) → T-* (test) → E-* (executed evidence)`。下面每个 R 的 Goal/D 映射继承自 [PRD 需求单元表](PRD.md#需求单元与设计约束)，并不是跳过设计。完整产品步骤另映射为 [GS01–20](ACCEPTANCE.md#20-步-golden-scenario)，安全/质量底线为 HG-1–6。

## 代码、测试与证据索引

### Code

| ID | 入口 / 实际责任 |
| --- | --- |
| C-OBS | [SessionEngine.swift](../Sources/VelaCore/SessionEngine.swift)：发现、FSEvents、解析/游标/状态；[FoundationService.swift](../Sources/VelaCore/FoundationService.swift)：project、dashboard、setup、usage |
| C-MEM | [MemoryService.swift](../Sources/VelaCore/MemoryService.swift)：save/transition/recall、library、checkpoint |
| C-CTX | [ContextService.swift](../Sources/VelaCore/ContextService.swift)：guidelines、workflows.build、signals.record、regression.list |
| C-IMP | [ImproveService.swift](../Sources/VelaCore/ImproveService.swift)：analyze、preview/apply/undo；基线为 deterministic explicit-language-v1 |
| C-AUT | [AutomationService.swift](../Sources/VelaCore/AutomationService.swift)：workflow/frozen approval/run/replay/health/evidence |
| C-SAFE | [SafeApply.swift](../Sources/VelaCore/SafeApply.swift)：allowed root、hash、文件身份、journal；[AutomationProcess.swift](../Sources/VelaCore/AutomationProcess.swift)：argv/env/进程组/限额 |
| C-LAB | [LabService.swift](../Sources/VelaCore/LabService.swift)：deterministic_command 配对；[SchedulerService.swift](../Sources/VelaCore/SchedulerService.swift)：helper 生命周期中的触发与持久化领取 |
| C-STORE | [Store.swift](../Sources/VelaCore/Store.swift)：SQLite、Markdown、批次补偿、CAS、search |
| C-RPC | [VelaCLI/main.swift](../Sources/VelaCLI/main.swift)：枚举 JSONL RPC、MCP read/contribute、队列和限额 |
| C-UI | [VelaApp/main.swift](../Sources/VelaApp/main.swift)、[app.js](../Sources/VelaApp/Resources/UI/app.js)、[index.html](../Sources/VelaApp/Resources/UI/index.html)：原生壳、renderer、路由/交互 |
| C-NOTIFY | [NotificationPolicy.swift](../Sources/VelaCore/NotificationPolicy.swift)、[Preferences.swift](../Sources/VelaCore/Preferences.swift)：分类、静默基线、来源/范围、偏好 |
| C-REL | [package-macos.sh](../scripts/package-macos.sh)、[release-audit.py](../scripts/release-audit.py)、[release_resources.py](../scripts/release_resources.py)、[CI](../.github/workflows/ci.yml)：构建、allowlist、审核；[官网](../website/dist/index.html) 独立静态交付 |
| C-AGENT（增量） | [AgentEvaluation.swift](../Sources/VelaCore/AgentEvaluation.swift)、[LabService.swift](../Sources/VelaCore/LabService.swift)：Codex JSONL adapter、冻结任务/模型请求、独立 verifier、版本化计分与旧结果重算 |
| C-REUSE（增量） | [ReuseService.swift](../Sources/VelaCore/ReuseService.swift)：Memory-only 晋升、Codex Hook 草案/Context receipt、同项目 provider Session 关联；不是普遍 Agent 自动采用证明 |

### Test

组名是索引，括号内才是现有测试函数/脚本。源码有测试不等于任意 commit 已执行；E 栏说明实际运行记录。

| ID | 现有明确检查 | 覆盖边界 |
| --- | --- | --- |
| T-ING | [FoundationTests](../Tests/VelaCoreTests/FoundationTests.swift)：`testClaudeStreamingOffsetAndUsageDeduplication`、`testCodexBoundedTailRetainsHeaderAndCumulativeUsage`、`testPartialJSONLAndRotation`、`testCursorReadOnlySQLiteAndUnsupportedSchemaDiagnostics`、`testFSEventsIngestsOnlyChangedLogWithoutManualRefresh` | 合成 provider 格式与真实摄取；不是五个真实运行 Agent |
| T-MEM | 同文件：`testRecallAllScopesStateAndBudget`、`testMemoryLifecycleAndHumanMarkdownEdits` | scope、Active-only、显式 supersede 与可读文件；不是自动提取或未来消费 |
| T-PRIVATE | 同文件：`testPrivateLibraryAlwaysExcludedFromAgentSearch`、`testHTMLAndDOCXLibraryImport`、`testPDFAndExplicitURLImportEnforceDocumentLimits` | 已实现入口的隔离/提取限额 |
| T-SETUP | 同文件：`testSetupScanningRedactsSecretsAndStaysInExplicitScope` | inventory/脱敏；不是全语义 Audit |
| T-CP | 同文件：`testCheckpointCapturesActualGitAndExportDoesNotExecute`、`testCheckpointGitDoesNotExecuteProjectFsmonitor` | 实际 Git 与不执行导出；不是新 Agent 恢复任务 |
| T-STORE | 同文件：`testSQLitePersistenceIsolationAndBoundQueries`、`testAtomicBatchRestoresBothSQLiteAndMarkdownOnFailure`、`testStateClaimAcrossTwoSQLiteConnectionsHasOneWinner` | 真实 SQLite、补偿、竞争；不是完整跨版本迁移矩阵 |
| T-CTX | [ContextTests](../Tests/VelaCoreTests/ContextTests.swift)：`testGuidelineVersionAndProjectBoundary`、`testWorkflowDraftUsesActualPackageScriptsAndDoesNotExecuteOrSave` | 版本/本地 builder；不证明 Guideline 注入 |
| T-IMP | [AutomationTests](../Tests/VelaCoreTests/AutomationTests.swift)：`testImprovePromotionUsesDistinctRealEvidenceAndIsIdempotent`、`testImproveDoesNotPromoteSingleSessionOrCleanConversation` | 3 signals/2 sessions、幂等、单会话/干净对话；缺完整 near-miss 质量集 |
| T-SAFE | 同文件：`testSafeApplyUndoAndStaleBatchAreRealFilesystemTransactions`、`testSafeApplyRejectsSymlinkTraversalMissingHashAndUnsafeUndo`、`testInterruptedJournalRecoversOnlyMatchingWrites` | 支持的文件事务反例；不保证任意断电/并发组合 |
| T-APPROVAL | 同文件：`testDryRunStubsEverySideEffect`、`testFrozenApprovalExecutesOnceAndIgnoresWorkflowEdits`、`testApprovalRejectsChangedFileWithoutOverwrite`、`testTwoDatabaseConnectionsCannotExecuteOneApprovalTwice`、`testRejectStopsWorkflowAndReplayIsDry`、`testHumanEditedWorkflowIsVersionedAndInvalidFrontmatterFailsClosed` | 冻结、一次领取、写入/脚本 stub、拒绝/重放 |
| T-LAB | 同文件：`testLabRunsApprovedRealPairedCommandsAndCleansWorktrees` | 真实 command 成对运行；不是 task/model/行为质量实验 |
| T-PROC | 同文件：`testProcessTimeoutAndOutputLimitAreEnforced` | 进程超时/输出限额；不是完整 worker crash/recovery |
| T-SCHED | 同文件：`testSchedulerClaimsAnEventOnceAndQuotaResetIsUnavailable`、`testTwoSchedulersClaimOneCronEvent`、`testHealthDoesNotInventRatesWithoutRealRuns`，及三个 `testBackgroundAnalysis*` | helper 内触发/opt-in/水位/失败重试；不证明休眠补跑 |
| T-NOTIFY | [NotificationTests](../Tests/VelaCoreTests/NotificationTests.swift) | 偏好、可信时间、历史静默、去重、快速 Run 与聚合范围；不测 OS delivery |
| T-MCP | [test-rpc.py](../scripts/test-rpc.py) | 编译 CLI、持久偏好、project 必填、private 排除、Candidate-only 贡献及 Dry Run |
| T-UI | [test-ui-browser.py](../scripts/test-ui-browser.py)；12 项见 [UX review](implementation/ux-review.md#最终-renderer-复验2026-09-12-1416-utc) | renderer→真实 CLI；原生通知注入/native stub 已明确；不运行完整 Golden |
| T-PKG | [test-release-resources.py](../scripts/test-release-resources.py)、[release-audit.py](../scripts/release-audit.py) | 原创资源与实际包排除；不等 notarization/update |
| T-PERF | [benchmark-read.py](../scripts/benchmark-read.py) | 100k synthetic records 的 warm RPC 搜索；不含 UI/冷启动/大日志 |
| T-IMP2（增量） | [ImproveAcceptanceTests](../Tests/VelaCoreTests/ImproveAcceptanceTests.swift)：`testFeatureSpecificationsQuotedExamplesAndAgainDoNotCreateSignals`、`testThreeParsedCodexToolSequencesCreateDisabledWorkflowDraftWithoutExecution`、`testCopiedProviderLogsDoNotMultiplySessionsOrCandidateMemories`，共九项专项方法 | 受控确切来源、near-miss 与有界读取；不是泛化 precision 或未来改善 |
| T-AGENT（增量） | [AgentEvaluationTests](../Tests/VelaCoreTests/AgentEvaluationTests.swift)、[AgentLabIntegrityTests](../Tests/VelaCoreTests/AgentLabIntegrityTests.swift)：`testWorseMissingAndTiedCandidatesCannotBecomePromotionReady`、`testFakeProtocolNoopLauncherCannotGameIndependentVerification`、`testFakeProtocolModifiedProtectedVerifierInvalidatesComparison` | synthetic protocol 实际走审批/Git/独立 verifier；不是真模型实验；最新 scorer 负例须随最终执行补证 |
| T-REUSE（增量） | 同 AgentEvaluationTests：`testHookSupersessionProjectPrivacyAndReceipts`、`testHookInstallPreservesOtherHooksAndRejectsStaleEdits`、`testReuseJoinRequiresCodexProviderAndCountsCopiedLogsOnce` | Hook 返回、范围/私有过滤、复制去重；不能把 Context 提供等同 Codex 信任、消费或遵循 |
| T-USAGE（增量） | [UsageIntegrityTests](../Tests/VelaCoreTests/UsageIntegrityTests.swift) 与本轮真实 helper 黑盒记录 | 缺失/真实零/部分 usage/整数溢出；不证明真实订阅额度或可归因成本 |

### Executed evidence

| ID | 可追踪记录 | 证明与不能证明 |
| --- | --- | --- |
| E-CORE | [verification.md / Preview.2](verification.md#preview2-verification) | 54/54 portable 真实核心方法；不是 XCTest；是基线的历史执行报告 |
| E-RPC | [verification.md](verification.md#preview2-verification) 和 T-MCP | 当轮 JSONL/MCP 黑盒通过；不是真实 agent 的 MCP 消费记录 |
| E-UI | [UX 最终记录](implementation/ux-review.md)、[原生记录](verification.md#preview2-verification)、[实际合成项目截图说明](assets/README.md) | 12 renderer 场景、部分 AppKit/WKWebView 与落库检查；不证明 Golden 完成 |
| E-PKG | [verification.md](verification.md#preview2-verification)、[v0.1.0-preview.2 release](https://github.com/Atingaii/Vela/releases/tag/v0.1.0-preview.2) | 当轮包签名/allowlist/资源审核与发行入口；具体归属使用 release checksum，不泛化后续包 |
| E-PERF | [initial performance measurements](verification.md#initial-performance-measurements) | 小样本 RSS/idle 与 search p95 132.33 ms；明确旧基线/负载范围 |
| E-WEB | [website/design-qa.md](../website/design-qa.md)、[verification.md](verification.md#preview2-verification) | 静态网站及响应式/图像检查；无核心业务验收能力 |
| E-NONE | **没有执行证据** | 计划、源码和测试名称不能填充此缺口 |
| E-LIVE（增量） | [ACCEPTANCE：真实 Agent 实验与更正](ACCEPTANCE.md#真实-agent-实验保留失败计分与更正)、[公开 v3 脱敏记录](evidence/2026-09-13-agent-lab.json)，Eval `938a7aa2-0bc7-416a-9437-e08b1240d9c4` | 真 Codex 六次、独立 verifier、同分不可晋升；更正旧 scorer 错误；六 raw 输出 hash 与 task hash 已核对；不是完整 Golden 或纵向质量结果 |
| E-PERF2（增量） | [本轮性能矩阵](reference-comparison.md#performance-matrix-to-run-before-a-hard-gate-decision) | release 100k 六类 warm 搜索均 <120 ms、有界摄取矩阵；不能提升整个 HG-1 为 Pass |
| E-USAGE（增量） | [本轮 Usage 反例与修复](reference-comparison.md#concrete-review-findings-and-follow-up)，本地 `acceptance-usage-integrity.json` | 缺失与两个历史 SIGTRAP 反例、修后六类 helper 行为及持续响应；不是所有 usage 来源完整 |

一次性旧 UI fixture 的 raw `browser-results.json` 不作为公开仓库长期工件；本次只核对到持久化报告与复验脚本，不假称原始文件仍保留。CI 配置存在不等于本次托管 CI 已通过；新候选应固定 run URL/commit 和工件哈希。E-CORE/E-RPC/E-UI 的合成数据不能作为真实用户长期改善样本。

## 原始 FR-01–78

R 编号对应 PRD 同号 D 约束及其 Goal；代码/测试覆盖的是“已具备部分”，不自动扩展到整行需求。`—` 表示没有合适现有测试，待 [ACCEPTANCE](ACCEPTANCE.md) 对应场景补证。

| FR | 能力 | R / D | 实现状态与缺口 | Code | Test | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| FR-01 | Harness 检测 | 01 | Partial：目录/CLI 检测，完整登录/版本/配额能力不足 | C-OBS | — | E-NONE |
| FR-02 | 实时监控 | 02/19 | Partial：状态基于日志推断，无存活证明 | C-OBS/C-UI | T-ING/T-UI | E-CORE/E-UI |
| FR-03 | Subagent | 02 | Missing：完整父子关系/根计数未具备 | C-OBS | — | E-NONE |
| FR-04 | Menu Bar | 19 | Partial：原生菜单/计数；完整 pause/状态任务流待验 | C-UI | — | E-UI |
| FR-05 | Notification | 19 | Partial：策略/试听；实际 OS 授权被拒 | C-NOTIFY/C-UI | T-NOTIFY | E-CORE/E-UI |
| FR-06 | Unified Session | 02/03 | Partial：messages/tools 子集，字段缺失与历史边界明确 | C-OBS | T-ING | E-CORE |
| FR-07 | 增量摄取 | 03 | Partial：append/partial/rotation/FSEvents；完整异常矩阵不足 | C-OBS | T-ING | E-CORE |
| FR-08 | Large Session | 03 | Partial：有界尾窗/保留上限，完整大负载矩阵缺测 | C-OBS | T-ING | E-CORE |
| FR-09 | Parser Version | 03 | Partial：游标版本；可续历史 backfill 缺失 | C-OBS | T-ING | E-CORE |
| FR-10 | Project identity | 02/03 | Partial：canonical path；remote/repository/worktree 归并不足 | C-OBS/C-STORE | T-STORE | E-CORE |
| FR-11 | Exclusion | 03 | Missing：显式 project/path/glob 全链排除 | C-OBS | — | E-NONE |
| FR-12 | Session Detail | 03 | Partial：实时消息/部分工具详情；完整 todos/files/subagents 不足 | C-UI/C-OBS | T-UI/T-ING | E-UI/E-CORE |
| FR-13 | Tool Detail | 03 | Partial：支持 input/output 子集；完整 duration/status/lazy paging 不足 | C-OBS/C-UI | T-ING | E-CORE |
| FR-14 | Inventory | 04 | Partial：扫描真实 Rules/Skills/Hooks/MCP；完整对象集合待验 | C-OBS/C-UI | T-SETUP/T-UI | E-CORE/E-UI |
| FR-15 | Artifact model | 04 | Partial：hash/source/diagnostics；runtime 加载差异/关系不足 | C-OBS | T-SETUP | E-CORE |
| FR-16 | Artifact relations | 04 | Partial：有限诊断引用，无完整六类关系 | C-OBS | — | E-NONE |
| FR-17 | Setup Audit | 04 | Partial：格式/重复/size；语义/漂移/过期检查未全做 | C-OBS | T-SETUP | E-CORE |
| FR-18 | Audit Evidence | 04 | Partial：诊断有来源；每 check 三类样本/适用性不足 | C-OBS | T-SETUP | E-CORE |
| FR-19 | No finding | 04 | Partial：允许空诊断；完整 clean/near-miss 集未验 | C-OBS | — | E-NONE |
| FR-20 | Context cost | 04 | Partial：保守估算；常驻/条件/按需四类载体全覆盖不足 | C-OBS/C-MEM | T-MEM | E-CORE |
| FR-21 | Cost ladder | 10 | Partial：Workflow/Guideline 分支；完整阶梯/理由缺失 | C-IMP | T-IMP | E-CORE |
| FR-22 | Memory extraction | 05 | Partial：九类型手动 CRUD；自动源事实提取缺失 | C-MEM/C-UI | T-MEM/T-UI | E-CORE/E-UI |
| FR-23 | Memory scope | 06 | Implemented：七 scope 的当前确定性匹配 | C-MEM | T-MEM/T-MCP | E-CORE/E-RPC |
| FR-24 | Memory state | 06 | Implemented：四状态和受限迁移 | C-MEM | T-MEM | E-CORE |
| FR-25 | Superseding | 06 | Partial：显式同项目 supersedes；新 Session 自动时序决议不足 | C-MEM | T-MEM | E-CORE |
| FR-26 | Memory relations | 06 | Partial：supersedes/provenance；完整关系图缺失 | C-MEM | T-MEM | E-CORE |
| FR-27 | Provenance | 05/06 | Partial：来源字段/原生消息保存；全字段可信验证不足 | C-MEM/C-UI | T-UI | E-UI |
| FR-28 | Authority | 06 | Missing：Verified/Confirmed/Observed/Inferred 的强制排序语义 | C-MEM | — | E-NONE |
| FR-29 | Lifecycle/expiry | 06 | Missing：branch/task/TTL 自动到期语义 | C-MEM | — | E-NONE |
| FR-30 | Recall engine | 07 | Partial：独立 Memory Recall；Rules/References 和消费缺口 | C-MEM/C-RPC | T-MEM/T-MCP | E-CORE/E-RPC |
| FR-31 | Recall ranking | 07 | Partial：词面/files/symbols；semantic/authority/freshness/conflict 不足 | C-MEM | T-MEM | E-CORE |
| FR-32 | Recall budget | 07 | Implemented：0–4000 保守估算上界与固定包装开销 | C-MEM | T-MEM | E-CORE |
| FR-33 | Checkpoint | 08 | Partial：用户记录+实际 Git；自动生成/完成验证不足 | C-MEM | T-CP | E-CORE |
| FR-34 | Handoff | 08 | Partial：中立文件/恢复提示，三个真实 Agent 恢复未验 | C-MEM | T-CP | E-CORE |
| FR-35 | MCP Server | 07 | Partial：受限 read 工具可用；实际 agent 注册/消费未验全 | C-RPC | T-MCP | E-RPC |
| FR-36 | MCP Permission | 07/20 | Implemented：明确项目/read/contribute，贡献不能执行/激活 | C-RPC | T-MCP | E-RPC |
| FR-37 | Usage quota | 18 | Missing：真实账户配额/plan/reset；日志 token 不是配额 | C-OBS | — | E-NONE |
| FR-38 | Usage history | 18 | Partial：观测 token 聚合；历史不全、day按会话开始 | C-OBS | T-ING | E-CORE |
| FR-39 | Task cost | 16/18 | Missing：可归因的 usage before/after/delta | C-LAB/C-AUT | — | E-NONE |
| FR-40 | Smart timing | 18 | Partial：默认关/水位分析；无 OS idle/额度策略 | C-LAB | T-SCHED | E-CORE |
| FR-41 | Search | 18/19 | Partial：本地搜索/导航；完整实体与结构筛选待补 | C-STORE/C-UI | T-STORE/T-UI | E-CORE/E-UI |
| FR-42 | Search ranking | 18 | Partial：substring；完整 exact/prefix/结构业务权重不足 | C-STORE | T-STORE | E-CORE |
| FR-43 | Extraction | 09 | Partial：明确语言关键词纠错；七类信号不完整 | C-IMP | T-IMP | E-CORE |
| FR-44 | Behavioral evidence | 09 | Partial：重复文字；真实 rollback/test failure 等旁证不足 | C-IMP | T-IMP | E-CORE |
| FR-45 | Clustering | 09 | Partial：确定性 key 分组；local retrieval+semantic候选不足 | C-IMP | T-IMP | E-CORE |
| FR-46 | Promotion | 09 | Partial：3 signals/2 sessions 的代码闸门；days/旁证语义不足 | C-IMP | T-IMP | E-CORE |
| FR-47 | Planner | 10 | Partial：有限 procedure/constraint 分支；完整可执行载体规划缺失 | C-IMP/C-CTX | T-IMP/T-CTX | E-CORE |
| FR-48 | Suggestion | 10 | Partial：evidence/diff/apply/dismiss；Test→Lab/revise/snooze 不全 | C-IMP/C-UI | T-IMP/T-SAFE | E-CORE |
| FR-49 | Safe Apply | 11 | Partial：支持路径+hash+stage/journal；完整故障矩阵未验 | C-SAFE/C-IMP | T-SAFE | E-CORE |
| FR-50 | Undo | 11 | Implemented：after hash 必须一致，不覆盖后续编辑 | C-SAFE/C-IMP | T-SAFE | E-CORE |
| FR-51 | Workflow | 12/13 | Partial：定义/执行；重复真实过程到定义的自动连接缺失 | C-AUT/C-CTX | T-APPROVAL/T-CTX | E-CORE |
| FR-52 | Workflow discovery | 12 | Missing：至少三 Session 真实 Tool/Task sequence | C-IMP | — | E-NONE |
| FR-53 | Workflow source | 13 | Implemented：Markdown + JSON(YAML子集)版本/人工编辑重读 | C-AUT/C-STORE | T-APPROVAL | E-CORE |
| FR-54 | Workflow builder | 13 | Partial：本地关键词/实际 scripts；完整自然语言/工具选择不足 | C-CTX/C-UI | T-CTX/T-UI | E-CORE/E-UI |
| FR-55 | Guideline | 10/13 | Partial：独立资产/版本/冻结；snapshot_only_not_injected | C-CTX/C-AUT | T-CTX | E-CORE |
| FR-56 | Tool permission | 13/20 | Partial：有限注册表/审批；扩展权限元数据不完整 | C-AUT/C-SAFE | T-APPROVAL | E-CORE |
| FR-57 | Unknown tool | 13/20 | Implemented：未知工具拒绝，比静默授予更保守 | C-AUT | T-APPROVAL | E-CORE |
| FR-58 | Dry Run | 13 | Implemented：仅受许 Git 读真实执行，测试/命令/写入 stub | C-AUT | T-APPROVAL/T-MCP/T-UI | E-CORE/E-RPC/E-UI |
| FR-59 | Approval Inbox | 13 | Partial：受支持副作用冻结审批；外部 providers/edit流程不足 | C-AUT/C-UI | T-APPROVAL/T-UI | E-CORE/E-UI |
| FR-60 | Frozen Action | 13 | Implemented：payload hash/参数快照/CAS；不承诺远端 exactly-once | C-AUT/C-STORE | T-APPROVAL | E-CORE |
| FR-61 | Run Ledger | 13 | Partial：实际工具/审批/输出；model/usage/实际Memory消费不足 | C-AUT | T-APPROVAL | E-CORE |
| FR-62 | Run Feedback | 14 | Missing：Good/Bad/reason 到未来 evidence 的完整路径 | C-AUT | — | E-NONE |
| FR-63 | Workflow Health | 14 | Partial：实际 success/runtime 等；完整 unused/edit/token metrics不足 | C-AUT | T-SCHED | E-CORE |
| FR-64 | Workflow Improve | 14 | Missing：真实 Health/Feedback/Failure→Workflow diff | C-AUT/C-IMP | — | E-NONE |
| FR-65 | Replay | 14 | Partial：冻结快照 dry replay；完整版本/外部差异可比性不足 | C-AUT | T-APPROVAL | E-CORE |
| FR-66 | Scheduler | 14 | Partial：cron/start/session/git；quota_reset unavailable | C-LAB | T-SCHED | E-CORE |
| FR-67 | Missed Schedule | 14 | Missing：休眠后 Skip/Run latest/Run all，默认 latest | C-LAB | — | E-NONE |
| FR-68 | Library | 18 | Partial：文档提取/显式 URL；2MB cap、无OCR/完整版本化检索 | C-MEM | T-PRIVATE | E-CORE |
| FR-69 | Private Library | 07/18/20 | Implemented：当前 Agent 检索路径硬排除；新增路径必复验 | C-MEM/C-STORE/C-RPC | T-PRIVATE/T-MCP | E-CORE/E-RPC |
| FR-70 | Agent Lab | 15 | Partial：三 kind 标签，实际仅 deterministic_command | C-LAB | T-LAB | E-CORE |
| FR-71 | Context Eval | 15 | Partial：文件变化的命令配对；真实 Agent 行为不足 | C-LAB | T-LAB | E-CORE |
| FR-72 | Memory Eval | 15 | Missing：Memory OFF/ON 实际 Recall 与 Agent 消费对照 | C-LAB | — | E-NONE |
| FR-73 | Workflow Eval | 15 | Partial：版本/命令基础；真实历史 Workflow 对照不足 | C-LAB/C-AUT | T-LAB | E-CORE |
| FR-74 | Eval Isolation | 15 | Partial：same commit/worktrees/command/timeout，task/model等缺失 | C-LAB | T-LAB | E-CORE |
| FR-75 | Eval Source | 15 | Partial：用户指定 Git/task 输入；源 correction/run 到 Eval 缺失 | C-LAB | T-LAB | E-CORE |
| FR-76 | Eval Metrics | 16 | Partial：exit/runtime/diff/1–5 repetitions；Agent指标不足 | C-LAB | T-LAB | E-CORE |
| FR-77 | Regression | 16/17 | Partial：已记录版本的观测趋势；自动触发/控制对照缺失 | C-CTX | — | E-NONE |
| FR-78 | Evidence Graph | 17 | Partial：若干来源引用；Eval→Adoption→FutureSession→Outcome缺失 | C-AUT/C-IMP/C-MEM | T-IMP/T-LAB | E-CORE |

## 原始 NFR-01–35

全部非功能要求归 R-20/D-20（全 Goal 的底线），性能/交互另归 R-19/D-19；安全边界另归 R-11/D-11、R-13/D-13。架构等价不等于免验：Electron 属性映射到 WKWebView/枚举 bridge 与独立 helper 的实际不变量，依据 [ADR 0001](adr/0001-native-macos-core.md)。

| NFR | 不变量 | 实现/验收缺口 | Code | Test | Evidence / Gate |
| --- | --- | --- | --- | --- | --- |
| NFR-01 | macOS/arm64 | Implemented：当前主机；macOS 13 实装未验 | C-REL/C-UI | T-PKG | E-PKG |
| NFR-02 | 冷启动 | Partial：后台初次摄取；分布未测 | C-UI/C-OBS | — | E-NONE / HG-1 |
| NFR-03 | 响应 | Partial：search p95 132.33 ms 超预算；其余缺测 | C-STORE/C-UI | T-PERF | E-PERF / HG-1 Fail |
| NFR-04 | idle CPU | Partial：FSEvents；短采样非长期平均 | C-OBS/C-UI | — | E-PERF / HG-1 |
| NFR-05 | memory | Partial：小 GUI 合计 196.6–196.7 MiB；负载矩阵未测 | C-OBS/C-UI | — | E-PERF / HG-1 |
| NFR-06 | backpressure | Partial：有限队列/双 RPC 队列；完整优先级/负载公平性未验 | C-RPC/C-OBS | T-PROC | E-CORE / HG-1/2 |
| NFR-07 | process isolation | Partial：独立 helper，服务共享故障域；不需照搬 9 workers | C-RPC/C-UI | — | E-NONE / HG-2 |
| NFR-08 | worker reliability | Partial：退出错误/时间限额；完整 heartbeat/watchdog/circuit/recovery不足 | C-RPC/C-UI/C-SAFE | T-PROC | E-CORE / HG-2 |
| NFR-09 | local-first | Implemented：无账户/托管业务状态；完整默认网络观测缺测 | C-STORE/C-RPC | T-MCP | E-RPC / HG-4 |
| NFR-10 | telemetry | Implemented：固定关闭；当前没有用户内容 telemetry | C-RPC | T-MCP | E-RPC / HG-4 |
| NFR-11 | credentials | Partial：无新凭据托管功能；脱敏/env清理；未来Keychain需独立验 | C-OBS/C-SAFE | T-SETUP/T-PROC | E-CORE / HG-3/4 |
| NFR-12 | renderer sandbox | Partial：系统 WebKit/CSP/非特权远程页；全攻击面未验 | C-UI | T-UI | E-UI / HG-3 |
| NFR-13 | typed minimal IPC | Partial：枚举/校验/队列限额；全方法模糊测试缺测 | C-UI/C-RPC | T-MCP | E-RPC / HG-3 |
| NFR-14 | input trust | Partial：JSON/长度/范围校验；完整不可信输入矩阵不足 | C-RPC/C-OBS/C-AUT | T-MCP/T-ING | E-CORE/E-RPC / HG-3 |
| NFR-15 | Markdown safety | Partial：转义/CSP；恶意Markdown/远图全场景未测 | C-UI | — | E-NONE / HG-3 |
| NFR-16 | file sandbox | Partial：支持写入根严格；已批准外部命令不是OS沙箱 | C-SAFE/C-AUT | T-SAFE | E-CORE / HG-3 |
| NFR-17 | traversal/symlink/TOCTOU | Partial：fd/O_NOFOLLOW/inode/device；完整race矩阵未验 | C-SAFE | T-SAFE | E-CORE / HG-3 |
| NFR-18 | atomic writes | Partial：单文件rename/journal多文件补偿；非跨介质全局原子 | C-SAFE/C-STORE | T-SAFE/T-STORE | E-CORE / HG-5 |
| NFR-19 | prompt injection | Partial：模型无权限/贡献受限；完整伪证据/间接输入矩阵不足 | C-RPC/C-AUT | T-MCP/T-APPROVAL | E-RPC/E-CORE / HG-3 |
| NFR-20 | argv spawn | Implemented：明确 executable/argv，无renderer通用shell | C-SAFE | T-PROC/T-APPROVAL | E-CORE / HG-3 |
| NFR-21 | env scrub | Partial：allowlist/敏感env排除；provider真实认证组合未全验 | C-SAFE | T-PROC | E-CORE / HG-3/4 |
| NFR-22 | SQLite/WAL | Implemented：参数化SQLite/WAL+可读长期资产 | C-STORE | T-STORE | E-CORE / HG-5 |
| NFR-23 | storage abstraction | Partial：集中Store API；非完整可替换StoragePort | C-STORE | T-STORE | E-CORE / HG-5 |
| NFR-24 | index recovery | Partial：有canonical资产/索引；全derived index重建协议未验 | C-STORE | — | E-NONE / HG-5 |
| NFR-25 | migration | Missing：完整版本迁移、失败回滚与升级矩阵 | C-STORE | — | E-NONE / HG-5 |
| NFR-26 | crash recovery | Partial：journal/部分运行reconcile；helper/worker全故障未验 | C-AUT/C-SAFE | T-SAFE | E-CORE / HG-2/5 |
| NFR-27 | signed/notarized release | Missing：当前ad-hoc；正式流程钩子不等实际认证 | C-REL | T-PKG | E-PKG（未公证） |
| NFR-28 | secure updater | Missing：已验证签名/可恢复自动更新 | C-REL/C-UI | — | E-NONE |
| NFR-29 | channel isolation | Partial：bundle/data/protocol；无完整updatefeed验证 | C-REL/C-UI | T-PKG | E-PKG |
| NFR-30 | package hygiene | Implemented：当轮实际allowlist及产物审核 | C-REL | T-PKG | E-PKG / HG-6 Pass |
| NFR-31 | sourcemaps | Not Applicable：当前无 sourcemap 生成/上传；未来启用需剥离审核 | C-REL | T-PKG | E-PKG / HG-6 |
| NFR-32 | test layers | Partial：core/contract/RPC/UI/security；Agent Eval/性能不足 | 全入口 | 全测试 | E-CORE/E-RPC/E-UI |
| NFR-33 | harness fixtures | Partial：已知格式/partial/rotation；所有provider状态矩阵不足 | C-OBS | T-ING | E-CORE / HG-2 |
| NFR-34 | DB integration | Partial：真实SQLite/CAS/重启；migration/crash矩阵不足 | C-STORE | T-STORE/T-APPROVAL | E-CORE / HG-5 |
| NFR-35 | security tests | Partial：路径/审批/MCP/脱敏；完整攻击矩阵缺测 | C-SAFE/C-RPC/C-UI | T-SAFE/T-MCP/T-SETUP | E-CORE/E-RPC / HG-3 |

## 22 个模块完整性检查

以下严格保留用户列出的 22 个模块；每行只给入口，不把可打开页面记为完整。整个表无完整产品 Pass。

| 模块 | 相关需求 | 当前最关键未闭环部分 |
| --- | --- | --- |
| Agents | FR-01–03 | 存活/五并发/父子归并 |
| Sessions | FR-06–09/12–13 | 全历史/完整事件/异常格式矩阵 |
| Projects | FR-10–11 | 统一repository/worktree身份、排除 |
| Menu Bar | FR-04–05 | 完整Sidecar任务流、OS通知投递 |
| Setup | FR-14–16 | 完整关系与实际加载差异 |
| Audit | FR-17–21 | 全类检查/negative/near-miss/抑制 |
| Usage | FR-37–40 | 真实额度与可归因成本 |
| Search | FR-41–42 | 完整实体/ranking/性能预算 |
| Memory | FR-22–29 | 自动正确提取、authority、期限 |
| Recall | FR-30–32 | 完整排序、未来实际消费 |
| Checkpoint | FR-33–34 | 新Agent实际恢复 |
| MCP | FR-35–36 | 三个真实Harness注册/消费 |
| Improve | FR-43–48 | 高精度全例、规划/候选到Lab |
| Evidence | FR-78 | Adoption/Future Session/Outcome边 |
| Safe Apply | FR-49–50 | 完整故障/并发恢复矩阵 |
| Workflow | FR-51–57/64–67 | 真实重复过程发现/feedback改善 |
| Dry Run | FR-58 | 受支持工具已测；新增工具必复验 |
| Approval | FR-59–60 | 受支持冻结执行已测；完整edit/external范围不足 |
| Run Ledger | FR-61–62 | 实际Memory/model/usage/feedback |
| Health | FR-63 | 完整指标和可追溯Workflow Diff |
| Lab | FR-70–76 | 同task/model真实Agent执行、多维指标 |
| Regression | FR-77 | 触发控制实验、退化拒绝、未来RFR |

官网/原创图标/音效/开源交付另受 R-19/20 与 WEB/REL 原需求约束；E-WEB/E-UI/E-PKG 仅证明各自交付。客户端新 Blume 参考与官网已发布 px0 方向见 [原则](PRODUCT_PRINCIPLES.md#三个参考项目如何影响-vela)，视觉验收不与业务闭环合并。

## 更新责任

实现作者补 Code/Test；复验者补确切版本、原始结果与受限结论；产品验收者核对 Goal/Req/Design 和缺口。每次改动只升级受该证据覆盖的行。引用新的测试总数不能批量将整表标完成；任何新消费/执行路径都必须重新验证 scope/private/approval 与六 Gate 的受影响部分。

### 本轮工作树增量

基线表保留 preview.2 历史，不表示后续补丁不存在。2026-09-12 的 [ImproveAcceptanceTests](../Tests/VelaCoreTests/ImproveAcceptanceTests.swift) 九项方法已单独通过当次 portable 执行：五 Session 明确纠错、精确 Candidate 来源和状态保留、13 类 near-miss、跨项目/旧信号/缺消息拒绝、真实 Codex JSONL 摄取后的三 Session 顺序检测、伪工具/错误顺序/错误目录拒绝、重复消息/源编辑不增证据、复制日志不增加 Session/Memory 数、安全 snapshot 的祖先 symlink/2 MiB 反例。

对应 `FR-22/43/46/47/52` 的窄项实现已补入 `ImproveService.swift`，`FR-49/NFR-16/17` 增加 internal `SafeApplyService.readSnapshot` 的读取边界。尚未建立总体 precision、三个 provider 的完整 procedure 支持或真实用户未来改善。该次 **81 方法中的三个新 Lab 执行场景失败**，暴露 Agent 配置标量 JSON 构造错误；只有 78 项通过，不将其记成一次完整成功套件。后续 [AgentLabIntegrityTests](../Tests/VelaCoreTests/AgentLabIntegrityTests.swift) 增加构造测试，统一复验结果待补。

2026-09-13 更新：上述配置编码错误修正后，已有 **90 方法的中间 portable 快照通过**；之后新增 Reuse provider/复制关联反例、复合命令计量与旧结果刷新检查。最终套件结果尚待补，不用中间总数替代当前工作树验收。

| 本轮 Goal → Req / Design | Code → Test → Evidence | 实现和验收边界 |
| --- | --- | --- |
| G-MEM/G-IMP → R-05/09/10，D-05/09/10 | C-IMP/C-MEM → T-IMP2 → 九项已执行专项记录 | 明确约束提 Candidate 与严格工程纠错/程序检测已补窄项；GS07–10 整链仍 Not Run |
| G-VER → R-15/16，D-15/16；FR-70–75 | C-AGENT → T-AGENT → E-LIVE | Codex Agent 对照已执行；计分更正后 Inconclusive，task/test 指标未改善，Corrections 未测；不能继续写成“完全没有 Agent Lab”，也不能称 Verify 产品完成 |
| G-VER/G-MEM → R-17，D-17；FR-76/78 | C-REUSE → T-AGENT/T-REUSE → E-LIVE（拒绝晋升） | 仅可将评估的同项目 Memory-only Context 以事务激活；实际同分候选被拒绝；正向真实 Promote→后续采用仍缺证 |
| G-MEM → R-07/17，D-07/17；FR-30/78 | C-REUSE → T-REUSE → 当前核心测试 support | 项目 Codex Hook 预览、受审写入与 provenance receipt 已有；provider+ID 关联补丁待最终测试；Hook stdout 不证明 Agent 采用 |
| G-OBS → R-08/18，D-08/18；FR-37/NFR-14 | C-OBS → T-USAGE → E-USAGE | nullable total 与可证 observed 子集、整数溢出拒绝已补；账户 quota/成本仍 Missing |
| G-OBS → R-19，D-19；NFR-01–06 | C-STORE/C-OBS → T-PERF → E-PERF2 | 旧搜索超标场景已修；未测冷启动/长期/五 Agent 并发/事件显示分布，完整 Performance Gate 仍 Not Run |

源记录、候选与实验之间有新增边，不代表已经存在同一次 `Session → Candidate → Suggestion → Eval → Promotion → New Session → Outcome` 完整证据。当前可定位的下一步是最终 scorer/旧结果/范围反例、真实 Codex Hook 信任与消费、适用未来 Session 覆盖与 RFR；没有这些数据时 Scorecard 保持 Not Scored。

### 最终核心回归快照（2026-09-13）

`swift build` 与 portable runner **93/93 方法通过**，包含 Reuse provider/复制索引关联、复合脚本语法失败未知值、旧评测所有读接口重算及拒绝晋升。核心使用 `codex-test-observation-v3`；`originalGitStatusUnchanged` 只声明 Git 状态相同，文件内容等价未测。真实 RPC/MCP 与无换行巨帧恢复通过。UI、原生包和 hosted XCTest 结果独立记录，整体 Golden/Hard Gate 仍未通过。
