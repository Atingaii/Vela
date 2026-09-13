# px0 功能覆盖台账

审计日期：2026-09-13。Vela 对照基线：`ea8fbd257f813c604a93e070d5f98a6337829d81`。本轮正在实现的改动不倒填为基线能力；增量验证列于文末。

目标是覆盖 px0 当前公开交付的用户能力并逐项验证，不能把下面的缺口改成“已有类似页面”或直接从目标删除。`官方交付`表示一方文档以现有命令描述该能力；本次没有安装、登录或运行 px0，因此不等于独立验证参考产品。官方资料互相矛盾或明确未接通的条目单独保留，不能算已交付，也不能隐藏。

来源范围为[官网](https://px0.ai/)、[比较页](https://px0.ai/comparisons)、[官方文档目录](https://docs.px0.ai/llms.txt)列出的 29 页，包括 CLI、配置、安装更新和安全边界。公开网页只能建立当前公开范围，不能保证穷尽未公开的内部功能。Composio 目录会变化：最终连接器覆盖须固定目录快照、参数 schema、访问类型和连接状态，不能用“1000+”营销数字代替成功调用证据。

## 代码与证据索引

| 缩写 | Vela 基线实现或证据 |
| --- | --- |
| W | [AutomationService.swift](../../Sources/VelaCore/AutomationService.swift)：固定工具步骤、冻结审批、run 和历史定义回放 |
| C | [ContextService.swift](../../Sources/VelaCore/ContextService.swift)：本地规则草稿、Guideline 版本、观察性统计 |
| S | [SchedulerService.swift](../../Sources/VelaCore/SchedulerService.swift)：helper 内 tick、cron/本地事件领取 |
| M | [MemoryService.swift](../../Sources/VelaCore/MemoryService.swift)：Memory、Recall、Library、Checkpoint |
| DB | [Store.swift](../../Sources/VelaCore/Store.swift)：SQLite 对象与 Markdown 资产，词面 LIKE 检索 |
| P | [AutomationProcess.swift](../../Sources/VelaCore/AutomationProcess.swift)：独立 argv、环境净化、时限和输出限制 |
| A | [SafeApply.swift](../../Sources/VelaCore/SafeApply.swift)：文件身份、hash、事务恢复、Undo |
| CLI | [main.swift](../../Sources/VelaCLI/main.swift)：受限 RPC/MCP 与少量 CLI 入口 |
| E | [verification.md](../verification.md)、[AutomationTests.swift](../../Tests/VelaCoreTests/AutomationTests.swift)、[ContextTests.swift](../../Tests/VelaCoreTests/ContextTests.swift)、[FoundationTests.swift](../../Tests/VelaCoreTests/FoundationTests.swift) |

下表 `部分`表示已有可定位代码，但未满足该行全部语义；`缺失`表示没有发现对应路径；`具备`仅限该行明确边界，不推导总体等价。每行 ID 对应独立验收事项，不以平均分抵消缺失。

## 创建与执行工作流

来源：[Build](https://docs.px0.ai/workflows/build)、[Run](https://docs.px0.ai/workflows/run)、[Anatomy](https://docs.px0.ai/workflows/anatomy)。本组参考状态均为官方交付。

| ID | 应覆盖的用户能力 | Vela 基线 / 缺口 | 必须验证的结果 |
| --- | --- | --- | --- |
| PX0-001 | 自然语言访谈，收敛任务、来源、产物、节奏、完成标准 | 部分 C：关键词规则草稿 | 多轮回答确实改变有效定义；不假造工具 |
| PX0-002 | 提前结束、有限追问、编辑/取消请求 | 缺失 | 取消不保存、不授权、不执行 |
| PX0-003 | 按能力搜索连接器，仅从返回结果选工具 | 缺失 | 未返回 slug 拒绝；记录 schema 来源 |
| PX0-004 | 建立前审阅 read/write/destructive 工具，允许剔除 | 部分 W：仅固定工具运行审批 | 取消或删工具后不能在生成定义复活 |
| PX0-005 | 所需应用授权；pending 与 blocked 有不同结果 | 缺失 | pending 可保存，blocked 不伪称可运行 |
| PX0-006 | 从同一原始请求重建 inputs/tools/guidelines | 缺失 C | 改请求后定义整体一致、旧版可找回 |
| PX0-007 | 根据任务拟定 Guideline，预览、重拟、单独接受 | 缺失 C | 未接受不得保存，既有原文不覆盖 |
| PX0-008 | 可手编 Markdown/YAML、递归发现，下一次按修改执行 | 部分 W：JSON frontmatter 子集、DB 管理资产 | 真实手改后执行新版本；坏文件单独报错 |
| PX0-009 | body 是真实模型 prompt，原始 request 与 description 分开 | 缺失 W：body 是说明，agent.run 是原始 argv | 真实进程收到渲染正文；来源可核对 |
| PX0-010 | 只读 tool 输入、前序输入作为后序参数 | 缺失 W | 写工具不得成为无条件输入；保持 JSON 类型 |
| PX0-011 | Library retrieve 输入和可引用 passage/anchor | 缺失 W | 相关来源、片段锚点和 Private 排除均成立 |
| PX0-012 | stdin 和重复 named inputs | 缺失 CLI/W | 引号、中文、多行和结构数据不损坏 |
| PX0-013 | 子 workflow 输入，独立 run、只传产物、不重复交付 | 缺失 W | 父子关系、错误传播、产物交付次数 |
| PX0-014 | optional 输入失败标 degraded；必需失败停止 | 缺失 W | 无数据与成功空数组区分，不能静默成功 |
| PX0-015 | 点路径模板、完整占位符保类型、内嵌字符串 | 缺失 W | 模板一次展开，输入正文不再解释成模板 |
| PX0-016 | 指定 Guideline 原文注入，记录确切版本 | 部分 W：snapshot_only_not_injected | 最终实际 prompt 与版本/hash 对得上 |
| PX0-017 | Memory 相关性、固定优先项与严格预算注入 | 部分 M：Recall 未接通 workflow prompt | 实際收到的文本不超预算，私有/失效/越界排除 |
| PX0-018 | stdout/file/inbox 产物，时间变量、安全根与并发写 | 部分 W/A：固定 file.write | 路径逃逸失败；计划产物与实际字节一致 |
| PX0-019 | scheduled/watch 不得只输出无人读取的 stdout | 缺失 W | 不合理定义保存前失败 |
| PX0-020 | pipeline 顺序传输出；always/has_output/no_output | 缺失 W | 跳过状态、失败中止、父子 run 和最终交付 |
| PX0-021 | 禁嵌套 pipeline、缺 stage/首 stage 条件验证 | 缺失 W | 坏依赖、循环与未知条件不进入执行 |
| PX0-022 | Dry Run 获取真实只读输入，所有写入 stub | 部分 W/E：固定 reads；agent.run 全 stub | 工程脚本等潜在变更均不运行，显示确切拟执行文本 |
| PX0-023 | 超时、每次尝试记录、重试退避、失败通知 | 部分 P：时限/输出/子进程清理；无重试策略 | 只重试已知可重试操作；未知副作用不重复 |
| PX0-024 | 单次 run flags、交互选择器、quiet/JSON、失败阶段 | 部分 CLI/W | 无 TTY 可用；失败有持久化阶段与原因 |
| PX0-025 | 验证全部定义、show、remove、enable/disable、clone | 部分 W：list/save；其余缺专用合同 | clone 不改原件；删引用可诊断；禁用不触发 |

## 调度与后台运行

来源：[Schedules and daemon](https://docs.px0.ai/workflows/schedule)。本组参考状态均为官方交付；其文档没有给出补跑次数上限，不能自行断言无限补跑。

| ID | 应覆盖的用户能力 | Vela 基线 / 缺口 | 必须验证的结果 |
| --- | --- | --- | --- |
| PX0-026 | 无窗口/终端常驻的 macOS launchd 调度 | 缺失 S：app/helper 活着才 tick | 退出桌面后按时产生真实记录，重新打开能看到 |
| PX0-027 | Linux systemd user 与 cron fallback | 缺失：当前仅 macOS | 保留平台差异目标；不能称跨平台等价 |
| PX0-028 | install/start/stop/restart/serve/uninstall | 缺失 CLI | 持久化服务生命周期、重复安装和卸载不损用户配置 |
| PX0-029 | 真实进程存活检查、上次/下次 fire | 部分 S：仅调度记录 | stale pid 与 PID 复用不能冒充存活 |
| PX0-030 | 5 字段 cron、workflow 时区覆盖默认时区 | 部分 S：仅机器当前时区 | 非法 zone、DST、跨时区和日期边界 |
| PX0-031 | startup/tick 补遗漏 fire，并记录 late | 缺失 S | 休眠/停机恢复、去重、已有不确定操作不再跑 |
| PX0-032 | 任意只读工具 watch，首轮 baseline、key 去重 | 部分 S：Git/session 固定事件 | 新事件输入冻结；轮询重复不重复发起 |
| PX0-033 | watch min_items 积累、poll interval、禁用跳过 | 缺失 S | 未达阈值不丢事件、跨重启保留积累 |
| PX0-034 | 每日 checkpoint、reindex、playlist ingest、retention | 部分 S：局部分析；无完整维护 | 每步故障隔离，其余维护继续 |
| PX0-035 | 每周更新检查、daemon/run logs follow | 缺失 CLI | 离线可诊断；已结束日志不会持续阻塞 |
| PX0-036 | 同一原因连续失败自动暂停，仅无人值守生效 | 缺失 S | 不同失败不误并；人工恢复和变更记录 |

## 工具、连接和执行权限

来源：[Tools](https://docs.px0.ai/tools/catalogue)、[Connections](https://docs.px0.ai/tools/connections)、[Configuration](https://docs.px0.ai/reference/configuration)。以下均为官方交付，另行标记的未接通配置除外。

| ID | 应覆盖的用户能力 | Vela 基线 / 缺口 | 必须验证的结果 |
| --- | --- | --- | --- |
| PX0-037 | GitHub：我的 PR、单 PR、diff、review comments | 缺失 W；本地 git 不等于远端 API | 真实授权账号只读结果和分页/权限错误 |
| PX0-038 | GitHub：创建 review comment | 缺失 W | 冻结 PR/commit/path/line/body，一次审批一次提交 |
| PX0-039 | Calendar 时间窗事件 | 缺失 W | 账号/日历/时区/分页/空结果 |
| PX0-040 | Gmail 搜索与读单邮件 | 缺失 W | 明确账号、真实消息 ID、内容边界 |
| PX0-041 | Gmail 发送、Slack 发消息 | 缺失 W | 专门测试收件箱/频道、确切正文和重复保护 |
| PX0-042 | 大目录搜索、工具发现、metadata 访问类型 | 缺失 W | 固定 catalog/schema 快照，不按名字猜读写 |
| PX0-043 | cached schema、inspect/list/status、refresh/forget | 缺失 W | 离线读取定义；schema 漂移要求重新审阅 |
| PX0-044 | 用户声明工具：argv 模板、参数 schema、坏文件隔离 | 部分 P：只能固定显式 command | 注入字面值不成为 shell；声明权限不得自动授予 |
| PX0-045 | 每工具 env allowlist；缺变量执行前拒绝 | 部分 P：通用敏感环境净化 | 只收到指定变量，日志无真实秘密 |
| PX0-046 | file.read/write/list、允许文件根 | 部分 A：受根/hash约束 write | read/list 也要限制根/符号链接与 Private |
| PX0-047 | http.get/post；brain.add；默认禁用 shell | 部分 M/P：URL导入、显式审批命令 | 每操作独立能力合同；不得向 renderer 暴露任意原语 |
| PX0-048 | memory.remember/recall 可供运行中工具调用 | 部分 M：非 workflow 工具 | write 受审批、read 受 scope 和预算 |
| PX0-049 | Composio key 验证、权限诊断、秘密保存 | 缺失 | 缺 auth_configs 权限不造链接；凭据不进仓库/导出 |
| PX0-050 | 应用 connect/disconnect/reconnect 与幂等授权 URL | 缺失 | pending/active/revoked/failed状态对应真实 provider |
| PX0-051 | TLS 自定义信任 CA 与明确失败，无禁证书绕过 | 部分 M：系统 TLS | 受信代理可用，错误证书拒绝 |
| PX0-052 | 连接器暂时故障退避，授权错误可行动诊断 | 缺失 | 限流/5xx/超时分开，写入不确定时不自动重发 |
| PX0-053 | Claude/Gemini/Pi/OpenCode 后端，保存前真实探测 | 部分 P：自选 argv；Lab 仅专门 Codex 模式 | 每一实际 CLI 版本的登录、model、输出协议与失败 |
| PX0-054 | 结构化 usage/cost；未知命令不猜 flags | 部分：日志 usage；无通用模型结果 envelope | 已测与估计区分，缺失不能显示零 |
| PX0-055 | builtin 工具循环与 scoped MCP agent loop | 缺失 W | 两条路均落实 allowlist、审批、stub、事件；不绕过权限 |
| PX0-056 | 无人值守日 cost/token budget | 缺失 W/S | 有测量才按费用限额；估计明确标记；人工命令另定义 |

## 审批与 Inbox

来源：[Approvals](https://docs.px0.ai/approvals/overview)、[Inbox](https://docs.px0.ai/runs/inbox)。参考状态均为官方交付。

| ID | 应覆盖的用户能力 | Vela 基线 / 缺口 | 必须验证的结果 |
| --- | --- | --- | --- |
| PX0-057 | 全部或指定写工具 hold，未知工具名称拒绝 | 部分 W：固定写步骤全部等待 | 明确授权策略不能被拼写错误放宽 |
| PX0-058 | 写调用被排队后，模型仍完成其余工作和产物 | 缺失 W：整条 run 在写步骤暂停 | 原产物保留，各写动作独立可审阅 |
| PX0-059 | 原始具体参数+产物一起审阅；审批不重跑 | 具备 W/E：固定步骤 hash/CAS | 修改定义/文件不能改变已审内容；跨进程一次领取 |
| PX0-060 | 审批前编辑参数并记录理由/历史 | 缺失 W | 新参数生成新快照，旧 hash 失效 |
| PX0-061 | rejected/failed 不自动回 pending，不重复发出 | 具备 W/E，限现有工具 | 断连/崩溃显示不确定，禁止自动重试 |
| PX0-062 | 审批有效期、resolved retention、oldest-first/filter | 缺失 W | 过期不可批；pending不可被retention误删 |
| PX0-063 | 远端回复审批：read poll、sender allowlist、严格语法 | 缺失 | 伪造sender、否定句、过期/重放消息均不执行 |
| PX0-064 | 无人值守待批通知，人工运行不重复提醒 | 部分 NotificationPolicy | 实际系统/远端投递和目标跳转，不只计算分类 |
| PX0-065 | file/inbox 定向交付，schedule/watch 默认入Inbox | 缺失：现 Inbox 主要是审批 | dryrun不入箱，标题取产物，条目追溯run |
| PX0-066 | read/archive/clear，未读保护与已读retention | 缺失 | 删文件回退preview并提示，未读不会自动消失 |

## Library、检索、Memory、Guidelines

来源：[Library](https://docs.px0.ai/brain/library)、[Search and ask](https://docs.px0.ai/brain/ask)、[Retrieval](https://docs.px0.ai/brain/retrieval)、[Memory](https://docs.px0.ai/memory/overview)、[Guidelines](https://docs.px0.ai/guidelines/overview)、[History](https://docs.px0.ai/guidelines/history)。参考状态均为官方交付。

| ID | 应覆盖的用户能力 | Vela 基线 / 缺口 | 必须验证的结果 |
| --- | --- | --- | --- |
| PX0-067 | URL/HTML、text PDF、DOCX、纯文本导入 | 具备 M/E 的 2MB 文本限制 | 每种真实合成文档；无文本 PDF 明确失败 |
| PX0-068 | ODT、legacy DOC、RST/Org 等格式 | 部分 M：未完整注册提取路径 | 每扩展名单与实际提取一致，不能当UTF-8猜读 |
| PX0-069 | YouTube transcript、无transcript stub、后续升级 | 缺失 M | 完整来源元数据、无字幕不伪称已转录 |
| PX0-070 | Playlist 后台队列、进度/限额、失败退休 | 缺失 M/S | 分页短缺明确、重复不重复导入、断点恢复 |
| PX0-071 | 批量sources、单次index、目标子目录 | 缺失 M | 任一失败可追踪，目标不能逃根 |
| PX0-072 | 原位 Obsidian/Logseq vault，dotfolder/ignore规则 | 缺失 M | read/search不修改vault，忽略项始终排除 |
| PX0-073 | list/show/remove/export、来源重抓/all/stale | 部分 M：create-only list/add | 删除同时去索引，ambiguous文件名拒绝，refresh明确新旧来源 |
| PX0-074 | SQLite FTS5/BM25、段落锚点、Unicode/重音/安全查询 | 缺失 DB：LIKE 排序 | CJK/拉丁/标点、章节引用、排序和索引更新 |
| PX0-075 | 本地 query coverage/proximity rerank、k/kind过滤 | 缺失 DB | 与未rerank可比较；空kind有明确诊断 |
| PX0-076 | 本地 hybrid/vector/reranker 可选后端 | 缺失 DB | 语义查询实测、版本检查、无网络服务要求 |
| PX0-077 | 模型下载尺寸预览、明确同意、拒绝仍可关键词 | 缺失 | 未同意不下载；缺binary清楚回退 |
| PX0-078 | Brain Ask 生成带 citations 答案、专门run | 缺失 CLI：本地结果拼接不等于生成答案 | 无命中不编造；答案源片段和run一一关联 |
| PX0-079 | Private 在search/ask/workflow/MCP/两后端硬排除 | 部分 M/DB/E：已接通路径成立 | 新路径都加泄漏回归；不能当OS文件沙箱 |
| PX0-080 | Memory 增改/查/forget、subject归并、pin、kind | 部分 M：生命周期与scope；无pin/subject语义 | 更新不留下相反双份，forget保可审历史 |
| PX0-081 | run bad note/对话纠正 → 长期Memory候选、接受后保存 | 部分 Improve：工程纠错规则 | 真实来源去重；坏模型响应不误写；不自动激活 |
| PX0-082 | 每run相关Memory预算、pin优先、单条过大裁剪 | 部分 M：Recall整条预算跳过，无pin与通用注入 | 真实prompt预算与来源一致，原文资产不被裁写 |
| PX0-083 | Guideline原文展示/编辑/移除、启动样例 | 部分 C：保存/列表 | 引用影响可见、删除可恢复、人工文字保留 |
| PX0-084 | 每 `##` claim 历史及手改自动checkpoint | 部分 DB/C：对象版本，不是claim历史 | 同名heading/slug碰撞和变更来源可追溯 |

## Ask、运行证据、改进与回放

来源：[Ask](https://docs.px0.ai/ask/overview)、[Runs](https://docs.px0.ai/runs/browse)、[Improve](https://docs.px0.ai/workflows/improve)。参考状态均为官方交付。

| ID | 应覆盖的用户能力 | Vela 基线 / 缺口 | 必须验证的结果 |
| --- | --- | --- | --- |
| PX0-085 | Ask 路由memory/brain/workflow/readtool/answer | 部分 CLI：单次本地搜索与Recall | explain不执行；write workflow先明确确认 |
| PX0-086 | 会话continue、指代理解、correction标记、会话retention | 缺失 CLI | 重启延续；临时对话与长期Memory区别 |
| PX0-087 | 重复问答提示改为workflow | 部分 Improve：重复工具流程候选 | 使用真实ask历史，不依靠演示计数 |
| PX0-088 | Run浏览/过滤/全文输出/日志follow/why/rerun | 部分 W/UI：详情和记录 | 保留dryrun语义、旧版资产来源、返回同一store |
| PX0-089 | Run真实inflight验证、cancel/force及退出状态 | 部分 P：超时清理，无用户cancel合同 | PID复用不杀别的程序；退出后记录一致 |
| PX0-090 | 区分record/rawlog/event retention，写入证据保留 | 缺失 W | 过期内容不可读时明确原因，不删除副作用账本 |
| PX0-091 | good/bad/clear + note、结构化事件、按workflow统计 | 部分 W：成功率/平均耗时 | 真实时间/来源、无参数值事件流、缺指标不可造零 |
| PX0-092 | Health：失败归因、empty output、全部tool失败却成功 | 部分 W：基础结果汇总 | 同一因聚合，不用rawlog猜成功 |
| PX0-093 | Health：refused/erroring/dead tool、timeout/turn cap | 缺失 W | dryrun排除分母、工具调用有准确次数 |
| PX0-094 | Health：输入长期空、bad notes、parked、跨版本窗口 | 缺失 W | 每发现都能回到实际run，不因版本混算伪推因果 |
| PX0-095 | Health narrow fix：移除unused工具、提高timeout | 缺失 W | 先确认、只改相应字段、可撤销，不擅加能力 |

2026-09-14 增量：手动 Run Feedback 已有 terminal/non-private/non-dry-run 的 prepare、CAS revision/history 与 Bridge 实测，且不改变 Health 的客观 successRate；UI21 尚未实现。Health 的 timeout proposal UI20 已覆盖 browser/native 限定路径。它们都不关闭 PX0-091–095 的完整反馈归因、跨版本趋势或通用可撤销修复验收。
| PX0-096 | 按实际证据生成改进request，diff、重建、单独guideline建议 | 部分 Improve：确定性工程建议 | 证据可预览、权限不自动扩大、保用户原文 |
| PX0-097 | opt-in捕获历史输入、fixture list/forget/到期 | 缺失 W | 默认不额外留敏感内容；删除不触及审计事实 |
| PX0-098 | 历史输入双版本模型回放、输出diff/churn | 缺失 W：旧定义dryrun仍重新读取今天Git | 输入工具和业务工具都不调用，独立两fixture验证 |
| PX0-099 | fixtures 排除 export/sync，不将一例差异称稳定改进 | 缺失 W | 档案字节检查；不足样本保持未知 |

## 数据所有权、CLI、安装与维护

来源：[Store](https://docs.px0.ai/reference/store)、[CLI](https://docs.px0.ai/reference/cli)、[MCP](https://docs.px0.ai/reference/mcp)、[Installation](https://docs.px0.ai/get-started/installation)、[Updating](https://docs.px0.ai/reference/updating)、[Status](https://docs.px0.ai/reference/status)、[Troubleshooting](https://docs.px0.ai/reference/troubleshooting)、[Privacy](https://docs.px0.ai/reference/privacy)。除明确列出的冲突/未接通条目外，参考状态均为官方交付。

| ID | 应覆盖的用户能力 | Vela 基线 / 缺口 | 必须验证的结果 |
| --- | --- | --- | --- |
| PX0-100 | 单目录、可选store位置、无托管账号/遥测 | 具备 DB/CLI，平台边界见README | 全新store、移动/备份后可读，网络实测无遥测 |
| PX0-101 | workflow/guideline/memory/config版本化原子changes | 部分 DB/A：不同资产/项目文件分散机制 | 一次多文件事件整体提交、revert也入历史 |
| PX0-102 | secret-free store export/import，冲突merge/force | 新增含 private 的本地完整 bundle；这不等价于 secret-free interchange，merge/force 仍缺失 | 凭据及其历史blob均排除；导入不损本机secret |
| PX0-103 | 可移动路径、内容/版本一致性store verify | 本地 backup restore 重绑新根资产路径，校验 DB/manifest/资产集合；通用 verify/同步仍待补齐 | 换根后引用仍对，丢blob/坏schema明确失败 |
| PX0-104 | 文件夹双向sync/pull/push/dryrun与机器冲突副本 | 缺失 | 不同步SQLite/凭据/fixture；不靠缺失推删除 |
| PX0-105 | 冲突解决后收敛，文件相同不再反复冲突 | 缺失 | 两store并发编辑/重新同步真实复现 |
| PX0-106 | typed config list/get/set/unset/edit/path与默认说明 | 部分 Preferences/CLI | 枚举/布尔/数值错误整体拒绝；秘密遮盖 |
| PX0-107 | MCP brain ask/search、workflow/guideline list/read | 部分 CLI：受限工程search/recall等 | 实际client发现、schema有效、项目/Private隔离 |
| PX0-108 | 显式开启MCP workflow run | 缺失 CLI：当前合同禁止执行 | 独立授权开关与受限执行入口；默认不列出、不执行 |
| PX0-109 | 完整CLI命令树、help、JSON、TTY/非TTY行为 | 部分 CLI：call/sessions/refresh/search/recall/doctor | 每个公开实体动作可用，非法args与退出码可靠 |
| PX0-110 | bash/zsh/fish completion，动态ID/config key | 缺失 CLI | 净shell中补全准确且不执行workflow |
| PX0-111 | init引导/环境诊断、安装前提、固定版本/前缀 | 部分 macOS package/doctor | 全新Mac安装、目录权限、未知binary而非虚假可用 |
| PX0-112 | update check、升级、schema migration、history、daemon重启 | 缺失 CLI | 失败不写成功历史；迁移原子；旧格式兼容策略 |
| PX0-113 | rollback binary与前向schema边界 | 缺失 | 无历史不猜版本；新schema不可被旧binary误写 |
| PX0-114 | uninstall保数据、另明确purge入口 | 部分手动卸载 | 先撤服务再移binary，默认不删用户store |
| PX0-115 | status聚合本地daemon、下次fire、失败/待审批/停用 | 部分 Foundation/W | 不联网/不调模型，真实状态、非零退出码 |
| PX0-116 | doctor：凭据、锁、schema、version、connections、workflow | 部分 CLI：基础诊断 | 针对真实故障给正确操作，不能仅binary存在 |
| PX0-117 | doctor：harness实际调用、index/private计数、update | 部分 CLI | 缺失与零区别；慢/联网检查可跳过、不能暗触付费调用 |
| PX0-118 | 网络目的地、prompt/log内容、Secret/Fixture持有边界 | 部分当前README/实现 | 所有新增外部路径都有真实数据流验证 |
| PX0-119 | update.channel stable/beta | **官方资料冲突** | Updating称可用，Configuration明确未接通；需版本/命令证据确认 |
| PX0-120 | connectors.provider 可切换后端 | **官方明确未接通** | 不能列为已交付；当前参考仍统一Composio |

## 不应混淆的范围与待确认事项

- [Configuration](https://docs.px0.ai/reference/configuration)明确把 `update.channel` 和 `connectors.provider` 列为尚未接通；不能因营销或另页示例改成“官方已验证”。
- [Run](https://docs.px0.ai/workflows/run)的 Dry Run 会调用模型，但 [Privacy](https://docs.px0.ai/reference/privacy)中“无向外执行”的概述容易被理解成绝不联网。Vela 的潜在写入命令全部 stub 是已存在的项目约束；可增加显式、审阅过的模型预览能力，但不得把普通 Dry Run 改为可运行任意 Agent。
- px0 的私有目录是检索排除；其 `shell.run` 明确能做用户能做的事。Vela 必须继续区分 Vela 传入上下文的边界与获批第三方进程自身的文件/网络权限。无需复制参考产品更宽的默认权限。
- 不能因为 Vela 是 macOS 项目而把 PX0-027 的参考跨平台能力标成覆盖；应保留独立平台差异，并按项目目标决定后续平台实现。
- 没有独立的 eval API 文档页；px0 此处公开的评估能力是 run marks、health、improve、fixtures replay。不能从名称推断它具备统计显著性检验或把 Vela Lab 的命令对照当其所有功能替代品。

## 首个实现切片与验收

优先接通 PX0-009–017：版本化输入合同 → 有界原文快照 → 明确 agent 参数中的真实 prompt → 用户审阅同一冻结 payload → 实际进程输出及run证据。该切片减少最核心的“资产仅存在数据库、运行没有用到”断点，不要求引入新框架或另开托管服务。

对应新增 [WorkflowContext.swift](../../Sources/VelaCore/WorkflowContext.swift)、[WorkflowContextTests.swift](../../Tests/VelaCoreTests/WorkflowContextTests.swift)、[ADR 0008](../adr/0008-workflow-context-execution.md)。支持的显式 context v1：固定 Git 只读输入、当前项目公开 Library 检索、stdin、literal/typed values，现有 Guideline 与 Active Memory 有界注入；真实命令仍逐项审批。旧 raw argv 保持字面值。历史回放改为复用捕获记录、零工具/模型调用，明确不等于 PX0-098 双模型对比。

验收必须同时通过：实际 fixture 进程收到精确 prompt；审批后改 Memory/Guideline/Workflow 不影响已冻结动作；Private/其他项目/候选记忆不进入；模板中的数据不再次解释；超预算/缺必需输入失败；Dry Run不运行命令；历史输入不被今天Git状态替代；手改Markdown确实生效；旧workflow回归不变。本文件不将尚未完成的上述验证提前记为通过。

后续必须继续覆盖：自然语言模型规划、子workflow/pipeline、通用受限tool loop、外部连接目录、后台服务、完整历史与产物、混合检索、Ask会话、双版本模型回放、跨机器store与完整CLI。单个已通过切片不关闭这些事项。

## English summary

This inventory fixes the public px0 surface as reviewed on 2026-09-13 and compares it with Vela commit `ea8fbd257f813c604a93e070d5f98a6337829d81`. The 120 independently identified requirements retain missing capabilities rather than relabeling a partial UI as parity. “Officially delivered” means documented by the reference product; px0 itself was not installed or exercised here. The official configuration guide explicitly identifies two unwired settings, including an update-channel claim contradicted elsewhere.

The first implementation connects explicitly declared workflow inputs, guidelines and active project memory to a frozen prompt passed to the actual approved process. Legacy argv remains literal. Captured-record replay makes no tool or model call and is not advertised as dual-model evaluation. Full parity still requires the remaining planner, connector, scheduler, pipeline, retrieval, history, store, platform and CLI acceptance work. Every success claim must identify the exact Vela revision and actual verification evidence.

## 第二个增量：审批式自然语言规划

[WorkflowPlanning.swift](../../Sources/VelaCore/WorkflowPlanning.swift) 与 [RestrictedCodexProposal.swift](../../Sources/VelaCore/RestrictedCodexProposal.swift) 提供显式选择 Codex executable/model/effort 的冻结规划任务。每轮请求先产生专用审批；实际进程仅在独立临时目录按冻结的只读、禁工具协议运行。模型输出仅为受限 JSON 数据，不能自行添加可执行文件、未知 tool slug 或权限。追问保留原请求、回答历史与上一版本 hash；取消、失败及不确定执行不能二次运行。合法结果为未保存、停用的 workflow draft，用户须显式 `workflows.save` 接受。接口详见[规划合同](../implementation/workflow-planning-contract.md)与 [ADR 0012](../adr/0012-reviewed-workflow-planning.md)。

`WorkflowPlanningTests` 的六项合成 CLI 定点验证已通过，包括真实 argv/独立工作目录、取消和重启、畸形输出、额外工具/可执行字段与版本篡改反例。合成 fixture 的 token 数不作为真实模型花费。真实提供商联调的范围与证据由集成验证单独记录。本增量没有完成 Composio discovery/authorization、模型式 Guideline 重拟或完整工具运行循环，不关闭 PX0-003/005/007 及其余未完成条目。

English: Reviewed planning now runs a specifically chosen local Codex CLI only after a frozen approval, then validates its single structured answer against the current read-only catalog. It yields an unsaved, disabled draft; follow-ups preserve the original request and version hash. Synthetic protocol/process tests passed. This is not a claim of complete connector, guideline, pipeline or autonomous tool-loop parity.

## 第三个增量：子工作流、pipeline 与根产物

[WorkflowComposition.swift](../../Sources/VelaCore/WorkflowComposition.swift) 接通 PX0-013、020、021 的 Core 路径：同项目冻结依赖图、子输入、每段独立 run、顺序传文本、always/has_output/no_output、跳过透传、失败停止、禁嵌套/循环/超深/超量。子审批完成沿父链推进；runs.get 纯读，runs.resume 使用已保存 ledger 结果恢复，未知副作用不重跑。子产物始终 memory，根才向调用方、store/output 文件或产物 Inbox 交付；这是 PX0-018/019 的 Core 实现，不等同于完整独立 CLI/UI 已验收。

24 项 Workflow 定点测试（10 composition、8 context、6 planning）在该次修改上通过，包括真实多段命令/冻结审批、原始输入的模板边界、子定义变化后的冻结执行、根文件单次交付、已执行结果的中断恢复、Unknown Dry Run 条件、Private/项目隔离、output symlink 与并发安全。完整产物合同见[工作流组合](../implementation/workflow-composition-contract.md)和 [ADR 0015](../adr/0015-workflow-composition.md)。历史 composition 回放只读取 hash 验证过的捕获文本；不会创建子运行、调用模型或重复交付文件，仍不冒充 PX0-098 双模型重放。

后台调度独立审查另发现并修正三个 P1：deferred 的 app_start 丢事件、latest 补跑跳过旧 uncertain claim、acknowledge 后崩溃使 schedule 永久锁住。根代理完成修复；独立 SchedulerReviewTests 覆盖对应边界。Daemon 增加独立退出信号和当前子进程组回收，真实阻塞 Git 读在 0.412 秒内随 daemon 正常退出。实际 launchd 临时 job 完成 bootstrap/print/异常 KeepAlive 重启/bootout/uninstall，既有用户 LaunchAgents 未变动，全部临时 job/文件已清理。具体二进制 hash 见 `output/parity/daemon-shutdown-review-after.json`、`output/parity/launchd-lifecycle.json`。这些证据不覆盖 Linux daemon、长期资源消耗、通用 watch 或所有维护任务。

English: The core now composes frozen child workflows, preserves individual approvals and resumes from known results. Root-only output delivery and captured-text replay have focused process and safety tests. Independent scheduler and real launchd lifecycle tests addressed restart and shutdown failure cases. The remaining public px0 requirements—including autonomous tool execution, connectors, richer retrieval, replay evaluation, platform coverage and complete UI/CLI acceptance—remain open until individually implemented and verified.

### 审批与文件交付恢复复验

`ApprovalRecoveryTests` 的 5 个反例已通过：同事务期望缺失冲突不留下半批数据、两个实例同时准备仅有一条绑定审批、过期审批不能批准或拒绝已改动的 run、真实 SIGTERM 与普通 exit 200 区分，以及真实超时 optional 子动作只写一次 marker 并阻止父链继续。连同 Workflow Context/Planning/Composition，本次定点 29/29；日志 `output/parity/px0/approval-recovery-focused-fixed.log`。首次运行的 28/29 失败是 timeout 测试定义漏填 context 显式调用模式，修正测试数据后重跑。

独立 `CompositionReviewTests` 复现并回归了 prepared output 恢复覆盖更新产物、uncertain ledger 与 run 落盘不同步两处缺陷；第三例验证 16 次并发恢复不重复交付。修复后 3/3，原始反例与复验分别保留在 `output/parity/blume/composition-review-first.log`、`output/parity/blume/composition-review-fixed.log`。这些结果验证具体恢复边界，不能替代整机最新冻结版本的全量验收。

English: Five focused approval regressions and three independent crash-recovery regressions passed. They cover atomic pending bindings, stale decisions, real signal/timeout uncertainty, preservation of newer artifacts, and concurrent recovery without repeated delivery. Whole-product acceptance remains pending.

## 第四个增量：可审阅工作流管理与有界资产读取

`WorkflowManagement.swift` 增加 get、逐项 validate、clone、setEnabled、归档 remove 和 restore，覆盖 PX0-025 的 Core 合同。get/validate 不导入手改、不运行输入；变更操作核对审阅 snapshotHash；clone 新身份且停用；活跃 run 或依赖引用阻止归档；恢复停用。工作流及版本通过同事务 CAS 保存。文件读取共用 descriptor 验证、NOFOLLOW/NONBLOCK、有界读取与目录身份复查，FIFO、符号链接、硬链接、过量及损坏 Markdown 均有反例。

管理 7 项连同 Context/Planning/Composition/Approval/SafeApply 等相关边界共52项定点通过，日志 `output/parity/px0/workflow-management-final-focused.log`。这仍是数据库管理资产和 JSON frontmatter（YAML 子集）的工作流，不关闭 PX0-008 的任意 YAML/递归发现兼容要求。合同见[工作流管理](../implementation/workflow-management-contract.md)、[ADR0019](../adr/0019-reviewed-workflow-management.md)。独立组合恢复随后新增“锁前旧 child 快照回退已完成后续步骤”反例；修复后4/4见 `output/parity/blume/composition-review-verified.log`，历史失败保留。

## 第五个增量：实际模型—工具—模型闭环

`AgentLoopService.swift` 使用用户明确选择的现有 Codex CLI，每轮输出受限 JSON 决策，Core 执行冻结目录中真实 Git/Memory/公开 Library 读取，将真实 receipt 反馈下一轮。工作流可显式调用 agent.loop 并传入冻结 context，raw agent.run argv 保持兼容。目录、schema、模型参数、调用上限和单次/总时限在初始审批冻结；Dry Run 全 stub。外部 Composio 调用只能生成新的独立 action/run/approval，入队不再请求 metadata，实际批准才复查账户/profile generation/schema。模型最终产物附真实排队 approval IDs，不能把排队当作执行成功。

闭环初版连同管理/Context/Composition/Approval/Connector定点55/55通过，日志 `output/parity/px0/agent-loop-focused-final.log`。随后排队时目录失效不出站、独立动作拒绝旧身份的定点为10 Loop +12 Connector，共22/22，`output/parity/px0/agent-loop-queue-deadline.log`。这些均为真实本地进程及合成 connector transport，不能证明用户真实外部账户可用。

一次真实 Codex 验证由 `scripts/test-agent-loop-live.py --live` 完成，证据 `output/parity/live-provider/tool-loop-attempt-1/receipt.json`：冻结 helper SHA256 `90e315ce5de945be9a9b7332d5467a80b1259fa2dc691cd6d03bec2848507bcd`，CLI 0.154.0，请求 gpt-5.6-sol/low，2个模型轮次、1次实际 git.status、17.967秒。第二轮 prompt 和最终回答含初始请求没有、只有 Git 能观察到的随机文件名。provider 报告 input+output tokens 合计20185，actual model identity 与成本未返回，记 unavailable。此单次实验没有外部写、用户数据或自动重试，临时 store/项目/helper 已清理。

独立审查先实际复现3组失败：冻结 Library 后标为 private-origin、删除 managed asset，仍启动模型；fractional/negative schema bounds 被接受。修复后所有模型出站前使用 fresh Library asset + isPublic 检查，schema 布尔与长度边界严格验证。4独立反例+10Loop+8Context共22/22见 `output/parity/px0/agent-loop-privacy-schema-fixed.log`；独立复验连同 Ask/Library21/21见 `output/parity/blume/review-boundaries-final.json`。claimed/response_received/decided 崩溃账本均不二次调用模型。CLI 同连接长审批期间 get/cancel 被队列阻塞也已由根代理修复，真实普通/饱和队列隔离脚本验证见集成证据，原失败保留。

该增量补足真实多轮工具决策与排队后继续产出能力，不能关闭完整第三方工具目录、所有 JSON Schema/provider 协议、平台和 UI/CLI 验收。观测 token 阈值只在真实 usage 返回后阻止下一轮，单轮可能超过阈值；它不是预扣配额。合同见[模型工具循环](../implementation/agent-loop-contract.md)和 [ADR0020](../adr/0020-reviewed-model-tool-loops.md)。

English: Reviewed workflow management and bounded asset reads now have focused regression evidence. The new restricted loop completed a real synthetic Git task through two Codex turns and one actual tool read. External actions remain independently approved; missing model identity and price remain unavailable. Independent privacy, malformed-schema and crash-state failures were reproduced and fixed. These concrete increments do not establish full px0 parity, real external-account compatibility, or final packaged-product acceptance.

## 第六个增量：只读工具 Watch 与 macOS 文件观察

PX0-032/033 的本地受限目录现在有完整 Core 路径：Git status/diff/log、scope 合格 Memory recall、公开 Library retrieve，首轮baseline、稳定结果hash、item key变化、跨重启积累、minItems/debounce、固定间隔、关闭/重新启用、dry preview、等待审批保留新增变化。同事务提交 schedule_event claim 与 watch水位；unknown沿既有显式ack合同，不重派。上下文事件仅含公开来源ID/hash，正文要重新检索，不将旧私有正文注入工作流。任意外部只读工具尚未得到相同权限与真实账户验证，因此 PX0-032/033 的完整外部目录范围仍保持未完成。

独立审查曾实际复现一处P1：来源离开检索窗口形成removed事件，debounce期间变私有，其before仍被派发。现在合并后、等待期间和claim前都复查pending的before/after全体来源，撤销后重新判断minItems。修前 `output/parity/watch-review-first.json`，修后 `output/parity/px0/watch-private-history-fixed.json`；不丢弃失败证据。

Vela额外实现 source files：系统FSEvents提示、descriptor安全SHA256字节快照、项目内不重叠路径/递归/ignore、删除/目录变化、具有inode/hash证据的rename、atomic replacement。同mtime不同字节仍识别，同字节原子替换不触发。闲置tick不重新读取文件内容；process/stream重启、drop事件只核对可证明的净变化，historyIncomplete不伪造历史。链接/FIFO、Private、数量/字节超量、不完整扫描保留旧水位。该扩展不能替代px0第三方tool watch验收。

稳定切片43/43定点通过（8 FileWatch、11 Watch、1独立WatchReview及Scheduler/Management回归），`output/parity/px0/watch-stable.json`，快照 `9dd9089a7bf4f12c51bed17290e9bf840bdfedbf8ead5bca16359ba5d205821c`。包括真实FSEvents、same-size/same-mtime二进制字节、rename/delete/atomic、idle扫描计数、stream原实例重启、实际printf收到冻结watchInput、16并发仅一event/run、失败水位不动。最后一个中间快照编译失败来自同期SessionHistory测试声明，后续明确修复后复验，并非被隐藏的Watch行为失败。

两次独立真实daemon工具/文件观察均通过 `scripts/test-watch-daemon.py`：工具源32.315秒（helper `fe8cd10b1afa64bbf4a0a29c2844924874b1533fa98dca80fc3597eb83f35c3e`）；文件源32.165秒（helper `57b3926a78e274c74ed4e5941f1bbe1126da49a7c6fc5bf68ddf9f0e047b3df0`），实际FSEvent ID 881546445、读取1文件34bytes。各生成1个待审批run，未批准写0，重启重复0，两次干净退出；没有模型、外部请求或launchd注册，临时项目/store/helper已清理。证据为 `output/parity/px0/watch-daemon-live.json`、`output/parity/px0/file-watch-daemon-live.json`；二进制随后glob和stream恢复修复由43项稳定源码定点覆盖，不能把旧binary hash当当前包验收。

接口、状态、硬界限与UI数据字段见[Watch合同](../implementation/workflow-watch-contract.md)和 [ADR0024](../adr/0024-durable-read-tool-watches.md)。界面仍通过指定Antigravity作者实施并单独验收。

English: Durable local tool watches and macOS FSEvents now share the scheduler's atomic dispatch journal, scope checks and approvals. Forty-three focused regressions passed, including real system events and process-level frozen input delivery. Two synthetic daemon lifecycle exercises dispatched exactly one pending run each, performed zero unapproved writes and did not repeat after restart. The local catalogue, filesystem extension, external-tool compatibility and packaged UI acceptance remain separately tracked scopes.
