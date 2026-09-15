"""Check SIGTERM responsiveness during a real blocked read in an isolated daemon."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, default=ROOT / '.build/debug/vela')
parser.add_argument('--output', type=Path)
args = parser.parse_args()
source = args.binary.resolve(strict=True)
report = {'check': 'daemon-sigterm-during-blocked-git-read'}
with tempfile.TemporaryDirectory(prefix='vela-daemon-shutdown-review-') as temporary:
    task = Path(temporary).resolve()
    binary = task / 'vela'
    shutil.copy2(source, binary)
    report['binarySHA256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
    project = task / 'project'
    project.mkdir()
    subprocess.run(['/usr/bin/git', 'init', '-q', str(project)], check=True, timeout=10)
    store = task / 'store'
    env = {**os.environ, 'VELA_DISABLE_DISCOVERY': '1'}
    env.pop('VELA_SESSION_ROOT', None)

    def call(method, params):
        result = subprocess.run([str(binary), 'call', method, json.dumps(params), '--home', str(store)], env=env, capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    call('projects.add', {'path': str(project)})
    call('workflows.save', {'title': 'Blocked read shutdown review', 'project': str(project), 'enabled': True, 'trigger': 'git_event', 'steps': [{'tool': 'git.status', 'arguments': {}}]})
    # Only this disposable repository is altered. Git's actual config reader
    # waits for FIFO input, simulating a stuck filesystem without a fake clock.
    config = project / '.git/config'
    config.unlink()
    os.mkfifo(config, 0o600)
    process = subprocess.Popen([str(binary), 'daemon', 'run', '--no-watch', '--home', str(store)], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    children = []
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            assert selector.select(8), 'No daemon startup response'
            assert json.loads(process.stdout.readline())['state'] == 'running'
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not children:
            snapshot = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,command='], capture_output=True, text=True, check=True, timeout=5)
            for line in snapshot.stdout.splitlines():
                fields = line.strip().split(None, 3)
                if len(fields) == 4 and int(fields[1]) == process.pid and fields[3].split()[0].endswith('/git'):
                    children.append((int(fields[0]), int(fields[2])))
            time.sleep(.05)
        assert children, 'The real Git read was not reached'
        started = time.monotonic()
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        live_children = []
        for child_pid, _ in children:
            child = subprocess.run(['/bin/ps', '-p', str(child_pid), '-o', 'stat='], capture_output=True, text=True, timeout=5)
            if child.returncode == 0 and child.stdout.strip() and not child.stdout.strip().startswith('Z'):
                live_children.append(child_pid)
        report.update({'stoppedWithinTwoSeconds': process.poll() is not None,
                       'elapsedSeconds': round(time.monotonic() - started, 3),
                       'exitCode': process.poll(), 'blockedGitObserved': True,
                       'ownedChildProcessesStopped': not live_children})
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        for child_pid, group in children:
            # AutomationProcess starts each child in its own group. Never send
            # a group signal unless that exact owned child's group was observed.
            if child_pid == group:
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        process.stdout.close()
        process.stderr.close()
report['temporaryStoreRemoved'] = not task.exists()
report['passed'] = report.get('stoppedWithinTwoSeconds') is True and report.get('exitCode') == 0 and report.get('ownedChildProcessesStopped') is True
if args.output:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
raise SystemExit(0 if report['passed'] else 1)
