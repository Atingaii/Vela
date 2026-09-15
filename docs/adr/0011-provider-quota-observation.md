# ADR 0011：通过 Provider 官方 CLI 读取订阅额度

- 状态：Accepted（决定已采用；真实账户与 UI 验收单独记录）
- 日期：2026-09-13
- 范围：`usage.quota.read`、`usage.quota.status` 和 Codex app-server 的只读额度观察

## 背景

本地日志 token 计数不能说明订阅剩余额度或重置时间。Codex 官方 app-server 文档提供 `account/rateLimits/read`。借助 provider 自己的认证和请求路径，可避免 Vela 读取、复制或维护用户的 token 文件和账户私有 HTTP 接口。

## 决策

Vela 提供独立额度接口：`usage.quota.read` 仅接受 `provider: codex` 与用户明确选择的绝对 CLI `executable` 路径；`usage.quota.status` 仅读本地最后结果。不给 RPC 调用方传递任意 args、环境、工作目录或服务 URL 的能力。普通日志 `usage.get` 保持原有含义，不混入账户额度。

短命子进程固定运行 `app-server --stdio`，完成 `initialize` / `initialized` 握手后只发送 `account/rateLimits/read`。客户端名称为 `vela`，不冒充第一方。它不会创建任务、启动模型、兑换 reset、充值、发邮件，或响应索取凭据的 server request。Vela 不打开 provider 的 auth 文件；用户正常查询时，Codex CLI 自己仍会按其配置处理账户认证及网络请求。

以独立进程组启动，stdout/stderr 分别非阻塞排空；stderr 永不保存或返回。单 JSONL 帧 1 MB、各流总量 4 MB、默认 15 秒上限；成功、超时、错误都结束本次进程组。没有自动重试。环境仅继承必要运行目录和语言设置，不继承 API token、动态库注入变量。权限边界仍以用户选择并信任的本机 CLI 为准，不能执行从会话正文或外部网页自动取出的路径。

只持久化规范化 bucket/window 数据：来源 limitId/name、planType、usedPercent、remainingPercent、windowDurationMins、Unix 秒 resetsAt。多 bucket 表优先，兼容旧单 bucket；未知 ID 原样保留，legacy 没有 ID 时为 null。不存在的窗口不补造；非法百分比/时间保持 null；明确 0% 保留为 0。remaining 由已知百分比计算且下限为 0，source usedPercent 不被饱和改写。

成功快照 `observedAt` 与每次尝试 `attemptedAt` 分开持久化，状态同时暴露 `sourceCapturedAt` / `lastAttemptAt`。失败保留旧成功快照，但 `quotaAvailable=false` 且标为 stale；不把旧值展示成新观测。超过五分钟的快照过期；已过 reset 的窗口不再作为当前可用额度。原始账号、email、token、credits/reset 能力及 stderr 都不入库。错误只保留安全分类与数值 code，不保存原错误消息。

## 取舍与后续

短命 CLI 比常驻 app-server 多一点启动成本，但避免新后台进程和持续账户连接；本功能用户触发且只读。独立额度队列不应阻塞 Session、Settings 或长 Workflow。使用 provider 认证可能需要其用户登录可用，Vela 不会通过自行抓取 cookie 修复。

Claude 与 Cursor 的同等个人订阅额度仍是明确未完成项。已查 Claude 公开监控文档主要描述 token/OTel；Cursor 官方 Admin API 需要管理员，不能将其等同个人套餐。后续必须继续确认支持的接口与认证契约，不能因 Codex 成功而将三家都标为支持。

## 依据和复验

- [Codex app-server 官方文档](https://developers.openai.com/codex/app-server)，读取日期 2026-09-13。
- [ProviderQuotaTests](../../Tests/VelaCoreTests/ProviderQuotaTests.swift)：规范化、实际子进程握手、缺失/零、旧快照、错误脱敏、输出限制、超时及子进程回收。
- [真实 Vela CLI 协议检查](../../scripts/test-quota-rpc.py)：通过隔离合成 app-server 测试全路径，无真实账号或模型调用。

## English summary

Codex quota is observed through the documented app-server read method using a short-lived local process. Vela does not handle credentials, start model tasks, or consume reset credits. Bounded transport and a separate last-attempt record keep errors, stale data, missing values and actual zero distinct. Claude/Cursor personal-plan parity remains open.
