# Velo

Velo 在桌面边缘呈现 AI 工具的用量与会话状态，并提供跨 CLI 的辅助能力。

## Language

**供应商**：提供 AI 服务或本地模型运行能力的来源。

**账户**：同一供应商下具有独立登录、额度和会话的身份。

**额度窗口**：供应商按特定周期计算的一份用量和上限，例如五小时或每周额度。

**主窗口**：圆环优先展示的额度窗口；缺失时不能用不同周期冒充。

**读取启停**：是否读取某个账户的状态和用量，与是否显示圆环分别控制。

**全量迁移**：保留 Codenotch Swift 主线已存在的功能、UI、视觉和交互。当前仅推进 macOS 的完整迁移与验收；Windows、Linux 保留在规划中，等待用户明确启动，见 [ADR 0009](docs/adr/0009-macos-first-delivery.md)。跨平台技术路线和已有兼容代码保留。

## 发行与身份

公开品牌和仓库为 Velo，官网 https://velo.codes。配置、凭据库与 hook 继续使用既有内部标识以兼容已有数据；见 [ADR 0007](docs/adr/0007-velo-preview-distribution.md)。安装包通过 GitHub Actions 的安装启动 gate 后发布预览版；官网使用 Cloudflare Pages 的静态站点。

源码已按 [ADR 0008](docs/adr/0008-signed-preview-updates.md) 配置实际签名公钥与独立预览 feed。当前正按 ADR 0009 将构建、发布和升级验收收敛到 Apple Silicon / Intel Mac；新版本尚待安装包和真实升级验证，不能把已配置的更新入口视为已验收能力。
