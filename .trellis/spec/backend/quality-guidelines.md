# 后端验收

一次只启动一个 Cargo 构建/测试进程：

```sh
CARGO_BUILD_JOBS=1 cargo test --locked --workspace -- --test-threads=1
```

针对解析边界、缺失额度、账户隔离、限流持久化、原子写入失败添加有意义的测试。不得只测试实现本身。改动平台 API 必须通过 macOS/Windows CI；Linux 测试不证明 Keychain、Credential Manager、窗口和托盘行为。

直接调用 AppKit/Foundation API 时，须核对 Apple SDK 头的 `API_AVAILABLE` 与支持的最低系统版本。`objc2` 绑定能编译不代表运行系统存在对应 selector。优先使用固定 Swift 源的兼容调用；仅在需要新版能力时加版本门控。例：显示器 ID 使用 `deviceDescription["NSScreenNumber"]`，不得无条件调用仅 macOS 26 的 `NSScreen.CGDirectDisplayID`。原生 CI 保留 macOS 15 Intel 启动检查，不能只用最新 Apple Silicon runner 验证兼容性。

`docs/migration-parity.md` 记录全量差异，不将部分适配标成全量完成。迁移完成前不以 UI 精简为由删除能力。

安装包发布还需运行 `scripts/smoke-installed.mjs <安装后的主程序> <报告>`：只允许显式 `--smoke-test <空目录>`，跳过采集与账户发现，检查实际 WebView、IPC、可见设置窗口与 bundled helper。必须检查真实 DMG / NSIS 的安装产物；模拟 IPC 不可代替该 gate。公开品牌 Velo，但旧配置目录、系统凭据服务和 helper 标识依 ADR 0007 保留。

macOS 分发信任必须独立检查：`node scripts/assess-macos.mjs <app> <report.json>`。
`codesign --verify` 接受 ad-hoc 签名，直接启动二进制也不模拟下载后 Gatekeeper；二者均不能证明普通安装可用。默认检查还要求 Developer ID、`spctl --assess --type execute` 与 stapled 公证票据。仅明确标注未公证的预览发布可显式传 `--allow-unnotarized-preview`，保留完整报告和首次打开说明；异常/损坏签名不能例外放行。不得关闭系统保护或清除 quarantine 来伪造通过结果。

## 原生窗口状态锁与启动握手

### 1. 触发范围

修改侧栏 `WindowRuntime`、`get_ui_flags`、窗口缩放、材质或显隐时适用。Rust 编译和 mocked IPC 测试不能发现主线程自锁；须运行实际原生 smoke。

### 2. 接口

`get_ui_flags(app, window) -> UiFlags` 返回当前窗口的 `fullscreen`、`pinned` 及持久显隐配置。`native_notch::runtime(label)` 返回该窗口的 `Arc<Mutex<WindowRuntime>>`；`smoke_ready(app, window, ready)` 必须由实际设置 WebView 调用。

### 3. 契约

一次锁内复制所需字段，显式结束 guard 后再构造返回值、获取其它状态锁或调用 Tauri/AppKit。不得持状态锁等待主线程操作，也不得在原生调用完成后用旧值覆盖更晚的窗口状态；需要回写时复核对应窗口和代次。

### 4. 失败处理

| 条件 | 要求 |
| --- | --- |
| 设置 WebView/IPC 在截止前未完成 | 安装检查失败，保留报告与退出状态 |
| 主线程卡住 | 对自有隔离进程采集调用栈，不直接归因为锁屏或网络 |
| 调用后窗口代次变化 | 丢弃旧操作的回写 |
| 原生返回失败 | 保留可恢复状态，不伪造成功 |

### 5. 场景

正常：设置与侧栏同时读取状态、尺寸变化仍可响应。基础：fresh `--smoke-test` 能完成真实 IPC 并退出。错误：struct 两个字段分别获取同一个 mutex，首个临时 guard 保留到整句结束，导致第二个 lock 自锁。

### 6. 检查

状态读取回归须有超时，避免测试本身无限挂起。安装 smoke 必须验证实际窗口与 IPC 握手，失败不能改用 mock 代替。自调用测试二进制的 `--exact` 名称必须包含真实模块路径，并用子进程标记断言目标分支确实执行，零项测试退出成功不是有效测试证据。

### 7. 错误与正确写法

```rust
// 错误：同一 struct 语句里连续获取同一个 mutex。
UiFlags { fullscreen: runtime.lock().unwrap().fullscreen,
          pinned: runtime.lock().unwrap().pinned, /* ... */ }

// 正确：复制状态后释放 guard，再执行返回构造或原生操作。
let (fullscreen, pinned) = {
    let state = runtime.lock().unwrap();
    (state.fullscreen, state.pinned)
};
```

同样审查 `if let`、tuple、链式表达式中临时 guard 的实际存活范围，不能只检查相邻源码行。
