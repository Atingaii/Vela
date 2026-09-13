# 外部连接器合同 v1

状态：Composio REST v3.1 Core/审批与工作流入口已实现，fixture 验收进行中；未连接真实测试账户，不能标“所有工具已验证”。UI 仍由 Antigravity CLI `gemini-3.8-flash-high --effort high` 实现。

## 设置与目录

`connectors.status {}` 是纯本地读取，不访问 Keychain secret 或网络。首次 `state:not_configured`。配置参数 `connectors.configure {apiKey,userId}`：用户明确输入 Composio project API key 及其服务内 user ID；先 GET 验证 auth_configs 权限，再存入当前 store 对应的 macOS Keychain 项，返回 metadata/generation/verifiedAt。API key 永不返回，不存 SQLite，也不进导出。失败不保存新 key。不要把密钥放进 URL、终端命令参数、日志、剪贴板或 localStorage。CLI 支持 `vela call connectors.configure --params-stdin` 从单行 JSON 读取；桌面使用已授权原生桥接。

`connectors.forget {generation}` 只断开本地配置并移除其 key；不会撤销或删除远端账户。必须根据 status 提供的 generation 明确操作。移除失败可用同 generation 再试；不会重新启用连接。

| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `connectors.tools.search` | `{query?,toolkit?,cursor?,limit?}` | 在线目录页 |
| `connectors.tools.get` | `{slug,version?}` | 当前/指定版本工具，保存本地 snapshot |
| `connectors.tools.list` | `{}` | 当前 credential generation 的本地缓存，最多1000条 |
| `connectors.toolkits.list` | `{query?,cursor?,limit?}` | 在线 toolkit 页 |
| `connectors.accounts.list` | `{toolkit?,cursor?,limit?}` | 当前 user ID 的账户页，移除 credential/state/data 字段 |
| `connectors.authConfigs.list` | `{toolkit?,query?,cursor?,limit?}` | 已有 auth config 页，移除 credentials/shared_credentials/proxy 字段 |

在线页为 `{items,nextCursor,hasMore,sourceCapturedAt,provider,apiVersion,networkRequested:true}`；每页默认25、最多100，authConfigs最多50。保持上一页与继续加载，不能将一页当完整目录。缓存工具含 slug/version/toolkit/name/description/inputSchema/outputSchema/noAuth/tags/scopes/scopeRequirements/catalogHash/sourceCapturedAt/approvalRequired。version 必须是具体版本，审批不绑定 `latest`。未知描述和 schema 是不可信数据，渲染需转义，不执行里面的 URL/命令。

工具请求接受完整 JSON `arguments`；保持值类型。客户端目前不声称实现了完整 JSON Schema 2020-12 验证器，Composio 对工具参数作最终验证。不能把 catalogHash 当作“参数一定正确”的证明。无论 tags 是否自称 read_only，当前均走显式审批。联网读取不放在页面 render 或自动 refresh 中，提供明确的“加载目录／刷新账户”动作。

## 明确动作与冻结审批

`connectors.action.preview` 和 `connectors.action.plan` 都接受：

```json
{
  "project":"/registered/project",
  "action":"tool",
  "toolSlug":"REAL_TOOL_SLUG_FROM_CATALOG",
  "version":"CONCRETE_VERSION_FROM_CATALOG",
  "catalogHash":"REVIEWED_CATALOG_HASH",
  "connectedAccountId":"SELECTED_ACCOUNT_ID",
  "arguments":{"typed":"values"}
}
```

preview 会读取工具及账户 metadata，返回 `{request,requestHash,dryRun:true,externalActionExecuted:false,saved:false}`，不会调用工具、建立审批或保存 run。plan 读取并验证当前 schema/账户后原子保存 action/run/approval，返回 action 与 approval。实际外部动作尚未执行。工具 `noAuth:true` 时省略 connectedAccountId，不能伪造账户。任何状态或字段不匹配都会要求重新审阅。

其它 action 参数：

- `connect`：`{project,action:"connect",authConfigId,toolkit}`，使用当前已启用 auth config 的 link endpoint。返回认证链接不等于连接成功；仅用户点击后打开；随后明确刷新账户确认 ACTIVE。
- `disable/enable/disconnect/revoke/reauthenticate`：`{project,action,connectedAccountId}`。其中 disconnect 删除远端 connected account，revoke 请求撤销提供方授权；应清楚展示具体对象与影响。

使用已有 `approvals.decide {id,snapshotHash,decision:"approve"|"reject"}`。review 展示 provider、具体账户/toolkit、版本/schema、完整参数、目标项目及外部影响。CLI/账户 generation、账户身份/状态、tool schema 变化都不得静默替换。一次审批只能领取一次，网络错误与服务端未知结果不自动重试。

详情 `connectors.action.get {project,id}` 与摘要 `connectors.action.list {project}` 纯本地。action状态 pending_approval/executing_or_uncertain/completed/failed/rejected/needs_review/acknowledged。需要核对的结果会在现有 Inbox 中保留。`connectors.action.resolve {project,id,requestHash,decision:"acknowledge_no_retry"}` 只确认已看过不确定结果；保留 outcomeUnknown，不断言没发生，不重新执行，也不推进旧运行。

工具结果含 providerSuccessful、logId、durationMs；网络错误含 httpStatus/outcomeUnknown/retried:false。链接结果只显示 connectionVerified:false，丢弃独立 link_token。输出与错误当作数据，不自动开启下一动作。

## 工作流步骤

```json
{"tool":"connector.call","arguments":{"toolSlug":"CATALOG_SLUG","version":"CONCRETE_VERSION","catalogHash":"HASH","connectedAccountId":"ACCOUNT","arguments":{}}}
```

保存不联网；Dry Run 完全 stub，不读取 secret 或目录、不调用外部工具。真实运行到该步时获取当前 metadata 并冻结独立审批。批准后才执行；未知结果让 run/approval 进入 needs_review，子工作流也不得继续。普通工作流定义不能传入预制 request 或绕过冻结逻辑。当前尚无免审外部 read input、任意代理请求或整个目录默认放行。

## English

The optional connector stores an explicitly supplied project key in macOS Keychain, browses paginated tool/account metadata and freezes each external action for one-shot approval. Catalog discovery is not execution verification. Dry runs never call tools, workflow steps retain their own approvals, and uncertain outcomes stay visible until acknowledged without retry. Account secrets and raw auth configuration credentials are discarded. Real provider/account acceptance remains separate from fixtures.
