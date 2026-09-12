# Security policy

Vela reads sensitive local development records and may execute user-approved workflows. Security boundaries are part of the product's core behavior.

## Supported versions

During initial development, security fixes target the latest `main` revision and the latest preview release. Preview binaries are not production-hardened releases. No older-version support commitment is currently made.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/Atingaii/Vela/security/advisories/new). Include affected version, reproducible steps using synthetic data, expected boundary and observed result. Do not include real API keys, messages, source code from private repositories or unredacted provider logs. Please allow maintainers to investigate before disclosure. No guaranteed response SLA or bounty is offered.

## Trust boundaries

- Session adapters read supported local formats; provider logs are untrusted input.
- Desktop UI calls an enumerated local RPC interface. No generic renderer shell API is exposed.
- MCP defaults to READ; optional contribution creates candidate memories/checkpoints. MCP cannot execute workflows or apply suggestions.
- Private Library content is excluded from agent retrieval even when its keywords match.
- Workflow write actions require an immutable, hashed approval. Project test scripts are executable code and also require approval.
- Safe Apply checks allowed roots and current content hashes, records before/after state and refuses path escapes.
- Telemetry is disabled. Vela has no hosted session store or account service.
- A user-approved invocation of an external coding agent uses that provider's network and policies. “Local-first” does not mean a remote model runs locally.

This document describes intended boundaries; see tests and [known limitations](docs/status.md) for the verified scope. A local attacker with the same user's filesystem privileges is outside the application's isolation boundary.

## Release authenticity

Development builds may use ad-hoc code signing. Only a release explicitly documenting Developer ID signing and successful Apple notarization should be treated as notarized. Verify the SHA-256 checksum supplied with the release. Never disable system-wide Gatekeeper protection to install Vela.
