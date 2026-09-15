"""Exercise observed Codex relations through JSON-RPC using synthetic logs only."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=repo / '.build/debug/vela')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or args.output.is_symlink():
        parser.error('Choose a new receipt path; previous evidence is retained.')
    receipt = dict(status='failed', startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   checks=[], providerCalls=0, sourceData='synthetic Codex JSONL only', userMaterialRead=False,
                   transport='JSON-RPC over helper stdio; helper restarted for each request')
    try:
        with tempfile.TemporaryDirectory(prefix='vela-relations-rpc-') as temporary:
            base = Path(temporary).resolve(); helper = base / 'vela'
            shutil.copy2(args.binary.resolve(strict=True), helper)
            digest = hashlib.sha256(helper.read_bytes()).hexdigest(); receipt['helperSHA256'] = digest
            project, other, logs, store, home = (base / name for name in ('project', 'other', 'logs', 'store', 'home'))
            project.mkdir(); other.mkdir(); home.mkdir()
            for provider in ('claude', 'codex', 'pi', 'omp', 'cursor'):
                (logs / provider).mkdir(parents=True)
            env = dict(os.environ, HOME=str(home), VELA_DISABLE_DISCOVERY='1', VELA_SESSION_ROOT=str(logs),
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
            request_count = 0

            def call(method, params=None, succeeds=True):
                nonlocal request_count
                request_count += 1
                assert hashlib.sha256(helper.read_bytes()).hexdigest() == digest
                request = dict(jsonrpc='2.0', id=request_count, method=method, params=params or {})
                result = subprocess.run([str(helper), 'rpc', '--home', str(store), '--no-watch'],
                                        input=json.dumps(request) + '\n', env=env, capture_output=True, text=True, timeout=30)
                assert hashlib.sha256(helper.read_bytes()).hexdigest() == digest
                assert result.returncode == 0, (method, result.stderr)
                responses = [json.loads(line) for line in result.stdout.splitlines()]
                response = next(row for row in responses if row.get('id') == request_count)
                if not succeeds:
                    assert 'error' in response, (method, response)
                    return None
                assert 'error' not in response, (method, response)
                return response['result']

            def uuid(number):
                return f'00000000-0000-4000-8000-{number:012d}'

            def header(number, parent=None, **extra):
                payload = dict(id=uuid(number), session_id=uuid(1), cwd=str(project),
                               timestamp='2026-09-13T00:00:00Z', cli_version='0.154.0', originator='codex_cli_rs', source='cli')
                if parent is not None:
                    payload.update(parent_thread_id=uuid(parent), source=dict(subagent=dict(thread_spawn=dict(parent_thread_id=uuid(parent), depth=1))))
                payload.update(extra)
                return dict(type='session_meta', payload=payload)

            def encode(rows):
                return b''.join((json.dumps(row, ensure_ascii=False, sort_keys=True) + '\n').encode() for row in rows)

            def write(name, rows):
                path = logs / 'codex' / (name + '.jsonl'); path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(encode(rows)); return path

            def append(path, rows):
                with path.open('ab') as stream:
                    stream.write(encode(rows))

            def spawn(call_id='spawn-a', namespace='multi_agent_v1'):
                return dict(type='response_item', payload=dict(type='function_call', namespace=namespace, name='spawn_agent',
                            call_id=call_id, arguments=json.dumps(dict(message='SYNTHETIC_PROMPT_MUST_NOT_RETURN'))))

            def acknowledgement(number, call_id='spawn-a'):
                return dict(type='response_item', payload=dict(type='function_call_output', call_id=call_id,
                            output=json.dumps(dict(agent_id=uuid(number), nickname=None))))

            def status(value):
                return dict(type='event_msg', timestamp='2026-09-13T00:00:01Z', payload=dict(type=value))

            def source_id(path):
                return next(row['id'] for row in call('sessions.list', dict(project=str(project))) if row.get('sourcePath') == str(path))

            def relation(method, identifier, **extra):
                return call('sessions.relations.' + method, dict(project=str(project), id=identifier, **extra))

            call('projects.add', dict(path=str(project))); call('projects.add', dict(path=str(other)))
            assert call('sessions.relations.describe')['readOnly'] is True
            parent_path = write('parent', [header(1), spawn()]); call('sessions.refresh')
            parent_id = source_id(parent_path)
            proposed = relation('events', parent_id)
            assert [item['status'] for item in proposed['items']] == ['proposed']
            assert relation('children', parent_id)['items'] == []
            append(parent_path, [acknowledgement(2), status('task_complete')]); call('sessions.refresh')
            reported = relation('events', parent_id)
            assert reported['relationEpoch'] == proposed['relationEpoch']
            assert reported['items'][-1]['status'] == 'reported_spawned'
            assert reported['items'][-1]['childResolution']['status'] == 'unavailable'
            child_path = write('child', [header(2, 1, forked_from_id=uuid(3)), status('error')])
            fork_path = write('fork', [header(3, forked_from_id=uuid(1))]); call('sessions.refresh')
            child_id, fork_id = source_id(child_path), source_id(fork_path)
            child = relation('get', child_id)
            assert child['relation']['parentThreadId'] == uuid(1) and child['relation']['forkedFromThreadId'] == uuid(3)
            assert child['parent']['resolved'] is True and child['parent']['source']['observedState'] == 'Completed'
            assert child['source']['observedState'] == 'Error' and child['liveness'] == 'unknown'
            assert relation('get', fork_id)['parent']['status'] == 'none_declared'
            children = relation('children', parent_id)
            assert len(children['items']) == 1 and children['childErrorsOnPage'] == 1 and children['parentState'] == 'Completed'
            assert relation('events', parent_id)['items'][-1]['childResolution']['parentEvidence'] == 'corroborated'
            receipt['checks'].append('Pending_vs_acknowledgement_then_child_source_and_independent_parent_completed_child_error')

            for reference in [relation('get', parent_id)['headerEvidence'], *[item['reference'] for item in reported['items']]]:
                raw = parent_path.read_bytes()[reference['byteOffset']:reference['byteOffset'] + reference['byteLength']]
                assert hashlib.sha256(raw).hexdigest() == reference['sha256']
            second = relation('events', parent_id, limit=1, afterSequence=reported['items'][0]['sequence'], epoch=reported['relationEpoch'])
            assert len(second['items']) == 1 and second['items'][0]['reference']['proposalReference']['sha256'] == reported['items'][0]['reference']['sha256']
            assert 'SYNTHETIC_PROMPT_MUST_NOT_RETURN' not in json.dumps([child, children, reported, second])
            receipt['checks'].append('Exact_UTF8_record_ranges_hashes_and_proposal_reference_without_prompt_body')

            internal_path = write('internal', [header(4, 1, source=dict(internal='guardian'))])
            private_path = write('private/hidden', [header(5, 1)])
            write('cross-project', [header(6, cwd=str(other))])
            orphan_path = write('orphan', [header(7, 6)])
            conflict_path = write('conflict', [header(8, 1, source=dict(subagent=dict(thread_spawn=dict(parent_thread_id=uuid(3), depth=1))))])
            call('sessions.refresh')
            for number in (4, 5, 6, 99):
                assert call('sessions.relations.resolve', dict(project=str(project), threadId=uuid(number)))['status'] == 'unavailable'
            for path in (internal_path, private_path):
                call('sessions.relations.get', dict(project=str(project), id=source_id(path)), succeeds=False)
            assert relation('get', source_id(orphan_path))['parent']['resolved'] is False
            assert relation('get', source_id(conflict_path))['parent']['resolved'] is False
            observed_ids = set(); next_cursor = None; empty_filtered_page = False
            for _ in range(10):
                page = relation('children', parent_id, limit=1, **({'after':next_cursor} if next_cursor else {}))
                observed_ids.update(item['source']['id'] for item in page['items'])
                empty_filtered_page |= page['scanned'] > 0 and not page['items']
                next_cursor = page['nextCursor']
                if next_cursor is None:
                    break
            else:
                raise AssertionError('Pagination did not terminate')
            assert empty_filtered_page and child_id in observed_ids and source_id(private_path) not in observed_ids
            receipt['checks'].append('Private_internal_cross_project_orphan_conflict_and_filtered_empty_page_advancement')

            collision_path = write('collision', [header(9), spawn('collision'), spawn('collision', 'foreign'), acknowledgement(2, 'collision')])
            write('duplicate-a', [header(10)]); write('duplicate-b', [header(10)])
            call('sessions.refresh')
            assert call('sessions.relations.resolve', dict(project=str(project), threadId=uuid(10)))['status'] == 'ambiguous'
            assert not any(row['status'] == 'reported_spawned' for row in relation('events', source_id(collision_path))['items'])
            receipt['checks'].append('Duplicate_native_UUID_and_call_ID_namespace_collision_fail_closed')

            old_epoch = child['relation']['relationEpoch']; inode = child_path.stat().st_ino
            child_path.write_bytes(encode([header(2, 3), status('error'), dict(type='event_msg', payload=dict(type='agent_message', message='synthetic padding ' * 100))]))
            assert child_path.stat().st_ino == inode
            call('sessions.refresh'); rewritten = relation('get', child_id)
            assert rewritten['relation']['relationEpoch'] != old_epoch and rewritten['relation']['parentThreadId'] == uuid(3)
            assert child_id not in {row['source']['id'] for row in relation('children', parent_id)['items']}
            call('sessions.relations.events', dict(project=str(project), id=child_id, afterSequence=1, epoch=old_epoch), succeeds=False)
            old_page = relation('children', parent_id, limit=1); assert old_page['nextCursor']
            old_parent_epoch = relation('get', parent_id)['relation']['relationEpoch']
            parent_path.write_bytes(encode([header(1)])); call('sessions.refresh')
            assert relation('get', parent_id)['relation']['relationEpoch'] != old_parent_epoch
            call('sessions.relations.children', dict(project=str(project), id=parent_id, after=old_page['nextCursor']), succeeds=False)
            assert relation('events', parent_id)['items'] == []
            receipt['checks'].append('Same_inode_growing_header_rewrite_and_rotated_anchor_invalidate_stale_relations_cursors')

            for method, values in [('get', dict(id=parent_id, project=str(other))), ('get', dict(id=parent_id, path='/etc/passwd')),
                                   ('children', dict(id=parent_id, limit=True)), ('events', dict(id=parent_id, afterSequence=1)),
                                   ('events', dict(id=parent_id, limit=1.5)), ('resolve', dict(threadId='not-a-uuid'))]:
                call('sessions.relations.' + method, dict(project=str(project), **values) if 'project' not in values else values, succeeds=False)
            relation_summary = next(row for row in call('sessions.list', dict(project=str(project))) if row['id'] == parent_id)['relationSummary']
            assert not any(key in relation_summary for key in ('pending', 'settled', 'events', 'messages', 'content'))
            receipt['checks'].append('Typed_arguments_project_scope_and_compact_dashboard_summary')
            receipt.update(status='passed', rpcRequests=request_count, helperUnchanged=True)
        receipt['temporaryDirectoryRemoved'] = not base.exists()
    except Exception as error:
        receipt['error'] = str(error)
        raise
    finally:
        receipt['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + '\n')
        print(json.dumps(receipt, ensure_ascii=False))


if __name__ == '__main__':
    main()
