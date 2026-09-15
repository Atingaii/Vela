#!/usr/bin/env python3
"""A delayed real feedback prepare must not overwrite the user's in-flight edit."""
import argparse,hashlib,importlib.util,json,os,select,shutil,signal,subprocess,time,traceback
from pathlib import Path
from release_resources import DEVELOPMENT_UI_RESOURCES, UI_RESOURCES, copy_ui_resources
ROOT=Path(__file__).resolve().parents[1]; FILES=UI_RESOURCES + DEVELOPMENT_UI_RESOURCES
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def evaluate_gate(evidence):
 diagnosis=evidence.get('diagnosis') if isinstance(evidence.get('diagnosis'),dict) else {}
 expected={'sameControlNode':True,'userValueBeforeRelease':'clear','valueAfterPrepareContinuation':'clear','delayedPrepareOverwroteUserSelection':False}
 failures=[key+'='+repr(diagnosis.get(key)) for key,value in expected.items() if diagnosis.get(key)!=value]
 if evidence.get('pageErrors')!=[]: failures.append('pageErrors='+repr(evidence.get('pageErrors')))
 if evidence.get('serverStopped') is not True: failures.append('serverStopped='+repr(evidence.get('serverStopped')))
 if evidence.get('fixtureRemoved') is not True: failures.append('fixtureRemoved='+repr(evidence.get('fixtureRemoved')))
 if evidence.get('sourceUnchanged') is not True: failures.append('sourceUnchanged='+repr(evidence.get('sourceUnchanged')))
 return {'passed':not failures,'expected':expected,'failures':failures}
def main():
 p=argparse.ArgumentParser();p.add_argument('--ui-directory',type=Path,required=True);p.add_argument('--binary',type=Path,required=True);p.add_argument('--fixture',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--browser-executable',type=Path,required=True);a=p.parse_args()
 ui,binary=a.ui_directory.resolve(strict=True),a.binary.resolve(strict=True);base,out=a.fixture.absolute(),a.output.absolute()
 if base.exists() or base.is_symlink() or base.parent!=(ROOT/'.task-tmp').resolve():p.error('new immediate owned fixture required')
 if out.exists() or out.is_symlink() or out.parent.resolve()!=(ROOT/'output/playwright').resolve():p.error('new output/playwright child required')
 if any(not(ui/n).is_file() or(ui/n).is_symlink() for n in FILES) or not a.browser_executable.is_file() or not shutil.which('node'):p.error('frozen UI, browser and Node required')
 out.mkdir(parents=True);(out/'consumer-test-source.py').write_bytes(Path(__file__).read_bytes());ev={'format':'vela-feedback-prepare-race-gate-v2','status':'failed','synthetic':True,'providerRuns':0,'checks':[]};server=driver=None;failure=None
 def save():(out/'results.json').write_text(json.dumps(ev,ensure_ascii=False,indent=2)+'\n')
 def b(*x):
  driver.stdin.write(json.dumps(x)+'\n');driver.stdin.flush();assert select.select([driver.stdout],[],[],20)[0],'browser timeout';z=json.loads(driver.stdout.readline());assert 'error' not in z,z;return z.get('output','')
 def v(x):return json.loads(b('eval',x))
 def wait(x,msg):
  end=time.monotonic()+10
  while time.monotonic()<end:
   if v(x):return
   time.sleep(.05)
  raise AssertionError(msg)
 def click(x):b('click',x);b('snapshot','-i')
 try:
  harness=(ROOT/'scripts/test-ui-server.py',ROOT/'scripts/create-ui-fixture.py',ROOT/'scripts/test-ui-browser.py');ev['uiBefore']={n:sha(ui/n) for n in FILES};ev['helperBefore']=sha(binary);ev['harnessBefore']={x.name:sha(x) for x in harness}
  made=subprocess.run(['python3',str(ROOT/'scripts/create-ui-fixture.py'),str(base),'--binary',str(binary),'--with-routing-project'],cwd=ROOT,text=True,capture_output=True,timeout=120);(out/'fixture-creation.log').write_text(made.stdout+made.stderr);made.check_returncode();fx=json.loads((base/'fixture.json').read_text());project,run=fx['project'],fx['completedRun']
  snap,helper=base/'ui-snapshot',base/'vela-frozen';copy_ui_resources(ui,snap,allow_development=True);shutil.copy2(binary,helper);ev['uiFixture']={n:sha(snap/n) for n in FILES};ev['helperFixture']=sha(helper)
  # Seed an actual current feedback so UI21's prepare continuation has a prefill value.
  direct=lambda m,x:subprocess.run([str(helper),'call',m,json.dumps(x),'--home',fx['home']],cwd=Path(project),text=True,capture_output=True,timeout=25)
  prep=direct('runs.feedback.prepare',{'project':project,'runId':run});assert prep.returncode==0,prep.stderr;prepared=json.loads(prep.stdout);seed=direct('runs.feedback.record',{'project':project,'runId':run,'runHash':prepared['runHash'],'previousFeedbackHash':None,'outcome':'bad','reason':'Synthetic delayed-prefill seed.'});assert seed.returncode==0,seed.stderr
  spec=importlib.util.spec_from_file_location('d',ROOT/'scripts/test-ui-browser.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);src=mod.PLAYWRIGHT_DRIVER.replace("const page=await browser.newPage({viewport:{width:1280,height:720}});page.setDefaultTimeout(5000);","const page=await browser.newPage({viewport:{width:1280,height:720}});await page.addInitScript(()=>{window.__diagErrors=[];addEventListener('error',e=>window.__diagErrors.push(e.message));addEventListener('unhandledrejection',e=>window.__diagErrors.push(String(e.reason)))});page.setDefaultTimeout(5000);")
  server=subprocess.Popen(['python3',str(ROOT/'scripts/test-ui-server.py'),str(base/'fixture.json'),'--binary',str(helper),'--ui-directory',str(snap)],cwd=ROOT,stdout=subprocess.PIPE,text=True,start_new_session=True);assert select.select([server.stdout],[],[],15)[0],'server start';url=json.loads(server.stdout.readline())['url'];pw=ROOT/'.task-tmp/ui-browser-tools/node_modules/playwright/index.js';assert pw.is_file();driver=subprocess.Popen(['node','-e',src,str(pw),str(a.browser_executable)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,start_new_session=True);b('open',url);b('wait','#project-selector');b('select','#project-selector',project)
  v("""window.__diag={events:[],hold:true};window.__diagValue=()=>{const e=document.querySelector('#run-feedback-outcome');if(e&&!e.dataset.diagNode)e.dataset.diagNode='node-'+Math.random().toString(36).slice(2);return e?{node:e.dataset.diagNode,value:e.value,disabled:e.disabled}:null};window.__diagMark=phase=>window.__diag.events.push({phase,t:performance.now(),control:window.__diagValue()});window.__diagOriginal=window.vela.call;window.vela.call=async(m,x={})=>{if(m==='runs.feedback.prepare'&&window.__diag.hold){window.__diagMark('prepare-enter-held');await new Promise(ok=>window.__diagRelease=ok);window.__diagMark('prepare-released-before-real-call')}const r=await window.__diagOriginal(m,x);if(m==='runs.feedback.prepare')window.__diagMark('prepare-real-response-before-ui-continuation');return r};true""")
  click('.nav-link[data-page="workflows"]');wait('document.querySelector(".nav-link.active")?.dataset.page==="workflows"','workflows unavailable');click('.tab-btn[data-wftab="runs"]');row='tr.clickable-row[data-id="'+run+'"]';wait('!!document.querySelector('+json.dumps(row)+')','run missing');click(row);wait('!!document.querySelector("#btn-open-run-feedback")','feedback entry missing');click('#btn-open-run-feedback');wait('window.__diag.events.some(x=>x.phase==="prepare-enter-held")','prepare was not actually held');wait('!!document.querySelector("#run-feedback-outcome")','form control missing while prepare pending')
  v('window.__diagMark("user-before-clear");true');b('select','#run-feedback-outcome','clear');v('window.__diagMark("user-after-clear");true');assert v('window.__diagValue().value==="clear"'),'user clear selection did not settle';b('screenshot',str(out/'prepare-pending-user-clear.png'));(out/'prepare-pending-user-clear.txt').write_text(b('snapshot','-i'))
  v('window.__diagRelease();true');wait('window.__diag.events.some(x=>x.phase==="prepare-real-response-before-ui-continuation")','real prepare response did not arrive');time.sleep(.15);v('window.__diagMark("after-ui-continuation");true');b('screenshot',str(out/'prepare-released.png'));(out/'prepare-released.txt').write_text(b('snapshot','-i'));ev['events']=v('window.__diag.events');ev['pageErrors']=v('window.__diagErrors');before=next(x for x in ev['events'] if x['phase']=='user-after-clear')['control'];after=next(x for x in ev['events'] if x['phase']=='after-ui-continuation')['control'];ev['diagnosis']={'sameControlNode':before and after and before['node']==after['node'],'userValueBeforeRelease':before['value'],'valueAfterPrepareContinuation':after['value'],'delayedPrepareOverwroteUserSelection':bool(before and after and before['value']=='clear' and after['value']=='bad')}
 except Exception as e:
  failure=type(e).__name__+': '+str(e);ev['failure']=failure;ev['status']='failed';ev['traceback']=traceback.format_exc(limit=6)
 finally:
  try:
   if driver:b('close');driver.wait(timeout=8)
  except Exception:
   if driver and driver.poll() is None:os.killpg(driver.pid,signal.SIGKILL);driver.wait()
  if server:
   if server.poll() is None:server.send_signal(signal.SIGTERM)
   try:server.wait(timeout=8)
   except subprocess.TimeoutExpired:os.killpg(server.pid,signal.SIGKILL);server.wait()
   ev['serverStopped']=server.poll() is not None
  for n in ('harness-rpc.jsonl','fixture.json'):
   if base.exists() and(base/n).is_file()and not(base/n).is_symlink():shutil.copyfile(base/n,out/n);ev.setdefault('retainedEvidenceSHA256',{})[n]=sha(out/n)
  if base.exists()and not base.is_symlink():shutil.rmtree(base)
  ev['fixtureRemoved']=not base.exists();ev['uiAfter']={n:sha(ui/n) for n in FILES};ev['helperAfter']=sha(binary);ev['harnessAfter']={x.name:sha(x) for x in harness};ev['sourceUnchanged']=ev.get('uiBefore')==ev.get('uiFixture')==ev.get('uiAfter')and ev.get('helperBefore')==ev.get('helperFixture')==ev.get('helperAfter')and ev.get('harnessBefore')==ev.get('harnessAfter');ev['gate']=evaluate_gate(ev)
  if failure is None and ev['gate']['passed']:ev['status']='passed'
  else:
   ev['status']='failed'
   if failure is None:
    failure='prepare-race gate failed: '+', '.join(ev['gate']['failures']);ev['failure']=failure
  save()
 if failure or ev['status']!='passed':raise SystemExit(1)
if __name__=='__main__':main()
