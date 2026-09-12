# 客户端与官网体验重构验收

审查日期：2026-09-12。代码基线：`dfd1c64`（`0.1.0-preview.1`）。本文件记录本轮产品体验改造的目标和验收项，不代表新版需求已经全部实现。

**当前证据状态：源码与契约审查完成；最终 renderer 的 12 组真实 CLI 浏览器验收全部通过。** 下文的问题描述保留改造基线，当前结论以文末最终复验为准。原生系统集成、官网视觉和性能使用各自证据；未执行或仅部分覆盖的项目保留未勾选。

## 目标与信息架构

主要用户任务依次为：发现需要关注的会话，查看过程与来源，保存和召回工程记忆，审阅自动化动作，验证执行结果。界面应帮助用户完成这些任务，而不是默认展示全部对象字段。

- 会话列表优先呈现任务、项目、状态和最后活动。模型、Token、完整路径和原始来源进入详情或可选列。
- Memory 应有侧栏直接入口；底层可以复用已有 Setup/Memory 渲染与 API，不需为了导航重建领域模型。
- 工作流、改进作为主要工作入口；配置、Lab、用量可以分组排列。Inbox 显示真实待处理数量，设置固定在侧栏底部。
- 每个页面只保留一个主要下一步。次要操作放详情、菜单或悬停状态；风险、隐私范围和执行结果仍应在相应决策点清晰可见。
- 使用一致的界面语言。产品名、模型名、命令和必要专业术语保留原文，不为每个控件并排重复中英文。

保留现有 Swift、AppKit、系统 WKWebView 与独立 helper。此轮重构不以更换运行时作为视觉优化前提。

## UX-01 配置资产分类

**问题：** 基线 `renderArtifactsSection` 用 `a.type === typeName` 过滤，而标签值是 `rules/skills/hooks`。核心扫描实际返回 `instruction/rule/skill/command/configuration`，Hook 和 MCP 还可能表示为配置对象的能力字段。真实已扫描资产可能不出现在任何对应页面中。

**预期：** Rules 包含 `instruction/rule`；Skills 包含 `skill/command`；Hooks 使用 `containsHooks`；MCP 包含 `mcp` 或 `containsMCP`。每条展示实际来源和脱敏内容，不依赖浏览器示例数据。

**依据：** [基线 UI](../../Sources/VelaApp/Resources/UI/app.js)，`renderSetupView/renderArtifactsSection`；[扫描器](../../Sources/VelaCore/FoundationService.swift)；[观察与配置契约](contracts.md#观察与配置)；新版 FR-14、FR-15。

- [x] 在隔离真实项目中扫描 AGENTS.md、Skill、Hook 和 MCP 配置，各项进入正确分类。
- [ ] 原生应用展示内容与 `setup.list` 返回一致；敏感值保持脱敏。
- [ ] 未发现配置问题时明确显示成功空结果，不制造问题。

## UX-02 更新、草稿与空状态

**问题：** 基线 `vela:refresh` 对自动摄取事件也强制重绘并显示“数据已刷新”；force 参数绕过正在编辑的保护。会话筛选零结果还复用“未检测到会话日志”和添加项目操作。打开详情后，详情数据只在首次读取时加载。

**预期：** 自动更新静默且局部应用；保持输入、焦点、筛选、滚动位置和选中对象。详情可以更新新消息，但用户回看历史时不自动跳到底部。无项目、无日志、无匹配和服务故障分别给出合适的下一步。

**依据：** [基线 UI](../../Sources/VelaApp/Resources/UI/app.js)，`setupShortcuts/refreshDashboard/renderSessionRows/openSessionDetail`；新版 FR-02、FR-12、NFR-03。

- [ ] 编辑设置、搜索词或工作流时连续触发真实 `data.changed`，内容和焦点保持。
- [x] 设置未保存草稿在真实 `data.changed` 与后续 dashboard 响应后保持输入和焦点，Core 持久化值不变，无自动刷新 Toast。
- [ ] 自动事件不产生刷新 Toast；明确点击刷新只产生一次反馈。
- [x] 筛选零结果显示清除筛选操作，清除后恢复真实会话列表。
- [ ] 无日志状态不会伪造连接成功或导入完成。
- [x] 已打开会话能接收同秒连续追加的新消息，保持历史阅读位置且不关闭详情。
- [ ] 截断和未知状态在相应异常 fixture 中仍可见。
- [ ] helper 失联时出现真实错误与恢复入口，不切换到示例数据。

## UX-03 导航与渐进展示

**问题：** Memory 藏在 Setup 的第六个标签。会话列表、Memory 行操作和详情默认暴露大量低频元数据，主要任务缺少层次。

**预期：** 会话到记忆的路径直接可见；列表便于识别待关注对象，详情先展示任务和内容。元数据、原始输出、完整路径及诊断按需展开。精简展示不能删除真实能力或将不可用能力包装为已实现。

**依据：** [基线 UI](../../Sources/VelaApp/Resources/UI/app.js)，`renderAgentsView/renderMemorySection/openSessionDetail`；新版 FR-12、FR-22、FR-27、FR-30。

- [ ] 从主界面可直接进入 Memory，查看来源、激活候选、执行 Recall。
- [x] 从独立 Memory 侧栏保存候选、激活并在明确选择的项目范围内 Recall。
- [ ] 在 900×620 最小窗口和常用桌面尺寸下，主任务区域无被遮挡控件。
- [ ] 长标题、路径、模型名和较多记录不破坏布局；长内容按需展开。
- [ ] 无证据的用量、模型、状态和收益保持“不可用/未知”，不填零或成功值。

## UX-04 快捷键与键盘操作

**问题：** 侧栏每条常驻显示数字快捷键和重复翻译；原生 View 菜单已经提供快捷键。模态与详情没有完整的焦点约束和恢复，Escape 同时关闭多层，点击行缺少完整键盘路径。

**预期：** 保留快捷键，在原生菜单、悬停提示和帮助中提供发现路径；搜索入口可以保留克制的 `⌘K` 提示。模态符合系统常用交互习惯。

**依据：** [页面结构](../../Sources/VelaApp/Resources/UI/index.html)；[原生菜单](../../Sources/VelaApp/main.swift)；[基线 UI](../../Sources/VelaApp/Resources/UI/app.js)，`setupShortcuts/openModal/closeModal/openDrawer`；新版 FR-41。

- [ ] 侧栏不再每行常驻显示快捷键；原有可用快捷键保持生效。
- [ ] 全局搜索可键盘打开、输入、选择结果和关闭。
- [ ] Tab 不离开当前模态；关闭后焦点回到触发位置，Escape 只关闭最上层。
- [x] 会话表格保留 AX 行语义，行内按钮可用 Enter 打开详情，导航高亮保持一致。
- [ ] 搜索结果能通过键盘打开；焦点状态清晰可见。
- [ ] 遵循减少动态效果偏好；状态信息不只依靠颜色。

## UX-05 通知与声音

**问题：** 基线仅有通知总开关，全部使用默认系统声音。一次工作流待审批可能分别由 Run 与 Approval 状态提醒。尚未提供通知点击后进入对应对象的完整路径。

**预期：** 通知用于审批、完成和错误，三类可分别关闭，声音可关闭并试听。普通点击、页面切换、日志摄取、Running/Idle 不发声。首次加载历史静默，同一动作去重；通知点击进入对应会话、Run 或 Inbox。使用系统通知途径，尊重系统权限与专注设置。

**依据：** [原生通知基线](../../Sources/VelaApp/main.swift)，`postLocalNotification/trackTransitionsAndNotify`；[设置契约](contracts.md#7-settings诊断与未完成范围)；新版 FR-05。

- [x] 隔离策略测试覆盖初始基线、重复事件、新审批、完成、错误和未知状态；2026-09-12 portable 套件 54/54 通过（不等同于原生通知投递验证）。
- [ ] 同一审批的 Run/Approval 更新只产生一次通知；关闭类别后无对应通知。
- [ ] 声音关闭时通知保留且不发声；重新启动后偏好保持。
- [ ] 正常使用仅在用户开启通知时申请系统授权；拒绝权限有准确说明。
- [ ] 实际通知点击能打开对应对象；目标已不存在时有可理解的回退。
- [x] 注入原生路由事件后，真实 CLI 数据支持成功跨项目、失败后导航不显示旧项目、未知项目全局回退和三类聚合路由；不等同于 OS 通知投递验收。
- [ ] 声音短促、克制，有原始来源或生成说明；声音文件进入发布资源白名单。

## UX-06 审批、证据与准确文案

**问题：** 审批主要展示原始 JSON 和 hash，用户难以迅速判断执行目的。部分界面直接暴露 `snapshot_only_not_injected` 等内部字段，出现“完全离线”或 Claude Desktop/Claude Code 混用。

**预期：** 审批先展示动作、项目、目标和关联运行，原始参数与 hash 仍可核对。Guideline、Lab、Usage 和 Handoff 的可用范围采用简洁、准确的用户语言说明。界面简化不改变冻结审批、私有数据过滤和失败关闭机制。

**依据：** [基线 UI](../../Sources/VelaApp/Resources/UI/app.js)，`renderInboxView/renderSettingsView/renderGuidelinesSection/openLabCompareDrawer`；[实际状态](../status.md)；新版 FR-48、FR-59、FR-60、FR-69、FR-70。

- [ ] Workflow 草案 → 保存 → Dry Run → 审批 → 执行 → Run 详情走通，写操作和测试仍须审批。
- [x] 实际表单保存 Workflow，Dry Run 不写文件，批准冻结动作后只执行预期文件写入；命令审批摘要保留 executable 和含空值/空格/引号的 JSON argv，命令持续待审批且未执行。
- [ ] 审批中的动作/项目/参数与实际冻结快照一致，重复点击不重复执行。
- [ ] Improve 来源 → Diff → Apply → Undo 可走通；文件已变化时拒绝覆盖且原因可见。
- [ ] Lab 审批前无结果，单组失败退出码如实显示；`completed` 不被解释为候选胜出。
- [ ] 不出现未经证明的额度、节省比例、自动注入、完全离线或完整 Agent Eval 宣传。

## UX-07 品牌、官网与 README

**问题：** 用户明确不接受现有客户端和官网视觉；README 缺少产品实际截图。此次应以实际产品画面与可验证下载作为主要展示材料。

**预期：** 官网对照 [px0](https://px0.ai/) 的实际页面，匹配信息层级、布局、字阶、留白、内容节奏和移动端适配。只借鉴公开设计语言，使用 Vela 自有品牌、文案和素材。客户端保留开发工具熟悉的操作结构，不将官网样式机械套入操作界面。

**依据：** 用户本轮反馈；[网站源文件](../../website/dist)；[英文 README](../../README.md) 与 [中文 README](../../README.zh-CN.md)。

- [ ] 保存并查看本轮参考站、改造前后官网和实际客户端截图后再记录视觉结论。
- [ ] 官网桌面/移动端无溢出、失效按钮、错误链接或不可读内容；不靠增加装饰卡片代替结构对齐。
- [ ] 产品图来自真实原生应用，使用隔离示例工程，并说明示例数据；不冒充用户实际会话。
- [ ] 英中 README 均有可加载的头图或实际截图、版本下载和最短上手流程。
- [ ] 图标保留 SVG 源文件和多尺寸 `.icns`，在 Dock、Finder、菜单栏及深浅背景中检查。
- [ ] 官网与 README 的版本、平台、签名、公证和功能边界与实际交付一致。

## 验证记录与待补证据

| 项目 | 证据 | 当前状态 |
| --- | --- | --- |
| 基线源码与 API 对照 | 本文件 UX-01 至 UX-06 的实现位置 | 已审查 |
| 实际客户端截图与尺寸检查 | 待补截图相对路径、版本与数据说明 | 未验收 |
| 官网参考对照 | 待补同尺寸参考/实现截图与差异说明 | 未验收 |
| 真实 renderer → CLI 主流程 | 下文最终 12 组及 RPC 记录；原生手工证据另记 | 浏览器 12/12 通过 |
| 通知策略与实际系统行为 | `python3 scripts/test-portable.py`：54/54，包括快速 Run、provider 时间来源与跨项目/混合来源聚合；原生交互待补 | 策略通过，系统行为未验收 |
| 核心、RPC/MCP、发布资源检查 | 待补本轮命令、结果和 CI 链接 | 未验收 |
| 性能 | 待补采样条件与实际指标 | 未验收 |

### 重构中诊断（2026-09-12，非最终验收）

使用直接 Playwright 驱动、隔离 Harbor/Beacon 项目和真实 CLI bridge 完成当前保存版本的诊断。默认 `agent-browser` 驱动在本机出现超时及浏览器重启到 `about:blank`，其后的控件缺失不计作产品缺陷；测试增加了明确的驱动选项与会话失效后停止机制。

- 已通过：会话筛选空状态与清除、真实表格 AX 行及 Enter 打开详情、Memory 保存/激活/Recall、Workflow Dry Run 无写入及审批后实际写入、真实 `data.changed` 后设置草稿/焦点/静默更新与未保存状态、模态 Tab/Escape/焦点恢复、延迟真实用量响应后的快速导航、Harbor 到 Beacon 的真实审批路由。
- 已复现：MCP 标签未展示已扫描的 `.mcp.json`；通知目标项目读取失败后仍展示旧项目审批；已移除项目的通知没有回退全局列表。Rules、Skills、Hooks 分类已通过，MCP 单项失败使配置组保留未验收。
- 测试修正：跨项目成功用例先等待目标 scope 的真实 dashboard 响应与渲染，再检查审批集合，避免将切换中的旧画面误判为项目泄漏。
- 待补：修复后的全新 fixture 完整复验、聚合通知来源选择、详情新消息与历史滚动位置、原生实际声音与通知投递。以上诊断不替代最终 macOS 安装包验收。

### 最终 renderer 复验（2026-09-12 14:16 UTC）

**全新独立 fixture，直接 Playwright Library，完整 12/12 通过，脚本退出码 0。** 本轮没有使用 `--checks` 筛选，也没有使用 demo 数据。Harbor 与 Beacon 由真实 CLI 登记；所有业务写入局限于本次合成工程。改造中发现的 MCP、通知失败/未知项目路由与同秒消息漏刷均在这一版本通过复验。

| 检查组 | 实际验证 |
| --- | --- |
| `filtering` | 无匹配与清除筛选、AX 表格行、Enter 打开详情、正确导航高亮 |
| `setup` | Rules / Skills / Hooks / MCP 展示真实扫描资产 |
| `memory` | 表单保存、激活、明确 Harbor 范围内 Recall |
| `workflow` | 保存、Dry Run 无写入、冻结审批后精确写入；命令摘要保留 JSON argv，命令未执行 |
| `draft` | 真正的文件追加触发 `data.changed`，dashboard 响应后草稿/焦点保持且未保存，无刷新 Toast |
| `keyboard` | 搜索模态 Tab 约束、Escape 关闭、触发按钮焦点恢复 |
| `rapid-navigation` | 延迟真实 `usage.get` 返回后，会话内容及导航仍一致 |
| `live-detail` | 两批同秒真实日志追加均出现，历史滚动位置保持、详情不关闭 |
| `routing` | Harbor → Beacon 后只显示目标项目审批 |
| `routing-failure` | 目标读取故障后无旧审批；切换工作流仍保留范围错误且不显示旧记录 |
| `routing-unknown` | 已移除项目通知回退全局，两个项目的不同审批均可见 |
| `routing-aggregate` | 同项目保留范围；跨项目进入全局；混合来源只列实际类别并逐个可达 |

原始结果 `browser-results.json` 和 `harness-rpc.jsonl` 保留在本次隔离验收 fixture；后者有 53 次真实 CLI 调用（包含独立 oracle 读取），`approvals.decide` 仅 1 次。最终两批新增消息的 provider 时间均为 `2026-09-12T14:16:10Z`，覆盖此前的秒级时间戳漏刷问题。

本次 renderer `app.js` SHA-256 为 `87f5e194e205459699380278fb0a6562faa57eb887d63bd7f4a8ab701fad7da0`。早期测试先后修正了全局 `inbox.list` 的 oracle 项目过滤、Recall 项目显式选择和最终错误页 selector；这些驱动/测试适配问题没有计作产品缺陷。全部 12 组在修正后同一次全新 fixture 上通过。

通知路由事件及一次只读故障为明确测试注入，业务读取、摄取与审批执行是真实 CLI。系统通知权限/投递、NSSound 实际发声、WebKit 原生观感、正式签名/公证及大规模性能不在此 12 组结果中推断，继续以各项独立验证记录为准。

UI 复验使用隔离数据目录和合成 fixture；不得摄取、修改或公开真实用户配置与会话。真实安装包截图可以展示明确标注的示例工程，但必须经原生 bridge 和真实持久化路径渲染。

可重复的浏览器主流程使用 `scripts/test-ui-browser.py`，其 transport 连接实际编译的 CLI；`system.info/ready/updateStatus/chooseProject` 为明确的原生测试替身，声音与操作系统通知需另行验证。

**推荐驱动为直接 Playwright Library，也是脚本默认值。** 已验证的实际依赖为 Playwright `1.62.1`、Node.js `24.19.0`、Python `3.14.7`、Google Chrome `153.0.8010.36`；该 Playwright 包要求 Node.js `>=20`，脚本要求 Python `>=3.9`。版本来自实际使用的 `package.json` 与运行环境，并核对了 [npm 官方 registry 发布元数据](https://registry.npmjs.org/playwright/1.62.1)。库模式的安装与使用见 [Playwright 官方说明](https://playwright.dev/docs/library)。

普通 checkout 可按下面的命令安装相同的库版本；这是开发者显式执行的本地安装步骤，测试脚本不自动安装依赖或修改全局配置。Playwright 放在独立的 `.task-tmp/ui-browser-tools` 目录，使用已安装的 Chrome，无需下载 Playwright 自带浏览器。测试 fixture 目录必须不存在：

```sh
npm install --prefix .task-tmp/ui-browser-tools --registry=https://registry.npmjs.org --save-exact playwright@1.62.1
swift build
python3 scripts/create-ui-fixture.py .task-tmp/ui-browser-qa --binary .build/debug/vela --with-routing-project
python3 scripts/test-ui-browser.py .task-tmp/ui-browser-qa/fixture.json \
  --binary .build/debug/vela \
  --driver playwright \
  --playwright-module "$PWD/.task-tmp/ui-browser-tools/node_modules/playwright/index.js" \
  --browser-executable "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
```

若 Chrome 安装位置不同，替换 `--browser-executable`；已有其他 Playwright 安装时，传其 `index.js` 路径。缺少指定模块或浏览器时脚本会在启动测试服务前报错。保留工具目录可重复使用；每次完整复验换一个新的 fixture 目录。

脚本使用一次性本地地址和独立浏览器会话；结果、失败截图和真实 RPC 方法记录保留在该 fixture 目录，驱动写入每项结果。可选 Beacon 项目只用于通知跨项目验收；默认截图 fixture 仍只有 Harbor。测试控制器仅能延迟或拒绝指定只读响应，用于重现异步导航及刷新失败，不构造业务响应、不重试写操作。

`--driver agent-browser` 保留为需要自行安装 CLI 的替代入口；本机诊断已记录该驱动的不稳定行为，未用它宣称其余流程通过。`--checks routing` 等只用于集中诊断，最终完整复验不得省略检查组。

现有性能测量见 [verification.md](../verification.md)。新版要求的搜索 p95 `<120 ms @100k records` 等属于独立验收目标，不能从原生技术栈或较小安装包推导达标。

## 本轮之外的需求追踪

本文件仅负责本轮可解决的体验与展示问题。新版需求中的完整 Harness 能力、Subagent 层级、排除规则、历史回填、Memory Authority/有效期/语义 Recall、真实配额、完整 Improve/Planner、自动 Workflow Discovery、错过调度补跑、完整 Agent Eval/Evidence Graph，以及正式签名和更新，不因视觉重构自动完成。

继续以 [需求矩阵](../requirements.md)、[功能状态](../status.md) 和 [当前 API 契约](contracts.md) 追踪实际能力。新版 FR/NFR 编号在此仅作用户需求定位；本文件未复制私有参考报告，也未改变已接受的技术路线。
