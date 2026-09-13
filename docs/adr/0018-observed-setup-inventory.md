# ADR 0018：公开配置清单与脱敏观察历史

- 状态：Accepted；验证记录另行保存
- 日期：2026-09-13
- 范围：Setup 文件发现、历史、diff 和来源边界

Blume 已发行版本提供 Rules/Skills/Hooks/MCP 清单及类型详情。Vela 原扫描只覆盖有限位置，把删除后的 metadata 直接移除，没有可追溯的配置版本。继续扩充散落的路径判断会混淆实际加载、内容变化与 provider 认证状态，因此采用一个有版本的公开位置 catalog 和独立的只读 `SetupInventoryService`。

保留既有 `setup.scan/list/audit`，FoundationService 仅转发。新增 `setup.catalog/get/history/diff/relations`；对象与版本只能用既有 ID 读取，项目历史重新核对 project，全局历史要求显式 `scope: global`。不用 provider CLI 读取配置，不执行 hooks、MCP、imports 或插件，也不解析成“当前生效配置”。文件被发现只证明观察到它，运行时 trust、CLI/env overlays、其他 profiles、管理策略与实际 cwd 需要另外的来源证据。

目录和文件按允许范围检查；逐级描述符与 `O_NOFOLLOW` 拒绝父目录链接，文件拒绝 hardlink、FIFO 和非普通文件。读取有文件数、目录项、深度、单文件和合计字节限制，读前/后核验 device/inode/size/mtime/ctime。扫描不完整时保留未见过的旧记录，不据缺失发现结果推断删除。明确发现源删除时记录新的 tombstone 版本，源重新出现继续编号。

每个实际内容/可读状态变更生成不可变 `setup_revision`。revision 和当前 artifact 用 Store `putBatch`、当前对象 hash 与新 revision ID absent 检查一起发布；并发扫描的失败方不能覆盖已发布版本。只在用户扫描时观察，无法重建两次扫描之间未观察到的修改。

JSON 在解析后按敏感字段、env/headers 容器和常见正文凭据形态脱敏；无效 JSON 不降级为保存原文。Markdown 保存经过常见凭据形态过滤的正文；它不是对任意自由文本秘密的完备识别器。TOML/YAML 暂不保存正文，仍保留源 hash、身份与变更版本；引入可靠的格式解析器之前不靠逐行正则承诺多行凭据安全。此限制保留在功能缺口中。混合认证容器 `~/.claude.json` 连正文/hash 都不读取，仅记录存在性；官方明确该文件包含 sign-in session。独立 auth.json、agent.db、Keychain 与环境凭据文件不进入 catalog。

版本 diff 只比较已存的脱敏表示，明确区分真实源 hash 改变与脱敏文本改变。diff 是有界的单替换区段表示，不是最小 diff 或可直接 Apply 的 patch；原配置写入仍由未来明确提案与 SafeApply 审批负责。关系仅报告同一 scope 内的相同字节、同名 Skill、公开约定的同目录 AGENTS.override 优先关系；不猜实际 provider 采纳。

选择继续用 Swift/Foundation/SQLite，避免为了扫描启动新的常驻运行时。若后续需要完整 TOML/YAML diff，选定维护良好的格式解析器并评估其解析深度、别名/自定义 tag、依赖维护和包体积，再单独更新该决策。自定义配置路径、provider 安全导出、管理配置、插件包清单与精确继承图仍是后续接入项。

## 来源

- [Claude settings](https://code.claude.com/docs/en/settings)：文件范围及混合登录状态容器。
- [Claude memory](https://code.claude.com/docs/en/memory) / [skills](https://code.claude.com/docs/en/skills)：指令、规则与技能位置。
- [Codex instructions](https://learn.chatgpt.com/docs/agent-configuration/agents-md) / [skills](https://learn.chatgpt.com/docs/build-skills)：分层约定与公开技能目录。
- [Cursor rules](https://cursor.com/docs/rules) / [MCP](https://cursor.com/docs/mcp) / [hooks](https://cursor.com/docs/hooks)：项目与用户来源。
- [Pi README](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md)：原生资源位置及 trust 边界。
- [OMP settings](https://github.com/can1357/oh-my-pi/blob/main/docs/settings.md)、[context](https://github.com/can1357/oh-my-pi/blob/main/docs/context-files.md)、[MCP](https://github.com/can1357/oh-my-pi/blob/main/docs/mcp-config.md)：当前 YAML 与 legacy JSON、原生与兼容目录。

## English

Vela observes a versioned catalog of public configuration locations and keeps immutable sanitized revisions through conditional SQLite batches. Discovery never proves runtime adoption. Source reads are bounded and reject linked files/ancestors; incomplete scans preserve unseen records. Mixed authentication stores remain metadata-only, while TOML/YAML retain hash history without text until a format-aware redactor exists. Scoped history and bounded sanitized diffs are read-only observations, not executable patches or a provider configuration evaluator.
