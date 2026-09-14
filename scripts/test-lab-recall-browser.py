#!/usr/bin/env python3
"""Fixture-only browser consumer for the Lab Recall contract; it never executes an approval."""
import argparse, hashlib, importlib.util, json, os, select, shutil, signal, subprocess, time, traceback, urllib.request
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
FILES=('app.js','i18n.js','app.css','index.html','app-icon.svg','demo.js')
HARNESS=('test-ui-server.py','create-ui-fixture.py','test-ui-browser.py')
CHECKS=('baseline-strict-off','candidate-lexical-preview','validation-scope-locales')
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
 p=argparse.ArgumentParser(description=__doc__); p.add_argument('--ui-directory',type=Path,required=True); p.add_argument('--binary',type=Path,required=True); p.add_argument('--fixture',type=Path,required=True); p.add_argument('--output',type=Path,required=True); p.add_argument('--browser-executable',type=Path,required=True); p.add_argument('--checks'); a=p.parse_args()
 selected=set(a.checks.split(',')) if a.checks else set(CHECKS)
 if not selected or not selected<=set(CHECKS): p.error('unknown or empty --checks')
 ui,binary=a.ui_directory.resolve(strict=True),a.binary.resolve(strict=True); base,out=a.fixture.absolute(),a.output.absolute()
 if base.exists() or base.is_symlink() or base.parent!=(ROOT/'.task-tmp').resolve(): p.error('fixture must be a new immediate .task-tmp child')
 if out.exists() or out.is_symlink() or out.parent.resolve()!=(ROOT/'output/playwright').resolve(): p.error('output must be a new output/playwright child')
 if not shutil.which('node') or not shutil.which('npx') or not a.browser_executable.is_file(): p.error('Node/npx and browser executable required')
 if any(not(ui/n).is_file() or (ui/n).is_symlink() for n in FILES): p.error('ordinary frozen UI files required')
 out.mkdir(parents=True); (out/'consumer-test-source.py').write_bytes(Path(__file__).read_bytes())
 ev={'format':'vela-lab-recall-renderer-v2','status':'failed','synthetic':True,'providerRuns':0,'modelRuns':0,'workflowExecuted':False,'nativeClaimed':False,'completeSuite':False,'selectedChecks':sorted(selected),'checks':[]}; server=driver=None; top_error=None
 def save(): (out/'results.json').write_text(json.dumps(ev,ensure_ascii=False,indent=2)+'\n')
 def b(*x):
  driver.stdin.write(json.dumps(x)+'\n'); driver.stdin.flush(); assert select.select([driver.stdout],[],[],20)[0],'browser timeout'; z=json.loads(driver.stdout.readline()); assert 'error' not in z,z; return z.get('output','')
 def v(x): return json.loads(b('eval',x))
 def wait(x,msg,seconds=10):
  end=time.monotonic()+seconds
  while time.monotonic()<end:
   if v(x): return
   time.sleep(.08)
  raise AssertionError(msg)
 def click(x): b('click',x); b('snapshot','-i')
 def rpc(m,x,allow_error=False):
  q=urllib.request.Request(url+'__rpc',json.dumps({'method':m,'params':x}).encode(),{'Content-Type':'application/json','Origin':'http://'+url.split('/')[2]})
  try:
   with urllib.request.urlopen(q,timeout=25) as r: z=json.load(r)
  except urllib.error.HTTPError as e: z=json.loads(e.read())
  if 'error' in z:
   if allow_error: return str(z['error'])
   raise RuntimeError(z['error'])
  if allow_error: raise AssertionError(m+' unexpectedly accepted')
  return z['result']
 def calls(m): return v('window.__lrCalls.filter(x=>x.method==='+json.dumps(m)+')')
 def check(n,fn):
  if n not in selected: return
  try: ev['checks'].append({'check':n,'passed':True,**(fn() or {})})
  except Exception as e: ev['checks'].append({'check':n,'passed':False,'error':str(e),'traceback':traceback.format_exc(limit=6)})
  finally:
   try:
    v('window.__lrHold=null;if(window.__lrHeld)window.__lrRelease();true'); b('press','Escape'); b('press','Escape')
   except Exception: pass
  ev['checks'][-1]['pageErrors']=v('window.__lrErrors||[]'); b('screenshot',str(out/(n+'.png'))); (out/(n+'.txt')).write_text(b('snapshot','-i')); print(json.dumps(ev['checks'][-1],ensure_ascii=False),flush=True); save()
 try:
  ev['uiBefore']={n:sha(ui/n) for n in FILES}; ev['helperBefore']=sha(binary); ev['harnessBefore']={n:sha(ROOT/'scripts'/n) for n in HARNESS}
  made=subprocess.run(['python3',str(ROOT/'scripts/create-ui-fixture.py'),str(base),'--binary',str(binary),'--with-routing-project'],cwd=ROOT,text=True,capture_output=True,timeout=120); (out/'fixture-creation.log').write_text(made.stdout+made.stderr); made.check_returncode(); fx=json.loads((base/'fixture.json').read_text()); project,beacon=fx['project'],fx['routingProject']
  (base/'synthetic-lab-recall-agent.py').write_text('#!/usr/bin/env python3\n'); (base/'synthetic-lab-recall-agent.py').chmod(0o700)
  # Lab accepts verification inputs only when they are committed.  Make this
  # fixture fact true instead of weakening the bridge's verifier guard.
  verifier=Path(project)/'verify.py'; verifier.write_text('assert True\n')
  git_env=os.environ.copy(); git_env.update({'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':os.devnull})
  for cmd in (['/usr/bin/git','-C',str(project),'-c','core.hooksPath=/dev/null','add','verify.py'],['/usr/bin/git','-C',str(project),'-c','core.hooksPath=/dev/null','-c','user.name=Vela Fixture','-c','user.email=fixture@invalid','commit','-m','Add synthetic Lab verifier']):
   committed=subprocess.run(cmd,text=True,capture_output=True,env=git_env,timeout=20); assert committed.returncode==0,committed.stderr or committed.stdout
  verifier_commit=subprocess.run(['/usr/bin/git','-C',str(project),'rev-parse','HEAD'],text=True,capture_output=True,env=git_env,timeout=20); verifier_commit.check_returncode(); ev['fixtureVerifierCommit']=verifier_commit.stdout.strip()
  snap,helper=base/'ui-snapshot',base/'vela-frozen'; snap.mkdir()
  for n in FILES: shutil.copyfile(ui/n,snap/n)
  shutil.copy2(binary,helper); ev['uiFixture']={n:sha(snap/n) for n in FILES}; ev['helperFixture']=sha(helper); assert ev['uiBefore']==ev['uiFixture'] and ev['helperBefore']==ev['helperFixture']
  def core(m,x):
   r=subprocess.run([str(helper),'call',m,json.dumps(x),'--home',fx['home']],cwd=Path(project),text=True,capture_output=True,timeout=25); assert r.returncode==0,(m,r.stderr or r.stdout); return json.loads(r.stdout)
  for row in ({'id':'lab-recall-active','project':project,'scope':'project','state':'active','title':'Needle','content':'LAB_RECALL_ACTIVE_SENTINEL lexical guidance'},{'id':'lab-recall-private','project':project,'scope':'project','state':'active','private':True,'title':'Private','content':'LAB_RECALL_PRIVATE_SENTINEL'}): core('memory.save',row)
  spec=importlib.util.spec_from_file_location('d',ROOT/'scripts/test-ui-browser.py'); mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
  src=mod.PLAYWRIGHT_DRIVER.replace("const page=await browser.newPage({viewport:{width:1280,height:720}});page.setDefaultTimeout(5000);","const page=await browser.newPage({viewport:{width:1280,height:720}});await page.addInitScript(()=>{window.__lrErrors=[];addEventListener('error',e=>window.__lrErrors.push(e.message));addEventListener('unhandledrejection',e=>window.__lrErrors.push(String(e.reason)))});page.setDefaultTimeout(5000);")
  server=subprocess.Popen(['python3',str(ROOT/'scripts/test-ui-server.py'),str(base/'fixture.json'),'--binary',str(helper),'--ui-directory',str(snap)],cwd=ROOT,stdout=subprocess.PIPE,text=True,start_new_session=True); assert select.select([server.stdout],[],[],15)[0],'server start'; url=json.loads(server.stdout.readline())['url']; pw=ROOT/'.task-tmp/ui-browser-tools/node_modules/playwright/index.js'; assert pw.is_file(),'pinned Playwright missing'; driver=subprocess.Popen(['node','-e',src,str(pw),str(a.browser_executable)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,start_new_session=True); b('open',url); b('wait','#project-selector'); b('select','#project-selector',project)
  v("""window.__lrCalls=[];window.__lrStarted=[];window.__lrOriginal=window.vela.call;window.vela.call=async(m,x={})=>{window.__lrStarted.push({method:m,params:x});if(window.__lrHold===m){window.__lrHeld=true;await new Promise(ok=>window.__lrRelease=ok);window.__lrHeld=false}try{let r=await window.__lrOriginal(m,x);window.__lrCalls.push({method:m,params:x,result:r});return r}catch(e){window.__lrCalls.push({method:m,params:x,error:String(e)});throw e}};window.__lrVisible=s=>{let e=document.querySelector(s);return!!e&&e.getClientRects().length>0};true""")
  def form(target=project, title='Synthetic Recall fixture'):
   click('.nav-link[data-page="lab"]'); wait('document.querySelector(".nav-link.active")?.dataset.page==="lab"','Lab unavailable'); click('#btn-new-lab'); wait('!!document.querySelector("#lab-baseline-recall-mode")','missingUI: Lab form lacks #lab-baseline-recall-mode'); wait('!!document.querySelector(".mode-switch-btn[data-target-mode=\\"codex_agent\\"]")','missingUI: Lab agent form unavailable'); click('.mode-switch-btn[data-target-mode="codex_agent"]')
   for sel in ('#lab-agent-title','#lab-agent-project','#lab-agent-kind','#lab-agent-model','#lab-agent-effort','#lab-agent-task','#lab-agent-executable','#lab-agent-verify-cmd','#lab-agent-verify-files','#lab-agent-output-files','#lab-agent-timeout','#lab-agent-repetitions'): wait('!!document.querySelector('+json.dumps(sel)+')','missingUI: fixture-safe Lab field '+sel)
   b('click','#lab-section-agent details summary'); wait('window.__lrVisible("#lab-agent-executable")&&window.__lrVisible("#lab-agent-verify-cmd")&&window.__lrVisible("#lab-agent-baseline-json")&&window.__lrVisible("#lab-agent-candidate-json")','missingUI: advanced Agent details did not open')
   b('fill','#lab-agent-title',title); b('select','#lab-agent-project',target); b('select','#lab-agent-kind','memory'); b('fill','#lab-agent-model','fixed-local-jsonl'); b('select','#lab-agent-effort','high'); b('fill','#lab-agent-task','Record frozen recall only.'); b('fill','#lab-agent-executable',str(base/'synthetic-lab-recall-agent.py')); b('fill','#lab-agent-verify-cmd','["/usr/bin/python3","verify.py"]'); b('fill','#lab-agent-verify-files','verify.py'); b('fill','#lab-agent-output-files','observed-context.txt'); b('fill','#lab-agent-timeout','20'); b('fill','#lab-agent-repetitions','1'); b('fill','#lab-agent-baseline-json','{"files":[]}'); b('fill','#lab-agent-candidate-json','{"files":[]}')
  def submit(before):
   click('#btn-save-lab'); wait('window.__lrCalls.filter(x=>x.method==="lab.run").length>'+str(before),'Lab submit did not call actual bridge'); row=calls('lab.run')[-1]; assert not row.get('error'),'Lab submit rejected: '+row.get('error',''); return row
  def pending(row):
   result=row['result']; eid=result.get('id'); assert eid and result.get('state')=='pending_approval','Lab Recall must remain a pending approval'; inbox=rpc('inbox.list',{'project':project}); assert any(x.get('runId')==eid and x.get('tool')=='lab.execute' for x in inbox),'Lab Recall did not create its frozen approval'; assert not calls('approvals.decide'),'consumer approved or executed Lab'; return result
  def strict():
   form(); before=len(calls('lab.run')); b('select','#lab-baseline-recall-mode','strict_off'); assert not v('window.__lrVisible("#lab-baseline-recall-query")'),'strict OFF exposed Recall ON inputs'; b('select','#lab-candidate-recall-mode','not_configured'); row=submit(before); params=row['params']; assert params['baseline'].get('recall')=={'enabled':False,'strictOff':True},'strict OFF payload changed'; assert 'recall' not in params['candidate'],'not_configured did not preserve legacy variant'; result=pending(row); assert result['baseline']['recall']['strictOff'] is True and result['baseline']['recall']['items']==[] and result['candidate']['recall']['selection']=='not_requested','Core frozen strict/not-configured receipt incorrect'; return {'strictOffSubmitted':True,'notConfiguredCompatible':True,'pendingOnly':True}
  def lexical():
   form(); before=len(calls('lab.run')); b('select','#lab-baseline-recall-mode','not_configured'); b('select','#lab-candidate-recall-mode','on'); wait('window.__lrVisible("#lab-candidate-recall-query")&&window.__lrVisible("#lab-candidate-retrieval-mode")&&window.__lrVisible("#lab-candidate-recall-budget")','missingUI: candidate Recall ON fields absent'); b('fill','#lab-candidate-recall-query','lexical guidance'); b('select','#lab-candidate-retrieval-mode','lexical'); b('fill','#lab-candidate-recall-budget','500'); b('screenshot',str(out/'lab-recall-form-open.png')); row=submit(before); recall=row['params']['candidate'].get('recall') or {}; assert set(recall)=={'enabled','query','mode','scope','budget'} and 'strictOff' not in recall and recall.get('enabled') is True and recall.get('query')=='lexical guidance' and recall.get('mode')=='lexical' and recall.get('scope')=='project' and recall.get('budget')==500,'Recall ON payload includes an OFF-only field or differs from entered values'; result=pending(row); frozen=result['candidate']['recall']; ids=[x.get('id') for x in frozen.get('items',[])]; assert frozen.get('enabled') is True and frozen.get('requestedRetrievalMode')=='lexical' and frozen.get('retrievalMode')=='lexical' and frozen.get('status')=='ok' and frozen.get('indexIncomplete') is False and 'lab-recall-active' in ids and 'lab-recall-private' not in ids,'actual lexical Recall did not freeze only eligible Core selection'; assert result['candidate'].get('memoryInjection')=='recall' and result['candidate'].get('finalContextHash'),'frozen Recall context receipt absent'; return {'actualLexicalRecallFrozenPreview':True,'onPayloadExcludesStrictOff':True,'selectedIDs':ids,'providerRuns':0}
  def guards():
   # A draft is modal- and project-scoped: cancelling A before opening B cannot
   # carry an A Recall query, mode or budget into B.
   form(project,'A draft must not leak'); b('select','#lab-candidate-recall-mode','on'); wait('window.__lrVisible("#lab-candidate-recall-query")','candidate ON control absent'); b('fill','#lab-candidate-recall-query','A_ONLY_RECALL_QUERY'); b('select','#lab-candidate-retrieval-mode','semantic'); b('fill','#lab-candidate-recall-budget','777'); b('press','Escape'); wait('!window.__lrVisible("#lab-candidate-recall-mode")','Escape did not close A Lab modal'); b('select','#project-selector',beacon); wait('document.querySelector("#project-selector").value==='+json.dumps(beacon),'project did not switch to B'); form(beacon,'B isolated draft'); b('select','#lab-candidate-recall-mode','on'); wait('window.__lrVisible("#lab-candidate-recall-query")','B candidate ON control absent'); assert v('document.querySelector("#lab-candidate-recall-query")?.value===""&&document.querySelector("#lab-candidate-retrieval-mode")?.value==="hybrid"&&document.querySelector("#lab-candidate-recall-budget")?.value==="2000"'),'A Recall draft leaked into B form'; b('press','Escape'); b('select','#project-selector',project); wait('document.querySelector("#project-selector").value==='+json.dumps(project),'project did not return to A'); form()
   b('select','#lab-candidate-recall-mode','on'); wait('window.__lrVisible("#lab-candidate-recall-query")','candidate ON control absent'); b('fill','#lab-candidate-recall-query','lexical guidance'); b('select','#lab-candidate-retrieval-mode','lexical'); b('fill','#lab-candidate-recall-budget','500'); before=len(calls('lab.run')); v('(()=>{const e=document.querySelector("#lab-candidate-recall-mode");e.add(new Option("unknown","unknown_mode"));e.value="unknown_mode";e.dispatchEvent(new Event("change",{bubbles:true}));return e.value})()'); assert v('document.querySelector("#lab-candidate-recall-mode")?.value==="unknown_mode"'),'unknown Recall mode fixture did not settle'; click('#btn-save-lab'); time.sleep(.25); assert len(calls('lab.run'))==before,'unknown Recall mode reached bridge'; b('press','Escape'); form(); b('select','#lab-candidate-recall-mode','on'); wait('window.__lrVisible("#lab-candidate-recall-query")','candidate ON control absent after invalid mode'); b('fill','#lab-candidate-recall-query','lexical guidance'); b('select','#lab-candidate-retrieval-mode','lexical'); b('fill','#lab-candidate-recall-budget','0'); before=len(calls('lab.run')); click('#btn-save-lab'); time.sleep(.25); assert len(calls('lab.run'))==before and v('window.__lrVisible("#lab-candidate-recall-budget")'),'invalid budget left the form through bridge acceptance'
   b('fill','#lab-candidate-recall-budget','500')
   for loc in ('en','zh-CN'):
    v('VelaI18n.setLocale('+json.dumps(loc)+');document.dispatchEvent(new Event("vela:locale"));true'); assert v('document.querySelector("label[for=\\"lab-candidate-recall-mode\\"]")?.textContent.trim().length>0'),'missing localized Recall label: '+loc; assert v('document.querySelector("#lab-candidate-recall-mode")?.value==="on"&&document.querySelector("#lab-candidate-recall-query")?.value==="lexical guidance"'),'locale change discarded Recall draft'
   def modal_state():
    return v('(()=>{const b=document.querySelector("#btn-save-lab"),m=b?.closest(".modal-content");return {visible:window.__lrVisible("#btn-save-lab"),sameButton:window.__lrHeldLabButton===b,title:document.querySelector("#lab-agent-title")?.value,formProject:document.querySelector("#lab-agent-project")?.value,query:document.querySelector("#lab-candidate-recall-query")?.value,mode:document.querySelector("#lab-candidate-retrieval-mode")?.value,text:m?.innerText?.slice(0,500),review:window.__lrVisible("#lab-recall-frozen-review"),selected:document.querySelector("#project-selector")?.value,page:document.querySelector(".nav-link.active")?.dataset?.page}})()')
   before=len(calls('lab.run')); starts=len(v('window.__lrStarted.filter(x=>x.method==="lab.run")')); v('window.__lrHold="lab.run";true'); click('#btn-save-lab'); wait('window.__lrHeld===true','Lab pending call was not held'); v('window.__lrHeldLabButton=document.querySelector("#btn-save-lab");true'); at_hold=modal_state(); v('(()=>{const x=document.querySelector("#btn-save-lab");if(x&&!x.disabled)x.click();return true})()'); assert len(v('window.__lrStarted.filter(x=>x.method==="lab.run")'))==starts+1,'pending Lab double-click started a second request'; assert at_hold['visible'],'held submit unexpectedly closed the A modal before scope switch'; b('select','#project-selector',beacon); wait('document.querySelector("#project-selector").value==='+json.dumps(beacon),'sidebar project switch did not take effect with A modal open'); before_release=modal_state(); v('window.__lrRelease();true'); wait('window.__lrHeld===false','held Lab response did not release'); wait('window.__lrCalls.filter(x=>x.method==="lab.run").length>'+str(before),'released Lab request did not settle'); after_release=modal_state(); assert after_release['sameButton'] and after_release['review'] is False and after_release['selected']==beacon and after_release['page']=='lab' and after_release['title']==at_hold['title'] and after_release['formProject']==at_hold['formProject'] and after_release['query']==at_hold['query'] and after_release['mode']==at_hold['mode'],'late response replaced the held A form, opened review, navigated, or changed B scope: '+json.dumps({'atHold':at_hold,'beforeRelease':before_release,'afterRelease':after_release}); assert v('document.querySelector("#btn-save-lab")?.disabled===true'),'stale A modal remained actionable after switching to B'; assert not before_release['visible'],'project switch leaves the old A Lab modal visible before its delayed result returns (the delayed result itself was discarded): '+json.dumps({'atHold':at_hold,'beforeRelease':before_release,'afterRelease':after_release}); return {'invalidBudgetRejected':True,'unknownModeRejectedBeforeBridge':True,'aDraftDidNotLeakToB':True,'localizedDrafts':['en','zh-CN'],'pendingDoubleClickCoalesced':True,'lateResponseDidNotReopenOrNavigate':True,'staleState':{'atHold':at_hold,'beforeRelease':before_release,'afterRelease':after_release}}
  check('baseline-strict-off',strict); check('candidate-lexical-preview',lexical); check('validation-scope-locales',guards)
  ev['uiAfter']={n:sha(ui/n) for n in FILES}; ev['helperAfter']=sha(binary); ev['harnessAfter']={n:sha(ROOT/'scripts'/n) for n in HARNESS}; ev['sourceUnchanged']=ev['uiBefore']==ev['uiFixture']==ev['uiAfter'] and ev['helperBefore']==ev['helperFixture']==ev['helperAfter'] and ev['harnessBefore']==ev['harnessAfter']; ev['selectedChecksPassed']=len(ev['checks'])==len(selected) and all(x['passed'] for x in ev['checks']); ev['completeSuite']=set(selected)==set(CHECKS) and ev['selectedChecksPassed'] and ev['sourceUnchanged'] and not any(x.get('pageErrors') for x in ev['checks']); ev['status']='passed' if ev['completeSuite'] else 'failed'
 except Exception as e:
  top_error=type(e).__name__+': '+str(e); ev['failure']=top_error; ev['status']='failed'
 finally:
  try:
   if driver: b('close'); driver.wait(timeout=8)
  except Exception:
   if driver and driver.poll() is None: os.killpg(driver.pid,signal.SIGKILL); driver.wait()
  if server:
   if server.poll() is None: server.send_signal(signal.SIGTERM)
   try: server.wait(timeout=8)
   except subprocess.TimeoutExpired: os.killpg(server.pid,signal.SIGKILL); server.wait()
   ev['serverStopped']=server.poll() is not None
  for n in ('harness-rpc.jsonl','fixture.json'):
   if base.exists() and (base/n).is_file() and not (base/n).is_symlink(): shutil.copyfile(base/n,out/n); ev.setdefault('retainedEvidenceSHA256',{})[n]=sha(out/n)
  if base.exists() and not base.is_symlink(): shutil.rmtree(base)
  ev['fixtureRemoved']=not base.exists(); save()
 if top_error or ev['status']!='passed': raise SystemExit(1)
if __name__=='__main__': main()
