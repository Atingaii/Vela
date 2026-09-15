# Blume 功能对齐清单

初始核对：2026-09-13；本机复核：2026-09-15。目标是将 Blume 的已交付产品能力逐项补齐，再验证 Vela 的额外改进；本清单不以功能名称相同、页面存在或测试总数代替验收。

**当前结论：尚未达到 Blume 功能超集。** 既有实现包括 Pi/OMP 只读适配、Codex 官方账户额度、受审三阶段模型 Improve，以及公开配置清单和版本历史。会话续接、多 provider 真实账户额度、完整配置语义治理和实际改善效果等剩余项继续保留。

最新 [Blume 1.0.74 原生逐项核对](blume-native-audit-2026-09-15.md)覆盖 B01–B52 与 24 条本机观察；[结构化清单](blume-native-audit-2026-09-15.json)分别记录入口、执行及未确认范围。本轮只更新审查与证据，未合入 UI 重构。下文早期测试和未关闭项作为历史基线保留。

## 来源及判定规则

- **O：官方说明**：公开产品页、发行文章和文档明确描述，不把说明当独立实测。
- **N：本机观察**：2026-09-15 官方 Blume 1.0.74 的原生窗口、可访问性树和截图；N01–N24 见最新审查。只看到入口、成功操作、失败态和未确认分别记录，不把只读设置当后台执行成功。
- **R：用户报告**：仅使用指定目录顶层三份 Markdown 的产品功能描述；不读取解包源码、`harvest/`、随包内部文档或私有提示词。报告静态可见不证明服务端开关、当前账号或当前安装可用。
- **P：规划或受控开放**：官方明确 Soon/Next，或报告明确灰度未开放。保留为目标能力，独立记录，不伪装成当前已交付基线。
- **U：本次未确认**：没有足够公开发布或独立运行证据；不推导“产品没有”。
- **V：Vela 源码及测试**：下表“已有”仅描述代码行为；各验收还需要明确版本、输入、输出及运行记录。

公开来源：

| 来源 | 读取内容 |
| --- | --- |
| [O1：Blume 首页](https://blume.codes/) | 五 harness、Agents/Setup/Usage、产品路线图 |
| [O2：1.0.56 发行文章，2026-07-27](https://blume.codes/blog/you-already-told-your-agent-that) | Improve beta、Search、Setup 细节、状态修正、引导 |
| [O3：Improve 使用说明，2026-07-15](https://blume.codes/blog/how-blume-codebase-improvements-work) | Connected plans、触发时机、配置范围、提案与回滚 |
| [O4：Claude Usage 指南](https://blume.codes/docs/claude-usage-mac) | 登录缺失与 Keychain 拒绝的独立修复路径、账户和窗口 |
| [O5：隐私说明](https://blume.codes/privacy) | 本地存储、provider 用量直连、云处理与本地控制 |
| [O6：Docs 目录](https://blume.codes/docs) | 本次公开文档覆盖范围；该目录没有列出全部模块指南 |

用户报告标记：**R1**=`Blume-Sidecar-完整逆向报告.md`（功能矩阵 §5）；**R2**=`Blume-Sidecar-模块详细说明.md`（B–O 产品模块）；**R3**=`Blume-Sidecar-技术架构与细节处理.md`（可靠性与数据边界）。这些标记说明需求来源，不发布其私有实现或引用内部提示词。

**发布状态冲突已处理：** 首页 Auto-Fixes 的 Soon 标签不能覆盖带版本和日期的 Improve beta 发行说明。增量建议、证据、Apply/Snooze/Dismiss 按“官方已交付 beta”列入基线。Analytics 在 1.0.74 已有可访问页面（N12），旧 Soon 标签不能继续代表其全部当前状态；非空趋势/效果仍未验证。Domain Model 与完整 Auto-Improve Mode 继续保留公开规划及未确认状态，自动处理设置不等于自动效果验收。7 月 Improve 文章对“本地”的表述也不能解释为模型厂商完全不收请求；Vela 需按实际 CLI 出站路径核验。

## Agents 与会话

| ID / 功能子项 | Blume 来源 / 状态 | Vela 实现位置与状态 | 未关闭的验收项 |
| --- | --- | --- | --- |
| B01 五 harness 发现 | O1：Claude、Codex、Cursor、Pi、omp | `FoundationService.agentList` 现列五种；Pi/OMP 本轮新增 | 真实已安装/未安装、GUI PATH 差异、非安装遗留目录的识别 |
| B02 Claude 消息摄取 | O1 已交付；R2 B2 补充格式需求 | `SessionEngine.mergeEvent` 支持常见 JSONL 消息/工具 | 按官方 CLI 版本维护 fixture；子代理、附加事件不能用一个 fixture 代表全兼容 |
| B03 Codex 消息摄取 | O1 已交付 | `SessionEngine` 处理 meta/context/response/event | 版本化协议、旧日志、完整输出类型和累计数据一致性 |
| B04 Cursor 消息摄取 | O1 已交付 | 已知 composerData SQLite 及导出 | 拆分 bubble、当前 schema、导入与实时状态分开验证 |
| B05 Pi 会话 | O1 已交付 | 本轮 `PiSessionReader`；v1 线性、v2/v3 树 | 真实 CLI 版本 fixture；未知版本保旧数据，格式支持不是运行中证明 |
| B06 OMP 会话 | O1 已交付 | 同一 reader 明确区分 provider；title slot、v1/v2/v3 | 标题原位变更、已迁移目录、provider 扩展角色/外置内容兼容 |
| B07 增量摄取、完整历史访问 | R2 B3–B4：报告描述 | 默认 FSEvents/轻量尾窗不变；新增四 JSONL provider 显式 manifest、版本 epoch、SQLite 断点、原文分块和稳定分页，见 [合同](../implementation/session-history-contract.md) | 已完成冻结合成数据的 History renderer 范围验收（发现、导入控制、分页、原文、分支及项目切换），见 [UI17](ui17-final-renderer-evidence-2026-09-13.json)。Cursor 一致性历史、超长 header/其他角色、跨源检索、保留维护、大型性能与完整真实 provider 历史仍待验收；raw、normalized、scope、branch 完整性分开 |
| B08 持久化分支、工作区身份 | R2 B6/B9：报告描述 | canonical 项目路径；Pi/OMP 默认显示最近持久化链，显式历史保留全部原始分支和父链分页 | Git remote/worktree 关系；内存 leaf 无来源时不得猜；子会话实体关系与完整 UI 另验 |
| B09 Running/Idle/Completed/Stopped/Error | O1/O2 已交付 | Claude/Codex 活动推断；Pi/OMP 仅明确 stopReason 终止态 | 五真实进程并发、停止/重启/中断/旧日志，不将推断视作进程存活 |
| B10 待审批与完成提醒 | O1/O2 已交付 | `NotificationPolicy`、原生通知已实现；权限失败实测保留 | 真 macOS 授权、banner、点回准确会话；五 provider 的真实等待/完成事件 |
| B11 工具调用及结果 | R2 B5/B9：报告描述 | Claude/Codex 常见工具；Pi/OMP 关联 toolCallId、name、结果和错误 | 起止时间、结果缺失/重排、并行 call、多个 tool 类型、完整参数显示 |
| B12 Todo / 计划进度 | O2 已交付 | `SessionPlanProjection`/`SessionPlanService`：Codex update_plan 与 Claude TodoWrite/四 Task 工具的已知调用/结构化结果→独立有界 ledger、确认计数及来源事件；CLI/会话详情可读。[合同](../implementation/session-plan-contract.md) | 普通正文/会话 Completed 不推导计划完成；提案、失败、未知与 provider 确认分开。冻结合成数据的 Plan drawer 状态、事件分页和延迟响应路由已验；UI17 全部项目 scope 是已复现问题。完整 History 投影、全 provider/version（含未获官方合同的 Claude camelCase transcript）、真实 provider 和完整 UI 仍待完成，不以此关闭 B12 全量验收 |
| B13 子代理关系与状态 | R2 B9；N04：本轮仅空状态 | `SessionRelationProjection/Service` 新增 Codex 固定公开版本的直接父声明、独立 fork、配对 spawn 回执、同项目来源解析、关系 epoch、只读分页与父子独立状态；[合同](../implementation/session-relations-contract.md) | 冻结合成数据的 Codex drawer 展开、隐私、分页、陈旧响应/重复 cursor 与支持尺寸已验，见 [972 CI](ci-972155b7-evidence-2026-09-13.json)；后台刷新收起已展开区域是单独的 UI17 已复现缺陷。仍限已索引窗口，其他 provider、v2/code-mode、完整历史图、实时子进程和原生完整流程未验收。缺失/私有/internal/冲突/重号不猜验证成功 |
| B14 标题/摘要/元数据生成 | O5 描述功能处理；R2 B9 补充 | 首条用户消息或源标题；无模型摘要生成 | 显式处理设置、来源标题保护、模型可用性与错误；生成结果不能充当事实 |
| B15 手动改名、恢复/回写标题 | R2 B9：报告描述；公开交付 U | OMP/Pi 标题只读，尚无修改接口 | Vela 名称与 provider 原名分离；冻结写入、原格式验证、Undo |
| B16 项目/路径模式排除与恢复 | N17：Behavior 专页有路径/glob、选择目录、影响说明和恢复说明；未执行真实索引删除 | `IngestionExclusionService` 已有 list/upsert/remove、投影撤回与规则代际检查；桌面 UI/bridge 未接通 | 接通已有服务；预览影响、添加/移除、恢复、搜索和 Recall 隔离与多克隆边界逐项测试 |
| B17 同 harness Continue | R2 会话操作：报告描述；公开交付 U | Checkpoint 的中立说明文本；没有直接启动原生 resume | 真实 provider resume ID、终端身份、用户确认、错误与恢复 |
| B18 跨 harness Transfer/Continue | R1 §5 明确灰度 0%；当前公开 U/P | `MemoryService checkpoint.export` 不是原生会话迁移 | 源快照→目标兼容格式/中立受控上下文→实际继续任务；保留全部目标，不冒称已公开基线 |
| B19 内嵌终端 | R1 §5/R2 G：报告称可用；公开 U | 无通用交互式 PTY；`AutomationProcess` 只执行冻结请求 | PTY、尺寸、输入/输出、停止、重连、端到端进程回收及有限权限 |

## Setup、Search 与 Improve

| ID / 功能子项 | Blume 来源 / 状态 | Vela 实现位置与状态 | 未关闭的验收项 |
| --- | --- | --- | --- |
| B20 Rules/Skills/Hooks/MCP/指令清单 | O1 已交付 | `SetupCatalog` + `SetupInventoryService` 的版本化五 harness 原生公开位置、项目/global 观察、来源 URL、JSON/Markdown 脱敏与重复字节关系 | 自定义/profile/managed/插件位置、完整跨范围继承、当前有效值来源；磁盘存在不等于运行时加载 |
| B21 类型详情、关系、诊断、历史 | O2；N07/N08：Content/Related/Details 实际可进入；块编辑入口可见，本轮参考保存未验 | 既有脱敏版本/历史/diff/关系及项目 instruction/skill 编辑。2026-09-15 新增一条原生标题块编辑→差异→冻结审批→精确写入→Undo 完整字节恢复，[证据](../evidence/2026-09-15-blume-native-comparison.json) | 原生单路径不等于全部类型和故障矩阵；编辑/审批/Undo 的文档上下文仍需重构。TOML/YAML、混合认证内容、完整类型语义及最近100条以外编辑历史继续待验 |
| B22 配置审计与模型判断 | R2 D：18 检查的报告，公开覆盖 U | `setup.audit` 仅格式/重复/保守大小 | 语义冲突、失效引用、MCP 漂移、规则适用性；原创检查+正负例，不复制私有 catalog |
| B23 周期审计、抑制与重新出现 | N13：自动 Setup audit 开关和 Weekly 频率入口已见；执行未验 | 未有单独完整审计策略与桌面入口 | 频率、停用、Dismiss 抑制、源变化重评、无新证据不反复推送；不以设置存在宣称后台成功 |
| B24 Artifact 导出/同步/冲突恢复 | R2 C：报告描述；公开 U | Markdown 资产与 SafeApply，无同等跨设备同步 | 所有权、加密、合并冲突、离线恢复；不要将本地文件可读写成同步完成 |
| B25 多对象全局搜索 | O2 已交付 | `VelaStore.search` +全局 UI，项目/会话/Memory 等 | 覆盖全部目标对象、精确消息、高亮、键盘筛选、旧记录分页 |
| B26 Raycast 快速入口 | R1 §5/R2 H：报告称可用；公开 U | 没有专用 Raycast 集成 | 搜索协议、离线启动/返回准确会话、最小权限 |
| B27 增量纠错/引导/摩擦识别 | O2 beta 已交付 | 保留确定性检测；本轮 `ModelImprovement` 增加经审批的 Codex 语义提取 | 真实多语言、间接反馈、近似负例与效果验证；模型提取不能替代来源核验 |
| B28 跨会话聚类、证据保留、触发阈值 | O2/O3 beta 已交付 | 确定性键/来源去重；新增结构化模型聚类和严格前阶段 ID 引用 | 真实语义相近/冲突验证、持续增量重跑去重；目前显式选择会话运行 |
| B29 模型规划 create/update/remove | O3 beta 已交付 | 三阶段模型 pipeline；五载体的显式目标创建/替换、diff/evidence；一次真实 Codex 合成来源验收通过 | 删除规划、现有配置关系/语义保持、实际任务改善与原生入口仍未关闭 |
| B30 Connected plans 选择 | O3 已交付 | Lab 与模型 Improve 可显式选择 Codex CLI/model；无其他分析 backend | Claude/Cursor 实际执行，requested 与 observed model 分开、版本/费用来源和失败分类 |
| B31 手动、空闲与额度末段触发 | O3；N13：空闲/额度窗口/关闭模式实际可见，后台执行未验 | 确定性分析水位；模型 pipeline 为 manual-only，三请求/时间/字节预算 | 真实 idle/额度、背景 opt-in、预算、取消与去重；缺配额不能触发假事件 |
| B32 Harness / project / global / 类型范围 | O3；N13：来源、项目/global、Rules/Hooks/Skills/Docs 设置已见；未改变 | 同项目模型输入、显式 carrier/path 和冻结协议 | 完整范围/多 harness 选择策略、禁用范围不可进入提案；新增 harness 不得扩大授权 |
| B33 Evidence、Diff、Apply、Undo | O3 已交付 | `SafeApply`；模型候选另要求新鲜 suggestionHash/project/原引用校验，独立 Apply/Undo | 更全 target 类型、真实审阅可用性与故障点；不能声称任意外部副作用 exactly-once |
| B34 Snooze/Dismiss/Resolved 与修订 | O2/O3 已交付；修订 R2 | 模型候选已支持带 hash 的 Snooze/Dismiss/Reopen，applied 不能被这些状态隐藏 | Snooze 到期、Resolved 证据、用户修订后重新冻结、跨阶段冲突保全 |
| B35 Cloud Improve 与撤销同意 | O5：有显式开通前条件，P | 没有 Vela 云 Improve | 仍保留能力；实现时独立 consent、退出、不自动 fallback、可审计数据流 |

## 用量、桌面产品与其他功能

| ID / 功能子项 | Blume 来源 / 状态 | Vela 实现位置与状态 | 未关闭的验收项 |
| --- | --- | --- | --- |
| B36 Claude 账户窗口与连接修复 | O4 已交付 | `usage.get` 只汇总本地 tokens；quotaAvailable=false | 登录缺失、Keychain 被拒、过期、限流和正常账户窗口均真实区分 |
| B37 Codex 账户窗口/重置 | O1/O5 已交付 | 官方 app-server 只读额度；规范化/fixture 及真实 Codex 0.154.0 账户读取成功 | 原生入口/刷新体验、真实错误与长期稳定性待验；其他 provider 未因此完成 |
| B38 Cursor 用量与额度 | O1/O5 官方说明；R1 提示部分灰度 | 无账户配额；Cursor 日志 usage 也不完整 | 版本与账号类型、额度含义、限流、过期，不能复用 token 总和代替 |
| B39 费用、历史快照、菜单栏用量 | O5/R2；N18：菜单栏与 Pinned 内容独立选择，状态数量/账户用量菜单已打开；真实费用未验 | `costAvailable=false`；无同等菜单栏用量 | 可追溯费用、币种、更新时间、重置/陈旧信息、菜单栏与窗口独立选择 |
| B40 窄 sidecar、固定、菜单栏 | N01/N18/N19：约400px窄窗；Pin→约180px悬浮条→展开→Unpin 实际往返 | 普通 AppKit 菜单栏/关窗保留，最小900×620；无同等窄窗或悬浮条。本轮普通置顶提案未合入 | 重新组织窄内容与完整工作区，三态保留位置/焦点，多屏/缩放/重启/关闭回收；仅置顶不算 Pin 对齐 |
| B41 首次引导与 auth guidance | O2 已交付；R1 旧开关存在歧义 | 手动加项目，未完整 provider-aware 引导 | 干净 Mac 首次运行，从发现/登录到第一条有效会话、撤销配置 |
| B42 自动更新及稳定/预览通道 | R2 N：报告描述；公开细节 U | dev/canary/stable 身份隔离；无已验证更新通道 | 签名、公证、下载验证、安装握手、失败回退和旧数据迁移 |
| B43 MCP read/contribute 与安装 | R1 §5/R2 J：报告称可用；公开 U | 受限 MCP read/contribute；手工配置 | 更全查询面/受限贡献语义、provider 安装预览/Undo、prompts，不能靠工具数量算等价 |
| B44 本地资料、退出/删除/账号控制 | O5 描述 | 本地 store；新增 CLI 完整备份/恢复，含私有资产、History 与 output；没有连接账户或完整桌面数据管理入口 | 备份、选择性删除、保留来源、连接撤销与私有数据全部入口隔离 |
| B45 反馈/功能请求与支持 | N22：支持聊天入口、请求列表/状态/评论/投票可见；未发送或投票 | GitHub Issues/社区文档，未内建同等入口 | 帮助/反馈可达、诊断可预览；run feedback 不是产品支持；外发不自动附私人 transcript |
| B46 账户/设备管理、邀请、公告 | N20/N22：邀请/分享入口可见；登录后设备/公告和成功链接未确认 | 无对应账户系统 | 先核实用户结果与公开契约；保留目标，不为了主题解锁复制强制账号机制 |
| B47 主题、个性化及周报 | N16/N17/N20：90–150%缩放、Sections/Card密度、实际卡片预览、主题与 Weekly Wrapped 开关已见；周报生成未验 | 深浅色/语言与图标；缺一致缩放、密度及周报 | 原创资产、缩放可读性、预览/reduce motion、真实统计与导出；不能继续只以旧灰度状态代表当前入口 |
| B48 Analytics 趋势 | N12：1.0.74 独立 Analytics 页面已可进入，有时间范围/信号类别/分母说明；非空趋势未验 | 记录统计/Lab 对照不等于相同 signal trend | 分类、分母、时间范围、缺失值与多日比较；入口存在不证明真实纠错改善 |
| B49 Local/Central Domain Model | O1 Soon/Next，P | 项目资产不是完整模型与团队意图系统 | 意图/决策来源、跨项目版本、权限、冲突及审计 |
| B50 Team Conflict Resolution | O1 Next，P | 未实现 | 可重现实例、共享与本地隔离、冲突双方证据和人工决策 |
| B51 Auto-Improve Mode | O1 Next，P | Lab 对照与显式晋升存在；未来复用链未验收 | 自动测试候选、回归拒绝、真实后续任务改善；无结果不得宣传超越 |
| B52 Windows/Linux 客户端 | O2 官方发行描述 | 当前产品目标为 macOS；没有其他平台客户端 | 平台覆盖单列未完成；不能把 macOS 包宣称为全平台替代 |

## Vela 证据入口和缺口

代码入口：[SessionEngine](../../Sources/VelaCore/SessionEngine.swift)、[PiSessionReader](../../Sources/VelaCore/PiSessionReader.swift)、[FoundationService](../../Sources/VelaCore/FoundationService.swift)、[ProviderQuotaService](../../Sources/VelaCore/ProviderQuotaService.swift)、[ImproveService](../../Sources/VelaCore/ImproveService.swift)、[ModelImprovement](../../Sources/VelaCore/ModelImprovement.swift)、[SafeApply](../../Sources/VelaCore/SafeApply.swift)、[CLI/MCP](../../Sources/VelaCLI/main.swift)。本轮 provider 兼容决策见 [ADR 0009](../adr/0009-session-provider-compatibility.md)，额度读取见 [ADR 0011](../adr/0011-provider-quota-observation.md)，模型提案见 [ADR 0014](../adr/0014-model-improvement-proposals.md) 和 [UI/API 合同](../implementation/model-improvement-contract.md)。

测试入口：[FoundationTests](../../Tests/VelaCoreTests/FoundationTests.swift) 包含日志增量、旧尾窗、Cursor 只读、脱敏与 FSEvents；[UsageIntegrityTests](../../Tests/VelaCoreTests/UsageIntegrityTests.swift) 包含未知/零/溢出；[ImproveAcceptanceTests](../../Tests/VelaCoreTests/ImproveAcceptanceTests.swift) 包含真实来源、重复程序和近似负例；[ProviderCompatibilityTests](../../Tests/VelaCoreTests/ProviderCompatibilityTests.swift) 新增 Pi/OMP 格式与边界检查。既有执行记录在 [verification](../verification.md)，本轮新增结果应引用实际执行日志，不能仅从测试文件存在推导通过。

这些合成测试检验确定性数据解析和错误行为，不是运行 Blume，也不是五个真实 Agent 的完整版本认证。全产品完成还要通过用户的 Golden Scenario、后台生命周期、长时间摄取、真实账号额度、原生通知和签名发布验收。

Codex 子代理只读关系切片（ADR0030）：20 个关系方法（含 2 个独立修前反例）与 Plan 18 / Provider 16 / History 16 方法共 **70/70 portable PASS**，不是 XCTest；冻结源码快照 `047ed304d732c14e36430062d533fc6e204e2a169f5eae9ff5a951b33ff8dad8`。实际 JSON-RPC consumer 在独立 helper 中完成 **57 请求 PASS**，只用合成 JSONL，0 provider/model 调用，父完成/子错误独立、缺失/跨项目/private/internal/重号/冲突拒绝、精确字节证据与 epoch 失效均有正反例。helper SHA256 `0f504932c9d35fe16bad807369671832ed24b9553f74ab7840d5858471e7aa8e`；见 [证据清单](session-relations-evidence-2026-09-13.json)。该本地验证混入同期 History Source 与 semantic 源码；结束时非关系 SemanticMemory 又有变化，不能当成正式集成 stage 全量结果。完整 UI 与其余 provider/历史关系仍未完成。

本轮 provider 首切片通过 15/15 Core 与 7/7 实际 CLI 摄取检查；其后新增固定 mtime 的同长度写入回归，16/16 通过。该回归也抓出共享 completion trigger 与外层 UPSERT 的真实冲突；修复后再次进入 Completed 能正常发布状态。额度切片通过 9/9 Core 与 5/5 CLI 协议检查。首 checkpoint 共 24/24 方法、两组 CLI 使用同一二进制 SHA256；对应 `output/parity/blume/final-checks.json` 是该时刻的证据，不代替后续源更改验证。

模型 Improve 已通过包括旧确定性检测和共享 planner 在内的 31/31 方法，其中自身 13 项；严格隐私字段类型收紧后自身 13/13 再次通过。新增模型全路径 CLI 7/7，通过审批→三阶段→证据/diff→独立 Apply/Undo→状态/重放拒绝。最后三组 CLI 合计 19/19，均使用 SHA256 `87531b1bf93b6c46b805f08d043e1f0b6b9ddd13cafc19f9276ae9c410bba7c0` 的冻结 helper 副本。

合成 provider 测试不等于真实模型效果。所有合成测试不读取真实凭据、不执行付费模型任务，保留日志位于 `output/parity/blume/`；复现入口为 [provider](../../scripts/test-provider-rpc.py)、[quota](../../scripts/test-quota-rpc.py)、[model improvement](../../scripts/test-model-improvement-rpc.py)，均使用隔离 fixture 与冻结 helper，避免并行 build 改写测试对象。较早失败快照仍保留，不冒称整库一直通过。

配置治理切片：`SetupInventoryTests` 11 个新方法加既有 Setup 回归 12/12 PASS；`scripts/test-setup-rpc.py` 7/7 实际 CLI PASS，证据为 `output/parity/blume/setup-final-tests.log` / `setup-rpc-final.json`。同一冻结 helper 完整生成 UI fixture，6 个 artifact 均来自合成项目/显式 sources 根，隔离目录已清理；见 `ui-fixture-isolation.json` 和 [API 合同](../implementation/setup-inventory-contract.md)。此验证不证明 provider 实际加载、不证明未观察期间全部变更可追溯，也不是 UI 验收。

另有独立**真实只读账户验证**：2026-09-13T01:23:41Z，Codex CLI 0.154.0，`quotaAvailable=true`/fresh，2 个 source bucket、3 个窗口；未启动模型任务，Vela 没有直接读取认证文件。只保留数量、版本、时间和 helper hash，不保留账户身份或原始余额，记录为 `output/parity/live-provider/quota-read.json`。

**真实 Model Improve 协议验收**另行执行并通过：2026-09-13T03:47:14Z–03:47:50Z，以 Codex 0.154.0、请求模型 `gpt-5.6-sol` / effort low，在三份合成 session、六条明确原消息上执行唯一一次审批，三个阶段各返回完整协议、零工具事件，生成一条保留原引用的 Rule draft；未 Apply、未创建 active Memory，临时 store 已清理。记录为 `output/parity/live-provider/model-improve-attempt-1/receipt.json`，同时保留完整合成 sources、冻结 request/approval、输入检查与结果。冻结 helper SHA256 为 `31bc1925225b09d0cf754d578f73972dcd8e9a5de9d1aa3c9ac05c0f484d6439`。Provider 报告 34116 input / 760 output tokens；实际模型身份未由协议证明，`observedModel=null`。这一结果证明三阶段协议和候选引用链，不证明真实纠错减少或未来任务质量改善。可显式复跑 [live 脚本](../../scripts/verify-model-improvement-live.py) `--live`，会消耗真实订阅用量且最多三个请求；不得放入自动 CI。

## 实现顺序与完成门槛

1. **会话数据基础**：本轮先交付 Pi/OMP 有版本的只读格式适配。继而完成各 provider 回填/分页、Todo、子代理和真实事件/进程状态。每个 adapter 维护可公开的版本 fixture、失败案例和准确 provenance。
2. **使用额度与后台触发**：provider 连接/权限修复、真实额度窗口/重置、持久化调度。离线、未知、陈旧、限流分别表示，不能伪造触发条件。
3. **配置治理与模型 Improve**：完整清单/关系/历史、原创审计、受限多阶段 CLI 分析、配置选择、提案生命周期。每一条修改继续沿冻结审批和 SafeApply。
4. **Continue 与集成**：同源恢复、明确授权的跨源交接、终端和 MCP 安装、Raycast。先证明目标 Agent 在正确项目/会话继续，再增加便捷入口。
5. **完整桌面及发布**：窄窗/多屏、引导、通知、更新与数据管理，随后完成账户/同步/协作/周报等未公开确认项及规划目标；不因没有公开证据而默默删项。
6. **超越验证**：以相同输入和真实输出核验功能等价，再测试更低资源占用、更稳恢复、隔离和下一任务效果。任何剩余功能未实现、真实接入未测或硬门未过，都保留“未达到超集”。

## English summary

Vela is not yet a functional superset of Blume. This inventory keeps 52 capability items and distinguishes published beta, roadmap and report-only observations. Current slices add versioned Pi/OMP ingestion, a Codex quota adapter with one real account verification, and a reviewed three-stage improvement pipeline. Both synthetic-provider tests and one real Codex run over synthetic source material passed; the latter produced an unapplied Rule candidate with verified citations. Other providers, real task effectiveness, configuration, continuation, desktop behavior and remaining parity items stay open.

2026-09-14 增量证据：Session Capture 的 Core/RPC 与 UI19/20 fixture consumer 已实通；Workflow Health UI20 有 4 组浏览器与 7 组原生边界记录。手动 Run Feedback 的 Core/API/Bridge 已测，但 UI21 consumer 仍是缺入口红例。100 MiB synthetic Codex 前缀/RSS 仅为单 helper 的有限观察；不构成完整摄取、全应用性能或 Golden 通过。详见 [Health 证据](ui20-health-proposal-evidence-2026-09-14.json) 与 [集成收据](feedback-lab-session-core-evidence-2026-09-14.json)。


## 关联模块独立审阅记录（2026-09-13）

这些验证不代替 Blume 全量功能等价，但属于跨模块正确性门：

- Composition：旧 prepared root 覆盖新产物、uncertain 子审批未传播、旧 child 快照重新打开已完成步骤三个修前反例均已保留。修后独立 4/4，通过真实子步骤和恢复账本核验；见 `output/parity/blume/composition-review-verified.json/log`。
- Connector：返回中已知 Keychain key 回显、`successful:false` 被当作无部分副作用两项 P1 已修；domain + URLProtocol 15/15 通过。另指出合法 scalar data 的兼容缺陷，由 Root 单独修复。这里没有真实外部消息发送。
- Library：缺失 public 标记、删除 managed asset 仍返回旧正文、错误类型 private-origin 标记三项已真实复现并修复，统一 `LibrarySource.fresh` / `LibraryIndex.isPublic`；派生索引不能作为来源事实。
- Agent Loop：冻结来源后来变成 private-origin 或丢失资产仍启动模型、非整数/负长度 schema 被忽略的反例均已修；claimed/response_received/decided 账本恢复没有重复调用。独立 4 项与 Ask 14 项、Library 3 项在同一源码快照 `0241b02a0d0aed5c3e56d0e882cc952505437f0015d915825c80731a8801b89e` 下 21/21 通过（portable fallback）。
- RPC：真实同连接 long approval 阻塞 get/cancel 的失败保留在 `loop-rpc-control-first.json`。Root 分离控制实例/队列并在普通队列满时立即返回 busy；修后普通及 32 请求饱和两例均在 provider barrier 释放前收到 get/cancel，1 次 fake provider、0 后续 tool receipt。helper `00f3cf665883c5738460ac36b711cb86f39870c6a732f147f8ab61861e27a816`，见 `loop-rpc-control-fixed.json` / `loop-rpc-saturated-first.json`；后者名字为 first，但捕获的是修后 helper，不能写成修前失败。

另完成 [Knowledge Ask](../implementation/knowledge-query-contract.md)：专门 run、逐轮独立审批、精确引文回查、后续来源重新核验和显式 Library FTS 段落模式。一次真实 Codex 仅使用合成公开 Library/Active Memory，1 call、2 citations、tool0；它证明真实协议与来源闭环，不证明答案解释绝对正确。所有一次性 fixture/helper/store 都已删除，成功和失败证据分别保留。

## Root-provided read-only observation — Blume 1.0.74

Root observed the public desktop UI read-only, without copying assets, screenshots, private project names or treating it as a parity pass. Agents, Setup, Usage and Improve expose top tabs. Setup separates project/global groups and uses Content, Related and Details views; its Markdown reader provides an Edit block action per block. Vela subsequently implemented block/full-document editing for eligible project instruction/skill Markdown, complete review, frozen approval and CAS-protected Undo; [13 browser journeys passed](../evidence/2026-09-14-setup-editing.json), with native editing unverified at that earlier checkpoint after macOS lock and CUA activation timeouts. On 2026-09-15 one isolated native heading-edit, approval and byte-exact undo round trip passed; see the [new bounded audit](blume-native-audit-2026-09-15.md). This does not close the full native regression matrix. Global and other configuration types remain outside this edit flow, so this does not close full Setup parity. Source presentation uses a short filename. Quota numbers were not verified because Claude was not connected and Codex had aborted. This is a design observation only, not full UI acceptance or evidence for account, quota, provider or private-project behavior.
