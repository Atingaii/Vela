#!/usr/bin/env python3
"""Frozen-helper semantic/hybrid Lab Recall receipt; never runs a provider or approval."""
import argparse,datetime,hashlib,json,os,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser();p.add_argument('--binary',type=pathlib.Path,default=ROOT/'.build/debug/vela');p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args();out=a.output.absolute();helper=a.binary.resolve(strict=True)
 if out.exists():p.error('output must be new')
 base=pathlib.Path(tempfile.mkdtemp(prefix='vela-lab-semantic-',dir=ROOT/'.task-tmp'));r={'format':'vela-lab-semantic-recall-rpc-v1','status':'failed','providerRuns':0,'modelRuns':0,'helperSHA256Before':sha(helper),'consumerSourceSHA256':sha(pathlib.Path(__file__)),'checks':[],'sourceLifecycleGuards':'not exercised; no approval or agent execution'}
 env=dict(os.environ,VELA_HOME=str(base/'store'),VELA_DISABLE_DISCOVERY='1',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL=os.devnull)
 def call(m,x):
  q=subprocess.run([str(helper),'call',m,json.dumps(x),'--home',str(base/'store')],cwd=base/'Harbor',env=env,text=True,capture_output=True,timeout=45)
  if q.returncode:raise RuntimeError(q.stderr or q.stdout)
  return json.loads(q.stdout)
 try:
  project=base/'Harbor';project.mkdir();(project/'verify.py').write_text('assert True\n');subprocess.run(['git','init','-q'],cwd=project,env=env,check=True);subprocess.run(['git','add','.'],cwd=project,env=env,check=True);subprocess.run(['git','-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture'],cwd=project,env=env,check=True)
  call('projects.add',{'path':str(project)});active=call('memory.save',{'id':'semantic-active','project':str(project),'scope':'project','state':'active','title':'Semantic needle','content':'English semantic retrieval sentinel for bounded local recall.'});call('memory.save',{'id':'semantic-private','project':str(project),'scope':'project','state':'active','private':True,'title':'Private','content':'PRIVATE_SEMANTIC_SENTINEL'})
  indexed=call('memory.semantic.index',{'project':str(project),'language':'en'});r['index']=indexed;r['platformModel']=indexed.get('model')
  if indexed.get('status')=='unavailable' or not indexed.get('model'):
   r['status']='skipped_unavailable';r['checks'].append({'name':'installed-model','passed':False,'actual':'unavailable','downloadRequested':indexed.get('downloadRequested')});return
  status=call('memory.semantic.status',{'project':str(project),'language':'en'});r['semanticStatus']=status
  if status.get('indexIncomplete') or status.get('indexed',0)<1:raise AssertionError('semantic index incomplete')
  agent=base/'agent';agent.write_text('#!/bin/sh\nexit 99\n');agent.chmod(0o700)
  def spec(mode):return {'title':'synthetic semantic receipt','project':str(project),'kind':'memory','agent':{'provider':'codex','executable':str(agent),'model':'fixed-local','reasoningEffort':'high'},'task':'Synthetic frozen preview only.','verificationCommand':['/usr/bin/python3','verify.py'],'verificationFiles':['verify.py'],'outputFiles':['observed.txt'],'timeoutSeconds':20,'repetitions':1,'baseline':{'files':[],'recall':{'enabled':False,'strictOff':True}},'candidate':{'files':[],'recall':{'enabled':True,'query':'semantic bounded local retrieval','mode':mode,'scope':'project','budget':500}}}
  for mode in ('semantic','hybrid'):
   created=call('lab.run',spec(mode));candidate=created['candidate'];recall=candidate['recall'];ids=[x['id']for x in recall['items']];assert ids==[active['id']] and recall['retrievalMode']==mode and recall['requestedRetrievalMode']==mode and recall['status']=='ok' and recall['indexIncomplete'] is False and recall['budget']==500 and recall['usedTokens']<=500 and len(recall['finalContextHash'])==64 and len(candidate['finalContextHash'])==64 and 'semantic retrieval sentinel' in candidate['context'] and 'PRIVATE_SEMANTIC_SENTINEL' not in candidate['context'];r['checks'].append({'name':mode,'passed':True,'selectedIDs':ids,'usedTokens':recall['usedTokens'],'budget':recall['budget'],'mode':recall['retrievalMode'],'status':recall['status'],'indexIncomplete':False,'frozenContextContainsActiveOnly':True})
  r['status']='passed'
 except Exception as e:r['status']='failed';r['failure']=type(e).__name__+': '+str(e)
 finally:
  r['helperSHA256After']=sha(helper);r['helperUnchanged']=r['helperSHA256Before']==r['helperSHA256After'];shutil.rmtree(base);r['fixtureRemoved']=not base.exists();r['finishedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat();out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(r,indent=2)+'\n');source_copy=out.with_suffix('.source.py');source_copy.write_bytes(pathlib.Path(__file__).read_bytes());r['consumerSourceCopySHA256']=sha(source_copy);out.write_text(json.dumps(r,indent=2)+'\n')
 if r['status']=='failed':raise SystemExit(1)
if __name__=='__main__':main()
