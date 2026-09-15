# 工作流管理合同

所有新入口都要求注册项目 `project`；不会从当前页面推断权限。UI 由 Antigravity CLI Gemini 3.8 Flash High 实现。

| 方法 | 参数 | 行为 |
| --- | --- | --- |
| `workflows.get` | `{project,id}` | 返回实际 Markdown、解析后 definition、valid、diagnostics、snapshotHash、assetHash；纯读 |
| `workflows.validate` | `{project,cursor?,limit?}` | 默认100、最多1000条；逐份诊断，返回下一 cursor 或 null；不运行、不保存 |
| `workflows.clone` | `{project,id,snapshotHash,title?}` | 克隆为新 ID、enabled false，保存 clonedFrom 来源；不复制 run/approval |
| `workflows.setEnabled` | `{project,id,snapshotHash,enabled:boolean}` | 保存新版本；不取消已批准或已开始运行 |
| `workflows.remove` | `{project,id,snapshotHash}` | 可恢复归档，不删除历史；活跃/不确定 run 或依赖阻止归档 |
| `workflows.restore` | `{project,id,snapshotHash}` | 原始归档资产恢复为停用的新版本；归档后手改需先修复 |
| `workflows.list` | `{project?,includeArchived?:boolean}` | 默认不显示归档；显式 includeArchived 才包含归档 |

`workflows.get.valid` 只表示当前定义通过 Core 的结构/作用域/依赖校验，不表示 CLI 已登录、连接器可用或工作流效果成功。手改可能导致返回的 definition 是下一次保存的候选版本；检查本身不写数据库或文件。显示错误时保留其他工作流的诊断结果，不用整页错误替代逐项反馈。

每次修改必须带最近 get 返回的 `snapshotHash`。发生版本或资产变动时重新检查；不得把上次 hash 自动替换后重发。克隆展示 `clonedFrom.workflowId/version/snapshotHash`。归档期间的历史 run、审批和输出仍可查看；归档和停用不是取消运行。

JSON frontmatter 仍是支持的文件格式。正文中的原文、多行、中文和模板样式字面文本会保留；要把文本送给模型，应使用既有明确的 context/template 编辑入口。

## English

Review returns actual Markdown and immutable review hashes. Validation is paginated, read-only and per-file. Clone, enable/disable, archive and restore require the reviewed hash. Archives retain historical evidence; restoring keeps schedules disabled. Validation does not claim authenticated providers, successful effects, arbitrary YAML support or cancellation of existing runs.
