"""Real renderer -> CLI acceptance checks using disposable synthetic records.

Requires Python 3.9+, Node.js 20+ and Playwright 1.62.1:
  npm install --prefix .task-tmp/ui-browser-tools --registry=https://registry.npmjs.org --save-exact playwright@1.62.1
  node .task-tmp/ui-browser-tools/node_modules/playwright/cli.js install chromium
  swift build
  python3 scripts/test-acceptance-browser.py

Omit --browser-executable for Playwright's installed Chromium (recommended in CI).
For local installed Chrome, pass --browser-executable "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome".

The default .task-tmp/acceptance-flow-qa directory MUST NOT exist. No provider
task, OS notification or trusted Codex hook is executed. Lab only creates frozen
pending approvals; test-ui-server refuses lab.execute. Reuse writes are limited
to the generated Harbor project. Successful fixtures are removed after evidence
is copied to output/playwright; failed fixtures remain for diagnosis.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import select
import shlex
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CHECKS = ['memory-lifecycle', 'exact-source', 'cross-project-source', 'lab-frozen-approval', 'reuse-apply-undo', 'usage-missing']


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--fixture', type=Path, default=ROOT / '.task-tmp/acceptance-flow-qa')
    parser.add_argument('--output', type=Path, default=ROOT / 'output/playwright/acceptance-flow-qa')
    parser.add_argument('--binary', type=Path, default=ROOT / '.build/debug/vela')
    parser.add_argument('--playwright-module', type=Path, default=ROOT / '.task-tmp/ui-browser-tools/node_modules/playwright/index.js')
    parser.add_argument('--browser-executable', type=Path, help='Optional installed Chrome path; omitted uses Playwright Chromium.')
    parser.add_argument('--keep-fixture', action='store_true')
    parser.add_argument('--checks', help='Diagnostic subset only; omit for all six checks. Use separate NEW fixture/output paths.')
    args = parser.parse_args()
    selected = set(args.checks.split(',')) if args.checks else set(CHECKS)
    if not selected or not selected <= set(CHECKS):
        parser.error('Unknown or empty checks subset.')
    base, output, binary = args.fixture.absolute(), args.output.absolute(), args.binary.resolve(strict=True)
    if base.exists() or base.is_symlink() or not base.resolve().is_relative_to((ROOT / '.task-tmp').resolve()):
        parser.error('Choose a NEW fixture below repository .task-tmp.')
    if output.exists() or not output.resolve().is_relative_to((ROOT / 'output/playwright').resolve()):
        parser.error('Choose a NEW evidence directory below output/playwright.')
    if not shutil.which('node') or not args.playwright_module.is_file() or (args.browser_executable and not args.browser_executable.is_file()):
        parser.error('Install the documented dependencies; this script never installs tools automatically.')
    output.mkdir(parents=True)
    subprocess.run(['python3', str(ROOT / 'scripts/create-ui-fixture.py'), str(base), '--binary', str(binary),
                    '--with-routing-project'], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)
    fixture = json.loads((base / 'fixture.json').read_text())
    harbor, beacon = fixture['project'], fixture['routingProject']
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
    sources = Path(fixture['sessionRoot']) / 'codex'

    def log(name, project, source, message, content):
        rows = [{'type': 'session_meta', 'timestamp': stamp, 'payload': {'id': source, 'cwd': project}},
                {'type': 'response_item', 'timestamp': stamp, 'payload': {'id': message, 'type': 'message',
                 'role': 'user', 'content': [{'type': 'input_text', 'text': content}]}}]
        (sources / name).write_text(''.join(json.dumps(row) + '\n' for row in rows))

    for i in range(3):
        log(f'acceptance-constraint-{i}.jsonl', harbor, f'acceptance-constraint-{i}', f'constraint-message-{i}',
            '以后完成任务之前一定先跑测试')
    log('acceptance-harbor-collision.jsonl', harbor, 'acceptance-shared-provider-id', 'harbor-exact-message',
        'Harbor exact source marker; keep this message distinct.')
    log('acceptance-beacon-collision.jsonl', beacon, 'acceptance-shared-provider-id', 'beacon-exact-message',
        'Beacon exact source marker; no provider usage was supplied.')
    hook = Path(harbor) / '.codex/hooks.json'
    hook.parent.mkdir(exist_ok=True)
    hook_before = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/false"}]}]}}\n'
    hook.write_text(hook_before)

    # Reuse the already reviewed isolated Playwright transport, not product demo.js.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('vela_ui_browser', ROOT / 'scripts/test-ui-browser.py')
    transport = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(transport)
    server = subprocess.Popen(['python3', str(ROOT / 'scripts/test-ui-server.py'), str(base / 'fixture.json'),
                               '--binary', str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    driver_source = '// Vela acceptance fixture: ' + json.dumps(str(base)) + '\n' + transport.PLAYWRIGHT_DRIVER
    driver_source = driver_source.replace('  }\n})().catch', '  }\n  await browser.close();\n})().catch')
    driver = subprocess.Popen(['node', '-e', driver_source, str(args.playwright_module.resolve()),
                               str(args.browser_executable or '')], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, start_new_session=True)
    results = []
    evidence = {'format': 'vela-browser-acceptance-v1', 'synthetic': True,
        'startedAt': stamp, 'platform': platform.platform(),
        'playwrightVersion': json.loads((args.playwright_module.resolve().parent / 'package.json').read_text())['version'],
        'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'uiSHA256': {name: hashlib.sha256((ROOT / 'Sources/VelaApp/Resources/UI' / name).read_bytes()).hexdigest()
                     for name in ('app.js', 'app.css', 'index.html')},
        'realProviderExecuted': False, 'nativeIntegrationTested': False, 'fullGoldenScenarioPassed': False,
        'requestedChecks': [name for name in CHECKS if name in selected], 'completeSuite': False, 'checks': results}

    def browser(*commands):
        driver.stdin.write(json.dumps(commands) + '\n'); driver.stdin.flush()
        if not select.select([driver.stdout], [], [], 15)[0]:
            raise TimeoutError('Isolated Playwright driver did not respond.')
        response = json.loads(driver.stdout.readline())
        if 'error' in response:
            raise AssertionError(response['error'])
        return response['output']

    def value(expression):
        return json.loads(browser('eval', expression))

    def wait_for(expression, reason):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if value(expression):
                return
            time.sleep(.1)
        raise AssertionError(reason)

    def rpc(method, params=None):
        request = urllib.request.Request(url + '__rpc', json.dumps({'method': method, 'params': params or {}}).encode(),
            {'Content-Type': 'application/json', 'Origin': url.split('/', 3)[0] + '//' + url.split('/')[2]})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                data = json.load(response)
        except urllib.error.HTTPError as error:
            raise AssertionError(json.load(error)['error']) from error
        if 'error' in data:
            raise AssertionError(data['error'])
        return data['result']

    def click(selector):
        browser('click', selector)

    def page(name, project=harbor):
        browser('press', 'Escape'); browser('press', 'Escape')
        if value('document.querySelector("#project-selector").value') != project:
            previous = value('window.__velaUITest.dashboardResolved')
            browser('select', '#project-selector', project)
            wait_for('window.__velaUITest.dashboardResolved>' + str(previous) + '&&window.__velaUITest.dashboardProject===' + json.dumps(project), 'Scope RPC has not resolved.')
        click('.nav-link[data-page=' + json.dumps(name) + ']')
        wait_for('document.querySelector(".nav-link.active")?.dataset.page===' + json.dumps(name), 'Navigation differs from visible page.')
        browser('snapshot', '-i')

    def cards():
        return value('Array.from(document.querySelectorAll(".memory-card[data-id]")).map(el=>el.dataset.id).sort()')

    def record(name, action):
        if name not in selected:
            return
        try:
            detail = action()
            result = {'check': name, 'passed': True, 'detail': detail}
        except Exception as error:
            result = {'check': name, 'passed': False, 'error': str(error)}
        results.append(result)
        try:
            browser('screenshot', str(output / (name + '.png')))
            (output / (name + '.txt')).write_text(browser('snapshot', '-i'))
            result['screenshot'] = name + '.png'
        except Exception as error:
            result['captureError'] = str(error)
        (output / 'results.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False), flush=True)

    try:
        if not select.select([server.stdout], [], [], 15)[0]:
            raise RuntimeError('Fixture server did not start.')
        url = json.loads(server.stdout.readline())['url']
        rpc('sessions.refresh')
        sessions = rpc('sessions.list')
        source = next(s for s in sessions if s['project'] == harbor and s.get('sourceSessionId') == 'acceptance-shared-provider-id')
        foreign = next(s for s in sessions if s['project'] == beacon and s.get('sourceSessionId') == 'acceptance-shared-provider-id')
        memories = {}
        for state in ['candidate', 'active', 'superseded', 'archived']:
            memory = rpc('memory.save', {'project': harbor, 'scope': 'project', 'title': 'Acceptance ' + state,
                'content': 'Fixture lifecycle state: ' + state, 'sourceSession': source['id'],
                'sourceMessage': 'harbor-exact-message'})
            if state in ('active', 'superseded'):
                memory = rpc('memory.transition', {'id': memory['id'], 'state': 'active'})
            if state in ('superseded', 'archived'):
                memory = rpc('memory.transition', {'id': memory['id'], 'state': state})
            memories[state] = memory
        cross_memory = rpc('memory.save', {'project': beacon, 'scope': 'project', 'title': 'Beacon precise source',
            'content': 'Same native provider ID; different project and exact message.', 'sourceSession': foreign['id'],
            'sourceMessage': 'beacon-exact-message'})
        analysis = rpc('improve.analyze', {'project': harbor})
        suggestion = next(s for s in rpc('improve.list', {'project': harbor}) if s.get('verificationCandidateMemoryIds'))
        assert set(suggestion['verificationCandidateMemoryIds']) <= {m['id'] for m in analysis['candidateMemories']}
        browser('open', url); browser('wait', '#session-search-input')
        evidence['browserUserAgent'] = value('navigator.userAgent')

        def lifecycle():
            page('memory')
            actual = rpc('memory.list', {'project': harbor})
            for state in ['all', 'candidate', 'active', 'superseded', 'archived']:
                click('.memory-filter-btn[data-filter=' + json.dumps(state) + ']')
                expected = sorted(m['id'] for m in actual if state == 'all' or m['state'].lower() == state)
                assert cards() == expected, 'Visible Memory cards do not match persisted lifecycle: ' + state
            click('.memory-filter-btn[data-filter="candidate"]')
            click('.btn-mem-activate[data-id=' + json.dumps(memories['candidate']['id']) + ']')
            wait_for('!document.querySelector(".btn-mem-activate[data-id=\\"' + memories['candidate']['id'] + '\\"]")', 'Activation did not leave Candidate filter.')
            assert next(m for m in rpc('memory.list', {'project': harbor}) if m['id'] == memories['candidate']['id'])['state'] == 'active'
            return {'statesChecked': 5, 'transition': 'candidate→active'}

        def exact_source():
            page('memory')
            click('.memory-filter-btn[data-filter="all"]')
            selector = '.memory-card[data-id=' + json.dumps(memories['active']['id']) + '] .btn-open-source'
            click(selector)
            wait_for('!!document.querySelector("[data-message-id=\\"harbor-exact-message\\"].message-highlight")', 'Exact source message was not highlighted.')
            assert value('document.querySelector("#project-selector").value') == harbor
            assert value('document.querySelector("#drawer-content").innerText.includes("Harbor exact source marker")')
            return {'sessionId': source['id'], 'messageId': 'harbor-exact-message'}

        def cross_source():
            page('memory', '')
            click('.memory-filter-btn[data-filter="all"]')
            click('.memory-card[data-id=' + json.dumps(cross_memory['id']) + '] .btn-open-source')
            wait_for('!!document.querySelector("[data-message-id=\\"beacon-exact-message\\"].message-highlight")', 'Cross-project source resolved the wrong message.')
            assert value('document.querySelector("#project-selector").value') == beacon
            assert not value('document.querySelector("#drawer-content").innerText.includes("Harbor exact source marker")')
            return {'providerIdCollision': True, 'correctProject': 'Beacon', 'sessionId': foreign['id']}

        def lab_freeze():
            page('improve')
            click('.btn-test-sug[data-id=' + json.dumps(suggestion['id']) + ']')
            browser('wait', '#lab-agent-task')
            assert value('document.querySelector("#lab-agent-source-sug").value') == suggestion['id']
            frozen_argv = ['/usr/bin/printf', '', 'argument with spaces', 'quote"argument']
            task = 'Synthetic pending-only acceptance; do not execute any provider task.'
            memory_id = suggestion['verificationCandidateMemoryIds'][0]
            memory = next(m for m in rpc('memory.list', {'project': harbor}) if m['id'] == memory_id)
            for selector, content in {
                '#lab-agent-title': 'Acceptance pending-only Agent comparison',
                '#lab-agent-model': 'fixture-no-provider-execution',
                '#lab-agent-task': task, '#lab-agent-verify-cmd': json.dumps(frozen_argv),
                '#lab-agent-verify-files': 'tests/parser.test.mjs', '#lab-agent-output-files': 'src/parser.mjs',
                '#lab-agent-repetitions': '3', '#lab-agent-timeout': '10',
            }.items():
                browser('fill', selector, content)
            click('details:has(#lab-agent-candidate-json) > summary')
            browser('fill', '#lab-agent-executable', '/usr/bin/true')
            baseline = {'context': 'Literal baseline context: "quoted"; $(never-executed).'}
            candidate = {'memoryIds': [memory_id]}
            browser('fill', '#lab-agent-baseline-json', json.dumps(baseline))
            browser('fill', '#lab-agent-candidate-json', json.dumps(candidate))
            click('#btn-save-lab')
            wait_for('!document.querySelector("#btn-save-lab")', 'Real Lab form did not submit successfully.')
            evaluation = next(e for e in rpc('lab.list', {'project': harbor}) if e['title'] == 'Acceptance pending-only Agent comparison')
            assert evaluation['state'] == 'pending_approval' and evaluation['results'] == []
            assert evaluation['sourceSuggestionId'] == suggestion['id'] and evaluation['sourceRelationship'] == 'evaluates_linked_memory'
            approval = next(a for a in rpc('inbox.list') if a['id'] == evaluation['approvalId'])
            frozen = approval['arguments']
            assert frozen['task'] == task and frozen['command'] == frozen_argv
            assert frozen['baseline']['context'] == baseline['context']
            assert frozen['candidate']['memories'][0]['id'] == memory_id
            assert frozen['candidate']['context'] == memory['title'] + '\n' + memory['content']
            assert frozen['agent']['executable'] == '/usr/bin/true'
            assert [f['path'] for f in frozen['verificationFiles']] == ['tests/parser.test.mjs']
            assert frozen['outputFiles'] == ['src/parser.mjs'] and frozen['repetitions'] == 3
            # This is an intentional negative request to the test-only bridge. Core never receives it.
            try:
                rpc('approvals.decide', {'id': approval['id'], 'decision': 'approve', 'snapshotHash': approval['snapshotHash']})
                raise AssertionError('Harness permitted execution of an Agent Lab approval.')
            except AssertionError as error:
                assert 'never shell/agent tools' in str(error), str(error)
            assert rpc('lab.compare', {'id': evaluation['id']})['state'] == 'pending_approval'
            assert not (Path(fixture['home']) / 'lab-worktrees').exists()
            page('inbox')
            browser('wait', '.btn-approve-appr[data-id=' + json.dumps(approval['id']) + ']')
            frozen_display = value('document.querySelector(' + json.dumps('.btn-approve-appr[data-id="' + approval['id'] + '"]') + ').closest(".card").innerText')
            assert task in frozen_display and 'tests/parser.test.mjs' in frozen_display and 'src/parser.mjs' in frozen_display
            return {'evalId': evaluation['id'], 'approvalId': approval['id'], 'memoryId': memory_id,
                    'state': 'pending_approval', 'exactArgv': frozen_argv, 'frozenArguments': frozen,
                    'providerExecuted': False, 'harnessExecutionRefused': True}

        def usage_missing():
            page('usage', beacon)
            usage = rpc('usage.get', {'project': beacon})
            assert usage['totalTokens'] is None and usage['sessionCount'] == 1
            wait_for('/未提供|未知|不可用|未观测/.test(document.querySelector("#usage-total-tokens")?.innerText||"")', 'Missing provider usage was presented as zero or left loading.')
            body = value('document.querySelector("#usage-provider-tbody").innerText')
            assert 'codex' in body.lower() and any(word in body for word in ['未提供', '未知', '不可用', '未观测'])
            trend_titles = value('Array.from(document.querySelectorAll("#usage-daily-container [title]")).map(el=>el.title)')
            assert not any(title.rstrip().endswith(': 0 Tokens') for title in trend_titles), 'Missing daily usage was rendered as a zero-token observation.'
            browser('screenshot', str(output / 'usage-missing-only.png'))
            # Add a real explicit zero usage event to the SAME synthetic provider log.
            event = {'type': 'event_msg', 'timestamp': stamp, 'payload': {'type': 'token_count',
                     'info': {'total_token_usage': {'input_tokens': 0, 'output_tokens': 0}}}}
            with (sources / 'acceptance-beacon-collision.jsonl').open('a') as file:
                file.write(json.dumps(event) + '\n')
            rpc('sessions.refresh')
            zero = rpc('usage.get', {'project': beacon})
            assert zero['totalTokens'] == 0 and zero['sessionCount'] == 1
            wait_for('document.querySelector("#usage-total-tokens")?.innerText.trim()==="0"', 'Explicit real zero usage did not replace unavailable state.')
            return {'missingTotal': None, 'explicitTotal': 0, 'sameProviderSession': True,
                    'missingScreenshot': 'usage-missing-only.png'}

        def reuse_apply_undo():
            page('memory')
            click('#btn-configure-reuse')
            browser('select', '#reuse-project-select', harbor)
            click('#btn-preview-reuse')
            browser('wait', '#btn-drawer-apply-sug')
            draft = next(s for s in rpc('improve.list', {'project': harbor}) if s.get('generator') == 'vela-codex-hook-v1')
            assert draft['requiresProviderTrust'] is True and len(draft['operations']) == 1
            assert hook.read_text() == hook_before, 'Reuse preview wrote the Hook before explicit Apply.'
            configuration = json.loads(draft['operations'][0]['content'])
            assert configuration['hooks']['Stop'] == json.loads(hook_before)['hooks']['Stop']
            handlers = [h for group in configuration['hooks']['SessionStart'] for h in group['hooks']]
            assert len(handlers) == 1
            expected = [str(binary), 'hook', '--home', fixture['home'], '--project', harbor]
            assert shlex.split(handlers[0]['command']) == expected, 'Reuse did not freeze the actual CLI helper and fixture scope.'
            click('#btn-drawer-apply-sug')
            browser('wait', '#btn-confirm-apply')
            assert hook.read_text() == hook_before, 'The confirmation dialog itself applied the Hook.'
            click('#btn-confirm-apply')
            wait_for('document.querySelector("#modal-container").classList.contains("hidden")', 'Safe Apply did not finish.')
            assert hook.read_text() == draft['operations'][0]['content']
            page('memory')
            click('#btn-configure-reuse')
            browser('select', '#reuse-project-select', harbor)
            click('#btn-preview-reuse')
            wait_for('document.querySelector("#drawer-content")?.innerText.includes("已配置")', 'Repeated preview did not explain that the exact Hook is already installed.')
            repeated = next(s for s in rpc('improve.list', {'project': harbor}) if s.get('generator') == 'vela-codex-hook-v1' and s['id'] != draft['id'])
            assert repeated['alreadyInstalled'] is True and repeated['operations'] == []
            assert not value('!!document.querySelector("#btn-drawer-apply-sug")?.getClientRects().length'), 'Already-installed Hook offered a redundant Apply action.'
            assert hook.read_text() == draft['operations'][0]['content']
            page('improve')
            click('.btn-preview-diff[data-id=' + json.dumps(draft['id']) + ']')
            browser('wait', '#btn-drawer-undo-sug')
            text = value('document.querySelector("#drawer-content").innerText')
            assert '/hooks' in text and ('信任' in text or 'trust' in text.lower()), 'Applied Hook does not explain the remaining provider trust step.'
            browser('screenshot', str(output / 'reuse-applied-untrusted.png'))
            click('#btn-drawer-undo-sug')
            wait_for('document.querySelector("#detail-drawer").classList.contains("hidden")', 'Undo did not finish.')
            assert hook.read_text() == hook_before, 'Undo did not restore the exact previous Hook bytes.'
            return {'suggestionId': draft['id'], 'beforeSHA256': hashlib.sha256(hook_before.encode()).hexdigest(),
                    'afterSHA256': hashlib.sha256(draft['operations'][0]['content'].encode()).hexdigest(),
                    'restoredExactBytes': True, 'existingStopPreserved': True, 'providerTrustCompleted': False,
                    'repeatPreviewNoWrite': True, 'hookExecuted': False, 'appliedScreenshot': 'reuse-applied-untrusted.png'}

        for name, action in [('memory-lifecycle', lifecycle), ('exact-source', exact_source),
                             ('cross-project-source', cross_source), ('lab-frozen-approval', lab_freeze),
                             ('reuse-apply-undo', reuse_apply_undo),
                             ('usage-missing', usage_missing)]:
            record(name, action)
    finally:
        try:
            browser('close')
        finally:
            if driver.poll() is None:
                os.killpg(driver.pid, signal.SIGTERM); driver.wait(timeout=5)
            server.terminate(); server.wait(timeout=10)
            transcript = base / 'harness-rpc.jsonl'
            if transcript.exists():
                shutil.copyfile(transcript, output / 'harness-rpc.jsonl')
            evidence['cleanup'] = {'browserClosed': True, 'helperStopped': True, 'fixtureRemoved': False}
            evidence['uiSHA256After'] = {name: hashlib.sha256((ROOT / 'Sources/VelaApp/Resources/UI' / name).read_bytes()).hexdigest()
                                         for name in evidence['uiSHA256']}
            evidence['uiSourceUnchangedDuringRun'] = evidence['uiSHA256After'] == evidence['uiSHA256']
            selected_passed = {r['check'] for r in results} == selected and all(r['passed'] for r in results)
            evidence['completeSuite'] = selected == set(CHECKS) and selected_passed and evidence['uiSourceUnchangedDuringRun']
            if selected_passed and (selected != set(CHECKS) or evidence['completeSuite']) and not args.keep_fixture:
                marker = json.loads((Path(fixture['home']) / '.vela-ui-fixture.json').read_text())
                if marker['manifest'] != str(base / 'fixture.json') or not base.resolve().is_relative_to((ROOT / '.task-tmp').resolve()):
                    raise RuntimeError('Fixture ownership changed; cleanup refused.')
                shutil.rmtree(base); evidence['cleanup']['fixtureRemoved'] = True
            (output / 'results.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')
    if {r['check'] for r in results} != selected or not all(r['passed'] for r in results):
        raise SystemExit(1)
    if selected == set(CHECKS) and not evidence['completeSuite']:
        raise SystemExit('Product UI source changed during the full run; repeat after renderer freezes.')


if __name__ == '__main__':
    main()
