# 功能状态与限制

**当前开发分支：基于 0.1.0-preview.2 的未发布完整能力扩展。产品总验收仍为 No-Go。** 下载仍是 [preview.2](https://github.com/Atingaii/Vela/releases/tag/v0.1.0-preview.2)，不包含下面新增的开发分支功能。源码：[Atingaii/Vela](https://github.com/Atingaii/Vela)；[公开官网](https://vela-engineering.zzzsssaa.chatgpt.site)。

目标已扩展为覆盖 Blume、Walrus Memory/MemWal、px0 的全部已交付能力，见[228 项逐项台账](parity/README.md)。旧版最小范围不是删减目标的依据。实现、隔离测试、真实提供方、桌面接通、发布验收分别记录；测试总数不能抵消缺失功能。

## 当前源码

| 模块 | 已实现行为 | 尚需完成或验证的边界 |
| --- | --- | --- |
| 桌面与语言 | AppKit、系统 WKWebView、独立 Swift helper；分组会话、记忆、工作流、审批与设置；简体中文/English 持久化切换 | 当前交付平台 Apple Silicon、macOS 13+。新增能力的界面正在指定 Antigravity CLI 中接通，不能沿用旧 UI 结果证明新入口可用 |
| 会话观察 | Claude/Codex 增量日志、部分 Cursor 导出/SQLite、Pi v1/v2/v3 分支记录与 OMP 元数据；有界流式读取、来源版本、身份/轮转检查 | 完整历史回填及所有私有 Cursor 格式仍未完成。日志推断不等于进程存活证明；Pi 最新持久化分支不冒充当前活跃分支 |
| 显式历史回填 | Claude/Codex/Pi/OMP JSONL来源清单、固定epoch、分批读取与重启续传、稳定分页和完整原文分块；解析/原文/分支分别计量 | 历史回填桌面发现/分页/启停/续传/原文分块已通过 UI17 实测和 972 CI；Cursor、未知格式与完整大负载仍未验收，未解析原文不计为归一化功能 |
| 会话计划 | Codex update_plan、Claude Todo/Task 的持久化调用与成功回执配对；只读任务状态、来源hash/位置、提议/失败/未知区分 | UI17 的全部项目 scope 与后台刷新展开/锚点缺陷保留为历史反例。UI18 r7 已在冻结 renderer→真实隔离 helper 的完整 8 项浏览器路径中复验 explicit project、展开首屏、默认首 cursor、无旧 cursor、stale guard 与 anchor；其真实 held `sessions.relations.get` + 用户 wheel 反例从 r6 的红结果变为 r7 保持阅读位置的通过结果。嵌套 held-response 加 wheel 的反例只在 Chrome 实测，机制是 Chromium 原生 scroll anchoring 的证据支持推断而非 setter trace 结论。另有匹配 r7 的 WKWebView 普通刷新、父子关系导航和双语 Search/Actions 实测；没有原生 held-response 覆盖，仅保存一张刷新后截图，不声称保存前后成对证据。完整历史投影/未文档化格式仍不足，计划完成不证明工程验证通过 |
| Setup | 五harness公开位置目录、项目/全局配置扫描、脱敏版本历史/差异、来源关系、删除/重新出现痕迹与不完整扫描保护 | Setup 目录/历史/diff/关系入口已通过真实 helper 浏览器验收；完整原生操作仍需持续验证。TOML/YAML无安全解析器时只给元数据/hash，不提供原文；实际加载配置仍未知，不执行被扫描的 Hook/MCP |
| Memory | 九类内容、七类作用域、Candidate/Active/Superseded/Archived、来源消息、Markdown 人工编辑；同项目已索引 session 单消息可经 Core identity/hash 重验捕获为 candidate observation；Active-only Recall | 捕获只重读已索引记录、不打开 provider 文件；新建需 review，不自动激活，后续人工编辑保留来源并标为 user-derived。完整提取、合并、遗忘、团队策略与所有插件入口仍按台账验收 |
| 语义 Recall | 系统已安装 NaturalLanguage 模型、本地分页索引、lexical/semantic/hybrid、版本/维度/sourceHash 校验、明确语言与不可用状态 | 默认仍可离线词面检索，不自动下载。真实合成中英文语义召回与界面取消/索引流程已测，不能据此宣称真实长期检索质量达标；Library向量后端仍需实现 |
| Library与Ask | 资料版本、审阅后编辑/归档/恢复/导出/重抓；FTS5段落/原文位置与本地重排；独立审批问答与重新核验的续问 | 真实Codex一次来源问答已通过，FTS路径有独立Core/CLI验证。缺标记/错误privacy/私有来源与消失资产反例已修；引用存在不证明语义正确。YouTube、vault与完整批量来源管线仍需接通 |
| 归档与 SDK | 有界 JSON 导出/校验/候选导入、跨项目身份与幂等；可安装 TypeScript/Python 本地 SDK，含语义接口 | 归档为明文，排除 private/global。SDK 安装产物已隔离验收；本地归档不等于加密跨设备同步 |
| 可选 Walrus 后端 | 独立TypeScript包、固定官方SDK、显式profile/隔离worker、owner交易准备/签名核验、端侧manifest与原文恢复/候选构造 | 真实安装包、公开兼容性与testnet只读交易模拟已通过；官方faucet限流，测试地址无gas。真实加密写入/恢复与owner/delegate链上提交仍待验证；模拟不是链上成功，不默认给桌面增加Node |
| OpenClaw集成 | 可选独立插件、宿主agent/workspace映射、namespace召回、候选捕获、注入框与持久操作日志 | 真实隔离宿主加载/CLI/hook与完整会话通过；模型响应使用本地合成provider。两条新记忆均为候选，不等于真实模型采纳或远端加密写入。自动捕获默认关闭，远端提取另需明确明文接收与预算 |
| 模型记忆中间件 | 独立可选TypeScript AI SDK v4、Python Responses与LangChain ChatOpenAI包；精确scope召回、受限注入、完整终态才捕获候选、取消/不确定回执 | AI SDK安装17项及基础TS12项通过；Python Responses修后安装30项、基础SDK12项与旧wheel兼容1项通过；独立四入口复核通过。LangChain v2安装36项、基础SDK13项和旧wheel1项通过，独立7方法与12矩阵格复核通过。均为真实SDK与loopbackHTTP/SSE，不代表真实模型质量；其他LangChain providers与remote analyze仍待完成 |
| 本地 MCP | 强类型 stdio、四协议版本协商、15只读/7显式贡献工具、项目与fresh-source隔离、可见正文分页及候选批量写入 | 四版本22工具实际消费者及 framing 修正已通过；46595a72 整次 CI 通过，包含454项真实 XCTest、MCP 及安装后集成。远端HTTP/OAuth及完整Agent客户端接入另验 |
| Checkpoint / Reuse | 用户工程记录及真实 Git 快照；中立交接；项目 Codex SessionStart Hook 的预览、Apply/Undo 与提供上下文收据 | 原生 Session Transfer、更多官方 lifecycle hooks 和完整真实下一会话闭环仍需验证。收据证明已提供，不证明模型遵守 |
| Workflow Context | 已选择 Guideline、Active Memory、只读 Git/Library/stdin/literal 输入，冻结来源/hash；显式 `{{vela.prompt}}` 参数实际交给 Agent | 旧 raw argv 不被静默改写。记录 prompt 消费路径不等于证明模型采纳约束 |
| 自然语言规划 | 明确选择 Codex 程序/模型/effort，冻结请求，经审批生成问题或默认停用草案，再显式保存 | 真实提供方已产出有效草案；规划工具目录仍需拓展，与自主多轮工具执行是不同能力 |
| 执行与组合 | 工具步骤、Markdown版本、Dry Run、逐工具审批；冻结pipeline/子工作流、条件透传、子输入、根产物文件/Inbox；审阅后克隆/启停/归档/恢复 | 四项独立恢复/并发反例已修后通过，历史证据保留。完整双版本Replay与更多工具仍按台账推进 |
| Health 候选改进 | 从完整 timeout 观察提出显式时限候选；受限工具、版本/来源 hash、needs_review 确认、原子生成新 ID 的停用工作流；accepting 显式恢复 | 46595a72 hosted CI 的454项真实 XCTest、真实RPC和安装后SDK已过；UI20 已接通预览、创建、拒绝、确认接受和中断恢复，并通过4项真实 helper 浏览器旅程；匹配UI20与helper的7项原生流程亦通过。只生成待审候选，不自动运行/修改原工作流，不证明提高成功率；精确跨进程检查至提交窗口未独立注入 |
| 历史输入Replay | 显式同意保留fixture、两保存模板版本的独立审批/最多两次模型调用、输出差异、取消、到期与分页清理；A/B使用同一已核hash原生入口副本 | 24项定点、两独立CLI fixture和普通/饱和RPC控制通过；0真实模型调用，语义效果保持未知。当前只支持单contextual agent.run；组合回放、解释器包装兼容与桌面入口仍未关闭 |
| 模型工具循环 | 有界多轮结构化决策、真实只读工具结果回传、外部动作独立排队审批、响应式查询/取消 | 真实Codex两轮+一次Git读取通过；同RPC普通/饱和队列取消通过。工具覆盖、全部账户、严格成本预算等仍未完成，初始循环审批不授权外部写 |
| 外部工具 | 可选 Composio v3.1：Keychain 凭据、分页发现、固定版本 schema/账户、审批后执行、连接/撤销等动作、`connector.call` 步骤 | 无凭据真实 HTTPS 拒绝路径已测；尚无真实测试账户正向执行证据。结果不确定不重试；失败回包不证明无部分副作用，已知凭据回显在入库前拒绝 |
| Improve | 保留确定性检测；新增三阶段模型提取/聚类/规划，最多三次审批内调用、原消息证据、五类候选载体、带 hash 的审阅与 Apply/Undo | 真实提供方三阶段协议与候选链通过，候选未自动应用。尚不能证明真实项目纠错率改善或所有治理诊断覆盖 |
| 调度与后台服务 | 用户显式管理 launchd 用户服务；跨进程 lease、时区/DST、skip/latest/all 有界补跑、去重、持久化完成事件游标、不重叠、需核对状态 | 真实 launchd 安装/启动/崩溃拉起/停止/移除已在隔离环境通过。`usage_reset` 尚未接通；不声称任意外部副作用 exactly-once |
| Watch触发 | 本地只读工具轮询、FSEvents文件观察、首轮基线、按key净变化/阈值积累、重启去重；文件字节SHA256与空闲不重读 | 43项定点与两次真实daemon路径通过；事件丢失/重启无法恢复中间变化时明确标记。私有撤销覆盖待发变更before/after；外部只读connector与最终原生界面另验 |
| Usage | 已索引日志 token 与实际 Codex 账户额度分开；通过只读 app-server 请求观测多 bucket/window、真实零、缺失与 stale | 真实 Codex 额度读取通过；Claude 账户额度、定价、精确成本和所有 reset trigger 仍未验收，不从日志 token 推算账户余额 |
| Lab | 同提交命令或 Codex 对照、冻结任务/模型、独立干净 verifier、证据与 Memory 晋升门槛 | 显式 Memory 与真实 Recall ON/OFF 现在分别冻结，执行前复核两类来源；strict OFF 禁止显式混入。Core/隔离 RPC 已测，桌面控件仍在接通。早期任务同分为 Inconclusive；Golden r2 六次真实运行均完成且 verifier 通过，但候选未胜出并超过冻结 token 成本限制，结论 Reject、晋升拒绝。纵向纠错改善仍未证明，历史失败与更正保留 |
| 通知与官网 | 可选原生分类通知及三个短提示音；静态公开官网及独立比较/场景/文档/发行页面 | 当前 ad-hoc 应用被 macOS 拒绝通知授权，系统横幅及点击回流未验收。官网展示不构成功能证据 |

## 验证记录如何阅读

本轮新增切片的隔离 Core、编译后 CLI、安装后的 SDK 和真实提供方结果见[持续验证记录](verification.md#full-capability-expansion--13-september-2026)及三个产品台账。不同验证使用不同明确 helper 快照；并行开发中的局部通过不是最终 checkout 全量通过。当前未给新增代码签署完整产品或新发布包验收。

先前提交 `ea8fbd257f813c604a93e070d5f98a6337829d81` 的 [CI](https://github.com/Atingaii/Vela/actions/runs/34715619455)为历史基线：99 项 XCTest、24 组 renderer 检查。先前 1,453,375 bytes 开发包也只是该阶段产物，不能作为新增能力的包体或界面验证结果。更早的原生、Lab、私有检索、通知拒绝与失败复现保留于 verification 文档，不以新测试覆盖删除历史问题。

最新已验证检查点 `46595a72` 的 [CI](https://github.com/Atingaii/Vela/actions/runs/34770795639)已全部通过：454项真实 XCTest（0失败）、session-memory-capture 与 Health proposal 能力RPC、MCP/renderer 流程（含 UI18 r7 完整8项 scope/live/ARIA 回归）、安装后 TypeScript/Python SDK 与 AI SDK/Python Responses/LangChain/OpenClaw 消费者，以及 macOS ad-hoc 打包和 release allowlist 审计。准确作业、步骤和范围见 [CI evidence](parity/ci-46595a72-evidence-2026-09-14.json)。这不验证 UI19/20、原生交互或真实模型改善；旧检查点失败和修后证据仍保留于[验证记录](verification.md#hosted-checkpoint-correction)。这是开发分支检查点，不改变公开下载版本与产品总验收状态。

UI18 r6 的嵌套 loader 用户 wheel 红例已保留，并由 r7 的完整 8 项冻结浏览器回归在同一真实 held-response 路径中复验通过：scrollTop 707 / relative -388.953125 在释放后保持不变。r7 只机械替换 `app.js`，其余五资源不变；scope、默认首 cursor、旧 cursor、stale guard 与 ARIA 断言均未弱化。legacy renderer 12 项仍只对应 r6；r5 History/Plan 10 项、Relations 5 项及 r4 Actions 9 项仍是不同冻结版本的阶段回归，不能充当 r7 全套验收。r7 的 Chrome held-response 结果不等于 WKWebView：本机原生已补普通刷新与关系导航，不覆盖注入的延迟响应；46595a72 hosted CI 已通过同一完整8项浏览器回归。精确哈希、AGY provenance、测试修正和原生边界见 [UI18 renderer evidence](parity/ui18-renderer-evidence-2026-09-14.json)。该段只记录 UI18；后续 Capture/Health 接通见下面 UI19/20 记录，不改变 Golden 或产品总验收状态。

冻结第9版界面另通过完整6项Library/Watch、11项工程和4项Ask浏览器检查；原生窗口已验证文件Watch创建、编辑和真实预览。原生动态字段的完整可访问性、其余新增入口、最终发布签名及资源预算继续分别验收。正在进行的MCP扩展与LangChain不在该提交中。

本机为 Command Line Tools 环境，`swift build` 可用但缺 XCTest；`scripts/test-portable.py` 编译真实 Core 与原同步测试方法，使用小型断言兼容层，**不是 XCTest**。完整 Xcode/CI 使用 `swift test`。

```sh
swift build
python3 scripts/test-portable.py
python3 scripts/test-rpc.py
python3 scripts/check-repository.py
```

安装包、OS 控件、真实外部账户、长时间稳定性与性能分别验收。有限测试不能证明绝对零缺陷，也不能从 Swift 或包体小推导延迟/RSS/CPU全部达标。

## 数据与发布边界

- 当前公开预览与本地开发包使用 ad-hoc 签名，没有 Developer ID 签名、公证或已验证的签名更新通道。通道字符串不会改变这些事实。
- 默认数据在所选 store 的 SQLite WAL 与 `assets/{memory,workflow,guideline,library,checkpoint}` Markdown 中；本地使用不要求云账户。
- 可选连接器凭据进入 macOS Keychain，不进入 SQLite、归档和日志。明确联网的 URL 导入、模型执行、Composio 或 Walrus 操作各有独立目的和用户控制；不会自动将全部会话上传。
- Walrus 的客户端加密不隐藏发往嵌入服务的明文；官方远端恢复可能要求 relayer 解密/重建索引，必须单独选择，不能将其描述为全端侧隐私。
- 预览格式的长期兼容、迁移、备份与更新还需完整验收；保留用户资产与原始来源，测试及一次性资料不进入应用包。

## Notification acceptance boundary

The ad-hoc application was denied notification authorization on the validation host. Sound previews work, but OS banner delivery and click-through remain unverified. This is a release gate, not a feature that can be marked complete by a renderer test.

UI19 记忆采集已通过指定 Antigravity CLI 实现并机械合入源码：预览原始消息后显式存为候选，编辑正文保留不可伪造的来源，项目切换清理旧弹窗。同一整合快照的5项真实 helper 浏览器采集与8项工作区回归通过；[证据](parity/ui19-session-capture-evidence-2026-09-14.json)。原生已通过取消、确认、幂等、来源编辑及项目切换；当时的双语提示布局缺陷保留，修复进入 UI20。

UI20 健康提案已由同一指定模型实现并合入开发源码：完整4项 Health 浏览器旅程、5项会话采集和8项 scope/ARIA 回归在同一冻结 UI 与真实隔离 helper 上通过。包括无效超时输入拒绝、确认前不生成工作流、接受后只新增默认停用候选、显式恢复及晚回包项目隔离；[证据](parity/ui20-health-proposal-evidence-2026-09-14.json)。匹配冻结来源的7项原生流程已通过（预览、拒绝、接受门槛、恢复、普通刷新与双语采集布局），发布包尚未更新。

运行反馈、Lab Recall 和增长日志完整性修复已机械合入开发源码，整合前冻结 Core 的463项 portable 方法与真实隔离 RPC 均通过；本机 root 构建通过。增长日志会验证已索引前缀完整 SHA，检测旧消息改写加追加；每64 KiB 释放临时读取对象。在同一100 MiB合成日志、五次追加的长驻 helper 对照中，RSS 从修前最终383344 KiB 降至修后约18176 KiB，完整扫描仍需约125–145 ms，不据此宣称全应用性能达标。[Core证据](parity/feedback-lab-session-core-evidence-2026-09-14.json)。反馈与Lab新界面、最终 checkout CI、发布包仍分别验收。

原生资源补测为2分钟、5个合成会话及一次增量刷新：可归属的主进程和helper RSS中位95.344 MiB、峰104.203 MiB；稳定空闲采样CPU峰0.4%。WebContent无法可靠归属，整应用内存目标仍未成立为已验收结论；启动/交互p95与长稳仍未测。[资源证据](parity/native-resource-evidence-2026-09-14.json)。

摄取排除与数据库迁移已合入开发源码：项目/来源规则、投影撤回和规则代际原子提交，五种 provider 的新写入复核代际；History 的旧 ID 在规则有效时不能绕过访问限制。SQLite 0→1 升级可回滚，较新 schema 会拒绝。匹配 root 的冻结 Core 共482项 portable 方法通过，真实隔离 RPC、重启和旧历史导入回归通过；[证据](parity/ingestion-migration-evidence-2026-09-14.json)。这不等于 OBS-09/OBS-13/SEC-12 整体验收：桌面排除入口、完整备份恢复与索引修复仍未闭合；已存在 Memory 的召回抑制在下述新检查点单独验收。

上一个 checkpoint 的 CI 在 Lab 浏览器测试桥处失败：新 Recall fixture 限制误拦了旧 pending-only 实验。已修复兼容分支，并验证错误 agent、跨项目提案、修改 verifier argv 和执行批准仍被拒绝；新 checkpoint CI 单独追踪。UI21 仍存在 late prepare 覆盖用户反馈选择的已复现问题，UI22 Lab Recall 控件待实现；指定 Antigravity 模型配额耗尽，目前均未合入。

`b16e7b99` 的新 CI 已通过两个任务，包括482项真实 XCTest、已安装SDK/OpenClaw、浏览器旅程和macOS打包审计；[CI证据](parity/ci-b16e7b99-evidence-2026-09-14.json)。本机独立开发包内容约8.54 MiB，并通过5项原生QA包装器检查；[原生证据](parity/native-b16-package-evidence-2026-09-14.json)。这是不同身份的隔离测试，不能替代正式安装、公证或系统通知验收。

召回排除修复已整合到开发源码，覆盖旧版采集 Memory 的五种检索路线、MCP、Ask/Route、工作流执行前、Agent Loop 每轮与 Lab 候选执行前。已冻结工作流仍使用原批准 argv；普通正文编辑不会替换该 argv。用户管理视图和原始 Markdown/日志保留，显式移除规则后可恢复召回。匹配 root 的123个 Core/测试输入已通过490项 portable 方法；root 实际构建后，旧 b16→新 helper 升级7组、consumer28项、loop16项、Lab8项和完整6项 renderer 均通过。[精确证据与历史失败](parity/exclusion-recall-evidence-2026-09-14.json)。这关闭的是上述召回/执行检查缺口；桌面排除入口、完整备份与总体验收仍未闭合。UI仍为UI20，既有b16开发包不包含本修复，新checkpoint CI另行记录。

同一2000条合成Memory、真实来源规则与7次测量的debug helper对照中，lexical Recall中位耗时从776.885 ms降为547.898 ms；每次查询复用一次规则读取。该结果只代表此次helper调用，不等同于10万条Search、原生交互延迟或整应用内存预算。
