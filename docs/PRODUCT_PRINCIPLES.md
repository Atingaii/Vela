# Vela 产品原则 / Product principles

**评估基线：2026-09-12，`6c2bf54`，`0.1.0-preview.2`。** 这是产品方向与验收原则，不是已实现能力声明。实现状态见 [PRD](PRD.md)、[追踪矩阵](TRACEABILITY.md)；最终通过条件见 [ACCEPTANCE](ACCEPTANCE.md)。并行开发中的改动必须补充代码、测试和运行证据后再更新状态。

**English:** Vela is a local-first macOS engineering layer above existing coding agents. Its five goals are Observe, Remember, Improve, Automate and Verify. Reuse closes the loop in future sessions; it is not established by saving an asset or exposing an MCP tool. The current preview does not meet the complete product definition.

## 五个不变目标

| Goal | 用户的问题 / User outcome | 不足以证明达成的替代指标 |
| --- | --- | --- |
| G-OBS · Observe | 所有受支持 Agent 现在、过去做了什么？能找到真实来源。 | Agent 卡片、目录存在、历史消息的最后时间 |
| G-MEM · Remember | 哪些工程事实应该跨 Session/Agent 保留？当前项目应采用哪个版本？ | Memory 数量、完整对话摘要、返回若干检索结果 |
| G-IMP · Improve | 用户反复纠正的问题是什么，是否值得改变工程上下文？ | Suggestion 数量、一次情绪、模型自报 confidence |
| G-AUT · Automate | 哪些重复操作可以变成受控执行的流程？ | Workflow 编辑器、保存 Markdown、模拟成功记录 |
| G-VER · Verify | 同条件下的改变是否改善真实任务，是否在未来仍有效？ | build 成功、命令 exit 0、按钮显示 Better |

完整路径为 `Observe → Remember → Improve / Automate → Verify → Reuse → Observe`。原始构思的简短品牌词未单列 Improve；最新验收明确五目标，故保留 Improve。Reuse 是所有目标共同产生的未来结果，不替换 Improve，也不是第六个独立功能堆栈。

## 产品决策原则

1. **以未来行为为终点。** 对一个适用问题，记录发生、保存正确上下文、生成候选、验证候选、批准采用、未来 Session 实际使用及后续结果。任一连接缺失，整链保持未验收。
2. **事实、推断和未知分开。** 日志能证明写过某事件，未必证明进程仍存活；配置存在未必被 Agent 加载；Context 被提供未必被使用；测试运行未必通过；相关性未必是因果。
3. **Memory 属于用户和项目。** Markdown 是可读资产；SQLite 保存索引、关系和运行事实。项目/分支/任务范围先于相关性排序。旧事实被 supersede 后保留来源但不再默认召回。
4. **精度优先。** 明确重复纠错才值得晋升；正常规格迭代、引用文本、假设与一次抱怨必须能产生零建议。一个错误 Always-on Rule 会污染未来任务，不能用召回更多建议来抵消。
5. **知识与过程分流。** 事实进入 Memory；做法进入 Guideline；约束进入 Rule；可重复顺序进入 Workflow。优先较窄载体：Hook → Workflow → Reference → Guideline → Skill → Rule。每个选择说明适用范围和成本，不要求为了展示阶梯而制造所有载体。
6. **建议与执行分离。** 模型或检测器可以贡献候选，不能扩大权限。Dry Run 对测试脚本、Agent 命令和所有可能写入均 stub；批准绑定冻结参数；不对未知外部副作用自动重试。
7. **证据可以反驳候选。** Lab 必须允许 Worse、Reject、Inconclusive 和 Unavailable。评分标准与对照条件在看到结果前确定。不得从假设构造纠错率下降或 token 节省数字。
8. **默认本地优先、最少权限。** 不要求账户或托管会话。Private Library 在检索执行边界排除。用户明确导入 URL、批准远程 Agent 是独立网络边界，不能宣传“任何内容永不离机”。
9. **安静、紧凑、可检查的 macOS Sidecar。** 高频任务少步骤，正文清晰，状态有来源，错误可恢复。快捷键在菜单/帮助/tooltip 中发现，不把全套快捷键铺满日常主界面。通知只服务需注意的事件，声音可关闭。
10. **验收结果不可互相抵消。** 完整功能、完整产品、性能、安全和分发各有证据。54 个核心测试、12 组 renderer 测试、漂亮截图及已上线官网都不能替代 Golden Scenario 或六个 Hard Gate。

## 三个参考项目如何影响 Vela

以下是用户指定的设计方向；参考项目自己的公开描述不构成其全部能力已验证，更不构成 Vela 的实现证据。

| 参考 | 采用的产品思想 | Vela 的独立责任与边界 |
| --- | --- | --- |
| [Blume](https://blume.codes/) | 跨 Harness 观察、配置治理、证据与 Diff、安静的侧边工具。官网公开展示 Agents/Setup/Usage/Improve，并区分部分未来能力。 | **客户端当前视觉参考**；借鉴信息层级、操作密度和渐进披露，做 Vela 原创界面。用户提供的三份 Blume 报告是设计输入，不复制私有源码、提示词、内部文档、商标或花朵素材。 |
| [Walrus Memory / MemWal](https://github.com/MystenLabs/MemWal) | 可迁移、可验证、明确所有权的跨 Session 记忆；公开 SDK 展示 remember/recall/restore。 | 先实现本地 scope、provenance、superseding、restore 与真实 reuse。不引入其账户、链或 relayer 作为 V1 的隐含依赖；Walrus backend 是后续选项。 |
| [px0](https://px0.ai/) | 可读 Workflow/Guideline、Dry Run、冻结审批、Run 来源与版本。 | **官网沿用已发布的 px0 参考方向**；产品自动化限于 Coding/Engineering。不能照搬通用生活助理范围，也不能因为有 Workflow 页面便声称连续改善成立。 |

以上公开入口于 2026-09-12 核对；不作竞品运行时可靠性、效果或安全保证。客户端参考 Blume 与官网参考 px0 是两个独立约束。

## 需求与设计的优先级

最新用户结果与验收要求 → 产品原则 → PRD/原始 FR/NFR → 设计与 ADR → 代码与测试 → 运行证据。原附件的 Electron/Rust 等属于暂定实现；已接受的 Swift/AppKit/WKWebView 路线见 [ADR 0001](adr/0001-native-macos-core.md)。评估等价的隔离、安全与性能结果，不因未使用 Electron 判失败，也不因使用原生框架推断达标。

原始固定导航是设计设想；后续用户要求产品经理视角优化，当前独立 Memory 入口不构成目标漂移。核心能力不得因移动入口而删减。所有 UI 实现继续遵守仓库 [AGENTS.md](../AGENTS.md) 的指定 Antigravity CLI / Gemini 3.8 Flash (High) 约束。

新增模块先说明服务哪个目标、删除后核心路径是否仍可靠、增加哪些长期成本。没有 Goal 的实现先移入 [NON_GOALS](NON_GOALS.md) 讨论；没有测试和证据的需求不能标完成。
