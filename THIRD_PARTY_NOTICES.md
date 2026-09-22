# 第三方来源与修改

## Codenotch

- 来源：https://github.com/vinzdg/codenotch
- 参考提交：`117a38b8edae2ebd0944bc86b8760c6381685345`
- 作者：Vinz，MIT License；原文保留于 [LICENSE](LICENSE) 与 [licenses/Codenotch-Windows-LICENSE](licenses/Codenotch-Windows-LICENSE)。
- 初始 Tauri 结构来自上游 `windows/`；当前按固定 `Sources/` Swift 主线补齐逻辑、布局、图形及 Phone Link v3 协议。
- 修改：Vela 品牌、独立配置目录与端口、macOS 原生能力适配、恢复原版设置、通知与声音、配置写入可靠性、插件、用量账期、CLI 同步、测试与文档。
- `src-tauri/tests/fixtures/phone-link-v3-vectors.json` 复制上游协议测试向量；`src-tauri/glyphs/swift/manifest.json` 逐文件记录图形来源与 SHA-256。
- 所有上游 Git 对象均不属于此仓库的新历史；代码来源在本文件保留。

供应商图形标识用于识别集成，见 [glyphs/NOTICE.md](src-tauri/glyphs/NOTICE.md)。品牌属于各自所有者。

## 框架与参考项目

- [Tauri](https://github.com/tauri-apps/tauri)：MIT / Apache-2.0，依赖于 Cargo.lock。
- [CC Switch](https://github.com/farion1231/cc-switch)：参考 Tauri + Rust 跨平台方案与功能方向，本轮未复制其实现。
- [Blume](https://blume.codes)：只参考未来会话观测方向，本轮没有嵌入服务或上传数据。
- 其余 Rust / npm 依赖及许可由 Cargo.lock、package-lock.json 与各包的许可证确定。
