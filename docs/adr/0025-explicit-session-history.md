# ADR 0025：显式回填的版本化会话历史

- 状态：Accepted；四 JSONL 基础实现，完整范围仍待分别验收
- 日期：2026-09-13
- 范围：Blume B07 完整历史访问及后续 B12/B13 的来源基础

当前 SessionEngine 为常驻观察保留每 provider 最近 60 文件、Claude/Codex 初始 256 KiB 尾窗、至多 1,000 消息及约 1 MiB 正文。Pi/OMP 虽能扫描有界完整分支索引，最终显示消息仍有保留预算。这些行为适合低占用的当前工作台，不能替代完整历史。直接提高这些上限会让 dashboard、搜索和每次刷新承受全部历史，也无法解决断点恢复、来源重写和稳定分页。

## 决策方向

新增独立 SessionHistoryService/SessionHistoryStore，以系统 SQLite 的专门表存放来源 manifest、版本 epoch、回填任务、事件及原记录分块。不把完整正文塞回 session JSON，不让 dashboard 加载历史；不增加常驻 Node、数据库服务或 provider 进程。回填必须由明确 API 启动，每次 advance 只做有界工作，不自动后台扫描全盘。

来源入口只能是已配置 provider roots 下发现的 ID，不接受 renderer/MCP 给任意文件路径。Manifest 记录 provider、相对路径、公开格式/decoder 版本、实际文件身份及来源项目。目录和文件逐级 no-follow 打开；符号链接、非普通文件和身份变化必须拒绝。项目由公开 header/cwd 元数据证明；未知或不一致的项目不推测归属。记录中显式改变 cwd 的事件按实际作用域处理，不能把其他项目原文放进本项目页面。

2026-09-13 根锚定修正：上述逐级 no-follow 从已经配置并规范化的 provider root 开始。直接以 `O_DIRECTORY | O_NOFOLLOW` 打开该授权根，比较打开前后名称与持有 descriptor 的 device/inode/type，并用 `F_GETPATH` 核对物理根路径；只在根以下逐组件 `openat`。不从 `/` 逐级打开授权根之外的祖先，避免额外触发 macOS 对祖先目录的访问限制。根自身、后代符号链接、普通文件 hardlink 和重定向的物理根仍拒绝；原来源 descriptor 与重新打开的文件版本继续在每批前后核对。本修正不申请或更改系统权限。

历史以独立 source epoch 冻结。文件身份至少包含 device/inode/size/纳秒 mtime/ctime，provider schema version 与 decoder revision 另行记录。每批开始和结束都核验，源变化将未完成任务标为 stale，保留此前证据但不能宣布完整。新版本创建新 epoch，旧 cursor 不静默跳到新内容。完成的旧 epoch 是历史快照，不因为原日志轮转而被重新写入。

首版不把“文件只变长”当成前缀未改变的证明，也不对持续写入的文件冒充跨批一致快照。当前工作台继续显示尾部观察；用户可在源稳定后回填新 epoch。若未来增加 append 续接，应核验已保存前缀内容/分块 hash，独立记录稳定前缀与追加边界；不能仅检查 inode/size。

每批按字节、记录数和时间设工作限额，事件、原文分块和下一 byte offset 同一 SQLite 事务提交。进程重启从最后已提交 offset 继续；多个 helper 对同一任务的 advance 通过数据库事务/CAS 去重，不能只依赖 Swift 对象锁。暂停、取消、stale、错误、预算耗尽都是持久化状态。未终止尾行和超大记录需要明确诊断，不允许跳过后仍标 complete。

分页键为 epoch 与物理记录序号/字节位置，绑定过滤条件和方向。时间戳只是来源属性；缺失时间为 null，不能用摄取时间替代原事件顺序。记录保留 provider 原始 ID、父 ID、role/type、usage 原值、工具调用 ID 和来源 byte range。相同原 ID 的不同版本必须保留 revision/group 关系，不能按文本相同删除合法重复。原文从独立分块 API 获取，可重建完整记录；页面只返回有界预览与原文引用。

Pi v1 的线性 parent 来源与 v2/v3 的明确 parentId 分开；OMP 保留标题 slot 和 provider 身份。完整图存到 SQL，分支读取沿明确 leaf 逐页追溯，孤儿、重复 ID、环或未知扩展均保留诊断。最后持久化 leaf 不等于当前内存 leaf。不能为了分页而把树降成扁平最新 1,000 条。

Cursor 仅接已知公开/可验证格式：JSONL、含 messages/conversation 的导出以及已知 composerData 内嵌数组。数据库需要只读一致性快照和稳定 key，不能直接把文件 stat 当 WAL 内容版本。未知 bubble/table/schema 保持 unsupported 并提示受支持导出路径，不能伪造对当前 Cursor 全格式兼容。

## 顺序与验收

第一切片实现四个 JSONL provider 的来源发现、冻结、分批原文/事件、重启、分页与 source mutation 反例，当前合同和实际验证见 [Session History](../implementation/session-history-contract.md)；之后接明确 Cursor 导出/数据库语义。单记录超过 normalizer 限额时可保留有界原始分块，但 normalization/source-scope 未被证明的记录不能被冒充可检索的完整消息。读取结束、原文完整、标准化完整、分支完整是独立字段。

B12 需要解析实际 Todo/plan 事件及版本进度，B13 需要明确 parent/child 会话与工具 ID 的关系、独立状态和失败传播；仅保存原始 JSON 不会关闭这两项。之后基于原始来源事件建立这些投影，保留原引用和未知状态。

验收至少覆盖：超过默认 60 文件和 1,000 消息；大于尾窗的深部正文；单条长消息原文分块可重建；多批重启无丢失/重复；相同事件 ID 的真实修订不被抹除；倒序时间不影响稳定分页；源中段等长重写、追加、轮转、截断；跨项目 cwd、符号链接与未知 schema；Pi/OMP 弃用分支、孤儿/环；并发 advance；暂停/取消和磁盘/解析边界。最终记录绑定源码与 helper hash，性能使用实际大合成数据测量。

## 权衡与重新评估

独立历史表需要额外磁盘与迁移维护，但使默认内存/响应时间不随总历史线性增长。保存完整原记录是用户明确选择的本地导入行为；不能把它自动上传、加入 Memory 或模型 prompt。物理顺序分页比跨文件全局时间排序简单可靠；跨来源排序应作为保留稳定 tie-breaker 的后续索引，不改变既有 cursor。

若静态 epoch 在正常长会话中频繁 stale，应据真实测量考虑验证前缀的 append 模式；若特定 provider 公开提供稳定 revision API，可增加专用 adapter。没有官方格式证据不能以猜测 schema 换取表面覆盖。

## English summary

Full session history uses explicit, resumable imports into separate SQLite tables while the default dashboard stays bounded. Immutable source epochs, exact byte checkpoints, stable event cursors and chunked original records distinguish raw coverage from normalization and branch completeness. Source changes fail closed; missing timestamps, project identity and live process state remain unavailable. Known provider formats are adapted explicitly, and unknown Cursor schemas remain unsupported until independently verified.

The configured canonical provider root is the authorized filesystem anchor. Its directory descriptor, named device/inode and physical path are checked before and after relative traversal; only descendants are opened component by component with no-follow. Opening unrelated ancestors is unnecessary. Root or descendant links, regular-file hardlinks and changed source versions remain rejected without changing macOS permissions.
