# Working on Vela

## Product boundaries

Read `README.md` and `docs/architecture.md` before substantial changes. `docs/status.md` distinguishes implemented behavior, tested guarantees and roadmap items. Keep them consistent with code.

- macOS local-first engineering support above coding agents; no new agent framework or hosted conversation service.
- Project-scoped data is isolated by default. Private Library must never reach agent retrieval, workflows or model prompts.
- All statistics require real evidence. Missing usage, quota, model identity or process liveness is unavailable, not zero or an invented value.
- Provider formats are untrusted. Use bounded streaming reads and sanitized fixtures.
- No copying proprietary reference code, private prompts, branding or extracted assets.

## UI implementation

On 2026-09-14, the initiator explicitly authorized Codex to implement the desktop and website UI directly, superseding the earlier Gemini authoring requirement. Use this current authorization; retain earlier provenance as historical evidence only. Keep credentials out of source and logs. Use familiar, readable developer-tool interactions with a restrained neutral palette, clear primary actions and progressive disclosure. Desktop layout should take inspiration from Codex without copying proprietary code or assets.

## Engineering

- Prefer the existing Swift/system framework stack; changes to runtime, persistence, public interfaces or deployment need an ADR.
- Never expose arbitrary shell or filesystem primitives through renderer or MCP.
- Dry runs stub every potentially mutating operation, including project test scripts.
- Approval applies to frozen arguments exactly once. Do not automatically retry uncertain side effects.
- File writes validate allowed roots, hashes and filesystem identity; retain recovery journals.
- Apply meaningful tests to safety and runtime changes. Use `swift test`, `python3 scripts/test-rpc.py`, and `python3 scripts/check-repository.py` as appropriate.
- Reuse synthetic fixtures and isolated data stores; do not touch real user configurations during tests.
- Keep packaged files on an explicit allowlist. Never ship tests, source, internal plans, real session data or secrets.
- Delete only disposable artifacts created by the current task; preserve deliverables and reusable dependencies.

## Communication

Use concise, factual Chinese for collaboration unless asked otherwise. Keep public documentation available in English and Chinese. Report actual verification and limitations rather than equating a successful build with product completion.
