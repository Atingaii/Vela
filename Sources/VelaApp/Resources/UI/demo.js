/**
 * Vela Browser Demo Fixture (demo.js)
 * Excluded from native shipping app bundle.
 * Used solely when opening index.html directly in a web browser without native bridge.
 * All fixtures are deterministic and in-memory, reflecting authoritative backend schemas.
 */

(function() {
  'use strict';

  let demoState = null;

  function createInitialState() {
    return {
      systemInfo: {
        channel: 'dev',
        home: '~/.vela-dev',
        version: '0.1.0',
        helperRunning: false
      },
      projects: [
        {
          id: 'proj-1',
          name: 'Vela Core',
          title: 'Vela Core (本地演示项目)',
          path: '/Users/demo/Projects/Vela-Core'
        }
      ],
      sessions: [
        {
          id: 'sess-claude-101',
          provider: 'claude',
          title: '修复 SQLite WAL 并发锁争用与写入阻塞',
          project: '/Users/demo/Projects/Vela-Core',
          cwd: '/Users/demo/Projects/Vela-Core',
          branch: 'main',
          model: 'claude-3-5-sonnet',
          state: 'Completed',
          startedAt: '2026-09-12T09:10:00Z',
          updatedAt: '2026-09-12T09:42:00Z',
          lastActivity: '2026-09-12T09:42:00Z',
          tokenInput: 18450,
          tokenOutput: 3120,
          sourcePath: '~/.claude/desktop/sessions/sess-claude-101.jsonl',
          messageCount: 3,
          messages: [
            {
              id: 'm-1',
              role: 'user',
              content: '在高频写入场景下，VelaStore 的 SQLite 连接偶发 database is locked 错误。请优化锁策略。',
              timestamp: '2026-09-12T09:10:05Z'
            },
            {
              id: 'm-2',
              role: 'assistant',
              content: '检查 Store.swift 的 PRAGMA 配置。建议开启 WAL 模式并设置 busy_timeout = 5000。',
              timestamp: '2026-09-12T09:11:30Z',
              tool: 'file.read'
            },
            {
              id: 'm-3',
              role: 'assistant',
              content: '已将 PRAGMA journal_mode=WAL 和 PRAGMA busy_timeout=5000 加入初始化连接。并发测试 50 个线程读写已全部通过。',
              timestamp: '2026-09-12T09:40:00Z',
              tool: 'shell.test'
            }
          ]
        },
        {
          id: 'sess-cursor-202',
          provider: 'cursor',
          title: '实现 Worktree 独立隔离环境挂载脚本',
          project: '/Users/demo/Projects/Vela-Core',
          cwd: '/Users/demo/Projects/Vela-Core',
          branch: 'feat/worktree-eval',
          model: 'claude-3-5-sonnet',
          state: 'Running',
          startedAt: '2026-09-12T10:15:00Z',
          updatedAt: '2026-09-12T10:28:00Z',
          lastActivity: '2026-09-12T10:28:00Z',
          tokenInput: 12100,
          tokenOutput: 1850,
          sourcePath: '~/.cursor/logs/worktree-202.log',
          messageCount: 2,
          messages: [
            {
              id: 'm-4',
              role: 'user',
              content: '编写 Git Worktree 创建与清理的原子流程，确保实验不污染主分支。',
              timestamp: '2026-09-12T10:15:05Z'
            },
            {
              id: 'm-5',
              role: 'assistant',
              content: '已创建 git worktree add --detach 并在 exit hook 中注册 git worktree remove --force。正在执行隔离性验证。',
              timestamp: '2026-09-12T10:20:00Z',
              tool: 'git.status'
            }
          ]
        }
      ],
      workflows: [
        {
          id: 'wf-ci-safety',
          title: '代码变更安全审查工作流',
          project: '/Users/demo/Projects/Vela-Core',
          description: '检查 Git 状态并在隔离环境中执行单元测试',
          trigger: 'manual',
          version: 1,
          enabled: true,
          steps: [
            {
              id: 'st-1',
              title: '检查工作区 Git 干净度',
              tool: 'git.status',
              arguments: {}
            },
            {
              id: 'st-2',
              title: '运行测试套件验证',
              tool: 'shell.test',
              arguments: {
                executable: 'npm',
                args: ['test'],
                timeoutSeconds: 60
              }
            }
          ]
        }
      ],
      runs: [
        {
          id: 'run-901',
          workflowId: 'wf-ci-safety',
          workflowVersion: 1,
          title: '代码变更安全审查工作流',
          state: 'Completed',
          startedAt: '2026-09-12T11:00:00Z',
          durationMs: 3420,
          dryRun: false,
          steps: [
            {
              title: '检查工作区 Git 干净度',
              tool: 'git.status',
              state: 'Completed',
              output: 'On branch main\nnothing to commit, working tree clean',
              durationMs: 120
            },
            {
              title: '运行测试套件验证',
              tool: 'shell.test',
              state: 'Completed',
              output: 'PASS Tests/VelaCoreTests\n  ✓ testStoreInitialization (0.05s)\n  ✓ testWalConcurrency (0.82s)\n\nTest Suites: 1 passed, 1 total',
              durationMs: 3300
            }
          ]
        }
      ],
      guidelines: [
        {
          id: 'gl-01',
          title: 'API 接口设计与幂等性规约',
          scope: 'project',
          mode: 'snapshot_only_not_injected',
          project: '/Users/demo/Projects/Vela-Core',
          content: '# API Guidelines\n- 所有外部状态突变必须支持幂等调用\n- 统一以 JSONL 传输跨进程消息',
          createdAt: '2026-09-10T10:00:00Z',
          updatedAt: '2026-09-11T12:00:00Z'
        }
      ],
      artifacts: [
        {
          id: 'art-rules-1',
          title: 'AGENTS.md 工程规约',
          type: 'rules',
          scope: 'project',
          provider: 'generic',
          path: '/Users/demo/Projects/Vela-Core/AGENTS.md',
          tokens: 420,
          hash: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          content: '# AGENTS.md\n- 本地优先架构，所有写操作必须提供确定性回滚支持',
          diagnostics: []
        }
      ],
      memories: [
        {
          id: 'mem-001',
          title: 'SQLite 并发必须配置 WAL 模式与 busy_timeout',
          content: '初始化 SQLite 必须执行 PRAGMA journal_mode=WAL 和 PRAGMA busy_timeout=5000，否则易导致 database is locked 异常。',
          type: 'fact',
          scope: 'project',
          project: '/Users/demo/Projects/Vela-Core',
          state: 'active',
          sourceSession: 'sess-claude-101',
          sourceMessage: 'm-3',
          createdAt: '2026-09-12T09:45:00Z'
        },
        {
          id: 'mem-002',
          title: '独立 Worktree 必须在退出钩子中强制解挂',
          content: '实验结束后必须执行 git worktree remove --force，避免遗留未释放的元数据锁。',
          type: 'decision',
          scope: 'project',
          project: '/Users/demo/Projects/Vela-Core',
          state: 'candidate',
          sourceSession: 'sess-cursor-202',
          sourceMessage: 'm-5',
          createdAt: '2026-09-12T10:30:00Z'
        },
        {
          id: 'mem-003',
          title: 'CI 测试工作流执行前需同步检视 AGENTS.md 准则',
          content: '运行 npm test 之前必须确保主干代码符合当前生效的 AGENTS.md 规约。',
          type: 'workflow knowledge',
          scope: 'project',
          project: '/Users/demo/Projects/Vela-Core',
          state: 'active',
          sourceSession: 'sess-claude-101',
          sourceMessage: 'm-2',
          createdAt: '2026-09-12T10:40:00Z'
        }
      ],
      library: [
        {
          id: 'lib-01',
          title: 'Vela 架构核心设计手册',
          project: '/Users/demo/Projects/Vela-Core',
          private: false,
          content: 'Vela 由 FoundationService 与 AutomationService 组成，采用本地 SQLite WAL 存储，完全离线运行。',
          createdAt: '2026-09-10T12:00:00Z'
        },
        {
          id: 'lib-02',
          title: '私密环境配置与本地密钥规范',
          project: '/Users/demo/Projects/Vela-Core',
          private: true,
          content: '包含内部专用端口配置。此条目已被标记为私密，已对所有 Agent 检索与 MCP 严格排除。',
          createdAt: '2026-09-11T16:00:00Z'
        }
      ],
      suggestions: [
        {
          id: 'sug-wal-promote',
          title: '在 AGENTS.md 中沉淀 SQLite WAL 并发连接配置准则',
          carrier: 'AGENTS.md',
          state: 'pending',
          evidence: [
            { sessionId: 'sess-claude-101', messageId: 'm-3', quote: '优化锁策略为 WAL 模式', timestamp: '2026-09-12T09:40:00Z' }
          ],
          contextTokens: 120,
          preview: [
            {
              path: 'AGENTS.md',
              before: '# AGENTS.md\n- 本地优先架构，所有写操作必须提供确定性回滚支持',
              beforeHash: 'e3b0c44298fc',
              content: '# AGENTS.md\n- 本地优先架构，所有写操作必须提供确定性回滚支持\n- SQLite 连接必须开启 WAL 模式与 busy_timeout = 5000 以避免锁争用',
              afterHash: '8f434346648f',
              delete: false
            }
          ]
        }
      ],
      evals: [
        {
          id: 'eval-agent-md',
          title: '验证 AGENTS.md 规约对 npm test 通过率的影响',
          kind: 'eval',
          evaluationKind: 'context',
          command: ['npm', 'test'],
          commit: '7a8b9c0d',
          state: 'completed',
          evaluator: 'deterministic_command',
          results: [
            {
              variant: 'baseline',
              repetition: 1,
              exitCode: 1,
              durationMs: 2450,
              timedOut: false,
              truncated: false,
              output: 'FAIL Tests/ConcurrencyTest\n  ✕ database locked error',
              changedFiles: [],
              diffStat: '+0 -0'
            },
            {
              variant: 'candidate',
              repetition: 1,
              exitCode: 0,
              durationMs: 1820,
              timedOut: false,
              truncated: false,
              output: 'PASS Tests/ConcurrencyTest\n  ✓ testWalConcurrency (0.65s)',
              changedFiles: ['AGENTS.md'],
              diffStat: '+1 -0'
            }
          ],
          summary: {
            baseline: { runs: 1, successes: 0, passRate: 0.0, averageDurationMs: 2450 },
            candidate: { runs: 1, successes: 1, passRate: 1.0, averageDurationMs: 1820 },
            runtimeDeltaMs: -630,
            successDelta: 1.0
          }
        }
      ],
      approvals: [
        {
          id: 'appr-shell-test',
          title: '执行工作流步骤：npm test',
          tool: 'shell.test',
          project: '/Users/demo/Projects/Vela-Core',
          snapshotHash: 'd41d8cd98f00b204e9800998ecf8427e',
          arguments: {
            executable: 'npm',
            args: ['test'],
            timeoutSeconds: 60
          },
          state: 'pending'
        }
      ],
      usage: {
        totalTokens: 35520,
        sessionCount: 2,
        providers: [
          {
            provider: 'claude',
            inputTokens: 18450,
            outputTokens: 3120,
            totalTokens: 21570,
            sessionCount: 1,
            quotaAvailable: false
          },
          {
            provider: 'cursor',
            inputTokens: 12100,
            outputTokens: 1850,
            totalTokens: 13950,
            sessionCount: 1,
            quotaAvailable: false
          }
        ],
        daily: [
          { date: '2026-09-10', tokens: 14200 },
          { date: '2026-09-11', tokens: 11700 },
          { date: '2026-09-12', tokens: 9620 }
        ]
      },
      settings: {
        notifications: false,
        launchAtLogin: false,
        analysisEnabled: true,
        telemetry: false
      }
    };
  }

  window.VelaDemo = {
    init: function() {
      demoState = createInitialState();
    },

    handleCall: async function(method, params = {}) {
      if (!demoState) demoState = createInitialState();

      switch (method) {
        case 'system.ready':
          return true;

        case 'system.info':
          return demoState.systemInfo;

        case 'system.chooseProject':
          return '/Users/demo/Projects/Vela-Core';

        case 'system.openExternal':
        case 'system.reveal':
        case 'system.updateStatus':
          return true;

        case 'dashboard.get':
          return {
            projects: demoState.projects,
            sessions: demoState.sessions,
            workflows: demoState.workflows,
            runs: demoState.runs,
            guidelines: demoState.guidelines,
            artifacts: demoState.artifacts,
            memories: demoState.memories,
            library: demoState.library,
            suggestions: demoState.suggestions,
            evals: demoState.evals,
            approvals: demoState.approvals,
            usage: demoState.usage,
            settings: demoState.settings
          };

        case 'projects.list':
          return demoState.projects;

        case 'projects.add': {
          const path = params.path || '/Users/demo/Projects/NewProject';
          const newProj = {
            id: 'proj-' + (demoState.projects.length + 1),
            name: path.split('/').pop() || 'New Project',
            title: path.split('/').pop() || 'New Project',
            path
          };
          demoState.projects.push(newProj);
          return newProj;
        }

        case 'sessions.list':
          return demoState.sessions;

        case 'sessions.get': {
          const sess = demoState.sessions.find(s => s.id === params.id);
          if (!sess) throw new Error('会话未找到');
          return sess;
        }

        case 'sessions.refresh':
          return { refreshed: demoState.sessions.length };

        case 'guidelines.list':
          return demoState.guidelines;

        case 'guidelines.save': {
          if (params.id) {
            const idx = demoState.guidelines.findIndex(g => g.id === params.id);
            if (idx >= 0) {
              demoState.guidelines[idx] = Object.assign({}, demoState.guidelines[idx], params, {
                updatedAt: new Date().toISOString()
              });
              return demoState.guidelines[idx];
            }
          }
          const newGl = {
            id: 'gl-' + (demoState.guidelines.length + 1),
            title: params.title,
            scope: params.scope || 'project',
            mode: 'snapshot_only_not_injected',
            project: params.project,
            content: params.content,
            createdAt: new Date().toISOString(),
            updatedAt: new Date().toISOString()
          };
          demoState.guidelines.push(newGl);
          return newGl;
        }

        case 'workflows.build': {
          return {
            workflow: {
              title: params.description ? ('基于提示：' + params.description.substring(0, 16)) : '新生成工作流',
              description: params.description || '',
              project: params.project || '/Users/demo/Projects/Vela-Core',
              trigger: 'manual',
              enabled: false,
              steps: [
                {
                  id: 'st-b1',
                  title: '检查 Git 状态',
                  tool: 'git.status',
                  arguments: {}
                },
                {
                  id: 'st-b2',
                  title: '执行验证命令',
                  tool: 'shell.test',
                  arguments: { executable: 'npm', args: ['test'], timeoutSeconds: 60 }
                }
              ]
            },
            unresolvedInputs: [],
            mode: 'deterministic-local-builder',
            saved: false,
            message: '已由本地模板生成工作流草稿。请审查参数后再手动保存。'
          };
        }

        case 'workflows.list':
          return demoState.workflows;

        case 'workflows.save': {
          if (params.id) {
            const idx = demoState.workflows.findIndex(w => w.id === params.id);
            if (idx >= 0) {
              demoState.workflows[idx] = Object.assign({}, demoState.workflows[idx], params, {
                version: (demoState.workflows[idx].version || 1) + 1
              });
              return demoState.workflows[idx];
            }
          }
          const newWf = Object.assign({
            id: 'wf-' + (demoState.workflows.length + 1),
            version: 1
          }, params);
          demoState.workflows.push(newWf);
          return newWf;
        }

        case 'workflows.run': {
          const wf = demoState.workflows.find(w => w.id === params.id);
          const isDry = !!params.dryRun;
          const newRun = {
            id: 'run-' + Math.floor(Math.random() * 9000 + 1000),
            workflowId: wf ? wf.id : params.id,
            workflowVersion: wf ? wf.version : 1,
            title: (wf ? wf.title : '工作流运行') + (isDry ? ' (Dry Run)' : ''),
            state: 'Completed',
            startedAt: new Date().toISOString(),
            durationMs: isDry ? 640 : 1980,
            dryRun: isDry,
            steps: (wf && wf.steps ? wf.steps : []).map(s => ({
              title: s.title,
              tool: s.tool,
              state: 'Completed',
              output: isDry ? `[Dry Run 试运行] 验证完成：未触发实际变更` : `执行成功：步骤输出正常完成`,
              durationMs: 400
            }))
          };
          demoState.runs.unshift(newRun);
          return newRun;
        }

        case 'runs.list':
          return demoState.runs;

        case 'runs.get': {
          const run = demoState.runs.find(r => r.id === params.id);
          if (!run) throw new Error('运行记录未找到');
          return run;
        }

        case 'workflows.health': {
          return {
            workflowId: params.id || null,
            runs: demoState.runs.length,
            completedRuns: demoState.runs.filter(r => r.state === 'Completed').length,
            successes: demoState.runs.filter(r => r.state === 'Completed').length,
            failures: demoState.runs.filter(r => r.state === 'Failed').length,
            successRate: 1.0,
            averageDurationMs: 1450,
            approvalRejected: 0,
            tokens: null,
            tokensAvailable: false,
            guidelineInfluence: 'not_measured'
          };
        }

        case 'workflows.replay': {
          const targetRun = demoState.runs.find(r => r.id === params.runId);
          if (!targetRun) throw new Error('无法重放：未找到该运行');
          const replayed = Object.assign({}, targetRun, {
            id: 'run-' + Math.floor(Math.random() * 9000 + 1000),
            startedAt: new Date().toISOString()
          });
          demoState.runs.unshift(replayed);
          return replayed;
        }

        case 'setup.list':
          return demoState.artifacts;

        case 'setup.scan':
          return { count: demoState.artifacts.length };

        case 'setup.audit':
          return { diagnostics: [] };

        case 'memory.list':
          return demoState.memories;

        case 'memory.save': {
          const newMem = {
            id: params.id || ('mem-' + (demoState.memories.length + 1)),
            title: params.title || '经验项',
            content: params.content || '',
            type: (params.type || 'fact').toLowerCase(),
            scope: (params.scope || 'project').toLowerCase(),
            project: params.project || '/Users/demo/Projects/Vela-Core',
            state: (params.state || 'candidate').toLowerCase(),
            branch: params.branch,
            task: params.task,
            sourceFile: params.sourceFile,
            sourceCommit: params.sourceCommit,
            sourceSession: params.sourceSession,
            sourceMessage: params.sourceMessage,
            createdAt: new Date().toISOString()
          };
          if (params.id) {
            const idx = demoState.memories.findIndex(m => m.id === params.id);
            if (idx >= 0) {
              demoState.memories[idx] = newMem;
              return newMem;
            }
          }
          demoState.memories.push(newMem);
          return newMem;
        }

        case 'memory.transition': {
          const mem = demoState.memories.find(m => m.id === params.id);
          if (mem) {
            mem.state = (params.state || 'active').toLowerCase();
            if (params.supersedes) {
              const oldMem = demoState.memories.find(m => m.id === params.supersedes);
              if (oldMem) {
                oldMem.state = 'superseded';
                oldMem.supersededBy = mem.id;
              }
            }
            return mem;
          }
          throw new Error('Memory 条目未找到');
        }

        case 'recall': {
          const budget = params.budget || 1000;
          const activeMemories = demoState.memories.filter(m => (m.state || '').toLowerCase() === 'active');
          return {
            items: activeMemories,
            usedTokens: Math.min(budget, activeMemories.length * 120),
            budget
          };
        }

        case 'search': {
          const q = (params.query || '').toLowerCase();
          const incPriv = !!params.includePrivate;
          const results = [];

          demoState.memories.forEach(m => {
            if (m.title.toLowerCase().includes(q) || m.content.toLowerCase().includes(q)) {
              results.push({ id: m.id, kind: 'memory', title: m.title, content: m.content });
            }
          });

          demoState.library.forEach(l => {
            if (!incPriv && l.private) return;
            if (l.title.toLowerCase().includes(q) || (l.content && l.content.toLowerCase().includes(q))) {
              results.push({ id: l.id, kind: 'library', title: l.title, content: l.content });
            }
          });

          demoState.sessions.forEach(s => {
            if (s.title.toLowerCase().includes(q)) {
              results.push({ id: s.id, kind: 'session', title: s.title, content: `Provider: ${s.provider} · Model: ${s.model}` });
            }
          });

          return results;
        }

        case 'checkpoint.save': {
          return {
            id: 'cp-' + Math.floor(Math.random() * 900 + 100),
            sessionId: params.sessionId,
            project: params.project,
            title: params.title || '阶段 Checkpoint',
            goal: params.goal,
            completed: params.completed,
            pending: params.pending,
            tests: params.tests,
            nextActions: params.nextActions,
            createdAt: new Date().toISOString()
          };
        }

        case 'checkpoint.export': {
          const prov = params.provider || 'Claude';
          return {
            path: `/Users/demo/Projects/Vela-Core/.vela/handoff-${prov.toLowerCase()}.md`,
            command: `vela recall --project /Users/demo/Projects/Vela-Core --budget 1000`,
            content: `# Handoff Checkpoint (${prov})\n- 目标：完善 SQLite WAL 模式与并发测试\n- 状态：测试套件通过\n- 后续行动：接入真实会话日志增量索引`
          };
        }

        case 'library.add': {
          const item = {
            id: 'lib-' + (demoState.library.length + 1),
            title: params.title,
            project: params.project,
            content: params.content,
            path: params.path,
            url: params.url,
            private: !!params.private,
            createdAt: new Date().toISOString()
          };
          demoState.library.push(item);
          return item;
        }

        case 'library.list':
          return demoState.library;

        case 'improve.analyze':
          return {
            suggestions: demoState.suggestions,
            signalsCount: 4
          };

        case 'improve.preview': {
          const sug = demoState.suggestions.find(s => s.id === params.id);
          if (!sug) throw new Error('建议未找到');
          return sug;
        }

        case 'improve.apply': {
          const sug = demoState.suggestions.find(s => s.id === params.id);
          if (sug) {
            sug.state = 'applied';
            return { applied: true };
          }
          throw new Error('未找到建议');
        }

        case 'improve.undo': {
          const sug = demoState.suggestions.find(s => s.id === params.id);
          if (sug) {
            sug.state = 'pending';
            return { reverted: true };
          }
          throw new Error('未找到建议');
        }

        case 'improve.dismiss': {
          const sug = demoState.suggestions.find(s => s.id === params.id);
          if (sug) {
            sug.state = 'dismissed';
            return { dismissed: true };
          }
          throw new Error('未找到建议');
        }

        case 'lab.run': {
          const newEval = {
            id: 'eval-' + (demoState.evals.length + 1),
            title: params.title || '新对照实验',
            kind: 'eval',
            evaluationKind: params.kind || 'context',
            command: params.command || ['npm', 'test'],
            state: 'pending_approval',
            evaluator: 'deterministic_command',
            commit: '7a8b9c0d',
            results: [],
            summary: null
          };
          demoState.evals.unshift(newEval);

          demoState.approvals.push({
            id: 'appr-' + newEval.id,
            title: `运行 Lab 对照实验: ${newEval.title}`,
            tool: 'shell.test',
            project: params.project || '/Users/demo/Projects/Vela-Core',
            snapshotHash: 'a1b2c3d4e5f6',
            arguments: { command: newEval.command, timeoutSeconds: params.timeoutSeconds || 60 },
            state: 'pending'
          });

          return newEval;
        }

        case 'lab.compare': {
          const ev = demoState.evals.find(e => e.id === params.id);
          if (!ev) throw new Error('实验记录未找到');
          return ev;
        }

        case 'regression.list': {
          return {
            workflowComparisons: [
              {
                workflowId: 'wf-ci-safety',
                baselineVersion: 1,
                candidateVersion: 2,
                baseline: {
                  runs: 12,
                  successes: 11,
                  successRate: 0.917,
                  meanRuntimeMs: 3420.0
                },
                candidate: {
                  runs: 8,
                  successes: 8,
                  successRate: 1.0,
                  meanRuntimeMs: 3070.0
                },
                causality: 'observational; inputs and environments may differ'
              }
            ],
            evaluations: demoState.evals,
            message: '回归分析数据就绪'
          };
        }

        case 'inbox.list':
          return demoState.approvals;

        case 'approvals.decide': {
          const idx = demoState.approvals.findIndex(a => a.id === params.id);
          if (idx >= 0) {
            demoState.approvals.splice(idx, 1);
            demoState.evals.forEach(e => {
              if (e.state === 'pending_approval') {
                e.state = params.decision === 'approve' ? 'completed' : 'rejected';
                if (params.decision === 'approve') {
                  e.results = [
                    {
                      variant: 'baseline',
                      repetition: 1,
                      exitCode: 1,
                      durationMs: 2450,
                      output: 'FAIL database locked error',
                      timedOut: false,
                      truncated: false,
                      changedFiles: [],
                      diffStat: '+0 -0'
                    },
                    {
                      variant: 'candidate',
                      repetition: 1,
                      exitCode: 0,
                      durationMs: 1820,
                      output: 'PASS (Exit: 0)',
                      timedOut: false,
                      truncated: false,
                      changedFiles: ['AGENTS.md'],
                      diffStat: '+1 -0'
                    }
                  ];
                  e.summary = {
                    baseline: { runs: 1, successes: 0, passRate: 0.0, averageDurationMs: 2450 },
                    candidate: { runs: 1, successes: 1, passRate: 1.0, averageDurationMs: 1820 },
                    runtimeDeltaMs: -630,
                    successDelta: 1.0
                  };
                }
              }
            });
            return { success: true };
          }
          throw new Error('待办项不存在');
        }

        case 'evidence.get':
          return {
            targetId: params.id,
            relatedSessions: ['sess-claude-101'],
            confidence: 0.98,
            signalFrequency: 3
          };

        case 'settings.get':
          return demoState.settings;

        case 'settings.save':
          demoState.settings = Object.assign({}, demoState.settings, params, { telemetry: false });
          return demoState.settings;

        case 'usage.get':
          return demoState.usage;

        default:
          throw new Error(`不支持的方法：${method}`);
      }
    }
  };

})();
