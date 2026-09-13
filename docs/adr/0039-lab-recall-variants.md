# ADR 0039: Frozen Lab Memory Recall variants

- Status: Accepted; execution evidence is recorded separately
- Date: 2026-09-14

## Context

A Lab variant previously accepted `memoryIds` and concatenated those records directly into an agent context. That is a caller-selected legacy path, not a Memory Recall operation. Treating it as Recall would hide retrieval scope, lifecycle, token accounting and source changes from the approval snapshot.

## Decision

`lab.run.baseline` and `candidate` accept an optional `recall` object. Omitting it is compatible with legacy variants and records `enabled:false, selection:not_requested`; an explicit OFF uses `enabled:false` and may set `strictOff:true`. A strict-OFF variant rejects `memoryIds`, so an ON/OFF evaluation cannot quietly compare Recall against manually injected memory. A non-strict OFF variant may retain legacy `memoryIds`, and its receipt says `memoryInjection:explicit_ids`, never `recall`.

An enabled Recall requires bounded query text, an actual `MemoryService.recall` mode (`lexical`, `semantic`, or `hybrid`), `scope:"project"`, and a 1–4000 token budget. Lab filters the service result again to same-project, project-scope, Active, nonprivate sources outside Private Library; candidates, global records and cross-project results are never automatically selected. The frozen variant records query/mode/scope, requested and used token budget, selected IDs, title/content hashes, lifecycle-source hashes, and final injected-context hash.

Before every variant creates a worktree, Lab rechecks each selected Recall source against its frozen project, scope, lifecycle, privacy/path, content and source hash. It does not re-run Recall or substitute newer records. A mismatch rejects the approved Lab execution before that variant starts, cleans no unowned path, and leaves the source for review. Existing explicit `memoryIds` behavior remains unchanged.

## Consequences

This is a bounded FR72 increment, not automatic memory activation, provider retrieval, model evaluation, or a benefit claim. Approval includes the final context and Recall receipt; no candidate/private/cross-project source is silently promoted into it. UI may display a concise ON/OFF summary and token use, while hashes and full text remain technical details.

## 中文

Lab 现在把显式 `memoryIds` 与真实 Recall 分开记录。Recall ON 必须经 `MemoryService.recall`，并冻结命中来源、预算与最终上下文；执行前重验来源。OFF 不会被误写成“无所有记忆”，严格 OFF 也不能混入显式记忆。该能力不自动激活记忆、不调用 provider，也不证明效果提升。

## 2026-09-14 explicit-memory execution correction

Independent review reproduced a private explicit `memoryIds` record still reaching the candidate agent when its privacy changed after approval was prepared. The frozen explicit receipt already contains content and lifecycle-source hashes; execution now revalidates those records before each variant creates its worktree, using the same project, scope, privacy/path and source checks as Recall. The compatible explicit path still permits Active/Candidate records, while automatic Recall remains Active-only. Existing nonempty explicit receipts without a source hash fail closed and must be prepared again. Neither path reruns selection or substitutes new content. The final context hash is rechecked before consuming either kind of memory. This supersedes the earlier statement that explicit execution behavior remains unchanged.
