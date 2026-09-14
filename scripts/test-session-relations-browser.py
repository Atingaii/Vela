"""Renderer acceptance for UI15 observed Codex session relations.

This runner is deliberately inert until a frozen UI directory is supplied. It
uses a newly-created synthetic fixture, a copied helper and the capability
scoped test bridge; no user store, provider, workflow, or native notification
is opened.  --checks is only for failure diagnosis and never marks a full suite.
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
CHECKS = ('hierarchy-and-privacy', 'reported-is-not-child', 'event-pagination',
          'stale-and-duplicate-guards', 'locale-and-supported-size')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ui-directory', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True, help='New immediate .task-tmp child; removed after testing.')
    parser.add_argument('--output', type=Path, required=True, help='New retained child of output/playwright.')
    parser.add_argument('--browser-executable', type=Path, required=True)
    parser.add_argument('--frozen-selectors', action='store_true', help='Required for an actual UI15 run.')
    parser.add_argument('--checks', help='Comma-separated diagnostic subset; omit for all relation journeys.')
    args = parser.parse_args()
    if not args.frozen_selectors:
        parser.error('UI15 is not accepted without frozen stable selectors.')
    selected = set(args.checks.split(',')) if args.checks else set(CHECKS)
    if not selected or not selected <= set(CHECKS): parser.error('unknown or empty --checks')
    base, output = args.fixture.absolute(), args.output.absolute()
    ui_source, binary = args.ui_directory.resolve(strict=True), args.binary.resolve(strict=True)
    if base.exists() or base.is_symlink() or base.parent != (ROOT / '.task-tmp').resolve(): parser.error('fixture must be a new immediate .task-tmp child')
    if output.exists() or output.is_symlink() or output.parent.resolve() != (ROOT / 'output/playwright').resolve(): parser.error('output must be a new output/playwright child')
    if not args.browser_executable.is_file(): parser.error('browser executable is missing')
    for name in UI_FILES:
        if not (ui_source / name).is_file() or (ui_source / name).is_symlink(): parser.error('missing ordinary UI file: ' + name)
    output.mkdir(parents=True); (output / 'consumer-test-source.py').write_bytes(Path(__file__).read_bytes())
    evidence = {'format': 'vela-session-relations-renderer-v1', 'synthetic': True, 'completeSuite': False,
                'realProviderExecuted': False, 'workflowExecuted': False, 'nativeAudioClaimed': False,
                'sourceDirectory': str(ui_source), 'fixtureDirectory': str(base), 'selectedChecks': sorted(selected), 'checks': []}
    server = driver = None; fixture_created = False

    def hashes(directory): return {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in UI_FILES}
    def source_hashes(directory):
        root = directory.resolve(strict=True)
        assert not root.is_symlink() and root.stat().st_uid == os.getuid()
        return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted(root.rglob('*.jsonl')) if path.is_file() and not path.is_symlink()}
    def save(): (output / 'results.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')
    def browser(*arguments):
        driver.stdin.write(json.dumps(arguments) + '\n'); driver.stdin.flush()
        assert select.select([driver.stdout], [], [], 25)[0], 'browser timed out'
        result = json.loads(driver.stdout.readline()); assert 'error' not in result, result; return result.get('output', '')
    def value(js): return json.loads(browser('eval', js))
    def wait(js, reason, seconds=12):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            if value(js): return
            time.sleep(.06)
        raise AssertionError(reason)
    def click(selector): browser('snapshot', '-i'); browser('click', selector); browser('snapshot', '-i')
    def select_settings_category(category):
        selector = '[data-settings-category="' + category + '"]'
        wait('!!document.querySelector(' + json.dumps(selector) + ')', 'Settings category is unavailable: ' + category)
        click(selector)
        wait('document.querySelector(' + json.dumps(selector) + ').getAttribute("aria-pressed")==="true"&&document.querySelector("[data-settings-panel=\\"' + category + '\\"]")?.hidden===false',
             'Settings category did not become visible: ' + category)
    def calls(method): return value('window.__relationsCalls.filter(x=>x.method===' + json.dumps(method) + ')')
    def rpc(method, params):
        request = urllib.request.Request(url + '__rpc', json.dumps({'method': method, 'params': params}).encode(),
                                         {'Content-Type': 'application/json', 'Origin': 'http://' + url.split('/')[2]})
        with urllib.request.urlopen(request, timeout=25) as response: result = json.load(response)
        assert 'error' not in result, result
        return result['result']
    def check(name, fn):
        if name not in selected: return
        try:
            evidence['checks'].append({'check': name, 'passed': True, **(fn() or {})})
        except Exception as error:
            evidence['checks'].append({'check': name, 'passed': False, 'error': str(error), 'traceback': traceback.format_exc(limit=5)})
        finally:
            if name == 'stale-and-duplicate-guards':
                value('window.__relationsPauseDashboard=false;(window.__relationsPausedDashboards||[]).splice(0).forEach(resolve=>resolve());true')
        evidence['checks'][-1]['pageErrors'] = value('window.__relationsErrors || []')
        browser('screenshot', str(output / (name + '.png')))
        (output / (name + '.txt')).write_text(browser('snapshot', '-i'))
        print(json.dumps(evidence['checks'][-1], ensure_ascii=False), flush=True); save()

    try:
        evidence['sourceBefore'] = hashes(ui_source); evidence['binaryBefore'] = hashlib.sha256(binary.read_bytes()).hexdigest()
        created = subprocess.run(['python3', str(ROOT / 'scripts/create-session-relations-fixture.py'), str(base), '--binary', str(binary)], capture_output=True, text=True, timeout=120)
        fixture_created = (base / 'store/.vela-ui-fixture.json').is_file(); (output / 'fixture-creation.log').write_text(created.stdout + created.stderr); created.check_returncode()
        fixture = json.loads((base / 'fixture.json').read_text()); rel, project = fixture['sessionRelations'], fixture['project']
        evidence['fixtureSourcesBefore'] = source_hashes(Path(fixture['sessionRoot']))
        assert evidence['fixtureSourcesBefore'] == rel['allSourceFilesSHA256']
        ui, helper = base / 'ui-snapshot', base / 'vela-frozen'; ui.mkdir()
        copy_ui_resources(ui_source, ui, allow_development=True)
        shutil.copy2(binary, helper); evidence['fixtureSourceBefore'] = hashes(ui); evidence['fixtureBinaryBefore'] = hashlib.sha256(helper.read_bytes()).hexdigest()
        assert evidence['sourceBefore'] == evidence['fixtureSourceBefore'] and evidence['binaryBefore'] == evidence['fixtureBinaryBefore']
        spec = importlib.util.spec_from_file_location('vela_browser_helpers', ROOT / 'scripts/test-ui-browser.py'); module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        driver_source = module.PLAYWRIGHT_DRIVER.replace("const page=await browser.newPage({viewport:{width:1280,height:720}});page.setDefaultTimeout(5000);", "const page=await browser.newPage({viewport:{width:1280,height:720}});await page.addInitScript(()=>{window.__relationsErrors=[];addEventListener('error',e=>window.__relationsErrors.push(e.message));addEventListener('unhandledrejection',e=>window.__relationsErrors.push(String(e.reason)))});page.setDefaultTimeout(5000);").replace("else if(command==='select')", "else if(command==='resize'){await page.setViewportSize({width:args[0],height:args[1]});out='true';}\n      else if(command==='select')")
        server = subprocess.Popen(['python3', str(ROOT / 'scripts/test-ui-server.py'), str(base / 'fixture.json'), '--binary', str(helper), '--ui-directory', str(ui)], stdout=subprocess.PIPE, text=True)
        assert select.select([server.stdout], [], [], 15)[0], 'server did not start'; url = json.loads(server.stdout.readline())['url']
        driver = subprocess.Popen(['node', '-e', driver_source, str(ROOT / '.task-tmp/ui-browser-tools/node_modules/playwright/index.js'), str(args.browser_executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, start_new_session=True)
        browser('open', url); browser('wait', '#project-selector'); browser('select', '#project-selector', project)
        # The wrapper calls the real bridge first, then can hold exactly one selected
        # relation response. This exposes stale UI writes without manufacturing data.
        value("""window.__relationsCalls=[];window.__relationsDispatch=window.dispatchEvent.bind(window);window.dispatchEvent=(event)=>window.__relationsSuppressRefresh&&event?.type==='vela:refresh'?true:window.__relationsDispatch(event);window.__relationsOriginal=window.vela.call;window.vela.call=async(method,params={})=>{try{const result=await window.__relationsOriginal(method,params);window.__relationsCalls.push({method,params,result});if(method==='dashboard.get'&&window.__relationsPauseDashboard){await new Promise(resolve=>(window.__relationsPausedDashboards||(window.__relationsPausedDashboards=[])).push(resolve));}const hold=window.__relationsHold;if(hold&&hold.method===method&&(!hold.id||hold.id===params.id)){window.__relationsHold=null;window.__relationsHeld=true;await new Promise(resolve=>window.__relationsRelease=resolve);window.__relationsHeld=false;if(hold.fail)throw Error('Injected test-only relation failure after real result');}return result;}catch(error){window.__relationsCalls.push({method,params,error:error.message});throw error;}};true""")
        # Stable UI15 identifiers supplied by the author. Open the known parent
        # through the normal Sessions UI, then expand its lazy disclosure.
        def open_parent():
            click('.nav-link[data-page="agents"]'); wait('document.querySelector(".nav-link.active")?.dataset.page==="agents"', 'Agents page did not settle')
            wait('!!document.querySelector(".session-title-btn[data-id=\\"' + rel['parentSourceId'] + '\\"]")', 'Parent session entry did not render')
            click('.session-title-btn[data-id="' + rel['parentSourceId'] + '"]')
            wait('!!document.querySelector("#session-relations-section")', 'Parent drawer did not open')
            click('#session-relations-summary'); wait('document.querySelector("#session-relations-section").open', 'Relations disclosure did not open')
            wait('document.querySelector("#session-relations-children-list")', 'Relations children did not load')
        def hierarchy():
            open_parent(); text = value('document.querySelector("#session-relations-body").innerText')
            assert value('!!document.querySelector("#session-relations-body [data-i18n=\\"sessions.relations.livenessUnknown\\"]")'), 'Liveness must remain explicitly unknown'
            assert value('document.querySelectorAll("#session-relations-children-list .session-relation-link").length') >= 1
            links = value('[...document.querySelectorAll(".session-relation-link")].map(x=>x.dataset.sessionId)')
            assert rel['privateSourceId'] not in links
            assert rpc('sessions.relations.resolve', {'project': fixture['routingProject'], 'threadId': rel['parentThreadId']})['status'] == 'unavailable'
            assert rpc('sessions.relations.get', {'project': project, 'id': rel['orphanSourceId']})['parent']['resolved'] is False
            assert rpc('sessions.relations.get', {'project': project, 'id': rel['conflictSourceId']})['relation']['headerState'] == 'conflict'
            return {'parentAndVisibleChild': True, 'privateWithheld': True, 'crossProjectWithheld': True, 'orphanUnresolved': True, 'conflictPlainState': True}
        def load_events():
            before = len(calls('sessions.relations.events'))
            click('#session-relation-events-summary')
            # Opening the disclosure triggers its own asynchronous first page.
            # Its fallback button is transient: it can disappear after a DOM
            # sample but before Playwright attempts the next click.
            wait('document.querySelector("#session-relation-events-container")?.open===true', 'Evidence disclosure did not open')
            wait('document.querySelectorAll(".session-relation-event-item").length>0', 'Evidence page missing')
            loaded = calls('sessions.relations.events')[before:]
            assert len(loaded) == 1, 'Opening evidence must complete exactly one first-page request'
            request = loaded[0]
            assert request['params'] == {'project': project, 'id': rel['parentSourceId'], 'limit': 50}, 'Evidence loaded from the wrong source or continuation'
            assert not request.get('error') and len(request.get('result', {}).get('items', [])) == 50, 'Evidence did not render a successful real first page'
        def reported():
            open_parent(); load_events()
            wait('document.querySelectorAll(".session-relation-event-item").length===50', 'First evidence page missing')
            assert value('!!document.querySelector(".session-relation-event-item [data-i18n=\\"sessions.relations.childUnavailable\\"]")'), 'Reported-only spawn was presented as a child'
            assert value('[...document.querySelectorAll(".session-relation-event-item .session-relation-link")].some(x=>x.dataset.sessionId===' + json.dumps(rel['childSourceId']) + ')')
            return {'reportedUnavailableDistinct': True, 'corroboratedChildLinked': True}
        def event_pages():
            open_parent(); load_events(); wait('!!document.querySelector("#btn-load-more-relation-events")', 'Missing event continuation')
            for _ in range(2): click('#btn-load-more-relation-events'); time.sleep(.15)
            wait('document.querySelectorAll(".session-relation-event-item").length===128', 'Bounded three-page event list incomplete')
            assert value('document.querySelector("#btn-load-more-relation-events")===null')
            assert value('!!document.querySelector("[data-i18n=\\"sessions.relations.eventsTruncated\\"]")')
            return {'retainedEvents': 128, 'pages': 3, 'truncationVisible': True}
        def stale():
            open_parent()
            # A background dashboard refresh legitimately replaces a session's
            # old source epoch. Hold those actual read responses during this
            # deliberately stale-cursor check; do not synthesize their payload.
            value('window.__relationsPauseDashboard=true;window.__relationsPausedDashboards=[];true')
            before_get = len(calls('sessions.relations.get'))
            value('window.__relationsHold={method:"sessions.relations.get",id:' + json.dumps(rel['parentSourceId']) + '};true')
            click('#btn-refresh-session-relations'); wait('window.__relationsHeld===true', 'Controlled first real get response was not held')
            parent_source = Path(rel['parentSourcePath']); original = parent_source.read_text(); assert '"source": "cli"' in original
            parent_source.write_text(original.replace('"source": "cli"', '"source":{"subagent":"epoch-one"}', 1))
            value('window.__relationsSuppressRefresh=true;true')
            rpc('sessions.refresh', {})
            if value('document.querySelector("#btn-refresh-session-relations").disabled'):
                refresh_mode = 'coalesced-disabled'
                value('window.__relationsRelease();true'); wait('!window.__relationsHeld', 'Held response did not release')
            else:
                click('#btn-refresh-session-relations')
                wait('!!document.querySelector("#session-relations-body [title=\\"unresolved_subagent\\"]")', 'Latest refresh did not render its actual newer relation state')
                value('window.__relationsRelease();true'); wait('!window.__relationsHeld', 'Held response did not release')
                assert value('!!document.querySelector("#session-relations-body [title=\\"unresolved_subagent\\"]")'), 'Late first refresh overwrote the newer drawer state'
                refresh_mode = 'latest-generation-wins'
            # Double-click continuation is required to yield at most one cursor request.
            wait('!!document.querySelector("#btn-load-more-relation-children")', 'Child continuation missing')
            initial_children = value('[...document.querySelectorAll("#session-relations-children-list .session-relation-link")].map(x=>x.dataset.sessionId)')
            before = len(calls('sessions.relations.children'))
            value('window.__relationsHeld=false;window.__relationsHold={method:"sessions.relations.children",id:' + json.dumps(rel['parentSourceId']) + '};true')
            click('#btn-load-more-relation-children'); wait('window.__relationsHeld===true', 'Controlled real child continuation was not held')
            first_after = calls('sessions.relations.children')[-1]['params'].get('after')
            # Use the same still-mounted control without waiting for an enabled
            # locator; a disabled button is the expected coalescing behavior.
            value('(()=>{const b=document.querySelector("#btn-load-more-relation-children");if(b&&!b.disabled)b.click();return true})()')
            time.sleep(.2)
            same_cursor = [call for call in calls('sessions.relations.children')[before:] if call['params'].get('after') == first_after]
            assert len(same_cursor) == 1, 'Same child cursor was requested more than once before its response settled'
            returned_page = same_cursor[0]['result']
            expected_children = set(initial_children) | {item['source']['id'] for item in returned_page['items']}
            assert returned_page['nextCursor'], 'Fixture must retain another page after the held continuation'
            value('window.__relationsRelease();true'); wait('!window.__relationsHeld', 'Held child continuation did not release')
            wait('JSON.stringify([...document.querySelectorAll("#session-relations-children-list .session-relation-link")].map(x=>x.dataset.sessionId).sort())===' + json.dumps(json.dumps(sorted(expected_children),separators=(',',':'))), 'Held continuation did not render its actual source identities')
            wait('!!document.querySelector("#btn-load-more-relation-children")&&!document.querySelector("#btn-load-more-relation-children").disabled', 'Next child page was not ready after the held continuation')
            wait('(window.__relationsPausedDashboards||[]).length>0', 'No actual background dashboard response was held')
            old_epoch = rpc('sessions.relations.get', {'project': project, 'id': rel['parentSourceId']})['relation']['relationEpoch']
            epoch_one = parent_source.read_text(); assert '"source":{"subagent":"epoch-one"}' in epoch_one
            parent_source.write_text(epoch_one.replace('"source":{"subagent":"epoch-one"}', '"source":{"subagent":"epoch-two"}', 1))
            rpc('sessions.refresh', {})
            new_epoch = rpc('sessions.relations.get', {'project': project, 'id': rel['parentSourceId']})['relation']['relationEpoch']
            assert new_epoch != old_epoch, 'Owned header rewrite did not produce a new relation epoch'
            click('#btn-load-more-relation-children')
            wait('!!document.querySelector("#btn-reload-relation-children")', 'Stale children cursor did not offer an explicit reload')
            # A real response is held while the selected project changes; then an
            # injected post-response failure is released after the drawer is gone.
            value('window.__relationsHeld=false;window.__relationsHold={method:"sessions.relations.get",id:' + json.dumps(rel['parentSourceId']) + ',fail:true};true')
            click('#btn-refresh-session-relations'); wait('window.__relationsHeld===true', 'Controlled get response was not held')
            browser('select', '#project-selector', fixture['routingProject'])
            wait('document.querySelector("#project-selector").value===' + json.dumps(fixture['routingProject']), 'Project replacement did not settle')
            value('window.__relationsRelease();true'); time.sleep(.25)
            assert not value('document.body.innerText.includes(' + json.dumps(rel['parentThreadId']) + ')'), 'Late relation response replaced the new project view'
            held_dashboards = value('(window.__relationsPausedDashboards||[]).length')
            value('window.__relationsPauseDashboard=false;(window.__relationsPausedDashboards||[]).splice(0).forEach(resolve=>resolve());true')
            return {'sameDrawerRefresh': refresh_mode, 'duplicateContinuationSuppressed': True, 'lateProjectAndFailureIgnored': True, 'staleGetChildrenEpochReset': True, 'actualBackgroundDashboardResponsesHeld': held_dashboards, 'payloadMocked': False, 'heldContinuationVisibleChildren': len(expected_children)}
        def locale_size():
            def save_locale(locale):
                # Selecting the current option does not emit a change event. Flip
                # once first so every asserted locale has a real settings.save.
                if value('document.querySelector("#setting-locale").value===' + json.dumps(locale)):
                    save_locale('en' if locale == 'zh-CN' else 'zh-CN')
                before = len(calls('settings.save'))
                browser('select', '#setting-locale', locale)
                wait('window.__relationsCalls.filter(x=>x.method==="settings.save").length>' + str(before), 'Locale save bridge call did not finish')
                wait('!document.querySelector("#setting-locale").disabled', 'Locale control remained disabled after save')
                saved = calls('settings.save')[-1]
                assert saved.get('result', {}).get('locale') == locale, 'Locale save did not confirm the requested locale'
                assert value('window.VelaI18n?.getLocale()===' + json.dumps(locale) + '&&document.documentElement.lang===' + json.dumps(locale) + '&&document.querySelector("#setting-locale").value===' + json.dumps(locale)), 'Saved locale was not applied to renderer state'
            browser('select', '#project-selector', project)
            wait('document.querySelector("#project-selector").value===' + json.dumps(project), 'Harbor project did not restore')
            click('.nav-link[data-page="settings"]'); select_settings_category('general'); wait('!!document.querySelector("#setting-locale")', 'Settings locale control did not open')
            save_locale('zh-CN')
            click('.nav-link[data-page="agents"]')
            open_parent()
            visual_geometry = []
            def verify_locale_and_geometry(locale, relation_title, plan_title, badge, body):
                assert value('document.querySelector("[data-i18n=\\"sessions.relations.title\\"]").textContent.trim()===' + json.dumps(relation_title)), 'Relation title did not render in ' + locale
                assert value('document.querySelector("#session-plan-section [data-i18n=\\"sessions.plan.title\\"]").textContent.trim()===' + json.dumps(plan_title)), 'Plan title did not render in ' + locale
                assert value('document.querySelector("#session-plan-badge").textContent.trim()===' + json.dumps(badge)), 'Plan badge did not render the compact ' + locale + ' text'
                assert value('document.querySelector("#session-plan-section [data-i18n=\\"sessions.plan.unavailable\\"]").textContent.trim()===' + json.dumps(body)), 'Plan body did not retain the complete ' + locale + ' explanation'
                for width, height in ((900, 620), (1250, 720)):
                    browser('resize', width, height); browser('screenshot', str(output / f'relations-{locale}-{width}x{height}.png'))
                    assert value('document.documentElement.scrollWidth<=document.documentElement.clientWidth'), 'Horizontal overflow at supported native size'
                    geometry = value("""(()=>{const drawer=document.querySelector('#detail-drawer'),section=document.querySelector('#session-plan-section'),title=section?.querySelector('[data-i18n="sessions.plan.title"]'),badge=section?.querySelector('#session-plan-badge'),refresh=section?.querySelector('#btn-refresh-session-plan'),header=section?.firstElementChild;if(!drawer||!section||!title||!badge||!refresh||!header)return null;const rect=e=>{const r=e.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height}};const range=document.createRange();range.selectNodeContents(title);const lineRects=[...range.getClientRects()].filter(r=>r.width>0).map(r=>({width:r.width,height:r.height}));const style=getComputedStyle(title),font=parseFloat(style.fontSize)||14,line=parseFloat(style.lineHeight)||font*1.2;return {drawer:rect(drawer),header:rect(header),title:rect(title),badge:rect(badge),refresh:rect(refresh),titleLines:lineRects.length,titleFont:font,titleLine:line,badgeText:badge.textContent.trim(),badgeOverflow:badge.scrollWidth>badge.clientWidth+1};})()""")
                    assert geometry, 'Plan header geometry is unavailable'
                    assert geometry['title']['width'] >= geometry['titleFont'] * 1.8, 'Plan title cannot fit two Chinese characters'
                    assert geometry['titleLines'] <= 2 and geometry['title']['height'] <= geometry['titleLine'] * 2.2, 'Plan title is wrapped into a vertical character column'
                    assert geometry['refresh']['left'] >= geometry['drawer']['left'] and geometry['refresh']['right'] <= geometry['drawer']['right'], 'Plan refresh control escapes drawer bounds'
                    assert geometry['refresh']['left'] >= geometry['header']['left'] and geometry['refresh']['right'] <= geometry['header']['right'], 'Plan refresh control escapes its header'
                    assert geometry['title']['right'] <= geometry['refresh']['left'] or geometry['refresh']['right'] <= geometry['title']['left'], 'Plan title overlaps refresh control'
                    if geometry['badgeText']:
                        assert geometry['badge']['left'] >= geometry['header']['left'] and geometry['badge']['right'] <= geometry['header']['right'], 'Plan badge escapes header bounds'
                        assert not geometry['badgeOverflow'], 'Plan badge text is clipped'
                        visual_geometry.append({'locale': locale, 'viewport': [width, height], **geometry})
            verify_locale_and_geometry('zh-CN', '关联会话', '会话任务计划', '未观察到计划', '尚未观察到已确认计划（未在会话日志中识别到受支持的任务计划工具调用）')
            click('.nav-link[data-page="settings"]'); wait('document.querySelector(".nav-link.active")?.dataset.page==="settings"', 'Settings navigation failed'); select_settings_category('general'); wait('!!document.querySelector("#setting-locale")', 'Settings locale control did not rerender')
            zh_title = value('document.querySelector("#setting-locale").value')
            save_locale('en')
            click('.nav-link[data-page="agents"]'); open_parent(); en_title = value('document.querySelector("[data-i18n=\\"sessions.relations.title\\"]").textContent')
            verify_locale_and_geometry('en', 'Related Sessions', 'Session Task Plan', 'Not observed', 'No confirmed task plan observed (no supported task plan tool calls detected)')
            assert zh_title == 'zh-CN' and en_title.strip() == 'Related Sessions', 'Relation title did not switch locale after confirmed saves'
            return {'localizedRelationTitle': {'zh-CN': '关联会话', 'en': en_title}, 'supportedViewports': [[900, 620], [1250, 720]], 'planHeaderGeometry': visual_geometry}
        check('hierarchy-and-privacy', hierarchy); check('reported-is-not-child', reported); check('event-pagination', event_pages); check('stale-and-duplicate-guards', stale); check('locale-and-supported-size', locale_size)
        evidence['sourceAfter'] = hashes(ui_source); evidence['fixtureSourceAfter'] = hashes(ui); evidence['binaryAfter'] = hashlib.sha256(binary.read_bytes()).hexdigest(); evidence['fixtureBinaryAfter'] = hashlib.sha256(helper.read_bytes()).hexdigest()
        evidence['fixtureSourcesAfter'] = source_hashes(Path(fixture['sessionRoot']))
        evidence['sourceUnchanged'] = evidence['sourceBefore'] == evidence['sourceAfter'] == evidence['fixtureSourceBefore'] == evidence['fixtureSourceAfter']; evidence['binaryUnchanged'] = evidence['binaryBefore'] == evidence['binaryAfter'] == evidence['fixtureBinaryBefore'] == evidence['fixtureBinaryAfter']
        evidence['fixtureSourceDataMutation'] = {'ownedPath': rel['parentSourcePath'], 'expected': True,
                                                 'changed': evidence['fixtureSourcesBefore'] != evidence['fixtureSourcesAfter']}
        evidence['selectedChecksPassed'] = len(evidence['checks']) == len(selected) and all(row['passed'] for row in evidence['checks']) and evidence['sourceUnchanged'] and evidence['binaryUnchanged'] and not value('window.__relationsErrors.length')
        evidence['completeSuite'] = selected == set(CHECKS) and evidence['selectedChecksPassed']
    except Exception as error:
        evidence['harnessError'] = str(error); evidence['traceback'] = traceback.format_exc(limit=7)
    finally:
        if driver:
            try:
                if driver.poll() is None: browser('close')
            except Exception as error: evidence.setdefault('cleanupWarnings', []).append('browser shutdown: ' + str(error))
            if driver.poll() is None: os.killpg(driver.pid, signal.SIGTERM)
            try: driver.wait(timeout=5)
            except subprocess.TimeoutExpired: os.killpg(driver.pid, signal.SIGKILL); driver.wait(timeout=5)
        if server:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait(timeout=5)
        if fixture_created:
            if (base / 'harness-rpc.jsonl').exists(): (output / 'rpc.jsonl').write_text((base / 'harness-rpc.jsonl').read_text())
            marker = json.loads((base / 'store/.vela-ui-fixture.json').read_text())
            assert not base.is_symlink() and base.resolve() == ROOT.resolve() / '.task-tmp' / base.name and base.stat().st_uid == os.getuid()
            assert marker['synthetic'] is True and marker['manifest'] == str(base / 'fixture.json')
            for path in (base / 'store', base / 'sources', base / 'Harbor', base / 'Beacon'):
                assert path.is_dir() and not path.is_symlink() and path.resolve().is_relative_to(base) and path.stat().st_uid == os.getuid()
            count = sum(1 for path in base.rglob('*') if path.is_file()); shutil.rmtree(base); evidence['cleanup'] = {'removedOwnedFixture': str(base), 'removedFiles': count, 'browserAndServerStopped': True, 'evidenceRetained': True}
        save()
    # A selected diagnostic is intentionally not a full-suite claim, but a
    # passing selected check must still return success to callers.
    return 0 if evidence.get('selectedChecksPassed') else 1


if __name__ == '__main__':
    raise SystemExit(main())
