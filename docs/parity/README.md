# 三产品完整覆盖计划

最新的 [188 项最终规格初步筛查](final-spec-2026-09-14.md) 把用户补充规格与现有代码对应，并单列实现、缺口和验收证据。它与下述 228 项参考清单互补；编号规格并非原子测试用例，当前没有宣称完整通过。

正式官网的 [Cloudflare 部署证据](cloudflare-production-evidence-2026-09-14.json) 记录 `velo.codes` 的 HTTP 和浏览器验证；[客户端易用性评审](../implementation/desktop-usability-review-2026-09-14.md) 记录待实施的界面重构要求，两者不替代产品全功能验收。

日期：2026-09-13。用户明确修正目标：Vela 的目标能力应覆盖 Blume、Walrus Memory/MemWal、px0 的全部已交付功能，并在可验证的方面改进。此前按工程最小闭环有意留下的范围限制，不再作为删减这些需求的理由。

## 固定对标范围

三份逐项清单共 228 个子项，包含公开已交付功能、beta、受条件控制的入口、示例和规划项，分别标明，不把它们统称为已发布：

- [Blume：52 项](blume.md)：多 harness 观测、配置治理、模型式 Improve、账户用量、托盘/快捷入口与发布体验。
- [Walrus Memory：56 项](walrus-memory.md)：语义记忆、所有权/授权、加密远端持久化/恢复、SDK/MCP/插件、存储生命周期与运维。
- [px0：120 项](px0.md)：自然语言创建、实际上下文消费、工具/连接器、调度、记忆/Library、审批、回放/改进和完整命令/部署面。

交付版本以各清单固定的第一方资料与日期为准。文档冲突、未发布开发分支和“Soon”不靠猜测解决；核对发布说明和发行物。参考实现具有的限制也记录下来，可成为 Vela 的具体优化目标，但不能据此伪报 Vela 已完成。

## 实现与验收顺序

| 阶段 | 必须交付的行为 | 验收出口 |
| --- | --- | --- |
| 1 核心接通 | 五 harness 读取、真正注入的 Workflow Context、跨进程安全的后台调度、记忆迁移与可安装 SDK | 界面→真实 helper→数据/进程→重启的完整证据；不存在的能力继续标缺失 |
| 2 Agent 与资料消费 | 自然语言访谈/规划、语义 Recall/Ask/提取、更多官方 lifecycle hooks、账户额度、模型式 Improve | 明确来源、模型/协议版本、冻结请求；真实提供方调用及反例，不用返回文本替代已采用 |
| 3 工具与身份 | 外部工具发现/连接/审批、完整 owner/namespace/delegate、可选加密远端后端、跨设备恢复 | 独立测试账户的真实授权与撤销、网络错误和不确定写入；不得用 fixture 冒充远端成功 |
| 4 执行与运维完整性 | pipeline/子工作流、watch积累、维护/备份/迁移、双版本回放、所有 CLI/SDK/插件入口与平台范围 | 多步完整流、断线/崩溃/并发/大集合、版本兼容及外部平台实测 |
| 5 产品级验收 | 完整 Golden Scenario、六 Hard Gate、安装/签名/通知/更新与三产品逐项关闭 | 全部已交付项有对应实现和成功证据；任一缺口不能被总测试数抵消 |

阶段用于安排依赖和并行工作，不是将后续需求移出范围。当前实现正逐项推进；没有预先宣布 228 项已完成，没有以改比较表标签作为功能补齐。

## “大于等于”的可检查含义

每一项参考用户能力至少有一个可使用的 Vela 路径，能处理同类输入、产物、权限和失败情况。技术实现可以不同，但不能把词面搜索称为语义搜索，把本地归档称为加密远端恢复，把固定命令称为自然语言 Agent，也不能把未执行的工具或未获得的订阅额度标成可用。

更优的结果必须具体测量，例如恢复完整分页、跨 namespace 权限、默认离线可用、候选记忆可审阅、来源可追溯、没有额外默认运行时、失败后不重复副作用。只有实现和测试之后才进入对外优势描述。

“验证成功无误”按每项事先明确的支持版本、输入范围和错误反例验收；软件无法由有限测试证明绝对零缺陷。真实账户、外部服务、Apple 签名/公证及其他机器/系统的结果，只能由对应环境实测获得。缺少此类证据时保留未验收状态，不伪造通过。

## English

The target is full capability coverage of the three reference products, followed by measured improvements. The 228-item inventory distinguishes shipped features, beta/gated capabilities, examples, and roadmap items. The stages order dependencies and parallel work; they do not remove later requirements. Every shipped capability needs an accessible implementation and specific execution evidence. A high aggregate test count cannot compensate for a missing user workflow, real-provider integration, recovery path, or release gate. The current branch does not claim complete parity.
