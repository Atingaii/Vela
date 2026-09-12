# Vela 非目标 / Non-goals

**English:** Vela supports engineering work performed by existing coding agents. It does not replace the IDE or agent, become a general automation platform, or require cloud memory. Deferred work is not completed work; required acceptance gaps must not be relabeled as non-goals.

本文件约束范围，配合 [PRODUCT_PRINCIPLES](PRODUCT_PRINCIPLES.md) 和 [PRD](PRD.md) 使用。不能为了通过验收，把原始核心能力移到这里。

## 首批版本不做

| 非目标 | 为什么不进入核心 |
| --- | --- |
| 新 IDE、代码编辑平台、自己的 Coding Agent | 用户继续使用 Claude Code/Codex/Cursor；Vela 承担观察、记忆、治理、自动化与验证 |
| 通用 Multi-Agent Orchestrator、Agent framework | 不需要发明一套运行时来证明一个 verification 改善路径 |
| Zapier/n8n 式通用自动化、邮箱/日历/CRM 生活助理 | Workflow 围绕 Coding/Engineering；参考 px0 不继承其所有行业任务 |
| Cloud-first SaaS、强制账户、托管对话/Memory | 默认用户本机拥有工程状态；联网行为必须具体且可审阅 |
| 无限会话总结、自动堆叠永久 Rules | Memory 要有未来价值、scope 和证据；重复 procedure 优先 Workflow |
| Windows、Linux、Mobile 首发 | 首发 macOS/Apple Silicon，先验证支持的系统范围 |
| Workflow Marketplace、团队协作管理与商业账户系统 | 不为核心单人闭环增加分发平台、审批层级和运营依赖 |
| 复制参考项目品牌/私有源码/私有提示词/内部素材 | 三个参考提供产品思想；Vela 独立实现与测量 |

## 延后但保留的方向

原始构思中的 Native Session Transfer、Best Harness/Model、外部 GitHub/Linear/Slack tool providers、Conflict Radar、Canonical Context、加密同步、自托管同步、Walrus backend、Team Memory/Workflow 属后续立项。新增公共接口、数据出口、权限或后台运行方式需单独设计和 ADR。中立 Checkpoint Handoff 仍是核心要求，不能因原生私有格式迁移延后而一起删除。

Semantic Recall、完整 History/Backfill、Workflow Discovery、真实 Agent Lab、未来 Session Reuse 等在原始核心阶段中有明确要求；当前不足应标 Missing/Partial，不属于永久非目标。可选择最简单正确实现，不强制某个模型、向量库、进程数量或旧 Electron 草案，但不能以方法简化删除用户结果。

## 不作出的保证

- 不把日志活动等同于进程存活，不把文件存在等同于 Agent 实际加载。
- 不承诺所有私有 provider schema、完整账户配额或任意模型版本均可用。
- 不把工作目录/worktree 当操作系统沙箱，不把一次审批领取当任意外部系统 exactly-once。
- 不承诺候选一定更好、token 必然节省、未来重复纠错率必然下降；这些必须测量。
- 不把官网上线、测试总数、包体积或 screenshot 当完整产品验收。
- 不将已验证的开发包宣称为已 Developer ID 签名、公证或稳定自动更新。

## 范围变更规则

每项新增需求指向至少一个 Goal，并说明对 Golden Scenario、Hard Gate 和维护成本的影响。若减少一个模块仍能可靠满足相同用户结果，优先简化；若取消核心结果，必须明确作为需求变更审阅，不能悄悄移动到路线图或文案中消失。
