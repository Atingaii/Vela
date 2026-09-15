# ADR 0033：有界工作流只读步骤重试

- 状态：Accepted；接线与验证分开记录
- 日期：2026-09-13

PX0 的 per-step retry/backoff 不应把 Vela 的一次性 approval 变成隐式重复执行。Vela 仅为固定本地 Git 观察工具 `git.status`、`git.diff`、`git.log` 提供显式、默认关闭的 retry policy。每个实际尝试、失败、等待、取消和最终状态必须随冻结 run step 持久化；已有尝试的重启恢复为人工复核，绝不猜测重放。

写入、shell/agent、connector、model、知识问答与 agent loop 可能产生副作用或无法判断结果。它们不支持此 policy，仍沿用既有冻结 approval 和 `needs_review` 边界。等待以短片段检查取消和 deadline，不建立后台 executor 或阻塞控制请求。

这保留现有 Swift workflow runner 与版本冻结语义；参见 [合同](../implementation/workflow-retry-contract.md)、ADR 0015 和 ADR 0020。
