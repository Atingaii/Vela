"""Measure warm real-CLI substring search over deterministic indexed records.

Run after `swift build -c release`. Defaults cover 10k and 100k SQLite objects,
not raw messages, ingestion, cold startup, or UI latency. Each measured case must
have p95 < 120 ms; a failure exits 1 while still emitting the complete JSON report.
Only newly created temporary stores are used, and all are removed on completion.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
import pathlib
import platform
import select
import sqlite3
import statistics
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT = '/synthetic/benchmark'


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True, timeout=15).strip()


def metadata(binary):
    digest = hashlib.sha256()
    with binary.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return dict(binary=str(binary.relative_to(ROOT)) if binary.is_relative_to(ROOT) else binary.name,
                binarySHA256=digest.hexdigest(), binaryBuild='release' if 'release' in binary.parts else 'unspecified',
                commit=command('git', 'rev-parse', 'HEAD'), workingTreeDirty=bool(command('git', 'status', '--porcelain')),
                platform=platform.platform(), machine=platform.machine(), python=platform.python_version(),
                sqlitePython=sqlite3.sqlite_version, swift=command('swift', '--version'),
                cpu=command('/usr/sbin/sysctl', '-n', 'machdep.cpu.brand_string'),
                memoryBytes=int(command('/usr/sbin/sysctl', '-n', 'hw.memsize')))


class RPC:
    def __init__(self, binary, home, env):
        self.process = subprocess.Popen([str(binary), 'rpc', '--home', str(home), '--no-watch', '--no-schedule'],
                                        env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buffer = bytearray()
        self.sequence = 0

    def call(self, method, params):
        self.sequence += 1
        self.process.stdin.write((json.dumps(dict(id=self.sequence, method=method, params=params)) + '\n').encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 15
        while True:
            if b'\n' in self.buffer:
                line, _, self.buffer = self.buffer.partition(b'\n')
                result = json.loads(line)
                if result.get('id') != self.sequence:
                    raise RuntimeError('Unexpected RPC response identifier')
                if 'error' in result:
                    raise RuntimeError(result['error'])
                return result['result']
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise TimeoutError('Real CLI search response exceeded 15 seconds')
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError('Real CLI closed before returning a response')
            self.buffer.extend(chunk)
            if len(self.buffer) > 16 * 1024 * 1024:
                raise RuntimeError('Benchmark response exceeded bounded reader size')

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
            raise
        if self.process.returncode:
            raise RuntimeError(self.process.stderr.read().decode(errors='replace'))
        self.process.stdout.close()
        self.process.stderr.close()


def run_size(args, binary, count):
    env = dict(os.environ, VELA_DISABLE_DISCOVERY='1')
    env.pop('VELA_SESSION_ROOT', None)
    with tempfile.TemporaryDirectory(prefix='vela-benchmark-read-') as temporary:
        home = pathlib.Path(temporary) / 'store'
        env['VELA_HOME'] = str(home)
        subprocess.run([str(binary), 'call', 'system.version', '{}', '--home', str(home)],
                       env=env, check=True, stdout=subprocess.DEVNULL, timeout=15)
        fixture_hash = hashlib.sha256()

        def rows():
            for i in range(count):
                item = dict(id=f'fixture-{i:06}', kind='session', project=PROJECT,
                            title=f'Verification {i}', content=f'synthetic engineering evidence topic-{i % 100} ' + ('bounded context ' * 20),
                            updatedAt=f'2026-09-12T00:{i % 60:02}:00Z', messages=[])
                # Retain the historical benchmark's payload and JSON spacing so
                # an index change is not credited for a smaller stored object.
                encoded = json.dumps(item)
                fixture_hash.update((encoded + '\n').encode())
                yield ('session', item['id'], item['project'], item['title'], item['content'], 0, item['updatedAt'], encoded)

        with sqlite3.connect(home / 'vela.sqlite3') as database:
            begin = time.perf_counter()
            database.executemany('INSERT INTO objects(kind,id,project,title,content,private,updatedAt,json) VALUES(?,?,?,?,?,?,?,?)', rows())
            database.commit()
            insert_ms = (time.perf_counter() - begin) * 1000
            database.execute('PRAGMA wal_checkpoint(TRUNCATE)')
            indexes = [row[0] for row in database.execute("SELECT sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY name")]

        client = RPC(binary, home, env)
        cases = []
        try:
            version = client.call('system.version', {})['version']
            definitions = [
                ('project_topic', True, lambda i: f'topic-{i % 100}', 50),
                ('global_topic', False, lambda i: f'topic-{i % 100}', 50),
                ('project_miss', True, lambda _: 'absent-search-needle', 0),
                ('global_miss', False, lambda _: 'absent-search-needle', 0),
                ('project_sparse', True, lambda _: f'Verification {count - 1}', 1),
                ('project_multiword', True, lambda _: 'engineering evidence', 50),
            ]
            for name, scoped, query, expected_count in definitions:
                durations = []
                for sample in range(args.warmups + args.samples):
                    params = dict(query=query(sample), includePrivate=False)
                    if scoped:
                        params['project'] = PROJECT
                    begin = time.perf_counter()
                    response = client.call('search', params)
                    duration = (time.perf_counter() - begin) * 1000
                    if len(response) != expected_count:
                        raise AssertionError(f'{name}: expected {expected_count} results, observed {len(response)}')
                    if sample >= args.warmups:
                        durations.append(duration)
                p95 = sorted(durations)[math.ceil(0.95 * len(durations)) - 1]
                cases.append(dict(name=name, scoped=scoped, includePrivate=False, expectedResults=expected_count,
                                  medianMs=round(statistics.median(durations), 3), p95Ms=round(p95, 3),
                                  maxMs=round(max(durations), 3), thresholdMs=120, comparison='<',
                                  passed=p95 < 120, samplesMs=[round(value, 3) for value in durations]))
        finally:
            client.close()
        return dict(indexedRecords=count, rawMessages=None, fixtureSHA256=fixture_hash.hexdigest(),
                    fixture='historical-read-v1: one project, public session objects, 100 lexical topics, empty message arrays',
                    cliVersion=version, warmupsPerCase=args.warmups, samplesPerCase=args.samples,
                    insertElapsedMs=round(insert_ms, 3), databaseBytes=(home / 'vela.sqlite3').stat().st_size,
                    indexes=indexes, cases=cases, passed=all(case['passed'] for case in cases))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=pathlib.Path, default=ROOT / '.build/release/vela')
    parser.add_argument('--records', type=int, nargs='+', choices=[10000, 100000], default=[10000, 100000])
    parser.add_argument('--warmups', type=int, default=10)
    parser.add_argument('--samples', type=int, default=50)
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    if args.samples < 20 or args.warmups < 1:
        parser.error('Use at least 20 samples and one warm-up per case.')
    binary = args.binary.resolve(strict=True)
    report = dict(format='vela-search-benchmark-v2', timestampUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  metric='warm RPC substring search latency', cache='Configured warmups per case; OS cache is not evicted',
                  limits='Indexed objects only; not ingestion, raw messages, cold startup, concurrent agents or UI timing.',
                  environment=metadata(binary), results=[run_size(args, binary, count) for count in args.records])
    report['passed'] = all(result['passed'] for result in report['results'])
    text = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    print(text, end='')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
