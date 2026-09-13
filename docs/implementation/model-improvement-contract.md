# Model Improve 合同 v1

状态：Core 已通过 13 项专属测试、7 项冻结 helper CLI 检查，以及一次真实 Codex 三阶段合成来源协议验收；UI 必须由 Antigravity CLI `gemini-3.8-flash-high`、effort `high` 实现。保持现有 `improve.analyze` 的确定性检测入口。模型分析由用户主动选择来源、目标、CLI 和模型后发起；协议通过不代表质量改善已证明。

## 界面与调用顺序

1. `improve.model.describe {}` 返回 provider、支持的 carrier、三个阶段、输入/时间预算。无需账户查询或模型请求。
2. 用户选择已登记项目及 1–20 个会话，选择 1–5 个明确修改目标，选定 Codex CLI、model 和 effort。摘要展示所选会话、发送给模型的脱敏证据、目标当前内容、最多三次模型请求及每次超时。Private Library 从不参与。
3. `improve.model.plan` 创建冻结的请求、run 与 pending approval；此步模型调用为零。返回完整 plan，内含 `request`、`requestHash`、`approval.id`、`approval.snapshotHash`、`runId`、`planHash`。
4. 用户审阅后调用既有 `approvals.decide {id, decision:"approve"|"reject", snapshotHash}`。批准的是最多三次、同一已选模型的提取→归并→规划；任何失败都停止后续调用。来源或目标改变会拒绝执行，需新建请求。绝不自动重试。
5. `improve.model.list {project}` 返回最近 100 条轻量记录；`improve.model.get {project,id}` 返回详情、各阶段已观测 metrics 和 suggestions。`drafts` 表示有候选，`observations_only` 表示证据不足或没有可提出的变更；两者都不表示已生效。
6. suggestion 中包含 `carrier`、`operations`、`preview`、`evidence`、`modelClaim`、`claimStatus:unverified_proposal`、`suggestionHash`。使用已有 `improve.preview` → 用户明确 `improve.apply {id,project,suggestionHash}` → `improve.undo {id}` 路径。模型候选 Apply 必须带最新 hash 和项目；来源被改为私密或所引消息变化会拒绝，不因新追加的无关消息而拒绝。模型不能批准或直接写项目。
7. `improve.model.transition` 支持稍后处理、忽略、重新打开。每次使用 get 返回的最新 `suggestionHash`；已应用条目不能被状态切换隐藏 Undo。

适合一个克制的“分析所选会话”流程：来源和目标选择、冻结输入预览、一次运行审批、阶段进度、按具体文件显示候选 diff。把预算与证据完整性放在审阅详情中，不铺满卡片或快捷键标签。

## 创建参数

```json
{
  "project": "/absolute/registered/project",
  "sessionIds": ["actual-indexed-session-id"],
  "targets": [{"carrier":"Doc","path":".vela/docs/project-handoff.md"}],
  "executable": "/absolute/path/to/codex",
  "model": "explicit-model-id",
  "effort": "high",
  "maxCalls": 3,
  "timeoutSeconds": 120,
  "maxEvidence": 60,
  "maxEvidenceBytes": 24000,
  "maxPromptBytes": 60000
}
```

`project/sessionIds/targets/executable/model` 必填。effort 为 low/medium/high/xhigh。额外参数被拒绝；没有通用 shell、外部 URL、Library、自动触发或不受限权限选项。

| 项 | 限制 |
| --- | --- |
| 会话 | 1–20 个不同的实际索引 ID，同一项目、非 private、非内部模型运行、已支持 provider |
| 证据 | 默认 60、最多 80 条；每会话最多取最近 80 条合格消息，轮流选取；每条最多 2000 字符 |
| 证据 JSON 字节 | 默认 24000，可选 1000–32000；确切遗漏数 `omittedMessages` 保留 |
| 每阶段 prompt | 默认 60000，可选 4000–64000 字节；派生输入超过冻结预算会停止 |
| 模型调用 | 仅 `maxCalls:3`；阶段失败后不继续，也不重试 |
| 每阶段时间 | 默认 120 秒，可选 1–300 秒 |
| 目标 | 1–5 个不同路径；每个原文件最多 8000 字节，合计最多 16000；含凭据模式的原文件拒绝规划 |
| 输出 | 单次协议总输出最多 262144 字节，结构化答案最多 32000；每个候选替换内容最多 16000 |

这是请求数、输入输出和时间硬边界；CLI 实际 token 仅来自已完成 provider 协议，不承诺美元硬上限或虚构价格。

## 目标 carrier

| carrier | 路径范围 |
| --- | --- |
| `Rule` | `AGENTS.md`、`CLAUDE.md`、`.cursorrules`、`.cursor/rules/`、`.vela/guidelines/` |
| `Skill` | `.claude/skills/`、`.agents/skills/`、`.codex/skills/` 中的 `SKILL.md` |
| `Hook` | `.codex/hooks.json`；候选必须是含 hooks 对象的 JSON，Apply 后仍需 provider 自己的信任流程 |
| `Doc` | `.vela/docs/*.md`（可有子目录） |
| `Workflow` | `.vela/workflows/*.md`；候选附带受限、停用的 `workflowDraft`，需另行 `workflows.save` 接受并审批运行 |

所有路径还必须通过现有 SafeApply allowlist、项目范围、symlink/identity/hash 检查。输入可为项目相对或项目内绝对路径。不能越界或修改 Private 路径。

Rule 至少需要三个不同、未截断的用户消息并横跨两个 provider source session；Skill/Hook/Workflow 至少三个 source session。复制同一 provider session 不会增加独立证据数。门槛只决定是否形成候选，不能证明模型解释正确，不能让候选变成永久规则。

## 状态切换

```json
{"project":"/project","id":"suggestion-id","suggestionHash":"current-hash","action":"snooze","until":"2026-09-20T00:00:00Z"}
```

- `snooze`：draft/needs_review/undone → snoozed，`until` 必须在未来一年内。
- `dismiss`：draft/needs_review/snoozed/undone → dismissed。
- `reopen`：dismissed/snoozed → draft，重新 Apply 时仍检查目标 hash。
- 稍后处理不会隐式唤醒模型。当前未接后台模型调用，也未到期自动执行。

## English summary

Model Improve creates a frozen request and a one-shot approval for three bounded Codex proposal stages. Each output can only cite the preceding stage and the originally selected project evidence and targets. Candidate changes stay reviewable; SafeApply and Undo remain separate human actions. Private Library is excluded, missing evidence is not synthesized, and manual-only behavior is explicit.
