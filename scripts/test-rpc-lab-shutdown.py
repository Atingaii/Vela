#!/usr/bin/env python3
"""Exercise real RPC shutdown against a synthetic, long-running Lab child; no provider is used."""
import argparse, json, os, select, shutil, signal, subprocess, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def call(binary, home, method, params):
    result = subprocess.run([str(binary), 'call', method, json.dumps(params), '--home', str(home)], text=True, capture_output=True, timeout=15)
    if result.returncode != 0: raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return json.loads(result.stdout)

def response(process, expected, deadline):
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], min(.1, max(0, deadline-time.monotonic())))
        if not ready: continue
        line = process.stdout.readline()
        if not line: break
        row = json.loads(line)
        if row.get('id') == expected: return row['result']
    raise RuntimeError('missing RPC response ' + expected)

def gone(pid):
    try: os.kill(pid, 0)
    except ProcessLookupError: return True
    return False

def run_eof_drain(binary):
    base = Path(tempfile.mkdtemp(prefix='vela-rpc-eof-'))
    try:
        project, home = base/'project', base/'store'; project.mkdir()
        process = subprocess.Popen([str(binary),'rpc','--home',str(home),'--no-schedule'], text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # A normal one-frame pipe client closes stdin immediately. The accepted
        # write must still run; EOF is drain, not an interruption signal.
        process.stdin.write(json.dumps({'id':'accepted','method':'projects.add','params':{'path':str(project)}})+'\n'); process.stdin.close()
        stdout = process.stdout.read(); process.wait(timeout=10)
        assert process.returncode == 0, process.stderr.read()
        assert any(json.loads(line).get('id') == 'accepted' and 'result' in json.loads(line) for line in stdout.splitlines()), stdout
        projects = call(binary,home,'projects.list',{})
        assert any(Path(row.get('path','')).samefile(project) for row in projects), projects
        return {'mode':'eof-drain','helperExitCode':process.returncode,'acceptedRequestPersisted':True}
    finally:
        shutil.rmtree(base, ignore_errors=True)

def run_mode(binary, mode, phase='agent'):
    base = Path(tempfile.mkdtemp(prefix='vela-rpc-shutdown-'))
    try:
        project, home = base/'project', base/'store'; project.mkdir()
        git_env = os.environ | {'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null','GIT_TEMPLATE_DIR':str(base/'empty-template')}
        (base/'empty-template').mkdir()
        (project/'bounds.py').write_text('value = "original"\n')
        (project/'verify.py').write_text("""import json, os, pathlib, time
if os.environ.get('VELA_SHUTDOWN_PHASE') == 'verifier':
 pathlib.Path(os.environ['VELA_SHUTDOWN_MARKER']).write_text(str(os.getpid()))
 time.sleep(30)
assert True
""")
        for args in (['git','-c','core.hooksPath=/dev/null','init','-q'],['git','-c','core.hooksPath=/dev/null','add','.'],['git','-c','core.hooksPath=/dev/null','-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture']):
            subprocess.run(args, cwd=project, env=git_env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        child = base/'long-child.py'; marker = base/'child.pid'
        child.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys, time
if '--version' in sys.argv:
 print('synthetic-long-child 1'); raise SystemExit(0)
if os.environ.get('VELA_SHUTDOWN_PHASE') == 'agent': pathlib.Path(os.environ['VELA_SHUTDOWN_MARKER']).write_text(str(os.getpid()))
pathlib.Path('bounds.py').write_text('value = "changed"\\n')
print(json.dumps({'type':'thread.started','thread_id':'synthetic'}), flush=True)
if os.environ.get('VELA_SHUTDOWN_PHASE') == 'agent': time.sleep(30)
print(json.dumps({'type':'turn.completed','usage':{'input_tokens':1,'output_tokens':1}}), flush=True)
""")
        child.chmod(0o700)
        env = os.environ | {'VELA_SHUTDOWN_MARKER':str(marker),'VELA_SHUTDOWN_PHASE':phase}
        process = subprocess.Popen([str(binary),'rpc','--home',str(home),'--no-schedule'], text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        def rpc(identifier, method, params):
            process.stdin.write(json.dumps({'id':identifier,'method':method,'params':params})+'\n'); process.stdin.flush()
            return response(process, identifier, time.monotonic()+10)
        rpc('1','projects.add',{'path':str(project)})
        evaluation = rpc('2','lab.run',{'title':'synthetic shutdown fixture','project':str(project),'kind':'context','agent':{'provider':'codex','executable':str(child),'model':'synthetic','reasoningEffort':'high'},'task':'fixed synthetic task','verificationCommand':['/usr/bin/python3','verify.py'],'verificationFiles':['verify.py'],'outputFiles':['bounds.py'],'timeoutSeconds':20,'repetitions':1,'baseline':{'files':[]},'candidate':{'files':[]}})
        approval = next(row for row in rpc('3','inbox.list',{'project':str(project)}) if row['id'] == evaluation['approvalId'])
        process.stdin.write(json.dumps({'id':'4','method':'approvals.decide','params':{'id':approval['id'],'decision':'approve','snapshotHash':approval['snapshotHash']}})+'\n'); process.stdin.flush()
        deadline=time.monotonic()+8
        while not marker.exists() and time.monotonic() < deadline: time.sleep(.02)
        if not marker.exists(): raise RuntimeError('synthetic child did not start')
        pid=int(marker.read_text())
        process.send_signal(signal.SIGINT if mode == 'sigint' else signal.SIGTERM)
        process.wait(timeout=10)
        deadline=time.monotonic()+2
        while not gone(pid) and time.monotonic() < deadline: time.sleep(.02)
        observed=call(binary,home,'lab.compare',{'id':evaluation['id']})
        inbox=call(binary,home,'inbox.list',{'project':str(project)})
        observed_approval=next(row for row in inbox if row['id']==approval['id'])
        assert observed['state']=='interrupted' and observed.get('interruptionReason') and observed.get('partialResults') == 1, observed
        assert len(observed['results'])==1 and observed['results'][0]['interrupted'] is True, observed
        assert observed_approval['state']=='needs_review', observed_approval
        assert observed_approval['result']['outcomeUnknown'] is True, observed_approval
        assert gone(pid), 'owned child remained after helper exit'
        assert not (home/'lab-worktrees'/evaluation['id']).exists()
        assert (project/'bounds.py').read_text() == 'value = "original"\n'
        row=observed['results'][0]; verification=row.get('verification',{})
        # The bounded cleanup permits a child to exit on the initial SIGTERM; a
        # later SIGKILL is only the fallback when it ignores that grace period.
        if phase == 'verifier': assert verification.get('terminationSignal') in (signal.SIGTERM, signal.SIGKILL), observed
        return {'mode':mode,'phase':phase,'helperExitCode':process.returncode,'evalState':observed['state'],'approvalState':observed_approval['state'],'partialResults':len(observed['results']),'interruptionPhase':row['interruptionPhase'],'terminationSignal':row['terminationSignal'],'verificationTerminationSignal':verification.get('terminationSignal'),'orphan':False,'ownedWorktreesRemaining':False}
    finally:
        shutil.rmtree(base, ignore_errors=True)

def main():
    p=argparse.ArgumentParser(); p.add_argument('--binary',type=Path,required=True); p.add_argument('--output',type=Path,required=True); args=p.parse_args()
    binary=args.binary.resolve(strict=True); rows=[run_mode(binary,mode) for mode in ('sigint','sigterm')] + [run_mode(binary,'sigint',phase='verifier'),run_eof_drain(binary)]
    args.output.parent.mkdir(parents=True,exist_ok=True); args.output.write_text(json.dumps({'format':'vela-rpc-lab-shutdown-v1','providerRuns':0,'modes':rows},indent=2)+'\n')
    print(json.dumps({'passed':len(rows),'output':str(args.output)}))
if __name__ == '__main__': main()
