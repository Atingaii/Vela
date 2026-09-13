# 摄取排除合同 / Ingestion exclusions contract

`ingestion.exclusions.list`、`ingestion.exclusions.upsert` 与 `ingestion.exclusions.remove` 是本地 RPC 管理接口。UI 入口尚未合入；本合同不表示桌面端已有可用配置界面。

每个请求都要求显式 `project`：它必须是绝对、canonical 的已登记项目身份。`list` 只接受 `project`。`remove` 只接受 `project,id`。`upsert` 只接受可选 `id` 与 `provider,pathGlob`，以及必需 `project`；提供的三个可选字段必须是非空字符串。已有 `id` 不能跨项目覆盖或删除。

省略 `provider,pathGlob` 创建 whole-project 规则。source 规则必须同时提供受支持 provider（`claude|codex|cursor|pi|omp`）与安全的 `pathGlob`，并且该 glob 必须先匹配同项目已知的、普通且非 symlink 的 session source。路径基准是该 provider 已配置 source root 下的相对日志路径，绝不是用户仓库路径。

Glob 最大 512 UTF-8 bytes，拒绝绝对路径、反斜杠、控制字符、空/`.`/`..` 段、重复 `/` 和 `[]{}` 字符。仅 `*`、`?` 是模式元字符；实现中的二者均可跨 `/`，因此它不是标准 pathname glob。每项目最多 256 条规则；读取发现超限会 fail closed，不会静默省略规则。

排除判定由 SessionEngine 的同一 eligibility 用于发现、FSEvents/refresh 和写前 admission；History discover 也使用同一 project/provider/relative source 判定。规则与 policy generation、已有 session/plan/relation/cursor 的派生撤回在同一 SQLite 事务中提交；所有 provider 的新投影写入以 generation CAS 防止使用过时策略。用户原始日志从不修改。

History 已缓存的 source/epoch/raw 数据不被作为原文删除；规则生效后 `history.sources` 过滤，`history.start`、`history.advance`、`history.page` 与 `history.raw` 重新检查并拒绝命中来源，不能由旧 ID 绕过。已保存 Memory 和用户文件不自动删除；来源不可用会由其原有来源校验处理。active whole-project 规则会抑制以该项目为目标的自动词面、semantic/vector/recent、工作流上下文与 Lab recall 使用（包括原本会注入该目标项目的 global/namespace Memory），但不会从管理列表删除资产；其他允许项目仍可使用合法 global Memory。source 规则只抑制受保护 `observed_session_capture` provenance 的 Memory：新 capture 保存 Core 从 configured provider ingestion root 派生的 `{provider,relativePath}` 快照；旧 capture 仅在其已有 `provider,sourcePath` 仍可映射到同一 configured provider root 时兼容匹配；若可信旧 capture 因 root 更换而无法映射，存在同 provider source 规则时 fail closed。手工/导入 Memory 不因任意 source metadata 被 source 规则误判。capture 创建携带 policy-generation CAS；Lab approval 执行前重新核验已冻结的 explicit/recall Memory。

一次 lexical、semantic、hybrid、recent 或 MCP 批量读取只建立一个有界的 rule snapshot，避免每条 Memory 重读最多 256 条规则；此 snapshot 不跨请求保存，也不承诺已经返回的读取会被强线性撤销。Knowledge/Ask 的冻结候选和验证、MCP 面向 agent 的 list/read/recall、Workflow/Composition 的批准执行、以及每一轮 Agent Loop 在外部调用或进程启动前再做当前资格核验。桌面 `memory.list` 是保留资产的管理读取，不受自动消费 gate 隐藏。工作流执行时 gate 只重核当前来源资格，不重渲染已批准的 frozen argv/prompt 或因普通 Memory 正文编辑改变其 approval hash。

解除规则这次操作本身不触发重新摄取（`automaticReingestion:false`）。随后显式 `sessions.refresh` 或正常 watcher 的新来源变化，才可能在普通项目/文件身份检查通过后重建 Session 投影。历史缓存没有被删除，因此显式解除规则后，原有 epoch 可再次访问，无需重新读取 provider 日志；排除规则不是删除历史功能。规则变更不宣称对已经进行中的读取具有强线性撤销保证。
