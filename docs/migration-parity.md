# Codenotch 全量迁移核对表

**当前阶段只推进 macOS（Apple Silicon / Intel）。** Windows、Linux 仅保留[后续规划](platform-roadmap.md)，收到用户明确指示后才恢复；历史记录中的跨端待验不再是本阶段任务。Mac 的全量功能、UI、视觉和交互一致性标准不变，见 [ADR 0009](adr/0009-macos-first-delivery.md)。

基准：`vinzdg/codenotch@117a38b8edae2ebd0944bc86b8760c6381685345`，以 `Sources/App/AppDelegate.swift` 实际注册的能力、Swift 设置与交互为准。Windows 分支仅作为可复用代码来源，不再作为功能范围。

顺序：恢复基准全部功能、UI 和效果 → 验证一致性 → 完成第 1 项边缘插件机制 → 暂停。设置精简及新增第 2–4 项延后。源代码迁移完成与真实账号、操作系统实机验收分别记录；不能以入口存在代替实现。

| 范围 | 基准能力 | 状态 |
| --- | --- | --- |
| 原有供应商 | Claude、Codex、Cursor、Antigravity、GLM、Grok | 已有，核对中 |
| 独立账户 | Claude / Codex / Antigravity profile，各自圆环、活动与启停 | 启动固定 registry、账户代次和 Claude 活动已补实现与隔离测试；Antigravity 授权重试及完整原生验收继续核对 |
| 新供应商 | MiniMax、Devin、OpenCode、Command Code、GitHub Copilot、Kimi、Kiro、Ollama Cloud、Gemini API | 已移植解析与独立账户采集，60 秒超时不阻塞其他账户；Kiro 补全及限流回退已静态核对，CLI 非零退出的登录分类已修正并通过离线回归。真实账户字段与异常路径仍待实测 |
| 网页会话 | DeepSeek、MiniMax、QianwenAI 的显式登录、退出和用量解析 | 已实现隔离会话、origin/nonce 校验、登录退出代次、失败分类及定向刷新；退出/重开自有 profile 清理和离线回归通过。真实网页登录、切号与原生窗口待验收 |
| 本地运行时 | Ollama、LM Studio 模型发现、上下文、速度、活动、日用量；Ollama 显式中转 | relay、LM Studio WS/日志/账本、每模型独立活动与详情均已有实现及阶段测试；实际服务行为与原生详情未完成实机验收 |
| 自定义端点 | OpenAI 兼容地址、模型、凭据、图标、启停 | 添加/编辑/删除、模型探测、图标上传/取消、凭据读取与清除、启停、后台定时探测和失败回滚已接并通过离线回归；真实服务与原生交互待验。URL 的 userinfo 因凭据库边界仍拒绝，属明确偏离 |
| 用量展示 | 明确主窗口、周窗口、节奏、每日额度、重置格式、DeepSeek 价格规则 | 主周元数据、每日份额与价格边界已补并通过阶段测试；各供应商剩余语义继续核对 |
| 提醒 | 完成/等待展开与声音、额度阈值、用量重置、提供方静音；Limit/Reset 首次静默，Threshold 按源首次检测越界 | 三个原版状态机的首帧、静音和再次越界语义测试通过；完整原生声音及展开实测待补齐 |
| 位置与呈现 | 物理边缘、硬件刘海、多屏实例、跟随活动屏幕、全屏收起、保持展开、尺寸与材质 | 已补 fleet、UUID、逐窗预算与原生玻璃层；新的同场景截图、多屏和系统材质验收待解锁继续 |
| 应用入口 | Dock / 托盘显隐、菜单栏额度与时间、启动项、诊断、更新 | 已补原生菜单图形、启动项、What's New 与唤醒订阅；双 Mac 发行 DMG 安装 smoke、远端两架构及本机真实签名升级通过。实际睡眠恢复、登录启动和完整入口交互待原生验收 |
| 手机连接 | 原版 `PhoneLink.isAvailable=false`，生产不显示入口、不启动服务器；保留局域网配对与只读 v3 协议实现 | 已迁移协议、设备撤销和刷新等待；生产 gate 已按源补齐，隔离测试可进入；不宣称手机端已开放 |
| 状态持久化 | 每账户缓存、过期/鉴权/限流区分、停用即停止轮询 | 已补账户代次、关闭忘记读数和自有密钥、Claude 定向刷新、网页会话退出清理与旧请求竞态测试；真实账户、唤醒后刷新和平台生命周期仍待原生验收 |
| 设置整理 | 主选项与高级选项分层，精简布局不删除能力 | 本轮不做 |
| 已有新增 | 插件、账期用量、供应商切换、MCP/Skill | 迁移验收后仅完成插件；其余延后 |

证据入口：上游 README、`Sources/Providers`、`Sources/Sessions`、`Sources/Notch`、`Sources/PhoneLink`、`Sources/Settings/Preferences.swift` 及对应上游测试。

## 已补充的迁移实现

- 账户圆环支持原顺序、拖动/键盘排序及全部关闭；读取启停与显示独立。
- 设置恢复 860 × 600、220 侧栏、原分组；语言在外观页。保留重置格式、Codex 额外额度、周圆环虚线、尺寸、阈值以及通知细项，未进行产品精简。
- 供应商图形移植固定 Swift 资源与坐标，并应用原版 opticalScale；尚须对比原生截图。
- 原版用量节奏与 Claude 每日份额已移植，默认关闭。卡片内联提示沿用原版文案、橙色透支/灰色预留；每日份额替代主圆环，会话移到细环，周额度保留于卡片。周期取自供应商字段或上游明确规则（含日历月），未知周期不计算。
- Phone Link 以实际 `Sources/PhoneLink` 的 **v3** 为准：上游同提交协议文档仍描述 v2，不据此降级。配对关闭、过期或成功后失效；密钥在系统凭据库，JSON 只含设备元数据。

## 尚未通过的完成条件

- 网页真实会话、本地运行时完整行为、服务商剩余鉴权/限流/账户字段等数据语义。
- 多屏实例、物理刘海/全屏/显示材质、应用入口与完整活动隔离。
- 与固定 Swift 基准逐屏、逐交互对比；macOS 原生体验与真实账号验证。Windows/Linux 仅列后续规划。
- 第一阶段未验收，新增边缘插件阶段尚未开始验收；此前扩展代码不算交付。

## 当前检查记录（阶段检查，非全量验收）

2026-09-22：Linux Rust 167 通过、3 忽略；Node 8 通过；Playwright 9 通过（单 worker），包括设置、账户全关/排序、手机配对开关、刘海悬浮与图标替换。HTML 脚本检查通过。原生目标 CI 随本次提交重新运行，结果另记。

2026-09-22 后续阶段检查：Rust 170 通过、3 忽略；Node 10 通过；Playwright 11 通过，新增节奏开关、每日份额圆环与关闭恢复覆盖。`e4c059e` 的 macOS / Windows / browser CI 全部通过（[run 35726507080](https://github.com/Atingaii/Vela/actions/runs/35726507080)），该结果不包含其后的节奏改动。尚未完成原生逐屏视觉验收。

2026-09-22 手机刷新阶段检查：Rust 172 通过、3 忽略。`/api/v3/refresh` 等待已接受读取完成，最多 20 秒；失败/无变化也完成，退避中的账户不请求。服务器固定两个低优先级 worker；活动使用来源会话 ID，服务结束清除运行状态。剩余：完整账户/额度字段、登录后的真实手机互通，以及慢请求体的底层超时。

2026-09-22 窗口交互阶段检查：Rust 174 通过、3 忽略；Node 10 通过；Playwright 13 通过。默认跟随前台窗口、固定显示器选择、全屏收起/悬停唤醒及独立的临时“保持展开”已移植。Windows 判断排除普通任务栏内最大化与桌面；macOS 保留 Swift 的菜单栏留白容差，硬件 safe-area 与 visibleFrame 补充路径仍待完善。`f63cc23` 的三项 CI 已通过（[run 35728495307](https://github.com/Atingaii/Vela/actions/runs/35728495307)），不含此次窗口 API 改动。

2026-09-22 提醒阶段检查：Rust 175 通过、3 忽略；Node 10 通过；Playwright 14 通过，覆盖独立额度卡片、关闭、完成只展开和返回会话。重置/耗尽分别持续 5/6 秒；批量完成只选最新会话，固定 Swift 基准没有提醒队列。卡片计时与完成展开独立。`a54201f` 的 macOS / Windows / browser CI 全部通过（[run 35729501896](https://github.com/Atingaii/Vela/actions/runs/35729501896)），不含后续提醒修改。原生通知权限、真实终端定位与完整视觉一致性仍待验证。

2026-09-22 用量元数据阶段检查：Rust 180 通过、3 忽略；Node 10 通过；Playwright 15 通过。修复 Kimi `TIME_UNIT_*` 字段导致的 5 小时窗口遗漏、Copilot 剩余次数与已用次数混淆；恢复 MiniMax boost 计数与 Claude/Codex/Kimi/Copilot/MiniMax/OpenCode/Command Code 的已知套餐字段，桌面卡片与手机快照共享。旧缓存兼容，手机 backoff 保留原采集时间；未因此完成全部供应商元数据、block 或手机真实互通验收。

2026-09-22 活动阶段检查：Rust 188 通过、3 忽略；Node 10 通过；Playwright 17 通过；HTML 脚本检查通过。Codex 独立账户使用各自 turns/names/rollout，Antigravity 迁移提问/批准/权限等待、9 秒完成与 60 秒工作超时、跨安装目录有效会话选择。桌面恢复完成脉冲与状态优先级，手机保留 waitingFor 并按 v3 将 success 映射 idle。停用账户不采样。`7031640` 的 macOS / Windows / browser CI 全部通过（[run 35732551138](https://github.com/Atingaii/Vela/actions/runs/35732551138)），不含本次活动改动。跨供应商完成通知、Claude profile 活动、原生实测仍未完成。

2026-09-22 跨供应商提醒阶段检查：Rust 189 通过、3 忽略。Claude 与活动采集共用按账户/会话隔离的完成转换器，busy → waiting / success / idle 触发对应提醒；首帧、消失、重复静默，批次只取最新。没有增加线程。Codex/Cursor 源头完整生命周期与真实窗口定位仍待迁移，不能把转换器接通等同于全部客户端完成提醒已验收。

2026-09-23 原生复核：确认此前未达到全量 1:1。修复动态侧栏尺寸、完整圆弧轮廓和收起弹簧、模板图标缺失、原生设置标题栏、账户行与应用入口。Rust 197 + helper 1、Node 13、Chromium 22、WebKit 22 通过；四边原生截图、菜单/快捷键重开和账户启停 IPC 已检查。详细范围与限制见 [本轮原生证据](verification/native-parity-2026-09-23/README.md)。系统材质、完整设置和数据语义仍未完成；不发布为“迁移完成”版本。

2026-09-23 持续迁移：生命周期、Codex token/reset 元数据、DeepSeek/Qianwen 解析检查点共 Rust 215 + helper 1 通过，3 忽略。原版同数据原生对照进一步发现 OpenAI 图标、百分比前缀及漏移植 2pt bezel bleed；正在修正。多屏每窗状态、显示器 UUID、网页会话和原生材质仍在实现与复核，本检查点不构成全量验收。生产 Phone Link 的可用性以同一 SHA 的 `Sources/PhoneLink/PhoneLinkServer.swift` 为准，不按旧协议文档推断产品已开放。

2026-09-23 后续整合检查点：Rust 319 + helper 1、Node 15、Chromium 51、WebKit 51 通过，五页脚本语法通过。已接 Grok/Gemini API/Kimi 活动、本地模型独立活动与详情、LM Studio WS/日志/账本、Ollama relay、三类提醒状态机、账户生命周期、原生菜单/材质和设置保留状态。另单独执行本机已登录 Codex 的只读额度集成测试并通过；其结果不代表其他真实账号已验收。Grok/Kimi Windows 进程适配、跳回会话、部分供应商授权/字段、签名更新链路仍有剩余工作。锁屏期间隔离原生安装 smoke 未完成 WebView/IPC 握手，保留为失败待解锁复测，不能据此宣称安装可用或视觉 1:1 完成。

2026-09-23 启动与聚焦修复：Rust 321 + helper 1、Chromium/WebKit 各 52 通过。调用栈证明此前原生启动失败来自 `ui_flags` 重复锁定相同 mutex，已修复并移除缩放/显隐/材质路径跨原生调用持锁；隔离 app 的真实 WebView/IPC smoke 现已通过，正常退出且未启动供应商采集。Claude/Grok/Kimi 会话使用来源 PID 与出生时间校验跳回；固定 Swift 源的 Codex/Cursor/Antigravity/Gemini API 会话未提供 processID，保留不可跳转。Grok macOS 临时文件真实持有/关闭测试已通过。Windows 活动、完整账户操作与鉴权、签名更新链路、最终安装包和逐屏视觉对照继续进行，不将此阶段标为完整迁移。

2026-09-23 平台适配检查点：`882093e` 的浏览器、macOS、Windows [CI 35816546847](https://github.com/Atingaii/Velo/actions/runs/35816546847) 已全部通过。随后本机 Rust 331 + helper 1、Node 18 与五页脚本语法检查通过，新增 Antigravity 凭据/配额解析、Windows Grok/Kimi 进程和文件占用适配、跨平台安装 watchdog、账户目的地及应用入口基础接线。该本机结果不证明新的 Windows Restart Manager 路径已通过目标系统检查；声音桥接尚需实际坏文件测试，账户 Windows 目的地、AG 主轮询旧 CLI 优先路径、Kiro/Gemini API/Devin 输出和签名更新仍在修复。

2026-09-23 后续整合检查点：Rust 362 + helper 1、Node 25、Chromium / WebKit 各 63 通过。已闭合 Kiro enrichment、Gemini/Devin/Copilot/CommandCode 输出、默认供应商活跃调度、重复圆环、稳定 ID 节点、原版弹簧/数字/卡片/手柄动画、状态透明度、完整语言选项与菜单、连续设置保存和真实版本号。真实 Ollama loopback 验证原文转发、thinking 起止及速度；按固定源仅 LM Studio 使用日账本。更新公钥、带签名版本校验的暂存、下次启动交接与三平台隔离升级验证脚本已实现，实际发布包升级尚未执行。

`ae7ee93` 的 [CI 35820700594](https://github.com/Atingaii/Velo/actions/runs/35820700594) 已通过 Windows 测试/原生构建/Taskbar proxy/Settings WebView/IPC/helper 检查，见 [Windows 实际报告](verification/native-parity-2026-09-23/windows-smoke-ae7ee93.json)。当前工作树重新构建后，在本次专用 macOS app 中实际启动也成功，报告 [0.1.1-preview.1 原生启动](verification/native-parity-2026-09-23/installation-smoke-0.1.1-preview.1.json) 的两处版本号一致、IPC/helper 成功、未启动账户采集、正常退出且无超时。Mac 仍锁屏，同场景原生视觉/材质/逐交互、真实账户和新三平台 DMG/NSIS/更新包的验收仍不能由上述测试替代。完整迁移任务保持进行中，边缘插件验收尚未开始。

2026-09-23 本批网页会话、自定义端点和生命周期源码检查点：Rust 369 + helper 1 通过、3 ignored（`/tmp/velo-migration-native-wake-probe-rust.log`）；Node 27 通过（`/tmp/velo-migration-web-endpoint-lifecycle-node.log`）；Chromium / WebKit 各 68 通过（`/tmp/velo-migration-web-endpoint-lifecycle-chromium-final.log`、`/tmp/velo-migration-web-endpoint-lifecycle-webkit.log`）。修复内容与固定源对照见 [本批 source review](../.trellis/tasks/09-22-swift-full-parity/research/2026-09-23-web-endpoint-lifecycle-source-review.md)。`9eb92d0` 的 [CI 35823934689](https://github.com/Atingaii/Velo/actions/runs/35823934689) 在 macOS / Windows / browser 均通过，旧版原生报告见 [macOS](verification/native-parity-2026-09-23/macos-smoke-9eb92d0.json) 和 [Windows](verification/native-parity-2026-09-23/windows-smoke-9eb92d0.json)；该提交不含本批新功能。本批标准 Tauri debug `.app` 构建与 [macOS 隔离 smoke](verification/native-parity-2026-09-23/macos-smoke-web-endpoint-lifecycle.json) 均成功：`wake_subscription=true`、WebView/IPC/helper=true、providers_started=false、版本与包版本均 `0.1.1-preview.1`、exit 0 且无超时。它仅证明唤醒 API 注册/注销及隔离启动，不证明实际睡眠恢复。macOS 仍锁屏；逐屏视觉、真实网页登录和账户、Windows 本批原生运行、三平台安装包及真实升级均未验，不标完成或归档。


2026-09-23 设置、硬件几何与换边检查点：Rust 379 + helper 1 通过、3 ignored（`/tmp/velo-parity-crossing-rust.log`）；Node 27 通过，Chromium / WebKit 各 84 通过（`/tmp/velo-parity-crossing-{node,chromium,webkit}-final.log`）。恢复硬件顶边的单次缩放、凸角手柄及折叠热区，修复透明窗口边界阻碍拖动与热区包围盒误捕获，drop zone 使用源收起轮廓；换边补齐整窗 0.16 秒淡出、折叠落位、50 ms 后展开和旧回调隔离。设置补首次接入说明、焦点回读但保留草稿、运行时打开/连接/活动、离线显示器选择、Windows 应用入口，并修正本地模型计数、连续阈值和新页面默认页。首次 Chromium 回归曾发现 LM Studio 断开后指标未隐藏，已修复状态刷新并保留原断言，最终双引擎通过。

来源与边界见[换边复核](../.trellis/tasks/09-22-swift-full-parity/research/2026-09-23-edge-crossing-review.md)、[侧栏交互审计](../.trellis/tasks/09-22-swift-full-parity/research/2026-09-23-notch-interaction-audit.md)和[设置审计](../.trellis/tasks/09-22-swift-full-parity/research/2026-09-23-settings-controls-readonly-review.md)。本批标准原生 app 正在重建。5176a88 的 Windows CI 在 localhost 扫描失败，当前双栈修复已通过本机 IPv4/IPv6 回归，仍需新 Windows CI；旧 SHA 的 Apple Silicon DMG 安装/签名完整性/隔离启动通过，Developer ID、公证和 Gatekeeper 默认信任均未通过。Mac 仍锁屏，未补新的原生截图或鼠标/材质验收；全量迁移和边缘插件验收均不标完成。


本批最终标准 Tauri debug app 构建成功（`/tmp/velo-parity-crossing-native-build-final.log`），隔离 native smoke 成功：WebView/IPC/helper/wake_subscription=true，providers_started=false，0.1.1-preview.1，exit 0、无超时。报告已保存为 `docs/verification/native-parity-2026-09-23/macos-smoke-controls-edge-crossing.json`。该报告验证启动与订阅，不是锁屏期间的视觉/鼠标/实际睡眠恢复验收。

2026-09-23 兼容性复核：`966de00` 的 [CI 35831142333](https://github.com/Atingaii/Velo/actions/runs/35831142333) 中 Apple Silicon 原生与浏览器通过，Intel macOS 15.7.9 启动 SIGABRT，Windows 本地端点扫描失败。已根据 Apple SDK 和固定 Swift 源修复无条件调用 macOS 26 专属 `NSScreen.CGDirectDisplayID`，改为 `deviceDescription["NSScreenNumber"]`，详见 [复核记录](../.trellis/tasks/09-22-swift-full-parity/research/2026-09-23-macos15-startup.md)。本地端点采用各有独立 1.2 秒期限的 IPv4/IPv6 并发无凭据探测，保留 localhost URL 并去重；不以调整地址顺序牺牲另一地址族。两项修复需新目标平台 CI 验证。失败诊断只保留本次隔离进程的报告，并补有界 LLDB 回退，不将失败转成成功。原生视觉和真实账户验收继续待完成。
