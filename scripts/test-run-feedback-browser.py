#!/usr/bin/env python3
"""Actual Playwright consumer test for the frozen Run Feedback bridge contract."""
import argparse, hashlib, importlib.util, json, os, select, shutil, signal, subprocess, time, traceback, urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; FILES=('app.js','i18n.js','app.css','index.html','app-icon.svg','demo.js'); CHECKS=('prepare-cancel-locales','revision-history-objective','stale-lifecycle')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser(); p.add_argument('--ui-directory',type=Path,required=True);p.add_argument('--binary',type=Path,required=True);p.add_argument('--fixture',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--browser-executable',type=Path,required=True);p.add_argument('--checks');a=p.parse_args(); chosen=set(a.checks.split(',')) if a.checks else set(CHECKS)
 if not chosen or not chosen<=set(CHECKS):p.error('unknown --checks')
 ui,binary=a.ui_directory.resolve(strict=True),a.binary.resolve(strict=True);base,out=a.fixture.absolute(),a.output.absolute()
 if base.exists() or base.is_symlink() or base.parent!=(ROOT/'.task-tmp').resolve():p.error('fixture must be a new immediate .task-tmp child')
 if out.exists() or out.is_symlink() or out.parent.resolve()!=(ROOT/'output/playwright').resolve():p.error('output must be a new output/playwright child')
 if not shutil.which('node') or not shutil.which('npx') or not a.browser_executable.is_file():p.error('Node/npx and browser executable required')
 if any(not(ui/x).is_file() or(ui/x).is_symlink() for x in FILES):p.error('ordinary frozen UI files required')
 out.mkdir(parents=True);(out/'consumer-test-source.py').write_bytes(Path(__file__).read_bytes()); ev={'format':'vela-run-feedback-renderer-v1','synthetic':True,'completeSuite':False,'providerRuns':0,'modelRuns':0,'workflowExecuted':'fixture Git reads only','nativeClaimed':False,'selectedChecks':sorted(chosen),'checks':[]};server=driver=None
 def save():(out/'results.json').write_text(json.dumps(ev,ensure_ascii=False,indent=2)+'\n')
 def b(*xs):
  driver.stdin.write(json.dumps(xs)+'\n');driver.stdin.flush();assert select.select([driver.stdout],[],[],20)[0],'browser timeout';z=json.loads(driver.stdout.readline());assert'error'not in z,z;return z.get('output','')
 def v(js):return json.loads(b('eval',js))
 def wait(js,msg):
  end=time.monotonic()+10
  while time.monotonic()<end:
   if v(js):return
   time.sleep(.08)
  raise AssertionError(msg)
 def click(s):b('click',s);b('snapshot','-i')
 def rpc(m,x,allow_error=False):
  q=urllib.request.Request(url+'__rpc',json.dumps({'method':m,'params':x}).encode(),{'Content-Type':'application/json','Origin':'http://'+url.split('/')[2]})
  try:
   with urllib.request.urlopen(q,timeout=25)as r:z=json.load(r)
  except urllib.error.HTTPError as e:z=json.loads(e.read())
  if'error'in z:
   if allow_error:return z['error']
   raise RuntimeError(z['error'])
  if allow_error:raise AssertionError(m+' unexpectedly accepted')
  return z['result']
 def calls(m):return v('window.__rfCalls.filter(x=>x.method==='+json.dumps(m)+')')
 def check(n,fn):
  if n not in chosen:return
  try:ev['checks'].append({'check':n,'passed':True,**(fn()or{})})
  except Exception as e:ev['checks'].append({'check':n,'passed':False,'error':str(e),'traceback':traceback.format_exc(limit=5)})
  finally:
   try:
    v('if(window.__rfHeld)window.__rfRelease();window.__rfHold=null;true');b('press','Escape');b('press','Escape')
   except:pass
  ev['checks'][-1]['pageErrors']=v('window.__rfErrors||[]');b('screenshot',str(out/(n+'.png')));(out/(n+'.txt')).write_text(b('snapshot','-i'));save();print(json.dumps(ev['checks'][-1]),flush=True)
 try:
  harness=(ROOT/'scripts/test-ui-server.py',ROOT/'scripts/create-ui-fixture.py',ROOT/'scripts/test-ui-browser.py');ev['uiBefore']={x:sha(ui/x)for x in FILES};ev['helperBefore']=sha(binary);ev['harnessBefore']={x.name:sha(x)for x in harness}
  made=subprocess.run(['python3',str(ROOT/'scripts/create-ui-fixture.py'),str(base),'--binary',str(binary),'--with-routing-project'],cwd=ROOT,text=True,capture_output=True,timeout=120);(out/'fixture-creation.log').write_text(made.stdout+made.stderr);made.check_returncode();fixture=json.loads((base/'fixture.json').read_text());project,beacon,run=fixture['project'],fixture['routingProject'],fixture['completedRun']
  snap,helper=base/'ui-snapshot',base/'vela-frozen';snap.mkdir();[shutil.copyfile(ui/x,snap/x)for x in FILES];shutil.copy2(binary,helper);ev['uiFixture']={x:sha(snap/x)for x in FILES};ev['helperFixture']=sha(helper)
  spec=importlib.util.spec_from_file_location('d',ROOT/'scripts/test-ui-browser.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);src=mod.PLAYWRIGHT_DRIVER.replace("const page=await browser.newPage({viewport:{width:1280,height:720}});page.setDefaultTimeout(5000);","const page=await browser.newPage({viewport:{width:1280,height:720}});await page.addInitScript(()=>{window.__rfErrors=[];addEventListener('error',e=>window.__rfErrors.push(e.message));addEventListener('unhandledrejection',e=>window.__rfErrors.push(String(e.reason)))});page.setDefaultTimeout(5000);")
  server=subprocess.Popen(['python3',str(ROOT/'scripts/test-ui-server.py'),str(base/'fixture.json'),'--binary',str(helper),'--ui-directory',str(snap)],cwd=ROOT,stdout=subprocess.PIPE,text=True,start_new_session=True);assert select.select([server.stdout],[],[],15)[0],'server start';url=json.loads(server.stdout.readline())['url'];pw=ROOT/'.task-tmp/ui-browser-tools/node_modules/playwright/index.js';assert pw.is_file(),'pinned Playwright missing';driver=subprocess.Popen(['node','-e',src,str(pw),str(a.browser_executable)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,start_new_session=True);b('open',url);b('wait','#project-selector');b('select','#project-selector',project)
  v("""window.__rfCalls=[];window.__rfStarted=[];window.__rfOriginal=window.vela.call;window.vela.call=async(m,x={})=>{window.__rfStarted.push({method:m,params:x});if(window.__rfBeforeHold===m){window.__rfHeld=true;await new Promise(ok=>window.__rfRelease=ok);window.__rfHeld=false}try{let r=await window.__rfOriginal(m,x);window.__rfCalls.push({method:m,params:x,result:r});return r}catch(e){window.__rfCalls.push({method:m,params:x,error:String(e)});throw e}};window.__rfVisible=s=>{let e=document.querySelector(s);return!!e&&e.getClientRects().length>0};true""")
  initialRun=rpc('runs.get',{'id':run});initialHealth=rpc('workflows.health',{'project':project});initialApprovals=rpc('inbox.list',{'project':project})
  def open_form():
   click('.nav-link[data-page="workflows"]');wait('document.querySelector(".nav-link.active")?.dataset.page==="workflows"','workflows page unavailable');click('.tab-btn[data-wftab="runs"]');row='tr.clickable-row[data-id="'+run+'"]';wait('!!document.querySelector('+json.dumps(row)+')','fixture run not rendered');click(row);wait('window.__rfVisible("#btn-open-run-feedback")','missingUI: actual terminal run detail has no #btn-open-run-feedback');before=len(calls('runs.feedback.prepare'));click('#btn-open-run-feedback');wait('window.__rfVisible("#run-feedback-review")','missingUI: click did not open #run-feedback-review');wait('window.__rfVisible("#run-feedback-outcome")&&window.__rfVisible("#run-feedback-reason")&&window.__rfVisible("#btn-save-run-feedback")','missingUI: feedback form controls absent');wait('window.__rfCalls.filter(x=>x.method==="runs.feedback.prepare").length>'+str(before),'prepare absent');got=calls('runs.feedback.prepare')[-1];assert got['params']=={'project':project,'runId':run},'prepare shape/project incorrect';b('screenshot',str(out/'feedback-form-open.png'));return got['result']
  def first():
   pre=open_form();assert not calls('runs.feedback.record'),'open wrote feedback';click('#btn-cancel-run-feedback');wait('!window.__rfVisible("#run-feedback-review")','cancel failed');assert not calls('runs.feedback.record'),'cancel wrote feedback'
   for loc in('en','zh-CN'):
    v('VelaI18n.setLocale('+json.dumps(loc)+');document.dispatchEvent(new Event("vela:locale"));true');open_form();assert v('document.querySelector("#run-feedback-outcome")?.labels?.[0]?.textContent.trim().length>0'),'missingUI: unlabelled localized select';click('#btn-cancel-run-feedback')
   return {'prepareCancelZeroWrite':True,'locales':['en','zh-CN'],'runHashLength':len(pre['runHash']),'formScreenshot':'feedback-form-open.png'}
  def revisions():
   pre=open_form();rows=[]
   for outcome,reason in [('good','Synthetic Git review useful.'),('bad','Synthetic reviewer corrected observation.'),('clear','Synthetic reviewer withdrew observation.')]:
    b('select','#run-feedback-outcome',outcome);b('fill','#run-feedback-reason',reason);click('#btn-save-run-feedback');wait('window.__rfCalls.filter(x=>x.method==="runs.feedback.record"&&!x.error).length>'+str(len(rows)),'record missing');rows.append(calls('runs.feedback.record')[-1]['result']);
    if outcome!='clear':click('#btn-open-run-feedback');wait('window.__rfVisible("#run-feedback-review")','reopen feedback form failed')
   assert [x['revision']for x in rows]==[1,2,3]and rows[-1]['outcome']=='clear','good→bad→clear revisions wrong'
   latest=rows[-1]
   for revision in range(4,23):
    latest=rpc('runs.feedback.record',{'project':project,'runId':run,'runHash':pre['runHash'],'previousFeedbackHash':latest['feedbackHash'],'outcome':'good' if revision%2==0 else 'clear','reason':'Synthetic history revision '+str(revision)+'.'})
   wait('window.__rfVisible("#btn-run-feedback-history")','missingUI: history button absent');click('#btn-run-feedback-history');wait('window.__rfVisible("#run-feedback-history")','missingUI: history pane absent');wait('window.__rfCalls.some(x=>x.method==="runs.feedback.history.list")','history list absent');hist=calls('runs.feedback.history.list')[-1]['result'];assert len(hist['items'])==20 and hist.get('cursor'),'history fixture must require a second page';
   item='#run-feedback-history [data-history-id="'+hist['items'][0]['historyId']+'"]';wait('!!document.querySelector('+json.dumps(item)+')','missingUI: history entry lacks an operable data-history-id detail control');click(item);wait('window.__rfCalls.some(x=>x.method==="runs.feedback.history.get")','history get detail call absent')
   if hist.get('cursor'):wait('window.__rfVisible("#btn-more-run-feedback-history")','missingUI: pagination button absent');click('#btn-more-run-feedback-history');wait('window.__rfCalls.filter(x=>x.method==="runs.feedback.history.list").length>=2','history page two absent')
   assert rpc('runs.get',{'id':run})==initialRun,'feedback changed run';assert rpc('workflows.health',{'project':project})['successRate']==initialHealth['successRate'],'feedback changed successRate';assert rpc('inbox.list',{'project':project})==initialApprovals,'feedback changed approval';return {'revisions':[1,2,3],'historyListAndPagination':True,'historyGetRequiredByUI21':True,'objectiveUnchanged':True}
  def stale():
   pre=open_form();b('select','#run-feedback-outcome','good');b('fill','#run-feedback-reason','Synthetic stale UI draft.');rpc('runs.feedback.record',{'project':project,'runId':run,'runHash':pre['runHash'],'previousFeedbackHash':pre['feedback']['feedbackHash']if pre.get('feedback')else None,'outcome':'bad','reason':'Synthetic competing current revision.'});before=len(calls('runs.feedback.record'));click('#btn-save-run-feedback');wait('window.__rfCalls.filter(x=>x.method==="runs.feedback.record").length>'+str(before),'stale save did not reach bridge');wait('window.__rfVisible("#run-feedback-review")','stale error must preserve draft');assert len(calls('runs.feedback.record'))==before+1,'UI retried stale write'
   b('fill','#run-feedback-reason','Synthetic pending write.');starts=len(v('window.__rfStarted.filter(x=>x.method==="runs.feedback.record")'));v('window.__rfBeforeHold="runs.feedback.record";true');click('#btn-save-run-feedback');wait('window.__rfHeld===true','pre-call save hold failed');v('(()=>{const x=document.querySelector("#btn-save-run-feedback");if(x&&!x.disabled)x.click();return true})()');assert len(v('window.__rfStarted.filter(x=>x.method==="runs.feedback.record")'))==starts+1,'pending double click started another write';b('press','Escape');b('select','#project-selector',beacon);v('window.__rfRelease();true');wait('window.__rfHeld===false','late save release failed');assert not v('window.__rfVisible("#run-feedback-review")'),'late project change reopened stale form';return {'staleCASNoRetry':True,'pendingDoubleClickCoalesced':True,'lateProjectAndRunDiscarded':True}
  check('prepare-cancel-locales',first);check('revision-history-objective',revisions);check('stale-lifecycle',stale)
  ev['uiAfter']={x:sha(ui/x)for x in FILES};ev['helperAfter']=sha(binary);ev['harnessAfter']={x.name:sha(x)for x in harness};ev['harnessUnchanged']=ev['harnessBefore']==ev['harnessAfter'];ev['sourceUnchanged']=ev['uiBefore']==ev['uiFixture']==ev['uiAfter']and ev['helperBefore']==ev['helperFixture']==ev['helperAfter']and ev['harnessUnchanged'];ev['selectedChecksPassed']=len(ev['checks'])==len(chosen)and all(x['passed']for x in ev['checks']);ev['completeSuite']=set(chosen)==set(CHECKS)and ev['selectedChecksPassed']and ev['sourceUnchanged']and not any(x.get('pageErrors')for x in ev['checks']);save()
  if not ev['completeSuite']:raise SystemExit(1)
 finally:
  try:
   if driver:b('close')
  except:pass
  if server:
   server.send_signal(signal.SIGTERM)
   try:server.wait(timeout=8)
   except subprocess.TimeoutExpired:server.kill();server.wait()
  for n in('harness-rpc.jsonl','fixture.json'):
   if base.exists()and(base/n).is_file()and not(base/n).is_symlink():shutil.copyfile(base/n,out/n);ev.setdefault('retainedEvidenceSHA256',{})[n]=sha(out/n)
  if base.exists()and not base.is_symlink()and(base/'store/.vela-ui-fixture.json').is_file():shutil.rmtree(base);ev['fixtureRemoved']=True
  else:ev['fixtureRemoved']=False
  save()
if __name__=='__main__':main()
