"""Ten History/Plan user journeys against frozen UI and a real isolated helper.

Synthetic source discovery, persisted imports and raw Unicode pages are exercised
through the actual UI bridge. Unknown and confirmed empty plans remain distinct.
Later checks use a separately seeded actual epoch to isolate upstream failures.
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
from release_resources import DEVELOPMENT_UI_RESOURCES, UI_RESOURCES, copy_ui_resources
import select
import shutil
import signal
import subprocess
import time
import traceback
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
UI_FILES = UI_RESOURCES + DEVELOPMENT_UI_RESOURCES
CHECKS = ('discovery-pagination', 'source-start', 'pause-resume-persistence', 'cancel-resume',
          'event-pages-unicode-raw', 'plan-states', 'plan-event-pagination', 'project-isolation',
          'delayed-plan-routing', 'branch-pagination')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ui-directory', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True, help='NEW immediate child of .task-tmp; cleaned on exit.')
    parser.add_argument('--output', type=Path, required=True, help='NEW directory under output/playwright; retained.')
    parser.add_argument('--browser-executable', type=Path, help='Optional browser; omit for installed Playwright Chromium.')
    parser.add_argument('--checks', help='Comma-separated diagnostic subset; omit for all ten journeys.')
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
    (output / 'consumer-test-source.py').write_bytes(Path(__file__).read_bytes())
    results = []
    evidence = {'format': 'vela-history-plan-renderer-v1', 'synthetic': True,
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

    def exists(selector):
        return value('!!document.querySelector(' + json.dumps(selector) + ')')

    def wait_selector(selector, reason):
        wait('!!document.querySelector(' + json.dumps(selector) + ')', reason)

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
        results[-1]['pageErrors'] = value('window.__consumerErrors || []')
        browser('screenshot', str(output / (name + '.png')))
        (output / (name + '.txt')).write_text(browser('snapshot', '-i'))
        print(json.dumps(results[-1], ensure_ascii=False), flush=True)
        value('if(window.__releasePlan){window.__releasePlan();window.__releasePlan=null;}if(window.__releaseHistory){window.__releaseHistory();window.__releaseHistory=null;}true')
        save()

    try:
        evidence['sourceBefore'] = hashes(ui_source)
        evidence['helperSourceSHA256'] = hashlib.sha256(helper_source.read_bytes()).hexdigest()
        created = subprocess.run(['python3', str(ROOT / 'scripts/create-history-plan-fixture.py'), str(base), '--binary', str(helper_source)],
                                 capture_output=True, text=True, timeout=60)
        fixture_created = (base / 'store/.vela-ui-fixture.json').is_file()
        (output / 'fixture-creation.log').write_text(created.stdout + created.stderr)
        created.check_returncode()
        fixture = json.loads((base / 'fixture.json').read_text())
        assert fixture['synthetic'] is True
        project = fixture['project']
        ui = base / 'ui-snapshot'
        ui.mkdir()
        copy_ui_resources(ui_source, ui, allow_development=True)
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
        value("window.__consumerErrors=[];window.addEventListener('error',e=>window.__consumerErrors.push(e.message));window.addEventListener('unhandledrejection',e=>window.__consumerErrors.push(String(e.reason)));window.__consumerOriginalCall=window.vela.call;window.__consumerReceipts=[];window.vela.call=async(method,params)=>{try{const result=await window.__consumerOriginalCall(method,params);window.__consumerReceipts.push({method,params,result});if(method==='history.page'&&params.id===window.__holdHistoryId&&params.cursor){window.__holdHistoryId=null;window.__historyHeld=true;await new Promise(resolve=>window.__releaseHistory=resolve);window.__historyDelivered=true;}if(method==='sessions.plan.get'&&params.id===window.__holdPlanId){window.__holdPlanId=null;window.__planHeld=true;await new Promise(resolve=>window.__releasePlan=resolve);window.__planDelivered=true;}return result;}catch(error){window.__consumerReceipts.push({method,params,error:error.message});throw error;}};true")
        hp = fixture['historyPlan']
        job_id = None
        source_id = None

        def history_page():
            page('agents')
            click('#btn-session-history')
            wait('!!document.querySelector("#btn-history-discover")', 'History entry did not open')

        def success_calls(method):
            return [x for x in ui_calls(method) if 'result' in x]

        def discover_all():
            response = rpc('history.discover', {'project': project, 'limit': 64})
            items = list(response.get('items', []))
            for _ in range(20):
                if response['state'] == 'completed': break
                response = rpc('history.discover', {'project': project, 'inventoryId': response['id'], 'limit': 64})
                items.extend(response.get('items', []))
            assert response['traversalComplete'] is True, response
            return items

        def discovery():
            history_page()
            count_before = len(success_calls('history.discover'))
            click('#btn-history-discover')
            wait('window.__consumerReceipts.filter(x=>x.method==="history.discover"&&x.result).length>' + str(count_before), 'Discovery did not return')
            response = success_calls('history.discover')[-1]['result']
            assert response['id'] and response['traversalComplete'] is False
            wait('!!document.querySelector("#btn-history-discover-more")', 'Incomplete discovery has no continuation control')
            inventories = [response['id']]
            for _ in range(20):
                if response['state'] == 'completed': break
                before = len(success_calls('history.discover'))
                click('#btn-history-discover-more')
                wait('window.__consumerReceipts.filter(x=>x.method==="history.discover"&&x.result).length>' + str(before), 'Discovery continuation missing')
                response = success_calls('history.discover')[-1]['result']; inventories.append(response['id'])
            assert response['traversalComplete'] is True and len(set(inventories)) == 1
            source_pages = []
            cursor = None
            while True:
                params = {'project': project, 'inventoryId': inventories[0], 'limit': 50}
                if cursor: params['afterId'] = cursor
                result = rpc('history.sources', params); source_pages.extend(result['items']); cursor = result['nextAfterId']
                if cursor is None: break
            # Discovery and source listing have independent bounded cursors.
            # Exercise the visible continuation instead of assuming eager fetch.
            source_loads = 0
            while exists('#btn-history-load-more-sources'):
                assert source_loads < 20, 'Source pagination did not terminate'
                before = len(success_calls('history.sources'))
                click('#btn-history-load-more-sources')
                wait('window.__consumerReceipts.filter(x=>x.method==="history.sources"&&x.result).length>' + str(before), 'Source page continuation missing')
                wait('!document.querySelector("#btn-history-load-more-sources") || !document.querySelector("#btn-history-load-more-sources").disabled', 'Source continuation stays busy')
                source_loads += 1
            visible = value('[...document.querySelectorAll(".btn-start-history-source")].map(x=>x.dataset.sourceId)')
            assert {x['id'] for x in source_pages} == set(visible), 'Displayed sources must use actionable manifest source IDs and include all discovered pages'
            assert len(visible) == len(set(visible)), 'Source pages contain duplicate actionable IDs'
            assert len(visible) >= hp['extraSources']
            return {'inventoryId': inventories[0], 'discoveryCalls': len(inventories), 'sources': len(visible), 'sourcePageContinuations': source_loads}
        check('discovery-pagination', discovery)

        def source_start():
            history_page()
            if not value('!!document.querySelector(".btn-start-history-source")'):
                click('#btn-history-discover')
                wait('!!document.querySelector(".btn-start-history-source")', 'No discovered sources')
            selector = '.btn-start-history-source'
            candidates = value('[...document.querySelectorAll(".btn-start-history-source")].map(x=>({id:x.dataset.sourceId,text:x.closest(".card").textContent}))')
            target = next((x for x in candidates if hp['sourceName'] in x['text']), None)
            for _ in range(20):
                if target or not exists('#btn-history-load-more-sources'): break
                before = len(success_calls('history.sources'))
                click('#btn-history-load-more-sources')
                wait('window.__consumerReceipts.filter(x=>x.method==="history.sources"&&x.result).length>' + str(before), 'Source continuation missing while finding import target')
                candidates = value('[...document.querySelectorAll(".btn-start-history-source")].map(x=>({id:x.dataset.sourceId,text:x.closest(".card").textContent}))')
                target = next((x for x in candidates if hp['sourceName'] in x['text']), None)
            assert target is not None, 'Import source must be reachable through visible source pagination'
            click(selector + '[data-source-id="' + target['id'] + '"]')
            wait('window.__consumerReceipts.some(x=>x.method==="history.start")', 'Start did not settle')
            response = ui_calls('history.start')[-1]
            assert 'result' in response, response
            epoch = response['result']
            assert epoch['state'] == 'pending' and epoch['sourceBytes'] == hp['sourceBytes']
            return {'epochId': epoch['id'], 'createdThroughUI': True}
        check('source-start', source_start)

        # Independently seed a real epoch to isolate later UI defects from discovery/start.
        source_id = next(x['id'] for x in discover_all() if x['relativePath'] == hp['sourceName'])
        job_id = rpc('history.start', {'project': project, 'sourceId': source_id})['id']

        def select_job():
            history_page()
            click('#btn-history-refresh-jobs')
            selector = '.btn-select-history-job[data-job-id="' + job_id + '"]'
            wait('!!document.querySelector(' + json.dumps(selector) + ')', 'Persisted job not listed')
            click(selector)
            wait('!!document.querySelector("#btn-history-advance-step")', 'Persisted job did not open')

        def pause_resume():
            select_job()
            assert value('!document.querySelector("#btn-history-pause").disabled'), 'Pending epoch must support pause before any further batch'
            click('#btn-history-pause')
            wait('window.__consumerReceipts.some(x=>x.method==="history.pause"&&x.result)', 'Pause not acknowledged')
            assert rpc('history.get', {'project': project, 'id': job_id})['state'] == 'paused'
            wait('!document.querySelector("#btn-history-resume").disabled', 'Paused epoch has no Resume action')
            click('#btn-history-resume')
            wait('window.__consumerReceipts.some(x=>x.method==="history.resume"&&x.result)', 'Resume not acknowledged')
            click('#btn-history-advance-step')
            wait('window.__consumerReceipts.some(x=>x.method==="history.advance"&&x.result)', 'Bounded advance did not finish')
            epoch = rpc('history.get', {'project': project, 'id': job_id})
            assert 0 < epoch['offset'] < epoch['sourceBytes'] and 0 < epoch['records'] < hp['expectedRecords']
            wait('!document.querySelector("#btn-history-advance-step").disabled', 'Step action stays disabled after completion')
            page('setup'); select_job()
            assert str(epoch['records']) in value('document.querySelector("#history-active-job-container").textContent'), 'Committed count missing after reopening'
            return {'epochId': job_id, 'offset': epoch['offset'], 'records': epoch['records'], 'harnessSeededEpoch': True}
        check('pause-resume-persistence', pause_resume)

        def cancel_resume():
            rpc('history.resume', {'project': project, 'id': job_id})
            select_job()
            browser('dialog', 'accept')
            click('#btn-history-cancel')
            wait('window.__consumerReceipts.some(x=>x.method==="history.cancel"&&x.result)', 'Cancel did not settle')
            epoch = rpc('history.get', {'project': project, 'id': job_id})
            assert epoch['state'] == 'cancelled'
            wait('!document.querySelector("#btn-history-resume").disabled', 'Cancelled persisted epoch cannot be resumed through UI')
            assert not value('document.querySelector("#btn-history-advance-step").disabled===false'), 'Cancelled epoch offers advance without Resume'
            click('#btn-history-resume')
            wait('window.__consumerReceipts.some(x=>x.method==="history.resume"&&x.result)', 'Resume did not settle')
            return {'cancelledRecordsPreserved': True, 'harnessSeededEpoch': True}
        check('cancel-resume', cancel_resume)

        if selected & {'event-pages-unicode-raw', 'project-isolation'}:
            rpc('history.resume', {'project': project, 'id': job_id})
            # The backend also has a one-second wall-clock batch budget. A fixed
            # batch count is not a completion bound on a loaded verification Mac.
            import_started = time.monotonic()
            evidence['harnessImportBatches'] = []
            previous_offset = -1
            for batch in range(120):
                imported = rpc('history.advance', {'project': project, 'id': job_id, 'batchBytes': 4194304, 'batchRecords': 2000})
                evidence['harnessImportBatches'].append({key: imported.get(key) for key in ('state', 'offset', 'records', 'sourceBytes', 'rawBytesComplete')})
                save()
                assert imported['state'] in ('pending', 'completed'), imported
                assert imported['offset'] > previous_offset or imported['state'] == 'completed', 'Historical import made no progress: ' + json.dumps(imported)
                previous_offset = imported['offset']
                if imported['state'] == 'completed': break
                assert time.monotonic() - import_started < 180, 'Import exceeded local acceptance time budget: ' + json.dumps(imported)
            assert imported['rawBytesComplete'] and imported['records'] == hp['expectedRecords'], imported
            evidence['harnessImportSeconds'] = round(time.monotonic() - import_started, 3)

        def event_raw():
            select_job()
            click('#btn-history-view-events')
            wait('document.querySelectorAll(".btn-history-view-raw").length===50', 'First physical event page absent')
            first = value('[...document.querySelectorAll(".btn-history-view-raw")].map(x=>Number(x.dataset.ordinal))')
            assert first == list(range(50))
            # Delay the real second-page result across an actual host refresh.
            # This controls timing only; payloads and persisted state stay real.
            value('window.__holdHistoryId=' + json.dumps(job_id) + ';window.__historyHeld=false;window.__historyDelivered=false;true')
            click('#btn-history-load-more-events')
            wait('window.__historyHeld===true', 'Second page was not held for the refresh race')
            dashboard_before = len(success_calls('dashboard.get'))
            value('window.dispatchEvent(new CustomEvent("vela:refresh",{detail:{source:"host"}}));true')
            wait('window.__consumerReceipts.filter(x=>x.method==="dashboard.get"&&x.result).length>' + str(dashboard_before), 'Background refresh did not return during the held event page')
            # Two paint turns let the real refresh handler process its response.
            value('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))')
            value('window.__releaseHistory();window.__releaseHistory=null;true')
            wait('document.querySelectorAll(".btn-history-view-raw").length===100', 'Second event page did not append')
            assert value('[...document.querySelectorAll(".btn-history-view-raw")].map(x=>Number(x.dataset.ordinal))') == list(range(100))
            click('.btn-history-view-raw[data-ordinal="1"]')
            wait('!!document.querySelector("#raw-viewer-pre")', 'Raw first part missing')
            for _ in range(20):
                if not value('!!document.querySelector("#btn-fetch-next-part")'): break
                before = len(success_calls('history.raw'))
                click('#btn-fetch-next-part')
                wait('window.__consumerReceipts.filter(x=>x.method==="history.raw"&&x.result).length>' + str(before), 'Raw continuation missing')
            raw = value('document.querySelector("#raw-viewer-pre").textContent')
            assert hashlib.sha256(raw.encode()).hexdigest() == hp['rawRecordSHA256'], 'Full Unicode byte stream does not match source hash'
            assert json.loads(raw)['message']['content'] == hp['expectedRawText']
            assert '\ufffd' not in raw
            parts = success_calls('history.raw')
            assert len(parts) > 1 and [x['params']['part'] for x in parts] == list(range(len(parts)))
            close()
            return {'sourceOrderVerified': 100, 'rawParts': len(parts), 'rawSHA256': hp['rawRecordSHA256'], 'harnessImportedEpoch': True, 'heldRealPageAcrossHostRefresh': True}
        check('event-pages-unicode-raw', event_raw)

        def open_plan(name):
            page('agents'); click('[data-agentstab="sessions"]')
            identifier = hp['sessions'][name]
            selector = '.session-card[data-id="' + identifier + '"]'
            wait('!!document.querySelector(' + json.dumps(selector) + ')', 'Plan fixture session missing')
            click(selector)
            wait('!!document.querySelector("#session-plan-body")', 'Plan panel absent')
            wait('window.__consumerReceipts.some(x=>x.method==="sessions.plan.get"&&x.params.id===' + json.dumps(identifier) + '&&x.result)', 'Plan request not completed')
            return identifier

        def plan_states():
            identifier = open_plan('consumer-confirmed-plan')
            wait('document.querySelector("#session-plan-body").textContent.includes("已核对来源标识")', 'Confirmed plan text missing')
            body = value('document.querySelector("#session-plan-body").textContent')
            assert all(x['step'] in body for x in hp['expectedConfirmedItems'])
            assert 'UNACKNOWLEDGED_NOT_COMPLETE' not in body
            assert exists('[data-i18n="sessions.plan.pendingUpdatesAlert"]')
            assert exists('[data-i18n="sessions.plan.workVerifiedNotice"]')
            open_plan('consumer-unavailable-plan')
            wait_selector('#session-plan-body [data-i18n="sessions.plan.unavailable"]', 'Unknown plan not marked unavailable')
            assert value('document.querySelector("#session-plan-badge").textContent') != '0'
            open_plan('consumer-empty-plan')
            wait_selector('#session-plan-body [data-i18n="sessions.plan.empty"]', 'Confirmed empty plan not distinguished')
            return {'states': ['confirmed-with-pending-update', 'unavailable', 'confirmed-empty'], 'workVerified': False}
        check('plan-states', plan_states)

        def plan_events():
            identifier = open_plan('consumer-confirmed-plan')
            click('#plan-events-container summary'); click('#btn-load-plan-events')
            wait('window.__consumerReceipts.some(x=>x.method==="sessions.plan.events"&&x.result)', 'Events read absent')
            response = success_calls('sessions.plan.events')[-1]['result']
            assert response['eventsTruncated'] and len(response['items']) == 50
            wait('!!document.querySelector("#btn-load-more-plan-events")', 'Persisted event page has no continuation')
            text_before = value('document.querySelector("#plan-events-body").textContent')
            assert all('#' + str(x['sequence']) in text_before for x in response['items'])
            before = len(success_calls('sessions.plan.events'))
            click('#btn-load-more-plan-events')
            wait('window.__consumerReceipts.filter(x=>x.method==="sessions.plan.events"&&x.result).length>' + str(before), 'Events next page absent')
            second = success_calls('sessions.plan.events')[-1]
            assert second['params']['afterSequence'] == response['nextAfterSequence']
            assert all(x['sequence'] > response['nextAfterSequence'] for x in second['result']['items'])
            return {'firstPage': 50, 'secondPage': len(second['result']['items']), 'eventsTruncated': True}
        check('plan-event-pagination', plan_events)
        def project_isolation():
            select_job()
            other = next(p for p in fixture['projects'] if p != project)
            browser('select', '#project-selector', other)
            wait('document.querySelector("#project-selector").value===' + json.dumps(other), 'Project did not switch')
            wait('!!document.querySelector("#btn-history-discover")', 'History did not render after project switch')
            assert job_id not in value('document.querySelector("#main-content").textContent'), 'Previous project epoch leaked into selected project'
            assert not value('!!document.querySelector(".btn-start-history-source")'), 'Previous project sources remained actionable'
            assert not value('!!document.querySelector("#btn-history-advance-step")'), 'Previous project import action remained active'
            browser('select', '#project-selector', project)
            select_job()
            return {'projectSwitched': True, 'previousProjectRowsCleared': True}
        check('project-isolation', project_isolation)

        def delayed_plan():
            page('agents'); click('[data-agentstab="sessions"]')
            old_id = hp['sessions']['consumer-confirmed-plan']
            value('window.__holdPlanId=' + json.dumps(old_id) + ';true')
            click('.session-card[data-id="' + old_id + '"]')
            wait('window.__planHeld===true', 'Controlled real plan response was not held')
            close()
            open_plan('consumer-empty-plan')
            wait_selector('#session-plan-body [data-i18n="sessions.plan.empty"]', 'New empty plan did not load')
            value('window.__releasePlan();true')
            wait('window.__planDelivered===true', 'Held plan response was not delivered')
            assert exists('#session-plan-body [data-i18n="sessions.plan.empty"]')
            assert '已核对来源标识' not in value('document.querySelector("#session-plan-body").textContent')
            return {'lateActualResponseIgnored': True, 'newSessionPreserved': True}
        check('delayed-plan-routing', delayed_plan)

        def branch_pages():
            nonlocal job_id
            branch_source = next(x for x in discover_all() if x['relativePath'] == hp['branchSourceName'])
            branch = rpc('history.start', {'project': project, 'sourceId': branch_source['id']})
            branch = rpc('history.advance', {'project': project, 'id': branch['id']})
            assert branch['state'] == 'completed' and branch['branchIntegrity'] is True
            previous = job_id; job_id = branch['id']
            try:
                select_job(); click('#btn-history-view-branch')
                wait('window.__consumerReceipts.some(x=>x.method==="history.branch"&&x.result)', 'Branch read missing')
                first = success_calls('history.branch')[-1]['result']
                assert len(first['items']) == 50 and first['nextCursor']
                wait('!!document.querySelector("#btn-load-more-ancestors")', 'Branch continuation control absent')
                click('#btn-load-more-ancestors')
                wait('window.__consumerReceipts.filter(x=>x.method==="history.branch"&&x.result).length===2', 'Branch continuation missing')
                second = success_calls('history.branch')[-1]
                assert second['params']['cursor'] == first['nextCursor'] and len(second['result']['items']) == 25
                text = value('document.querySelector("#branch-modal-content").textContent')
                assert 'branch-74' in text and 'branch-0' in text
                return {'ancestorEntries': 75, 'pages': 2, 'harnessImportedEpoch': True}
            finally:
                job_id = previous; close()
        check('branch-pagination', branch_pages)
        evidence['sourceAfter'] = hashes(ui_source)
        evidence['fixtureSourceAfter'] = hashes(ui)
        evidence['sourceUnchanged'] = evidence['sourceBefore'] == evidence['sourceAfter'] == evidence['fixtureSourceBefore'] == evidence['fixtureSourceAfter']
        forbidden = [event['method'] for event in events() if event['method'].startswith(('daemon.', 'connectors.', 'ask.', 'loops.')) or event['method'] in ('workflows.run', 'approvals.decide')]
        evidence['forbiddenActions'] = forbidden
        evidence['selectedChecksPassed'] = len(results) == len(selected) and all(row['passed'] for row in results) and evidence['sourceUnchanged'] and not forbidden and not value('window.__consumerErrors.length')
        evidence['completeSuite'] = selected == set(CHECKS) and evidence['selectedChecksPassed']
        (output / 'ui-receipts.json').write_text(json.dumps(value('window.__consumerReceipts'), ensure_ascii=False, indent=2) + '\n')
    except Exception as error:
        evidence['harnessError'] = str(error)
        evidence['traceback'] = traceback.format_exc(limit=6)
        print(evidence['traceback'], flush=True)
    finally:
        if driver and driver.poll() is None:
            try:
                (output / 'ui-receipts.json').write_text(json.dumps(value('window.__consumerReceipts || []'), ensure_ascii=False, indent=2) + '\n')
            except Exception:
                pass
        if driver:
            try:
                if driver.poll() is None:
                    browser('close')
            except (BrokenPipeError, EOFError, ValueError, AssertionError) as error:
                evidence.setdefault('cleanupWarnings', []).append('Browser shutdown: ' + str(error))
            finally:
                if driver.poll() is None:
                    os.killpg(driver.pid, signal.SIGTERM)
                try:
                    driver.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(driver.pid, signal.SIGKILL)
                    driver.wait(timeout=5)
        if server:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
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
