# Observed Session Memory Capture contract / 已观察会话记忆捕获合同

`memory.capture.prepare` and `memory.capture` are local helper RPC methods for a
single already-indexed user or assistant message. They require a registered project
and never inspect raw provider files or relation/history paths.

## Prepare

```json
{"project":"/absolute/project","sessionId":"vela-session-id","messageId":"provider-message-id"}
```

The response includes `protocol`, `project`, `sessionId`, `messageId`, `role`,
`content`, `contentBytes`, `sourceIdentity`, and `expectedSourceHash`. The hash covers
that selected indexed message and source identity, so an unrelated later message does
not stale it. This re-reads Vela's persisted indexed record; it does not re-open or
verify the provider file on disk. `content` is
available only after Core's same-project visibility checks. It is bounded to 32 KiB
and must be free of the existing credential-redaction patterns. The response says
`state:"candidate"`, `sourceObservation:"observed"`, and `modelCalls:0`; it is not
a write or a claim of complete provider history.

## Capture

```json
{
  "project":"/absolute/project",
  "sessionId":"vela-session-id",
  "messageId":"provider-message-id",
  "sourceIdentity":"codex:provider-thread-id",
  "expectedSourceHash":"64-lowercase-hex"
}
```

No title, content, source path, scope, state, provenance, authority, or model
parameter is accepted. Core re-resolves the session/message, verifies the prepared
identity and snapshot, then writes a project-scoped `observation` in `candidate`
state. A newly created result is `requiresReview:true`; it never activates the
Memory or calls a model. Repeating the identical source returns
`created:false,idempotent:true` and preserves its current content, lifecycle state,
review flags, and any user-derived label. It does not reactivate or restore source
content. Changing the same source identity/message after a prior capture fails rather
than overwriting the candidate.

Eligible sessions have a supported provider, the selected registered project, normal
project scope, no private/source-labelled-private/internal flag, and no private
source path. The exact message must occur once, be a user or assistant message, and
have no private flag, NUL, credential pattern, or content over 32 KiB. All failures
occur before a Memory write.

## Provenance and edits

Captured provenance stores the protocol, stable capture identity, source snapshot
hash, original-content hash, provider/session/message identifiers, and bounded-source
coverage statement. Generic `memory.save` cannot set or replace capture provenance or alter source
session/message/file/commit fields (it may repeat their existing values for form
compatibility). If a later normal edit changes the content, provenance remains linked to the original
message and gains `contentEqualsObservedSource:false`, `derivedBy:"user_edit"`, and a
timestamp. It must not be displayed as if the edited content were the original source.

## SDKs

The TypeScript client exposes `prepareSessionCapture` and
`captureSessionCandidate`; Python exposes `prepare_session_capture` and
`capture_session_candidate`, with async counterparts. Both validate IDs, identity
and hash locally, then use the existing `rpc --no-watch --no-schedule` transport.
Transport failure after capture request dispatch remains potentially uncertain and is
not retried automatically.
