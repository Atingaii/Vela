"""Real Vela CLI -> synthetic Codex app-server; no user credentials or model call."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import shutil

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, default=root / '.build/debug/vela')
binary = parser.parse_args().binary.resolve(strict=True)
checks = []

with tempfile.TemporaryDirectory(prefix='vela-quota-rpc-') as temporary:
    base = Path(temporary).resolve()
    frozen_binary = base / 'vela'
    shutil.copy2(binary, frozen_binary)
    binary_hash = hashlib.sha256(frozen_binary.read_bytes()).hexdigest()
    helper = base / 'codex'
    home = base / 'store'
    environment = os.environ.copy()
    environment['VELA_DISABLE_DISCOVERY'] = '1'
    environment['CODEX_HOME'] = str(base / 'empty-provider-home')
    environment['SYNTHETIC_API_TOKEN'] = 'must-not-forward'

    def call(method, parameters):
        result = subprocess.run([str(frozen_binary), 'call', method, json.dumps(parameters), '--home', str(home)], env=environment, text=True, capture_output=True, timeout=20)
        assert result.returncode == 0, (method, result.returncode, result.stderr)
        return json.loads(result.stdout)

    def server(fail=False):
        body = '''#!/usr/bin/python3
import json, os, sys, time
assert sys.argv[1:] == ['app-server', '--stdio']
assert 'SYNTHETIC_API_TOKEN' not in os.environ
first = json.loads(sys.stdin.readline())
assert first['method'] == 'initialize'
assert first['params']['clientInfo']['name'] == 'vela'
print(json.dumps({'id':1,'result':{}}),flush=True)
assert json.loads(sys.stdin.readline()) == {'method':'initialized'}
assert json.loads(sys.stdin.readline()) == {'method':'account/rateLimits/read','id':2}
'''
        response = {'id': 2, 'error': {'code': -32000, 'message': 'Not logged in SYNTHETIC_SECRET'}} if fail else {'id': 2, 'result': {'rateLimitsByLimitId': {'a': {'limitId': 'unknown-real-bucket', 'limitName': 'Source label', 'primary': {'usedPercent': 0, 'windowDurationMins': 300, 'resetsAt': 2000000000}, 'secondary': None}}, 'account': {'email': 'SYNTHETIC_SECRET'}}}
        body += 'print(' + repr(json.dumps(response)) + ',flush=True)\ntime.sleep(10)\n'
        helper.write_text(body)
        helper.chmod(0o700)

    initial = call('usage.quota.status', {'provider': 'codex'})
    assert initial['status'] == 'never_read' and initial['snapshot'] is None
    checks.append('initial_status_does_not_start_provider')
    server()
    first = call('usage.quota.read', {'provider': 'codex', 'executable': str(helper)})
    assert first['status'] == 'fresh' and first['quotaAvailable'] is True, first
    buckets = first['snapshot']['buckets']
    assert buckets[0]['key'] == 'a' and buckets[0]['limitId'] == 'unknown-real-bucket'
    assert buckets[0]['windows'][0]['remainingPercent'] == 100
    assert first['snapshot']['observedAt'] == first['sourceCapturedAt']
    assert 'SYNTHETIC_SECRET' not in json.dumps(first)
    checks.append('real_cli_handshake_nullable_zero_and_source_bucket')
    reloaded = call('usage.quota.status', {'provider': 'codex'})
    assert reloaded['snapshot'] == first['snapshot']
    checks.append('last_snapshot_survives_cli_restart')
    server(True)
    failure = call('usage.quota.read', {'provider': 'codex', 'executable': str(helper)})
    assert failure['status'] == 'error' and failure['stale'] is True and failure['quotaAvailable'] is False
    assert failure['snapshot'] == first['snapshot']
    assert failure['lastAttempt']['error'] == {'kind': 'login_required', 'code': -32000}
    assert 'SYNTHETIC_SECRET' not in json.dumps(failure)
    checks.append('error_is_sanitized_and_success_timestamp_preserved')
    assert not (base / 'empty-provider-home').exists()
    checks.append('no_provider_credentials_loaded')

print(json.dumps({'status': 'pass', 'count': len(checks), 'checks': checks, 'binarySHA256': binary_hash, 'frozenHelper': True, 'provider': 'synthetic executable implementing documented stdio handshake', 'modelCalls': 0, 'userCredentialsAccessed': False, 'temporaryStoreRemoved': not base.exists()}, indent=2))
