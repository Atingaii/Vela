# Desktop Comfort、Run Feedback 与 Lab Recall

本文记录本轮已合入开发源码的桌面舒适度、Run Feedback 与 Lab Recall 约定及有限证据。实现来自阶段根 `.task-tmp/flash-author-2026-09-14`，已由集成方机械合入；完整188项规格、228项参考能力、最终原生与 CI 验收仍均为 **NoGo**。

## 桌面信息层级

资产普通行显示服务端给出的 scope 与项目内相对路径（或不臆测信任的末段位置）；标题的 `title` 可保留完整路径。绝对路径、资产 ID、完整 hash 和原始 JSON 放入默认折叠的“位置与标识/技术详情”，并提供复制完整路径。执行目标、命令、网络范围和变更影响仍以结构化字段可见，不能为隐藏技术细节而省略审批所需判断信息。

技术详情必须默认折叠，长路径、argv、ID、hash 和原始 JSON 要可折行或受限滚动，不能撑出卡片或抽屉。服务端诊断决定异常状态；Global、User、Shared 等 scope 只是已返回的范围说明，不能推断为不可信或改变可用操作。

## Run Feedback

这是终态、非 dry-run、非私有 run 的人工观察，不能改变 run 状态、审批、工作流定义或 Health 的客观 successRate。打开表单先只读调用 `runs.feedback.prepare {project,runId}`；取消或 prepare 期间不写入。

写入严格为：

```json
{"project":"…","runId":"…","runHash":"…","previousFeedbackHash":null,"outcome":"good|bad|clear","reason":"…"}
```

即 `runs.feedback.record` 的六字段。runHash 与 previousFeedbackHash 来自本次 prepare 的闭包，不进入可编辑控件或普通页面。保存按钮在请求中保持 disabled；CAS、超时或不确定结果不自动重试。后端拒绝旧 receipt 后，用户必须重新 prepare/review；UI 仅可保留草稿供审阅或复制，不能复用旧 hash。

Run drawer 的当前反馈投影不能从 `runs.get`、`runs.list` 或 dashboard 原始 run 推断；每张合格详情卡片都单独只读调用 `runs.feedback.prepare {project,runId}`，再以 project、runId、drawer 实例和该卡片自身 epoch 校验回包。prepare 只给卡片呈现当前 outcome/reason，runHash 与 previousFeedbackHash 继续只留在表单闭包。`runs.feedback.get/list` 是直接记录查询，不替代详情投影；历史初页为 `runs.feedback.history.list {project,runId,limit:20}`，只原样追加返回 cursor，详情用 `history.get {project,id}`。cursor/snapshot 过期、run 删除或变私有时清空旧展示并显式刷新，不能显示缓存的私有正文。项目、run、详情实例、卡片 epoch 或 modal 变更后的 prepare/save/history 回调必须丢弃。反馈表单的 dirty flag 只允许同一表单内保留用户已改字段，迟到的 prepare 不得覆盖它。

## Lab Recall

每个 baseline/candidate variant 保留四态：

| 状态 | 发送的 `variant.recall` |
| --- | --- |
| 未配置 | 不发送 `recall`，兼容既有 `memoryIds` |
| 自动召回关闭 | `{enabled:false,strictOff:false}` |
| 严格 Memory OFF | `{enabled:false,strictOff:true}`，与显式 `memoryIds` 冲突即拒绝 |
| 自动召回开启 | `{enabled:true,query,mode,scope:"project",budget}` |

开启时 query 非空、mode 仅 lexical/semantic/hybrid、budget 为 1…4000 整数；未知 UI 状态必须在本地拒绝，不能把原始 variant JSON 带入 `lab.run`。隐藏字段不随 disabled/strict 状态发送。表单草稿应绑定单个 modal 与其创建配置，语言重绘不丢输入，关闭或项目切换不能把另一项目/另一 modal 的 draft 带入。

Core 以实际 `MemoryService.recall` 冻结 receipt，只保留 active、非 private、项目 scope 且来源合格的 Memory。semantic/hybrid 要求实际 mode 等于请求值、status=ok、indexIncomplete=false；否则 fail closed，不自动降级。运行前重新核验冻结的显式/Recall 来源、项目、生命周期、隐私与来源 hash；任一项变化都会使旧 receipt 失效，必须重新 prepare/review，不能重放旧 receipt、重新召回、替换、激活或重试。

`lab.run` 同事务创建 evaluation 与 executable approval：任何一方无法写入则没有孤立 pending eval/approval。UI 创建后只能显示 pending approval，绝不自动 approve 或启动 provider。

## 证据与限制

r4 renderer 的 `app.js` SHA256 为 `05e206cb841038df037e77503ae080b9138a5aa5cec811ff086d62eb8bf5acca`，helper SHA256 为 `020726c1276ad5de361c073b9b8e0f16bdd046b747a2475701a16e48f640551c`。以下浏览器运行均使用合成 fixture，未执行 provider。

- [Desktop 6/6](../../output/playwright/combined-comfort-r4-browser/results.json)：资产路径、审批冻结 wire、过期刷新、跨项目延迟、中英与窄窗路径通过。
- [Run Feedback 5/5](../../output/playwright/combined-comfort-r4-feedback-browser/results.json)：prepare/cancel 零写入、good→bad→clear/history、关闭再打开后的 drawer feedback 投影、output 合同与 stale CAS/双击/跨项目延迟通过。
- [held prepare gate](../../output/playwright/combined-comfort-r4-feedback-prepare/results.json)：用户选择 clear 后释放 held prepare，控件身份和最终值不变，未重现迟到预填覆盖。
- [此前 Lab 浏览器 3/3](../../output/playwright/combined-comfort-r2-lab-browser/results.json) 仍是四态 payload、来源/隐私重验及项目/语言草稿边界的独立历史证据；不把它冒充为 r4 同 SHA 的复验。
- [原生 r3 观察](../../output/playwright/native-comfort-r3/native-observations.json) 记录 history footer 成功、Feedback 从 good r1 写到 bad r2 而 run 仍为 completed、Lab Recall ON 字段及切换 English 后草稿保留；[r4 启动器身份](../../output/playwright/native-comfort-r4/launcher-comfort-r4.json) 对应重启后 Harbor completed run 正确显示 r2 负面 reason，且 header 竖排经 AX 与截图复核已修。

r5 将运行记录表格限制在可横向滚动的局部区域，原生重启、反馈恢复、标题与表格、资产长路径、一次合成审批文件写入已实测，见[原生 r5 记录](../../output/playwright/native-comfort-r5/native-observations.json)。[r5 drawer 专项 4/4](../../output/playwright/combined-comfort-r5-drawer-focused-r4/results.json) 已通过：真实初读回包延迟与本地保存、标记的错误/畸形 transport、项目/运行/关闭三类迟到回包，以及 1200px 中英标题与表格列边界/横滚后操作可见性。故最终原生、checkout/CI、发布包、完整188项规格与228项参考能力仍均为 **NoGo**。Core 的 68/68 是 portable 方法回归，**不是 XCTest**；另有 1 项 Lab eval/approval 原子故障注入，只覆盖所列 Core 边界。

本轮 UI 作者使用用户新授权的兼容 API 请求 `gemini-3.8-flash`、`high`；本文不保存凭据、endpoint 或原始会话，且该记录不独立证明上游模型身份。

源码身份与 UI 作者请求的精简记录见 [provenance](desktop-ui-provenance-2026-09-14.json)。不含 API 凭据、网关地址或原始模型会话。
