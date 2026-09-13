# AI SDK integration acceptance / AI SDK 集成验收

This is a separate slice after checkpoint `b94707ff41620b3928dede2b8eefe49f90f1f64c`; its results do not rewrite that checkpoint.

2026-09-13, Node 24.19.0, AI SDK 7.0.99, provider interface 4.0.14, OpenAI adapter 4.0.66:

- **17/17** installed AI SDK tests, actual `generateText` / `streamText` to a synthetic loopback HTTP/SSE provider, and explicitly selected real Vela helper/stores. Boundary cases additionally use labeled legacy/malformed Core fixtures. No external model or real credentials.
- **12/12** existing TypeScript SDK tests against the newly installed SDK package, plus consumer TypeScript compilation and `npm ls --all`.
- **1/1** additional actual old SDK tarball installation: read-only generation still works; auto-capture fails before provider dispatch, with zero writes.
- **5/5** Core integration methods using the portable fallback runner, **not XCTest**. Source snapshot `69b28aabd1f5ed55a33eeeb85caa177a40e7cd57c68d028e58d910caa2fccec9`; owned Core/test source hashes still match. Full product/XCTest acceptance belongs to its independent checkpoint.

The tests cover exact namespace/active/non-private injection; instructions, tools, image-file parts and provider options; complete streaming; AbortSignal/explicit close; default zero capture; candidate provenance and replay after review; concurrent namespace isolation and same-turn overlap rejection; filtering/escaping/byte limits; unsupported source combinations; and real candidate commit followed by lost acknowledgement. The last case returns the successful model response, marks capture `uncertain`, and sends no retry. Model output is not automatically captured.

| Artifact | SHA-256 | Bytes |
| --- | --- | ---: |
| AI package | `19e56c0058eb0ba8e9d1e08e3a1184511e60f957f24832058a0727427fae745a` | 11,820 |
| Local TypeScript SDK package | `ab2e0aef01410ffefe1c78d3923cd3ad84a35d3a801042d68119b0819ef8bb9d` | 10,626 |
| Frozen helper | `3dd60c6dea13868ad2f5006152f6acaa417d493dc89516ef51301b0097628e1e` | — |
| Retained pre-AI SDK | `02213e99bd1a2d7ac09e263579e891fb54365cc104147ab4c626a5c6aff8db9e` | — |

Each package contains exactly package metadata, license, README, JavaScript entry and declaration entry. Tests, internal evidence, source, credentials and development dependencies are excluded. Installed entry/declaration bytes were compared to the frozen current build.

Local detailed artifacts: `sdk/ai/evidence/installed-v6/package-results.json`, `source-freeze.json`, `actual-ai-sdk-tests.log`, `legacy-sdk-tests.log` and tarballs. Earlier failed installation/consumer attempts remain separately preserved; missing Zod/ESM test resolution and outdated test API usage were resolved before this acceptance.

Reproduce after building the helper and installing/building `sdk/typescript`: run `npm ci --ignore-scripts` in `sdk/ai`, then `python3 scripts/test-ai-integrations.py`. Select a retained old package with `VELA_AI_LEGACY_SDK_PACKAGE` for the additional legacy test; absence of that artifact is reported as not run. Each run gets a separate evidence directory. All temporary consumer installations, helper copies, synthetic stores and their caches are removed; reusable package dependencies and acceptance artifacts remain.

中文：本轮交付的是经过真实安装和协议验证的本地 TypeScript 中间件。网络地址声明并不代表网络身份已验证；停止下游 tee 不等于底层流已取消，调用方须使用 AbortSignal 或 close。模型生成成功与记忆写入未知分别报告，不自动重发。Python、LangChain、远端 analyze、真实模型质量和完整 Walrus parity 仍需各自实现与验收。
