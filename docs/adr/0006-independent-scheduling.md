# ADR 0006：独立后台调度与可审计补跑

- 状态：Accepted（验收范围单独记录，不代表完整参考功能已完成）
- 日期：2026-09-13
- 范围：Scheduler、CLI、每用户 launchd 服务、持久化事件与恢复

## 背景

用户明确要求覆盖三个参考产品的全部已交付能力。原来“仅 helper 存活时调度”的运行边界不满足这一目标。px0 的[调度文档](https://docs.px0.ai/workflows/schedule)描述独立 daemon、时区和漏掉 fire 的补跑。Vela 必须保持默认本地、低空闲开销和审批语义，同时使这些行为独立于窗口与 stdin。

## 决策

扩展现有 `vela` 可执行文件为 `vela daemon run`，采用 Dispatch timer/FSEvents，不增加 Node、HTTP 服务或第二个 Agent 框架。后台驻留是显式选择，关闭/卸载保留数据；macOS 使用当前用户 launchd，不申请 root。`plan` 返回确切 plist，install 只创建或接受完全相同的已有文件，start/stop 使用确定的 store 派生 label，不按历史 PID 发送信号。配置路径逐级拒绝符号链接及不安全权限，文件为 0600。遵循 Apple [Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)：前台进程不自行 fork/daemonize，处理 SIGTERM。

daemon 对每 store 持有独占文件 lease。状态中的 `running` 来自锁的实际占用；SQLite 中 PID、启动时间和心跳仅是记录，不能把强杀后的旧记录当存活证明。桌面 RPC helper 检查到 daemon lease 后不重复 tick。调度 tick 另持短期跨进程 lease，配合 SQLite 的唯一事件领取避免两个进程同时推进不同的补跑游标。SDK 使用 `rpc --no-watch --no-schedule`，保持接入不会隐式启动观察和调度。

工作流保存 IANA `timeZone` 和 `catchUp`（skip/latest/all）。新定义默认 latest；老定义缺字段时继续 skip，避免默默扩大既有副作用授权。补跑使用 UTC 分钟的事件身份、指定时区匹配，保存 scheduledAt/lateBySeconds、合并数量和窗口裁剪事实。默认最多回看 24 小时，允许 1–168 小时；all 每 tick 最多 1–100 次、默认 10 次，后续 tick 续游标。超出窗口明确标 truncated，不宣称无限历史已经补齐。

任何副作用仍冻结并等待原审批；已有运行/审批阻止重叠。领取后中断的事件进入 needs_review，不能自动重试；用户只能明确 acknowledge 原事件，后续新事件才可继续，不能通过“恢复”执行一次结果不明的旧动作。每次计算补跑窗口前查询所有未解决领取，避免 latest 跳过旧 claim；acknowledge 与 schedule 摘要使用同一带快照检查的 SQLite 事务，旧版中断在两次写入之间的摘要也能从事件账本恢复。启动事件只有在领取/去重后才记为已处理，等待已有运行不会丢事件。

会话完成通过 SQLite 触发器写入只含项目/会话/活动时间的递增身份日志。每工作流持久保存游标，每 tick 最多读取 100 个身份，后续 tick 继续，历史总量不由界面列表的 1,000 条上限决定；空闲时只查询最大序号，不遍历会话正文。首次启用或迁移建立当前基线，不追溯执行旧会话。每个待触发身份重新核对当前项目、私有状态、来源路径及内部运行标记；私有/删除/迁移或内部会话仅推进游标，不触发工作流。单个损坏项目/工作流不得阻止独立项继续调度。

## 取舍与边界

独立 Swift 常驻进程比反复冷启动更适合会话观察，也复用已有数据与审批逻辑；代价是额外常驻内存和生命周期，需要单独测量。launchd 用户代理在用户登录期间运行，不能替代系统级服务或断电期间运行。当前轮询仍为 30 秒。这里不实现 Linux systemd、通用工具 watch、每日维护与失败自动暂停；它们仍在完整 [px0 清单](../parity/px0.md)，没有从目标删除。

单元测试使用固定时钟覆盖时区/DST、latest/all/skip、停机补跑、窗口上限、跨连接竞争、审批阻塞和不确定结果；真实进程测试用独立数据目录验证关闭 stdin、单实例、强杀后状态及重启不自动执行。launchd 安装/启动和长期资源指标必须分别保留实际证据。Accepted 不是所有验收已通过。

## English

Vela reuses its Swift helper as an optional, user-scoped foreground daemon managed by launchd. Store leases establish actual liveness and serialize scheduler cursor updates across processes; historical PIDs never authorize process termination. New workflows explicitly choose a time zone and bounded skip/latest/all catch-up policy. Legacy definitions retain skip until edited. Durable event claims, frozen approvals, and explicit reconciliation prevent blind retry after an uncertain dispatch. SDK connections disable both watching and scheduling. Linux service management and the remaining reference capabilities remain requirements, not exclusions.

## 2026-09-13 独立审查后的生命周期修正

独立慢读取测试发现：如果 SIGTERM 与同步 tick 共享串行队列，Git 文件读取阻塞会拖住退出。现在信号使用独立控制队列；进程内一次性 shutdown gate 与 `posix_spawn`/进程组登记共用锁，停止请求拒绝新命令，并对本进程登记的子进程组执行 TERM、短宽限期、KILL 和回收。活动 tick 的持久化完成后才记录 `stopped` 并释放 daemon lease；五秒兜底退出为失败，保留中断记录，不制造清洁退出或自动重试。普通 RPC/SDK/规划进程没有发出停止请求时，行为不变。

管理器以非阻塞方式打开待验证 plist，拒绝 FIFO、符号链接、硬链接和非本用户文件。安装失败只清理自己仍持有的 inode；卸载先原子隔离文件、再核验被移动对象，变更对象保留且恢复不会覆盖其他文件。对已加载的 job，磁盘 plist 相等仍不充分：必须核对 `launchctl print` 的配置路径、program 及完整 argv，未知输出格式拒绝操作。此保护覆盖配置替换与误操作；它不是针对任意同 UID 恶意进程的系统级权限隔离。

验收见 `Tests/VelaCoreTests/DaemonReviewTests.swift`、`scripts/test-daemon-shutdown.py` 和 `scripts/test-launchd.py`。后者使用实际 VelaCore 管理器、临时 fake home、唯一 launchd label 和禁止真实会话发现的 wrapper，覆盖 bootstrap/print、异常退出后的 KeepAlive、bootout、卸载保留 store；测试结束移除该 job 和全部临时数据。具体二进制 hash、结果与时间边界见 `output/parity/daemon-shutdown-review-after.json` 和 `output/parity/launchd-lifecycle.json`，不得把它们泛化为未测版本或长期运行指标。

English: Shutdown is now independent of a blocked scheduling queue and drains only child process groups registered by the current process. A clean stop is recorded only after the active tick finishes; an overrun exits unsuccessfully with recovery evidence intact. The manager validates both on-disk identity and the loaded launchd job. Real lifecycle verification used an isolated temporary job and did not install anything in the user's existing LaunchAgents directory.
