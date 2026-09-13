"""Locale regression through product renderer and a real isolated CLI.

Requires Python 3.9+, Node.js 20+, built .build/debug/vela, and Playwright 1.62.1:
  npm install --prefix .task-tmp/ui-browser-tools --registry=https://registry.npmjs.org --save-exact playwright@1.62.1
  node .task-tmp/ui-browser-tools/node_modules/playwright/cli.js install chromium
  python3 scripts/test-localization-browser.py

Use --browser-executable for an installed Chrome; omitted uses Playwright Chromium.
The fixture/output paths must be NEW. Legacy/corrupt locale rows are constructed
only in the generated fixture, before its HTTP helper starts. No provider, Hook,
workflow or native menu action executes. Native locale events are explicitly
injected; browser/helper restart is real. Successful fixtures are removed and
evidence retained; failed fixtures remain for diagnosis. No tools are installed.
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
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
NAV = {
    'zh-CN': {'agents': '会话', 'workflows': '工作流', 'inbox': '待办审批', 'memory': '工程记忆',
              'setup': '配置与资产', 'usage': '用量追踪', 'improve': '调优建议', 'lab': '对照实验', 'settings': '设置'},
    # Exact labels agreed with the renderer author; user content is never matched against this map.
    'en': {'agents': 'Sessions', 'workflows': 'Workflows', 'inbox': 'Approvals', 'memory': 'Memory',
           'setup': 'Setup', 'usage': 'Usage', 'improve': 'Improve', 'lab': 'Lab', 'settings': 'Settings'},
}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--fixture', type=Path, default=ROOT / '.task-tmp/localization-browser-qa')
    parser.add_argument('--output', type=Path, default=ROOT / 'output/playwright/localization-browser-qa')
    parser.add_argument('--binary', type=Path, default=ROOT / '.build/debug/vela')
    parser.add_argument('--playwright-module', type=Path, default=ROOT / '.task-tmp/ui-browser-tools/node_modules/playwright/index.js')
    parser.add_argument('--browser-executable', type=Path)
    parser.add_argument('--keep-fixture', action='store_true')
    parser.add_argument('--ui-snapshot', type=Path, help='Copy a previously frozen UI into the generated fixture for a single-version check.')
    args = parser.parse_args()
    base, output, binary = args.fixture.absolute(), args.output.absolute(), args.binary.resolve(strict=True)
    if base.exists() or base.is_symlink() or not base.resolve().is_relative_to((ROOT / '.task-tmp').resolve()):
        parser.error('Use a NEW fixture below repository .task-tmp.')
    if output.exists() or not output.resolve().is_relative_to((ROOT / 'output/playwright').resolve()):
        parser.error('Use a NEW evidence directory below output/playwright.')
    if not shutil.which('node') or not args.playwright_module.is_file() or (args.browser_executable and not args.browser_executable.is_file()):
        parser.error('Install the documented dependencies; this test does not install them.')
    output.mkdir(parents=True)
    subprocess.run(['python3', str(ROOT / 'scripts/create-ui-fixture.py'), str(base), '--binary', str(binary)],
                   check=True, capture_output=True, text=True, timeout=90)
    fixture = json.loads((base / 'fixture.json').read_text())
    ui = ROOT / 'Sources/VelaApp/Resources/UI'
    if args.ui_snapshot:
        ui = base / 'ui-snapshot'
        shutil.copytree(args.ui_snapshot.resolve(strict=True), ui)
    project, home = fixture['project'], fixture['home']
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(base), 'VELA_HOME': home,
           'VELA_SESSION_ROOT': fixture['sessionRoot'], 'VELA_DISABLE_DISCOVERY': '1',
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull}

    def hashes():
        return {str(p.relative_to(ui)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(ui.rglob('*')) if p.is_file() and p.suffix in ('.js', '.css', '.html', '.json')}

    results = []
    evidence = {'format': 'vela-localization-browser-v1', 'synthetic': True, 'startedAt': stamp,
        'platform': platform.platform(), 'playwrightVersion': json.loads((args.playwright_module.resolve().parent / 'package.json').read_text())['version'],
        'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'uiSHA256': hashes(),
        'checks': results, 'completeSuite': False, 'realProviderExecuted': False,
        'nativeIntegrationTested': False, 'localeEventInjected': True}

    def direct(method, params=None, expect_error=False):
        request = {'id': 'locale-test', 'method': method, 'params': params or {}}
        run = subprocess.run([str(binary), 'rpc', '--home', home, '--no-watch'], input=json.dumps(request) + '\n',
                             text=True, capture_output=True, env=env, cwd=base, timeout=20)
        assert run.returncode == 0, run.stderr
        response = next(json.loads(line) for line in run.stdout.splitlines() if json.loads(line).get('id') == 'locale-test')
        with (output / 'direct-rpc.jsonl').open('a') as log:
            log.write(json.dumps({'request': request, 'response': response}, ensure_ascii=False) + '\n')
        assert ('error' in response) == expect_error, response
        return response.get('result')

    def legacy(value, missing=False):
        # The helper is not running here; alter only locale in our marked disposable store.
        marker = json.loads((Path(home) / '.vela-ui-fixture.json').read_text())
        assert marker == {'format': 'vela-ui-fixture-v1', 'synthetic': True, 'manifest': str(base / 'fixture.json')}
        with sqlite3.connect(str(Path(home) / 'vela.sqlite3')) as db:
            row = json.loads(db.execute("SELECT json FROM objects WHERE kind='settings' AND id='preferences'").fetchone()[0])
            if missing:
                row.pop('locale', None)
            else:
                row['locale'] = value
            db.execute("UPDATE objects SET json=? WHERE kind='settings' AND id='preferences'", (json.dumps(row),))

    server = driver = None
    url = None
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('vela_locale_transport', ROOT / 'scripts/test-ui-browser.py')
    transport = importlib.util.module_from_spec(spec); spec.loader.exec_module(transport)

    def start():
        nonlocal server, driver, url
        server = subprocess.Popen(['python3', str(ROOT / 'scripts/test-ui-server.py'), str(base / 'fixture.json'), '--binary', str(binary), *(['--ui-directory', str(ui)] if args.ui_snapshot else [])],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert select.select([server.stdout], [], [], 15)[0], 'Fixture helper did not start.'
        url = json.loads(server.stdout.readline())['url']
        source = '// Vela locale fixture: ' + json.dumps(str(base)) + '\n' + transport.PLAYWRIGHT_DRIVER
        source = source.replace('page.setDefaultTimeout(5000);', '''page.setDefaultTimeout(5000);
        await page.addInitScript(() => {
          window.__localePageErrors = [];
          window.addEventListener('error', event => window.__localePageErrors.push(String(event.error?.stack || event.message)));
          window.addEventListener('unhandledrejection', event => window.__localePageErrors.push(String(event.reason?.stack || event.reason)));
        });''')
        source = source.replace('  }\n})().catch', '  }\n  await browser.close();\n})().catch')
        driver = subprocess.Popen(['node', '-e', source, str(args.playwright_module.resolve()), str(args.browser_executable or '')],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        browser('open', url); browser('wait', '#session-search-input')

    def browser(*commands):
        driver.stdin.write(json.dumps(commands) + '\n'); driver.stdin.flush()
        assert select.select([driver.stdout], [], [], 15)[0], 'Playwright response timed out.'
        response = json.loads(driver.stdout.readline())
        assert 'error' not in response, response.get('error')
        # Side-effect-only eval expressions legitimately return JavaScript undefined.
        return response.get('output', '')

    def value(expression):
        return json.loads(browser('eval', expression))

    def wait(expression, reason):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if value(expression):
                browser('eval', 'new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))')
                return
            time.sleep(.1)
        raise AssertionError(reason)

    def rpc(method, params=None):
        request = urllib.request.Request(url + '__rpc', json.dumps({'method': method, 'params': params or {}}).encode(),
            {'Content-Type': 'application/json', 'Origin': 'http://' + url.split('/')[2]})
        with urllib.request.urlopen(request, timeout=20) as response:
            data = json.load(response)
        assert 'error' not in data, data
        return data['result']

    def stop():
        nonlocal driver, server
        if driver is not None:
            try:
                if driver.poll() is None:
                    browser('close')
            finally:
                if driver.poll() is None:
                    os.killpg(driver.pid, signal.SIGTERM); driver.wait(timeout=5)
                driver = None
        if server is not None:
            server.terminate(); server.wait(timeout=10); server = None

    def page(name):
        browser('press', 'Escape'); browser('press', 'Escape')
        browser('click', '.nav-link[data-page=' + json.dumps(name) + ']')
        wait('document.querySelector(".nav-link.active")?.dataset.page===' + json.dumps(name), 'Route did not settle.')

    def nav(locale):
        expected = NAV[locale]
        wait('document.documentElement.lang===' + json.dumps(locale), 'Document language did not update.')
        actual = value('Object.fromEntries(Array.from(document.querySelectorAll(".nav-link[data-page]")).map(el=>[el.dataset.page,el.querySelector(".nav-label").textContent.trim()]))')
        assert actual == expected, {'expected': expected, 'actual': actual}

    def external_locale(locale):
        rpc('settings.save', {'locale': locale})
        browser('eval', 'window.dispatchEvent(new CustomEvent("vela:localeChanged",{detail:{locale:' + json.dumps(locale) + '}}))')
        nav(locale)

    def record(name, action):
        if driver is not None:
            browser('eval', 'window.__localePageErrors=[]')
        try:
            result = {'check': name, 'passed': True, 'detail': action()}
        except Exception as error:
            result = {'check': name, 'passed': False, 'error': str(error)}
        if driver is not None:
            try:
                result['pageErrors'] = value('window.__localePageErrors || []')
                if result['pageErrors']:
                    result['passed'] = False
                browser('screenshot', str(output / (name + '.png')))
                (output / (name + '.txt')).write_text(browser('snapshot', '-i'))
            except Exception as error:
                result['captureError'] = str(error)
        results.append(result)
        (output / 'results.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False), flush=True)
        return result['passed']

    def core_contract():
        legacy(None, missing=True)
        assert direct('settings.get')['locale'] == 'zh-CN'
        for invalid in ['fr', 'en-US', '', None, True, 1, [], {}]:
            before = direct('settings.get')
            direct('settings.save', {'locale': invalid, 'analysisEnabled': not before['analysisEnabled']}, expect_error=True)
            assert direct('settings.get') == before, 'Rejected locale patch mutated another preference.'
        legacy('invalid-legacy-locale')
        assert direct('settings.get')['locale'] == 'zh-CN'
        direct('settings.save', {'locale': 'en'})
        assert direct('settings.get')['locale'] == 'en', 'New CLI process did not read persisted English.'
        direct('settings.save', {'locale': 'zh-CN'})
        return {'default': 'zh-CN', 'invalidPatches': 8, 'legacyFallback': True, 'newHelperRead': 'en'}

    try:
        if not record('core-locale-contract', core_contract):
            raise RuntimeError('Core locale contract failed; UI checks were not attempted.')
        literal = '设置 Settings / 工作流 Workflows / 已完成 Completed / Candidate Active / /tmp/设置.txt / --lang=中文'
        branch = "feature/设置-quote'branch"
        log = Path(fixture['sessionRoot']) / 'codex' / 'locale-content.jsonl'
        rows = [{'type': 'session_meta', 'timestamp': stamp, 'payload': {'id': 'locale-content', 'cwd': project, 'git': {'branch': branch}}},
                {'type': 'response_item', 'timestamp': stamp, 'payload': {'id': 'locale-message', 'type': 'message', 'role': 'user',
                 'content': [{'type': 'input_text', 'text': literal}]}}]
        log.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows))
        direct('sessions.refresh')
        session = next(s for s in direct('sessions.list') if s.get('sourceSessionId') == 'locale-content')
        memory_title = '''设置 Settings — O'Hara "quoted" > <span id="locale-markup-sentinel">safe</span>'''
        memory = direct('memory.save', {'project': project, 'scope': 'project', 'state': 'active', 'title': memory_title,
            'content': literal, 'sourceSession': session['id'], 'sourceMessage': 'locale-message'})
        start()
        if value('document.querySelector("#project-selector").value') != project:
            browser('select', '#project-selector', project)
            wait('window.__velaUITest.dashboardProject===' + json.dumps(project), 'Project did not load.')

        def settings_draft():
            nav('zh-CN'); page('settings'); browser('wait', '#setting-locale')
            original = rpc('settings.get')
            browser('click', '#setting-analysis')
            browser('eval', 'window.__localeDraftInput=document.querySelector("#setting-analysis")')
            before_lines = len((base / 'harness-rpc.jsonl').read_text().splitlines())
            browser('select', '#setting-locale', 'en'); nav('en')
            after = rpc('settings.get')
            assert after['locale'] == 'en' and after['analysisEnabled'] == original['analysisEnabled']
            assert value('document.querySelector("#setting-analysis").checked') != original['analysisEnabled']
            assert value('document.querySelector("#setting-analysis")===window.__localeDraftInput'), 'Locale replaced unsaved settings controls.'
            assert value('document.querySelector(".nav-link.active").dataset.page') == 'settings'
            calls = [json.loads(x) for x in (base / 'harness-rpc.jsonl').read_text().splitlines()[before_lines:]]
            assert [x['params'] for x in calls if x['method'] == 'settings.save'] == [{'locale': 'en'}]
            return {'onlyLocaleSaved': True, 'unsavedAnalysisPreserved': True, 'navigationLabels': NAV}

        record('settings-switch-preserves-draft', settings_draft)

        def selected_content():
            page('agents')
            title_selector = '.session-title-btn[data-id=' + json.dumps(session['id']) + ']'
            browser('wait', title_selector)
            browser('eval', 'window.__localeSessionButton=document.querySelector(' + json.dumps(title_selector) + ');'
                'window.__localeSessionCard=window.__localeSessionButton.closest(".session-card");'
                'window.__localeSessionBranch=window.__localeSessionCard.querySelector(".session-meta-branch")')
            live_attributes = []
            for locale in ['en', 'zh-CN', 'en']:
                if value('document.documentElement.lang') != locale:
                    external_locale(locale)
                sample = value('(()=>{const card=window.__localeSessionCard,button=window.__localeSessionButton,branch=window.__localeSessionBranch;'
                    'return {sameNodes:card.isConnected&&button===card.querySelector(".session-title-btn")&&branch===card.querySelector(".session-meta-branch"),'
                    'rowAria:card.getAttribute("aria-label"),buttonAria:button.getAttribute("aria-label"),'
                    'title:button.getAttribute("title"),rowTitle:card.getAttribute("title"),branchTitle:branch.getAttribute("title"),'
                    'branchText:branch.textContent.trim(),visibleTitle:button.textContent.trim()};})()')
                prefixes = {'en': ['View session: ', 'Status source: ', 'Status basis: ', 'Branch: '],
                            'zh-CN': ['查看会话: ', '状态来源: ', '状态依据: ', '分支: ']}[locale]
                assert sample['sameNodes'], 'Language change replaced the existing session card or controls.'
                assert sample['rowAria'] == sample['buttonAria'] and sample['rowAria'].startswith(prefixes[0] + session['title'] + ' · '), sample
                assert sample['rowTitle'] == prefixes[1] + session['statusSource'] + ' · ' + prefixes[2] + session['statusEvidence'], sample
                assert sample['branchTitle'] == prefixes[3] + branch and sample['branchText'] == branch, sample
                assert sample['title'] == sample['visibleTitle'] == literal, sample
                live_attributes.append({'locale': locale, **sample})
            (output / 'session-live-attributes.json').write_text(json.dumps(live_attributes, ensure_ascii=False, indent=2) + '\n')
            browser('click', title_selector)
            selector = '[data-message-id="locale-message"]'
            browser('wait', selector)
            before = rpc('sessions.get', {'id': session['id']})
            external_locale('zh-CN')
            assert value('document.querySelector(".nav-link.active").dataset.page') == 'agents'
            assert value('document.querySelector(' + json.dumps(selector) + ')?.textContent.includes(' + json.dumps(literal) + ')')
            assert not value('document.querySelector("#detail-drawer").classList.contains("hidden")')
            assert rpc('sessions.get', {'id': session['id']}) == before
            page('memory')
            browser('click', '.btn-mem-view[data-id=' + json.dumps(memory['id']) + ']')
            browser('wait', '#drawer-content .code-view')
            external_locale('en')
            assert value('document.querySelector("#drawer-content .code-view").textContent') == literal
            assert value('document.querySelector("#drawer-content").textContent.includes(' + json.dumps(project) + ')')
            stored = next(m for m in rpc('memory.list', {'project': project}) if m['id'] == memory['id'])
            assert stored['content'] == literal and stored['title'] == memory['title']
            browser('press', 'Escape')
            browser('click', '.btn-mem-supersede[data-id=' + json.dumps(memory['id']) + ']')
            notice = '[data-i18n="memory.supersedeNotice"]'
            browser('wait', notice)
            for locale in ['en', 'zh-CN', 'en']:
                if locale != 'en' or value('document.documentElement.lang') != 'en':
                    external_locale(locale)
                assert value('JSON.parse(document.querySelector(' + json.dumps(notice) + ').getAttribute("data-i18n-params")).title') == memory_title
                assert value('document.querySelector(' + json.dumps(notice) + ').textContent.includes(' + json.dumps(memory_title) + ')')
                assert value('document.querySelectorAll("#locale-markup-sentinel").length') == 0
            assert next(m for m in rpc('memory.list', {'project': project}) if m['id'] == memory['id']) == stored
            return {'exactMessage': 'locale-message', 'memoryId': memory['id'], 'userTextAndPathUnchanged': True,
                    'supersedeTitleQuotesAndMarkupPreserved': True, 'injectedNodes': 0, 'supersedeSubmitted': False,
                    'sessionLiveAttributeLocales': ['en', 'zh-CN', 'en'], 'sessionNodesPreserved': True}

        record('selected-records-and-user-content', selected_content)

        def workflow_draft():
            page('workflows'); browser('click', '#btn-new-workflow'); browser('wait', '#wf-modal-title')
            title = '未保存 / Settings / 新建工作流'
            argv = json.dumps({'executable': '/usr/bin/true', 'args': ['', '设置', 'argument with spaces', 'quote"argument']}, ensure_ascii=False)
            browser('fill', '#wf-modal-title', title)
            browser('fill', '.wf-step-args[data-idx="0"]', argv)
            browser('focus', '.wf-step-args[data-idx="0"]')
            browser('eval', 'window.__localeForm=document.querySelector(".wf-step-args[data-idx=\\"0\\"]");window.__localeForm.setSelectionRange(3,9)')
            external_locale('zh-CN')
            assert value('document.querySelector("#wf-modal-title").value') == title
            assert value('window.__localeForm.isConnected&&document.activeElement===window.__localeForm&&window.__localeForm.selectionStart===3&&window.__localeForm.selectionEnd===9')
            assert value('window.__localeForm.value') == argv
            assert value('document.querySelector(".nav-link.active").dataset.page') == 'workflows'
            assert not any(w['title'] == title for w in rpc('workflows.list', {'project': project}))
            return {'draftSaved': False, 'argvUnchanged': True, 'focusSelectionPreserved': True}

        record('unsaved-workflow-and-argv', workflow_draft)

        def restart():
            page('settings'); browser('select', '#setting-locale', 'en'); nav('en')
            assert rpc('settings.get')['locale'] == 'en'
            stop(); start(); nav('en')
            page('settings'); browser('wait', '#setting-locale')
            assert value('document.querySelector("#setting-locale").value') == 'en'
            browser('select', '#setting-locale', 'zh-CN'); nav('zh-CN')
            assert rpc('settings.get')['locale'] == 'zh-CN'
            return {'browserAndHelperRestarted': True, 'persistedLocale': 'en', 'returnedToChinese': True}

        record('restart-and-roundtrip', restart)

        def english_coverage():
            external_locale('en')
            surfaces, issues = [], []
            def inspect(name, ready, scope='#main-content'):
                try:
                    browser('wait', ready)
                    sample = value(r'''(()=>{
                      const scope=document.querySelector(SCOPE), rows=[], userStrings=USER_STRINGS;
                      const selectors='.page-header h1,.page-header p,h2,h3,.form-label,.empty-state-title,.empty-state-desc,.status-badge,button,input[placeholder],textarea[placeholder],[data-i18n]';
                      for(const el of scope.querySelectorAll(selectors)){
                        if(!el.getClientRects().length||el.closest('#setting-locale')||el.matches('.session-title-btn,.btn-open-source'))continue;
                        const key=el.getAttribute('data-i18n'), params=el.getAttribute('data-i18n-params');
                        // Inspect the fixed template for interpolated labels, never reject user Chinese.
                        const text=params&&key?window.VelaI18n.DICTIONARY.en[key]:
                          el.matches('input,textarea')?el.placeholder:el.textContent;
                        if(text&&text.trim()&&!userStrings.includes(text.trim()))rows.push({selector:el.id?'#'+el.id:el.tagName.toLowerCase()+'.'+el.className,key,text:text.trim().slice(0,400)});
                        for(const attr of ['placeholder','aria-label','title']){
                          const attrKey=el.getAttribute('data-i18n-'+attr), raw=el.getAttribute(attr);
                          const attrText=params&&attrKey?window.VelaI18n.DICTIONARY.en[attrKey]:raw;
                          if(attrText)rows.push({selector:el.id?'#'+el.id:el.tagName.toLowerCase(),attribute:attr,key:attrKey,text:attrText.slice(0,400)});
                        }
                      }
                      return {rows,residualFixedChinese:rows.filter(x=>/[\u3400-\u9fff]/.test(x.text))};
                    })()'''.replace('SCOPE', json.dumps(scope)).replace('USER_STRINGS', json.dumps([literal, memory['title']])))
                    sample['surface'] = name
                    surfaces.append(sample)
                    if sample['residualFixedChinese']:
                        issues.append({'surface': name, 'fixedChinese': sample['residualFixedChinese']})
                    browser('screenshot', str(output / ('english-' + name + '.png')))
                    (output / ('english-' + name + '.txt')).write_text(browser('snapshot', '-i'))
                except Exception as error:
                    issues.append({'surface': name, 'error': str(error)})

            routes = {'agents': '#session-search-input', 'workflows': '#btn-new-workflow', 'inbox': '.btn-approve-appr',
                      'memory': '#btn-new-memory', 'setup': '#btn-scan-setup', 'usage': '#usage-total-tokens',
                      'improve': '#btn-run-analysis', 'lab': '#btn-new-lab', 'settings': '#setting-locale'}
            for route, ready in routes.items():
                page(route); inspect(route, ready)
            # Explicit, read-only entry paths. No modal Save/Run/Apply/approval is clicked.
            modals = [
                ('memory', 'memory-new', '#btn-new-memory', '#mem-title', None),
                ('memory', 'recall', '#btn-recall-tester', '#recall-query', None),
                ('memory', 'reuse', '#btn-configure-reuse', '#reuse-project-select', None),
                ('workflows', 'workflow-new', '#btn-new-workflow', '#wf-modal-title', None),
                ('lab', 'lab-new', '#btn-new-lab', '#lab-agent-task', None),
                ('setup', 'guideline-new', '#btn-new-guideline', '#gl-title', '[data-setuptab="guidelines"]'),
                ('setup', 'library-new', '#btn-add-library', '#lib-title', '[data-setuptab="library"]'),
            ]
            for route, name, trigger, ready, tab in modals:
                try:
                    page(route)
                    if tab:
                        browser('click', tab)
                    browser('click', trigger)
                    inspect(name, ready, '#modal-container')
                except Exception as error:
                    issues.append({'surface': name, 'error': str(error)})
            page('agents'); browser('press', 'Meta+k')
            inspect('global-search', '#global-search-input', '#modal-container')
            parity = value('window.VelaI18n.checkParity()')
            missing = value('window.VelaI18n.getMissingKeys()')
            navigation_aria = value('document.querySelector("nav.sidebar-nav").getAttribute("aria-label")')
            if not navigation_aria or any('\u3400' <= char <= '\u9fff' for char in navigation_aria):
                issues.append({'surface': 'sidebar', 'fixedNavigationAria': navigation_aria})
            detail = {'surfaces': surfaces, 'issues': issues, 'parity': parity, 'missingKeys': missing,
                      'userContentExcluded': True, 'nativeMenusCovered': False}
            (output / 'english-coverage.json').write_text(json.dumps(detail, ensure_ascii=False, indent=2) + '\n')
            assert not parity['missingInEn'] and not parity['missingInZh'], parity
            assert not missing, {'missingKeys': missing}
            assert not issues, {'coverageIssues': issues}
            return {'routes': 9, 'modals': 8, 'fixedChinese': [], 'missingKeys': [], 'catalogKeys': parity['totalEn']}

        record('english-surface-coverage', english_coverage)
    finally:
        stop()
        transcript = base / 'harness-rpc.jsonl'
        if transcript.exists():
            shutil.copyfile(transcript, output / 'harness-rpc.jsonl')
        evidence['uiSHA256After'] = hashes()
        evidence['uiSourceUnchangedDuringRun'] = evidence['uiSHA256After'] == evidence['uiSHA256']
        evidence['completeSuite'] = len(results) == 6 and all(r['passed'] for r in results) and evidence['uiSourceUnchangedDuringRun']
        evidence['cleanup'] = {'browserClosed': driver is None, 'helperStopped': server is None, 'fixtureRemoved': False}
        if evidence['completeSuite'] and not args.keep_fixture:
            marker = json.loads((Path(home) / '.vela-ui-fixture.json').read_text())
            assert marker['manifest'] == str(base / 'fixture.json') and marker['synthetic'] is True
            shutil.rmtree(base); evidence['cleanup']['fixtureRemoved'] = True
        (output / 'results.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')
    if not evidence['completeSuite']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
