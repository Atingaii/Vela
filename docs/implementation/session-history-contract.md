# 显式会话历史 API 合同

当前切片是四个 JSONL provider 的本地完整来源回填基础：Claude、Codex、Pi、OMP。默认 SessionEngine、dashboard、FSEvents 和 60 文件/尾窗策略不变。没有 UI 改动，没有模型调用、自动后台回填、Memory 激活或 MCP 原文入口。Cursor 导出/数据库、Todo 和子代理投影继续单独实现；此合同不表示 B07/B12/B13 全部验收。

## 请求

除 `history.describe` 外，所有请求必须有已登记绝对 `project`。方法仅接受下表字段；未知字段、错误类型、超界数字和 NUL 拒绝。文件只能通过配置 roots 发现的 source ID 选择，没有任意 path 参数。

| 方法 | 额外参数 | 行为 |
| --- | --- | --- |
| `history.describe` | 无 | 协议/decoder 版本、支持 provider、预算、尚未兼容的 Cursor |
| `history.discover` | 首次可选 `provider`；续页 `inventoryId`；`limit` 1–128 默认 64 | 创建或推进持久化 manifest；每次处理一个目录的词法名称页；返回本页来源 `items` 与任务状态 |
| `history.sources` | `inventoryId`，可选 `afterId`、`limit` 1–100 默认 50 | 同一 manifest 的来源页，返回 `nextAfterId`；未完成 discovery 仍可能新增来源，完整遍历后分页才是固定集合 |
| `history.start` | `sourceId`，可选 `maxBytes` 1–8 GiB 默认 256 MiB | 重验当前 header、项目、文件版本，创建不可变 source epoch；同一源版本/decoder/project 已存在时返回原 epoch |
| `history.advance` | `id`，可选 `batchBytes` 1–4 MiB 默认 4 MiB、`batchRecords` 1–2,000 默认 2,000 | 单批原始记录/事件与断点同事务提交；独立 utility 队列；协作式约 1 秒读取预算，不是硬实时 SLA |
| `history.get` | `id` | epoch 状态、来源与覆盖计数，不包含历史正文 |
| `history.jobs` | 可选 `afterId` | 100 条 epoch 摘要及 `nextAfterId`，不加载原文 |
| `history.pause` | `id` | pending/paused 停止后续 advance |
| `history.resume` | `id` | 显式恢复 pending/paused/failed/cancelled；执行前仍核对相同冻结版本 |
| `history.cancel` | `id` | 停止 pending/paused；保留已有原文和断点以便显式恢复 |
| `history.page` | `id`，可选 `cursor`、`direction` forward/backward、`limit` 1–100 默认 50、`type` | 当前已提交事件的来源物理顺序页，返回 `nextCursor` 与最后可续读位置 `endCursor` |
| `history.raw` | `id,ordinal`，可选 `part` 默认 0 | 同项目完整已提交记录的一个 ≤64 KiB 原始块，`dataBase64`、`nextPart`、整记录 SHA256；包含真实换行 |
| `history.branch` | `id`，可选 `leafId`、`cursor`、`limit` 1–100 默认 50 | Pi/OMP 完整且无歧义的父链，顺序 leaf→ancestor；默认最后持久化 leaf，来源未证明的内存 leaf 不猜 |

`id` 是 epoch ID，不是默认 `sessions.get` 的 session ID。来源行给出 `inventoryId/sourceIdentity/provider/path/root/relativePath/sourceSessionId/sourceFormatVersion/decoderVersion/sourceVersion/sourceBytes`；实际来源的稳定标识独立于每次 manifest ID。`maxBytes` 限制选定源文件字节，SQLite 索引与记录元数据会有额外磁盘占用，它不是数据库文件的硬配额。

`history.advance` 在新 SQLite connection 的短写事务内读取当前 epoch，批次失败回滚全部 raw chunks/events/offset。八个独立 service 并发测试验证无重复提交。普通读取能在批间进行；单次事务内的文件/SQL 操作与解析不是可抢占实时操作。暂停/取消不撤销已提交证据，stale 不能被恢复到新源，必须 `start` 新版本。

## 来源和覆盖语义

来源从已配置根逐级 `openat/O_NOFOLLOW`，拒绝链接、hardlink、非普通文件。macOS `/private/var` 使用真实路径和词法组件校验，不用会改写系统别名的 Foundation standardization 来比较实体。每批前后核对 device/inode/size/纳秒 mtime/ctime，文件轮转、截断、追加或等长原位修改会使未完成版本 stale。完成的旧 epoch 仍可读，原文件后来删除不会将旧 cursor 指向新内容。

当前 header probe 最多前 64 KiB / 32 行。没有可验证 cwd 的源、首行过长和未知 Pi 版本不自动归属项目，`unavailableSources`、诊断和排除数显示这一限制。目录页最多遍历 100,000 个目录项、深度 32；超过限制明确 `failures`，`traversalComplete=false`，不能仅凭本页完成说历史已完整发现。目录版本变化必须新建 inventory；不同目录是在不同时刻观察，`pointInTimeInventory=false`。

事件 `ordinal/recordStart/recordBytes/rawParts/rawSHA256/providerId/parentId/sourceType/type` 保留物理出处。预览至多 4,096 UTF-8 bytes，原文通过 raw 分块完整重建，预览不冒充完整消息。相同 provider ID 不被删除，返回 `previousSameProviderIdOrdinal` 作为原始同 ID 关系；例如 Codex call 与 output 共享 ID，不被误说成同一消息文本。缺时间为 null；来源逆序时间不改变物理页顺序。

独立完整性字段：

- `rawBytesComplete`：冻结文件的字节已读到末尾，并保留原记录块。
- `normalizationComplete`：没有未知/无法解析事件，不等于模型正确或全产品语义齐全。
- `projectScopeComplete`：全部记录能归入选定项目；显式 foreign cwd、未知作用域的记录不返回，也不允许 raw 绕过。
- `branchIntegrity`：Pi/OMP ID 唯一且 parent 指向已存在更早记录；重复、孤儿、未知身份、重复 header、解析失败拒绝 branch API。

单条超过 8 MiB 的记录分块仍有界保存，但 normalizer 不加载整个超大对象；该条和继承的未知 scope 保持不可读，直到之后明确 cwd 恢复。超限、坏行和不完整无效尾行不会被静默跳过后宣称标准化完整。未知 Pi role 保持未知，raw 能证明原材料，不能证明语义适配已完成。持久化片段链是读取片段的链式校验；只有 `rawSHA256` 是整记录真实字节 hash。

## 验证与剩余工作

16 个新 History + 16 个已有 Provider Core 方法共 **32/32 通过**，冻结源码 `7c9fdc24a87d5f4fe347d3e56ab845ff9e8984458c38d2b36dc6ea691a84e27d`，结束时与工作树匹配；见 `output/parity/blume/history-final-tests.json/log`。这是 portable fallback，编译真实 Core 和测试，但不是 XCTest。覆盖 73 来源、1,207 记录、约 500 KiB 单条 Unicode 原文、断点进程重启、暂停/恢复、八个独立实例并发、同 ID 原始版本、倒序时间、来源变更、跨项目、符号链接、未知角色/版本、分支页和参数/cursor 绑定。另明确验证 >8 MiB 单条仍记录 raw coverage，但 normalization/scope 不完整且原文入口不能绕过 scope。

`scripts/test-session-history-rpc.py --output <new-receipt.json>` 的实际 CLI 六组检查通过：73 来源分页发现、20 批次/1,202 原始记录、进程重启续传、原文重建、default session 不膨胀、epoch/cursor/stale 与跨项目拒绝。冻结 helper SHA256 `d42897eb0c51bbcafa21cec1bc704f7db4abbec1de1d86b3afe83cc81e630dce`；2026-09-13T05:40:22Z–05:40:24Z，receipt `output/parity/blume/history-rpc-final.json`。本次合成主来源 353,163 bytes，所记录导入阶段 0.7492 秒；这是单个小样本，不代表大历史性能 SLA。临时 store/source/helper 已清理，provider 请求为零。

首轮辅助测试重载编译失败、随后 `/private/var` 路径校验导致的共同失败证据仍保留。实际修复是词法组件验证配合逐级实体 no-follow，未放宽为允许符号链接；之后 14 项及最终 32 项独立快照通过。

已知 Cursor JSON/SQLite 的一致性快照、超长 header 的按需解析、额外公开事件角色、完整 Todo/plan 投影、子代理关联与状态、跨来源查询/排序、手工清理与磁盘保留策略、完整 UI 和大历史性能/长期稳定性仍列在全量清单，不从“原文已存”推导已完成这些功能。

## English summary

History is an explicit local import into separate SQLite records and original-byte chunks. Stable epochs and cursors preserve provenance through restarts and source rotation without enlarging dashboard sessions. Raw, normalized, project-scoped and branch coverage are distinct guarantees. Unknown formats and budget boundaries are visible. Four JSONL adapters are present; Cursor, plan/subagent projections and the UI remain separate acceptance work.
