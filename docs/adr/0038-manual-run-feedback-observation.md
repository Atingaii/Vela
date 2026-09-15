# ADR 0038: Manual run feedback is bounded observation evidence

- Status: Accepted
- Date: 2026-09-14

## Decision

`runs.feedback.prepare` reads one registered-project terminal, non-private, non-dry run and returns its exact `runHash`. `runs.feedback.record` accepts only `{project,runId,runHash,previousFeedbackHash,outcome,reason}`, where outcome is `good`, `bad`, or `clear`; the reason is bounded to 1,000 UTF-8 bytes, contains no control characters, and must pass existing secret redaction unchanged. The service re-reads the run and creates an immutable deterministic feedback record in a single CAS batch expecting the reviewed run hash. Exact replay returns the existing record. A changed outcome requires the prepared current `previousFeedbackHash`; the prior record is retained as immutable audit history. `clear` withdraws the current good/bad observation. Stale hashes, another project, private sources, invalid bounds, and conflicting revisions fail without a write.

Health consumes only feedback whose current run remains eligible and whose current hash still equals the recorded hash. It reports manual-observation counts and project detail, while leaving `successRate`, execution, approvals, candidate promotion, and model calls unchanged. Feedback is not an objective outcome or evidence that a model improved.

## Consequences

The UI/native bridge can show a review snapshot then submit the returned `runHash`; it must never send a source/provenance field. No renderer or native bridge ships in this ADR. A later API may add pagination without changing the frozen record shape.
