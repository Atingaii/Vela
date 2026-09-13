# ADR 0035：受限 RPC child shutdown 与 Lab 中断账本

- 状态：Accepted；实现与验证分开记录
- 日期：2026-09-13

`vela rpc` 既可由 Desktop/SDK 持有，也可在批准的 Lab 中同步等待本地 child。直接结束 helper 会留下独立 process group，且已 claim 的 approval/eval 可能永久停在 `executing`/`running`。把这类未知结果标成失败或自动重跑都会错误扩大副作用。

EOF 只停止 RPC 新准入并排空已接受请求，兼容单帧 pipe client；它不因 stdin 关闭取消已批准 child。`SIGINT` 与 `SIGTERM` 才触发进程本地的 shutdown gate；gate 仅向 Vela 自己创建并登记的 process group 发终止信号，拒绝新的 child。运行中的 Lab 将已有 child receipt 持久化为 `interrupted`，并记录 interruption reason、时间和 partial result 数量；不再启动 verifier 或下一变体。对应 approval 以 `needs_review` 和 `outcomeUnknown=true` 完成。没有 retry、继续运行或自动 promotion。

helper 在有界时间内等待执行队列写入终态。超界时可对已登记 group 强制停止，但不能把强制停止描述为清理完成或持久化成功；调用方必须重新读取 ledger。该边界沿用现有 Swift runtime gate、冻结 approval 与独立 Git worktree，不新增驻留 agent、远端服务或取消任意外部进程的接口。参见 [Agent Lab 合同](../implementation/agent-lab-contract.md)。

`posix_spawn` 的 child 必须显式使用空 signal mask；Dispatch worker 的调用线程可能暂时屏蔽 `SIGCHLD`、`SIGINT` 或 `SIGTERM`。仅恢复 signal disposition 不会解除该掩码，可能使 provider runtime 无法观察其子命令完成。该修复仍仅改变 Vela 启动的 child，保留新 process group 和现有终止 disposition。
