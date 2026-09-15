"""Exercise cancellation on the same real RPC connection as a running loop.

The model is a barrier-controlled synthetic executable. No real provider or
credentials are used. New evidence paths prevent overwriting a failing receipt.
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


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=repo / '.build/debug/vela')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--saturate', action='store_true', help='Queue 32 ordinary reads before sending control frames.')
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Choose a new receipt path.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    receipt = {'status': 'failed', 'sourceData': 'isolated synthetic provider/project only', 'realModelCalls': 0, 'saturatedOrdinaryQueue': args.saturate}
    with tempfile.TemporaryDirectory(prefix='vela-loop-rpc-control-') as temporary:
        base = Path(temporary).resolve(); project = base / 'project'; project.mkdir()
        store, sources = base / 'store', base / 'sources'; sources.mkdir()
        binary = base / 'vela'; shutil.copy2(args.binary.resolve(strict=True), binary)
        digest = hashlib.sha256(binary.read_bytes()).hexdigest(); receipt['frozenHelperSHA256'] = digest
        environment = dict(os.environ, VELA_HOME=str(store), VELA_SESSION_ROOT=str(sources), VELA_DISABLE_DISCOVERY='1')
        def call(method, params):
            response = subprocess.run([str(binary), 'call', method, '--params-stdin', '--home', str(store)], input=json.dumps(params), env=environment, capture_output=True, text=True, timeout=10, check=True)
            return json.loads(response.stdout)
        call('projects.add', {'path': str(project)})
        ready, release, counter = base / 'ready', base / 'release', base / 'calls.jsonl'
        provider = base / 'synthetic-codex'
        script = '''#!/usr/bin/python3
import json,pathlib,time
ready,release,counter=map(pathlib.Path,PATHS)
count=len(counter.read_text().splitlines()) if counter.exists() else 0
with counter.open('a') as out:out.write('called\\n')
ready.touch()
deadline=time.time()+7
while not release.exists() and time.time()<deadline:time.sleep(.01)
decision={'kind':'tool','toolId':'git.status','arguments':{}} if count==0 else {'kind':'final','answer':'Synthetic finish.'}
for event in [{'type':'thread.started','thread_id':'synthetic-rpc-loop'},{'type':'item.completed','item':{'id':'answer','type':'agent_message','text':json.dumps({'decision':decision})}},{'type':'turn.completed','usage':{'input_tokens':5,'output_tokens':5}}]:print(json.dumps(event),flush=True)
'''.replace('PATHS', repr([str(ready), str(release), str(counter)]))
        provider.write_text(script); provider.chmod(0o700)
        planned = call('loops.plan', {'project': str(project), 'prompt': 'Use the selected synthetic read.',
            'agent': {'executable': str(provider), 'model': 'synthetic-model', 'reasoningEffort': 'low'},
            'tools': ['git.status'], 'limits': {'maxModelCalls': 2, 'timeoutSeconds': 8, 'totalTimeoutSeconds': 15}})
        approval = planned['approval']
        process = subprocess.Popen([str(binary), 'rpc', '--no-watch', '--no-schedule', '--home', str(store)], env=environment,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        responses = queue.Queue()
        def read():
            for line in process.stdout:
                responses.put(json.loads(line))
        reader = threading.Thread(target=read, daemon=True); reader.start()
        errors = []
        def drain_errors():
            for line in process.stderr:
                errors.append(line)
        threading.Thread(target=drain_errors, daemon=True).start()
        collected = {}
        def send(identifier, method, params):
            process.stdin.write(json.dumps({'id': identifier, 'method': method, 'params': params}) + '\n'); process.stdin.flush()
        def receive(identifier, timeout):
            deadline = time.monotonic() + timeout
            while identifier not in collected:
                try:
                    response = responses.get(timeout=max(0, deadline-time.monotonic()))
                except queue.Empty:
                    return None
                if 'id' in response:
                    collected[response['id']] = response
            return collected[identifier]
        try:
            send('approve', 'approvals.decide', {'id': approval['id'], 'snapshotHash': approval['snapshotHash'], 'decision': 'approve'})
            deadline = time.monotonic() + 4
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            assert ready.exists(), 'Synthetic model did not reach its barrier.'
            if args.saturate:
                for index in range(32):
                    send(f'ordinary-{index}', 'runs.list', {'project': str(project)})
            send('get', 'loops.get', {'id': planned['id'], 'project': str(project)})
            progress = receive('get', 1)
            receipt['progressBeforeProviderRelease'] = progress is not None
            if progress is not None and 'result' in progress:
                current = progress['result']
                send('cancel', 'loops.cancel', {'id': planned['id'], 'project': str(project), 'loopHash': current['loopHash']})
                cancelled = receive('cancel', 1)
                receipt['cancelBeforeProviderRelease'] = cancelled is not None and 'result' in cancelled
            else:
                receipt['cancelBeforeProviderRelease'] = False
            release.touch()
            assert receive('approve', 10) is not None
            receive('get', 2)
            process.stdin.close(); assert process.wait(timeout=5) == 0
            final = call('loops.get', {'id': planned['id'], 'project': str(project)})
            receipt['loopState'] = final['state']
            receipt['providerInvocations'] = len(counter.read_text().splitlines())
            receipt['toolReceipts'] = sum('receipt' in item for item in final['rounds'])
            receipt['responseOrder'] = list(collected)
            receipt['status'] = 'pass' if receipt['progressBeforeProviderRelease'] and receipt['cancelBeforeProviderRelease'] and receipt['providerInvocations'] == 1 and receipt['toolReceipts'] == 0 and final['state'] == 'cancelled' else 'failed'
            assert hashlib.sha256(binary.read_bytes()).hexdigest() == digest
        finally:
            release.touch()
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
            if process.poll() is None:
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.terminate(); process.wait(timeout=5)
    receipt['temporaryFixturesRemoved'] = not base.exists()
    args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
    if receipt['status'] != 'pass':
        raise SystemExit(1)


if __name__ == '__main__':
    main()
