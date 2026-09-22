# 日志

现有诊断入口是 `diag.rs`、`doctor.rs`。只记录故障类别、HTTP 状态、计时和非敏感 provider ID；不记录 token、Authorization、Cookie、凭据文件内容或任意服务端响应正文。测试用合成数据，不读取开发者真实凭据；需真实 CLI 的测试显式 ignored。
