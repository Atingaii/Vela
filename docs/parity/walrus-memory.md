# Walrus Memory / MemWal 功能覆盖审计

审计日期：2026-09-13。目标是逐项覆盖参考产品已交付能力并改进，而不是把 Vela 的局部实现换成“已完成”标签。此记录核对公开产品文档、发布版本和 Vela 源码；没有登录第三方账户、读取任何用户私钥、发送用户记忆、签署链上交易或验证真实远端部署。

## 基线与证据边界

第一方仓库基线为 [MystenLabs/MemWal `493c9e66851e1b542ce5f55a547827f64e141c45`](https://github.com/MystenLabs/MemWal/tree/493c9e66851e1b542ce5f55a547827f64e141c45)，提交时间 2026-09-11 07:05:08 UTC。官网文档入口为 [docs.wal.app/walrus-memory](https://docs.wal.app/walrus-memory/)。下方仓库文档链接固定提交，不随 dev 分支漂移。

| Surface | 固定仓库中的版本 | 本次读取 registry 的已发布 latest | 判断 |
| --- | --- | --- | --- |
| TypeScript SDK | 0.1.7 | [0.1.6](https://registry.npmjs.org/@mysten-incubation/memwal/latest) | dev 比发布版本新，不能把 dev 全部视为已发布包 |
| MCP package | 0.0.13 | [0.0.12](https://registry.npmjs.org/@mysten-incubation/memwal-mcp/latest) | 同上；最新提交为登录完成后继续服务 stdin 的修正 |
| OpenClaw plugin | 0.0.6 | [0.0.6](https://registry.npmjs.org/@mysten-incubation/oc-memwal/latest) | 版本一致；未以账户实跑 |
| Python SDK | 0.1.10 | [0.1.9](https://pypi.org/pypi/memwal/json) | dev 比发布版本新 |

`公开能力` 表示第一方当前文档提供可调用功能/源码入口，除非特别标为 gated、example 或 roadmap；本轮没有解包测试每个已发布版本，因此不承诺该功能已包含在所有旧发行版，也不把未测试写成“不存在”。完整覆盖应以这些条目为上界继续验证，不利用版本区别删去需求。

Vela 代码定位：`M` = [MemoryService](../../Sources/VelaCore/MemoryService.swift)，`S` = [Store](../../Sources/VelaCore/Store.swift)，`C` = [CLI/MCP](../../Sources/VelaCLI/main.swift)，`R` = [ReuseService](../../Sources/VelaCore/ReuseService.swift)，`I` = [ImproveService](../../Sources/VelaCore/ImproveService.swift)，`A` = [MemoryArchiveService](../../Sources/VelaCore/MemoryArchiveService.swift)。`E` = [SemanticMemory](../../Sources/VelaCore/SemanticMemory.swift)。 “未实现”限于本仓库公开代码路径，不是对未来范围的排除。验收列为必须实际执行的场景，列在这里不代表已经通过。

## Memory 数据、检索与恢复

| ID | 参考能力及证据 | 参考交付边界 | Vela 当前代码/缺口 | 完成验收 |
| --- | --- | --- | --- | --- |
| WM-01 | 单条 remember 与可返回持久标识 [S1] | 异步接收 job，再等待存储完成 | M/S 有本地保存；可选 adapter 封装 reviewed remember/status 与真实 SDK job，尚无 funded remote roundtrip | 保存后终止进程，新客户端取回相同原文与来源；远端完成才报告耐久 |
| WM-02 | Bulk remember 与逐条结果 [S1] | 独立 job ID，批量等待和失败结果 | 可选 adapter 新增冻结 prepareRememberBulk，复用公开 SDK bulk jobs；每项计入写入上限，逐项状态/有界等待已通过安装包协议测试，实际远端写入待测试 gas | 部分远端失败准确归因，未完成不报成功，不重复写已完成项 |
| WM-03 | 异步 job 查询、等待超时与失败 [S2] | pending/running/done/failed；调用接受不等于检索可见 | 可选 adapter 单条/bulk status 与有界 wait 已实现；保留 succeeded/failed/missing/pending，断线持 job ID 继续查，读状态不传 SEAL session；真实账户任务待验收 | 断线后持原 job ID 继续查询；超时不自动重试写入 |
| WM-04 | LLM analyze 提取多个事实 [S1] | 自动提取后返回存储 jobs | 可选 Walrus SDK 已封装官方 analyze、显式 relayer 明文授权、accepted jobs 和一次性冻结操作；真实提炼质量与远端写入仍待账户验收 | 多事实/否定/引用/隐私 fixture；每条保留源区间，失败不制造事实 |
| WM-05 | 语义 Recall [S3] | Embedding + pgvector/HNSW cosine 近邻 | E 已有真实本机 Apple en/zh-Hans embedding、版本化 SQLite Float BLOB 与流式 semantic/hybrid；远端 pgvector/provider 尚未接入 | 同义改写可召回，语义相近但错误项目不可召回；记录实际模型版本 |
| WM-06 | similarity/distance cutoff、limit [S1] | 相似度阈值与限量查询 | E 有真实 cosine 阈值、top-K、保守 token budget 和截断标记；M 保留词面默认 | 检查阈值边界、空结果、明确 limit 和预算，同时不伪称词面分为 cosine |
| WM-07 | 新近匹配、recency/importance 加权 [S1] | `recent` 从语义匹配中排序；weights 只重排候选 | E 的 `memory.semantic.recent` 在所有合格向量上按创建时间、cosine、稳定 ID 排序；query relevance 仍可显式 recency/importance 加权，recent 拒绝权重。安装后 TS/Python consumer、source freshness 与 namespace 隔离已验收；远端排序未接入 | 新旧/缺失/未来时间 fixture，固定时钟，安装包 recent 调用与权重拒绝 |
| WM-08 | 独立 embed 与预计算 vector 检索 [S2] | `/api/embed`、manual recall 返回 blob IDs | E 的 `memory.semantic.embed` 和 `memory.semantic.query` 已为只读公共 RPC；embed 不持久化，query 只接受当前本机模型兼容的有限非零 vector，未提供或伪称 Walrus blob ID。已安装 TS/Python consumer 验收；远端 manual blob 检索未接入 | 维度/NaN/模型不匹配、64 KiB、无持久化、模型 unavailable、namespace/source invalidation 的 Core 与安装包检查 |
| WM-09 | owner + namespace 分区 [S4] | 检索与恢复匹配 namespace；不是 delegate 级 ACL | M 新增真实 namespace scope；integration API、词面/语义召回均严格隔离，已测；远端 adapter 显式 profile owner/account/namespace 并查 owner 后签名，待实网验收 | 两 owner 同 namespace、同 owner 两 namespace 均按合同隔离 |
| WM-10 | namespace 枚举及数量/存储字节 [S5] | 游标分页、metadata-only，无需解密全文 | 可选 adapter 复用官方 SDK owner namespace 分页，真实签名协议 fixture 已过；实网完整遍历未验收 | 超过一页仍不漏/重、真实字节、权限拒绝、稳定增量水位 |
| WM-11 | Memory 与 agent 元数据读 API [S5] | owner-scoped memories/agents，分页不依赖 page length | 可选 adapter ownerMemories/ownerAgents 已实现，使用公开签名 REST、字段白名单和 endpoint/account/owner 绑定游标；真实协议 fixture 已过，账户完整遍历待验收 | 遍历上限之外完整集合；agent 来自真实身份，不臆测 |
| WM-12 | 删除 tombstones 与增量同步 [S5] | 删除标记单独返回；超保留窗口要求 resync | 可选 adapter 返回 deleted tombstones、mustResync、snapshotVersion 2 与增量 cursor；支持空页继续/保留最终水位，已测协议；真实双客户端同步待验收 | 两客户端 create/update/delete 同步，旧 cursor 触发完整重建 |
| WM-13 | Walrus 加密 Blob 持久化 [S6] | 密文远端保存，vector index 可重建 | S/A 为本地明文；可选 adapter 已接官方 clientEncryption/relayerProcessing，真实远端加密往返未验收 | 远端无明文、断线重连、完整性失败拒绝、无账户秘密进入日志 |
| WM-14 | namespace 索引 restore [S7] | 链上枚举→下载→解密→embedding→索引，跳过已索引记录 | A 有已导出记忆恢复至空 store，E 可显式重建本机索引；可选 adapter 已封装显式 relayer index restore 与独立端侧 manifest reader；真实成功解密/索引重建未验收 | 丢失索引后重建实际记录；坏 UTF-8、解密失败与暂时失败分别计数 |
| WM-15 | 大集合恢复边界 [S2][S7] | 默认 newest 10；无 cursor；侧车候选数封顶；`truncated=false` 不证明全覆盖 | A 明确最多 100 条/1 MiB，超限不隐式截断；全量远端恢复未实现 | 超过来源限制的命名空间仍可完成；可恢复断点且最终集合哈希相等 |
| WM-16 | forget index 而保留 Blob [S2] | `/api/forget` 仅删除索引，可 restore | 可选 adapter 冻结 prepareForgetNamespace，显式只清选定 namespace 索引且不传解密 session；真实签名协议已测，Blob 保留/恢复实网待验收 | 清索引后 Blob 仍可验证，恢复无重复，不能误称销毁 |
| WM-17 | namespace stats [S2] | memory_count/storage_bytes 来自实际存储 | memory.integration.stats 有有界非私有数量/状态/complete；plugin stats 有持久 capture 日志；远端 namespaceStats 核对 owner/namespace 与非负真实计数，缺字段拒绝，实网待验收 | 存储/导入/删除后实际字节与数量一致，缺测量不报 0 |
| WM-18 | 内容版本和 immutable blob lineage [S8] | 密文内容寻址，每次写可产生新版本；不是自动去重 | M supersedes 生命周期；A 保留源 scope/state 与记录摘要，新版本新 ID | 原版本可定位、来源可追溯，修改后不覆盖归档导入版本 |
| WM-19 | 跨设备/跨应用恢复 [S7] | 同身份连接索引；新 relayer 可从 Blob 重建 | A 独立 JSON 导入；可选 SDK 的 raw/archive manifest 恢复与 Core 原始文本构造已实现，已安装 fixture 通过；实际第二设备/真实解密未验收 | 第二台干净机器/不同根目录恢复原文，召回前审核，不读源设备路径 |

## 身份、权限与存储生命周期

| ID | 参考能力及证据 | 参考交付边界 | Vela 当前代码/缺口 | 完成验收 |
| --- | --- | --- | --- | --- |
| WM-20 | 账户创建及 owner registry [S4] | 一个 Sui 地址一个账户 | 可选 adapter 已封装公开 createAccount builder、完整 bytes/gas cap/owner 签名；testnet registry 实查成功，faucet 429 导致无 gas，未提交 | 显式建立/恢复身份，账户误配失败，Private Library 不自动离机 |
| WM-21 | delegate 密钥增加、撤销 [S4][S9] | owner 控制；delegate 能存/读/恢复但不能管理账户 | C 有进程级能力；可选 adapter add/remove delegate 精确预览/签名/一次提交已实现，真实链上授权撤销未验收 | 只读/写入/撤销分别验证；撤销后新请求拒绝，无密钥泄漏 |
| WM-22 | active/freeze/reactivate 与撤销轮换 [S4] | access counter 前向轮换；旧密钥已读历史无法自动收回 | 未实现 | 冻结阻止新解密，旧授权不能预取未来密钥；明确历史撤销边界 |
| WM-23 | 请求 Ed25519 签名、时间窗、nonce [S6][S2] | 账户信息与请求体参与签名；重放拒绝 | 本地 stdio 不变；可选 adapter 复用真实官方 Ed25519 签名，body/path/nonce/account fixture 通过；实网重放/时间窗拒绝未验收 | 改参数/账户/路径/时间、重放 nonce、签名失效全部拒绝 |
| WM-24 | 本机 client-side SEAL/manual 模式 [S10] | 客户端加密/解密与 embedding，relayer 收密文/vector | 可选 adapter 调用官方 Manual SEAL 公开 API；embedding provider 原文可见；无账户端到端验证，A checksum 仍不等于加密 | 密钥由用户控制，服务端明文检查、密钥轮换和丢失恢复实测 |
| WM-25 | owner bearer token 只读 API [S11] | `memories.read` Phase 1；无 write/renew scope | 未实现；MCP贡献权限不等价 | token 到期/受众/owner 不符拒绝；只读 token 永不写入 |
| WM-26 | dashboard 登录及客户端授权 [S12] | 签到、delegate 管理、SDK playground；示例 app 公开 | 本地客户端不需账户；无远端账户连接界面 | 成功/取消/过期/换账户、权限撤销、原凭据保留与安全移除 |
| WM-27 | Blob 到期、续期和真实成本归属 [S13][S14] | epoch 有期限；延长现有 Blob，不重新上传 | 本地无到期机制；无远端存储生命周期 | 到期前续期、余额不足、过期不可恢复、标识保持，金额来自实际账单 |
| WM-28 | sponsored/self-funded 写入 [S14] | 服务器或代理资金；owned Blob 归属需真实链上检查 | 未实现 | 对冻结确切交易单独确认，验证 owner、容量、费用，未知结果只查询 |
| WM-29 | dashboard 删除及程序化永久删除 [S15] | 先预览；准备、签署、提交与批次状态；不可撤销 | Memory 只有 archive/supersede 生命周期；无对应安全删除产品入口 | 先逐项预览并校验冻结 IDs，取消零变更，提交后逐项证据 |
| WM-30 | legacy security-delete [S16] | 同时启用两个 flags 才可用；后端选择旧记录，最多 900/batch | 未实现；不能把私有库删除或普通归档称等价 | disabled 404、签名对应准确交易、并发批次冲突、未知提交结果恢复 |
| WM-31 | 账户/Blob indexer 与崩溃续传 [S3][S17] | 持久 chain event cursor、撤销缓存、过期索引清理 | S 本地索引，没有远端事件同步器 | 重启续游标，事件重放无重复，撤销与过期最终一致 |
| WM-32 | 自托管 relayer 与公开 relayer [S18][S19] | PostgreSQL/Redis/sidecar/Walrus/Sui；公开 endpoint 无 SLA 承诺 | Vela 本地 helper 已有；无兼容的自托管远端模式 | 干净部署、版本配对、备份恢复、网络隔离和限流测试 |
| WM-33 | TEE 部署参考 [S20] | **template**；仍需 attestation/measurement/Move 校验接线 | 未实现；不把模板算作已验证端到端功能 | 真正 attestation 校验通过后才允许给出 enclave 信任标记 |

## SDK、MCP 和自动注入

| ID | 参考能力及证据 | 参考交付边界 | Vela 当前代码/缺口 | 完成验收 |
| --- | --- | --- | --- | --- |
| WM-34 | TypeScript SDK 工厂与类型化 API [S1] | 默认/手动/AI/account 多入口 | [本地 TS SDK](../../sdk/typescript/README.md) 有候选 bulk、归档、语义 index/status/recall、取消/错误；可选远端/manual/account/manifest adapter 已安装验收；[AI middleware 已完成实际安装验证](../../sdk/ai/VERIFICATION.md)，完整远端与跨客户端验收仍缺 | 打包安装、类型检查、错误分类、兼容性与完整流程测试 |
| WM-35 | Python sync/async SDK [S21] | remember/bulk/recall/analyze/ask/restore；生命周期 close | 新增 [本地 Python sync/async SDK](../../sdk/python/README.md)，含本机语义 index/status/recall；远端 analyze/ask/SEAL 仍缺 | sync/async 等价，资源回收，取消/超时/失败正确 |
| WM-36 | Vercel AI SDK 中间件 [S22] | 生成前召回注入，生成后可 analyze/save；配置阈值、数量 | [可安装 middleware](../../sdk/ai/README.md) 已通过 17 项真实 AI SDK generate/stream→loopback HTTP/SSE→真实 helper 检查；默认零捕获、明确 namespace、终态候选与未知写入分离；[收据与版本](../../sdk/ai/VERIFICATION.md)。远端 analyze、真实模型质量与其他 provider 完整性不由该验收证明 | 真模型调用可核对注入输入；关闭 autosave 后没有隐式保存 |
| WM-37 | Python LangChain/OpenAI wrapper [S23] | 同步与异步调用 hook；按需依赖 | [OpenAI Responses](../../sdk/python-ai/VERIFICATION.md) 30 项、[LangChain exact ChatOpenAI](../../sdk/python-langchain/VERIFICATION.md) 36 项 installed sync/async/stream 验收；真实 HTTP/SSE/helper，候选默认关、recipient 配置冻结、取消与 uncertain 已测。其他 OpenAI 入口、opaque Runnable/其他 provider、远端 analyze 仍未覆盖 | wrapper 前后消息保真、异常不中断资源关闭、配置可控 |
| WM-38 | Grounded ask [S2][S21] | 召回后结合记忆回答 | C 本地 Ask 不是此完整语义检索+生成合同 | 无来源时不编造，有来源时列真实记录且不串项目 |
| WM-39 | MCP remember/bulk/recall/analyze/restore/health [S24] | 文档化工具与参数；写入等待进度 | [有类型 stdio MCP](../implementation/mcp-stdio-contract.md) 已有严格逐工具 schema、四版本协商、fresh-source 读、原子候选 bulk 与明确本地 archive restore；[真实 stdio 验证脚本](../../scripts/test-mcp-stdio.py)。默认只读，贡献不激活；远端 analyze/restore/job 进度与多客户端安装仍未验收 | MCP 工具发现、严格参数、错误/取消、默认权限、真实写后读 |
| WM-40 | MCP stdio 与 Streamable HTTP [S24] | HTTP session 生命周期与 legacy SSE | C 只有 stdio | 多连接互不串身份、关闭释放、session 限制、协议协商 |
| WM-41 | MCP browser login/logout、multi-account [S24] | 本地 credentials；logout 不等于远端 revoke | 未实现远端登录 | 首次登录后不中断 stdin；取消保旧账户；logout与revoke区别明确 |
| WM-42 | MCP OAuth/Claude connector [S24] | PKCE、refresh/revoke、注册 URI allowlist，受部署配置控制 | 未实现 | 错 redirect/PKCE/replay 拒绝，令牌续期与撤销端到端验证 |
| WM-43 | Claude Code/Codex/Antigravity/Cursor plugin [S25] | MCP + lifecycle hooks；MCP-only 为 best-effort | R 有 Codex Hook 预览/Apply/Undo 与 offered receipt；未覆盖全部插件 | 每个真实支持客户端独立安装/授权/触发/撤销测试，不用注入假事件代替 |
| WM-44 | Claude Desktop/OpenCode/通用 MCP 客户端 [S25] | 提供各客户端文档与接入方式 | C 标准 stdio 可能可接入；未逐客户端验证 | 各实际客户端工具可见，调用/取消/错误正确；未知仍标未验证 |
| WM-45 | OpenClaw/NemoClaw before_prompt_build recall [S26] | 每 turn 自动取回并注入 | sdk/openclaw 已实现；真实隔离 OpenClaw 2026.9.4 post-policy hook runner 验证权限、转义、namespace；完整宿主 turn→本机合成 provider 已核验实际 prompt；真实模型质量/NemoClaw 尚未验收 | 真实 turn 中实际 prompt 包含对应 namespace 原文和上下文边界 |
| WM-46 | OpenClaw agent_end capture [S26] | 最近消息窗口、提取过滤及异步 analyze | 独立 plugin 已实现 opt-in 当前输入/新消息捕获、权限与防反馈；本地仅候选原文，远端复用官方 analyze 和持久防重日志；真实远端提炼未验收 | 不捕获注入回声/无效短句，保留原文，失败不重复保存 |
| WM-47 | 多 Agent namespace 分离、memory_search/store [S26] | session key 派生；是组织分区，非链上 ACL | 实际 host context→显式 project/namespace；tool 参数无跨域入口；真实 helper 同项目两 agent 负例已过，非远端 ACL | agent A/B 同项目时仍按选择隔离，显式跨域需正确权限 |
| WM-48 | 注入内容转义、 framing、防反馈循环 [S26] | regex/HTML escape/不信任标记/tag strip；不等于绝对防注入 | plugin 已有 HTML escape、双标签 frame strip、字节上限、不信任标记、候选默认、防回声/凭据筛选；真实 host/helper fixture 已测，不提供模型服从保证 | 恶意 memory 不闭合容器、不二次捕获；不把模型服从宣称为形式保证 |
| WM-49 | Plugin CLI search/stats [S26] | 可指定 agent/namespace，health/数量可观察 | openclaw vela-memory search/stats 已经真实 host loader/CLI 执行，明确 --agent 与分页完整性，无默认命名空间猜测 | 命令实际调用对应 namespace，统计非虚构 |
| WM-50 | SDK/relayer compatibility 与 typed errors [S27] | 先检查 /version，health 成功不代表 auth 成功 | C 本地诊断；可选 adapter 有官方 /version 协商与鉴权区分，已验证不兼容和401协议错误路径 | 旧版本拒绝有明确错误；健康在线但401时不能显示“已连接账户” |

## 文档示例、运维及可进一步优化点

| ID | 参考能力及证据 | 参考交付边界 | Vela 当前代码/缺口 | 完成验收 |
| --- | --- | --- | --- | --- |
| WM-51 | Codebase memory 与每仓库 namespace [S28] | 可运行接入模式；无独立 tags API | M 已有项目 Memory；缺语义批量适配器示例 | 两真实仓库独立写/召回；无敏感文件自动扫描 |
| WM-52 | Playground、Chatbot、Noter、Researcher [S12] | 四个 **example apps**，不是四个正式产品保证 | Vela 有本地桌面工程流程；无对应 SDK 示例 | 分别展示原文保存、提取、注入和新会话恢复，每个有可复现脚本 |
| WM-53 | Storage loop 及恢复上下文示例 [S29] | 应用自行管理预算、完成状态与生命周期 | 本地工程记忆基础；无远端示例 | 限量循环、存储终态、重启恢复、准确失败退出 |
| WM-54 | 日志、metrics、traces、限流 [S30][S24] | 健康、错误/延迟/队列指标，MCP session 限制 | Vela 有本地诊断/限流；无远端指标 | 指标不包含记忆原文/私钥，负载下保持界限，缺数据不可伪报 |
| WM-55 | 原生内容去重 [S31][S8] | 内容自动去重文档为 **roadmap**；已发布 SDK 的 idempotency key 是另一项已存在能力 | A 已对相同来源版本幂等导入；普通 Memory 新写无通用语义去重 | 并发/重启/响应丢失后不重复；不能把归档去重扩称所有写入去重 |
| WM-56 | SDK 内建重试/backoff [S31] | 通用自动重试文档仍写 **roadmap**；实际发布包已有 job polling backoff、显式 idempotency key 及 pending key 复用，不能说全部没有 | 可选 adapter 单写使用公开 idempotency key，bulk/analyze 未公开幂等参数则不伪造；有界状态等待仅重复读，副作用未知不重发，跨进程远端写入 journal 尚未实现 | 读操作有限重试，副作用按 job ID 查询；401与永久错误不重试 |

## 本轮落地与继续执行的顺序

本轮新增 A 的 `memory.archive.export / validate / import`，ADR 为 [0007](../adr/0007-portable-memory-archives.md)。它改善 WM-18/19 的本地可移植基础，并为 WM-02/14 提供后续可复用的验证边界。9 个同源 portable Core 测试及 4 项真实 CLI/RPC 完整往返检查通过。Archive 自身源码在测试期间保持不变；其他代理并行修改了 Automation/WorkflowContext，因此此结果不冒充整仓最终冻结快照。测试源码为 [MemoryArchiveTests](../../Tests/VelaCoreTests/MemoryArchiveTests.swift) 与 [CLI 验证脚本](../../scripts/test-memory-archives.py)。

2026-09-14：本地 Lab Recall 的 explicit 执行 guard、词面 recall 冻结及安装的 Apple English semantic/hybrid 检索均有隔离 helper 收据；semantic/hybrid 只证明 active、非私有、同项目记忆的本地选择和冻结上下文，不证明模型采用、远端 Walrus 能力或后续任务改善。Lab UI22 仍是缺入口红例，private/source 失效执行 guard 属 Core 验证范围。详见 [集成收据](feedback-lab-session-core-evidence-2026-09-14.json)。

后续同轮增加 [ADR 0010](../adr/0010-local-client-sdks.md) 定义的可安装 SDK：TypeScript `.tgz` 在临时安装目录完成 consumer 类型检查及 9 项检查，Python wheel 在临时 venv 安装后完成 7 项检查；包含真实 helper 读写/恢复、候选隔离，以及单独故障 fixture 的输出上限/超时/取消/批次部分结果。SDK 固定关闭 discovery/watch/scheduler，没有给 macOS app 新增 Node/Python 运行时。此事实更新 WM-34/35 的本地接入状态，仍未宣称远端 SDK 全功能覆盖或发布到 npm/PyPI。

后续增加 [ADR 0013](../adr/0013-local-semantic-recall.md) 定义的本地语义索引与召回。9 个 Core 定点测试通过，编译输入 hash 在执行期间全部稳定；5 项真实 CLI 检查通过，English 模型 512 维/revision 1、中文 640 维/revision 1。真实同义句 cosine 分别为 0.647859 和 0.932333，仅证明这些 synthetic 场景，不是置信度或普遍质量评估。安装后的 TS 10 项、Python 8 项检查及 consumer 类型检查全部通过，与 CLI 验证使用同一冻结 helper SHA `7a907841ebc57cf4cf97972e4e01dd30285ac141dd8035a917d3a2001786f769`。脚本为 [SDK 验证](../../scripts/test-sdks.py) 和 [语义 CLI 验证](../../scripts/test-semantic-rpc.py)。首次语义 SDK fixture 错误假设无关句 cosine 非负；实际模型按阈值正确排除该句，已修正测试假设并保留初次失败记录。


后续可选 [Walrus SDK](../../sdk/walrus/README.md) 通过 npm pack 后真实安装的 24 项协议/边界测试和 consumer 类型检查，含官方 Ed25519 签名、Owner transaction builder、部署/owner 替换拒绝、SDK 吞错 partial、manifest/raw UTF-8/hash/scope/cursor 与坏密文逐项失败。端侧 reader 使用公开 SEAL API，不调用 relayer/embedding；这不是成功解密的实网证据。Core 新增 raw 构造后 11 项 archive 测试通过，安装后本地 TS 11 项/Python 9 项通过，同 helper SHA `027b632ea9f30a1f3b166ad267ff0b955158f131ff7f9e2bb893a7cab57a8611`。源和 receipt 声明始终 caller-reported，Core 仅验证输入正文摘要。

公开 testnet package 发布交易核验了真实 registry/version/migration 状态；本轮新隔离 owner 获准仅领免费测试币。官方 faucet 两次均 HTTP 429，第二次 Retry-After:30，余额仍 0。未花真实币、未读已有用户钱包、未提交 owner 交易或上传 Memory，真实远端写后读继续标为待测试 gas。此阻塞不免除全项实现与后续验收。具体边界见 [当前合同](../implementation/walrus-remote-contract.md) 和 [账户计划](../implementation/walrus-account-test-plan.md)。


后续新增 [ADR 0023](../adr/0023-scoped-openclaw-memory-integration.md) 与可选 [OpenClaw 插件](../../sdk/openclaw/README.md)，固定 OpenClaw 2026.9.4，Node >=24.16.0 <25 或 >=26.1.0；默认 Mac app 无新增运行时。Core integration 3 + semantic 10 + archive 11 的 24 项初次定点通过，增加 limit 后 integration 4 项再次通过；namespace 变化会使旧向量失效，普通项目召回不混入 namespace，Private/malformed-private/source-path 负例通过。本地安装 SDK 更新为 TS 12 / Python 10；最终同轮复验使用冻结 helper `b1724c9a78c7d539ca94082b05b87f90fd8e55f1b8e5ec96556c11f25e629621`。实际隔离 OpenClaw loader、CLI search/stats 与 hook runner 的测试收据在 `output/parity/openclaw/package-results.json`，测试源码和可重复安装脚本在仓库；另完成实际 OpenClaw 嵌入式 turn→本机合成 provider：真正的 prompt 含同 namespace 原文，工具 memory_store 实际执行并返回候选收据，agent_end 实际捕获当前输入；没有真实模型语义质量、NemoClaw 主机或远端加密往返证据。远端 analyze 采用真实已发布 SDK 的临时 SEAL session 与签名请求，fixture 不冒充模型事实质量或远端存储完成。

后续远端 SDK 扩展批量写入/状态等待、owner memories/agents 元数据、增量 tombstones、namespace stats 和显式 forget。已发布 SDK 没有公开方法的固定 metadata 路由采用文档化 Ed25519 签名协议，不调用私有 API；元数据读和清索引不传 SEAL 解密会话。新安装包 32 项测试与 consumer 类型检查全部通过，包 SHA `906766753e1894fc5c744cd2758c3e02c804f8bcad34a9dfa8b501d7a81e2003`，25,599 bytes，15 个明确允许文件。新阶段收据独立保存在 `output/parity/walrus-metadata-sdk/package-results.json`，保留前一 25 项测试阶段证据。包含真实 SDK bulk 请求、真实 Ed25519 验签、empty-page cursor、跨 owner/profile 拒绝、tombstones/resync、部分失败/缺失状态、429 不重发与 forget 只清索引的合同；仍没有真实链上写入或成功 SEAL 解密证据。

冻结前继续自审发现并修复 bulk 参数数组别名：调用者修改原始 texts 数组会改变旧包实际请求，旧 32 项测试包已以真实签名 HTTP body 复现；现在 prepare 在保存 hash 前深复制嵌套参数。新增回归后安装包 33 项与 consumer 类型检查全部通过，SHA `53a90db381c1979943bd8769c0219ddb5ff8d39a9531f59da4a1d22d8523e3b8`，25,665 bytes。独立收据在 `output/parity/walrus-frozen-arguments/package-results.json`，保留旧包复现和首轮旧 300 ms 轮询 fixture 在并行负载下超时的原始记录；该 fixture 调整为足够认证读取预算及一次有界等待后，完整复验通过，产品超时逻辑未放宽。

最终消费者复核另外证明并修复两个 P2：OpenClaw 在 `captureMaxMessages=1` 时将当前输入和额外助手消息保存为两条；Python 取消排队调用时将另一个实际请求的编号/副作用标志误归给被取消调用。旧安装包反例保存在 `output/parity/sdk-consumer-review-20260913`，不涉及外部模型、钱包或远端记忆。修复后 Python 11 项安装测试、OpenClaw 7 项安装测试/类型检查及真实 host loader/CLI/完整两轮合成模型 turn 全通过，共同 helper SHA `d42897eb0c51bbcafa21cec1bc704f7db4abbec1de1d86b3afe83cc81e630dce`；分别使用新收据目录 `output/parity/python-cancellation-fix` 与 `output/parity/openclaw-capture-cap-fix`。前者取消回执只标本调用是否真正发送，其他实际写仍保留自身不确定性；后者先检查包括当前输入的 cap 再追加。TypeScript/Walrus 本轮未改、未重复其无关测试；模型质量与真实加密远端验收仍未因此完成。

不能据此把 WM-13/14/20–32 标成完成。完整覆盖建议按以下可执行闭环推进：

1. 明确 owner 身份与 namespace，做可安装 TS/Python SDK 和严格的本地 API；同时完成被批准的全局/私有完整备份容器，不让私有数据进入 Agent 检索。
2. 实现可替换语义索引和分析适配器，保存来源、模型、阈值及预算；离线 fallback 透明可见，已确认版本才参与召回。
3. 实现加密远端 Blob/索引恢复适配器及凭据保管；从干净机器证明跨应用恢复，记录不可达/过期/解密失败，不用本地 fixture 替代真实网络验收。
4. 逐个完成 SDK middleware、MCP transport、插件/client Hook 的真实接入测试，验证数据确实进入提供方允许的上下文通道。
5. 补齐远端授权撤销、存储成本/续期、永久删除和运维恢复；用超限集合、并发、断线与旧客户端证明可靠性。

能够进一步优于参考的具体方向包括：恢复提供完整分页而非隐含来源上限；每次受支持写入采用显式幂等键；namespace 权限真正单独授权；明文暴露边界可见；本地离线仍可使用；候选事实审核及来源可追溯。这些是待实现和待测试的改进目标，不能提前写成对外优势。

## English summary

This audit fixes Walrus Memory at commit `493c9e6` and distinguishes current repository capabilities, published package versions, gated APIs, examples, and roadmap items. The source package versions are newer than the current npm/PyPI releases. Fifty-six independently testable requirements cover memory writes and retrieval, recovery, ownership and delegation, encrypted storage, SDKs, MCP, plugins, lifecycle management, examples, and operations. Vela now provides optional local Apple semantic/hybrid retrieval, tested separately from deterministic vector fixtures, and installed local TypeScript/Python SDKs. The optional remote adapter also provides reviewed bulk writes, bounded job polling, signed owner metadata/tombstone pages, namespace statistics, and explicit index-only forgetting. Its latest installed package passes 33 protocol/boundary tests and consumer type checking, including a regression proving caller-owned arrays cannot alter reviewed bulk arguments; successful encrypted testnet roundtrip remains unverified. These do not establish encrypted-remote or cryptographic-owner parity. The new archive API supplies a bounded, integrity-checked, candidate-only local portability foundation; it does not complete encrypted remote recovery or full-store backup. Account-wide delegate authorization, restore candidate limits, template-only TEE attestation, and roadmap-only native deduplication/retry remain explicit reference boundaries, not reasons to reduce Vela's requested scope.

[S1]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/sdk/api-reference.md
[S2]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/relayer/api-reference.md
[S3]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/indexer/database-sync.md
[S4]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/contract/ownership-and-permissions.md
[S5]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/api/memory-read-api.md
[S6]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/fundamentals/architecture/data-flow-security-model.md
[S7]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/guides/manage-your-memory.md
[S8]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/sdk/versioned-datasets.md
[S9]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/contract/delegate-key-management.md
[S10]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/sdk/usage/memwal-manual.md
[S11]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/api/owner-token-auth.md
[S12]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/examples/example-apps.md
[S13]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/fundamentals/architecture/tracking-agent-storage.md
[S14]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/fundamentals/architecture/funding-storage.md
[S15]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/guides/delete-memories-programmatically.md
[S16]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/api/security-delete.md
[S17]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/indexer/onchain-events.md
[S18]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/relayer/self-hosting.md
[S19]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/relayer/public-relayer.md
[S20]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/relayer/nautilus-tee.md
[S21]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/python-sdk/api-reference.md
[S22]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/sdk/ai-integration.md
[S23]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/python-sdk/usage/with-memwal.md
[S24]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/mcp/reference.md
[S25]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/mcp/overview.md
[S26]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/openclaw/reference.md
[S27]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/relayer/versioning-and-compatibility.md
[S28]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/sdk/codebase-memory.md
[S29]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/sdk/agent-storage-loop.md
[S30]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/relayer/observability.md
[S31]: https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/sdk/production-readiness.md

2026-09-13 进一步解包已发布 SDK 0.1.6，确认 `rememberAsync` 显式幂等键、job 状态与轮询 backoff 已在包中；已据此纠正文档 roadmap 与实际发行物的差别。新增 [可选 adapter](../../sdk/walrus/README.md) / [ADR 0017](../adr/0017-optional-walrus-adapter.md)：构造/准备不联网，实际官方签名、Sui public client、namespace page、错误脱敏与一次性预览边界已通过协议 fixture。真正远端加密存取、owner/delegate 交易、全量端侧恢复及桌面 credential UI 仍需继续实现和实网验收，不以包装器入口代替完成。
