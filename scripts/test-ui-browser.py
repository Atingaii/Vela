"""Browser regression checks against product UI and real isolated CLI records.

Recommended: Python 3.9+, Node.js 20+, installed Google Chrome, and Playwright
1.62.1 (the verified library version). From a normal repository checkout:
  npm install --prefix .task-tmp/ui-browser-tools --registry=https://registry.npmjs.org --save-exact playwright@1.62.1
  swift build
  python3 scripts/create-ui-fixture.py .task-tmp/ui-browser-qa --binary .build/debug/vela --with-routing-project
  python3 scripts/test-ui-browser.py .task-tmp/ui-browser-qa/fixture.json --binary .build/debug/vela --driver playwright --playwright-module "$PWD/.task-tmp/ui-browser-tools/node_modules/playwright/index.js" --browser-executable "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

The fixture directory must be NEW. Dependencies stay under .task-tmp; the script
never installs packages, downloads browsers, or changes global configuration.
--driver agent-browser is an optional alternative and requires that CLI.
Native dialogs, audio and notification delivery require separate macOS checks.
Failing screenshots are test evidence, not product artwork.
Route events and bounded read faults are injected; business data is always real CLI output.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
from release_resources import DEVELOPMENT_UI_RESOURCES, UI_RESOURCES
import select
import shutil
import signal
import subprocess
import time
import traceback
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
PLAYWRIGHT_DRIVER = r"""
const { chromium } = require(process.argv[1]);
const readline = require('node:readline');
(async()=>{
  const browser=await chromium.launch({headless:true,...(process.argv[2]?{executablePath:process.argv[2]}:{})});
  const page=await browser.newPage({viewport:{width:1280,height:720}});page.setDefaultTimeout(5000);
  for await (const line of readline.createInterface({input:process.stdin})) {
    const [command,...args]=JSON.parse(line);let output='';
    try {
      if(command==='open')await page.goto(args[0]);
      else if(command==='click')await page.locator(args[0]).click();
      else if(command==='focus')await page.locator(args[0]).focus();
      else if(command==='fill')await page.locator(args[0]).fill(args[1]);
      else if(command==='select')await page.locator(args[0]).selectOption(args[1]);
      else if(command==='press')await page.keyboard.press(args[0]);
      else if(command==='wait')await page.locator(args[0]).waitFor();
      else if(command==='snapshot')output=await page.locator(args.includes('-s')?args[args.indexOf('-s')+1]:'body').ariaSnapshot();
      else if(command==='eval')output=JSON.stringify(await page.evaluate(args[0]));
      else if(command==='get'&&args[0]==='url')output=page.url();
      else if(command==='screenshot')await page.screenshot({path:args[0]});
      else if(command==='close'){await browser.close();console.log(JSON.stringify({output}));break;}
      else throw Error('Unsupported test driver command: '+command);
      console.log(JSON.stringify({output}));
    }catch(error){console.log(JSON.stringify({error:String(error)}));}
  }
})().catch(error=>{console.error(error);process.exit(1)});
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--binary', type=Path, default=ROOT / '.build/debug/vela')
    parser.add_argument('--ui-directory', type=Path, help='Optional frozen <fixture>/ui-snapshot copy; recorded in source hashes.')
    parser.add_argument('--agent-browser', default='agent-browser')
    parser.add_argument('--browser-executable', type=Path, help='Optional explicit Chrome executable for isolated local QA.')
    parser.add_argument('--driver', choices=['agent-browser', 'playwright'], default='playwright', help='Playwright is recommended; no driver is installed automatically.')
    parser.add_argument('--playwright-module', default=str(ROOT / '.task-tmp/ui-browser-tools/node_modules/playwright/index.js'), help='Installed Playwright Node module or entry path; defaults to the documented local tools directory.')
    parser.add_argument('--checks', help='Optional comma-separated diagnostic checks; omit for the complete suite.')
    args = parser.parse_args()
    if args.driver == 'playwright':
        if not shutil.which('node'):
            parser.error('Node.js 20+ is required for the Playwright driver; see --help for setup.')
        module = Path(args.playwright_module)
        if module.is_file():
            args.playwright_module = str(module.resolve())
        elif '/' in args.playwright_module or '\\' in args.playwright_module:
            parser.error('Playwright module does not exist. Install the documented pinned dependency or pass --playwright-module; see --help.')
    if args.browser_executable and not args.browser_executable.is_file():
        parser.error('The specified Chrome executable does not exist.')
    server = subprocess.Popen(['python3', str(ROOT / 'scripts/test-ui-server.py'), str(args.manifest),
                               '--binary', str(args.binary), *(['--ui-directory', str(args.ui_directory)] if args.ui_directory else [])], stdout=subprocess.PIPE, text=True)
    session = 'vela-ui-test-' + uuid.uuid4().hex[:8]
    results = []
    selected_checks = set(args.checks.split(',')) if args.checks else None
    if selected_checks and not selected_checks <= {'filtering', 'setup', 'memory', 'workflow', 'draft', 'keyboard', 'rapid-navigation', 'live-detail', 'routing', 'routing-failure', 'routing-unknown', 'routing-aggregate'}:
        server.terminate()
        server.wait(timeout=5)
        parser.error('Unknown check name.')
    direct_driver = None
    if args.driver == 'playwright':
        direct_driver = subprocess.Popen(['node', '-e', PLAYWRIGHT_DRIVER, args.playwright_module,
            str(args.browser_executable or '')], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            text=True, start_new_session=True)

    def browser(*arguments):
        if direct_driver:
            direct_driver.stdin.write(json.dumps(arguments) + '\n')
            direct_driver.stdin.flush()
            if not select.select([direct_driver.stdout], [], [], 15)[0]:
                raise TimeoutError('Direct Playwright driver did not respond.')
            response = json.loads(direct_driver.stdout.readline())
            if 'error' in response:
                raise AssertionError(response['error'])
            return response['output']
        options = ['--namespace', session, '--session', session, '--pin-tab']
        if args.browser_executable:
            options += ['--executable-path', str(args.browser_executable.resolve(strict=True))]
        environment = {k: v for k, v in os.environ.items() if not k.startswith('AGENT_BROWSER_') and k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')}
        environment['AGENT_BROWSER_DEFAULT_TIMEOUT'] = '5000'
        process = subprocess.Popen([args.agent_browser, *options, *arguments],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
            env=environment)
        try:
            output, error = process.communicate(timeout=15)
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
        if process.returncode:
            raise AssertionError(error or output)
        return output.strip()

    def value(expression):
        return json.loads(json.loads(browser('eval', 'JSON.stringify(' + expression + ')')))

    def wait_for(expression, message):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if value(expression):
                return
            time.sleep(0.15)
        raise AssertionError(message)

    def click(selector):
        browser('click', selector)
        browser('snapshot', '-i')

    def open_action_menu(trigger):
        menu = 'details.action-menu:has(' + trigger + ')'
        wait_for('!!document.querySelector(' + json.dumps(menu) + ')', 'Action menu is absent for ' + trigger)
        if not value('document.querySelector(' + json.dumps(menu) + ').open'):
            click(menu + ' > summary')
            wait_for('document.querySelector(' + json.dumps(menu) + ').open===true', 'Action menu did not open for ' + trigger)

    def page(name):
        browser('press', 'Escape')
        browser('press', 'Escape')
        click('.nav-link[data-page="' + name + '"]')
        wait_for('document.querySelector(".nav-link.active[data-page]")?.dataset.page===' + json.dumps(name),
                 'Visible navigation does not match the requested page: ' + name)

    def read(method, params=None):
        request = urllib.request.Request(url + '__rpc', data=json.dumps({'method': method, 'params': params or {}}).encode(),
            headers={'Content-Type': 'application/json', 'Origin': url.split('/', 3)[0] + '//' + url.split('/')[2]})
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)['result']

    def check(name, action):
        if selected_checks is not None and name not in selected_checks:
            return
        try:
            action()
            results.append({'check': name, 'passed': True, 'driver': args.driver})
        except Exception as error:
            results.append({'check': name, 'passed': False, 'error': str(error), 'traceback': traceback.format_exc(limit=3), 'driver': args.driver})
            try:
                results[-1]['url'] = browser('get', 'url')
                browser('screenshot', str(base / ('failure-' + name + '.png')))
            except Exception:
                pass
        print(json.dumps(results[-1], ensure_ascii=False), flush=True)
        report.write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
        if results[-1].get('url') and results[-1]['url'] != url:
            raise RuntimeError('Browser left the test URL; remaining flows were not evaluated.')

    try:
        if not select.select([server.stdout], [], [], 15)[0]:
            raise RuntimeError('Fixture server did not start.')
        ready = json.loads(server.stdout.readline())
        url, base = ready['url'], Path(ready['fixture'])
        report = base / ('browser-results-diagnostic.json' if selected_checks else 'browser-results.json')
        metadata_path = base / ('browser-metadata-diagnostic.json' if selected_checks else 'browser-metadata.json')
        def source_hashes():
            files = {name: (args.ui_directory or ROOT / 'Sources/VelaApp/Resources/UI') / name for name in UI_RESOURCES + DEVELOPMENT_UI_RESOURCES}
            files['helper'] = args.binary
            return {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in files.items()}
        source_before = source_hashes()
        metadata = {'sourceBefore': source_before, 'completeSuite': False, 'sourceUnchanged': None}
        metadata_path.write_text(json.dumps(metadata, indent=2) + '\n')
        fixture = json.loads(args.manifest.read_text())
        project = Path(fixture['project'])
        browser('open', url)
        browser('wait', '#session-search-input')
        browser('snapshot', '-i')

        def filtering():
            assert value('!!window.vela && !window.VelaDemo'), 'Product UI must use the real bridge.'
            page('agents')
            browser('fill', '#session-search-input', 'no-such-session-unique')
            assert value('!!document.querySelector("#sessions-empty-state")?.getClientRects().length'), 'No visible filter empty state.'
            assert value('/无匹配|没有匹配|未找到匹配|No match/i.test(document.querySelector("#sessions-empty-state").textContent)'), 'Filter result must explain that no sessions match.'
            clear = value('Array.from(document.querySelectorAll("#sessions-empty-state button")).find(b=>b.getClientRects().length && /清除|重置|clear/i.test(b.textContent))?.id || ""')
            assert clear, 'No visible clear-filter action.'
            click('#' + clear)
            assert value('document.querySelector("#session-search-input").value') == '', 'Clear filters did not reset search.'
            snapshot = browser('snapshot', '-s', '#sessions-grouped-lists')
            assert 'listitem' in snapshot and 'Validate request limits' in snapshot, 'Session groups are absent from the accessibility tree.'
            session_button = '#sessions-grouped-lists .session-group:first-child .session-card:first-child .session-title-btn'
            browser('focus', session_button)
            browser('press', 'Enter')
            wait_for('!document.querySelector("#detail-drawer").classList.contains("hidden")', 'Session row button did not open its detail with Enter.')
            assert value('document.querySelector(".nav-link.active").dataset.page') == 'agents', 'Opening a session activated another page.'

        def setup():
            page('setup')
            click('#btn-scan-setup')
            for tab, title in [('rules', 'AGENTS.md'), ('skills', 'SKILL.md')]:
                click('[data-setuptab="' + tab + '"]')
                wait_for('document.querySelector("#setup-tab-content").textContent.includes(' + json.dumps(title) + ')', 'Real scanned ' + title + ' is not visible.')
            click('[data-setuptab="hooks"]')
            assert value('document.querySelector("#setup-tab-content").textContent.includes("settings.json")'), 'Hook configuration is not visible.'
            click('[data-setuptab="mcp"]')
            assert value('document.querySelector("#setup-tab-content").textContent.includes(".mcp.json")'), 'Real MCP configuration is not visible.'

        def memory():
            page('memory')
            click('#btn-new-memory')
            browser('fill', '#mem-title', 'Renderer acceptance constraint')
            browser('fill', '#mem-content', 'Retain the boundary assertion when refactoring request validation.')
            browser('select', '#mem-project', str(project))
            click('#btn-save-mem')
            wait_for('document.querySelector("#modal-container").classList.contains("hidden")', 'Memory form did not save.')
            item = next(m for m in read('memory.list') if m['title'] == 'Renderer acceptance constraint')
            open_action_menu('.btn-mem-activate[data-id="' + item['id'] + '"]')
            click('.btn-mem-activate[data-id="' + item['id'] + '"]')
            open_action_menu('#btn-recall-tester')
            click('#btn-recall-tester')
            browser('fill', '#recall-query', 'Renderer acceptance constraint')
            browser('select', '#recall-project', str(project))
            click('#btn-do-recall')
            wait_for('document.querySelector("#recall-results-area").textContent.includes("Renderer acceptance constraint")', 'Activated memory was not recalled.')

        def workflow():
            page('workflows')
            click('#btn-new-workflow')
            browser('fill', '#wf-modal-title', 'Renderer approved note')
            browser('select', '#wf-modal-project', str(project))
            browser('select', '.wf-step-tool[data-idx="1"]', 'file.write')
            browser('fill', '.wf-step-args[data-idx="1"]', json.dumps({'path': 'docs/ui-browser-check.md', 'content': 'Written after explicit renderer approval.\n'}))
            click('#btn-save-wf')
            wait_for('document.querySelector("#modal-container").classList.contains("hidden")', 'Workflow form did not save.')
            item = next(w for w in read('workflows.list') if w['title'] == 'Renderer approved note')
            click('.btn-wf-dryrun[data-id="' + item['id'] + '"]')
            assert not (project / 'docs/ui-browser-check.md').exists(), 'Dry Run wrote a file.'
            page('workflows')
            click('.btn-wf-run[data-id="' + item['id'] + '"]')
            # The product handler awaits workflows.run before it refreshes the
            # dashboard. A Playwright click only waits for the DOM event, so
            # wait for the exact frozen side effect instead of sampling Inbox
            # before the bridge call has committed it.
            expected_path = str((project / 'docs/ui-browser-check.md').resolve())
            expected_content = 'Written after explicit renderer approval.\n'
            deadline = time.monotonic() + 8
            approval = None
            while time.monotonic() < deadline:
                for candidate in read('inbox.list'):
                    arguments = candidate.get('arguments') or {}
                    if (candidate.get('tool') == 'file.write'
                            and candidate.get('project') == str(project)
                            and arguments.get('path') == expected_path
                            and arguments.get('content') == expected_content):
                        candidate_run = read('runs.get', {'id': candidate['runId']})
                        steps = candidate_run.get('steps') or []
                        if (candidate_run.get('workflowId') == item['id']
                                and candidate_run.get('state') == 'pending_approval'
                                and any(step.get('approvalId') == candidate['id']
                                        and step.get('tool') == 'file.write'
                                        and step.get('state') == 'pending_approval'
                                        for step in steps)):
                            approval = candidate
                            break
                if approval:
                    break
                time.sleep(0.1)
            assert approval is not None, 'Workflow run did not persist its exact pending file.write approval within 8 seconds.'
            page('inbox')
            wait_for('!!document.querySelector(' + json.dumps('.btn-approve-appr[data-id="' + approval['id'] + '"]') + ')?.getClientRects().length',
                     'Persisted approval is absent from the Inbox UI.')
            assert not (project / 'docs/ui-browser-check.md').exists(), 'File was written before approval.'
            click('.btn-approve-appr[data-id="' + approval['id'] + '"]')
            # A browser click returns before its async approval request completes.
            # Wait for this exact persisted run, then verify its file bytes independently.
            deadline = time.monotonic() + 8
            while True:
                approved_run = read('runs.get', {'id': approval['runId']})
                if approved_run.get('state') in ('completed', 'failed') or time.monotonic() >= deadline:
                    break
                time.sleep(0.1)
            assert approved_run.get('state') == 'completed', 'Approved workflow did not complete: ' + str(approved_run.get('state'))
            assert (project / 'docs/ui-browser-check.md').read_text() == 'Written after explicit renderer approval.\n'
            if fixture.get('commandApproval'):
                command = next(a for a in read('inbox.list') if a['id'] == fixture['commandApproval'])
                selector = '.btn-approve-appr[data-id="' + command['id'] + '"]'
                display = value('Array.from(document.querySelector(' + json.dumps(selector) + ').closest(".card").querySelectorAll("code")).filter(el=>el.getClientRects().length&&!el.closest("details")).map(el=>el.textContent).join("\\n")')
                assert command['arguments']['executable'] in display, 'Command approval summary omitted the frozen executable.'
                arrays = []
                for index, char in enumerate(display):
                    if char == '[':
                        try:
                            arrays.append(json.JSONDecoder().raw_decode(display[index:])[0])
                        except ValueError:
                            pass
                argv = command['arguments']['args']
                assert argv in arrays or [command['arguments']['executable'], *argv] in arrays, 'Visible approval summary lost exact empty/spaced command arguments.'
                assert command['state'] == 'pending' and read('runs.get', {'id': command['runId']})['state'] == 'pending_approval', 'Summary verification must not execute the pending command.'

        def draft():
            page('settings')
            browser('wait', '#setting-analysis')
            before = value('document.querySelector("#setting-analysis").checked')
            persisted = read('settings.get')['analysisEnabled']
            click('#setting-analysis')
            focused = value('document.activeElement.id')
            received = value('window.__velaUITest.refreshReceived')
            revision = json.loads(urllib.request.urlopen(url + '__events').read())['revision']
            source = Path(fixture['sessionRoot']) / 'claude/harbor-0.jsonl'
            with source.open('a') as output:
                output.write(json.dumps({'type': 'user', 'uuid': uuid.uuid4().hex, 'message': {'role': 'user', 'content': 'Keep this synthetic event separate from the settings draft.'}}) + '\n')
                output.flush()
                os.fsync(output.fileno())
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline and json.loads(urllib.request.urlopen(url + '__events').read())['revision'] <= revision:
                time.sleep(0.15)
            assert json.loads(urllib.request.urlopen(url + '__events').read())['revision'] > revision, 'No real FSEvents update observed.'
            wait_for(f'window.__velaUITest.refreshReceived>{received} && window.__velaUITest.dashboardEvent>{received}', 'Renderer did not receive the event and resolve a subsequent real dashboard refresh.')
            browser('eval', 'new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))')
            assert value('document.querySelector("#setting-analysis").checked') != before, 'Data update discarded settings draft.'
            assert value('document.activeElement.id') == focused, 'Data update changed input focus.'
            assert read('settings.get')['analysisEnabled'] == persisted, 'An unsaved draft was unexpectedly persisted.'
            assert '数据已刷新' not in value('document.querySelector("#toast-container").textContent'), 'Automatic event produced refresh noise.'

        def keyboard():
            page('agents')
            click('#btn-quick-search')
            browser('press', 'Tab')
            assert value('document.querySelector("#modal-container").contains(document.activeElement)'), 'Modal lost keyboard focus.'
            browser('press', 'Escape')
            assert value('document.querySelector("#modal-container").classList.contains("hidden")'), 'Escape did not close search.'
            assert value('document.activeElement.id') == 'btn-quick-search', 'Search did not restore focus.'

        def rapid_navigation():
            count = value('window.__velaUITest.controlledReads')
            browser('eval', 'window.__velaUITest.nextRead={method:"usage.get",delay:1800}')
            page('usage')
            page('agents')
            wait_for(f'window.__velaUITest.controlledReads>{count}', 'Delayed real usage request was not exercised.')
            browser('eval', 'new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))')
            assert value('document.querySelector(".nav-link.active").dataset.page') == 'agents', 'Late read changed active navigation.'
            assert value('!!document.querySelector("#session-search-input")?.getClientRects().length'), 'Late read replaced the session page body.'

        def live_detail():
            page('agents')
            source = Path(fixture['sessionRoot']) / 'claude/harbor-0.jsonl'
            item = next(s for s in read('sessions.list') if s.get('sourcePath') == str(source))
            click('.session-title-btn[data-id="' + item['id'] + '"]')
            marker = 'Live renderer evidence ' + uuid.uuid4().hex[:8]

            def append(messages):
                with source.open('a') as output:
                    for content in messages:
                        output.write(json.dumps({'type': 'user', 'uuid': uuid.uuid4().hex,
                            'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                            'message': {'role': 'user', 'content': content}}) + '\n')
                    output.flush()
                    os.fsync(output.fileno())

            append([marker + f' history {i}\n' + ('Synthetic history remains readable while new messages arrive.\n' * 24) for i in range(6)])
            wait_for('document.querySelector("#drawer-content").textContent.includes(' + json.dumps(marker + ' history 5') + ')', 'Open session did not receive new real log messages.')
            assert value('document.querySelector("#drawer-content").scrollHeight > document.querySelector("#drawer-content").clientHeight + 200'), 'Fixture did not create a scrollable history.'
            browser('eval', 'document.querySelector("#drawer-content").scrollTop=50')
            before = value('document.querySelector("#drawer-content").scrollTop')
            append([marker + ' newest message'])
            wait_for('document.querySelector("#drawer-content").textContent.includes(' + json.dumps(marker + ' newest message') + ')', 'Subsequent real message did not arrive in the open detail.')
            assert not value('document.querySelector("#detail-drawer").classList.contains("hidden")'), 'New message closed the detail.'
            assert abs(value('document.querySelector("#drawer-content").scrollTop') - before) < 24, 'New message moved the reader away from history.'

        def notify(detail):
            # Native event payload injection only; every resulting business read uses the real CLI.
            browser('eval', 'window.dispatchEvent(new CustomEvent("vela:notificationRoute",{detail:' + json.dumps(detail) + '}))')

        def visible_approval(identifier):
            selector = '.btn-approve-appr[data-id="' + identifier + '"]'
            return '!!document.querySelector(' + json.dumps(selector) + ')?.getClientRects().length'

        def harbor_inbox():
            page('inbox')
            before = value('window.__velaUITest.dashboardResolved')
            browser('select', '#project-selector', str(project))
            wait_for(f'window.__velaUITest.dashboardResolved>{before} && window.__velaUITest.dashboardProject===' + json.dumps(str(project)), 'Harbor dashboard did not resolve after changing scope.')
            browser('eval', 'new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))')
            wait_for(visible_approval(harbor_approval), 'Harbor approval did not load in its own project.')
            assert not value(visible_approval(fixture['routingApproval'])), 'Another project leaked into Harbor Inbox.'

        def routing():
            harbor_inbox()
            notify({'source': 'approval', 'sources': ['approval'], 'recordID': fixture['routingApproval'],
                    'project': fixture['routingProject'], 'kind': 'approval', 'count': 1,
                    'spansProjects': False, 'isAggregate': False})
            wait_for(visible_approval(fixture['routingApproval']), 'Notification did not load Beacon approval.')
            assert not value(visible_approval(harbor_approval)), 'Beacon Inbox still displays Harbor approval.'
            assert value('document.querySelector("#project-selector").value') == fixture['routingProject']
            assert value('document.querySelector(".nav-link.active").dataset.page') == 'inbox'

        def routing_failure():
            harbor_inbox()
            count = value('window.__velaUITest.controlledReads')
            browser('eval', 'window.__velaUITest.nextRead=' + json.dumps({'method': 'dashboard.get', 'project': fixture['routingProject'], 'fail': True}))
            notify({'source': 'approval', 'recordID': fixture['routingApproval'], 'project': fixture['routingProject'], 'kind': 'approval', 'count': 1})
            wait_for(f'window.__velaUITest.controlledReads>{count}', 'Test read failure was not applied to the target project.')
            wait_for('!!document.querySelector("#global-error")?.getClientRects().length', 'Failed route did not show an explicit error.')
            assert not value(visible_approval(harbor_approval)), 'Failed project switch displays an old project approval.'
            assert not value(visible_approval(fixture['routingApproval'])), 'Failed route continued to render its target.'
            page('workflows')
            assert value('!!document.querySelector("#btn-retry-scope")?.getClientRects().length'), 'Sidebar navigation discarded the unresolved project-scope error.'
            assert not value('!!document.querySelector(".btn-wf-run")?.getClientRects().length'), 'Sidebar navigation reused workflow records after a failed project switch.'

        def routing_unknown():
            notify({'source': 'approval', 'recordID': '', 'project': str(base / 'Removed'), 'kind': 'approval', 'count': 1})
            wait_for(visible_approval(harbor_approval) + ' && ' + visible_approval(fixture['routingApproval']), 'Unknown project did not fall back to the global Inbox.')
            assert value('document.querySelector("#project-selector").value') == ''
            assert value('document.querySelector(".nav-link.active").dataset.page') == 'inbox'

        def routing_aggregate():
            def route_and_wait(detail):
                before = value('window.__velaUITest.dashboardResolved')
                notify(detail)
                wait_for(f'window.__velaUITest.dashboardResolved>{before} && window.__velaUITest.dashboardProject===' + json.dumps(detail['project']), 'Aggregate did not refresh its explicit project scope.')
                browser('eval', 'new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))')

            route_and_wait({'source': 'session', 'sources': ['session'], 'recordID': '', 'project': str(project),
                            'kind': 'completed', 'count': 2, 'isAggregate': True, 'spansProjects': False})
            wait_for('document.querySelector(".nav-link.active").dataset.page==="agents" && !!document.querySelector("#session-search-input")', 'Same-project aggregate did not open the session list.')
            assert value('document.querySelector("#project-selector").value') == str(project), 'Same-project aggregate unnecessarily widened scope.'
            assert value('document.querySelector("#detail-drawer").classList.contains("hidden")'), 'Aggregate opened a representative record.'

            route_and_wait({'source': 'approval', 'sources': ['approval'], 'recordID': '', 'project': '',
                            'kind': 'approval', 'count': 2, 'isAggregate': True, 'spansProjects': True})
            wait_for(visible_approval(harbor_approval) + ' && ' + visible_approval(fixture['routingApproval']), 'Cross-project aggregate did not expose both projects in the global Inbox.')
            assert value('document.querySelector("#project-selector").value') == ''

            mapping = {'session': 'agents', 'run': 'workflows', 'approval': 'inbox'}
            for target, sources in [('agents', ['session', 'run']), ('workflows', ['session', 'run']), ('inbox', ['approval', 'run'])]:
                route_and_wait({'source': 'mixed', 'sources': sources, 'recordID': '', 'project': '',
                                'kind': 'completed', 'count': 2, 'isAggregate': True, 'spansProjects': True})
                wait_for('!document.querySelector("#modal-container").classList.contains("hidden")', 'Mixed aggregate did not offer a source choice.')
                assert sorted(value('Array.from(document.querySelectorAll(".btn-choice-agg")).map(b=>b.dataset.target)')) == sorted(mapping[source] for source in sources), 'Mixed aggregate invented or omitted a source category.'
                click('.btn-choice-agg[data-target="' + target + '"]')
                wait_for('document.querySelector(".nav-link.active").dataset.page===' + json.dumps(target), 'Mixed aggregate choice did not activate its category.')
                assert value('document.querySelector("#project-selector").value') == ''
                assert value('document.querySelector("#detail-drawer").classList.contains("hidden")'), 'Mixed aggregate opened a representative record.'
                expected = {'agents': '#session-search-input', 'workflows': '#btn-new-workflow', 'inbox': '.btn-approve-appr'}[target]
                wait_for('!!document.querySelector(' + json.dumps(expected) + ')?.getClientRects().length', 'Mixed aggregate category did not render its real records.')

        for name, action in [('filtering', filtering), ('setup', setup), ('memory', memory), ('workflow', workflow), ('draft', draft), ('keyboard', keyboard)]:
            check(name, action)
        check('rapid-navigation', rapid_navigation)
        check('live-detail', live_detail)
        if fixture.get('routingProject'):
            # inbox.list is global by contract; dashboard.get supplies project-scoped renderer data.
            harbor_approval = next(a['id'] for a in read('inbox.list') if a.get('project') == str(project) and a.get('state') == 'pending')
            assert harbor_approval != fixture['routingApproval'], 'Cross-project routing requires two distinct real approvals.'
            for name, action in [('routing', routing), ('routing-failure', routing_failure), ('routing-unknown', routing_unknown), ('routing-aggregate', routing_aggregate)]:
                check(name, action)
        report.write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
        source_after = source_hashes()
        unchanged = source_before == source_after
        metadata.update(sourceAfter=source_after, sourceUnchanged=unchanged,
                        completeSuite=not selected_checks and len(results) == 12 and unchanged and all(result['passed'] for result in results))
        metadata_path.write_text(json.dumps(metadata, indent=2) + '\n')
        if not unchanged:
            raise RuntimeError('UI or helper changed during the run; this is not a single-version acceptance result.')
        if not results:
            raise RuntimeError('No checks ran. Routing checks require --with-routing-project when creating the fixture.')
        if not all(result['passed'] for result in results):
            raise SystemExit(1)
    finally:
        try:
            browser('close')
        finally:
            if direct_driver and direct_driver.poll() is None:
                os.killpg(direct_driver.pid, signal.SIGTERM)
                direct_driver.wait(timeout=5)
            server.terminate()
            server.wait(timeout=10)


if __name__ == '__main__':
    main()
