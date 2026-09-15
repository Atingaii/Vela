# Vela 产品需求 / Product requirements

**基线：2026-09-12，`6c2bf54` / `0.1.0-preview.2`。** 当前产品仍是开发者预览；下文的目标能力不是发布承诺。完整的原始能力条目保留在 [requirements.md](requirements.md)，78 项 FR、35 项 NFR 的逐项对照见 [TRACEABILITY](TRACEABILITY.md)。

**English:** This PRD specifies the complete Observe → Remember → Improve/Automate → Verify → Reuse loop for developers using Claude Code, Codex and Cursor on macOS. Current implementation and product acceptance are separate states. Automatic extraction, procedure discovery, controlled agent evaluation and future-session impact are not established by the preview's existing tests.

## 用户、问题与价值

主要用户是持续使用多个 Coding Agent 的个人开发者。任务可能跨终端、项目、分支和工作树；用户需要知道哪里等审批、恢复为什么作过某决定、减少重复纠正与重复操作，并能拒绝无效“优化”。首发不依赖团队账户、云记忆或自建 Agent。

最短有价值路径是找到正在工作的 Session → 查看真实消息/工具 → 保存有来源的工程事实 → 在正确项目中恢复它。完整产品再把重复纠错/操作转成候选，经真实受控任务验证后进入后续 Session，并继续收集反例。

## 规范来源与冲突处理

| 来源 ID | 内容 | 使用方式 |
| --- | --- | --- |
| S1 | 用户原始《Vela / The engineering layer for coding agents》73 节 | 五目标的背景、主闭环、三个参考项目的分工、长期边界 |
| S2 | 用户《Vela 功能性与非功能性需求清单》 | FR-01–78、NFR-01–35；M0–M7 和早期阶段建议 |
| S3 | 用户最终验收补充，2026-09-12 | 20 步 Golden Scenario、五承诺反例、六 Hard Gate、性能矩阵、Scorecard、DoD |
| S4 | 用户后续界面要求 | 客户端参考 Blume、减少快捷键噪声、原创图标/适当音效/真实 README 图片；官网 px0 风格保持 |
| B1/B2/B3 | 用户提供的 Blume 产品、模块、技术报告 | 清洁室设计输入，非竞品能力的独立认证；不随公开仓库复制 |

S1/S2 对 P0/P1/P2 的分组不同，不用旧阶段标签删除 S3 的必需步骤；本 PRD 按依赖与验收安排。S3 的 20 步保留原意，包含 Improve；“自动 Recall”必须有真实消费证据。手工准备实验数据可以明确标 synthetic，但不得替代自动发现或真实 Agent 阶段。

## 需求单元与设计约束

每个 `R-*` 是验收单位，后面的 `D-*` 是行为设计约束，不预设新公共 API。`Partial` 指仅有子集，`Missing` 指尚无该结果路径。未列成 `Implemented` 不抹掉其已有可用子能力。

| Req / Goal | 必须达到的用户结果 | Design | 当前实现与主要缺口 |
| --- | --- | --- | --- |
| R-01 / G-OBS | 发现三个 Harness 的可用能力及 Session，失败互不影响 | D-01 能力分项为 available/unavailable/unknown，记录 provider/schema | Partial：已知格式支持；完整安装/登录/配额能力与版本矩阵不足 |
| R-02 / G-OBS | 当前状态与项目、分支、worktree 可信；根/子 Agent 不重复计数 | D-02 源事件/进程证据/超时推断分列；unknown 保留 | Partial：日志推断；无独立存活证明、完整 subagent 归并和五 Agent 实测 |
| R-03 / G-OBS | 有界增量摄取、可读时间线、证据定位及项目排除 | D-03 游标只在持久化后推进；近期优先；限制/缺历史可见 | Partial：FSEvents、半行/轮转/截断已覆盖；回填/历史分页/排除缺失 |
| R-04 / G-OBS,G-MEM | 清楚配置实际来源、版本、成本与诊断，干净配置零发现 | D-04 Inventory 与实际加载分开；每项 Audit 有 positive/negative/near-miss | Partial：扫描/脱敏/基础诊断；语义冲突、过期事实和抑制治理未完整 |
| R-05 / G-MEM | 从确切工程事实提 Candidate，保留用户审阅和完整 provenance | D-05 日常摘要不自动长期化；引用/假设不作事实；来源缺失显式标识 | Partial：手动保存和来源字段；自动 Session 提取缺失 |
| R-06 / G-MEM | 七级 scope、状态、authority、期限及 superseding 确保当前事实正确 | D-06 scope→状态/失效→相关性；跨项目不合并；保留旧版本 | Partial：七 scope/四状态及显式 supersedes；authority/期限/自动冲突处理缺失 |
| R-07 / G-MEM,G-VER | 正确且受预算的 Context 真正进入下一 Session，并可确认采用版本 | D-07 区分 eligible/selected/provided/consumed/observed outcome，私人资料硬排除 | Partial：lexical Active-only Recall、受限 MCP；自动接入与消费追踪缺失 |
| R-08 / G-MEM | 中断任务可通过中立 Checkpoint 恢复 | D-08 用户陈述与实际 Git/测试事实分列，不改 provider 私有历史 | Partial：导出可用；新的 Claude/Codex/Cursor 恢复任务未验收 |
| R-09 / G-IMP | 从重复的明确工程纠错发现可审阅问题，near-miss 不晋升 | D-09 幂等来源 ID；阈值版本化；精度优先；零建议是合法结果 | Partial：关键词纠错与 3 signals/2 sessions 门槛；尚缺完整正负例质量验收 |
| R-10 / G-IMP,G-AUT | 把知识问题与过程问题分流到最窄载体，建议可追溯、测试、拒绝 | D-10 说明载体/范围/成本/风险；单独的草案不会自动生效 | Partial：Workflow/Guideline 确定性分支；完整成本阶梯、候选到 Lab 与结果采用链不足 |
| R-11 / G-IMP,G-AUT | 安全 Apply/Undo，不覆盖并发编辑，不绕过审批 | D-11 hash/allowed-root/文件身份/journal；不确定结果 needs_review | Partial：受支持文件路径真实实现和反例测试；完整故障矩阵仍待验收 |
| R-12 / G-AUT | 多 Session 重复真实工具顺序形成可执行 Workflow 草案 | D-12 Tool events 提供顺序证据；至少三个不同 Session 的指定验收例；不塞入 Always-on Rule | Missing：Builder 与纠错衍生 Workflow 文稿存在；真实 sequence discovery 不存在 |
| R-13 / G-AUT | 可读 Workflow→Dry Run→冻结审批→实际执行→持久账本 | D-13 测试/写入/Agent 命令均可能有副作用；unknown fail-closed；冻结批准一次 | Partial：受限工具闭环已测试；通用 Planner、完整字段/feedback/edit 语义不足 |
| R-14 / G-AUT,G-VER | Health/Feedback/Replay/Scheduler 能定位与复现问题 | D-14 统计只用实际样本；重放重新审批；错过时机策略明确 | Partial：只读统计/版本观察/有限触发；完整 feedback→diff、missed-run 策略缺失 |
| R-15 / G-VER | Context、Memory、Workflow 的真实 Agent baseline/candidate 对照 | D-15 同 repo/commit/task/harness/model/reasoning/timeout/budget；差异冻结；原工作树不变 | Partial：同 commit 的隔离命令对照；任务/模型/Agent 行为控制不足 |
| R-16 / G-VER | 测量成功、tests、遵循、纠错、tokens、runtime、tool calls、retries、无关修改 | D-16 逐指标原始来源；重复运行；Better/Worse/Inconclusive；不可用不记零 | Partial：exit/output/runtime/diff/样本统计；Agent 指标、负向 Reject 缺口 |
| R-17 / G-VER,G-MEM,G-IMP | 仅在证据支持且用户采用后进入未来任务，持续衡量重复摩擦 | D-17 验证版本→采用记录→具体提供的上下文→后续 Session/Outcome 形成稳定边 | Missing：无完整 Promote/Reject→消费→纵向 outcome ledger；无实测纠错率下降 |
| R-18 / G-OBS,G-MEM | Search/Usage/Library 不编造、不越界；Ask 有证据且明确能力 | D-18 人类搜索与 Agent Recall 分开；额度未知、历史不完整、私有内容明确 | Partial：本地搜索/观测 token/私有资料；真实配额、完整分析成本、模型 Ask 不可用 |
| R-19 / 全目标 | 日常任务高效、安静、可访问，Mac Sidecar 不中断开发 | D-19 Blume 参考客户端；渐进披露；项目范围稳定；图标/音效原生集成 | Partial：上一轮 12 renderer + 部分原生测试；OS 通知授权失败、完整用户旅程/性能缺测 |
| R-20 / 全目标 | 六 Hard Gate、可重建开源工程及真实发布信息 | D-20 独立性能/安全/隐私/完整性/包审计；官网保持 px0 方向，内容诚实 | Partial：预览已发布、allowlist 审计；签名公证/更新、压力与迁移验证仍不足 |

## 必须贯通的数据关系

`Session/Message/ToolEvent → Candidate Memory/Signal → Cluster → Suggestion → Artifact/Workflow Version → Approval/Run → Eval → Adoption → Future Session → Outcome`。

这些名称描述产品证据，不宣称数据库已有每个实体。每条边记录 origin、project/scope、源 ID/版本、产生时间及 evidence availability。源被截断/删除时保留已知 provenance 并显示 unavailable；不得伪造一条可点击的证据。`Adoption` 与 `Outcome` 的实现尚缺，交付不得用字符串标题关联来替代稳定 ID。

## 产品闭环的实施顺序

1. **纠正记忆与信号。** 明确约束→Candidate、手工确认/supersede、scope-safe Recall；同时收敛 near-miss 与重复 sequence 检测。退出标准是 R-05/06/09/12 的真实输入/负例验证。
2. **连接候选、对照和采用。** Suggestion→相同条件 Lab，显式拒绝坏候选，采用记录绑定版本。先完成一个 verification workflow 垂直路径，不先扩一整套通用 Agent framework。
3. **完成未来 Session 消费。** 用户可审阅接入方式，记录提供的 Memory/Rule/Workflow 版本和实际消费 evidence。一个 harness 跑通后再分别验证三个支持边界，不能从 CLI MCP 黑盒测试外推。
4. **持续改善证据。** 记录适用任务与未观测样本，按 [纵向协议](ACCEPTANCE.md#未来会话与重复摩擦) 判断改善、退化或证据不足。
5. **关闭六 Gate 缺口。** 性能、故障、权限、隐私、迁移恢复与包装逐项通过，不能用增加 UI 功能替代。

本顺序不授权自动外发、执行用户真实项目脚本或改变已批准技术栈；仍遵守适用权限边界。未来实现计划不算当前状态。

## 本轮开发增量（不覆盖已发布基线）

上述矩阵固定在 preview.2，用于保留本次验收发现的缺口。其后工作树中的 `explicit-engineering-v2` 已增加：明确 verification 长期约束→有来源 Candidate Memory、受控纠错正负例、同项目至少三个不同 provider Session 的 Codex 工具顺序→禁用的 Workflow draft，以及 `verificationCandidateMemoryIds` 供候选评测关联。现有 parser 缺少可验证工具参数时不做 sequence 推断；工具调用不等于测试成功。重复日志文件不能充当独立 Session，重分析不激活或覆盖已审阅记忆。

本轮 [ImproveAcceptanceTests](../Tests/VelaCoreTests/ImproveAcceptanceTests.swift) 的九项方法已分别通过 portable runner，覆盖确切来源、near-miss、范围、复制日志、无执行和安全读取；该次整体套件因另一个 Lab 命令构造问题未全通过，不把局部通过写成整体通过。R-05/09/12 的这些子能力已从缺口进入已测实现，**完整需求和 GS07/09/10 仍未通过真实主场景验收**。Lab/Reuse 的新增实现、协议替身测试与真实模型试跑必须分别附证据，不能用此段的九项结果代替。

## 产品完成定义

[20 步 Golden Scenario](ACCEPTANCE.md#20-步-golden-scenario) 是完整产品的必要条件，六 Gate 是不可抵消的底线。既要有单次可回放链，也要有适用未来 Session 的真实结果。只有因源码缺口完成修复、对应测试和证据齐全时才能将 Partial/Missing 升级；不能以官网上线、README 截图、导航入口数或测试总数作替代。
