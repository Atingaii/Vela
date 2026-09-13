"""Pi/OMP ingestion through the real CLI, using isolated synthetic session files."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import shutil

root = Path(__file__).resolve().parents[1]
binary = root / '.build/debug/vela'
checks = []

with tempfile.TemporaryDirectory(prefix='vela-provider-rpc-') as temporary:
    base = Path(temporary).resolve()
    frozen_binary = base / 'vela'
    shutil.copy2(binary, frozen_binary)
    binary_hash = hashlib.sha256(frozen_binary.read_bytes()).hexdigest()
    project = base / 'project'
    project.mkdir()
    logs = base / 'logs'
    for provider in ('claude', 'codex', 'cursor', 'pi', 'omp'):
        (logs / provider).mkdir(parents=True)
    environment = os.environ.copy()
    environment['VELA_SESSION_ROOT'] = str(logs)
    environment['VELA_HOME'] = str(base / 'store')
    environment['VELA_DISABLE_DISCOVERY'] = '1'

    def call(method, parameters=None):
        result = subprocess.run([str(frozen_binary), 'call', method, json.dumps(parameters or {}), '--home', str(base / 'store')], env=environment, text=True, capture_output=True, timeout=20)
        assert result.returncode == 0, (method, result.returncode, result.stderr)
        return json.loads(result.stdout)

    call('projects.add', {'path': str(project)})
    names = [item['id'] for item in call('agents.list')]
    assert names == ['claude', 'codex', 'cursor', 'pi', 'omp'], names
    checks.append('five_harness_cli_inventory')
    sources = {}
    for provider in ('pi', 'omp'):
        rows = [
            {'type': 'session', 'version': 3, 'id': provider + '-synthetic', 'cwd': str(project), 'timestamp': '2026-09-13T01:00:00Z'},
            {'type': 'message', 'id': 'u', 'parentId': None, 'timestamp': '2026-09-13T01:00:01Z', 'message': {'role': 'user', 'content': "原文 don't change", 'timestamp': 1789261201000}},
            {'type': 'message', 'id': 'a', 'parentId': 'u', 'timestamp': '2026-09-13T01:00:02Z', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Task complete'}], 'provider': 'fixture-model-provider', 'model': 'fixture-model', 'stopReason': 'stop', 'usage': {'input': 20, 'output': 4, 'cacheRead': 2, 'cacheWrite': 1}}},
        ]
        text = ''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows)
        if provider == 'omp':
            slot = json.dumps({'type': 'title', 'title': 'OMP source title'})
            text = slot + ' ' * (255 - len(slot.encode())) + '\n' + text
        source = logs / provider / 'synthetic.jsonl'
        source.write_text(text)
        sources[provider] = (source, hashlib.sha256(source.read_bytes()).hexdigest())
    result = call('sessions.refresh')
    assert result['sourcesUpdated'] == 2, result
    all_sessions = call('sessions.list', {'project': str(project)})
    assert len(all_sessions) == 2, all_sessions
    for item in all_sessions:
        provider = item['provider']
        session = call('sessions.get', {'id': item['id']})
        assert session['sourceSessionId'] == provider + '-synthetic'
        assert session['modelProvider'] == 'fixture-model-provider'
        assert session['model'] == 'fixture-model'
        assert session['branch'] is None
        assert session['state'] == 'Completed' and session['liveStatusAvailable'] is False
        assert session['tokenInput'] == 23 and session['tokenOutput'] == 4
        assert session['messages'][0]['content'] == "原文 don't change"
        source, digest = sources[provider]
        assert hashlib.sha256(source.read_bytes()).hexdigest() == digest
        checks.append(provider + '_persistent_source_identity_messages_usage')
    assert call('sessions.refresh')['sourcesUpdated'] == 0
    checks.append('unchanged_source_refresh_is_noop')
    usage = call('usage.get', {'project': str(project)})
    assert usage['totalTokens'] == 54 and usage['quotaAvailable'] is False
    checks.append('combined_observed_usage_is_not_quota')
    other = base / 'other'
    other.mkdir()
    call('projects.add', {'path': str(other)})
    assert call('sessions.list', {'project': str(other)}) == []
    checks.append('project_scoping')
    before = call('sessions.list', {'project': str(project)})
    sources['pi'][0].write_text(json.dumps({'type': 'session', 'version': 999, 'id': 'unknown', 'cwd': str(project)}) + '\n')
    rejected = call('sessions.refresh')
    assert rejected['diagnostics'] and rejected['sourcesUpdated'] == 0
    assert call('sessions.list', {'project': str(project)}) == before
    checks.append('future_schema_preserves_previous_snapshot')

print(json.dumps({'status': 'pass', 'checks': checks, 'count': len(checks), 'binarySHA256': binary_hash, 'frozenHelper': True, 'fixtures': 'synthetic', 'temporaryStoreRemoved': not base.exists()}, indent=2))
