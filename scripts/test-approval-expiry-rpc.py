#!/usr/bin/env python3
"""Real, isolated RPC checks for approval deadlines, including a SQLite wait race."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import sqlite3
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes(root):
    return {str(p.relative_to(root)): sha(p) for p in sorted((root / 'Sources').rglob('*.swift'))}


class RPC:
    def __init__(self, binary, home, project, transcript):
        self.transcript = transcript
        self.serial = 0
        self.argv = [str(binary), 'rpc', '--no-watch', '--no-schedule', '--home', str(home)]
        env = dict(os.environ, HOME=str(home.parent), VELA_HOME=str(home), VELA_DISABLE_DISCOVERY='1',
                   GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        self.proc = subprocess.Popen(self.argv, cwd=project, env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.transcript.append({'launch': self.argv, 'pid': self.proc.pid})

    def send(self, method, params):
        self.serial += 1
        frame = {'id': self.serial, 'method': method, 'params': params}
        self.transcript.append({'request': frame, 'pid': self.proc.pid})
        self.proc.stdin.write(json.dumps(frame) + '\n')
        self.proc.stdin.flush()
        return self.serial

    def receive(self, serial, allow_error=False):
        if not select.select([self.proc.stdout], [], [], 20)[0]:
            raise RuntimeError('RPC deadline')
        raw = self.proc.stdout.readline()
        self.transcript.append({'response': raw, 'pid': self.proc.pid})
        result = json.loads(raw)
        assert result['id'] == serial, result
        if 'error' in result and not allow_error:
            raise RuntimeError(json.dumps(result['error']))
        return result

    def call(self, method, params, allow_error=False):
        response = self.receive(self.send(method, params), allow_error)
        return response if allow_error else response['result']

    def close(self):
        if self.proc.poll() is None:
            if not self.proc.stdin.closed:
                self.proc.stdin.close()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=5)
        self.transcript.append({'stopped': self.proc.pid, 'exit': self.proc.returncode,
                                'stderr': self.proc.stderr.read()})
        assert self.proc.poll() is not None


def wait_past(timestamp):
    end = dt.datetime.fromisoformat(timestamp.replace('Z', '+00:00')).timestamp() + .20
    delay = end - time.time()
    assert delay < 4, 'fixture unexpectedly has a long deadline'
    if delay > 0:
        time.sleep(delay)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--binary', type=Path, required=True)
    ap.add_argument('--legacy-binary', type=Path, required=True)
    ap.add_argument('--source-root', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    binary = args.binary.resolve(strict=True)
    legacy = args.legacy_binary.resolve(strict=True)
    source = args.source_root.resolve(strict=True)
    out = args.output.resolve()
    raw = out.with_suffix('.raw.json')
    assert not out.exists() and not raw.exists(), 'new receipt paths required'
    out.parent.mkdir(parents=True, exist_ok=True)
    base = Path(tempfile.mkdtemp(prefix='approval-expiry-rpc-', dir=ROOT / '.task-tmp')).resolve()
    result = {'status': 'failed', 'checks': [], 'providerRuns': 0, 'synthetic': True,
              'helperBefore': sha(binary), 'legacyBefore': sha(legacy), 'sourceBefore': source_hashes(source)}
    trace, processes = [], []
    database = None

    def check(name, condition, **details):
        result['checks'].append({'name': name, 'passed': bool(condition), **details})
        assert condition, name

    def start(bin_path, home, project):
        rpc = RPC(bin_path, home, project, trace)
        processes.append(rpc)
        return rpc

    def pending(rpc, project, name):
        flow = rpc.call('workflows.save', {'project': str(project), 'title': name, 'steps': [
            {'tool': 'file.write', 'arguments': {'path': name + '.txt', 'content': name}}]})
        run = rpc.call('workflows.run', {'id': flow['id'], 'dryRun': False})
        assert run['state'] == 'pending_approval'
        return run, run['steps'][0]['approvalId']

    try:
        new = base / 'vela-new'; old = base / 'vela-old'
        shutil.copy2(binary, new); shutil.copy2(legacy, old)
        project = base / 'project'; project.mkdir()
        other = base / 'other'; other.mkdir()
        home = base / 'home'
        rpc = start(new, home, project)
        rpc.call('projects.add', {'path': str(project)})
        rpc.call('projects.add', {'path': str(other)})
        prefs = rpc.call('settings.get', {})
        check('new-approval-policy-default-seven-days', prefs['approvalExpirySeconds'] == 604800)
        for bad in [True, False, -1, .5, '1', 31536001]:
            answer = rpc.call('settings.save', {'approvalExpirySeconds': bad}, allow_error=True)
            check('invalid-policy-rejected-' + repr(bad), 'error' in answer and
                  rpc.call('settings.get', {})['approvalExpirySeconds'] == 604800)

        rpc.call('settings.save', {'approvalExpirySeconds': 1})
        run, identity = pending(rpc, project, 'expired-action')
        approval = rpc.call('approvals.get', {'id': identity})
        wait_past(approval['expiresAt'])
        # Decide without an intervening get/list sweep: this tests the claim gate itself.
        rpc.call('approvals.decide', {'id': identity, 'decision': 'approve',
                 'snapshotHash': approval['snapshotHash']}, allow_error=True)
        after = rpc.call('approvals.get', {'id': identity})
        run_after = rpc.call('runs.get', {'id': run['id']})
        check('expired-claim-does-not-write-and-terminalizes-run', after['state'] == 'expired' and
              run_after['state'] == 'expired' and run_after['steps'][0]['state'] == 'expired' and
              not (project / 'expired-action.txt').exists())

        rpc.call('settings.save', {'approvalExpirySeconds': 30})
        _, identity = pending(rpc, project, 'fresh-action')
        approval = rpc.call('approvals.get', {'id': identity})
        decided = rpc.call('approvals.decide', {'id': identity, 'decision': 'approve',
                           'snapshotHash': approval['snapshotHash']})
        repeat = rpc.call('approvals.decide', {'id': identity, 'decision': 'approve',
                          'snapshotHash': approval['snapshotHash']}, allow_error=True)
        check('fresh-frozen-action-executes-once', decided['state'] == 'executed' and 'error' in repeat and
              (project / 'fresh-action.txt').read_text() == 'fresh-action')

        rpc.call('settings.save', {'approvalExpirySeconds': 1})
        locked_run, identity = pending(rpc, project, 'writer-wait-action')
        approval = rpc.call('approvals.get', {'id': identity})
        # Only the transaction barrier is injected, never business approval fields.
        database = sqlite3.connect(home / 'vela.sqlite3')
        database.execute('BEGIN IMMEDIATE')
        serial = rpc.send('approvals.decide', {'id': identity, 'decision': 'approve',
                          'snapshotHash': approval['snapshotHash']})
        wait_past(approval['expiresAt'])
        database.commit(); database.close(); database = None
        rpc.receive(serial, allow_error=True)
        after = rpc.call('approvals.get', {'id': identity})
        check('writer-wait-crosses-deadline-before-claim', after['state'] == 'expired' and
              rpc.call('runs.get', {'id': locked_run['id']})['state'] == 'expired' and
              not (project / 'writer-wait-action.txt').exists())

        rpc.call('settings.save', {'approvalExpirySeconds': 0})
        wanted = []
        for name in ['page-a', 'page-b', 'page-c']:
            _, identity = pending(rpc, project, name)
            row = rpc.call('approvals.get', {'id': identity})
            assert not row.get('expiresAt') and row.get('expiryMode') == 'disabled', row
            wanted.append(row)
        _, foreign = pending(rpc, other, 'other-page')
        page = rpc.call('approvals.list', {'project': str(project), 'limit': 2})
        page2 = rpc.call('approvals.list', {'project': str(project), 'limit': 2, 'cursor': page['cursor']})
        ids = [item['id'] for item in page['items'] + page2['items']]
        expected = [row['id'] for row in sorted(wanted, key=lambda row: (row['createdAt'], row['id']))]
        check('pending-pagination-oldest-first-and-project-isolated', ids == expected and
              foreign not in ids and page2['cursor'] is None)
        expired = rpc.call('approvals.list', {'project': str(project), 'state': 'expired', 'limit': 100})
        check('expired-list-is-explicit', len(expired['items']) == 2 and all(row['state'] == 'expired' for row in expired['items']))
        rpc.close(); processes.remove(rpc)
        rpc = start(new, home, project)
        check('deadline-policy-persists-after-restart', rpc.call('settings.get', {})['approvalExpirySeconds'] == 0)

        legacy_home = base / 'legacy-home'
        legacy_rpc = start(old, legacy_home, project)
        legacy_rpc.call('projects.add', {'path': str(project)})
        _, identity = pending(legacy_rpc, project, 'legacy-action')
        legacy_rpc.close(); processes.remove(legacy_rpc)
        upgraded = start(new, legacy_home, project)
        approval = upgraded.call('approvals.get', {'id': identity})
        check('actual-old-helper-pending-remains-legacy-unbounded', approval['expiryMode'] == 'legacy_unbounded' and not approval.get('expiresAt'))
        decision = upgraded.call('approvals.decide', {'id': identity, 'decision': 'approve',
                                 'snapshotHash': approval['snapshotHash']})
        check('actual-legacy-pending-still-executes-frozen-action', decision['state'] == 'executed' and
              (project / 'legacy-action.txt').read_text() == 'legacy-action')
        result['status'] = 'passed'
    except Exception as error:
        result['failure'] = type(error).__name__ + ': ' + str(error)
    finally:
        if database is not None:
            try:
                database.rollback()
            except Exception as error:
                result.setdefault('cleanupErrors', []).append(str(error)); result['status'] = 'failed'
            finally:
                try:
                    database.close()
                except Exception as error:
                    result.setdefault('cleanupErrors', []).append(str(error)); result['status'] = 'failed'
        for process in processes:
            try:
                process.close()
            except Exception as error:
                result.setdefault('cleanupErrors', []).append(str(error)); result['status'] = 'failed'
        try:
            result['helperAfter'] = sha(binary); result['legacyAfter'] = sha(legacy)
            result['sourceAfter'] = source_hashes(source)
            result['inputsUnchanged'] = result['helperBefore'] == result['helperAfter'] and result['legacyBefore'] == result['legacyAfter'] and result['sourceBefore'] == result['sourceAfter']
            if not result['inputsUnchanged']:
                result['status'] = 'failed'
        except Exception as error:
            result['integrityError'] = str(error); result['status'] = 'failed'
        try:
            shutil.rmtree(base)
        except Exception as error:
            result.setdefault('cleanupErrors', []).append(str(error)); result['status'] = 'failed'
        result['fixtureRemoved'] = not base.exists()
        if not result['fixtureRemoved']:
            result['status'] = 'failed'
        raw.write_text(json.dumps(trace, indent=2) + '\n')
        out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'status': result['status'], 'checks': len(result['checks']), 'output': str(out)}))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
