# Reference comparison and acceptance evidence

读取日期 / Accessed: **2026-09-12**（Asia/Shanghai）。Vela 比较基线：`0.1.0-preview.2`，提交 `6c2bf54e99e19fdeedcf7e0ddfa49beed58c5d21`。本轮进行文档和代码审查；下文历史测试结果来自 [verification.md](verification.md)，不是本轮重新运行的结果。后续修复与实验必须追加具体执行证据，不能自动继承本表状态。

**English summary.** Blume's public materials describe coding-agent observation, configuration governance and usage visibility; some improvement features carry roadmap labels. Walrus Memory/MemWal documents portable, permissioned memory through an owner/namespace boundary and a relayer-backed storage system. px0 documents editable local workflows with actual memory/guideline injection, held writes and traceable runs. These are first-party descriptions, not independent runtime certifications. Vela's baseline command comparisons and manual recall do not establish future-session behavior improvement. The later six-run Codex experiment below adds real task evidence, but its corrected result is inconclusive. Existing test passes cannot replace the complete product scenario or compensate for a failed hard gate.

## Evidence rules

| 标记 | 含义 | 不代表什么 |
| --- | --- | --- |
| **O：官方公开** | 本次读取到的产品官网、官方文档、官网链接的官方仓库 README | 未安装并实测参考产品，不据此证明版本兼容、正确率、性能或安全保证 |
| **R：用户报告** | 用户提供的三份 Blume v1.0.73 报告中的产品及架构描述 | 报告的“已确认”不等于本项目独立确认，不等于当前公开交付状态 |
| **V：Vela 证据** | 本仓库代码、测试方法、已记录的执行结果 | 有代码不等于有测试；测试存在不等于这次执行通过 |
| **I：比较判断** | 根据上述材料作出的差距或验收判断 | 不作为参考产品的事实陈述，不给没有实验依据的评分 |

只查阅报告目录顶层的 `Blume-Sidecar-完整逆向报告.md`、`Blume-Sidecar-技术架构与细节处理.md` 和 `Blume-Sidecar-模块详细说明.md`。未读取 `app-asar`、解包源码、`harvest`、随包内部文档或私有提示词；不将其复制进仓库。报告只作为用户需求背景，公开比较优先引用可访问的第一方资料。

原始 Vela 构思附件明确写了 **“Walrus Memory / MemWal”**，但没有提供 URL。下列官方身份由 `MystenLabs/MemWal` README 与 Walrus 文档交叉确认，不能写成“URL 来自原附件”。没有找到或无法读取某项官方资料，只能标为**本次未确认**，不能写成“该产品没有此功能”。

## Three reference directions

### Blume: observation and configuration governance

| 公开可证的描述（O） | Vela 当前状态（V） | 验收差距（I） |
| --- | --- | --- |
| 官网展示 Claude Code、Codex、Cursor、Pi、omp，以及运行、完成、待审批状态和配置总览。[官网](https://blume.codes/) | Claude/Codex 日志与部分 Cursor 导出/SQLite 记录可索引；状态带推断标识，不能证明所有真实进程存活 | 需要版本化兼容矩阵、五个并发真实 agent 的状态/项目/branch/worktree 证据；不能把推断 Running 等同进程观测 |
| 官网展示规则、技能、Hook 与有证据和 diff 的改进建议；同页 Auto-Fixes/Analytics 标为 Soon，Auto-Improve Mode 标为 Next。[官网](https://blume.codes/) | Setup 有实际扫描/脱敏；Improve 是确定性纠错检测与建议，支持受限 Apply/Undo | 保留官方发布状态歧义，不把演示或报告中的实现直接标为全面可用；Vela 需要精度、near-miss 和重复流程分流验收 |
| Claude 用量指南区分未登录与 Keychain 读取受阻，成功后展示账户和额度窗口。[用量指南](https://blume.codes/docs/claude-usage-mac) | 只有已索引日志 token；额度、价格、reset 不可用 | 不能用累计 token 代替订阅额度，也不能从缺少凭证推导零用量 |
| 隐私页说明本地 SQLite、部分功能可发送必要内容、有限遥测；Cloud Improvements 需显式选择，并有尚待验证后开放的条件。[隐私说明](https://blume.codes/privacy) | 无 Vela 遥测；显式 URL 导入和获批远程 CLI 可产生网络请求 | 两者都应按具体数据流描述，不能用“本地优先”推导完全离线；不把旧报告对官网的批评当当前官网原话 |

**R 与 O 的分界。** 三份用户报告讨论 worker 隔离、分阶段 Improve、MCP、Apply/Undo、跨 harness 续接和功能开关；这些是该报告对特定版本的陈述。本次未验证其当前运行时、服务端开关或私有实现。报告之间的进程计数口径不同，且早期“官网列出四种 harness”的描述与本次官网展示五种不一致，因此不将内部数量、私有接口或历史营销评价用作 Vela 的硬指标。可继承的是有界解析、失败显式可见、证据可追溯等需求，验证仍由 Vela 自己完成。

### Walrus Memory / MemWal: portable ownership and retrieval

| 公开可证的描述（O） | Vela 当前状态（V） | 验收差距（I） |
| --- | --- | --- |
| 官方仓库将其定义为仍在演进的 beta，面向跨应用/会话的可迁移记忆。[官方仓库](https://github.com/MystenLabs/MemWal) | Markdown 资产和 SQLite，Memory 独立于 agent provider | Vela 的项目所有权是本地范围语义；不能声称已有跨设备协议、去中心化验证或加密同步 |
| `owner + namespace` 约束操作；公开 API 包含 remember、recall、restore；restore 重建 namespace 的缺失索引。[官方 README](https://github.com/MystenLabs/MemWal) | global/project/repository/branch/worktree/task/session，active-only Recall，显式 supersede，来源字段 | namespace 不是 Vela 的完整 scope/lifecycle；restore 也不等于恢复 coding agent 原生会话。需分别验证范围隔离、旧事实被替换、实际来源和下一次消费 |
| 默认客户端通过 relayer 处理 embedding、加密、Walrus 存储及检索；手动客户端仍有 relayer 职责。[SDK 概览](https://docs.wal.app/walrus-memory/sdk/overview) | 无 relayer、embedding 服务或 Walrus 后端；词面排序加预算 | 当前技术选择不同，不是缺少一个 SDK 接口即可等价。不要为参考对齐而引入与本地优先目标无关的基础设施 |
| Python/TypeScript SDK 和相应中间件有公开接入说明；配置涉及 account、delegate key 与 namespace。[Python quick start](https://docs.wal.app/walrus-memory/python-sdk/quick-start) | MCP 默认只读，贡献只创建候选资产；尚无普遍自动注入 | 公开集成文档可证明接入面存在，不能证明在用户全部 coding harness 上会自动 Recall；Vela 仍需真实后续会话实验 |

官方仓库链接 [memory.walrus.xyz](https://memory.walrus.xyz/) 和 [Walrus Docs](https://docs.wal.app/walrus-memory/sdk/overview)。本次前者未取得可读页面，后者搜索索引可读但一次直接读取超时；上述判断由成功读取的官方 README 和文档索引支持，没有运行托管服务，也没有接触任何账户或密钥。

### px0: workflows that consume context and preserve decisions

| 公开可证的描述（O） | Vela 当前状态（V） | 验收差距（I） |
| --- | --- | --- |
| 文档描述从自然语言生成可编辑 Markdown workflow，并通过现有 coding-agent CLI 执行；外部工具可经 Composio。[产品介绍](https://docs.px0.ai/) | 有限工具注册表、关键词及现有项目脚本生成 Draft；无通用外部工具发现 | Vela 应优先完成工程流程闭环；不需要复制通用 SaaS 自动化范围 |
| Memory 由用户确认，相关项按预算进入后续运行；同 subject 写入替换旧事实，运行可追查用了哪些记忆。[Memory](https://docs.px0.ai/memory/overview) | Recall 可调用，生命周期可管理；Guideline 当前是冻结快照，尚未注入；没有通用未来 Session 自动消费 | 缺的是“选出的上下文确实进入本次执行且可追溯”的证据，而不仅是 Memory 列表或保存接口 |
| 审批保留工具和参数，批准执行记录的调用而不重跑；失败不会自动变回 pending。[Approvals](https://docs.px0.ai/approvals/overview) | 冻结 approval + 跨连接 CAS；Dry Run stub 所有副作用 | 有相应已执行核心测试；仍不能宣称任意远端副作用端到端 exactly-once |
| 官网描述运行健康分析、历史输入 replay、独立 daemon 与错过调度补跑。[官网](https://px0.ai/) | 健康统计、有限 replay/cron/事件去重；仅 helper 存活时运行，无完整休眠补跑 | 不把相似命令名当相同语义；需固定输入、版本与结果的证据 |
| store 文档区分可重建索引和不可重建历史/待审批记录，并说明显式迁移、导出、冲突处理。[Store](https://docs.px0.ai/reference/store) | SQLite + Markdown，部分事务补偿和 Apply journal；尚无成熟迁移/恢复兼容矩阵 | 文件可读不等于所有资产和历史可无损恢复，需崩溃点与升级场景验收 |
| 隐私说明列明模型 prompt、工具/连接器流向、private 资料硬排除。[Privacy](https://docs.px0.ai/reference/privacy) | private Library 排除于 agent search/Recall；显式 URL 与批准命令可联网 | 必须逐入口证明私有标签不可被覆盖丢失；外部 CLI 继承其 provider 数据政策 |

官网视觉对照已单独记录在 [website/design-qa.md](../website/design-qa.md)。字体、留白、颜色和页面可用性属于界面验收，不参与核心产品闭环或 Hard Gate 抵分。

## Golden Scenario: where evidence stops

| 用户要求的阶段 | 当前证据 | 尚不能宣称 |
| --- | --- | --- |
| Observe：自动发现、状态、消息及工具证据 | JSONL/Cursor fixtures、FSEvents 与真实 native helper 界面 | 完整 provider 私有格式、全部历史、真实进程状态、所有 Changed Files/Todo，以及五 agent 并发正确性 |
| Remember：保存正确事实并淘汰旧事实 | scope/budget/lifecycle 测试；原生消息保存后独立 CLI 核对 sourceSession/sourceMessage | 自动提取泛化正确；任意 provenance 都经过真实来源校验；未来 Session 已消费 |
| Improve / Automate：重复纠错与重复程序分别处理 | 不同 Session 的确定性信号去重、晋升；单 Session/干净会话负例；手动 workflow Draft | 五 Session positive、一次性抱怨和正常 feature-spec 迭代组成的精度集全部通过；自动区分知识与流程；重复程序自动产生可运行提案 |
| Verify：同 repo/commit/task/model/timeout 多次执行 | 独立 worktree 的真实 baseline/candidate 命令；退出码、时间、输出及 diff | 真实相同模型任务，Corrections/Tokens/Tool Calls 指标或更好/更差的可靠结论；当前 `deterministic_command` 不是完整 Agent Eval |
| Promote → Reuse：未来会话正确执行并降低重复纠错 | 目前无完整连续实验记录 | 20 步 Golden Scenario 已完成，或“Vela v1.0 Product Complete” |

这是证据盘点，不是产品分数。Hard Gate 未通过前不计算可用于发布的综合分；没有运行的场景保留未测，不能把预期输出写成观察结果。

### Agent Lab 增量与计分更正（2026-09-13）

上表保留 preview.2 比较基线。本轮新增严格工程约束 Candidate、具有真实来源的重复程序发现、源 Suggestion 到 Agent Lab 的冻结关联、Memory-only 显式晋升、Codex SessionStart Hook 草案和 Recall receipt。源码或受控测试支持这些窄项；不据此将三参考方向都标为完整复刻。

真实 Eval `938a7aa2-0bc7-416a-9437-e08b1240d9c4` 使用 `codex-cli 0.154.0`、请求 `gpt-5.6-sol` / `high`，完成 baseline/candidate 各三次同 commit 的 `clamp` 任务。provider resolved model version 为 null；这是固定模型请求，不能称已验证后端精确版本。六次独立 verifier 均成功，但旧 scorer 漏记复合命令中的测试，曾错误报告 baseline 0/3、candidate 2/3 并给出 `ready_for_review`。

从保留的六次 raw JSONL 重算后，两边实际测试观察均为 **3/3**，任务验证均为 **3/3**，判定更正为 **Inconclusive**；实际晋升被拒绝、Memory 保持 Candidate。[公开脱敏记录](evidence/2026-09-13-agent-lab.json) 使用 `codex-test-observation-v3`，保留六次 raw hash、测试 argv、冻结任务及构建身份。旧摘要与原结果保留，不能只展示修正后的成功执行而隐去计分缺陷。均值 tokens 为 baseline 142,437.333、candidate 108,768.667，仅限该 fixture；没有统计泛化、Corrections 或未来 RFR 下降结论。原文件/重算文件哈希与当前回归待项见 [ACCEPTANCE](ACCEPTANCE.md#真实-agent-实验保留失败计分与更正)。

这新增了真实 Agent 对照证据，也证明“候选没有变好”必须是可交付结果。它没有补齐自动提取来源到真实未来会话的 Golden 链，Hook receipt 也不能证明 agent 消费或遵循。客户端按 Blume 的信息组织优化，官网维持 px0 方向；两项视觉结论与核心验证结果分别记录，完整产品仍 **No-Go / Not Scored**。

## Six Hard Gates: coverage and missing evidence

下列测试名可在 [Tests/VelaCoreTests](../Tests/VelaCoreTests) 查找；RPC/MCP 见 [test-rpc.py](../scripts/test-rpc.py)，界面见 [test-ui-browser.py](../scripts/test-ui-browser.py)。历史 portable 54/54 与 browser 12/12 的范围见 [verification.md](verification.md)。

| Gate | 已有可定位证据 | 缺口及当前判定 |
| --- | --- | --- |
| Performance | 历史 100k warm search、小 GUI RSS/CPU 采样；本轮 release 10k/100k × 六类搜索与九组有界摄取矩阵 | **历史 Search p95 132.33 ms 为失败，保留记录；本轮 100k 六类查询 p95 57.127–77.873 ms，均通过 <120 ms。** 摄取矩阵只证明有界行为，不是完整历史或 event→UI 指标；冷启动、真实并发和长期分布未测，不能判整关 PASS |
| Reliability | `testPartialJSONLAndRotation`、Cursor 未知 schema、bounded-tail、FSEvents；子进程 timeout/output-limit；本轮 RPC/MCP 64 MiB 巨帧持续输入拒绝及恢复通过 | 尚无 helper/解析器强杀后的原生错误和恢复测试、长时间旋转/截断压力。helper 与 UI 分进程，但核心服务共享 helper，不能声称逐 worker 故障隔离全部通过 |
| Security | SafeApply traversal/symlink/hash/unsafe undo、frozen approval、两 DB 连接争抢、Git fsmonitor 禁用；MCP 注册项目/只读贡献边界；本轮七项 IntegrityTests 与巨帧 RPC/MCP 回归 | 已复现的祖先 symlink、Library 私有来源/跨项目覆盖、无界入站帧已有修复及回归；全权限/外发/并发路径矩阵仍未完成。不能用 UI routing 模拟证明 OS 点击安全性 |
| Privacy | 私有 Memory/Library 排除、private 目录强制标签、MCP includePrivate 拒绝、Setup env/header 脱敏 | 未有覆盖全部允许入口的外发审计或默认运行网络观测；修改私有资产时的标签保持需补证。默认本地与显式联网操作必须分开验 |
| Data Integrity | SQLite 重新打开、Markdown 编辑、批次失败补偿、真实 Apply/Undo、构造的 interrupted journal 恢复 | 缺旧版本→新版本迁移与重复打开、磁盘满/权限故障、进程在各文件/DB提交点被杀、用户并发写入的完整矩阵。合成 journal 恢复不等于真实断电/任意崩溃安全 |
| Packaging | 包资源筛选、arm64、签名验证、无调试 capture marker/构建路径、3 个 WAV 格式/时长校验，真实正式包启动与审批 | 当前 ad-hoc、未公证，macOS 13 未实测；本机通知授权拒绝，实际 OS 投递/点击未通过。安装包卫生与签名/通知能力分开记录；声明的正式发布要求尚不能整体判 PASS |

### Concrete review findings and follow-up

以下列出基线代码问题以及本轮追查结果，不将尚未执行的测试写成通过。

1. **Library 身份与隐私来源可被同 ID 覆盖。** `MemoryService.library.add` 从本次参数重建对象，再 `store.put`；未验证已有 Library 的项目，省略旧 `sourcePath` 可丢弃强制 private 来源。复现步骤：从测试项目 `private/secret.md` 导入（传 false 也应存 true），再同 ID 传内容和 `private:false`，检查 sourcePath/private 和非私有 search；另一项目同 ID 更新应拒绝并保持原数据。
2. **store 祖先 symlink 检查发生在建目录之后。** `VelaStore.assetURL` 先递归创建 `assets/<kind>` 再检查规范路径；若 `assets` 指向临时 outside 目录，失败请求仍可能先创建 outside 子目录。复现必须检查错误之外的文件系统零变化，现有测试只覆盖最终 `.md` 符号链接。
3. **RPC 的 2 MB 限制在完整读行之后。** `readLine()` 返回后才检查大小；无换行大输入在拒绝前已有不受该限值约束的内存占用。应有有界读取、超限恢复和下一合法帧测试，不能仅测带换行的短非法 JSON。
4. **Usage 缺失值与整数溢出。** 后续隔离日志复现：没有 usage 的会话返回 totalTokens=0；Claude `Int.max` 加缓存字段在摄取中导致 helper SIGTRAP，Codex `Int.max` 输入加输出在 `usage.get` 中同样崩溃。2026-09-13 修复后，以真实 debug helper 连续执行缺失、Claude 极端值、Codex 极端值、真实零、混合有/无数据、跨会话总和越界六场景，全部通过，且每场之后同进程仍能响应 `system.version`。完整值与 observed 部分和分离，缺失/越界返回 null，真实零保留 0；决策见 [ADR 0004](adr/0004-nullable-observed-usage.md)。具名证据为 `output/playwright/acceptance-usage-integrity.json`，包含修前后差异与修后二进制 hash；修前未捕获 hash/精确时标，报告明确保留该限制。

**本轮复现与修复状态（2026-09-12）。** 使用已有 debug CLI、`VELA_DISABLE_DISCOVERY=1`、移除继承的 `VELA_SESSION_ROOT`，仅在 `vela-integrity-baseline-*` 一次性目录执行：问题 1 的 private 从 true 变 false、sourcePath 丢失、跨项目覆盖和非私有检索可见均复现；问题 2 的请求返回错误但 outside/memory 仍创建也复现。临时目录已自动清理，无真实用户数据。

随后源码收紧为：Library 导入只创建新对象，已有 ID 不可覆盖；创建条件在 SQLite 写事务内复核，以覆盖跨连接竞争；资产子目录通过目录描述符逐级 `openat/mkdirat` 并使用 `O_NOFOLLOW`，拒绝祖先符号链接后再创建。新增 [IntegrityTests.swift](../Tests/VelaCoreTests/IntegrityTests.swift) 七项回归，包含原私有数据/资产不变、跨项目拒绝、并发唯一赢家、祖先 symlink 零外部变化、五类正常资产重开，以及批次来源过期拒绝与来源未变提交。`putBatch(expecting:)` 在 `BEGIN IMMEDIATE` 内复核全部原对象哈希，再备份及写入；失败只恢复本批已写资产，并在释放数据库写锁前完成文件恢复。**七项方法已在本轮 90 方法的 portable 快照中通过**；这不是 macOS XCTest SDK 执行，也不继承到随后改动的最终工作树。此改动不构成对任意并发目录替换或真实断电的完整证明。

问题 3 也已得到基线反例：[test-rpc-limits.py](../scripts/test-rpc-limits.py) 对旧 CLI 输入 2,000,001 字节但不发送换行时，5 秒内没有超限响应，测试在该断言失败。新的 [BoundedInput.swift](../Sources/VelaCLI/BoundedInput.swift) 接入 debug CLI 后，本轮实际执行上述脚本，**RPC 与 MCP 黑盒均通过**：覆盖 UTF-8 分片、多帧、坏 JSON 恢复、恰好 2 MB 的 CRLF 帧、无换行超限即时拒绝、同一超限帧继续输入 64 MiB 时只报一次、后续合法帧和 EOF。64 MiB drain 期间按每 1 MiB 输入采样 `ps` RSS，RPC 基线/采样峰值为 18,160/18,208 KiB，MCP 为 18,128/18,192 KiB，增长分别为 48/64 KiB，均低于脚本的 32 MiB 增长上限。这只证明该隔离 fixture 的采样结果，不是全应用内存上界；脚本已接入 CI。所有测试只清理自己的进程和一次性目录。

## Performance matrix to run before a hard-gate decision

预算来源：[requirements.md §5](requirements.md#5-性能预算与测量方式)。[benchmark-read.py](../scripts/benchmark-read.py) 测 warm RPC/SQLite substring search：直接插入 10k/100k 对象，每个大小六类查询、每类 10 次 warm-up 和 50 个串行样本，所有 p95 必须严格小于 120 ms，否则退出码为 1。保持历史字段和 JSON 存储体积，不把空 messages 数组的对象冒充真实消息。[benchmark-ingest.py](../scripts/benchmark-ingest.py) 单独流式生成真实 JSONL，使用隔离 helper 执行显式 `sessions.refresh`，把输入和实际保留量分开报告。

**2026-09-12 release 实测。** 二进制 SHA-256 为 `3d91f2f554c361e222b17e6cbbdce11b9fcd1847b9c2952d37af9183b7ee3fc2`；报告记录提交、工作区修改标记、平台、Swift、SQLite、fixture hash 与全部原始样本。OS 缓存未驱逐；这不是冷启动测试。100k 项目命中、全局命中、项目无结果、全局无结果、单条稀疏命中、多词命中的 p95 分别为 **77.873、76.010、58.348、57.127、60.237、70.221 ms**；10k 六类为 6.389–9.166 ms。新增 `objects_search_project(project,private,kind)`，没有改变 substring、转义、权限、结果排序或 LIMIT。独立 SQLite 试验中，该索引使 100k fixture 数据库增加 3.84%，单次批量插入增加 8.1%；后者不是写吞吐分布。按时间排序的候选索引使 global miss 变慢，复制正文的 covering index 近乎翻倍体积，均未采用。

摄取矩阵为九个独立场景，每组三个样本；没有把维度相乘，也没有据三个样本声称 p95。10/100/1,000 个源分别选中 10/60/60，保留 100/600/600 条消息。1/10/50/500 MB（十进制）单日志分别保留 351/351/351/350 条尾部消息；10k/100k 原始消息均只保留 351 条。所有断言通过、历史截断标识明确。显式 refresh 的场景中位数为 24.013–141.044 ms；10k 原始消息场景一次 132.477 ms 的较慢样本也保留。helper RSS 50 ms 采样最高 22,480 KiB；短峰值、其它进程、长期预算和真实 Agent 并发都不在该数字范围内。原始 JSON 由上述脚本 `--output` 生成，当前验收产物为 `output/playwright/acceptance-performance-{search,ingest,index-experiment}.json`。

| 维度 | 固定 fixture / 记录要求 | 当前证据 |
| --- | --- | --- |
| Session 数量 | 10、100、1,000；provider/项目比例固定 | 单一合成 Claude provider 各三样本，60 源上限已验证；不等于同时完整索引 1,000 Session |
| 单日志大小 | 1、10、50、500 MB；完整/partial/malformed/rotate 分列 | 合法 JSONL 各三样本，有界 tail 行为通过；未完成对应尺寸的 partial/malformed/rotate 性能矩阵 |
| 消息数量 | 10k、100k；明确是原始消息、已索引消息还是聚合对象 | 原始消息轴已测，当前均只保留 351 条；不能宣称 100k 消息完整摄取/检索 |
| 冷启动 | 窗口可见 p95 ≤1.5 s；真实内容可交互 p95 ≤2 s；区分 OS/file-cache 冷暖 | 尚无冷启动样本分布；瞬时加载树观察不算启动时间 |
| 常驻资源 | 空闲 CPU <0.5%；Main+Watcher <120 MB；全进程 <220 MB；注明 MB/MiB 与共享 RSS 口径 | 历史短采样约102.9 MiB和196.6–196.7 MiB；0.0%仅 `ps`显示精度，不是零 CPU 证明 |
| 摄取与显示 | ingest latency、原始 event→已索引→UI 三个时间点；event→UI p95 <300 ms | 已测显式 refresh；没有三个阶段的同一事件时标，不能证明300ms目标 |
| 交互 | 页签切换 p95 <50 ms；Session首屏 p95 <150 ms；不能将骨架完成算内容完成 | 界面功能验收通过不等于性能达标 |
| 搜索 | 100k、scope/private 过滤开启，代表性 hit/miss/短词/多词，p95 <120 ms | 本轮六类通过，100k最高77.873ms；历史132.33ms保留，不外推到原始100k消息或并发负载 |
| 并发与长期 | 2 Codex + 2 Claude + 1 Cursor；同时摄取/搜索/后台分析/Lab；持续采样与队列长度 | 尚无该组合与长时间稳定性结果 |

每条记录需包含提交、二进制构建配置、OS/硬件、fixture hash/规模、缓存条件、采样数与原始结果。先按代表性组合覆盖边界，不必盲目跑所有维度笛卡尔积；但必须明确哪些组合没有覆盖。不要通过提高阈值、丢弃失败样本或只挑最快一次把 FAIL 改为 PASS。
