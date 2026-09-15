# ADR 0005：桌面语言偏好与显式界面绑定

- 状态：Accepted（决定已采用，界面迁移与验收结果另行记录）
- 日期：2026-09-13
- 范围：共享 Preferences、AppKit 菜单与通知、WKWebView 固定文案

## 背景

桌面应用需要支持简体中文和 English，并在切换时保留当前项目、选中记录与未保存表单。应用同时包含原生菜单、系统通知和 WebKit 界面；分别持久化语言会导致重启后或外部设置更新时显示不一致。工程数据包含用户正文、命令、来源和技术诊断，不能把界面翻译扩展到这些数据。

## 决策

以现有全局 `preferences` 对象的 `locale` 为唯一持久化来源，取值严格为 `zh-CN` 或 `en`。旧存储缺失或无效时读取回退 `zh-CN`，保留现有用户的中文默认。显式写入无效 locale 或包含无效布尔字段的混合补丁必须在保存前整体拒绝；不把空格、区域别名或数值转换为有效选择。

设置语言控件与原生 Language 菜单只提交 `settings.save({locale})`。它们不保存其他表单草稿、不请求通知权限、不改变登录启动登记。只有成功持久化的返回值更新确认语言；失败保留旧值且提供本地化错误标题。原生壳从真实偏好响应同步菜单，并用 `vela:localeChanged` 将确认的枚举值通知 renderer；应用不为此重新加载 WebKit。

使用随包的轻量显式双语词典与命名插值，不引入 UI 框架、翻译服务或额外进程。renderer 的固定叶文本、提示属性及动态固定标题在源码中明确绑定 key；切换只更新这些绑定，不重建页面、对话框、控件或详情容器。新增节点只处理明确绑定，禁止扫描任意正文进行按值、正则或机器翻译。插值数据按目标上下文转义，原始路径、argv、ID 和用户文本不作为翻译 key。

原生固定菜单、状态、通知模板与错误标题使用小型 Swift 词典。两平台保留相同导航术语与语言枚举；用户或 provider 产生的标题、消息、Memory、Workflow、输出和原始诊断维持原文。日期与已知数字可以按界面 locale 格式化，未知用量仍是未知，不能因为格式化变成零。

## 取舍与验证边界

显式绑定比整页重新渲染或运行时文本替换需要更多逐项迁移，但能保留 DOM 身份、焦点、选择区、滚动位置与草稿，并避免误改用户内容。两个小词典有术语同步成本，使用固定导航表、缺 key 检查及双语回归控制该成本；不为两种语言引入大型通用国际化依赖。

核心测试覆盖默认、旧值兼容、严格枚举、混合补丁拒绝、重开持久化与原数据不变。专门浏览器测试通过真实隔离 helper 验证即时切换和草稿保留；事件注入仅验证 renderer 消费逻辑，原生菜单、通知模板和实际系统投递分别验证。Accepted 不代表上述界面迁移、原生交互或测试已完成。

## 关联

- [接口契约](../implementation/contracts.md)
- [当前架构](../architecture.md)
- [Preferences.swift](../../Sources/VelaCore/Preferences.swift)
- [LocalizationTests.swift](../../Tests/VelaCoreTests/LocalizationTests.swift)

## English

**Status:** Accepted. This records the decision; implementation and acceptance results are tracked separately.

The existing global preferences object is the only persistent source of the desktop locale. Its exact supported values are `zh-CN` and `en`. Reading a missing or invalid legacy value falls back to Simplified Chinese. Explicit writes reject unsupported values and reject an entire mixed patch if any supplied preference is invalid. There is no second locale copy in browser storage or native user defaults.

The Settings selector and native Language menu save only the locale field, leaving other unsaved preferences untouched. Confirmed persistence updates the renderer and native menus; failures retain the previous confirmed locale and show a localized error heading. The host propagates confirmed values through `vela:localeChanged` without reloading WebKit. Changing language does not request notification permission or alter login registration.

The renderer uses a bundled, explicit bilingual dictionary with named interpolation. Only source-declared fixed text leaves and attributes are translated. Existing pages, dialogs, controls and detail containers retain their DOM identity, draft values, focus, selection and scroll position. Dynamically inserted elements are processed only when they carry explicit bindings. Runtime text scanning, regular-expression translation of arbitrary content and automatic translation of user data are prohibited. Parameter values are escaped for their HTML context.

The AppKit host uses a small Swift dictionary for its menus, status, notification templates and fixed error messages. Both layers share locale values and navigation terminology. User and provider titles, messages, Memory, Workflow content, output, paths, exact argv, identifiers and raw technical diagnostics remain unchanged. Missing numerical evidence remains unavailable rather than becoming zero.

This explicit approach requires more individual call-site migration than a page reload or text replacement, but preserves application state and avoids altering engineering data. The two dictionaries require terminology and key-parity checks; two languages do not justify a new framework, translation service or additional runtime process.

Verification separates preference compatibility and persistence, real-helper renderer interaction, native menus and notification text, and actual system notification delivery. Injected native events in browser tests establish renderer handling only. Acceptance of this ADR does not imply that all those checks have passed.
