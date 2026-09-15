# ADR 0007: Portable Memory archives / 可移植记忆归档

- Status: Accepted
- Date: 2026-09-13
- Scope: Memory interchange API, import identity, transactional create-only writes

## Context / 背景

用户要求 Vela 覆盖 Blume、Walrus Memory 和 px0 已交付能力，再改善体验和可靠性。Walrus Memory 的可移植性包含跨应用身份、加密远端存储及索引恢复；原有 Vela 只有本地 Markdown/SQLite Memory 与 checkpoint 文本交接，不能将二者视为等价。完整功能核对在 [Walrus Memory parity](../parity/walrus-memory.md)。

实现完整远端能力还涉及 owner/delegate、密钥保管、兼容版本、网络错误与可验证恢复。先建立可直接验收的本地 interchange 能力，供后续 SDK、namespace 与加密备份复用；这不缩减完整覆盖目标，也不把可选导出当作远端恢复完成。

## Decision / 决策

新增 `MemoryArchiveService`，由已有 `MemoryService` 转发三个方法：

| Method | Parameters | Result |
| --- | --- | --- |
| `memory.archive.export` | 已登记的 `project`；可选唯一 `ids` | 版本化 `archive` JSON、数量、实际字节数；无文件写入 |
| `memory.archive.validate` | `archive` JSON | 检查结果、数量、SHA-256；无目标项目要求、无数据写入 |
| `memory.archive.import` | 已登记的目标 `project`、`archive` JSON | 新建与跳过数量、目标 ID；仅新建待审核 Memory |

调用方通过已有 CLI JSON/RPC 路由传递数据。没有新增任意文件路径、shell、网络原语；MCP 白名单不增加归档读写工具，renderer 也没有新增入口。

V1 使用 `format: vela.memory-archive`、`version: 1`、`source`、`entries` 和外层 `sha256`。`source` 包含原项目标识与其派生的 `project:<sha256>` namespace，都是来源数据，不代表被认证的 owner。每条 `record` 的 SHA-256 和整体 checksum 使用 Vela 的排序 JSON 序列化（`jsonString`，UTF-8、无斜线转义），明确不是跨语言 JCS 标准或数字签名。其他语言适配器必须验证相同字节合同，不能仅凭键排序假设兼容。

所有已知层级都严格检查必填和允许字段；不认识的版本或字段整包拒绝。限制为 100 条、整体 1 MiB、每条正文 512 KiB、标题 300 字符、来源 metadata 单值 4096 UTF-8 字节。未提供 `ids` 时导出整个允许集合，超限必须显式分批选择，不能悄悄截断。

当前安全默认仅导出选定项目中非私有 Memory。Global、Private Library、私有 Memory、来源文件带 private 目录标记的记录不进入此格式；显式选择这些记录会失败。归档中的 private 标记必须是严格的 JSON `false`，`true`、数字、字符串、私有 scope 或私有来源路径都不能通过反序列化降级为公开内容。这是 V1 interchange 的界限，不代表最终备份产品排除个人或全局记忆。恶意制作方可改写内容再重算 checksum，因此导入的内容一律是不受信任的候选事实。

导入目标必须由调用方显式指定且已经登记。原项目、namespace、scope、state、branch、worktree、session 等只进入来源记录，不能选择本机路径、移动项目或直接激活。导入统一得到目标项目 scope 和 `candidate` 状态，在人类审核激活前不会进入 Recall。

目标 ID 由目标项目、来源身份及 record checksum 确定。同一版本重复导入识别已有来源并返回 skipped，保留导入之后的用户编辑和生命周期决定；改变内容的版本得到新候选 ID。已有 ID 若不是匹配的归档来源则整包失败，不覆盖。

为消除服务层“先查后写”的跨进程竞态，`VelaStore.putBatch` 新增兼容默认参数 `createOnly: Bool = false`。归档使用 `true`，所有冲突检查与插入处于同一 `BEGIN IMMEDIATE` 事务中。任何一项冲突或文件写入失败会回滚数据库并补偿已完成的 Markdown 写入。并发相同导入可能让一方得到明确冲突；不会自动重试未知写入。

## Alternatives / 取舍

- 直接复制数据库最省代码，但混入本地绝对路径、所有项目、私有数据和非 Memory 对象，不能作为安全的跨应用合同。
- 仅导出 Markdown 方便阅读，但缺少来源身份、逐项校验、幂等恢复和全包验证，无法建立可靠闭环。
- 本轮直接嵌入远端 SDK 会同时改变账户、密钥、网络及运行时边界。先完成独立归档，再通过明确适配器实现这些功能，便于分别验证；完整远端能力仍是必须跟踪的缺口。

保留现有系统框架和 SQLite，未引入依赖、常驻服务或网络开销。格式严格会增加未来版本迁移工作，但避免旧程序静默忽略权限字段。

## Verification and limits / 验证及边界

`MemoryArchiveTests` 覆盖跨空 store 恢复、原文保留、待审核召回隔离、重启可读、重复导入、隐私排除、篡改/未知字段/大小限制、目标范围、跨 SQLite 连接竞争、批次补偿、ID 冲突和符号链接拒绝。验收记录应说明使用 XCTest 还是 portable fallback。

此格式为明文便携副本，checksum 仅检查一致性，不能证明作者、链上所有权、内容真实或未被恶意重写。导入恢复被归档的 Memory，不重建未导出记录、原会话、Private Library 或所有旧 store 数据。事务内失败补偿不等于断电时 Markdown 与 SQLite 的分布式事务；没有新增或宣称完整的断电恢复保证。

下一阶段的完全备份需要用户控制的密钥、认证加密、包含私有与全局数据的显式范围、密钥丢失和轮换策略、断点与冲突恢复；Walrus 兼容还需要 owner/delegate、远端 Blob/namespace、语义索引和可核验的网络恢复。实现这些边界时扩展版本或另建加密容器，不向 V1 偷加权限字段。

## English summary

Vela adds a bounded, versioned JSON Memory interchange API with per-record and whole-archive SHA-256 checks. Imports require an explicitly registered destination project and create candidate memories only. Foreign scope and lifecycle fields are provenance, never local authority. Deterministic import IDs preserve later user edits on repeat imports. A backward-compatible `createOnly` batch option checks collisions under the same SQLite write transaction and rolls back failed batches. This is a verified foundation for portability, not encrypted remote storage, authenticated ownership, complete-store backup, or full Walrus Memory parity. Private/global backup and remote recovery remain tracked requirements.

## Original Walrus records / 原始 Walrus 文本

`memory.archive.fromWalrusRecords` 将显式非私有原文和公开来源转成现有 V1 归档；只核对输入 SHA 和严格结构，不写记忆、不联网、不认证来源声明。虚拟 source path 永不读取。可选 reader receipt 明确保留为 caller-reported，Core 只证明内容哈希；candidate-only 原子导入和幂等规则继续适用。同一来源版本包括精确正文、标题和 provenance；修改 receipt/provenance 会构成不同归档版本，不覆盖之前审核。私有完整库必须独立备份容器。
