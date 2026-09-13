# Workflow Watch 合同 v1

`workflows.save` 增加 `trigger:"watch"` 与以下 `watch`。enabled 为 true 才由已有 daemon/helper 的 Scheduler 观察；保存和普通 Dry Run 不执行观察。

```json
{
  "source":"tool",
  "tool":"library.retrieve",
  "arguments":{"query":"release notes","k":10},
  "mode":"items",
  "key":"id",
  "everySeconds":60,
  "minItems":2,
  "debounceSeconds":10
}
```

可选工具为 `git.status`、`git.diff`、`git.log`（arguments 为空对象），`memory.recall`（query、budgetTokens 1–2000），`library.retrieve`（query、k 1–10）。它们均为本地受限读取。外部 connector 不能通过此入口自动调用。

Git 仅支持 mode output；Memory/Library 默认 mode items。output 比较一项完整受限结果，minItems 必须1；items 的 key 默认为 id，必须是每项都存在的唯一 scalar dot path。Memory/Library 的事件值只包含 id/kind/contentHash，正文由显式工作流输入重新检索。检索窗口之外的项目不在本次观察范围内。

每次观察首先建立或更新完整快照。首次、重新启用、定义版本改变仅建基线；普通重启保留既有积累。相同 hash 不触发，多个变化按 key 合并为净变化，minItems 满足且最后变化后 debounce 到期才提交。间隔30–86400秒、debounce 0–300秒，实际检查精度由30秒 Scheduler tick 决定。休眠期间不伪造遗漏的读结果。

| API | 参数 | 结果 |
| --- | --- | --- |
| `watches.describe` | `{}` | 当前可用读目录和最小间隔 |
| `watches.get` | `{project,id}` | definition、watch_state、schedule，纯读 |
| `watches.preview` | `{project,id}` | 真实只读 snapshot、拟积累项、是否建立基线；mutated false，零 run/approval/event |

Workflow Context 可用 `{{input.watch}}` 引用冻结事件。事件含 protocol、tool、changes、snapshotHash、observedAt、sequence；每个 change 有 key、type added/modified/removed、before/after。没有 Context 的工作流仍可被触发，证据保存在 run.watchInput，不隐式修改旧 argv。Pipeline 可显式传递 input.watch。

状态包括 watching、accumulating、deferred、claimed、needs_review，以及实际 run 状态。等待前次审批不会丢掉新增积累；未知派发不会再跑，沿已有调度事件 acknowledge 合同处理。数据超界、duplicate key 或读失败显示 failed，保留原水位。Private/失效来源被撤销，不能把这些旧条目作为工作流的删除正文。

## 文件观察

`watch:{source:"files",paths:["src","README.md"],recursive:true,ignore:["**/cache/**","*.tmp"],minItems:1,debounceSeconds:5}` 选择项目内不重叠路径；`paths:["."]` 可选择整个项目。每路径最多32层、1–16个根；绝对路径、逃逸、Private或重叠根拒绝。recursive false观察所选目录的直接子项，true递归。未来文件可先以不存在路径建基线再观察创建。

FSEvents 提示后，已有30秒 tick用SHA256读取实际字节。同大小/同mtime内容变化仍能识别；内容不变的原子替换不触发。before/after的value含path、kind(file/directory)、contentHash、bytes、fileIdentity。确切inode/hash配对的移动呈现 type renamed；其他情形保留removed/added，不猜重命名。未读到的中间保存过程不伪造为完整历史。

`watch_state.fileEventID`、`fileEventSerial`、`fileObserverInstance`记录通知水位；receipt含filesRead/directoriesRead/bytesRead/excludedCount。空闲tick不重复扫描内容；重启或drop事件重新核对快照，historyIncomplete表示历史并不完整，既有claim仍不得自动重派。文件源的nextPollEpoch为null，靠提示和重启核对。minItems按配对后的变化项计数；pendingItems保留待处理路径键数。

硬界限是每文件2MB、一次32MB、512目录/2000条目、snapshot128KB、pending192KB/100key；任一界限先到都阻止移动水位。5秒扫描期限为系统调用之间的协作检查。默认忽略Private、.git、.vela、.build、node_modules；显式glob支持*（不跨目录）、**（可跨目录）和?。观察不读取链接或FIFO，不通过renderer暴露任意文件读取。

任意第三方读工具仍未提供。外部metadata自报readOnly不能绕过此目录限制，真实外部账户另行验收。

English: The first observation establishes a baseline. Bounded, keyed net changes accumulate durably and trigger the existing reviewed executor only after minimum/debounce conditions are met. macOS FSEvents supplies hints for descriptor-safe SHA256 snapshots, including exact rename evidence and atomic replacements. Idle ticks do not reread file contents. Preview neither starts a stream nor changes runtime state. Uncertain dispatches remain blocked for explicit reconciliation; third-party read tools are not yet supported.
