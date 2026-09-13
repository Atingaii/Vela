"""New capability UI checks against a frozen UI copy and a real isolated helper.

Create a NEW create-ui-fixture.py fixture, copy UI resources to its ui-snapshot
and a built helper to vela-frozen, then run this script with --fixture/--output.
No models, credentials, remote tools or launchd lifecycle actions execute.
Delayed archive/index responses retain their real CLI data; only delivery timing
is controlled to exercise user selection/cancellation races. Keep failed evidence.
"""
import argparse, hashlib, importlib.util, json, os
from pathlib import Path
import select, signal, subprocess, time, traceback, urllib.request

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
    server = subprocess.Popen(['python3',str(ROOT/'scripts/test-ui-server.py'),str(base/'fixture.json'),'--binary',str(binary),'--ui-directory',str(ui)],stdout=subprocess.PIPE,text=True)
    driver = None; results=[]
    def hashes():
        return {name:hashlib.sha256((ui/name).read_bytes()).hexdigest() for name in ('app.js','i18n.js','app.css','index.html')}
    evidence={'format':'vela-parity-renderer-v1','synthetic':True,'sourceBefore':hashes(),'helperSHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),
              'realProviderExecuted':False,'nativeDialogsTested':False,'checks':results,'completeSuite':False}
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
        browser('select','#project-selector',project)
        wait('document.querySelector("#project-selector").value==='+json.dumps(project),'Explicit fixture project was not selected')
        browser('snapshot','-i')
        def optional_reads():
            before=len(events())
            page('settings'); wait('!!document.querySelector("#setting-locale")','Settings absent')
            page('usage'); wait('!!document.querySelector("#codex-cli-path-input")','Quota entry absent')
            page('improve'); click('#btn-model-improve-plans')
            wait('!document.querySelector("#modal-container").classList.contains("hidden")','Plans dialog absent')
            calls=events()[before:]
            forbidden=[row['method'] for row in calls if row['method'] in ('usage.quota.read','connectors.configure','connectors.tools.search','daemon.start','improve.model.plan')]
            assert not forbidden, 'Opening views performed explicit-only actions: '+str(forbidden)
            assert any(row['method']=='usage.quota.status' and row['ok'] for row in calls), 'Actual quota status was not read'
            assert any(row['method']=='daemon.status' and row['ok'] for row in calls), 'Actual daemon status was not read'
        check('opening-views-does-not-connect-execute-or-enable',optional_reads)

        memory_a=rpc('memory.save',{'project':project,'title':'Archive selection A','content':'Synthetic archive first source','state':'candidate','scope':'project','type':'fact'})
        memory_b=rpc('memory.save',{'project':project,'title':'Archive selection B','content':'Synthetic archive second source','state':'candidate','scope':'project','type':'fact'})
        for label,item in [('A',memory_a),('B',memory_b)]:
            (base/('archive-'+label+'.json')).write_text(json.dumps(rpc('memory.archive.export',{'project':project,'ids':[item['id']]})['archive']))
        def archive_race():
            page('memory'); click('#btn-import-memory-archive')
            browser('wait','#memory-archive-file-input')
            value("window.__velaUITest.nextRead={method:'memory.archive.validate',delay:1500}; true")
            browser('files','#memory-archive-file-input',str(base/'archive-A.json'))
            wait("window.__velaUITest.nextRead===null",'First archive validation did not start')
            browser('files','#memory-archive-file-input',str(base/'archive-B.json'))
            wait("!document.querySelector('#btn-confirm-import').disabled && document.querySelector('#import-archive-preview-area').textContent.includes('Archive selection B')",'Current file did not validate')
            time.sleep(1.7)
            preview=value("document.querySelector('#import-archive-preview-area').textContent")
            assert 'Archive selection B' in preview and 'Archive selection A' not in preview, 'A late response replaced the user-selected archive preview'
            before={m['id'] for m in rpc('memory.list',{'project':project})}
            click('#btn-confirm-import')
            wait("document.querySelector('#modal-container').classList.contains('hidden')",'Import did not finish')
            created=[m for m in rpc('memory.list',{'project':project}) if m['id'] not in before]
            assert len(created)==1 and created[0]['title']=='Archive selection B' and created[0]['state'].lower()=='candidate',created
        check('archive-selection-race-and-candidate-import',archive_race)

        def archive_english():
            page('settings'); browser('select','#setting-locale','en')
            wait("window.VelaI18n.getLocale()==='en'",'English did not persist')
            page('memory'); click('#btn-import-memory-archive')
            browser('files','#memory-archive-file-input',str(base/'archive-B.json'))
            wait("!document.querySelector('#btn-confirm-import').disabled",'Archive did not validate')
            text=value("document.querySelector('#import-archive-preview-area').textContent")
            assert not any(term in text for term in ['类别分布','条目预览','来源项目','目标项目']), 'Fixed Chinese text leaked into English archive controls'
        check('archive-preview-fixed-text-in-english',archive_english)

        semantic=rpc('memory.save',{'project':project,'title':'Synthetic vehicle maintenance','content':'The automobile needs repair and regular maintenance.','state':'active','scope':'project','type':'fact'})
        def semantic_roundtrip():
            page('memory'); click('#btn-semantic-memory')
            wait("!!document.querySelector('#semantic-status-area code')",'Installed model status did not render')
            before=len(events()); click('#btn-start-semantic-index')
            wait("document.querySelector('#btn-start-semantic-index').style.display!=='none'",'Index did not settle',20)
            assert any(e['method']=='memory.semantic.index' and e['ok'] for e in events()[before:]), 'No actual indexing call'
            status=rpc('memory.semantic.status',{'project':project,'language':'en'})
            assert status['indexed']>0,status
            click('#btn-close-semantic-modal'); click('#btn-recall-tester')
            browser('fill','#recall-query','A car requires servicing')
            browser('select','#recall-project',project); browser('select','#recall-mode','semantic'); browser('select','#recall-language','en')
            click('#btn-do-recall')
            wait("document.querySelector('#recall-results-area').textContent.includes('Synthetic vehicle maintenance')",'Semantic result did not contain the real indexed paraphrase')
        check('local-semantic-index-and-paraphrase-recall',semantic_roundtrip)

        for i in range(12):
            rpc('memory.save',{'project':project,'title':'Cancellation fixture '+str(i),'content':'Vehicle repair procedure '+str(i),'state':'active','scope':'project','type':'fact'})
        def cancel_index():
            page('memory'); click('#btn-semantic-memory')
            wait("!!document.querySelector('#semantic-status-area code')",'Model status absent')
            wait("!document.body.textContent.includes(window.VelaI18n.t('memory.semanticIndexSuccessToast'))",'Earlier completion toast did not expire')
            browser('fill','#semantic-batch-size','1')
            value("window.__velaUITest.nextRead={method:'memory.semantic.index',delay:1200}; true")
            before=len(events()); click('#btn-start-semantic-index')
            wait("window.__velaUITest.nextRead===null",'First index request did not start')
            click('#btn-cancel-semantic-index')
            wait("document.querySelector('#btn-start-semantic-index').style.display!=='none'",'Cancellation did not settle')
            calls=[e for e in events()[before:] if e['method']=='memory.semantic.index']
            assert len(calls)==1, 'Cancellation started another page'
            assert not value("document.body.textContent.includes(window.VelaI18n.t('memory.semanticIndexSuccessToast'))"), 'Cancellation was reported as successful completion'
        check('index-cancellation-keeps-partial-progress-without-success',cancel_index)
        evidence['sourceAfter']=hashes()
        evidence['sourceUnchanged']=evidence['sourceBefore']==evidence['sourceAfter']
        evidence['completeSuite']=len(results)==5 and all(row['passed'] for row in results) and evidence['sourceUnchanged']
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
