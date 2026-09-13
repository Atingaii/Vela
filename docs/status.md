# 功能状态与限制

**当前开发分支：基于 0.1.0-preview.2 的未发布完整能力扩展。产品总验收仍为 No-Go。** 下载仍是 [preview.2](https://github.com/Atingaii/Vela/releases/tag/v0.1.0-preview.2)，不包含下面新增的开发分支功能。源码：[Atingaii/Vela](https://github.com/Atingaii/Vela)；[公开官网](https://vela-engineering.zzzsssaa.chatgpt.site)。

目标已扩展为覆盖 Blume、Walrus Memory/MemWal、px0 的全部已交付能力，见[228 项逐项台账](parity/README.md)。旧版最小范围不是删减目标的依据。实现、隔离测试、真实提供方、桌面接通、发布验收分别记录；测试总数不能抵消缺失功能。

## 当前源码

| 模块 | 已实现行为 | 尚需完成或验证的边界 |
| --- | --- | --- |
| 桌面与语言 | AppKit、系统 WKWebView、独立 Swift helper；分组会话、记忆、工作流、审批与设置；简体中文/English 持久化切换 | 当前交付平台 Apple Silicon、macOS 13+。新增能力的界面正在指定 Antigravity CLI 中接通，不能沿用旧 UI 结果证明新入口可用 |
| 会话观察 | Claude/Codex 增量日志、部分 Cursor 导出/SQLite、Pi v1/v2/v3 分支记录与 OMP 元数据；有界流式读取、来源版本、身份/轮转检查 | 完整历史回填及所有私有 Cursor 格式仍未完成。日志推断不等于进程存活证明；Pi 最新持久化分支不冒充当前活跃分支 |
| 显式历史回填 | Claude/Codex/Pi/OMP JSONL来源清单、固定epoch、分批读取与重启续传、稳定分页和完整原文分块；解析/原文/分支分别计量 | 已完成16项新Core与原Provider16项组合验证；Cursor、Todo/子代理产品视图及桌面操作仍需继续接通，不能把未解析原文计为全部功能 |
| Setup | 五harness公开位置目录、项目/全局配置扫描、脱敏版本历史/差异、来源关系、删除/重新出现痕迹与不完整扫描保护 | Core与隔离CLI已验；原生入口接通中。TOML/YAML无安全解析器时只给元数据/hash，不提供原文；实际已加载配置仍未知，不执行被扫描的Hook/MCP |
| Memory | 九类内容、七类作用域、Candidate/Active/Superseded/Archived、来源消息、Markdown 人工编辑；Active-only Recall | 完整提取、合并、遗忘、团队策略与所有插件入口仍按台账验收 |
| 语义 Recall | 系统已安装 NaturalLanguage 模型、本地分页索引、lexical/semantic/hybrid、版本/维度/sourceHash 校验、明确语言与不可用状态 | 默认仍可离线词面检索，不自动下载。真实合成中英文语义召回与界面取消/索引流程已测，不能据此宣称真实长期检索质量达标；Library向量后端仍需实现 |
| Library与Ask | 资料版本、审阅后编辑/归档/恢复/导出/重抓；FTS5段落/原文位置与本地重排；独立审批问答与重新核验的续问 | 真实Codex一次来源问答已通过，FTS路径有独立Core/CLI验证。缺标记/错误privacy/私有来源与消失资产反例已修；引用存在不证明语义正确。YouTube、vault与完整批量来源管线仍需接通 |
| 归档与 SDK | 有界 JSON 导出/校验/候选导入、跨项目身份与幂等；可安装 TypeScript/Python 本地 SDK，含语义接口 | 归档为明文，排除 private/global。SDK 安装产物已隔离验收；本地归档不等于加密跨设备同步 |
| 可选 Walrus 后端 | 独立TypeScript包、固定官方SDK、显式profile/隔离worker、owner交易准备/签名核验、端侧manifest与原文恢复/候选构造 | 真实安装包、公开兼容性与testnet只读交易模拟已通过；官方faucet限流，测试地址无gas。真实加密写入/恢复与owner/delegate链上提交仍待验证；模拟不是链上成功，不默认给桌面增加Node |
| OpenClaw集成 | 可选独立插件、宿主agent/workspace映射、namespace召回、候选捕获、注入框与持久操作日志 | 真实隔离宿主加载/CLI/hook与完整会话通过；模型响应使用本地合成provider。两条新记忆均为候选，不等于真实模型采纳或远端加密写入。自动捕获默认关闭，远端提取另需明确明文接收与预算 |
| Checkpoint / Reuse | 用户工程记录及真实 Git 快照；中立交接；项目 Codex SessionStart Hook 的预览、Apply/Undo 与提供上下文收据 | 原生 Session Transfer、更多官方 lifecycle hooks 和完整真实下一会话闭环仍需验证。收据证明已提供，不证明模型遵守 |
| Workflow Context | 已选择 Guideline、Active Memory、只读 Git/Library/stdin/literal 输入，冻结来源/hash；显式 `{{vela.prompt}}` 参数实际交给 Agent | 旧 raw argv 不被静默改写。记录 prompt 消费路径不等于证明模型采纳约束 |
| 自然语言规划 | 明确选择 Codex 程序/模型/effort，冻结请求，经审批生成问题或默认停用草案，再显式保存 | 真实提供方已产出有效草案；规划工具目录仍需拓展，与自主多轮工具执行是不同能力 |
| 执行与组合 | 工具步骤、Markdown版本、Dry Run、逐工具审批；冻结pipeline/子工作流、条件透传、子输入、根产物文件/Inbox；审阅后克隆/启停/归档/恢复 | 四项独立恢复/并发反例已修后通过，历史证据保留。完整双版本Replay与更多工具仍按台账推进 |
| 模型工具循环 | 有界多轮结构化决策、真实只读工具结果回传、外部动作独立排队审批、响应式查询/取消 | 真实Codex两轮+一次Git读取通过；同RPC普通/饱和队列取消通过。工具覆盖、全部账户、严格成本预算等仍未完成，初始循环审批不授权外部写 |
| 外部工具 | 可选 Composio v3.1：Keychain 凭据、分页发现、固定版本 schema/账户、审批后执行、连接/撤销等动作、`connector.call` 步骤 | 无凭据真实 HTTPS 拒绝路径已测；尚无真实测试账户正向执行证据。结果不确定不重试；失败回包不证明无部分副作用，已知凭据回显在入库前拒绝 |
| Improve | 保留确定性检测；新增三阶段模型提取/聚类/规划，最多三次审批内调用、原消息证据、五类候选载体、带 hash 的审阅与 Apply/Undo | 真实提供方三阶段协议与候选链通过，候选未自动应用。尚不能证明真实项目纠错率改善或所有治理诊断覆盖 |
| 调度与后台服务 | 用户显式管理 launchd 用户服务；跨进程 lease、时区/DST、skip/latest/all 有界补跑、去重、持久化完成事件游标、不重叠、需核对状态 | 真实 launchd 安装/启动/崩溃拉起/停止/移除已在隔离环境通过。`usage_reset` 尚未接通；不声称任意外部副作用 exactly-once |
| Watch触发 | 本地只读工具轮询、FSEvents文件观察、首轮基线、按key净变化/阈值积累、重启去重；文件字节SHA256与空闲不重读 | 43项定点与两次真实daemon路径通过；事件丢失/重启无法恢复中间变化时明确标记。私有撤销覆盖待发变更before/after；外部只读connector与最终原生界面另验 |
| Usage | 已索引日志 token 与实际 Codex 账户额度分开；通过只读 app-server 请求观测多 bucket/window、真实零、缺失与 stale | 真实 Codex 额度读取通过；Claude 账户额度、定价、精确成本和所有 reset trigger 仍未验收，不从日志 token 推算账户余额 |
| Lab | 同提交命令或 Codex 对照、冻结任务/模型、独立干净 verifier、证据与 Memory 晋升门槛 | 原六次真实任务同分、Inconclusive，拒绝晋升。纵向纠错改善仍未证明，旧计分缺陷与更正保留 |
| 通知与官网 | 可选原生分类通知及三个短提示音；静态公开官网及独立比较/场景/文档/发行页面 | 当前 ad-hoc 应用被 macOS 拒绝通知授权，系统横幅及点击回流未验收。官网展示不构成功能证据 |

## 验证记录如何阅读

本轮新增切片的隔离 Core、编译后 CLI、安装后的 SDK 和真实提供方结果见[持续验证记录](verification.md#full-capability-expansion--13-september-2026)及三个产品台账。不同验证使用不同明确 helper 快照；并行开发中的局部通过不是最终 checkout 全量通过。当前未给新增代码签署完整产品或新发布包验收。

先前提交 `ea8fbd257f813c604a93e070d5f98a6337829d81` 的 [CI](https://github.com/Atingaii/Vela/actions/runs/34715619455)为历史基线：99 项 XCTest、24 组 renderer 检查。先前 1,453,375 bytes 开发包也只是该阶段产物，不能作为新增能力的包体或界面验证结果。更早的原生、Lab、私有检索、通知拒绝与失败复现保留于 verification 文档，不以新测试覆盖删除历史问题。

本机为 Command Line Tools 环境，`swift build` 可用但缺 XCTest；`scripts/test-portable.py` 编译真实 Core 与原同步测试方法，使用小型断言兼容层，**不是 XCTest**。完整 Xcode/CI 使用 `swift test`。

```sh
swift build
python3 scripts/test-portable.py
python3 scripts/test-rpc.py
python3 scripts/check-repository.py
```

安装包、OS 控件、真实外部账户、长时间稳定性与性能分别验收。有限测试不能证明绝对零缺陷，也不能从 Swift 或包体小推导延迟/RSS/CPU全部达标。

## 数据与发布边界

- 当前公开预览与本地开发包使用 ad-hoc 签名，没有 Developer ID 签名、公证或已验证的签名更新通道。通道字符串不会改变这些事实。
- 默认数据在所选 store 的 SQLite WAL 与 `assets/{memory,workflow,guideline,library,checkpoint}` Markdown 中；本地使用不要求云账户。
- 可选连接器凭据进入 macOS Keychain，不进入 SQLite、归档和日志。明确联网的 URL 导入、模型执行、Composio 或 Walrus 操作各有独立目的和用户控制；不会自动将全部会话上传。
- Walrus 的客户端加密不隐藏发往嵌入服务的明文；官方远端恢复可能要求 relayer 解密/重建索引，必须单独选择，不能将其描述为全端侧隐私。
- 预览格式的长期兼容、迁移、备份与更新还需完整验收；保留用户资产与原始来源，测试及一次性资料不进入应用包。

## Notification acceptance boundary

The ad-hoc application was denied notification authorization on the validation host. Sound previews work, but OS banner delivery and click-through remain unverified. This is a release gate, not a feature that can be marked complete by a renderer test.
