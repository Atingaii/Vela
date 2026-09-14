# 最终规格初步源码筛查（2026-09-14）

> **状态：初步源码筛查，不是最终逐项行为验收、发布门禁或产品完成声明。**

审计基线：28e873259f6bc21b93c0cead41f097a2b23165a3。本文件把附件编号需求与当前静态源码、228 项参考台账、状态文档和已保存的局部证据定位；不以函数、测试数量或局部回归推导整条规格完成。机器可读版本见 [JSON](final-spec-2026-09-14.json)。

## 规格解释与范围

附件编号 1–186 是产品要求；187–188 仅保留聚合定位。附件中已经全部包含、能力超过、应直接冻结等结论、参考产品推断、链接和推进建议属于助手元话语，不作为用户验收事实或实现证据。

附件没有跨窗口独立条目：128 是 MCP Server；135 Menu Bar、185 最终一级产品导航、186 全局入口才与窗口级或全局入口直接相关。因此不会把 MCP 后端能力写成跨窗口 UI 已验。

## 状态口径

| 状态 | 数量 | 本次筛查含义 |
| --- | ---: | --- |
| 部分实现 | 132 | 存在明确子路径，完整要求仍未关闭。 |
| 缺失 | 26 | 未定位到对应完整产品路径。 |
| 后端有证据 | 21 | 受限 Core/RPC 有实现或既有证据，不表示 UI、原生或整条完成。 |
| 外部未验 | 6 | 隔离 SDK/模拟路径存在，但缺真实外部正向验收。 |
| 范围/翻译 | 3 | 定位或翻译项，非可独立关闭产品能力。 |

## 当前优先项：原文检查点与源码筛查

下表逐项写出附件原文检查点、已定位实现与明确缺口。已见实现不等于该行通过；原生列不把浏览器切片升级为原生全流程。

| # | 原文检查点 | 已定位实现与锚点 | 明确未实现或未验 |
| ---: | --- | --- | --- |
| 1 | 运行/审批/失败 Agent；项目/会话/今日数；三家 usage；Memory/Conflict/Improve；Workflow/Lab/Regression/Artifact/MCP/worker/activity；New Workflow/Search/Ask/Open Project/Resume/Run/Checkpoint/Evaluation/Doctor。 | dashboard.get 返回 projects、sessions、memories、workflows、runs、suggestions、approvals、evals、artifacts、library；renderer 有页内导航。<br>FoundationService.swift:49-66（聚合但 stats 仅四项）；109-119（liveStatusAvailable=false）；app.js:781-787、1134-1173。 | 缺统一活动时间线、今日 session、分类聚合、Memory conflict、回归/MCP/worker/background 状态和除 Search 外的完整快捷闭环。<br>原生：无 Home 全量字段及十个快捷操作的独立原生验收。 |
| 17 | Repository Tree；Open File；Recent/Changed/Agent Modified Files；Git Diff；轻量只读非 IDE。 | 未发现 repository reader；会话历史或原文查看不是工程阅读器。<br>全仓未见 repository tree、受控文件 open、recent/changed/agent-modified 文件或 workspace reader 服务；app.js:1134-1173 只是产品页路由。 | 需实现只读 tree/file/recent/changed/Git diff/agent-modified，并验收私有库、符号链接、超大仓库分页与零写入。<br>原生：无原生阅读器验收。 |
| 18 | Fuzzy/文件内/工作区/Regex/Symbol 搜索；Outline；Definition/References/Hover；Jump line/Back/Forward；通过 LSP。 | 未见以 LSP 驱动的代码导航或工作区检索。<br>未定位 workspace/regex/symbol search、outline、definition/reference/hover 或 LSP client；MemoryService.swift:93-96 的 search 是记忆/资料搜索。 | 需定义项目根、server 生命周期、取消/限额与结果版本；所有列举导航路径缺失。<br>原生：无原生导航验收。 |
| 19 | TypeScript/JavaScript、Go、Rust、Python、C/C++、Java、Kotlin、Swift、其他标准 LSP。 | 未见标准 LSP transport、language server 发现/启动或诊断协议。<br>全仓未见 typescript-language-server、gopls、rust-analyzer、pyright、clangd、jdtls 或 JSON-RPC LSP 客户端。 | 八类语言和其他标准 LSP 均需实现可用性、超时、崩溃恢复与诊断版本契约。<br>原生：无原生 LSP 验收。 |
| 20 | Syntax Highlight；Line Numbers；Large File Virtualization/Lazy Highlighting；Wrap；Selection/Copy；Diff/Search Highlight；Diagnostics；read-only。 | 未见面向工程文件的 read-only Code Viewer；history raw event viewer 不等同代码视图。<br>app.js:2466-2472 只打开 history raw event；未定位 syntax highlighter、virtualization、diagnostic overlay 或文件 diff component。 | 缺所有列出的 viewer 能力及零编辑写入验证。<br>原生：无原生 Code Viewer 验收。 |
| 21 | AGENTS/CLAUDE/Cursor Rules/Instructions/Skills/Hooks/MCP/Configs/Guidelines/Memory/Reference Docs。 | 固定 catalog 的公开、只读、受限扫描覆盖部分 instruction/rule/skill/hook/MCP/config。<br>SetupCatalog.swift:24-57（项目路径）、60-80（全局路径）、83-100（限制）；SetupInventoryService.swift:79-179（上限、脱敏、私有边界）。 | Guideline、Memory、Reference Docs 不在同一扫描模型；自定义 import/plugin、实际 provider load/override、凭据混合内容明确未覆盖。<br>原生：无完整原生 Setup Inventory 验收。 |
| 22 | Rule/Instruction/Skill/Hook/MCP/Config/Guideline/Memory/Reference/Workflow；id/type/name/provider/scope/sourcePath/runtimePath/content/version/hash/enabled/timestamps/relationships/diagnostics/contextCost。 | setup artifact 有观测记录；Memory/Workflow 等仍是独立模型，未统一为完整 Artifact。<br>SetupInventoryService.swift:140-179；MemoryService.swift:9-12、37-76。 | 缺统一 runtimePath/enabled/relationships/contextCost、跨类型 version/timestamps，也未证明 Workflow/Guideline/Reference 均进同一 schema。<br>原生：无统一 Artifact 原生验收。 |
| 23 | Global/User/Project/Repository/Workspace/Branch/Worktree/Task/Session。 | Setup artifact 只有 global/project；Memory 有部分项目内 scope，未构成统一 Artifact Scope。<br>SetupInventoryService.swift:53-71；MemoryService.swift:9、45-55。 | 缺 User/Workspace，Repository/Branch/Worktree/Task/Session 没被 Setup Artifact 承载，且无 precedence/继承契约。<br>原生：无跨 Scope 原生验收。 |
| 24 | references/imports/depends_on/conflicts_with/duplicates/supersedes/derived_from/validated_by/applies_to/used_by。 | 只推导三类同 scope 观测关系，且明确不推断 runtime merge。<br>SetupInventoryService.swift:227-240（identical_observed_bytes、same_declared_skill_name、documented_same_directory_override）。 | 缺十类完整关系、统一图查询与运行时图谱；字节相同不是语义 duplicates。<br>原生：无关系图谱原生验收。 |
| 25 | 每 Artifact 的 Claude/Codex/Cursor 覆盖和 Provider Drift。 | 没有 Artifact × Provider coverage 或 drift 结果。<br>SetupCatalog.swift:98-102（runtimeLoadedState=unavailable）；SetupInventoryService.swift:239（不推断 runtime merge）。 | 不能用发现文件代替实际 provider 载入；缺 coverage grid、unknown 和变更重算。<br>原生：无原生 coverage/drift 验收。 |
| 26 | 附件列出的 Rule/Skill/Hook/MCP/Provider/Repo/Command/Context/Memory/Permission 共 22 类自动审计。 | 有不可读、无效 JSON、重复字节、超大文本等有限诊断，不是 Setup Audit 全集。<br>SetupInventoryService.swift:95-123、155-179、242-272。 | 缺 conflict/contradictory/stale/broken/missing/path/package manager、dead/unused skill/hook、MCP drift/repo mismatch/stale unsafe command、memory conflict、verification/permission 等分析器。<br>原生：无完整原生 audit 验收。 |
| 27 | Title/Category/Severity/Affected Artifact/Evidence/Reason/Harness Applicability/Suggested Fix/Confidence；Preview/Fix/Ignore/Suppress/Dismiss/Open File。 | diagnostics 是嵌入 artifact 的简化 JSON，不是 Audit Finding 实体。<br>SetupInventoryService.swift:154-167、179 仅 code/severity/path/message。 | 缺完整 schema 和七项操作，尤其没有安全 Fix 与 Safe Apply 关联。<br>原生：无 finding 列表或操作原生验收。 |
| 28 | findingKey/artifactHash/suppressedAt/reason；相关 Artifact 改变才重新报告。 | 未见 finding suppression 持久化或重报状态机。<br>SetupInventoryService.swift:182-202 仅观测 revision；全仓未定位 findingKey suppression store/route。 | 需精确 suppression 记录、相关 hash 才 re-emit、跨重启和无关变更反例。<br>原生：无原生 suppression 验收。 |
| 29 | Always-on/Conditional/On-demand/Zero-context tokens；Token contribution；total percent。 | setup 和 memory 有静态 tokenEstimate，不是 context cost 归因。<br>SetupInventoryService.swift:149-158；MemoryService.swift:58。 | 缺四类成本、贡献和百分比；估算不等于实际加载成本。<br>原生：无 Context Cost 原生验收。 |
| 30 | Harness/Project/Artifact Type 预算；warning/largest/removals/unused/duplicate。 | 未见按 Harness/Project/Artifact Type 的 context budget 服务。<br>SetupInventoryService.swift:157 仅单件 large-context warning。 | 缺预算来源/未知值、warning、largest/removals/unused/duplicate 的可验证输出。<br>原生：无 budget 原生验收。 |
| 31 | Deterministic Hook、Workflow、Reference、Guideline、Skill、Always-on Rule；避免永久 Token Tax。 | 未见 Hook 到 Always-on Rule 的 planner 成本阶梯。<br>全仓未定位 context cost ladder 或 workflow planner 排序。 | 缺选路、降级、must-keep 条件与避免永久 token tax 的行为反例。<br>原生：无 Planner 原生验收。 |
| 32 | Version 1/2/3；beforeHash/afterHash/patch/source/reason/timestamp。 | setup 有只读观测 revision/history/diff，不是所有配置资产的版本系统。<br>SetupInventoryService.swift:33-43、182-224；179 明示 historyFullyObserved=false。 | 缺全类型 history 和 required 字段组合；diff 明示非 apply patch。<br>原生：无全部 Artifact 原生历史验收。 |
| 33 | Read Current/Resolve realpath/Verify base hash/Validate permission/Staging/fsync/Atomic rename/Record version；多文件 all-or-nothing。 | 受限 Core 安全写入有跨进程锁、路径/身份验证、baseHash 重查、stage fsync、rename、journal/rollback。<br>SafeApply.swift:48-77、123-141、179-235、239-280。 | 尚未证明所有 Agent/Workflow 提议只能经此入口；缺权限 UX、journal 版本可见性、崩溃恢复和各 proposal 端到端验收。<br>原生：无所有 Agent proposal 的完整原生 Safe Apply 验收。 |
| 34 | currentHash == expectedPostApplyHash 才 Undo；否则 needs review。 | undo 用 prior afterHash 作为下一次 apply baseHash，外部改动时拒绝覆盖。<br>SafeApply.swift:80-94、211-227、281-289。 | 缺 needs-review UI/人工恢复路径和各 proposal journal 接入验证。<br>原生：无 Safe Undo 原生用户流程验收。 |
| 128 | search/recall_memory/remember/get memory/session/checkpoint/project/setup/artifact/list-get-run workflow/get run-suggestion-eval/library_search。 | 存在静态 schema 的 stdio MCP、read/contribute 模式、项目注册和 fresh/private gate；与原始工具清单不同。<br>MCPTools.swift:4-6、130-199；MCPToolAccess.swift:13-57、154-211。 | 缺 get_session/project/setup/artifact/run/suggestion/eval、run_workflow 等完整清单；缺 READ/CONTRIBUTE/EXECUTE/ADMIN 四层逐项行为。<br>原生：无第 128 项全工具集或跨窗口原生验收；MCP 不是 Menu Bar。 |
| 135 | Running Agents/Needs Approval/Failed Runs/Usage/Workflow Runs；Open/Search/Ask/Show Agents/Pause/Settings/Quit。 | 原生 status item 显示 running/approval，并有 Open/Inbox/Refresh/Quit；非完整菜单栏控制面。<br>main.swift:516-580、582-590、536-546；FoundationService.swift:49-66 未给 failed/usage/workflow-run status 聚合。 | 缺 Failed Runs/Usage/Workflow Runs；缺 Search/Ask/Show Agents/Pause Monitoring/Settings status 快捷项。<br>原生：无全部菜单项与动态状态的独立原生验收。 |
| 185 | Home；WORK；KNOWLEDGE；AUTOMATION；INTELLIGENCE；OBSERVABILITY；SYSTEM 下列全部一级项目。 | renderer/原生 View menu 只有 agents/workflows/setup/usage/improve/lab 六页，并有 scope guard。<br>app.js:1122-1173；main.swift:695-724。 | 缺 Home、Sessions、Projects、Code、Memory、Library、Runs、Activity、Reports、Inbox、Connections、Doctor 等完整结构。<br>原生：无附件完整一级导航的原生验收。 |
| 186 | Cmd+K；Search；Ask Vela；Commands。 | 窗口内 Cmd/Ctrl+K 和原生 View Search 会触发 Search modal。<br>app.js:790-829；main.swift:718-721、900-911。 | Ask Vela/Commands 未见同一 palette；缺无窗口唤醒、scope、键盘/读屏和 action 不误执行验证。<br>原生：仅有 renderer Search/Actions 切片；无 Search+Ask+Commands 跨窗口原生验收。 |

## Walrus / Memory Space 抽样复核

- MemoryIntegrationService 要求已注册 project 和显式 namespace，并明确 namespaceIsRemoteACL=false；它是本地范围选择，不是远程授权。见 MemoryIntegrationService.swift:4-14、63-68。
- sdk/walrus 的 RemoteProfile 绑定 expectedOwner 和 namespace，manifest 与 profile 严格匹配；owner 模块可构造并核验 add/remove delegate 的冻结交易。见 sdk/walrus/src/index.ts:11-23、54-76、167-176，manifest.ts:53-60，owner.ts:5-38。
- docs/status.md:20 明确保留真实加密写入/恢复和 owner/delegate 链上提交的缺口。因此 41–43 调整为外部未验，不写成完全缺失，也不写成已交付。

## 逐项追踪矩阵（其余行为仍为粗筛）

除上一节优先项外，本表保留初步定位。大量行尚复用同类源锚点，后续必须以逐条公开 API、renderer/WKWebView 和失败反例重新验收；相同锚点绝不表示这些行完成。

| # | 规格 | 当前判定 | 源码/证据锚点 | 原生验证 | 尚缺闭环 |
| ---: | --- | --- | --- | --- | --- |
| 1 | Home / Mission Control | 部分实现：dashboard.get 返回 projects、sessions、memories、workflows、runs、suggestions、approvals、evals、artifacts、library；renderer 有页内导航。 | FoundationService.swift:49-66（聚合但 stats 仅四项）；109-119（liveStatusAvailable=false）；app.js:781-787、1134-1173。 | 无 Home 全量字段及十个快捷操作的独立原生验收。 | 缺统一活动时间线、今日 session、分类聚合、Memory conflict、回归/MCP/worker/background 状态和除 Search 外的完整快捷闭环。 |
| 2 | Harness / Agent Platform | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | SessionEngine.swift:27; SessionHistoryService.swift:6; FoundationService.swift:78; status §会话观察 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 3 | Agent Monitor | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | SessionEngine.swift:27; SessionHistoryService.swift:6; FoundationService.swift:78; status §会话观察 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 4 | Subagent / Agent Tree | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | SessionEngine.swift:27; SessionHistoryService.swift:6; FoundationService.swift:78; status §会话观察 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 5 | Session Discovery | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | SessionEngine.swift:27; SessionHistoryService.swift:6; FoundationService.swift:78; status §会话观察 | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 6 | Unified Session Model | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | SessionEngine.swift:27; SessionHistoryService.swift:6; FoundationService.swift:78; status §会话观察 | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 7 | Session Timeline | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | SessionEngine.swift:27; SessionHistoryService.swift:6; FoundationService.swift:78; status §会话观察 | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 8 | Session Detail | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | SessionEngine.swift:27; SessionHistoryService.swift:6; FoundationService.swift:78; status §会话观察 | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 9 | Large Session Support | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | SessionEngine.swift:27; SessionHistoryService.swift:6; FoundationService.swift:78; status §会话观察 | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 10 | Session Recovery | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | SessionEngine.swift:27; SessionHistoryService.swift:6; FoundationService.swift:78; status §会话观察 | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 11 | Parser Versioning | 缺失：未实现为完整产品能力 | SessionEngine.swift:27; SessionHistoryService.swift:6; FoundationService.swift:78; status §会话观察 | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 12 | Self-run Isolation | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | SessionEngine.swift:27; SessionHistoryService.swift:6; FoundationService.swift:78; status §会话观察 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 13 | Projects | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | FoundationService.swift:49; IngestionExclusionService.swift:3; Store.swift:874 | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 14 | Workspace / Worktree | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | FoundationService.swift:49; IngestionExclusionService.swift:3; Store.swift:874 | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 15 | Project Exclusion | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | FoundationService.swift:49; IngestionExclusionService.swift:3; Store.swift:874 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 16 | Git Intelligence | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | FoundationService.swift:49; IngestionExclusionService.swift:3; Store.swift:874 | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 17 | Read / Review Workspace | 缺失：未发现 repository reader；会话历史或原文查看不是工程阅读器。 | 全仓未见 repository tree、受控文件 open、recent/changed/agent-modified 文件或 workspace reader 服务；app.js:1134-1173 只是产品页路由。 | 无原生阅读器验收。 | 需实现只读 tree/file/recent/changed/Git diff/agent-modified，并验收私有库、符号链接、超大仓库分页与零写入。 |
| 18 | Code Navigation | 缺失：未见以 LSP 驱动的代码导航或工作区检索。 | 未定位 workspace/regex/symbol search、outline、definition/reference/hover 或 LSP client；MemoryService.swift:93-96 的 search 是记忆/资料搜索。 | 无原生导航验收。 | 需定义项目根、server 生命周期、取消/限额与结果版本；所有列举导航路径缺失。 |
| 19 | LSP | 缺失：未见标准 LSP transport、language server 发现/启动或诊断协议。 | 全仓未见 typescript-language-server、gopls、rust-analyzer、pyright、clangd、jdtls 或 JSON-RPC LSP 客户端。 | 无原生 LSP 验收。 | 八类语言和其他标准 LSP 均需实现可用性、超时、崩溃恢复与诊断版本契约。 |
| 20 | Code Viewer | 缺失：未见面向工程文件的 read-only Code Viewer；history raw event viewer 不等同代码视图。 | app.js:2466-2472 只打开 history raw event；未定位 syntax highlighter、virtualization、diagnostic overlay 或文件 diff component。 | 无原生 Code Viewer 验收。 | 缺所有列出的 viewer 能力及零编辑写入验证。 |
| 21 | Setup / Context Inventory | 部分实现：固定 catalog 的公开、只读、受限扫描覆盖部分 instruction/rule/skill/hook/MCP/config。 | SetupCatalog.swift:24-57（项目路径）、60-80（全局路径）、83-100（限制）；SetupInventoryService.swift:79-179（上限、脱敏、私有边界）。 | 无完整原生 Setup Inventory 验收。 | Guideline、Memory、Reference Docs 不在同一扫描模型；自定义 import/plugin、实际 provider load/override、凭据混合内容明确未覆盖。 |
| 22 | Artifact Model | 部分实现：setup artifact 有观测记录；Memory/Workflow 等仍是独立模型，未统一为完整 Artifact。 | SetupInventoryService.swift:140-179；MemoryService.swift:9-12、37-76。 | 无统一 Artifact 原生验收。 | 缺统一 runtimePath/enabled/relationships/contextCost、跨类型 version/timestamps，也未证明 Workflow/Guideline/Reference 均进同一 schema。 |
| 23 | Artifact Scope | 部分实现：Setup artifact 只有 global/project；Memory 有部分项目内 scope，未构成统一 Artifact Scope。 | SetupInventoryService.swift:53-71；MemoryService.swift:9、45-55。 | 无跨 Scope 原生验收。 | 缺 User/Workspace，Repository/Branch/Worktree/Task/Session 没被 Setup Artifact 承载，且无 precedence/继承契约。 |
| 24 | Artifact Relationship Graph | 部分实现：只推导三类同 scope 观测关系，且明确不推断 runtime merge。 | SetupInventoryService.swift:227-240（identical_observed_bytes、same_declared_skill_name、documented_same_directory_override）。 | 无关系图谱原生验收。 | 缺十类完整关系、统一图查询与运行时图谱；字节相同不是语义 duplicates。 |
| 25 | Context Coverage | 缺失：没有 Artifact × Provider coverage 或 drift 结果。 | SetupCatalog.swift:98-102（runtimeLoadedState=unavailable）；SetupInventoryService.swift:239（不推断 runtime merge）。 | 无原生 coverage/drift 验收。 | 不能用发现文件代替实际 provider 载入；缺 coverage grid、unknown 和变更重算。 |
| 26 | Setup Audit | 部分实现：有不可读、无效 JSON、重复字节、超大文本等有限诊断，不是 Setup Audit 全集。 | SetupInventoryService.swift:95-123、155-179、242-272。 | 无完整原生 audit 验收。 | 缺 conflict/contradictory/stale/broken/missing/path/package manager、dead/unused skill/hook、MCP drift/repo mismatch/stale unsafe command、memory conflict、verification/permission 等分析器。 |
| 27 | Audit Finding | 部分实现：diagnostics 是嵌入 artifact 的简化 JSON，不是 Audit Finding 实体。 | SetupInventoryService.swift:154-167、179 仅 code/severity/path/message。 | 无 finding 列表或操作原生验收。 | 缺完整 schema 和七项操作，尤其没有安全 Fix 与 Safe Apply 关联。 |
| 28 | Audit Suppression | 缺失：未见 finding suppression 持久化或重报状态机。 | SetupInventoryService.swift:182-202 仅观测 revision；全仓未定位 findingKey suppression store/route。 | 无原生 suppression 验收。 | 需精确 suppression 记录、相关 hash 才 re-emit、跨重启和无关变更反例。 |
| 29 | Context Cost | 部分实现：setup 和 memory 有静态 tokenEstimate，不是 context cost 归因。 | SetupInventoryService.swift:149-158；MemoryService.swift:58。 | 无 Context Cost 原生验收。 | 缺四类成本、贡献和百分比；估算不等于实际加载成本。 |
| 30 | Context Budget | 缺失：未见按 Harness/Project/Artifact Type 的 context budget 服务。 | SetupInventoryService.swift:157 仅单件 large-context warning。 | 无 budget 原生验收。 | 缺预算来源/未知值、warning、largest/removals/unused/duplicate 的可验证输出。 |
| 31 | Context Cost Ladder | 缺失：未见 Hook 到 Always-on Rule 的 planner 成本阶梯。 | 全仓未定位 context cost ladder 或 workflow planner 排序。 | 无 Planner 原生验收。 | 缺选路、降级、must-keep 条件与避免永久 token tax 的行为反例。 |
| 32 | Artifact Version History | 部分实现：setup 有只读观测 revision/history/diff，不是所有配置资产的版本系统。 | SetupInventoryService.swift:33-43、182-224；179 明示 historyFullyObserved=false。 | 无全部 Artifact 原生历史验收。 | 缺全类型 history 和 required 字段组合；diff 明示非 apply patch。 |
| 33 | Safe Apply | 后端有证据：受限 Core 安全写入有跨进程锁、路径/身份验证、baseHash 重查、stage fsync、rename、journal/rollback。 | SafeApply.swift:48-77、123-141、179-235、239-280。 | 无所有 Agent proposal 的完整原生 Safe Apply 验收。 | 尚未证明所有 Agent/Workflow 提议只能经此入口；缺权限 UX、journal 版本可见性、崩溃恢复和各 proposal 端到端验收。 |
| 34 | Safe Undo | 后端有证据：undo 用 prior afterHash 作为下一次 apply baseHash，外部改动时拒绝覆盖。 | SafeApply.swift:80-94、211-227、281-289。 | 无 Safe Undo 原生用户流程验收。 | 缺 needs-review UI/人工恢复路径和各 proposal journal 接入验证。 |
| 35 | Memory Engine | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 36 | Memory Operations | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 37 | Automatic Memory Extraction | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | limited: UI19 Capture 的候选/来源旅程；不覆盖该完整条目 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 38 | Memory State | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | limited: UI19 Capture 的候选/来源旅程；不覆盖该完整条目 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 39 | Memory Authority | 缺失：未实现为完整产品能力 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 40 | Memory Scope | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 41 | Memory Space | 外部未验：本地 integration 有 project+namespace；可选 Walrus SDK 有 namespace/owner 范围校验，尚非完整 Memory Space。 | MemoryIntegrationService.swift:4-14、63-68；sdk/walrus/src/index.ts:11-23、54-76；sdk/walrus/src/manifest.ts:53-60。 | 无 Memory Space 原生 UI 或真实远程账户验收。 | 本地 namespace 明确 namespaceIsRemoteACL=false；无 Space 生命周期/成员权限，也无真实加密写入/恢复正向证据。 |
| 42 | Memory Ownership | 外部未验：Walrus SDK 有 expectedOwner、owner metadata/manifest/signer 核验；Core 本地 Memory 没有 Owner 模型。 | sdk/walrus/src/index.ts:14、134-139、167-174；metadata.ts:27-48；manifest-reader.ts:16-18。 | 无 owner 账户或链上正向原生验收。 | 真实 owner 创建/绑定/恢复与桌面凭据流未完成；不能把 transaction prepare 写成提交成功。 |
| 43 | Memory Delegates | 外部未验：Walrus SDK 可构造/校验 addDelegate/removeDelegate 交易，未见产品执行。 | sdk/walrus/src/owner.ts:5-38；sdk/walrus/src/index.ts:167-176；docs/status.md:20。 | 无 delegate 原生验收。 | 缺授权 UI、执行/撤销 receipt、链上成功/失败恢复与本地访问控制；预览交易不是授权生效。 |
| 44 | Memory Provenance | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | limited: UI19 Capture 的候选/来源旅程；不覆盖该完整条目 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 45 | Memory Relations | 缺失：未实现为完整产品能力 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 46 | Memory Lifecycle | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 47 | Memory Conflict | 缺失：未实现为完整产品能力 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 48 | Recall Engine | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 49 | Recall Ranking | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 50 | Recall Token Budget | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 51 | Memory Canonical Store | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 52 | Restore / Reindex | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 53 | Local Memory Backend | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 54 | Walrus Memory Backend | 外部未验：可选/模拟或隔离路径存在，真实外部正向行为未证实 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 有可选接口或参考资料，但无独立真实账户/链上正向验收；不得标为可用。 |
| 55 | Self-hosted Memory Backend | 缺失：未实现为完整产品能力 | MemoryService.swift:3,15-94,243; SemanticMemory.swift:65,281; MemoryArchiveService.swift:18-48 | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 56 | Checkpoint | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | Checkpoint/Reuse Core 与 status §Checkpoint / Reuse | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 57 | Checkpoint Trigger | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | Checkpoint/Reuse Core 与 status §Checkpoint / Reuse | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 58 | Handoff | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | Checkpoint/Reuse Core 与 status §Checkpoint / Reuse | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 59 | Native Session Transfer | 缺失：未实现为完整产品能力 | Checkpoint/Reuse Core 与 status §Checkpoint / Reuse | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 60 | Engineering Library | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LibraryService.swift:6-25; LibraryIndex.swift:61-121; status §Library与Ask | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 61 | Library Operations | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LibraryService.swift:6-25; LibraryIndex.swift:61-121; status §Library与Ask | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 62 | Private Library | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LibraryService.swift:6-25; LibraryIndex.swift:61-121; status §Library与Ask | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 63 | Guidelines | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LibraryService.swift:6-25; LibraryIndex.swift:61-121; status §Library与Ask | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 64 | Guideline Operations | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LibraryService.swift:6-25; LibraryIndex.swift:61-121; status §Library与Ask | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 65 | Improve Engine | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | ImproveService.swift; ModelImprovement.swift; RunFeedback.swift:10; status §Improve | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 66 | Signal Types | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | ImproveService.swift; ModelImprovement.swift; RunFeedback.swift:10; status §Improve | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 67 | Behavioral Evidence | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | ImproveService.swift; ModelImprovement.swift; RunFeedback.swift:10; status §Improve | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 68 | Signal Normalization | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | ImproveService.swift; ModelImprovement.swift; RunFeedback.swift:10; status §Improve | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 69 | Signal Clustering | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | ImproveService.swift; ModelImprovement.swift; RunFeedback.swift:10; status §Improve | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 70 | Cluster | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | ImproveService.swift; ModelImprovement.swift; RunFeedback.swift:10; status §Improve | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 71 | Promotion | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | ImproveService.swift; ModelImprovement.swift; RunFeedback.swift:10; status §Improve | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 72 | Improve Planner | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | ImproveService.swift; ModelImprovement.swift; RunFeedback.swift:10; status §Improve | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 73 | Planner Targets | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | ImproveService.swift; ModelImprovement.swift; RunFeedback.swift:10; status §Improve | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 74 | Suggestion | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | ImproveService.swift; ModelImprovement.swift; RunFeedback.swift:10; status §Improve | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 75 | Suggestion Actions | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | ImproveService.swift; ModelImprovement.swift; RunFeedback.swift:10; status §Improve | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 76 | Automatic Workflow Discovery | 缺失：未实现为完整产品能力 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 77 | Workflow Builder | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 78 | Workflow Format | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 79 | Workflow Metadata | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 80 | Workflow Inputs | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 81 | Workflow Steps | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 82 | Workflow Trigger | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 83 | Watch Trigger | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 84 | Scheduler | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 85 | Sleep Recovery | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 86 | Workflow Retry | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 87 | Failure Policy | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 88 | Workflow Notification | 缺失：未实现为完整产品能力 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 89 | Dry Run | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | AutomationService.swift:30-62; WorkflowPlanning.swift:83; WorkflowWatch; SchedulerService.swift:115 | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 90 | Tool Registry | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 91 | Built-in Tools | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 92 | Custom Local Tool | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 93 | Safe argv | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 94 | External Connectors | 外部未验：可选/模拟或隔离路径存在，真实外部正向行为未证实 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 有可选接口或参考资料，但无独立真实账户/链上正向验收；不得标为可用。 |
| 95 | Connector Authentication | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 96 | Tool Capability | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 97 | Unknown Tool | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 98 | Approval Inbox | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 99 | Frozen Action | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 100 | Run Ledger | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 101 | Run Operations | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 102 | Run Why | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 103 | Workflow Health | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | limited: UI20 Health 原生旅程；仅覆盖 Health timeout proposal，不覆盖完整工作流健康规格 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 104 | Workflow Improve | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 105 | Workflow Replay | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | AutomationService.swift:30-121,449; ConnectorService.swift:286; WorkflowHealthProposal.swift:12-15 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 106 | Agent Lab | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LabService.swift:4; WorkflowComposition.swift; status §Lab | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 107 | Baseline vs Candidate | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LabService.swift:4; WorkflowComposition.swift; status §Lab | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 108 | Eval Dataset | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LabService.swift:4; WorkflowComposition.swift; status §Lab | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 109 | Eval Isolation | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | LabService.swift:4; WorkflowComposition.swift; status §Lab | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 110 | Eval Assertions | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LabService.swift:4; WorkflowComposition.swift; status §Lab | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 111 | Eval Metrics | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LabService.swift:4; WorkflowComposition.swift; status §Lab | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 112 | Repeated Evaluation | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LabService.swift:4; WorkflowComposition.swift; status §Lab | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 113 | No Magic Score | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | LabService.swift:4; WorkflowComposition.swift; status §Lab | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 114 | Promote / Reject | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LabService.swift:4; WorkflowComposition.swift; status §Lab | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 115 | Regression Detection | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LabService.swift:4; WorkflowComposition.swift; status §Lab | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 116 | Regression Result | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LabService.swift:4; WorkflowComposition.swift; status §Lab | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 117 | Evidence Graph | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LabService.swift:4; WorkflowComposition.swift; status §Lab | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 118 | Why Everywhere | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | LabService.swift:4; WorkflowComposition.swift; status §Lab | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 119 | Search | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:94; AskRouteService.swift:281; FoundationService.swift:89,120 | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 120 | Search Types | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:94; AskRouteService.swift:281; FoundationService.swift:89,120 | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 121 | Coding-oriented Ranking | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:94; AskRouteService.swift:281; FoundationService.swift:89,120 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 122 | Ask Vela | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:94; AskRouteService.swift:281; FoundationService.swift:89,120 | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 123 | Usage | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:94; AskRouteService.swift:281; FoundationService.swift:89,120 | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 124 | Usage Dimensions | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:94; AskRouteService.swift:281; FoundationService.swift:89,120 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 125 | Background Cost | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:94; AskRouteService.swift:281; FoundationService.swift:89,120 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 126 | Cost Efficiency | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:94; AskRouteService.swift:281; FoundationService.swift:89,120 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 127 | Smart Background Scheduling | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MemoryService.swift:94; AskRouteService.swift:281; FoundationService.swift:89,120 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 128 | MCP Server | 后端有证据：存在静态 schema 的 stdio MCP、read/contribute 模式、项目注册和 fresh/private gate；与原始工具清单不同。 | MCPTools.swift:4-6、130-199；MCPToolAccess.swift:13-57、154-211。 | 无第 128 项全工具集或跨窗口原生验收；MCP 不是 Menu Bar。 | 缺 get_session/project/setup/artifact/run/suggestion/eval、run_workflow 等完整清单；缺 READ/CONTRIBUTE/EXECUTE/ADMIN 四层逐项行为。 |
| 129 | MCP Permission | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MCPTools/MCPToolAccess; status §本地 MCP | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 130 | MCP Contribution | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | MCPTools/MCPToolAccess; status §本地 MCP | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 131 | MCP Execute | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | MCPTools/MCPToolAccess; status §本地 MCP | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 132 | Terminal | 缺失：未实现为完整产品能力 | NotificationPolicy.swift; AutomationProcess.swift; AutomationService.swift:82-98; RunFeedback.swift:10 | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 133 | Terminal Backpressure | 缺失：未实现为完整产品能力 | NotificationPolicy.swift; AutomationProcess.swift; AutomationService.swift:82-98; RunFeedback.swift:10 | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 134 | Environment Sanitization | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | NotificationPolicy.swift; AutomationProcess.swift; AutomationService.swift:82-98; RunFeedback.swift:10 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 135 | Menu Bar | 部分实现：原生 status item 显示 running/approval，并有 Open/Inbox/Refresh/Quit；非完整菜单栏控制面。 | main.swift:516-580、582-590、536-546；FoundationService.swift:49-66 未给 failed/usage/workflow-run status 聚合。 | 无全部菜单项与动态状态的独立原生验收。 | 缺 Failed Runs/Usage/Workflow Runs；缺 Search/Ask/Show Agents/Pause Monitoring/Settings status 快捷项。 |
| 136 | Notifications | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | NotificationPolicy.swift; AutomationProcess.swift; AutomationService.swift:82-98; RunFeedback.swift:10 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 137 | Inbox | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | NotificationPolicy.swift; AutomationProcess.swift; AutomationService.swift:82-98; RunFeedback.swift:10 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 138 | Wrapped / Engineering Review | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | NotificationPolicy.swift; AutomationProcess.swift; AutomationService.swift:82-98; RunFeedback.swift:10 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 139 | Feedback | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | NotificationPolicy.swift; AutomationProcess.swift; AutomationService.swift:82-98; RunFeedback.swift:10 | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 140 | Account | 缺失：未实现为完整产品能力 | StoreBackupService.swift:7; Store.swift; MemoryArchiveService.swift | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 141 | Device Management | 缺失：未实现为完整产品能力 | StoreBackupService.swift:7; Store.swift; MemoryArchiveService.swift | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 142 | Import / Export | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | StoreBackupService.swift:7; Store.swift; MemoryArchiveService.swift | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 143 | Backup | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | StoreBackupService.swift:7; Store.swift; MemoryArchiveService.swift | limited: native backup recovery evidence exists; no full user-facing backup surface | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 144 | Store Layout | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | StoreBackupService.swift:7; Store.swift; MemoryArchiveService.swift | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 145 | SQLite | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | StoreBackupService.swift:7; Store.swift; MemoryArchiveService.swift | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 146 | Storage Port | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | StoreBackupService.swift:7; Store.swift; MemoryArchiveService.swift | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 147 | Canonical vs Derived Data | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | StoreBackupService.swift:7; Store.swift; MemoryArchiveService.swift | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 148 | Doctor | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | VelaCLI/main.swift:146,374-381; VelaApp Resources UI app.js | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 149 | Update | 缺失：未实现为完整产品能力 | VelaCLI/main.swift:146,374-381; VelaApp Resources UI app.js | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 150 | Update Channels | 缺失：未实现为完整产品能力 | VelaCLI/main.swift:146,374-381; VelaApp Resources UI app.js | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 151 | Raycast | 缺失：未实现为完整产品能力 | VelaCLI/main.swift:146,374-381; VelaApp Resources UI app.js | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 152 | Keyboard-first | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | VelaCLI/main.swift:146,374-381; VelaApp Resources UI app.js | limited: UI18 scope/relations or Chrome renderer only; not full native requirement | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 153 | Theme | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | VelaCLI/main.swift:146,374-381; VelaApp Resources UI app.js | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 154 | Security | 范围/翻译：规范范围/定位，不独立实现 | Sources/VelaApp/main.swift bridge allowlist; SafeApply.swift; Connector Keychain path | 未见该完整条目的独立原生验收 | 这是范围聚合/平台翻译项，不是独立可验收功能；需拆成原子能力，Electron 专属安全项应转换为 AppKit/WKWebView 等价边界。 |
| 155 | Typed IPC | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | Sources/VelaApp/main.swift bridge allowlist; SafeApply.swift; Connector Keychain path | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 156 | File Sandbox | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | Sources/VelaApp/main.swift bridge allowlist; SafeApply.swift; Connector Keychain path | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 157 | Prompt Injection Boundary | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | Sources/VelaApp/main.swift bridge allowlist; SafeApply.swift; Connector Keychain path | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 158 | Child Process Security | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | Sources/VelaApp/main.swift bridge allowlist; SafeApply.swift; Connector Keychain path | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 159 | Credential Security | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | Sources/VelaApp/main.swift bridge allowlist; SafeApply.swift; Connector Keychain path | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 160 | Local-first | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | Sources/VelaApp/main.swift bridge allowlist; SafeApply.swift; Connector Keychain path | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 161 | Telemetry | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | Sources/VelaApp/main.swift bridge allowlist; SafeApply.swift; Connector Keychain path | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 162 | Optional Cloud Improve | 缺失：未实现为完整产品能力 | VelaStore/Core service boundaries; Workflow/approval ledgers | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 163 | Optional Model Router | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | VelaStore/Core service boundaries; Workflow/approval ledgers | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 164 | Walrus / Distributed Ownership | 外部未验：可选/模拟或隔离路径存在，真实外部正向行为未证实 | VelaStore/Core service boundaries; Workflow/approval ledgers | 未见该完整条目的独立原生验收 | 有可选接口或参考资料，但无独立真实账户/链上正向验收；不得标为可用。 |
| 165 | Team | 缺失：未实现为完整产品能力 | VelaStore/Core service boundaries; Workflow/approval ledgers | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 166 | Team Conflict Resolution | 缺失：未实现为完整产品能力 | VelaStore/Core service boundaries; Workflow/approval ledgers | 未见该完整条目的独立原生验收 | 当前未找到对应完整产品路径；需先定义可观察输入、产物、拒绝/恢复反例，再实现。 |
| 167 | Domain Model | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | VelaStore/Core service boundaries; Workflow/approval ledgers | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 168 | Search + Recall + Ask 统一 Retrieval Layer | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | VelaStore/Core service boundaries; Workflow/approval ledgers | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 169 | Permissions | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | VelaStore/Core service boundaries; Workflow/approval ledgers | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 170 | Change Ledger | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | VelaStore/Core service boundaries; Workflow/approval ledgers | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 171 | Everything Reversible | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | VelaStore/Core service boundaries; Workflow/approval ledgers | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 172 | Everything Explainable | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | VelaStore/Core service boundaries; Workflow/approval ledgers | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 173 | No Forced Findings | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | VelaStore/Core service boundaries; Workflow/approval ledgers | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 174 | Performance | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | scripts/package-macos.sh; tests and CI evidence; native-resource evidence | limited: 2-minute resource sample; whole-app/long-run criteria未验 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 175 | Worker Architecture | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | scripts/package-macos.sh; tests and CI evidence; native-resource evidence | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 176 | Worker Manager | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | scripts/package-macos.sh; tests and CI evidence; native-resource evidence | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 177 | Background Priorities | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | scripts/package-macos.sh; tests and CI evidence; native-resource evidence | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 178 | Packaging | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | scripts/package-macos.sh; tests and CI evidence; native-resource evidence | CI package/allowlist；非 Developer ID/notarization | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 179 | macOS Distribution | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | scripts/package-macos.sh; tests and CI evidence; native-resource evidence | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 180 | Testing | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | scripts/package-macos.sh; tests and CI evidence; native-resource evidence | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 181 | Harness Fixtures | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | scripts/package-macos.sh; tests and CI evidence; native-resource evidence | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 182 | Security Tests | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | scripts/package-macos.sh; tests and CI evidence; native-resource evidence | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 183 | Database Tests | 后端有证据：受限 Core/RPC 行为已实现并有本机或CI切片证据 | scripts/package-macos.sh; tests and CI evidence; native-resource evidence | 未见该完整条目的独立原生验收 | 已具备受限后端路径与测试/CI证据；仍需按本条所有输入范围及可访问原生入口逐一验收。 |
| 184 | Complete Product Acceptance | 部分实现：部分 Core、RPC、renderer 或隔离证据存在 | scripts/package-macos.sh; tests and CI evidence; native-resource evidence | 未见该完整条目的独立原生验收 | 已有相邻或受限切片，但未覆盖本条列出的全部字段、操作、失败恢复、桌面入口或外部条件。 |
| 185 | 最终一级产品导航 | 部分实现：renderer/原生 View menu 只有 agents/workflows/setup/usage/improve/lab 六页，并有 scope guard。 | app.js:1122-1173；main.swift:695-724。 | 无附件完整一级导航的原生验收。 | 缺 Home、Sessions、Projects、Code、Memory、Library、Runs、Activity、Reports、Inbox、Connections、Doctor 等完整结构。 |
| 186 | 全局入口 | 部分实现：窗口内 Cmd/Ctrl+K 和原生 View Search 会触发 Search modal。 | app.js:790-829；main.swift:718-721、900-911。 | 仅有 renderer Search/Actions 切片；无 Search+Ask+Commands 跨窗口原生验收。 | Ask Vela/Commands 未见同一 palette；缺无窗口唤醒、scope、键盘/读屏和 action 不误执行验证。 |
| 187 | 最终产品核心定义 | 范围/翻译：规范范围/定位，不独立实现 | Sources/VelaApp/Resources/UI/app.js; product navigation and scope text | 未见该完整条目的独立原生验收 | 这是范围聚合/平台翻译项，不是独立可验收功能；需拆成原子能力，Electron 专属安全项应转换为 AppKit/WKWebView 等价边界。 |
| 188 | 产品最终定位 | 范围/翻译：规范范围/定位，不独立实现 | Sources/VelaApp/Resources/UI/app.js; product navigation and scope text | 未见该完整条目的独立原生验收 | 这是范围聚合/平台翻译项，不是独立可验收功能；需拆成原子能力，Electron 专属安全项应转换为 AppKit/WKWebView 等价边界。 |

## 证据与限制

- 本文件是初步源码筛查，非最终逐项行为验收、发布门禁或产品完成声明。
- 函数、测试数量和局部 Chrome/CI 证据不等同整条用户需求完成。
- 原生列只计算相关独立原生路径，renderer/CI 不提升为 WKWebView 已验。
- Walrus 抽样仅证明 SDK/本地范围子能力，真实链上和加密存储正向行为仍未验证。
