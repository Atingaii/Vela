# 当前架构

Vela `0.1.0-preview.1` 是一个以本地数据为中心的macOS开发预览：Swift核心、独立CLI/helper、AppKit壳与系统WKWebView，附独立静态官网。它已建立观察、工程资产、审批执行和真实命令对照的基础闭环，未实现完整P0–P2产品范围。功能状态见 [status.md](status.md)，API见 [implementation/contracts.md](implementation/contracts.md)，选型依据见 [ADR 0001](adr/0001-native-macos-core.md)。

## 进程与请求路径

```text
Vela.app（AppKit + WKWebView，VelaDesktop可执行文件）
    │ 本地页面；枚举RPC方法；请求ID
    ▼
vela rpc（独立Swift helper，JSONL stdin/stdout）
    ├─ Foundation串行队列
    │    Context / Foundation / Memory查询、项目、Setup、Library、Recall
    ├─ Automation串行队列
    │    Workflow / Approval / Improve / Lab / Run / Evidence
    │    Scheduler：首次约10秒，之后每30秒tick
    └─ VelaStore：SQLite WAL + FULLMUTEX + 实例锁
           ├─ 长期Markdown资产
           └─ 索引、版本、运行、审批、评测和恢复日志

FSEvents专用队列 → 变更路径 + 文件游标 → provider解析 → Session提交
                                                    │
                                                    ▼
                               {event:"data.changed"} → 原生150ms防抖
                                                    → 页面vela:refresh
```

两条RPC队列可并行，响应允许乱序并按ID对应，最多32个已排队请求。长自动化不占用Foundation请求队列，但二者共享数据库和helper进程，并非完全隔离的故障域。SessionEngine另有FSEvents队列和锁；初次摄取在后台开始。当前没有九个常驻worker，也没有额外Node/Chromium运行时。

helper通知只表示摄取更新，未构成覆盖所有写操作的事件总线。WebKit对普通/长操作采用180秒/1,800秒超时；超时不会授权重复执行，也不等同取消核心任务。窗口隐藏后菜单栏每5秒轮询dashboard。关闭窗口保留sidecar，退出应用终止helper；实际退出和重启行为以原生壳实现为准。

`vela mcp`是独立启动模式，使用同一核心与store，但不启动watcher或Scheduler；当前MCP请求按Foundation队列处理。CLI一次性`call`适合明确操作和集成验证。多个进程可访问同一数据库，因此审批和事件领取不能只依赖Swift实例锁。

## 代码和数据责任

| 边界 | 责任 |
| --- | --- |
| `Sources/VelaApp` | Antigravity实现的原生窗口、菜单栏、通知、登录启动、WebKit bridge和UI资源；没有通用shell/file API |
| `Sources/VelaCLI/main.swift` | JSONL/JSON-RPC协议、两队列路由、MCP权限、设置、诊断、本地Ask入口、调度timer |
| `Sources/VelaCore/Store.swift` | 系统sqlite3、参数化查询、轻量session summary、Markdown资产、批次补偿、CAS、事件唯一插入与Session变化计数器 |
| `SessionEngine.swift` | Claude/Codex日志及已知Cursor记录、受限发现、FSEvents、增量偏移、截断/轮转/坏记录诊断 |
| `FoundationService.swift` | 项目登记、harness检测、dashboard、脱敏Setup扫描、基础审计、日志Usage聚合 |
| `MemoryService.swift` | Memory生命周期与Scope、保守预算Recall、人类Search、Library文本提取、Checkpoint和中立交接 |
| `ContextService.swift` | Guideline版本、本地规则Workflow Builder、来源绑定Signal贡献、无操作Suggestion草案、观测回归统计 |
| `AutomationService.swift` | Workflow版本、Markdown定义校验、工具注册表、冻结审批、运行账本、健康统计、Replay和证据引用 |
| `SafeApply.swift` | 项目根与文件身份验证、staging/fsync/rename、多文件失败补偿、Undo、跨进程锁和中断恢复 |
| `AutomationProcess.swift` | 明确可执行文件和参数、净化环境、独立进程组、时间/输出上限与后代清理 |
| `ImproveService.swift` | 确定性明确纠错检测、真实证据去重、代码晋升、可审阅的Markdown建议 |
| `LabService.swift` / `SchedulerService.swift` | 审批后的成对worktree命令对照；有限cron/事件触发与持久化领取 |
| `website/dist` | 独立官网静态资源，不连接用户本地Session、Memory或Workflow数据库 |

CLI默认数据目录`~/.vela`，可用`--home`或`VELA_HOME`指定。桌面stable默认`~/.vela`、canary为`~/.vela-canary`、dev为`~/.vela-dev`，并把所选目录传给helper。通道有独立bundle ID、协议和数据目录；CLI连接开发应用时也必须指向同一home，不能假定默认目录相同。

数据库为`vela.sqlite3`，使用WAL与`synchronous=NORMAL`。长期资产保存在`assets/{memory,workflow,guideline,library,checkpoint}/<id>.md`，包含元信息、标题和正文；运行时对象单独存SQLite。存储层会读取人工改过的资产标题/正文；Workflow执行前再校验JSON frontmatter并增版，防止实际运行陈旧的数据库steps。当前支持JSON这一YAML子集，不是任意YAML解释器。

SQLite trigger在Session新增、JSON变化或删除时推进单行持久化revision，其他连接的写入同样生效。后台分析先读这一水位，未变化时不加载会话历史；分析成功后才保存已处理revision，分析期间新增数据留给下次检查。

## 观察、检索和知识边界

首次发现最多选择60个近期文件，每文件初始读取256KiB尾窗，流式读取上限8MiB，每个Session保留最多1,000条消息；后续按FSEvents变化路径和持久化偏移摄取。完整历史回填尚未交付，dashboard明确标记`historyFullyIndexed=false`。Cursor适配是已知导出和SQLite composerData记录，不能概括成兼容全部私有版本。

Agent状态源于日志，不是进程监视器；API区分推断与可用能力，过久的Running会降为Idle/Unknown。Usage仅聚合已索引日志token，并按会话开始日分组；没有真实订阅百分比、价格、额度窗口或reset。Setup当前只检查有限内容、语法、重复和估算上下文大小，不承诺完整18项治理审计。

Memory有global/project/repository/branch/worktree/task/session范围及candidate/active/superseded/archived生命周期。Recall先做范围与private过滤，再按词面相关性排序，并施加0–4,000的保守字符预算；只有Active参与。当前没有向量数据库、语义模型排序或自动把Recall结果注入任意Agent CLI。

Library为用户持有的资料，支持Markdown/UTF-8、HTML、可提取文字的PDF、DOCX和显式URL；导入默认private，用户private目录强制隔离。人类可显式搜索private内容，Agent路径不能读取；当前Recall仅处理Memory，尚未完成Library语义召回。URL导入是用户指定的网络读取，与默认本地存储并不矛盾。

## 权限、审批和文件修改

WebKit加载随包页面，CSP禁用业务网络，原生桥接限制方法清单；HTTPS外链交给系统浏览器。Renderer不能调用任意shell或任意filesystem方法，但可以在允许的Workflow Builder里定义受审阅的工具参数，实际副作用需进入核心审批。

MCP提供7个READ工具和启用`--contribute`后追加的4个贡献工具。每个请求必须给已登记的绝对项目，服务端重新检查。READ仅搜索/读取；贡献只创建Candidate Memory、Checkpoint、同项目已有Session支持的Signal或无文件操作的Suggestion草案，不接受替换对象ID，也不暴露执行、Apply/Undo或长期删除。private检查在检索和MCP返回边界执行，工具readOnly注解按真实权限清单设置。

Workflow冻结其版本与步骤，Dry Run仅运行三个Git只读工具，shell测试、Agent调用和file.write全部stub。真实副作用先保存冻结Approval（工具、参数、项目、run、step和hash），以SQLite事务CAS从pending领取为executing，再执行原快照。两个进程竞争同一审批只有一个成功领取；executing期间中断不会自动重试。此机制避免重复领取，但不能对任意外部系统、断电或未知远端结果宣称全局exactly-once。

SafeApply的路径授权和文件访问使用规范项目根、纯词法目标路径、逐级目录描述符、O_NOFOLLOW及inode/device检查，拒绝越界、symlink/hardlink、缺hash或变化的基础文件。全部目标校验后staging/fsync，再逐文件rename，journal保留before/after。单个rename是原子的，多文件依靠失败回滚和启动恢复；若用户并发改动导致无法安全回滚，则保留needs_review。Undo同样验证after hash，不覆盖后续人工修改。

文件事务用flock跨进程串行，恢复只在无活跃事务锁时进行；stage清理以journal里的精确文件名和内容hash为依据。SQLite+Markdown批次补偿与SafeApply journal各自负责不同写入路径，不应混称跨介质原子事务。

不在业务SQLite里保存OAuth/API密钥，当前尚未实现需要保存凭据的外部provider；未来接入应使用Keychain并记录权限接口决策。Telemetry固定关闭，无账号要求和云端会话/Memory/Workflow状态存储。用户明确批准调用已有远程模型CLI时，CLI本身可能把输入发送给对应模型商，不能据“本地执行”宣传内容绝不出机。

## 自动化、Improve与Lab的当前语义

执行器使用posix_spawn，明确executable/args、净化敏感环境，创建进程组并限制运行时间和输出；退出清理后代。工作目录隔离不是操作系统沙箱，已批准命令仍可能访问其他路径。Git只读路径禁用hooks、fsmonitor及external diff/textconv。

Improve目前从真实user消息检测明确纠错语言，按稳定来源ID去重；纯代码至少3信号、2个不同Session才晋升。它生成证据Markdown草案，没有调用语义模型做完整Extraction/Clustering/Planning，不能把heuristic结果包装成模型置信度。Guideline和Memory快照尚未自动注入Agent执行。

后台证据分析默认关闭。用户开启analysisEnabled后，同一Scheduler每约30秒检查水位，只有Session或检测器版本变化才运行确定性分析，失败下次重试；关闭不消费变化，重新开启处理积累数据。该功能不检测OS空闲、不启动模型或进程、不自动应用草案。当前每次分析上限为最近500个已索引Session和10,000个Signal，因此这仍是有界扫描，不是完整历史回填或逐Session增量抽取。

Lab先冻结同一Git commit、command、timeout及baseline/candidate文件内容，批准后创建独立detached worktree并执行真实命令，记录退出码、输出、runtime、diff和样本统计，再清理本次worktree。`evaluator=deterministic_command`明确其性质；memory/workflow类别标签不自动执行Recall或历史workflow。没有真实Agent调用和评分证据时，不能称为完整Agent Eval或宣称因果提升。

Scheduler按workflow.enabled运行，支持基本本地cron、helper启动、最新Session完成、Git HEAD变化；通过schedule_event唯一ID跨进程领取事件，现有运行或审批时避免重叠。usage_reset明确unavailable，休眠期间全部事件补跑未完成。`regression.list`仅比较已记录版本的观测统计，不自动触发回归或判断变更因果。

## 构建、分发与验证边界

SPM生成核心库VelaCore、`vela`和`VelaDesktop`；交付主应用为`Vela.app`。`scripts/package-macos.sh`创建release构建，通过显式资源允许清单装入两个可执行文件与必要UI，剔除demo fixtures、测试、源码和内部文档，执行codesign验证、安装包审核并生成ZIP/checksum。提供Developer ID和已有Keychain公证profile时可走正式签名/公证；默认ad-hoc开发包不是已公证公开发行软件。

GitHub Actions配置了Swift测试、JSONL/MCP集成与资源/安装包检查；当前本机缺XCTest SDK时使用portable runner编译真实核心与相同测试方法。配置存在不等于某次远端CI已通过，最新测试、签名、公证、官网与下载状态以交付证据为准。

官网托管与应用分发独立，静态站点不引入用户数据服务，下载目标由发行流程配置。冷启动、RSS、CPU、事件延迟和10万条搜索指标是独立性能验收项目；不能从“原生Swift”或安装包体积推导全部达标。P3/P4的原生Session迁移、选模、外部SaaS工具、同步和团队资产仍属后续范围。
