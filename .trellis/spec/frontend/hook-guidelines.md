# 事件与 IPC

本项目没有 React hooks。用 Tauri `invoke` 拉取初始状态，`listen` 接收后续状态（见 notch.html 的 providers 事件）。注册事件不重复叠加。异步操作成功后再更新持久状态；失败显示错误并复原 busy 状态。浏览器预览使用 mock，不能伪装成真实系统调用验证。
