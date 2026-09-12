# Vela 产品验收 / Product acceptance

**基线：2026-09-12，`6c2bf54` / `0.1.0-preview.2`。结论：完整产品 No-Go；开发预览的历史发布事实不变。** Golden Scenario 尚未整链执行，六 Hard Gate 未全部通过，Scorecard 为 **Not Scored**。本文件是可执行的验收协议与缺口记录，不是未来结果预测。

**English:** A complete product requires every Golden Scenario step and all six hard gates. Existing component, renderer and packaging checks retain their limited scope. Missing evidence is not a pass. No future correction-rate reduction, token saving or agent-quality improvement has been measured for this baseline.

## 状态与证据规则

实现使用 `Implemented / Partial / Missing`；验收使用 `Pass / Fail / Not Run / Blocked`。实现完整也可能未验收。下表的 `Partial` 都指实现，不是半个 Pass。Golden 的单步组件证据只作 support，只有同一次可追溯的真实运行才可填入该步 Pass。

每次验收保存：commit、app/helper 版本、OS/硬件、harness/CLI/model/version、project/commit、fixture 来源和 manifest、配置与预算、执行命令/时间、源 Session/Message/Tool IDs、候选/审批/Run/Eval IDs、原始输出/指标、失败与清理记录。私有数据只在用户控制的位置保留；公开报告使用脱敏数据和哈希。截图证明呈现，不独立证明落库、执行、范围隔离或 Agent 采用。

证据索引 `E-*` 与测试索引 `T-*` 见 [TRACEABILITY](TRACEABILITY.md#代码测试与证据索引)。现有 preview 测试不在本文件重跑；新改动必须附新的运行记录。

## 本轮增量与判定更正（2026-09-13）

下方 20 步与 Hard Gate 表保留 preview.2 基线；本节记录其后的实现和实际证据，避免把历史 `Missing` 当作新代码不存在，也避免把局部完成替换为整链 Pass。**当前完整产品仍为 No-Go，Scorecard 仍为 Not Scored。**

| 涉及步骤 | 新增实现或证据 | 当前仍缺什么 |
| --- | --- | --- |
| GS07/09/10 | 明确长期 verification 约束可自动产生 Candidate；严格工程纠错、near-miss 与复制日志去重已有九项专项回归；三个不同 Codex provider Session 的真实工具事件顺序可产生未启用 Workflow draft | 仅受限确定性 detector；不能证明泛化 precision、所有 provider、完整自然语言规划；不是同次真实 Golden 来源链 |
| GS13–15 | `sourceSuggestionId` 与精确文件或关联 Memory 绑定；Agent Lab 冻结 task、requested model/reasoning、commit、超时、两组上下文、受保护 verifier 与输出 allowlist；两边各三次真实 Codex 运行已执行；新界面 Suggestion→Lab→真实 pending approval 已在六组套件通过 | 新 UI 测试止于冻结待审批，没有执行 Agent；provider resolved model version 为 null；六次真实实验候选是专门准备的 fixture，不是 GS06 自动提取后一路生成 |
| GS16/17 | 本次真实运行两边各 3/3 独立任务检查通过；计分修正后两边各 3/3 观察到测试调用，结果 **Inconclusive**；实际 `lab.promote` 拒绝，Memory 仍 Candidate | 此结果证明同分不应晋升，未证明 tests 增加、corrections 减少或有效候选的 Promote 正向主线 |
| GS18–20 | Codex 项目 SessionStart Hook 可预览、经受审 Apply 安装，active Recall 可记录 provider Session 与 Context hash；后续关联提供来源记录 | Hook 的 stdout 仅证明提供上下文；真实 Codex trust/自动消费/行为遵循与未来 RFR 均未验收；一次 hook fixture 不能补齐三步 |

### 真实 Agent 实验：保留失败计分与更正

Eval `938a7aa2-0bc7-416a-9437-e08b1240d9c4` 于 **2026-09-12 15:46:26–15:52:57 UTC** 执行，CLI 为 `codex-cli 0.154.0`，请求 `gpt-5.6-sol` / `high`，provider resolved version 未返回。任务是受控 `clamp` 实现 fixture；三次 baseline 与三次 candidate 交替运行，使用同一冻结 commit 与独立 verifier。六次原始 provider Session ID、JSONL、冻结审批和输出均保留。

旧计分只识别简单 argv，漏记实际复合命令中的测试调用，将测试行为错误计为 baseline 0/3、candidate 2/3，并给出 `ready_for_review`。这不是可接受的产品成功。`codex-test-observation-v2` 从同一六次 raw JSONL 重算为 **3/3 对 3/3**；独立任务验证仍为 **3/3 对 3/3**，结论更正为 **`inconclusive`**。旧摘要保留在 `previousAnalysisSummary`，旧文件没有用新结果覆盖。

本 fixture 的平均 provider tokens 为 baseline **142,437.333**、candidate **108,768.667**；不从六次、单任务、未知 provider resolved version 的差异推导普遍节省、统计显著改善或未来纠错减少。Corrections 与 future effect 保持 unavailable / not measured。运行报告显示原 Git 状态相同且 cleanupFailures 为空；当时的状态比较并非任意已脏文件内容完整性证明。

原 `evaluation.json` 的 SHA-256 为 `893627063b69d36d6eb98d9a36e1f0ea737ea09aaddf895329b81834a937b298`；v2 `evaluation-reanalyzed.json` 为 `ebc088bc30cd441be022e6732ccb14532224ec2d4b530ea80121eddf41abdd56`。本地 raw 工件包含工作目录等信息，不直接作为公开包资源。[公开脱敏实验记录](evidence/2026-09-13-agent-lab.json) 使用更保守的 `codex-test-observation-v3`，在成功的复合脚本中才接受首条测试调用为观察，重算结果仍 Inconclusive。报告保留冻结 task/commit、两个二进制 hash、六条原始输出 hash、测试 argv、真实独立退出码及拒绝晋升记录；这六个 raw hash 与冻结 task hash 已逐项核对。重新执行入口为 [test-agent-live.py](../scripts/test-agent-live.py)，会产生新的真实模型运行和费用，不能当作重算旧数据的同一实验。

### 增量验收待项

最终源码 `91d34e2` 的 [macOS CI](evidence/2026-09-13-ci-final.json)实际通过 95 项 XCTest 和 18 组 renderer 检查；[原生组件验收](evidence/2026-09-13-ui.json)确认隔离 wrapper 的两种窗口布局与 Reuse Preview/Apply/重开/Undo 持久化；[开发包审核](evidence/2026-09-13-package.json)通过资源、签名完整性和归档检查。这些新增证据不改变整条 Golden 的 Not Run、完整产品 No-Go 或签名/公证缺口。

- 曾有一次 81 方法运行出现三个 Agent Lab 执行失败，原因是配置标量 JSON 编码；修正后已有 90 方法的中间 portable 快照通过。随后仍有 scorer、旧结果重算、Usage 与 Reuse 关联改动；**中间通过不继承为最新工作树通过**。
- 最终回归须同时检查 `lab.list` / `lab.compare` / `evidence.get` / `lab.promote` 对旧结果使用相同计分，旧 ready 修正后不能激活，顶层及逐次 tokens 的 null/真实零一致。复合命令有语法错误或状态不明时不能凭前缀断言测试实际执行。
- Reuse 关联必须同项目、同 provider、同原生 Session ID；复制日志只能算一次匹配会话。旧无 provider 收据仅兼容可识别的 Codex Hook 记录，未知来源不做正向归因。
- 本轮 release 100k 六类 warm 搜索 p95 为 57.127–77.873 ms，已修复旧 132.33 ms 超标场景；HG-1 整关仍 Not Run，冷启动、真实五 Agent 并发、长期资源与 event→UI 分布未齐。详见 [参考与证据盘点](reference-comparison.md#performance-matrix-to-run-before-a-hard-gate-decision)。
- 原生截图、真实声音试听、网页检查与打包仍分别验收；不代替来源导航、数据落库、Agent 执行、后续使用和六 Hard Gate。

## 20 步 Golden Scenario

主线采用一个有真实测试的 Git 项目、Codex 与可审阅 verification 候选；跨 Claude Code/Cursor 的兼容验收另列。准备期间不能手工填入本来应该自动产生的 Memory/Cluster/Suggestion，并将其当自动步骤通过。

| GS | 用户操作与必须证明的结果 | Req / Design | 当前实现；整链验收 | 现有 support / 尚需证据 |
| --- | --- | --- | --- | --- |
| 01 | 启动真实 Codex，记录 CLI/版本/登录能力与 project | R-01 / D-01 | Partial；Not Run | 检测入口存在；需真实启动记录，不以 fixture JSONL 代替 |
| 02 | Vela 自动发现此 Session，无手工 refresh/DB 插入 | R-01/03 / D-03 | Partial；Not Run | T-ING 的 FSEvents 合成日志通过；需关联 GS01 source ID |
| 03 | Agents 在预算内显示 Running，显示证据/推断来源 | R-02/19 / D-02 | Partial；Not Run | 日志状态推断，缺进程存活及 event→UI p95 |
| 04 | Codex 修改本任务项目代码 | R-03 / D-03 | Partial；Not Run | 必须读取真实 Git diff/Tool 事件及 task 关联 |
| 05 | 正确记录 Messages、Tool Calls、Changed Files、Todo | R-02/03 / D-02/03 | Partial；Not Run | 已知消息/工具子集；完整同一 Session 逐事件比对缺失 |
| 06 | 用户提出“以后完成任务之前一定先跑测试” | R-05/09 / D-05/09 | Partial；Not Run | 需真实 user Message ID 与范围；例句只是测试输入 |
| 07 | 自动提取 Verification Preference/Constraint Candidate Memory | R-05/06 / D-05/06 | Missing；Not Run | 手动 Message→Memory 通过 E-UI，不替代自动提取 |
| 08 | 新 Session 再发生“怎么又没测试”的明确纠错 | R-09 / D-09 | Partial；Not Run | 需不同真实 Session；重复摄取同记录不得加次数 |
| 09 | 多条确切记录聚成 Verification Cluster | R-09 / D-09 | Partial；Not Run | T-IMP 测 distinct evidence/幂等；完整五-session/near-miss 质量集未跑 |
| 10 | 建议建立适用的 verification Workflow 或有理由的 Rule/Hook | R-10/12 / D-10/12 | Partial；Not Run | 现有程序型 Markdown 草案不是已保存可执行 Workflow |
| 11 | 用户点击该 Suggestion 的 Evidence | R-10 / D-10 | Partial；Not Run | evidence API 存在；需要此次来源对象导航记录 |
| 12 | 精确回到原始 Session 与 Message | R-03/10 / D-03/10 | Partial；Not Run | 引用文本不能替代稳定 ID；源不可读时明确 unavailable |
| 13 | 用户从该候选点 Test | R-10/15 / D-15 | Missing；Not Run | 独立 Lab 页面不足；需源候选 ID/版本关联 |
| 14 | Lab 建立明确 baseline/candidate 并冻结差异 | R-15 / D-15 | Partial；Not Run | T-LAB 真实命令配对支持；需候选的真实 Agent 实验 |
| 15 | 同 repo、commit、task、harness、model、reasoning、timeout、budget | R-15 / D-15 | Partial；Not Run | 当前 commit/command/timeout 配对；task/model 等未锁定 |
| 16 | 实际对照支持 tests 增加、corrections 减少，tokens 无不可接受恶化 | R-16 / D-16 | Missing；Not Run | exit code/runtime 不是这些指标；差异也可能 Worse/Inconclusive |
| 17 | 用户基于结果 Promote；坏候选可以 Reject | R-17 / D-17 | Missing；Not Run | 需 adoption 绑定 eval、目标版本、权限与撤销语义 |
| 18 | 后续新 Session 自动 Recall 适用 Context | R-07/17 / D-07/17 | Partial；Not Run | MCP 可调用；无自动消费实证，不能把返回 JSON 当采用 |
| 19 | Agent 实际按 verification 要求执行并报告真实测试 | R-13/16/17 / D-13/16/17 | Missing；Not Run | 需工具执行、测试结果及所用 Context 版本，排除用户再次提醒 |
| 20 | 后续适用 Session 重复纠错发生率下降，并可追到前述改变 | R-17 / D-17 | Missing；Not Run | 无纵向 outcome 数据；不得编造下降率或承诺一定下降 |

**终止规则：** 任一步缺实现、缺来源、被人工替代自动动作或条件失配，记录阻断并保留已获得证据；不把后续模拟补齐为 Pass。GS16 若候选变差，正确拒绝是 Verify 负例通过，但这次候选不进入 GS17–20 的“有效候选”主线。

## 五个核心承诺的专项验收

| 承诺 | 输入和反例 | 通过判据 | 当前状态 |
| --- | --- | --- | --- |
| Observe | 同时 2 Codex + 2 Claude Code + 1 Cursor；分别 Running/Idle/Needs Approval/Finished；kill CLI、截断、轮转、坏 JSON | 项目/branch/worktree 正确；死进程不永久 Running；单一坏源不拖累其他；资源符合 Gate | Not Run；T-ING 只覆盖部分合成格式/增量反例 |
| Remember | Session 1 用 npm，Session 20 确认迁到 pnpm；A/B 项目相同关键词 | pnpm 为 Active，npm 可追溯为 Superseded 且不注入；B 无 A 私有项目记忆；缺新证据不擅自覆写 | Partial support：T-MEM 显式 supersedes/scope；自动提取到新 Agent 的整链 Not Run |
| Improve | A：5 不同 Session 明确要求测试；B：一次“这里不好”；C：正常 feature-spec 迭代与仅含 again/test 的近似文本 | A 有来源建议；B/C 不生成永久 Rule；重摄取不增证据；显示 reason，允许无建议 | T-IMP 覆盖单 Session/干净会话；完整质量集 Not Run |
| Automate | 3 不同 Session 实际工具顺序 git diff→test→summary；对照仅文字描述、顺序不同、跨项目 | 识别真实重复 procedure，产受审阅 Workflow；不是 AGENTS Always-on 追加；未批准不执行 | Missing / Not Run |
| Verify | AGENTS v1/v2 的同条件真实任务、多次运行；加入明确更差 candidate | 保留所有结果；成功/测试/纠错/tokens/runtime/tool calls 有来源；坏候选可拒绝，无依据则 Inconclusive | T-LAB 命令级支持；Agent 对照 Not Run |

质量评估使用在运行前冻结、标注到来源 ID 的 positive/negative/near-miss 集。分别报告 precision、遗漏、错误晋升及混淆表；样本数和标注分歧可见。未事先约定总体 precision 阈值时，不得自行编造一个百分比作为产品通过线；以上明确反例均须通过。规则检测与模型检测都遵守同一标准，不强制使用模型来代替正确性。

## 六个不可抵消的 Hard Gate

| Gate | 必须通过 | 现有证据与缺口 | 基线判定 |
| --- | --- | --- | --- |
| HG-1 Performance | 启动/CPU/总内存/交互预算；完整负载矩阵 | E-PERF：小样本 RSS/idle；100k warm RPC search p95 132.33 ms，高于 <120 ms 目标；多项缺测 | **Fail（已知搜索超标）**，其他项 Not Run |
| HG-2 Reliability | parser/helper 故障不能使 App 崩溃；有陈旧提示/恢复；有界任务和重启 reconcile | T-ING/T-PROC 有部分反例；helper 与多服务共享故障域；没有完整 kill/重启/长期压力记录 | **Not Run**（有 Partial support） |
| HG-3 Security | IPC/File/MCP/Workflow 的拒绝路径；权限不因模型文本改变 | T-SAFE/T-APPROVAL/T-MCP 已测多项；完整恶意 Markdown、超大 IPC、TOCTOU 竞争与全接口矩阵未齐 | **Not Run**（不能把部分安全测试作全 Gate Pass） |
| HG-4 Privacy | 默认 local-first，无默认正文外发；Private 在所有 Agent 路径不可达 | T-PRIVATE/T-MCP 和关闭 telemetry 的代码支持；缺 packaged-app 默认网络流量实测及所有新增消费路径复验 | **Not Run** |
| HG-5 Data Integrity | Apply/Undo/并发编辑/崩溃/DB migration 不丢资产；失败可诊断恢复 | T-SAFE/T-STORE 覆盖 journal、批次补偿与 CAS；跨版本升级/故障注入矩阵缺失 | **Not Run** |
| HG-6 Packaging | 实际交付包无测试、开发源码、内部计划、密钥、私有元信息；清单可复验 | E-PKG 记录 preview.2 实际包 allowlist/排除审计通过；仅指该产物，源码 checkout 和必要运行 UI JS 不属于禁打包“开发源码” | **Pass，仅限记录的 preview.2 包**；新包必须重验 |

任何 Fail、Not Run 或 Blocked 都不能得到完整产品 Go。HG-6 不替代正式发行要求：当前 ad-hoc 包未 Developer ID 签名、未 notarized，安全可恢复的自动更新尚未验收；macOS 13 兼容性及 OS 通知投递另需实际安装验证。

### 必做破坏性反例（只使用合成允许根）

1. 路径 `../../.ssh/id_rsa` 必须被路径规则拒绝；使用临时目录中的同名 sentinel，不读取用户 `.ssh`。
2. 合成项目 `link` 指向临时项目外 sentinel 目录，写入必须拒绝，sentinel 内容/身份不变。
3. 建议生成后手动改目标文件，再 Apply 旧 hash：必须 Needs Review、原用户改动不变。Undo 前编辑亦同。
4. 将破坏性 command 作为**不执行的冻结 payload**提交：批准前没有执行/写入；Dry Run 为 stub；拒绝后不执行。不得为验收真实执行 `rm -rf`；若需要执行器覆盖，使用记录调用的无破坏 fixture 工具。未知工具不能“先执行看看”。

## 性能矩阵与测量

预算沿用 [requirements.md](requirements.md#5-性能预算与测量方式)：窗口 p95 ≤1.5 s、可用 ≤2 s；idle CPU <0.5%；宿主+watcher RSS <120 MB、正常 GUI 总 RSS <220 MB；event→UI p95 <300 ms、tab <50 ms、session open <150 ms、100k records search <120 ms。记录单位 MB/MiB，不用共享内存重复/漏算掩盖结果。

每 release 至少覆盖如下负载维度，保存实际覆盖单元，未跑单元不得默认通过：

| 维度 | 规定水平 | 测量 |
| --- | --- | --- |
| Session 数 | 10 / 100 / 1,000 | cold start、全应用 RSS/idle CPU、search、打开会话 |
| 单 Session 文件 | 1 / 10 / 50 / 500 MB | 初次摄取、增量 append、坏行/超长行、打开首屏、event→UI |
| 消息数 | 10k / 100k | 摄取吞吐/内存上界、历史完整性标记、search/会话打开 |
| 并发活动 | 指定五 Agent 场景；后台 Improve/Lab 开/关 | 实时状态延迟和 UI 响应是否受阻 |

大型源超出保留窗口时，以正确且明确的截断/回填状态验收资源限制，不能以静默丢历史宣称“完整摄取”。分别报告冷/热缓存、硬件/OS、release/debug、进程集合、样本数、p50/p95/max；旧 4-session 的五次 idle 采样不够估计长期资源，旧 50 次搜索结果只证明那组 warm RPC 负载。原附件 0.3%→4.8% 是示例，不是 Vela 实测。

## Agent 对照实验协议

冻结 repo/commit、任务说明与来源、harness/版本、实际 model identity/reasoning、timeout/budget、依赖准备、工具/网络权限、baseline/candidate 版本。相同 provider 不能确认模型版本时标 unknown，不称 Same Model。只改待验证变量；两边独立 worktree，不把 baseline 结果泄漏给 candidate；交换运行顺序并记录可能的缓存/外部状态差异。保存失败、超时、取消及未完成样本，不选择性丢弃。

Tests 以实际执行及结果计，Task Success 使用预先定义的任务检查；Rule Compliance/Corrections 要有明确适用条件与消息证据；Tokens 使用 provider 可归因数据，无数据填 unavailable；Runtime/Tool Calls/Retry/Unrelated Changes 各自保留来源。设定可接受的 token 成本恶化界限与成功判据后再运行；当前没有获确认的阈值，因此不报告显著改善。1–5 次命令运行不代表稳定 Agent 成功率。

候选的产品判定为 Better / Worse / Inconclusive / Unavailable，并展示理由与样本。坏候选被 Reject 是必要负例。即使 Lab 显示 Better，也不能自动称未来重复纠错减少；后者需要下一节的独立证据。

## 未来会话与重复摩擦

对问题 `i` 和已冻结的适用 scope/任务规则，在声明的未来观察窗口中定义：

`RFR(i) = 再次发生同问题的适用 Session 数 / 可观测且适用的 Session 数`。

同 Session 多次重复只计一次该问题；同时另报纠错事件数。分母不包括无法判定是否适用或日志缺失的 Session，这些必须单列为 unknown；分母为零显示 unavailable。每项记录 issue/cluster、detection version、adopted artifact/workflow version、provided context IDs、session IDs、反例证据、观察起止、harness/model/task 类别与覆盖率。

比较采用前后时报告分子/分母、样本量、任务难度和工具/模型/用户行为变化；没有可比条件，只能称观测变化，不能因果归于 Vela。冻结任务集的配对实验与真实纵向使用分别报告。规则“没有再被提起”可能是用户放弃或日志缺失，不自动算改善。当前 **没有 RFR 实测结果**。

## 完整性表与 Scorecard

逐项模块及原始 FR/NFR 状态见 [TRACEABILITY](TRACEABILITY.md)。22 个模块不是 22 个已完成勾选项。

| 评分域 | 用户指定权重 | 当前 |
| --- | --- | --- |
| Observe | 15 | Not Scored |
| Memory & Recall | 20 | Not Scored |
| Improve Quality | 20 | Not Scored |
| Workflow Automation | 15 | Not Scored |
| Lab Verification | 20 | Not Scored |
| UX & Performance | 10 | Not Scored |

评分前先定义每域 rubric 并具备测试证据，不能按代码量或按钮完成率填分。用户给出的分段为：90+ 对应 v1.0 Product Complete，80–89 Public Beta，70–79 Private Beta，<70 Alpha；这些标签只在六 Gate 满足后参与候选版本判断。完整产品仍须 Golden 全通过；90 分不能抵消缺少 GS18–20。当前不追溯重命名已发布开发预览，也不声称它达到 Public Beta。

## Definition of Done

真实开发者连续使用受支持 Claude Code/Codex/Cursor，Vela 能观察、记住正确工程事实、发现重复纠错与操作、形成受控 Context/Workflow、在真实任务中验证、在未来任务中复用，并证明改善或诚实报告证据不足。性能、安全、隐私和数据完整性没有被牺牲。只有“保存、生成、测试界面”而没有这条可回放链，仍未完成原始构思。

### 当前核心与六组界面回归快照（2026-09-13）

`swift build` 与 portable runner **95/95 方法通过**，包含 Reuse provider/复制索引关联、复合脚本语法失败未知值、旧评测所有读接口重算及拒绝晋升，以及已安装/已应用 Hook 预览的两项真实文件回归。核心使用 `codex-test-observation-v3`；`originalGitStatusUnchanged` 只声明 Git 状态相同，文件内容等价未测。真实 RPC/MCP 与无换行巨帧恢复通过。原生包和 hosted XCTest 结果独立记录，整体 Golden/Hard Gate 仍未通过。

[六组真实 renderer→CLI 套件](verification.md#six-renderer-to-cli-acceptance-checks)使用同一次全新合成 fixture 通过 **6/6**，`completeSuite: true`，56 次 Core RPC 无错误；运行前后 UI 文件哈希一致。其证据仅支持 Memory 状态过滤和真实激活、确切 Session/Message 来源、跨项目同 provider ID 不误链、Suggestion→Lab 冻结待审批、Reuse 文件 Apply/Undo 与缺失用量语义。Lab approval 在测试桥被拒，未转入 Core 执行；Hook 只修改测试项目文件且从未运行。该套件不能将 GS13–20 的同次真实 Agent 主线标为 Pass。

最后一行 Reuse 对话框文案调整后，于 **2026-09-12 17:37:16 UTC** 使用新的 `acceptance-flow-final` fixture 再跑全六组通过。最终 E-UI2 记录为本地 `output/playwright/acceptance-flow-final/results.json`，`app.js` SHA-256 为 `01104e7fbeef5c24a08af20fe70bd1934dc82f1446f7e16e230b03688ee3af0b`，helper 仍为 `bbeb97c8…e14d24483`。17:27:33 UTC 的中间通过与更早的两项产品失败记录均保留，没有用最终结果覆盖历史证据。

Reuse 初次诊断保留两项产品失败：已安装空操作草稿的预览被 Apply 数量校验拒绝；已应用草稿重开预览被过期 base hash 拒绝，导致无法进入 Undo。现仅对内部 Vela Hook 标记、确切项目路径及未变化观测 hash 提供无变更预览；已应用预览读取同项目已提交 journal。空 Apply 仍拒绝，Undo 仍按 journal 的 after hash 校验当前文件，外部编辑必须停止。两项 Core 回归与最终六组中的真实预览/恢复均通过；跨 scope 守卫另经源码复核，不扩大为完整恶意 journal/并发攻击矩阵已通过。原失败证据保留，成功与已解决失败的临时 fixture 均已清理。

[核心提交 8929967 的 GitHub macOS CI](https://github.com/Atingaii/Vela/actions/runs/34705822040)已实际通过 **93 项 XCTest、0 失败**，以及仓库/资源、RPC/MCP、巨帧、强杀重启和打包检查。首轮 XCTest 的两条记录来自预期异常被 `XCTUnwrap` 另行记错的测试辅助函数，已保留失败运行并修正测试，不曾放宽生产安全校验。该提交尚未包含最终客户端界面，不能代替后续 UI/打包验收。
