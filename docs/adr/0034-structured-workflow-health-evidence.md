# ADR 0034：结构化 workflow health 运行证据

- 状态：Accepted；实现与验证分开记录
- 日期：2026-09-13

PX0 的 health 从持久化 run event 与 workflow version 做算术，不能把当前定义或输出文本当作历史原因。Vela 以现有 run ledger、冻结 `workflowVersion`、step 状态和 approval ledger 构建只读报告，不新增执行器、模型调用或自动修复。

成功率和平均时长的分母仅为非 dry-run 的 `completed` 与 `failed`。取消、拒绝、待审批、运行中和 `needs_review` 分别计数；不确定结果不会被转换为失败或成功。timeout、拒绝工具、turn cap、完成 run 的全步骤失败均须有对应结构字段才形成 observation，未记录的指标为 unknown/null，不声明因果。

保留原 `workflows.health` 聚合字段以兼容既有 consumer；项目范围请求才返回分页、脱敏 run 摘要和 run-id 回链。无项目请求仅提供跨项目聚合，以免新 detail surface 泄露其他项目记录。参见 [合同](../implementation/workflow-health-contract.md)。
