# 账户生命周期后续差异审计（只读）

对照基准：固定 Swift 源码 `codenotch@117a38b8edae2ebd0944bc86b8760c6381685345`；Rust 为本工作树当前源码。本文只列源码已能确认的行为差异，未使用真实账户、凭据、构建或运行态验证。下列能力均**尚未完成迁移**。

## 1. 关闭账户没有执行源版的 sign-out 生命周期

- Swift `Sources/Settings/SettingsView.swift:2161-2183`：非本地模型开关关闭时先调用 `signOut(provider.id)`，再保存断开状态；`Sources/Model/UsageStore.swift:521-529` 的 `signOut` 会取消刷新、清除读数与归档，并调用 provider 的 `signOut()`。MiniMax 的 app 自有 API key / Cookie 删除见 `Sources/Providers/MiniMaxProvider.swift:102-107`；Web 会话只清所属站点资料，见 `Sources/Providers/WebSessionProvider.swift:414-438`。
- Rust `src-tauri/ui/settings.html:1317-1327` 只调用 `set_provider_enabled`；`src-tauri/src/providers.rs:237-273` 只修改配置、在开启时要求刷新并广播；`src-tauri/src/secrets.rs:47-60` 虽可通过空密钥删除 Vela 自有密钥，开关路径没有调用。当前也没有等价的 provider sign-out 分发。
- **最小修复边界**：在非本地模型的关闭路径增加明确的账户退出动作，复用同一原子化生命周期入口来取消刷新、忘记读数，并且仅对 **Vela 自有** MiniMax 等凭据/网页会话做 provider 级清理。第三方 Claude/Codex/Cursor CLI 凭据仍归原应用所有，不删除。Windows 上无 WKWebView 时只实现该平台实际拥有的会话清理，不模拟网页退出。测试开关关闭后自有密钥被删、其他 provider 密钥不受影响。

## 2. 关闭后及重启后仍保留、返回旧读数

- Swift `Sources/Model/UsageStore.swift:50-64` 在断开时删除 `snapshots`、`lastGood` 并重写 archive；初始重建时也过滤断开账户，见 `Sources/Model/UsageStore.swift:200-211`。
- Rust `src-tauri/src/providers.rs:117-132` 从 `providers-usage.json` 不分启停地恢复旧快照；`src-tauri/src/providers.rs:151-161,182-216` 对关闭账户仍返回该快照；`src-tauri/src/providers.rs:251-273` 的关闭动作没有删除内存或磁盘读数。Claude 多账户轮询跳过关闭账户，却仍在 `src-tauri/src/usage.rs:863-866` 用完整 `order` 和仍在 `accounts` 中的读数聚合；聚合实际逐账户读取见 `src-tauri/src/usage.rs:679-712`。
- **最小修复边界**：关闭时按账户 ID 清理 provider snapshot、聚合状态与对应持久化项；启动恢复和所有返回路径按已关闭 ID 过滤。重新开启先展示源版 placeholder，再获取新读数，不把已注销账户的旧数值恢复出来。测试关闭即查、重启后查、再开启未刷新前查，覆盖两 Claude 账户只关闭其一。

## 3. 已启动的读取缺少跨“关→开”的失效代次

- Swift `Sources/Model/UsageStore.swift:496-499` 取消时递增每账户 generation；`Sources/Model/UsageStore.swift:629-663` 在读取前后都检查断开、任务取消及 generation，所以旧请求即便在重新连接后返回，也不能覆盖新账户状态。
- Rust catalog 读取在前后只检查当前 `enabled`，见 `src-tauri/src/providers.rs:358-420`；如果读取中发生关→开，后检查重新为真，旧结果仍会写入缓存，见 `src-tauri/src/providers.rs:438-445`。Codex 轮询仅在读取前检查，之后直接持久化/广播，见 `src-tauri/src/codex.rs:928-935,888-893`；Antigravity CLI 同样在读取前检查后直接持久化/广播，见 `src-tauri/src/antigravity.rs:844-846,862-890`。`src-tauri/src/refresh.rs:12-30` 的 generation 只表示 Phone Link 完成次数，不是读取结果的有效性代次。
- **最小修复边界**：给每个账户维护连接代次，关闭/退出/账户地址变更时递增并清除排队请求；各读取路径在开始时捕获代次，在更新内存、磁盘和发事件前同时验证代次及启停状态。同步系统调用不必强制中断，但旧结果必须丢弃。用可控阻塞读取验证“读取中关闭”和“读取中关闭再开启”两种竞态。

## 4. 刷新一个 Claude 账户仍会读取全部 Claude 账户

- Swift `Sources/Model/UsageStore.swift:434-445` 的 `refresh(providerID:)` 只启动指定 provider；注释明确避免消耗其他账户的速率预算，且同一账户已有任务会复用。
- Rust `src-tauri/src/providers.rs:163-167` 对任一 Claude profile 的请求调用无 ID 的 `usage::request_refresh()`；该函数仅设置全局布尔标记，见 `src-tauri/src/usage.rs:44-49`。唤醒后 `src-tauri/src/usage.rs:817-844` 遍历并 `poll_account` 所有启用的 Claude profile。
- **最小修复边界**：把“定时刷新所有账户”和“手动刷新指定账户”分成有账户 ID 的请求状态；手动刷新只触发目标账户，已有请求合并，保留各账户退避规则。测试两个启用的 Claude profile 对其中一个执行 `refresh_ring`，确认仅该账户进入读取，定时刷新仍覆盖两者。

建议下一批按 **失效代次 → 关闭时清理与退出 → Claude 定向刷新** 落地：先保证旧结果不会重新写回，再验证归档/凭据清理；各项完成后才在全量迁移验收中标记。源码静态审计不能替代 macOS/Windows 实机及真实账户验收。
