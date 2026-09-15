"""Create isolated Codex-relation records for renderer acceptance tests only.

The fixture delegates base project/store construction to create-ui-fixture.py,
then writes synthetic JSONL below its dedicated VELA_SESSION_ROOT.  It never
reads user stores, launches a provider, or reuses an existing directory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    base, binary = args.directory.absolute(), args.binary.resolve(strict=True)
    if base.exists() or base.is_symlink() or base.parent != (ROOT / '.task-tmp').resolve():
        parser.error('Choose a new immediate child of repository .task-tmp.')
    subprocess.run(['python3', str(ROOT / 'scripts/create-ui-fixture.py'), str(base), '--binary', str(binary),
                    '--with-routing-project'], check=True, text=True, timeout=90)
    fixture_path = base / 'fixture.json'
    fixture = json.loads(fixture_path.read_text())
    harbor, beacon, sources = Path(fixture['project']), Path(fixture['routingProject']), Path(fixture['sessionRoot'])
    codex = sources / 'codex'; codex.mkdir(exist_ok=True)

    def uuid(number):
        return f'00000000-0000-4000-8000-{number:012d}'

    def encode(rows):
        return b''.join((json.dumps(row, ensure_ascii=False, sort_keys=True) + '\n').encode() for row in rows)

    def header(number, project=harbor, parent=None, source=None, **extra):
        payload = {'id': uuid(number), 'session_id': uuid(1), 'cwd': str(project), 'timestamp': '2026-09-13T00:00:00Z',
                   'cli_version': '0.154.0', 'originator': 'codex_cli_rs', 'source': source if source is not None else 'cli'}
        if parent is not None:
            payload['parent_thread_id'] = uuid(parent)
            payload['source'] = source if source is not None else {'subagent': {'thread_spawn': {'parent_thread_id': uuid(parent), 'depth': 1}}}
        payload.update(extra)
        return {'type': 'session_meta', 'payload': payload}

    def spawn(call_id, child):
        return {'type': 'response_item', 'payload': {'type': 'function_call', 'namespace': 'multi_agent_v1',
                'name': 'spawn_agent', 'call_id': call_id, 'arguments': json.dumps({'message': 'SYNTHETIC_NO_PROVIDER'})}}

    def acknowledgement(call_id, child):
        return {'type': 'response_item', 'payload': {'type': 'function_call_output', 'call_id': call_id,
                'output': json.dumps({'agent_id': uuid(child), 'nickname': None})}}

    def status(value):
        return {'type': 'event_msg', 'timestamp': '2026-09-13T00:00:01Z', 'payload': {'type': value}}

    def write(name, rows):
        path = codex / (name + '.jsonl'); path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(encode(rows)); return path

    parent_rows = [header(1)]
    # 70 call/receipt pairs deliberately exceed the 128-event retained window.
    # The two important reports land in the first retained evidence page.
    for index in range(70):
        child = 2 if index == 6 else (999 if index == 7 else 1000 + index)
        parent_rows.extend([spawn(f'spawn-{index}', child), acknowledgement(f'spawn-{index}', child)])
    parent = write('relations-parent', parent_rows)
    child = write('relations-child', [header(2, parent=1), status('error')])
    visible_children = [child]
    for number in range(3, 55):
        visible_children.append(write(f'relations-child-{number}', [header(number, parent=1), status('task_complete')]))
    private = write('private/relations-hidden', [header(90, parent=1)])
    cross = write('relations-cross-project', [header(6, project=beacon, parent=1)])
    orphan = write('relations-orphan', [header(7, parent=998)])
    conflict = write('relations-conflict', [header(8, parent=1, source={'subagent': {'thread_spawn': {'parent_thread_id': uuid(3), 'depth': 1}}})])
    duplicate_a = write('relations-duplicate-a', [header(10)])
    duplicate_b = write('relations-duplicate-b', [header(10)])

    isolated_env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(base), 'LANG': 'en_US.UTF-8',
                    'VELA_HOME': fixture['home'], 'VELA_SESSION_ROOT': fixture['sessionRoot'], 'VELA_DISABLE_DISCOVERY': '1',
                    'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull}
    def call(method, params=None, succeeds=True):
        result = subprocess.run([str(binary), 'call', method, json.dumps(params or {}), '--home', fixture['home']],
                                cwd=base, capture_output=True, text=True, timeout=30, env=isolated_env)
        if not succeeds:
            assert result.returncode != 0, (method, result.stdout, result.stderr)
            return None
        if result.returncode: raise RuntimeError(result.stderr or result.stdout)
        return json.loads(result.stdout)

    call('sessions.refresh')
    rows = call('sessions.list', {'project': str(harbor)})
    source_ids = {Path(row['sourcePath']).name: row['id'] for row in rows if row.get('sourcePath')}
    expected = {'relations-parent.jsonl', 'relations-child.jsonl', 'relations-hidden.jsonl', 'relations-orphan.jsonl',
                'relations-conflict.jsonl', 'relations-duplicate-a.jsonl', 'relations-duplicate-b.jsonl'} | {path.name for path in visible_children}
    assert expected <= source_ids.keys(), (expected, source_ids.keys())
    parent_id, child_id = source_ids[parent.name], source_ids[child.name]
    events = call('sessions.relations.events', {'project': str(harbor), 'id': parent_id, 'limit': 50})
    children = call('sessions.relations.children', {'project': str(harbor), 'id': parent_id, 'limit': 20})
    assert len(events['items']) == 50 and events['hasMore'] and events['eventsTruncated'] is True
    assert any(item['status'] == 'reported_spawned' and item.get('childThreadId') == uuid(2) for item in events['items'])
    assert any(item['status'] == 'reported_spawned' and item.get('childThreadId') == uuid(999) for item in events['items'])
    assert 19 <= len(children['items']) <= 20 and children['nextCursor'] is not None
    assert call('sessions.relations.resolve', {'project': str(harbor), 'threadId': uuid(90)})['status'] == 'unavailable'
    assert call('sessions.relations.resolve', {'project': str(harbor), 'threadId': uuid(10)})['status'] == 'ambiguous'
    assert call('sessions.relations.get', {'project': str(harbor), 'id': source_ids[conflict.name]})['parent']['resolved'] is False
    cursor, empty_filtered = None, False
    for _ in range(80):
        page = call('sessions.relations.children', {'project': str(harbor), 'id': parent_id, 'limit': 1, **({'after': cursor} if cursor else {})})
        empty_filtered |= page['scanned'] > 0 and not page['items'] and page['nextCursor'] is not None
        cursor = page['nextCursor']
        if cursor is None: break
    assert empty_filtered, 'private fixture must create a bounded empty filtered page'
    fixture['sessionRelations'] = {'parentSourceId': parent_id, 'childSourceId': child_id,
        'privateSourceId': source_ids[private.name], 'orphanSourceId': source_ids[orphan.name],
        'conflictSourceId': source_ids[conflict.name], 'crossProjectSourcePath': str(cross),
        'duplicateSourceIds': [source_ids[duplicate_a.name], source_ids[duplicate_b.name]],
        'parentThreadId': uuid(1), 'childThreadId': uuid(2), 'unavailableReportedThreadId': uuid(999),
        'visibleChildSourceIds': [source_ids[path.name] for path in visible_children], 'eventPairs': 70, 'retainedEvents': 128, 'initialEpoch': events['relationEpoch'],
        'parentSourcePath': str(parent), 'sourceSHA256': hashlib.sha256(parent.read_bytes()).hexdigest(),
        'allSourceFilesSHA256': {str(path.relative_to(sources)): hashlib.sha256(path.read_bytes()).hexdigest()
                                 for path in sorted(sources.rglob('*.jsonl')) if path.is_file() and not path.is_symlink()}}
    fixture_path.write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'synthetic': True, 'fixture': str(fixture_path), 'relationEvents': 140, 'providerCalls': 0}))


if __name__ == '__main__':
    main()
