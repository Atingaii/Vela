# 界面组件

复用页面已有 CSS、行布局和 render 函数。沿用 Codenotch 悬浮、点击展开、圆环和账户行为。设置压缩应折叠高级项，不删底层能力。动态名称、模型、错误等通过 textContent 或现有转义 helper 输出，避免 HTML 注入。按钮提供可读标签，键盘可操作。

例：`settings.html` 的 accountBlock 负责账户行；`notch.html` 的 headlineOf 选择主窗口。两处展示与 Rust 的 ring_window 应一致。
