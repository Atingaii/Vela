# ADR 0016：显式连接的外部工具与冻结审批

- 状态：Accepted；真实服务与账户验收单独记录
- 日期：2026-09-13
- 范围：Composio REST v3.1、Keychain、工具目录及外部操作

三产品完整覆盖包括外部工具和身份。继续沿用 Swift/Foundation，增加可选的薄 REST adapter；不把 Python/Node 服务加入默认桌面运行时，也不把“能展示工具名”算作已成功执行全部目录。依据 [Composio API](https://docs.composio.dev/reference)、[工具版本与执行](https://docs.composio.dev/reference/api-reference/tools/postToolsExecuteByToolSlug)、[账户连接](https://docs.composio.dev/reference/api-reference/connected-accounts)固定当前合同。API base 是 `https://backend.composio.dev/api/v3.1`。

项目 API key 由用户显式输入，存储在当前 store 派生 service 与随机 generation 的 macOS Keychain 项。SQLite 只保存 generation 和用户标识。轮换先创建新 key、CAS 更新 metadata，再删除旧 key，避免崩溃让待批动作突然使用另一账户的 key。状态读取不主动读 key 或联网。默认不连接，不读取其他应用的凭据。

HTTP 使用限时、限响应大小、无 cookie/cache 的 ephemeral URLSession，禁止重定向、任意 URL 与 proxy 调用。GET 失败保留错误状态，写操作无自动重试；网络中断或服务端错误明确保存 outcomeUnknown，不能宣称外部动作没有发生。服务器返回的原始账户 credential/state 字段丢弃，不进入 UI/SQLite/日志。

目录分页保留 toolkit/tool slug、具体 version、原始参数 schema、目录 hash 与来源时间。账户绑定检查选定 user_id、toolkit、active/disabled 状态；工具 metadata 不赋予默认免审执行权限。外部动作先生成精确待批请求，冻结 credential generation、账户身份、tool version/schema、完整参数和目标项目，沿用一次性审批 CAS。执行前核对冻结身份和当前连接，变化则要求重新审阅。结果中的文本/URL仅是数据，不自动开链接、授权、发信或继续调工具。

托管 OAuth 采用当前 link endpoint；旧 create-account 托管 OAuth 路线已有官方停用日期，不使用旧示例绕行。认证链接需用户明确打开，连接成功需要随后通过账户状态确认，不能由“返回了URL”推断。真实第三方验证使用专用测试账户，实际消息或内容写入须有明确授权；fixture 与真实提供方分别记证据。此 ADR 不宣称已覆盖目录中所有工具、平台、权限模式或错误条件。

## 独立复核后的错误与凭据边界

工具响应 `successful:false` 不能证明无部分副作用，统一进入 `needs_review`，保留一次执行证据而不继续依赖节点。除明确认证/权限拒绝外，写请求的 HTTP 错误也保留不确定性；服务端错误正文不进入用户数据。

所有已认证响应在缓存/审批/运行保存前递归检查本次精确 Keychain key；若回显则拒绝该响应，提交后的写入标记结果未知，不改写 schema 来掩盖问题。普通结果中的嵌套凭据字段显式脱敏并返回数量。HTTP key 只允许可见 ASCII，按 Unicode scalar 检查，避免 Swift 将 CRLF 视为单个 Character 导致逐字符 contains 检查漏过。URLProtocol 定点测试覆盖固定端点、query 编码、请求/响应大小、失败状态和超时；这些是隔离传输测试，不能替代真实账户授权与动作验证。

## English

Optional Composio access uses a bounded native REST adapter and generation-bound Keychain credentials. Catalog snapshots and approvals pin the account, tool version, schema and arguments. Unknown external outcomes are never retried automatically. Account credentials returned by the provider are discarded, and authentication links are only user-opened. Real-account evidence remains distinct from fixtures and from catalog discovery.
