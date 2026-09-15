"""Exercise actual Setup, workflow management, Ask and loop UI flows.

Requires a NEW owned frozen fixture and output directory. The real helper runs
against synthetic files. A byte-pinned local provider emits deterministic JSONL;
no external model, connector, real credentials or daemon lifecycle executes.
Native dialog acceptance is explicitly a browser test boundary.
"""
import argparse, hashlib, importlib.util, json, os
from pathlib import Path
from release_resources import DEVELOPMENT_UI_RESOURCES, UI_RESOURCES
import select, shutil, signal, subprocess, time, traceback, urllib.request

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--browser-executable', type=Path)
    args = parser.parse_args()
    base, output = args.fixture.resolve(strict=True), args.output.absolute()
    if not base.is_relative_to((ROOT/'.task-tmp').resolve()) or output.exists() or not output.resolve().is_relative_to((ROOT/'output/playwright').resolve()):
        parser.error('Use an owned fixture and a NEW output/playwright evidence directory.')
    fixture = json.loads((base/'fixture.json').read_text())
    assert fixture['synthetic'] is True
    binary, ui = base/'vela-frozen', base/'ui-snapshot'
    output.mkdir(parents=True)
    module_path = ROOT/'.task-tmp/ui-browser-tools/node_modules/playwright/index.js'
    spec = importlib.util.spec_from_file_location('vela_browser_helpers',ROOT/'scripts/test-ui-browser.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    source = module.PLAYWRIGHT_DRIVER.replace("else if(command==='select')", "else if(command==='files')await page.locator(args[0]).setInputFiles(args[1]);\n      else if(command==='select')")
    source = source.replace("else if(command==='select')", "else if(command==='dialog')page.once('dialog', dialog => args[0]==='accept'?dialog.accept(args[1]??''):dialog.dismiss());\n      else if(command==='select')")
    provider=base/'synthetic-codex'
    if not provider.exists():
        shutil.copyfile(ROOT/'scripts/ui-fixture-provider.py',provider); provider.chmod(0o700)
    assert provider.read_bytes()==(ROOT/'scripts/ui-fixture-provider.py').read_bytes()
    counter=provider.with_suffix('.calls.jsonl')
    server = subprocess.Popen(['python3',str(ROOT/'scripts/test-ui-server.py'),str(base/'fixture.json'),'--binary',str(binary),'--ui-directory',str(ui)],stdout=subprocess.PIPE,text=True)
    driver = None; results=[]
    def hashes():
        return {name:hashlib.sha256((ui/name).read_bytes()).hexdigest() for name in UI_RESOURCES + DEVELOPMENT_UI_RESOURCES}
    evidence={'format':'vela-engineering-renderer-v1','synthetic':True,'sourceBefore':hashes(),'helperSHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),
              'realProviderExecuted':False,'syntheticProviderProcess':True,'nativeDialogsTested':False,'checks':results,'completeSuite':False}
    def browser(*args):
        driver.stdin.write(json.dumps(args)+'\n'); driver.stdin.flush()
        assert select.select([driver.stdout],[],[],15)[0], 'Browser response timed out'
        reply=json.loads(driver.stdout.readline())
        assert 'error' not in reply, reply.get('error')
        return reply.get('output','')
    def value(expression): return json.loads(browser('eval',expression))
    def wait(expression,reason,seconds=10):
        deadline=time.monotonic()+seconds
        while time.monotonic()<deadline:
            if value(expression): return
            time.sleep(.08)
        raise AssertionError(reason)
    def click(selector):
        browser('snapshot','-i'); browser('click',selector); browser('snapshot','-i')
    def open_action_menu(trigger):
        menu = 'details.action-menu:has(' + trigger + ')'
        open_menu(menu, trigger)
    def open_menu(menu, label):
        wait('!!document.querySelector(' + json.dumps(menu) + ')', 'Action menu is absent for ' + label)
        if not value('document.querySelector(' + json.dumps(menu) + ').open'):
            click(menu + ' > summary')
            wait('document.querySelector(' + json.dumps(menu) + ').open===true', 'Action menu did not open for ' + label)
    def open_setup_history(item):
        row = 'article[data-testid="asset-row"][data-asset-id="' + item['id'] + '"]'
        wait('!!document.querySelector(' + json.dumps(row) + ')', 'Setup asset row is absent')
        trigger = row + ' .btn-setup-history[data-id="' + item['id'] + '"]'
        open_menu(row + ' details.action-menu', trigger)
        click(trigger)
    def open_mcp_history(item):
        row = 'article.record-row[data-asset-id="' + item['id'] + '"]'
        history = row + ' .btn-setup-history[data-id="' + item['id'] + '"]'
        wait('!!document.querySelector(' + json.dumps(row) + ')', 'MCP record row is absent')
        open_menu(row + ' details.action-menu', history)
        click(history)
    def page(name):
        browser('press','Escape'); browser('press','Escape')
        click('.nav-link[data-page="'+name+'"]')
        wait('document.querySelector(".nav-link.active")?.dataset.page==='+json.dumps(name),'Navigation did not settle')
    def rpc(method,params=None):
        request=urllib.request.Request(url+'__rpc',json.dumps({'method':method,'params':params or {}}).encode(),{'Content-Type':'application/json','Origin':'http://'+url.split('/')[2]})
        with urllib.request.urlopen(request,timeout=25) as response: data=json.load(response)
        assert 'error' not in data,data
        return data['result']
    def events():
        path=base/'harness-rpc.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    def check(name,body):
        try:
            body(); results.append({'check':name,'passed':True})
        except Exception as error:
            results.append({'check':name,'passed':False,'error':str(error),'traceback':traceback.format_exc(limit=3)})
            browser('screenshot',str(output/('failure-'+name+'.png')))
            (output/(name+'-snapshot.txt')).write_text(browser('snapshot','-i'))
        print(json.dumps(results[-1],ensure_ascii=False),flush=True)
        (output/'results.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n')
    try:
        assert select.select([server.stdout],[],[],15)[0], 'Fixture server did not start'
        url=json.loads(server.stdout.readline())['url']
        driver=subprocess.Popen(['node','-e',source,str(module_path),str(args.browser_executable or '')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,start_new_session=True)
        browser('open',url); browser('wait','#session-search-input'); browser('snapshot','-i')
        project=fixture['project']
        initial_approvals={a['id'] for a in rpc('inbox.list',{})}
        browser('select','#project-selector',project)
        wait('document.querySelector("#project-selector").value==='+json.dumps(project),'Explicit fixture project was not selected')
        browser('snapshot','-i')
        def count_calls():
            return len(counter.read_text().splitlines()) if counter.exists() else 0
        def modal_text(): return value("document.querySelector('#modal-body').textContent")
        def setup_history():
            page('setup'); open_action_menu('#btn-catalog-setup'); click('#btn-catalog-setup')
            wait("document.querySelector('#modal-body').textContent.toLowerCase().includes('omp')",'Five-provider catalog did not render')
            assert all(name.lower() in modal_text().lower() for name in ['Claude','Codex','Cursor','Pi','OMP'])
            assert count_calls()==0
            browser('press','Escape')
            path=Path(project)/'AGENTS.md'
            path.write_text(path.read_text()+'\nUI_REVIEW_ADDED: Keep release fixtures isolated.\n')
            before=len(events()); click('#btn-scan-setup')
            wait("!document.querySelector('#btn-scan-setup').disabled",'Explicit scan did not finish')
            records=rpc('setup.list',{'project':project})
            item=next(a for a in records if a.get('path')==str(path))
            assert any(e['method']=='setup.scan' and e['ok'] for e in events()[before:])
            open_setup_history(item)
            wait("document.querySelectorAll('#diff-from-select option').length>=2",'Observed revisions absent')
            click('#btn-run-setup-diff')
            wait("document.querySelector('#setup-diff-result').textContent.includes('UI_REVIEW_ADDED')",'Actual source diff did not render')
            assert 'synthetic-secret-do-not-display' not in modal_text()
            browser('screenshot',str(output/'setup-observed-diff.png'))
        check('setup-real-source-change-history-and-diff',setup_history)

        def setup_earlier_revisions():
            browser('press','Escape')
            path=Path(project)/'AGENTS.md'
            original=path.read_text()
            for revision in range(32):
                path.write_text(original+'\nPAGINATED_REVISION_'+str(revision)+'\n')
                rpc('setup.scan',{'project':project})
            item=next(a for a in rpc('setup.list',{'project':project}) if a.get('path')==str(path))
            history=rpc('setup.history',{'project':project,'id':item['id']})
            assert len(history['revisions'])==30 and history['nextBefore'] is not None
            page('setup')
            open_setup_history(item)
            wait("document.querySelectorAll('#diff-from-select option').length===30",'First observed history page absent')
            selected=str(history['revisions'][-1]['revision'])
            browser('select','#diff-from-select',selected)
            before=len(events())
            click('#btn-load-earlier-setup-revisions')
            wait("document.querySelectorAll('#diff-from-select option').length>30",'Earlier observed versions were not appended')
            options=value("Array.from(document.querySelectorAll('#diff-from-select option')).map(x=>x.value)")
            assert len(options)==len(set(options)) and '1' in options
            assert value("document.querySelector('#diff-from-select').value")==selected, 'Loading history discarded the selected comparison'
            pages=[e for e in events()[before:] if e['method']=='setup.history']
            assert len(pages)==1 and pages[0]['ok'] and pages[0]['params'].get('before')==history['nextBefore'], 'UI did not use the actual history cursor'
            browser('select','#diff-from-select','1')
            click('#btn-run-setup-diff')
            wait("document.querySelector('#setup-diff-result').textContent.includes('PAGINATED_REVISION_31')",'Oldest observed version is not usable for comparison')
            browser('screenshot',str(output/'setup-earlier-revisions.png'))
        check('setup-history-pagination-retains-comparison-and-oldest-version',setup_earlier_revisions)

        def setup_redacted_change():
            browser('press','Escape')
            path=Path(project)/'.mcp.json'
            document=json.loads(path.read_text())
            document['mcpServers']['fixture-read-only']['env']['API_KEY']='synthetic-rotated-mcp-secret'
            path.write_text(json.dumps(document)+'\n')
            rpc('setup.scan',{'project':project})
            item=next(a for a in rpc('setup.list',{'project':project}) if a.get('path')==str(path))
            diff=rpc('setup.diff',{'project':project,'id':item['id']})
            assert diff['sourceChanged'] is True and diff['sanitizedTextChanged'] is False
            page('setup')
            click('[data-setuptab="mcp"]')
            open_mcp_history(item)
            wait("!!document.querySelector('#btn-run-setup-diff')",'Configuration history not available')
            click('#btn-run-setup-diff')
            wait("!!document.querySelector('#setup-diff-result [data-i18n=\"setup.diffSourceChangedOnly\"]')",'Source change was incorrectly presented as no change')
            notice=value("document.querySelector('#setup-diff-result [data-i18n=\"setup.diffSourceChangedOnly\"]').innerText")
            assert notice and notice!='setup.diffSourceChangedOnly'
            assert 'synthetic-rotated-mcp-secret' not in modal_text() and 'synthetic-mcp-secret-do-not-display' not in modal_text()
            browser('screenshot',str(output/'setup-redacted-source-change.png'))
        check('setup-secret-rotation-explained-without-secret-content',setup_redacted_change)

        def setup_action_menu():
            page('setup'); click('[data-setuptab="rules"]')
            first_id = value('document.querySelector(\'article[data-testid="asset-row"]\')?.dataset.assetId')
            assert first_id, 'Setup asset row has no identity'
            row = 'article[data-testid="asset-row"][data-asset-id="' + first_id + '"]'
            wait('!!document.querySelector(' + json.dumps(row) + ')', 'Setup asset row is absent')
            menu = row + ' details.action-menu'
            summary = menu + ' > summary'
            state_js='''(() => {
                const row=document.querySelector('article[data-testid="asset-row"]');
                const menu=row?.querySelector('details.action-menu');
                const summary=menu?.querySelector('summary');
                return {open:menu?.open===true, visibleSummary:!!summary?.getClientRects().length,
                    visibleRowButtons:[...row.querySelectorAll(':scope > button,.workspace-row-content > button')].filter(b=>b.getClientRects().length>0).length,
                    actionCount:menu?.querySelectorAll('button').length || 0};
            })()'''
            initial=value(state_js)
            assert not initial['open'] and initial['visibleSummary'] and initial['actionCount']>=2,initial
            value('document.querySelector(' + json.dumps(summary) + ').focus();true')
            browser('press','Enter')
            opened_by_keyboard=value(state_js)
            assert opened_by_keyboard['open'],opened_by_keyboard
            browser('press','Enter')
            assert not value(state_js)['open'], value(state_js)
            click(summary)
            opened=value(state_js)
            assert opened['open'] and opened['actionCount']>=2,opened
            assert value('!!document.querySelector(' + json.dumps(row + ' .btn-setup-action-history') + ')'), 'Opened row menu omitted history action'
            # Change the read-only setup projection outside the renderer, then wait
            # for the actual five-second, force:false dashboard poll. A refresh may
            # replace the page, but it must not discard an action menu the user has
            # deliberately opened.
            poll_start = len(events())
            source = Path(project) / 'AGENTS.md'
            source.write_text(source.read_text() + '\nMENU_POLL_RETENTION_CHECK\n')
            rpc('setup.scan', {'project': project})
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if any(event.get('method') == 'dashboard.get' and event.get('ok')
                       for event in events()[poll_start:]):
                    break
                time.sleep(.08)
            else:
                raise AssertionError('A real background dashboard poll did not occur after opening the menu')
            assert value(state_js)['open'], 'force:false dashboard refresh closed an open action menu'
            click(summary)
            closed=value(state_js)
            assert not closed['open'],closed
            assert count_calls()==0
            browser('screenshot',str(output/'setup-restrained-row-actions.png'))
        check('setup-secondary-actions-menu-keyboard-and-dismissal',setup_action_menu)

        workflow=rpc('workflows.save',{'project':project,'title':'UI reviewed workflow','enabled':False,'trigger':'manual',
                    'steps':[{'tool':'git.status','arguments':{}}]})
        clone_id=None
        def inspect(identifier):
            page('workflows')
            click('[data-wftab="list"]')
            wait('!!document.querySelector('+json.dumps('.btn-wf-inspect[data-id="'+identifier+'"]')+')','Workflow row absent')
            click('.btn-wf-inspect[data-id="'+identifier+'"]')
            wait("!!document.querySelector('#btn-inspect-clone')",'Inspection did not return current Markdown')
        def stale_and_clone():
            nonlocal clone_id
            inspect(workflow['id'])
            updated=dict(workflow,title='UI concurrent source revision'); updated.pop('assetPath',None)
            rpc('workflows.save',updated)
            before=len(events()); click('#btn-inspect-toggle-enabled')
            wait("!document.querySelector('#wf-inspect-msg').classList.contains('hidden')",'Stale review did not report conflict')
            current=rpc('workflows.get',{'project':project,'id':workflow['id']})
            assert current['definition']['enabled'] is False
            mutations=[e for e in events()[before:] if e['method']=='workflows.setEnabled']
            assert len(mutations)==1 and not mutations[0]['ok'], 'UI retried with a fresh hash'
            inspect(workflow['id'])
            browser('dialog','accept','UI cloned workflow'); open_action_menu('#btn-inspect-clone'); click('#btn-inspect-clone')
            wait("document.querySelector('#modal-container').classList.contains('hidden')",'Clone did not settle')
            clone=next(w for w in rpc('workflows.list',{'project':project}) if w['title']=='UI cloned workflow')
            clone_id=clone['id']
            assert clone_id!=workflow['id'] and clone['enabled'] is False
            assert clone['clonedFrom']['workflowId']==workflow['id']
        check('workflow-stale-review-rejected-and-explicit-clone',stale_and_clone)

        def archive_restore():
            assert clone_id, 'Clone prerequisite failed'
            inspect(clone_id)
            browser('dialog','accept'); open_action_menu('#btn-inspect-archive'); click('#btn-inspect-archive')
            wait("document.querySelector('#modal-container').classList.contains('hidden')",'Archive did not settle')
            assert clone_id not in [w['id'] for w in rpc('workflows.list',{'project':project})]
            click('#chk-include-archived')
            wait('!!document.querySelector('+json.dumps('.btn-wf-inspect[data-id="'+clone_id+'"]')+')','Archived workflow is not reachable')
            click('.btn-wf-inspect[data-id="'+clone_id+'"]')
            wait("!!document.querySelector('#btn-inspect-restore')",'Restore action absent')
            click('#btn-inspect-restore')
            wait("!!document.querySelector('#btn-inspect-archive')",'Restore did not return active definition')
            current=rpc('workflows.get',{'project':project,'id':clone_id})
            assert current['definition']['enabled'] is False and current['definition'].get('state')!='archived'
            browser('press','Escape'); open_action_menu('#btn-validate-workflows'); click('#btn-validate-workflows')
            wait('document.querySelector("#modal-body").textContent.includes('+json.dumps(clone_id)+')','Per-file validation missing')
            assert count_calls()==0 and {a['id'] for a in rpc('inbox.list',{})}==initial_approvals, 'Management unexpectedly executed a task'
        check('workflow-archive-restore-and-readonly-validation',archive_restore)

        def all_archived_reachable():
            browser('press','Escape')
            if value("document.querySelector('#chk-include-archived')?.checked===true"):
                click('#chk-include-archived')
                wait("document.querySelector('#chk-include-archived')?.checked===false",'Archive filter did not reset')
            before_runs={r['id'] for r in rpc('runs.list',{'project':project})}
            for approval in rpc('inbox.list',{}):
                if approval.get('project')==project:
                    rpc('approvals.decide',{'id':approval['id'],'decision':'reject','snapshotHash':approval['snapshotHash']})
            for row in rpc('workflows.list',{'project':project}):
                detail=rpc('workflows.get',{'project':project,'id':row['id']})
                rpc('workflows.remove',{'project':project,'id':row['id'],'snapshotHash':detail['snapshotHash']})
            assert not rpc('workflows.list',{'project':project})
            page('workflows'); click('[data-wftab="list"]')
            wait("document.querySelectorAll('.btn-wf-inspect').length===0",'Archived workflows remained in the active list')
            assert value("!!document.querySelector('#chk-include-archived')"), 'Empty active list hides the only archive entry point'
            click('#chk-include-archived')
            selector='.btn-wf-inspect[data-id="'+workflow['id']+'"]'
            wait('!!document.querySelector('+json.dumps(selector)+')','Archived workflow was not reachable from empty state')
            click(selector)
            wait("!!document.querySelector('#btn-inspect-restore')",'Archived workflow could not be inspected')
            click('#btn-inspect-restore')
            wait("!!document.querySelector('#btn-inspect-archive')",'Restore did not finish')
            restored=rpc('workflows.get',{'project':project,'id':workflow['id']})['definition']
            assert restored.get('state')!='archived' and restored['enabled'] is False
            assert {r['id'] for r in rpc('runs.list',{'project':project})}==before_runs
            browser('screenshot',str(output/'workflow-restore-from-empty-list.png'))
        check('workflow-empty-active-list-can-find-and-restore-archive',all_archived_reachable)

        rpc('library.add',{'project':project,'title':'UI public Harbor release','content':'A Harbor release requires passing the focused parser tests.','private':False})
        rpc('library.add',{'project':project,'title':'UI private Harbor release','content':'UI_PRIVATE_SENTINEL Harbor must never be injected.','private':True})
        ask_id=None
        def fill_ask(query):
            page('memory'); click('#btn-knowledge-ask')
            wait("!!document.querySelector('#ask-question-input')",'Ask form absent')
            browser('fill','#ask-question-input','What does Harbor require before release?')
            browser('fill','#ask-search-input',query)
            browser('fill','#ask-exec-input',str(provider)); browser('fill','#ask-model-input','synthetic-ui')
            click('#btn-submit-ask')
        def ask_no_sources():
            fill_ask('zzznomatch923754')
            wait("!!document.querySelector('#btn-view-no-src')",'No-source result absent')
            assert count_calls()==0
            rows=rpc('ask.list',{'project':project})
            assert any(row['state']=='no_sources' for row in rows)
        check('ask-empty-retrieval-never-starts-provider',ask_no_sources)

        def ask_answer():
            nonlocal ask_id
            fill_ask('Harbor')
            wait("!!document.querySelector('#btn-approve-ask')",'Pending Ask approval absent')
            ask=next(row for row in rpc('ask.list',{'project':project}) if row['state']=='pending_approval')
            ask_id=ask['id']
            assert count_calls()==0 and 'UI_PRIVATE_SENTINEL' not in modal_text()
            click('#btn-approve-ask')
            wait("!!document.querySelector('#btn-view-citations')",'Answer/citations did not render after actual provider process',20)
            assert count_calls()==1
            done=rpc('ask.get',{'project':project,'id':ask_id})
            assert done['state']=='answered' and done['completedModelCalls']==1
            assert 'Harbor releases require the focused parser tests.' in modal_text()
            click('#btn-view-citations')
            wait("!!document.querySelector('#btn-back-to-ask-detail')",'Citation view absent')
            assert 'A Harbor release requires passing the focused parser tests.' in modal_text()
            assert 'UI_PRIVATE_SENTINEL' not in modal_text()
            browser('screenshot',str(output/'ask-real-helper-citations.png'))
        check('ask-explicit-approval-actual-answer-and-exact-citations',ask_answer)

        def ask_followup_cancel():
            assert ask_id, 'Ask prerequisite failed'
            click('#btn-back-to-ask-detail'); wait("!!document.querySelector('#btn-followup-ask')",'Followup unavailable')
            click('#btn-followup-ask'); browser('fill','#ask-followup-input','Harbor')
            click('#btn-submit-followup'); wait("!!document.querySelector('#btn-cancel-ask')",'Followup did not require a new approval')
            assert count_calls()==1
            follow=next(row for row in rpc('ask.list',{'project':project}) if row['state']=='pending_approval')
            assert follow['id']!=ask_id and follow['round']==2
            browser('dialog','accept'); click('#btn-cancel-ask')
            wait("!document.querySelector('#btn-cancel-ask') && !!document.querySelector('#btn-close-ask-detail')",'Cancellation did not settle')
            assert rpc('ask.get',{'project':project,'id':follow['id']})['state']=='rejected'
            assert count_calls()==1
        check('ask-followup-new-approval-and-cancel-without-call',ask_followup_cancel)

        def loop_cancel():
            page('agents'); click('[data-agentstab="loops"]'); click('#btn-plan-loop')
            wait("!!document.querySelector('#loop-prompt-input')",'Loop capability form absent')
            browser('fill','#loop-prompt-input','Inspect only the selected Git status.')
            browser('fill','#loop-exec-input',str(provider)); browser('fill','#loop-model-input','synthetic-ui')
            for tool in value("Array.from(document.querySelectorAll('.loop-tool-chk:checked')).map(x=>x.value)"):
                if tool!='git.status': click('.loop-tool-chk[value="'+tool+'"]')
            if not value("document.querySelector('.loop-tool-chk[value=\"git.status\"]').checked"):
                click('.loop-tool-chk[value="git.status"]')
            before=count_calls(); click('#btn-submit-plan-loop')
            wait("!!document.querySelector('#btn-done-plan-loop')",'Loop plan failed to freeze')
            assert count_calls()==before
            loop=rpc('loops.list',{'project':project})[0]
            assert loop['state']=='pending_approval'
            click('#btn-done-plan-loop'); click('.btn-view-loop[data-id="'+loop['id']+'"]')
            wait("!!document.querySelector('#btn-cancel-loop')",'Loop cancel absent')
            browser('dialog','accept'); click('#btn-cancel-loop')
            wait("!document.querySelector('#btn-cancel-loop')",'Loop cancel did not settle')
            assert rpc('loops.get',{'project':project,'id':loop['id']})['state']=='rejected'
            assert count_calls()==before
        check('loop-reviewed-capabilities-and-cancel-before-execution',loop_cancel)

        evidence['providerCalls']=count_calls()
        evidence['sourceAfter']=hashes(); evidence['sourceUnchanged']=evidence['sourceBefore']==evidence['sourceAfter']
        evidence['completeSuite']=len(results)==11 and all(row['passed'] for row in results) and evidence['sourceUnchanged']
        (output/'results.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n')
        (output/'rpc.jsonl').write_text((base/'harness-rpc.jsonl').read_text())
        if not evidence['completeSuite']: raise SystemExit(1)
    finally:
        if driver:
            try: browser('close')
            finally:
                if driver.poll() is None: os.killpg(driver.pid,signal.SIGTERM); driver.wait(timeout=5)
        server.terminate(); server.wait(timeout=10)

if __name__=='__main__': main()
