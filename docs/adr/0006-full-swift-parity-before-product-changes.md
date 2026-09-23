# ADR 0006：先迁移 Swift 主线行为，再整理设置与扩展

状态：采纳（实现进行中）

2026-09-23：当前跨端实施范围由 [ADR 0009](0009-macos-first-delivery.md) 取代，先完成 macOS；下文保留原决定背景，其余迁移与技术约束继续适用。

## 背景

Codenotch 的 Tauri 分支只有部分供应商和桌面交互。仅复用该分支不能满足“保留全部现有逻辑”的要求。基准固定为 `vinzdg/codenotch@117a38b8edae2ebd0944bc86b8760c6381685345` 的 Swift 主线；具体差异见 [迁移清单](../migration-parity.md)。

## 决策

继续使用已确认的 Tauri 2 / Rust / WebView 路线。Swift 的供应商语义、状态转换与设置能力逐项移植，不在迁移中删除功能。macOS 的系统适配使用原生 API，Windows 实现对应能力；不能因为名称或入口一致便声明行为一致。

供应商由统一调度器安排，每账户保留独立的正在执行读取、缓存、退避和启停代次；不能让某账户无响应阻塞其它账户。调度间隔及 60 秒失效标记按固定 Swift UsageStore 迁移，同代次不重复创建卡住的读取，返回时再次检查账户代次。HTTP 禁止凭据重定向，响应体设置上限。第三方 CLI 凭据只读；Vela 自己收集的密钥存入 macOS Keychain / Windows Credential Manager，不写入配置 JSON。未知供应商不得回退到 Claude 的数据。

首版只做实现语言和平台适配转换，保持 Swift 主线的 UI、视觉效果、设置项和交互。必须先通过迁移核对，再实现新增第 1 项边缘插件机制；两项完成后暂停。依据用户最新要求，设置精简和新增第 2–4 项延后。此前的账本与 CLI 同步源码保留，但从首版设置入口撤下，不能混入原版一致性验收。ADR 0002 的设置精简决策暂缓。

## 验证边界

使用上游格式的离线样例验证百分比方向、缺失字段、重复记录、额度重置和限流。测试单线程，不对真实供应商做负载测试。平台构建、离线测试、真实账户验收分别记录，不能相互替代。

## 协议与资源来源

Phone Link 按固定提交的实际 Swift v3 实现迁移；该提交附带的协议说明仍是 v2，以源码及 v3 测试向量优先。使用 HKDF-SHA256 分离签名与加密密钥，AES-256-GCM 封装内容；配对仅在窗口打开期间有效。设备密钥遵循上述系统凭据库决策。

图标使用相同提交的 asset catalog 与 CGPoint 轮廓；转换脚本及 manifest 保留来源、校验和、坐标路径与 opticalScale。不能用相似品牌图标替代原版视觉验收。

## 前台窗口与收起

单窗口模式默认跟随前台窗口所在显示器；固定显示器保留为显式选择。每秒读取一次窗口几何，拖动时不抢占位置。macOS 使用 WindowServer 的窗口列表和 NSWorkspace，Windows 使用前台窗口矩形，不采集窗口标题、画面或内容。全屏检测沿用 Swift 的边界容差；macOS 允许菜单栏顶部留白，Windows 要求覆盖完整显示器，避免把任务栏内的最大化误判为全屏。硬件 safe-area、所有显示器实例及真实系统效果仍是后续迁移/验收项。

“保持展开”恢复为当前进程的临时 pin，独立于持久化的 Show 设置；它覆盖全屏收起。改变 Show 设置清除 pin，与 Swift 主线一致。

## 应用内网页登录会话

DeepSeek、QianwenAI 与 MiniMax 的网页回退沿用 Swift 的显式登录门：用户主动打开各供应商的应用内 WebView 后才建立签入状态，后台读取只在已签入且页面回到该站 HTTPS 原点时执行。macOS 14+ 使用每供应商独立的持久 `WKWebsiteDataStore` 标识，Windows 使用每供应商独立的 WebView2 数据目录；无法提供隔离存储的平台明确显示不可用，不退回共享浏览器 profile。外站窗口不授予 Tauri IPC 权限；请求在页面内完成，原始 token、Cookie 与响应正文不写入日志或配置，只有必要的数值读数和会话指纹摘要进入 Rust。退出仅清除对应供应商的数据存储；不会读取 Chrome 或 Safari 的会话。

## 本地运行时协议适配

Ollama 的显式中转和 LM Studio 的本地指标连接属于原版能力，继续在 Rust 进程内实现。HTTP 中转使用已有 Tokio 运行时上的 Hyper 处理报文与背压，WebSocket RPC 使用维护中的协议库，不自行实现网络帧解析。中转默认关闭，仅绑定 loopback；关闭或切换上游时取消该代次拥有的连接任务，旧响应不能写入新状态。只保留模型、时序、token 计数等指标，不记录提示词、生成正文或授权头。该适配不新增远程后端，也不改变用户可见的原版连接流程。

## Windows 进程证据适配

Swift 的活动识别依赖进程身份、出生时间、工作目录以及进程实际打开的会话文件。Windows 的工作目录与进程身份适配使用目标平台限定的 `sysinfo`，仅启用 `system` 功能，避免在产品中自行维护读取进程参数的 PEB 结构；读取失败保留不可用，不推断虚假活动。文件持有关系先采用只读 Restart Manager 文件占用查询，不调用关闭或重启进程的 API，不以目录更新时间替代。对应测试使用本次创建的子进程与临时文件，验证打开、关闭、退出和 PID 身份变化；没有 Windows 测试证据时不标记跨端完成。

## Windows 任务栏入口

原版 Dock / Menu Bar / Hidden 三种应用入口，在 Windows 分别映射为任务栏 / 托盘 / 隐藏。设置关闭时任务栏模式仍须留下能重新打开设置的入口，不能只保存偏好。采用一个由 Tauri 管理的最小化原生窗口作为任务栏入口；不为它启动额外 WebView，也不维护第二套 Win32 窗口过程。

锁定的 Tauri 2.11.5 将纯原生 `WindowBuilder` 与 `Manager::get_window` 放在 `unstable` 功能门内。仅 Windows 目标启用该功能以访问这两个 API，macOS 不变。选择它比额外创建 WebView 或自行维护 Win32 窗口生命周期更小；Tauri 升级时须重新检查该接口，并由 Windows CI 的真实原生 smoke 验证创建、最小化、设置显示及代理隐藏。编译成功不代表任务栏点击和系统视觉已完成验收。

## macOS 应用生命周期

固定 Swift `AppDelegate` 在正常启动时让同 bundle ID、启动时间严格更早的实例退出，由新实例接管；路径和版本不参与排序。macOS 的 Tauri single-instance 插件会先通知旧实例并直接退出新进程，因此此平台改在创建窗口前用 AppKit 执行原版顺序。自身 bundle ID 取自 `NSBundle.mainBundle`，新旧顺序由内核进程出生时间判断：`NSRunningApplication.launchDate` 对绕过 LaunchServices 直接运行包内程序的实例可能为空，不能因此静默跳过接管。终止请求另须核对同用户、同可执行文件名、PID 与进程出生时间，并在请求前重核身份；无法核实时跳过，隔离 smoke/视觉/升级验证均不参与。Windows 保留现有单实例行为，此处不将 Windows 入口视为与 macOS 新实例接管同一语义。唤醒后的全量刷新由 `NSWorkspace.didWakeNotification` 触发，应用退出时移除该 observer。

Windows 的唤醒刷新由系统 `RegisterSuspendResumeNotification` 的回调触发，仅处理必经的 `PBT_APMRESUMEAUTOMATIC`，避免随后可能到达的 `PBT_APMRESUMESUSPEND` 导致重复读取；退出时注销。通知回调只排队现有刷新，不在系统电源回调线程执行账户读取。
