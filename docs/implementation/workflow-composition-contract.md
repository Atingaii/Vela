# 工作流组合与输出合同

状态：Core 已实现；UI 必须经指定 Antigravity CLI 接入。此文区分确定性工作流组合与尚未完成的模型自主工具循环。接口由现有 `vela call`/JSONL RPC 调用，不新增网络服务。

## 定义

普通 workflow 继续使用既有 `steps` 与显式 `context` v1。新增 pipeline 与 steps/context/guidelines 互斥；pipeline 自己没有模型 prompt。保存接口仍是 `workflows.save`：

```json
{
  "id": "weekly-report",
  "title": "Weekly report",
  "project": "/absolute/registered/project",
  "pipeline": [
    {"id": "collect", "workflowId": "collect-changes"},
    {"id": "summarize", "workflowId": "summarize-changes", "when": "has_output"}
  ],
  "output": {"target": "file", "path": "weekly-{date}.md", "inbox": true}
}
```

1–16 个 stage。`when` 只有 `always`（默认）、`has_output`、`no_output`；首段只能 always。判断依据为上一段输出去掉首尾空白后是否为空。跳过段记录 skipped 并透传前一段文本，失败段停止整个 pipeline。pipeline 不能直接或经子输入嵌套另一 pipeline。

每段收到上段文本：有显式 context 的子 workflow 通过 `input.previous` 与 stdin 获得；可在模板中写 `{{input.previous}}`，或声明 source: stdin 的输入。stage 的可选 `inputs` 对象可使用 `{{previous}}` 与 pipeline 原始 `{{input.key}}`。旧版 raw argv 不变；没有 context 的固定命令不会被静默加上 prompt/stdin，其定义仍可作为忽略上段文本的步骤。显式绑定 inputs 必须有子 context。

Context v1 的输入新增一种 source，不能与 tool/retrieve/source/value 同时出现：

```json
{
  "id": "summary",
  "workflow": {
    "id": "summarize-changes",
    "inputs": {"topic": "{{earlierInput.topic}}"},
    "stdin": "{{earlierInput.text}}"
  },
  "optional": false
}
```

inputs/stdin 均可省略。输入按声明顺序解析，后者可用之前的已捕获数据；子工作流产物成为该输入的字符串值。optional 仅在子运行明确 failed/rejected 时降级，结果不确定不能降级为成功。子 workflow 可以继续有子输入，但整个展开图不得循环、深度不得超过 8、子节点不得超过 64，冻结定义总量不得超过 1 MB。依赖必须来自同一注册项目。依赖缺失、嵌套 pipeline、未知条件及路径错误在保存/开始前拒绝。

依赖定义、版本和整体 hash 在根运行开始时冻结；后续编辑 workflow 不改变该次图。Guideline/Memory/实际只读输入在对应节点准备其 prompt 时捕获，记录确切版本/hash；每个获批动作始终使用那份已保存的最终 argv。数据只展开一次，不会把来自输入中的双花括号再次解释。

## 运行、审批与恢复

`workflows.run {id,dryRun,inputs?,stdin?}` 不改变。子运行有 `parentRunId`、`rootRunId` 和 `outputMode: memory`，每段有独立 run。根记录包含 `compositionMode`、`compositionCursor`、`waitingChildId`、`stageResults`；其 `compositionDefinitions` 与 `compositionHash` 是内部审计数据，列表接口不重复返回整张图。

UI 状态至少区分：

| 状态 | 含义与操作 |
| --- | --- |
| running | 正在获取输入或推进结构 |
| waiting_child | 等待指定 child，通常需要打开它的真实审批 |
| pending_approval | 此 run 自己的实际工具动作待审批 |
| blocked | Dry Run 的前序产物未知，无法判断条件/准备后续输入 |
| needs_review | 子动作结果不确定、恢复记录不一致或产物安全写入失败；不能显示自动重试 |
| failed / rejected | 已知失败或拒绝，依赖图停止 |
| completed | 该 run 完成；仍应显示其真实 outputKnown/delivery |

每个 Agent、项目文件写入等业务工具仍走原 `approvals.decide {id,decision,snapshotHash}`。批准父级结构不授予整条流水线权限，子模型输出不修改工具白名单。审批完成后自动沿父链推进；忙碌导致未推进时返回 `continuationError`，原动作并不会重做。

`runs.get` 纯读。用户明确点击继续时调用 `runs.resume {id,project}`；它使用冻结图与确定性 child run ID，重建审批 ledger 已保存的 completed/failed/rejected 结果，再推进尚未开始的结构节点。executing/needs_review 审批不重试。跨进程 composition lease 覆盖短期推进，等待用户审批期间释放；重复读取或恢复不能再创建/执行同一 child。

Dry Run 会读取允许的只读输入，整个依赖图的模型/项目脚本/文件交付都 stub。未执行模型的输出标 unknown；依赖未知输出的条件或父 prompt 停在 blocked，不把它当作空文本制造成功。

## 产物

普通 workflow 也可添加 output；默认从最后一步的实际 output 取文本，也可用 `stepId` 指定唯一的既有 step。pipeline 的产物为最后一段/透传后的文本。

```json
{"target":"stdout"}
{"target":"file","path":"reports/{date}.md","inbox":true,"stepId":"report"}
{"target":"inbox"}
```

文本上限 1 MB，保存 `output`、`outputKnown`、`outputHash`。stdout 表示交给调用方/RPC 返回的运行结果；Core 不向 JSONL 通道额外插入裸文本。显式 scheduled 输出不得只设 stdout。旧版无 output 的 workflow 保留原运行行为，新建 pipeline 默认手动 stdout、其他触发器 Inbox。

文件只在当前 store 的 `output/` 内；拒绝绝对路径、父目录穿越、NUL、未知占位符、symlink/hardlink 逃逸。仅支持 UTC `{date}`、`{datetime}`、`{time}`（也接受双花括号），基于该 run 的开始时间冻结。使用 SafeApply 在同一跨进程事务锁内读取原 hash 并 journaled 写入，多个产物不会交错；内容已相同时不重复写。业务工具写入仍需审批，Vela 自身的 run/产物持久化属于用户已选择的输出行为。只有根交付，子 run 一律 memory；Dry Run 不交付文件或 Inbox。

- `outputs.list {project}`：最多 100 条产物元信息，无正文。
- `outputs.get {project,id}`：读取对应 run ID 的产物与 hash。
- `outputs.inbox {project}`：仅已交付且 unread 的产物。
- `outputs.markRead {project,id}`：标已读，不能跨项目。

产物 Inbox 与待审批列表分别处理，不能把一条报告显示成“批准执行”。`runs.list` 去掉新加的整图定义和重复 delivery 正文，大文本使用 outputPreview；完整内容由 runs.get/outputs.get 请求。

## 验收证据与未完成范围

`WorkflowCompositionTests` 覆盖实际两阶段进程与逐次审批、冻结旧子定义、只交付根文件、子输入模板边界、optional 降级、跳过透传、Dry Run unknown、循环/深度/总量/跨项目拒绝、已保存执行结果的崩溃恢复、uncertain 不重试、Inbox 作用域、并发与 symlink 写入边界。必须结合当前源码的实际测试结果，不能把测试文件存在当作已通过。

本合同没有替代 connector discovery/auth、模型自主选择工具、完整 retry/watch/通知规则或全部 CLI 命令。它们仍在三产品覆盖台账内。

## English summary

The existing Swift engine now supports bounded, frozen workflow dependency graphs with individual child runs and tool approvals. Pipelines have three factual conditions, skip with pass-through, and do not nest. Subworkflow inputs capture child text without duplicate delivery. Explicit resume uses persisted approval results and never retries uncertain effects; reading a run remains passive. Root-only output can return to the caller, write safely inside the local store, or enter a scoped artifact inbox. Unknown dry-run outputs block dependent decisions rather than pretending to be empty. This deterministic composition does not claim to implement an autonomous agent/tool loop.

## 恢复时的检查状态

`run_output.baseHash` 是交付前持久化的原始文件版本，和 `contentHash` 分别标识被替换内容与本轮产物。恢复发现另一轮已覆盖同一路径时，原 run 进入 `needs_review`，错误阶段为 `output`；UI 应展示待检查原因和原 receipt，不提供自动重试按钮。底层 `apply_journal` 保留文件事务证据。

命令结果带真实 `terminationSignal`（正常退出为 0）；`timedOut` 或非零 signal 表示未知副作用，审批和父子 run 显示 `needs_review`。`runs.resume` 不重复这些命令；审批 ledger 和 run 状态落盘先后不同也会向父链传播待检查状态。普通非零退出码仍是已知失败。
