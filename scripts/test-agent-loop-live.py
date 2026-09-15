"""Opt-in, bounded real Codex verification of one reviewed synthetic tool loop.

No real project, memory, Library or connector is used. One independently approved
loop may make at most three model requests. This script never retries it.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--live', action='store_true')
parser.add_argument('--binary', type=Path, default=Path('.build/debug/vela'))
parser.add_argument('--executable', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if not args.live:
    parser.error('--live is required; no model was invoked')
args.output.mkdir(parents=True, exist_ok=False)
provider = args.executable.resolve(strict=True)
version = subprocess.run([str(provider), '--version'], capture_output=True, text=True, check=True, timeout=10).stdout.strip()
report = {'realProvider': True, 'modelRequested': 'gpt-5.6-sol', 'effortRequested': 'low',
          'modelIdentityObserved': None, 'cliVersion': version, 'maximumModelRequests': 3,
          'sourceData': 'isolated synthetic Git project only', 'externalWrites': False,
          'startedAt': datetime.now(timezone.utc).isoformat(), 'completeReferenceParity': False}
started = time.monotonic()

def save(name, value):
    (args.output / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

with tempfile.TemporaryDirectory(prefix='vela-live-tool-loop-') as temporary:
    task = Path(temporary).resolve()
    binary = task / 'vela'
    shutil.copy2(args.binary.resolve(strict=True), binary)
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    report.update(helperSHA256=binary_hash, helperFrozen=True)
    project = task / 'project'; project.mkdir()
    subprocess.run(['/usr/bin/git', 'init', '-q', str(project)], check=True, timeout=10)
    marker = 'observed-' + uuid.uuid4().hex[:12] + '.txt'
    (project / marker).write_text('Synthetic verification fixture.\n')
    environment = {**os.environ, 'VELA_DISABLE_DISCOVERY': '1'}
    environment.pop('VELA_SESSION_ROOT', None)
    store = task / 'store'

    def call(method, params, timeout=20):
        assert hashlib.sha256(binary.read_bytes()).hexdigest() == binary_hash
        process = subprocess.Popen([str(binary), 'call', method, json.dumps(params), '--home', str(store)],
                                   env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            # The helper owns a separate session, and AutomationProcess owns
            # separate child groups. Capture exact direct children before
            # stopping this disposable helper; never target unrelated jobs.
            listing = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,pgid='], capture_output=True, text=True, check=True, timeout=5)
            groups = []
            for line in listing.stdout.splitlines():
                fields = line.split()
                if len(fields) == 3:
                    pid, parent, group = map(int, fields)
                    if parent == process.pid and pid == group:
                        groups.append(group)
            for group in groups:
                try: os.killpg(group, signal.SIGTERM)
                except ProcessLookupError: pass
            try: stdout, stderr = process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                for group in groups:
                    try: os.killpg(group, signal.SIGKILL)
                    except ProcessLookupError: pass
                process.kill(); stdout, stderr = process.communicate(timeout=5)
            raise RuntimeError(method + ' exceeded its harness timeout; owned processes were stopped without retry')
        if process.returncode:
            raise RuntimeError(method + ': ' + stderr[-4000:])
        return json.loads(stdout)

    loop = None
    try:
        call('projects.add', {'path': str(project)})
        loop = call('loops.plan', {
            'project': str(project),
            'prompt': 'First call the selected git.status tool with an empty argument object. Then give a concise final answer naming the exact untracked .txt filename returned by that tool. Do not guess a filename and do not call the tool again if the result is already available. No changes, no external services, no extra tasks.',
            'agent': {'executable': str(provider), 'model': 'gpt-5.6-sol', 'reasoningEffort': 'low'},
            'tools': ['git.status'],
            'limits': {'maxModelCalls': 3, 'timeoutSeconds': 60, 'totalTimeoutSeconds': 180, 'observedTokenBudget': 0}})
        assert loop['state'] == 'pending_approval' and loop['modelCalls'] == 0
        assert marker not in loop['request']['prompt']
        assert len(loop['request']['catalog']) == 1 and loop['request']['catalog'][0]['access'] == 'read'
        assert len(call('inbox.list', {})) == 1 and call('connectors.action.list', {'project': str(project)}) == []
        save('frozen-request.json', loop)
        save('synthetic-fixture.json', {'filename': marker, 'content': 'Synthetic verification fixture.\n'})
        print(json.dumps({'state': 'approved_synthetic_readonly_loop', 'maxCalls': 3}), flush=True)
        approval = loop['approval']
        decision = call('approvals.decide', {'id': approval['id'], 'snapshotHash': approval['snapshotHash'], 'decision': 'approve'}, timeout=240)
        result = call('loops.get', {'project': str(project), 'id': loop['id']})
        save('result.json', {'decision': decision, 'loop': result})
        rounds = result.get('rounds', [])
        tool_rounds = [r for r in rounds if r.get('decision', {}).get('kind') == 'tool']
        final_rounds = [r for r in rounds if r.get('decision', {}).get('kind') == 'final']
        report.update(state=result.get('state'), approvalState=decision.get('state'), modelCalls=result.get('modelCalls'),
                      modelAttempts=result.get('modelAttempts'), toolCalls=len(tool_rounds),
                      observedTokens=result.get('observedTokens'), cost=None,
                      rounds=[{'index': r['index'], 'state': r['state'], 'promptHash': r['promptHash'],
                               'commandHash': r['commandHash'], 'process': {k:v for k,v in r.get('process', {}).items() if k != 'rawOutput'},
                               'metrics': r.get('metrics'), 'receiptHash': r.get('receipt', {}).get('receiptHash')} for r in rounds])
        assert decision['state'] == 'executed' and result['state'] == 'completed', result.get('output')
        assert 2 <= result['modelCalls'] <= 3 and 1 <= len(tool_rounds) <= 2
        assert all(r['decision']['toolId'] == 'git.status' and r['receipt']['exitCode'] == 0 for r in tool_rounds)
        assert len(final_rounds) == 1 and marker in result['output']
        assert marker in final_rounds[0]['prompt'], 'Actual tool result did not reach the subsequent prompt'
        assert result['queuedActions'] == [] and call('connectors.action.list', {'project': str(project)}) == []
        assert (project / marker).read_text() == 'Synthetic verification fixture.\n'
        assert call('memory.list', {'project': str(project)}) == [] and call('library.list', {'project': str(project)}) == []
        report.update(status='passed', realToolResultInjected=True, syntheticFileUnchanged=True)
    except Exception as error:
        report.update(status='failed', error=str(error))
        if loop:
            try: save('failure-state.json', call('loops.get', {'project': str(project), 'id': loop['id']}))
            except Exception: report['failureStateUnavailable'] = True
report['temporaryStoreRemoved'] = not task.exists()
report['durationSeconds'] = round(time.monotonic() - started, 3)
report['completedAt'] = datetime.now(timezone.utc).isoformat()
save('receipt.json', report)
print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
raise SystemExit(0 if report['status'] == 'passed' else 1)
