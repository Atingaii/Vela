#!/usr/bin/env python3
"""Post-verify one retained Golden live fixture without a provider call or refresh."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def stop(process):
    if process and process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def golden_parser():
    spec = importlib.util.spec_from_file_location('golden_live_parser', ROOT / 'scripts/test-golden-live.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module.parse_codex_source


class RPC:
    def __init__(self, binary, env, cwd, out):
        self.responses, self.failed, self.seq = queue.Queue(maxsize=128), None, 0
        self.log = (out / 'rpc.jsonl').open('w')
        self.stderr = (out / 'helper.stderr').open('w')
        self.process = subprocess.Popen([str(binary), 'rpc', '--home', env['VELA_HOME'], '--no-schedule'], env=env,
            cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr, text=True, bufsize=1,
            start_new_session=True)
        self.reader = threading.Thread(target=self.read, daemon=True); self.reader.start()

    def read(self):
        try:
            for line in self.process.stdout:
                if len(line.encode()) > 32 * 1024 * 1024 or not line.endswith('\n'):
                    raise ValueError('Truncated or oversized RPC frame')
                result = json.loads(line)
                if result.get('event') != 'data.changed':
                    self.responses.put_nowait(result)
        except Exception as error:
            self.failed = type(error).__name__

    def call(self, method, params, deadline):
        if method == 'sessions.refresh':
            raise RuntimeError('Post-verification cannot refresh sources')
        if self.failed or self.process.poll() is not None:
            raise RuntimeError('RPC stopped')
        wait = min(20, deadline - time.monotonic())
        if wait <= 0:
            raise RuntimeError('Post-verification deadline elapsed')
        self.seq += 1; request = {'id': str(self.seq), 'method': method, 'params': params}
        self.process.stdin.write(json.dumps(request) + '\n'); self.process.stdin.flush()
        wait = min(20, deadline - time.monotonic())
        if wait <= 0:
            raise RuntimeError('Post-verification deadline elapsed')
        try:
            response = self.responses.get(timeout=wait)
        except queue.Empty:
            raise RuntimeError('Post-verification RPC timeout: ' + method) from None
        if response.get('id') != request['id']:
            raise RuntimeError('Post-verification RPC identity mismatch')
        self.log.write(json.dumps({'request': request, 'response': response}) + '\n'); self.log.flush()
        if 'error' in response or 'result' not in response:
            raise RuntimeError('Post-verification RPC rejected ' + method)
        return response['result']

    def close(self):
        stop(self.process); self.reader.join(timeout=2); self.log.close(); self.stderr.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--prior-receipt', type=Path, required=True)
    parser.add_argument('--prior-output', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New immediate output/parity child')
    parser.add_argument('--timeout', type=int, default=90)
    args = parser.parse_args()
    fixture, prior, prior_out, out = args.fixture.resolve(strict=True), args.prior_receipt.resolve(strict=True), args.prior_output.resolve(strict=True), args.output.absolute()
    if not 30 <= args.timeout <= 180 or out.exists() or out.is_symlink() or out.parent != ROOT / 'output/parity':
        parser.error('Require a 30–180 second timeout and a new immediate output/parity child')
    owner = json.loads((fixture / '.owner.json').read_text())
    if owner.get('format') != 'vela-golden-live-owned-v1' or not (fixture / 'sources/codex').is_dir():
        parser.error('Retained fixture ownership/source root is invalid')
    prior_data = json.loads(prior.read_text())
    if prior_data.get('componentResult') != 'fail' or not prior_data.get('cleanup', {}).get('temporaryAuthRemoved'):
        parser.error('Prior receipt is not the retained failed no-auth fixture')
    out.mkdir(mode=0o700); receipt = {'format': 'vela-golden-live-postverify-v1', 'status': 'not_run',
        'sameLiveSessionEvidence': True, 'newProviderRuns': 0, 'manualRefresh': False, 'manualCandidateWrites': False,
        'priorReceipt': str(prior), 'priorReceiptSHA256': sha(prior.read_bytes()), 'harnessSHA256': sha((ROOT / 'scripts/test-golden-live.py').read_bytes()),
        'steps': {}, 'cleanup': {}}
    rpc = None
    try:
        project = fixture / 'Bounds'; sources = fixture / 'sources/codex'; helper = fixture / 'vela-frozen'
        if not project.is_dir() or not helper.is_file() or helper.is_symlink():
            raise RuntimeError('Retained project/helper is unavailable')
        if sha(helper.read_bytes()) != prior_data.get('helperSHA256'):
            raise RuntimeError('Retained helper hash differs from original live receipt')
        receipt['helperSHA256'] = sha(helper.read_bytes())
        turns = prior_data.get('providerTurns', []); labels = ['01-task', '02-first-constraint', '03-new-session-correction', '04-second-constraint']
        if [row.get('label') for row in turns] != labels or any(row.get('exitCode') != 0 for row in turns):
            raise RuntimeError('Original four provider turn receipt is incomplete')
        threads = {row['label']: row.get('threadId') for row in turns}
        if not all(isinstance(value, str) for value in threads.values()) or threads['01-task'] != threads['02-first-constraint'] or threads['03-new-session-correction'] != threads['04-second-constraint'] or threads['01-task'] == threads['03-new-session-correction']:
            raise RuntimeError('Original provider thread mapping is invalid')
        prompt_map = {}
        for row in turns:
            text = (prior_out / (row['label'] + '.prompt.txt')).read_text()
            if sha(text.encode()) != row.get('promptSHA256'):
                raise RuntimeError('Retained prompt hash differs from original live receipt')
            prompt_map[row['label']] = text
        env = {key: value for key, value in os.environ.items() if not key.startswith(('VELA_', 'CODEX_'))}
        env.update(VELA_HOME=str(fixture / 'store'), VELA_SESSION_ROOT=str(fixture / 'sources'), VELA_DISABLE_DISCOVERY='1')
        rpc = RPC(helper, env, fixture, out); deadline = time.monotonic() + args.timeout
        rpc.call('projects.add', {'path': str(project)}, deadline)
        sessions = rpc.call('sessions.list', {'project': str(project)}, deadline)
        indexed = {row.get('sourceSessionId'): row for row in sessions if row.get('project') == str(project) and row.get('sourceSessionId') in {threads['01-task'], threads['03-new-session-correction']}}
        if set(indexed) != {threads['01-task'], threads['03-new-session-correction']} or len(indexed) != 2:
            raise RuntimeError('Expected exactly the two original project-scoped provider sessions')
        parse = golden_parser(); session_details = {thread: rpc.call('sessions.get', {'id': row['id']}, deadline) for thread, row in indexed.items()}
        evidence, raw_by_thread = [], {}
        (out / 'sources').mkdir()
        for thread, session in session_details.items():
            source = Path(session.get('sourcePath', '')).resolve(strict=True)
            if not source.is_relative_to(sources.resolve()) or not source.is_file() or source.is_symlink() or source.stat().st_size > 32 * 1024 * 1024:
                raise RuntimeError('Retained source path is outside bounded owned Codex root')
            data = source.read_bytes(); parsed = parse(data); meta, users = parsed['meta'], parsed['users']
            if meta.get('id') != thread or meta.get('cwd') != str(project):
                raise RuntimeError('Raw session metadata does not bind original CLI thread and project')
            raw_by_thread[thread] = users
            target = out / 'sources' / (session['id'] + '.jsonl')
            shutil.copy2(source, target)
            receipt.setdefault('sources', []).append({'sessionId': session['id'], 'providerThread': thread, 'sessionMeta': {'id': meta['id'], 'cwd': meta['cwd']}, 'bytes': len(data), 'sha256': sha(data), 'rawEvidence': 'sources/' + target.name})
        expected = [('01-task', threads['01-task']), ('02-first-constraint', threads['02-first-constraint']), ('03-new-session-correction', threads['03-new-session-correction']), ('04-second-constraint', threads['04-second-constraint'])]
        for label, thread in expected:
            # The original harness writes one newline-delimited stdin frame. The
            # provider source and Vela record preserve that exact frame text.
            wire_prompt = prompt_map[label] + '\n'
            raw = [record for record in raw_by_thread[thread] if record['content'] == wire_prompt and record['id']]
            if len(raw) != 1:
                raise RuntimeError('Raw user source record is missing or ambiguous: ' + label)
            message = [item for item in session_details[thread].get('messages', []) if item.get('role') == 'user' and item.get('id') == raw[0]['id'] and item.get('content') == wire_prompt]
            if len(message) != 1:
                raise RuntimeError('Vela user ID/content mapping differs from raw provider record: ' + label)
            evidence.append({'label': label, 'providerThread': thread, 'sessionId': session_details[thread]['id'], 'rawMessageId': raw[0]['id'], 'velaMessageId': message[0]['id'], 'sourceShape': raw[0]['shape'], 'wirePromptSHA256': sha(wire_prompt.encode())})
        receipt['steps']['rawProvenance'] = {'status': 'passed', 'fourTurns': evidence}
        analysis = rpc.call('improve.analyze', {'project': str(project)}, deadline)
        (out / 'analysis.json').write_text(json.dumps(analysis, ensure_ascii=False, indent=2) + '\n')
        pairs = {(row['sessionId'], row['velaMessageId']) for row in evidence if row['label'] != '01-task'}
        candidates = [row for row in analysis.get('candidateMemories', []) if row.get('state') == 'candidate' and (row.get('sourceSession'), row.get('sourceMessage')) in pairs and row.get('provenance', {}).get('origin') == 'session_explicit_constraint']
        if not candidates:
            raise RuntimeError('Automatic candidate evidence is missing or has mismatched provenance')
        clusters = [row for row in analysis.get('clusters', []) if row.get('title') == 'verification' and row.get('signalCount', 0) >= 3 and row.get('distinctSessions', 0) >= 2]
        if not clusters:
            raise RuntimeError('Distinct-session verification cluster is missing')
        suggestions = [row for row in analysis.get('suggestions', []) if row.get('clusterId') in {cluster['id'] for cluster in clusters}]
        if not suggestions:
            raise RuntimeError('Evidence-linked suggestion is missing')
        links = []
        for suggestion in suggestions:
            result = rpc.call('evidence.get', {'id': suggestion['id']}, deadline)
            for ref in result.get('references', []):
                pair = (ref.get('sessionId'), ref.get('messageId'))
                if pair not in pairs:
                    continue
                session = next((row for row in session_details.values() if row['id'] == pair[0]), None)
                message = next((row for row in session.get('messages', []) if row.get('id') == pair[1]), None) if session else None
                if not message or message.get('content') != ref.get('quote'):
                    raise RuntimeError('Suggestion evidence does not exactly map to Vela source message')
                links.append({'suggestionId': suggestion['id'], 'sessionId': pair[0], 'messageId': pair[1]})
        if len(links) < 3:
            raise RuntimeError('Suggestion does not retain three exact correction evidence links')
        receipt['steps']['improveAnalyze'] = {'status': 'passed', 'candidateIds': [row['id'] for row in candidates], 'clusterIds': [row['id'] for row in clusters], 'suggestionIds': [row['id'] for row in suggestions], 'exactEvidenceLinks': links}
        receipt['status'] = 'passed'
    except Exception as error:
        receipt['status'] = 'failed'; receipt['failure'] = str(error)[:3000]
    finally:
        if rpc: rpc.close()
        receipt['cleanup']['helperStopped'] = rpc is None or rpc.process.poll() is not None
        (out / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({'receipt': str(out / 'receipt.json'), 'status': receipt['status'], 'newProviderRuns': 0}, ensure_ascii=False))
    return 0 if receipt['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
