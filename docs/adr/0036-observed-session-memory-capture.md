# ADR 0036: Verified observed Session-message Memory capture / 已核验的观察会话消息记忆捕获

- Status: Accepted
- Date: 2026-09-13
- Scope: Local Memory capture API, source-provenance integrity and SDK boundary

## Context / 背景

The desktop can prefill a generic Memory form from an indexed session message, but a
caller-controlled `memory.save` body and provenance fields cannot establish that a
candidate came from that message. In particular, a stale source, a private/internal
session, a repeated message ID, or a caller-supplied source path must not become
reusable project context. This decision adds a narrow Observe → Remember path; it
does not add model extraction, authority ranking, provider-history import, or a new
runtime.

## Decision / 决策

Core exposes two local RPC methods:

- `memory.capture.prepare` resolves exactly one persisted, registered-project
  session/message and returns its current `sourceIdentity` and
  `expectedSourceHash`. The hash covers the selected message and source identity,
  not unrelated later session messages; capture still rechecks current session visibility
  and uses a whole-session CAS for its create.
- `memory.capture` requires both values and re-resolves the record inside the write
  operation. It copies no caller text, title, source path, or provenance.

Only supported provider sessions in the same registered project are eligible. Core
rejects private, source-labelled-private, internal, malformed-scope, private-path,
missing, duplicate-ID, tool-role, NUL/control-ID, credential-pattern and over-32 KiB
messages. Capture uses the already indexed record only; it does not open provider
files, history sources, relation events, or arbitrary paths. A bounded indexed
message is evidence of that message, not an assertion that complete provider history
was observed.

The candidate identity is stable for `(project, provider, source identity, Vela
session ID, message ID)`. Replaying the identical source hash returns the existing
record without changing its content, state, or review fields; it does not implicitly
activate or restore a user-edited capture. A changed source under that identity is
refused rather than overwriting its evidence. The write is `createOnly` with a session CAS expectation. Every capture
is an `observation`, `candidate`, `requiresReview=true`, and `modelCalls=0`; it never
activates, recalls, invokes a provider, or changes ordinary `memory.save` behavior.

Capture provenance is Core-managed. Generic `memory.save` rejects capture-reserved
metadata. The source-session/message/file/commit fields are immutable: a generic
save may repeat their stored values for form compatibility but cannot change them.
Editing captured content preserves its immutable observed-source identity, records
`originalContentHash`, and marks the record as user-derived when content no longer
equals the source. The displayable provenance describes an observed source; it
is not the authority-ranking feature, which remains separate work.

TypeScript and Python SDKs expose typed prepare/capture calls through their existing
explicit local helper transport. They do not expose arbitrary RPC or provider paths.

## Alternatives / 取舍

- Trusting UI or SDK prefilled text was rejected because it cannot resist stale,
  cross-project, or forged provenance.
- Reading raw history during capture was rejected because it would introduce a new
  filesystem boundary and bypass indexed-source privacy decisions.
- Auto-activating a captured fact was rejected because observing a message does not
  make it reviewed long-term context.
- Using a new generic authority field was deferred to the authority/ranking decision;
  this change records only the source observation fact.

## Consequences / 后果

A UI may use prepare then capture, and must handle a stale-source refusal by
reloading the source. Existing generic Memory save remains available for user-authored
notes but cannot claim capture provenance. SDK timeouts retain their normal uncertain
mutation semantics. The exact API and limits are recorded in the implementation
contract; tests cover idempotency, source changes, privacy/internal boundaries,
duplicate identities, size limits, and post-capture edits.

## English summary

Session-message capture is a Core-verified, candidate-only local path. It copies one
current indexed user/assistant message after project, privacy, identity and snapshot
checks, then preserves immutable source evidence across later user edits. It neither
reads provider files nor promotes a Memory, and it does not introduce authority
ranking or model extraction.
