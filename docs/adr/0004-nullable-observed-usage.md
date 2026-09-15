# ADR 0004：用量未知值与已观测部分和分离

- 状态：Accepted（决定已采用，测试与界面迁移结果另行记录）
- 日期：2026-09-13
- 范围：Session provider 计数、`usage.get`、原生 WebKit 中的用量显示

## 背景

隔离 provider 日志复现了两类实际问题：没有 usage 的 Session 被聚合成 0；`Int.max` 加缓存计数可使 Claude 摄取崩溃，Codex 输入/输出汇总也会使 helper 以 SIGTRAP 退出。来源格式不可信，缺失字段不能提供“未使用任何 token”的证据；部分 Session 有计数也不证明整个项目总量完整。

## 决策

保留 JSON 数值接口，但仅接受 `0...2^53−1` 的非负精确整数；真实零保留为零，缺失、非法、越界值与不可表示的加法结果返回 null。Swift 使用检查式加法；不截断、不饱和到最大值、不用浮点近似累计。这个范围与 WebKit 的 JavaScript 安全整数一致。未来若确需更大计数，必须协同迁移字符串/BigInt 契约，不能只放宽核心范围。

Session 和 provider/day/global 聚合同时给出完整可用值与 `observed*` 部分和，coverage 为 complete/partial/unavailable/overflow。完整只指此次选择的索引范围，不改变全历史未完成的声明。UI 将 null 显示为未提供；部分和明确写已观测，不用零柱替代未知值。

Claude 按 assistant message ID 维护有界的可空计数账本，在一次摄取批次结束时汇总。后补 usage 可以完成先前的缺失值，同 ID 的重复 partial 不能抹掉已经报告的计数。账本达到 4,096 条后的截断必须让完整值不可用，观测子集仍可见。Codex 使用其提供的累计计数，不估算未给出的维度。保留现有日志发现/尾窗/消息保留架构。

## 取舍与后续

返回 null 会要求旧消费者明确处理缺失值；保留 `observed*` 能避免因此隐藏已有可靠信息。受限整数比 BigInt/字符串接口改动小，也避免显示层悄悄丢精度。空库不再显示 0 token，但有明确零计数的会话仍显示 0。历史账本若曾经缺失来源信息，本次修复不伪造回填或证明历史完整性。

八项 `UsageIntegrityTests` 覆盖未知/零、混合范围、非法和极端计数、跨会话溢出、重复/后补消息与空库；实现验收由统一测试及真实 RPC 复测给出，本 ADR 的 Accepted 不代表测试已通过或界面已完成迁移。

## 依据

- [ECMAScript Number.MAX_SAFE_INTEGER](https://tc39.es/ecma262/multipage/numbers-and-dates.html#sec-number.max_safe_integer)，读取日期 2026-09-13。
- [Usage 返回契约](../implementation/contracts.md)、[SessionEngine.swift](../../Sources/VelaCore/SessionEngine.swift)、[UsageIntegrityTests.swift](../../Tests/VelaCoreTests/UsageIntegrityTests.swift)。
