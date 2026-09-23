<!-- TRELLIS:START -->
# Trellis Instructions

These instructions are for AI assistants working in this project.

This project is managed by Trellis. The working knowledge you need lives under `.trellis/`:

- `.trellis/workflow.md` — development phases, when to create tasks, skill routing
- `.trellis/spec/` — package- and layer-scoped coding guidelines (read before writing code in a given layer)
- `.trellis/workspace/` — per-developer journals and session traces
- `.trellis/tasks/` — active and archived tasks (PRDs, research, jsonl context)

If a Trellis command is available on your platform (e.g. `/trellis:finish-work`, `/trellis:continue`), prefer it over manual steps. Not every platform exposes every command.

If you're using Codex or another agent-capable tool, additional project-scoped helpers may live in:
- `.agents/skills/` — reusable Trellis skills
- `.codex/agents/` — optional custom subagents

Managed by Trellis. Edits outside this block are preserved; edits inside may be overwritten by a future `trellis update`.

<!-- TRELLIS:END -->

# Vela 项目约定

- 中文沟通；复杂开发先应用 `~/.codex/.agents/vibe-coding.md`（若环境有此文件）。最终回复带 Recap。
- 先按 `docs/migration-parity.md` 全量迁移 Codenotch Swift 主线，首版仅转换技术实现，保持 UI、视觉效果和全部交互一致；验收后实现新增第 1 项边缘插件机制，然后暂停。设置精简和新增第 2–4 项本轮不推进。遵循 `docs/adr/0006-full-swift-parity-before-product-changes.md`。
- 原 Antigravity CLI / Gemini 强制实现限制已由用户取消。沿用 Tauri 2 + Rust + HTML/JavaScript，不另换技术栈。
- 已明确授权的实现、修复、初始化和验证直接继续，Trellis 模板中的重复确认步骤不重新阻断现有授权；有新的不可逆操作才依据当前授权判断。
- Trellis 保持 `codex.dispatch_mode: inline`，不启动常驻 worker；Root 可按 [`docs/agents/model-delegation.md`](docs/agents/model-delegation.md) 显式分派最多 3 个子代理。Cargo jobs=1、Rust test threads=1、Playwright workers=1，重型构建与测试由唯一执行者串行运行。
- 第三方凭据只读；应用密钥走操作系统凭据库。日志、任务和 journal 不保存 token、Cookie 或真实会话内容。
- 验收区分：源码实现、自动化测试、macOS/Windows 实机、真实账号。未完成项保留为待完成，不能用文档或 UI 入口代替能力。
- 清理仅限本次创建、确认路径后的临时产物；保留源码、用户数据、凭据和可复用依赖。

## Agent skills

### Issue tracker

实现任务使用 Trellis；远程 Issue 仅在明确要求时发布。见 `docs/agents/issue-tracker.md`。

### Domain docs

single-context：`CONTEXT.md` + `docs/adr/`。见 `docs/agents/domain.md`。

### Grill

已安装 mattpocock/skills 的 `grill-me`（依赖 `grilling`）和 `grill-with-docs`（另依赖 `domain-modeling`）。用户要求审查方案时调用；仅安装不自动开启问答，也不重复追问已确定的迁移顺序。来源锁定见 `docs/agents/tooling-lock.json`。
