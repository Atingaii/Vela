# 核查结果

- 用户明确尚未开通 Apple Developer 账号。本机 `security find-identity -v -p codesigning` 为 0 个有效身份，GitHub secret list 无已配置凭据名称。
- 官网 preview.4 ARM DMG SHA-256 与发行文件相符，hdiutil verify 通过。复制至本轮临时目录后 codesign 完整性通过，Signature=adhoc、TeamIdentifier=not set；spctl 退出 3 rejected；stapler 退出 65，无票据。未运行应用、清除隔离属性或修改系统安全策略。
- Apple 首次打开步骤：https://support.apple.com/zh-cn/102445
- Tauri 明确 ad-hoc 不能免除用户在隐私与安全中的逐应用确认：https://tauri.app/distribute/sign/macos/
- 用户追问 CC Switch：当前官方安装文档声明已签名公证，v3.9.0 官方发布说明曾声明无开发者账号。不能由此断言作者个人付费；Apple 普通个人会员为 99 USD/年，有限机构资格可豁免。
  https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/en/1-getting-started/1.2-installation.md
  https://github.com/farion1231/cc-switch/releases/tag/v3.9.0
  https://developer.apple.com/programs/enroll/

规范判断：沿用 ADR 0007 的未公证预览机制，只补足信任检查与披露，无新技术栈/数据边界/部署机制，不创建新 ADR。新增 backend quality gate 规则防止混淆直接启动与下载系统信任。
