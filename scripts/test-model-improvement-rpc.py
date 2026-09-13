"""Frozen real Vela CLI, synthetic provider execution and isolated project/store."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
checks = []
with tempfile.TemporaryDirectory(prefix='vela-model-improve-rpc-') as temporary:
    base = Path(temporary).resolve()
    binary = base / 'vela'
    shutil.copy2(root / '.build/debug/vela', binary)
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    project = base / 'project'; project.mkdir()
    logs = base / 'logs'
    for provider in ('claude', 'codex', 'cursor', 'pi', 'omp'):
        (logs / provider).mkdir(parents=True)
    environment = os.environ.copy()
    environment.update(VELA_SESSION_ROOT=str(logs), VELA_DISABLE_DISCOVERY='1', CODEX_HOME=str(base / 'empty-provider-home'))
    home = base / 'store'

    def call(method, params=None, succeeds=True):
        result = subprocess.run([str(binary), 'call', method, json.dumps(params or {}), '--home', str(home)], env=environment, text=True, capture_output=True, timeout=30)
        if not succeeds:
            assert result.returncode != 0, (method, result.stdout)
            return
        assert result.returncode == 0, (method, result.stderr)
        return json.loads(result.stdout)

    call('projects.add', {'path': str(project)})
    for index in range(3):
        rows = [{'type': 'session', 'version': 3, 'id': f'synthetic-{index}', 'cwd': str(project), 'timestamp': '2026-09-13T00:00:00Z'}]
        for message in range(2):
            rows.append({'type': 'message', 'id': f'm-{message}', 'parentId': None if message == 0 else 'm-0', 'timestamp': '2026-09-13T00:00:00Z', 'message': {'role': 'user', 'content': f'Please verify this result before handoff, task {index}, correction {message}.'}})
        (logs / 'pi' / f'{index}.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
    call('sessions.refresh')
    sessions = call('sessions.list', {'project': str(project)})
    assert len(sessions) == 3
    checks.append('real_cli_ingests_three_synthetic_source_sessions')
    provider = base / 'synthetic-codex'
    counter = base / 'calls.jsonl'
    source = '''#!/usr/bin/python3
import json,os,stat,sys
counter=COUNTER_LITERAL
assert sys.argv[1]=='exec' and '--ignore-user-config' in sys.argv
assert sys.argv[sys.argv.index('--sandbox')+1]=='read-only'
assert stat.S_IMODE(os.stat(os.getcwd()).st_mode)==0o700
assert stat.S_IMODE(os.stat(sys.argv[sys.argv.index('--output-schema')+1]).st_mode)==0o600
data=json.loads(sys.argv[-1].split('Frozen input:\\n',1)[1]);stage=data['stage']
with open(counter,'a') as out: out.write(json.dumps({'stage':stage,'scratch':os.getcwd()})+'\\n')
if stage=='extract': result={'observations':[{'id':'o1','kind':'correction','summary':'Repeated review request','evidenceIds':[e['id'] for e in data['evidence']]}],'unresolved':[]}
elif stage=='cluster': result={'clusters':[{'id':'c1','title':'Review handoff','rationale':'Review cited messages','carrier':'Rule','observationIds':['o1']}],'unresolved':[]}
else: result={'proposals':[{'id':'p1','title':'Review before handoff','summary':'An explicit review candidate','clusterId':'c1','targetId':data['targets'][0]['id'],'content':'# Handoff review\\n\\nVerify the actual result before handing off.\\n'}],'unresolved':[]}
for event in [{'type':'thread.started','thread_id':'synthetic-'+stage},{'type':'item.completed','item':{'id':'answer','type':'agent_message','text':json.dumps(result)}},{'type':'turn.completed','usage':{'input_tokens':4,'output_tokens':6}}]: print(json.dumps(event),flush=True)
'''.replace('COUNTER_LITERAL', repr(str(counter)))
    provider.write_text(source); provider.chmod(0o700)
    descriptor = call('improve.model.describe')
    assert descriptor['manualOnly'] and descriptor['approvalRequired'] and descriptor['limits']['maxCalls'] == 3
    plan = call('improve.model.plan', {'project': str(project), 'sessionIds': [s['id'] for s in sessions], 'targets': [{'carrier': 'Rule', 'path': 'AGENTS.md'}], 'executable': str(provider), 'model': 'synthetic-explicit-model', 'timeoutSeconds': 5})
    assert plan['state'] == 'pending_approval' and not counter.exists() and not (project / 'AGENTS.md').exists()
    checks.append('frozen_request_and_approval_start_no_model_or_write')
    approval = plan['approval']
    decided = call('approvals.decide', {'id': approval['id'], 'snapshotHash': approval['snapshotHash'], 'decision': 'approve'})
    assert decided['state'] == 'executed', decided
    done = call('improve.model.get', {'project': str(project), 'id': plan['id']})
    assert done['state'] == 'drafts' and done['modelCalls'] == 3 and done['providerAttempts'] == 3
    attempts = [json.loads(line) for line in counter.read_text().splitlines()]
    assert [a['stage'] for a in attempts] == ['extract', 'cluster', 'plan']
    assert all(not Path(a['scratch']).exists() for a in attempts)
    checks.append('three_bounded_stages_and_isolated_scratch_cleanup')
    suggestion = done['suggestions'][0]
    assert len(suggestion['evidence']) == 6 and suggestion['distinctSessions'] == 3 and suggestion['claimStatus'] == 'unverified_proposal'
    assert not (project / 'AGENTS.md').exists()
    checks.append('candidates_keep_actual_evidence_and_do_not_apply')
    call('improve.apply', {'id': suggestion['id'], 'project': str(project), 'suggestionHash': 'stale'}, succeeds=False)
    call('improve.apply', {'id': suggestion['id'], 'project': str(project), 'suggestionHash': suggestion['suggestionHash']})
    assert 'Verify the actual result' in (project / 'AGENTS.md').read_text()
    call('improve.undo', {'id': suggestion['id']})
    assert not (project / 'AGENTS.md').exists()
    checks.append('reviewed_hash_apply_and_journaled_undo')
    fresh = call('improve.model.get', {'project': str(project), 'id': plan['id']})['suggestions'][0]
    dismissed = call('improve.model.transition', {'project': str(project), 'id': fresh['id'], 'suggestionHash': fresh['suggestionHash'], 'action': 'dismiss'})
    reopened = call('improve.model.transition', {'project': str(project), 'id': fresh['id'], 'suggestionHash': dismissed['suggestionHash'], 'action': 'reopen'})
    assert reopened['state'] == 'draft'
    call('approvals.decide', {'id': approval['id'], 'snapshotHash': approval['snapshotHash'], 'decision': 'approve'}, succeeds=False)
    assert len(counter.read_text().splitlines()) == 3
    checks.append('state_transitions_and_approval_replay_cannot_repeat_model')
    assert not (base / 'empty-provider-home').exists()
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == binary_hash
    checks.append('fixed_helper_and_no_real_provider_credentials')

print(json.dumps({'status': 'pass', 'count': len(checks), 'checks': checks, 'binarySHA256': binary_hash, 'frozenHelper': True, 'provider': 'synthetic executable', 'realModelCalls': 0, 'syntheticProviderInvocations': 3, 'userCredentialsAccessed': False, 'temporaryFixturesRemoved': not base.exists()}, indent=2))
