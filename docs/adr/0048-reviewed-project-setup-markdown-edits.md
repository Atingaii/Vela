# ADR 0048：项目 Setup Markdown 的冻结审批编辑

- 状态：Accepted
- 日期：2026-09-14
- 范围：项目内 instruction/skill Markdown 的读取、预览、一次性审批、写入和 Undo

## 背景

Setup inventory 只保存公开目录的脱敏观察和历史。将其展示的 `content` 直接送回文件会把 `[REDACTED]` 或 withheld 空文本覆盖用户原文；把已有 workflow `file.write` 暴露给 Setup 编辑则会把一次 UI 功能变成任意项目文件写入。两种路径都不满足项目根、文件身份、审核 payload 和可追溯 Undo 的边界。

## 决策

新增四个仅限 Desktop/CLI bridge 的方法：

- `setup.edit.get { project, artifactId }`
- `setup.edit.preview { project, artifactId, baseHash, sourceIdentity, content }`
- `setup.edit.prepare { project, artifactId, baseHash, sourceIdentity, content }`
- `setup.edit.undo { project, artifactId, journalId }`

方法没有 `path` 参数。它们只能从当前已登记项目的 `origin=setup` artifact 取得路径，并只允许 `SetupCatalog` 已知、项目作用域、类型为 `instruction` 或 `skill`、扩展名为 `.md` 的文件；全局文件、rule/configuration/hook/MCP、未知路径、非活动 artifact、链接/硬链接、非 UTF-8、超过 64 KiB、withheld 或已脱敏内容一律不能编辑。

`get` 直接通过 descriptor-safe 读取当前文件，而不以 inventory 的 sanitized content 作为原文。它只在当前原文和 `ModelImprovement.redact` 一致时返回原文、SHA-256 `baseHash` 和 inode/device/mtime/bytes，以及项目根和每层父目录 inode/device 的 `sourceIdentity`；否则返回不可编辑原因且不泄露内容。`preview` 与 `prepare` 重新读取并精确比较这些值，连同新全文（允许空文本、最多 64 KiB）再次做同一敏感模式检查。它们拒绝而不 sanitize：脱敏占位永远不写回源文件或审批 ledger。

`prepare` 创建内部单步 run、持久 `setup_edit` provenance 和既有 `approval`。审批工具固定为 `setup.file.edit`；冻结 payload 只含 edit/artifact identity、相对路径、hash、source identity、经检查的冻结 `before` 原文和新全文。它沿用现有 TTL、snapshot hash、SQLite claim-or-expire 和一次性决定。批准后专用执行器再次 descriptor-safe 读取和比较原始 hash/identity，随后只调用 `SafeApplyService.applySetupEdit` 这个 Core 内部 typed overload；该 overload 在打开目标、staging 与 commit 前都重验文件、项目根及每层父目录 identity。SafeApply journal 带 Core-owned `origin=setup_edit`、edit ID 与 artifact ID，以便重启后查回来源；公共 SafeApply 不接收任意 metadata。执行后若文件已落盘但 setup_edit 链接写入失败，返回 `outcomeUnknown` 并令审批/run 进入 `needs_review`，保留真实 journal、不重试或伪报失败。Undo 落盘后的链接失败也同样需要人工核对。不给公共 SafeApply RPC、MCP 写工具或用户 workflow 增加写能力。

Undo 不另建审批，因为它是用户明确点击的同一已审阅变更的回退；但必须同时匹配项目、artifact、`setup_edit` 和带 provenance 的 applied journal。底层 Undo 仍以 journal `afterHash` CAS 执行，外部修改会保留并拒绝回退。

## 取舍与限制

编辑为全文替换，块级 Markdown 编辑仅是 renderer 对全文的受控生成方式；Core 不解析或执行 Markdown。inventory 的 observed revision 可能在 Vela 写入后短暂落后当前原文，`get` 标记 observation stale，而不是伪造一次扫描。`get.changes` 按 artifact 返回最近至多 100 条并以 `changesHasMore` 明示截断；Undo 仍以精确 journal ID 查询，不受该展示上限影响。敏感模式是已有有界检测，不能证明文本绝无秘密；命中时宁可拒绝编辑。全局、provider runtime/custom import、配置、hooks、MCP 和任意项目代码文件仍不在本接口范围。

## 验证

- `SetupEditTests.swift`：instruction/skill 成功预览→审批→CAS 写入→重启后 provenance Undo；空文本；重复决定；stale hash/identity；全局/未知类型、redacted/withheld、secret before/after、链接/硬链、超限、跨项目和伪造 journal 均拒绝。
- `AutomationTests.swift`：继续覆盖 SafeApply 多文件事务、链接、陈旧 batch 与 Undo 的文件系统语义。
- `scripts/test-setup-edit-rpc.py`：冻结 helper 与合成项目上的完整 CLI 链，确认敏感原文不进入 receipt/store。

## English summary

Project Setup editing is a typed, reviewable Markdown replacement flow, not a generic filesystem RPC. It permits only safe, catalogued project instruction/skill Markdown, freezes an authoritative descriptor-safe source identity and content hash into the existing one-shot approval, revalidates at execution, and records SafeApply provenance for CAS-protected Undo after restart. Sanitized, withheld, global and non-Markdown configuration are never write inputs.
