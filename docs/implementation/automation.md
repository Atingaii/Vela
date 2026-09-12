# 自动化内核实现与验证

此文记录当前实现，需求完整范围见 `docs/requirements.md`。本模块未编写或修改任何 UI；所有界面由专门的 Antigravity 任务实现。

## 已实现的真实闭环

- `workflows.save` 保存版本化 Markdown 与数据库对象，运行时重新解析人类编辑过的 JSON frontmatter（JSON 是当前支持的 YAML 子集）；变更产生新版本，无效格式拒绝执行。Run 冻结对应 workflow 版本，不受后续修改影响。
- `workflows.run` 支持 `git.status/diff/log`、`shell.test/typecheck`、`agent.run`、`file.write`。Dry Run 只真实运行三个 Git 只读工具，其余步骤全部 stub。实际 shell、Agent CLI 与文件写入均需 Inbox 审批。
- Inbox 批准的是持久化的工具、参数、项目、run、stepIndex 和内容 hash。数据库 CAS 先将 pending 变为 executing，成功领取的执行者才运行；两个 SQLite 连接同时批准也只运行一次。中断的 executing 动作不会自动重试。
- Run Ledger 保存每步退出码、输出、截断标记、超时、执行时间、冻结参数、审批与文件事务引用。失败或拒绝会停止后续步骤。Replay 使用原始冻结 workflow，默认 Dry Run；旧批准不会用于新运行。
- Safe Apply 使用允许项目根、逐级 `openat/O_NOFOLLOW`、文件身份验证、UTF-8 / 大小上限、hash 比对、staging、fsync、rename、before/after journal；Undo 在 after hash 一致时恢复。配置事务通过 `flock` 跨进程串行，启动恢复不会干扰另一进程的活跃提交。
- Improve 从真实索引消息提取明确纠错语言，保留 message/session 引用；纯代码要求至少 3 个信号且来自至少 2 个不同会话才晋升。同源重复分析幂等。输出可预览、Apply、Undo、Dismiss 的证据草案，不伪造模型调用或 confidence 分数。
- Lab 在同一个真实 Git commit 创建两个 detached worktree，使用同一 command / timeout、按重复次数交替执行顺序、应用冻结的 variant 文件；保存真实退出码、输出、时间、diff 和统计，然后删除该次评测创建的 worktree。启动评测先进入 Inbox，不立即执行。
- Scheduler 支持 manual、cron、app_start、session_completed / agent_finished、git_event；事件以固定 ID 在数据库原子领取。已有运行 / 待审批时避免重叠。usage_reset 因当前没有真实 provider quota/reset 数据，明确标为 unavailable。
- 后台证据分析默认关闭。显式开启 `analysisEnabled` 后，每次 tick 先比较 SQLite 单行 Session revision，未变化时不加载历史或重写信号；变化时调用已有确定性检测器，只有成功后才保存水位，失败可重试。关闭不推进水位，重新开启处理积累数据，不调用模型/命令、不自动 Apply。
- Workflow Health 只计算真实非 Dry Run 的运行样本。零样本时 rate、tokens 为 null；没有测量 guideline 影响时标记 not_measured。

## 核心接口

Workflow 步骤示例：

```json
{
  "title": "Run tests",
  "tool": "shell.test",
  "arguments": { "executable": "npm", "args": ["test"], "timeoutSeconds": 120 }
}
```

命令不通过通用 shell 字符串拼接；需要 shell 时用户明确选择 `/bin/sh` 并提供参数。执行器使用 `posix_spawn` 为进程创建独立进程组，超时终止整组，输出有 1 MiB 上限，不允许测试或分析留下未知后台子进程。

Lab 请求示例：

```json
{
  "project": "/absolute/registered/repository",
  "title": "Compare verification context",
  "kind": "context",
  "baseline": { "files": [{ "path": "AGENTS.md", "content": "Baseline instructions" }] },
  "candidate": { "files": [{ "path": "AGENTS.md", "content": "Candidate instructions" }] },
  "command": ["/absolute/executable", "argument"],
  "timeoutSeconds": 120,
  "repetitions": 1
}
```

`lab.list` 和 `lab.compare` 返回同一个 eval 对象。对象 `kind` 为 `eval`，具体类别保存在 `evaluationKind`。结果为 `results:[{variant,repetition,exitCode,output,durationMs,timedOut,truncated,configuredChanges,changedFiles,diffStat}]`；汇总包含每组样本数、通过数、通过率、平均时间、时间方差和候选差值。

## 当前能力边界

1. Improve 使用版本化的明确语言规则，未接入语义模型的抽取、聚类和规划；关键词命中必须让用户查看原始证据。生成的 Workflow carrier 当前是 Markdown 证据草案，需在 Builder 中保存显式工具后才成为可执行工作流。
2. Lab 是真实命令对照基础设施。`evaluator=deterministic_command` 不代表独立模型质量评测；用户可以显式选择已安装 Agent CLI 命令，但当前不自动解析各 CLI token、模型、reasoning 或成功评分。只记录实测输出，不宣称因果改善。
3. Git worktree 提供工作目录与 Git 状态隔离，**不是操作系统沙箱**。用户批准的任意命令仍可能访问工作区以外的文件。原仓库 status 前后对比用于记录意外变化，不等同访问限制。
4. Memory / Workflow 类评测标签共用成对文件变更与命令执行机制，当前不会自动注入 Memory Recall，也不会隐式执行指定 workflow 的历史版本。调用方需明确构造 variant 文件及使用它们的命令。
5. `guidelinesUsed` 保存批准时参考快照，`guidelineUseMode=snapshot_only_not_injected`；当前不会假定任意 CLI 自动读取这些快照，Health 不推断其输出影响。
6. 不支持未连接的 GitHub、Slack、Linear 等外部工具，未知工具直接拒绝。审批编辑流程、任意 action 的外部幂等 key、自动 provider quota 触发尚未实现。
7. 多文件 replacement 由单文件原子 rename、失败回滚与恢复 journal 提供一致性；不是操作系统层面的多文件原子事务。无法安全回滚外部并发改动时保留 needs_review，不覆盖用户新内容。跨进程 CAS 避免重复领取，不对任意外部系统声称全局 exactly-once。
8. Cron 使用 Mac 本地时区，支持 5 个字段、逗号、范围和步长（weekday 0–6）。当前会话完成触发仅考虑每项目最新完成事件，休眠期间全部历史事件补跑、Git 任意文件事件与显式时区配置属于后续完善范围。
9. 后台分析是 helper 运行期间约每 30 秒的定期变化检查，不是操作系统空闲检测；仅 RPC/桌面模式启动 timer。每次分析上限为最近 500 个已索引 Session 和 10,000 个 Signal，不代表完整历史回填。

## 验证

2026-09-12 在本机真实核心 / SQLite / 文件 / 进程上执行：

```text
python3 scripts/test-portable.py
Executed 38 real-core test methods using the portable fallback runner.
38 PASS
```

其中 `AutomationTests.swift` 的 19 个测试覆盖：Dry Run 无副作用、冻结审批不受编辑影响且不能重放、过期 hash 不覆盖、拒绝与安全 Replay、多文件 Apply/Undo、缺 hash / symlink / traversal 拒绝、中断 journal 恢复、人工编辑增版、真实证据晋升及重跑去重、单 session 不晋升、Lab 成对真命令与 worktree 清理、进程组超时及输出上限、调度去重和 quota 不可用、零样本 Health、两个数据库连接并发批准、两个 Scheduler 同事件唯一领取，以及后台分析默认关闭、开启后处理、未变化不重写、更新与重新开启后的积累数据处理、真实 SQLite 持久化失败后重试。

本机 CLI SDK 没有 XCTest 模块，所以使用项目的 portable runner 编译实际核心与相同测试方法，未替换数据库或文件操作。完整 Xcode CI 使用 `swift test`。这些验证不包含吞吐量/常驻内存基准或公开发行签名与公证。

测试 fixture、portable runner 临时目录、路径别名探测目录和 Lab worktree 均在各自 `defer` / finally 中清理。保留源码、测试、持久化格式和交付文档。
