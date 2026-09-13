# ADR 0009：多 Harness 的公开格式适配与持久化分支证据

- 状态：Accepted（实现采用；验收结果单独记录）
- 日期：2026-09-13
- 范围：Pi/OMP 只读 Session 摄取与五 harness 发现

## 背景

Vela 原来的 `SessionEngine` 只处理 Claude/Codex 与部分 Cursor。新增 Pi/OMP 时，简单套用 Cursor fallback 会丢失嵌套角色、工具关系及模型厂商；把分支树按文件顺序拼成一个对话，会将放弃的分支混入当前证据。既有 256 KB 尾窗也不保证保留较早的分支祖先。

## 决策

采用独立 Swift `PiSessionReader`，仅依据两个 provider 的公开格式文档实现读适配。v1 按物理顺序生成本地关联；v2/v3 使用 `id/parentId`。OMP 的固定 title slot 与逻辑 session header 单独处理。未来版本、重复 ID、循环或超限源拒绝提交，保留旧快照并报告错误；不自动修改、迁移或删除原始文件。

Reader 以 64 KB 分块扫描，保存条目的字节偏移与父链，再读取最近持久化条目的祖先正文。单源 128 MB、100,000 条、单条 8 MB 上限；展示保留 1,000 条、1 MB 正文。使用 fresh lstat 的 device/inode/size/mtime 纳秒/ctime 纳秒版本在扫描前后复查，避免 URL 元数据缓存与 Double 时间精度导致同长度改写被跳过。Reader 用 O_NOFOLLOW 打开文件并检查 descriptor 的类型与大小；变化则保留原快照并重排检查。未知事件保留祖先关联并降低完整性，不推断其含义；不读取 header、工具文本或外置 blob 所引用的路径。

`provider` 始终表示 harness（pi/omp）；`modelProvider` 只保存源事件提供的模型厂商。没有源 Git branch 时为 null，不从当前项目分支猜历史。`parentSession` 是 opaque 来源信息，不是自动跟随的文件路径。记录 `sourceFormatVersion`、`branchSelectionSource`、`sourceLeafId`、`branchAncestryComplete`、`compatibilityWarnings`。

最近持久化条目不是 Agent 进程当前的内存 leaf。UI/检索只使用明确标记的持久化链；状态只来自显式 assistant stopReason，不把文件修改或用户消息当作进程存活。现有 Claude/Codex 的推断状态合同不因新增适配被改写。

用量按全部索引分支中的唯一持久化 usage 事件累计，以反映已经发生的调用；不只累计当前展示链。输入包括源给出的 input/cacheRead/cacheWrite，沿用 [ADR 0004](0004-nullable-observed-usage.md) 的可空安全整数与 overflow 语义。完整计数和 observed 部分和分别存储；不是账户剩余额度。

## 取舍

相比复制私有 parser，公开格式独立实现可维护且不带入私有代码。相比只读末尾窗口，offset 索引保留早期祖先；代价是变化文件会重扫，首版不会宣称大历史长期性能已经达标。相比把每个源事件都写入通用 store，临时索引避免新增持久化 schema、海量对象和额外查询 API。未来实测证明变化文件重扫超出性能目标时，再以独立决策引入持久化 offset/entry 索引。

## 依据及验证

- [Pi 公开 session 格式](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md)
- [OMP 公开 session 格式](https://github.com/can1357/oh-my-pi/blob/main/docs/session.md)
- [ProviderCompatibilityTests](../../Tests/VelaCoreTests/ProviderCompatibilityTests.swift)：版本、分支、标题、工具、未知值、坏源保旧、partial/rotation、FSEvents 和资源上限。
- [完整 Blume 对齐清单](../parity/blume.md)：新增 adapter 不等于功能超集或真实多 provider 运行验收完成。

## English summary

Pi/OMP sessions use independent read-only adapters based on public schemas. A bounded streaming byte index preserves persisted branch ancestry without loading every transcript into memory or following referenced paths. Harness identity, model-provider identity, usage coverage and live-process uncertainty remain separate. Unknown versions and corrupt graphs do not replace an existing snapshot.
