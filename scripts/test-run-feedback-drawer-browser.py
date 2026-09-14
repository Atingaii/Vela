#!/usr/bin/env python3
"""Focused renderer gate for feedback drawer reads, late continuations, and 1200px layout."""
import argparse, hashlib, importlib.util, json, os, select, shutil, signal, subprocess, time, traceback
from pathlib import Path
from release_resources import DEVELOPMENT_UI_RESOURCES, UI_RESOURCES, copy_ui_resources
ROOT=Path(__file__).resolve().parents[1]
FILES=UI_RESOURCES + DEVELOPMENT_UI_RESOURCES
CHECKS=('drawer-read-edit-stale','drawer-unavailable','drawer-stale-lifecycle','wide-drawer-header')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--ui-directory',type=Path,required=True);p.add_argument('--binary',type=Path,required=True);p.add_argument('--fixture',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--browser-executable',type=Path,required=True);a=p.parse_args()
 ui,binary=a.ui_directory.resolve(strict=True),a.binary.resolve(strict=True);base,out=a.fixture.absolute(),a.output.absolute()
 if base.exists()or base.is_symlink()or base.parent.resolve()!=(ROOT/'.task-tmp').resolve():p.error('fixture must be a new immediate .task-tmp child')
 if out.exists()or out.is_symlink()or out.parent.resolve()!=(ROOT/'output/playwright').resolve():p.error('output must be a new output/playwright child')
 if not a.browser_executable.is_file()or not shutil.which('node')or any(not(ui/x).is_file()or(ui/x).is_symlink()for x in FILES):p.error('frozen UI, Chrome and Node required')
 out.mkdir(parents=True);out.joinpath('consumer-test-source.py').write_bytes(Path(__file__).read_bytes());ev={'format':'vela-run-feedback-drawer-renderer-r5','status':'failed','synthetic':True,'providerRuns':0,'checks':[],'controlledTransport':[]};server=driver=None;failure=None
 def save():out.joinpath('results.json').write_text(json.dumps(ev,ensure_ascii=False,indent=2)+'\n')
 def b(*x):
  driver.stdin.write(json.dumps(x)+'\n');driver.stdin.flush();assert select.select([driver.stdout],[],[],20)[0],'bounded Playwright wait elapsed';z=json.loads(driver.stdout.readline());assert'error'not in z,z;return z.get('output','')
 def v(x):return json.loads(b('eval',x))
 def wait(x,msg,seconds=12):
  end=time.monotonic()+seconds
  while time.monotonic()<end:
   if v(x):return
   time.sleep(.06)
  raise AssertionError(msg)
 def click(x):b('click',x);b('snapshot','-i')
 def shot(n):b('screenshot',str(out/(n+'.png')));(out/(n+'.txt')).write_text(b('snapshot','-i'))
 def direct(method,params):
  z=subprocess.run([str(helper),'call',method,json.dumps(params),'--home',fx['home']],cwd=project,text=True,capture_output=True,timeout=30)
  if z.returncode:raise RuntimeError(method+' real helper failed: '+z.stderr.strip())
  return json.loads(z.stdout)
 try:
  harness=(ROOT/'scripts/test-ui-server.py',ROOT/'scripts/create-ui-fixture.py',ROOT/'scripts/test-ui-browser.py',Path(__file__));ev['uiBefore']={x:sha(ui/x)for x in FILES};ev['helperBefore']=sha(binary);ev['harnessBefore']={x.name:sha(x)for x in harness}
  made=subprocess.run(['python3',str(ROOT/'scripts/create-ui-fixture.py'),str(base),'--binary',str(binary),'--with-routing-project'],cwd=ROOT,text=True,capture_output=True,timeout=120);out.joinpath('fixture-creation.log').write_text(made.stdout+made.stderr);made.check_returncode();fx=json.loads((base/'fixture.json').read_text());project,beacon,run_a=fx['project'],fx['routingProject'],fx['completedRun']
  snap,helper=base/'ui-snapshot',base/'vela-frozen';copy_ui_resources(ui,snap,allow_development=True);shutil.copy2(binary,helper);ev['uiFixture']={x:sha(snap/x)for x in FILES};ev['helperFixture']=sha(helper)
  wf=direct('workflows.save',{'project':project,'title':'Drawer stale target B','trigger':'manual','steps':[{'title':'Read fixture Git state','tool':'git.status','arguments':{}}]});run_b=direct('workflows.run',{'id':wf['id'],'dryRun':False});assert run_b['state']=='completed','second real terminal run did not complete';run_b=run_b['id']
  def seed(run,reason,outcome='good'):
   prep=direct('runs.feedback.prepare',{'project':project,'runId':run});return direct('runs.feedback.record',{'project':project,'runId':run,'runHash':prep['runHash'],'previousFeedbackHash':(prep.get('feedback')or{}).get('feedbackHash'),'outcome':outcome,'reason':reason})
  seed(run_a,'DRAWER_INITIAL_REAL_RESPONSE');seed(run_b,'DRAWER_CURRENT_RUN_B_RESPONSE')
  spec=importlib.util.spec_from_file_location('driver',ROOT/'scripts/test-ui-browser.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
  src=mod.PLAYWRIGHT_DRIVER.replace("else if(command==='screenshot')await page.screenshot({path:args[0]});","else if(command==='resize')await page.setViewportSize({width:args[0],height:args[1]});else if(command==='screenshot')await page.screenshot({path:args[0]});").replace("const page=await browser.newPage({viewport:{width:1280,height:720}});page.setDefaultTimeout(5000);","const page=await browser.newPage({viewport:{width:1280,height:720}});await page.addInitScript(()=>{window.__drawerErrors=[];addEventListener('error',e=>window.__drawerErrors.push(e.message));addEventListener('unhandledrejection',e=>window.__drawerErrors.push(String(e.reason)))});page.setDefaultTimeout(5000);")
  pw=ROOT/'.task-tmp/ui-browser-tools/node_modules/playwright/index.js';assert pw.is_file(),'pinned Playwright missing'
  server=subprocess.Popen(['python3',str(ROOT/'scripts/test-ui-server.py'),str(base/'fixture.json'),'--binary',str(helper),'--ui-directory',str(snap)],cwd=ROOT,stdout=subprocess.PIPE,text=True,start_new_session=True);assert select.select([server.stdout],[],[],15)[0],'server start';url=json.loads(server.stdout.readline())['url'];driver=subprocess.Popen(['node','-e',src,str(pw),str(a.browser_executable)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,start_new_session=True);b('open',url);b('wait','#project-selector');b('select','#project-selector',project)
  v(r'''(()=>{window.__drawerCalls=[];window.__drawerControl=null;window.__drawerBase=window.vela.call;window.__drawerVisible=s=>{const e=document.querySelector(s);return!!e&&e.getClientRects().length>0};window.__drawerArm=(kind,runId)=>window.__drawerControl={kind,runId,used:false,held:false,settled:false,realResponse:false};window.__drawerRelease=()=>{const c=window.__drawerControl;if(c&&c.release)c.release();return true};window.vela.call=async(m,x={})=>{const r=await window.__drawerBase(m,x),c=window.__drawerControl,hit=m==='runs.feedback.prepare'&&c&&!c.used&&x.runId===c.runId;window.__drawerCalls.push({method:m,params:x,result:r,controlled:!!hit,kind:hit?c.kind:null});if(!hit)return r;c.used=true;c.realResponse=true;c.params=x;if(c.kind==='hold'){c.held=true;await new Promise(ok=>c.release=ok);c.held=false;c.settled=true;return r}c.settled=true;if(c.kind==='error')throw Error('controlled drawer prepare transport error');if(c.kind==='malformed')return {feedback:{outcome:'not-an-outcome'}};throw Error('unknown controlled transport')};return true})()''')
  def openrun(run,title=None):
   click('.nav-link[data-page="workflows"]');wait('document.querySelector(".nav-link.active")?.dataset.page==="workflows"','workflows page unavailable');runs_tab='.tab-btn[data-wftab="runs"]';wait('!!document.querySelector('+json.dumps(runs_tab)+')?.getClientRects().length','runs tab did not become visible');
   if not v('document.querySelector('+json.dumps(runs_tab)+').classList.contains("active")'):click(runs_tab)
   row='#main-content #workflow-runs-table tbody tr.clickable-row[data-id="'+run+'"]';wait('!!document.querySelector('+json.dumps(row)+')?.getClientRects().length','actual main run row did not become visible');click(row);wait('window.__drawerVisible("#detail-drawer")','drawer did not open')
   if title:wait('document.querySelector("#drawer-title")?.textContent.includes('+json.dumps(title)+')','drawer title did not bind current run')
  def close():
   if v('window.__drawerVisible("#detail-drawer")'):click('#btn-close-drawer');wait('!window.__drawerVisible("#detail-drawer")','drawer close failed')
  def held(label):
   wait('window.__drawerControl&&window.__drawerControl.held===true',label);c=v('window.__drawerControl');assert c['realResponse']and c['params']=={'project':project,'runId':run_a},'held item was not an actual exact drawer response';return c
  def check(name,fn):
   item={'check':name,'passed':False}
   try:
    item.update(fn()or{});item['pageErrors']=v('window.__drawerErrors||[]');assert not item['pageErrors'],'page errors: '+json.dumps(item['pageErrors']);item['passed']=True
   except Exception as e:item['error']=str(e);item['traceback']=traceback.format_exc(limit=6)
   finally:
    try:v('window.__drawerRelease()');close()
    except:pass
    shot(name);ev['checks'].append(item);save();print(json.dumps(item,ensure_ascii=False),flush=True)
  def initial_edit():
   close();seed(run_a,'DRAWER_INITIAL_REAL_RESPONSE');v('window.__drawerArm("hold",'+json.dumps(run_a)+')');openrun(run_a,'Review the current change');c=held('initial drawer read not held after real response');click('#btn-open-run-feedback');wait('window.__drawerVisible("#run-feedback-review")','editor did not open');wait('document.querySelector("#run-feedback-original-state")?.textContent.trim().length>0','modal actual prepare did not settle');b('select','#run-feedback-outcome','bad');b('fill','#run-feedback-reason','DRAWER_EDITED_NEW_REASON');wait('document.querySelector("#btn-save-run-feedback")?.disabled===false','save disabled');before=v('window.__drawerCalls.filter(x=>x.method==="runs.feedback.record").length');click('#btn-save-run-feedback');wait('window.__drawerCalls.filter(x=>x.method==="runs.feedback.record").length>'+str(before),'record missing');wait('document.querySelector("#run-feedback-card-content")?.innerText.includes("DRAWER_EDITED_NEW_REASON")','save did not update card');v('window.__drawerRelease()');wait('window.__drawerControl.settled===true','held read did not settle');wait('document.querySelector("#run-feedback-card-content")?.innerText.includes("DRAWER_EDITED_NEW_REASON")','late initial response overwrote new edit');assert not v('document.querySelector("#run-feedback-card-content")?.innerText.includes("DRAWER_INITIAL_REAL_RESPONSE")'),'old reason returned after release';return {'heldRealResponse':c,'newReasonVisibleAfterRelease':True,'oldReasonAbsent':True}
  def unavailable():
   details=[]
   for kind in('error','malformed'):
    close();v('window.__drawerArm('+json.dumps(kind)+','+json.dumps(run_a)+')');openrun(run_a);wait('window.__drawerControl&&window.__drawerControl.settled===true',kind+' transport did not settle');sel='[data-i18n="runs.feedback.currentUnavailable"]';wait('window.__drawerVisible('+json.dumps(sel)+')',kind+' did not render currentUnavailable');d=v('(()=>{const e=document.querySelector('+json.dumps(sel)+');return {text:(e?.textContent||"").trim(),html:(e?.innerHTML||"").trim(),card:(document.querySelector("#run-feedback-card-content")?.textContent||"").trim()}})()');assert d['text']and d['html']and d['card'],kind+' rendered empty unavailable state';details.append({'kind':kind,'realResponseBeforeControl':True,'unavailable':d});shot('drawer-unavailable-'+kind)
   ev['controlledTransport']+=details;return {'controlledResponses':details,'nonEmptyCurrentUnavailable':True}
  def stale():
   cases=[]
   close();seed(run_a,'STALE_PROJECT_RESPONSE');v('window.__drawerArm("hold",'+json.dumps(run_a)+')');openrun(run_a);held('project hold absent');b('select','#project-selector',beacon);wait('document.querySelector("#project-selector")?.value==='+json.dumps(beacon),'project did not settle');v('window.__drawerRelease()');wait('window.__drawerControl.settled===true','project hold did not settle');d=v('(()=>{const x=document.querySelector("#detail-drawer"),c=document.querySelector("#run-feedback-card-content");return {hidden:!!x?.classList.contains("hidden"),card:c?.innerText||""}})()');assert 'STALE_PROJECT_RESPONSE'not in d['card'],'late old project response wrote current view';cases.append({'case':'project','stateAfterRelease':d})
   b('select','#project-selector',project);wait('document.querySelector("#project-selector")?.value==='+json.dumps(project),'Harbor did not settle');close();seed(run_a,'STALE_RUN_A_RESPONSE');v('window.__drawerArm("hold",'+json.dumps(run_a)+')');openrun(run_a);held('run hold absent');close();openrun(run_b,'Drawer stale target B');wait('document.querySelector("#run-feedback-card-content")?.innerText.includes("DRAWER_CURRENT_RUN_B_RESPONSE")','current run B response missing');v('window.__drawerRelease()');wait('window.__drawerControl.settled===true','run hold did not settle');d=v('(()=>({title:document.querySelector("#drawer-title")?.textContent||"",card:document.querySelector("#run-feedback-card-content")?.innerText||""}))()');assert 'STALE_RUN_A_RESPONSE'not in d['card']and'Drawer stale target B'in d['title'],'late A response overwrote B';cases.append({'case':'run','stateAfterRelease':d})
   close();seed(run_a,'STALE_CLOSE_RESPONSE');v('window.__drawerArm("hold",'+json.dumps(run_a)+')');openrun(run_a);held('close hold absent');close();v('window.__drawerRelease()');wait('window.__drawerControl.settled===true','close hold did not settle');d=v('(()=>{const x=document.querySelector("#detail-drawer"),c=document.querySelector("#run-feedback-card-content");return {hidden:!!x?.classList.contains("hidden"),card:c?.innerText||""}})()');assert d['hidden']and'STALE_CLOSE_RESPONSE'not in d['card'],'late closed drawer response updated content';cases.append({'case':'close','stateAfterRelease':d});return {'lateLifecycleCases':cases,'allLateResponsesDiscarded':True}
  def wide():
   b('resize',1200,800);b('select','#project-selector',project);openrun(run_a,'Review the current change');wait('window.__drawerVisible("#btn-open-run-feedback")&&window.__drawerVisible("#btn-run-feedback-history")','feedback actions absent');allboxes=[]
   for loc in('zh-CN','en'):
    v('VelaI18n.setLocale('+json.dumps(loc)+');document.dispatchEvent(new Event("vela:locale"));true');wait('document.querySelector("#btn-open-run-feedback")?.textContent.trim().length>0',loc+' action label empty');d=v('(()=>{const r=e=>{const x=e.getBoundingClientRect();return {left:x.left,right:x.right,top:x.top,bottom:x.bottom,width:x.width,height:x.height}};const a=document.querySelector("#drawer-custom-actions"),h=document.querySelector(".drawer-header"),dr=document.querySelector("#detail-drawer"),m=document.querySelector("#main-content"),t=document.querySelector("#drawer-title"),w=document.querySelector("#workflow-runs-table"),wrap=w?.closest(".table-wrapper");return {viewport:{width:innerWidth},drawer:r(dr),main:r(m),mainInert:!!m?.inert,mainVisibility:m?getComputedStyle(m).visibility:null,title:r(t),actions:r(a),header:r(h),buttons:[...a.querySelectorAll("button")].map(r),table:w&&r(w),wrapper:wrap&&{rect:r(wrap),scrollWidth:wrap.scrollWidth,clientWidth:wrap.clientWidth}}})()');inside=lambda x,o:x['left']>=o['left']-1 and x['right']<=o['right']+1 and x['top']>=o['top']-1 and x['bottom']<=o['bottom']+1;overlap=not(d['title']['right']<=d['actions']['left']or d['actions']['right']<=d['title']['left']or d['title']['bottom']<=d['actions']['top']or d['actions']['bottom']<=d['title']['top']);assert d['viewport']['width']==1200 and d['mainInert'] and d['mainVisibility']=='hidden' and inside(d['title'],d['header'])and inside(d['actions'],d['header'])and all(inside(x,d['drawer'])and x['width']>4 for x in d['buttons'])and not overlap,'detail header escapes or overlaps: '+json.dumps(d);assert d['table']and d['wrapper']and d['table']['width']>=899 and d['wrapper']['scrollWidth']>=d['table']['width']and d['wrapper']['scrollWidth']>d['wrapper']['clientWidth'],'runs table lacks visible bounded horizontal overflow at 1200: '+json.dumps(d);layout=v(r'''(()=>{const wrap=document.querySelector('#workflow-runs-table')?.closest('.table-wrapper'),row=document.querySelector('#workflow-runs-table tbody tr');if(!wrap||!row)return null;const r=e=>{const x=e.getBoundingClientRect();return {left:x.left,right:x.right,top:x.top,bottom:x.bottom,width:x.width,height:x.height}};const initial={wrap:r(wrap),cells:[...row.cells].map(r),badges:[...row.querySelectorAll('.code-badge,.status-badge')].map(e=>({box:r(e),cell:[...row.cells].findIndex(c=>c.contains(e))}))};wrap.scrollLeft=wrap.scrollWidth;const action=row.querySelector('.btn-replay-run');const final={wrap:r(wrap),scrollLeft:wrap.scrollLeft,action:action&&r(action)};return {initial,final}})()''');assert layout and all(layout['initial']['cells'][i]['right']<=layout['initial']['cells'][i+1]['left']+1 for i in range(len(layout['initial']['cells'])-1)) and all(b['cell']>=0 and b['box']['left']>=layout['initial']['cells'][b['cell']]['left']-1 and b['box']['right']<=layout['initial']['cells'][b['cell']]['right']+1 for b in layout['initial']['badges']),'run table columns or status/code badges overlap: '+json.dumps(layout);assert layout['final']['scrollLeft']>0 and layout['final']['action'] and layout['final']['action']['left']>=layout['final']['wrap']['left']-1 and layout['final']['action']['right']<=layout['final']['wrap']['right']+1,'right-side replay action remains clipped after horizontal scroll: '+json.dumps(layout);allboxes.append({'locale':loc,'box':d,'tableLayout':layout});shot('wide-drawer-header-'+loc)
   return {'viewport':'1200x800','locales':allboxes,'mainContentInertAndHidden':True,'runsTableHorizontalOverflow':True}
  check('drawer-read-edit-stale',initial_edit);check('drawer-unavailable',unavailable);check('drawer-stale-lifecycle',stale);check('wide-drawer-header',wide)
  ev['pageErrors']=v('window.__drawerErrors||[]');ev['uiAfter']={x:sha(ui/x)for x in FILES};ev['helperAfter']=sha(binary);ev['harnessAfter']={x.name:sha(x)for x in harness};ev['sourceUnchanged']=ev['uiBefore']==ev['uiFixture']==ev['uiAfter']and ev['helperBefore']==ev['helperFixture']==ev['helperAfter']and ev['harnessBefore']==ev['harnessAfter'];ev['completeSuite']=len(ev['checks'])==len(CHECKS)and all(x['passed']for x in ev['checks'])and not ev['pageErrors']and ev['sourceUnchanged'];ev['status']='passed'if ev['completeSuite']else'failed'
 except Exception as e:failure=type(e).__name__+': '+str(e);ev['failure']=failure;ev['traceback']=traceback.format_exc(limit=8);ev['status']='failed'
 finally:
  try:
   if driver:b('close');driver.wait(timeout=8)
  except:
   if driver and driver.poll()is None:os.killpg(driver.pid,signal.SIGKILL);driver.wait()
  if server:
   if server.poll()is None:server.send_signal(signal.SIGTERM)
   try:server.wait(timeout=8)
   except subprocess.TimeoutExpired:os.killpg(server.pid,signal.SIGKILL);server.wait()
   ev['serverStopped']=server.poll()is not None
  for name in('harness-rpc.jsonl','fixture.json'):
   x=base/name
   if x.is_file()and not x.is_symlink():shutil.copyfile(x,out/name);ev.setdefault('retainedEvidenceSHA256',{})[name]=sha(out/name)
  if base.exists()and not base.is_symlink():shutil.rmtree(base)
  ev['fixtureRemoved']=not base.exists();ev.setdefault('uiAfter',{x:sha(ui/x)for x in FILES});ev.setdefault('helperAfter',sha(binary));ev.setdefault('harnessAfter',{x.name:sha(x)for x in (ROOT/'scripts/test-ui-server.py',ROOT/'scripts/create-ui-fixture.py',ROOT/'scripts/test-ui-browser.py',Path(__file__))});ev['sourceUnchanged']=ev.get('uiBefore')==ev.get('uiFixture')==ev.get('uiAfter')and ev.get('helperBefore')==ev.get('helperFixture')==ev.get('helperAfter')and ev.get('harnessBefore')==ev.get('harnessAfter');
  if not ev.get('completeSuite'):ev['status']='failed'
  save()
 if failure or ev['status']!='passed'or not ev.get('serverStopped')or not ev.get('fixtureRemoved'):raise SystemExit(1)
if __name__=='__main__':main()
