"""Verify the real daemon using only a disposable store and synthetic project."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, default=ROOT / '.build/debug/vela')
parser.add_argument('--output', type=Path)
args = parser.parse_args()
binary = args.binary.resolve(strict=True)
results = []
processes = []

with tempfile.TemporaryDirectory(prefix='vela-daemon-acceptance-') as temporary:
    task = Path(temporary).resolve()
    store = task / 'store'
    project = task / 'project'
    project.mkdir()
    env = {**os.environ, 'VELA_DISABLE_DISCOVERY': '1'}
    env.pop('VELA_SESSION_ROOT', None)

    def invoke(*command, expected=0):
        result = subprocess.run([str(binary), *command, '--home', str(store)], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
        assert result.returncode == expected, (command, result.returncode, result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() else None

    def call(method, params=None):
        return invoke('call', method, json.dumps(params or {}))

    def until(check, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = check()
            if value:
                return value
            time.sleep(.05)
        raise AssertionError('Daemon readiness condition timed out')

    def start():
        process = subprocess.Popen([str(binary), 'daemon', 'run', '--no-watch', '--home', str(store)], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        processes.append(process)
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            assert selector.select(8), 'No daemon startup response'
            first = process.stdout.readline()
        assert first, process.stderr.read()
        ready = json.loads(first)
        assert ready['state'] == 'running' and ready['pid'] == process.pid
        return process

    try:
        call('projects.add', {'path': str(project)})
        plan = invoke('daemon', 'plan')
        assert plan['mutated'] is False and not Path(plan['path']).exists()
        workflow = call('workflows.save', {'title': 'Synthetic daemon approval', 'project': str(project), 'trigger': 'app_start', 'enabled': True, 'steps': [{'title': 'Review explicit write', 'tool': 'file.write', 'arguments': {'path': 'approval-only.txt', 'content': 'approved content'}}]})
        first = start()
        until(lambda: call('runs.list'))
        time.sleep(.25)
        assert first.poll() is None, 'Daemon exited on closed stdin'
        status = invoke('daemon', 'status')
        assert status['running'] is True and status['recorded']['pid'] == first.pid
        assert not (project / 'approval-only.txt').exists()
        assert call('runs.list')[0]['state'] == 'pending_approval'
        results.append({'check': 'independent-daemon-with-closed-stdin', 'passed': True, 'pendingApproval': True, 'unapprovedFileAbsent': True})

        invoke('daemon', 'run', '--no-watch', expected=1)
        assert first.poll() is None
        assert len(call('runs.list')) == 1
        results.append({'check': 'exclusive-store-daemon', 'passed': True})

        first.send_signal(signal.SIGKILL)
        first.wait(timeout=5)
        assert invoke('daemon', 'status')['running'] is False
        assert invoke('daemon', 'status')['recorded']['state'] == 'running'
        assert not (project / 'approval-only.txt').exists()
        results.append({'check': 'liveness-uses-lease-after-force-kill', 'passed': True, 'staleMetadataNotLiveness': True})

        second = start()
        until(lambda: invoke('daemon', 'status')['recorded'].get('lastTickAt'))
        assert len(call('runs.list')) == 1
        assert len(call('inbox.list')) == 1
        assert not (project / 'approval-only.txt').exists()
        second.send_signal(signal.SIGTERM)
        second.wait(timeout=8)
        assert second.returncode == 0
        status = invoke('daemon', 'status')
        assert status['running'] is False and status['recorded']['state'] == 'stopped'
        results.append({'check': 'restart-retains-approval-and-graceful-stop', 'passed': True, 'retriedSideEffect': False})
        assert not Path(plan['path']).exists()
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if process.stdout:
                process.stdout.close()
            if process.stderr:
                process.stderr.close()

report = {'status': 'passed', 'checks': results, 'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'scope': 'real foreground daemon, isolated store; no real launchd registration or account access', 'temporaryStoreRemoved': not task.exists()}
if args.output:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
