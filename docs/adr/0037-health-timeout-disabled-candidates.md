# ADR 0037：Health timeout 的停用候选工作流

- 状态：Accepted；实现和验证证据另列
- 日期：2026-09-13

## 背景

ADR 0034 的 `timeout_observed` 是持久化 run/step 字段，不是已证明的根因或修复。现有 `git.*` 读取固定使用 30 秒 `AutomationProcess.git` 超时，不消费 step 的 `timeoutSeconds`；`shell.test`、`shell.typecheck` 和 `agent.run` 的超时结果标为 `outcomeUnknown` 并把 run 留在 `needs_review`。因此把 health finding 自动写回原活动 workflow，或把 uncertain timeout 当作失败原因，都会产生不成立的“自动修复”。

## 决策

只为完整项目范围扫描中、同一 workflow/version/snapshot 的单个已记录 timeout step 创建 `workflow_health_proposal`。候选仅限现有确实消费 `arguments.timeoutSeconds` 的 `shell.test`、`shell.typecheck`、`agent.run`，显式值为 1–300 的整数；缺失值冻结现有执行默认 120。人工调用方提供建议值，Core 只接受大于冻结值、不超过两倍且不超过 300 的值。proposal 冻结 project、workflow ID/version/snapshotHash、run ID/hash、step ID、finding ID、tool、旧/新 timeout 和来源是否 outcome-unknown；不保存输出、参数以外的命令内容或私有材料。

`needs_review` timeout 可以作为观察事实被提案，但标记 `sourceOutcomeUnknown:true`，接受时必须显式 `acknowledgeUncertainSource:true`。这不是改善、原因或安全执行结论。创建和 reject 不写 workflow/run/approval。accept 重新验证 scan cap、run hash/隐私/timeout、原 workflow snapshot/version；最终写入以 proposal、run 和持久 workflow record 的精确 CAS 保护，并在事务前重新检查 asset-backed snapshot。随后只新建不同 ID 的 `enabled:false` candidate workflow，保留原 argv/tool/context 等字段，仅改该 step timeout。若进程在 claim 后中断，显式 `recover` 只 CAS 恢复 proposal 供再次人工决定，不创建或重试 candidate；CAS 冲突不覆盖并发状态。原活动 workflow、历史 run、approval 都不更新或重放；候选的后续启用和执行仍走既有 workflow 审阅与 approval。

## 后果

该能力是 FR64 的窄闭环，不是自动调参或通用 workflow patch API，也不改变 Git timeout 合同。任何跨项目、私有、dry-run、截断、缺失、source/version/hash 改变或 10,000 scan cap 都拒绝；proposal 不会用今天的状态替代历史证据。参见 [合同](../implementation/workflow-health-proposal-contract.md)、ADR 0034 和 ADR 0019。

## English summary

A timeout finding can create a reviewable, disabled new workflow candidate only. Acceptance revalidates frozen evidence and never changes or reruns the active workflow. Unknown outcomes require explicit acknowledgement and do not prove an improvement.
