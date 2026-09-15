# Workflow read-step retry contract

Workflow step may opt in with exactly `retry: {maxAttempts, initialBackoffMs, maxBackoffMs}`. Omission means one attempt and preserves legacy behavior. `maxAttempts` is 1–3; delays are 50–5000 ms and 50–10000 ms, with `initialBackoffMs <= maxBackoffMs`.

Only fixed local reads `git.status`, `git.diff`, and `git.log` accept the policy. File writes, shell/agent commands, connectors, model calls, knowledge answers and agent loops reject it. A frozen run step records the policy and attempt receipts. The current product has no user-facing `runs.cancel` operation: runner cancellation is only a process shutdown request (`VelaRuntimeShutdown`). The helper accepts a cancellation callback so the runner can stop between attempts and during backoff, but a unit fixture callback does not imply a public cancellation feature. A recorded started attempt after a restart is `needs_review`, never replayed automatically.

The overall retry deadline is enforced before starting another attempt and while waiting for backoff. An already-started Git observation keeps its existing `AutomationProcess` timeout (currently independent, bounded process execution) and may finish after the retry deadline; the receipt records `retryDeadlineScope:"between_attempts_and_backoff"`. Vela does not claim preemptive deadline cancellation for an in-flight process.

The retry helper returns the final local read result. It does not approve actions, mutate a project, invoke a provider or claim that a non-read operation is idempotent.

A retry result without an integral process `exitCode` in 0–255 is `needs_review` with `outcomeUnknown:true`; it is never defaulted to success or retried. Every retry checkpoint and the final step update use the run ledger's compare-and-swap identity, so a concurrent run update is surfaced as a conflict rather than overwritten.
