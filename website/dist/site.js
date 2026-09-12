/**
 * Vela Official Website Interactions (site.js)
 * Plain, accessible UI interactions without external dependencies or tracking.
 */

(function() {
  'use strict';

  document.addEventListener('DOMContentLoaded', () => {
    setupMobileMenu();
    setupDemoTabs();
    setupCopyButtons();
  });

  // Mobile Menu Toggle
  function setupMobileMenu() {
    const toggle = document.querySelector('.mobile-menu-toggle');
    const nav = document.querySelector('.site-nav');
    if (!toggle || !nav) return;

    toggle.addEventListener('click', () => {
      const isExpanded = toggle.getAttribute('aria-expanded') === 'true';
      toggle.setAttribute('aria-expanded', !isExpanded);
      if (!isExpanded) {
        nav.style.display = 'flex';
        nav.style.flexDirection = 'column';
        nav.style.position = 'absolute';
        nav.style.top = '58px';
        nav.style.left = '0';
        nav.style.right = '0';
        nav.style.background = '#07070a';
        nav.style.padding = '20px 24px';
        nav.style.borderBottom = '1px solid rgba(255, 255, 255, 0.08)';
      } else {
        nav.style.display = '';
      }
    });
  }

  // Interactive Product Scenario Tabs
  function setupDemoTabs() {
    const tabs = document.querySelectorAll('.demo-tab-btn');
    const content = document.getElementById('demo-scenario-content');
    if (!tabs.length || !content) return;

    const scenarios = {
      observe: {
        title: '会话捕获与日志解析 (Observe)',
        desc: 'Vela 在本地监听已连接项目的日志流（如 Claude Code、Cursor、Codex），解析工具调用、Token 消耗与分支上下文。',
        sidebar: [
          { title: 'Claude: 修复 SQLite 并发锁', time: '09:42', active: true },
          { title: 'Cursor: Worktree 隔离验证', time: '10:28', active: false },
          { title: 'Codex: stdio MCP 权限路由', time: '14:35', active: false }
        ],
        detail: `
          <div class="demo-card">
            <div class="demo-card-title">
              <span>会话元数据</span>
              <span class="demo-badge">已完成 (Pass)</span>
            </div>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; font-size: 12px; color: #a5a5b2;">
              <div>Provider: <strong style="color: #fff;">Claude Code</strong></div>
              <div>Model: <code class="code-block" style="padding: 1px 4px;">claude-3-5-sonnet</code></div>
              <div>Observed Tokens: <strong style="color: #fff;">21,570</strong> (In: 18.4k / Out: 3.1k)</div>
              <div>Git Branch: <code class="code-block" style="padding: 1px 4px;">main</code></div>
            </div>
          </div>
          <div class="demo-card">
            <div class="demo-card-title">工具调用记录 (Tool Invocations)</div>
            <div class="code-block">
[09:11:30] tool.call: file.read { path: "Sources/VelaCore/Store.swift" }
[09:12:05] tool.output: PRAGMA journal_mode=DELETE; // 锁争用源头
[09:40:00] tool.call: shell.test { executable: "npm", args: ["test"] }
[09:40:15] tool.output: PASS 18 passed, 0 failed (WAL 并发测试通过)
            </div>
          </div>
        `
      },
      remember: {
        title: '经验沉淀与保守估算预算召回 (Remember)',
        desc: '将已确认的工程经验保存为 Memory，支持通过 CLI 或 MCP 按保守估算预算（如 1000 tokens 上限）显式召回，启动时不自动检索。',
        sidebar: [
          { title: 'SQLite WAL 并发模式配置', time: 'Active', active: true },
          { title: '独立 Worktree 退出清理规范', time: 'Candidate', active: false },
          { title: '单线程同步连接（已废弃）', time: 'Superseded', active: false }
        ],
        detail: `
          <div class="demo-card">
            <div class="demo-card-title">
              <span>Memory 详情：SQLite 并发连接配置</span>
              <span class="demo-badge" style="color: #34d399; background: rgba(52, 211, 153, 0.1);">Active (生效中)</span>
            </div>
            <p style="font-size: 12px; color: #a5a5b2; margin-bottom: 10px;">
              初始化 SQLite 连接时设置 PRAGMA journal_mode=WAL 和 busy_timeout=5000。
            </p>
            <div style="font-size: 11px; color: #71717a;">
              关联来源：会话 sess-claude-101 · 审核通过时间：2026-09-12 09:45
            </div>
          </div>
          <div class="demo-card">
            <div class="demo-card-title">
              <span>保守估算预算召回模拟 (Recall)</span>
              <span style="font-size: 11px; color: #a5a5b2;">Budget: 1,000 Tokens</span>
            </div>
            <div class="code-block">
$ vela recall "数据库并发" --project /path/to/project --budget 1000
➔ 匹配到 1 条 Active 记忆 · 消耗 142 / 1000 Tokens
{
  "title": "SQLite 并发必须配置 WAL 模式与 busy_timeout",
  "scope": "project",
  "type": "fact",
  "content": "初始化执行 PRAGMA journal_mode=WAL 和 PRAGMA busy_timeout=5000"
}
            </div>
          </div>
        `
      },
      automate: {
        title: '工作流自动化与审批门禁 (Automate)',
        desc: '配置多步骤自动化管道。只读步骤直接运行；文件写入（file.write）与测试执行（shell.test）需在 Inbox 中审批。',
        sidebar: [
          { title: '代码变更安全审查工作流', time: 'v1 · 2步', active: true },
          { title: '定时 TypeScript 类型检查', time: 'v2 · cron', active: false }
        ],
        detail: `
          <div class="demo-card">
            <div class="demo-card-title">
              <span>工作流步骤定义 (Workflow Steps)</span>
              <span class="demo-badge">参数冻结</span>
            </div>
            <div class="code-block">
步骤 1: [只读] git.status {} ➔ PASS
步骤 2: [待执行的操作] shell.test { executable: "npm", args: ["test"], timeoutSeconds: 60 }
        ➔ 状态: Pending Approval (需人工在 Inbox 中点击批准)
            </div>
          </div>
          <div class="demo-card">
            <div class="demo-card-title">
              <span>Dry Run 只读试运行输出</span>
              <span class="demo-badge" style="color: #60a5fa; background: rgba(96, 165, 250, 0.1);">只读模拟</span>
            </div>
            <div class="code-block">
[Dry Run] 校验环境依赖 ... OK
[Dry Run] 计算冻结参数哈希: d41d8cd98f00b204e9800998ecf8427e
[Dry Run] 试运行完成：只读 Git 真实运行；写入和测试步骤使用模拟结果。未修改项目文件。
            </div>
          </div>
        `
      },
      verify: {
        title: 'Worktree 命令对照评测 (Verify)',
        desc: '在相同 Git HEAD 的独立 Worktree 中分别执行相同测试命令检验不同工程配置（非并发执行），以退出码和耗时作为评估依据（当前为确定性命令对比，非自主智能体评测）。',
        sidebar: [
          { title: '配置 SQLite busy_timeout 对并发测试的影响', time: 'Pass', active: true }
        ],
        detail: `
          <div class="demo-card">
            <div class="demo-card-title">
              <span>评测器：deterministic_command（确定性命令结果）</span>
              <span class="demo-badge">同 HEAD 隔离</span>
            </div>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-top: 8px;">
              <div style="background: #0d0d14; border: 1px solid rgba(255,255,255,0.08); padding: 10px; border-radius: 4px;">
                <div style="font-size: 11px; font-weight: 600; color: #f87171; margin-bottom: 4px;">Baseline (默认配置: 无 busy_timeout)</div>
                <div style="font-size: 11px; color: #a5a5b2;">Exit Code: <strong>1 (Fail)</strong></div>
                <div style="font-size: 11px; color: #a5a5b2;">耗时: 2,450ms</div>
                <div style="font-size: 10px; font-family: monospace; color: #ef4444; margin-top: 4px;">FAIL database locked error</div>
              </div>
              <div style="background: #0d0d14; border: 1px solid rgba(255,255,255,0.08); padding: 10px; border-radius: 4px;">
                <div style="font-size: 11px; font-weight: 600; color: #34d399; margin-bottom: 4px;">Candidate (候选配置: busy_timeout=5000)</div>
                <div style="font-size: 11px; color: #a5a5b2;">Exit Code: <strong>0 (Pass)</strong></div>
                <div style="font-size: 11px; color: #a5a5b2;">耗时: 1,820ms</div>
                <div style="font-size: 10px; font-family: monospace; color: #10b981; margin-top: 4px;">PASS 18 passed, 0 failed</div>
              </div>
            </div>
          </div>
          <div class="demo-card">
            <div class="demo-card-title">指标差异 (Diff Metrics)</div>
            <div class="code-block">
{
  "testPassDelta": "+1 passed",
  "runtimeSpeedup": "25.7% faster",
  "evaluator": "deterministic_command"
}
            </div>
          </div>
        `
      }
    };

    const renderScenario = (key) => {
      const s = scenarios[key];
      if (!s) return;

      content.innerHTML = `
        <div class="demo-scenario">
          <div class="demo-sidebar-compact">
            <div style="font-size: 11px; font-weight: 600; color: #71717a; text-transform: uppercase; margin-bottom: 8px;">示例导航 (${key.toUpperCase()})</div>
            ${s.sidebar.map(item => `
              <div class="demo-sidebar-item ${item.active ? 'active' : ''}">
                <span style="text-overflow: ellipsis; overflow: hidden; white-space: nowrap; max-width: 190px;">${item.title}</span>
                <span style="font-family: monospace; font-size: 10px; opacity: 0.6;">${item.time}</span>
              </div>
            `).join('')}
          </div>
          <div class="demo-detail-pane">
            <div>
              <h3 style="font-size: 15px; font-weight: 600; margin-bottom: 4px; color: #fff;">${s.title}</h3>
              <p style="font-size: 12px; color: #a5a5b2; margin-bottom: 12px;">${s.desc}</p>
            </div>
            ${s.detail}
          </div>
        </div>
      `;
    };

    tabs.forEach(btn => {
      btn.addEventListener('click', () => {
        tabs.forEach(t => t.classList.remove('active'));
        btn.classList.add('active');
        renderScenario(btn.getAttribute('data-tab'));
      });
    });

    renderScenario('observe');
  }

  // Copy Snippet Buttons
  function setupCopyButtons() {
    document.querySelectorAll('.btn-copy-snippet').forEach(btn => {
      btn.addEventListener('click', () => {
        const text = btn.getAttribute('data-copy');
        if (!text) return;
        navigator.clipboard.writeText(text).then(() => {
          const originalText = btn.textContent;
          btn.textContent = '已复制！';
          setTimeout(() => {
            btn.textContent = originalText;
          }, 2000);
        });
      });
    });
  }

})();
