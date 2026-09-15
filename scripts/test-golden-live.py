"""Opt-in real Codex Observe/Remember/Improve component acceptance.

Four real turns, two provider-owned sessions, one fresh project and live watcher.
Controlled correction prompts are test inputs, never a measured model defect or
improvement rate. The existing auth file is linked for the same CLI, not read or
copied. The temporary auth link is always removed. No complete Golden claim.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import stat
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
STIMULI = ('以后完成任务之前一定先跑测试。', '怎么又没测试？完成前必须先运行项目测试。',
           '以后交付这个项目的代码前，一定先运行项目测试并报告真实结果。')
TASK = ('Implement clamp(value, lower, upper) in bounds.py. Accept finite int/float values, '
        'including endpoints; restrict the value to the inclusive interval. Reject booleans '
        'and non-numbers with TypeError, non-finite numbers or reversed bounds with ValueError. '
        'Keep the signature unchanged. Do not edit verify.py or project configuration. '
        'Summarize the actual result.')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def parse_codex_source(data):
    """Parse bounded Codex JSONL source bytes without accepting ambiguous user shapes."""
    try:
        rows = [json.loads(line) for line in data.splitlines() if line.strip()]
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError('Malformed provider source JSONL') from error
    metadata = [row.get('payload') for row in rows if isinstance(row, dict) and row.get('type') == 'session_meta'
                and isinstance(row.get('payload'), dict)]
    if len(metadata) != 1:
        raise ValueError('Provider source requires exactly one session_meta record')
    users = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        payload = row.get('payload')
        if not isinstance(payload, dict):
            continue
        if row.get('type') == 'event_msg' and payload.get('type') == 'user_message':
            text = payload.get('message')
            if isinstance(text, str):
                users.append({'id': payload.get('id') if isinstance(payload.get('id'), str) else None, 'content': text,
                              'shape': 'event_msg.user_message'})
        elif row.get('type') == 'response_item' and payload.get('type') == 'message' and payload.get('role') == 'user':
            identifier, content = payload.get('id'), payload.get('content')
            if not isinstance(identifier, str) or not isinstance(content, list):
                continue
            parts = [item.get('text') for item in content if isinstance(item, dict) and item.get('type') == 'input_text'
                     and isinstance(item.get('text'), str)]
            if parts:
                users.append({'id': identifier, 'content': ''.join(parts), 'shape': 'response_item.message.user'})
    return {'meta': metadata[0], 'users': users}


def stop(process):
    if process and process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


class RPC:
    def __init__(self, binary, env, base, out):
        self.events, self.seq, self.failed, self.event_times = 0, 0, None, []
        self.responses = queue.Queue(maxsize=128)
        self.log = (out / 'rpc.jsonl').open('w')
        self.stderr = (out / 'helper.stderr').open('w')
        self.process = subprocess.Popen([str(binary), 'rpc', '--home', env['VELA_HOME'], '--no-schedule'],
            env=env, cwd=base, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
            text=True, bufsize=1, start_new_session=True)
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        try:
            while True:
                line = self.process.stdout.readline(32 * 1024 * 1024)
                if not line:
                    return
                if not line.endswith('\n'):
                    raise ValueError('Truncated or oversized RPC frame')
                result = json.loads(line)
                if result.get('event') == 'data.changed':
                    self.events += 1; self.event_times.append(round(time.monotonic(), 3))
                else:
                    self.responses.put_nowait(result)
        except Exception as error:
            self.failed = type(error).__name__

    def call(self, method, params, deadline=None):
        if self.failed or self.process.poll() is not None:
            raise RuntimeError('RPC failed or stopped')
        assert method != 'sessions.refresh', 'Discovery must be automatic'
        wait = 20 if deadline is None else min(20, deadline - time.monotonic())
        if wait <= 0:
            raise RuntimeError('RPC deadline elapsed: ' + method)
        self.seq += 1
        request = {'id': str(self.seq), 'method': method, 'params': params}
        self.process.stdin.write(json.dumps(request) + '\n')
        self.process.stdin.flush()
        wait = 20 if deadline is None else min(20, deadline - time.monotonic())
        if wait <= 0:
            raise RuntimeError('RPC deadline elapsed: ' + method)
        try:
            result = self.responses.get(timeout=wait)
        except queue.Empty:
            raise RuntimeError('RPC timeout: ' + method) from None
        if result.get('id') != request['id']:
            raise RuntimeError('RPC identity mismatch')
        self.log.write(json.dumps(dict(request, response=result)) + '\n')
        self.log.flush()
        if 'error' in result or 'result' not in result:
            raise RuntimeError('RPC rejected ' + method + ': ' + str(result.get('error')))
        return result['result']

    def close(self):
        stop(self.process)
        self.reader.join(timeout=2)
        self.log.close()
        self.stderr.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--codex', type=Path, default=Path(shutil.which('codex') or '/missing/codex'))
    p.add_argument('--auth-file', type=Path, required=True)
    p.add_argument('--fixture', type=Path, required=True, help='New immediate .task-tmp child')
    p.add_argument('--output', type=Path, required=True, help='New immediate output/parity child')
    p.add_argument('--model', default='gpt-5.6-terra')
    p.add_argument('--timeout', type=int, default=240)
    p.add_argument('--keep-fixture', action='store_true')
    p.add_argument('--live', action='store_true')
    a = p.parse_args()
    if not a.live or not 30 <= a.timeout <= 600:
        p.error('--live and a timeout of 30–600 seconds are required')
    base, out, auth = a.fixture.absolute(), a.output.absolute(), a.auth_file.absolute()
    for path, parent in ((base, ROOT / '.task-tmp'), (out, ROOT / 'output/parity')):
        if path.exists() or path.is_symlink() or path.parent != parent or parent.is_symlink():
            p.error('Choose new immediate owned fixture/evidence directories')
    info = auth.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        p.error('Auth must be an existing private ordinary current-user file')
    binary, codex = a.binary.resolve(strict=True), a.codex.resolve(strict=True)
    # Reuse the exact existing independent verifier without importing its live runner.
    tree = ast.parse((ROOT / 'scripts/test-agent-live.py').read_text())
    texts = [node.value for node in ast.walk(tree) if isinstance(node, ast.Constant) and isinstance(node.value, str)]
    verifiers = [text for text in texts if text.startswith('import math, unittest\n') and 'class BoundsTests' in text]
    if len(verifiers) != 1:
        p.error('Independent clamp verifier changed; review before live execution')
    base.mkdir(mode=0o700)
    out.mkdir(mode=0o700)
    marker = {'format': 'vela-golden-live-owned-v1', 'id': str(uuid.uuid4()), 'uid': os.getuid()}
    (base / '.owner.json').write_text(json.dumps(marker))
    receipt = {'format': 'vela-observe-improve-live-v1', 'goldenComplete': False,
        'componentResult': 'not_run', 'controlledStimuli': True, 'naturalDefectAndImprovementRate': 'not_measured',
        'manualProviderHistoryWrites': False, 'manualMemoryOrSuggestionWrites': False,
        'modelRequested': a.model, 'steps': {f'GS{i:02}': {'status': 'not_run'} for i in range(1, 21)},
        'providerTurns': [], 'cleanup': {}}
    rpc, observations = None, []
    auth_link = base / 'codex-home/auth.json'

    def save():
        (out / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')

    def command(argv, timeout=30):
        process = subprocess.Popen(argv, env=env, cwd=project, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=timeout)
            return process.returncode, stdout, stderr
        finally:
            stop(process)

    try:
        project = base / 'Bounds'
        project.mkdir()
        sources, home = base / 'sources', base / 'codex-home'
        home.mkdir(mode=0o700)
        for provider in ('codex', 'claude', 'cursor', 'pi', 'omp'):
            (sources / provider).mkdir(parents=True, exist_ok=True)
        (home / 'sessions').symlink_to(sources / 'codex', target_is_directory=True)
        auth_link.symlink_to(auth)
        helper = base / 'vela-frozen'
        shutil.copy2(binary, helper)
        receipt['helperSHA256'] = sha(helper.read_bytes())
        receipt['harnessSHA256'] = sha(Path(__file__).read_bytes())
        env = {key: value for key, value in os.environ.items() if not key.startswith(('VELA_', 'CODEX_'))}
        env.update(CODEX_HOME=str(home), VELA_HOME=str(base / 'store'), VELA_SESSION_ROOT=str(sources),
            VELA_DISABLE_DISCOVERY='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
        for name, argv in (('version', [str(codex), '--version']), ('login', [str(codex), 'login', 'status'])):
            code, stdout, stderr = command(argv, 20)
            receipt[name] = {'exitCode': code, 'stdoutSHA256': sha(stdout.encode()), 'stderrSHA256': sha(stderr.encode())}
            if name == 'version':
                receipt[name]['value'] = stdout.strip()[:120]
            if code:
                raise RuntimeError('Provider preflight failed: ' + name)
        (project / 'bounds.py').write_text('def clamp(value, lower, upper):\n    raise NotImplementedError\n')
        (project / 'verify.py').write_text(verifiers[0])
        (project / 'README.md').write_text('# Bounds\n\nRun `/usr/bin/python3 verify.py` to validate.\n')
        protected = {name: sha((project / name).read_bytes()) for name in ('verify.py', 'README.md')}
        for tail in (['init', '-q'], ['add', 'bounds.py', 'verify.py', 'README.md'],
                     ['-c', 'user.name=Vela Acceptance', '-c', 'user.email=acceptance@example.invalid', 'commit', '-qm', 'Frozen independent clamp task']):
            if command(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-C', str(project), *tail])[0]:
                raise RuntimeError('Synthetic Git setup failed')
        receipt['projectCommit'] = command(['/usr/bin/git', '-C', str(project), 'rev-parse', 'HEAD'])[1].strip()
        rpc = RPC(helper, env, base, out)
        rpc.call('projects.add', {'path': str(project)})
        if rpc.call('sessions.list', {'project': str(project)}):
            raise RuntimeError('Fresh project contains preexisting sessions')
        started = time.monotonic()

        def observe(deadline=None):
            rows = rpc.call('sessions.list', {'project': str(project)}, deadline)
            observations.append({'elapsedSeconds': round(time.monotonic() - started, 3), 'watchEvents': rpc.events,
                'lastWatchEventMonotonic': rpc.event_times[-1] if rpc.event_times else None,
                'sessions': [{key: row.get(key) for key in ('id', 'state', 'statusEvidence', 'statusInferred')} for row in rows]})
            return rows

        def turn(label, prompt, thread=None):
            argv = [str(codex), 'exec'] + (['resume'] if thread else [])
            argv += ['--ignore-user-config', '--json', '--model', a.model, '-c', 'approval_policy="never"',
                     '-c', 'sandbox_mode="workspace-write"', '-c', 'model_reasoning_effort="high"']
            if not thread:
                argv += ['--sandbox', 'workspace-write', '--cd', str(project)]
            argv += [thread, '-'] if thread else ['-']
            row = {'label': label, 'argv': argv, 'promptSHA256': sha(prompt.encode()), 'resolvedModelVersion': None}
            receipt['providerTurns'].append(row)
            (out / (label + '.prompt.txt')).write_text(prompt)
            stdout_path = out / (label + '.stdout.jsonl')
            with stdout_path.open('w') as stdout, (out / (label + '.stderr')).open('w') as stderr:
                process = subprocess.Popen(argv, env=env, cwd=project, stdin=subprocess.PIPE,
                    stdout=stdout, stderr=stderr, text=True, start_new_session=True)
                began = time.monotonic()
                try:
                    process.stdin.write(prompt + '\n')
                    process.stdin.close()
                    deadline = began + a.timeout
                    while process.poll() is None:
                        if time.monotonic() >= deadline:
                            raise RuntimeError('Provider timeout: ' + label)
                        observe(deadline)
                        time.sleep(min(.25, max(0, deadline - time.monotonic())))
                    row['exitCode'] = process.returncode
                finally:
                    stop(process)
                    row['durationSeconds'] = round(time.monotonic() - began, 3)
            data = stdout_path.read_bytes()
            row['stdoutSHA256'] = sha(data)
            events = [json.loads(line) for line in data.splitlines() if line.strip()]
            ids = [e['thread_id'] for e in events if e.get('type') == 'thread.started' and e.get('thread_id')]
            if row['exitCode'] or any(e.get('type') in ('error', 'turn.failed') for e in events) or not any(e.get('type') == 'turn.completed' for e in events):
                raise RuntimeError('Provider turn incomplete: ' + label)
            actual = ids[-1] if ids else thread
            uuid.UUID(actual)
            if thread and actual != thread:
                raise RuntimeError('Resume thread identity changed')
            row['threadId'] = actual
            row['reportedCommands'] = [e['item'] for e in events if e.get('type') == 'item.completed' and e.get('item', {}).get('type') == 'command_execution']
            if any(sha((project / name).read_bytes()) != digest for name, digest in protected.items()):
                raise RuntimeError('Provider changed protected verifier')
            save()
            print(json.dumps({'finishedTurn': label, 'durationSeconds': row['durationSeconds']}), flush=True)
            return actual

        first = turn('01-task', TASK)
        receipt['steps']['GS01'] = {'status': 'component_pass', 'thread': first}
        code, diff, _ = command(['/usr/bin/git', '-C', str(project), 'diff', '--binary'])
        (out / 'task.diff').write_text(diff)
        verifier_code, stdout, stderr = command(['/usr/bin/python3', 'verify.py'])
        (out / 'independent-verifier.log').write_text(stdout + stderr)
        if code or not diff or verifier_code:
            raise RuntimeError('Independent clamp implementation verification failed')
        receipt['steps']['GS04'] = {'status': 'component_pass', 'diffSHA256': sha(diff.encode()), 'independentVerifierExitCode': verifier_code}
        turn('02-first-constraint', STIMULI[0], first)
        second = turn('03-new-session-correction', STIMULI[1])
        if first == second:
            raise RuntimeError('Expected independent second session')
        turn('04-second-constraint', STIMULI[2], second)
        deadline = time.monotonic() + 45
        expected_threads = {STIMULI[0]: first, STIMULI[1]: second, STIMULI[2]: second}
        found, details = {}, []
        while time.monotonic() < deadline:
            details = [rpc.call('sessions.get', {'id': row['id']}, deadline) for row in observe(deadline)]
            found = {text: [(s, m) for s in details for m in s.get('messages', [])
                if s.get('project') == str(project) and s.get('sourceSessionId') == expected_threads[text]
                and m.get('role') == 'user' and m.get('content') == text + '\n'] for text in STIMULI}
            if all(found.values()):
                break
            time.sleep(min(.25, max(0, deadline - time.monotonic())))
        if not all(found.values()) or rpc.events <= 0:
            raise RuntimeError('Watcher did not ingest provider-owned correction messages')
        receipt['steps']['GS02'] = {'status': 'component_pass', 'watchEvents': rpc.events,
            'lastWatchEventMonotonic': rpc.event_times[-1], 'manualRefresh': False,
            'mapping': 'Dedicated Codex sessions link to the exact watched provider root'}
        receipt['steps']['GS03'] = {'status': 'not_run', 'reason': 'Native event-to-UI latency/liveness not measured'}
        receipt['steps']['GS06'] = {'status': 'component_pass', 'sessionId': found[STIMULI[0]][0][0]['id'], 'messageId': found[STIMULI[0]][0][1]['id']}
        receipt['steps']['GS08'] = {'status': 'component_pass', 'providerThreads': [first, second], 'controlledStimulus': True, 'naturalDefectClaimed': False}
        (out / 'sources').mkdir()
        receipt['sources'] = []
        for session in details:
            source = Path(session['sourcePath']).resolve(strict=True)
            if not source.is_relative_to(sources / 'codex') or not source.is_file() or source.stat().st_uid != os.getuid():
                raise RuntimeError('Source outside owned provider scope')
            if source.stat().st_size > 32 * 1024 * 1024:
                raise RuntimeError('Source exceeds evidence byte budget')
            data = source.read_bytes()
            parsed = parse_codex_source(data); meta, raw_users = parsed['meta'], parsed['users']
            if not isinstance(meta, dict) or meta.get('id') != session.get('sourceSessionId') or meta.get('cwd') != str(project):
                raise RuntimeError('Source session metadata does not bind CLI thread to owned project')
            for text, pairs in found.items():
                source_messages = [m for s, m in pairs if s['id'] == session['id']]
                # turn() sends a newline-delimited stdin frame; both the provider
                # source and the Vela message retain that newline as source text.
                if source_messages and not all(any(record['id'] == message.get('id') and record['content'] == text + '\n'
                    and message.get('content') == record['content']
                    for record in raw_users) for message in source_messages):
                    raise RuntimeError('Indexed user message lacks provider source record')
            filename = session['id'] + '.jsonl'
            if Path(filename).name != filename:
                raise RuntimeError('Invalid source identifier')
            (out / 'sources' / filename).write_bytes(data)
            receipt['sources'].append({'id': session['id'], 'providerThread': session.get('sourceSessionId'), 'bytes': len(data),
                'sha256': sha(data), 'rawEvidence': 'sources/' + filename,
                'sessionMeta': {'id': meta['id'], 'cwd': meta['cwd']},
                'userRecords': [{'id': record['id'], 'shape': record['shape']} for record in raw_users],
                'userMessageIds': [m['id'] for m in session.get('messages', []) if m.get('role') == 'user'],
                'toolMessageCount': sum(bool(m.get('tool')) for m in session.get('messages', []))})
        receipt['steps']['GS05'] = {'status': 'partial', 'reason': 'Source/message provenance verified; exhaustive changed-files/Todo equivalence not asserted'}
        analysis = rpc.call('improve.analyze', {'project': str(project)})
        (out / 'analysis.json').write_text(json.dumps(analysis, ensure_ascii=False, indent=2))
        pairs = {(s['id'], m['id']) for values in found.values() for s, m in values}
        memories = [m for m in analysis.get('candidateMemories', []) if m.get('state') == 'candidate'
            and (m.get('sourceSession'), m.get('sourceMessage')) in pairs and m.get('provenance', {}).get('origin') == 'session_explicit_constraint']
        if not memories:
            raise RuntimeError('GS07 automatic candidate missing/provenance mismatch')
        receipt['steps']['GS07'] = {'status': 'component_pass', 'candidateIds': [m['id'] for m in memories]}
        clusters = [c for c in analysis.get('clusters', []) if c.get('title') == 'verification' and c.get('signalCount', 0) >= 3 and c.get('distinctSessions', 0) >= 2]
        if not clusters:
            raise RuntimeError('GS09 distinct-source verification cluster missing')
        receipt['steps']['GS09'] = {'status': 'component_pass', 'clusterIds': [c['id'] for c in clusters]}
        suggestions = [s for s in analysis.get('suggestions', []) if s.get('clusterId') in {c['id'] for c in clusters}]
        if not suggestions:
            raise RuntimeError('GS10 evidence-linked suggestion missing')
        receipt['steps']['GS10'] = {'status': 'partial', 'suggestionIds': [s['id'] for s in suggestions],
            'reason': 'Reviewable Markdown draft; not adopted or verified executable'}
        links = []
        for suggestion in suggestions:
            evidence = rpc.call('evidence.get', {'id': suggestion['id']})
            for ref in evidence['references']:
                if 'sessionId' not in ref or 'messageId' not in ref:
                    continue
                s = rpc.call('sessions.get', {'id': ref['sessionId']})
                message = next((m for m in s.get('messages', []) if m.get('id') == ref['messageId']), None)
                if s.get('project') != str(project) or message is None or message.get('content') != ref.get('quote'):
                    raise RuntimeError('Evidence source/message mismatch')
                links.append({'suggestionId': suggestion['id'], 'sessionId': s['id'], 'messageId': message['id']})
        if len(links) < 3:
            raise RuntimeError('Exact source links missing')
        receipt['steps']['GS11'] = {'status': 'not_run', 'reason': 'Native evidence click not exercised'}
        receipt['steps']['GS12'] = {'status': 'partial', 'exactAPILinks': links, 'nativeNavigation': 'not_run'}
        receipt['componentResult'] = 'pass'
        receipt['fixture'] = str(base)
    except Exception as error:
        receipt['componentResult'] = 'fail'
        receipt['failure'] = str(error)[:3000]
    finally:
        if rpc:
            rpc.close()
        (out / 'watch-observations.json').write_text(json.dumps(observations, indent=2))
        if auth_link.is_symlink():
            if os.readlink(auth_link) != str(auth):
                raise RuntimeError('Auth link changed; cleanup requires review')
            auth_link.unlink()
        elif auth_link.exists():
            current = auth_link.lstat()
            if not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid():
                raise RuntimeError('Unexpected refreshed auth file')
            auth_link.unlink()
        receipt['cleanup']['temporaryAuthRemoved'] = not auth_link.exists()
        if base.is_symlink() or base.stat().st_uid != os.getuid() or json.loads((base / '.owner.json').read_text()) != marker:
            raise RuntimeError('Fixture identity changed; no recursive cleanup')
        if not a.keep_fixture:
            shutil.rmtree(base)
        receipt['cleanup'].update(fixtureRemoved=not base.exists(), retainedForContinuation=a.keep_fixture,
            helperStopped=rpc is None or rpc.process.poll() is not None)
        save()
        print(json.dumps({'receipt': str(out / 'receipt.json'), 'componentResult': receipt['componentResult'],
            'goldenComplete': False, 'failure': receipt.get('failure')}, ensure_ascii=False), flush=True)
    return 0 if receipt['componentResult'] == 'pass' else 1


if __name__ == '__main__':
    raise SystemExit(main())
