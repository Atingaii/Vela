# Setup 清单、版本与 diff 合同

状态：Core 与隔离 CLI 验证已通过，实际验证结果见下；原生 UI 只能由指定 Antigravity CLI 模型接入。此模块没有执行 provider 命令、写入源配置或调用模型。

## 接口

所有接口通过现有 `vela call <method> '<JSON>'` / JSONL RPC 使用。

| 方法 | 参数 | 结果 |
| --- | --- | --- |
| `setup.catalog` | `{}` | 有版本的五 provider 公共位置、类型、递归范围、来源 URL 与能力限制 |
| `setup.scan` / `setup.audit` | `{project?}` 或 `{scope:"global"}` | 观察并保存当前文件；兼容旧版 `{project}` 同时观察已知 global 文件；无 project 扫已登记项目及 global |
| `setup.list` | `{project?,includeInactive?}` 或 `{scope:"global",includeInactive?}` | 本地已索引列表；不读源文件；默认隐藏 deleted/excluded |
| `setup.get` | `{id,project}` 或 `{id,scope:"global"}` | 当前观察记录及脱敏正文/不可读原因 |
| `setup.history` | 上述 identity，加 `before?` / `limit?` | 新→旧版本摘要，不含正文；limit 1–100，默认 30；before 为排除上界，nextBefore 为下一页参数 |
| `setup.diff` | 上述 identity，加 `from?` / `to?` | 指定观察版本间的脱敏文本差异；默认最新两版，只有一版时比较自身 |
| `setup.relations` | 上述 identity | 同 scope 相同源字节、同名 Skill、同目录 AGENTS.override 约定关系 |

项目 get/history/diff/relations 要求传入相同绝对 project；global 必须明确 `scope:"global"`，不能带 project。ID 不能让调用者读取任意路径。版本参数必须是准确整数，不能以 boolean 代替。读取历史不发起扫描，读取 catalog 不访问任何文件。

扫描结果保留 `artifacts` / `diagnostics` / `scannedProjects`，增加 `catalogVersion`、`scanComplete`、`entriesVisited`、`sourceBytesRead`。`historyFullyObserved` 固定 false：两次扫描之间的变化无法补证。当前每次最多 64 个项目、512 文件、15,000 目录项、深度 12、单文件 1 MiB、合计读取 8 MiB。大文件、无法读取、链接或有界截断都有明确诊断；扫描不完整不会把未看见的既有记录误记为删除。

## 当前记录与历史

artifact 沿用 `origin:"setup"` / `type` / `provider` / `scope` / `project` / `path` / `content` / `hash`。新增：

- `revision` / `revisionId`：从首次成功观察开始；相同源和状态重复扫描不增版本。
- `sourceIdentity` / `sourceBytes` / `observedAt`：实际文件身份及观察时间。
- `sourceURL` / `catalogVersion`：公开位置约定的来源，不代表调用了该 URL。
- `sanitizedHash`：保留正文的 hash，与源 `hash` 分开。
- `runtimeLoadedState:"unavailable"`：从来不把磁盘存在当作该 Agent 当前加载。
- `details`：JSON 的解析状态、MCP 名称/数量、Hook event 名称；Markdown 的简单单行 frontmatter 提取，明确不是完整 YAML 解释器。

`state` 区分 active、unavailable、deleted。删除只增加 tombstone，不删除旧版本；恢复源文件继续增版。读取失败保留独立不可用版本和历史，不静默显示旧正文为当前文件。

| contentStatus | 含义 |
| --- | --- |
| sanitized | 有可展示的脱敏 JSON/Markdown |
| metadata_only_mixed_auth_store | 混合认证容器，仅 stat，未读正文和源 hash |
| withheld_unparsed_configuration | TOML/YAML 仅 hash/身份历史，正文未保存 |
| withheld_invalid_json | JSON 无法按配置 object 解析，原文未保存 |
| unavailable | 源读取/身份/字节边界失败 |
| source_missing | 在完整扫描中观察到源删除 |

UI 应原样区分这些状态，不用空正文冒充空配置。删除/无法读取不代表 provider 已卸载；指令中的文字也不能证明 Agent 遵守。

## Diff 与关系

`sourceChanged` 比较原文件 hash，`sanitizedTextChanged` 比较已保存正文。凭据旋转可能只有前者 true；此时提示源变化但脱敏文本不变。`redacted` 明确说明展示不等于原始配置。TOML/YAML、无效 JSON、混合认证或不可用版本返回 `diffAvailable:false` 和 reason；不要显示为“无变化”。

可用 diff 返回 `format:"single_replacement_block_not_minimal"`、1-based `startLine`、`removed:[String]`、`added:[String]`；保留共同前后缀后把中间区域展示为一段替换。上限 2,000 变化区段行和两个正文合计 256 KiB，超出返回不可用原因。`isApplyPatch:false`，UI 不应提供直接套用此表示的按钮。Apply 仍需从真实源 hash 产生受审提案。

关系仅同项目或同 global 范围；不会因为一个全局文件名字相同就混入别的项目。相同内容、同名 Skill 都只是审计事实；各 provider 的合并/选中行为尚未证实。AGENTS.override 同目录关系注明 Codex/Pi 的公开约定并保留 runtimeLoadedState unavailable。

## 接入范围与未完成项

覆盖 Claude/Codex/Cursor/Pi/OMP 的当前公开原生位置、常见 Markdown 资源及 legacy OMP settings.json。`~/.claude.json` 官方明确混合登录状态，只记录存在性；auth.json、agent.db、Keychain、env 文件和私人 Library 都不读取。不执行引用、插件或 endpoint，不读取其自定义路径。

自定义 CODEX_HOME/CLAUDE_CONFIG_DIR/OMP profile、managed/remote config、插件配置包、完整 TOML/YAML 正文 diff、跨 provider 精确继承/失效引用图、语义审计、版本恢复/编辑及自动周期策略仍未完成。所有新 UI 由 Antigravity 实现；当前 contract 不是 UI 验收。

## 验证

隔离 `SetupInventoryTests` 覆盖五 provider、真实文件版本/删除/恢复、凭据变更、metadata-only、链接/大文件/无效 JSON、Private/nested project 范围、扫描截断、并发版本发布和历史参数。12/12 定点 Core 方法通过（11 个新方法和一个既有 Setup 回归），冻结源码摘要 `7f78b327b72855721a13cdd66f31d8ad617c5d0e67d7052ab489282abf2efaba`，见 `output/parity/blume/setup-final-tests.log`。这是 portable fallback，不能称为完整 XCTest。

`scripts/test-setup-rpc.py` 7/7 真实 CLI 检查通过，见 `output/parity/blume/setup-rpc-final.json`；冻结 helper SHA256 为 `bd57d1c1e1baedb1a28c423fbeb7f18bd9b7fda63ed62d4859a1abd81d2911a6`。另使用同一冻结 helper 完整执行 `scripts/create-ui-fixture.py`，6 个实际 Setup artifact 的路径均位于合成项目或显式 sources 根，见 `output/parity/blume/ui-fixture-isolation.json`。

隔离规则：设置 `VELA_SESSION_ROOT` 时该根也作为 Setup 的 globalHome；只有 `VELA_DISABLE_DISCOVERY=1` 时使用隔离 store 根；二者都没有才走正常用户 home。测试不依赖改写 HOME，也不读取用户现有配置。所有临时 fixture/store/helper 已删除；日志与来源摘要保留。早期失败证据也保留，包括 scalar JSON 比较缺陷修前日志。

## English summary

Setup now has a versioned public-location catalog, bounded read-only observations, immutable sanitized revisions, scoped history, and bounded text diffs. A discovered file is never represented as an active provider configuration. JSON and Markdown have sanitized views; mixed authentication stores are metadata-only and TOML/YAML text remains withheld pending a format-aware redactor. Incomplete scans preserve unseen artifacts; deletion and reappearance remain traceable. Diffs are review records, not executable patches.
