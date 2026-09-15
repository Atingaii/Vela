"""Recover acknowledged state and partial JSONL after real helper SIGKILL.

Uses only newly created synthetic logs/stores. Two forced terminations and two
reopens check acknowledged Memory/Markdown/settings/session persistence, a partial
record completed after restart, and duplicate-free reindexing. Explicit refresh
is used with --no-watch: this is not a watcher/UI, power-loss, disk-full, or
unacknowledged in-flight side-effect durability guarantee.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import select
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]


class Helper:
    def __init__(self, binary, home, sources):
        env = dict(os.environ, VELA_HOME=str(home), VELA_SESSION_ROOT=str(sources), VELA_DISABLE_DISCOVERY='1')
        self.process = subprocess.Popen([str(binary), 'rpc', '--home', str(home), '--no-watch'],
                                        env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.pending = bytearray()
        self.identifier = 0

    def call(self, method, params=None):
        self.identifier += 1
        request = dict(id=self.identifier, method=method, params=params or {})
        self.process.stdin.write((json.dumps(request) + '\n').encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 15
        while b'\n' not in self.pending:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([self.process.stdout], [], [], remaining)[0], f'{method}: helper response timed out'
            chunk = os.read(self.process.stdout.fileno(), 65536)
            assert chunk, f'{method}: helper exited before acknowledging the request'
            self.pending.extend(chunk)
            assert len(self.pending) <= 4 * 1024 * 1024, 'Unexpectedly large helper response'
        line, _, self.pending = self.pending.partition(b'\n')
        response = json.loads(line)
        assert response.get('id') == self.identifier and 'error' not in response, (method, response)
        return response['result']

    def kill(self):
        assert self.process.poll() is None, 'Only this live test helper may be killed'
        self.process.kill()
        code = self.process.wait(timeout=10)
        assert code == -signal.SIGKILL, f'Expected SIGKILL, got {code}'
        return code

    def close(self, graceful=False):
        if self.process.poll() is None:
            if graceful:
                self.process.stdin.close()
            else:
                self.process.terminate()
            try:
                code = self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
                raise
            if graceful:
                assert code == 0, self.process.stderr.read().decode(errors='replace')
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


def encoded(row):
    return (json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n').encode()


def asset_snapshot(memory, home):
    path = pathlib.Path(memory['assetPath'])
    assert path.resolve().is_relative_to(home.resolve()), 'Only fixture assets may be inspected'
    return path.read_bytes()


def verify_memory_and_settings(helper, project, home, memories, settings):
    current = helper.call('memory.list', dict(project=str(project)))
    assert {item['id'] for item in current} == set(memories), 'Acknowledged memories were lost or duplicated'
    for item in current:
        expected, original_bytes = memories[item['id']]
        assert item['title'] == expected['title'] and item['content'] == expected['content'], 'Memory content changed during recovery'
        assert item['project'] == str(project) and item['state'] == expected['state'], 'Memory scope/state changed during recovery'
        assert asset_snapshot(item, home) == original_bytes, 'Acknowledged Markdown asset changed during recovery'
    assert helper.call('settings.get') == settings, 'Acknowledged settings or timestamps changed during recovery'


def verify_session(helper, session_id, project, expected_messages, indexed_bytes):
    summaries = helper.call('sessions.list', dict(project=str(project)))
    assert len(summaries) == 1 and summaries[0]['id'] == session_id, 'Session identity changed or was duplicated'
    detail = helper.call('sessions.get', dict(id=session_id))
    observed = [(message['id'], message['content']) for message in detail['messages']]
    assert observed == expected_messages, (observed, expected_messages)
    assert len({identifier for identifier, _ in observed}) == len(observed), 'Duplicate message IDs after restart'
    assert detail['indexedBytes'] == indexed_bytes, 'Source cursor did not preserve the complete-record boundary'
    return detail


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=pathlib.Path, default=ROOT / '.build/debug/vela')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    helpers = []
    phases = []
    with tempfile.TemporaryDirectory(prefix='vela-restart-test-') as temporary:
        base = pathlib.Path(temporary).resolve()
        project, home, sources = base / 'project', base / 'store', base / 'sources'
        project.mkdir()
        (sources / 'claude').mkdir(parents=True)
        source = sources / 'claude' / 'restart.jsonl'
        first_content = 'Confirmed synthetic first message'
        second_content = '合成 continuation preserves a split UTF-8 record'
        first = encoded(dict(type='user', uuid='message-first', sessionId='provider-restart', cwd=str(project),
                             timestamp='2026-09-12T00:00:00Z', message=dict(role='user', content=first_content)))
        second = encoded(dict(type='user', uuid='message-second', timestamp='2026-09-12T00:00:01Z',
                              message=dict(role='user', content=second_content)))
        # Split inside a multibyte scalar, with no newline, to exercise a real
        # unfinished JSONL record rather than two syntactically complete lines.
        split = second.index('合'.encode()) + 1
        source.write_bytes(first + second[:split])
        try:
            initial = Helper(binary, home, sources); helpers.append(initial)
            version = initial.call('system.version')['version']
            initial.call('projects.add', dict(path=str(project)))
            memory = initial.call('memory.save', dict(title='Confirmed restart memory', content='synthetic durable engineering constraint',
                                                       project=str(project), scope='project', state='candidate'))
            memories = {memory['id']: (memory, asset_snapshot(memory, home))}
            settings = initial.call('settings.save', dict(notifications=False, notificationSound=False, notifyErrors=False, analysisEnabled=False))
            refreshed = initial.call('sessions.refresh')
            assert refreshed['sessionCount'] == 1 and refreshed['sourcesUpdated'] == 1, refreshed
            session_id = initial.call('sessions.list', dict(project=str(project)))[0]['id']
            verify_session(initial, session_id, project, [('message-first', first_content)], len(first))
            phases.append(dict(phase='first_helper_killed_after_success_responses', terminationReturnCode=initial.kill(),
                               acknowledgedMemories=1, confirmedMessages=1, incompleteSourceRecordPresent=True))

            reopened = Helper(binary, home, sources); helpers.append(reopened)
            verify_memory_and_settings(reopened, project, home, memories, settings)
            verify_session(reopened, session_id, project, [('message-first', first_content)], len(first))
            # A refresh while the line is still incomplete must neither consume
            # the fragment nor manufacture a second message.
            reopened.call('sessions.refresh')
            verify_session(reopened, session_id, project, [('message-first', first_content)], len(first))
            with source.open('ab') as output:
                output.write(second[split:]); output.flush(); os.fsync(output.fileno())
            reopened.call('sessions.refresh')
            verify_session(reopened, session_id, project,
                           [('message-first', first_content), ('message-second', second_content)], len(first) + len(second))
            another = reopened.call('memory.save', dict(title='Confirmed after first restart', content='second acknowledged synthetic asset',
                                                         project=str(project), scope='project', state='candidate'))
            memories[another['id']] = (another, asset_snapshot(another, home))
            settings = reopened.call('settings.save', dict(notifications=False, notificationSound=True, notifyErrors=True, analysisEnabled=False))
            phases.append(dict(phase='second_helper_killed_after_continuation_and_new_success_responses', terminationReturnCode=reopened.kill(),
                               acknowledgedMemories=2, confirmedMessages=2, partialRecordCompletedExactlyOnce=True))

            final = Helper(binary, home, sources); helpers.append(final)
            verify_memory_and_settings(final, project, home, memories, settings)
            for _ in range(2):
                unchanged = final.call('sessions.refresh')
                assert unchanged['sourcesUpdated'] == 0, unchanged
                verify_session(final, session_id, project,
                               [('message-first', first_content), ('message-second', second_content)], len(first) + len(second))
                verify_memory_and_settings(final, project, home, memories, settings)
            phases.append(dict(phase='second_reopen_and_two_unchanged_refreshes', memoryCount=2, sessionCount=1,
                               messageCount=2, duplicateMessages=0, assetsUnchanged=True, settingsUnchanged=True,
                               completeSourceBytes=len(first) + len(second)))
            final.close(graceful=True)
            assets = [dict(memoryID=identifier, assetSHA256=hashlib.sha256(snapshot).hexdigest())
                      for identifier, (_, snapshot) in sorted(memories.items())]
        finally:
            for helper in helpers:
                helper.close()
    report = dict(format='vela-restart-regression-v1', verifiedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  binarySHA256=binary_hash, cliVersion=version, passed=True, forcedTerminations=2, reopens=2,
                  phases=phases, assetEvidence=assets,
                  covered=['Acknowledged Memory and Markdown assets survive helper SIGKILL',
                           'Acknowledged settings and timestamps survive two reopens',
                           'Confirmed session and unfinished UTF-8 JSONL record recover without duplicate messages'],
                  limits=['Process SIGKILL with OS still running is not power-loss or disk-full durability',
                          'Only writes acknowledged before termination are asserted; no claim about unacknowledged in-flight writes',
                          'Explicit refresh with --no-watch; no FSEvents/UI recovery timing or automatic restart claim',
                          'Synthetic Claude JSONL fixture only; not all provider formats or a crash-point matrix'],
                  cleanup=dict(temporaryStoreAndLogsRemoved=True, allTestHelpersReaped=True))
    rendered = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered)
    print(rendered, end='')


if __name__ == '__main__':
    main()
