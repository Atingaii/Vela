#!/usr/bin/env python3
"""Real local Lab approval regression; all projects and agent markers are owned fixtures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import traceback

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / '.build/debug/vela')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    binary, output = args.binary.resolve(strict=True), args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error('output must be new')
    scratch = ROOT / '.task-tmp'
    scratch.mkdir(exist_ok=True)
    # Foundation canonicalizes project paths; never mix /var and /private/var.
    base = Path(tempfile.mkdtemp(prefix='lab-explicit-guard-', dir=scratch)).resolve()
    owner = base / '.vela-explicit-guard-owned'
    owner.write_text('test-lab-explicit-memory-guard-rpc.py\n')
    output.parent.mkdir(parents=True, exist_ok=True)
    source_copy = output.with_suffix('.consumer.py')
    if source_copy.exists():
        parser.error('consumer source copy must be new')
    source_copy.write_bytes(Path(__file__).read_bytes())
    helper = base / 'vela-frozen'
    shutil.copy2(binary, helper)
    result = {'format': 'vela-lab-explicit-memory-guard-rpc-v2', 'synthetic': True,
              'providerCalls': 0, 'modelCalls': 0, 'passed': False, 'checks': [],
              'helperBefore': sha(binary), 'helperFrozen': sha(helper),
              'consumerSourceBefore': sha(Path(__file__)), 'actualCalls': []}
    try:
        for mutation in ('private', 'archived', 'content', 'foreign', 'unchanged'):
            # A directory literally named private is intentionally protected by
            # the product and cannot be used for a public baseline fixture.
            case = base / ('case-' + mutation)
            case.mkdir()
            project, other, home = case / 'Harbor', case / 'Beacon', case / 'store'
            project.mkdir(); other.mkdir()
            template = case / 'empty-git-template'
            template.mkdir()
            env = dict(os.environ, VELA_HOME=str(home), VELA_DISABLE_DISCOVERY='1',
                       VELA_SESSION_ROOT=str(case / 'no-sessions'), GIT_CONFIG_NOSYSTEM='1',
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_TEMPLATE_DIR=str(template))
            (project / 'verify.py').write_text('assert True\n')
            for command in (['git', 'init', '-q'], ['git', 'add', '.'],
                            ['git', '-c', 'user.name=fixture', '-c',
                             'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture']):
                subprocess.run(command, cwd=project, env=env, check=True, capture_output=True)

            def call(method, params):
                execution = subprocess.run([str(helper), 'call', method, json.dumps(params),
                                            '--home', str(home)], cwd=project, env=env,
                                           text=True, capture_output=True, timeout=45)
                result['actualCalls'].append({'case': mutation, 'method': method,
                                              'exitCode': execution.returncode})
                if execution.returncode:
                    raise RuntimeError(method + ': ' + (execution.stderr or execution.stdout))
                return json.loads(execution.stdout)

            marker = case / 'agent-starts.jsonl'
            agent = case / 'synthetic-agent.py'
            agent.write_text('#!/usr/bin/env python3 -I\n'
                             'import json,sys\nfrom pathlib import Path\n'
                             'if "--version" in sys.argv:\n'
                             ' print("Vela owned synthetic agent 1");sys.exit(0)\n'
                             'with Path(' + repr(str(marker)) + ').open("a") as f:\n'
                             ' f.write(json.dumps({"cwd":str(Path.cwd())})+"\\n")\n'
                             'print(json.dumps({"type":"thread.started","thread_id":"fixture"}),flush=True)\n'
                             'print(json.dumps({"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}),flush=True)\n')
            agent.chmod(0o700)
            memory_id = 'explicit-' + mutation
            call('projects.add', {'path': str(project)})
            call('projects.add', {'path': str(other)})
            memory = {'id': memory_id, 'project': str(project), 'scope': 'project',
                      'state': 'active', 'title': 'Synthetic source', 'content': 'ORIGINAL'}
            call('memory.save', memory)
            created = call('lab.run', {'title': 'Synthetic explicit source guard',
                'project': str(project), 'kind': 'memory',
                'agent': {'provider': 'codex', 'executable': str(agent), 'model': 'local', 'reasoningEffort': 'high'},
                'task': 'Synthetic local marker only.', 'verificationCommand': ['/usr/bin/python3', 'verify.py'],
                'verificationFiles': ['verify.py'], 'outputFiles': ['output.txt'], 'timeoutSeconds': 20,
                'repetitions': 1, 'baseline': {'files': [], 'recall': {'enabled': False, 'strictOff': True}},
                'candidate': {'files': [], 'memoryIds': [memory_id], 'recall': {'enabled': False}}})
            if mutation == 'private':
                call('memory.save', dict(memory, private=True))
            elif mutation == 'archived':
                call('memory.transition', {'id': memory_id, 'state': 'archived'})
            elif mutation == 'content':
                call('memory.save', dict(memory, content='CHANGED'))
            elif mutation == 'foreign':
                # No public reparent API: mutate only this fixture's database to
                # reproduce a source whose project changed after preparation.
                with sqlite3.connect(home / 'vela.sqlite3') as connection:
                    row = json.loads(connection.execute(
                        "SELECT json FROM objects WHERE kind='memory' AND id=?", (memory_id,)).fetchone()[0])
                    row['project'] = str(other)
                    connection.execute("UPDATE objects SET project=?,json=? WHERE kind='memory' AND id=?",
                                       (str(other), json.dumps(row, separators=(',', ':')), memory_id))
            approval = next(item for item in call('inbox.list', {'project': str(project)})
                            if item['id'] == created['approvalId'])
            decision = call('approvals.decide', {'id': approval['id'], 'decision': 'approve',
                                               'snapshotHash': approval['snapshotHash']})
            evaluation = call('lab.compare', {'id': created['id']})
            starts = [json.loads(line) for line in marker.read_text().splitlines()] if marker.exists() else []
            candidate_starts = [item for item in starts if Path(item['cwd']).name.startswith('candidate-')]
            baseline_starts = [item for item in starts if Path(item['cwd']).name.startswith('baseline-')]
            worktrees = subprocess.run(['git', 'worktree', 'list', '--porcelain'], cwd=project,
                                       env=env, check=True, capture_output=True, text=True).stdout
            live_paths = [line.removeprefix('worktree ') for line in worktrees.splitlines() if line.startswith('worktree ')]
            assert live_paths == [str(project)], 'owned Lab worktree remained registered'
            assert all(not Path(item['cwd']).exists() for item in starts), 'owned variant directory remained'
            expected_success = mutation == 'unchanged'
            passed = (decision['state'] == ('executed' if expected_success else 'failed')
                      and len(candidate_starts) == (1 if expected_success else 0)
                      and len(baseline_starts) == 1)
            result['checks'].append({'mutation': mutation, 'passed': passed, 'state': decision['state'],
                                     'candidateStarted': bool(candidate_starts), 'agentStarts': starts,
                                     'baselineStartCount': len(baseline_starts),
                                     'candidateStartCount': len(candidate_starts), 'ownedWorktreesRemoved': True,
                                     'evaluationResultCount': len(evaluation.get('results', [])),
                                     'foreignMutationUsesOwnedDatabaseSeam': mutation == 'foreign'})
            assert passed, 'unexpected explicit source guard outcome: ' + mutation
        result['passed'] = len(result['checks']) == 5 and all(item['passed'] for item in result['checks'])
    except Exception as error:
        result['passed'] = False
        result['failure'] = str(error)
        result['traceback'] = traceback.format_exc(limit=5)
    finally:
        result['helperAfter'] = sha(binary)
        result['helperFrozenAfter'] = sha(helper)
        result['consumerSourceAfter'] = sha(Path(__file__))
        result['sourceUnchanged'] = (result['helperBefore'] == result['helperFrozen'] == result['helperAfter']
                                     == result['helperFrozenAfter'] and result['consumerSourceBefore']
                                     == result['consumerSourceAfter'] == sha(source_copy))
        if base.parent == scratch.resolve() and owner.is_file() and not owner.is_symlink():
            shutil.rmtree(base)
        result['fixtureRemoved'] = not base.exists()
        result['passed'] = result['passed'] and result['sourceUnchanged'] and result['fixtureRemoved']
        output.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({key: result[key] for key in ('passed', 'sourceUnchanged', 'fixtureRemoved', 'checks')}))
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
