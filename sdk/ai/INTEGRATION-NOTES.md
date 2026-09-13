# Integration notes / 集成说明

This package is the next slice after checkpoint b94707ff41620b3928dede2b8eefe49f90f1f64c. It must not retroactively change that checkpoint's acceptance facts.

- Core `memory.integration.capture` accepts exactly `openclaw` and `ai-sdk-v4`, stores the actual integration in provenance, and preserves candidate/private/namespace/create-only rules.
- Scoped `memory.integration.stats` adds `supportedIntegrations`; no new arbitrary RPC or authorization mechanism exists.
- Local TS `captureIntegration` accepts an optional exact `integration` union in final request options. Existing OpenClaw callers retain the default. `MEMORY_INTEGRATIONS` advertises the SDK's supported union.
- AI SDK capture verifies both the new SDK and Core support before dispatching a model request. It never probes compatibility by attempting a write or mislabels captures as OpenClaw.
- Installed acceptance: 17 real AI SDK integration cases, 12 base SDK compatibility cases, one separately installed legacy SDK case. Exact package/helper hashes and boundary evidence are recorded in `VERIFICATION.md`; no external model/remote-memory/wallet validation is implied.

ADR 0026 and the interface contract now distinguish the accepted local TypeScript path from remaining work. Python wrappers and reviewed remote analysis have not been implemented here. The package provides no fictional compatibility adapter for those remaining capabilities.
