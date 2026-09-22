# ADR 0007：Velo 品牌与可验证的预览发行

状态：Accepted

## 决策

用户指定官网 velo.codes，并授权仓库与产品更名 Velo、发布安装包及重写 Cloudflare 官网。

可见品牌和主可执行文件统一 Velo / velo，仓库 Atingaii/Velo。内部 `com.atingaii.vela` bundle ID、`vela` 数据目录、`Vela` 凭据服务、LaunchAgent / 启动项标识与 `vela-hook` 保留，避免名称更改导致丢失凭据、重复 hooks 或破坏旧配置。此轮不迁移磁盘身份。

GitHub tag 驱动预览发布。浏览器 gate 后串行构建 Apple Silicon、Intel 与 Windows 安装包，各自执行 Rust 测试、安装/挂载产物和真实 WebView + IPC smoke；全部通过才能发布，附 SHA-256 与机器报告。smoke 仅在显式 `--smoke-test <空目录>` 时开启，独立配置、跳过采集与账户发现，不表示真实供应商验收。

当前没有 Developer ID 或 Windows 代码签名证书；macOS 采用 ad-hoc、Windows 未签名，只发布标注系统首启要求的预览版。不启用占位公钥的自动更新。正式发行需要签名、公证和完整验收后另行推进。

官网使用无框架的静态 HTML/CSS/JS，部署既有 Cloudflare Pages `velo`，保持域名。安装包由 GitHub Releases 托管，下载页使用明确的预览 tag。此轮不引入后端服务、账户系统或收费依赖。

## 后果

可以重复核验下载产物与安装启动路径；操作系统初次信任和真实账户效果仍有独立边界。旧内部标识有意保留，后续若要更名需显式数据与凭据迁移方案。
