# Workflow health timeout proposal contract

This narrow FR64 increment turns one complete `timeout_observed` record into a reviewable **disabled candidate workflow**. It does not automatically repair, enable, execute, retry, or mutate the source workflow.

| Method | Required fields | Result |
| --- | --- | --- |
| `workflows.health.proposeTimeout` | `project,workflowId,workflowVersion,snapshotHash,runId,stepId,findingId,newTimeoutSeconds` | Persists one `pending_review` timeout proposal, or rejects incomplete/stale evidence. |
| `workflows.health.proposal.get` | `project,id` | Returns the project-scoped safe proposal summary. |
| `workflows.health.proposal.list` | `project,limit?` | Returns up to 100 safe summaries. |
| `workflows.health.proposal.decide` | `project,id,proposalHash,decision,acknowledgeUncertainSource?` | `reject` changes only the proposal. `accept` creates one new disabled workflow candidate after revalidation. `recover` is accepted only from `accepting`, restores `pending_review`, and creates nothing. |

Proposal evidence is complete only when explicit project scans of both runs and approvals remain below 10,000 rows. The source must be a non-dry-run `failed` or `needs_review` run with a non-truncated step whose persisted `timedOut` is true. Private/labeled-private/path-private sources, cross-project records, stale run hashes, changed snapshots or changed versions are rejected. `needs_review` is retained as `sourceOutcomeUnknown:true`; acceptance then requires the boolean `acknowledgeUncertainSource:true`.

Only `shell.test`, `shell.typecheck`, and `agent.run` are eligible. An explicit integer `timeoutSeconds` in 1–300 is frozen; an absent value freezes the existing execution default of 120. The caller supplies the proposed integer, which must be greater than the frozen value, at most twice it, and at most 300. It preserves all other definition fields, creates a new ID at version 1 with `enabled:false`, and records that ID in the accepted proposal. The original workflow, historical run, approval ledger, argv, path, retry policy and execution state are never altered. No model/provider call occurs.

## 中文

本合同只支持把一条完整 timeout 观察变成新 ID、`enabled:false` 的候选工作流。accept 会重新核验冻结证据；它不修改或重放原活动 workflow。来源为 `needs_review` 时必须显式确认不确定性，且不表示改善已经得到证明。

## Interrupted acceptance

`accepting` is a claim state, never evidence of a created candidate. If the process is
interrupted after the claim, callers must explicitly submit the same proposal hash with
`decision:"recover"`; Core CAS-transitions it back to `pending_review` and records the
interruption. Recovery never creates or retries a candidate. Final candidate creation
CAS-protects the claimed proposal, the inspected run, and the persisted workflow record;
it re-inspects the workflow immediately before the transaction. A changed source record
or inspected asset is refused rather than cloned. If the CAS detects another writer,
recovery or invalidation does not overwrite that concurrent proposal state.
