"""Browser acceptance for Health timeout proposals using an actual local helper.

The runner creates a new Harbor/Beacon fixture, then creates three real local
shell timeout runs through the frozen helper. It never starts a provider,
network account, arbitrary shell command, or user store. Frozen selector and
bridge contracts are required; diagnostic subsets never report a full suite.
"""
import argparse, hashlib, importlib.util, json, os, select, shutil, signal, sqlite3, subprocess, time, traceback, urllib.request
from pathlib import Path
from release_resources import DEVELOPMENT_UI_RESOURCES, UI_RESOURCES, copy_ui_resources
ROOT=Path(__file__).resolve().parents[1]
UI_FILES=UI_RESOURCES + DEVELOPMENT_UI_RESOURCES
HARNESS_FILES=('test-ui-server.py','create-ui-fixture.py','test-ui-browser.py')
CHECKS=('readonly-preview','proposal-reject','uncertain-accept','recovery-stale-locales')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
 p=argparse.ArgumentParser(description=__doc__); p.add_argument('--ui-directory',type=Path,required=True); p.add_argument('--binary',type=Path,required=True); p.add_argument('--fixture',type=Path,required=True); p.add_argument('--output',type=Path,required=True); p.add_argument('--browser-executable',type=Path,required=True); p.add_argument('--checks'); a=p.parse_args()
 selected=set(a.checks.split(',')) if a.checks else set(CHECKS)
 if not selected or not selected <= set(CHECKS): p.error('unknown or empty --checks')
 base,out=a.fixture.absolute(),a.output.absolute(); ui_source,binary=a.ui_directory.resolve(strict=True),a.binary.resolve(strict=True)
 if base.exists() or base.is_symlink() or base.parent != (ROOT/'.task-tmp').resolve(): p.error('fixture must be a new immediate .task-tmp child')
 if out.exists() or out.is_symlink() or out.parent.resolve() != (ROOT/'output/playwright').resolve(): p.error('output must be a new output/playwright child')
 if not a.browser_executable.is_file() or not shutil.which('node'): p.error('browser executable and Node.js are required')
 if any(not (ui_source/n).is_file() or (ui_source/n).is_symlink() for n in UI_FILES): p.error('missing ordinary frozen UI file')
 out.mkdir(parents=True); (out/'consumer-test-source.py').write_bytes(Path(__file__).read_bytes())
 ev={'format':'vela-workflow-health-proposal-renderer-v1','synthetic':True,'completeSuite':False,'providerRuns':0,'workflowExecuted':True,'nativeClaimed':False,'selectedChecks':sorted(selected),'checks':[]}; server=driver=None
 def save(): (out/'results.json').write_text(json.dumps(ev,ensure_ascii=False,indent=2)+'\n')
 def direct(method,params):
  r=subprocess.run([str(helper),'call',method,json.dumps(params),'--home',str(fixture['home'])],cwd=Path(fixture['project']),env=env,text=True,capture_output=True,timeout=25)
  if r.returncode: raise RuntimeError(method+': '+(r.stderr or r.stdout))
  return json.loads(r.stdout)
 def browser(*args):
  driver.stdin.write(json.dumps(args)+'\n'); driver.stdin.flush(); assert select.select([driver.stdout],[],[],20)[0],'browser driver timeout'; row=json.loads(driver.stdout.readline()); assert 'error' not in row,row; return row.get('output','')
 def value(js): return json.loads(browser('eval',js))
 def wait(js,msg,seconds=10):
  end=time.monotonic()+seconds
  while time.monotonic()<end:
   observed=value(js)
   if observed: return observed
   time.sleep(.08)
  raise AssertionError(msg)
 def click(sel): browser('click',sel); browser('snapshot','-i')
 def bridge(method,params):
  req=urllib.request.Request(url+'__rpc',json.dumps({'method':method,'params':params}).encode(),{'Content-Type':'application/json','Origin':'http://'+url.split('/')[2]})
  try:
   with urllib.request.urlopen(req,timeout=25) as resp: data=json.load(resp)
  except urllib.error.HTTPError as err: data=json.loads(err.read())
  if 'error' in data: raise RuntimeError(data['error'])
  return data['result']
 def bridge_error(method,params):
  try: bridge(method,params)
  except RuntimeError: return True
  raise AssertionError(method+' unexpectedly passed bridge validation')
 def rows(): return direct('workflows.list',{'project':project})
 def runs(): return direct('runs.list',{'project':project})
 def approvals(): return direct('inbox.list',{'project':project})
 def check(name,fn):
  if name not in selected:return
  try: ev['checks'].append({'check':name,'passed':True,**(fn() or {})})
  except Exception as e: ev['checks'].append({'check':name,'passed':False,'error':str(e),'traceback':traceback.format_exc(limit=6)})
  finally:
   try:
    value('window.__healthHold=null;true')
    if value('window.__healthHeld===true'): value('window.__healthRelease();true')
    browser('press','Escape'); browser('press','Escape')
   except Exception: pass
  ev['checks'][-1]['pageErrors']=value('window.__healthErrors||[]'); browser('screenshot',str(out/(name+'.png'))); (out/(name+'.txt')).write_text(browser('snapshot','-i')); print(json.dumps(ev['checks'][-1],ensure_ascii=False),flush=True); save()
 try:
  ev['uiBefore']={n:sha(ui_source/n) for n in UI_FILES}; ev['helperBefore']=sha(binary)
  ev['harnessBefore']={n:sha(ROOT/'scripts'/n) for n in HARNESS_FILES}
  created=subprocess.run(['python3',str(ROOT/'scripts/create-ui-fixture.py'),str(base),'--binary',str(binary),'--with-routing-project'],capture_output=True,text=True,timeout=120); (out/'fixture-creation.log').write_text(created.stdout+created.stderr); created.check_returncode(); fixture=json.loads((base/'fixture.json').read_text()); project=fixture['project']; env=dict(os.environ,VELA_HOME=fixture['home'],VELA_SESSION_ROOT=fixture['sessionRoot'],VELA_DISABLE_DISCOVERY='1',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL=os.devnull)
  snap,helper=base/'ui-snapshot',base/'vela-frozen'; copy_ui_resources(ui_source,snap,allow_development=True)
  shutil.copy2(binary,helper); ev['uiFixture']={n:sha(snap/n) for n in UI_FILES}; ev['helperFixture']=sha(helper); assert ev['uiBefore']==ev['uiFixture'] and ev['helperBefore']==ev['helperFixture']
  # Three actual helper runs: reject, uncertain accept, and recovery. Each runs
  # only the fixture-owned local sleep command after one recorded approval.
  def make_case(name):
   wf=direct('workflows.save',{'id':'health-ui-'+name,'title':'Health UI '+name,'project':project,'enabled':True,'steps':[{'id':'health-ui-'+name+'-step','title':'Bounded synthetic timeout','tool':'shell.test','arguments':{'executable':'/bin/sh','args':['-c','sleep 2'],'timeoutSeconds':1}}]})
   started=direct('workflows.run',{'id':wf['id'],'dryRun':False}); approval=next(x for x in approvals() if x['runId']==started['id']); direct('approvals.decide',{'id':approval['id'],'snapshotHash':approval['snapshotHash'],'decision':'approve'}); run=direct('runs.get',{'id':started['id']}); assert run['state']=='needs_review'; health=direct('workflows.health',{'project':project,'id':wf['id']}); finding=next(x for x in health['findings'] if x['code']=='timeout_observed' and x['runId']==run['id']); assert finding.get('id') and finding.get('stepId'), 'frozen helper lacks Health finding identity contract (id + stepId)'; inspect=direct('workflows.get',{'project':project,'id':wf['id']}); return {'workflow':wf,'run':run,'approval':approval,'finding':finding,'inspect':inspect,'seed':{'project':project,'workflowId':wf['id'],'workflowVersion':wf['version'],'snapshotHash':inspect['snapshotHash'],'runId':run['id'],'stepId':finding['stepId'],'findingId':finding['id'],'newTimeoutSeconds':2}}
  cases={name:make_case(name) for name in ('reject','accept','recovery')}; reject_case,accept_case,recovery_case=cases['reject'],cases['accept'],cases['recovery']; ev['fixtureHealth']={name:{'workflowId':item['workflow']['id'],'runId':item['run']['id'],'findingId':item['finding']['id'],'sourceOutcomeUnknown':True} for name,item in cases.items()}
  # Match WorkflowHealthProposalTests: only the owned fixture DB marks a persisted
  # pending proposal accepting to model a process that died after claim. Renderer
  # never writes this state. Retain before/after records as evidence.
  recovery_pending=direct('workflows.health.proposeTimeout',recovery_case['seed']); db=Path(fixture['home'])/'vela.sqlite3'
  with sqlite3.connect(db) as con:
   raw=con.execute("SELECT json FROM objects WHERE kind='workflow_health_proposal' AND id=?",(recovery_pending['id'],)).fetchone(); assert raw; before_claim=json.loads(raw[0]); claimed=dict(before_claim); claimed['state']='accepting'; claimed['decision']='accept'; claimed['updatedAt']='2026-09-14T00:00:00Z'; con.execute("UPDATE objects SET json=?, updatedAt=? WHERE kind='workflow_health_proposal' AND id=?",(json.dumps(claimed,separators=(',',':')),claimed['updatedAt'],recovery_pending['id']))
  ev['fixtureCrashSeam']={'owner':'test-workflow-health-proposal-browser.py','before':{'id':before_claim['id'],'state':before_claim['state']},'after':{'id':claimed['id'],'state':claimed['state']},'rendererDidNotWriteState':True}
  spec=importlib.util.spec_from_file_location('ui_driver',ROOT/'scripts/test-ui-browser.py'); mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
  src=mod.PLAYWRIGHT_DRIVER.replace("const page=await browser.newPage({viewport:{width:1280,height:720}});page.setDefaultTimeout(5000);","const page=await browser.newPage({viewport:{width:1280,height:720}});await page.addInitScript(()=>{window.__healthErrors=[];addEventListener('error',e=>window.__healthErrors.push(e.message));addEventListener('unhandledrejection',e=>window.__healthErrors.push(String(e.reason)))});page.setDefaultTimeout(5000);")
  server=subprocess.Popen(['python3',str(ROOT/'scripts/test-ui-server.py'),str(base/'fixture.json'),'--binary',str(helper),'--ui-directory',str(snap)],stdout=subprocess.PIPE,text=True); assert select.select([server.stdout],[],[],15)[0],'fixture server did not start'; url=json.loads(server.stdout.readline())['url']; playwright=ROOT/'.task-tmp/ui-browser-tools/node_modules/playwright/index.js'; assert playwright.is_file(),'pinned Playwright module missing'
  driver=subprocess.Popen(['node','-e',src,str(playwright),str(a.browser_executable)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,start_new_session=True); browser('open',url); browser('wait','#project-selector'); browser('select','#project-selector',project)
  value("""window.__healthCalls=[];window.__healthOriginal=window.vela.call;window.vela.call=async(method,params={})=>{try{const result=await window.__healthOriginal(method,params);window.__healthCalls.push({method,params,result});if(window.__healthHold===method){window.__healthHeld=true;await new Promise(resolve=>window.__healthRelease=resolve);window.__healthHeld=false}return result}catch(error){window.__healthCalls.push({method,params,error:String(error)});throw error}};true""")
  def open_health():
   click('.nav-link[data-page="workflows"]'); wait('document.querySelector(".nav-link.active")?.dataset.page==="workflows"','workflow page absent'); click('.tab-btn[data-wftab="health"]'); wait('!!document.querySelector("#workflow-health-findings")','Health finding list selector missing')
  def finding_button(case): return '.btn-propose-health-timeout[data-finding-id="'+case['finding']['id']+'"]'
  def readonly_preview():
   before=(len(rows()),len(runs()),len(approvals())); assert bridge_error('workflows.health.proposeTimeout',dict(reject_case['seed'],unexpected='blocked')),'bridge accepted extra proposal field'; assert bridge_error('workflows.health.proposal.get',{'project':fixture['projects'][1],'id':'foreign-proposal'}),'bridge accepted foreign project proposal read'; open_health(); wait('!!document.querySelector('+json.dumps(finding_button(reject_case))+')','eligible timeout finding has no proposal control'); n=len(value('window.__healthCalls.filter(x=>x.method==="workflows.health.proposeTimeout")')); click(finding_button(reject_case)); wait('!!document.querySelector("#health-timeout-proposal-preview")','readonly proposal preview missing'); wait('!!document.querySelector("#health-timeout-new-seconds")','readonly timeout preview did not finish loading'); assert value('document.querySelector("#health-timeout-new-seconds")?.value') in ('2',''), 'invalid default proposal value'; assert len(value('window.__healthCalls.filter(x=>x.method==="workflows.health.proposeTimeout")'))==n,'preview wrote proposal'; assert (len(rows()),len(runs()),len(approvals()))==before,'preview mutated workflow/run/approval'; body=value('document.body.innerText'); assert not any(token in body for token in (reject_case['inspect']['snapshotHash'],)), 'raw freeze hash rendered in normal UI'; browser('screenshot',str(out/'readonly-preview-modal.png')); (out/'readonly-preview-modal.txt').write_text(browser('snapshot','-i'))
   for invalid in ('','0','1','3','1.5','-1'):
    browser('fill','#health-timeout-new-seconds',invalid); assert value('document.querySelector("#btn-create-health-timeout-proposal")?.disabled===true'), 'invalid timeout enabled Create: '+invalid
   assert len(value('window.__healthCalls.filter(x=>x.method==="workflows.health.proposeTimeout")'))==n,'invalid form values wrote a proposal'
   browser('fill','#health-timeout-new-seconds','2'); assert value('document.querySelector("#btn-create-health-timeout-proposal")?.disabled===false'),'valid timeout remained disabled'
   return {'previewReadOnly':True,'countsUnchanged':True,'invalidTimeoutValuesBlocked':['empty',0,1,3,1.5,-1]}
  def propose_reject():
   open_health(); click(finding_button(reject_case)); wait('!!document.querySelector("#btn-create-health-timeout-proposal")','create control missing'); browser('fill','#health-timeout-new-seconds','2'); click('#btn-create-health-timeout-proposal'); wait('!!document.querySelector("#health-timeout-proposal-review")','pending proposal review missing'); before=(len(rows()),len(runs()),len(approvals())); click('#btn-reject-health-proposal'); wait('document.querySelector("#health-timeout-proposal-review")?.dataset.state==="rejected"','reject did not settle'); assert (len(rows()),len(runs()),len(approvals()))==before,'reject changed workflow/run/approval'; return {'pendingCreated':True,'rejectNoCandidate':True}
  def uncertain_accept():
   open_health(); click(finding_button(accept_case)); wait('!!document.querySelector("#btn-create-health-timeout-proposal")','accept fixture create control missing'); browser('fill','#health-timeout-new-seconds','2'); click('#btn-create-health-timeout-proposal'); wait('!!document.querySelector("#health-timeout-proposal-review")','accept fixture proposal review missing'); before=(len(rows()),len(runs()),len(approvals())); pending=next(x for x in bridge('workflows.health.proposal.list',{'project':project,'limit':20})['items'] if x.get('workflowId')==accept_case['workflow']['id'] and x.get('state')=='pending_review'); assert bridge_error('workflows.health.proposal.decide',{'project':project,'id':pending['id'],'proposalHash':pending['proposalHash'],'decision':'accept','acknowledgeUncertainSource':False}),'Core accepted uncertain proposal without acknowledgement'; assert value('document.querySelector("#health-timeout-uncertain-ack")?.checked===false'),'uncertain acknowledgement must start unchecked'; assert value('document.querySelector("#btn-accept-health-proposal")?.disabled===true'),'unchecked uncertain accept must be disabled'; value('document.querySelector("#health-timeout-uncertain-ack").click();true'); wait('document.querySelector("#btn-accept-health-proposal")?.disabled===false','acknowledgement did not enable explicit accept'); click('#btn-accept-health-proposal'); wait('document.querySelector("#health-timeout-proposal-review")?.dataset.state==="accepted"','accepted proposal did not settle'); proposals=bridge('workflows.health.proposal.list',{'project':project,'limit':20})['items']; accepted=next(x for x in proposals if x.get('workflowId')==accept_case['workflow']['id'] and x.get('state')=='accepted'); candidate=bridge('workflows.get',{'project':project,'id':accepted['acceptedWorkflowId']})['definition']; assert candidate['enabled'] is False and candidate['id']!=accept_case['workflow']['id'] and candidate['steps'][0]['arguments']['timeoutSeconds']==2; expected_steps=json.loads(json.dumps(accept_case['inspect']['definition']['steps'])); expected_steps[0]['arguments']['timeoutSeconds']=2; assert candidate['steps']==expected_steps,'candidate changed other step semantics'; assert direct('workflows.get',{'project':project,'id':accept_case['workflow']['id']})['snapshotHash']==accept_case['inspect']['snapshotHash'],'original workflow changed'; assert direct('runs.get',{'id':accept_case['run']['id']})==accept_case['run'],'original historical run changed'; assert len(runs())==before[1] and len(approvals())==before[2] and len(rows())==before[0]+1,'accept did not create exactly one disabled candidate'; return {'missingAckBlocked':True,'acceptedDisabledCandidate':candidate['id'],'originalRunApprovalUnchanged':True}
  def recovery_stale():
   # accepting was seeded only in the owned fixture DB above. The UI can only issue
   # explicit recover. Hold that real bridge response, close the dialog through
   # Escape (the backdrop correctly prevents clicking through it), switch project,
   # then release the response.
   open_health(); recovery_entry='.btn-open-proposal-item[data-proposal-id="'+recovery_pending['id']+'"]'; wait('!!document.querySelector('+json.dumps(recovery_entry)+')','accepting proposal entry missing'); click(recovery_entry); wait('!!document.querySelector("#btn-recover-health-proposal")','accepting proposal recovery control missing'); before=len(rows()); value('window.__healthHold="workflows.health.proposal.decide";true'); click('#btn-recover-health-proposal'); wait('window.__healthHeld===true','real recovery response was not held'); calls_before=value('window.__healthCalls.filter(x=>x.method==="workflows.health.proposal.decide").length'); value('(()=>{const b=document.querySelector("#btn-recover-health-proposal");if(b&&!b.disabled)b.click();return true})()'); browser('press','Escape'); wait('document.querySelector("#modal-container")?.classList.contains("hidden")===true','Escape did not dismiss held proposal review'); click('.nav-link[data-page="agents"]'); wait('!!document.querySelector('+json.dumps('.session-title-btn[data-id="'+fixture['sessions'][0]+'"]')+')','fixture session unavailable during held recovery'); click('.session-title-btn[data-id="'+fixture['sessions'][0]+'"]'); browser('select','#project-selector',fixture['projects'][1]); value('window.__healthRelease();true'); wait('window.__healthHeld===false','held recovery did not release'); assert value('window.__healthCalls.filter(x=>x.method==="workflows.health.proposal.decide").length')==calls_before,'double click issued a second recovery'; recovered=bridge('workflows.health.proposal.get',{'project':project,'id':recovery_pending['id']}); assert recovered['state']=='pending_review' and len(rows())==before,'recover created candidate or left accepting'; assert bridge_error('workflows.health.proposal.get',{'project':fixture['projects'][1],'id':recovery_pending['id']}),'foreign proposal was readable'; browser('select','#project-selector',project);
   for locale in ('en','zh-CN'):
    value('VelaI18n.setLocale('+json.dumps(locale)+');document.dispatchEvent(new Event("vela:locale"));true'); open_health(); text=wait('document.querySelector('+json.dumps(finding_button(recovery_case))+')?.textContent.trim() || \"\"','localized timeout finding did not finish loading: '+locale); assert text and not text.startswith('workflows.'),'missing Health proposal localization: '+locale
   return {'explicitRecovery':True,'doubleClickCoalesced':True,'projectAndSessionSwitchDiscardedLateUI':True,'localizedLabels':['en','zh-CN'],'zeroCandidates':True}
  check('readonly-preview',readonly_preview); check('proposal-reject',propose_reject); check('uncertain-accept',uncertain_accept); check('recovery-stale-locales',recovery_stale)
  ev['uiAfter']={n:sha(ui_source/n) for n in UI_FILES}; ev['helperAfter']=sha(binary)
  ev['harnessAfter']={n:sha(ROOT/'scripts'/n) for n in HARNESS_FILES}
  ev['sourceUnchanged']=ev['uiBefore']==ev['uiFixture']==ev['uiAfter'] and ev['helperBefore']==ev['helperFixture']==ev['helperAfter'] and ev['harnessBefore']==ev['harnessAfter']
  ev['selectedChecksPassed']=len(ev['checks'])==len(selected) and all(x['passed'] for x in ev['checks']); ev['completeSuite']=set(selected)==set(CHECKS) and ev['selectedChecksPassed'] and ev['sourceUnchanged'] and not any(x.get('pageErrors') for x in ev['checks']); save()
  if not ev['selectedChecksPassed'] or not ev['sourceUnchanged'] or any(x.get('pageErrors') for x in ev['checks']): raise SystemExit(1)
 finally:
  try:
   if driver: browser('close')
  except Exception: pass
  if server:
   server.send_signal(signal.SIGTERM)
   try: server.wait(timeout=5)
   except subprocess.TimeoutExpired: server.kill(); server.wait()
  for name in ('harness-rpc.jsonl','fixture.json'):
   if (base/name).is_file() and not (base/name).is_symlink():
    shutil.copyfile(base/name,out/name); ev.setdefault('retainedEvidenceSHA256',{})[name]=sha(out/name)
  if base.exists() and not base.is_symlink() and (base/'store/.vela-ui-fixture.json').is_file(): shutil.rmtree(base); ev['fixtureRemoved']=True
  else: ev['fixtureRemoved']=False
  save()
if __name__=='__main__': main()
