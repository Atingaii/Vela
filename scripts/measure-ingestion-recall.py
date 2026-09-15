#!/usr/bin/env python3
"""Measure repeated local lexical recall under a real source rule on an owned fixture."""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import select
import shutil
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--memories', type=int, default=2000)
    args = parser.parse_args()
    assert 100 <= args.memories <= 5000
    binaries = {key: getattr(args, key).resolve(strict=True) for key in ('baseline', 'candidate')}
    output = args.output.resolve()
    if output.exists():
        parser.error('Choose a new receipt path')
    scratch = ROOT / '.task-tmp'
    scratch.mkdir(exist_ok=True)
    base = Path(tempfile.mkdtemp(prefix='ingestion-recall-timing-', dir=scratch)).resolve()
    result = {'format': 'vela-ingestion-recall-timing-v1', 'status': 'failed', 'synthetic': True,
              'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'providerRuns': 0, 'memories': args.memories, 'warmupCallsPerProcess': 1,
              'measuredCallsPerProcess': 7, 'helpers': {}, 'measurements': {},
              'claimScope': 'Helper-only sequential lexical RPC on synthetic managed assets; not whole-app RSS or UI latency.'}
    proc = None
    serial = 0
    try:
        project, home, logs = (base / key for key in ('project', 'store', 'logs'))
        for path in (project, home, logs / 'claude'):
            path.mkdir(parents=True)
        env = dict(os.environ, VELA_HOME=str(home), VELA_SESSION_ROOT=str(logs), VELA_DISABLE_DISCOVERY='1')
        for label, binary in binaries.items():
            copy = base / ('vela-' + label)
            shutil.copy2(binary, copy)
            result['helpers'][label] = {'path': str(binary), 'sha256Before': sha(binary), 'copy': str(copy)}

        def stop():
            if proc is not None and proc.poll() is None:
                proc.stdin.close()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)

        def start(label):
            return subprocess.Popen([result['helpers'][label]['copy'], 'rpc', '--no-watch', '--no-schedule'],
                                    cwd=project, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True)

        def call(method, params):
            nonlocal serial
            serial += 1
            proc.stdin.write(json.dumps({'id': serial, 'method': method, 'params': params}) + '\n')
            proc.stdin.flush()
            assert select.select([proc.stdout], [], [], 30)[0], method + ' deadline'
            value = json.loads(proc.stdout.readline())
            assert value.get('id') == serial and 'error' not in value, value
            return value['result']

        proc = start('baseline')
        call('projects.add', {'path': str(project)})
        for index in range(args.memories):
            call('memory.save', {'id': 'timing-' + str(index).zfill(5), 'project': str(project),
                                 'title': 'Recall timing evidence', 'content': 'timing deterministic context ' + str(index),
                                 'state': 'active', 'scope': 'project'})
        log = logs / 'claude' / 'fixture.jsonl'
        log.write_text(json.dumps({'type': 'user', 'uuid': 'timing-source', 'sessionId': 'timing-source',
                                  'cwd': str(project), 'message': {'role': 'user', 'content': 'Source-rule fixture.'}}) + '\n')
        call('sessions.refresh', {})
        call('ingestion.exclusions.upsert', {'project': str(project), 'provider': 'claude', 'pathGlob': 'fixture.jsonl'})
        stop()
        assets_before = {p.name: sha(p) for p in (home / 'assets/memory').iterdir()}
        expected_ids = None
        # Two independent helper processes use the same immutable assets and policy.
        for label in ('baseline', 'candidate'):
            proc = start(label)
            times, rss = [], []
            for iteration in range(8):
                started = time.perf_counter()
                response = call('recall', {'project': str(project), 'query': 'timing', 'budget': 4000})
                elapsed = (time.perf_counter() - started) * 1000
                ids = [item['id'] for item in response['items']]
                assert ids and response['usedTokens'] <= 4000
                if expected_ids is None:
                    expected_ids = ids
                assert ids == expected_ids, 'Recall results changed between processes'
                if iteration:
                    times.append(elapsed)
                    sample = subprocess.run(['ps', '-p', str(proc.pid), '-o', 'rss='], check=True,
                                            capture_output=True, text=True)
                    rss.append(int(sample.stdout.strip()))
            result['measurements'][label] = {'milliseconds': times, 'medianMs': statistics.median(times),
                'p95Ms': sorted(times)[math.ceil(len(times) * .95) - 1], 'sampledHelperRSSKiB': rss,
                'sampledHelperPeakRSSKiB': max(rss), 'returnedIDs': expected_ids}
            stop()
        result['assetsUnchanged'] = assets_before == {p.name: sha(p) for p in (home / 'assets/memory').iterdir()}
        result['medianRatioCandidateToBaseline'] = result['measurements']['candidate']['medianMs'] / result['measurements']['baseline']['medianMs']
        result['status'] = 'passed' if result['assetsUnchanged'] else 'failed'
    except Exception as error:
        result['failure'] = repr(error)
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        result['helperStopped'] = proc is None or proc.poll() is not None
        for label, item in result['helpers'].items():
            item['sha256After'] = sha(binaries[label])
            item['unchanged'] = item['sha256Before'] == item['sha256After'] == sha(Path(item.pop('copy')))
        if not result['helperStopped'] or not all(item['unchanged'] for item in result['helpers'].values()):
            result['status'] = 'failed'
        shutil.rmtree(base)
        result['fixtureRemoved'] = not base.exists()
        result['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result.get(key) for key in ('status', 'failure', 'medianRatioCandidateToBaseline', 'fixtureRemoved')}))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
