"""Browser acceptance for the Core-verified session Memory capture flow.

Requires frozen UI/helper inputs. It uses a fresh synthetic fixture and the
fixture-only bridge; diagnostic subsets never claim a complete suite.
"""
import argparse, hashlib, importlib.util, json, os, select, shutil, signal, subprocess, time, traceback, urllib.request
from pathlib import Path
from release_resources import DEVELOPMENT_UI_RESOURCES, UI_RESOURCES, copy_ui_resources

ROOT = Path(__file__).resolve().parents[1]
UI_FILES=UI_RESOURCES + DEVELOPMENT_UI_RESOURCES
HARNESS_FILES=('test-ui-server.py','create-ui-fixture.py','test-ui-browser.py')
CHECKS = ('prepare-cancel-confirm','idempotency-and-source-edit','stale-and-scope-guards','ineligible-and-locales','all-projects-and-pending')
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

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
 evidence={'format':'vela-session-memory-capture-renderer-v1','synthetic':True,'completeSuite':False,'realProviderExecuted':False,'modelCalls':0,'workflowExecuted':False,'nativeClaimed':False,'selectedChecks':sorted(selected),'checks':[]}; server=driver=None
 def save(): (out/'results.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n')
 def browser(*args):
  driver.stdin.write(json.dumps(args)+'\n'); driver.stdin.flush(); assert select.select([driver.stdout],[],[],20)[0],'browser driver timeout'; row=json.loads(driver.stdout.readline()); assert 'error' not in row,row; return row.get('output','')
 def value(js): return json.loads(browser('eval',js))
 def wait(js,msg,seconds=10):
  until=time.monotonic()+seconds
  while time.monotonic()<until:
   if value(js): return
   time.sleep(.08)
  raise AssertionError(msg)
 def click(selector): browser('click',selector); browser('snapshot','-i')
 def open_action_menu(trigger):
  menu='details.action-menu:has('+trigger+')'
  wait('!!document.querySelector('+json.dumps(menu)+')','action menu absent for '+trigger)
  if not value('document.querySelector('+json.dumps(menu)+').open'):
   click(menu+' > summary'); wait('document.querySelector('+json.dumps(menu)+').open===true','action menu did not open for '+trigger)
 def rpc(method,params):
  request=urllib.request.Request(url+'__rpc',json.dumps({'method':method,'params':params}).encode(),{'Content-Type':'application/json','Origin':'http://'+url.split('/')[2]})
  try:
   with urllib.request.urlopen(request,timeout=25) as response: data=json.load(response)
  except urllib.error.HTTPError as err: data=json.loads(err.read())
  if 'error' in data: raise RuntimeError(data['error'])
  return data['result']
 def rpc_error(method,params):
  try: rpc(method,params)
  except RuntimeError as error: return str(error)
  raise AssertionError(method+' unexpectedly succeeded')
 def calls(method): return value('window.__captureCalls.filter(x=>x.method==='+json.dumps(method)+')')
 def memories(project): return rpc('memory.list',{'project':project})
 def check(name,fn):
  if name not in selected: return
  try: evidence['checks'].append({'check':name,'passed':True,**(fn() or {})})
  except Exception as err: evidence['checks'].append({'check':name,'passed':False,'error':str(err),'traceback':traceback.format_exc(limit=6)})
  finally:
   # A failed frozen-UI contract check can leave its real modal open. Dismiss it
   # so later diagnostic checks independently describe their own missing contract.
   try:
    # Held responses are scoped to one check. Clear the interception rule even
    # after a successful release so the next check uses ordinary real RPC.
    value('window.__captureHold=null;true')
    if value('window.__captureHeld===true'): value('window.__captureRelease();true')
    browser('press','Escape'); browser('press','Escape')
   except Exception: pass
  evidence['checks'][-1]['pageErrors']=value('window.__captureErrors||[]'); browser('screenshot',str(out/(name+'.png'))); (out/(name+'.txt')).write_text(browser('snapshot','-i')); print(json.dumps(evidence['checks'][-1],ensure_ascii=False),flush=True); save()
 try:
  evidence['uiBefore']={n:digest(ui_source/n) for n in UI_FILES}; evidence['helperBefore']=digest(binary)
  evidence['harnessBefore']={n:digest(ROOT/'scripts'/n) for n in HARNESS_FILES}
  made=subprocess.run(['python3',str(ROOT/'scripts/create-ui-fixture.py'),str(base),'--binary',str(binary),'--with-routing-project'],text=True,capture_output=True,timeout=120); (out/'fixture-creation.log').write_text(made.stdout+made.stderr); made.check_returncode(); fixture=json.loads((base/'fixture.json').read_text()); project=fixture['project']
  snap,helper=base/'ui-snapshot',base/'vela-frozen'; copy_ui_resources(ui_source,snap,allow_development=True)
  shutil.copy2(binary,helper); evidence['uiFixture']={n:digest(snap/n) for n in UI_FILES}; evidence['helperFixture']=digest(helper); assert evidence['uiBefore']==evidence['uiFixture'] and evidence['helperBefore']==evidence['helperFixture']
  spec=importlib.util.spec_from_file_location('ui_driver',ROOT/'scripts/test-ui-browser.py'); mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
  driver_source=mod.PLAYWRIGHT_DRIVER.replace("const page=await browser.newPage({viewport:{width:1280,height:720}});page.setDefaultTimeout(5000);","const page=await browser.newPage({viewport:{width:1280,height:720}});await page.addInitScript(()=>{window.__captureErrors=[];addEventListener('error',e=>window.__captureErrors.push(e.message));addEventListener('unhandledrejection',e=>window.__captureErrors.push(String(e.reason)))});page.setDefaultTimeout(5000);")
  server=subprocess.Popen(['python3',str(ROOT/'scripts/test-ui-server.py'),str(base/'fixture.json'),'--binary',str(helper),'--ui-directory',str(snap)],stdout=subprocess.PIPE,text=True); assert select.select([server.stdout],[],[],15)[0],'fixture server did not start'; url=json.loads(server.stdout.readline())['url']
  playwright=ROOT/'.task-tmp/ui-browser-tools/node_modules/playwright/index.js'; assert playwright.is_file(),'pinned local Playwright module missing'
  driver=subprocess.Popen(['node','-e',driver_source,str(playwright),str(a.browser_executable)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,start_new_session=True); browser('open',url); browser('wait','#project-selector'); browser('select','#project-selector',project)
  value("""window.__captureVisible=selector=>{const el=document.querySelector(selector);return !!el&&el.getClientRects().length>0};window.__captureCalls=[];window.__captureOriginal=window.vela.call;window.vela.call=async(method,params={})=>{try{const result=await window.__captureOriginal(method,params);window.__captureCalls.push({method,params,result});if(window.__captureHold===method){window.__captureHeld=true;await new Promise(resolve=>window.__captureRelease=resolve);window.__captureHeld=false;}return result}catch(error){window.__captureCalls.push({method,params,error:String(error)});throw error}};true""")
  source=next(x for x in rpc('sessions.list',{}) if x.get('provider')=='codex' and x.get('project')==project); detail=rpc('sessions.get',{'id':source['id'],'project':project}); messages=detail.get('messages') or []; eligible=[m for m in messages if m.get('role') in ('user','assistant') and m.get('id')]; assert len(eligible)>=2,'fixture needs user and assistant messages'; user=next(m for m in eligible if m['role']=='user'); assistant=next(m for m in eligible if m['role']=='assistant'); tool=[m for m in messages if m.get('role') not in ('user','assistant')]
  def btn(msg): return '#session-msg-'+msg['id']+' .btn-save-msg-memory'
  def close_detail():
   if value('!document.querySelector("#detail-drawer")?.classList.contains("hidden")'):
    click('#btn-close-drawer'); wait('document.querySelector("#detail-drawer")?.classList.contains("hidden")','detail did not close')
  def open_source(keep_scope=False):
   close_detail()
   if not keep_scope and value('document.querySelector("#project-selector").value')!=project: browser('select','#project-selector',project)
   click('.nav-link[data-page="agents"]'); wait('document.querySelector(".nav-link.active")?.dataset.page==="agents"','Agents page did not settle'); wait('!!document.querySelector('+json.dumps('.session-title-btn[data-id="'+source['id']+'"]')+')','source session missing'); click('.session-title-btn[data-id="'+source['id']+'"]'); wait('!!document.querySelector('+json.dumps('#session-msg-'+assistant['id'])+')','source message missing')
  def prepare_confirm():
   open_source(); before=memories(project); n=len(calls('memory.capture.prepare')); click(btn(assistant)); wait('window.__captureVisible("#session-capture-preview")','capture must show source preview, not ordinary Memory editor'); wait('window.__captureCalls.filter(x=>x.method==="memory.capture.prepare").length>'+str(n),'capture prepare did not settle'); prepared=calls('memory.capture.prepare')[n:]; assert len(prepared)==1 and prepared[0]['params']=={'project':project,'sessionId':source['id'],'messageId':assistant['id']},'prepare did not bind actual source'; assert value('document.querySelector("#session-capture-preview [data-capture-content]")?.textContent')==assistant['content'],'preview differs from source'; assert len(memories(project))==len(before),'prepare wrote Memory'; browser('screenshot',str(out/'capture-preview.png')); (out/'capture-preview.txt').write_text(browser('snapshot','-i')); click('#btn-cancel-session-capture'); wait('!window.__captureVisible("#session-capture-preview")','cancel did not close preview'); assert not calls('memory.capture') and len(memories(project))==len(before),'cancel wrote capture'; click(btn(assistant)); wait('window.__captureVisible("#btn-confirm-session-capture")','confirm missing'); click('#btn-confirm-session-capture'); wait('window.__captureCalls.some(x=>x.method==="memory.capture"&&!x.error)','confirm did not call Core'); sent=calls('memory.capture'); assert len(sent)==1 and sent[0]['params']=={k:prepared[0]['result'][k] for k in ('project','sessionId','messageId','sourceIdentity','expectedSourceHash')},'capture did not send exact frozen five-field contract'; rows=[x for x in memories(project) if x.get('sourceSession')==source['id'] and x.get('sourceMessage')==assistant['id']]; assert len(rows)==1 and rows[0].get('state')=='candidate' and rows[0].get('requiresReview') is True and rows[0].get('content')==assistant['content'],'confirm did not create exact reviewable candidate'; return {'prepareZeroWrites':True,'cancelZeroWrites':True,'confirmedCandidate':rows[0]['id'],'exactSource':True}
  def idempotency():
   open_source(); before=[x for x in memories(project) if x.get('sourceSession')==source['id'] and x.get('sourceMessage')==assistant['id']]; assert len(before)==1, 'requires the prior confirmed capture; UI capture contract is unavailable'; click(btn(assistant)); wait('window.__captureVisible("#btn-confirm-session-capture")','second preview missing'); click('#btn-confirm-session-capture'); wait('!window.__captureVisible("#session-capture-preview")','second capture did not settle'); after=[x for x in memories(project) if x.get('sourceSession')==source['id'] and x.get('sourceMessage')==assistant['id']]; assert len(after)==1 and after[0]['id']==before[0]['id'] and after[0].get('state')=='candidate','repeat created or activated a candidate'; click('.nav-link[data-page="memory"]'); wait('!!document.querySelector('+json.dumps('.memory-card[data-id="'+after[0]['id']+'"]')+')','candidate absent from memory list'); edit_selector='.btn-mem-edit[data-id="'+after[0]['id']+'"]'; open_action_menu(edit_selector); click(edit_selector); wait('!!document.querySelector("#mem-src-session")&&!!document.querySelector("#mem-src-msg")','editor source fields absent'); assert value('["session","msg","file","commit"].every(x=>{const el=document.getElementById("mem-src-"+x);return el&&(el.readOnly||el.disabled)})'),'capture source fields are editable in Memory editor'; edited='User-reviewed capture text after observation.'; browser('fill','#mem-content',edited); click('#btn-save-mem'); wait('window.__captureCalls.some(x=>x.method==="memory.save"&&!x.error&&x.params.content==='+json.dumps(edited)+')','edited content did not save through Core'); current=next(x for x in memories(project) if x['id']==before[0]['id']); assert current['content']==edited and current.get('state')=='candidate' and current.get('provenance',{}).get('derivedBy')=='user_edit','edited capture was not recorded as user edit'; assert all(current.get(k)==before[0].get(k) for k in ('sourceSession','sourceMessage','sourceFile','sourceCommit')),'source changed on content edit'; return {'idempotent':True,'candidateNotActivated':True,'sourceFieldsReadonly':True,'contentEditPreservesSource':True,'derivedBy':'user_edit'}
  def stale_scope():
   open_source(); before=len(memories(project)); prior=len(calls('memory.capture.prepare')); click(btn(user)); wait('window.__captureVisible("#session-capture-preview")','source-change check requires preview'); wait('window.__captureCalls.filter(x=>x.method==="memory.capture.prepare").length>'+str(prior),'source-change prepare did not settle'); frozen=calls('memory.capture.prepare')[prior:]; assert len(frozen)==1; click('#btn-cancel-session-capture')
   source_path=Path(source['sourcePath']); original=source_path.read_text()
   # SessionEngine treats a larger JSONL file as an append and only reads from
   # the saved offset.  This is a replacement of an existing provider record,
   # so preserve the exact UTF-8 byte count and exercise its source-version
   # rewrite path instead of misrepresenting it as an append.
   replacement='R' * len(user['content'].encode())
   assert len(replacement.encode())==len(user['content'].encode()), 'fixture replacement must preserve the provider record byte length'
   records=[json.loads(line) for line in original.splitlines() if line.strip()]; matches=0
   for record in records:
    payload=record.get('payload') or {}
    if payload.get('role')=='user' and payload.get('id')==user['id']:
     for part in payload.get('content') or []:
      if part.get('text')==user['content']: part['text']=replacement; matches+=1
   assert matches==1,('fixture message identity must select exact raw source',matches,user['id'])
   source_path.write_text(''.join(json.dumps(record)+'\n' for record in records)); rpc('sessions.refresh',{})
   observed=rpc('sessions.get',{'id':source['id'],'project':project}); assert any(m.get('id')==user['id'] and m.get('content')==replacement for m in observed.get('messages',[])),'modified source was not actually indexed'
   stale_params={k:frozen[0]['result'][k] for k in ('project','sessionId','messageId','sourceIdentity','expectedSourceHash')}; stale_error=rpc_error('memory.capture',stale_params); assert 'Session source changed' in stale_error,stale_error; assert len(memories(project))==before,'stale source capture wrote a candidate'
   # Restore fixture source for the separate held-prepare generation check.
   source_path.write_text(original); rpc('sessions.refresh',{}); open_source(); value('window.__captureHold="memory.capture.prepare";true'); click(btn(user)); wait('window.__captureHeld===true','prepare response not held'); browser('select','#project-selector',fixture['projects'][1]); value('window.__captureRelease();true'); wait('window.__captureHeld===false','held prepare did not release'); assert not value('window.__captureVisible("#btn-confirm-session-capture")'),'old source remains confirmable after project switch'; assert len(memories(project))==before,'held prepare wrote candidate'; assert rpc_error('memory.capture.prepare',{'project':project,'sessionId':source['id'],'messageId':'missing-message-id'}); assert len(memories(project))==before,'missing message wrote candidate'; return {'sourceChangedRejected':True,'heldPrepareNoWrite':True,'scopeSwitchBlocksOldConfirm':True,'missingMessageRejected':True}
  def ineligible_locale():
   open_source()
   for msg in tool: assert not value('!!document.querySelector('+json.dumps(btn(msg))+')'),'tool/non-message received a capture control'
   for locale in ('en','zh-CN'):
    value('VelaI18n.setLocale('+json.dumps(locale)+');document.dispatchEvent(new Event("vela:locale"));true'); open_source(); text=value('document.querySelector('+json.dumps(btn(assistant))+').textContent.trim()'); assert text and not text.startswith('sessions.'),'missing capture localization: '+locale
   return {'toolMessageWithheld':bool(tool),'localizedLabels':['en','zh-CN']}
  def all_projects_pending():
   browser('select','#project-selector',''); open_source(keep_scope=True)
   n=len(calls('memory.capture.prepare')); click(btn(user))
   wait('window.__captureCalls.filter(x=>x.method==="memory.capture.prepare").length>'+str(n),'All Projects prepare did not settle')
   prepared=calls('memory.capture.prepare')[n:]; assert len(prepared)==1 and prepared[0]['params']['project']==project and not prepared[0].get('error'),'All Projects capture lost the actual session project'
   before=len(calls('memory.capture')); value('window.__captureHold="memory.capture";true'); click('#btn-confirm-session-capture')
   wait('window.__captureHeld===true','capture mutation response was not held')
   assert value('document.querySelector("#btn-confirm-session-capture")?.disabled===true'),'pending capture control remains enabled'
   browser('press','Enter'); assert len(calls('memory.capture'))==before+1,'duplicate keyboard submit reissued capture'
   browser('select','#project-selector',fixture['projects'][1]); value('window.__captureRelease();window.__captureHold=null;true')
   wait('window.__captureHeld===false','capture response did not release'); wait('!window.__captureVisible("#session-capture-preview")','old mutation reopened a source preview after project switch')
   captured=[m for m in memories(project) if m.get('sourceSession')==source['id'] and m.get('sourceMessage')==user['id']]
   assert len(captured)==1 and captured[0]['state']=='candidate','pending capture created a duplicate or changed lifecycle'
   assert not any(m.get('sourceSession')==source['id'] for m in memories(fixture['projects'][1])),'capture crossed project scope'
   return {'allProjectsUsesSessionProject':True,'pendingDuplicateBlocked':True,'lateMutationNoStaleModal':True,'candidateCount':1,'crossProjectWrites':0}
  check('prepare-cancel-confirm',prepare_confirm); check('idempotency-and-source-edit',idempotency); check('stale-and-scope-guards',stale_scope); check('ineligible-and-locales',ineligible_locale); check('all-projects-and-pending',all_projects_pending)
  evidence['uiAfter']={n:digest(ui_source/n) for n in UI_FILES}; evidence['helperAfter']=digest(binary)
  evidence['harnessAfter']={n:digest(ROOT/'scripts'/n) for n in HARNESS_FILES}
  evidence['sourceUnchanged']=evidence['uiBefore']==evidence['uiFixture']==evidence['uiAfter'] and evidence['helperBefore']==evidence['helperFixture']==evidence['helperAfter'] and evidence['harnessBefore']==evidence['harnessAfter']
  evidence['selectedChecksPassed']=len(evidence['checks'])==len(selected) and all(x['passed'] for x in evidence['checks']); evidence['completeSuite']=set(selected)==set(CHECKS) and evidence['selectedChecksPassed'] and evidence['sourceUnchanged'] and not any(x.get('pageErrors') for x in evidence['checks']); save()
  if not evidence['selectedChecksPassed'] or not evidence['sourceUnchanged'] or any(x.get('pageErrors') for x in evidence['checks']): raise SystemExit(1)
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
    shutil.copyfile(base/name,out/name); evidence.setdefault('retainedEvidenceSHA256',{})[name]=digest(out/name)
  if base.exists() and not base.is_symlink() and (base/'store/.vela-ui-fixture.json').is_file(): shutil.rmtree(base); evidence['fixtureRemoved']=True
  else: evidence['fixtureRemoved']=False
  save()
if __name__=='__main__': main()
