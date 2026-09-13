# Vela TypeScript SDK

A Node.js client for the explicitly selected local Vela helper and store. Zero runtime dependencies. This development package is built from the repository; it has not been published to npm. Node.js 22+ and a compatible macOS Vela helper are required. It is not bundled with the desktop application.

```sh
npm ci
npm run build
npm pack
# In your application, install the resulting vela-engineering-sdk-0.1.0-dev.1.tgz.
```

```ts
import { VelaClient, VelaError, VelaBulkError } from '@vela-engineering/sdk';

const client = new VelaClient({
  transport: {
    type: 'local',
    executable: '/Applications/Vela.app/Contents/MacOS/vela',
    home: '/absolute/path/to/.vela-dev',
  },
  project: '/absolute/path/to/project',
});
try {
  await client.registerProject('/absolute/path/to/project');
  const candidate = await client.saveCandidate({
    title: 'Verification command', content: 'Run the project verification before publishing.',
    type: 'constraint',
  });
  const memories = await client.listMemories();
  const archive = await client.exportArchive();
  await client.validateArchive(archive.archive);
  // Import into a separately registered project; imported memories remain candidates.
  // await client.importArchive(archive.archive, '/absolute/path/to/other-project');
} finally {
  await client.close();
}
```

`listProjects`, `registerProject`, `listMemories`, `recall`, `saveCandidate`, `saveCandidates`, `exportArchive`, `validateArchive`, and `importArchive` call real helper methods. Each read and write names a project either explicitly or through the client default. Candidate writes and archive imports do not activate memory. Review activation in Vela before expecting it in Recall. Local recall retains the capabilities of the selected helper; the SDK does not itself supply embeddings or remote memory.

Every method accepts final request options containing `timeoutMs` (1–120,000, default 15,000) and `signal: AbortSignal`. At most 32 requests are pending. A timeout, abort, protocol failure or output overflow closes the shared connection and terminates its owned process group. Other pending calls fail too. Explicit `close()` waits for helper termination. There is no automatic reconnect or request retry.

`VelaError` exposes `code`, `requestId`, and `effectsUnknown`. A started mutation may have completed before a timeout, disconnect, cancellation, or core error; inspect the selected store before deciding what to do next. Cancellation is not proof of rollback or core cancellation. Raw helper stdout/stderr and error bodies are never included in exceptions. Output is bounded to a 2 MiB JSONL frame and 64 KiB stderr per connection.

`saveCandidates` validates its entire 1–100 item input before sending, then writes sequentially. It is **not atomic**. On the first failure, `VelaBulkError` exposes `completed`, `failedIndex`, `unattempted`, `skipped` (0), and the typed `cause`. No trailing write is attempted. If all-or-nothing local import is needed, use a valid Memory archive instead. The SDK never re-hashes or silently repairs an archive.

The child is launched without a shell, discovery, watchers, or the scheduler (`rpc --no-watch --no-schedule`). The SDK is an integration layer, not an ACL: local OS/helper/store permissions still apply. `transport.type` currently accepts only `local`. It creates no owner identity, remote authentication, cloud account, or new provider credential. No arbitrary shell/filesystem or workflow execution methods are exposed.

Run the real-helper and fault-fixture tests with `npm test` after `npm run build`. Set `VELA_TEST_HELPER` to an explicit helper path when testing an installed package. The tests use disposable stores, never personal agent logs.


`semanticIndex({language, batchSize, cursor})` builds an explicit resumable local index; pass each `nextCursor` until `hasMore` is false. `semanticStatus({language})` reports actual model availability and stale/missing entries. `recall(query, {retrievalMode: 'semantic' | 'hybrid', language: 'en' | 'zh-Hans', limit, minSimilarity, scoringWeights})` uses that index. Default recall remains lexical. Model assets are optional, never automatically downloaded; inspect `status`, `indexIncomplete`, and `fallbackReason` rather than treating absent assets as success. Branch/worktree/task/sessionId scope parameters remain available. Index writes do not activate candidates.

```ts
const status = await client.semanticStatus({language: 'en'});
if (status.status === 'ok') {
  let cursor: string | undefined;
  do {
    const page = await client.semanticIndex({language: 'en', batchSize: 32, ...(cursor ? {cursor} : {})});
    if (page.status !== 'ok' && page.status !== 'partial') break;
    cursor = page.nextCursor ?? undefined;
  } while (cursor);
  const result = await client.recall('The vehicle needs repair.', {retrievalMode: 'hybrid', language: 'en', minSimilarity: 0.2});
}
```

## 简体中文

这是连接用户明确指定的本地 helper 和 store 的 TypeScript SDK，使用 Node.js 22+，没有运行时第三方依赖，不加入 macOS 安装包，目前未发布到 npm。先执行上面的构建命令，再将产出的 `.tgz` 安装到应用中。

接口支持项目登记、Memory 列表/召回、候选记忆写入、顺序批量写入和归档导出/校验/导入。所有写入只创建候选记忆，需在 Vela 审核激活后才会被召回。归档严格沿用 Core 的校验和权限边界。

批量写入不是原子操作：失败立即停止，异常列出已完成、失败位置和未尝试数量。超时或取消会关闭整个连接及自有 helper 进程组；`effectsUnknown` 表示写入可能已发生，不能自动重发，也不能把终止客户端等同于核心操作已回滚。异常不暴露 helper 原文输出。

SDK 固定关闭发现、监听和调度，不提供任意 shell/file/workflow 执行入口。它不是 owner/namespace ACL，也没有实现远端加密存储或同步身份。SDK/API 完整覆盖状态见仓库 `docs/parity/walrus-memory.md`。

语义接口支持本机 English / 简体中文模型、显式分页索引、状态检查、semantic/hybrid 召回与可选时间/重要性排名。默认仍为词面检索；模型缺失和索引不完整均显式返回，不下载模型、不自动激活候选，也不代表远端加密记忆已实现。

`archiveFromWalrusRecords(source, records)` constructs an integrity-checked archive from explicitly selected, non-private original Walrus UTF-8 text, without writing memory. Each record supplies `blobID/title/content/sha256/private:false` and an optional reader `receipt`. Remote source/receipt are caller-reported; Core authenticates only the plaintext checksum. Validate and import into an explicit registered project to create idempotent candidates. 中文：原始 Walrus 文本先构造归档，再显式导入候选；不把来源自报当成已认证，也不激活或导入私有备份。

### Scoped integration memory

`captureIntegration(namespace, sourceID, records)` creates only candidate observations; `recallIntegration(namespace, query, parameters)` retrieves only active non-private records in that exact namespace and selected project. `integrationStats(namespace)` returns bounded observed counts and completeness. These local process methods do not authenticate a host or implement remote ACL. The optional OpenClaw plugin selects the namespace from trusted host context.

中文：集成捕获只创建候选原文观察；普通项目召回与 namespace 召回隔离。宿主身份认证不是本地 SDK 的能力，OpenClaw 插件由可信宿主上下文决定 namespace。
