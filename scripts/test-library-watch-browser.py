"""Six Library/Watch user journeys against frozen UI and a real isolated helper.

Imports default private; edits use reviewed hashes; stale edits must fail; archive
and restore retain identity/privacy; explicit FTS indexing pages can be cancelled;
both Watch sources are created and previewed through UI, then toggled through UI.
The helper is launched by test-ui-server.py with --no-schedule. No system daemon,
provider, connector, network import, or workflow execution is permitted here.
--checks is a diagnostic subset and never sets completeSuite=true.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import time
import traceback
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
UI_FILES = ('app.js', 'i18n.js', 'app.css', 'index.html', 'app-icon.svg', 'demo.js')
CHECKS = ('library-private-edit', 'library-stale-review', 'library-archive-restore',
          'library-paged-index-search', 'tool-watch', 'files-watch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ui-directory', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True, help='NEW immediate child of .task-tmp; cleaned on exit.')
    parser.add_argument('--output', type=Path, required=True, help='NEW directory under output/playwright; retained.')
    parser.add_argument('--browser-executable', type=Path, help='Optional browser; omit for installed Playwright Chromium.')
    parser.add_argument('--checks', help='Comma-separated diagnostic subset; omit for all six journeys.')
    args = parser.parse_args()
    selected = set(args.checks.split(',')) if args.checks else set(CHECKS)
    if not selected or not selected <= set(CHECKS):
        parser.error('Unknown or empty check selection.')
    base, output = args.fixture.absolute(), args.output.absolute()
    ui_source, helper_source = args.ui_directory.resolve(strict=True), args.binary.resolve(strict=True)
    if base.exists() or base.is_symlink() or base.resolve().parent != (ROOT / '.task-tmp').resolve():
        parser.error('Use a new immediate child of repository .task-tmp.')
    if output.exists() or output.is_symlink() or not output.resolve().is_relative_to((ROOT / 'output/playwright').resolve()):
        parser.error('Use a new output/playwright evidence directory.')
    if args.browser_executable and not args.browser_executable.is_file():
        parser.error('Explicit browser executable is missing.')
    for name in UI_FILES:
        if not (ui_source / name).is_file() or (ui_source / name).is_symlink():
            parser.error('UI allowlist file missing or symlinked: ' + name)
    output.mkdir(parents=True)
    results = []
    evidence = {'format': 'vela-library-watch-renderer-v1', 'synthetic': True,
                'checks': results, 'selectedChecks': sorted(selected), 'completeSuite': False,
                'realProviderExecuted': False, 'workflowExecuted': False,
                'daemonLifecycleExecuted': False, 'schedulerEnabled': False,
                'sourceDirectory': str(ui_source), 'fixtureDirectory': str(base),
                'browserExecutable': str(args.browser_executable) if args.browser_executable else 'playwright.chromium',
                'testScriptSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'bridgeSHA256': hashlib.sha256((ROOT / 'scripts/test-ui-server.py').read_bytes()).hexdigest()}
    server = driver = None
    fixture_created = False

    def hashes(directory):
        return {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in UI_FILES}

    def save():
        (output / 'results.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')

    def browser(*arguments):
        driver.stdin.write(json.dumps(arguments) + '\n')
        driver.stdin.flush()
        assert select.select([driver.stdout], [], [], 20)[0], 'Browser timed out'
        reply = json.loads(driver.stdout.readline())
        assert 'error' not in reply, reply
        return reply.get('output', '')

    def value(js):
        return json.loads(browser('eval', js))

    def wait(js, reason, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if value(js):
                return
            time.sleep(.05)
        raise AssertionError(reason)

    def click(selector):
        browser('snapshot', '-i')
        browser('click', selector)
        browser('snapshot', '-i')

    def checkbox(selector, checked):
        if value('document.querySelector(' + json.dumps(selector) + ').checked') != checked:
            click(selector)

    def close():
        browser('press', 'Escape')
        browser('press', 'Escape')

    def page(name):
        close()
        click('.nav-link[data-page="' + name + '"]')
        wait('document.querySelector(".nav-link.active")?.dataset.page===' + json.dumps(name), 'Navigation did not settle')

    def library_page():
        page('setup')
        click('[data-setuptab="library"]')
        wait('!!document.querySelector("#btn-add-library")', 'Library controls absent')

    def rpc(method, params):
        request = urllib.request.Request(url + '__rpc', json.dumps({'method': method, 'params': params}).encode(),
                                        {'Content-Type': 'application/json', 'Origin': 'http://' + url.split('/')[2]})
        with urllib.request.urlopen(request, timeout=25) as response:
            data = json.load(response)
        assert 'error' not in data, data
        return data['result']

    def events():
        return [json.loads(line) for line in (base / 'harness-rpc.jsonl').read_text().splitlines()]

    def ui_calls(method):
        return value('window.__consumerReceipts.filter(item=>item.method===' + json.dumps(method) + ')')

    def check(name, body):
        if name not in selected:
            return
        try:
            detail = body() or {}
            results.append({'check': name, 'passed': True, **detail})
        except Exception as error:
            results.append({'check': name, 'passed': False, 'error': str(error), 'traceback': traceback.format_exc(limit=4)})
        browser('screenshot', str(output / (name + '.png')))
        (output / (name + '.txt')).write_text(browser('snapshot', '-i'))
        print(json.dumps(results[-1], ensure_ascii=False), flush=True)
        save()

    def library_item(identifier):
        return rpc('library.get', {'id': identifier, 'project': project})

    def wait_library_row(identifier):
        wait('!!document.querySelector(' + json.dumps('.btn-edit-library[data-id="' + identifier + '"]') + ')', 'Library row absent')

    try:
        evidence['sourceBefore'] = hashes(ui_source)
        evidence['helperSourceSHA256'] = hashlib.sha256(helper_source.read_bytes()).hexdigest()
        subprocess.run(['python3', str(ROOT / 'scripts/create-ui-fixture.py'), str(base), '--binary', str(helper_source)],
                       check=True, capture_output=True, text=True, timeout=60)
        fixture_created = True
        fixture = json.loads((base / 'fixture.json').read_text())
        assert fixture['synthetic'] is True
        project = fixture['project']
        ui = base / 'ui-snapshot'
        ui.mkdir()
        for name in UI_FILES:
            shutil.copyfile(ui_source / name, ui / name)
        helper = base / 'vela-frozen'
        shutil.copy2(helper_source, helper)
        evidence['fixtureSourceBefore'] = hashes(ui)
        evidence['helperSHA256'] = hashlib.sha256(helper.read_bytes()).hexdigest()
        assert evidence['sourceBefore'] == evidence['fixtureSourceBefore']
        assert evidence['helperSourceSHA256'] == evidence['helperSHA256']
        spec = importlib.util.spec_from_file_location('vela_browser_helpers', ROOT / 'scripts/test-ui-browser.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        driver_source = module.PLAYWRIGHT_DRIVER.replace("else if(command==='select')", "else if(command==='dialog')page.once('dialog',dialog=>args[0]==='accept'?dialog.accept(args[1]??''):dialog.dismiss());\n      else if(command==='select')")
        server = subprocess.Popen(['python3', str(ROOT / 'scripts/test-ui-server.py'), str(base / 'fixture.json'),
                                   '--binary', str(helper), '--ui-directory', str(ui)], stdout=subprocess.PIPE, text=True)
        assert select.select([server.stdout], [], [], 15)[0], 'Server did not start'
        url = json.loads(server.stdout.readline())['url']
        driver = subprocess.Popen(['node', '-e', driver_source,
                                   str(ROOT / '.task-tmp/ui-browser-tools/node_modules/playwright/index.js'),
                                   str(args.browser_executable or '')], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True, start_new_session=True)
        browser('open', url)
        browser('wait', '#project-selector')
        browser('snapshot', '-i')
        browser('select', '#project-selector', project)
        wait('document.querySelector("#project-selector").value===' + json.dumps(project), 'Project selection absent')
        value("window.__consumerOriginalCall=window.vela.call;window.__consumerReceipts=[];window.vela.call=async(method,params)=>{const hold=method==='library.index'&&window.__holdNextIndex;if(hold)window.__holdNextIndex=false;try{const result=await window.__consumerOriginalCall(method,params);window.__consumerReceipts.push({method,params,result});if(hold){window.__indexHeld=true;await new Promise(resolve=>window.__releaseIndex=resolve);window.__indexDelivered=true;}return result;}catch(error){window.__consumerReceipts.push({method,params,error:error.message});throw error;}};true")
        initial_runs = {row['id'] for row in rpc('runs.list', {})}
        initial_approvals = {row['id'] for row in rpc('inbox.list', {})}
        document_id = None

        def private_edit():
            nonlocal document_id
            library_page()
            click('#btn-add-library')
            assert value('document.querySelector("#lib-private").checked'), 'New Library import is not private by default'
            browser('fill', '#lib-title', 'Consumer private library')
            browser('select', '#lib-project', project)
            browser('fill', '#lib-folder', 'engineering/review')
            browser('fill', '#lib-content', 'Consumer private source before explicit publication.')
            click('#btn-save-lib')
            wait('document.querySelector("#modal-container").classList.contains("hidden")', 'Library import did not finish')
            item = next(row for row in rpc('library.list', {'project': project}) if row['title'] == 'Consumer private library')
            document_id = item['id']
            assert item['private'] is True and item['project'] == project
            reviewed = library_item(document_id)
            wait_library_row(document_id)
            click('.btn-edit-library[data-id="' + document_id + '"]')
            wait('!!document.querySelector("#lib-edit-content")', 'Reviewed edit did not load')
            browser('fill', '#lib-edit-title', 'Consumer published library')
            browser('fill', '#lib-edit-content', 'Consumer published source, explicitly accepted by the user.')
            checkbox('#lib-edit-private', False)
            click('#btn-save-edit-lib')
            wait('document.querySelector("#modal-container").classList.contains("hidden")', 'Reviewed edit did not finish')
            after = library_item(document_id)
            assert after['item']['private'] is False and after['item']['version'] == 2
            assert after['item']['folder'] == 'engineering/review'
            write = ui_calls('library.update')[-1]
            assert write['params']['snapshotHash'] == reviewed['snapshotHash']
            assert write['params']['project'] == project and after['snapshotHash'] != reviewed['snapshotHash']
            return {'id': document_id, 'defaultPrivate': True, 'acceptedVersion': 2, 'reviewedHashUsed': True}
        check('library-private-edit', private_edit)

        # Independent seeds only when a diagnostic subset omitted the first
        # journey; a failed first journey does not silently become a PASS.
        if document_id is None:
            document_id = rpc('library.add', {'project': project, 'title': 'Consumer independent library',
                                             'content': 'Independent source for the following review journeys.', 'private': False})['id']

        def stale_review():
            library_page()
            wait_library_row(document_id)
            reviewed = library_item(document_id)
            click('.btn-edit-library[data-id="' + document_id + '"]')
            wait('!!document.querySelector("#lib-edit-content")', 'Edit did not load')
            rpc('library.update', {'id': document_id, 'project': project, 'snapshotHash': reviewed['snapshotHash'],
                                   'content': 'External newer content must survive the stale editor.'})
            browser('fill', '#lib-edit-content', 'A stale editor must not overwrite the newer source.')
            before = len(ui_calls('library.update'))
            click('#btn-save-edit-lib')
            wait('!document.querySelector("#lib-edit-stale-warn").classList.contains("hidden")', 'Stale review warning absent')
            calls = ui_calls('library.update')[before:]
            assert len(calls) == 1 and 'changed since review' in calls[0].get('error', ''), 'Stale edit retried or was not rejected'
            after = library_item(document_id)
            assert after['item']['content'] == 'External newer content must survive the stale editor.'
            assert calls[0]['params']['snapshotHash'] == reviewed['snapshotHash']
            return {'id': document_id, 'staleWritesAttempted': 1, 'automaticRetry': False, 'newerContentPreserved': True}
        check('library-stale-review', stale_review)

        def archive_restore():
            library_page()
            wait_library_row(document_id)
            before = library_item(document_id)
            browser('dialog', 'accept')
            click('.btn-archive-library[data-id="' + document_id + '"]')
            wait('!document.querySelector(' + json.dumps('.btn-archive-library[data-id="' + document_id + '"]') + ')', 'Archived row still active')
            archived = library_item(document_id)
            assert archived['item']['state'] == 'archived'
            assert document_id not in {row['id'] for row in rpc('library.list', {'project': project})}
            checkbox('#chk-lib-include-archived', True)
            wait('!!document.querySelector(' + json.dumps('.btn-restore-library[data-id="' + document_id + '"]') + ')', 'Archived row cannot be restored')
            click('.btn-restore-library[data-id="' + document_id + '"]')
            wait('!!document.querySelector(' + json.dumps('.btn-archive-library[data-id="' + document_id + '"]') + ')', 'Restored row did not become active')
            restored = library_item(document_id)
            assert restored['item']['state'] == 'active' and restored['item']['private'] == before['item']['private']
            assert restored['item']['content'] == before['item']['content'] and restored['item']['version'] == before['item']['version'] + 2
            versions = rpc('library.history', {'id': document_id, 'project': project})
            return {'id': document_id, 'identityAndPrivacyRetained': True, 'versionsRetained': len(versions)}
        check('library-archive-restore', archive_restore)

        def paged_index_search():
            for number in range(28):
                rpc('library.add', {'project': project, 'title': 'Harbor public paragraph ' + str(number),
                                    'content': '# Index proof\n\nUIFTSPROOF public paragraph ' + str(number) + ' has exact source bytes.', 'private': False})
            rpc('library.add', {'project': project, 'title': 'Hidden private paragraph',
                                'content': 'UIFTSPROOF PRIVATE_EXCLUDED_SENTINEL', 'private': True})
            removed = rpc('library.add', {'project': project, 'title': 'Hidden archived paragraph',
                                         'content': 'UIFTSPROOF ARCHIVED_EXCLUDED_SENTINEL', 'private': False})
            old = library_item(removed['id'])
            rpc('library.remove', {'id': removed['id'], 'project': project, 'snapshotHash': old['snapshotHash']})
            library_page()
            click('#btn-library-index')
            wait('!!document.querySelector("#btn-start-index")', 'Index dialog absent')
            assert not ui_calls('library.index'), 'Opening index dialog started mutation'
            value('window.__holdNextIndex=true;window.__indexHeld=false;window.__indexDelivered=false;true')
            click('#btn-start-index')
            wait('window.__indexHeld===true', 'First real index page did not finish')
            first = ui_calls('library.index')[-1]['result']
            assert first['nextCursor'] and first['processed'] == 25
            click('#btn-cancel-index')
            value('window.__releaseIndex();true')
            wait('!document.querySelector("#btn-start-index").disabled', 'Cancellation did not settle')
            assert len(ui_calls('library.index')) == 1, 'Cancellation started another index page'
            assert value('!!document.querySelector(' + json.dumps('[data-i18n="library.indexCancelled"]') + ')'), 'Cancellation was described as success'
            click('#btn-start-index')
            wait('!document.querySelector("#btn-start-index").disabled && !!document.querySelector(' + json.dumps('[data-i18n="library.indexDone"]') + ')', 'Paged index did not finish', 20)
            pages = ui_calls('library.index')[1:]
            assert len(pages) >= 2 and pages[0]['result']['nextCursor']
            assert pages[1]['params']['cursor'] == pages[0]['result']['nextCursor']
            assert all(page['result']['networkRequests'] == 0 and not page['result']['failures'] for page in pages)
            status = rpc('library.index.status', {'project': project})
            assert status['databaseCoverageComplete'] is True
            close()
            click('#btn-library-search')
            browser('fill', '#lib-search-query', 'UIFTSPROOF')
            browser('fill', '#lib-search-k', '50')
            click('#btn-do-library-search')
            wait('document.querySelector("#lib-search-results").textContent.includes("public paragraph")', 'Actual indexed paragraphs absent')
            search = ui_calls('library.search')[-1]['result']
            assert len(search['items']) == 28 and all(item['project'] == project for item in search['items'])
            body = value('document.querySelector("#lib-search-results").textContent')
            assert 'PRIVATE_EXCLUDED_SENTINEL' not in body and 'ARCHIVED_EXCLUDED_SENTINEL' not in body
            assert all(item['content'] in body for item in search['items'])
            assert 'UTF-16' in body and len({item['citationId'] for item in search['items']}) == 28
            return {'cancelledAfterPages': 1, 'completedPages': len(pages), 'actualParagraphs': 28,
                    'privateAndArchivedExcluded': True, 'networkRequests': 0}
        check('library-paged-index-search', paged_index_search)

        def watch_journey(source):
            title = 'Consumer ' + source + ' watch'
            page('workflows')
            click('#btn-new-workflow')
            browser('fill', '#wf-modal-title', title)
            browser('select', '#wf-modal-project', project)
            browser('select', '#wf-modal-trigger', 'watch')
            # Scheduled definitions require a durable destination; choose the
            # existing Inbox control explicitly instead of the manual stdout default.
            browser('select', '#wf-output-target', 'inbox')
            # Reduce any default steps through their actual controls; do not
            # depend on an unreviewed command being the editor's second row.
            while value('document.querySelectorAll(".wf-step-tool").length') > 1:
                index = value('Array.from(document.querySelectorAll(".wf-step-tool")).at(-1).getAttribute("data-idx")')
                click('.btn-step-del[data-idx="' + index + '"]')
            if value('document.querySelectorAll(".wf-step-tool").length') == 0:
                click('#btn-add-step')
            assert value('document.querySelectorAll(".wf-step-tool").length') == 1
            browser('select', '.wf-step-tool[data-idx="0"]', 'git.status')
            if source == 'files':
                browser('select', '#wf-watch-source', 'files')
                browser('fill', '#wf-watch-paths', 'src\nREADME.md')
                checkbox('#wf-watch-recursive', True)
                browser('fill', '#wf-watch-ignore', '**/cache/**\n*.tmp')
                browser('fill', '#wf-watch-debounce', '5')
            else:
                if value('!!document.querySelector("#wf-watch-source")'):
                    browser('select', '#wf-watch-source', 'tool')
                browser('select', '#wf-watch-tool', 'git.status')
                assert value('document.querySelector("#wf-watch-mode").value') == 'output'
                assert value('document.querySelector("#wf-watch-mode").disabled')
                browser('fill', '#wf-watch-every', '30')
                browser('fill', '#wf-watch-debounce', '5')
            click('#btn-save-wf')
            wait('document.querySelector("#modal-container").classList.contains("hidden")', 'Watch UI save did not finish')
            workflow = next(row for row in rpc('workflows.list', {'project': project}) if row['title'] == title)
            identifier = workflow['id']
            assert workflow['trigger'] == 'watch' and workflow['watch']['source'] == source
            if source == 'files':
                # The Core contract canonicalizes the set of watched roots.
                assert workflow['watch']['paths'] == sorted(['src', 'README.md'])
                assert workflow['watch']['recursive'] is True and workflow['watch']['ignore'] == ['**/cache/**', '*.tmp']
            else:
                assert workflow['watch']['tool'] == 'git.status' and workflow['watch']['mode'] == 'output'
            # Reload the persisted definition through the actual edit control.
            # Source switching must preserve the draft, and saves must not mix
            # file-specific and polling-specific fields.
            click('.btn-wf-edit[data-id="' + identifier + '"]')
            wait('!!document.querySelector("#wf-watch-source")', 'Watch source edit control absent')
            assert value('document.querySelector("#wf-watch-source").value') == source
            if source == 'files':
                original_paths = value('document.querySelector("#wf-watch-paths").value')
                original_ignore = value('document.querySelector("#wf-watch-ignore").value')
                assert sorted(original_paths.splitlines()) == sorted(['src', 'README.md'])
                assert original_ignore.splitlines() == ['**/cache/**', '*.tmp']
                assert value('document.querySelector("#wf-watch-recursive").checked') is True
                browser('select', '#wf-watch-source', 'tool')
                browser('select', '#wf-watch-source', 'files')
                assert value('document.querySelector("#wf-watch-paths").value') == original_paths
                assert value('document.querySelector("#wf-watch-ignore").value') == original_ignore
                checkbox('#wf-watch-recursive', False)
            else:
                assert value('document.querySelector("#wf-watch-every").value') == '30'
                assert value('document.querySelector("#wf-watch-tool").value') == 'git.status'
            browser('fill', '#wf-watch-debounce', '7')
            click('#btn-save-wf')
            wait('document.querySelector("#modal-container").classList.contains("hidden")', 'Edited Watch did not save')
            edited = rpc('workflows.get', {'id': identifier, 'project': project})['definition']['watch']
            assert edited['source'] == source and edited['debounceSeconds'] == 7
            if source == 'files':
                assert edited['recursive'] is False and edited['paths'] == workflow['watch']['paths']
                assert not {'tool', 'mode', 'key', 'everySeconds'} & edited.keys(), edited
            else:
                assert not {'paths', 'recursive', 'ignore'} & edited.keys(), edited
            selector = '.btn-wf-preview-watch[data-id="' + identifier + '"]'
            wait('!!document.querySelector(' + json.dumps(selector) + ')', 'Watch preview row absent')
            click(selector)
            wait('!!document.querySelector(' + json.dumps('[data-i18n="watch.previewBaselineTrue"]') + ')', 'Watch baseline preview absent')
            preview = ui_calls('watches.preview')[-1]['result']
            assert preview['mutated'] is False and preview['workflowExecuted'] is False and preview['externalRequests'] == 0
            assert preview['wouldInitializeBaseline'] is True and preview['snapshot']['entries']
            if source == 'files':
                values = [entry['value'] for entry in preview['snapshot']['entries'].values()]
                assert {'src/parser.mjs', 'README.md'} <= {item['path'] for item in values}
                assert preview['snapshot']['filesRead'] >= 2 and preview['snapshot']['bytesRead'] > 0
            close()
            click('.btn-wf-inspect[data-id="' + identifier + '"]')
            wait('!!document.querySelector("#btn-inspect-toggle-enabled")', 'Watch enable control absent')
            enabled_before = workflow.get('enabled', True)
            for expected in [not enabled_before, enabled_before]:
                click('#btn-inspect-toggle-enabled')
                wait('!!document.querySelector("#btn-inspect-toggle-enabled") && document.querySelector("#btn-inspect-toggle-enabled").getAttribute("data-i18n")===' + json.dumps('workflows.btnDisable' if expected else 'workflows.btnEnable'), 'Watch toggle did not reflect saved state')
                assert rpc('workflows.get', {'id': identifier, 'project': project})['definition']['enabled'] is expected
            status = rpc('watches.get', {'id': identifier, 'project': project})
            assert status['state'] is None, 'Passive preview or enable created a watch watermark'
            assert {row['id'] for row in rpc('runs.list', {})} == initial_runs
            assert {row['id'] for row in rpc('inbox.list', {})} == initial_approvals
            return {'workflowId': identifier, 'createdThroughUI': True, 'source': source,
                    'editedThroughUI': True, 'persistedFieldsAndSourceSwitchVerified': True,
                    'previewMutated': False, 'newRuns': 0, 'newApprovals': 0,
                    'watchWatermarkCreated': False, 'enabledStatesVerified': [not enabled_before, enabled_before]}
        check('tool-watch', lambda: watch_journey('tool'))
        check('files-watch', lambda: watch_journey('files'))
        evidence['sourceAfter'] = hashes(ui_source)
        evidence['fixtureSourceAfter'] = hashes(ui)
        evidence['sourceUnchanged'] = evidence['sourceBefore'] == evidence['sourceAfter'] == evidence['fixtureSourceBefore'] == evidence['fixtureSourceAfter']
        forbidden = [event['method'] for event in events() if event['method'].startswith(('daemon.', 'connectors.', 'ask.', 'loops.')) or event['method'] in ('workflows.run', 'approvals.decide')]
        evidence['forbiddenActions'] = forbidden
        evidence['selectedChecksPassed'] = len(results) == len(selected) and all(row['passed'] for row in results) and evidence['sourceUnchanged'] and not forbidden
        evidence['completeSuite'] = selected == set(CHECKS) and evidence['selectedChecksPassed']
        (output / 'ui-receipts.json').write_text(json.dumps(value('window.__consumerReceipts'), ensure_ascii=False, indent=2) + '\n')
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
            count = sum(1 for path in base.rglob('*') if path.is_file())
            shutil.rmtree(base)
            evidence['cleanup'] = {'removedOwnedFixture': str(base), 'removedFiles': count,
                                   'browserAndServerStopped': True, 'evidenceRetained': True,
                                   'sharedDependenciesRemoved': False}
        save()
    return 0 if evidence.get('selectedChecksPassed') and 'harnessError' not in evidence else 1


if __name__ == '__main__':
    raise SystemExit(main())
