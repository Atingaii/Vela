# 换边与折叠热区复核

固定源：`vinzdg/codenotch@117a38b8edae2ebd0944bc86b8760c6381685345`。Root 负责此批跨原生窗口/WebView 的实现；此前 Sol High 代理提供只读 API 和遗漏审计。新分级协议要求后续 Sol/Luna max，本次既有会话不能原地重配。

## 发现与修复

- `Sources/Notch/NotchWindowController.swift:961–1021`：原版先以 `NSAnimationContext` 将整窗 alpha 用 0.16 秒降到 0，按最新变更序号换边并折叠落位、恢复 alpha，原本展开时延后 0.05 秒展开。此前 Tauri 保存边缘后直接定位，缺少完整流程。
- 新 `edge_transition.rs` 为每个窗口保存已呈现边缘、等待目标、变更序号和淡出/落位阶段。普通尺寸、显示器和内容更新在淡出期间不能提前换边；旧淡出、旧页面应答、旧恢复定时器不能覆盖新操作。首次放置无需动画。
- macOS 对原生 `NSWindow` 做动画，覆盖 WKWebView 下的原生玻璃。Windows 使用同一时长的页面淡出。落位后 WebView 立即归零折叠弹簧、内容和手柄，经过两帧应答才恢复显示，再延后 50 ms 按原展开状态恢复。
- 700 ms 无应答恢复仅是防止窗口永久消失的故障保护，有独立日志；不能把进入故障保护认定为正常动效验收。
- `NotchViewModel.swift:659–675`：与硬件齐平的刘海 `wakeBand=0`，resting 宽高使用实际硬件。此前 DOM 命中代理始终 79×10 加约 34pt，漏掉两端、却侵入下方标题栏；现绑定硬件宽高，并将普通唤醒带保持为不随 sizeScale 改变的面板点数。
- 原版仅展开时测试手柄；新增 document 捕获的弧线入口现在也禁止折叠或换边中操作。

## 验证边界

新增 Rust 回归覆盖布局刷新等待、快速反向、旧到达/恢复拒绝和逐窗隔离。新增浏览器回归覆盖淡出、精确折叠落位、原展开/折叠状态、旧回调、完整硬件命中与折叠手柄拒绝。

本批 Rust 379 + helper 1 通过、3 ignored（`/tmp/velo-parity-crossing-rust.log`）。浏览器和标准原生 app 重建仍由唯一测试代理串行执行，结果另记录。Mac 锁屏，尚不能核验整窗玻璃淡出、物理刘海命中、鼠标和多屏；编译与浏览器通过不能替代这些原生验收。


本批最终标准 Tauri debug app 构建成功（`/tmp/velo-parity-crossing-native-build-final.log`），隔离 native smoke 成功：WebView/IPC/helper/wake_subscription=true，providers_started=false，0.1.1-preview.1，exit 0、无超时。报告已保存为 `docs/verification/native-parity-2026-09-23/macos-smoke-controls-edge-crossing.json`。该报告验证启动与订阅，不是锁屏期间的视觉/鼠标/实际睡眠恢复验收。
