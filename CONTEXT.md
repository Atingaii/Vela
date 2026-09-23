# Velo

Velo 在桌面边缘呈现 AI 工具的用量与会话状态，并提供跨 CLI 的辅助能力。

## Language

**供应商**：提供 AI 服务或本地模型运行能力的来源。

**账户**：同一供应商下具有独立登录、额度和会话的身份。

**额度窗口**：供应商按特定周期计算的一份用量和上限，例如五小时或每周额度。

**主窗口**：圆环优先展示的额度窗口；缺失时不能用不同周期冒充。

**读取启停**：是否读取某个账户的状态和用量，与是否显示圆环分别控制。

**全量迁移**：保留 Codenotch Swift 主线已存在的功能与交互，同时让 macOS 和 Windows 使用同一产品实现。

## 发行与身份

公开品牌和仓库为 Velo，官网 https://velo.codes。配置、凭据库与 hook 继续使用既有内部标识以兼容已有数据；见 [ADR 0007](docs/adr/0007-velo-preview-distribution.md)。安装包通过 GitHub Actions 的安装启动 gate 后发布预览版；官网使用 Cloudflare Pages 的静态站点。

自动更新当前仍处于占位公钥阶段。正在按 [ADR 0008](docs/adr/0008-signed-preview-updates.md) 接入签名更新包与独立预览索引；完成前不把更新入口视为可用能力。
