# Vela 当前 API 契约

本文对应 `0.1.0-preview.1` 的实际实现，供原生壳、Web UI、CLI 和 MCP 集成使用。完整产品需求见 [requirements.md](../requirements.md)，交付状态见 [status.md](../status.md)。本文不代表 P0–P2 全部功能已完成；不支持的能力不能用模拟结果替代。

所有前端 UI、样式与原生界面由用户指定的 Antigravity CLI `gemini-3.8-flash-high`（High）实现。核心实现不复制 Blume 私有源码、提示词或品牌。以下类型中的 `?` 表示可选字段，`JSON` 表示 JSON 对象。

## 1. 传输、并发与原生桥接

### JSONL helper

```text
vela rpc [--home PATH] [--no-watch]
stdin  → {"id":"request-1","method":"sessions.list","params":{}}
stdout ← {"id":"request-1","result":[]}
stdout ← {"id":"request-1","error":{"message":"...","code":-32602}}
stdout ← {"event":"data.changed"}
```

- 请求、响应各占一行，stdout 只输出 JSON，诊断写 stderr。无效 JSON 返回错误；解析后的单行上限为 2,000,000 字节，路由方法名少于 100 字符、params 少于 80 个键，服务进一步验证类型、大小和权限。
- helper 内有两条串行队列：`workflows.* / runs.* / improve.* / lab.* / approvals.* / inbox.* / evidence.*` 进入 Automation 队列，其余请求进入 Foundation 队列。两队列可并行，跨队列响应可能乱序，客户端必须按 `id` 关联，不能按发送顺序解包。
- 最多 32 个已进入处理队列的请求。长 Workflow / Lab 不占用 Foundation 请求队列，但共享 SQLite 和进程资源，不等于完全性能隔离。
- RPC 默认启动 FSEvents 和初次受限索引；摄取确实更新数据后发送无 `id` 的 `data.changed`。这不是每次对象修改的通用变更总线，客户端仍须处理方法响应与必要刷新。
- Scheduler 在 Automation 队列上于启动约 10 秒后开始、每 30 秒 tick；长自动化期间排队，不与同 helper 中的执行重叠。
- stdin EOF 后等待已提交请求完成，再停止 watcher 和 timer。`vela mcp` 不启动 watcher 或 Scheduler；MCP 请求全部走 Foundation 队列。

### WebKit bridge

```javascript
const result = await window.vela.call(method, params);
// 原生入口：window.webkit.messageHandlers.vela.postMessage({id, method, params})
// 原生响应：window.__velaReceive(response)
```

WebKit 只加载随包页面，原生壳限制可调用方法。它收到 `data.changed` 后约 150 ms 防抖，向页面发出 `vela:refresh` 事件。页面关闭/隐藏时，原生菜单栏每 5 秒读取一次 dashboard；前台页面处理刷新与用户操作。

Bridge 普通请求超时 180 秒，长操作超时 1,800 秒。客户端超时不构成后端取消或重新执行授权；执行状态以持久化 Run / Approval / Eval 为准。没有通用的取消任意正在运行任务 API。

浏览器直接打开 UI 时只能显示明确标注的 demo 模式；存在原生 bridge 时不得回退假数据。生产安装包移除 demo fixtures。加载、空结果、错误和不可用状态必须可见。

| 原生方法 | 参数 | 返回与边界 |
| --- | --- | --- |
| `system.ready` | `{}` | `true` |
| `system.info` | `{}` | `{channel,home,version,helperRunning,notificationsStatus,launchAtLoginStatus,launchAtLoginSupported}`；其中壳版本字段与 CLI `system.version` 分开维护，发行版本以打包元信息/CLI为准 |
| `system.chooseProject` | `{}` | 所选目录绝对路径字符串；取消为 `null`；选择本身不登记项目 |
| `system.openExternal` | `{url}` | 仅 HTTPS；成功发起系统打开后返回 `true` |
| `system.reveal` | `{path}` | 仅已存在且位于 Vela store 或已知项目范围内的文件/目录 |
| `system.updateStatus` | `{running?,approvals?}` | 兼容性确认，不采用 renderer 的项目筛选数量覆盖菜单栏；计数来自原生全局轮询 |
| `system.previewNotificationSound` | `{kind:"approval"或"completed"或"error"}` | 原生专用主动试听，仅使用随包声音白名单；不请求通知授权、不改变偏好、不接收声音路径。CLI/MCP 不提供该方法；浏览器测试不代表真实发声 |
| `system.version` | `{}` | 转发 helper，返回 `{version,platform:"macOS",home}` |

`settings.save` 经桌面壳调用时会处理通知授权和 `SMAppService` 登录启动登记；经 CLI 直接调用只保存偏好。界面允许清单不包含所有 CLI 内部方法，例如 `signals.record`、`suggestions.draft`、`ask`、`doctor` 不属于当前 WebKit 通用桥接入口。

## 2. 本地存储与核心服务

```swift
public typealias JSON = [String: Any]
public final class VelaStore {
    public let root: URL
    public init(root: URL) throws
    public func put(_ kind: String, _ object: JSON) throws -> JSON
    public func putBatch(_ objects: [(String, JSON)]) throws -> [JSON]
    public func get(_ kind: String, _ id: String) throws -> JSON?
    public func list(_ kind: String, project: String? = nil, limit: Int = 500) throws -> [JSON]
    public func remove(_ kind: String, _ id: String) throws
    public func search(_ query: String, project: String? = nil,
                       includePrivate: Bool = false, limit: Int = 50) throws -> [JSON]
    public func claimState(kind: String, id: String, expected: String,
                           newState: String, fields: JSON = [:]) throws -> JSON?
    public func insertIfAbsent(_ kind: String, _ object: JSON) throws -> Bool
    public func sessionRevision() throws -> Int64
}
```

- 系统 SQLite，WAL、FULLMUTEX、参数化 SQL、实例内 `NSRecursiveLock`；运行时使用 `synchronous=NORMAL`。这不构成断电后外部副作用全局 exactly-once 的保证。
- 通用对象保存 `id,kind,createdAt,updatedAt` 和业务字段。`put` 始终把 `kind` 设为存储对象类型，例如 `eval`；评测类别另用 `evaluationKind`。
- `list` 默认 500 条、最大 10,000；Search 默认 50 条、最大 500。当前不是完整分页游标接口。Session summary 在 SQL 中移除 messages/content，避免 dashboard 读取整个转录。
- `memory/workflow/guideline/library/checkpoint` 长期资产为 `assets/<kind>/<id>.md`；SQLite 保存索引、关系、状态和账本。受限读取会同步人工编辑过的标题/正文。Workflow 在运行前额外解析并校验正文 frontmatter，修改结构则建立新版本，无效结构拒绝运行。
- `putBatch` 提供数据库事务与 Markdown 失败补偿；不宣称数据库加多个文件具备操作系统级原子可见性。
- `claimState` 仅用于 approval/schedule/run，通过事务与旧状态条件原子领取；`insertIfAbsent` 用于 schedule_event/schedule/run/approval，按固定 `(kind,id)` 唯一键防重复。
- `sessionRevision` 读取单行持久化计数器；SQLite trigger 在 session 新增、JSON变化或删除时递增，可感知其他连接的写入。读取成本不随会话历史条数增长，其他对象写入不推进此水位。
- 辅助函数：`VelaError(String)`、`jsonString(Any)`、`isoNow()`、`stableHash(String)`（SHA-256）、`canonicalProject(String)`（包含 macOS `/private/var` 别名处理）。

服务分工：`FoundationService` 管理 Session、Setup、Usage、项目，并分派 `MemoryService` 的 Memory/Recall/Library/Checkpoint；`ContextService` 管理 Guideline、本地 Workflow Builder、贡献草案和回归统计；`AutomationService` 管理执行、审批、Improve、Lab、Scheduler 与证据。各服务 `handle(method,params)` 对未知方法返回 `nil`，最终 Router 才返回不支持错误。

## 3. Foundation 与工程上下文 API

### 观察与配置

| 方法 | 参数 | 返回与行为 |
| --- | --- | --- |
| `dashboard.get` | `{project?}` | `projects,sessions,memories,workflows,runs,suggestions,approvals,evals,artifacts,library,harnesses,usage,stats,settings,ingestion`；project/harness列表不按所选项目缩减，其他对象按项目过滤 |
| `projects.list` | `{}` | project 数组 |
| `projects.add` | `{path}` | 登记存在的绝对目录或 `~/` 路径，返回 `{id,title,path,project,state}`；不要求必须是 Git 仓库 |
| `projects.remove` | `{id}` | 仅移除登记，`{removed:true,filesDeleted:false}`；不是删除工程、清空所有历史或永久排除摄取 |
| `agents.list` | `{}` | 三个 harness 的检测结果：`provider,installed,executable,sourceDirectories,quotaAvailable:false,liveStatusAvailable:false,capabilities`；当前运行卡片来自 Session，不能把此列表误当进程清单 |
| `sessions.refresh` | `{}` | `{sourceFilesChecked,sourcesUpdated,sessionCount,historyFullyIndexed:false,initialFileLimit,initialTailBytes,diagnostics}` |
| `sessions.list` | `{project?,query?}` | 轻量 session 数组；query 匹配标题/正文索引 |
| `sessions.get` | `{id}` | session 及保留范围内的 messages；移除内部 usageByMessage |
| `setup.list` | `{project?}` | 已索引且 `origin=setup` 的 artifact 数组 |
| `setup.scan` | `{project?}` | `{artifacts,diagnostics,scannedProjects,globalScope,sourceFilesModified:false,scannedAt}`；显式项目或已登记项目加已知 global 配置路径 |
| `setup.audit` | `{project?}` | 扫描后 `{artifacts,diagnostics,auditedAt,method}`；当前为语法、重复内容和上下文大小等确定性检查 |
| `usage.get` | `{project?}` | 日志用量聚合，结构见下 |

Session 常见字段：`id,provider,title,project,cwd,branch,model,state,startedAt,lastActivity,updatedAt,tokenInput,tokenOutput,sourcePath,messageCount,statusSource,statusInferred,messagesTruncated,historyFullyIndexed`。消息为 `{id,role,content,timestamp,tool?}`，不同 provider 缺失字段不保证存在。状态包含 `Running/Idle/Needs Approval/Completed/Error/Stopped/Unknown`；当前使用日志证据，未验证进程活性。原状态 Running 的最近活动超过 45 秒可推断为 Idle，超过 6 小时为 Unknown，并保留 `statusInferred`。

新摄取记录的 `startedAtSource/lastActivitySource` 为 `provider`（原事件显式提供字符串时间）或 `ingestion_fallback`（缺时间而使用索引时钟）。`provider` 不保证日期有效或进程活跃；通知策略仍解析日期、检查时间范围。旧索引缺少来源字段时保持未知，不能把 `createdAt/updatedAt` 当作源事件发生时间。

初次导入最多 60 个近期文件，初始尾窗 256 KiB，流式单次读取上限 8 MiB，每会话保留最多 1,000 条消息；后续用 FSEvents 处理变更路径，历史截断必须显示。Cursor 仅支持已知 JSON/JSONL 导出和只读 SQLite composerData 记录，未知私有 schema 返回诊断。

Artifact 常见字段：`id,origin,title,type,scope,provider,path,project,state,hash,content,tokens,redacted,diagnostics,containsHooks?,containsMCP?`。content 是脱敏内容，hash 对应原始文本；tokens 为保守字符估算，不能宣称精确 tokenizer 结果。当前不包含完整 Hook 有效性、MCP drift 或语义规则冲突审计。

```text
usage = {
  providers: [{provider,inputTokens,outputTokens,totalTokens,sessionCount,quotaAvailable:false}],
  daily: [{date,tokens}], totalTokens, sessionCount,
  quotaAvailable:false, costAvailable:false, historyFullyIndexed:false, coverage
}
```

daily 把会话用量归入 session 起始日，不是每次 token 发生时刻的精准日账。没有订阅窗口百分比、价格或 reset 数据，不能从 token 总量推导配额。

### Memory、Recall 与 Library

| 方法 | 参数 | 返回与约束 |
| --- | --- | --- |
| `memory.list` | `{project?}` | Memory 数组；人类本地管理接口，不仅限 Active；MCP另强制项目与private过滤 |
| `memory.save` | `{id?,title,content,type?,scope?,project?,state?,sourceSession?,sourceMessage?,sourceFile?,sourceCommit?,branch?,worktree?,task?,private?}` | 默认 `type=fact,scope=project,state=candidate`；非global必须指定project；不能通过编辑改变既有状态或跨项目移动 |
| `memory.transition` | `{id,state,supersedes?}` | 状态转换；supersedes 只允许激活新条目时替代同项目的 Active 条目，两条状态通过存储批次更新 |
| `recall` | `{project,query?,branch?,worktree?,task?,sessionId?,files?:string[],symbols?:string[],budget?}` | `{items,usedTokens,budget,tokenAccounting,truncated}`；没有单独的scope字符串筛选器 |
| `search` | `{query,project?,includePrivate?}` | 人类本地搜索，默认排除private；当前索引类别为 session/memory/workflow/guideline/library/checkpoint/artifact |
| `library.list` | `{project?}` | 人类管理用 Library 数组 |
| `library.add` | `{id?,title,project?,content?,path?,url?,private?}` | 返回 Library；url 优先于path，导入上限2 MiB，当前默认private=true |
| `checkpoint.list` | `{project?}` | Checkpoint 数组 |
| `checkpoint.save` | `{id?,project,title?,goal,completed?,pending?,tests?,nextActions?,decisions?:string[],failures?:string[],changedFiles?:string[],sessionId?}` | 本地 Markdown及对象；completed/pending/tests/nextActions支持字符串或字符串数组，并尝试捕获真实Git branch/commit/status |
| `checkpoint.export` | `{id,provider?}` | `{path,content,command,provider,executed:false}`；provider默认codex，可选claude/cursor；command是交接提示文本，不是已执行的原生session迁移或保证可直接运行的shell命令 |

Memory 类型保存为小写：`decision/constraint/preference/failure/fact/workflow knowledge/observation/hypothesis/checkpoint`。scope 为 `global/project/repository/branch/worktree/task/session`；branch/worktree/task/session 各需相应定位字段（session 使用 sourceSession）。状态转换为 `candidate → active或archived`、`active → superseded或archived`、`superseded → archived`，archived不直接恢复。

Recall 只返回 Active、非private、同项目或global Memory；branch/worktree/task/session需匹配调用上下文。当前按标题、正文、文件、symbol词面命中排序；scope授权先于排序。默认预算2,000，上限4,000，可为0；按字符保守估算，CJK每个scalar计2，加每条包装开销32，不是模型精确token账。

Library 支持UTF-8文本/Markdown、HTML文本提取、PDF可提取文字、DOCX；扫描PDF无OCR时返回明确错误。显式URL导入使用HTTP/HTTPS，不接受内嵌凭据。来源路径中用户的private/.private目录强制private（系统/private/var不误判）。Private库可在人类搜索显式包含，不能通过MCP/Recall/Workflow自动取用；当前Recall仅召回Memory，没有实现Library语义召回。

### ContextService

| 方法 | 参数 | 返回与行为 |
| --- | --- | --- |
| `guidelines.list` | `{project?}` | guideline 数组 |
| `guidelines.save` | `{id?,title,content,scope?:"project"或"global",project?}` | `state=active,tokens,version`；标题≤240字符、正文≤128KiB；更新保留项目边界并创建 guideline_version |
| `workflows.build` | `{project,description}` | `{workflow,unresolvedInputs,mode:"deterministic-local-builder",saved:false,approvalRequired,message}`；project须登记，description≤8,000字符；读取真实package scripts/lockfile/Package.swift，生成Git/测试/typecheck草案；不保存、不执行、不调用模型 |
| `regression.list` | `{project?}` | `{workflowComparisons,evaluations,message}`；比较有运行记录的最近两个workflow版本，样本排除dryRun，返回runs/successes/successRate/meanRuntimeMs；仅观测趋势，无自动因果归因或回归触发 |
| `signals.record` | `{project,title,content,sourceSession,...}` | 创建 `state=candidate,origin=contribution` signal；忽略传入id，sourceSession必须存在且同项目；不验证任意文本claim已成立 |
| `suggestions.draft` | `{project,title,content}` | 创建 `state=draft,origin=contribution,carrier=reference,operations:[],evidence:[]`；纯文本草案，不产生可直接Apply的文件操作 |

## 4. Workflow、审批与文件事务

### 定义与运行

`workflows.save` 接收：

```text
{id?,title,project,description?,
 trigger?:manual|cron|app_start|session_completed|agent_finished|git_event|usage_reset,
 cron?,enabled?,guidelines?:string[],
 steps:[{id?,title?,tool,arguments:{...}}]}
```

项目须已登记且存在；title≤240字符；1–40步；默认trigger=manual、enabled=false。版本自1递增，保存workflow、workflow_version和Markdown。运行前读取人工编辑过的JSON frontmatter，校验身份、项目、工具及参数；不能通过编辑资产移到另一项目。

| 工具 | arguments | 实际权限 |
| --- | --- | --- |
| `git.status` | `{}` | 真实只读status；禁用fsmonitor、hooks和可选index锁 |
| `git.diff` | `{}` | `git diff --stat HEAD`，禁止external diff/textconv；不是完整patch返回 |
| `git.log` | `{}` | 最近10条提交摘要 |
| `shell.test` / `shell.typecheck` | `{executable,args?:string[],timeoutSeconds?}` | 必须审批，因为测试可运行任意项目代码 |
| `agent.run` | 同上 | 必须审批；调用用户明确选择的可执行CLI，不自动假定provider/model/订阅用量 |
| `file.write` | `{path,content}` | 必须审批；目标仅在所选项目内，审批快照追加当前baseHash；拒绝受保护路径、越界、symlink及不安全文件 |

命令解析为绝对executable和分离参数，不拼接隐式shell。执行超时默认120秒、执行器限制1–3,600秒；stdout/stderr合并输出最多1MiB并记录truncated。子进程净化敏感环境、创建独立进程组，超时终止整组；这不是OS文件访问沙箱。

| 方法 | 参数 | 返回与行为 |
| --- | --- | --- |
| `workflows.list` | `{project?}` | workflow数组 |
| `workflows.run` | `{id,dryRun?}` | 默认dryRun=true；保存并执行run，遇副作用步骤暂停为pending_approval |
| `runs.list` / `runs.get` | `{project?}` / `{id}` | 真实持久化Run Ledger |
| `workflows.replay` | `{runId}` | 使用原run冻结workflow创建新的dryRun，带replayOf，不复用旧审批 |
| `workflows.health` | `{id?}` | `{workflowId,runs,completedRuns,successes,failures,successRate,averageDurationMs,approvalRejected,tokens:null,tokensAvailable:false,guidelineInfluence:"not_measured"}`；零样本率为null |
| `inbox.list` | `{}` | pending/executing/needs_review审批数组，不只返回待点击项 |
| `approvals.decide` | `{id,decision:"approve"或"reject",snapshotHash}` | 领取并决定冻结动作；approve可继续后续步骤并产生下一个审批；reject停止该run |

Run 常见字段：`id,title,project,workflowId,workflowVersion,workflowSnapshot,state,steps,startedAt,completedAt?,durationMs,dryRun,inputs,memoryUsed,guidelinesUsed,guidelineUseMode,replayOf?`。steps含 `id,title,tool,arguments,state,output?,exitCode?,durationMs?,timedOut?,truncated?,approvalId?,journalId?`。Run状态使用小写，例如running/pending_approval/completed/failed/rejected。`guidelinesUsed`目前仅快照，`guidelineUseMode=snapshot_only_not_injected`；memoryUsed/inputs当前未提供完整自动填充。

审批对象保存 `id,title,runId,stepIndex,tool,arguments,project,snapshotHash,state`。hash绑定tool/arguments/project/runId/stepIndex；批准前和数据库原子claim后都校验。只允许pending被领取，失败/已执行/中断的动作不能直接重放；executing后崩溃可能已产生副作用，应检查账本。当前无审批编辑API和任意外部系统幂等协议，不能宣称外部副作用全局exactly-once。

### Improve与Safe Apply

| 方法 | 参数 | 返回与行为 |
| --- | --- | --- |
| `improve.analyze` | `{project?}` | `{signals,clusters,suggestions,method,modelCalled:false}`；真实user消息的明确纠错语言规则，至少3信号且2不同session晋升，重跑不重复增加同源signal |
| `improve.list` | `{project?}` | suggestion数组 |
| `improve.preview` | `{id}` | 原suggestion加 `preview:[{path,before,beforeHash,content,afterHash,delete,stageName}]`；不会创建不存在目录，过期hash报错 |
| `improve.apply` | `{id}` | 只允许可应用状态与上下文工件路径；保存apply_journal，失败转needs_review |
| `improve.undo` | `{id}` | 仅Applied建议，当前文件仍匹配afterHash时恢复，否则保留用户改动 |
| `improve.dismiss` | `{id}` | 标为dismissed，不写项目文件 |
| `evidence.get` | `{id}` | `{object,references}`；读取已有来源引用，不是完整可推理的图数据库 |

Suggestion保存 `state,evidence,carrier,contextTokens,operations:[{path,baseHash,content}],journalId?` 等字段。不存在文件的baseHash使用字面值`absent`；存在文件必须是原始UTF-8文本的SHA-256。Apply需1–32个操作，每个文件≤2MiB，拒绝缺hash、重复路径、越界、symlink/hardlink、不安全文件及`.git/.env*`目标。建议写入目录比通用workflow file.write更窄，只允许已定义的context路径。

SafeApply用跨进程flock串行配置事务，逐级目录描述符/O_NOFOLLOW/文件身份检查、全部baseHash预检、staging、fsync、单文件rename、before/after journal和失败补偿；恢复前不会夺取另一进程的活跃事务锁。多文件不是操作系统级原子可见事务，无法安全恢复时返回needs_review。崩溃遗留stage仅按journal中的精确名字和内容hash清理，不扫描删除未知文件。

当前Improve没有模型语义Extraction/Clustering/Planner。Workflow carrier是证据Markdown草案，需在Builder中保存显式工具后才可执行；没有自动把草案安装成可运行workflow。

`settings.analysisEnabled=true` 时，Scheduler tick 比较 session revision 与已完成的 `analysis_state/background`；有变化或检测器版本变化才调用上述确定性分析。默认关闭，关闭期间不推进水位，重新开启会处理积累的已索引会话；仅成功完成后保存水位，失败下次重试。它不检测OS空闲、不调用模型/命令、不自动Apply。当前分析最多检查最近500个已索引Session及10,000个Signal，并非完整历史回填或逐Session增量抽取。

### Scheduler

每个workflow以enabled显式开启。cron为本地时区5字段，支持逗号、范围、步长，weekday 0–6。同一事件使用固定schedule_event ID原子插入领取，活跃或待审批run避免重叠。session_completed/agent_finished当前只观察每项目最新完成事件，git_event观察HEAD变化，app_start按helper启动触发；尚未补跑全部休眠期间事件。usage_reset因配额数据不可用，记录unavailable且不执行。

后台证据分析使用同一个约30秒tick，但由独立的analysisEnabled控制，不要求存在enabled workflow。MCP及单次CLI call没有周期timer；桌面应用或`vela rpc`运行期间才会定期检查。

## 5. Lab的实际参数与结果

```json
{
  "project": "/absolute/registered/repository",
  "title": "Paired context check",
  "kind": "context",
  "baseline": {"files": [{"path": "AGENTS.md", "content": "Baseline context"}]},
  "candidate": {"files": [{"path": "AGENTS.md", "content": "Candidate context"}]},
  "command": ["/absolute/executable", "argument"],
  "timeoutSeconds": 120,
  "repetitions": 1
}
```

- `lab.run`接受kind=context/memory/workflow；baseline/candidate是包含`files`数组的对象，空对象有效。每组最多16个相对路径文本文件，每文件≤1MiB；不接受绝对路径、`..`或`.git`目标。
- 项目须登记且有真实Git HEAD。command是明确executable/参数数组；timeout为1–600秒（默认120），repetitions为1–5（默认1）。创建请求保存Eval与冻结审批，返回pending_approval，尚未运行命令。
- 批准后按快照中的同commit建立独立detached worktree，应用各组文件，同command/timeout运行。多次重复交替baseline/candidate先后顺序，记录原工作树status前后是否一致，并清理本次worktree。
- `lab.list {project?}`返回eval数组；`lab.compare {id}`读取同一eval对象，不额外执行。

```text
eval = {
  id,title,project,kind:"eval",evaluationKind, state, evaluator:"deterministic_command",
  command,commit,baseline,candidate,timeoutSeconds,repetitions,approvalId,
  results:[{variant,repetition,commit,command,exitCode,output,durationMs,
            timedOut,truncated,configuredChanges,changedFiles,diffStat,
            tokens:null,tokensAvailable:false}],
  summary:{baseline:{runs,successes,passRate,averageDurationMs,runtimeVariance},
           candidate:{runs,successes,passRate,averageDurationMs,runtimeVariance},
           runtimeDeltaMs,successDelta,interpretation},
  originalWorktreeUnchanged,cleanupFailures,limitations,tokensAvailable:false
}
```

未执行对象没有可用summary；零样本比例及方差不足时为null。state=completed表示对照过程结束，即使某组命令失败，单组退出码仍如实保存。

这是实际命令对照设施，不是完整Agent Eval。选择memory/workflow类别不会自动注入Recall或运行历史workflow版本；调用方需显式构造variant文件及使用它们的命令。Git worktree不是OS沙箱，允许的命令仍可能访问外部路径。当前没有自动模型、reasoning、token、任务成功率或规则合规语义评判；不能由此声明Agent改善因果结论。

## 6. MCP权限契约

```text
vela mcp [--contribute] [--home PATH]
```

当前stdio JSON-RPC协议版本为`2024-11-05`，提供initialize/ping/tools/list/tools/call，接受initialized/cancelled通知；未实现resources、resource templates或prompts。默认只读，不启动历史watcher或scheduler。

**所有MCP工具均要求已登记的绝对project路径**，schema中project为必填，服务端重新规范化并查登记。每个工具的内容必填项由对应服务再次校验。调用会剥离id/path/supersedes/includePrivate，避免替换既有资产、注入路径或扩大读取权限。

| MCP工具 | 核心方法 | 权限与限制 |
| --- | --- | --- |
| `vela_search` | `search` | READ；强制includePrivate=false |
| `vela_recall` | `recall` | READ；Active + project/scope + budget约束 |
| `vela_memory_list` | `memory.list` | READ；project过滤后再去除private条目 |
| `vela_setup_list` | `setup.list` | READ；读取已索引脱敏artifact，不触发文件修改 |
| `vela_workflows_list` | `workflows.list` | READ；不运行workflow |
| `vela_evals_list` | `lab.list` | READ；不启动eval |
| `vela_checkpoints_list` | `checkpoint.list` | READ；不启动其他Agent |
| `vela_memory_contribute` | `memory.save` | 仅`--contribute`；创建Candidate，不能激活、替换已有条目 |
| `vela_checkpoint_save` | `checkpoint.save` | 仅`--contribute`；新建checkpoint，可读取Git状态 |
| `vela_signal_record` | `signals.record` | 仅`--contribute`；要求同项目真实sourceSession |
| `vela_suggestion_draft` | `suggestions.draft` | 仅`--contribute`；无operations，不能Apply |

`readOnlyHint`由read工具清单成员关系决定，所有contribute工具为false；`destructiveHint=false,openWorldHint=false`。这些注解描述工具暴露的动作，不承诺只读连接完全不更新内部索引元数据。结果为MCP文本content，其text包含序列化核心JSON。工具无权执行shell/Workflow/Lab、Apply/Undo、删除长期Memory或访问private库。

## 7. Settings、诊断与未完成范围

- `settings.get {}`：默认telemetry=false、notifications=false、analysisEnabled=false、launchAtLogin=false；notificationSound、notifyApprovals、notifyCompleted、notifyErrors默认true。旧偏好自动补齐新字段，保留既有选择；返回preferences对象。`dashboard.get.settings`使用相同默认值。
- `settings.save {notifications?,analysisEnabled?,launchAtLogin?,notificationSound?,notifyApprovals?,notifyCompleted?,notifyErrors?}`：仅接受这七个布尔字段，拒绝未知键、字符串和数值0/1，telemetry始终false。声音与分类开关受notifications总开关控制。analysisEnabled控制上述后台确定性证据分析；保存本身不立即分析，等待下个Scheduler tick。
- `dashboard.get`额外返回`notificationScope`：无项目筛选时为`"*"`，否则为所选项目绝对路径。原生通知策略仅消费全局快照，按集合首次建立静默基线、消费静音期间的转移，同批事件每类最多一条。UI的项目筛选不重置通知基线。
- 首次观察即完成/失败的 Run，仅在其真实`createdAt`处于静默基线到当前观察时间之间时通知；避免漏掉两次轮询之间完成的快任务。首次见到的会话只考虑待审批，且要求`lastActivitySource`或`startedAtSource`为`provider`、对应日期有效并处于上述区间；旧记录缺来源、历史回填、索引时钟及未来日期均不推断成新待审批。首次导入终态会话保持静默。会话通知始终标记推断性质。
- `VelaNotificationEvent`提供`kind,source,recordID,project,title,inferred,count,sources,spansProjects,isAggregate`。`sources`为去重排序的`session/run/approval`数组；混合来源时`source="mixed"`。多条聚合的`recordID`为空，跨项目聚合的`project`为空且`spansProjects=true`。原生通知点击透传这些字段，单对象路由先加载其项目，跨项目路由先加载全局；混合来源通过列表级入口选择来源，不能打开代表对象或虚构分来源计数。策略只提供事件数据，实际系统投递、声音和导航由原生壳负责。详见[ADR 0002](../adr/0002-native-notification-policy.md)。
- `ask {query,project?}`（CLI）：`{query,items,mode:"local-retrieval",message}`，最多12个本地非private匹配；没有调用外部模型生成回答。
- `doctor {}`（CLI）：版本、DB/store、隐私与harness检测；不等同完整生产健康检查。

当前缺少完整历史回填、真实provider配额、语义Recall/Improve、完整Setup治理、审批编辑、外部provider、原生session迁移、自动Recall上下文注入、完整Agent Eval/自动Regression、加密同步和团队功能。Mac安装/签名/公证、官网线上可用性和性能实测分别见发行状态，不从API存在推导已完成。
