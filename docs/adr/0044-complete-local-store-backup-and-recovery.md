# ADR 0044：完整本地 Store 备份与恢复

- 状态：Accepted（开发分支；不代表完整产品或发行验收通过）
- 日期：2026-09-14

## 背景与选择

`memory.archive` 是最多 100 条/1 MiB 的 Memory interchange，不能用于恢复整个本地 Store。用户需要保留 SQLite 中的对象、偏好、版本、History 原始记录和来源收据，以及五类 Markdown 资产和 `store/output` 交付文件。直接复制运行中的 SQLite/WAL/SHM 不能证明数据库与资产来自同一个 Vela 写入边界。

继续使用系统 SQLite 与 Swift 文件 API。完整备份只由本地 CLI 调用，不向 renderer、RPC 或 MCP 暴露任意备份/恢复路径。恢复必须使用新的目标目录，不覆盖既有 Store；既有受限 Memory interchange 保持原语义。

## 快照

顺序取得 SafeApply 的 `apply.lock`、scheduler/daemon/composition lease，再在 Store 写连接上取得 `BEGIN IMMEDIATE`。锁只用非阻塞尝试；SQLite 自身等锁最多 5 秒。写屏障取得后检查外部动作账本，拒绝运行中和执行结果不确定的状态；普通待审批请求允许备份。恢复时已经明确撤销执行资格的 `needs_review` 记录不会永久阻止再次备份。

在屏障期间，通过独立只读连接调用 SQLite Online Backup API，每批 256 页并检查 30 秒期限。同一写连接直接作为 backup source 的本机原生 probe 返回 SQLITE_BUSY；独立只读 source 成功，另一写连接仍返回 SQLITE_BUSY。依据为 [SQLite Online Backup](https://www.sqlite.org/backup.html) 和 [API 合同](https://www.sqlite.org/c3ref/backup_finish.html)。

Markdown 与交付文件从固定目录读取。读写以目录描述符定位，拒绝 symlink、hardlink、FIFO 与非普通文件；每次只读取 64 KiB，检查打开前后文件身份、大小和修改时间。最终再核对所有源文件 hash。此机制协调 Vela 写者并检测可观察到的外部编辑，不声称能阻止任意同用户进程修改磁盘。

数据库文件最多 2 GiB；资产与 output 合计最多 50,000 文件/2 GiB，单文件最多 64 MiB；manifest 最多 8 MiB。整个资产快照 I/O 使用 60 秒期限。超限或锁/读取失败时不返回完整成功，也不隐式截断。

## 恢复与数据边界

先校验 manifest、数据库与全部列出的资产 hash，在目标同级唯一暂存目录复制，再由现有 schema 管理器校验/迁移。manifest 中的五类资产 identity 必须与数据库 canonical 对象集合完全相等。数据库内的 `assetPath` 预先重绑最终目标，不绑定暂存目录；Markdown 原始字节保持不变。

恢复保留审计并撤销旧执行资格，随后使用 macOS `renameatx_np(..., RENAME_EXCL)` 发布到新目标。目标已存在或竞争失败时不覆盖它。CLI create/restore 均在 Router 前分派，不初始化会执行中断恢复的 AutomationService。create 只打开选定 Store；restore 不打开或迁移调用者原先的 `VELA_HOME`。

| 数据 | 恢复行为 |
| --- | --- |
| 对象、偏好、不可变版本、History 表与原始 chunks/收据 | 保留；不把外部来源路径改写成新的原始来源 |
| memory/workflow/guideline/library/checkpoint Markdown 与 managed output | 保留字节和身份；canonical `assetPath` 重绑新根 |
| run、approval、loop、replay、plan、Ask/Query、model improvement、connector、schedule/watch 等未决账本 | 保存冻结参数和证据，改为 `needs_review` 并标记 `restoreRevoked`；run 内待执行 step 同步撤销 |
| Lab eval / Health proposal 未决状态 | eval 变为 `needs_review`；Health 变为 `invalidated` |
| 非 manual workflow | 禁用；需用户后续显式重新启用，恢复本身不启动 daemon、模型或工具 |
| SafeApply `apply_journal` | 保留审计；prepared/committing 变为 needs_review，启动不得恢复写外部文件；终态保留既有显式 hash-guarded Undo |
| runtime 对象、文件锁/PID/socket/进程组 | runtime 对象删除；live 文件不进入 bundle |
| semantic vectors / session completion 投影 | 清除；当前服务通过显式索引/来源刷新恢复，不声称已重建 |
| Library 段落索引 | 重绑对象会使现有索引失效；使用既有 `library.index` 分页重建，不另造已完成 repair API |

本地备份含 private 内容且未加密。它不会主动读取 Keychain、provider 凭证、外部 provider 原始日志或项目工作树；用户自行写入 Memory/Library/设置正文的秘密仍可能随数据进入备份。外部项目、原始来源与身份仍需分别保留。本地完整恢复不是加密远端恢复、跨设备同步或 Walrus 成功写入。

## 验收要求

必须通过公开 CLI create→restore→新 helper reopen，实际核对 private/public 资料、History 原文、来源字段、偏好、资产路径、output 与旧审批不可执行。补充篡改、路径穿越、符号/硬链接、FIFO、超限、运行锁、并发新目标发布，以及 Store.remove 对既有 ingestion 事务的回归。新 schema 拒绝与资产索引重建需要对应证据；不能用测试总数替代这些路径。

2026-09-14 路径兼容修正：本机原生验收发现 Foundation 会将已存在的 `/private/tmp` 父目录标准化为 `/tmp` 别名，而 C `realpath` 返回 `/private/tmp`，使旧守卫误拒绝正常目标。开发修复在检查真实规范路径前不调用该标准化步骤，继续拒绝用户符号链接祖先、`.`/`..` 和 NUL；目录描述符、无覆盖发布和文件身份防线保持原样。真实 `/private/tmp` create→restore 及用户链接拒绝已纳入定点测试；原失败见 [3894 原生证据](../parity/native-3894dab6-evidence-2026-09-14.json)。

## English summary

Provide a bounded full local Store bundle through the CLI, restored only to a new directory. Use a writer barrier, a separate read-only SQLite Online Backup source, and streamed identity/hash-checked canonical assets. Preserve private data, history, source receipts and audit records while revoking old execution eligibility. Publish without replacing an existing target. External credentials, source logs and project working trees are outside the bundle. This is an unencrypted local backup, not remote recovery or synchronization; UI and full product acceptance remain separate.
