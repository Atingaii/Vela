# 实施与验收计划

每一阶段都要贯通数据、核心行为、界面入口和失败提示。功能完成状态以测试及交付验收为准，不以页面存在判定。

1. **P0 观测闭环**：独立本地 helper、SQLite、Claude/Codex 增量 Session、项目管理、菜单栏、Setup/Usage/Search、Memory、Checkpoint、MCP READ。
2. **P1 工程闭环**：Cursor 容错适配、Recall、确定性 Setup Audit、证据信号与建议、Safe Apply/Undo、Markdown Workflows、Dry Run、冻结 Approval Inbox、Run Ledger、隔离 Lab。
3. **P2 持续演化**：工作流调度、Health/Replay、工程 Library 和私有隔离、预算 Recall、检索型 Ask Vela、评测比较、Regression 提示、CLI/Raycast 接口。
4. **客户端与官网集成**：Antigravity CLI 3.8 Flash High 实现 UI，连接真实 RPC；官网同 px0 风格，产品文案真实；打包 `.app` 和分发归档。
5. **发布验收**：真实文件/SQLite 安全测试、CLI/MCP 集成、增量摄取与预算检查、包内显式文件允许清单、Mac 启动及资源采样、官网链接验证与托管。

P3（外部平台适配、原生 Session 迁移、智能选模）与 P4（同步和团队能力）遵循草案后续边界。正式公开分发所需 Developer ID 签名、公证依赖用户可用 Apple 凭证；在凭证不可用时必须标记本地开发构建，不能宣称正式公证完成。

## 执行约束

- 所有客户端 UI 和官网 UI 由 `agy --model gemini-3.8-flash-high --effort high` 编写，常规 agent 负责核心与集成。
- 只读取 Blume 三份报告，不复制逆向包源码、私有 prompt 或品牌资产。
- Provider 的真实配额不可获取时显示 unavailable，会话 token 统计不冒充额度百分比。
- 不自动执行用户项目的测试脚本；工作流中执行这类任意项目代码需要冻结审批。
- 默认不发消息、不改外部服务、不自动向 Agent 提交用户历史内容。
