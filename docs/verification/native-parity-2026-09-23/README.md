# 原生迁移阶段验证 · 2026-09-23

**这是局部修复证据，不是全量 Swift 迁移验收。** 所有 Velo 截图来自本机运行的 Tauri / WKWebView；数字来自隔离的 `--visual-test` 快照，没有启动供应商采集或使用真实账户。

## 基准

- Swift 固定提交：`vinzdg/codenotch@117a38b8edae2ebd0944bc86b8760c6381685345`。
- 运行与该提交一致的 [官方 Package CI 产物](https://github.com/vinzdg/codenotch/actions/runs/35702125348)，使用 `CODENOTCH_DEMO=1`；为隔离配置，仅更改测试副本 bundle 标识、显示名称、更新元数据并做临时签名，未修改其 Swift 实现。
- `swift-reference-left-three.png` 是官方 Demo 原版。Velo 的账户、读数与其不同，不能把这两张图当作相同 fixture 的像素差异测试。

## 本轮实现和验证

| 项目 | 结果 |
| --- | --- |
| 六账户长条截断 | 窗口按内容、屏幕和缩放重新计算；拥挤时先减账户间距；两端弧线及手柄完整 |
| 四边形状 | 使用同一 `SideNotchShape` 圆弧路径与坐标变换，原生四边显示检查通过 |
| 收起形状 | 同一路径收缩到 `26 × 210` 设计像素；采用 `response=.42, damping=.78` 弹簧，原生收起截图及 WebKit 快速反向测试通过 |
| 图标 | 内置黑色模板 SVG 改为继承前景色，保留路径；原生六个内置标记显示正常 |
| 设置窗口 | 860×600、原生窗口按钮、暗色透明标题栏；原生截图检查通过 |
| 账户页 | 行内静音、单一连接开关、顺序；实际 IPC 关闭三个账户，原生圆环数量由六变三 |
| 应用入口 | Dock / 菜单栏 / 隐藏偏好，保留升级前托盘选择；原生菜单“设置”和 ⌘, 关闭后重开验证通过 |
| macOS 层级 | 恢复 statusBar level、跨 Space / 全屏辅助窗口标记；跨 Space / 真正全屏原生交互仍待验证 |
| 强调色 | 恢复原版 11 色、系统强调色读取、控件/低用量圆环/卡片联动；WebKit 测试通过 |
| 自动化 | Rust 主程序 197 通过、3 忽略；helper 1 通过；Node 13 通过；Chromium 22、WebKit 22 通过，单 worker |

CI 新增 WebKit，防止仅在 Chromium 通过而 WKWebView 显示缺失；远端执行结果另记录。

## 原生截图

![账户设置，隔离测试数据](settings-accounts.png)

![右侧六账户](notch-six-accounts.png)

![左侧六账户](notch-left-six.png)

![顶部六账户](notch-top-six.png)

![底部六账户](notch-bottom-six.png)

![收起形状](notch-folded.png)

## 仍未完成

- 系统强调色运行中改变时的完整同步、Liquid Glass、硬件刘海和多屏实例。
- 内容/手柄/卡片的全部 Swift 动画参数、曲线命中区域、拖动与窗口聚焦的逐交互原生对照。
- 所有设置页、登录/退出、清除缓存及正在执行请求的取消/隔离。账户连接开关本轮统一了读取启停和圆环成员，**尚不能视作 Swift 完整 sign-out**。
- DeepSeek / Qianwen 等网页登录、本地 runtime 指标及中转、全部活动生命周期与真实账户验证。
- Windows 实机视觉与交互；构建 CI 不等同于实机验收。

原生控制工具可以操作设置和应用菜单，但对不可聚焦的 Tauri 侧栏坐标点击报 `noWindowsAvailable`，因此本轮不把原生圆环 hover/click 标为通过。WebKit 的对应浏览器交互已通过。没有用关闭 Gatekeeper、修改真实账号或伪造原生操作来代替验证。
