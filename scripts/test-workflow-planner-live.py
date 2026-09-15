"""Opt-in real provider verification of one approved workflow planning request.

Only a synthetic description is sent. No user project, conversation, memory or
external connector is included. This consumes the chosen provider allowance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, default=Path('.build/debug/vela'))
parser.add_argument('--executable', type=Path, required=True)
parser.add_argument('--model', required=True)
parser.add_argument('--effort', default='low')
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--live', action='store_true')
args = parser.parse_args()
if not args.live:
    parser.error('--live is required for a real provider call')
if args.output.exists():
    parser.error('Choose a new evidence directory; existing evidence is retained')
args.output.mkdir(parents=True)
source_binary = args.binary.resolve(strict=True)
executable = args.executable.resolve(strict=True)
report = {'realProvider': True, 'modelRequested': args.model, 'effortRequested': args.effort,
          'binarySHA256': hashlib.sha256(source_binary.read_bytes()).hexdigest(),
          'scope': 'one synthetic planner request; no project contents or external tools',
          'workflowAutomaticallySaved': False, 'completeReferenceParity': False}
started = time.monotonic()
try:
    with tempfile.TemporaryDirectory(prefix='vela-live-planner-') as temporary:
        task = Path(temporary).resolve()
        binary = task / 'vela'
        shutil.copy2(source_binary, binary)
        report['binarySHA256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
        report['binaryFrozenForAllCalls'] = True
        project = task / 'project'
        project.mkdir()
        subprocess.run(['/usr/bin/git', '-C', str(project), 'init', '-q'], check=True)
        env = {**os.environ, 'VELA_DISABLE_DISCOVERY': '1'}
        env.pop('VELA_SESSION_ROOT', None)

        def call(method, params):
            result = subprocess.run([str(binary), 'call', method, json.dumps(params), '--home', str(task / 'store')],
                                    env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=110)
            if result.returncode:
                raise RuntimeError(method + ': ' + result.stderr[-4000:])
            return json.loads(result.stdout)

        call('projects.add', {'path': str(project)})
        plan = call('workflows.plan', {
            'project': str(project), 'executable': str(executable), 'model': args.model,
            'effort': args.effort, 'timeoutSeconds': 90,
            'description': 'Create a manual workflow titled Working tree report. Read only git.status, then produce a short report summarizing changed files. Do not change any files or call external services. No additional information is needed.'})
        approval = plan['approval']
        assert plan['state'] == 'pending_approval'
        assert approval['arguments']['requestHash'] == plan['requestHash']
        command = approval['arguments']['commandTemplate']
        assert command[0] == str(executable) and '--sandbox' in command and 'read-only' in command
        assert '--ignore-user-config' in command and '--ignore-rules' in command
        assert len(call('workflows.list', {'project': str(project)})) == 0
        (args.output / 'frozen.json').write_text(json.dumps(plan, indent=2) + '\n')
        print(json.dumps({'state': 'approved-synthetic-planner', 'model': args.model}), flush=True)
        decision = call('approvals.decide', {'id': approval['id'], 'snapshotHash': approval['snapshotHash'], 'decision': 'approve'})
        final = call('workflows.plan.get', {'project': str(project), 'id': plan['id']})
        (args.output / 'result.json').write_text(json.dumps({'decision': decision, 'plan': final}, indent=2) + '\n')
        report.update({'approvalState': decision.get('state'), 'planState': final.get('state'),
                       'questions': final.get('questions', []), 'unresolved': final.get('unresolved', []),
                       'error': final.get('error'), 'savedWorkflowCount': len(call('workflows.list', {'project': str(project)}))})
        assert final['state'] == 'draft', final.get('error', final['state'])
        assert final['draft']['enabled'] is False
        assert report['savedWorkflowCount'] == 0
        assert final.get('savedWorkflow') is False
        # Accepting the returned, reviewed disabled draft is a separate action.
        accepted = call('workflows.save', final['draft'])
        assert accepted['enabled'] is False and accepted['trigger'] == 'manual'
        assert len(call('workflows.list', {'project': str(project)})) == 1
        report['explicitlyAcceptedDisabledDraft'] = True
        report['status'] = 'passed'
except Exception as error:
    report['status'] = 'failed'
    report['error'] = str(error)
finally:
    report['durationSeconds'] = round(time.monotonic() - started, 3)
    report['temporaryStoreRemoved'] = 'task' in locals() and not task.exists()
    (args.output / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2), flush=True)
if report['status'] != 'passed':
    raise SystemExit(1)
