"""Frozen UI14 browser acceptance scaffold for Search + Actions, templates and sound previews.

The runner creates a new synthetic fixture under .task-tmp, copies only the UI
allowlist into it, and starts the existing capability-scoped test server.  It
never opens a user Vela store.  UI14 selectors are intentionally resolved only
after the UI author records their frozen stable names.
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

ROOT = Path(__file__).resolve().parents[1]
UI_FILES = UI_RESOURCES + DEVELOPMENT_UI_RESOURCES


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ui-directory', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True, help='New immediate .task-tmp child; removed after testing.')
    parser.add_argument('--output', type=Path, required=True, help='New retained output/playwright directory.')
    parser.add_argument('--browser-executable', type=Path, required=True)
    parser.add_argument('--frozen-selectors', action='store_true', help='Required after UI14 stable selectors are frozen.')
    parser.add_argument('--checks', help='Optional comma-separated diagnostic subset; omit for the complete suite.')
    args = parser.parse_args()
    base, output = args.fixture.absolute(), args.output.absolute()
    ui_source, binary = args.ui_directory.resolve(strict=True), args.binary.resolve(strict=True)
    if base.exists() or base.is_symlink() or base.parent != (ROOT / '.task-tmp').resolve():
        parser.error('fixture must be a new immediate child of .task-tmp')
    if output.exists() or output.is_symlink() or not output.parent.resolve().is_relative_to((ROOT / 'output/playwright').resolve()):
        parser.error('output must be a new child below output/playwright')
    if not args.browser_executable.is_file(): parser.error('browser executable is missing')
    for name in UI_FILES:
        if not (ui_source / name).is_file() or (ui_source / name).is_symlink(): parser.error('missing ordinary UI file: ' + name)
    output.mkdir(parents=True)
    (output / 'consumer-test-source.py').write_bytes(Path(__file__).read_bytes())
    evidence = {'format': 'vela-workspace-actions-ui14-v1', 'synthetic': True, 'completeSuite': False,
                'realProviderExecuted': False, 'workflowExecuted': False, 'nativeAudioClaimed': False,
                'sourceDirectory': str(ui_source), 'fixtureDirectory': str(base), 'checks': []}
    known_checks = {'actions-keyboard-defaults', 'actions-project-required', 'search-late-response-isolation', 'starter-templates-dry-run', 'sound-preview-and-visuals', 'toast-bounds-and-dismissal', 'draft-modal-protection', 'actions-template-entry', 'supported-size-visuals'}
    selected_checks = set(args.checks.split(',')) if args.checks else known_checks
    if not selected_checks or not selected_checks <= known_checks: parser.error('unknown or empty --checks')
    evidence['selectedChecks'] = sorted(selected_checks)
    server = driver = None; fixture_created = False
    def hashes(directory): return {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in UI_FILES}
    def save(): (output / 'results.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')
    def browser(*arguments):
        driver.stdin.write(json.dumps(arguments) + '\n'); driver.stdin.flush()
        assert select.select([driver.stdout], [], [], 20)[0], 'browser timed out'
        reply = json.loads(driver.stdout.readline()); assert 'error' not in reply, reply; return reply.get('output', '')
    def value(script): return json.loads(browser('eval', script))
    try:
        evidence['sourceBefore'] = hashes(ui_source)
        evidence['binaryBefore'] = hashlib.sha256(binary.read_bytes()).hexdigest()
        created = subprocess.run(['python3', str(ROOT / 'scripts/create-ui-fixture.py'), str(base), '--binary', str(binary), '--with-routing-project'], capture_output=True, text=True, timeout=60)
        fixture_created = (base / 'store/.vela-ui-fixture.json').is_file(); (output / 'fixture-creation.log').write_text(created.stdout + created.stderr); created.check_returncode()
        fixture = json.loads((base / 'fixture.json').read_text()); assert fixture['synthetic'] is True
        frozen_ui, frozen_binary = base / 'ui-snapshot', base / 'vela-frozen'; frozen_ui.mkdir()
        copy_ui_resources(ui_source, frozen_ui, allow_development=True)
        shutil.copy2(binary, frozen_binary); evidence['fixtureSourceBefore'] = hashes(frozen_ui)
        evidence['fixtureBinaryBefore'] = hashlib.sha256(frozen_binary.read_bytes()).hexdigest()
        assert evidence['sourceBefore'] == evidence['fixtureSourceBefore']
        spec = importlib.util.spec_from_file_location('ui_browser', ROOT / 'scripts/test-ui-browser.py'); module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        server = subprocess.Popen(['python3', str(ROOT / 'scripts/test-ui-server.py'), str(base / 'fixture.json'), '--binary', str(frozen_binary), '--ui-directory', str(frozen_ui)], stdout=subprocess.PIPE, text=True)
        assert select.select([server.stdout], [], [], 15)[0], 'test server did not start'; url = json.loads(server.stdout.readline())['url']
        driver_source = module.PLAYWRIGHT_DRIVER.replace(
            "const page=await browser.newPage({viewport:{width:1280,height:720}});page.setDefaultTimeout(5000);",
            "const page=await browser.newPage({viewport:{width:1280,height:720}});await page.addInitScript(()=>{window.__ui14EarlyErrors=[];window.addEventListener('error',e=>window.__ui14EarlyErrors.push(e.message));window.addEventListener('unhandledrejection',e=>window.__ui14EarlyErrors.push(String(e.reason)));});page.setDefaultTimeout(5000);").replace("else if(command==='select')", "else if(command==='clock.install')await page.clock.install();\n      else if(command==='clock.pauseAt')await page.clock.pauseAt(args[0]);\n      else if(command==='clock.runFor')await page.clock.runFor(args[0]);\n      else if(command==='clock.resume')await page.clock.resume();\n      else if(command==='resize')await page.setViewportSize({width:args[0],height:args[1]});\n      else if(command==='select')")
        driver = subprocess.Popen(['node', '-e', driver_source, str(ROOT / '.task-tmp/ui-browser-tools/node_modules/playwright/index.js'), str(args.browser_executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, start_new_session=True)
        browser('open', url); browser('wait', '#project-selector'); browser('select', '#project-selector', fixture['project'])
        # Test-only boundary: only the native audio call is stubbed. Search delay control
        # wraps real bridge results and is released explicitly by later frozen-selector checks.
        value("""window.__ui14={calls:[],heldSearch:null,releaseSearch:null,errors:window.__ui14EarlyErrors||[]};window.__ui14.original=window.vela.call;window.vela.call=async(method,params={})=>{if(method==='system.previewNotificationSound'){if(!['approval','completed','error'].includes(params.kind))throw Error('invalid test sound kind');const result={kind:params.kind,playing:true};window.__ui14.calls.push({method,params,result,nativeAudioMock:true});return result;}const result=await window.__ui14.original(method,params);window.__ui14.calls.push({method,params,result});if(method==='search'&&window.__ui14.heldSearch&&params.query===window.__ui14.heldSearch.query&&params.project===window.__ui14.heldSearch.project){const held=window.__ui14.heldSearch;await new Promise(resolve=>window.__ui14.releaseSearch=resolve);if(held.error)throw Error('Injected test-only delayed search error');}return result;};true""")
        if not args.frozen_selectors:
            raise RuntimeError('UI14 is not selector-frozen; scaffold stopped before product assertions.')
        def wait(script, reason, seconds=10):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if value(script): return
                time.sleep(.05)
            raise AssertionError(reason)
        def click(selector): browser('click', selector)
        def select_settings_category(category):
            selector = '[data-settings-category="' + category + '"]'
            wait('!!document.querySelector(' + json.dumps(selector) + ')', 'Settings category is unavailable: ' + category)
            click(selector)
            wait('document.querySelector(' + json.dumps(selector) + ').getAttribute("aria-pressed")==="true"&&document.querySelector("[data-settings-panel=\\"' + category + '\\"]")?.hidden===false',
                 'Settings category did not become visible: ' + category)
        def open_starter_menu():
            summary = '#btn-wf-starters-menu'
            wait('!!document.querySelector(' + json.dumps(summary) + ')', 'Workflows view missing starter menu')
            if not value('document.querySelector(' + json.dumps(summary) + ').closest("details.action-menu")?.open'):
                click(summary)
            wait('document.querySelector(' + json.dumps(summary) + ').closest("details.action-menu")?.open===true',
                 'Starter menu did not open through its native details summary')
        def open_workflow_actions(workflow_id):
            menu = 'article.workspace-row.workflow-row[data-id="' + workflow_id + '"] details.action-menu'
            wait('!!document.querySelector(' + json.dumps(menu) + ')', 'Saved workflow lacks its native action menu')
            if not value('document.querySelector(' + json.dumps(menu) + ').open'):
                click(menu + ' > summary')
            wait('document.querySelector(' + json.dumps(menu) + ').open===true',
                 'Workflow action menu did not open through its native details summary')
            return menu
        def check(name, fn):
            if name not in selected_checks: return
            try: evidence['checks'].append(dict(check=name, passed=True, **fn()))
            except Exception as error: evidence['checks'].append({'check': name, 'passed': False, 'error': str(error)}); raise
        def open_cmdk():
            browser('press', 'Meta+k'); wait('!!document.querySelector("#tab-mode-search")', 'Cmd-K did not open Search + Actions')
        def close_modal(): browser('press', 'Escape')
        def actions_keyboard():
            open_cmdk()
            assert value('document.querySelector("#tab-mode-search").getAttribute("aria-selected") === "true"'), 'Search must be default mode'
            assert value('!document.querySelector("#search-include-private").checked'), 'Private search must default off'
            click('#tab-mode-actions'); wait('document.querySelector("#tab-mode-actions").getAttribute("aria-selected")==="true"', 'Actions tab did not activate')
            assert value('document.querySelector("#tab-mode-actions").classList.contains("active") && !document.querySelector("#tab-mode-search").classList.contains("active")'), 'Tab visual active class disagrees with aria-selected'
            browser('screenshot', str(output / 'actions-active.png'))
            tab_style = value('(()=>{const a=getComputedStyle(document.querySelector("#tab-mode-actions")),s=getComputedStyle(document.querySelector("#tab-mode-search"));return {actions:{color:a.color,background:a.backgroundColor},search:{color:s.color,background:s.backgroundColor}}})()')
            browser('fill', '#global-search-input', '')
            wait('document.querySelectorAll("[data-action-id]").length > 0', 'Action filtering showed no actions')
            selected_selector = '[data-action-id][aria-selected="true"]'
            browser('press', 'ArrowDown'); wait('document.querySelector(' + json.dumps(selected_selector) + ') !== null', 'ArrowDown did not expose an accessible current action')
            selected = value('document.querySelector(' + json.dumps(selected_selector) + ')?.dataset.actionId')
            browser('press', 'ArrowUp'); assert value('document.querySelector(' + json.dumps(selected_selector) + ') !== null'), 'ArrowUp lost selection'
            close_modal()
            return {'defaultMode': 'search', 'privateDefault': False, 'keyboardSelected': selected, 'activeTabStyle': tab_style}
        def project_required():
            values = value('[...document.querySelector("#project-selector").options].map(x=>x.value)')
            none = next((item for item in values if not item), None)
            assert none is not None, 'Fixture project selector lacks no-project option'
            browser('select', '#project-selector', none); open_cmdk(); click('#tab-mode-actions')
            selector = '[data-action-id="action-new-workflow"]'; wait('!!document.querySelector(' + json.dumps(selector) + ')', 'New workflow action missing')
            assert value('document.querySelector(' + json.dumps(selector) + ').matches(' + json.dumps(':disabled,[aria-disabled="true"]') + ')'), 'Project-dependent action remains enabled without a project'
            assert value('document.querySelector(' + json.dumps(selector) + ').querySelector(".status-badge")?.textContent.trim().length > 0 || document.querySelector(' + json.dumps(selector) + ').getAttribute("aria-description")'), 'Disabled action does not explain project requirement'
            close_modal(); browser('select', '#project-selector', fixture['project'])
            return {'action': 'action-new-workflow', 'disabledWithoutProject': True}
        def late_search_isolation():
            project = fixture['project']; cases = [('query', False), ('clear', False), ('mode', False), ('project', False), ('replaced-modal', True), ('error-after-clear', True)]
            for index, (mode, is_error) in enumerate(cases):
                open_cmdk(); query = 'parser'
                value('window.__ui14.heldSearch={query:' + json.dumps(query) + ',project:' + json.dumps(project) + ',error:' + json.dumps(is_error) + '};window.__ui14.releaseSearch=null;true')
                browser('fill', '#global-search-input', query); browser('press', 'Enter'); wait('window.__ui14.releaseSearch !== null', 'Real search response was not held: ' + mode)
                if mode == 'query': browser('fill', '#global-search-input', 'different-query')
                elif mode == 'clear' or mode == 'error-after-clear': browser('fill', '#global-search-input', '')
                elif mode == 'mode': click('#tab-mode-actions')
                elif mode == 'project': browser('select', '#project-selector', next(p for p in fixture['projects'] if p != project))
                elif mode == 'replaced-modal': close_modal(); open_cmdk()
                value('window.__ui14.releaseSearch();true'); time.sleep(.15)
                if mode == 'mode': assert value('document.querySelector("#tab-mode-actions").getAttribute("aria-selected")==="true"'), 'Late search replaced Actions mode'
                elif mode == 'replaced-modal': assert value('!!document.querySelector("#tab-mode-search")'), 'Late search closed replacement modal'
                elif mode == 'project': browser('select', '#project-selector', project)
                else: assert not value('document.querySelector("#search-results-list").textContent.includes("' + query + '")'), 'Late search rendered after ' + mode
                close_modal()
            return {'heldRealSearchResponse': True, 'invalidations': [name for name, _ in cases], 'lateSuccessAndErrorIgnored': True}
        def project_tree_hash():
            digest = hashlib.sha256(); root = Path(fixture['project'])
            for path in sorted((p for p in root.rglob('*') if p.is_file() and '.git' not in p.parts), key=str):
                digest.update(str(path.relative_to(root)).encode()); digest.update(path.read_bytes())
            return digest.hexdigest()
        def starter_templates():
            click('.nav-link[data-page="workflows"]'); wait('!!document.querySelector("#btn-wf-starters-menu")', 'Workflows view missing starter menu')
            expected = {'template-worktree-check': ['git.status', 'git.diff'], 'template-recent-changes': ['git.log', 'git.status'], 'template-handoff-review': ['git.status', 'git.diff', 'git.log']}
            before_project = project_tree_hash(); opened = []; saved_runs = []; restored_states = []
            def workflows_list_state():
                return value("(()=>{const modal=document.querySelector('#modal-container');const menu=document.querySelector('#btn-wf-starters-menu');const pane=document.querySelector('.content-pane');return {modalHidden:!!modal?.classList.contains('hidden'),workflowsActive:document.querySelector('.nav-link.active')?.dataset.page==='workflows',drawerClosed:!document.body.classList.contains('has-inspector-open')&&!document.querySelector('.detail-drawer:not(.hidden)'),mainVisible:getComputedStyle(pane).visibility!=='hidden',menuVisible:!!menu&&menu.getClientRects().length>0&&getComputedStyle(menu).visibility!=='hidden'};})()")
            def require_workflows_list(reason):
                wait("(()=>{const modal=document.querySelector('#modal-container');const menu=document.querySelector('#btn-wf-starters-menu');const pane=document.querySelector('.content-pane');return !!modal?.classList.contains('hidden')&&document.querySelector('.nav-link.active')?.dataset.page==='workflows'&&!document.body.classList.contains('has-inspector-open')&&!document.querySelector('.detail-drawer:not(.hidden)')&&getComputedStyle(pane).visibility!=='hidden'&&!!menu&&menu.getClientRects().length>0&&getComputedStyle(menu).visibility!=='hidden';})()", reason)
                state = workflows_list_state(); assert all(state.values()), state; restored_states.append(state)
            for template, tools in expected.items():
                before_calls = value('window.__ui14.calls.length'); open_starter_menu(); click('[data-template-id="' + template + '"]'); wait('!!document.querySelector("#wf-modal-title")', 'Starter did not open an editor')
                assert value('document.querySelector("#wf-modal-trigger").value === "manual"'), 'Starter trigger is not manual'
                actual = value('[...document.querySelectorAll(".wf-step-tool")].map(x=>x.value)'); assert actual == tools, (template, actual)
                assert value('[...document.querySelectorAll(".wf-step-args")].every(x=>x.value.trim()==="{}")'), 'Starter arguments are not empty objects'
                calls = value('window.__ui14.calls.slice(' + str(before_calls) + ').map(x=>x.method)'); assert 'workflows.save' not in calls and 'workflows.run' not in calls, 'Opening a starter mutated state'
                opened.append({'template': template, 'tools': actual}); click('#btn-cancel-wf'); require_workflows_list('Cancelling starter did not restore the visible Workflows list')
            assert project_tree_hash() == before_project, 'Opening unsaved starters changed the fixture project'
            for template, tools in expected.items():
                save_before = value('window.__ui14.calls.filter(x=>x.method==="workflows.save"&&x.result).length'); open_starter_menu(); click('[data-template-id="' + template + '"]'); click('#btn-save-wf'); wait('window.__ui14.calls.filter(x=>x.method==="workflows.save"&&x.result).length > ' + str(save_before), 'Explicit save did not reach helper')
                saved = value('window.__ui14.calls.filter(x=>x.method==="workflows.save"&&x.result).at(-1).result'); assert saved['trigger'] == 'manual' and saved['enabled'] is False and [step['tool'] for step in saved['steps']] == tools and all(step['arguments'] == {} for step in saved['steps'])
                workflow_id = saved['id']; dry_run_selector = '.btn-wf-dryrun[data-id="' + workflow_id + '"]'
                open_workflow_actions(workflow_id); wait('!!document.querySelector(' + json.dumps(dry_run_selector) + ')', 'Saved workflow lacks dry-run action'); click(dry_run_selector); wait('window.__ui14.calls.some(x=>x.method==="workflows.run"&&x.params.id===' + json.dumps(workflow_id) + '&&x.params.dryRun===true)', 'Dry run was not issued')
                wait('document.body.classList.contains("has-inspector-open") && !!document.querySelector("#btn-close-drawer") && document.querySelector("#btn-close-drawer").getClientRects().length>0', 'Dry run did not open its inspected run detail')
                click('#btn-close-drawer'); require_workflows_list('Closing dry-run detail did not restore the visible Workflows list')
                saved_runs.append({'template': template, 'id': workflow_id, 'tools': tools, 'detailOpenedThenClosed': True})
            assert project_tree_hash() == before_project, 'Git-read dry run modified the fixture project'
            return {'openedUnsaved': opened, 'restoredListStates': restored_states, 'savedThenDryRun': saved_runs, 'projectUnchanged': True}
        def sound_preview_and_visuals():
            click('.nav-link[data-page="settings"]'); select_settings_category('notifications'); wait('!!document.querySelector("#setting-notifications")', 'Settings notifications control did not load')
            assert not value('document.querySelector("#setting-notifications").checked'), 'Fixture notifications must start disabled'
            assert not value('document.querySelector("#btn-preview-notification-sound").disabled'), 'Preview is incorrectly disabled with notifications off'
            before = value('window.__ui14.calls.length')
            for kind in ('approval', 'completed', 'error'):
                browser('select', '#setting-preview-sound-kind', kind); click('#btn-preview-notification-sound'); wait('window.__ui14.calls.filter(x=>x.method==="system.previewNotificationSound").length >= ' + str({'approval': 1, 'completed': 2, 'error': 3}[kind]), 'Sound mock did not receive ' + kind)
            calls = value('window.__ui14.calls.slice(' + str(before) + ')'); assert [x['params']['kind'] for x in calls if x['method'] == 'system.previewNotificationSound'] == ['approval', 'completed', 'error']
            assert not any(x['method'] == 'settings.save' for x in calls), 'Preview saved settings'; assert not value('document.querySelector("#setting-notifications").checked'), 'Preview toggled notifications'
            for width in (1250, 375):
                browser('resize', width, 720); browser('screenshot', str(output / ('settings-' + str(width) + '.png')))
                assert value('document.documentElement.scrollWidth <= document.documentElement.clientWidth'), 'Horizontal overflow at ' + str(width)
            browser('resize', 1280, 720)
            select_settings_category('general')
            browser('select', '#setting-locale', 'en'); wait('VelaI18n.getLocale()==="en"&&!document.querySelector("#setting-locale").disabled', 'English locale save did not settle')
            open_cmdk(); assert value('document.querySelector("#tab-mode-actions").textContent.includes("Actions")'), 'English Actions accessibility label missing'; close_modal()
            browser('select', '#setting-locale', 'zh-CN'); wait('VelaI18n.getLocale()==="zh-CN"&&!document.querySelector("#setting-locale").disabled', 'Chinese locale save did not settle')
            open_cmdk(); assert value('document.querySelector("#tab-mode-actions").textContent.trim().length > 0 && document.querySelector("#tab-mode-actions").getAttribute("role") === "tab"'), 'Chinese Actions accessibility tab missing'; close_modal()
            return {'nativeAudioMockOnly': True, 'previewKinds': 3, 'notificationsUnchanged': True, 'localizedAccessibleTabs': ['en', 'zh-CN'], 'viewports': [1250, 375]}
        def toast_bounds_and_dismissal():
            click('.nav-link[data-page="settings"]'); select_settings_category('notifications'); wait('!!document.querySelector("#btn-preview-notification-sound")', 'Settings preview unavailable')
            browser('clock.install'); browser('clock.pauseAt', value('Date.now()') + 1)
            def preview(kind):
                before = value('window.__ui14.calls.filter(x=>x.method==="system.previewNotificationSound").length')
                prior_keys = value('[...document.querySelectorAll("#toast-container .toast")].map(x=>x.dataset.toastKey)')
                browser('select', '#setting-preview-sound-kind', kind); click('#btn-preview-notification-sound')
                wait('window.__ui14.calls.filter(x=>x.method==="system.previewNotificationSound").length > ' + str(before), 'Preview bridge response missing: ' + kind)
                try:
                    wait('[...document.querySelectorAll("#toast-container .toast")].some(x=>!(' + json.dumps(prior_keys) + ').includes(x.dataset.toastKey)) || document.querySelectorAll("#toast-container .toast").length>0', 'Preview toast missing: ' + kind)
                except AssertionError:
                    raise AssertionError('Preview toast missing: ' + kind + '; calls=' + json.dumps(value('window.__ui14.calls.filter(x=>x.method==="system.previewNotificationSound")')) + '; dom=' + json.dumps(value('[...document.querySelectorAll("#toast-container .toast")].map(x=>({key:x.dataset.toastKey,text:x.textContent,html:x.outerHTML}))')))
                return value('[...document.querySelectorAll("#toast-container .toast")].at(-1)?.dataset.toastKey')
            approval_node = preview('approval'); preview('completed')
            assert value('document.querySelectorAll("#toast-container .toast").length===2'), 'Two real preview notices were not retained'
            browser('clock.runFor', 3200); assert value('[...document.querySelectorAll("#toast-container .toast")].some(x=>x.style.opacity==="0")'), 'Expiry did not begin real dismissal'
            preview('approval'); assert value('[...document.querySelectorAll("#toast-container .toast")].some(x=>x.style.opacity!=="0")'), 'Repeated real toast did not restore visibility'
            preview('error'); assert value('document.querySelectorAll("#toast-container .toast").length<=2'), 'Third real toast exceeded capacity'
            open_cmdk(); close_modal()
            browser('clock.runFor', 250); assert value('[...document.querySelectorAll("#toast-container .toast")].some(x=>x.dataset.toastKey===' + json.dumps(approval_node) + '&&x.style.opacity!=="0")'), 'Expired timer removed the replacement toast'
            browser('clock.resume'); select_settings_category('general'); browser('select', '#setting-locale', 'en'); wait('VelaI18n.getLocale()==="en"&&!document.querySelector("#setting-locale").disabled', 'English locale save unavailable')
            assert value('document.querySelector(".toast-dismiss-btn")?.getAttribute("aria-label")==="Dismiss"'), 'English dismiss aria mismatch'
            browser('select', '#setting-locale', 'zh-CN'); wait('VelaI18n.getLocale()==="zh-CN"&&!document.querySelector("#setting-locale").disabled', 'Chinese locale save unavailable')
            assert value('document.querySelector(".toast-dismiss-btn")?.getAttribute("aria-label")==="关闭"'), 'Chinese dismiss aria mismatch'
            const_before = value('document.querySelectorAll("#toast-container .toast").length'); browser('focus', '#toast-container .toast:first-child .toast-dismiss-btn'); browser('press', 'Enter')
            wait('document.querySelectorAll("#toast-container .toast").length < ' + str(const_before), 'Keyboard dismiss did not remove a toast')
            browser('eval', 'window.__clockCleanup=true;true')
            return {'realPreviewKinds': 3, 'maxVisible': 2, 'clockControlled': True, 'cmdkResponsive': True, 'keyboardDismissed': True}
        def draft_modal_protection():
            click('.nav-link[data-page="workflows"]'); wait('!!document.querySelector("#btn-new-workflow")', 'Workflows view missing')
            cases = [('title', 'document.querySelector("#wf-modal-title").value="";'), ('select', 'document.querySelector("#wf-modal-trigger").value="cron";document.querySelector("#wf-modal-trigger").dispatchEvent(new Event("change",{bubbles:true}));'), ('checkbox', 'document.querySelector("#wf-context-enable").click();')]
            protected = []
            for name, mutate in cases:
                click('#btn-new-workflow'); wait('!!document.querySelector("#wf-modal-title")', 'New workflow editor absent')
                value(mutate + 'true'); browser('press', 'Meta+k'); time.sleep(.1)
                assert value('!!document.querySelector("#wf-modal-title") && !document.querySelector("#modal-container").classList.contains("hidden")'), 'Cmd-K replaced unsaved editor after ' + name
                if name == 'title': assert value('document.querySelector("#wf-modal-title").value === ""'), 'Cleared draft title was overwritten'
                if name == 'select': assert value('document.querySelector("#wf-modal-trigger").value === "cron"'), 'Changed trigger was overwritten'
                if name == 'checkbox': assert value('document.querySelector("#wf-context-enable").checked'), 'Changed checkbox was overwritten'
                click('#btn-cancel-wf'); protected.append(name)
            return {'protectedDraftChanges': protected}
        def actions_template_entry():
            click('.nav-link[data-page="agents"]'); wait('!!document.querySelector(".nav-link[data-page=\\"agents\\"]")', 'Sessions navigation absent')
            expected = {'action-starter-worktree-check': ['git.status', 'git.diff'], 'action-starter-recent-changes': ['git.log', 'git.status'], 'action-starter-handoff-review': ['git.status', 'git.diff', 'git.log']}; opened = []
            for action, tools in expected.items():
                open_cmdk(); click('#tab-mode-actions'); wait('!!document.querySelector(' + json.dumps('[data-action-id="' + action + '"]') + ')', 'Actions template missing: ' + action); click('[data-action-id="' + action + '"]'); wait('!!document.querySelector("#wf-modal-title")', 'Actions template did not open editor: ' + action)
                assert value('[...document.querySelectorAll(".wf-step-tool")].map(x=>x.value)') == tools, 'Wrong Actions template payload: ' + action
                click('#btn-cancel-wf'); opened.append(action)
            return {'openedFromActions': opened}
        def supported_size_visuals():
            captures = []
            for width, height in ((900, 620), (1250, 720)):
                browser('resize', width, height)
                for page_name, selector in (('settings', '#setting-notifications'), ('workflows', '#btn-wf-starters-menu'), ('actions', '#tab-mode-actions')):
                    if page_name == 'settings': click('.nav-link[data-page="settings"]'); select_settings_category('notifications'); wait('!!document.querySelector("#setting-notifications")', 'Settings unavailable')
                    elif page_name == 'workflows': click('.nav-link[data-page="workflows"]'); wait('!!document.querySelector("#btn-wf-starters-menu")', 'Workflows unavailable')
                    else: open_cmdk(); click('#tab-mode-actions'); wait('!!document.querySelector("#tab-mode-actions")', 'Actions unavailable')
                    assert value('document.documentElement.scrollWidth <= document.documentElement.clientWidth'), 'Horizontal overflow at supported size ' + str(width)
                    assert value('document.querySelector(' + json.dumps(selector) + ').getBoundingClientRect().width > 0'), 'Primary control not visible at ' + str(width)
                    browser('screenshot', str(output / (page_name + '-' + str(width) + '.png'))); captures.append(page_name + '-' + str(width))
                    if page_name == 'actions': close_modal()
            browser('resize', 1280, 720); return {'supportedViewports': [[900, 620], [1250, 720]], 'captures': captures}
        check('actions-keyboard-defaults', actions_keyboard)
        check('actions-project-required', project_required)
        check('search-late-response-isolation', late_search_isolation)
        check('starter-templates-dry-run', starter_templates)
        check('sound-preview-and-visuals', sound_preview_and_visuals)
        check('toast-bounds-and-dismissal', toast_bounds_and_dismissal)
        check('draft-modal-protection', draft_modal_protection)
        check('actions-template-entry', actions_template_entry)
        check('supported-size-visuals', supported_size_visuals)
        evidence['earlyErrors'] = value('window.__ui14EarlyErrors || []')
        evidence['uiErrors'] = value('window.__ui14.errors || []')
        evidence['sourceAfter'] = hashes(ui_source); evidence['fixtureSourceAfter'] = hashes(frozen_ui)
        evidence['binaryAfter'] = hashlib.sha256(binary.read_bytes()).hexdigest(); evidence['fixtureBinaryAfter'] = hashlib.sha256(frozen_binary.read_bytes()).hexdigest()
        evidence['sourceUnchanged'] = evidence['sourceBefore'] == evidence['sourceAfter'] == evidence['fixtureSourceBefore'] == evidence['fixtureSourceAfter']
        evidence['binaryUnchanged'] = evidence['binaryBefore'] == evidence['binaryAfter'] == evidence['fixtureBinaryBefore'] == evidence['fixtureBinaryAfter']
        evidence['selectedChecksPassed'] = set(row['check'] for row in evidence['checks']) == selected_checks and all(row['passed'] for row in evidence['checks']) and evidence['sourceUnchanged'] and evidence['binaryUnchanged'] and not evidence['earlyErrors'] and not evidence['uiErrors']
        evidence['completeSuite'] = selected_checks == known_checks and evidence['selectedChecksPassed']
        (output / 'ui-receipts.json').write_text(json.dumps(value('window.__ui14.calls'), ensure_ascii=False, indent=2) + '\n')
    except Exception as error:
        evidence['harnessError'] = str(error); evidence['traceback'] = traceback.format_exc(limit=5)
    finally:
        if driver:
            try: browser('close')
            except Exception: pass
            if driver.poll() is None:
                os.killpg(driver.pid, signal.SIGTERM)
                try: driver.wait(timeout=5)
                except subprocess.TimeoutExpired: os.killpg(driver.pid, signal.SIGKILL); driver.wait(timeout=5)
        if server:
            server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.kill(); server.wait(timeout=5)
        if fixture_created:
            transcript = base / 'harness-rpc.jsonl'
            if transcript.exists(): (output / 'rpc.jsonl').write_text(transcript.read_text())
            marker = json.loads((base / 'store/.vela-ui-fixture.json').read_text())
            assert marker == {'format': 'vela-ui-fixture-v1', 'synthetic': True, 'manifest': str(base / 'fixture.json')}
            assert not base.is_symlink() and base.resolve() == ROOT.resolve() / '.task-tmp' / base.name
            count = sum(1 for path in base.rglob('*') if path.is_file())
            shutil.rmtree(base); evidence['cleanup'] = {'removedOwnedFixture': str(base), 'removedFiles': count, 'browserAndServerStopped': True, 'evidenceRetained': True}
        try:
            evidence['sourceAfter'] = hashes(ui_source)
            evidence['binaryAfter'] = hashlib.sha256(binary.read_bytes()).hexdigest()
            evidence['sourceUnchanged'] = evidence.get('sourceBefore') == evidence['sourceAfter']
            evidence['binaryUnchanged'] = evidence.get('binaryBefore') == evidence['binaryAfter']
        except OSError as error:
            evidence['hashAfterError'] = str(error)
        save()
    return 0 if evidence.get('selectedChecksPassed') else 1


if __name__ == '__main__':
    raise SystemExit(main())
