# Velo 品牌、发布与官网

用户明确授权：仓库随 velo.codes 更名 Velo、填写 About、完成 CI/CD、发布安装包、重写既有官网并部署 Cloudflare。

## 交付
- GitHub 仓库 Velo、描述、官网与 topics；当前品牌与下载入口统一。
- macOS Apple Silicon / Intel DMG 与 Windows x64 NSIS 安装包，校验和、安装说明与真实发布链接。
- release gate：Node / Rust / 浏览器检查、原生 WebView + IPC smoke、包内 helper、安装或挂载产物检查；全部通过才发布预览版。
- 官网保留旧站白底网格、黄按钮、大标题与深浅模式方向；新文案聚焦屏幕边缘额度/活动产品，真实下载链接与开发阶段边界。
- Cloudflare 既有 Pages 项目 velo，保持 velo.codes 域名；部署并验证线上静态资源和下载链路。

## 边界
- 不将未完成全量迁移或未验收真实账户宣传为完成。
- 没有签名证书：macOS ad-hoc，未公证；Windows 未签名。发布明确预览版，说明 OS 首次打开要求，不能承诺无系统提示。
- 保留内部 vela 配置目录、bundle ID、keychain 服务与 helper 名称，避免品牌更名丢失数据；可见品牌及主应用名称改 Velo。
- 不改供应商实现，不推进尚未验收的插件扩展。不删除旧站之外的 Cloudflare 项目。
