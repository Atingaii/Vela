"""Verify provider plan observations using a frozen helper and synthetic JSONL."""
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
        parser.error('Choose a new receipt path; old evidence is retained.')
    receipt = dict(status='failed', startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   checks=[], providerCalls=0, sourceData='synthetic JSONL only', userMaterialRead=False)
    try:
        with tempfile.TemporaryDirectory(prefix='vela-plans-rpc-') as temporary:
            base = Path(temporary).resolve(); helper = base / 'vela'
            shutil.copy2(args.binary.resolve(strict=True), helper)
            digest = hashlib.sha256(helper.read_bytes()).hexdigest()
            receipt['helperSHA256'] = digest
            project, logs, store, home = (base / name for name in ('project', 'logs', 'store', 'home'))
            project.mkdir(); home.mkdir()
            for provider in ('claude', 'codex', 'pi', 'omp', 'cursor'):
                (logs / provider).mkdir(parents=True)
            env = dict(os.environ, HOME=str(home), VELA_DISABLE_DISCOVERY='1', VELA_SESSION_ROOT=str(logs),
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')

            def call(method, params=None, succeeds=True):
                assert hashlib.sha256(helper.read_bytes()).hexdigest() == digest
                result = subprocess.run([str(helper), 'call', method, '--params-stdin', '--home', str(store)],
                                        input=json.dumps(params or {}), env=env, capture_output=True, text=True, timeout=30)
                assert hashlib.sha256(helper.read_bytes()).hexdigest() == digest
                if not succeeds:
                    assert result.returncode != 0, (method, result.stdout)
                    return None
                assert result.returncode == 0, (method, result.stderr)
                return json.loads(result.stdout)

            def encode(rows):
                return b''.join((json.dumps(row, ensure_ascii=False, sort_keys=True) + '\n').encode() for row in rows)

            def codex_call(identifier, status='completed'):
                return dict(type='response_item', payload=dict(type='function_call', name='update_plan', call_id=identifier,
                            arguments=json.dumps(dict(plan=[dict(step='核验解析', status=status)]), ensure_ascii=False)))

            def codex_result(identifier, output='Plan updated'):
                return dict(type='response_item', payload=dict(type='function_call_output', call_id=identifier, output=output))

            def claude_call(identifier, tool, value):
                return dict(type='assistant', uuid='a-' + identifier, message=dict(role='assistant',
                            content=[dict(type='tool_use', id=identifier, name=tool, input=value)]))

            def claude_result(identifier, value, error=False):
                return dict(type='user', uuid='r-' + identifier, message=dict(role='user',
                            content=[dict(type='tool_result', tool_use_id=identifier, is_error=error, content='Synthetic result')]), tool_use_result=value)

            call('projects.add', dict(path=str(project)))
            assert call('sessions.plan.describe')['readOnly'] is True
            codex_path = logs / 'codex' / 'fixture.jsonl'
            codex_path.write_bytes(encode([dict(type='session_meta', payload=dict(id='codex-synthetic', cwd=str(project), cli_version='0.114.0')), codex_call('p')]))
            call('sessions.refresh')
            sessions = call('sessions.list', dict(project=str(project)))
            codex_id = next(row['id'] for row in sessions if row['provider'] == 'codex')
            scope = dict(project=str(project), id=codex_id)
            assert call('sessions.plan.get', scope)['total'] is None
            with codex_path.open('ab') as stream:
                stream.write(encode([codex_result('wrong'), dict(type='event_msg', payload=dict(type='task_complete'))]))
            call('sessions.refresh'); assert call('sessions.plan.get', scope)['available'] is False
            with codex_path.open('ab') as stream:
                stream.write(encode([codex_result('p')]))
            call('sessions.refresh')
            actual = call('sessions.plan.get', scope)
            assert actual['counts']['completed'] == 1 and actual['workVerified'] is False
            assert call('sessions.get', dict(id=codex_id))['plan']['counts']['completed'] == 1
            receipt['checks'].append('Codex_pending_wrong_ID_session_completion_and_restart_then_matching_success')
            events = call('sessions.plan.events', scope)['items']
            for event in events:
                reference = event['source']
                raw = codex_path.read_bytes()[reference['byteOffset']:reference['byteOffset'] + reference['byteLength']]
                assert hashlib.sha256(raw).hexdigest() == reference['sha256']
            assert events[-1]['source']['callSource']['sha256'] == events[0]['source']['sha256']
            receipt['checks'].append('Exact_source_record_hashes_and_matching_call_provenance')

            claude_path = logs / 'claude' / 'fixture.jsonl'
            claude_path.write_bytes(encode([dict(type='user', uuid='header', sessionId='claude-synthetic', cwd=str(project), version='synthetic-sdk-contract', message=dict(role='user', content='Synthetic')),
                claude_call('create', 'TaskCreate', dict(subject='验证任务', description='Synthetic fixture')),
                claude_result('create', dict(task=dict(id='7', subject='验证任务'))),
                claude_call('fail', 'TaskUpdate', dict(taskId='7', status='completed')),
                claude_result('fail', dict(success=False, taskId='7', updatedFields=[], error='Synthetic error'))]))
            call('sessions.refresh')
            claude_id = next(row['id'] for row in call('sessions.list', dict(project=str(project))) if row['provider'] == 'claude')
            cscope = dict(project=str(project), id=claude_id)
            assert call('sessions.plan.get', cscope)['counts']['pending'] == 1
            with claude_path.open('ab') as stream:
                stream.write(encode([claude_call('done', 'TaskUpdate', dict(task_id='7', status='completed')),
                                    claude_result('done', dict(success=True, taskId='7', updatedFields=['status'], statusChange=dict(from_='pending', to='completed')))]).replace(b'"from_"', b'"from"'))
            call('sessions.refresh'); assert call('sessions.plan.get', cscope)['counts']['completed'] == 1
            assert any(event['state'] == 'failed' for event in call('sessions.plan.events', cscope)['items'])
            receipt['checks'].append('Claude_TaskCreate_ID_failed_update_then_confirmed_status_transition')

            call('sessions.plan.get', dict(scope, project=str(base)), succeeds=False)
            call('sessions.plan.get', dict(scope, path='/etc/passwd'), succeeds=False)
            call('sessions.plan.events', dict(scope, limit=True), succeeds=False)
            call('sessions.plan.get', dict(id=codex_id), succeeds=False)
            receipt['checks'].append('Cross_project_unregistered_extra_path_and_typed_pagination_rejected')
            before = call('sessions.plan.events', scope)
            call('sessions.refresh')
            assert call('sessions.plan.events', scope) == before
            assert all('pending' not in row and 'events' not in row for row in call('sessions.list', dict(project=str(project))))
            receipt['checks'].append('Idempotent_refresh_and_summary_excludes_private_correlation_ledger')
            receipt['status'] = 'passed'
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
