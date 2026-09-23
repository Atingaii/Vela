# 2026-09-23 设置控件与行为只读复核

基准：`vinzdg/codenotch@117a38b8edae2ebd0944bc86b8760c6381685345`。范围是固定 Swift 的 Accounts、DeepSeek、Ollama、LM Studio、Appearance、Notifications、General 设置页与当前 `src-tauri/ui/settings.html` 及直接使用的 IPC。Custom Endpoints 与语言此前已专项核对，本次不重复；Phone 页按固定源 `PhoneLink.isAvailable=false` 的生产 gate 核对。Mac 仍锁屏，本记录不包含原生视觉判断、真实账户或实机交互结论，也未改实现。

## 可复现差异

| 位置与源行为 | 当前行为和复现场景 |
| --- | --- |
| **Accounts 首次使用说明。** `Sources/Settings/SettingsView.swift:700–752, 1376–1405, 1443–1476`：没有任何账户摘要且没有已连接本地模型时，Connected 组显示“Connect an assistant to get started”，说明支持的本机工具和 Keychain 授权；空组、已有圆环时还分别显示空状态或拖动顺序说明，并始终说明网页会话例外。 | `settings.html:229–236, 1533–1544` 的 Connected 组只注入账户行，未插入上述条件性说明。全新安装且所有来源未登录时，用户只看到各账户的逐行状态，缺少源版关于 Claude Code 与 Claude 网页版区别、授权提示及入门说明；已连接后也缺源版顺序/会话边界说明。这是信息与操作引导缺口，不以控件外观差异计。 |
| **回到设置时重读账户。** `SettingsView.swift:505–510, 1299–1302` 在首次出现及窗口成为 key 时执行 `accounts = providers()`。 | `settings.html:2459–2473` 的 `focus` 只读 tray options、显示器、外观等；`settings_opened` 仅 blur 输入，`providerMetadata` 只在启动和 `providers` 事件读。打开账户所属 App、在外部切换登录后立即回到仍开着的设置窗口，账户摘要与来源说明可继续显示旧身份，直到后台 provider 事件到来。`get_account_destination` 的 15 秒轮询不重读摘要。 |
| **Ollama / LM Studio 打开所属应用。** `Sources/Settings/OllamaSettingsRow.swift:33–34`、`LMStudioSettingsRow.swift:36–37` 各有独立 `Open Ollama` / `Open LM Studio` 按钮，监控开关关闭时仍可用。 | `settings.html:263–278` 两个 Connection 页没有该动作。虽然 `account_destination.rs:22–31` 有这两个 owner App 映射，`resolve` 在 `:115–125` 只接受 `get_providers` Reading 或六个默认圆环，而这两个本地 runtime 父 ID 不在两者中；即使从页面调用现有 IPC，也得不到目的地。安装对应 App 后进入本地页，无法像源版直接打开它。 |
| **本地连接的“检查”状态。** `OllamaSettingsRow.swift:41–45`、`LMStudioSettingsRow.swift:44–48` 在地址未变化且监控关闭或当前正在检查时禁用 `Check connection`。 | `settings.html:1633–1645, 1725–1738` 只切换按钮文案，未按监控/检查状态禁用。关闭监控、保持原地址后点击 `Check connection`，前端仍调用 `refresh_ring` 并显示 Saved；`main.rs:925–930` 的 `refresh_provider` 因 disabled 返回 false，实际没有检查。LM Studio 同样可复现。 |
| **LM Studio 指标说明与活动状态。** `LMStudioSettingsRow.swift:68–69, 134–155` 在已连接时显示 `Activity, speed and tokens`、SDK 连接状态、server log 读取/今日 token 摘要及来源说明。 | `local_runtime.rs:432–440` 的 `get_local_runtime_activity().lmstudio` 已有状态数据，但 `settings.html:272–278, 1662–1690` 只显示监控状态与 token 输入；前端仅在 Ollama 页读取并消费 `.relay`。连接 LM Studio 并产生 server log 后，本地页看不到源版活动/日统计及读取状态。 |
| **拔掉已固定的显示器。** `SettingsView.swift:943–979, 1299–1310` 的 Display picker 保留已存但断开的 display ID，显示 `Unavailable display`，说明会暂跟随活动窗口，并监听屏幕参数变化。 | `main.rs:2136–2154` 的 `get_monitors` 只返回当前显示器，`settings.html:2221–2255` 只从返回项判断 `pinned`；拔掉固定的外屏后，下拉框显示 `Follow active window`，文案也称正在跟随，掩盖仍存于配置里的固定 ID。重接外屏会再次固定，用户此前看不到这个保留状态。设置窗口保持焦点时也没有屏幕变化事件触发刷新。 |
| **Windows 的应用图标选择。** 固定 Swift `SettingsView.swift:1031–1044` 提供 Dock / menu bar / hidden 三态；Velo 的 Windows 适配已在 `settings_window.rs:194–270` 实现 Taskbar / system tray / hidden。 | `settings.html:2022–2026` 在非 macOS 隐藏整个 `app-presence-controls`。Windows 用户无法在设置页改变已经存在的三态持久值，只能沿用默认 Taskbar；这属于平台入口遗漏，不是要求 Windows 显示 macOS Dock 文案。 |

其余已核控件中，DeepSeek 的启用/UTC 日程/恢复规则、Appearance 的重置格式/节奏/周环/尺寸/阈值/语言、Notifications 的四个声音选择及试听/三档持续时间/限额预览、General 的登录启动/自动更新/版本和作者入口，当前均有对应 UI 与 IPC；本次没有据静态源码确认新的缺失动作。这里的“未发现”不替代原生逐屏、真实账户或更新安装验收。自定义端点、网页会话和语言专项结果继续以各自记录为准。
