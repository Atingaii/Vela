"""Create an isolated, synthetic project through the real CLI for app QA/screenshots.

This is test data, never a product demo mode. The target must not already exist.
No user agent logs or configuration files are read. The printed environment can
be used to launch Vela.app's actual executable against this disposable store.
"""
import argparse
import datetime
import json
import os
import pathlib
import shlex
import subprocess

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=pathlib.Path)
    parser.add_argument('--binary', type=pathlib.Path, default=REPOSITORY / '.build/debug/vela')
    parser.add_argument('--with-routing-project', action='store_true', help='Add an isolated Beacon project for cross-project notification tests.')
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    base = args.directory.expanduser().absolute()
    if base.exists() or base.is_symlink():
        parser.error('Choose a new directory; existing paths are never overwritten.')
    base.mkdir(parents=True, mode=0o700)
    base = base.resolve()
    project, store, logs = base / 'Harbor', base / 'store', base / 'sources'
    project.mkdir()
    for provider in ('claude', 'codex', 'cursor'):
        (logs / provider).mkdir(parents=True)
    env = dict(os.environ, VELA_HOME=str(store), VELA_SESSION_ROOT=str(logs), VELA_DISABLE_DISCOVERY='1')
    # Avoid consulting user-level Git configuration or hooks even in the fixture repo.
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
    env.update(GIT_AUTHOR_NAME='Vela Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
               GIT_COMMITTER_NAME='Vela Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')

    def run(command):
        result = subprocess.run(command, env=env, cwd=project, text=True, capture_output=True, timeout=60)
        if result.returncode:
            raise RuntimeError(result.stderr or result.stdout)
        return result.stdout

    def call(method, params=None):
        return json.loads(run([str(binary), 'call', method, json.dumps(params or {}), '--home', str(store)]))

    def write(relative, content):
        path = project / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    write('README.md', '# Harbor\n\nSynthetic local project for Vela interface verification.\n')
    write('AGENTS.md', '# Working on Harbor\n\nKeep request validation explicit. Run tests before proposing a release.\n')
    write('CLAUDE.md', '# Project context\n\nUse the existing parser. Preserve public response field names.\n')
    write('.agents/skills/review/SKILL.md', '---\nname: review-request-boundary\ndescription: Review request validation changes.\n---\n\nInspect the diff and the assertion that covers invalid input.\n')
    write('.cursor/rules/validation.mdc', '---\ndescription: Preserve request validation behavior\nglobs: src/parser.mjs\nalwaysApply: false\n---\n\nKeep valid positive limits unchanged and default malformed values to 20.\n')
    write('.claude/settings.json', json.dumps({'hooks': {'PostToolUse': [{'matcher': 'Write|Edit',
        'hooks': [{'type': 'command', 'command': 'node --test tests/parser.test.mjs'}]}]},
        'env': {'HARBOR_FIXTURE_TOKEN': 'synthetic-secret-do-not-display', 'HARBOR_ENV': 'synthetic-hidden-env'}}, indent=2) + '\n')
    write('.mcp.json', json.dumps({'mcpServers': {'fixture-read-only': {
        'command': '/usr/bin/false', 'args': [], 'env': {'API_KEY': 'synthetic-mcp-secret-do-not-display'}}}}, indent=2) + '\n')
    write('package.json', json.dumps({'name': 'harbor-fixture', 'private': True,
          'scripts': {'test': 'node --test tests/parser.test.mjs', 'typecheck': 'node --check src/parser.mjs'}}, indent=2) + '\n')
    write('src/parser.mjs', 'export function parseLimit(value) {\n  const n = Number(value);\n  return Number.isInteger(n) && n > 0 && n <= 100 ? n : 20;\n}\n')
    write('tests/parser.test.mjs', "import { test } from 'node:test';\nimport assert from 'node:assert/strict';\nimport { parseLimit } from '../src/parser.mjs';\ntest('rejects invalid limits', () => {\n  assert.equal(parseLimit(-1), 20);\n  assert.equal(parseLimit(25), 25);\n});\n")
    run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', 'init', '-b', 'main'])
    run(['/usr/bin/git', 'add', '.'])
    run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', 'commit', '-m', 'Add synthetic parser fixture'])
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

    def timestamp(minutes=0):
        return (now + datetime.timedelta(minutes=minutes)).isoformat().replace('+00:00', 'Z')

    def jsonl(path, rows):
        path.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows))

    for index, (title, answer, terminal, minutes) in enumerate([
        ('Validate request limits', 'The parser now rejects negative and oversized limits. The regression test covers both invalid input and a valid limit.', 'result', -12),
        ('Review the pagination boundary', 'Keep the public response fields stable. The remaining change needs an explicit review before writing the release note.', 'approval_requested', -3),
    ]):
        jsonl(logs / 'claude' / f'harbor-{index}.jsonl', [
            {'type': 'user', 'uuid': f'claude-{index}-u', 'sessionId': f'harbor-claude-{index}', 'cwd': str(project), 'gitBranch': 'main', 'timestamp': timestamp(minutes), 'message': {'role': 'user', 'content': title}},
            {'type': 'assistant', 'uuid': f'claude-{index}-a', 'timestamp': timestamp(minutes + 1), 'message': {'id': f'claude-{index}-answer', 'role': 'assistant', 'content': [{'type': 'text', 'text': answer}], 'usage': {'input_tokens': 1420 + index * 680, 'output_tokens': 360 + index * 90}}},
            {'type': terminal, 'timestamp': timestamp(minutes + 2), 'is_error': False},
        ])
    for index, (title, answer, minutes) in enumerate([
        ('Cover invalid pagination input', 'The focused parser assertions pass. No response fields were renamed.', -30),
        ('Prepare the verification handoff', 'The next session can start from the committed parser change and the recorded request boundary.', -55),
    ]):
        jsonl(logs / 'codex' / f'harbor-{index}.jsonl', [
            {'type': 'session_meta', 'timestamp': timestamp(minutes), 'payload': {'id': f'harbor-codex-{index}', 'cwd': str(project), 'git': {'branch': 'main'}}},
            {'type': 'response_item', 'timestamp': timestamp(minutes), 'payload': {'id': f'codex-{index}-u', 'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': title}]}},
            {'type': 'response_item', 'timestamp': timestamp(minutes + 1), 'payload': {'id': f'codex-{index}-tool', 'type': 'function_call', 'name': 'exec_command', 'arguments': '{"cmd":"node --test tests/parser.test.mjs"}'}},
            {'type': 'response_item', 'timestamp': timestamp(minutes + 2), 'payload': {'id': f'codex-{index}-a', 'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': answer}]}},
            {'type': 'event_msg', 'timestamp': timestamp(minutes + 2), 'payload': {'type': 'token_count', 'info': {'total_token_usage': {'input_tokens': 2100 + index * 410, 'output_tokens': 640 + index * 160}}}},
            {'type': 'event_msg', 'timestamp': timestamp(minutes + 3), 'payload': {'type': 'task_complete'}},
        ])
    (logs / 'cursor' / 'harbor.json').write_text(json.dumps({
        'name': 'Inspect request validation', 'cwd': str(project), 'messages': [
            {'id': 'cursor-u', 'role': 'user', 'timestamp': timestamp(-90), 'content': 'Review the parser without changing its public response.'},
            {'id': 'cursor-a', 'role': 'assistant', 'timestamp': timestamp(-89), 'content': 'The input boundary is explicit. Keep malformed values separate from valid limits.'},
        ]
    }))
    call('projects.add', {'path': str(project)})
    call('settings.save', {'notifications': False, 'analysisEnabled': False, 'launchAtLogin': False})
    call('sessions.refresh')
    sessions = call('sessions.list')
    assert len(sessions) == 5, f'Expected five ingested synthetic sessions, got {len(sessions)}'
    source_session = next(item for item in sessions if item['provider'] == 'codex')
    for title, content, kind, state in [
        ('Preserve the public response contract', 'Keep response field names stable while tightening input validation.', 'Constraint', 'Active'),
        ('Verify parser changes with focused assertions', 'Use the local parser test before reviewing the broader release diff.', 'Workflow Knowledge', 'Active'),
        ('Separate invalid input from empty results', 'An invalid page limit should use the documented default, not an empty response.', 'Observation', 'Candidate'),
    ]:
        call('memory.save', {'title': title, 'content': content, 'project': str(project), 'scope': 'Project',
                            'type': kind, 'state': state, 'sourceSession': source_session['id']})
    guideline = call('guidelines.save', {'project': str(project), 'title': 'Review request boundaries',
                                       'content': 'Explain the rejected input, the preserved contract, and the assertion that covers the change.'})
    call('library.add', {'project': str(project), 'title': 'Request parsing notes', 'content': 'Synthetic private notes. Positive integer limits are bounded at 100.', 'private': True})
    setup = call('setup.scan', {'project': str(project)})
    artifacts = setup['artifacts']
    assert {'skill', 'rule', 'mcp', 'configuration'} <= {item['type'] for item in artifacts}
    assert any(item.get('containsHooks') for item in artifacts)
    assert any(item.get('containsMCP') for item in artifacts)
    serialized_setup = json.dumps(setup)
    assert 'synthetic-secret-do-not-display' not in serialized_setup
    assert 'synthetic-hidden-env' not in serialized_setup
    assert 'synthetic-mcp-secret-do-not-display' not in serialized_setup
    review = call('workflows.save', {'project': str(project), 'title': 'Review the current change',
        'description': 'Inspect the working tree and recent diff before starting another task.', 'trigger': 'manual',
        'guidelines': [guideline['id']], 'steps': [{'title': 'Inspect working tree', 'tool': 'git.status', 'arguments': {}},
                                              {'title': 'Review the diff', 'tool': 'git.diff', 'arguments': {}}]})
    run_record = call('workflows.run', {'id': review['id'], 'dryRun': False})
    assert run_record['state'] == 'completed'
    pending = call('workflows.save', {'project': str(project), 'title': 'Write a verification note',
        'description': 'Review the frozen note before writing to the project.', 'trigger': 'manual',
        'steps': [{'title': 'Write the reviewed note', 'tool': 'file.write', 'arguments': {
            'path': 'docs/verification.md', 'content': '# Verification\n\nThe focused parser checks passed.\n'}}]})
    pending_run = call('workflows.run', {'id': pending['id'], 'dryRun': False})
    assert pending_run['state'] == 'pending_approval'
    assert not (project / 'docs/verification.md').exists()
    call('checkpoint.save', {'project': str(project), 'title': 'Parser verification handoff',
        'goal': 'Tighten request validation without changing the public contract.',
        'completed': 'Input boundaries and focused assertions are committed.',
        'pending': 'Review the release note and run the wider integration checks.',
        'nextActions': 'Inspect the frozen verification note in Inbox before approving.'})
    manifest = {'format': 'vela-ui-fixture-v1', 'synthetic': True, 'home': str(store), 'store': str(store), 'project': str(project), 'sessionRoot': str(logs),
                'sessions': [item['id'] for item in sessions], 'completedRun': run_record['id'], 'pendingRun': pending_run['id']}
    if args.with_routing_project:
        beacon = base / 'Beacon'
        beacon.mkdir()
        (beacon / 'README.md').write_text('# Beacon\n\nSynthetic notification routing fixture.\n')
        call('projects.add', {'path': str(beacon)})
        notification_workflow = call('workflows.save', {'project': str(beacon), 'title': 'Review Beacon release note',
            'trigger': 'manual', 'steps': [{'title': 'Write Beacon release note', 'tool': 'file.write',
            'arguments': {'path': 'release-note.md', 'content': 'Synthetic Beacon note.\n'}}]})
        notification_run = call('workflows.run', {'id': notification_workflow['id'], 'dryRun': False})
        assert notification_run['state'] == 'pending_approval' and not (beacon / 'release-note.md').exists()
        notification_approval = next(a for a in call('inbox.list') if a.get('project') == str(beacon))
        command_workflow = call('workflows.save', {'project': str(project), 'title': 'Inspect exact command arguments',
            'trigger': 'manual', 'steps': [{'title': 'Review command without executing', 'tool': 'shell.test',
            'arguments': {'executable': '/usr/bin/false', 'args': ['', 'argument with spaces', 'quote"argument']}}]})
        command_run = call('workflows.run', {'id': command_workflow['id'], 'dryRun': False})
        assert command_run['state'] == 'pending_approval'
        command_approval = next(a for a in call('inbox.list') if a.get('runId') == command_run['id'])
        assert command_approval['arguments']['executable'] == '/usr/bin/false'
        assert command_approval['arguments']['args'] == ['', 'argument with spaces', 'quote"argument']
        manifest.update(projects=[str(project), str(beacon)], routingProject=str(beacon),
                        routingApproval=notification_approval['id'], commandApproval=command_approval['id'])
    (base / 'fixture.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (store / '.vela-ui-fixture.json').write_text(json.dumps({'format': 'vela-ui-fixture-v1', 'synthetic': True,
        'manifest': str(base / 'fixture.json')}, indent=2) + '\n')
    print('Created real CLI records from synthetic logs. All screenshot captions must label the data as synthetic.')
    print(' '.join(f'{key}={shlex.quote(value)}' for key, value in {
        'VELA_HOME': str(store), 'VELA_SESSION_ROOT': str(logs), 'VELA_DISABLE_DISCOVERY': '1'}.items()))
    print(f'Fixture manifest: {base / "fixture.json"}')


if __name__ == '__main__':
    main()
