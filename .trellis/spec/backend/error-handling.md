# 错误与数据语义

用量未知不能显示为 0；缺失窗口不能用另一类额度代替。参考 `main.rs::ring_window`、`providers/parse.rs` 的测试。remaining 必须先转换成 used 再传给圆环。

IPC 使用 `Result<_, String>` 返回可读错误。解析与传输分开；鉴权失败、限流、网络失败和不存在分别处理。`providers.rs` 失败保留上次成功窗口和时间，重试遵守 backoff；手动刷新不能绕过 429。账户缓存、鉴权和冷却不能混用。
