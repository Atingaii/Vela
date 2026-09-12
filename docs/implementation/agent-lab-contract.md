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

## `lab.promote {id}`

Requires a completed `codex_agent` eval ready for review. Only a **memory-only candidate** can activate memory: no extra candidate file changes or unpromoted context. Source suggestion hash and current memory content/scope/privacy must still match. A guarded SQLite/Markdown batch rejects concurrent changes. Return shape:

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
