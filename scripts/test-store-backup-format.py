#!/usr/bin/env python3
import argparse, hashlib, json, os, select, shutil, sqlite3, subprocess, tempfile, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def sha(p):
 h=hashlib.sha256()
 with open(p,'rb') as f:
  for b in iter(lambda:f.read(65536),b''):h.update(b)
 return h.hexdigest()
def tree(p): return {str(x.relative_to(p)):sha(x) for x in sorted(p.rglob('*')) if x.is_file()}
def canon(x):return json.dumps(x,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
def sign(m):p=dict(m);p.pop('sha256',None);m['sha256']=hashlib.sha256(canon(p)).hexdigest()
def run(argv,env):
 p=subprocess.run(argv,text=True,capture_output=True,env=env,timeout=30);return {'argv':argv,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
def main():
 a=argparse.ArgumentParser();a.add_argument('--binary',type=Path,required=True);a.add_argument('--output',type=Path,required=True);q=a.parse_args();binary=q.binary.resolve(strict=True);out=q.output.resolve()
 if out.exists():a.error('--output must be new')
 out.parent.mkdir(parents=True,exist_ok=True);(ROOT/'.task-tmp').mkdir(exist_ok=True);base=Path(tempfile.mkdtemp(prefix='vela-backup-format-',dir=ROOT/'.task-tmp')).resolve();home=base/'nonexistent-home';source=base/'source';bundle=base/'bundle';sentinel=base/'sentinel';sentinel.write_bytes(b'outside unchanged')
 ev={'format':'vela-backup-format-acceptance-v2','status':'failed','helperBefore':sha(binary),'cases':[],'rpc':[]};env={'PATH':os.environ['PATH'],'HOME':str(home),'VELA_HOME':str(source),'VELA_DISABLE_DISCOVERY':'1'};rpc=None
 try:
  source.mkdir();subprocess.run(['/usr/bin/git','init'],cwd=base,check=True,capture_output=True);rpc=subprocess.Popen([str(binary),'rpc','--no-schedule'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
  def call(i,m,p):
   frame={'id':str(i),'method':m,'params':p};rpc.stdin.write(json.dumps(frame)+'\n');rpc.stdin.flush();ready,_,_=select.select([rpc.stdout],[],[],15)
   if not ready:raise RuntimeError('RPC response deadline '+m)
   raw=rpc.stdout.readline();ev['rpc'].append({'request':frame,'response':raw});return json.loads(raw)
  call(1,'projects.add',{'path':str(base)});call(2,'memory.save',{'project':str(base),'title':'evidence','content':'private fixture','scope':'project','private':True})
  wf={'id':'format-output','project':str(base),'title':'format output','trigger':'manual','steps':[{'id':'status','title':'status','tool':'git.status','arguments':{}}],'output':{'target':'file','path':'format-output.md','stepId':'status'}};saved=call(3,'workflows.save',wf);done=call(4,'workflows.run',{'id':saved['result']['id'],'dryRun':False})
  if done.get('result',{}).get('state')!='completed' or not (source/'output'/'format-output.md').is_file():raise RuntimeError('public workflow output missing')
  rpc.stdin.close();rpc.wait(timeout=10);ev['rpcEOFExit']=rpc.returncode;rpc=None
  created=run([str(binary),'backup','create','--destination',str(bundle),'--home',str(source)],env)
  if created['exit']!=0:raise RuntimeError(created['stderr'])
  ev['sourceBefore']=tree(source);ev['bundleBefore']=tree(bundle)
  def case(name,mutate,expected):
   bad=base/(name+'-bundle');shutil.copytree(bundle,bad);mutate(bad);target=base/(name+'-target');r=run([str(binary),'backup','restore','--bundle',str(bad),'--target',str(target),'--home',str(home)],env)
   ok=r['exit']!=0 and expected in(r['stderr']+r['stdout']) and not target.exists() and tree(source)==ev['sourceBefore'] and tree(bundle)==ev['bundleBefore'] and sentinel.read_bytes()==b'outside unchanged' and not home.exists()
   ev['cases'].append({'name':name,'passed':ok,'expected':expected,'result':r,'targetAbsent':not target.exists()})
  def future(b):
   db=b/'vela.sqlite3';c=sqlite3.connect(db);c.execute('pragma user_version=999');c.commit();c.close();m=json.loads((b/'manifest.json').read_text());m['database']['sha256']=sha(db);sign(m);(b/'manifest.json').write_text(json.dumps(m,sort_keys=True,separators=(',',':')))
  def junk(b):
   db=b/'vela.sqlite3';db.write_bytes(b'not sqlite');m=json.loads((b/'manifest.json').read_text());m['database']['sha256']=sha(db);sign(m);(b/'manifest.json').write_text(json.dumps(m,sort_keys=True,separators=(',',':')))
  def missing(b):m=json.loads((b/'manifest.json').read_text());m['assets']=m['assets'][1:];sign(m);(b/'manifest.json').write_text(json.dumps(m,sort_keys=True,separators=(',',':')))
  def output(b):m=json.loads((b/'manifest.json').read_text());(b/m['outputs'][0]['path']).write_bytes(b'tampered output')
  case('future-schema',future,'schema');case('non-sqlite',junk,'schema version');case('missing-asset-row',missing,'exactly match');case('output-checksum',output,'output checksum')
  ev['status']='passed' if all(x['passed'] for x in ev['cases']) and ev['rpcEOFExit']==0 else 'failed'
 except Exception as error:
  ev['error']=type(error).__name__+': '+str(error);ev['status']='failed'
 finally:
  if rpc is not None:
   try:
    if rpc.stdin and not rpc.stdin.closed:rpc.stdin.close()
    try:rpc.wait(timeout=10)
    except subprocess.TimeoutExpired:
     rpc.terminate()
     try:rpc.wait(timeout=5)
     except subprocess.TimeoutExpired:rpc.kill();rpc.wait(timeout=5)
    ev['rpcEOFExit']=rpc.returncode
    ev['rpcStderr']=rpc.stderr.read()
   except Exception as error:ev['rpcCleanupError']=str(error);ev['status']='failed'
   ev['rpcStopped']=rpc.poll() is not None
  else:ev['rpcStopped']=True
  try:
   ev['helperAfter']=sha(binary);ev['sourceAfter']=tree(source) if source.exists() else None;ev['bundleAfter']=tree(bundle) if bundle.exists() else None
   ev['defaultHomeAbsent']=not home.exists();ev['sentinelUnchanged']=sentinel.read_bytes()==b'outside unchanged'
   ev['integrityPassed']=ev['helperAfter']==ev['helperBefore'] and ev['sourceAfter']==ev.get('sourceBefore') and ev['bundleAfter']==ev.get('bundleBefore') and ev['defaultHomeAbsent'] and ev['sentinelUnchanged']
  except Exception as error:ev['integrityError']=str(error);ev['integrityPassed']=False
  try:shutil.rmtree(base)
  except Exception as error:ev['cleanupError']=str(error)
  ev['fixtureRemoved']=not base.exists()
  if not(ev.get('integrityPassed') and ev['fixtureRemoved'] and ev['rpcStopped']):ev['status']='failed'
  out.write_text(json.dumps(ev,indent=2,ensure_ascii=False)+'\n')
 if ev['status']!='passed':raise SystemExit(1)
if __name__=='__main__':main()
