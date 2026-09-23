# 持续集成审查（进行中）

基准仍为 `vinzdg/codenotch@117a38b8edae2ebd0944bc86b8760c6381685345`。本记录列出实际源码对照发现，不代表验收完成。

## 当前检查点

- 最新阶段 Rust 289 项、helper 1 项通过，3 项有外部依赖的测试忽略（`/tmp/velo-migration-alerts-models-tests.log`）。在此前 280 项检查点上补入 Cursor 无写入时的时间状态转换、自定义端点鉴权、菜单格式和三类提醒语义。Codex 重定向测试的假服务器改为先读完有界请求头再响应，消除提前关闭引起的 TCP reset；仍严格断言不会转发到重定向目标。Windows 自有 Job Object 路径仍需 Windows CI；完整本地模型、LM Studio、账户页和调度继续实现。
- Chromium 与 WebKit 最新检查各 47 项通过（`/tmp/velo-migration-custom-local-ui-second.log`、`/tmp/velo-migration-custom-local-webkit.log`），包含自定义端点扫描/草稿探测/图片/分离预算、Ollama 开关、LM Studio 自有 token 的设置交互，以及此前菜单/材质/定价/预览检查。齿轮测试已等待真实位置并点击可见圆心；这些浏览器测试使用隔离 IPC，不代替原生窗口与真实服务验收。
- 五个 HTML 页内脚本语法检查通过。新的 macOS 原生 debug 构建通过（`/tmp/velo-migration-native-build-third.log`），不等同于安装包或运行验收。
- 原生同数据截图复核曾恢复，随后 Mac 再次锁屏而暂停；代码与离线验证继续。不将此前截图标作新实现的效果证据。等待解锁期间没有替换用户已安装的应用。
- 后续整合：本地模型与账户新增场景在 Chromium 50 项通过（`/tmp/velo-migration-model-accounts-ui-second.log`），WebKit 正在复验。首次失败揭示测试把显式空显示列表当作默认选择；修正测试场景，并补本地监控开启后重读原生显示顺序，保留“明确隐藏全部”的含义。
- LM Studio WS/日志/日账本已接入后端。本次 Rust 编译通过，304 通过、1 失败、3 忽略（`/tmp/velo-migration-runtime-accounts-tests-third.log`）；唯一失败为 MiniMax 中国站重试 fixture 使用不受支持的模型名称，已修 fixture、待复验。不能把这轮记录为全绿。
- 随后调度与本地运行时检查点 Rust 308 + helper 1 通过、3 忽略（`/tmp/velo-migration-scheduler-runtime-tests.log`），原生 debug 构建通过（`/tmp/velo-migration-runtime-native-build.log`）；Chromium/WebKit 50 项分别全通过，WebKit 记录在 `/tmp/velo-migration-model-accounts-webkit.log`。尚不包含之后的本地活动贯通与新增 Grok/Gemini API/Kimi 活动模块。
- 已将该构建复制到本次专用 `Velo Parity.app`，临时签名验证通过，未覆盖 `/Applications/Velo.app`。锁屏期间运行安装 smoke 失败：设置 WebView/IPC 未完成，程序到时未退出，外部 45 秒 watchdog 结束了进程（`/tmp/velo-migration-runtime-installed-smoke.log`）。没有新的截图或安装可用结论，需解锁后复测并排查；不把失败归零或当作通过。
- 准备推送的后续检查点：Rust 319 + helper 1、3 ignored（`/tmp/velo-migration-activity-integration-tests-third.log`），Chromium/WebKit 各 51（`/tmp/velo-migration-activity-model-ui-second.log`、`/tmp/velo-migration-activity-model-webkit.log`），Node 15（`/tmp/velo-migration-checkpoint-node-tests.log`）通过。额外只读 Codex `account/rateLimits/read` 集成检查通过（`/tmp/velo-migration-live-codex-readonly.log`），没有运行 Claude 真实续期或 Antigravity CLI 集成测试。
- 新活动模块的 Mac FFI 已按本机 SDK 核实结构与常量；Windows Grok/Kimi 进程/句柄路径尚未完成，不能用返回空数组的暂存分支代表跨端迁移已验收。模型属性中的引号必须用属性编码，不能用仅适合文本节点的转义；新增带引号模型 ID 与活动隔离回归已双引擎通过。
- 此检查点已提交并推送为 `2f39315`，对应 [CI 35815026540](https://github.com/Atingaii/Velo/actions/runs/35815026540) 的 macOS 和浏览器通过，Windows 311 通过、1 失败、3 忽略。失败的自有子进程测试给 `--exact` 传入了缺少 `usage::` 前缀的名称，子进程实际运行零项测试；正在修复，不能将 Job Object 路径记为已通过。
- 本机安装 smoke 改用 `/private/tmp/` 实际路径后，原先的沙箱路径报错消失，但 WebView/IPC 仍未完成，45 秒 watchdog 终止进程。`/tmp/velo-migration-realpath-installed-smoke.log` 保留失败；Mac 仍锁屏，不将路径修正当成安装修复完成。
- 预览更新密钥已生成并存入系统 Keychain，读回比对成功；两个签名 Secrets 已配置到 GitHub Actions，临时私钥文件已删除。用实际密钥签署自有测试文件，并用应用依赖的 `minisign-verify` 验证：原字节通过、修改一个字节拒绝、签名可信注释包含 `0.1.1-preview.1`。这只验证密钥与签名能力，客户端 feed、下载、安装和新版发布仍未完成。
- 随后对自有隔离原生进程采集调用栈，已定位启动失败的代码原因：主线程 `get_ui_flags → ui_flags → WindowRuntime::lock` 阻塞，`ui_flags` 在同一 struct 表达式的两个字段重复锁定同一 mutex，首个临时 guard 尚未释放。不能再把该次启动失败归为锁屏限制。正在修复此处并审查缩放、显隐、材质调用中的跨线程持锁；调用栈保存在本次临时目录 `velo-smoke-stack-7w2wlgli/sample.txt`，后续以新原生 smoke 验证修复。
- 修复上述自锁及缩放、显隐、材质的跨调用持锁后，重新原生构建并更新本次隔离 `Velo Parity.app`：`/tmp/velo-migration-deadlock-fixed-installed-smoke.json` 已通过，实际设置 WebView/IPC 与 bundled helper 为真，采集未启动，退出码 0，无超时。测试时 Mac 仍锁屏，说明此前失败不能由锁屏解释。该证据来自复制新 debug binary 的隔离 app，不代表最终 DMG / NSIS 或 Gatekeeper 已通过，视觉仍待解锁对照。

## 必须关闭的审查项

1. WebSession：旧登录成功不得复活已退出账户，旧 HTTP 401 不得注销新账户；epoch 与持久授权状态原子变更，profile 清理与并发创建串行。重复打开登录窗保留输入中的页面，脚本执行和取回结果都校验 origin，超时清理 nonce 结果。
2. Claude transcript：首次扫描还没有 JSONL 时，每轮仍检查直接路径；只省略重复的目录扫描，不能永久缓存“不存在”。
3. Claude 独立账户：registry → Snapshot → 每账户圆环、卡片、提醒、定位及 Phone Link 协议必须保留 provider 身份；默认账户关闭不得关闭副账户活动，副账户完成不得通知默认账户。
4. 原生侧栏：真实 NSGlassEffectView 使用同源完整 path mask，验证四边、卡片尾部、设置按钮、透明度辅助功能和收放动画；面板预算采用 Swift 完整 cardHeight 语义，不能调整固定像素掩盖 DOM 高度误差。
5. Claude 用量：同账户 Desktop cache、CLI `/usage`、Keychain OAuth 及拒绝授权后允许重试逻辑仍需完整对照。
6. Cursor：恢复子代理过滤、编辑器进程启动时间、15 分钟失效、9 秒完成和 6 秒空闲；即使 DB 未写入也重新计算时间状态。Codex 同步复核固定源监控语义。
7. 本地运行时：Ollama relay/速度/活动/日 token、LM Studio 授权与日志/流状态；只有模型发现不算完成。
8. DeepSeek：价格时段开关、schedule 持久化和卡片渲染，不以没有后端字段的默认值冒充。
9. 应用入口：调整尺寸时 1.2 秒预览，系统 accent 更新，菜单栏信息，macOS ServiceManagement 启动项状态及失败提示，对照源实际行为。
10. 自定义端点：保存前探测、本地端口扫描、自定义图片和完整错误回退；剩余项由实现者逐一补齐。
11. 源实际注册的 Grok、Gemini API、Kimi 活动监视器必须迁移；默认连接与 seenProviders 按源 reconcile，只自动开启新的 Claude/Codex 账户族。
12. 原 UsageStore 刷新语义：活跃 60 秒、空闲 300 秒、本地 1 秒、15 分钟过期、额度重置边界及时刷新；统一代次和有界超时，旧请求不能覆盖新账户。
13. Mac 会话定位：不仅激活终端程序，还需按源匹配 Terminal/iTerm2 的 tty、cmux surface/cwd、Ghostty cwd；外部调用失败才降级到激活程序。
14. 首启与版本介绍顺序按源 What's New → Settings，不能以首次显示空环代替引导。
15. 玻璃配色按 Palette 全量映射；浅色需黑色主文字和浅色额度颜色。暗玻璃 pill/card 遮罩分别为 0.60/0.80，普通玻璃在暗色系统下卡片遮罩为 0.35，不能统一处理。
16. 三族账户发现不能统一要求凭据文件：macOS Claude 是首次运行 marker 加 Keychain 属性枚举；Codex 签出后保留有设置或会话的账户行；Antigravity 接受完整 marker 集合并检查凭据。允许源支持的合法目录名，不以 ASCII 限制替代路径组件验证。以 AppDelegate 69–71 的启动时固定 registry 为准；新账户在下次启动时应用 seen/connected 规则，不增加源没有的周期发现机制。
17. 重启恢复用量 archive 按源先标 stale，保留原始采集时间；本地运行时不恢复旧库存，断开账户从持久 cache 中移除。60 秒 pass deadline 必须能让无人应答的 Keychain 调用不阻塞其余采集。
18. 菜单栏需使用完整 glyph、主窗口与 weeklyID 元数据，Codex `secondary` 不得遗漏；不得把分组模型五小时额度冒充账户额度。提醒也需接受同时有 count 和 fraction 的真实额度，并按源将 block 计入 exhausted。
19. Settings 关闭后隐藏并保留页面/草稿/位置，重开仅离屏时居中；只有刘海齿轮执行 toggle，其余入口 show；无最小化。账户行完整恢复 Open、Switch、Allow 与独立续期失败提示，旧用量不能遮盖凭据失败。
20. 源 AppDelegate 738–764 的专用 ClaudeTokenRefresher 仅服务默认账户，且独立于用量回退读取。不可扩展为后台自动续期每个副账户；显式登录与每账户 `/usage` 回退保持各自原版语义。
21. 本地运行时按 `ProviderSnapshot.notchSnapshots` 与 `ProviderOrder.cells` 为每个已加载模型生成独立单元，保留源 provider 身份、已有模型顺序、单独隐藏选择；汇总模型数量不能代替模型圆环、上下文、速度和日 token 详情。
22. 自定义端点的金额/token 预算分别保存；无预算时始终显示实际填写用量，余额模式不把“100% 剩余”染为耗尽。`usedText`、`prefersUsedText`、`bandOverride` 需贯通圆环、详情、菜单和协议，不仅增加后端字段。401/403 与网络失败分开处理；模型列表优先字段和排序/截断遵循源实现。
23. 提醒的三个原版状态机不能合并成一套“首次静默、静音均消费”的规则：`ThresholdNotifier` 首次即检测 80/100，100→90→100 可再次越过 100；`UsageLimitWatcher` 首次静默，静音时未送出的后续耗尽事件不标为已送出；`UsageResetWatcher` 只有实际送出后才清峰值并记最后提醒的重置时间。以固定源函数为准，旧文档的“首次快照不提醒”仅适用于 Limit/Reset。
24. 自定义尺寸：原版分别保存 preset、usesCustomNotchScale 和 customNotchScale，切回预设再切自定义不能丢掉先前滑块值。LM Studio 未选地址时读取其自身配置端口，已选地址优先；WebSocket 保留 IPv6 loopback 地址，不强制改连 IPv4。
25. 供应商异常语义逐个迁移：Copilot/CommandCode/Ollama Cloud 的 403、OpenCode 无订阅及指数退避、MiniMax 国际凭据失败后一次中国站重试；Kiro CLI 与可选 API enrichment 的失败和限流必须独立，不能丢弃仍有效的 CLI 用量。
26. 安装更新：按 ADR 0008 提供独立的签名预览 feed，三平台安装检查通过后才能更新 feed；Tauri 应用更新签名不等同 Apple 公证。实际密钥与篡改拒绝已验证，尚未完成客户端更新链路、新版安装包及更新验收。
27. 跳回会话：前端只发稳定会话 ID；后端由当前活动映射到 PID，并复核采集时的进程出生时间与未停用状态。Windows 应选择最近的宿主窗口而非更上层 Explorer，且只有实际前台切换成功才报告成功。没有来源 PID 的行不可伪造跳转。
28. Windows 应用呈现：设置中的应用图标选项必须有真实任务栏/托盘行为，不能只写配置；再次启动仍能打开设置。需分别验证操作系统等效行为与 macOS 原版行为。
29. Gemini API 输出严格按固定源：month 总窗口保留实际 token 和可选预算百分比、today 总窗口、cli/opencode/hermes 各一个月窗口；不能添加每来源 calls/today 行，也不能有预算后丢掉实际 token。无日志采用原版 nothingMetered 语义。
30. Devin 金额展示保留 Usage / Extra usage 分组，overage 的 used 是四舍五入后的 cents，usedText 是据该 cents 格式化的美元；金额不能只拼进 label 后再显示裸分数。Desktop 优先凭据、身份和源标签、CLI 空白校验与请求错误策略一并迁移。
31. 声音原生桥接必须实际验证无声坏文件失败，不能用文件枚举测试代替 AVAudioPlayer 初始化结果。按源在调用 play 前替换 retained player；仅初始化失败才采用 NSSound 回退。
32. 默认内置供应商的刷新也要对齐 UsageStore。CATALOG 与 named profile 已有活跃 60 秒、空闲 300 秒和 reset 边界调度，但 Codex/Cursor/Grok/GLM/Antigravity 默认采集仍有独立固定 300 秒循环；不能只对新增供应商迁移调度，再把全局调度标作完成。

最近检查：`882093e` 的浏览器/macOS/Windows CI 35816546847 全通过。当前后续检查点本机 Cargo 331 + helper 1、3 ignored（`/tmp/velo-migration-platform-ag-chime-tests.log`）、Node 18/18（`/tmp/velo-migration-platform-ag-node-tests.log`）通过。新 Windows 活动适配尚待对应提交的 CI，不能复用此前结果。

`d132ff1` 已推送，对应 CI 35817407268。其后本机 Cargo 332 + helper 1、3 ignored 通过（`/tmp/velo-migration-accounts-chime-kiro-tests.log`），包含真实 AVAudioPlayer 初始化坏音频后返回失败的无声测试。原生构建通过（`/tmp/velo-migration-accounts-native-build.log`），新 binary 复制到本次专用隔离 bundle 后实际 smoke 再次通过（`/tmp/velo-migration-accounts-native-smoke.json`）：WebView/IPC 和 helper 存在、无供应商采集、正常退出。该次 Windows Taskbar 检查在 macOS 报告为 null，绝不推断 Windows 已验证。Kiro 此检查点只闭合完整 Reading 结构，其 enrichment 仍在实现。

## 解锁后的原生复核顺序

1. 将通过检查的新 binary 复制到本轮隔离测试应用，使用新的空 visual root 和 `--fixture swift`；保留用户 `/Applications/Velo.app`。同时原版仅运行 `CODENOTCH_DEMO=1`。
2. 左侧、小尺寸、solid、weekly outside、无 move handle 的同场景先核对：面板边界、2pt bezel、三枚图形、百分比、底部 settings arc；再核四边的卡片尾部、悬停空隙、离开收起、保持展开与尺寸临时展开。
3. 逐页核 Accounts、DeepSeek、Ollama、LM Studio、Custom Endpoints、Appearance、Notifications、General；验证 tab/草稿在关闭重开后保留、空白点击结束编辑、所有保存失败能恢复旧值。
4. 对照系统 glass、darkGlass、solid 及降低透明度，验证真实材质安装成功后才移除 WebView 背景；截图不得把无桌面背景的离屏渲染冒充材质验收。
5. 独立核菜单栏 1/2/3/4 个账户、周环、倒计时 tooltip、重复 glyph 标签与系统强调色。原生窗口/菜单实际点击与页面内 mocked IPC 的证据分别记录。
6. 全量检查稳定后冻结源码、提交并运行对应 SHA 的双平台 CI 与安装包 smoke；真实账户和 Windows 实机未执行的项目保持明确边界，不由 parser fixtures 代替。

实现按用户要求由 GPT-6-Sol High 执行；根代理负责源代码核对、集成审查及最终验证。工作区尚未达到全量迁移完成条件。

后续 Kiro 完整 CLI/API enrichment 批次通过 Cargo 340 + helper 1（3 ignored，`/tmp/velo-migration-kiro-feature-tests.log`）、Node 18/18 与 UI 脚本检查。Chromium/WebKit 各 55/55 通过。CI 35817407268 的 Windows 在 Tauri native WindowBuilder 的 unstable feature gate 处编译失败，尚未执行活动测试；本检查点补 Windows-only feature，并将实际 native startup smoke 加入普通双平台 CI。新 updater 模块仍在实现，不包含在此验证结论中。
