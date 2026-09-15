# ADR 0010: Local TypeScript and Python SDKs / 本地客户端 SDK

- Status: Accepted
- Date: 2026-09-13
- Scope: Public SDK API, helper process lifecycle, error and cancellation contracts

## Context / 背景

Walrus Memory 提供可安装 SDK、批量写入和自动注入适配器，而 Vela 仅有 CLI/RPC。新增 SDK 是完整能力覆盖的一步，不能把本地客户端直接标记为远端加密记忆、owner/delegate 或所有 middleware 已完成。归档格式沿用 [ADR 0007](0007-portable-memory-archives.md)。

## Decision / 决策

增加独立包 `sdk/typescript`（`@vela-engineering/sdk`，Node.js 22+，async）和 `sdk/python`（`vela-engineering`，Python 3.10+，sync/async）。两者只有语言标准库运行时依赖，不纳入 macOS app，不改变 Swift/Core 的部署运行时。开发期 TypeScript 编译和 Python 打包工具不随桌面客户端分发。

用户显式选择 helper 绝对路径、store 绝对路径及可选默认 project；本版本只接受 `transport.type = local`。namespace/owner 不是任意未校验字符串，不在 SDK 私自实现身份模型。未来远端 transport 需要独立版本/适配器和认证合同，不能悄悄将本地路径变成网络目的地。

公开入口限于项目列举/登记、Memory 列表/Recall、候选写入、候选批量写入和 archive export/validate/import。[ADR 0013](0013-local-semantic-recall.md) 后续增加显式 semantic index/status 和 typed Recall 参数，仍使用同一受限传输。没有任意 RPC 方法、shell、文件或 workflow 执行公共 API。SDK 不是安全沙箱或 ACL；同一本机进程仍具有其 OS 与 helper/store 权限。

SDK 使用受限 JSONL，启动参数固定为 `rpc --no-watch --no-schedule --home ...`，环境中关闭 discovery。之所以新增 `--no-schedule`，是因为旧 `--no-watch` 仅关闭会话 watcher，RPC 的 Scheduler 仍可能执行既有自动化。此独立开关保持普通 RPC 默认行为，外部 SDK 连接不隐式开启自动运行。

TypeScript 同时最多 32 个待响应请求，按 ID 接收乱序响应。Python 同步连接串行处理；async 使用标准库 worker 将阻塞过程移出 event loop，并限制 32 个排队/进行中调用。两者逐帧限制 2 MiB、整连接 stderr 限制 64 KiB，不在异常泄露原始输出、核心错误消息或凭据。

错误包含稳定 `code`、请求 ID 和 `effectsUnknown` / `effects_unknown`。开始发送的副作用请求在超时、断连、取消或不明确 core error 后保守标记未知；不重连、不重发、不宣称 core 已取消或回滚。关闭过程向自有进程组发 TERM，最多等待 0.5 秒后用 KILL 清理残留；等待 helper 退出并关闭资源。取消单个请求关闭整个共享连接，其他 pending 请求也失败，这一行为在 SDK README 明示。 Python 的取消回执由本次调用独立记录，已发送状态与取消快照在同一锁内核对；未发送的排队调用不借用其他正在执行调用的 ID 或副作用标志。受影响的其他请求各自保留正确的未知副作用异常。

普通 candidate bulk 预验证全部 1–100 个输入后顺序发送，不冒充原子事务。首个错误停止后续项，返回已完成记录、失败位置、未尝试数量、skipped=0、当前请求的未知副作用标记。异步批量取消也保留已完成记录。需要本地整包原子写入时使用 Core 的校验归档导入。

归档在不同语言间只传递，不重新签封或替换摘要，防止客户端把损坏的包“修好”。Memory 的原文、状态及归档候选边界由 Core 实施，SDK 不做额外自动激活。

## Alternatives / 取舍

- 每个调用启动 CLI 能简化传输，但反复启动影响延迟，也无法提供稳定的多请求资源生命周期；选择受限长连接。
- 新 HTTP 服务可跨语言，但会增加常驻网络边界、身份/端口与部署负担；本阶段先复用既有 helper，后续远端 transport 不在本协议上猜测。
- 将官方 Walrus SDK 嵌入 Mac app 可加快部分远端接入，但会同时带入账户、Sui/SEAL 和 Node/Python 运行时；本地 SDK 独立分发，远端适配器另行核对兼容发布版本。
- Python 原生 asyncio 另写一份协议循环会复制安全状态机；选择同一同步传输配合线程与 async 取消桥接，并明确连接级取消边界。

## Verification / 验证

真实 helper 测试覆盖安装包调用、候选写入、批量写入、重启恢复、归档跨 store 恢复、Recall 隔离与参数拒绝。独立 fake helper 只用于测试故障边界：乱序、坏 JSON、stdout/stderr 超限、写入超时/取消、批次中途失败。故障 fixture 的成功不当作产品数据能力已完成。打包后须从临时安装目录重新执行真实 helper 与边界测试，确认运行时不借用源码目录。

子进程生命周期实现依据 [Node child_process](https://nodejs.org/api/child_process.html)、[Python subprocess](https://docs.python.org/3/library/subprocess.html) 和 [asyncio subprocess/cancellation](https://docs.python.org/3/library/asyncio-subprocess.html) 的公开合同。轮次验收分别记录源码测试与打包后测试，保留首次失败原因，不把本机通过扩称所有最低版本平台已测试。

## English summary

Vela adds independently packaged local TypeScript and Python clients using the explicitly selected Swift helper and store, without adding a runtime to the Mac app. Both disable discovery, watchers, and scheduling. APIs are bounded and typed; memory writes remain candidates. Timeout/cancellation closes the connection and owned process group but never proves rollback or retries a mutation. Bulk operations stop with exact partial-result metadata. The SDK is not an ACL and does not imply remote ownership, encrypted storage, semantic providers, or middleware parity. Those remain explicit follow-on capabilities.
