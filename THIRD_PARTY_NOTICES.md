# 第三方来源与修改

## Codenotch

- 来源：https://github.com/vinzdg/codenotch
- 参考提交：`117a38b8edae2ebd0944bc86b8760c6381685345`
- 作者：Vinz，MIT License；原文保留于 [LICENSE](LICENSE) 与 [licenses/Codenotch-Windows-LICENSE](licenses/Codenotch-Windows-LICENSE)。
- 本项目主要移植上游 `windows/` 的 Tauri 实现，参考 `Sources/` SwiftUI 的交互和布局。
- 修改：Vela 品牌、独立配置目录与端口、macOS 原生能力适配、设置精简、通知开关、配置写入可靠性、插件、用量账期、CLI 同步、测试与文档。
- 所有上游 Git 对象均不属于此仓库的新历史；代码来源在本文件保留。

供应商图形标识用于识别集成，见 [glyphs/NOTICE.md](src-tauri/glyphs/NOTICE.md)。品牌属于各自所有者。

## 框架与参考项目

- [Tauri](https://github.com/tauri-apps/tauri)：MIT / Apache-2.0，依赖于 Cargo.lock。
- [CC Switch](https://github.com/farion1231/cc-switch)：参考 Tauri + Rust 跨平台方案与功能方向，本轮未复制其实现。
- [Blume](https://blume.codes)：只参考未来会话观测方向，本轮没有嵌入服务或上传数据。
- 其余 Rust / npm 依赖及许可由 Cargo.lock、package-lock.json 与各包的许可证确定。
