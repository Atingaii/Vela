# ADR 0043: Apply ingestion exclusions to captured-Memory recall

- Status: Accepted
- Date: 2026-09-14

## Context

An ingestion exclusion already prevents future provider-session projections and retracts
existing derived projections. It must not leave an automatically recalled Memory from the
same excluded source available merely because that Memory is retained for user management
or its source Session projection has since been withdrawn.

A source rule is relative to a configured provider ingestion root, not a repository root.
Persisting every source session identifier on a rule would be unbounded and would fail once
those derived Session records are retracted.

## Decision

Core writes a bounded `{provider, relativePath}` snapshot onto a Session only when its source
is under that provider's configured ingestion root. A new observed-session Memory capture
copies that snapshot into its protected capture provenance. Capture writes carry the active
policy-generation CAS precondition, so a concurrently committed rule makes the stale
create-only write fail and requires a new capture attempt.

For pre-snapshot observed captures, Core accepts the existing protected
`provenance.provider` and absolute `provenance.sourcePath` only when they map, with the same
provider, beneath a currently configured ingestion root. If a trusted legacy capture cannot
be mapped after a root change, an active source rule for that provider fails closed; this does
not apply to user-created or imported Memory. This compatibility mapping does not consult a
Session record. Source rules never infer provenance from a project path, a missing
Session, or arbitrary user metadata. The public Memory editor reserves capture provenance;
ordinary user/imported assets are not source-rule candidates. Whole-project exclusions suppress automatic use for that selected project context, including global and namespace candidates that would otherwise be injected into it; another allowed project may still use lawful global Memory.

`MemoryService` lexical recall, semantic vector/hybrid retrieval, semantic recent results,
and the semantic index all apply this eligibility gate from one bounded, call-local rule
snapshot, rather than reading the rule table once per candidate. Vector rows are derived data
and may remain transiently on disk, but excluded rows are never returned and an index pass
removes them. The vector write also rechecks eligibility inside its write transaction.
Knowledge/Ask candidate and verification paths, MCP agent-tool list/read/recall, workflow
approval (including composition), and every agent-loop round take the same gate before they
make an external call or launch an approved process. Lab explicit and frozen recall receipts
also revalidate it before an approved execution starts. Workflow approval uses its frozen
Memory receipt only to check current scope/private/exclusion eligibility: an ordinary body edit
does not replace frozen argv/prompt or change its approval hash. These execution checks are
fresh; the read snapshot is deliberately not a linear revocation promise for an already-returned result.

Memory objects, user files, and the Memory management listing remain retained. Rule removal
restores eligibility for retained eligible records; it does not recreate Session projections or
claim a strong linear revocation for a read already in progress.

## Consequences

The rule table remains bounded (256 rules per project) and contains no source-ID list. The
compatibility path depends on currently configured ingestion roots: when a trusted old capture
cannot resolve its exact relative source under those roots, it remains a managed Memory but is
withheld while a source rule for the same provider is active. `FoundationService` installs the
configured-root mapper on every opened store, so fresh Memory/SemanticMemory instances use the
same mapping without looking up a withdrawn Session. A UI management entry is still outside this
ADR's Core-only scope.
