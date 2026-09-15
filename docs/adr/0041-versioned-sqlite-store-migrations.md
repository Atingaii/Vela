# ADR 0041：版本化 SQLite Store 迁移

- 状态：Accepted
- 日期：2026-09-14
- 范围：`vela.sqlite3` 的 Core schema 兼容、升级拒绝与事务迁移；不定义远端同步、完整备份/恢复或任意派生索引重建策略。

## 背景

`VelaStore` 原先在每次打开时直接执行当前 `CREATE ... IF NOT EXISTS` 和 trigger 修复。已存在的未 versioned store 可以继续打开，但 helper 无法区分旧 schema、当前 schema 与未来 schema；较旧二进制也可能对来自较新二进制的 store 先改 journal 或 schema，再发现不兼容。

SQLite WAL 的 `-wal`/`-shm` sidecar 与 checkpoint 会改变数据库文件字节，因此 raw file hash 不是迁移原子性或数据保留的可靠验收信号。需要验证已提交的 schema 和业务/无关对象的逻辑状态。

## 决策

使用 SQLite `PRAGMA user_version` 作为唯一 schema 版本标记，当前版本为 1。打开既有 database 后先读取该值；若它大于本 helper 支持的版本，立即拒绝，且在设置 WAL/NORMAL 或执行任何 schema、数据写入之前返回错误。

版本 0 包括此前所有未 versioned Vela database。`0 → 1` 在单个 `BEGIN IMMEDIATE` 事务内建立当前表、索引、counter 和 trigger，并在所有步骤成功后写入 `user_version=1` 后提交。取得写锁后必须再次读取版本并从该锁内值推进：另一 helper 若在等待期间已迁移到 current，当前连接不重复 DDL；若已迁移到更高版本，当前连接 rollback 并拒绝，绝不回写较低版本。迁移按显式 registry 顺序推进；未来版本须添加确定的下一步和相应的兼容/失败测试，不能在普通启动路径隐式补表。任一 DDL/DML 步骤失败则 rollback，原 store 保持可由同版本 helper 重试。

`user_version=1` 不是允许 `CREATE IF NOT EXISTS` 修补的承诺：打开 current store 会核验其必要 tables、indexes、triggers 和 `objects` 核心列；缺失或损坏会明确拒绝。当前版本不自动重建 canonical business objects。

测试仅有一个 internal 编号故障点，用于在既定迁移语句后抛错；它不接受调用方 SQL，也不向 CLI/RPC/renderer 暴露。

## 后果与验证

这保留了旧 `user_version=0` store 的兼容性，并使新建/已迁移 store 后续打开不重复 schema DDL。未来 schema 拒绝优先于 journal 设置，防止旧 helper 改写较新 store。迁移事务只覆盖 SQLite 内容；Markdown 资产的跨介质补偿仍沿用既有 Store/asset 合同，不因本 ADR 获得原子性保证。

`StoreMigrationTests` 用真实 SQLite fixture 覆盖：未 versioned legacy database 升级和重开、current database 重开、future/negative version 拒绝、current version 的损坏 schema 拒绝、半迁移故障 rollback 和重试，以及由 semaphores 协调的两连接竞态（旧 helper 初读 0、另一连接提交 2、旧 helper 在写锁内重读后拒绝，不会降级回 1）。每例检查 `user_version`、业务对象、无关表记录及目标 schema。测试不比较 WAL raw bytes。

## English summary

Vela Store now records schema version 1 with SQLite `PRAGMA user_version`. Legacy unversioned stores migrate from 0 to 1 in one immediate transaction; newer versions are rejected before changing journal mode or running schema/data writes. A numbered internal test fault point proves rollback and retry without exposing arbitrary SQL. WAL sidecars are deliberately excluded from byte-for-byte migration assertions; tests verify committed logical schema and data instead.
