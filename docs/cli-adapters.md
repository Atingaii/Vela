# CLI 适配约定

核对日期：2026-09-22。默认用户目录；本版不自动识别启动参数、自定义配置根目录或组织管理层。

| 能力 | Claude Code | Codex | Gemini CLI |
| --- | --- | --- | --- |
| 供应商 | `~/.claude/settings.json` 的 env | `~/.codex/config.toml` 的 model / model_provider / model_providers | `~/.gemini/settings.json` + `~/.gemini/.env` |
| MCP | `~/.claude.json` 的 mcpServers | `~/.codex/config.toml` 的 mcp_servers | `~/.gemini/settings.json` 的 mcpServers |
| Skill | `~/.claude/skills/<id>/SKILL.md` | `~/.agents/skills/<id>/SKILL.md` | `~/.gemini/skills/<id>/SKILL.md` |
| 本地 token 账本 | 默认 projects JSONL | 默认 sessions JSONL | 暂未实现 |

跨平台指操作系统。供应商 API 协议仍有区别，选择 CLI 时需使用兼容的供应商。

中立 MCP 格式包含 id、transport、command、args、url、env_vars。stdio 环境变量转换：Claude/Gemini 使用 `${NAME}` 引用，Codex 使用 env_vars 白名单。HTTP 转换为 Claude type=http+url、Codex url、Gemini httpUrl；自定义认证头不在本版中立子集。

可移植 Skill 的中立格式是 id、description、instructions。导出生成共有 YAML frontmatter。附带 scripts/references/assets 的目录导入与平台专属工具名称翻译不属于本版实现；现有目标附属文件不删除。

密钥变量需在 CLI 与 Vela 启动环境中可见。Claude 的目标 settings env 会移除旧 ANTHROPIC_AUTH_TOKEN，避免它优先于新 API key；外部进程环境或组织策略依然可能覆盖。Gemini 会选择 gemini-api-key 认证并设置 GOOGLE_GEMINI_BASE_URL。Codex 使用 Responses wire_api，不负责协议转换。

正式文档来源：

- [Claude MCP](https://code.claude.com/docs/en/mcp)
- [Claude settings](https://code.claude.com/docs/en/settings)
- [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Codex skills](https://learn.chatgpt.com/docs/build-skills)
- [Gemini MCP](https://geminicli.com/docs/tools/mcp-server/)
- [Gemini configuration](https://geminicli.com/docs/reference/configuration/)
- [Gemini skills](https://geminicli.com/docs/cli/skills/)

这些是独立客户端格式适配，用户仍应在 CLI 中检查 `/mcp`、skill 列表和实际选中的模型。配置测试证明文件转换，不证明某个外部供应商可用。
