# ADR 0040：增长会话来源的已索引前缀完整性

- 状态：Accepted
- 日期：2026-09-14
- 范围：默认 `SessionEngine` 的 Claude/Codex JSONL 增量摄取；不改变显式 History epoch 或 Pi/OMP 的完整版本化 reader。

## 背景

文件增长不能证明先前已经摄取的字节未被重写：inode、ctime、mtime 和 size 都会随正常 append 变化。原先 Codex 仅复核 header 行，因此旧的非 header message、plan 或关系事件被改写并追加新行时，旧 offset 会保留过期投影。

## 决策

每个成功提交的 JSONL ingestion cursor 保存 `indexedPrefixSHA256`，即 `[0, offset)` 已完成字节的 SHA-256。只有来源**增长**时，才以 64 KiB 固定块重新计算该完整前缀；每块在独立 autorelease pool 内释放，避免长驻 RPC helper 保留逐块临时 `Data`；匹配才从旧 offset 增量读取。失配、缩短、同大小版本变化、fingerprint/decoder 变化均从头建立新 session/plan/relation 快照。旧 cursor 没有 digest 时，下一次增长保守重建一次，随后写入 digest。正常未变化的来源不额外扫描。

摘要计算不把前缀读入内存，峰值附加内存为一个块；增长刷新额外 I/O 为 O(previous completed offset)。partial tail 不在 offset/digest 中，后续补全该行仍按原有流式规则读取。来源在摘要或解析期间再变化时，既有 scan-end source-version 校验保留先前快照并请求后续刷新。

## 后果与验证

这给出默认 dashboard 已索引前缀的完整性检查，不等同完整历史导入、进程活性或任意 provider 格式支持。它会使大而频繁追加的日志产生额外顺序读取；选择该成本是为了不把旧投影伪装为当前来源。`FoundationTests` 覆盖 Claude/Codex 旧区重写加追加、正常追加、旧 cursor 迁移和 partial tail；实际 CLI receipt 另行保存。

## English summary

Growing JSONL files now carry a SHA-256 digest of their completed indexed prefix. On growth, Vela streams and verifies that whole prefix before reusing the prior offset; mismatches and legacy cursors without a digest rebuild once. This costs O(previous offset) I/O only on growth and fixed-chunk memory, while unchanged files incur no extra scan. It protects indexed dashboard projections, not complete provider history or liveness.
