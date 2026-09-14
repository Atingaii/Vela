# Vela desktop：产品与日常 coding-agent 使用者评审

**Implementation status / 实施状态：** Proposed design only; the current desktop has not been changed. UI implementation requires the initiator’s designated Antigravity model. Source anchors refer to commit `28e873259f6bc21b93c0cead41f097a2b23165a3`.

**范围。** 这是一份只读设计评审，不修改 UI、Core 或原生层。依据是用户提供的两张截图、`Sources/VelaApp/Resources/UI/app.js` / `app.css` 与现有 Run Feedback 规格。截图展示的是合成 QA 内容；下文不将它当作真实用户数据或原生行为证据。

## 结论

Vela 已有安全审批的正确底座：审批卡先给出 intent、项目、目标文件、命令和内容预览，完整参数放入 `<details>`，按钮携带冻结 `snapshotHash`；服务端仍是最终授权者。问题是信息排序：绝对路径、完整 hash 和原始 JSON 在同一视觉权重中抢占了“这次会做什么、影响哪里、是否应批准”。资产页也把本地绝对路径当成行内主内容，导致一条记录换行、列宽失衡和大面积空白。

目标应是 **Codex 式、安静的工作台**：项目与任务是导航骨架，当前工作项是主内容，只有状态和风险用颜色。它不是把安全细节藏掉，而是把“可快速判断的语义摘要”放在前面，把“可逐字核对的冻结证据”放进相邻、明确、可复制的逐层披露区。

OpenAI 将 Codex app 定义为管理并行、长时任务的 command center；这支持用项目、任务和 review queue 组织主界面，而不是让机器 JSON 成为默认阅读面。[OpenAI：Introducing the Codex app](https://openai.com/index/introducing-the-codex-app/)

## 已观察到的证据

| 观察 | 代码位置 | 用户影响 |
| --- | --- | --- |
| 资产行把 `/Users/.../.agents/skills/review/SKILL.md` 作为行内主要文本，截图中换成两行。 | 现有资产/详情的 `assetPath` 直接渲染；Library detail 在 `app.js:13853-13856` 也直接显示。 | 识别资产要先扫机器路径；一条记录撑高，表格无法快速比较。 |
| 审批卡已生成项目 basename、相对 target、命令和前 3 行内容预览。 | `renderInboxView()`，`app.js:18028-18227`。 | 这是正确的一级信息，但它与下面的原始技术块仍缺少明确层级。 |
| 折叠区输出完整项目绝对路径、完整 `snapshotHash` 和完整 JSON。 | `app.js:18231-18238`。 | 审批者面对长路径、hash 和 JSON 时很难先判断副作用；hash 没有被解释为“冻结快照”。 |
| 全局正文是 13px，但大量说明、表格辅助信息和折叠项为 10–12px。 | `app.css:64-72`；例如 approval summary `1050-1085` 与多处 inline 11px。 | 在桌面常见阅读距离下显得紧凑；中文元信息尤其难扫读。 |
| UI 已有系统字体、浅色表面、细分隔线、drawer 与 `<details>` 模式。 | `app.css:1-72, 1050-1085, 1485-1590`。 | 不需要重做视觉语言；应收敛 token、提高层级和可读性。 |

Apple 对 macOS 的默认/最小可读字号分别给出 13pt/10pt，并建议用字号、字重和颜色表达层级、避免细字重。[Apple HIG：Typography](https://developer.apple.com/design/human-interface-guidelines/typography) 因而 10–11px 不应再承担理解审批或资产归属的主要内容。

## 两类用户的任务模型

### 产品经理：控制、可解释、可审计

产品经理在首页需要回答：哪些项目有待处理风险？哪些审批会写文件、执行命令或启动 agent？哪一个需要今天决定？当前卡片已具备数据，却没有把 **风险、目标、后果、状态** 固定为同一顺序。主列表不能以 JSON 长度决定卡片高度，也不能用颜色装饰无风险信息。

推荐的审批列表排序：`等待我处理`、`已过期/失败`、`运行中`、`最近完成`。每张卡只显示：操作动词、对象、项目、风险级别、目标相对路径或命令摘要、变更预览、提交时间。审批编号、完整项目根、完整 hash 和 raw payload 仍然可见，但不进入默认扫描层。

### 日常 coding-agent 使用者：快扫、精确核对、不中断上下文

使用者反复在项目、会话、资产、待办之间切换。他需要先看到 `Harbor › .agents/skills/review/SKILL.md`，不是本机用户名和临时目录；需要看到 `写入 release-note.md`、`将在 Harbor 执行 git status`，不是一个 JSON blob。遇到高风险动作时，又必须一键取得完整 frozen argv、文件内容、base hash 与 snapshot hash，用来逐字核对或复制给同事。

VS Code 的一手 UX 指南也建议侧栏保持最少视图、避免过多 actions，以免造成混乱；将项目切换与少量一级视图保留在侧栏，将当前对象的检查放在主区或 inspector 更符合这一成熟工具模式。[VS Code：Sidebars](https://code.visualstudio.com/api/ux-guidelines/sidebars)

## 可直接交给 AGY 的视觉与信息标准

### 1. 基础布局、排版和配色

- 保留左侧项目/工作区导航；宽度从当前 `228px` 调整到 **240px**，最小 224px。一级导航不增加新的“安全”或“技术”顶层页面。
- 主内容最大阅读宽度 **1120px**；外侧 gutter 32px，卡片间距 12px，卡片内距 16px。窗口窄于 900px 时改为 20px gutter，审批卡的元信息由横排改纵排。
- 使用现有 SF system font；正文与审批意图 **16px / 1.5–1.55**，页面标题 22px/600，卡片标题 16px/600，常规控件、状态和元信息 **14px / 1.4**，技术 metadata 12–13px。**10–11px 只可用于键盘提示或纯装饰，不可用于路径、状态、审批说明或按钮。**
- 中性偏冷的 Codex 式浅色：app `#F7F8FA`，surface `#FFFFFF`，subtle `#F1F3F5`，border `#DEE2E6`，主要文本 `#202124`，次要文本 `#5F6368`。蓝色只表示 keyboard focus/primary action；amber 只表示 pending/needs attention；red 只表示 destructive/error；green 只表示已验证/完成。取消米色底、大面积蓝底和无语义渐变。
- 阴影只用于 modal/drawer；普通卡以边框和留白分组。焦点环保持高对比，普通按钮最小高度 **32px**，主要审批按钮最小高度 **36px**。

### 2. 资产与路径：相对路径优先，完整位置永不丢失

资产表改为四列：**名称**（15px、单行）、**位置**（相对路径）、**范围/Provider**（badge + 文本）、**状态/操作**。每行高度 56–64px；不让路径换行撑高整个表。

路径规则：

1. 资产属于当前项目时显示 `Harbor › .agents/skills/review/SKILL.md`；路径列使用 mono 14px、单行省略，保留 basename 末段。
2. 位于已注册共享根时显示 `Shared › review/SKILL.md`，并在 scope badge 说明 shared；不要伪装成项目内路径。
3. 合法 global/user 或其他非项目位置依服务端提供的 scope/来源显示 `Shared`、`User` 或 `Other location`；不要把视觉上的相对化失败推断为不可信、风险或不可操作。完整绝对路径只在 Inspector 的“位置与身份”区提供。
4. hover/键盘 focus 的 tooltip、Copy location 和 inspector 都提供完整 canonical path；屏幕阅读器标签应包含完整路径。省略不改变选择、定位、权限、现有 action availability 或安全边界；异常状态只显示服务端已提供的诊断。

相邻 `View` 打开 inspector，而不是在表格内展开全文。Inspector 首屏依次为：名称与状态、项目/Provider、相对位置、诊断；第二层 `位置与身份` 才显示 absolute path、asset id、source hash。对长 token 设置 `overflow-wrap:anywhere` 只用于 inspector/raw 区，列表永不强制折行。

### 3. 审批：语义审阅与精确冻结证据双层并存

每个 pending approval 固定为以下顺序，避免以 JSON 结构决定画面：

1. **动作标题**：动词 + 对象，例如“写入 `release-note.md`”或“在 Harbor 运行 `git status`”；工具名作为 12px mono badge。
2. **影响摘要**：项目 basename、相对目标、命令（executable + 可读 argv chips）或前三行 diff/content preview；写入/执行/网络/agent 的风险标签明确可见。
3. **可决定的冻结影响**：始终结构化显示真实 target（相对路径）、执行命令与 argv、网络数据范围、写入/执行/agent 风险、content/diff preview、timeout 与 verification files；这些是批准判断所需信息，不因风险级别折叠。
4. **“查看冻结技术详情” disclosure**：默认折叠，内含完整 64 字符 `snapshotHash`、完整 canonical project path、base hash、asset id 及只读 raw JSON，皆可复制。默认不显示短 hash，也不把 hash 当作人类可读的风险解释；它是用于精确核对的技术证据。
5. **操作栏**：`拒绝`、`批准执行` 固定在右下。批准前显示本卡影响摘要，不自动重试。成功与终态错误均从服务端重新读取权威列表；expired/late error 后不得保留或重新启用旧 pending 卡。

这不会削弱冻结合同：按钮继续提交原始 `id` 与完整 `snapshotHash`，Core 继续做唯一决定；UI 不能生成、截断后提交、重新计算或自动重试 hash。原始 JSON、完整 hash 和绝对路径不删除，但默认折叠在“冻结技术详情”中；真正影响批准的 target、命令、网络范围与副作用始终结构化可见。Apple 也明确建议 disclosure 隐藏暂时不相关的细节、把常用内容放在层级上方，并使用描述性标签。[Apple HIG：Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)

### 4. 渐进披露一致标准

| 层级 | 默认可见 | 允许内容 | 不允许内容 |
| --- | --- | --- | --- |
| L0 列表/队列 | 状态、动作、项目、相对对象、时间、风险 | 计数 | hash、全路径、全 JSON、长 argv |
| L1 卡片/Inspector 首屏 | 意图、真实 target、命令/argv、网络范围、预览、风险解释 | 相对路径、timeout、verification files | 未解释的序列化对象、hash |
| L2 冻结技术详情（默认折叠） | 完整 snapshot hash、base hash、绝对路径、raw JSON | Copy、搜索/等宽文本 | 可编辑的 frozen inputs |
| L3 审计/诊断 | id、timestamps、source receipt、原始数据 | 只读、按需加载 | 作为日常任务列表默认内容 |

所有页面统一此规则：Memory/Library/Guideline/History/Workflow detail 的 asset path、source hash、snapshot hash、raw record 都进入 L2/L3；业务内容、私有状态和项目归属留在 L0/L1。任何 private/removed/stale 状态仍不得显示缓存文本。

### 5. 最小实现地图与验收

- `app.js:18028-18245`：保留 `getApprovalSummary()` 的相对路径逻辑；新增结构化 frozen evidence renderer，不再将完整 JSON 作为唯一详情格式；完整 payload/hash 仍原样保存在 `data-hash` 与 RPC 参数里。
- `app.js:13849-13856, 13946`：Library/asset details 将 `assetPath` 改为 relative location + technical disclosure，绝对路径只在 L2。
- `app.css:64-72, 1050-1085, 1244-1256, 1485-1590`：集中 token，移除影响阅读的 inline 10–11px；为 `.relative-path`、`.frozen-evidence`、`.approval-impact-grid`、`.tech-meta-details` 建样式，不再依赖大量 inline style。
- `i18n.js`：新增中英成对、动作导向文案，例如“查看冻结技术详情 / View frozen technical details”“复制完整路径 / Copy full path”“复制快照哈希 / Copy snapshot hash”。不得把 hash 误译成“安全证明”。
- 原生行为未测：未在本轮启动应用、验证 VoiceOver、窗口缩放、高对比、复制权限、tooltip、键盘焦点、审批异步刷新或中英断行。实现后应在真实 helper 的 pending file-write、command、agent 三类审批以及项目内/shared/external 路径上逐项验证；同时确认 expired/late response 仍不会出现 success toast。

## 实施优先级

1. 先重排审批卡并加入精确冻结 evidence disclosure（不改 RPC/Core）。
2. 再统一 asset relative-path renderer 和 Inspector 技术层。
3. 最后集中 CSS token、16px/14px 字号与响应布局，跑 zh-CN/en 的真实 helper UI 回归与原生可访问性检查。

这三步保留现有功能边界，避免把“视觉整理”变成新的工作流、权限模型或 agent 自动化。
