# Local Store backup and restore / 本地完整备份与恢复

This command is on the development branch. It is a local, unencrypted backup of Vela-managed data; it does not copy your agent login, original provider log directories, or Git working trees. A bundle can contain private notes and imported material. Choose a private destination and keep the related projects and original sources separately.

此命令属于开发分支，备份 Vela 管理的本地数据，未加密。它不复制 Agent 登录身份、外部原始日志目录或 Git 工作树；bundle 可能含私有笔记与资料。请使用私有目标目录，并另行保存相关项目与原始来源。

```sh
# Use the helper and Store for the channel you actually run.
vela backup create --destination /absolute/private-parent/vela-backup --home /absolute/path/to/store
vela backup restore --bundle /absolute/private-parent/vela-backup --target /absolute/private-parent/vela-restored
vela call settings.get '{}' --home /absolute/private-parent/vela-restored
```

Both the bundle and restored Store must be new children of an existing real directory. A pre-existing target is rejected, including an empty directory. `restore` does not open the original/default Store. It does not replace your application's configured Store or automatically switch channels; inspect the restored Store with an explicitly selected `--home` before using it.

bundle 和恢复目标必须是既有真实目录下的新目录；目标即使为空但已经存在，也会被拒绝。`restore` 不打开原 Store 或默认 Store，也不自动切换客户端的数据目录。先用明确的 `--home` 检查恢复数据。

Paths must use their canonical spelling without symlink ancestors. On macOS, use `/private/tmp` for a temporary destination rather than the `/tmp` symlink. The development fix preserves canonical paths through Foundation parent-directory operations; the earlier `3894dab6` package incorrectly rejected this valid destination.

路径必须使用没有符号链接祖先的真实规范路径。macOS 临时目标可使用 `/private/tmp`，不要使用 `/tmp` 链接别名。开发修复保留 Foundation 父目录操作中的规范路径；此前 `3894dab6` 包会误拒绝这一有效目标。

## What survives / 保留的内容

- SQLite objects, preferences, versions, sessions, History records/raw chunks and persisted source receipts.
- Exact bytes for Memory, Workflow, Guideline, Library and Checkpoint Markdown assets, plus regular managed `store/output` files. Canonical `assetPath` fields point to the restored root.
- Private content remains private. Management may display it; eligible agent retrieval, Recall and MCP continue to apply their privacy and scope rules.
- Run, approval and other execution records remain as evidence. Pending work becomes non-executable `needs_review` (Health proposals become `invalidated`); automatic workflows are disabled. Old approval IDs cannot authorize a resumed side effect.

SQLite 对象、偏好、版本、会话与 History 原文/收据、五类 Markdown 资产和受管 output 文件都会保留。私有内容仍受原有管理与召回隔离约束。历史运行与审批保留审计，但旧待执行请求失去执行资格，自动工作流停用；恢复不会重放它们。

## Indexes and external sources / 索引与外部来源

Local semantic vectors and completion projections are discarded. Library index entries become stale when canonical objects are rebound; rebuild them through the existing paged `library.index` API. Original provider/source paths are preserved as provenance. If those files are unavailable, origin-dependent operations continue to report missing/stale sources rather than inventing a new origin.

本地向量与完成事件投影会清除。Library 对象重绑后索引失效，可通过既有 `library.index` 分页重建。外部原始来源路径仍保留为来源证据；文件缺失时，依赖来源的操作继续报告不可用，不伪造新来源。

## Bounds and errors / 上限与失败

- SQLite snapshot: at most 2 GiB; 256 pages per backup step with a 30-second database-copy deadline.
- Canonical assets and outputs: at most 50,000 files and 2 GiB combined, 64 MiB per file. Manifest: at most 8 MiB.
- File I/O uses 64 KiB chunks and a 60-second snapshot/restore I/O deadline. Slow or oversized stores fail explicitly; there is no silent truncation.
- A running daemon/scheduler/composition lease, SafeApply lock, or active/uncertain external action blocks creation. Stop the owned runtime and resolve uncertain actions before trying again. A pending approval that has never executed is allowed.
- Corrupt manifests, changed bytes, unsafe paths, symlinks, hardlinks, FIFOs, future schemas and existing targets are rejected. Publication uses `RENAME_EXCL`, so competing restores cannot overwrite the winner.

超过容量/时间上限、存在活跃运行锁或执行结果不确定时明确失败，不截断为“完整成功”。普通待审批请求可备份，但恢复后不能沿用旧审批执行。文件身份和 hash 检查可检测观察到的修改；并不承诺抵抗同用户进程任意改写磁盘或断电时的绝对跨介质原子性。

Implementation decision: [ADR 0044](../adr/0044-complete-local-store-backup-and-recovery.md). Full reference coverage, desktop management, encrypted remote recovery and release gates are separate acceptance work.
