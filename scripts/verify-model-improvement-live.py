"""Explicit, bounded paid-provider verification over synthetic material only.

Never run from CI. --live authorizes one reviewed pipeline, at most three calls,
using the fixed provider/model/effort below. It never applies a candidate.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--live', action='store_true', help='Explicitly run at most three real Codex requests; may consume subscription usage.')
parser.add_argument('--executable', type=Path, required=True, help='Explicit absolute path to the reviewed Codex executable.')
parser.add_argument('--output', help='New evidence directory; existing directories are refused.')
args = parser.parse_args()
if not args.live:
    parser.error('--live is required; no provider request was started')
if not args.executable.is_absolute():
    parser.error('--executable must be an absolute path; no provider request was started')

root = Path(__file__).resolve().parents[1]
parent = root / 'output/parity/live-provider'
if args.output:
    evidence_dir = Path(args.output).resolve()
else:
    sequence = 1
    while (parent / f'model-improve-attempt-{sequence}').exists():
        sequence += 1
    evidence_dir = parent / f'model-improve-attempt-{sequence}'
evidence_dir.mkdir(parents=True, exist_ok=False)
provider = args.executable.resolve(strict=True)
version = subprocess.run([str(provider), '--version'], capture_output=True, text=True, timeout=10, check=True).stdout.strip()
if version != 'codex-cli 0.154.0':
    raise SystemExit(f'Provider version changed ({version}); no model request was started. Review this script before continuing.')

def save(name, value):
    (evidence_dir / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

started = time.monotonic()
receipt = {'operation': 'Model Improve live synthetic acceptance', 'realProvider': True, 'sourceData': 'synthetic only', 'requestedModel': 'gpt-5.6-sol', 'requestedEffort': 'low', 'cliVersion': version, 'maxProviderRequests': 3, 'stageTimeoutSeconds': 90, 'automaticallyApplied': False, 'qualityImprovementClaim': False, 'adapterReadCredentialsDirectly': False, 'startedAt': datetime.now(timezone.utc).isoformat()}
failure = None
with tempfile.TemporaryDirectory(prefix='vela-live-model-improve-') as temporary:
    base = Path(temporary).resolve()
    binary = base / 'vela'
    shutil.copy2(root / '.build/debug/vela', binary)
    helper_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    receipt.update(helperSHA256=helper_hash, helperFrozen=True)
    project = base / 'synthetic-review-project'; project.mkdir()
    logs = base / 'synthetic-logs'
    for harness in ('claude', 'codex', 'cursor', 'pi', 'omp'):
        (logs / harness).mkdir(parents=True)
    environment = os.environ.copy()
    environment.update(VELA_SESSION_ROOT=str(logs), VELA_DISABLE_DISCOVERY='1')
    store = base / 'store'
    def call(method, params=None, timeout=20):
        assert hashlib.sha256(binary.read_bytes()).hexdigest() == helper_hash, 'Frozen helper changed'
        response = subprocess.run([str(binary), 'call', method, json.dumps(params or {}), '--home', str(store)], env=environment, text=True, capture_output=True, timeout=timeout)
        assert response.returncode == 0, (method, response.returncode, response.stderr)
        return json.loads(response.stdout)

    source_rows = {}
    original_quotes = set()
    plan = None
    try:
        call('projects.add', {'path': str(project)})
        for index in range(3):
            text = [
                f'For repository task {index + 1}, you forgot to run the relevant project tests before handoff. Please check the actual result.',
                'For future tasks in this repository, run the relevant project tests before handing off and report the exact pass or failure result. If you could not run them, say so explicitly.'
            ]
            original_quotes.update(text)
            rows = [{'type': 'session', 'version': 3, 'id': f'synthetic-review-{index}', 'cwd': str(project), 'timestamp': '2026-09-13T00:00:00Z'}]
            for message_index, content in enumerate(text):
                rows.append({'type': 'message', 'id': f'synthetic-message-{message_index}', 'parentId': None if message_index == 0 else 'synthetic-message-0', 'timestamp': '2026-09-13T00:00:00Z', 'message': {'role': 'user', 'content': content}})
            name = f'review-{index}.jsonl'
            (logs / 'pi' / name).write_text(''.join(json.dumps(row) + '\n' for row in rows))
            source_rows[name] = rows
        save('synthetic-sources.json', source_rows)
        refreshed = call('sessions.refresh')
        assert not refreshed['diagnostics'], refreshed
        sessions = call('sessions.list', {'project': str(project)})
        assert len(sessions) == 3 and all(s['provider'] == 'pi' for s in sessions)
        params = {'project': str(project), 'sessionIds': [s['id'] for s in sessions], 'targets': [{'carrier': 'Rule', 'path': 'AGENTS.md'}], 'executable': str(provider), 'model': 'gpt-5.6-sol', 'effort': 'low', 'maxCalls': 3, 'timeoutSeconds': 90, 'maxEvidence': 60, 'maxEvidenceBytes': 24000, 'maxPromptBytes': 60000}
        plan = call('improve.model.plan', params)
        save('frozen-request-approval.json', plan)
        frozen = plan['request']
        assert plan['state'] == 'pending_approval' and plan['modelCalls'] == 0 and plan['providerAttempts'] == 0
        assert len(frozen['evidence']) == 6 and len(frozen['sources']) == 3 and frozen['omittedMessages'] == 0
        assert all(e['quote'] in original_quotes and e['role'] == 'user' and not e['redacted'] and not e['truncated'] for e in frozen['evidence'])
        assert all(e['sourceHash'] == hashlib.sha256(e['quote'].encode()).hexdigest() for e in frozen['evidence'])
        assert frozen['targets'] == [{'id': 'target-1', 'carrier': 'Rule', 'path': str(project / 'AGENTS.md'), 'baseHash': 'absent', 'content': ''}]
        assert frozen['maxCalls'] == 3 and frozen['timeoutSeconds'] == 90 and frozen['trigger'] == 'manual'
        assert not (project / 'AGENTS.md').exists()
        input_check = {'syntheticMaterialOnly': True, 'exactSourceSessions': 3, 'exactEvidenceMessages': 6, 'libraryRead': False, 'targetPreviouslyAbsent': True, 'modelCallsBeforeApproval': 0, 'requestHash': plan['requestHash'], 'helperSHA256': helper_hash, 'verifiedAt': datetime.now(timezone.utc).isoformat()}
        save('input-review.json', input_check)
        print(json.dumps({'state': 'synthetic_input_verified', 'evidenceDirectory': str(evidence_dir), 'maxProviderRequests': 3, 'stageTimeoutSeconds': 90}), flush=True)
        approval = plan['approval']
        # The single approval is authorized by explicit --live. No retry loop.
        decision = call('approvals.decide', {'id': approval['id'], 'snapshotHash': approval['snapshotHash'], 'decision': 'approve'}, timeout=300)
        save('approval-result.json', decision)
        done = call('improve.model.get', {'project': str(project), 'id': plan['id']})
        save('result.json', done)
        receipt.update(state=done['state'], providerAttempts=done['providerAttempts'], completedModelCalls=done['completedModelCalls'], modelCalls=done['modelCalls'], observedModel=done['observedModel'], stages=[{'stage': s['stage'], 'state': s['state'], 'exitCode': s['exitCode'], 'durationMs': s['durationMs'], 'metrics': s.get('metrics'), 'protocolHash': s['protocolHash']} for s in done['stages']], candidateCount=len(done['suggestions']))
        assert decision['state'] == 'executed' and done['state'] == 'drafts', (decision['state'], done['state'], done.get('error'))
        assert done['providerAttempts'] == 3 and done['completedModelCalls'] == 3 and done['modelCalls'] == 3
        assert [s['stage'] for s in done['stages']] == ['extract', 'cluster', 'plan']
        actual_evidence = {e['id']: e for e in frozen['evidence']}
        assert done['suggestions'] and all(s['state'] == 'draft' and s['claimStatus'] == 'unverified_proposal' for s in done['suggestions'])
        assert all(e == actual_evidence[e['id']] for s in done['suggestions'] for e in s['evidence'])
        assert all(op['path'] == str(project / 'AGENTS.md') and op['baseHash'] == 'absent' for s in done['suggestions'] for op in s['operations'])
        assert not (project / 'AGENTS.md').exists() and call('memory.list', {'project': str(project)}) == []
        assert hashlib.sha256(binary.read_bytes()).hexdigest() == helper_hash
        receipt.update(status='pass', citationChainVerified=True, candidateRemainsUnapplied=True, activeMemoryCreated=False)
    except Exception as error:
        failure = str(error)
        receipt.update(status='failed', error=failure)
        if plan is not None:
            try:
                current = call('improve.model.get', {'project': str(project), 'id': plan['id']})
                save('failure-state.json', current)
                receipt.update(providerAttempts=current.get('providerAttempts'), completedModelCalls=current.get('completedModelCalls'), modelCalls=current.get('modelCalls'), state=current.get('state'))
            except Exception:
                receipt['failureStateUnavailable'] = True
    receipt['durationSeconds'] = round(time.monotonic() - started, 3)

receipt['temporaryStoreRemoved'] = not base.exists()
receipt['completedAt'] = datetime.now(timezone.utc).isoformat()
save('receipt.json', receipt)
print(json.dumps({'status': receipt['status'], 'receipt': str(evidence_dir / 'receipt.json'), 'providerAttempts': receipt.get('providerAttempts'), 'candidateCount': receipt.get('candidateCount'), 'temporaryStoreRemoved': receipt['temporaryStoreRemoved']}, ensure_ascii=False), flush=True)
if failure:
    raise SystemExit(1)
