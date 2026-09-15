# Reference downloads / 参考资料下载

Recorded 2026-09-13. These are local reference copies, separate from Vela source and release packages. No third-party source, installation script or agent was executed.

| Reference | Retrieved baseline | Verification and boundary |
| --- | --- | --- |
| [Walrus Memory / MemWal](https://github.com/MystenLabs/MemWal) | `493c9e66851e1b542ce5f55a547827f64e141c45` | Full public Git repository; Apache-2.0 license retained. |
| [px0 workflow product](https://github.com/px0-ai/px0/commit/df7e6eba9df7759cb0c924ac84563a7874bfb051) | `df7e6eba9df7759cb0c924ac84563a7874bfb051` | Original workflow commit retrieved directly from official remote, after locating its SHA through a public fork parent. |
| [Blume official macOS download](https://updates.blume-page.com/desktop/stable/download-info?platform=mac) | `Blume-1.0.74-arm64.dmg` | 188,597,393 bytes; SHA-256 `7058008a6224025f39d16f116aee2e6f54535f632358923fe97b8073ba5651df`; image checksum verified by `hdiutil verify`. App signing was not verified because the read-only attach did not expose an app filesystem; attached image was detached. No app installed or launched. |

The Blume repository named in the user-provided report returns HTTP 404 without authentication. Its private source was not downloaded. Public behavior and the user-provided product report remain the comparison inputs; private prompts and extracted assets are not incorporated in Vela.

px0's current default branch is a different, read-only IDE product at `012194dc2e67280ad934f9bc174fa052e37cf596`. That repository was also downloaded and its identity recorded, but it does not silently replace the original workflow requirements. The original workflow documentation remains at [docs.px0.ai](https://docs.px0.ai/). New changes are audited separately against the frozen 120-item inventory.

Local copies are retained in the sibling `Vela-reference-sources` directory for feature-by-feature inspection. The [machine-readable manifest](reference-downloads-2026-09-13.json) records commits and content hashes. Download completion is not feature coverage or acceptance.

## 中文

已下载两个公开参考项目的完整 Git 源码，并保留原 px0 工作流提交；Blume 下载的是官方 1.0.74 安装包，私有仓库不公开。下载物均保留为独立参考，不进入 Vela 应用或仓库。每项能力仍需对应 Vela 实现、本机运行证据和反例测试；下载记录不能替代功能验收。
