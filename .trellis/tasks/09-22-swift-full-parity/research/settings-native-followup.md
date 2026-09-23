# 设置页第二批原生对照（2026-09-23，进行中）

## 固定基准与取证方式

- Swift 基准仍为 `vinzdg/codenotch@117a38b8edae2ebd0944bc86b8760c6381685345` 的官方 Package CI 产物。此前刘海截图用 `CODENOTCH_DEMO=1`；该模式不构建 `SettingsWindowController`，因此本批设置页截图改用同一产物的正常模式。
- 原版正常模式使用隔离 bundle/配置副本。初次启动时默认启用 Claude/Codex，曾短暂只读访问本机账户；随后在参考副本关闭供应商再截取外观、通知、通用页。三个 `swift-settings-*.jpg` 截图时账户数为 0，图片不含真实账户数据，保存在 `docs/verification/native-parity-2026-09-23/`。
- Velo 最终三页截图使用最新源码构建的独立 `--visual-test` root10，不启动供应商采集；它们是 Tauri/WKWebView 原生窗口，不是静态 HTML mock。Swift 三图尺寸为 860×600 px，Velo 三图为 860×601 px（窗口截图外框/取整的 1 px 差异，未裁改；源码 `inner_size` 仍为 860×600）。原版账户为 0，Velo 显示隔离快照，数据不同；不得宣称截图达到像素一致。

## 本次可复核结果

- 外观页可见原生标题栏、侧栏、分组行、开关与分段控件。macOS 符号在应用运行时由 SF Symbols 转为 PNG data URL，`tauri::image::Image::from_bytes` 验证解码、尺寸和可见 alpha；AppKit 渲染通过 `run_on_main_thread` 执行。Rust 单测只用合成 PNG，不从测试 worker 调用 AppKit。真正符号的原生窗口呈现在 Velo 外观截图中，尚无独立像素/无障碍判定。
- 在先前隔离 root08 运行中，通过真实 IPC 将「重置日期」改为「剩余时间」，关闭窗口、⌘, 重开后仍选中，再恢复原值。该操作确认这一个偏好的保存与重载路径；其他设置项须逐项验证。
- 自动更新偏好对旧配置默认关闭，保存成功后才改变内存状态；未配置签名 key/HTTPS feed 时拒绝开启。手动检查只检查；后台下载完成后按许可代次与当前开关复核，再进入安装调用。Tauri updater 2.12.0 本地实现的 `download()` 在返回前验签，`install()` 是单独的平台安装边界。关闭开关与安装交接共用 gate；一旦平台安装已开始，就无法承诺撤销。错误日志只记类别，避免写入签名或端点细节。
- 刘海高度预算继续按固定 Swift 公式在 Rust 中计算，纳入 plan、token、reset 标志；探针修复祖先 CSS `zoom` 对量测的干扰后，strict budget equality 通过。`fit_heights` 的 CSS 合成测量不作为这次高度预算的验收依据。
- 设置页滚动条占约 12 pt 时会挤压内容；现已补偿，使通用（无 gutter）与通知（有 gutter）的内容右边距同为 20 pt。跨页断言在 Chromium、WebKit 均通过，最新 root10 原生三页截图已现场查看并保存。通知页仍有局部纵向约 7 pt 差异及文案差异，不能称为像素一致。
- 本批本地 `/tmp/velo-final-parity-rust.log`：主程序 204 通过、3 忽略；helper 1 通过。Node 13 通过；Chromium 28/28 通过，包括通知页右对齐、两段说明、试听 IPC 与跨页 gutter 边距断言；WebKit 28/28 通过。上批 Rust 197、Chromium 22、WebKit 22 属历史记录，不与本批计数相加。最新源码原生构建通过；此处记录本地结果，本提交的远端 CI 按 GitHub Actions 对应 SHA 核对。

## 尚未达到迁移验收

- 外观页余下分组与动态系统强调色、通知页和通用页的逐项真实 IPC，仍待后续取证。三页原生截图验证主要版式，并未完成全部交互、文案及无障碍逐项对照。
- Sparkle 的周期检查及安装时机尚未迁移完整；签名 feed 仍未配置，没有真实网络更新、签名下载或安装验证。当前更新控件及策略测试不能代替分发可用性。
- Liquid Glass、硬件刘海、多屏、完整 sign-out/在途请求处理、网页登录、token/reset 卡片 UI、Windows 实机与真实账户，仍在全量迁移待办中。

主证据与图片链接见 `docs/verification/native-parity-2026-09-23/README.md`。本研究记录不关闭或归档全量任务。
