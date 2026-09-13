# ADR 0024 — 持久化只读工具观察

- 状态：已接受；工具观察及 FSEvents 扩展已实现，发布验收单独记录
- 日期：2026-09-13

## 背景

px0 的 watch 是按间隔执行只读工具，建立初始 baseline，按 key 去重并积累到 min_items 后启动工作流。现有 Vela Git/session 固定触发不足以覆盖这项行为。新增文件系统观察也不能替代该公开能力。目标复用现有调度与审批，不增加 agent framework、网络服务或不受控定时命令。

参考：[px0 Schedules and daemon](https://docs.px0.ai/workflows/schedule)、[px0 官方仓库的 watch 示例](https://github.com/px0-ai/px0)。官方工具 watch 与后续 macOS 文件观察的覆盖范围分别记录。

## 决策

工作流增加 `trigger:watch` 和严格 `watch` 对象。首版本 source 为 tool，仅接受 Core 已验证的 Git 状态/diff/log、scope 合格 Memory recall 与公开 Library retrieve。执行复用只读 dispatcher；连接器 metadata 自报 readOnly 不能取得无人值守权限。不存在的参数/模式/工具拒绝，不自动扩大能力。

观察在现有 Scheduler 30 秒 tick 和同一跨进程 lease 内完成。固定间隔可为30秒至24小时，不追补每一次错过的 poll。首次启用和定义版本变更只建立 baseline；正常重启保留 baseline、pending 和 dispatch sequence，只从新读结果证明净变化。耗时、采集时间及用量字段不参与变化 hash。Git 比较完整的受限标准输出；上下文按明确 key 和原正文 hash 比较，仅将公开来源 ID/hash 注入变化事件，正文需由工作流重新检索。当前是有界检索窗口，并非全 Library 或远端完整历史。

`watch_state` 持久化最近观察结果及未交付净变化，按不同 key 合并修改，新增后删除或改回原值不触发。minItems 和 debounce 满足才派发；等待前次审批时继续按间隔积累。Library 转为私有、Private-origin、资产丢失及 Memory 失效时撤销相关候选，不将旧正文当删除事件传入模型。

事件 claimed、pending 清空和 sequence 递增在同一 SQLite 事务完成，期望原状态 hash 不变且新事件不存在。随后沿既有逐工具冻结审批执行。未知派发结果继续由 schedule_event 保留并阻塞，只有显式 acknowledge 可以解除，不能盲目重跑。只读预览既不改变基线，也不创建 run/approval/event。执行前的用户审批不由 watch 取代。

每快照最多2000 key/128KB，每批待交付最多100 key/192KB，单次读取至多15秒。重复 key、截断的 Git 输出、失败和超量必须保留旧水位并给出诊断。运行中的 daemon 停止信号使用已有全局派发 gate 和有界进程回收。

## macOS 文件系统 source 扩展

`source:files` 已接通系统 FSEvents；每个 scheduler 实例只有一个 stream，不创建逐文件 timer。既有 tick 消费变化提示，实际读取采用相对项目目录 descriptor、安全文件身份验证和字节 SHA256，不按 mtime 推断内容变化。空闲时只读事件计数，不重新读取文件内容。初次/定义变化建基线；进程或 stream 重启会重新核对持久化快照，同一进程 stream 重启也增加 generation，不能错过暂停期间的变化。事件丢失/重启标记 historyIncomplete，只宣称可证明的净变化，不重建中间历史。

支持1–16个不重叠的项目内文件/目录，递归深度32，最多512目录和2000条目，每文件2MB、一次32MB；快照仍受128KB总限制，先达到的界限生效。扫描有5秒协作式截止检查，不把操作系统文件 I/O 声称为可硬中断。Private、.git、.vela、.build、node_modules默认排除；其他ignore支持有界 `*`、`**`、`?` glob，使用动态规划避免文件名引起正则回溯。链接、FIFO、超界或不完整扫描都保留旧水位。

实际字节变化、删除及空目录创建均成为净变化。文件 inode/设备身份与原hash一致时可将移出/移入配对为 renamed；不能确认的移动保持明确的 removed/added。同内容原子替换不触发，变化内容的原子替换触发 modified。Preview不启动stream或改runtime。失败的FSEvents仅使对应文件watch失败，其余调度仍继续；没有静默降级成定时mtime扫描。此扩展不关闭外部工具目录兼容缺口。

## English

Vela extends the existing scheduler with durable, bounded watches over a verified local read catalogue and macOS FSEvents. The first observation establishes a baseline; later keyed net changes accumulate across restarts and enter the same atomic dispatch journal and one-shot approval flow. File events are hints, while descriptor-safe byte hashes determine changes; idle ticks do not rescan contents. Private or unavailable context is revoked before dispatch. External tool compatibility and packaged UI acceptance remain separately verified requirements.
