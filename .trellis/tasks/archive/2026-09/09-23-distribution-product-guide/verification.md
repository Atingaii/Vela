# 验收与边界

完成现有授权的未公证开源软件安装流程：下载后引导、Mac 单独允许步骤与排障、产品说明导航和当前 UI 五张高清截图。正式站四页 1440/390/320px 与真实下载、图像放大、焦点恢复、主题、安装帮助通过。

Gatekeeper 在本机与 GitHub runner 均拒绝未公证包，已独立记录。用户选择未开通开发者账号阶段的手动确认流程，不把此限制标为已消除。原生隔离 smoke 成功，常规 macOS/Windows/browser CI 全绿。现有发行说明及信任附件更新；没有新发布同类未公证二进制。

证据：docs/evidence/distribution-product-guide/README.md。规范新增 distribution-trust.md 与 quality/index 引用，防止将 ad-hoc 完整性或直接启动混同默认系统信任。沿用 ADR 0007，无长期架构变更。

本轮临时预览服务、Chrome 测试会话、下载与挂载复制产物在收尾移除；最终截图、源码、报告与可复用依赖保留。
