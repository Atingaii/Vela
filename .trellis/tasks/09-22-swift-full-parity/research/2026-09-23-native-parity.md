# 原生迁移复盘（进行中）

基准：vinzdg/codenotch `117a38b8edae2ebd0944bc86b8760c6381685345`。本轮验证 HEAD 仍相同；参考源码位于 `~/.cache/velo-reference/codenotch`，保留作为可复用迁移输入。

## 根因与过去验收的缺口

- 固定 650 点窗口沿用旧五账户假设，而 CSS 已迁入 Swift 的更大间距。旧 Rust 测试还按 14 点间距计算，验证对象与运行页面不一致。
- Chromium 测试使用两账户和人工 SVG，没有验证 WKWebView 六账户、两端弧线、手柄与真实内置图标。
- 400 ms 安装 smoke 只验证 HTML/IPC 启动，没有证明透明背景、原生标题栏或完整交互。
- 两个平台都使用 decorations(false)，删掉 macOS traffic lights；遗漏 transparent 与 Swift surface() 的 Regular 激活步骤。
- 阶段 CI 及成功安装不能代表全量迁移；全量任务不归档，剩余项不能标完成。

## 对照实现

- NotchLayout bodyLength/shapeLength/slack/tooltipDepth，NotchViewModel cellSpacing/panelSize：动态尺寸，拥挤先减间距，tooltip 和 notch 缩放独立。
- SideNotchShape canonicalPath：完整圆弧路径与四边变换，替换 CSS 拼接轮廓。
- SettingsWindowController show/surface/layoutTrafficLights：860×600、透明暗色窗口、原生标题栏、按钮中心 26/48.5/71，header 52。
- SettingsView SettingsSection/SettingsSidebarRow：Accounts 子页折叠持久化，Phone 为顶层。上游禁止 sidebar toggle，不额外添加。
- SettingsButtonStyles：capsule、12pt medium、白色 8%/14%/20% 状态。

## 隔离验收

`velo --visual-test <新建空目录>` 使用独立设置、六个 synthetic UsageSnapshot、真实 Tauri 窗口和 glyph 管线，不启动供应商、凭据读取或轮询。区别于 smoke：不自动退出，不自动给出成功结论；用于原生交互和截图。

## 未完成

Liquid Glass、硬件刘海、多屏实例、原生窗口层级、折叠形状动画；DeepSeek pricing、本地 runtime/relay、网页登录、完整 session 生命周期和全部设置项；原生与真实账户验收。后续证据另记。

## 后续本轮修复与证据

- 找到与固定 SHA 精确一致的 Package CI 产物（run 35702125348），以官方 `CODENOTCH_DEMO=1` 运行，保留真实 Swift 截图。release v1.16.0 的 tag 对应更早提交，未将它误作本轮基准。
- WebKit 模板图标实际缺失：模板 SVG 的黑色 fill 改为 currentColor，路径不变；PNG 保留 alpha mask。六内置标记原生截图通过。
- 按 AppKit 实测的百分数字体 14.221073pt / 17pt 行高恢复 cellExtent。
- Accounts 原版是单一连接开关和行内 bell；移除此前自行增加的第二个读取开关与长篇 hook 行。hook 后端命令保留，完整生命周期仍需按 Swift 迁移。连接偏好与圆环顺序一次原子保存，失败不更新 UI；尚未移植完整 signOut 清缓存及取消 in-flight 的语义。
- AppPresence 恢复 Dock / menuBar / hidden、旧选择兼容、原生应用菜单 Settings 和 Cmd+,、RunEvent::Reopen。macOS 窗口 statusBar level / allSpaces / stationary / fullscreenAuxiliary 已接入。
- Fold 不再以裁切长矩形作为形状：共用 SideNotchShape 的 corner-first clamping，26×210 resting size，.42/.78 弹簧保留中途反向速度；减少动态效果直接落到目标。
- 两个回归当场修复：账户排序保存后 busy 未解除导致开关卡住；AppPresence 调用 drawSeg 传 boolean 与旧数组参数不兼容导致保存报错。
- 本轮原生证据与未通过项见 `docs/verification/native-parity-2026-09-23/README.md`。全量任务维持 in_progress。

- 与官方原版运行截图对比后发现低用量固定绿与系统强调色默认行为不一致；按 AccentColorChoice 恢复全部 11 色、读取 NSColor.controlAccentColor（sRGB），设置和低用量圆环/详情共用颜色；保留告警状态颜色。
