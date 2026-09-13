#!/usr/bin/env python3
"""Exercise the test-only HTTP bridge against an explicit, zero-provider helper.

The script owns its synthetic fixture, test server, and helper child.  It keeps
only a compact, non-user-data JSON result after shutting every owned process
down and deleting the fixture.
"""
import datetime
import argparse
import hashlib
import http.client
import json
import os
import select
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
FIXTURE_SCRIPT = ROOT / 'scripts' / 'create-ui-fixture.py'
BRIDGE_SCRIPT = ROOT / 'scripts' / 'test-ui-server.py'
DEFAULT_OUTPUT = ROOT / 'output' / 'parity' / 'run-feedback-bridge-r2.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / '.build' / 'debug' / 'vela',
                        help='built Vela CLI used for the owned fixture and Bridge')
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT,
                        help='new JSON evidence path (the script never overwrites it)')
    args = parser.parse_args()
    output = args.output.absolute()
    helper = args.binary.resolve(strict=True)
    if output.exists():
        raise SystemExit(f'Refusing to overwrite evidence: {output}')
    required = [helper, FIXTURE_SCRIPT, BRIDGE_SCRIPT]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise SystemExit('Missing frozen test input: ' + ', '.join(missing))
    helper_before = digest(helper)
    bridge_before = digest(BRIDGE_SCRIPT)
    fixture_before = digest(FIXTURE_SCRIPT)
    test_before = digest(Path(__file__))

    result = {
        'format': 'vela-run-feedback-bridge-v1',
        'status': 'failed',
        'executedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'scope': {
            'providerRuns': 0,
            'modelRuns': 0,
            'fixture': 'owned synthetic Harbor/Beacon fixture',
            'run': 'completed non-dry-run workflow containing Git read steps only',
            'transport': 'real HTTP requests through test-ui-server Bridge to explicit helper',
        },
        'sha256': {
            'helperBefore': helper_before,
            'bridgeBefore': bridge_before,
            'fixtureCreatorBefore': fixture_before,
            'testBefore': test_before,
        },
        'checks': [],
        'cleanup': {'serverStopped': False, 'fixtureRemoved': False},
    }
    base = None
    server = None
    try:
        scratch = ROOT / '.task-tmp'
        scratch.mkdir(exist_ok=True)
        base = Path(tempfile.mkdtemp(prefix='vela-feedback-bridge-', dir=scratch))
        fixture = base / 'fixture'
        create = subprocess.run(
            [sys.executable, str(FIXTURE_SCRIPT), str(fixture), '--binary', str(helper), '--with-routing-project'],
            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90,
        )
        if create.returncode:
            raise RuntimeError('Owned fixture creation failed: ' + (create.stderr or create.stdout).strip())
        manifest = fixture / 'fixture.json'
        info = json.loads(manifest.read_text())
        harbor, beacon, run_id = info['project'], info['routingProject'], info['completedRun']

        server = subprocess.Popen(
            [sys.executable, str(BRIDGE_SCRIPT), str(manifest), '--binary', str(helper)],
            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        deadline = time.monotonic() + 30
        startup = ''
        while time.monotonic() < deadline:
            remaining = max(0, deadline - time.monotonic())
            if not select.select([server.stdout], [], [], remaining)[0]:
                break
            line = server.stdout.readline()
            if line:
                startup = line
                break
            if server.poll() is not None:
                break
        if not startup:
            raise RuntimeError('Test-only bridge did not publish its local capability.')
        endpoint = urlsplit(json.loads(startup)['url'])

        def request(method, params):
            body = json.dumps({'method': method, 'params': params}, separators=(',', ':')).encode()
            connection = http.client.HTTPConnection(endpoint.hostname, endpoint.port, timeout=30)
            try:
                connection.request('POST', endpoint.path + '__rpc', body=body, headers={
                    'Content-Type': 'application/json', 'Host': endpoint.netloc,
                    'Origin': f'{endpoint.scheme}://{endpoint.netloc}',
                })
                response = connection.getresponse()
                payload = json.loads(response.read())
                return response.status, payload
            finally:
                connection.close()

        def good(name, expected, method, params, verify=lambda value: None):
            status, payload = request(method, params)
            verify(status, payload)
            result['checks'].append({'name': name, 'expected': expected,
                                     'actual': {'httpStatus': status, 'result': 'accepted'}, 'passed': True})
            return payload['result']

        def rejected(name, expected, method, params):
            status, payload = request(method, params)
            if status != 400 or not isinstance(payload.get('error'), str) or not payload['error']:
                raise AssertionError(f'{name} was not rejected by the live bridge: {status} {payload!r}')
            result['checks'].append({'name': name, 'expected': expected,
                                     'actual': {'httpStatus': status, 'result': 'rejected'}, 'passed': True})

        prepared = good('prepare', 'terminal Harbor run yields a 64-character run hash', 'runs.feedback.prepare',
                        {'project': harbor, 'runId': run_id},
                        lambda status, payload: (_ for _ in ()).throw(AssertionError('prepare response invalid'))
                        if status != 200 or len(payload.get('result', {}).get('runHash', '')) != 64 else None)
        run_hash = prepared['runHash']
        saved = good('record-good', 'first good observation is persisted', 'runs.feedback.record', {
            'project': harbor, 'runId': run_id, 'runHash': run_hash, 'previousFeedbackHash': None,
            'outcome': 'good', 'reason': 'Synthetic local Git review is acceptable.',
        }, lambda status, payload: (_ for _ in ()).throw(AssertionError('good record response invalid'))
             if status != 200 or payload.get('result', {}).get('outcome') != 'good' else None)
        current = good('get-good', 'stored good observation is retrievable in Harbor', 'runs.feedback.get',
                       {'project': harbor, 'id': saved['id']},
                       lambda status, payload: (_ for _ in ()).throw(AssertionError('get response invalid'))
                       if status != 200 or payload.get('result', {}).get('outcome') != 'good' else None)
        if current['feedbackHash'] != saved['feedbackHash']:
            raise AssertionError('get did not return the saved feedback revision')
        bad = good('good-to-bad', 'current feedback hash permits one corrected observation', 'runs.feedback.record', {
            'project': harbor, 'runId': run_id, 'runHash': run_hash, 'previousFeedbackHash': saved['feedbackHash'],
            'outcome': 'bad', 'reason': 'Synthetic reviewer corrected the Git observation.',
        }, lambda status, payload: (_ for _ in ()).throw(AssertionError('bad record response invalid'))
             if status != 200 or payload.get('result', {}).get('outcome') != 'bad' else None)
        rejected('stale-cas', 'superseded feedback hash cannot clear the corrected observation', 'runs.feedback.record', {
            'project': harbor, 'runId': run_id, 'runHash': run_hash, 'previousFeedbackHash': saved['feedbackHash'],
            'outcome': 'clear', 'reason': 'Synthetic stale clear request.',
        })
        cleared = good('bad-to-clear', 'latest feedback hash can withdraw the observation', 'runs.feedback.record', {
            'project': harbor, 'runId': run_id, 'runHash': run_hash, 'previousFeedbackHash': bad['feedbackHash'],
            'outcome': 'clear', 'reason': 'Synthetic reviewer withdrew the observation.',
        }, lambda status, payload: (_ for _ in ()).throw(AssertionError('clear response invalid'))
             if status != 200 or payload.get('result', {}).get('outcome') != 'clear' else None)
        history_one = good('history-list-first-page', 'history list exposes a bounded first page and cursor',
                           'runs.feedback.history.list', {'project': harbor, 'runId': run_id, 'limit': 1},
                           lambda status, payload: (_ for _ in ()).throw(AssertionError('history page invalid'))
                           if status != 200 or not payload.get('result', {}).get('cursor') else None)
        history_two = good('history-list-next-page', 'cursor retrieves the second immutable revision',
                           'runs.feedback.history.list', {'project': harbor, 'runId': run_id, 'limit': 1,
                                                          'cursor': history_one['cursor']},
                           lambda status, payload: (_ for _ in ()).throw(AssertionError('second history page invalid'))
                           if status != 200 or len(payload.get('result', {}).get('items', [])) != 1 else None)
        good('history-get', 'history identifier retrieves its immutable observation', 'runs.feedback.history.get',
             {'project': harbor, 'id': history_one['items'][0]['historyId']},
             lambda status, payload: (_ for _ in ()).throw(AssertionError('history get invalid'))
             if status != 200 or payload.get('result', {}).get('historyId') != history_one['items'][0]['historyId'] else None)
        if history_one['items'][0]['historyId'] == history_two['items'][0]['historyId'] or cleared['outcome'] != 'clear':
            raise AssertionError('history chain or clear transition was not preserved')

        rejected('extra-field', 'prepare rejects unsupported request fields', 'runs.feedback.prepare',
                 {'project': harbor, 'runId': run_id, 'extra': True})
        rejected('cross-project', 'Beacon cannot review Harbor run', 'runs.feedback.prepare',
                 {'project': beacon, 'runId': run_id})
        for label, value in [('boolean', True), ('zero', 0), ('over-max', 101)]:
            rejected(f'limit-{label}', 'feedback list accepts integer limits from 1 through 100 only',
                     'runs.feedback.list', {'project': harbor, 'limit': value})
        rejected('unknown-id', 'unknown feedback id is not exposed', 'runs.feedback.get',
                 {'project': harbor, 'id': 'unknown-feedback-id'})
        rejected('cursor-shape', 'malformed opaque cursor is rejected', 'runs.feedback.history.list',
                 {'project': harbor, 'runId': run_id, 'cursor': 'not-a-feedback-cursor'})
        rejected('hash-shape', 'non-SHA-256 run hash is rejected before recording', 'runs.feedback.record', {
            'project': harbor, 'runId': run_id, 'runHash': 'invalid', 'previousFeedbackHash': None,
            'outcome': 'good', 'reason': 'Synthetic invalid hash request.',
        })
        if not all((result['sha256']['helperBefore'] == digest(helper), result['sha256']['bridgeBefore'] == digest(BRIDGE_SCRIPT), result['sha256']['fixtureCreatorBefore'] == digest(FIXTURE_SCRIPT), result['sha256']['testBefore'] == digest(Path(__file__)))):
            raise RuntimeError('A frozen Bridge source changed before the final check.')
        result['status'] = 'passed'
    except Exception as error:
        result['failure'] = type(error).__name__ + ': ' + str(error)
    finally:
        if server is not None:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=10)
            result['cleanup']['serverStopped'] = server.poll() is not None
        if base is not None and base.exists():
            shutil.rmtree(base)
            result['cleanup']['fixtureRemoved'] = not base.exists()
        result['sha256']['helperAfter'] = digest(helper)
        result['sha256']['bridgeAfter'] = digest(BRIDGE_SCRIPT)
        result['sha256']['fixtureCreatorAfter'] = digest(FIXTURE_SCRIPT)
        result['sha256']['testAfter'] = digest(Path(__file__))
        result['sha256']['helperUnchanged'] = result['sha256']['helperBefore'] == result['sha256']['helperAfter']
        result['sha256']['bridgeUnchanged'] = result['sha256']['bridgeBefore'] == result['sha256']['bridgeAfter']
        result['sha256']['fixtureCreatorUnchanged'] = result['sha256']['fixtureCreatorBefore'] == result['sha256']['fixtureCreatorAfter']
        result['sha256']['testUnchanged'] = result['sha256']['testBefore'] == result['sha256']['testAfter']
        result['sourceUnchanged'] = all(result['sha256'][key] for key in ('helperUnchanged','bridgeUnchanged','fixtureCreatorUnchanged','testUnchanged'))
        if not result['sourceUnchanged']:
            result['status'] = 'failed'
            result.setdefault('failure', 'A frozen Bridge source changed during the run.')
        result['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2) + '\n')
    if result['status'] != 'passed':
        raise SystemExit(1)


if __name__ == '__main__':
    main()
