"""Frozen real Vela CLI -> isolated public-layout fixtures; no live provider or credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, default=root / '.build/debug/vela')
selected_binary = parser.parse_args().binary.resolve(strict=True)
checks = []
with tempfile.TemporaryDirectory(prefix='vela-setup-rpc-') as temporary:
    base = Path(temporary).resolve()
    helper = base / 'vela'
    shutil.copy2(selected_binary, helper)
    digest = hashlib.sha256(helper.read_bytes()).hexdigest()
    project, home, store = base / 'project', base / 'synthetic-home', base / 'store'
    project.mkdir(); home.mkdir()
    environment = os.environ.copy()
    environment['VELA_DISABLE_DISCOVERY'] = '1'
    environment['VELA_SESSION_ROOT'] = str(home)

    def write(path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def call(method, parameters=None, fail=False):
        assert hashlib.sha256(helper.read_bytes()).hexdigest() == digest
        result = subprocess.run([str(helper), 'call', method, json.dumps(parameters or {}), '--home', str(store)], env=environment, text=True, capture_output=True, timeout=20)
        if fail:
            assert result.returncode != 0, (method, result.stdout)
            return
        assert result.returncode == 0, (method, result.returncode, result.stderr)
        return json.loads(result.stdout)

    call('projects.add', {'path': str(project)})
    catalog = call('setup.catalog')
    assert catalog['providers'] == ['claude', 'codex', 'cursor', 'pi', 'omp']
    assert catalog['runtimeLoadedState'] == 'unavailable'
    checks.append('public_catalog_without_provider_execution')
    write(project / 'AGENTS.md', 'First line\nOriginal rule\n')
    write(project / '.claude/rules/style.md', '# Synthetic rule')
    write(project / '.cursor/hooks.json', json.dumps({'version': 1, 'hooks': {'sessionStart': [{'command': 'never execute this'}]}}))
    write(project / '.codex/config.toml', 'model="fixture"\napi_key="synthetic-config-key"')
    write(project / '.pi/settings.json', '{}')
    write(project / '.omp/config.yml', 'modelRoles:\n  default: fixture\npassword: |\n  secret-yaml-line')
    write(home / '.claude.json', 'mixed-auth-container-do-not-read')
    first = call('setup.scan', {'project': str(project)})
    assert first['scanComplete'] and not first['sourceFilesModified']
    assert not first['historyFullyObserved']
    assert {row['provider'] for row in first['artifacts']} >= {'claude', 'codex', 'cursor', 'pi', 'omp'}
    encoded = json.dumps(first)
    assert all(value not in encoded for value in ['synthetic-config-key', 'secret-yaml-line', 'mixed-auth-container-do-not-read'])
    checks.append('five_provider_source_observations_and_credential_boundaries')
    artifact = next(row for row in first['artifacts'] if row['path'] == str(project / 'AGENTS.md'))
    identity = {'id': artifact['id'], 'project': str(project)}
    call('setup.scan', {'project': str(project)})
    assert call('setup.get', identity)['revision'] == 1
    write(project / 'AGENTS.md', 'First line\nRevised rule\n')
    call('setup.scan', {'project': str(project)})
    diff = call('setup.diff', identity)
    assert diff['diffAvailable'] and diff['sourceChanged']
    assert diff['removed'] == ['Original rule'] and diff['added'] == ['Revised rule']
    assert diff['isApplyPatch'] is False
    checks.append('deduplicated_persistent_revisions_and_real_sanitized_diff')
    (project / 'AGENTS.md').unlink()
    call('setup.scan', {'project': str(project)})
    assert call('setup.get', identity)['state'] == 'deleted'
    write(project / 'AGENTS.md', 'Restored rule')
    call('setup.scan', {'project': str(project)})
    assert call('setup.get', identity)['revision'] == 4
    history = call('setup.history', identity | {'limit': 2})
    assert [row['revision'] for row in history['revisions']] == [4, 3]
    assert all('content' not in row for row in history['revisions'])
    assert [row['revision'] for row in call('setup.history', identity | {'before': history['nextBefore']})['revisions']] == [2, 1]
    checks.append('source_deletion_reappearance_and_restart_safe_history_pagination')
    for method in ['setup.get', 'setup.history', 'setup.diff', 'setup.relations']:
        call(method, identity | {'project': str(base)}, fail=True)
    mixed = next(row for row in first['artifacts'] if row['path'] == str(home / '.claude.json'))
    assert mixed['hash'] is None and mixed['contentStatus'] == 'metadata_only_mixed_auth_store'
    call('setup.get', {'id': mixed['id'], 'project': str(project)}, fail=True)
    assert call('setup.get', {'id': mixed['id'], 'scope': 'global'})['content'] == ''
    checks.append('project_and_explicit_global_read_boundaries')
    before = hashlib.sha256((project / '.cursor/hooks.json').read_bytes()).hexdigest()
    assert call('setup.scan', {'scope': 'global'})['scannedProjects'] == []
    assert before == hashlib.sha256((project / '.cursor/hooks.json').read_bytes()).hexdigest()
    assert not (project / 'never execute this').exists()
    checks.append('global_only_scan_and_no_source_mutation_or_hook_execution')
    environment.pop('VELA_SESSION_ROOT')
    write(store / '.claude/CLAUDE.md', 'isolated fallback global settings')
    fallback = call('setup.scan', {'scope': 'global'})
    assert fallback['artifacts'] and all(Path(row['path']).is_relative_to(store) for row in fallback['artifacts'])
    assert any(row.get('content') == 'isolated fallback global settings' for row in fallback['artifacts'])
    checks.append('disable_discovery_without_fixture_root_uses_store_as_global_home')

print(json.dumps({'status': 'pass', 'count': len(checks), 'checks': checks, 'binarySHA256': digest,
                  'frozenHelper': True, 'sourceData': 'synthetic configuration files only',
                  'providerCalls': 0, 'userCredentialsAccessed': False,
                  'temporaryStoreRemoved': not base.exists()}, indent=2))
