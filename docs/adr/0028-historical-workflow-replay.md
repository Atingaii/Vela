# ADR 0028：显式历史材料的双版本回放

- 状态：Accepted，验证范围单独记录
- 日期：2026-09-13
- 范围：PX0-097/098/099 的单 contextual `agent.run` template 比较；组合形状后续扩展

## 决策

保留 `workflows.replay` 的 captured-only 行为。新增 `replay.*`：用户显式同意保存一个已有终态 run 的完整 context v1 snapshot（1–30 天），然后选择同一 workflow 两个保存版本，经过新的独立审批，最多调用 Codex 两次。两次采用相同的历史 inputs、guidelines、memory；仅 template 改变。原工具、输入工具、当前 Git 和交付工具均不执行，旧 run 的审批没有继承效力。

拒绝缺失 hash、degraded 输入、不支持的 snapshot、pipeline、子工作流输入、agent.loop、多个步骤和交付输出。仅扩大 caps 或重新读取今天的上下文不能弥补历史数据缺失。每个原始 source/content/input/prompt hash 都重新验证；模板以单遍 substitution 渲染，插值里的模板语法不会再次执行。

元数据和正文分别持久化为 `replay_fixture` / `replay_fixture_payload`、`replay` / `replay_payload`。审批及普通 run 只含 ID/hash。get/list 只返回小元数据，review/results 显式读取单个正文。fixture 有 revision、expiry 和 tombstone。forget 先 CAS 撤销元数据，再清正文；每次 forget 最多删 128 个关联 payload，并准确返回 cleanupPending。prune 以稳定 identity cursor 遍历 1–32 个 fixture，未清完当前项不越过；中断后可继续。删除不声称清除 SQLite WAL 或原 run/provider 文件的取证残留。

模型使用既有 RestrictedCodexProposal 的 no-tools 隔离目录协议。请求冻结两份命令/schema、agent、timeout 和 hash，审批一次最多两次发送。每次发送前重新检查 fixture、取消标记和来源：Library 必须明确 public、active 且安全资产存在；Memory/Guideline 需保持原 scope 和有效状态。来源正文更新仍使用冻结旧正文；改为 private/archived/missing 则阻止发送。已发送的请求无法撤回；运行中取消只阻止后续发送。

每次 claim/receipt 以 metadata、payload 和 fixture 原 hash 联合 CAS，取消只合并取消标记，撤销或删除后不得重建正文。claim 后崩溃即不确定，不自动重试；A 失败时不发送 B。完整受限原输出和逐调用回执仅存在可撤销 payload。比较采用有界共同前后缀行替换 diff，不声称最小 edit distance；语义效果始终 unknown，完成模型协议不证明真实工程改进。

## 权衡与数据边界

不选无持久化临时回放：无法复查确切历史输入和失败的部分回执。不选读取当前来源代替历史：会混淆输入变化与版本变化。不复用通用工作流执行器：它可能运行 Git、shell、外部工具或产物交付。新增模块只提供比较实验，不成为新 agent 框架。

Memory archive/export、integration memory recall 均按明确 memory kind 白名单读取，不包括新增 fixture/replay kind。通用本地 store 管理备份若未来支持全部 kind，必须另行定义 replay 的 opt-in 导出规则。

## English summary

Explicitly retained historical context is compared across two saved templates under a new two-call approval. No input or business tools run. Separate revocable payloads, bounded no-tools transport, per-send privacy checks and CAS receipts prevent stale resurrection or automatic retries. This slice does not complete composition replay or prove semantic improvement.

## 审查后补强

独立审查指出项目级 10,000 行窗口会遮挡待删正文，以及按路径核 hash 后再启动存在入口替换竞态。清理改用按 fixture 过滤并 JOIN 实际 payload 的窄 SQL 与显式游标。Replay 采用独立 native_snapshot：仅支持可独立运行的 macOS Mach-O 入口，审批后流式复制到私有 0700 目录/0500 文件，副本完整 hash 必须等于冻结值，A/B 同一副本执行后清理。script/Node 包装器明确拒绝，后续兼容另行设计，不能影响 Ask/Planner/Loops 原合同。入口 hash 不涵盖动态库、插件或 helper 依赖，依赖相对资源的 CLI 若失败不得回退原路径；真实本机 Codex 0.154.0 副本 --version 已验证，但未调用真实回放模型。
