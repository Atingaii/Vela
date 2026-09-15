#!/usr/bin/env python3
"""Zero-provider frozen-helper RPC smoke for manual run feedback."""
import argparse, datetime, hashlib, json, os, pathlib, shutil, subprocess, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser(); p.add_argument('--binary',type=pathlib.Path,default=ROOT/'.build/debug/vela'); p.add_argument('--output',type=pathlib.Path,required=True); a=p.parse_args()
 if a.output.exists(): p.error('output must be new')
 scratch=ROOT/'.task-tmp'; scratch.mkdir(exist_ok=True); base=pathlib.Path(tempfile.mkdtemp(prefix='vela-run-feedback-',dir=scratch)); project=base/'project'; home=base/'home'; project.mkdir(); home.mkdir(); subprocess.run(['git','init'],cwd=project,env=dict(os.environ,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL=os.devnull),check=True,capture_output=True); helper=base/'vela'; shutil.copy2(a.binary,helper)
 r={'format':'vela-run-feedback-rpc-v1','status':'failed','providerRuns':0,'modelRuns':0,'helperSHA256':sha(helper),'checks':[]}
 env=dict(os.environ,VELA_HOME=str(home),VELA_DISABLE_DISCOVERY='1',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL=os.devnull)
 def call(m,x):
  q=subprocess.run([str(helper),'call',m,json.dumps(x),'--home',str(home)],cwd=project,env=env,text=True,capture_output=True,timeout=20)
  if q.returncode: raise RuntimeError(q.stderr or q.stdout)
  return json.loads(q.stdout)
 try:
  call('projects.add',{'path':str(project)})
  wf=call('workflows.save',{'id':'feedback','title':'feedback','project':str(project),'enabled':True,'description':'x','context':{'version':1,'template':'x','memory':{'enabled':False,'budgetTokens':0},'inputs':[]},'steps':[{'id':'agent','title':'agent','tool':'agent.run','arguments':{'executable':'/usr/bin/true','args':['{{vela.prompt}}'],'promptMode':'workflow_context','timeoutSeconds':5}},{'id':'status','title':'status','tool':'git.status','arguments':{}}]})
  started=call('workflows.run',{'id':wf['id'],'dryRun':False}); approval=next(x for x in call('inbox.list',{'project':str(project)}) if x['runId']==started['id']); call('approvals.decide',{'id':approval['id'],'snapshotHash':approval['snapshotHash'],'decision':'approve'})
  pre=call('runs.feedback.prepare',{'project':str(project),'runId':started['id']}); saved=call('runs.feedback.record',{'project':str(project),'runId':started['id'],'runHash':pre['runHash'],'previousFeedbackHash':None,'outcome':'good','reason':'Synthetic local status review.'}); assert saved['created']; assert call('runs.feedback.record',{'project':str(project),'runId':started['id'],'runHash':pre['runHash'],'previousFeedbackHash':None,'outcome':'good','reason':'Synthetic local status review.'})['idempotent']; bad=call('runs.feedback.record',{'project':str(project),'runId':started['id'],'runHash':pre['runHash'],'previousFeedbackHash':saved['feedbackHash'],'outcome':'bad','reason':'Reviewer corrected the observation.'}); cleared=call('runs.feedback.record',{'project':str(project),'runId':started['id'],'runHash':pre['runHash'],'previousFeedbackHash':bad['feedbackHash'],'outcome':'clear','reason':'Reviewer withdrew the observation.'}); history=call('runs.feedback.history.list',{'project':str(project),'runId':started['id'],'limit':1}); assert len(history['items'])==1 and history['truncated'] and history['cursor']; page2=call('runs.feedback.history.list',{'project':str(project),'runId':started['id'],'limit':1,'cursor':history['cursor']}); assert len(page2['items'])==1 and page2['items'][0]['historyId'] != history['items'][0]['historyId']; assert [history['items'][0]['outcome'],page2['items'][0]['outcome']] == ['bad','good'] and [history['items'][0]['revision'],page2['items'][0]['revision']] == [2,1]; assert call('runs.feedback.history.get',{'project':str(project),'id':history['items'][0]['historyId']})['outcome']==history['items'][0]['outcome']; health=call('workflows.health',{'project':str(project)}); assert health['manualFeedback']['good']==0 and health['manualFeedback']['bad']==0 and health['successRate']==1
  r['checks']=['prepare_hash','cas_record','exact_replay','revision_chain_good_bad_clear','history_pagination_snapshot_bound','health_manual_observation_without_rate_change']; r['status']='passed'
 finally:
  r['finishedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat(); a.output.parent.mkdir(parents=True,exist_ok=True); a.output.write_text(json.dumps(r,indent=2)+'\n'); shutil.rmtree(base,ignore_errors=True)
 if r['status']!='passed': raise SystemExit(1)
if __name__=='__main__': main()
