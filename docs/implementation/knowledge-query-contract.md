# Knowledge Ask / Brain API 合同

Core 已接线并完成定点、隔离 CLI 和一次真实模型验证，具体快照见末尾；前端/原生实现继续交指定 Antigravity CLI 模型。没有 UI 代码包含在本切片。

## 入口

| 方法 | 参数 | 行为 |
| --- | --- | --- |
| `ask.describe` | `{}` | 固定协议、硬边界、检索能力与限制；无模型调用 |
| `ask.create` | 下述 create 参数 | 冻结来源并创建专用 run；有来源时 pending approval，无来源时 no_sources |
| `ask.followup` | create 参数 + `id,askHash` | 新一轮独立审批；旧轮必须已回答/unanswered/no_sources、来源仍有效、hash 相同 |
| `ask.get` | `{id,project}` | 当前状态、askHash、请求/来源、回答与审批；重新检查所有源 |
| `ask.list` | `{project}` | 最近 100 条状态摘要；不含请求/正文/原始协议/askHash，不逐条读取大来源资产；sourceValidation:not_checked_on_list |
| `ask.cancel` | `{id,project,askHash}` | 未执行审批的拒绝；沿现有审批账本 |
| `ask.citations` | `{id,project,askHash}` | 当前可读的引文和冻结来源片段；失效来源拒绝 |

create 必填：`project`（登记的绝对根）、`question`（≤4,000 UTF-8 bytes）、`executable`（实际 Codex 路径）、`model`、`effort`（low/medium/high/xhigh）。可选：`retrievalMode`（lexical / library_fts，默认 lexical）、`searchQuery`（≤1,000 bytes）、`timeoutSeconds`（1–300，默认 120）、`maxSources`（1–12，默认 8）、`maxSourceBytes`（1,000–32,000，默认 24,000）、`branch/worktree/task/sessionId`（每个 ≤1,024 bytes，worktree 必须绝对路径）。未知参数、boolean 代替数字、凭据模式问题文本和非法 effort 都拒绝。

Follow-up 要保留原 scope，最多八轮；不能降低 source 数量/字节预算而丢掉旧来源。新问题依然明确传入 executable/model/effort。一个审批仅一个请求，不能授权后续轮次；超时和 provider 失败没有自动 retry。`maxCallsPerRound` 是请求数边界，不是美元/token 花费上限。

## 来源与回答

候选来自当前项目已索引 substring 查询（最多六个词面搜索，每个最多 100 候选），只允许明确公开 Active Library 与 scope 相等的 Active Memory。Private Library、global/其他项目、inactive、上下文不匹配 Memory 都排除。候选之后再次读取真实 managed asset；新手工编辑会更新正文，但没有命中的旧索引可能遗漏新词，因此 `indexCompleteness:not_guaranteed`。显式 `library_fts` 调用本地 Library FTS5/BM25 的段落候选（并保留 Memory 词面候选）；不会自动索引，也不会无声退回 Library substring。返回 index 状态，未索引或 stale 时可能没有 Library 来源。FTS 命中随后再取新鲜 source 核对快照，冻结真实 paragraph、anchor、citationId 与 rangeUTF16，可引用正文深处的段落；full source hash 不因截取而变。Hybrid/vector 后端尚未接入本问答入口。

单来源最多 4,000 bytes，联合来源遵守预算，prompt ≤48,000 bytes，答案 ≤24,000 bytes。`request.sources` 给出 `sourceId/kind/id/title/content/sourceHash/excerptHash/fullSourceBytes/truncated/redacted`；FTS 段落的 sourceId 带 `#anchor`，附加 `paragraph` 元数据。`sourceHash` 覆盖完整当前源和隐私/作用域，content 是经过模式过滤的片段。片段截断可降低答案覆盖；脱敏模式不是任意秘密识别器。

模型返回 `claims:[{text,citations:[{sourceId,quote}]}],unanswered:[String]`，Core 额外组成 `answer`（按 claim 顺序连接）、全部 citations、`citationVerification:exact_substring_in_frozen_excerpt` 与 `semanticCorrectness:not_verified`。最多 12 条 claim，每条 1–4 处原文引用；无法支持的结论放入最多八个 unanswered，不得无引用生成答案。存在准确 quote 不能证明解释正确，UI 应支持打开原片段核对。

`requested` 模型选择在 request.agent；`observedModel` 未被协议证明时为 null。providerAttempts/completedModelCalls/metrics 只来自实际运行；失败不能伪造零消耗。`rawProtocol` 不保存正文，不把未验证回答回显给 Inbox 或 run。

## 状态与审批

- `pending_approval`：可审阅精确输入，批准仍调用 `approvals.decide` 及当前 approval.snapshotHash。
- `answered` / `unanswered`：一次完整协议且引用通过；unanswered 没有支持的 claim。
- `no_sources`：本轮没找到合格来源，0 模型请求、无审批；不意味着全部资料都不存在。
- `rejected` / `failed` / `executing_or_uncertain`：沿审批/过程真实状态，不自动重新执行。
- `sources_unavailable`：当前来源改变、私密或丢失。`ask.get` 隐藏 request/result，引用回查和 follow-up 拒绝；generic Inbox/run 中仅保留源 hash 参数及安全摘要。

来源在批准前、模型后、最终 Store CAS 和读取时复查。已经公开时存入本地的历史快照不会追溯抹除外部模型已处理的数据。无任何自动写入 Memory、修改源资料、发消息或执行模型工具的路径。

## 验证

14/14 Ask Core 方法通过，含 FTS 深部段落、无索引不 fallback、新 sourceLabeledPrivate、source/approval/tool/continuation 边界。之后复用 `LibrarySource.fresh` / `LibraryIndex.isPublic`，并与 Library 独立审查 3 项、Loop 独立审查 4 项合跑，21/21 通过；`output/parity/blume/review-boundaries-final.json/log` 的冻结源码 hash 为 `0241b02a0d0aed5c3e56d0e882cc952505437f0015d915825c80731a8801b89e`，结束时与工作树匹配。这是 portable fallback，不是 XCTest。

`scripts/verify-knowledge-query.py --output <new-evidence-dir>` 默认使用 fake provider 但执行真实 CLI/transport，6 组检查通过，见 `output/parity/blume/knowledge-cli-attempt-1/receipt.json`。

默认合成模式不需要 provider 安装路径。显式真实模式必须同时提供 `--live --executable /absolute/path/to/codex`；脚本没有用户机器路径默认值，缺失或相对路径在创建证据目录和启动 provider 前拒绝。

独立授权 `--live` 一次已通过：2026-09-13T04:47:47Z–04:47:58Z，Codex CLI 0.154.0，requested gpt-5.6-sol / low，1 个完整模型请求、10.987 秒、2 个合成公开源、2 个精确引用、0 tool call；协议报告 9,986 input + 154 output tokens。`observedModel:null` 不把选择参数冒充模型身份证明。证据在 `output/parity/live-provider/knowledge-attempt-1/`，保存调用前 source/request/approval 审阅和最终引用回查。CLI 与真实调用均冻结 helper `35d6aeb67cbdf85ce7117231e41da642369d2a913f959b833111987391d80e26`。

后续新 helper `20f58ba432cfca74402443d84d21865e7c9c4a153cbf059a09d36afd1bd23c6f` 的实际 CLI 两模式回归通过：lexical 6 组、library_fts 7 组；见 `output/parity/blume/knowledge-cli-shared/receipt.json`、`knowledge-cli-fts/receipt.json`。后者确实先显式创建段落索引，再核验 FTS 来源、审批、原文引用、独立续问、privacy 撤销和临时目录清理。

这一次真实调用发生在显式 FTS/sourceLabeledPrivate 扩展之前，只证明原词面双来源的答案协议与引用链；FTS 扩展由后续定点核验。没有再次消耗真实模型授权；新版本不能继承旧 helper 的完整联调结论。所有临时 fixture/store/helper 已清理，原始成功和失败证据保留。无调用真实用户材料、不自动续问、不激活 Memory。这不是问答语义正确性或产品整体完成证明。

## English summary

Ask creates a source-bound, reviewed answer with a dedicated run. Every model call is separately approved, every claim has exact quotes, and every source is rechecked before execution, publication and readback. Follow-ups preserve provenance and get new authorization. Missing sources produce a no-call result. Quote validity and model correctness are explicitly different guarantees. The default candidate stage is bounded indexed substring retrieval. Explicit library_fts mode freezes real indexed paragraphs with anchors; missing or stale index entries never cause a silent fallback.
