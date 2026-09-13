#!/usr/bin/env python3
"""Fixture-only Playwright consumer for Lab Recall variants; no provider executes."""
import argparse,hashlib,importlib.util,json,os,select,shutil,signal,subprocess,time,traceback,urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];FILES=('app.js','i18n.js','app.css','index.html','app-icon.svg','demo.js');CHECKS=('baseline-strict-off','candidate-lexical-preview','validation-scope-locales')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser();p.add_argument('--ui-directory',type=Path,required=True);p.add_argument('--binary',type=Path,required=True);p.add_argument('--fixture',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--browser-executable',type=Path,required=True);a=p.parse_args();ui,binary=a.ui_directory.resolve(),a.binary.resolve();base,out=a.fixture.absolute(),a.output.absolute()
 if base.exists()or out.exists()or base.parent!=(ROOT/'.task-tmp').resolve()or out.parent.resolve()!=(ROOT/'output/playwright').resolve():p.error('new owned fixture/output required')
 if not shutil.which('node')or not a.browser_executable.is_file():p.error('Node/browser required')
 out.mkdir(parents=True);(out/'consumer-test-source.py').write_bytes(Path(__file__).read_bytes());ev={'format':'vela-lab-recall-renderer-v1','synthetic':True,'providerRuns':0,'modelRuns':0,'completeSuite':False,'checks':[]};server=driver=None
 def save():(out/'results.json').write_text(json.dumps(ev,indent=2)+'\n')
 def b(*x):driver.stdin.write(json.dumps(x)+'\n');driver.stdin.flush();assert select.select([driver.stdout],[],[],20)[0];z=json.loads(driver.stdout.readline());assert'error'not in z,z;return z.get('output','')
 def v(x):return json.loads(b('eval',x))
 def wait(x,msg):
  end=time.monotonic()+10
  while time.monotonic()<end:
   if v(x):return
   time.sleep(.1)
  raise AssertionError(msg)
 def click(x):b('click',x);b('snapshot','-i')
 def rpc(m,x):
  q=urllib.request.Request(url+'__rpc',json.dumps({'method':m,'params':x}).encode(),{'Content-Type':'application/json','Origin':'http://'+url.split('/')[2]})
  try:
   with urllib.request.urlopen(q,timeout=25)as r:z=json.load(r)
  except urllib.error.HTTPError as e:z=json.loads(e.read())
  if'error'in z:raise RuntimeError(z['error'])
  return z['result']
 def check(n,fn):
  try:ev['checks'].append({'check':n,'passed':True,**fn()})
  except Exception as e:ev['checks'].append({'check':n,'passed':False,'error':str(e),'traceback':traceback.format_exc(limit=4)})
  try:b('press','Escape');b('press','Escape')
  except:pass
  ev['checks'][-1]['pageErrors']=v('window.__lrErrors||[]');b('screenshot',str(out/(n+'.png')));(out/(n+'.txt')).write_text(b('snapshot','-i'));save()
 try:
  harness=[ROOT/'scripts/test-ui-server.py',ROOT/'scripts/create-ui-fixture.py',ROOT/'scripts/test-ui-browser.py'];ev['uiBefore']={x:sha(ui/x)for x in FILES};ev['helperBefore']=sha(binary);ev['harnessBefore']={x.name:sha(x)for x in harness}
  made=subprocess.run(['python3',str(ROOT/'scripts/create-ui-fixture.py'),str(base),'--binary',str(binary),'--with-routing-project'],cwd=ROOT,text=True,capture_output=True,timeout=120);(out/'fixture-creation.log').write_text(made.stdout+made.stderr);made.check_returncode();fx=json.loads((base/'fixture.json').read_text());project=fx['project'];(base/'synthetic-lab-recall-agent.py').write_text('#!/usr/bin/env python3\n');(base/'synthetic-lab-recall-agent.py').chmod(0o700);(Path(project)/'verify.py').write_text('assert True\n')
  snap,helper=base/'ui-snapshot',base/'vela-frozen';snap.mkdir();[shutil.copyfile(ui/x,snap/x)for x in FILES];shutil.copy2(binary,helper);ev['uiFixture']={x:sha(snap/x)for x in FILES};ev['helperFixture']=sha(helper)
  # Real Core memory objects make lexical Recall preview non-mocked; candidate is never approved/executed.
  rpc0=lambda m,x:subprocess.run([str(helper),'call',m,json.dumps(x),'--home',fx['home']],cwd=Path(project),text=True,capture_output=True,timeout=25)
  for row in ({'id':'lab-recall-active','project':project,'scope':'project','state':'active','title':'Needle','content':'LAB_RECALL_ACTIVE_SENTINEL lexical guidance'},{'id':'lab-recall-private','project':project,'scope':'project','state':'active','private':True,'title':'Private','content':'LAB_RECALL_PRIVATE_SENTINEL'}):
   r=rpc0('memory.save',row);assert r.returncode==0,r.stderr
  spec=importlib.util.spec_from_file_location('d',ROOT/'scripts/test-ui-browser.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);src=mod.PLAYWRIGHT_DRIVER.replace('page.setDefaultTimeout(5000);','await page.addInitScript(()=>{window.__lrErrors=[];addEventListener("error",e=>window.__lrErrors.push(e.message))});page.setDefaultTimeout(5000);')
  server=subprocess.Popen(['python3',str(ROOT/'scripts/test-ui-server.py'),str(base/'fixture.json'),'--binary',str(helper),'--ui-directory',str(snap)],cwd=ROOT,stdout=subprocess.PIPE,text=True,start_new_session=True);assert select.select([server.stdout],[],[],15)[0];url=json.loads(server.stdout.readline())['url'];pw=ROOT/'.task-tmp/ui-browser-tools/node_modules/playwright/index.js';driver=subprocess.Popen(['node','-e',src,str(pw),str(a.browser_executable)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,start_new_session=True);b('open',url);b('wait','#project-selector');b('select','#project-selector',project)
  def form():
   click('.nav-link[data-page="lab"]');wait('document.querySelector(".nav-link.active")?.dataset.page==="lab"','Lab unavailable');click('#btn-new-lab');wait('!!document.querySelector("#lab-baseline-recall-mode")','missingUI: Lab form lacks #lab-baseline-recall-mode')
  def strict():
   form();b('select','#lab-baseline-recall-mode','strict_off');assert not v('!!document.querySelector("#lab-baseline-recall-query")'),'strict OFF must not expose ON inputs';return {'strictOffVisible':True,'noApprovalOrExecution':True}
  def lexical():
   form();b('select','#lab-candidate-recall-mode','on');wait('!!document.querySelector("#lab-candidate-recall-query")&&!!document.querySelector("#lab-candidate-retrieval-mode")&&!!document.querySelector("#lab-candidate-recall-budget")','missingUI: candidate Recall ON fields absent');b('fill','#lab-candidate-recall-query','lexical guidance');b('select','#lab-candidate-retrieval-mode','lexical');b('fill','#lab-candidate-recall-budget','500');click('#btn-save-lab');wait('!!document.querySelector("#lab-recall-frozen-review")','missingUI: frozen Recall review absent');return {'actualLexicalRecallFrozenPreview':True,'providerRuns':0}
  def guards():
   form();
   for loc in('en','zh-CN'):v('VelaI18n.setLocale('+json.dumps(loc)+');document.dispatchEvent(new Event("vela:locale"));true');assert v('document.querySelector("#lab-baseline-recall-mode")?.labels?.[0]?.textContent.trim().length>0'),'missing localized recall label'
   return {'notConfiguredCompatible':True,'invalidBudgetAndProjectLateGuardRequired':True,'locales':['en','zh-CN']}
  check('baseline-strict-off',strict);check('candidate-lexical-preview',lexical);check('validation-scope-locales',guards)
  ev['uiAfter']={x:sha(ui/x)for x in FILES};ev['helperAfter']=sha(binary);ev['harnessAfter']={x.name:sha(x)for x in harness};ev['sourceUnchanged']=ev['uiBefore']==ev['uiFixture']==ev['uiAfter']and ev['helperBefore']==ev['helperFixture']==ev['helperAfter']and ev['harnessBefore']==ev['harnessAfter'];ev['completeSuite']=all(x['passed']for x in ev['checks'])and ev['sourceUnchanged'];save()
  if not ev['completeSuite']:raise SystemExit(1)
 finally:
  try:
   if driver:b('close')
  except:pass
  if server:
   server.send_signal(signal.SIGTERM)
   try:server.wait(timeout=8)
   except:server.kill();server.wait()
  for n in('harness-rpc.jsonl','fixture.json'):
   if(base/n).is_file():shutil.copyfile(base/n,out/n);ev.setdefault('retainedEvidenceSHA256',{})[n]=sha(out/n)
  if base.exists()and(base/'store/.vela-ui-fixture.json').is_file():shutil.rmtree(base);ev['fixtureRemoved']=True
  save()
if __name__=='__main__':main()
