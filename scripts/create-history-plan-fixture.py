"""Create synthetic History/Plan inputs for actual renderer and native QA.

Extends the owned UI fixture through real CLI calls. It never reads provider
accounts, existing logs or a normal store. Run only against a NEW immediate
child of .task-tmp; no model or workflow execution occurs.
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
    base = args.directory.absolute()
    if base.exists() or base.is_symlink() or base.resolve().parent != (ROOT / '.task-tmp').resolve():
        parser.error('Use a new immediate child of repository .task-tmp.')
    binary = args.binary.resolve(strict=True)
    subprocess.run(['python3', str(ROOT / 'scripts/create-ui-fixture.py'), str(base),
                    '--binary', str(binary), '--with-routing-project'], check=True, capture_output=True)
    fixture = json.loads((base / 'fixture.json').read_text())
    project = fixture['project']
    sources = Path(fixture['sessionRoot'])
    for provider in ('pi', 'omp'):
        (sources / provider).mkdir(exist_ok=True)
    env = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(base), LANG='en_US.UTF-8',
               VELA_HOME=fixture['home'], VELA_SESSION_ROOT=str(sources), VELA_DISABLE_DISCOVERY='1',
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')

    def call(method, params=None):
        response = subprocess.run([str(binary), 'call', method, '--params-stdin', '--home', fixture['home']],
                                  input=json.dumps(params or {}), env=env, capture_output=True, text=True,
                                  check=True, timeout=30)
        return json.loads(response.stdout)

    def encode(rows):
        return b''.join((json.dumps(row, ensure_ascii=False, sort_keys=True) + '\n').encode() for row in rows)

    def user(identifier, text, cwd=None):
        value = dict(type='user', uuid=identifier, message=dict(role='user', content=text))
        if cwd:
            value['cwd'] = cwd
        return value

    original = '原始记录🙂中英文分块 ' * 10000 + ' RAW_END_MARKER'
    rows = [user('header', 'History consumer fixture', project), user('long-original', original)]
    rows.extend(user('history-' + str(index), 'Historical row ' + str(index) + ' ' + 'x' * 2200)
                for index in range(4000))
    main_source = sources / 'claude/000-history-consumer.jsonl'
    main_source.write_bytes(encode(rows))
    for index in range(1, 73):
        (sources / 'claude' / f'consumer-{index:03}.jsonl').write_bytes(
            encode([user('header-' + str(index), 'Synthetic source ' + str(index), project)]))

    branch_name = 'consumer-branch.jsonl'
    branch_rows = [dict(type='session', version=3, id='consumer-pi-session', cwd=project)]
    branch_rows.extend(dict(type='message', id='branch-' + str(index),
                            parentId='branch-' + str(index - 1) if index else None,
                            message=dict(role='user', content='Branch source ' + str(index)))
                       for index in range(75))
    (sources / 'pi' / branch_name).write_bytes(encode(branch_rows))

    def header(identifier):
        return dict(type='session_meta', payload=dict(id=identifier, cwd=project, cli_version='0.114.0'))

    def question(text):
        return dict(type='response_item', payload=dict(type='message', role='user',
                    content=[dict(type='input_text', text=text)]))

    def plan(identifier, items):
        return dict(type='response_item', payload=dict(type='function_call', name='update_plan',
                    call_id=identifier, arguments=json.dumps(dict(plan=items), ensure_ascii=False)))

    def confirmed(identifier):
        return dict(type='response_item', payload=dict(type='function_call_output',
                    call_id=identifier, output='Plan updated'))

    expected_items = [dict(step='已核对来源标识', status='completed'),
                      dict(step='正在验证历史分块', status='in_progress'),
                      dict(step='等待执行最终验证', status='pending')]
    plan_rows = [header('consumer-confirmed-plan'), question('Confirmed plan consumer fixture')]
    for index in range(70):
        identifier = 'confirmed-' + str(index)
        plan_rows.extend([plan(identifier, expected_items), confirmed(identifier)])
    plan_rows.append(plan('unacknowledged', [dict(step='UNACKNOWLEDGED_NOT_COMPLETE', status='completed')]))
    (sources / 'codex/consumer-confirmed-plan.jsonl').write_bytes(encode(plan_rows))
    (sources / 'codex/consumer-unavailable-plan.jsonl').write_bytes(encode([
        header('consumer-unavailable-plan'), question('Unavailable plan consumer fixture'),
        plan('proposal-only', [dict(step='PROPOSAL_ONLY', status='completed')])]))
    (sources / 'codex/consumer-empty-plan.jsonl').write_bytes(encode([
        header('consumer-empty-plan'), question('Empty confirmed plan consumer fixture'),
        plan('empty', []), confirmed('empty')]))
    call('sessions.refresh')
    sessions = call('sessions.list', dict(project=project))
    identifiers = {row['sourceSessionId']: row['id'] for row in sessions
                   if row.get('sourceSessionId') in ('consumer-confirmed-plan', 'consumer-unavailable-plan', 'consumer-empty-plan')}
    assert len(identifiers) == 3
    plans = {name: call('sessions.plan.get', dict(project=project, id=identifier))
             for name, identifier in identifiers.items()}
    assert plans['consumer-confirmed-plan']['counts']['completed'] == 1
    assert plans['consumer-confirmed-plan']['pendingUpdates'] == 1
    assert plans['consumer-confirmed-plan']['workVerified'] is False
    assert plans['consumer-unavailable-plan']['available'] is False
    assert plans['consumer-unavailable-plan']['total'] is None
    assert plans['consumer-empty-plan']['available'] is True
    assert plans['consumer-empty-plan']['total'] == 0
    events = call('sessions.plan.events', dict(project=project, id=identifiers['consumer-confirmed-plan']))
    assert events['eventsTruncated'] is True
    fixture['historyPlan'] = dict(sourceName=main_source.name, sourceBytes=main_source.stat().st_size,
        sourceSHA256=hashlib.sha256(main_source.read_bytes()).hexdigest(), rawRecordOrdinal=1,
        rawRecordSHA256=hashlib.sha256(encode([rows[1]])).hexdigest(), expectedRawText=original,
        expectedRecords=len(rows), extraSources=73, branchSourceName=branch_name, branchEntries=75, sessions=identifiers,
        expectedConfirmedItems=expected_items, eventsTruncated=True, helperSHA256=hashlib.sha256(binary.read_bytes()).hexdigest())
    (base / 'fixture.json').write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(dict(synthetic=True, fixture=str(base / 'fixture.json'), extraSources=73,
                         historyRecords=len(rows), sourceBytes=main_source.stat().st_size,
                         planStates=['confirmed', 'unavailable', 'confirmed-empty'], providerCalls=0)))


if __name__ == '__main__':
    main()
