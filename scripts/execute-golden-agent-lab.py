#!/usr/bin/env python3
"""Execute one reviewed Golden Lab approval; retain uncertain/interrupted outcomes."""
import argparse, hashlib, importlib.util, json, os, signal, stat, subprocess, threading, queue, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def sha(data): return hashlib.sha256(data).hexdigest()
def save_receipt(out, receipt):
    pending=out/'receipt.pending.json'
    with pending.open('w') as stream:
        json.dump(receipt,stream,ensure_ascii=False,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
    pending.replace(out/'receipt.json')
class ExecutionInterrupted(Exception): pass
def interrupt(signum, frame): raise ExecutionInterrupted(signal.Signals(signum).name)
def load(path):
    spec=importlib.util.spec_from_file_location('golden_lab_freeze',path); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
def stop(process):
    if process and process.poll() is None:
        os.killpg(process.pid,signal.SIGTERM)
        try: process.wait(timeout=8)
        except subprocess.TimeoutExpired: os.killpg(process.pid,signal.SIGKILL); process.wait(timeout=5)
class RPC:
    def __init__(self,binary,env,cwd,out):
        self.q,self.failed,self.seq=queue.Queue(),None,0; self.log=(out/'rpc.jsonl').open('w'); self.err=(out/'helper.stderr').open('w')
        self.process=subprocess.Popen([str(binary),'rpc','--home',env['VELA_HOME'],'--no-schedule'],env=env,cwd=cwd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.err,text=True,bufsize=1,start_new_session=True)
        self.reader=threading.Thread(target=self.read,daemon=True); self.reader.start()
    def read(self):
        try:
            for line in self.process.stdout:
                if not line.endswith('\n') or len(line.encode())>32*1024*1024: raise ValueError('Invalid RPC frame')
                row=json.loads(line)
                if row.get('event')!='data.changed': self.q.put_nowait(row)
        except Exception as error: self.failed=type(error).__name__
    def call(self,method,params,deadline,cap=20,on_submitted=None):
        if method=='sessions.refresh': raise RuntimeError('Golden Lab execution cannot refresh sources')
        if self.failed or self.process.poll() is not None: raise RuntimeError('Helper stopped')
        wait=min(cap,deadline-time.monotonic())
        if wait<=0: raise RuntimeError('Execution deadline elapsed')
        self.seq+=1; request={'id':str(self.seq),'method':method,'params':params}; self.process.stdin.write(json.dumps(request)+'\n');self.process.stdin.flush()
        self.log.write(json.dumps({'phase':'submitted','request':request})+'\n');self.log.flush()
        if on_submitted: on_submitted()
        wait=min(cap,deadline-time.monotonic())
        if wait<=0: raise RuntimeError('Execution deadline elapsed')
        try: response=self.q.get(timeout=wait)
        except queue.Empty: raise RuntimeError('RPC timeout: '+method) from None
        if response.get('id')!=request['id']: raise RuntimeError('RPC identity mismatch')
        self.log.write(json.dumps({'request':request,'response':response})+'\n');self.log.flush()
        if 'error' in response or 'result' not in response: raise RuntimeError('RPC rejected '+method)
        return response['result']
    def close(self): stop(self.process);self.reader.join(timeout=2);self.log.close();self.err.close()
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--fixture',type=Path,required=True);p.add_argument('--freeze-receipt',type=Path,required=True);p.add_argument('--auth-file',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--timeout',type=int,default=1800);a=p.parse_args()
    fixture,freeze,auth,out=a.fixture.resolve(strict=True),a.freeze_receipt.resolve(strict=True),a.auth_file.absolute(),a.output.absolute()
    if not 600<=a.timeout<=2400 or out.exists() or out.is_symlink() or out.parent!=ROOT/'output/parity': p.error('Require 600–2400 seconds and a new immediate output/parity child')
    marker=json.loads((fixture/'.owner.json').read_text())
    if marker.get('format')!='vela-golden-live-owned-v1':p.error('Fixture is not owned Golden evidence')
    info=auth.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)&0o077:p.error('Auth must be existing private ordinary current-user file')
    frozen=json.loads(freeze.read_text())
    if frozen.get('status')!='pending_approval_created' or frozen.get('approvalDecision')!='not_sent' or frozen.get('newProviderRuns')!=0:p.error('Freeze receipt is not pending unchanged approval')
    out.mkdir(mode=0o700); receipt={'format':'vela-golden-agent-lab-execution-v2','status':'not_run','sameLiveSessionEvidence':True,'plannedProviderRuns':6,'newProviderRuns':0,'approvalDecision':'not_sent','approvalResponseReceived':False,'promotionAttempted':False,'freezeReceipt':str(freeze),'freezeReceiptSHA256':sha(freeze.read_bytes()),'cleanup':{}}
    save_receipt(out,receipt)
    old_handlers={sig:signal.signal(sig,interrupt) for sig in (signal.SIGINT,signal.SIGTERM)}
    rpc=None;auth_link=fixture/'codex-home/auth.json'
    try:
        support=load(ROOT/'scripts/prepare-golden-agent-lab.py'); project,helper=fixture/'Bounds',fixture/'vela-frozen'
        if auth_link.exists() or auth_link.is_symlink():raise RuntimeError('Fixture auth path must be absent before execution')
        if sha(helper.read_bytes())!=frozen.get('helperSHA256'):raise RuntimeError('Frozen helper differs')
        before=support.project_snapshot(project); (out/'project-before.json').write_text(json.dumps(before,indent=2)+'\n')
        if before['manifestSHA256']!=frozen.get('projectSnapshotAfter') or before['gitStatusSHA256']!=frozen.get('gitStatusAfter'):raise RuntimeError('Project changed after Lab freeze')
        auth_link.symlink_to(auth); env={k:v for k,v in os.environ.items() if not k.startswith(('VELA_','CODEX_'))};env.update(CODEX_HOME=str(fixture/'codex-home'),VELA_HOME=str(fixture/'store'),VELA_SESSION_ROOT=str(fixture/'sources'),VELA_DISABLE_DISCOVERY='1')
        rpc=RPC(helper,env,fixture,out);deadline=time.monotonic()+a.timeout; rpc.call('projects.add',{'path':str(project)},deadline)
        approvals=rpc.call('inbox.list',{'project':str(project)},deadline); approval=next((row for row in approvals if row.get('id')==frozen.get('approvalId')),None)
        evaluation_id=frozen.get('evaluation',{}).get('id')
        if not approval or approval.get('state')!='pending' or approval.get('tool')!='lab.execute' or approval.get('snapshotHash') is None or approval.get('runId')!=evaluation_id:raise RuntimeError('Frozen approval is no longer exact pending Lab action')
        evaluation=rpc.call('lab.compare',{'id':evaluation_id},deadline)
        if evaluation.get('state')!='pending_approval' or evaluation.get('approvalId')!=approval['id'] or evaluation.get('sourceSuggestionId')!=frozen.get('suggestionId') or set(row.get('id') for row in evaluation.get('candidate',{}).get('memories',[]))!=set(frozen.get('candidateMemoryIds',[])):raise RuntimeError('Eval payload differs from reviewed freeze')
        receipt.update(helperSHA256=sha(helper.read_bytes()),approvalId=approval['id'],approvalSnapshotHash=approval['snapshotHash'],evaluationId=evaluation_id,projectSnapshotBefore=before['manifestSHA256'],gitStatusBefore=before['gitStatusSHA256'])
        # Persist before dispatch: a killed process must never imply the approval was not sent.
        receipt.update(status='approval_dispatching',approvalDecision='dispatch_uncertain',newProviderRuns=None)
        save_receipt(out,receipt)
        def submitted():
            receipt.update(status='approval_submitted',approvalDecision='approve',approvalRequestSubmitted=True)
            save_receipt(out,receipt)
        result=rpc.call('approvals.decide',{'id':approval['id'],'decision':'approve','snapshotHash':approval['snapshotHash']},deadline,cap=max(600,min(2300,a.timeout)),on_submitted=submitted)
        receipt['approvalResponseReceived']=True;save_receipt(out,receipt)
        (out/'approval-result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        compared=rpc.call('lab.compare',{'id':evaluation_id},deadline)
        (out/'evaluation.json').write_text(json.dumps(compared,ensure_ascii=False,indent=2)+'\n')
        raw=[]
        for index,row in enumerate(compared.get('results',[]),1):
            data=str(row.get('output','')).encode();path=out/f'agent-result-{index}.jsonl';path.write_bytes(data);raw.append({'index':index,'variant':row.get('variant'),'repetition':row.get('repetition'),'bytes':len(data),'sha256':sha(data)})
        receipt['rawAgentResults']=raw;receipt['recordedProviderResults']=len(raw)
        if len(raw)!=6:raise RuntimeError('Expected exactly six paired Agent Lab results')
        receipt['newProviderRuns']=6;summary=compared.get('summary',{});decision=summary.get('decision')
        receipt['comparison']={'state':compared.get('state'),'decision':decision,'summary':summary}
        if decision!='ready_for_review':
            receipt['promotionAttempted']=True
            try:rpc.call('lab.promote',{'id':evaluation_id},deadline)
            except RuntimeError: receipt['promotionRejectedForNonReadyDecision']=True
            else: raise RuntimeError('Non-ready evaluation unexpectedly promoted')
        after=support.project_snapshot(project);(out/'project-after.json').write_text(json.dumps(after,indent=2)+'\n')
        if before!=after:raise RuntimeError('Agent Lab changed original project regular files or Git status')
        receipt.update(status='completed_no_auto_promotion',projectSnapshotAfter=after['manifestSHA256'],gitStatusAfter=after['gitStatusSHA256'])
    except (ExecutionInterrupted,KeyboardInterrupt) as error:
        receipt.update(status='interrupted_outcome_unknown' if receipt['approvalDecision']!='not_sent' else 'interrupted_before_approval',failure=str(error) or 'KeyboardInterrupt')
    except Exception as error:receipt.update(status='failed_outcome_unknown' if receipt['approvalDecision']!='not_sent' and not receipt['approvalResponseReceived'] else 'failed',failure=str(error)[:3000])
    finally:
        # Finish the bounded helper stop and the owned auth-link cleanup even after one signal.
        for sig in old_handlers: signal.signal(sig,signal.SIG_IGN)
        try:
            if rpc:rpc.close()
        except Exception as error:receipt['cleanup']['helperStopError']=str(error)[:1000]
        try:
            if auth_link.is_symlink():
                if os.readlink(auth_link)!=str(auth):raise RuntimeError('Auth link changed; cleanup requires review')
                auth_link.unlink()
            elif auth_link.exists():raise RuntimeError('Unexpected auth file in fixture')
        except Exception as error:receipt['cleanup']['authCleanupError']=str(error)[:1000]
        receipt['cleanup'].update(temporaryAuthRemoved=not (auth_link.exists() or auth_link.is_symlink()),helperStopped=rpc is None or rpc.process.poll() is not None,credentialCopied=False)
        receipt['cleanup']['ownedChildProcessesVerifiedStopped']=False
        if 'helperStopError' in receipt['cleanup'] or 'authCleanupError' in receipt['cleanup']:receipt['status']='cleanup_requires_review'
        save_receipt(out,receipt)
        for sig,handler in old_handlers.items():signal.signal(sig,handler)
        print(json.dumps({'receipt':str(out/'receipt.json'),'status':receipt['status'],'approvalDecision':receipt['approvalDecision']},ensure_ascii=False))
    return 0 if receipt['status']=='completed_no_auto_promotion' else 1
if __name__=='__main__':raise SystemExit(main())
