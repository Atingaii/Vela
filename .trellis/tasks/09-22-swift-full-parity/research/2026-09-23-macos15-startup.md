# macOS 15 启动兼容性复核

基准：`vinzdg/codenotch@117a38b8edae2ebd0944bc86b8760c6381685345`。

## 已观察

- `5176a88` 的发行验证 `35826536749`：Intel macOS 15 在安装包构建及签名完整性通过后，安装后的真实进程约 1.8 秒以 `Rust cannot catch foreign exceptions` / SIGABRT 退出。
- `966de00` 的 CI `35831142333`：macOS 15.7.9 x64 的 debug app 同样 SIGABRT；定向系统崩溃采集没有找到匹配报告，不能声称已得到异常调用栈。
- Apple SDK `AppKit.framework/Headers/NSScreen.h` 明确声明 `CGDirectDisplayID API_AVAILABLE(macos(26.0))`。迁移代码 `refresh_display_ids` 无条件发送了这个 selector，而 objc2 的可编译绑定不执行系统版本检查。
- 固定 Swift 源 `Sources/Notch/NotchGeometry.swift` 的 `displayIdentifier` 从 `deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber` 取 ID，再生成 ColorSync UUID，不使用这个 macOS 26 新属性。

## 修复与验收边界

`native_notch.rs` 改回固定 Swift 的 deviceDescription 路径，保留显示器 UUID 与物理边界映射。缺少字段、类型不符或 null display ID 时跳过该项，继续现有未命名显示器处理。新增真实 Foundation dictionary / NSNumber 测试，覆盖合法值、缺失、错误类型与 0。

这是由 SDK 与源代码共同证实的兼容性错误；它是否是此次进程崩溃的唯一原因，仍以修复后 Intel macOS 15 原生启动结果判断。失败专用 LLDB 诊断保留第一次 Objective-C 抛出栈，其本身不等于未捕获的最终异常，也不把原失败转换成成功。完整视觉、鼠标、材质及真实账户验收不由这些启动检查替代。

官方 API 说明：[NSScreen deviceDescription](https://developer.apple.com/documentation/appkit/nsscreen/devicedescription)、[CGDirectDisplayID](https://developer.apple.com/documentation/appkit/nsscreen/cgdirectdisplayid-8ph5i)。

本机修复后验证：Rust 381 + helper 1 通过、3 ignored（`/tmp/velo-macos15-display-id-rust-final.log`），Node 32 通过（`/tmp/velo-macos15-final-node.log`）。新增 dictionary fixture 首次编译的 E0283 已修复，保留失败日志，不删除测试。LLDB 在本机连 `/bin/echo` 都因调试权限被拒绝，未调整系统权限；真实异常捕获正路径仍待 CI。该限制不影响直接运行隔离安装 smoke。
