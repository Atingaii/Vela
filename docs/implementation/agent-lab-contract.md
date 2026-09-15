# Agent Lab / Reuse contract

Implemented interfaces for the working branch; executed checks are recorded separately in the acceptance evidence. Existing `lab.run` command mode is retained.

## `lab.run`: Codex mode

```json
{
  "project": "/absolute/registered/repo",
  "title": "Verification before handoff",
  "kind": "memory",
  "agent": {"provider": "codex", "executable": "codex", "model": "explicit-model-id", "reasoningEffort": "high"},
  "task": "The same task for both variants",
  "verificationCommand": ["/usr/bin/python3", "verify.py"],
  "verificationFiles": ["verify.py", "README.md"],
  "outputFiles": ["bounds.py"],
  "timeoutSeconds": 240,
  "repetitions": 3,
  "baseline": {"label": "Baseline", "files": [], "memoryIds": []},
  "candidate": {"label": "Candidate", "files": [], "memoryIds": ["candidate-memory-id"]}
}
```

- Requires a committed repository and 1–5 repetitions. Promotion review requires at least three. The model is an explicit **requested** identifier; provider-resolved server version is unavailable.
- `verificationFiles` and `outputFiles` are distinct lists of 1–32 normalized relative paths. Verification files must be committed. The task can change output files; other working files are not copied into the independent verifier's clean worktree. Changed protected verification files invalidate the sample.
- `baseline/candidate.files` contains `{path,content}`; `context` optionally supplies bounded text. `memoryIds` freezes nonprivate candidate/active **project-scope** memory. The combined context is at most 32 KB.
- Optional `sourceSuggestionId` must refer to this project. Candidate must include the suggestion's exact file changes or its `verificationCandidateMemoryIds`; unrelated associations are rejected.
- Returns an eval with `state=pending_approval`, `evaluator=codex_agent`, `approvalId`, `agent`, `task`, `commit`, frozen variants, verification/output lists and `modelIdentity`. Nothing executes until its existing frozen Inbox approval is approved. Dry-run UI must not approve automatically.
- Approval arguments include the same frozen fields. Display the **agent**, task, variant contexts, allowed outputs and independent verifier, not merely the legacy `command` field.

## `lab.compare` / `lab.list`

Each result retains agent process `exitCode/output/durationMs/timedOut/truncated`, `agentCommand`, `agentMetrics`, independent `verification`, `verificationIntact`, worktree changes and tokens. `agentMetrics` contains actual completed commands, source session ID, provider usage, observed matching test invocations and tool count. Test observation v3 recognizes an exact simple command with a completed exit record, or the unconditional first test invocation of a successfully completed compound script. Compound exit status does not establish the individual test exit status. Unclassified absence, parse failures and incomplete events remain unavailable; counts may be lower bounds. Corrections stay null for single-turn comparisons.

Completed historical Codex evaluations are reanalyzed from retained raw events on `lab.list`, `lab.compare`, `evidence.get` and before promotion. Derived row/summary token fields use the same current metric version. `originalGitStatusUnchanged` compares Git status only; `originalWorktreeUnchanged` is unavailable because status equality cannot prove file-content equality. The original stored evidence is preserved, with the previous summary and correction reason included in the view when its analysis version changes.

`summary` contains baseline/candidate `runs`, `validRuns`, `successes`, `testExecutingRuns`, `passRate`, `testExecutionRate`, `averageTokens`, `averageDurationMs`, and:

- `decision=reject`: measured success/test execution regression or token increase beyond the recorded 20% / 100-token tolerance.
- `decision=inconclusive`: incomplete/too few samples, unavailable tokens or no measured benefit, including a tie.
- `decision=ready_for_review`: at least three complete samples each, candidate independent verifier success in every sample, measured success or test execution improvement, and acceptable tokens.

`futureEffect=not_measured` in all cases. Null is unavailable, never 0. These are narrow local measurements, not proof of longitudinal correction reduction or release eligibility.

## Interrupted helper execution

EOF stops RPC admission and drains requests already accepted from stdin; it does not cancel an approved command just because a normal one-frame pipe client closes. `SIGINT` and `SIGTERM` close the local runtime gate before another child command starts. A running Lab retains any already-observed child receipt, stops before another variant or verifier starts, removes only its owned worktrees, and records `eval.state=interrupted` with `interruptionReason`, `interruptedAt`, and `partialResults`. The matching approval becomes `needs_review` with `result.outcomeUnknown=true`; it is not retried, promoted, or treated as a failed measurement.

The helper waits for the active request to persist this terminal record. A bounded force-stop can target only Vela-created process groups if that wait does not complete; it does not prove cleanup or a terminal ledger write. Callers must inspect the persisted approval/eval after an interrupted transport instead of deriving state from a missing RPC response.

Lab child processes start with an explicit empty signal mask. This prevents a Dispatch worker's private blocked `SIGCHLD`/control-signal mask from reaching the provider runtime, while retaining Vela's dedicated process group and its approved shutdown handling.

## `lab.promote {id}`

Requires a completed `codex_agent` eval ready for review. Only a **memory-only candidate** can activate memory: no extra candidate file changes or unpromoted context. Promotion rechecks the frozen final context and each selected Memory against the same project, lifecycle, privacy markers, source paths and source hash used before Lab execution. Current whole-project and captured-source ingestion exclusions also apply. A changed or missing source receipt requires a new evaluation; legacy records are retained for inspection but cannot activate Memory without that receipt.

The eligibility check and activation are linked by the existing guarded SQLite/Markdown batch: it compares every selected Memory, the evaluation and the ingestion-policy revision (including an absent revision). If another helper changes a selected record or commits a policy change after validation, the entire promotion is rejected without partially activating Memory. Return shape:

```json
{"evaluation": {}, "promotion": {"id": "promotion-eval-id", "evalId": "eval-id", "memoryIds": [], "state": "active", "futureEffect": "not_measured"}, "nextStep": "..."}
```

This does not apply suggestion file operations or silently install hooks. File-only comparisons remain review evidence.

## `reuse.preview {project}`

Creates a normal suggestion object (`id/state/carrier=Hook/operations/evidence/limitations/requiresProviderTrust=true`). The CLI injects its own helper executable; the renderer cannot supply a replacement. Existing project `.codex/hooks.json` is merged without removing other hooks. Preview, apply and undo use existing `improve.*` endpoints. If the exact helper command already exists, `alreadyInstalled=true`, `operations=[]`; show that status instead of an Apply button.

After applying, Codex must trust the exact definition in `/hooks`. Vela does not change Codex trust, user-wide configuration or AGENTS.md. A disabled or untrusted hook cannot be described as working automatically.

## `reuse.outcomes {project,id}`

`id` is a memory ID. Returns `receipts`, `offeredSessions`, `matchedSessions`, `sessionIds`, positively `observedVerificationSignals`, and explicit unavailable `verificationCorrectionCount/correctionRateReduction`. `analysisCoverage=not_established`, `agentAdoption=not_measured`. Receipt delivery is `provided_to_hook_stdout`; it does not certify compliance.

## CLI-only `vela hook --project PATH --home PATH`

Consumes a bounded SessionStart JSON event on stdin, validates project/cwd, and returns the official `hookSpecificOutput.additionalContext` shape for active nonprivate scoped memory. Records an idempotent receipt. It ignores transcript paths and runs no model or workflow. Internal Lab children receive no live Vela context. `reuse.context` is **not** exposed to the renderer or MCP tool surface.

## Optional frozen Memory Recall variants (FR72)

A `baseline` or `candidate` can include a backward-compatible `recall` object:

```json
{"enabled": true, "query": "bounded clamp", "mode": "lexical", "scope": "project", "budget": 800}
```

- Omitted `recall` records `enabled:false, selection:not_requested` and retains legacy behavior. `{"enabled":false}` is explicit OFF. `strictOff:true` is allowed only with OFF and rejects `memoryIds`, for an actual Recall-OFF comparison. Non-strict OFF with `memoryIds` remains an explicit-ID injection and is labelled `memoryInjection:explicit_ids`, not Recall.
- ON accepts only MemoryService's closed `lexical`, `semantic`, or `hybrid` modes, bounded query text, exact `scope:"project"`, and an integer 1–4000 budget. Lab calls `MemoryService.recall`; it then keeps only Active, nonprivate, non-Private-Library, same-project, **project-scope** results. Candidate, global and cross-project records are not automatically included.
- The approval freezes query/mode/scope, requested/used token budget, selected IDs, content and lifecycle-source hashes, and the exact final context hash. Before each variant allocates a worktree or starts an agent, those selected sources are revalidated, including the current ingestion-exclusion eligibility. A changed body, scope, lifecycle, privacy flag/path, project or active exclusion rejects that variant without rerunning Recall or selecting a replacement.
- `memoryIds` remains the caller-selected Active/Candidate project-memory path. Before each variant creates a worktree, execution rechecks each frozen explicit source against project/scope, privacy/path, lifecycle, content and source hash, and verifies the final context hash. Older nonempty explicit receipts without source hashes must be prepared again; a source becoming private, archived, foreign or edited rejects the variant before it starts. It is not evidence that MemoryService Recall ran. A Recall result is labelled `selection:memory_service_recall`; legacy selections are labelled `selection:explicit_memory_id`.

## 可供 UI 实现的简要合同

Show a compact Recall switch, query, real supported mode, project-only scope and budget; show OFF / explicit IDs / Recall as separate states. Preview the selected count and used/requested budget from the frozen response. The approval screen must say that execution will revalidate sources and may reject stale/private/lifecycle-changed results. Do not expose raw source hashes by default, auto-enable candidate memory, or imply a measured benefit.
