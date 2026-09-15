"""Verify read-tool watch dispatch using the actual daemon and synthetic Git only.

No provider, credential, launchd registration or real user configuration is used.
The helper is frozen before the test. Existing receipts are never overwritten.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    repo = Path(__file__).resolve().parents[1]
    parser.add_argument('--binary', type=Path, default=repo / '.build/debug/vela')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source', choices=['tool', 'files'], default='tool')
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Choose a new evidence path; previous evidence is retained.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    receipt = {'passed': False, 'source': args.source, 'realModelCalls': 0, 'externalRequests': 0, 'sourceData': 'isolated synthetic Git project', 'launchdModified': False}
    began = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix='vela-watch-daemon-') as temporary:
            base = Path(temporary).resolve()
            project, store, helper = base / 'project', base / 'store', base / 'vela'
            project.mkdir()
            shutil.copy2(args.binary.resolve(strict=True), helper)
            receipt['frozenHelperSHA256'] = hashlib.sha256(helper.read_bytes()).hexdigest()
            environment = dict(os.environ, VELA_DISABLE_DISCOVERY='1', VELA_HOME=str(store))
            subprocess.run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', 'init', '-q', str(project)], check=True, env={k: v for k, v in environment.items() if not k.startswith('GIT_')})
            def call(method, params):
                result = subprocess.run([str(helper), 'call', method, '--params-stdin', '--home', str(store)], input=json.dumps(params), env=environment, capture_output=True, text=True, timeout=10, check=True)
                return json.loads(result.stdout)
            call('projects.add', {'path': str(project)})
            watch = {'tool': 'git.status', 'arguments': {}, 'everySeconds': 30, 'debounceSeconds': 0} if args.source == 'tool' else {'source': 'files', 'paths': ['observed-by-daemon.txt'], 'recursive': False, 'debounceSeconds': 0}
            workflow = call('workflows.save', {'title': 'Synthetic daemon watch', 'project': str(project), 'trigger': 'watch', 'enabled': True,
                'watch': watch,
                'steps': [{'tool': 'file.write', 'arguments': {'path': 'requires-approval.txt', 'content': 'Must wait for explicit approval'}}]})
            params = {'id': workflow['id'], 'project': str(project)}
            preview = call('watches.preview', params)
            assert preview['wouldInitializeBaseline'] and not preview['mutated']
            assert call('watches.get', params)['state'] is None
            def start():
                return subprocess.Popen([str(helper), 'daemon', 'run', '--no-watch', '--home', str(store)], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            def stop(process):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=7)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait(timeout=3)
                        raise AssertionError('Daemon did not complete bounded clean shutdown')
                assert process.returncode == 0, f'Daemon exited {process.returncode}'
            process = start()
            try:
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    state = call('watches.get', params)['state']
                    if state is not None:
                        break
                    time.sleep(.1)
                assert state is not None and state['pollCount'] == 1
                assert call('runs.list', {'project': str(project)}) == []
                (project / 'observed-by-daemon.txt').write_text('Synthetic watch observation only.\n')
                deadline = time.monotonic() + 38
                while time.monotonic() < deadline:
                    runs = call('runs.list', {'project': str(project)})
                    if runs:
                        break
                    time.sleep(.25)
                assert len(runs) == 1 and runs[0]['state'] == 'pending_approval'
                assert not (project / 'requires-approval.txt').exists()
                schedules = call('schedules.list', {'project': str(project)})
                assert len(schedules['events']) == 1 and schedules['events'][0]['state'] == 'dispatched'
                event = schedules['events'][0]
                assert 'observed-by-daemon.txt' in json.dumps(event['watchInput'])
                if args.source == 'files':
                    observed = call('watches.get', params)['state']
                    assert observed['fileEventID'] != 'unavailable'
                    assert observed['receipt']['filesRead'] == 1
                    receipt['observedFSEventID'] = observed['fileEventID']
                    receipt['filesRead'] = observed['receipt']['filesRead']
                    receipt['bytesRead'] = observed['receipt']['bytesRead']
                receipt.update(runId=runs[0]['id'], eventId=event['id'], inputHash=event['inputHash'], state=runs[0]['state'], initialPollCount=state['pollCount'])
                stop(process)
                process = start()
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    status = call('daemon.status', {})
                    if status['running'] and status['recorded'].get('state') == 'running':
                        break
                    time.sleep(.1)
                assert status['running'] and status['recorded']['state'] == 'running'
                # A new daemon's immediate tick sees the persisted watermark;
                # it must not invent a second dispatch for the same observation.
                time.sleep(.3)
                assert len(call('runs.list', {'project': str(project)})) == 1
                assert len(call('schedules.list', {'project': str(project)})['events']) == 1
                assert not (project / 'requires-approval.txt').exists()
                receipt['restartDuplicateDispatches'] = 0
                receipt['unapprovedWrites'] = 0
                stop(process)
                receipt['cleanShutdown'] = True
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=7)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait(timeout=3)
        receipt['passed'] = True
        receipt['temporaryStoreProjectAndHelperRemoved'] = not base.exists()
    except Exception as error:
        receipt['error'] = str(error)
        raise
    finally:
        receipt['durationSeconds'] = round(time.monotonic() - began, 3)
        args.output.write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
