"""Verify Ask consumer contracts using frozen UI, a real CLI, and a fake provider.

Default expectations require correct behavior and fail on missing frozen input,
stale history responses replacing a draft, or dropped follow-up source scope.
--expectations known-bugs is an explicit pre-fix diagnostic, never a product PASS.
All RPC payloads and results are real. Only delivery of one ask.list is held.
No external model, real credentials, connector, or daemon lifecycle is invoked.
The script creates and removes only its NEW synthetic fixture; evidence remains.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import time
import traceback
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
UI_FILES = ('app.js', 'i18n.js', 'app.css', 'index.html', 'app-icon.svg', 'demo.js')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ui-directory', type=Path, required=True, help='UI directory to copy byte-for-byte into the new isolated fixture; frozen copies supported.')
    parser.add_argument('--binary', type=Path, required=True, help='Already built helper; copied and SHA256 recorded before testing.')
    parser.add_argument('--fixture', type=Path, required=True, help='NEW directory under repository .task-tmp; removed in finally.')
    parser.add_argument('--output', type=Path, required=True, help='NEW evidence directory under repository output/playwright; retained.')
    parser.add_argument('--expectations', choices=('correct', 'known-bugs'), default='correct')
    parser.add_argument('--browser-executable', type=Path, help='Optional explicit browser executable; omit to use installed Playwright Chromium.')
    args = parser.parse_args()
    ui_source, binary_source = args.ui_directory.resolve(strict=True), args.binary.resolve(strict=True)
    base, output = args.fixture.absolute(), args.output.absolute()
    if base.exists() or base.is_symlink() or base.resolve().parent != (ROOT / '.task-tmp').resolve():
        parser.error('--fixture must be a new immediate child of repository .task-tmp.')
    if output.exists() or output.is_symlink() or not output.resolve().is_relative_to((ROOT / 'output/playwright').resolve()):
        parser.error('--output must be a new directory under repository output/playwright.')
    if not ui_source.is_dir() or not binary_source.is_file() or (args.browser_executable and not args.browser_executable.is_file()):
        parser.error('UI, helper and browser must already exist; this test installs nothing.')
    for name in UI_FILES:
        if not (ui_source / name).is_file() or (ui_source / name).is_symlink():
            parser.error('UI allowlist file is missing or symlinked: ' + name)
    output.mkdir(parents=True)
    results = []
    evidence = {
        'format': 'vela-ask-consumer-contracts-v2', 'synthetic': True,
        'expectations': args.expectations, 'checks': results,
        'sourceDirectory': str(ui_source), 'fixtureDirectory': str(base),
        'realProviderExecuted': False, 'syntheticProviderProcess': True,
        'nativeDialogsTested': False, 'completeSuite': False,
        'browserExecutable': str(args.browser_executable) if args.browser_executable else 'playwright.chromium',
        'testScriptSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'bridgeSHA256': hashlib.sha256((ROOT / 'scripts/test-ui-server.py').read_bytes()).hexdigest(),
    }
    server = driver = None
    fixture_created = False

    def source_hashes(directory):
        return {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in UI_FILES}

    def save():
        (output / 'results.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')

    def browser(*arguments):
        driver.stdin.write(json.dumps(arguments) + '\n')
        driver.stdin.flush()
        assert select.select([driver.stdout], [], [], 20)[0], 'Browser response timed out'
        reply = json.loads(driver.stdout.readline())
        assert 'error' not in reply, reply
        return reply.get('output', '')

    def value(js):
        return json.loads(browser('eval', js))

    def wait(js, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if value(js):
                return
            time.sleep(.05)
        raise AssertionError('UI did not settle: ' + js)

    def click(selector):
        browser('snapshot', '-i')
        browser('click', selector)
        browser('snapshot', '-i')

    def rpc(method, params):
        request = urllib.request.Request(url + '__rpc', json.dumps({'method': method, 'params': params}).encode(),
                                        {'Content-Type': 'application/json', 'Origin': 'http://' + url.split('/')[2]})
        with urllib.request.urlopen(request, timeout=25) as response:
            result = json.load(response)
        assert 'error' not in result, result
        return result['result']

    def events():
        return [json.loads(line) for line in (base / 'harness-rpc.jsonl').read_text().splitlines()]

    def record(name, correct, known_bug, details):
        row = {'name': name, 'correctBehavior': bool(correct), 'bugReproduced': bool(known_bug),
               'passed': bool(correct if args.expectations == 'correct' else known_bug), **details}
        results.append(row)
        browser('screenshot', str(output / (name + '.png')))
        (output / (name + '.txt')).write_text(browser('snapshot', '-i'))
        print(json.dumps(row, ensure_ascii=False), flush=True)
        save()

    try:
        evidence['sourceBefore'] = source_hashes(ui_source)
        evidence['helperSourceSHA256'] = hashlib.sha256(binary_source.read_bytes()).hexdigest()
        subprocess.run(['python3', str(ROOT / 'scripts/create-ui-fixture.py'), str(base), '--binary', str(binary_source)],
                       check=True, capture_output=True, text=True, timeout=60)
        fixture_created = True
        fixture = json.loads((base / 'fixture.json').read_text())
        assert fixture['synthetic'] is True
        project = fixture['project']
        ui = base / 'ui-snapshot'
        ui.mkdir()
        for name in UI_FILES:
            shutil.copyfile(ui_source / name, ui / name)
        binary = base / 'vela-frozen'
        shutil.copy2(binary_source, binary)
        provider = base / 'synthetic-codex'
        shutil.copyfile(ROOT / 'scripts/ui-fixture-provider.py', provider)
        provider.chmod(0o700)
        evidence['fixtureSourceBefore'] = source_hashes(ui)
        evidence['helperSHA256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
        assert evidence['sourceBefore'] == evidence['fixtureSourceBefore'], 'Source changed during copy'
        assert evidence['helperSourceSHA256'] == evidence['helperSHA256'], 'Helper changed during copy'
        native = ROOT / 'Sources/VelaApp/main.swift'
        evidence['nativeAllowlistSHA256'] = hashlib.sha256(native.read_bytes()).hexdigest()
        methods = ('ask.get', 'ask.list', 'ask.followup', 'approvals.decide')
        evidence['nativeAllowlistIncludesMethods'] = all(('"' + method + '"') in native.read_text() for method in methods)
        assert evidence['nativeAllowlistIncludesMethods'], 'Required RPC missing from native allowlist'
        spec = importlib.util.spec_from_file_location('vela_browser_driver', ROOT / 'scripts/test-ui-browser.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        server = subprocess.Popen(['python3', str(ROOT / 'scripts/test-ui-server.py'), str(base / 'fixture.json'),
                                   '--binary', str(binary), '--ui-directory', str(ui)], stdout=subprocess.PIPE, text=True)
        assert select.select([server.stdout], [], [], 15)[0], 'Fixture server did not start'
        url = json.loads(server.stdout.readline())['url']
        driver = subprocess.Popen(['node', '-e', module.PLAYWRIGHT_DRIVER,
                                   str(ROOT / '.task-tmp/ui-browser-tools/node_modules/playwright/index.js'),
                                   str(args.browser_executable or '')], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True, start_new_session=True)
        browser('open', url)
        browser('wait', '#project-selector')
        browser('snapshot', '-i')
        browser('select', '#project-selector', project)
        wait('document.querySelector("#project-selector").value===' + json.dumps(project))
        rpc('library.add', {'project': project, 'title': 'Consumer review source',
                           'content': 'A Harbor release requires passing the focused parser tests.', 'private': False})
        pending = rpc('ask.create', {'project': project, 'question': 'What is the Harbor release policy?',
                                    'searchQuery': 'Harbor', 'branch': 'review/ask-scope',
                                    'executable': str(provider), 'model': 'synthetic-ui', 'effort': 'low',
                                    'timeoutSeconds': 47, 'maxSources': 2, 'maxSourceBytes': 2000})
        ask = rpc('ask.get', {'project': project, 'id': pending['id']})
        assert ask['state'] == 'pending_approval' and ask['request']['scope'] == {'branch': 'review/ask-scope'}
        (output / 'pending-real-cli.json').write_text(json.dumps(ask, ensure_ascii=False, indent=2) + '\n')
        click('.nav-link[data-page="memory"]')
        browser('wait', '#btn-knowledge-ask')
        click('#btn-knowledge-ask')
        wait('!!document.querySelector("#ask-question-input")')
        value("window.__consumerOriginalCall=window.vela.call;window.__consumerDelayNext=true;window.__consumerHeld=false;window.__consumerDelivered=false;window.vela.call=async(method,params)=>{const hold=method==='ask.list'&&window.__consumerDelayNext;if(hold)window.__consumerDelayNext=false;const result=await window.__consumerOriginalCall(method,params);if(hold){window.__consumerHeld=true;await new Promise(resolve=>window.__consumerRelease=resolve);window.__consumerDelivered=true;}return result};true")
        click('#tab-ask-history')
        wait('window.__consumerHeld===true')
        click('#tab-ask-new')
        browser('fill', '#ask-question-input', 'UNSAVED consumer question')
        value('window.__consumerRelease();true')
        wait('window.__consumerDelivered===true')
        ui_state = value("({newActive:document.querySelector('#tab-ask-new').classList.contains('active'),draft:document.querySelector('#ask-question-input')?.value??null,historyRows:!!document.querySelector('.btn-open-ask-row'),submitVisible:document.querySelector('#btn-submit-ask').style.display!=='none'})")
        correct = ui_state['newActive'] and ui_state['draft'] == 'UNSAVED consumer question' and not ui_state['historyRows'] and ui_state['submitVisible']
        known_bug = ui_state['newActive'] and ui_state['draft'] is None and ui_state['historyRows'] and ui_state['submitVisible']
        record('history-return-preserves-new-input', correct, known_bug,
               {'actualReadMethod': 'ask.list', 'payloadMocked': False, 'actualUI': ui_state})

        # Select History again explicitly. This works whether the first check
        # passed or failed, so a stale-tab failure cannot hide the other checks.
        click('#tab-ask-history')
        wait('!!document.querySelector(".btn-open-ask-row")')
        click('.btn-open-ask-row[data-id="' + ask['id'] + '"]')
        wait('!!document.querySelector("#btn-approve-ask")')
        value('document.querySelectorAll("#modal-body details").forEach(element=>element.open=true);true')
        body = value('document.querySelector("#modal-body").textContent')
        request = ask['request']
        expected = {
            'sourceExcerpt': request['sources'][0]['content'],
            'executable': request['agent']['executable'],
            'requestedModel': request['agent']['model'],
            'reasoningEffort': request['agent']['reasoningEffort'],
            'scope': request['scope']['branch'],
            'timeoutSeconds': str(request['timeoutSeconds']),
        }
        fields = {key: text in body for key, text in expected.items()}
        # A UUID, timestamp or source body containing the digits 47 is not a
        # rendered timeout control. Require its label and a standalone value.
        fields['timeoutSeconds'] = re.search(r'(?:timeout(?:Seconds)?|超时|时间上限)[^\n]{0,80}(?<!\d)47(?!\d)', body, re.IGNORECASE) is not None
        review_usable = all(fields.values()) and value('!document.querySelector("#btn-approve-ask").disabled')
        incomplete = not all(fields.values()) and value('!document.querySelector("#btn-approve-ask").disabled')
        record('approval-reviews-frozen-input', review_usable, incomplete,
               {'fieldsPresentAfterExpandingDetails': fields, 'approvalId': ask['approval']['id'],
                'sourceExcerptExistsInActualCLI': True, 'expectedTimeoutSeconds': request['timeoutSeconds']})

        # Only the byte-pinned, network-free provider can execute through the
        # harness. One approved synthetic first answer establishes a real scope.
        click('#btn-approve-ask')
        wait('!!document.querySelector("#btn-followup-ask")', 20)
        answered = rpc('ask.get', {'project': project, 'id': ask['id']})
        assert answered['state'] == 'answered'
        click('#btn-followup-ask')
        browser('fill', '#ask-followup-input', 'Harbor')
        click('#btn-submit-followup')
        wait("!document.querySelector('#btn-submit-followup') || !document.querySelector('#btn-submit-followup').disabled")
        follow = next(event for event in reversed(events()) if event['method'] == 'ask.followup')
        queries = rpc('ask.list', {'project': project})
        new_queries = [query for query in queries if query['id'] != ask['id']]
        child = rpc('ask.get', {'project': project, 'id': new_queries[0]['id']}) if len(new_queries) == 1 else None
        actual_scope = child['request']['scope'] if child else None
        error = 'Follow-up must retain the original source scope'
        actual_error = error if value('document.body.textContent.includes(' + json.dumps(error) + ')') else None
        correct_scope = follow['ok'] and follow['params'].get('branch') == 'review/ask-scope' and child is not None and child['state'] == 'pending_approval' and actual_scope == request['scope']
        known_scope_bug = not follow['ok'] and 'branch' not in follow['params'] and actual_error == error and not new_queries
        provider_calls = len((base / 'synthetic-codex.calls.jsonl').read_text().splitlines())
        record('followup-preserves-frozen-scope', correct_scope, known_scope_bug,
               {'originalScope': request['scope'], 'actualFollowupRPC': follow,
                'actualCoreError': actual_error, 'newQueryScope': actual_scope,
                'newApprovalCreated': bool(child and child.get('approvalId')), 'syntheticProviderCalls': provider_calls})
        assert provider_calls == 1, 'The new follow-up must remain unexecuted'
        evidence['fixtureSourceAfter'] = source_hashes(ui)
        evidence['sourceAfter'] = source_hashes(ui_source)
        evidence['sourceUnchanged'] = (evidence['sourceBefore'] == evidence['sourceAfter'] ==
                                       evidence['fixtureSourceBefore'] == evidence['fixtureSourceAfter'])
        evidence['checksMatchedExpectations'] = len(results) == 3 and all(row['passed'] for row in results) and evidence['sourceUnchanged']
        evidence['completeSuite'] = args.expectations == 'correct' and evidence['checksMatchedExpectations']
    except Exception as error:
        evidence['harnessError'] = str(error)
        evidence['traceback'] = traceback.format_exc(limit=6)
        print(evidence['traceback'], flush=True)
    finally:
        if driver:
            try:
                browser('close')
            finally:
                if driver.poll() is None:
                    os.killpg(driver.pid, signal.SIGTERM)
                driver.wait(timeout=5)
        if server:
            server.terminate()
            server.wait(timeout=10)
        if fixture_created:
            if (base / 'harness-rpc.jsonl').exists():
                (output / 'rpc.jsonl').write_text((base / 'harness-rpc.jsonl').read_text())
            marker = json.loads((base / 'store/.vela-ui-fixture.json').read_text())
            assert not base.is_symlink() and base.resolve() == ROOT.resolve() / '.task-tmp' / base.name
            assert marker['synthetic'] is True and marker['manifest'] == str(base / 'fixture.json')
            removed_files = sum(1 for path in base.rglob('*') if path.is_file())
            shutil.rmtree(base)
            evidence['cleanup'] = {'removedOwnedFixture': str(base), 'removedFiles': removed_files,
                                   'browserAndServerStopped': True, 'evidenceRetained': True,
                                   'sharedDependenciesRemoved': False}
        save()
    return 0 if evidence.get('checksMatchedExpectations') and 'harnessError' not in evidence else 1


if __name__ == '__main__':
    raise SystemExit(main())
