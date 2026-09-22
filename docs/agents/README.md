# 仓库开发工具

- Trellis：`@mindfoldhq/trellis@0.6.17`，作为开发依赖锁定，`npm ci` 恢复，`npm run trellis -- --version` 查看版本。已用 `--codex --user Atingaii` 初始化。
- Grill：来源 `mattpocock/skills`，具体提交和文件 SHA-256 见 `tooling-lock.json`；技能在 `.agents/skills/`，没有安装其他同名项目。下一轮可通过 `$grill-me` 或 `$grill-with-docs` 使用。
- 项目规范在 `.trellis/spec/`，现有 ADR 在 `docs/adr/`，共享术语在 `CONTEXT.md`。当前使用单会话实现，自动 journal 提交关闭，worker 上限 1。
- Codex hooks 文件已生成；宿主是否启用 hooks、是否完成宿主自身的首次信任检查取决于运行环境。手动入口始终可用：`python3 .trellis/scripts/get_context.py`。初始化不修改用户全局配置。
- 技能与开发框架不会打包到 Vela 应用；不会运行常驻服务。初始化不等于完成产品迁移。

更新 Trellis 时先检查 `npm run trellis -- update --help`，review 模板差异并保留本仓库约束；grill 更新必须显式选定提交，不自动跟随 main。
