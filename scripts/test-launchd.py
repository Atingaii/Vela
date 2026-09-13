"""Exercise Vela's real manager against a unique launchd job in a fake user home.

The test installs no file in the user's actual Library/LaunchAgents. Its wrapper
disables discovery, and its store contains only synthetic test data.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
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
report = {'scope': 'real user launchd, unique temporary job/store/fake home; discovery disabled', 'checks': []}
with tempfile.TemporaryDirectory(prefix='vela-launchd-review-') as temporary:
    task = Path(temporary).resolve()
    binary = task / 'vela'
    shutil.copy2(args.binary.resolve(strict=True), binary)
    report['binarySHA256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
    fake_home = task / 'fake-user'
    fake_home.mkdir()
    store = task / 'store'
    wrapper = task / 'launch-vela'
    wrapper.write_text('#!/bin/sh\nexport VELA_DISABLE_DISCOVERY=1\nunset VELA_SESSION_ROOT\nexec ' + shlex.quote(str(binary)) + ' "$@"\n')
    wrapper.chmod(0o700)
    harness_source = task / 'manager.swift'
    harness_source.write_text('''import Foundation
import VelaCore
let a = CommandLine.arguments
let store = try VelaStore(root: URL(fileURLWithPath:a[2]))
let service = try VelaDaemonService(store:store,executable:a[4],userHome:URL(fileURLWithPath:a[3]))
let result: JSON
switch a[1] {
case "plan": result = try service.plan()
case "install": result = try service.install()
case "start": result = try service.start()
case "status": result = try service.status()
case "stop": result = try service.stop()
case "uninstall": result = try service.uninstall()
default: fatalError("Unknown fixture operation")
}
print(try jsonString(result))
''')
    harness = task / 'manager'
    objects = sorted((ROOT / '.build/debug/VelaCore.build').glob('*.swift.o'))
    assert objects, 'Build the debug Vela core first'
    subprocess.run(['swiftc', '-swift-version', '5', '-I', str(ROOT / '.build/debug/Modules'), '-I', str(ROOT / 'Sources/CSQLite'), str(harness_source), *map(str, objects), '-o', str(harness)], check=True, capture_output=True, text=True, timeout=30)
    target = None
    owns_label = False
    installed_path = None
    last_pid = None

    def manager(operation):
        result = subprocess.run([str(harness), operation, str(store), str(fake_home), str(wrapper)], capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, (operation, result.stderr)
        return json.loads(result.stdout)

    def printed():
        return subprocess.run(['/bin/launchctl', 'print', target], capture_output=True, text=True, timeout=5)

    def until(check, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            found = check()
            if found:
                return found
            time.sleep(.1)
        raise AssertionError('launchd readiness condition timed out')

    def running_instance():
        status = manager('status')
        if status.get('running') is True and status.get('recorded', {}).get('pid'):
            return status['recorded']
        return None

    try:
        plan = manager('plan')
        installed_path = Path(plan['path'])
        configured_executable = plan['configuration']['ProgramArguments'][0]
        assert installed_path.is_relative_to(fake_home)
        target = 'gui/' + str(os.getuid()) + '/' + plan['label']
        assert printed().returncode != 0, 'Unexpected existing fixture label; no mutation attempted'
        owns_label = True
        manager('install')
        assert installed_path.exists()
        manager('start')
        first = until(running_instance)
        last_pid = first['pid']
        assert configured_executable in printed().stdout
        manager('start')  # Validates the *actual* launchctl path/program/argv format.
        report['checks'].append({'check': 'install-bootstrap-print-idempotent-start', 'passed': True})

        # PID and store lease are both observed from this exact loaded job.
        current_print = printed()
        assert current_print.returncode == 0 and configured_executable in current_print.stdout
        assert ('pid = ' + str(last_pid)) in current_print.stdout
        os.kill(last_pid, signal.SIGKILL)
        def restarted():
            value = running_instance()
            return value if value and value.get('instance') != first['instance'] else None
        second = until(restarted, timeout=40)
        last_pid = second['pid']
        report['checks'].append({'check': 'keepalive-restarts-after-abnormal-exit', 'passed': True, 'instanceChanged': True})

        manager('stop')
        until(lambda: manager('status')['running'] is False)
        assert printed().returncode != 0
        assert manager('status')['recorded']['state'] == 'stopped'
        manager('uninstall')
        assert not installed_path.exists() and store.exists()
        report['checks'].append({'check': 'verified-bootout-uninstall-preserves-store', 'passed': True})
    finally:
        # This target was absent before the test. Boot out only this unique job,
        # even if a manager assertion failed; never query or unload other jobs.
        if owns_label and target and printed().returncode == 0:
            subprocess.run(['/bin/launchctl', 'bootout', target], capture_output=True, text=True, timeout=15)
        if owns_label and target:
            assert printed().returncode != 0, 'Fixture launchd job was not removed'
        if last_pid:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                child = subprocess.run(['/bin/ps', '-p', str(last_pid), '-o', 'command='], capture_output=True, text=True)
                if child.returncode != 0 or str(task) not in child.stdout:
                    break
                time.sleep(.05)
            else:
                # Exact unique fixture command still proves ownership.
                os.kill(last_pid, signal.SIGKILL)
report.update({'passed': len(report['checks']) == 3, 'temporaryFilesRemoved': not task.exists(), 'fixtureJobRemoved': True})
if args.output:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
