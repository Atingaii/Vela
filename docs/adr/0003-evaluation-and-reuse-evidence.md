# ADR 0003：真实 Agent 对照与项目启动召回

- 状态：Accepted（决定已采用，验收结果另行记录）
- 日期：2026-09-12

## 背景

成对命令的退出码不等于 Agent 行为改善，MCP 可调用也不等于下一次会话会收到 Memory。新的产品验收要求把建议、候选、对照、晋升和后续使用连起来，同时禁止把 Vela 变成另一套 Coding Agent 或编排平台。

## 决策

沿用 Swift、现有冻结审批和独立 Git worktree。在命令 Lab 之外加入明确的 Codex CLI 协议适配器；冻结 repo/commit、同一任务、模型请求、reasoning effort、超时、重复次数、候选上下文和独立验证命令。记录实际 CLI 版本、结构化事件、provider usage、命令调用与独立验证结果。没有事件或指标时保留 unavailable。测试文件等验证依据冻结并在 Agent 执行后检查，变化使评估失效，不能把被修改的测量尺算通过。

单轮对照不估算用户纠错数，也不自动证明未来行为改善。候选差于基线时拒绝晋升；无改善、样本不足、输出截断或 token 数据缺失时保留 inconclusive。只有满足已记录的局部比较门槛且人工点击晋升，才激活经评估的项目 Candidate Memory；保留内容 hash 与 eval 链接。整体产品 Hard Gate 和 Golden Scenario 是另一层发布门槛。

下一次会话通过 Codex 官方 SessionStart Hook 获取有预算的 active、非 private、同 scope 的 Memory。安装仅对所选项目生成可审阅的 `.codex/hooks.json` 文件变更，合并保留已有配置，使用 SafeApply 的 base hash、路径检查和 Undo。Vela 不代写 Codex 的 hook trust；用户在 Codex `/hooks` 审核确切定义后启用。CLI 接受受限 JSON 输入，不读取传入的 transcript_path、不执行模型、不暴露任意读写或 shell。召回收据表示“提供给 Hook 的上下文”，不是 Agent 已采用的声明。

## 取舍与边界

- 复用官方 CLI 与 Hook，减少常驻进程及维护成本；依赖已安装且已认证的支持版本。Claude/Cursor 的同等接入需各自验证，不能从 Codex 推广。
- 自动修改所有 agent 配置、长期塞入 AGENTS.md、默认执行项目脚本都被排除。Hook 本身只输出上下文，不执行其中描述的工作流。
- 对照使用 provider 计量而非估算 token；缓存、模型服务端变化和少量重复仍限制因果结论。模型参数可冻结，服务端模型版本并非由 Vela 控制。
- Worktree 不是 OS 沙箱。真实 Agent 使用其 workspace-write 沙箱；独立项目验证命令仍须明确审批。
- 后续效果由收据关联到真实已摄取会话的观察统计给出，缺失或未匹配会话不算成功，不能将一次演示外推为长期纠错率下降。

## 依据

- [Codex Hooks](https://developers.openai.com/codex/hooks/)：项目配置、SessionStart additionalContext、确切定义 trust。
- [Non-interactive mode](https://developers.openai.com/codex/noninteractive/)：JSONL 事件与 provider usage。
- 本机 `codex-cli 0.154.0` 的 `exec --help`，以及本仓库现有 Lab/Approval/SafeApply 实现。
- 实际结果与未通过项记录在 `docs/ACCEPTANCE.md` 和本轮验证记录，不由 ADR 的 Accepted 状态代替。
