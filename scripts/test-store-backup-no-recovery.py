#!/usr/bin/env python3
"""Regression acceptance: `vela backup create` must not recover an interrupted SafeApply journal.

The workflow and its managed output are created through public RPC.  SQLite is used
only after that completed flow to model a crash after the output rename and before
its durable journal transitioned from `committing` to `applied`.
"""
import argparse, hashlib, json, os, shutil, sqlite3, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRANSCRIPT=[]
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def source_hashes(root): return {str(p.relative_to(root)):sha(p) for p in sorted((root/'Sources').rglob('*.swift'))}
def invoke(argv, *, env, cwd, data=None, okay=True):
    result=subprocess.run(argv,input=data,text=True,capture_output=True,env=env,cwd=cwd,timeout=45)
    TRANSCRIPT.append({'argv':argv,'stdin':data,'stdout':result.stdout,'stderr':result.stderr,'exitCode':result.returncode})
    if okay and result.returncode: raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result

def main():
    p=argparse.ArgumentParser(); p.add_argument('--binary',type=Path,required=True); p.add_argument('--source-root',type=Path,required=True); p.add_argument('--output',type=Path,required=True); a=p.parse_args()
    binary=a.binary.resolve(strict=True); source=a.source_root.resolve(strict=True); out=a.output.resolve(); raw=out.with_suffix('.raw.json')
    if out.exists() or raw.exists() or out.is_symlink() or raw.is_symlink(): p.error('output and raw must be new regular paths')
    out.parent.mkdir(parents=True,exist_ok=True); (ROOT/'.task-tmp').mkdir(exist_ok=True)
    receipt={'format':'vela-backup-no-recovery-r1','status':'failed','expectedRegression':'backup create must not mutate interrupted SafeApply state','helperSHA256Before':sha(binary),'sourceBefore':source_hashes(source),'checks':[],'providerRuns':0,'synthetic':True}
    base=Path(tempfile.mkdtemp(prefix='backup-no-recovery-',dir=ROOT/'.task-tmp')).resolve()
    def check(name,passed,**details): receipt['checks'].append({'name':name,'passed':bool(passed),**details})
    try:
        helper=base/'vela'; shutil.copy2(binary,helper); helper.chmod(0o755)
        home=base/'home'; project=base/'project'; bundle=base/'bundle'; project.mkdir()
        env=dict(os.environ,HOME=str(base),VELA_HOME=str(home),VELA_SESSION_ROOT=str(base/'empty-logs'),VELA_DISABLE_DISCOVERY='1',GIT_CONFIG_GLOBAL=os.devnull,GIT_CONFIG_NOSYSTEM='1')
        invoke(['/usr/bin/git','init','-q'],env=env,cwd=project)
        def rpc(method,params):
            return json.loads(invoke([str(helper),'call',method,'--params-stdin','--home',str(home)],env=env,cwd=project,data=json.dumps(params)).stdout)
        # Public flow: a registered isolated Git project and a read-only workflow
        # whose output delivery takes the actual SafeApply path.
        rpc('projects.add',{'path':str(project)})
        workflow=rpc('workflows.save',{'id':'backup-no-recovery','project':str(project),'title':'Read Git state for backup regression','trigger':'manual','steps':[{'id':'status','title':'Read Git status','tool':'git.status','arguments':{}}],'output':{'target':'file','path':'backup-no-recovery.md','stepId':'status'}})
        run=rpc('workflows.run',{'id':workflow['id'],'dryRun':False})
        output=home/'output'/'backup-no-recovery.md'
        public_flow_ok=run.get('state')=='completed' and output.is_file()
        if not public_flow_ok: raise RuntimeError('public read-only workflow did not deliver managed output')
        output_before=output.read_bytes()
        # Crash seam only: preserve the already-renamed bytes and change precisely
        # the completed SafeApply journal state to its post-rename crash state.
        db=home/'vela.sqlite3'; con=sqlite3.connect(db)
        rows=con.execute("SELECT id,json FROM objects WHERE kind='apply_journal' ORDER BY id").fetchall()
        if len(rows)!=1: raise RuntimeError(f'expected one applied SafeApply journal, got {len(rows)}')
        journal_id,journal_text=rows[0]; journal=json.loads(journal_text)
        if journal.get('state')!='applied': raise RuntimeError('public workflow did not produce applied SafeApply journal')
        journal['state']='committing'; journal.pop('completedAt',None)
        con.execute("UPDATE objects SET json=? WHERE kind='apply_journal' AND id=?",(json.dumps(journal,sort_keys=True,separators=(',',':')),journal_id)); con.commit(); con.close()
        receipt['crashSeam']={'database':str(db),'journalId':journal_id,'stateBeforeBackup':'committing','outputSHA256BeforeBackup':hashlib.sha256(output_before).hexdigest()}
        # Deliberately no RPC/router command between the seam and backup create.
        created=invoke([str(helper),'backup','create','--destination',str(bundle)],env=env,cwd=project)
        created_json=json.loads(created.stdout)
        con=sqlite3.connect(db); after_row=con.execute("SELECT json FROM objects WHERE kind='apply_journal' AND id=?",(journal_id,)).fetchone(); con.close()
        journal_after=json.loads(after_row[0]) if after_row else {}
        bundle_output=bundle/'output'/'backup-no-recovery.md'
        manifest=json.loads((bundle/'manifest.json').read_text()) if (bundle/'manifest.json').is_file() else {}
        output_rows=manifest.get('outputs',[]) if isinstance(manifest,dict) else []
        check('public-readonly-workflow-created-applied-journal-and-output',public_flow_ok and receipt['crashSeam']['stateBeforeBackup']=='committing')
        check('backup-create-does-not-recover-or-alter-preexisting-output',output.is_file() and output.read_bytes()==output_before)
        check('backup-create-leaves-interrupted-journal-committing',journal_after.get('state')=='committing',actualState=journal_after.get('state'))
        check('backup-preserves-preexisting-managed-output',created_json.get('complete') is True and bundle_output.is_file() and bundle_output.read_bytes()==output_before and any(r.get('path')=='output/backup-no-recovery.md' for r in output_rows))
        receipt['status']='passed' if all(x['passed'] for x in receipt['checks']) else 'failed'
    except Exception as error:
        receipt['failure']=type(error).__name__+': '+str(error)
    finally:
        receipt['helperSHA256After']=sha(binary); receipt['sourceAfter']=source_hashes(source); receipt['helperUnchanged']=receipt['helperSHA256Before']==receipt['helperSHA256After']; receipt['sourceUnchanged']=receipt['sourceBefore']==receipt['sourceAfter']
        try: shutil.rmtree(base)
        except Exception as error: receipt['cleanupError']=type(error).__name__+': '+str(error); receipt['status']='failed'
        receipt['fixtureRemoved']=not base.exists()
        if not receipt['helperUnchanged'] or not receipt['sourceUnchanged'] or not receipt['fixtureRemoved']: receipt['status']='failed'
        raw.write_text(json.dumps(TRANSCRIPT,indent=2)+'\n'); out.write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2)); return 0 if receipt['status']=='passed' else 1
if __name__=='__main__': raise SystemExit(main())
