# ADR 0042：原子项目与来源摄取排除

- 状态：Accepted
- 日期：2026-09-14

## 背景

取消项目登记不是摄取排除：它既不能表达某一个 session source，也不能安全撤回既有派生投影。来源日志通常位于 provider root，而不是用户仓库；路径规则必须保留项目身份边界。

## 决策

采用项目 scoped `ingestion_exclusion` 对象，并以现有 SQLite 事务保存规则和 policy generation。规则要么排除整个已登记 canonical 项目，要么以 provider-root-relative glob 排除已知同项目的普通日志来源。source glob 在写入前验证关联，拒绝未知、跨项目、symlink 或不安全路径。

Session ingest 与 History discovery/read chain 复用此 eligibility。规则写入、generation 推进和已存 session/plan/relation/cursor 的撤回在同一事务内完成；后续投影写入以 generation CAS 拒绝策略变化期间的旧 admission。History 原始缓存保留审计价值，但所有可读/推进入口重验并拒绝已排除来源。Memory、用户文件和 provider 原始日志不删除。

每项目上限为 256 条；超过上限的读取 fail closed。Glob 只支持 `*` 与 `?`，且它们跨斜杠匹配，明确不采用标准 pathname glob 语义。解除规则的操作本身不启动重新摄取；后续显式 refresh 或正常 watcher 的来源变化可以重建 Session 投影。历史缓存保留，因此撤销限制后旧 epoch 可再次访问。这是可逆的摄取/访问策略，不是删除历史；不引入跨数据库 tombstone 或原文删除事务。

## 后果与边界

这保留多 helper 的 SQLite 一致性，而无需新表迁移。规则变更不会修改 provider 文件，也不承诺已在飞行中的源读取具备强线性撤销；写前 CAS 仅阻止其产生过时的持久投影。Accepted 记录选择的长期边界，不表示 UI、完整回归或产品验收已经完成。
