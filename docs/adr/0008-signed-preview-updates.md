# ADR 0008：独立预览更新索引与应用包签名

状态：Accepted（实现进行中）

2026-09-23：本记录的平台资产范围由 [ADR 0009](0009-macos-first-delivery.md) 取代，当前 feed 只交付两种 Mac 架构；签名、公钥和原子索引发布约束继续适用。

## 背景

完整迁移包括原版的更新功能。当前预览版配置仍使用占位公钥，没有生成 Tauri 更新包；更新地址指向 GitHub 的最新正式 Release，不能作为预览版通道。缺少 Apple Developer 账号影响 macOS 的首次系统信任，但不阻止生成和验证 Tauri 应用更新签名。

## 决策

使用专用 `updates-preview` Git 分支发布静态 `latest.json`，客户端读取 `https://raw.githubusercontent.com/Atingaii/Velo/updates-preview/latest.json`。索引内的平台下载地址固定到不可变的 Release tag；应用版本和 tag 使用一致、递增的 preview SemVer。

仅在 macOS arm64、macOS x64 和 Windows x64 的构建、安装 smoke、更新包及签名全部齐备后，发布流程才原子更新索引。公钥随源码和应用发布；私钥和密码只保存在维护者的系统凭据库及 GitHub Actions Secrets，不进入仓库、任务记录或日志。客户端验签后才能将包交给安装器。

延用既有 GitHub Release 产物托管和 CI，不为更新引入 Cloudflare 运行时或额外后端。相较于客户端解析 GitHub Release API，静态索引保持 Tauri 原生格式，并避免客户端处理预览筛选和 API 限流。

## 后果与验证

本决策替代 [ADR 0007](0007-velo-preview-distribution.md) 中“因占位公钥关闭自动更新”的临时措施；品牌、内部标识、官网托管和操作系统信任边界继续适用。应用更新签名不等于 Developer ID 签名或公证，首次安装仍遵循明确的未公证预览版引导。

必须验证旧版到新版的下载、验签、取消自动更新和安装交接，拒绝被修改的包、缺少平台的索引及非递增版本。采用决策不代表该链路已经验收完成。
