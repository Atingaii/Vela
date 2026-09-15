"""Verify Replay control admission during a blocked synthetic model call.

Uses one actual helper RPC connection, with 32 ordinary requests queued ahead
of metadata/cancel/forget. No real model, credentials or business tools run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import traceback
from native_provider_fixture import compile_provider


def exercise(binary, base, action, saturate):
    project = base / 'project'
    project.mkdir()
    sources = base / 'sources'
    sources.mkdir()
    home = base / 'store'
    env = dict(os.environ, VELA_HOME=str(home), VELA_SESSION_ROOT=str(sources), VELA_DISABLE_DISCOVERY='1')
    result = {'action': action, 'status': 'failed', 'ordinaryRequests': 32 if saturate else 0}

    def call(method, params):
        p = subprocess.run([str(binary), 'call', method, '--params-stdin', '--home', str(home)],
                           input=json.dumps(params), env=env, text=True, capture_output=True, timeout=15)
        assert p.returncode == 0, (method, p.stderr, p.stdout)
        return json.loads(p.stdout)

    call('projects.add', {'path': str(project)})
    context = {'version': 1, 'template': 'VERSION_A {{input.task}} {{pasted}}',
               'inputs': [{'id': 'pasted', 'source': 'stdin'}], 'memory': {'enabled': False}}
    definition = {'title': 'Synthetic control fixture', 'project': str(project), 'context': context,
                  'steps': [{'tool': 'agent.run', 'arguments': {'executable': '/usr/bin/false',
                             'args': ['{{vela.prompt}}'], 'promptMode': 'workflow_context'}}]}
    workflow = call('workflows.save', definition)
    run = call('workflows.run', {'id': workflow['id'], 'dryRun': True,
                                'inputs': {'task': 'HISTORICAL_CONTROL_MARKER'}, 'stdin': '中文 {{literal}}'})
    assert run['state'] == 'completed', run
    inspected = call('replay.fixtures.inspect', {'project': str(project), 'runId': run['id']})
    fixture = call('replay.fixtures.capture', {'project': str(project), 'runId': run['id'],
                   'runHash': inspected['runHash'], 'consent': True, 'retentionDays': 1})
    context['template'] = 'VERSION_B {{input.task}} {{pasted}}'
    call('workflows.save', dict(definition, id=workflow['id']))
    ready, release, counter = (base / name for name in ('ready', 'release', 'calls.jsonl'))
    provider = base / 'synthetic-codex'
    script = '''#!/usr/bin/python3
import json,pathlib,time
ready,release,counter=map(pathlib.Path,PATHS)
with counter.open('a') as out:out.write('called\\n')
ready.touch()
deadline=time.monotonic()+9
while not release.exists() and time.monotonic()<deadline:time.sleep(.01)
events=[{'type':'thread.started','thread_id':'synthetic-replay-control'},
{'type':'item.completed','item':{'id':'answer','type':'agent_message','text':json.dumps({'output':'SYNTHETIC_OUTPUT_MARKER'})}},
{'type':'turn.completed','usage':{'input_tokens':5,'output_tokens':5}}]
for event in events:print(json.dumps(event),flush=True)
'''.replace('PATHS', repr([str(ready), str(release), str(counter)]))
    compile_provider(provider, script)
    pending = call('replay.create', {'project': str(project), 'fixtureId': fixture['id'],
              'fixtureHash': fixture['fixtureHash'], 'versions': [1, 2], 'executable': str(provider),
              'model': 'synthetic-model', 'effort': 'low', 'timeoutSeconds': 10})
    process = subprocess.Popen([str(binary), 'rpc', '--no-watch', '--no-schedule', '--home', str(home)],
                               env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, bufsize=1)
    responses, errors, collected = queue.Queue(), [], {}

    def read():
        for line in process.stdout:
            try:
                responses.put(json.loads(line))
            except json.JSONDecodeError:
                errors.append('Malformed RPC response')

    def drain_errors():
        for line in process.stderr:
            if len(errors) < 20:
                errors.append(line)

    threading.Thread(target=read, daemon=True).start()
    threading.Thread(target=drain_errors, daemon=True).start()

    def send(identifier, method, params):
        process.stdin.write(json.dumps({'id': identifier, 'method': method, 'params': params}) + '\n')
        process.stdin.flush()

    def receive(identifier, timeout=1):
        deadline = time.monotonic() + timeout
        while identifier not in collected:
            try:
                item = responses.get(timeout=max(0, deadline-time.monotonic()))
            except queue.Empty:
                return None
            if 'id' in item:
                collected[item['id']] = item
        return collected[identifier]

    try:
        approval = pending['approval']
        send('approve', 'approvals.decide', {'id': approval['id'], 'snapshotHash': approval['snapshotHash'], 'decision': 'approve'})
        deadline = time.monotonic() + 4
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        assert ready.exists(), 'The synthetic provider did not reach its barrier.'
        for index in range(result['ordinaryRequests']):
            send(f'ordinary-{index}', 'runs.list', {'project': str(project)})
        controls = [('get', 'replay.get', {'id': pending['id']}),
                    ('list', 'replay.list', {}),
                    ('fixture-get', 'replay.fixtures.get', {'id': fixture['id']}),
                    ('fixture-list', 'replay.fixtures.list', {}),
                    ('fixture-prune', 'replay.fixtures.prune', {})]
        for identifier, method, params in controls:
            send(identifier, method, dict(params, project=str(project)))
        replies = {identifier: receive(identifier) for identifier, _, _ in controls}
        result['allMetadataBeforeProviderRelease'] = all(r is not None and 'result' in r for r in replies.values())
        assert result['allMetadataBeforeProviderRelease'], 'Control metadata was blocked or returned an error.'
        serialized = json.dumps(replies)
        assert not any(marker in serialized for marker in ('HISTORICAL_CONTROL_MARKER', 'SYNTHETIC_OUTPUT_MARKER', 'VERSION_A'))
        current = replies['get']['result']
        if action == 'cancel':
            params = {'id': pending['id'], 'replayHash': current['replayHash']}
            method = 'replay.cancel'
        else:
            params = {'id': fixture['id'], 'fixtureHash': fixture['fixtureHash']}
            method = 'replay.fixtures.forget'
        send('control', method, dict(params, project=str(project)))
        controlled = receive('control')
        result['controlBeforeProviderRelease'] = controlled is not None and 'result' in controlled
        assert result['controlBeforeProviderRelease'], 'Cancellation/forget was blocked or rejected.'
        assert not release.exists()
        release.touch()
        assert receive('approve', 12) is not None, 'The bounded first call did not settle.'
        process.stdin.close()
        assert process.wait(timeout=8) == 0
        final = call('replay.get', {'id': pending['id'], 'project': str(project)})
        result['state'] = final['state']
        result['providerInvocations'] = len(counter.read_text().splitlines())
        assert result['providerInvocations'] == 1, 'Version B must not start after cancellation or forget.'
        assert final['providerAttempts'] == 1
        if action == 'cancel':
            assert final['state'] == 'cancelled', final
        else:
            assert final['fixtureState'] == 'revoked_or_expired', final
            # A new helper process must still reject deleted bodies; no late receipt may resurrect them.
            for method in ('replay.review', 'replay.results'):
                probe = subprocess.run([str(binary), 'call', method, '--params-stdin', '--home', str(home)],
                    input=json.dumps({'project': str(project), 'id': final['id'], 'replayHash': final['replayHash']}),
                    env=env, text=True, capture_output=True, timeout=10)
                assert probe.returncode != 0, (method, probe.stdout)
                assert 'HISTORICAL_CONTROL_MARKER' not in probe.stdout
        result['responseOrder'] = list(collected)
        result['status'] = 'pass'
    except Exception as error:
        result['error'] = str(error)
        result['traceback'] = traceback.format_exc()
    finally:
        release.touch()
        if process.stdin and not process.stdin.closed:
            process.stdin.close()
        if process.poll() is None:
            try:
                process.wait(timeout=12)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
        result['processExited'] = process.poll() is not None
    return result


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=repo / '.build/debug/vela')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--saturate', action='store_true')
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Choose a new evidence path; failed receipts must be retained.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    receipt = {'status': 'failed', 'realModelCalls': 0, 'businessToolCalls': 0,
               'sourceData': 'isolated synthetic projects and barrier provider', 'checks': []}
    with tempfile.TemporaryDirectory(prefix='vela-replay-rpc-control-') as temporary:
        base = Path(temporary).resolve()
        binary = base / 'vela'
        shutil.copy2(args.binary.resolve(strict=True), binary)
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        receipt['frozenHelperSHA256'] = digest
        for action in ('cancel', 'forget'):
            scenario = base / action
            scenario.mkdir()
            try:
                result = exercise(binary, scenario, action, args.saturate)
            except Exception as error:
                result = {'action': action, 'status': 'failed', 'error': str(error), 'traceback': traceback.format_exc()}
            receipt['checks'].append(result)
        receipt['helperUnchanged'] = hashlib.sha256(binary.read_bytes()).hexdigest() == digest
    receipt['temporaryFixturesRemoved'] = not base.exists()
    receipt['status'] = 'pass' if receipt['helperUnchanged'] and all(r['status'] == 'pass' for r in receipt['checks']) else 'failed'
    args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
    if receipt['status'] != 'pass':
        raise SystemExit(1)


if __name__ == '__main__':
    main()
