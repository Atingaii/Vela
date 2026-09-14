# 三参考产品交付差距与验收出口（2026-09-14）

## 结论

当前分支不能宣称“至少覆盖 Blume、Walrus Memory / MemWal、px0 三个参考项目的完整成品”。现有的 [228 项参考台账](README.md) 与 [188 项最终规格初步筛查](final-spec-2026-09-14.md) 仍分别有大量 `partial`、`missing` 与 `external_unverified`。其中 188 项的分布为：132 项部分实现、26 项缺失、21 项仅后端有证据、6 项外部未验证、3 项范围/翻译；它不是逐项行为验收。

最关键的阻断不是界面数量或总测试数，而是下列四段用户闭环没有取得同一来源、可重放的正向证据：

```text
Observe（观察真实 agent/session）
  → Remember（把可审查记忆交给后续真实会话）
  → Improve（由证据产生、审阅、执行候选改进）
  → Verify / Reuse（同条件对照胜出，并在后续会话观察到效果）
```

[ACCEPTANCE.md](../ACCEPTANCE.md) 已正确将完整产品标为 **No-Go**：20 步 Golden Scenario 未整链通过，六个 Hard Gate 未全部通过，Scorecard 为 Not Scored。本报告只收敛会阻断这一结论的具体交付项，不重新复制 228 行大表。

## 本轮审查边界

- 只读核对：固定台账、当前源码、`status.md`、`verification.md`、Golden r2 证据及本机已下载参考资料；没有运行参考产品、浏览器、provider 或远端账户请求。
- 固定参考证据：
  - **Blume**：已校验的官方 DMG `1.0.74` 与用户提供的三份报告。其私有仓库未取得可读源码（参见 [下载记录](reference-downloads-2026-09-13.json)），因此只能借鉴公开描述和用户报告中可核对的交互，不声称逐行源码对应。
  - **MemWal**：下载记录中相对仓库的 `../Vela-reference-sources/MemWal`，提交 `493c9e66851e1b542ce5f55a547827f64e141c45`，Apache-2.0；未执行。
  - **px0-workflows**：下载记录中相对仓库的 `../Vela-reference-sources/px0-workflows`，提交 `df7e6eba9df7759cb0c924ac84563a7874bfb051`；未执行。没有把后来 IDE 方向的 `px0` 仓库替换进本轮工作流对照。
- 参考交互用于定义输入、输出、权限、失败和验收。可复用的开源代码须遵守其许可证并保留归属；不复制专有源码、私有提示词、商标或资产。

## 三个参考方向的交互映射

| 闭环与交互 | 可借鉴的参考交互证据 | 当前 Vela 可证实的边界 | 交付出口 |
| --- | --- | --- | --- |
| Observe：多个 coding harness 的会话、状态、配置与用量 | Blume 官方资料及 [blume.md](blume.md) 的 `B-01`–`B-15`；其实际源码不可读。px0-workflows 的 `px0/daemon.py`、`status.py`、`tests/test_daemon_logs.py`、`tests/test_watch_triggers.py` 是本地可读的状态/观察参考。 | `FoundationService.agentList` 明确返回 `liveStatusAvailable:false`（`Sources/VelaCore/FoundationService.swift:109-117`）；Setup 扫描明确不执行 provider command/import/hook/MCP，且 `runtimeLoadedState:"unavailable"`（`SetupInventoryService.swift:6,125,143-179`）。 | 对五个声称支持的 harness 分别记录版本、来源发现、运行/未知状态依据、项目/branch/worktree，并以真实 agent session 和重启反例确认；未知必须可见，不能由日志推断替代 live 状态。 |
| Remember：作用域内 recall 被实际送入下一次 agent 输入，且能追溯 | MemWal README “How It Works”；`packages/openclaw-memory-memwal/src/hooks/recall.ts:12-101` 的 `before_prompt_build` 自动召回/注入；`hooks/capture.ts:20-82` 的结束捕获；`packages/sdk/src/ai/middleware.ts:102-207` 的中间件注入与不可信数据边界。 | Vela 有 active-only Recall 与来源约束；`ReuseService.hookContext` 只支持 Codex `SessionStart`，回执写明 `delivery:"provided_to_hook_stdout"`、`agentAdoption:"not_measured"`（`Sources/VelaCore/ReuseService.swift:33-55`），结果页也明确不能得出因果改善（`:90-108`）。 | 先在本地完成按 provider/lifecycle 的明确适配清单与撤销路径；每个支持客户端都要在真实安装、授权后的下一次会话证明 prompt 收到正确项目记忆，private/global/source-excluded 负例不能进入。模型是否遵守仍须单列为行为测量。 |
| Improve：从观察证据形成可审阅候选与安全变更 | px0-workflows 的 `px0/analysis.py`、`improve.py`、`tests/test_analysis.py`、`tests/test_improve.py`、`tests/test_feedback_loops.py`（固定审计键 `PX-HEALTH`）；Blume 的改进建议只以官方/报告描述参照，不能当可读源码。 | Vela 有确定性检测、候选和受限 Apply/Undo；但 Golden GS07/09/10 的现有证据是受控 verification 提醒，不能证明泛化 precision、完整自然语言规划或所有 provider（`ACCEPTANCE.md:21-24`）。 | 建立多项目、跨 provider 的带标签来源集：真阳性、near miss、重复记录、私有/撤销来源、建议被拒绝/应用/undo。只有候选的 source/message/tool ID、hash 和安全写入 journal 同时可查，才关闭这一段。 |
| Verify / Reuse：baseline/candidate 同条件对照、拒绝劣化、只在正向门槛达标时推广 | px0-workflows 的 `px0/workflow.py`、`runner.py`、`approvals.py`、`runs.py` 与 `tests/test_approvals.py`、`tests/test_failure_path.py`、`tests/test_sync_and_pipelines.py`（`PX-RUN`、`PX-APPROVAL`）；MemWal 的 `owner + namespace`/restore 语义作为跨会话/跨设备边界参考。 | Agent Lab 能冻结 task、模型、commit、verifier 与审批；Golden r2 实际完成 3/3 对 3/3，但 candidate token 平均为 baseline 的约 1.2734 倍且有 observation unavailable，因此 `lab.promote` **Reject**，不是正向效益（`ACCEPTANCE.md:35-40`）。 | 使用同一 Observe 来源自动形成的 candidate，预先冻结任务、模型、预算、verifier、样本数与 promotion 阈值，运行足够独立重复后保存全部 receipt。劣化/未知必须拒绝；只有正向成功才可进入后续会话效果测量。 |

## 阻断完整交付的优先项

### P0-1：同一真实来源的正向 Golden 闭环尚不存在

- **现状与源码/证据**：Golden 步骤 GS01–20 仍以 `Partial; Not Run` 为基线；r2 证明了拒绝门禁，而不是有效候选的 Promote 或未来改善（[ACCEPTANCE.md](../ACCEPTANCE.md):21-24、35-40、62-114）。`ReuseService` 仅记录“已提供”上下文，明确不测 agent adoption（`Sources/VelaCore/ReuseService.swift:53,90-108`）。
- **参考对照**：px0 的可读路径将 workflow run、approval、memory/retrieval 分开保留在 `px0/workflow.py`、`px0/runner.py`、`px0/approvals.py`、`px0/brain.py`；MemWal 的自动 recall hook 则是每回合前的实际注入路径。两者都不能替代 Vela 自己的质量证据。
- **可本地补全**：实现一个不可手填 candidate 的 Golden harness：监听真实 session 记录、固定 source ID/hash、自动产出候选、冻结实验，再生成全链 receipt；先以本地可控 CLI/fixture 验证状态机、拒绝和清理。
- **需外部条件**：真实 Codex 或受支持 provider 登录、可归档的原始会话及会产生可测改善的任务。不能用合成 JSONL 或手工 Candidate 代替。
- **验收**：同一 run 证明 GS01–20 每步输入、对象 ID、审批、原始结果、verifier 与 cleanup；成功候选至少一次满足预冻 promotion 门槛，并在后续真实会话中只报告“提供/观察到的行为”，不把相关性写成因果。

### P0-2：多 harness 的真实 Observe 与配置治理未闭合

- **现状与源码/证据**：`FoundationService.agentList` 将运行状态明确标为不可用；Usage 也说明仅是 selected indexed logs（`FoundationService.swift:109-117,120-156`）。`SetupInventoryService` 是固定公开位置、有限大小、脱敏的只读库存，且声明 `runtimeLoadedState:"unavailable"` 和不推断 provider precedence（`SetupInventoryService.swift:6,125,143-179,227-240`）。最终规格中 1–10、21–32 均为部分或缺失，尤其 Setup 25–31 是缺失。
- **参考对照**：Blume 的公开方向是 agent 状态/配置总览；px0 的 daemon/watch 源码提供可审阅的状态与失效路径例子。Blume 私有实现未知，不能假定其轮询、进程判定或覆盖规则。
- **可本地补全**：为已有五 provider 先定义版本化适配契约、每种状态的证据等级和可恢复错误；增加真实进程存在/退出、来源轮转、项目/branch/worktree 分离与 Setup 不执行副作用的回归。
- **需外部条件**：五个实际安装的 harness、各自真实配置/登录状态和 macOS 权限环境；这些不能由测试 fixture 证明。
- **验收**：每个 provider 在“发现、活跃/未知、退出、来源不可读、配置覆盖不明”下均有同一张观察收据。若无法确认，UI/RPC 必须返回 unknown/unavailable，而非 `Running` 或完整覆盖。

### P0-3：后续会话的记忆消费只对有限路径有“提供”证据

- **现状与源码/证据**：`MemoryService.recall`、`SemanticMemory.recall` 是本地 retrieval；`ReuseService` 的安装目标仅为项目 `.codex/hooks.json` 的 `SessionStart`（`Sources/VelaCore/ReuseService.swift:4-33`）。该服务显式写出 provider trust 未绕过、stdout 回执不证明遵循（`:29,53,90-108`）。最终规格 Memory 35–50 均为 partial/missing，44 的 provenance 也尚未覆盖所有消费面。
- **参考对照**：MemWal `before_prompt_build` 以 session-derived namespace 查询并追加系统上下文；其代码也处理超时、失败与 legacy namespace。Vela 可以借鉴“每次注入都有 scope、deadline、receipt、失败不泄露”的交互合同，复用开源实现须遵守其许可证，不能把 remote ACL 降格为本地 scope。
- **可本地补全**：统一 Vela 的 supported-provider lifecycle adapter，保证 active/project/private/exclusion/fresh-source gate 在每个注入前重验，并以真实本地 hook runner 验证安装、撤销、scope 和 prompt 字节。
- **需外部条件**：Codex、Claude、Cursor、Pi、OMP 等实际宿主是否接受/运行相应 hook 与模型对提供上下文的行为影响。
- **验收**：每个列为支持的宿主都有安装→下一会话→recall receipt→撤销→不再提供的真实闭环；跨项目、private、superseded 和排除来源全部为负例。模型采纳以独立设计的对照实验测量。

### P0-4：验证系统只有正确 Reject，缺有效候选的正向 Promote 与回归检测

- **现状与源码/证据**：`LabService.createEvaluation` 与 pending approval 提供隔离执行入口（`Sources/VelaCore/LabService.swift:4-78`），但 final-spec 106–118 都是 partial，除 isolation/no-magic-score 外未有完整用户级验收。r2 的 6 次真实实验是实测 provider，但得出 Reject；这不能升级为 Improve/Reuse 成功。
- **参考对照**：px0 的 `runner.py`、`runs.py`、`approvals.py` 和失败路径测试给出“运行、审批、终态不重试”的可比语义；其输出质量不能被假定优于 Vela。
- **可本地补全**：补齐 dataset 版本、指标定义、时间/成本/测试调用的 unavailable 语义、回归基线保留和 failed/uncertain 终态，不允许通过重跑或改阈值抹去失败。
- **需外部条件**：真实 provider 的重复执行、稳定的独立 verifier，以及足以区分候选的任务样本；这会产生费用。
- **验收**：同一 commit/task/model/预算下预注册多个样本；candidate 胜出才允许 `promote`，劣化/缺测必须拒绝。推广后再观察下一会话，不把单次 token 差异或测试通过写成长期质量改善。

### P1-5：MemWal 对标中的 owner/namespace/delegate、加密远端写读与恢复尚未实证

- **现状与源码/证据**：Vela 的可选 adapter 只有受限 SDK/transaction preparation 与本地 archive；[walrus-memory.md](walrus-memory.md) 已记录官方 faucet 429、测试地址零余额，且没有 owner/delegate 链上提交、加密写后读或桌面凭据流的正向证据（约 107–114 行）。最终规格 41–43、54 是 `external_unverified`，55 缺失。
- **参考对照**：MemWal README 明确 owner+namespace、relayer embed/encrypt/upload/search/restore；`packages/mcp/src/auth.ts` 和 SDK 代码提供 delegate 身份边界，`packages/openclaw-memory-memwal/src/config.ts`/`hooks` 提供 namespace 分离例子。
- **可本地补全**：继续 strict profile、密钥不落日志、请求签名/分页/tombstone/未知状态和失败恢复的协议测试；不将本地 namespace 称为 remote ACL。
- **需外部条件**：独立测试 owner、gas、wallet/delegate 授权、官方 relayer/Walrus 可用性及真实加密写→读→restore→revoke 结果。
- **验收**：测试账户下明确 authorize、写入、跨 namespace 拒绝、读取/恢复、删除/撤销、断网/429/不确定写的 receipt；没有交易回执即保持 external_unverified。

### P1-6：Workflow、工具/connector 与通知的产品交互未覆盖 px0/Blume 的完整已交付面

- **现状与源码/证据**：Vela 有受限 `AutomationService.pendingApproval`（`Sources/VelaCore/AutomationService.swift:377,477-489`）、connector action 的冻结审批（`ConnectorService.swift:286-302`）和 watchdog/daemon 切片；但 final-spec 76（自动 workflow discovery）、88（通知）、92（custom local tool）、94–97（connector/auth/capability/unknown tool）仍 partial/missing/external。`docs/status.md` 也明确 connector 只有无凭据 HTTPS 拒绝路径，缺真实账户正向执行。
- **参考对照**：px0-workflows 的 `builder.py`、`tools.py`、`connect.py`、`catalogue.py`、`approvals.py` 与对应 `tests/test_builder_discovery.py`、`test_composio_execution.py`、`test_approvals.py`；Blume 的通知/用量是公开产品交互，但其内部实现不可读。
- **可本地补全**：冻结本地工具 catalogue、unknown-tool 可解释拒绝、workflow 生命周期/重启/审批到期与通知状态机；补真实账户之外的 schema、Dry Run、fail-closed、重启、并发和没有副作用的反例。
- **需外部条件**：connector 的测试账户、OAuth/Keychain、真实 provider connector 写入与操作系统通知授权/点击回流。
- **验收**：逐 connector 的 discover→credential boundary→preview→approval→一次执行→receipt→revoke，以及 reconnect/uncertain 状态；未经外部账户验证的项不能标成“已交付”。

### P1-7：配置治理与 Safe Apply/Undo 尚未成为统一 Artifact 与审计产品

- **现状与源码/证据**：SafeApply 的窄路径已有后端证据，但最终规格 21–34 显示统一 Artifact model、scope、关系图、coverage、audit、suppression、context budget/ladders、完整 history 仍 partial/missing。`SetupInventoryService` 的 relation 只是 observed byte/name/directory 关系，明确不推断 runtime merge（`:227-240`）。
- **参考对照**：Blume 方向提供 rules/skills/hooks/配置治理的用户交互目标；px0-workflows 的 config/store/doctor 源码与测试是可读的运行/修复参考。Blume 的私有实现未知。
- **可本地补全**：先定义统一 Artifact ID、scope/precedence、runtime-observed vs unknown、finding/suppression、历史与 Safe Apply journal 的同一数据模型；所有建议必须只能通过 Safe Apply/Undo。
- **需外部条件**：各 provider 实际配置加载、override、插件发现和权限行为。扫描到文件绝不能作为运行时已加载证据。
- **验收**：同一受控项目中做配置冲突、读取失败、权限/隐私边界、preview/apply/undo、外部改动拒绝、崩溃恢复；实测 provider 实际加载与 Vela 观察一致或明确 unknown。

### P1-8：发行与硬门禁尚未完成

- **现状与证据**：HG-1 到 HG-5 仍 Fail/Not Run，HG-6 只限记录的 preview.2 包 Pass（`ACCEPTANCE.md:107-114`）。README 也说明开发 app 是 ad-hoc 签名、未 Developer ID/notarized。当前开发树的 UI/浏览器/原生切片不能自动继承为正式包验收。
- **可本地补全**：在固定 release candidate 上执行 allowlist、冷启动/资源/重启/恢复/安全/隐私负例与跨版本升级矩阵，保留原始环境和失败记录。
- **需外部条件**：Apple Developer ID、公证服务、实际目标 macOS 环境、系统通知授权及真实 provider/远端账户。
- **验收**：每一 Hard Gate 同一 release candidate 独立通过；ad-hoc 开发包、旧 preview.2 或不同 helper 的成功不能替代。

## 现有“通过”宣称的证据审计

当前权威文档总体上没有把 fixture 直接写成 provider 成功，且已包含关键限制；交付时必须继续维持下表边界，不能从测试数倒推产品完成度。

| 证据类型 | 已有事实 | 不得升级成 |
| --- | --- | --- |
| portable runner | README 明确说明它复用同步测试体和 assertion compatibility layer，**不是 XCTest**。 | “所有 macOS XCTest 通过”或正式 release 可靠性。 |
| renderer/browser | 六组 renderer→CLI 验收使用同一全新**合成** fixture、56 次 Core RPC，且 Lab approval 在桥中被拒、hook 从未运行（`ACCEPTANCE.md:179`）。 | 真正 agent 执行、下一会话自动消费、provider 质量或 Golden GS13–20 通过。 |
| hosted XCTest/CI | CI 可证明对应提交、对应 job 的 Swift test 与打包步骤；已有 CI evidence 也限定 helper/UI 快照。 | 外部账户、远程存储、provider 模型行为、真实系统权限已验证。 |
| Agent Lab r2 | 六次真实 provider 运行、独立 verifier 和 receipt 是高价值实测；结果为 **Reject**。 | 记忆改善、token 节省、有效 promotion 或未来纠错降低。 |
| OpenClaw/AI SDK/MCP | 已有真实安装/loopback 或本地合成 provider 的切片，可证明协议/注入字节与边界。 | 真实模型采纳、所有 host/provider 兼容或 Walrus 远端加密成功。 |
| Walrus adapter | 有 transaction preparation、签名/协议负例和 testnet 只读/失败边界。 | owner/delegate 已授权、链上提交、加密写后读或恢复成功。 |

因此，报告、PR 和发布说明应同时写出 **commit/helper/UI hash、fixture 是否合成、provider 是否真实、账户/网络是否真实、原生/浏览器还是 Core/RPC、以及失败或 unavailable**。任何一项缺失时只能作为支持证据，不能关闭参考台账行。

## 建议的最小交付顺序

1. **先做 P0-1/P0-3 的单来源 Golden harness**：它把 session、candidate、approval、Lab、promotion、next-session receipt 串成可审计对象链；本地先验证拒绝、取消、恢复和 cleanup。
2. **并行收紧 P0-2 的 provider 观察契约**：先不扩展猜测的 live 功能，给每个现有 harness 明确 supported/unknown/unsupported 与真实运行验收入口。
3. **在拥有独立测试账户后做 P1-5/P1-6**：Walrus 与 connector 都以真实授权、写后读/撤销、不确定写为最小闭环；不能由 mock 或交易预览关闭。
4. **最后以固定 release candidate 运行 P1-8**：Golden 全链与六 Hard Gate 全部通过前，继续维持 No-Go，不以 188/228 行数、测试方法数或截图数量替代。

## 可追溯索引

- 参考范围与逐行目标：[228 项台账](README.md)、[Blume 52 项](blume.md)、[MemWal 56 项](walrus-memory.md)、[px0 120 项](px0.md)。
- 参考来源固定与不可读边界：[reference-downloads-2026-09-13.json](reference-downloads-2026-09-13.json)、[px0 source audit](px0-source-audit-2026-09-13.md)。
- Vela 产品验收与历史正/负证据：[ACCEPTANCE.md](../ACCEPTANCE.md)、[verification.md](../verification.md)、[status.md](../status.md)、[Golden r2 evidence](golden-source-chain-r2-evidence-2026-09-13.json)。
- 用户补充规格的当前**初步源码筛查**：[final-spec-2026-09-14.md](final-spec-2026-09-14.md)；它不替代本报告定义的真实交互验收。
