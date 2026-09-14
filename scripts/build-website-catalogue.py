#!/usr/bin/env python3
"""Build paired static product/catalogue pages using the existing bilingual shell."""
from pathlib import Path
import re, html
ROOT=Path(__file__).resolve().parents[1]; DIST=ROOT/'website/dist'
def esc(s): return html.escape(s)
# All copy describes existing source capabilities, with availability stated on-page.
FEATURES=[
 ('sessions','会话与历史','Sessions & history','把工具调用放回上下文。','Put tool calls back in context.','浏览 Claude Code、Codex、Cursor 导入及 Pi/OMP 的受支持日志。搜索消息、回看计划与关联会话，分批导入历史。状态依据日志显示，未知信息保留未知。','Browse supported Claude Code, Codex, imported Cursor and Pi/OMP logs. Search messages, inspect plans and session relationships, and import history in batches. Status reflects log evidence; missing evidence stays unknown.'),
 ('memory','项目记忆','Project memory','值得记住的，留给下一次。','Keep what the next session needs.','从会话保存候选记忆，审阅后激活；按项目与作用域召回，替代或归档过时内容。支持本地词面、语义与混合检索，以及归档导入导出。','Capture candidate memories from sessions, review before activation, and recall within project and scope. Supersede or archive old context. Local lexical, semantic and hybrid search plus archive import/export keep it manageable.'),
 ('library','知识库与问答','Library & Ask','回答有出处，资料有边界。','Answers with sources. Notes with boundaries.','保存资料版本，以全文检索找到相关段落。Ask 经单独审批调用已配置模型并返回引用；私有资料不进入 Agent 检索或问答上下文。','Keep versioned references and find relevant passages with full-text search. Ask calls your configured model after separate approval and returns citations. Private sources are excluded from agent retrieval and question context.'),
 ('setup','配置与资产','Setup & assets','看清项目里生效前的配置。','Understand the configuration in your project.','集中查看 Rules、Skills、Hooks、MCP 与 Guidelines。扫描公开位置、审阅脱敏内容与差异，查看版本和来源关系；扫描不会执行 Hook 或 MCP。','Inspect rules, skills, hooks, MCP and guidelines together. Scan documented locations, review redacted content and diffs, and follow version/source relationships. Scanning does not execute hooks or MCP servers.'),
 ('workflows','工作流与调度','Workflows & schedules','把重复检查变成可复用步骤。','Make repeatable checks reusable.','用 Markdown 保存工作流，选择项目记忆和指南，先 Dry Run，再审阅写操作。支持运行记录、健康检查、显式调度和受控连接器动作。','Save workflows as Markdown, select memory and guidelines, and dry-run before reviewing mutations. Run records, health checks, explicit schedules and governed connector actions support repeatable work.'),
 ('approvals','审批与恢复','Approvals & recovery','清楚看到即将发生的修改。','See the change before it happens.','在 Inbox 查看目标文件、命令参数和完整内容。审批只用于一次已审阅的操作；过期审批不能执行。支持的本地修改保留恢复记录。','Review the target file, exact arguments and full content in Inbox. Approval covers one reviewed operation; expired approvals cannot execute. Supported local changes retain recovery records.'),
 ('improve','改进建议','Improvement proposals','从失败中找出可审查的改进。','Turn failures into reviewable changes.','回看会话中的纠错信号，为项目配置准备有证据的建议。修改前预览差异，执行后保留记录；支持的变更可撤销。','Review correction signals and prepare evidence-backed project configuration proposals. Preview the diff, apply the reviewed change and keep its record. Supported changes can be undone.'),
 ('lab','对照实验','Agent Lab','用实际结果判断下一步。','Choose the next step with evidence.','在隔离 Git worktree 比较基线与候选命令或 Agent 配置，核对召回、输出与验证结果。证据不足会显示不确定，不自动宣称改进。','Compare baseline and candidate commands or agent configurations in isolated Git worktrees. Inspect recall, output and verification results. Insufficient evidence is reported as inconclusive.'),
 ('feedback','运行反馈','Run feedback','把执行结果和使用感受分开。','Keep execution and usefulness distinct.','查看 Run 输出与交付状态，单独记录好坏评估和原因。反馈版本保留历史，避免把命令执行成功等同于结果有用。','Inspect run output and delivery state, then separately record usefulness and reasoning. Versioned feedback history keeps a successful command distinct from a useful result.'),
 ('usage','用量与配额','Usage & quota','可观测的数字，明确的来源。','Numbers with a visible source.','查看已观察到的 Token 用量及 Codex 账户额度状态（如可读取）。缺失的统计不显示为零；日志计量与订阅额度分别呈现。','Review observed token usage and Codex account quota status when it is available. Missing values are not shown as zero, and log usage remains separate from subscription allowance.'),
 ('handoff','交接与集成','Handoff & integrations','换一个会话，也接得上。','Carry context into the next session.','导出中立 Checkpoint，通过本地 MCP、CLI、SDK 或经审阅的 Codex Hook 提供上下文。可选集成独立安装，桌面不捆绑 Node 运行时。','Export a neutral checkpoint and offer context through local MCP, CLI, SDKs or a reviewed Codex hook. Optional integrations install separately; the desktop does not bundle Node.'),
 ('ownership','本地持有与备份','Local ownership & backup','工程数据保留在自己手里。','Keep your engineering data yours.','原生 AppKit、系统 WKWebView 与 Swift helper。Markdown 资产和本地 SQLite 索引保留在本机，支持备份与审阅后恢复，完整灾难恢复矩阵仍在验收。提供中英文界面、通知偏好和声音预览；系统通知受 macOS 授权限制。','Native AppKit, system WKWebView and a Swift helper. Keep Markdown assets and SQLite indexes locally, with backup and reviewed restore. The full disaster-recovery matrix remains under validation. Choose English or Simplified Chinese, notification preferences and sound previews; system delivery requires macOS authorization.')]
CASES=[
 ('session-review','sessions','接手昨天的改动','Pick up yesterday’s change','这段代码为什么这样改？','Why did this code change?','会话日志、工具调用、计划','Session logs, tool calls, plans','搜索项目 → 阅读消息 → 保存交接点','Search project → read messages → save checkpoint','带有来源的改动来由和 Checkpoint','Change rationale with sources and a checkpoint','继续工作前','Before resuming'),
 ('project-memory','memory','记住项目的约定','Remember the project’s rules','不要再重复说明测试和构建约束。','Stop repeating build and test constraints.','会话消息、已审阅的项目知识','Session messages, reviewed project context','保存候选 → 人工激活 → 受限召回','Save candidate → review and activate → bounded recall','下次会话可使用的项目记忆','Project memory for a future session','完成一次任务后','After a task'),
 ('review-workflows','workflows','放心运行重复任务','Run recurring checks with confidence','发布前，把需要检查的内容走一遍。','Walk through the checks before release.','工作流定义、Git 状态、项目脚本','Workflow definition, Git state, scripts','预演 → 检查目标与原文 → 批准执行','Dry-run → inspect targets and source → approve','有执行记录和输出的工作流','A workflow with recorded execution and output','提交或发布前','Before commit or release'),
 ('compare-and-reuse','lab','验证一次配置改进','Verify a configuration change','这条新规则是否真的有帮助？','Did the new rule actually help?','基线与候选配置、验证命令','Baseline/candidate settings, verifier','冻结方案 → 隔离运行 → 比较证据','Freeze plan → isolated runs → compare evidence','可追溯的比较，或明确的不确定','Traceable comparison, or explicit uncertainty','修改工程规则时','When changing a rule'),
 ('configuration-audit','sessions','梳理分散的配置','Untangle scattered configuration','各个 Agent 从哪里读取项目规约？','Where do agents get their project rules?','Rules、Skills、Hooks、MCP 文件','Rules, skills, hooks, MCP files','选择项目 → 扫描配置 → 审阅差异与来源','Select project → scan setup → review diffs and sources','脱敏资产目录、历史与配置诊断','Redacted asset inventory, history and diagnostics','接入或维护项目时','During project setup'),
 ('knowledge-search','memory','从项目资料中找答案','Find answers in project references','哪份资料解释了这条接口约束？','Which source explains this API constraint?','已公开给 Agent 的 Library 资料','Library sources available to agents','本地检索 → 审阅问答请求 → 核对引用','Search locally → review Ask request → inspect citations','带来源位置的回答与可继续的问答','An answer with source locations and follow-up','阅读陌生项目时','When learning a project'),
 ('workflow-health','workflows','回顾自动化的实际表现','Review how automation performed','任务完成了，但产物真的有用吗？','The run finished. Was the result useful?','Run 输出、健康诊断、历史反馈','Run output, health findings, feedback history','检查输出 → 记录评估 → 审阅调整建议','Inspect output → record feedback → review proposals','分开的执行状态、评估与变更历史','Separate execution state, assessment and change history','工作流结束后','After a workflow run'),
 ('usage-and-recovery','lab','让本地工作区保持可控','Keep the local workspace manageable','知道用了多少，也能保留和恢复记录。','Understand usage and preserve your records.','日志用量、本地索引与资产','Observed usage, local index and assets','检查用量来源 → 创建备份 → 校验与恢复','Inspect usage sources → back up → validate and restore','真实计量和可审查的恢复记录','Observed metrics and reviewable recovery records','定期维护时','During maintenance')]

def shell(locale, route, title, main):
 en=locale=='en';prefix='/en' if en else '';base=(DIST/('en/index.html' if en else 'index.html')).read_text()
 head=base[:base.index('  <main>')];foot=base[base.index('  <footer class="site-footer">'):]
 # Relative shell assets must also resolve from nested routes.
 asset_ref = r'(href|src)="(?:\.\./)*(assets/[^\"]+|styles\.css(?:\?[^\"]*)?|site\.js(?:\?[^\"]*)?)"'
 head=re.sub(asset_ref,lambda m:m[1]+'="/'+m[2]+'"',head)
 foot=re.sub(asset_ref,lambda m:m[1]+'="/'+m[2]+'"',foot)
 head=re.sub(r'<title>.*?</title>', '<title>'+esc(title)+' — Vela</title>',head)
 head=re.sub(r'<meta name="description" content="[^"]*">','<meta name="description" content="'+esc(title)+' · '+('Local-first engineering workspace for coding agents.' if en else '面向 Coding Agent 的本地工程工作区。')+'">',head)
 for attr,loc in [('canonical',prefix+route)]:head=re.sub(r'<link rel="canonical"[^>]+>',f'<link rel="canonical" href="https://velo.codes{loc}">',head)
 for lang,path in [('zh-CN',route),('en','/en'+route),('x-default',route)]:head=re.sub(r'<link rel="alternate" hreflang="'+lang+r'"[^>]+>',f'<link rel="alternate" hreflang="{lang}" href="https://velo.codes{path}">',head)
 other=route if en else '/en'+route
 head=re.sub(r'href="[^"]*"( class="header-lang-link")',f'href="{other}"'+r'\1',head)
 head=re.sub(r'href="[^"]*"( class="nav-link lang-switch-link")',f'href="{other}"'+r'\1',head)
 dest=DIST/(prefix+route).lstrip('/')/'index.html';dest.parent.mkdir(parents=True,exist_ok=True);dest.write_text(head+'  <main>\n'+main+'\n  </main>\n\n'+foot)

def hero(eyebrow,title,desc):return f'<section class="catalogue-hero container"><div class="section-eyebrow">{eyebrow}</div><h1 class="catalogue-title">{title}</h1><p class="catalogue-lead">{desc}</p></section>'
def availability(en):return '<aside class="availability-note container">'+('This guide covers the current development source. The public download is preview.2; newer capabilities require a source build. See <a href="/en/releases.html">releases</a> for availability.' if en else '本指南介绍当前开发分支能力。公开下载仍为 preview.2，较新的能力需要从源码构建；具体版本请查看<a href="/releases.html">发行记录</a>。')+'</aside>'
VISUALS = {
 'sessions': ('vela-reading.png', '会话中的命令、正文和原始记录', 'Conversation text, readable commands and original records'),
 'memory': ('vela-memory-current.png', '项目记忆、状态与来源链接', 'Project memories, lifecycle states and source links'),
 'workflows': ('vela-workflows-current.png', '按任务类型区分的工作流和条目菜单', 'Workflows with task-specific icons and contextual actions'),
 'approvals': ('vela-approval-current.png', '完整内容预览与单次操作审批', 'Full content preview and review of one action'),
 'setup': ('vela-setup-current.png', '配置资产的相对位置与脱敏预览', 'Configuration assets, relative locations and redacted previews')
}

def screenshot(feature, en):
 if feature not in VISUALS: return ''
 name,zh,english=VISUALS[feature]
 caption='Actual macOS development UI · isolated nonpersistent synthetic fixture · not the preview.2 download' if en else '实际 macOS 开发版界面 · 隔离非持久合成 fixture · 非 preview.2 下载内容'
 return f'<figure class="product-visual"><img src="/assets/{name}" alt="{esc(english if en else zh)}" width="1250" height="800" loading="lazy" decoding="async"><figcaption>{caption}</figcaption></figure>'

def context_story(en):
 title='A session ends. The useful part stays.' if en else '会话结束，值得留下的继续。'
 copy='Read the source, keep a reviewed piece of context, and offer it to the next session. Vela keeps the history of that decision; only a later comparison can tell you whether it helped.' if en else '先读清来源，再保留经过审阅的上下文，交给下一次会话。Vela 记录这次选择的来由；是否有帮助，仍需后续对照验证。'
 alt='A small black character stitches a reviewed bookmark into a notebook between two conversations.' if en else '小黑把一枚经过审阅的书签缝入笔记本，让知识连接前后两次会话。'
 caption='Concept illustration · context is reviewed, not automatically trusted' if en else '概念插图 · 上下文需要审阅，不自动视为可信'
 return f'<section class="context-story container"><figure><img src="/assets/vela-context-stitch.png" alt="{esc(alt)}" width="1672" height="941" loading="lazy" decoding="async"><figcaption>{caption}</figcaption></figure><div><div class="section-eyebrow">OBSERVE / REMEMBER / VERIFY</div><h2>{title}</h2><p>{copy}</p></div></section>'

CASE_GUIDANCE = {
 'session-review': [('选择正在处理的项目，按名称或提供方找到对应会话。状态依据已观察日志，不代表实时进程监控。','Choose the project and find the session by title or provider. State comes from observed logs, not live process monitoring.'),('阅读消息和可识别的命令；需要精确参数时展开原始记录。计划和关联会话保留各自证据边界。','Read messages and recognized commands; expand the original record for exact parameters. Plans and related sessions retain their evidence boundaries.'),('保存 Checkpoint，保留用户笔记和当时的 Git 状态，供下一次会话参考。','Save a checkpoint with your notes and captured Git state for the next session.')],
 'project-memory': [('从一条用户或助手消息保存候选记忆，保留来源会话和消息身份。工具记录不能直接视为项目约定。','Capture a candidate from a user or assistant message, preserving source identity. Tool records are not automatically project rules.'),('核对内容、类型和项目范围，明确激活后才可进入相应召回。过时内容可替代或归档。','Review the text, type and project scope before activation makes it eligible for recall. Supersede or archive outdated context.'),('通过受支持的 CLI、MCP 或经审阅的 Hook 提供上下文。召回记录证明提供了什么，不证明模型遵守或质量提升。','Offer context through the supported CLI, MCP or a reviewed hook. Recall receipts show what was offered, not model compliance or improvement.')],
 'review-workflows': [('从已保存定义开始，检查每一步的工具和作用域。Dry Run 只执行受支持的只读检查，其他步骤保留审阅说明。','Start from a saved definition and inspect each tool and scope. Dry Run executes supported reads; other steps retain review information.'),('在审批页阅读目标、命令与完整源内容。原始参数可展开；审批快照与当时看到的操作保持一致。','Read the target, command and full source in Approvals. Expand exact parameters; approval remains bound to the displayed operation.'),('批准后查看持久化运行记录、输出和需要进一步处理的状态。执行完成和结果有用分别判断。','After approval, inspect persisted run records, output and follow-up states. Judge execution completion separately from usefulness.')],
 'compare-and-reuse': [('固定相同项目提交、任务、基线和候选配置；选择记忆模式与独立验证命令，审阅冻结方案。','Fix the project commit, task, baseline and candidate configuration. Select memory modes and an independent verifier; review the frozen plan.'),('经审批后在隔离 Git worktree 执行，保留真实命令结果、输出与验证证据。','After approval, execute in isolated Git worktrees and retain actual command results, output and verification evidence.'),('按真实结果比较。缺失数据、平局和回归不能当作改进；只有满足条件的候选才可进入后续推广审阅。','Compare actual results. Missing data, ties and regressions do not count as improvements; only eligible candidates reach promotion review.')],
 'configuration-audit': [('选择已登记项目，扫描受支持的 Rules、Skills、Hooks 和 MCP 配置位置。','Select a registered project and scan supported rules, skills, hooks and MCP locations.'),('列表显示可读名称和相对位置，打开条目阅读脱敏预览；扫描本身不执行配置。','Read recognizable names and relative locations, then open redacted content. Scanning does not execute configuration.'),('检查来源、版本历史和差异，再决定是否需要后续改动。','Inspect sources, version history and differences before deciding on a change.')],
 'knowledge-search': [('保存本地文档或显式提供的资料网址，记录来源与版本。默认私有资料保留检索边界。','Save local documents or an explicitly supplied reference URL, preserving source and version. Private material retains its retrieval boundary.'),('先使用本地段落检索定位资料；确认哪些公开资料可用于模型问答。','Use local passage search first, and review which eligible public sources can enter model-backed questions.'),('Ask 经单独审批调用已配置模型并返回引用。检查引用后再使用回答，不把输出视为自动验证的事实。','Ask invokes your configured model after separate approval and returns citations. Inspect citations before using the answer.')],
 'workflow-health': [('打开工作流的运行记录和健康视图，检查已有失败与耗时证据。','Open run history and health views to inspect observed failures and timing evidence.'),('查看可审阅建议的适用范围和来源，不将统计提示自动应用到配置。','Review a proposal’s scope and source; statistical hints are not applied automatically.'),('重新运行受支持的检查并保存反馈。反馈历史与客观执行结果分别保留。','Run supported checks again and record feedback, keeping its history separate from objective execution results.')],
 'usage-and-recovery': [('分别查看日志 Token 与账户额度，核对来源时间；未提供的数据不会显示为零。','Read log tokens and account limits separately, checking observation time. Missing data is not shown as zero.'),('使用 CLI 创建本地 Store 备份，核对清单。备份不包含项目工作树或外部 Agent 凭据。','Create a local Store backup with the CLI and inspect the manifest. Project working trees and external agent credentials are excluded.'),('先校验备份，再恢复到新的目录；旧执行请求会失效，避免意外重复运行。','Validate the backup before restoring into a new directory. Old execution requests are invalidated to avoid unintended reruns.')]
}
CASE_FEATURE = {'session-review':'sessions','project-memory':'memory','review-workflows':'approvals','compare-and-reuse':'lab','configuration-audit':'setup','knowledge-search':'library','workflow-health':'workflows','usage-and-recovery':'usage'}
# The four catalogue filters intentionally group related jobs. Detail-page eyebrow labels name the concrete product surface linked below.
CASE_EYEBROW = {
 'configuration-audit': ('配置与资产', 'SETUP & ASSETS'),
 'knowledge-search': ('知识库与问答', 'LIBRARY & ASK'),
 'usage-and-recovery': ('用量与恢复', 'USAGE & RECOVERY'),
}

for locale in ['zh','en']:
 en=locale=='en';p='/en' if en else ''
 main=hero('PRODUCT', 'A workspace for the work<br>between agent sessions.' if en else '让每一次会话，<br>成为下一次工作的起点。', 'Observe the work, keep useful context, review automation and test what improves it. One local workspace, around the coding tools you already use.' if en else '观察过程、保留上下文、审阅自动化，并用实际结果验证改进。围绕你已经在用的编码工具，建立一个本地工作区。')
 main+='<nav class="product-index container" aria-label="'+('Product capabilities' if en else '产品能力')+'">'+''.join(f'<a href="#{f[0]}">{esc(f[2] if en else f[1])}</a>' for f in FEATURES)+'</nav>'
 main+='<div class="feature-catalogue container">'
 for i,f in enumerate(FEATURES):main+=f'<section class="feature-row" id="{f[0]}"><div class="feature-row-label"><span class="section-eyebrow">{i+1:02d} / {esc(f[2] if en else f[1])}</span></div><div><h2>{esc(f[4] if en else f[3])}</h2><p>{esc(f[6] if en else f[5])}</p><a class="text-link" href="{p}/docs.html">'+('Explore the documentation →' if en else '查看文档 →')+'</a></div>'+screenshot(f[0],en)+'</section>'
 main+='</div>'+context_story(en)+availability(en);shell(locale,'/product/','Product' if en else '产品功能',main)
 main=hero('INTEGRATIONS','Your tools.<br>A shared engineering context.' if en else '熟悉的工具，<br>连续的工程上下文。','Choose the connection you need. Read local logs, offer reviewed context or install an optional SDK integration.' if en else '按需接入：读取本地日志，提供已审阅的上下文，或为自己的工具安装可选 SDK。')
 groups=[('Local agent logs','本地 Agent 日志','Claude Code · Codex · Cursor · Pi · OMP','Read supported formats, inspect provenance and import supported history. Coverage differs by provider; Cursor private formats are not assumed compatible.','读取受支持格式、查看来源并导入可支持的历史。不同工具覆盖范围不同，不能假设 Cursor 私有格式全部兼容。'),('Context interfaces','上下文接口','CLI · stdio MCP · Codex Hook · Checkpoint','Use project-scoped recall and explicit candidate contributions. Review hook installation before applying it; a delivery receipt does not prove the model followed the context.','使用项目隔离的召回与显式候选写入。Hook 安装前需要审阅；提供上下文的收据不等于模型已经遵守。'),('Optional SDKs','可选 SDK','TypeScript · Python · AI SDK · Responses · LangChain · OpenClaw','Install SDK and host adapters separately. Scope, cancellation and candidate capture have separate contracts. Consult the package documentation for supported versions.','独立安装 SDK 和宿主适配器，作用域、取消和候选捕获各有接口约定。支持版本见对应软件包文档。'),('Governed automation','受控自动化','Local commands · HTTP · Connector profiles','Configure supported actions explicitly and review their exact arguments before side effects. External integrations need your own provider credentials.','显式配置受支持动作，在产生副作用前审查精确参数。外部服务需要你自己的提供方凭据。')]
 main+='<div class="feature-catalogue container">'
 for i,g in enumerate(groups):main+=f'<section class="feature-row"><div class="section-eyebrow">{i+1:02d} / {g[0] if en else g[1]}</div><div><h2>{g[2]}</h2><p>{g[3] if en else g[4]}</p></div></section>'
 main+='</div><div class="container integration-footer"><h2>'+('Local by default. Connected by choice.' if en else '默认本地运行，连接由你选择。')+'</h2><p>'+('The macOS app does not bundle Electron or a Node runtime. Optional remote storage remains experimental and is documented separately.' if en else 'macOS 客户端不捆绑 Electron 或 Node 运行时。可选远端存储仍处于实验阶段，另有独立文档。')+f'</p><a class="text-link" href="{p}/docs.html">'+('Integration documentation →' if en else '集成文档 →')+'</a></div>'+availability(en);shell(locale,'/integrations/','Integrations' if en else '工具集成',main)
 main=hero('USE CASES','From a loose end<br>to a clear next step.' if en else '从一个待解问题，<br>到清楚的下一步。','Eight everyday engineering tasks. Start with the question, see the inputs and leave with a result you can inspect.' if en else '八个日常工程场景。从具体问题开始，看清需要的输入，留下可以检查的结果。')
 cats=[('all','全部任务','All tasks',8),('sessions','观察与配置','Observe & configure',2),('memory','知识与记忆','Knowledge & memory',2),('workflows','运行与审阅','Run & review',2),('lab','验证与维护','Verify & maintain',2)]
 main+='<section class="container usecase-catalogue"><div class="catalogue-pills" role="toolbar" aria-label="'+('Filter use cases' if en else '筛选使用场景')+'">'+''.join(f'<button class="catalogue-pill {"active" if c[0]=="all" else ""}" data-filter="{c[0]}" aria-pressed="{str(c[0]=="all").lower()}">{c[2] if en else c[1]} <span class="catalogue-pill-count">{c[3]}</span></button>' for c in cats)+'</div><div id="filter-status" class="filter-status" role="status" aria-live="polite">'+('Showing 8 / 8 use cases' if en else '显示 8 / 8 个场景')+'</div><div class="usecases-table-wrapper" tabindex="0"><table class="usecases-table"><thead><tr>'+''.join('<th scope="col">'+x+'</th>' for x in (['What you want to do','What it uses','What you leave with','When'] if en else ['想完成的事','使用的输入','留下的结果','何时使用']))+'</tr></thead><tbody>'
 for c in CASES:
  slug,cat,zh,enTitle,question,questionEn,reads,readsEn,steps,stepsEn,result,resultEn,cadence,cadenceEn=c
  main+=f'<tr data-category="{cat}"><td><a class="usecase-task-link" href="{p}/usecases/{slug}/">{enTitle if en else zh}<span aria-hidden="true">↗</span></a><p class="usecase-task-desc">{questionEn if en else question}</p></td><td>{readsEn if en else reads}</td><td>{resultEn if en else result}</td><td><span class="case-cadence">{cadenceEn if en else cadence}</span></td></tr>'
  eyebrow = CASE_EYEBROW.get(slug, (cat.upper(), cat.upper()))[1 if en else 0]
  detail=hero('USE CASE / '+eyebrow,enTitle if en else zh,questionEn if en else question)
  detail+='<div class="container case-detail"><div class="case-readout"><div><span class="section-eyebrow">'+('INPUT' if en else '输入')+'</span><p>'+ (readsEn if en else reads)+'</p></div><div><span class="section-eyebrow">'+('RESULT' if en else '结果')+'</span><p>'+(resultEn if en else result)+'</p></div></div><ol class="case-steps">'
  for i,step in enumerate((stepsEn if en else steps).split('→')):
   detail+=f'<li><span>{i+1:02d}</span><div><h2>{step.strip()}</h2><p>{esc(CASE_GUIDANCE[slug][i][1 if en else 0])}</p></div></li>'
  detail+='</ol>'+screenshot(CASE_FEATURE[slug],en)+f'<a class="text-link" href="{p}/product/#{CASE_FEATURE[slug]}">'+('Explore related capabilities →' if en else '查看相关产品功能 →')+f'</a><br><a class="text-link" href="{p}/usecases/">'+('← All use cases' if en else '← 全部使用场景')+'</a></div>'
  if slug == 'project-memory': detail+=context_story(en)
  detail+=availability(en)
  shell(locale,'/usecases/'+slug+'/',enTitle if en else zh,detail)
 main+='</tbody></table></div></section>'+availability(en);shell(locale,'/usecases/','Use Cases' if en else '使用场景',main)
# Keep every existing route and local language partner while extending both navigation surfaces.
for path in DIST.rglob('*.html'):
 s=path.read_text();en=path.relative_to(DIST).parts[0]=='en';p='/en' if en else ''
 nav=''.join(f'<a href="{p}/{route}/" class="nav-link">{label}</a>' for route,label in [('product','Product' if en else '产品功能'),('usecases','Use Cases' if en else '使用场景'),('integrations','Integrations' if en else '工具集成'),('comparisons','Comparisons' if en else '产品对比')])
 s=re.sub(r'(<nav class="site-nav"[^>]*>).*?(</nav>)',lambda m:m[1]+nav+m[2],s,flags=re.S)
 a=s.index('<div class="mobile-nav-panel"');b=s.index('</div>',a);chunk=s[a:b]
 for route,label in [('product','Product' if en else '产品功能'),('integrations','Integrations' if en else '工具集成')]:
  if f'href="{p}/{route}/"' not in chunk:chunk=chunk[:chunk.index('>')+1]+f'<a href="{p}/{route}/" class="nav-link">{label}</a>'+chunk[chunk.index('>')+1:]
 s=s[:a]+chunk+s[b:]
 if path in [DIST/'index.html',DIST/'en/index.html']:
  title='Explore the whole workspace.' if en else '一个工作区，连接完整工程过程。'
  intro='Twelve connected capabilities, from session history and configuration to knowledge, automation, evaluation and recovery.' if en else '十二个相互衔接的能力，覆盖会话历史、工程配置、知识、自动化、验证与恢复。'
  showcase=f'<section class="narrative-section product-overview"><div class="container"><div class="section-eyebrow">THE WORKSPACE</div><h2 class="section-h2">{title}</h2><p class="section-lead">{intro}</p><div class="overview-links">'+''.join(f'<a href="{p}/product/#{f[0]}"><span>{i+1:02d}</span>{f[2] if en else f[1]}<span>↗</span></a>' for i,f in enumerate(FEATURES))+f'</div><a class="text-link" href="{p}/product/">'+('Explore all capabilities →' if en else '查看全部功能 →')+'</a></div></section>'
  if 'class="narrative-section product-overview"' not in s:s=s.replace('    <!-- Section: 4 Use Case Task Entries -->',showcase+'\n    <!-- Section: 4 Use Case Task Entries -->')
  if 'class="context-story container"' not in s:s=s.replace('    <!-- Section: 4 Use Case Task Entries -->',context_story(en)+'\n    <!-- Section: 4 Use Case Task Entries -->')
  s=s.replace('across all 4 use cases','across all 8 use cases').replace('全部 4 个','全部 8 个')
 path.write_text(s)
print('Built',len(list(DIST.rglob('*.html'))),'bilingual pages')

# A changed asset gets a new URL even in browsers retaining an older Cloudflare TTL.
import runpy
runpy.run_path(str(Path(__file__).with_name("version-website-assets.py")), run_name="__main__")
