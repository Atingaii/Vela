# Historical template replay / 历史模板回放合同

协议 `vela-historical-template-replay-v1`，所有 method 由 helper `vela call METHOD --params-stdin --home STORE` / 同一 RPC / 受约束工具接口可达。UI 未在本切片实现。旧 `workflows.replay {runId}` 保持 `captured_records_no_execution`。

## API

- `replay.describe {}`：边界、配额和保留上限。
- `replay.fixtures.inspect {project,runId}`：只检查终态历史 run；返回 `eligible,runHash,contextHash,promptHash,inputHash,sourceCount,inputCount,workflowId,workflowVersion`。不读取当前 Git、不调用模型；缺历史记录抛错，不能造一个新 snapshot 补全。
- `replay.fixtures.capture {project,runId,runHash,consent:true,retentionDays?}`：strict Boolean consent，1–30 天（默认 7）；精确 runHash；创建 metadata 和独立 payload。
- `replay.fixtures.get {project,id}` / `.list {project}`：只读取元数据，list 最多 100 条；`sourceValidation=not_checked_on_metadata_read`。
- `replay.fixtures.forget {project,id,fixtureHash}`：先撤销 fixture，删除 fixture 和关联 replay 正文；保留 ID/hash 审计。每次最多删除 128 个关联 payload；`cleanupPending=true/payloadRemoved=false` 表示需要重复调用，原 fixtureHash 仍可用。
- `replay.fixtures.prune {project,after?,limit?}`：清理过期或已撤销正文；每页 1–32 个 fixture（默认 32），返回 `nextCursor`（null 表示扫描完毕）与 `cleanupPending`。当前 fixture 尚有正文时游标不会越过它；调用者继续传回游标，每次仍有界。到期即禁止正文访问，即使未执行 prune。
- `replay.create {project,fixtureId,fixtureHash,versions:[A,B],executable,model,effort,timeoutSeconds?}`：A/B 为同一 workflow 两个不同已保存版本号，输入定义、memory policy、guideline IDs 必须与历史一致。显式可独立运行的 macOS Mach-O Codex 程序/model/effort；script/Node wrappers 本切片明确拒绝。timeout 每次 1–120 秒（默认 90）。创建专用 run 和新审批，最多 2 次调用。
- `replay.get {project,id}` / `.list {project}`：只读取 replay metadata、`replayHash`、小 `approval{id,state,snapshotHash}`。无 prompt/答案/原日志；list 最多 100 条。metadata 读取不验证 source assets。
- `replay.review {project,id,replayHash}`：重新检查来源、expiry、hash 后返回完整 `{request,approval,replayHash}`。request 的 `executableMode=native_snapshot`，执行后临时副本路径只替换 argv[0]，冻结的源路径仍用于审计。request 包含 exact commands、schema、A/B 模板与 revision hashes、agent、executableHash、timeout、fixtureHash、inputHash、maxCalls。
- 使用原 `approvals.decide {id,snapshotHash,decision:"approve"|"reject"}` 批准这份新审批。工具名 `workflow.replay.execute`，参数仅 `{replayId,requestHash}`；旧 run 的批准无法替代。
- `replay.results {project,id,replayHash}`：来源仍有效时，返回完整/部分 `receipts` 与 `comparison`；无来源权限时抛错，不返旧正文。
- `replay.cancel {project,id,replayHash}`：pending 则拒绝审批；executing 标记取消，当前已发送调用最多等待自身 timeout，再阻止下一次发送。不会声称撤回已经发送到提供方的文字。

所有 project 必须为已注册的绝对项目路径。未知参数、布尔冒充整数、错项目、错 hash、无保存版本、过期及不支持的组合形状均失败。模板插入值只渲染一遍；历史输入自身的 `{{...}}` 为字面数据。

## Storage and receipts

`replay_fixture` 仅保存 protocol、id/project、sourceRunId/Hash、fixtureHash、revision、expiresAt、state、计数和输入摘要 hash。`replay_fixture_payload.frozen` 保存真实历史 `workflow,snapshot,sourceRunId,sourceRunHash`。snapshot 校验自身 prompt/template/input/source hashes、原 run 的重复记录；不允许 degraded、缺回执或重建今天的输入。

`replay` 仅保存 id/project/fixtureId/fixtureHash/requestHash/versions/inputHash、state/cancelRequested、providerAttempts/completedModelCalls、各 attempt 的 claimed/response_received/validated 摘要及哈希、runId/approvalId。`replay_payload` 保存 `request,receipts,comparison`，总计最多 1 MB。每份 raw receipt 最多 262,144 bytes；每份结构化 answer 最多 32,000 bytes；truncated 不视为完整成功。

claim 后调用不自动重试，甚至只完成 A 也保留该部分。source 变为 private/archived/missing、fixture 过期或 forget 后，不能开始 B 或通过 getter取回正文。forget 与执行并发时联合 CAS 防止删除后重建 payload；取消标记只合并，不能被旧执行副本清掉。response 保存失败只返回短诊断到 run/approval，不复制模型正文。

`comparison` 保留 A/B 内容 hash、共同前缀/后缀行数、中段完整 added/removed lines、churn。算法是有界非最小行替换；`semanticEffect=unknown`，协议完成不等于答案正确或工程指标改善。提供方实际模型身份缺少可信事件时不可假称已观测；request.model 只是请求的模型。

## Scope and privacy

本切片只接受一个 contextual `agent.run`，不支持 pipeline/child workflow inputs/agent.loop/多个步骤/交付产物。所有工具被禁用，历史 Git/Library 输入只读冻结值，不执行原业务命令。不支持形状仍列为后续工作，不能据此标记 PX0 全功能完成。

Library 当前必须明确 public + active + managed asset 存在。Memory/Guideline 必须仍 active、原 project/scope 合格、资产安全存在；global 只接受原已选入的 global 来源。公开正文更新时仍使用历史正文；撤销公开资格则阻止读取/发送。无 source 标签的 literal/stdin 历史值不能自行推断其私密性，所以保留必须显式 consent，credential-like 内容直接拒绝。

memory archive/export 与 integration recall 按 memory kind 白名单，不包括 replay/fixture。SQLite 逻辑删除不保证 WAL 取证擦除，也不删除原 run/provider 数据。列表上限、发送前检查与已发送请求不可撤回，是独立可见的边界。

## English summary

Retain a historical context with explicit consent, review two saved template revisions under one new two-call approval, then inspect bounded no-tools receipts and a nonminimal line diff. Metadata reads are lightweight; full payload reads recheck source visibility. Expiry/forget revoke payload access and prevent resurrection. This is synthetic-testable template comparison, not a claim of complete composition replay or semantic improvement.

## Entrypoint identity

审批创建时确认 bounded native executable hash；执行前把原始入口按流复制到随机 0700 目录的 0500 文件，并验证副本完整 SHA256。A/B 使用同一个私有副本，原路径之后替换或截断不能改变入口；绝不回退原路径。receipt 保存 executableSnapshotHash。此合同只固定入口字节，`dependencyClosurePinned=false`：系统动态库、runtime helpers 和原生CLI可能需要的相对资源不在快照内。依赖相对安装路径的程序可能失败，失败后不改flags或重试；解释型包装器兼容仍需后续专门设计。
