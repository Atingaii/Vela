#!/usr/bin/env python3
"""Frozen-helper, isolated CLI acceptance for `vela backup create|restore`.

This harness intentionally constructs normal source data through RPC, not SQLite.
It refuses to overwrite its receipt, bundle, or target.  Run only against a frozen
helper/source pair; it records source/helper hashes before and after execution.
"""
import argparse, base64, hashlib, json, os, select, shutil, subprocess, tempfile, time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
TRANSCRIPT=[]
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def sources(root): return {str(p.relative_to(root)):sha(p) for p in sorted((root/'Sources').rglob('*.swift'))}
def run(argv, *, env, cwd, data=None, timeout=30, okay=True):
 r=subprocess.run(argv,input=data,text=True,capture_output=True,env=env,cwd=cwd,timeout=timeout)
 TRANSCRIPT.append({'argv':argv,'stdin':data,'stdout':r.stdout,'stderr':r.stderr,'exitCode':r.returncode})
 if okay and r.returncode: raise RuntimeError(r.stderr.strip() or r.stdout.strip())
 return r
def main():
 ap=argparse.ArgumentParser(); ap.add_argument('--binary',type=Path,required=True); ap.add_argument('--source-root',type=Path,required=True); ap.add_argument('--output',type=Path,required=True); a=ap.parse_args()
 binary=a.binary.resolve(strict=True); source=a.source_root.resolve(strict=True); out=a.output.resolve(); raw=out.with_suffix('.raw.json')
 if out.exists() or raw.exists() or out.is_symlink() or raw.is_symlink(): ap.error('new output required')
 out.parent.mkdir(parents=True,exist_ok=True); (ROOT/'.task-tmp').mkdir(exist_ok=True)
 receipt={'status':'failed','helperSHA256Before':sha(binary),'sourceBefore':sources(source),'checks':[],'providerRuns':0,'synthetic':True}
 base=Path(tempfile.mkdtemp(prefix='backup-cli-acceptance-',dir=ROOT/'.task-tmp')).resolve()
 mcp=None
 def stop_mcp(process):
  if process.stdin and not process.stdin.closed: process.stdin.close()
  try: process.wait(timeout=10)
  except subprocess.TimeoutExpired:
   process.terminate()
   try: process.wait(timeout=5)
   except subprocess.TimeoutExpired:
    process.kill()
    try: process.wait(timeout=5)
    except subprocess.TimeoutExpired: return False
  return process.poll() is not None
 def check(name, passed, **detail): receipt['checks'].append({'name':name,'passed':bool(passed),**detail})
 try:
  helper=base/'vela'; shutil.copy2(binary,helper); project=base/'project'; home=base/'home'; logs=base/'logs'; bundle=base/'bundle'; target=base/'target'; sentinel=base/'external-sentinel'
  project.mkdir(); run(['/usr/bin/git','init','-q'],env=dict(os.environ),cwd=project); (logs/'codex').mkdir(parents=True); sentinel.write_text('outside unchanged')
  env=dict(os.environ,HOME=str(base),VELA_HOME=str(home),VELA_SESSION_ROOT=str(logs),VELA_DISABLE_DISCOVERY='1',GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1')
  def rpc(method,params): return json.loads(run([str(helper),'call',method,'--params-stdin','--home',str(home)],env=env,cwd=project,data=json.dumps(params)).stdout)
  # Normal RPC fixture: captured public + private Memory and a persisted History source.
  rpc('projects.add',{'path':str(project)})
  log=logs/'codex'/'backup.jsonl'; stamp='2026-09-14T00:00:00Z'
  log.write_text(json.dumps({'type':'session_meta','timestamp':stamp,'payload':{'id':'backup-fixture','cwd':str(project)}})+'\n'+json.dumps({'type':'response_item','timestamp':stamp,'payload':{'id':'public','type':'message','role':'user','content':[{'type':'input_text','text':'BACKUP_PUBLIC'}]}})+'\n')
  rpc('sessions.refresh',{}); session=next(x for x in rpc('sessions.list',{'project':str(project)}) if x.get('sourceSessionId')=='backup-fixture'); mid=rpc('sessions.get',{'id':session['id']})['messages'][0]['id']; fields={'project':str(project),'sessionId':session['id'],'messageId':mid}; prep=rpc('memory.capture.prepare',fields); public=rpc('memory.capture',dict(fields,sourceIdentity=prep['sourceIdentity'],expectedSourceHash=prep['expectedSourceHash'])); rpc('memory.transition',{'id':public['id'],'state':'active'})
  # A private record uses the supported public memory-save contract; no DB seam.
  private=rpc('memory.save',{'id':'backup-private','project':str(project),'title':'private backup','content':'BACKUP_PRIVATE','private':True,'state':'active'})
  rpc('settings.save',{'locale':'en','notifications':True})
  # Every canonical asset kind is made through its public RPC contract. The
  # workflow is read-only (`git.status`) but delivers its real stdout to managed output.
  guideline=rpc('guidelines.save',{'project':str(project),'title':'Backup acceptance guideline','content':'BACKUP_GUIDELINE_CONTENT'})
  library=rpc('library.add',{'project':str(project),'title':'Backup public library','content':'BACKUP_LIBRARY_SEARCH_SENTINEL','private':False})
  indexed=rpc('library.index',{'project':str(project),'batchSize':20})
  if indexed.get('indexed')!=1 or indexed.get('pageSucceeded') is not True: raise RuntimeError('Library FTS index was not built before backup')
  checkpoint=rpc('checkpoint.save',{'project':str(project),'title':'Backup checkpoint','goal':'BACKUP_CHECKPOINT_GOAL','completed':'BACKUP_CHECKPOINT_COMPLETED','pending':'BACKUP_CHECKPOINT_PENDING','nextActions':'BACKUP_CHECKPOINT_NEXT'})
  workflow=rpc('workflows.save',{'id':'backup-readonly-workflow','project':str(project),'title':'Backup read-only Git status','trigger':'manual','steps':[{'id':'status','title':'Read isolated Git status','tool':'git.status','arguments':{}}],'output':{'target':'file','path':'backup-readonly-status.md','stepId':'status'}})
  workflow_run=rpc('workflows.run',{'id':workflow['id'],'dryRun':False})
  workflow_output=home/'output'/'backup-readonly-status.md'
  if workflow_run.get('state')!='completed' or not workflow_output.is_file(): raise RuntimeError('Read-only workflow did not create managed output')
  # Real explicit History import, including its raw receipt bytes.
  (logs/'claude').mkdir(exist_ok=True)
  history_bytes=(json.dumps({'type':'user','uuid':'header','cwd':str(project),'message':{'role':'user','content':'history header'}},sort_keys=True)+'\n'+json.dumps({'type':'user','uuid':'history-private','message':{'role':'user','content':'BACKUP_HISTORY_BYTES'}},sort_keys=True)+'\n').encode()
  history_path=logs/'claude'/'backup-history.jsonl'; history_path.write_bytes(history_bytes)
  history_deadline=time.monotonic()+30; discover_rounds=0; inventory=rpc('history.discover',{'project':str(project),'provider':'claude','limit':20})
  while inventory['state']!='completed' and discover_rounds<100 and time.monotonic()<history_deadline:
   discover_rounds+=1; inventory=rpc('history.discover',{'project':str(project),'inventoryId':inventory['id'],'limit':20})
  receipt['historyDiscoverFinalState']=inventory.get('state'); receipt['historyDiscoverRounds']=discover_rounds
  if inventory.get('state')!='completed': raise RuntimeError('History discovery did not complete within bounded deadline')
  source_row=rpc('history.sources',{'project':str(project),'inventoryId':inventory['id'],'afterId':'','limit':20})['items'][0]
  epoch=rpc('history.start',{'project':str(project),'sourceId':source_row['id']}); advance_rounds=0
  while epoch['state']=='pending' and advance_rounds<100 and time.monotonic()<history_deadline:
   advance_rounds+=1; epoch=rpc('history.advance',{'project':str(project),'id':epoch['id'],'batchRecords':100,'batchBytes':65536})
  receipt['historyAdvanceFinalState']=epoch.get('state'); receipt['historyAdvanceRounds']=advance_rounds
  if epoch.get('state')!='completed': raise RuntimeError('History advance did not complete within bounded deadline')
  history_raw=base64.b64decode(rpc('history.raw',{'project':str(project),'id':epoch['id'],'ordinal':1,'part':0})['dataBase64'])
  public_bytes=Path(public['assetPath']).read_bytes(); private_bytes=Path(private['assetPath']).read_bytes()
  canonical_assets={'memory':{public['id']:public_bytes,private['id']:private_bytes},'guideline':{guideline['id']:Path(guideline['assetPath']).read_bytes()},'library':{library['id']:Path(library['assetPath']).read_bytes()},'checkpoint':{checkpoint['id']:Path(checkpoint['assetPath']).read_bytes()},'workflow':{workflow['id']:Path(workflow['assetPath']).read_bytes()}}
  managed_output_bytes=workflow_output.read_bytes()
  settings_before=rpc('settings.get',{})
  # CLI is the subject under test: no direct DB creation/copy is used for happy path.
  create=run([str(helper),'backup','create','--destination',str(bundle)],env=env,cwd=project); create_json=json.loads(create.stdout)
  default_home=base/'restore-default-must-not-open'
  restore_env=dict(env,VELA_HOME=str(default_home))
  restore=run([str(helper),'backup','restore','--bundle',str(bundle),'--target',str(target)],env=restore_env,cwd=project); restore_json=json.loads(restore.stdout)
  if default_home.exists(): raise RuntimeError('backup restore opened or migrated the configured default VELA_HOME')
  restored_env=dict(env,VELA_HOME=str(target));
  def restored(method,params): return json.loads(run([str(helper),'call',method,'--params-stdin','--home',str(target)],env=restored_env,cwd=project,data=json.dumps(params)).stdout)
  rows={x['id']:x for x in restored('memory.list',{'project':str(project)})}
  check('cli-create-restore',create_json.get('complete') is True and restore_json.get('restored') is True)
  check('public-and-private-records-retained',public['id'] in rows and private['id'] in rows)
  check('asset-bytes-and-rebound-target-paths',Path(rows[public['id']]['assetPath']).read_bytes()==public_bytes and Path(rows[private['id']]['assetPath']).read_bytes()==private_bytes and rows[public['id']]['assetPath']==str(target/'assets'/'memory'/(public['id']+'.md')) and rows[private['id']]['assetPath']==str(target/'assets'/'memory'/(private['id']+'.md')))
  check('settings-retained',restored('settings.get',{}).get('locale')==settings_before.get('locale') and restored('settings.get',{}).get('notifications')==settings_before.get('notifications'))
  restored_assets={
   'memory':{x['id']:x for x in rows.values()},
   'guideline':{x['id']:x for x in restored('guidelines.list',{'project':str(project)})},
   'library':{x['id']:x for x in restored('library.list',{'project':str(project)})},
   'checkpoint':{x['id']:x for x in restored('checkpoint.list',{'project':str(project)})},
   'workflow':{x['id']:x for x in restored('workflows.list',{'project':str(project)})},
  }
  assets_ok=True
  for kind, expected in canonical_assets.items():
   for asset_id, original_bytes in expected.items():
    item=restored_assets.get(kind,{}).get(asset_id); expected_path=target/'assets'/kind/(asset_id+'.md')
    assets_ok=assets_ok and item is not None and item.get('assetPath')==str(expected_path) and expected_path.is_file() and expected_path.read_bytes()==original_bytes
  restored_output=target/'output'/'backup-readonly-status.md'
  check('all-five-asset-kinds-and-managed-output-retained',assets_ok and restored_output.is_file() and restored_output.read_bytes()==managed_output_bytes and not default_home.exists())
  stale_search=restored('library.search',{'project':str(project),'query':'BACKUP_LIBRARY_SEARCH_SENTINEL','k':10})
  stale_items=stale_search.get('items',[]); stale_count=stale_search.get('staleRejectedCount',stale_search.get('stale',0))
  before_index=restored('library.index.status',{'project':str(project)})
  reindexed=restored('library.index',{'project':str(project),'batchSize':20})
  fresh_search=restored('library.search',{'project':str(project),'query':'BACKUP_LIBRARY_SEARCH_SENTINEL','k':10})
  fresh_ids={x.get('id') for x in fresh_search.get('items',[])}
  check('library-restored-stale-then-explicit-reindex-search',library['id'] not in {x.get('id') for x in stale_items} and before_index.get('pendingDocuments',0)>=1 and before_index.get('indexedPublicDocuments')==0 and reindexed.get('indexed')>=1 and library['id'] in fresh_ids, beforeIndex=before_index, staleRejectedCount=stale_count)
  restored_epoch=restored('history.get',{'project':str(project),'id':epoch['id']})
  restored_page=restored('history.page',{'project':str(project),'id':epoch['id'],'cursor':'','limit':20})
  restored_raw=base64.b64decode(restored('history.raw',{'project':str(project),'id':epoch['id'],'ordinal':1,'part':0})['dataBase64'])
  history_identity=('sourceId','sourceIdentity','path','root','sourceVersion','decoderVersion')
  check('history-record-source-and-raw-bytes-retained',all(epoch.get(k) not in (None,'') and restored_epoch.get(k)==epoch.get(k) for k in history_identity) and len(restored_page.get('items',[]))>=2 and restored_raw==history_raw, fields={k:restored_epoch.get(k) for k in history_identity})
  # Private data must remain present for management but unavailable to consumer surfaces.
  check('private-management-retained',rows[private['id']].get('private') is True)
  recalled=restored('recall',{'project':str(project),'query':'BACKUP_PRIVATE','budgetTokens':1000})
  check('memory-recall-does-not-leak-private-content',private['id'] not in json.dumps(recalled) and 'BACKUP_PRIVATE' not in json.dumps(recalled))
  mcp=subprocess.Popen([str(helper),'mcp','--home',str(target),'--no-watch'],env=restored_env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  init={'jsonrpc':'2.0','id':0,'method':'initialize','params':{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'backup-cli','version':'1'}}}
  mcp.stdin.write((json.dumps(init)+'\n').encode()); mcp.stdin.flush()
  if not select.select([mcp.stdout],[],[],20)[0]: raise RuntimeError('MCP initialize deadline')
  init_response=json.loads(mcp.stdout.readline()); TRANSCRIPT.append({'transport':'mcp','request':init,'response':init_response})
  if 'error' in init_response: raise RuntimeError('MCP initialize error: '+json.dumps(init_response))
  notification={'jsonrpc':'2.0','method':'notifications/initialized'}; mcp.stdin.write((json.dumps(notification)+'\n').encode()); mcp.stdin.flush(); TRANSCRIPT.append({'transport':'mcp','request':notification,'response':None})
  def mcp_tool(i,name,args):
   mcp.stdin.write((json.dumps({'jsonrpc':'2.0','id':i,'method':'tools/call','params':{'name':name,'arguments':dict(project=str(project),**args)}})+'\n').encode()); mcp.stdin.flush()
   if not select.select([mcp.stdout],[],[],20)[0]: raise RuntimeError('MCP deadline')
   response=json.loads(mcp.stdout.readline()); TRANSCRIPT.append({'transport':'mcp','request':{'id':i,'name':name,'arguments':args},'response':response}); return response['result']
  listed=mcp_tool(1,'vela_memory_list',{'limit':100}); gotten=mcp_tool(2,'vela_memory_get',{'id':private['id']}); list_text=''.join(x.get('text','') for x in listed.get('content',[]))
  check('mcp-list-and-get-reject-private-retained-memory',not listed.get('isError') and private['id'] not in list_text and 'BACKUP_PRIVATE' not in list_text and gotten.get('isError') is True)
  receipt['mcpStopped']=stop_mcp(mcp); receipt['mcpExitCode']=mcp.returncode
  if not receipt['mcpStopped']: raise RuntimeError('MCP did not stop')
  mcp=None
  # Pending approval has not started a process and is deliberately backupable;
  # restore must revoke it before a caller can decide the old approval.
  pending_flow=rpc('workflows.save',{'project':str(project),'title':'pending backup guard','steps':[{'tool':'file.write','arguments':{'path':'never-write.txt','content':'never'}}]})
  pending_run=rpc('workflows.run',{'id':pending_flow['id'],'dryRun':False})
  pending_bundle, pending_target = base/'pending-bundle', base/'pending-target'
  pending_create=run([str(helper),'backup','create','--destination',str(pending_bundle)],env=env,cwd=project)
  pending_restore=run([str(helper),'backup','restore','--bundle',str(pending_bundle),'--target',str(pending_target)],env=env,cwd=project)
  pending_env=dict(env,VELA_HOME=str(pending_target))
  def pending_call(method,params): return json.loads(run([str(helper),'call',method,'--params-stdin','--home',str(pending_target)],env=pending_env,cwd=project,data=json.dumps(params),okay=False).stdout or '{}')
  pending_approval=pending_call('dashboard.get',{'project':str(project)}).get('approvals',[])[-1]
  decision_proc=run([str(helper),'call','approvals.decide','--params-stdin','--home',str(pending_target)],env=pending_env,cwd=project,data=json.dumps({'id':pending_approval['id'],'decision':'approve','snapshotHash':pending_approval['snapshotHash']}),okay=False)
  check('pending-backup-restores-as-revoked-not-executable',pending_run.get('state')=='pending_approval' and json.loads(pending_create.stdout).get('complete') is True and json.loads(pending_restore.stdout).get('restored') is True and not (project/'never-write.txt').exists() and decision_proc.returncode!=0)
  rebackup=run([str(helper),'backup','create','--destination',str(base/'pending-restored-rebackup')],env=pending_env,cwd=project)
  check('restored-revoked-pending-does-not-block-next-backup',json.loads(rebackup.stdout).get('complete') is True)
  # Restore a second time with the same target must reject without touching it or bundle/sentinel.
  bundle_hash=sha(bundle/'manifest.json'); target_marker={str(p.relative_to(target)):sha(p) for p in target.rglob('*') if p.is_file()}; bad=run([str(helper),'backup','restore','--bundle',str(bundle),'--target',str(target)],env=env,cwd=project,okay=False)
  check('existing-target-rejected-without-mutation',bad.returncode!=0 and sha(bundle/'manifest.json')==bundle_hash and sentinel.read_text()=='outside unchanged' and {str(p.relative_to(target)):sha(p) for p in target.rglob('*') if p.is_file()}==target_marker)
  # Adversarial bundles are deliberately copied only after happy-path verification.
  for name, mutate in [('invalid-manifest-text',lambda p:p.write_text('../outside')),('asset-bytes-tamper',lambda p:p.write_bytes(b'x'))]:
   bad_bundle=base/('bad-'+name); shutil.copytree(bundle,bad_bundle); candidate=bad_bundle/'manifest.json' if name!='asset-bytes-tamper' else next(p for p in (bad_bundle/'assets').rglob('*') if p.is_file())
   mutate(candidate); rejected=run([str(helper),'backup','restore','--bundle',str(bad_bundle),'--target',str(base/('target-'+name))],env=env,cwd=project,okay=False); check(name+'-rejected',rejected.returncode!=0 and sentinel.read_text()=='outside unchanged')
  # This stays syntactically valid and recomputes manifest sha256: rejection must
  # therefore come from the asset-path guard rather than malformed JSON/checksum.
  path_bundle=base/'bad-valid-path'; shutil.copytree(bundle,path_bundle); manifest=json.loads((path_bundle/'manifest.json').read_text()); manifest['assets'][0]['path']='assets/memory/../escape.md'; payload=dict(manifest); payload.pop('sha256'); manifest['sha256']=hashlib.sha256(json.dumps(payload,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest(); (path_bundle/'manifest.json').write_text(json.dumps(manifest,sort_keys=True,separators=(',',':'),ensure_ascii=False))
  rejected=run([str(helper),'backup','restore','--bundle',str(path_bundle),'--target',str(base/'target-valid-path')],env=env,cwd=project,okay=False); path_error=(rejected.stdout+' '+rejected.stderr).lower(); check('valid-manifest-path-traversal-rejected',rejected.returncode!=0 and 'path' in path_error and 'checksum mismatch' not in path_error and sentinel.read_text()=='outside unchanged', error=path_error)
  external_assets=base/'external-assets'; external_assets.mkdir(); shutil.copytree(bundle/'assets'/'memory',external_assets/'memory'); (external_assets/'sentinel').write_bytes(b'external directory sentinel'); external_before={str(p.relative_to(external_assets)):sha(p) for p in external_assets.rglob('*') if p.is_file()}
  for name, relative, directory in [('final-asset-symlink',next(p.relative_to(bundle) for p in (bundle/'assets').rglob('*') if p.is_file()),False),('intermediate-asset-symlink',Path('assets/memory'),True)]:
   bad_bundle=base/('bad-'+name); shutil.copytree(bundle,bad_bundle); victim=bad_bundle/relative
   if directory: shutil.rmtree(victim)
   else: victim.unlink()
   victim.symlink_to((external_assets/'memory') if directory else sentinel,target_is_directory=directory); bad_target=base/('target-'+name); rejected=run([str(helper),'backup','restore','--bundle',str(bad_bundle),'--target',str(bad_target)],env=env,cwd=project,okay=False); check(name+'-rejected',rejected.returncode!=0 and sentinel.read_bytes()==b'outside unchanged' and {str(p.relative_to(external_assets)):sha(p) for p in external_assets.rglob('*') if p.is_file()}==external_before and not bad_target.exists())
  ancestor=base/'symlink-parent'; ancestor.symlink_to(base,target_is_directory=True); rejected=run([str(helper),'backup','restore','--bundle',str(bundle),'--target',str(ancestor/'symlinked-target')],env=env,cwd=project,okay=False); check('target-ancestor-symlink-rejected',rejected.returncode!=0 and sentinel.read_bytes()==b'outside unchanged' and not (base/'symlinked-target').exists())
  receipt['status']='passed' if all(x['passed'] for x in receipt['checks']) else 'failed'
 except Exception as e: receipt['failure']=type(e).__name__+': '+str(e)
 finally:
  if mcp is not None:
   try:
    stopped=stop_mcp(mcp) if mcp.poll() is None else True
   except Exception as stop_error:
    stopped=False; receipt['mcpCleanupError']=type(stop_error).__name__+': '+str(stop_error)
   receipt['mcpExitCode']=mcp.returncode
   receipt['mcpStopped']=receipt.get('mcpStopped',stopped)
  else: receipt['mcpStopped']=receipt.get('mcpStopped',True)
  if not receipt['mcpStopped']: receipt['status']='failed'
  receipt['helperSHA256After']=sha(binary); receipt['sourceAfter']=sources(source); receipt['sourceUnchanged']=receipt['sourceBefore']==receipt['sourceAfter']; receipt['helperUnchanged']=receipt['helperSHA256Before']==receipt['helperSHA256After']
  try: shutil.rmtree(base)
  except Exception as cleanup_error: receipt['cleanupError']=type(cleanup_error).__name__+': '+str(cleanup_error); receipt['status']='failed'
  receipt['fixtureRemoved']=not base.exists()
  if not receipt['sourceUnchanged'] or not receipt['helperUnchanged'] or not receipt['fixtureRemoved']: receipt['status']='failed'
  raw.write_text(json.dumps(TRANSCRIPT,indent=2)+'\n'); out.write_text(json.dumps(receipt,indent=2)+'\n')
 print(json.dumps(receipt,indent=2)); return 0 if receipt['status']=='passed' else 1
if __name__=='__main__': raise SystemExit(main())
