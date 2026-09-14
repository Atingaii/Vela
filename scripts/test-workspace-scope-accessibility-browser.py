"""Consumer regressions for All Projects scope, live details, and Search + Actions ARIA.

The runner freezes its UI/helper inputs, creates a new synthetic relation fixture,
and retains screenshots, DOM trees, and real bridge receipts for every check.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
from release_resources import DEVELOPMENT_UI_RESOURCES, UI_RESOURCES, copy_ui_resources
import re
import select
import shutil
import signal
import subprocess
import time
import traceback
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
UI_FILES = UI_RESOURCES + DEVELOPMENT_UI_RESOURCES
CHECKS = ('all-projects-harbor-plan', 'all-projects-beacon-plan',
          'all-projects-codex-relations-pagination', 'stale-bridge-results',
          'live-refresh-preserves-detail-intent', 'search-actions-listbox',
          'search-actions-tablist', 'all-projects-live-anchor-and-stale-guards')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stop(process):
    if not process or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        except ProcessLookupError:
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ui-directory', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True, help='New immediate .task-tmp child; removed after run.')
    parser.add_argument('--output', type=Path, required=True, help='New retained immediate output/playwright child.')
    parser.add_argument('--browser-executable', type=Path, required=True)
    parser.add_argument('--playwright-module', type=Path,
                        default=ROOT / '.task-tmp/ui-browser-tools/node_modules/playwright/index.js')
    parser.add_argument('--frozen-selectors', action='store_true')
    parser.add_argument('--checks', help='Comma-separated diagnostic subset; omit for the complete suite.')
    args = parser.parse_args()
    if not args.frozen_selectors:
        parser.error('--frozen-selectors is required for this frozen selector contract.')
    selected = set(args.checks.split(',')) if args.checks else set(CHECKS)
    if not selected or not selected <= set(CHECKS):
        parser.error('Unknown or empty --checks.')
    fixture, output = args.fixture.absolute(), args.output.absolute()
    ui_source, binary = args.ui_directory.resolve(strict=True), args.binary.resolve(strict=True)
    if fixture.exists() or fixture.is_symlink() or fixture.parent != (ROOT / '.task-tmp').resolve():
        parser.error('--fixture must be a new immediate .task-tmp child.')
    if output.exists() or output.is_symlink() or output.parent.resolve() != (ROOT / 'output/playwright').resolve():
        parser.error('--output must be a new immediate output/playwright child.')
    if not args.browser_executable.is_file() or not args.playwright_module.is_file():
        parser.error('Chrome and the local Playwright module must be ordinary files.')
    for name in UI_FILES:
        if not (ui_source / name).is_file() or (ui_source / name).is_symlink():
            parser.error('Missing ordinary UI file: ' + name)

    output.mkdir(parents=True)
    (output / 'consumer-test-source.py').write_bytes(Path(__file__).read_bytes())
    evidence = {'format': 'vela-workspace-scope-accessibility-v2', 'synthetic': True,
                'completeSuite': selected == set(CHECKS), 'realProviderExecuted': False,
                'workflowExecuted': False, 'nativeAudioClaimed': False,
                'sourceDirectory': str(ui_source), 'binary': str(binary),
                'browserExecutable': str(args.browser_executable.resolve()),
                'playwrightModule': str(args.playwright_module.resolve()),
                'selectedChecks': sorted(selected), 'checks': []}
    server = driver = None
    fixture_created = False

    def save():
        (output / 'results.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')

    def browser(*command):
        driver.stdin.write(json.dumps(command) + '\n')
        driver.stdin.flush()
        if not select.select([driver.stdout], [], [], 25)[0]:
            raise TimeoutError('Playwright driver timed out.')
        reply = json.loads(driver.stdout.readline())
        if 'error' in reply:
            raise AssertionError(reply['error'])
        return reply.get('output', '')

    def value(expression):
        return json.loads(json.loads(browser('eval', 'JSON.stringify(' + expression + ')')))

    def wait(expression, reason, seconds=12):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if value(expression):
                return
            time.sleep(.06)
        raise AssertionError(reason)

    def click(selector):
        browser('click', selector)
        browser('snapshot', '-i')

    def rpc(method, params):
        request = urllib.request.Request(url + '__rpc', json.dumps({'method': method, 'params': params}).encode(),
            {'Content-Type': 'application/json', 'Origin': 'http://' + url.split('/')[2]})
        with urllib.request.urlopen(request, timeout=25) as response:
            answer = json.load(response)
        if 'error' in answer:
            raise AssertionError(answer['error'])
        return answer['result']

    def calls(method=None):
        source = 'window.__scopeCalls'
        if method:
            source += '.filter(x=>x.method===' + json.dumps(method) + ')'
        return value(source)

    def reset_all_projects():
        browser('press', 'Escape')
        browser('press', 'Escape')
        browser('select', '#project-selector', '')
        wait('document.querySelector("#project-selector").value === ""', 'All Projects did not settle.')
        click('.nav-link[data-page="agents"]')
        wait('document.querySelector(".nav-link.active")?.dataset.page === "agents"', 'Sessions page did not settle.')

    def open_session(session_id):
        selector = '.session-title-btn[data-id="' + session_id + '"]'
        wait('!!document.querySelector(' + json.dumps(selector) + ')', 'Session is absent from All Projects.')
        click(selector)
        wait('!document.querySelector("#detail-drawer").classList.contains("hidden")', 'Session drawer did not open.')
        wait('!!document.querySelector("#session-plan-body")', 'Plan region did not mount.')

    def expect(rows, method, project, session_id, **expected):
        matches = [row for row in rows if row.get('method') == method and row.get('params', {}).get('id') == session_id]
        assert matches, 'Missing bridge request: ' + method
        row, params = matches[-1], matches[-1]['params']
        assert params.get('project') == project, method + ' omitted/misrouted explicit project: ' + repr(params)
        for key, target in expected.items():
            assert params.get(key) == target, method + ' wrong ' + key + ': ' + repr(params)
        assert not row.get('error'), method + ' failed through real bridge: ' + row.get('error', 'unknown error')
        return row

    def receipt(name):
        source = fixture / 'harness-rpc.jsonl'
        if source.is_file():
            (output / (name + '-rpc.jsonl')).write_bytes(source.read_bytes())

    def check(name, action):
        if name not in selected:
            return
        result = {'check': name, 'passed': False}
        call_start = len(calls())
        try:
            result.update(action() or {})
            result['passed'] = True
        except Exception as error:
            result['error'] = str(error)
            result['traceback'] = traceback.format_exc(limit=6)
        finally:
            try:
                result['pageErrors'] = value('window.__scopePageErrors || []')
                result['consoleErrors'] = value('window.__scopeConsoleErrors || []')
                result['browserBridgeCalls'] = [
                    {'method': row.get('method'), 'params': row.get('params'), 'error': row.get('error'), 'real': row.get('real')}
                    for row in calls()[call_start:]
                    if row.get('method', '').startswith('sessions.') or
                    (name in ('live-refresh-preserves-detail-intent', 'all-projects-live-anchor-and-stale-guards') and row.get('method') == 'dashboard.get')
                ]
                (output / (name + '-browser-bridge-calls.json')).write_text(
                    json.dumps(result['browserBridgeCalls'], ensure_ascii=False, indent=2) + '\n')
                browser('screenshot', str(output / (name + '.png')))
                (output / (name + '.txt')).write_text(browser('snapshot', '-i'))
            except Exception as artifact_error:
                result['artifactError'] = str(artifact_error)
            receipt(name)
            evidence['checks'].append(result)
            save()
            print(json.dumps(result, ensure_ascii=False), flush=True)

    try:
        evidence['sourceBefore'] = {name: sha(ui_source / name) for name in UI_FILES}
        evidence['binaryBefore'] = sha(binary)
        created = subprocess.run(['python3', str(ROOT / 'scripts/create-session-relations-fixture.py'), str(fixture),
                                  '--binary', str(binary)], capture_output=True, text=True, timeout=120)
        fixture_created = (fixture / 'store/.vela-ui-fixture.json').is_file()
        (output / 'fixture-creation.log').write_text(created.stdout + created.stderr)
        created.check_returncode()
        manifest = json.loads((fixture / 'fixture.json').read_text())
        harbor, beacon, relation = manifest['project'], manifest['routingProject'], manifest['sessionRelations']

        frozen_ui, frozen_helper = fixture / 'ui-snapshot', fixture / 'vela-frozen'
        frozen_ui.mkdir()
        copy_ui_resources(ui_source, frozen_ui, allow_development=True)
        shutil.copy2(binary, frozen_helper)
        evidence['frozenUIHashes'] = {name: sha(frozen_ui / name) for name in UI_FILES}
        evidence['frozenHelperSHA256'] = sha(frozen_helper)
        assert evidence['sourceBefore'] == evidence['frozenUIHashes']
        assert evidence['binaryBefore'] == evidence['frozenHelperSHA256']

        spec = importlib.util.spec_from_file_location('vela_browser_helpers', ROOT / 'scripts/test-ui-browser.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        init = """const page=await browser.newPage({viewport:{width:1280,height:720}});await page.addInitScript(()=>{window.__scopePageErrors=[];window.__scopeConsoleErrors=[];addEventListener('error',e=>window.__scopePageErrors.push(e.message||String(e.error)));addEventListener('unhandledrejection',e=>window.__scopePageErrors.push(String(e.reason)));const original=console.error.bind(console);console.error=(...items)=>{window.__scopeConsoleErrors.push(items.map(String).join(' '));original(...items);};});page.setDefaultTimeout(5000);"""
        driver_source = module.PLAYWRIGHT_DRIVER.replace(
            'const page=await browser.newPage({viewport:{width:1280,height:720}});page.setDefaultTimeout(5000);', init)
        driver_source = driver_source.replace(
            "else if(command==='press')await page.keyboard.press(args[0]);",
            "else if(command==='press')await page.keyboard.press(args[0]);else if(command==='wheel'){if(args[2])await page.locator(args[2]).hover();await page.mouse.wheel(Number(args[0]),Number(args[1]));}")
        server = subprocess.Popen(['python3', str(ROOT / 'scripts/test-ui-server.py'), str(fixture / 'fixture.json'),
                                   '--binary', str(frozen_helper), '--ui-directory', str(frozen_ui)],
                                  stdout=subprocess.PIPE, text=True, start_new_session=True)
        if not select.select([server.stdout], [], [], 15)[0]:
            raise RuntimeError('Fixture server did not start.')
        url = json.loads(server.stdout.readline())['url']
        driver = subprocess.Popen(['node', '-e', driver_source, str(args.playwright_module.resolve()),
                                   str(args.browser_executable.resolve())], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True, start_new_session=True)
        browser('open', url)
        browser('wait', '#project-selector')
        reset_all_projects()
        # The wrapper logs a real bridge completion/error before it may hold a
        # result. A post-hold failure is deliberate test transport, never data.
        value("""(()=>{window.__scopeCalls=[];window.__scopeOriginal=window.vela.call;window.vela.call=async(method,params={})=>{let result,error;try{result=await window.__scopeOriginal(method,params);window.__scopeCalls.push({method,params,result,real:true});}catch(e){error=String(e?.message||e);window.__scopeCalls.push({method,params,error,real:true});}const hold=window.__scopeHold;if(hold&&hold.method===method&&(!hold.id||hold.id===params.id)){window.__scopeHold=null;window.__scopeHeld={method,params,hadRealError:!!error};await new Promise(resolve=>window.__scopeRelease=resolve);window.__scopeHeld=null;if(hold.fail)throw Error('Test hold failure after real bridge result');}if(error)throw Error(error);return result;};return true})()""")

        harbor_id = relation['parentSourceId']
        harbor_rows = rpc('sessions.list', {'project': harbor})
        assert any(row['id'] == harbor_id for row in harbor_rows)
        harbor_secondary = next(row['id'] for row in harbor_rows if row['id'] != harbor_id)
        beacon_rows = rpc('sessions.list', {'project': beacon})
        assert beacon_rows, 'Relation fixture did not expose a Beacon session.'
        beacon_id = beacon_rows[0]['id']

        def plan(project, session_id):
            reset_all_projects()
            start = len(calls())
            open_session(session_id)
            wait('window.__scopeCalls.slice(' + str(start) + ').some(x=>x.method==="sessions.plan.get"&&x.params.id===' + json.dumps(session_id) + ')',
                 'Plan did not reach the real bridge.')
            get = expect(calls()[start:], 'sessions.plan.get', project, session_id)
            wait('!!document.querySelector("#plan-events-container")', 'Plan response did not render event disclosure.')
            click('#plan-events-container > summary')
            wait('document.querySelector("#plan-events-container").open', 'Plan event disclosure did not open.')
            click('#btn-load-plan-events')
            wait('window.__scopeCalls.slice(' + str(start) + ').some(x=>x.method==="sessions.plan.events"&&x.params.id===' + json.dumps(session_id) + ')',
                 'Plan events did not reach the real bridge.')
            events = expect(calls()[start:], 'sessions.plan.events', project, session_id, afterSequence=0, limit=50)
            wait('!!document.querySelector("#plan-events-body")', 'Plan event response did not render.')
            return {'sessionId': session_id, 'planRequest': get['params'], 'eventsRequest': events['params']}

        check('all-projects-harbor-plan', lambda: plan(harbor, harbor_id))
        check('all-projects-beacon-plan', lambda: plan(beacon, beacon_id))

        def relations():
            reset_all_projects()
            start = len(calls())
            open_session(harbor_id)
            click('#session-relations-summary')
            wait('document.querySelector("#session-relations-section").open', 'Relations disclosure did not open.')
            wait('window.__scopeCalls.slice(' + str(start) + ').some(x=>x.method==="sessions.relations.get")',
                 'Relations did not reach real bridge.')
            get = expect(calls()[start:], 'sessions.relations.get', harbor, harbor_id)
            wait('window.__scopeCalls.slice(' + str(start) + ').some(x=>x.method==="sessions.relations.children")',
                 'First relation-child page did not reach real bridge.')
            first = calls()[start:]
            child1 = expect(first, 'sessions.relations.children', harbor, harbor_id, limit=20)
            wait('!!document.querySelector("#btn-load-more-relation-children")', 'No child continuation.')
            click('#btn-load-more-relation-children')
            wait('window.__scopeCalls.filter(x=>x.method==="sessions.relations.children").length >= 2', 'No second child page.')
            child2 = expect(calls('sessions.relations.children'), 'sessions.relations.children', harbor, harbor_id, limit=20)
            assert child2['params'].get('after') and child2['params']['after'] != child1['params'].get('after'), 'Child page cursor did not advance.'
            click('#session-relation-events-summary')
            wait('!!document.querySelector("#session-relation-events-container").open', 'Relation event disclosure did not open.')
            wait('window.__scopeCalls.some(x=>x.method==="sessions.relations.events")', 'No first event page.')
            event1 = expect(calls('sessions.relations.events'), 'sessions.relations.events', harbor, harbor_id, limit=50)
            assert event1['params'].get('afterSequence', 0) == 0, 'First relation-event request must use the public default cursor.'
            wait('!!document.querySelector("#btn-load-more-relation-events")', 'No event continuation.')
            click('#btn-load-more-relation-events')
            wait('window.__scopeCalls.filter(x=>x.method==="sessions.relations.events").length >= 2', 'No second event page.')
            event2 = expect(calls('sessions.relations.events'), 'sessions.relations.events', harbor, harbor_id, limit=50)
            assert event2['params'].get('afterSequence') and event2['params']['afterSequence'] != event1['params'].get('afterSequence'), 'Event page cursor did not advance.'
            return {'getRequest': get['params'], 'childrenFirst': child1['params'], 'childrenSecond': child2['params'],
                    'eventsFirst': event1['params'], 'eventsSecond': event2['params']}

        check('all-projects-codex-relations-pagination', relations)

        def stale():
            browser('select', '#project-selector', harbor)
            wait('document.querySelector("#project-selector").value===' + json.dumps(harbor), 'Harbor scope did not settle.')
            click('.nav-link[data-page="agents"]')
            wait('document.querySelector(".nav-link.active")?.dataset.page === "agents"', 'Harbor Sessions page did not settle.')
            open_session(harbor_id)
            wait('!!document.querySelector("#btn-refresh-session-plan")', 'Plan refresh did not render.')
            value('(()=>{window.__scopeHold={method:"sessions.plan.get",id:' + json.dumps(harbor_id) + '};return true})()')
            click('#btn-refresh-session-plan')
            wait('!!window.__scopeHeld', 'Successful real bridge result was not held.')
            held = value('window.__scopeHeld')
            assert held['hadRealError'] is False, 'Success hold requires a completed real bridge result.'
            open_session(harbor_secondary)
            value('(()=>{window.__scopeRelease();return true})()')
            wait('!window.__scopeHeld', 'Held successful result did not release.')
            assert value('document.querySelector("#detail-drawer").textContent.includes(' + json.dumps(harbor_id) + ')') is False, 'Late success rewrote the new session drawer.'
            browser('select', '#project-selector', beacon)
            wait('document.querySelector("#project-selector").value===' + json.dumps(beacon), 'Beacon scope did not settle.')
            click('.nav-link[data-page="agents"]')
            wait('document.querySelector(".nav-link.active")?.dataset.page === "agents"', 'Beacon Sessions page did not settle.')
            open_session(beacon_id)
            value('(()=>{window.__scopeHold={method:"sessions.plan.get",id:' + json.dumps(beacon_id) + ',fail:true};return true})()')
            click('#btn-refresh-session-plan')
            wait('!!window.__scopeHeld', 'Second real bridge result was not held.')
            browser('select', '#project-selector', harbor)
            wait('document.querySelector("#project-selector").value===' + json.dumps(harbor), 'Rapid project change did not settle.')
            before_release = value('document.querySelector("#detail-drawer").textContent')
            value('(()=>{window.__scopeRelease();return true})()')
            wait('!window.__scopeHeld', 'Held failure did not release.')
            assert value('document.querySelector("#detail-drawer").textContent') == before_release, 'Late failure rewrote changed project view.'
            return {'successfulHold': held, 'lateSuccessIgnored': True, 'lateFailureIgnoredAfterProjectChange': True}

        check('stale-bridge-results', stale)

        def live_refresh_preserves_detail_intent():
            # This journey deliberately selects Harbor: All Projects scope is
            # covered above, while this check needs successful real paged data.
            browser('select', '#project-selector', harbor)
            wait('document.querySelector("#project-selector").value===' + json.dumps(harbor), 'Harbor scope did not settle.')
            click('.nav-link[data-page="agents"]')
            wait('document.querySelector(".nav-link.active")?.dataset.page === "agents"', 'Harbor Sessions page did not settle.')
            open_session(harbor_id)
            wait('!!document.querySelector("#plan-events-container")', 'Plan event disclosure did not render.')
            click('#plan-events-container > summary')
            wait('document.querySelector("#plan-events-container").open', 'Plan event disclosure did not open.')
            click('#btn-load-plan-events')
            wait('window.__scopeCalls.some(x=>x.method==="sessions.plan.events"&&x.params.id===' + json.dumps(harbor_id) + ')',
                 'Plan events did not use the real bridge.')

            click('#session-relations-summary')
            wait('document.querySelector("#session-relations-section").open', 'Relations disclosure did not open.')
            wait('!!document.querySelector("#btn-load-more-relation-children")', 'First relation-child page did not render.')
            children_before_more = len(calls('sessions.relations.children'))
            click('#btn-load-more-relation-children')
            wait('window.__scopeCalls.filter(x=>x.method==="sessions.relations.children").length>' + str(children_before_more),
                 'Second real relation-child page did not load.')
            old_child_cursor = calls('sessions.relations.children')[-1]['params'].get('after')
            assert old_child_cursor, 'Fixture did not produce an old child cursor.'

            click('#session-relation-events-summary')
            wait('document.querySelector("#session-relation-events-container").open', 'Relation event disclosure did not open.')
            wait('!!document.querySelector("#btn-load-more-relation-events")', 'First relation-event page did not render.')
            events_before_more = len(calls('sessions.relations.events'))
            click('#btn-load-more-relation-events')
            wait('window.__scopeCalls.filter(x=>x.method==="sessions.relations.events").length>' + str(events_before_more),
                 'Second real relation-event page did not load.')
            old_event_cursor = calls('sessions.relations.events')[-1]['params'].get('afterSequence')
            assert old_event_cursor, 'Fixture did not produce an old event cursor.'

            anchor_before = value("""(()=>{const body=document.querySelector('#drawer-content'),anchor=document.querySelector('#session-relations-summary');body.scrollTop=Math.max(1,anchor.offsetTop-32);return {scrollTop:body.scrollTop,relative:anchor.getBoundingClientRect().top-body.getBoundingClientRect().top};})()""")
            assert anchor_before['scrollTop'] > 0, 'Fixture content cannot establish a drawer scroll anchor.'

            parent_source = Path(relation['parentSourcePath'])
            original = parent_source.read_text()
            assert '"source": "cli"' in original, 'Fixture parent source lost its deterministic initial header.'
            parent_source.write_text(original.replace('"source": "cli"', '"source": {"subagent": "live-refresh"}', 1))
            expected_bytes = parent_source.stat().st_size

            def scoped_calls(method):
                return [row for row in calls(method) if row.get('params', {}).get('id') == harbor_id]

            def scoped_call_count_expression(method):
                return ('window.__scopeCalls.filter(x=>x.method===' + json.dumps(method) +
                        '&&x.params.id===' + json.dumps(harbor_id) + ').length')

            def live_dom_state():
                return value("""(()=>{const text=e=>e?e.textContent.trim().slice(0,240):null;
                    const details=(selector,bodySelector,itemSelector)=>{const e=document.querySelector(selector),b=document.querySelector(bodySelector);return {exists:!!e,open:!!e?.open,loaded:e?.dataset.loaded||null,bodyExists:!!b,bodyText:text(b),items:itemSelector?document.querySelectorAll(itemSelector).length:null};};
                    const drawer=document.querySelector('#detail-drawer'),selected=document.querySelector('.session-card.selected');
                    return {selectedSessionId:selected?.dataset.id||null,drawer:{exists:!!drawer,hidden:!!drawer?.classList.contains('hidden'),text:text(drawer)},plan:details('#plan-events-container','#plan-events-body','#plan-events-body > *'),relations:details('#session-relations-section','#session-relations-children-list','#session-relations-children-list > *'),relationEvents:details('#session-relation-events-container','#session-relation-events-body','#session-relation-events-container .session-relation-event-item')};})()""")

            # Every counter below is scoped to this same source session. A full
            # suite has already opened Harbor in earlier checks, so comparing a
            # global start count with a scoped wait would be invalid evidence.
            plan_call_start = len(scoped_calls('sessions.plan.events'))
            child_call_start = len(scoped_calls('sessions.relations.children'))
            event_call_start = len(scoped_calls('sessions.relations.events'))
            session_get_start = len(scoped_calls('sessions.get'))
            # Hold the actual periodic dashboard result only after the bridge
            # has returned it. No dashboard/session/relations payload is made up.
            value('(()=>{window.__scopeHold={method:"dashboard.get"};return true})()')
            rpc('sessions.refresh', {})
            wait('!!window.__scopeHeld', 'Data-change polling did not receive and hold an actual dashboard result.', seconds=15)
            held_dashboard = value('window.__scopeHeld')
            assert held_dashboard['method'] == 'dashboard.get' and held_dashboard['hadRealError'] is False, 'Dashboard hold did not follow a successful real bridge response.'
            value('(()=>{window.__scopeRelease();return true})()')
            wait('!window.__scopeHeld', 'Held dashboard result did not release.')
            wait(scoped_call_count_expression('sessions.get') + '>' + str(session_get_start),
                 'Periodic dashboard refresh did not fetch the current drawer source.', seconds=15)

            current = rpc('sessions.get', {'id': harbor_id})
            assert current.get('sourcePath') == str(parent_source), 'Live drawer no longer identifies the current parent source.'
            assert current.get('indexedBytes') == expected_bytes, 'Live drawer source was not rebuilt from the changed file.'
            evidence['liveRefreshAttempt'] = {
                'actualDashboardHold': held_dashboard,
                'currentSourcePath': current.get('sourcePath'),
                'currentIndexedBytes': current.get('indexedBytes'),
                'expectedIndexedBytes': expected_bytes,
                'oldCursors': {'children': old_child_cursor, 'events': old_event_cursor},
                'anchorBefore': anchor_before,
                'domBeforeFreshWait': live_dom_state(),
            }
            save()
            # sessions.get confirms only the drawer source. The renderer starts
            # its disclosure reads asynchronously, so wait for each real first
            # page to mount before judging expanded state or the scroll anchor.
            try:
                wait(scoped_call_count_expression('sessions.plan.events') + '>' + str(plan_call_start) + '&&document.querySelector("#plan-events-container")?.open===true&&!!document.querySelector("#plan-events-body")',
                     'Changed source did not remount the open Plan events first page.', seconds=15)
                wait(scoped_call_count_expression('sessions.relations.children') + '>' + str(child_call_start) + '&&document.querySelector("#session-relations-section")?.open===true&&!!document.querySelector("#session-relations-children-list")',
                     'Changed source did not remount the open relation-children first page.', seconds=15)
                wait(scoped_call_count_expression('sessions.relations.events') + '>' + str(event_call_start) + '&&document.querySelector("#session-relation-events-container")?.open===true&&document.querySelectorAll("#session-relation-events-container .session-relation-event-item").length>0',
                     'Changed source did not remount the open relation-events first page.', seconds=15)
            except Exception:
                evidence['liveRefreshAttempt'].update({'domAfterFreshWait': live_dom_state(), 'freshScopedCalls': {method: [row.get('params') for row in scoped_calls(method)[start:]] for method, start in (('sessions.plan.events', plan_call_start), ('sessions.relations.children', child_call_start), ('sessions.relations.events', event_call_start))}})
                save()
                raise
            evidence['liveRefreshAttempt'].update({'domAfterFreshWait': live_dom_state(), 'freshScopedCalls': {method: [row.get('params') for row in scoped_calls(method)[start:]] for method, start in (('sessions.plan.events', plan_call_start), ('sessions.relations.children', child_call_start), ('sessions.relations.events', event_call_start))}})
            save()
            assert value('document.querySelector("#session-relations-section").open'), 'Background detail rerender collapsed the Relations disclosure.'
            assert value('document.querySelector("#session-relation-events-container").open'), 'Background detail rerender collapsed the relation-events disclosure.'
            assert value('document.querySelector("#plan-events-container").open'), 'Background detail rerender collapsed the plan-events disclosure.'

            refreshed_children = scoped_calls('sessions.relations.children')[child_call_start:]
            refreshed_events = scoped_calls('sessions.relations.events')[event_call_start:]
            assert len(refreshed_children) == 1, 'Changed source issued duplicate relation-child first pages: ' + repr([row.get('params') for row in refreshed_children])
            assert len(refreshed_events) == 1, 'Changed source issued duplicate relation-event first pages: ' + repr([row.get('params') for row in refreshed_events])
            child_params, event_params = refreshed_children[0]['params'], refreshed_events[0]['params']
            assert child_params == {'project': harbor, 'id': harbor_id, 'limit': 20}, 'Changed source reused an old child cursor: ' + repr(child_params)
            assert event_params == {'project': harbor, 'id': harbor_id, 'limit': 50}, 'Changed source reused an old event cursor: ' + repr(event_params)
            assert child_params.get('after') != old_child_cursor and event_params.get('afterSequence') != old_event_cursor
            evidence['liveRefreshAttempt']['freshFirstPages'] = {'children': child_params, 'events': event_params}
            save()
            anchor_after = value("""(()=>{const body=document.querySelector('#drawer-content'),anchor=document.querySelector('#session-relations-summary');return {scrollTop:body.scrollTop,relative:anchor.getBoundingClientRect().top-body.getBoundingClientRect().top};})()""")
            evidence['liveRefreshAttempt'].update({'anchorAfter': anchor_after, 'domAtAnchorCheck': live_dom_state()})
            save()
            assert abs(anchor_after['relative'] - anchor_before['relative']) <= 3, 'Background detail rerender lost the drawer page anchor.'
            return {'actualDashboardHold': held_dashboard, 'sourceBytes': expected_bytes,
                    'oldCursors': {'children': old_child_cursor, 'events': old_event_cursor},
                    'freshFirstPages': {'children': child_params, 'events': event_params},
                    'anchorBefore': anchor_before, 'anchorAfter': anchor_after}

        check('live-refresh-preserves-detail-intent', live_refresh_preserves_detail_intent)

        def all_projects_live_anchor_and_stale_guards():
            # This is intentionally independent of the selected-project live
            # path above: an All Projects drawer must retain the source's real
            # project for every deferred detail read.
            parent_source = Path(relation['parentSourcePath'])

            def scoped_calls(method):
                return [row for row in calls(method) if row.get('params', {}).get('id') == harbor_id]

            def scoped_count_expression(method):
                return ('window.__scopeCalls.filter(x=>x.method===' + json.dumps(method) +
                        '&&x.params.id===' + json.dumps(harbor_id) + ').length')

            def prepare_parent_drawer():
                reset_all_projects()
                assert value('document.querySelector("#project-selector").value') == '', 'All Projects scope was not retained.'
                open_session(harbor_id)
                plan_start = len(scoped_calls('sessions.plan.events'))
                wait('!!document.querySelector("#plan-events-container")', 'All Projects plan disclosure did not render.')
                click('#plan-events-container > summary')
                wait('document.querySelector("#plan-events-container").open', 'All Projects plan disclosure did not open.')
                click('#btn-load-plan-events')
                wait(scoped_count_expression('sessions.plan.events') + '>' + str(plan_start),
                     'All Projects initial Plan events did not reach the real bridge.')

                child_start = len(scoped_calls('sessions.relations.children'))
                click('#session-relations-summary')
                wait('document.querySelector("#session-relations-section").open', 'All Projects relations disclosure did not open.')
                wait(scoped_count_expression('sessions.relations.children') + '>' + str(child_start),
                     'All Projects initial relation children did not reach the real bridge.')

                event_start = len(scoped_calls('sessions.relations.events'))
                click('#session-relation-events-summary')
                wait('document.querySelector("#session-relation-events-container").open', 'All Projects relation events disclosure did not open.')
                wait(scoped_count_expression('sessions.relations.events') + '>' + str(event_start),
                     'All Projects initial relation events did not reach the real bridge.')
                anchor = value("""(()=>{const body=document.querySelector('#drawer-content'),anchor=document.querySelector('#session-relations-summary');body.scrollTop=Math.max(1,anchor.offsetTop-32);return {scrollTop:body.scrollTop,relative:anchor.getBoundingClientRect().top-body.getBoundingClientRect().top};})()""")
                assert anchor['scrollTop'] > 0, 'All Projects fixture cannot establish a drawer anchor.'
                return anchor

            source_revision = [0]

            def bump_real_source():
                # Change the real JSONL header, rather than adding whitespace
                # that the helper may intentionally ignore in its fingerprint.
                source_revision[0] += 1
                original = parent_source.read_text()
                replacement = ('"source": {"subagent": "all-projects-anchor-' + str(source_revision[0]) +
                               '-' + ('x' * source_revision[0]) + '"}')
                updated, changes = re.subn(r'"source"\s*:\s*(?:"cli"|\{\s*"subagent"\s*:\s*"[^"]+"\s*\})', replacement, original, count=1)
                assert changes == 1, 'Fixture parent source lacks a mutable deterministic source header.'
                parent_source.write_text(updated)
                return parent_source.stat().st_size

            def hold_parent_live_response():
                plan_start = len(scoped_calls('sessions.plan.events'))
                child_start = len(scoped_calls('sessions.relations.children'))
                event_start = len(scoped_calls('sessions.relations.events'))
                value('(()=>{window.__scopeHold={method:"sessions.get",id:' + json.dumps(harbor_id) + '};return true})()')
                rpc('sessions.refresh', {})
                wait('!!window.__scopeHeld', 'All Projects data change did not reach a held actual sessions.get response.', seconds=15)
                held = value('window.__scopeHeld')
                assert held == {'method': 'sessions.get', 'params': {'id': harbor_id}, 'hadRealError': False}, 'Held response was not the successful real parent read: ' + repr(held)
                return held, plan_start, child_start, event_start

            def release_and_assert_fresh(plan_start, child_start, event_start):
                value('(()=>{window.__scopeRelease();return true})()')
                wait('!window.__scopeHeld', 'Held All Projects live response did not release.')
                wait(scoped_count_expression('sessions.plan.events') + '>' + str(plan_start) + '&&document.querySelector("#plan-events-container")?.open===true&&!!document.querySelector("#plan-events-body")',
                     'All Projects refresh did not remount Plan events.', seconds=15)
                wait(scoped_count_expression('sessions.relations.children') + '>' + str(child_start) + '&&document.querySelector("#session-relations-section")?.open===true&&!!document.querySelector("#session-relations-children-list")',
                     'All Projects refresh did not remount relation children.', seconds=15)
                wait(scoped_count_expression('sessions.relations.events') + '>' + str(event_start) + '&&document.querySelector("#session-relation-events-container")?.open===true&&document.querySelectorAll("#session-relation-events-container .session-relation-event-item").length>0',
                     'All Projects refresh did not remount relation events.', seconds=15)
                plan = scoped_calls('sessions.plan.events')[plan_start:]
                children = scoped_calls('sessions.relations.children')[child_start:]
                events = scoped_calls('sessions.relations.events')[event_start:]
                assert len(plan) == len(children) == len(events) == 1, 'All Projects refresh duplicated a first-page read: ' + repr({'plan': [x['params'] for x in plan], 'children': [x['params'] for x in children], 'events': [x['params'] for x in events]})
                expected_plan = {'project': harbor, 'id': harbor_id, 'afterSequence': 0, 'limit': 50}
                expected_children = {'project': harbor, 'id': harbor_id, 'limit': 20}
                expected_events = {'project': harbor, 'id': harbor_id, 'limit': 50}
                assert plan[0]['params'] == expected_plan, 'All Projects live Plan read lost source project/cursor: ' + repr(plan[0]['params'])
                assert children[0]['params'] == expected_children, 'All Projects live child read reused a cursor or lost source project: ' + repr(children[0]['params'])
                assert events[0]['params'] == expected_events, 'All Projects live event read reused a cursor or lost source project: ' + repr(events[0]['params'])
                return {'plan': plan[0]['params'], 'children': children[0]['params'], 'events': events[0]['params']}

            anchor_before = prepare_parent_drawer()
            source_bytes = bump_real_source()
            held, plan_start, child_start, event_start = hold_parent_live_response()
            # Playwright sends an actual pointer wheel event to the open drawer
            # while the real sessions.get result is intentionally held.
            browser('wheel', '0', '360', '#drawer-content')
            wait('document.querySelector("#drawer-content").scrollTop !== ' + str(anchor_before['scrollTop']),
                 'User wheel did not change the drawer scroll position during the held response.')
            wheel_intent = value("""(()=>{const body=document.querySelector('#drawer-content'),anchor=document.querySelector('#session-relations-summary');return {scrollTop:body.scrollTop,relative:anchor.getBoundingClientRect().top-body.getBoundingClientRect().top};})()""")
            fresh = release_and_assert_fresh(plan_start, child_start, event_start)
            wheel_after = value("""(()=>{const body=document.querySelector('#drawer-content'),anchor=document.querySelector('#session-relations-summary');return {scrollTop:body.scrollTop,relative:anchor.getBoundingClientRect().top-body.getBoundingClientRect().top};})()""")
            assert abs(wheel_after['scrollTop'] - wheel_intent['scrollTop']) <= 3, 'Held response overwrote the user wheel intent: ' + repr({'intent': wheel_intent, 'after': wheel_after})

            # Unlike the sessions.get hold above, relations.get begins only
            # after checkAndTriggerLiveSessionUpdate captured its anchor and
            # rebuilt the drawer. Wheel input while this nested real result is
            # held must cancel that already-established anchor before the
            # loader renders and attempts a realignment.
            nested_anchor_before = prepare_parent_drawer()
            nested_source_bytes = bump_real_source()
            value('(()=>{window.__scopeHold={method:"sessions.relations.get",id:' + json.dumps(harbor_id) + '};return true})()')
            rpc('sessions.refresh', {})
            wait('!!window.__scopeHeld', 'Changed source did not reach a held actual relation read after live drawer rebuild.', seconds=15)
            nested_held = value('window.__scopeHeld')
            assert nested_held == {'method': 'sessions.relations.get', 'params': {'project': harbor, 'id': harbor_id}, 'hadRealError': False}, 'Held nested response was not the successful real relation read: ' + repr(nested_held)
            browser('wheel', '0', '360', '#drawer-content')
            wait('document.querySelector("#drawer-content").scrollTop !== ' + str(nested_anchor_before['scrollTop']),
                 'User wheel did not change drawer scroll during the held nested loader response.')
            nested_wheel_intent = value("""(()=>{const body=document.querySelector('#drawer-content'),anchor=document.querySelector('#session-relations-summary');return {scrollTop:body.scrollTop,relative:anchor.getBoundingClientRect().top-body.getBoundingClientRect().top};})()""")
            value('(()=>{window.__scopeRelease();return true})()')
            wait('!window.__scopeHeld', 'Held nested relation response did not release.')
            wait('document.querySelector("#session-relations-section")?.open===true&&!!document.querySelector("#session-relations-children-list")',
                 'Nested relation response did not render its real first page after release.', seconds=15)
            nested_wheel_after = value("""(()=>{const body=document.querySelector('#drawer-content'),anchor=document.querySelector('#session-relations-summary');return {scrollTop:body.scrollTop,relative:anchor.getBoundingClientRect().top-body.getBoundingClientRect().top};})()""")
            assert abs(nested_wheel_after['scrollTop'] - nested_wheel_intent['scrollTop']) <= 3, 'Nested loader realigned to an obsolete anchor after user wheel: ' + repr({'intent': nested_wheel_intent, 'after': nested_wheel_after})

            # A held parent response must not overwrite a newly opened session.
            bump_real_source()
            held_session, _, _, _ = hold_parent_live_response()
            open_session(harbor_secondary)
            wait('document.querySelector(".session-card.selected")?.dataset.id===' + json.dumps(harbor_secondary), 'New session did not become selected while old live response was held.')
            value('(()=>{window.__scopeRelease();return true})()')
            wait('!window.__scopeHeld', 'Held response did not release after session switch.')
            session_guard = value("""(()=>{const drawer=document.querySelector('#detail-drawer');return {selected:document.querySelector('.session-card.selected')?.dataset.id||null,drawerHidden:!!drawer?.classList.contains('hidden'),drawerText:drawer?.textContent||''};})()""")
            assert session_guard['selected'] == harbor_secondary and 'relations-parent' not in session_guard['drawerText'], 'Held parent response overwrote the newly selected session: ' + repr(session_guard)

            # A project selector change closes the old drawer; the deferred
            # parent result must not restore it after release.
            reset_all_projects()
            open_session(harbor_id)
            bump_real_source()
            held_project, _, _, _ = hold_parent_live_response()
            browser('select', '#project-selector', beacon)
            wait('document.querySelector("#project-selector").value===' + json.dumps(beacon), 'Project switch did not settle while live response was held.')
            wait('document.querySelector("#detail-drawer").classList.contains("hidden")', 'Project switch did not close the stale parent drawer.')
            value('(()=>{window.__scopeRelease();return true})()')
            wait('!window.__scopeHeld', 'Held response did not release after project switch.')
            project_guard = value("""(()=>{const drawer=document.querySelector('#detail-drawer');return {project:document.querySelector('#project-selector').value,drawerHidden:!!drawer?.classList.contains('hidden'),selected:document.querySelector('.session-card.selected')?.dataset.id||null};})()""")
            assert project_guard == {'project': beacon, 'drawerHidden': True, 'selected': None}, 'Held parent response rewrote the changed project view: ' + repr(project_guard)
            return {'sourceBytes': source_bytes, 'actualHeldResponse': held, 'freshFirstPages': fresh,
                    'anchorBefore': anchor_before, 'wheelIntent': wheel_intent, 'wheelAfter': wheel_after,
                    'nestedSourceBytes': nested_source_bytes, 'nestedLoaderHeld': nested_held,
                    'nestedAnchorBefore': nested_anchor_before, 'nestedWheelIntent': nested_wheel_intent,
                    'nestedWheelAfter': nested_wheel_after,
                    'sessionGuardHeld': held_session, 'sessionGuard': session_guard,
                    'projectGuardHeld': held_project, 'projectGuard': project_guard}

        check('all-projects-live-anchor-and-stale-guards', all_projects_live_anchor_and_stale_guards)

        def open_search():
            reset_all_projects()
            browser('press', 'Meta+k')
            wait('!!document.querySelector("#search-results-list")', 'Search + Actions did not open.')

        def listbox():
            open_search()
            click('#tab-mode-actions')
            wait('document.querySelector("#tab-mode-actions").getAttribute("aria-selected")==="true"', 'Actions tab did not activate.')
            wait('document.querySelectorAll("#search-results-list [role=option]").length > 1', 'Action options did not render.')
            before = value("""(()=>{const l=document.querySelector('#search-results-list'),i=document.querySelector('#global-search-input'),o=[...l.querySelectorAll('[role=option]')];return {rootRole:l.getAttribute('role'),nestedListboxes:l.querySelectorAll('[role=listbox]').length,totalListboxes:document.querySelectorAll('[role=listbox]').length,direct:o.every(x=>x.parentElement===l),options:o.map(x=>({id:x.id,selected:x.getAttribute('aria-selected')})),controls:i.getAttribute('aria-controls'),active:i.getAttribute('aria-activedescendant')};})()""")
            assert before['rootRole'] == 'listbox', 'Search result root is not the controlled listbox.'
            assert before['nestedListboxes'] == 0, 'Nested listbox exists.'
            assert before['totalListboxes'] == 1, 'Search modal does not expose one listbox tree.'
            assert before['direct'], 'Options are not direct #search-results-list children.'
            assert before['controls'] == 'search-results-list', 'Combobox controls wrong listbox.'
            assert before['active'] == before['options'][0]['id'] and before['options'][0]['selected'] == 'true', 'Initial option ARIA is unsynchronized.'
            browser('focus', '#global-search-input')
            browser('press', 'ArrowDown')
            after = value("""(()=>{const i=document.querySelector('#global-search-input'),o=[...document.querySelectorAll('#search-results-list > [role=option]')];return {active:i.getAttribute('aria-activedescendant'),selected:o.filter(x=>x.getAttribute('aria-selected')==='true').map(x=>x.id)};})()""")
            assert after['active'] == before['options'][1]['id'] and after['selected'] == [before['options'][1]['id']], 'ArrowDown did not update active option ARIA.'

            # A new nonempty query must synchronously clear old options and the
            # active descendant. ArrowDown/Enter in that interval may issue the
            # new real search, but must never select an old result.
            click('#tab-mode-search')
            wait('document.querySelector("#tab-mode-search").getAttribute("aria-selected")==="true"', 'Search tab did not activate.')
            initial_query = 'Harbor'
            before_initial_search = len(calls('search'))
            browser('fill', '#global-search-input', initial_query)
            browser('focus', '#global-search-input')
            browser('press', 'Enter')
            wait('window.__scopeCalls.filter(x=>x.method==="search"&&x.params.query===' + json.dumps(initial_query) + ').length>' + str(before_initial_search),
                 'Initial query did not reach the real search bridge.')
            initial_search = [row for row in calls('search') if row.get('params', {}).get('query') == initial_query][-1]
            assert not initial_search.get('error'), 'Initial search bridge failed: ' + repr(initial_search)
            wait('document.querySelectorAll("#search-results-list > [role=option]").length>0', 'Initial real query rendered no selectable result.')
            old_options = value('[...document.querySelectorAll("#search-results-list > [role=option]")].map(x=>x.id)')
            browser('focus', '#global-search-input')
            browser('press', 'ArrowDown')
            wait('document.querySelector("#global-search-input").getAttribute("aria-activedescendant")===' + json.dumps(old_options[0]),
                 'Initial real result did not become the active option.')

            new_query = 'vela-query-stale-option-guard'
            before_new_search = len([row for row in calls('search') if row.get('params', {}).get('query') == new_query])
            before_session_get = len(calls('sessions.get'))
            browser('fill', '#global-search-input', new_query)
            wait('document.querySelectorAll("#search-results-list > [role=option]").length===0&&!document.querySelector("#global-search-input").hasAttribute("aria-activedescendant")',
                 'New nonempty query retained old options or aria-activedescendant.')
            browser('focus', '#global-search-input')
            browser('press', 'ArrowDown')
            assert value('!document.querySelector("#global-search-input").hasAttribute("aria-activedescendant")'), 'ArrowDown reactivated a stale result after query replacement.'
            assert value('document.querySelectorAll("#search-results-list > [role=option]").length===0'), 'ArrowDown restored stale result options after query replacement.'
            browser('press', 'Enter')
            wait('window.__scopeCalls.filter(x=>x.method==="search"&&x.params.query===' + json.dumps(new_query) + ').length>' + str(before_new_search),
                 'Enter did not send the replacement query to the real search bridge.')
            replacement_search = [row for row in calls('search') if row.get('params', {}).get('query') == new_query][-1]
            assert not replacement_search.get('error'), 'Replacement search bridge failed: ' + repr(replacement_search)
            assert len(calls('sessions.get')) == before_session_get, 'ArrowDown/Enter activated an old search result instead of only querying replacement text.'
            wait('!document.querySelector("#global-search-input").hasAttribute("aria-activedescendant")',
                 'Replacement query left a stale aria-activedescendant after its response.')
            return {'initial': before, 'afterArrowDown': after,
                    'queryReplacement': {'oldOptions': old_options, 'newQuery': new_query,
                                         'initialSearch': initial_search['params'], 'replacementSearch': replacement_search['params'],
                                         'oldResultActivationBlocked': True}}

        check('search-actions-listbox', listbox)

        def tablist():
            open_search()
            def assert_tab_state(expected, trigger):
                state = value("""(()=>{const tabs=[...document.querySelectorAll('#tab-mode-search,#tab-mode-actions')].map(t=>{const p=document.getElementById(t.getAttribute('aria-controls'));return {id:t.id,selected:t.getAttribute('aria-selected'),active:t.classList.contains('active'),controls:t.getAttribute('aria-controls'),panelExists:!!p,panelHidden:!!p?.hidden,panelClassHidden:!!p?.classList.contains('hidden')};});return {tabs,active:document.activeElement?.id};})()""")
                for tab in state['tabs']:
                    assert tab['controls'], tab['id'] + ' lacks aria-controls.'
                    assert tab['panelExists'], tab['id'] + ' controls no actual tabpanel.'
                    selected = tab['id'] == expected
                    assert tab['selected'] == str(selected).lower(), trigger + ' did not synchronize aria-selected for ' + tab['id'] + ': ' + repr(tab)
                    assert tab['active'] is selected, trigger + ' did not synchronize active class for ' + tab['id'] + ': ' + repr(tab)
                    assert tab['panelHidden'] is (not selected) and tab['panelClassHidden'] is (not selected), trigger + ' did not synchronize visible panel for ' + tab['id'] + ': ' + repr(tab)
                return state

            initial = assert_tab_state('tab-mode-search', 'initial render')
            for tab in initial['tabs']:
                panel = 'document.getElementById(' + json.dumps(tab['controls']) + ')'
                assert value(panel + '.getAttribute("role")==="tabpanel"'), tab['id'] + ' controls no actual tabpanel.'
            click('#tab-mode-actions')
            click_actions = assert_tab_state('tab-mode-actions', 'Actions click')
            click('#tab-mode-search')
            click_search = assert_tab_state('tab-mode-search', 'Search click')
            browser('focus', '#tab-mode-search')
            keyboard = []
            for key, target in (('ArrowRight', 'tab-mode-actions'), ('Home', 'tab-mode-search'), ('End', 'tab-mode-actions'), ('ArrowLeft', 'tab-mode-search')):
                browser('press', key)
                wait('document.activeElement===document.querySelector("#' + target + '")', key + ' did not move tab focus.')
                keyboard.append({'key': key, 'state': assert_tab_state(target, key)})

            # Match the native keyboard route: leave the query input backwards
            # to its tab, switch mode, return to the relocated input, then move
            # the action list selection. All transitions use the actual UI.
            browser('focus', '#global-search-input')
            browser('press', 'Shift+Tab')
            wait('document.activeElement===document.querySelector("#tab-mode-search")', 'Shift+Tab did not reach the Search tab from the input.')
            browser('press', 'ArrowRight')
            native_mode = assert_tab_state('tab-mode-actions', 'input Shift+Tab then ArrowRight')
            wait('document.activeElement===document.querySelector("#tab-mode-actions")', 'ArrowRight did not retain focus on the Actions tab.')
            browser('press', 'Tab')
            wait('document.activeElement===document.querySelector("#global-search-input")', 'Tab from Actions did not reach the relocated input.')
            before_action_down = value("""(()=>{const i=document.querySelector('#global-search-input'),o=[...document.querySelectorAll('#search-results-list > [role=option]')];return {active:i.getAttribute('aria-activedescendant'),selected:o.filter(x=>x.getAttribute('aria-selected')==='true').map(x=>x.id),options:o.map(x=>x.id)};})()""")
            browser('press', 'ArrowDown')
            wait('document.querySelector("#global-search-input").getAttribute("aria-activedescendant")!=='+json.dumps(before_action_down['active']), 'ArrowDown from relocated Actions input did not move active descendant.')
            native_down = value("""(()=>{const i=document.querySelector('#global-search-input'),o=[...document.querySelectorAll('#search-results-list > [role=option]')];return {active:i.getAttribute('aria-activedescendant'),selected:o.filter(x=>x.getAttribute('aria-selected')==='true').map(x=>x.id)};})()""")
            assert native_down['selected'] == [native_down['active']], 'ArrowDown left Actions aria-selected out of sync with active descendant.'
            return {'initialTabs': initial, 'clickActions': click_actions, 'clickSearch': click_search,
                    'keys': keyboard, 'nativeKeyboardPath': {'beforeArrowDown': before_action_down,
                    'afterArrowDown': native_down, 'actionsState': native_mode}}

        check('search-actions-tablist', tablist)
    finally:
        try:
            if 'ui_source' in locals():
                evidence['sourceAfter'] = {name: sha(ui_source / name) for name in UI_FILES}
                evidence['binaryAfter'] = sha(binary)
                evidence['sourceUnchanged'] = (evidence['sourceAfter'] == evidence.get('sourceBefore') and
                                               evidence['binaryAfter'] == evidence.get('binaryBefore'))
                save()
        finally:
            stop(driver)
            stop(server)
            if fixture_created:
                shutil.rmtree(fixture)
    failed = [item['check'] for item in evidence['checks'] if not item['passed']]
    if failed:
        raise SystemExit('Failed checks: ' + ', '.join(failed))


if __name__ == '__main__':
    main()
