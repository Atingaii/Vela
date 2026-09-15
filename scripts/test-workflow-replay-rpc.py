"""Two synthetic historical replay consumers through a frozen helper (no real provider)."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from native_provider_fixture import compile_provider


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=repo / '.build/debug/vela')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or args.output.is_symlink():
        parser.error('Choose a new receipt path; evidence is never overwritten.')
    receipt = dict(status='failed', startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   realProviderCalls=0, businessToolCalls=0, fixtures=[], checks=[], sourceData='synthetic only')
    try:
        with tempfile.TemporaryDirectory(prefix='vela-replay-consumer-') as temporary:
            base = Path(temporary).resolve()
            helper = base / 'vela'; shutil.copy2(args.binary.resolve(strict=True), helper)
            helper_hash = hashlib.sha256(helper.read_bytes()).hexdigest()
            receipt['helperSHA256'] = helper_hash
            for name in ('home', 'sources', 'project-1', 'project-2'):
                (base / name).mkdir()
            env = dict(os.environ, HOME=str(base / 'home'), VELA_HOME=str(base / 'store'),
                       VELA_DISABLE_DISCOVERY='1', VELA_SESSION_ROOT=str(base / 'sources'),
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
            provider = base / 'synthetic-provider'
            compile_provider(provider, f'''
import json, pathlib, sys
args = sys.argv[1:]
required = ['--ignore-user-config','--ignore-rules','read-only','mcp_servers={{}}','shell_tool','memories','code_mode_host']
assert all(x in args for x in required)
assert args[-2] == '--'
prompt = args[-1]
with pathlib.Path({str(base / 'provider-calls.jsonl')!r}).open('a') as f:
    f.write(json.dumps(dict(prompt=prompt,args=args,cwd=str(pathlib.Path.cwd())))+'\\n')
answer = 'version B\\n' if 'VERSION_B' in prompt else 'version A\\n'
answer += 'Synthetic fixture output; engineering effect unknown.'
for row in [dict(type='thread.started',thread_id='synthetic-replay'),dict(type='item.completed',item=dict(id='answer',type='agent_message',text=json.dumps(dict(output=answer)))),dict(type='turn.completed',usage=dict(input_tokens=40,output_tokens=20))]:
    print(json.dumps(row),flush=True)
''')
            provider.chmod(0o700)
            receipt['syntheticProviderSHA256'] = hashlib.sha256(provider.read_bytes()).hexdigest()
            def call(method, params=None, succeeds=True):
                assert hashlib.sha256(helper.read_bytes()).hexdigest() == helper_hash
                process = subprocess.run([str(helper), 'call', method, '--params-stdin', '--home', str(base/'store')],
                                         input=json.dumps(params or {}), capture_output=True, text=True, env=env, timeout=30)
                assert hashlib.sha256(helper.read_bytes()).hexdigest() == helper_hash
                if not succeeds:
                    assert process.returncode != 0, (method, process.stdout)
                    return None
                assert process.returncode == 0, (method, process.stderr)
                return json.loads(process.stdout)
            assert call('replay.describe')['maxCalls'] == 2
            for index, marker in enumerate(('SYNTHETIC_STDIN_一', 'SYNTHETIC_GIT_二'), 1):
                project = base / f'project-{index}'
                call('projects.add', dict(path=str(project)))
                subprocess.run(['/usr/bin/git', 'init', '-q', str(project)], env=env, check=True, capture_output=True)
                (project / 'before.txt').write_text(marker)
                inputs = [dict(id='pasted', source='stdin')]
                if index == 2:
                    inputs.append(dict(id='gitBefore', tool='git.status'))
                template = 'VERSION_A {{input.task}} {{pasted}}' + (' {{gitBefore}}' if index == 2 else '')
                context = dict(version=1, template=template, inputs=inputs, memory=dict(enabled=False))
                step = dict(tool='agent.run', arguments=dict(executable='/usr/bin/false', args=['{{vela.prompt}}'], promptMode='workflow_context'))
                workflow = call('workflows.save', dict(project=str(project), title='Synthetic replay', steps=[step], context=context))
                historical = call('workflows.run', dict(id=workflow['id'], dryRun=True, inputs=dict(task=marker), stdin='literal {{memory}}'))
                assert historical['state'] == 'completed'
                inspected = call('replay.fixtures.inspect', dict(project=str(project), runId=historical['id']))
                captured = call('replay.fixtures.capture', dict(project=str(project), runId=historical['id'], runHash=inspected['runHash'], consent=True, retentionDays=1))
                context['template'] = template.replace('VERSION_A', 'VERSION_B')
                call('workflows.save', dict(project=str(project), id=workflow['id'], title='Synthetic replay', steps=[step], context=context))
                (project / 'TODAYS_NEW_FILE_DO_NOT_CAPTURE.txt').write_text('current data must not replace history')
                created = call('replay.create', dict(project=str(project), fixtureId=captured['id'], fixtureHash=captured['fixtureHash'], versions=[1,2], executable=str(provider), model='synthetic-model', effort='low', timeoutSeconds=5))
                assert marker not in json.dumps(created)
                review = call('replay.review', dict(project=str(project), id=created['id'], replayHash=created['replayHash']))
                commands = review['request']['commands']
                assert all(marker in command[-1] and 'literal {{memory}}' in command[-1] for command in commands)
                assert all('TODAYS_NEW_FILE_DO_NOT_CAPTURE' not in command[-1] for command in commands)
                assert review['request']['inputHash'] == inspected['inputHash']
                approval = created['approval']
                decision = call('approvals.decide', dict(id=approval['id'], snapshotHash=approval['snapshotHash'], decision='approve'))
                assert decision['state'] == 'executed'
                done = call('replay.get', dict(project=str(project), id=created['id']))
                result = call('replay.results', dict(project=str(project), id=created['id'], replayHash=done['replayHash']))
                assert done['state'] == 'completed' and done['completedModelCalls'] == 2
                assert len(result['receipts']) == 2 and result['comparison']['churnLines'] == 2
                assert result['comparison']['semanticEffect'] == 'unknown'
                for row in result['receipts']:
                    assert row['metrics']['toolCalls'] == 0 and row['metrics']['tokens'] == 60
                    assert hashlib.sha256(row['output'].encode()).hexdigest() == row['protocolHash']
                    assert hashlib.sha256(row['answer'].encode()).hexdigest() == row['answerHash']
                call('approvals.decide', dict(id=approval['id'], snapshotHash=approval['snapshotHash'], decision='approve'), succeeds=False)
                audit = call('runs.get', dict(id=done['runId']))
                assert marker not in json.dumps(audit) and 'Synthetic fixture output' not in json.dumps(audit)
                archive = call('memory.archive.export', dict(project=str(project)))
                assert marker not in json.dumps(archive) and 'Synthetic fixture output' not in json.dumps(archive)
                legacy = call('workflows.replay', dict(runId=historical['id']))
                assert legacy['replayMode'] == 'captured_records_no_execution'
                call('replay.get', dict(project=str(base / f'project-{3-index}'), id=created['id']), succeeds=False)
                call('replay.fixtures.forget', dict(project=str(project), id=captured['id'], fixtureHash=captured['fixtureHash']))
                call('replay.results', dict(project=str(project), id=created['id'], replayHash=done['replayHash']), succeeds=False)
                forgotten = call('replay.fixtures.get', dict(project=str(project), id=captured['id']))
                assert forgotten['state'] == 'forgotten'
                receipt['fixtures'].append(dict(shape='stdin' if index == 1 else 'captured_git_status', inputSHA256=inspected['inputHash'], fixtureSHA256=captured['fixtureHash'], requestSHA256=done['requestHash'], outputSHA256=[row['answerHash'] for row in result['receipts']], syntheticModelCalls=2, toolCalls=0, semanticEffect='unknown'))
            calls = [json.loads(line) for line in (base/'provider-calls.jsonl').read_text().splitlines()]
            assert len(calls) == 4 and all(not Path(row['cwd']).exists() for row in calls)
            receipt['syntheticModelCalls'] = len(calls)
            receipt['checks'] = ['two_independent_project_fixtures', 'exact_historical_input_hash_and_different_saved_templates', 'current_git_changes_not_read', 'new_approval_required_once', 'bounded_no_tools_protocol_and_actual_output_hashes', 'nonminimal_line_diff', 'metadata_run_and_memory_archive_exclude_bodies', 'cross_project_rejected', 'forget_revokes_results', 'legacy_captured_replay_unchanged', 'scratch_directories_removed']
            receipt['status'] = 'passed'
    except Exception as error:
        receipt['error'] = str(error)
        raise
    finally:
        receipt['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        receipt['temporaryDataRemoved'] = True
        receipt['scriptSHA256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2)+'\n')
        print(json.dumps(dict(status=receipt['status'], receipt=str(args.output), syntheticModelCalls=receipt.get('syntheticModelCalls',0), realProviderCalls=0)))


if __name__ == '__main__':
    main()
