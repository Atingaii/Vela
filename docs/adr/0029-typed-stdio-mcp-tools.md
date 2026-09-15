# ADR 0029：有类型边界的本地 stdio MCP 工具

- 状态：Accepted；具体客户端和回归验证单独记录
- 日期：2026-09-13
- 范围：WM-39 / PX0-107 的本地工具面，不含远端账户、HTTP、OAuth 或模型执行

## 协议依据

按 MCP 固定版本 [2025-11-25 生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)、[基础消息](https://modelcontextprotocol.io/specification/2025-11-25/basic)、[工具](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)、[stdio 传输](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) 和 [取消](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation) 实施。旧 [2024-11-05 工具](https://modelcontextprotocol.io/specification/2024-11-05/server/tools) 保持文本结果；annotations 与 structured output 分别依据 [2025-03-26](https://modelcontextprotocol.io/specification/2025-03-26/changelog) 和 [2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/changelog) 引入时点输出。

## 决策

独立 `MCPTools` 实例保存 initialize/initialized 状态，支持上述四个已知日期协议。协商支持版本则回同版本，未知版本回本服务最新支持版本，客户端可断开。默认仅 tools 能力；不假报 sampling、tasks、resources、prompts 或远端登录。request ID 不可在本连接复用；通知永不返回响应；有界读写操作不自动重试。JSON-RPC malformed envelope/未知工具与工具输入或业务错误分开报告。

工具目录与执行校验共用明确静态 schema，additionalProperties:false；严格区分数字与布尔、枚举、范围、必填字段和项目注册。参数被忽略或悄悄删掉不是校验。旧七个只读名字和四个贡献名字保留，原列表文本结果保留数组形状，分页进度由工具结果 metadata 提供。此前被静默删除的 id/state/path/includePrivate 等不合法请求现在明确失败；只有 candidate 状态可贡献，客户端应移除更新身份并显式请求候选创建。

通过构造参数注入已有 `coreCall`，避免重新建立 FoundationService、扫描宿主历史或丢失隔离 sourceRoots。读取依赖当前 managed asset、来源公开状态和项目/scope资格，Library 复用统一 fresh/public gate。Memory 默认仅 Active，显式 candidate 只供审阅。私有、归档、丢失、链接和跨项目数据不能返回。列表先取窄 ID 页，逐项验证，按最后扫描 ID 前进，不能因过滤后空页停住。先对完整正文脱敏，再以可见正文的 Swift extended grapheme cluster 分页，保留完整中文/emoji；后续页必须带未改变的原文 sourceHash；不会把凭据切成多页绕开脱敏。

`--contribute` 只新增候选记忆/原子 bulk、现有 checkpoint/signal/suggestion 和明确命名的本地候选 archive restore。checkpoint 保留现有固定 Git 只读观察；FoundationCommand 已关闭 fsmonitor/hooks 和用户全局/系统 Git 配置。不运行用户测试脚本、不自动激活、不改项目文件、不启动 connector/workflow/model。远端 restore、分析模型、HTTP/OAuth 和其他客户端安装仍是后续功能，不以此模块关闭全部参考产品范围。

## 权衡

不继续复用一份宽 schema：它无法表达每个工具真正需要的字段，且旧代码只剥掉危险字段，会掩盖客户端错误。不新建通用 JSON Schema 平台：静态目录只需要有界的 object/array/string/number/integer/boolean/enum/anyOf 子集，对外 schema 仍是标准 JSON Schema。服务不接收或执行调用者定义的 schema。

读取可能更新 Vela 自有派生索引以反映人工编辑，但不会改源项目文件。取消通知可以忽略已经完成或无法取消的本地原子动作；不声称撤销已经写入的贡献，不做隐式重试。stdio 进程退出即结束协议状态。

## English summary

A stateful, version-negotiated stdio MCP surface uses per-tool schemas and project-scoped fresh-source checks. Existing tool names and legacy list text shapes remain compatible; previously ignored unsafe fields now fail explicitly. Contributions create candidates or other narrowly defined local records, with no model, workflow execution or remote account access. The module does not establish complete remote MCP parity.
