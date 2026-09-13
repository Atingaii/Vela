#!/usr/bin/env python3
"""Real HTTP negative checks for CI55's fixture-only Lab safety split."""
import argparse,datetime,hashlib,http.client,json,os,select,shutil,signal,subprocess,sys,tempfile,time
from pathlib import Path
from urllib.parse import urlsplit
ROOT=Path(__file__).resolve().parents[1]; CREATE=ROOT/'scripts/create-ui-fixture.py'; SERVER=ROOT/'scripts/test-ui-server.py'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',type=Path,default=ROOT/'.build/debug/vela');p.add_argument('--output',type=Path,default=ROOT/'output/parity/ui-server-ci55-lab-guards-r1.json');a=p.parse_args();helper=a.binary.resolve(strict=True);out=a.output.absolute()
 if out.exists():raise SystemExit('refusing to overwrite evidence')
 hashes={'helperBefore':sha(helper),'serverBefore':sha(SERVER),'fixtureCreatorBefore':sha(CREATE),'testBefore':sha(Path(__file__))};ev={'format':'vela-ui-server-ci55-lab-guards-v1','status':'failed','executedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'synthetic':True,'providerRuns':0,'modelRuns':0,'checks':[],'sha256':hashes,'cleanup':{'serverStopped':False,'fixtureRemoved':False}};base=server=None
 try:
  base=Path(tempfile.mkdtemp(prefix='vela-ci55-lab-guards-',dir=ROOT/'.task-tmp'));fixture=base/'fixture';made=subprocess.run([sys.executable,str(CREATE),str(fixture),'--binary',str(helper),'--with-routing-project'],cwd=ROOT,text=True,capture_output=True,timeout=120);assert made.returncode==0,made.stderr or made.stdout;fx=json.loads((fixture/'fixture.json').read_text());harbor,beacon=fx['project'],fx['routingProject'];(Path(harbor)/'tests').mkdir(exist_ok=True);(Path(harbor)/'tests/parser.test.mjs').write_text('export {};\n');(Path(harbor)/'src').mkdir(exist_ok=True);(Path(harbor)/'src/parser.mjs').write_text('export {};\n')
  server=subprocess.Popen([sys.executable,str(SERVER),str(fixture/'fixture.json'),'--binary',str(helper)],cwd=ROOT,stdout=subprocess.PIPE,text=True,start_new_session=True);assert select.select([server.stdout],[],[],15)[0],'server start';endpoint=urlsplit(json.loads(server.stdout.readline())['url'])
  def call(method,params):
   conn=http.client.HTTPConnection(endpoint.hostname,endpoint.port,timeout=30)
   try:
    conn.request('POST',endpoint.path+'__rpc',body=json.dumps({'method':method,'params':params}).encode(),headers={'Content-Type':'application/json','Host':endpoint.netloc,'Origin':endpoint.scheme+'://'+endpoint.netloc});r=conn.getresponse();return r.status,json.loads(r.read())
   finally:conn.close()
  def reject(name,method,params):
   status,body=call(method,params);assert status==400 and isinstance(body.get('error'),str) and body['error'],(name,status,body);ev['checks'].append({'name':name,'passed':True,'actual':{'httpStatus':status,'rejected':True}})
  legacy={'provider':'codex','executable':'/usr/bin/true','model':'fixture-no-provider-execution','reasoningEffort':'high'};argv=['/usr/bin/printf','','argument with spaces','quote"argument']
  def payload(**more):
   x={'title':'CI55 pending-only guard','project':harbor,'kind':'memory','agent':legacy,'task':'Synthetic pending only.','verificationCommand':argv,'verificationFiles':['tests/parser.test.mjs'],'outputFiles':['src/parser.mjs'],'timeoutSeconds':10,'repetitions':3,'baseline':{'context':'baseline'},'candidate':{'context':'candidate'}};x.update(more);return x
  reject('invalid-agent','lab.run',payload(agent=dict(legacy,executable='/bin/sh')))
  status,body=call('reuse.preview',{'project':beacon,'helperExecutable':'/usr/bin/true'});assert status==200,body;foreign=body['result']['id'];reject('foreign-source-suggestion','lab.run',payload(sourceSuggestionId=foreign))
  reject('changed-verification-argv','lab.run',payload(verificationCommand=['/usr/bin/printf','changed']))
  status,body=call('lab.run',payload());assert status==200,body;eval_id=body['result']['id'];status,body=call('inbox.list',{});assert status==200,body;approval=next(x for x in body['result'] if x.get('runId')==eval_id);reject('legacy-approval-execution','approvals.decide',{'id':approval['id'],'snapshotHash':approval['snapshotHash'],'decision':'approve'});status,body=call('lab.compare',{'id':eval_id});assert status==200 and body['result']['state']=='pending_approval',body;ev['checks'].append({'name':'pending-unchanged','passed':True,'actual':{'state':'pending_approval','providerExecuted':False}})
  ev['status']='passed'
 except Exception as e:ev['failure']=type(e).__name__+': '+str(e)
 finally:
  if server:
   if server.poll() is None:server.send_signal(signal.SIGTERM)
   try:server.wait(timeout=8)
   except subprocess.TimeoutExpired:os.killpg(server.pid,signal.SIGKILL);server.wait()
   ev['cleanup']['serverStopped']=server.poll() is not None
  if base and base.exists():shutil.rmtree(base);ev['cleanup']['fixtureRemoved']=not base.exists()
  for label,path in [('helperAfter',helper),('serverAfter',SERVER),('fixtureCreatorAfter',CREATE),('testAfter',Path(__file__))]:hashes[label]=sha(path)
  ev['sourceUnchanged']=all(hashes[a]==hashes[b] for a,b in [('helperBefore','helperAfter'),('serverBefore','serverAfter'),('fixtureCreatorBefore','fixtureCreatorAfter'),('testBefore','testAfter')])
  if not ev['sourceUnchanged']:ev['status']='failed';ev.setdefault('failure','frozen source changed')
  out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(ev,ensure_ascii=False,indent=2)+'\n')
 if ev['status']!='passed':raise SystemExit(1)
if __name__=='__main__':main()
