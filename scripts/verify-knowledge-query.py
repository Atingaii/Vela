"""Verify the real Ask CLI with isolated synthetic sources.

Default: a synthetic provider exercises actual subprocess transport, approvals,
citations, continuation, source revocation and no-match behavior. --live performs
exactly one separately authorized Codex request; it never retries or follows up.
Do not run --live from CI or without explicit authorization for that model call.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=repo / '.build/debug/vela')
    parser.add_argument('--output', type=Path, required=True, help='New evidence directory; existing evidence is never overwritten.')
    parser.add_argument('--live', action='store_true')
    parser.add_argument('--executable', type=Path, help='Absolute Codex executable path; required only with --live.')
    parser.add_argument('--model', default='gpt-5.6-sol')
    parser.add_argument('--effort', choices=['low', 'medium', 'high', 'xhigh'], default='low')
    parser.add_argument('--retrieval-mode', choices=['lexical', 'library_fts'], default='lexical')
    args = parser.parse_args()
    if args.live and (args.executable is None or not args.executable.is_absolute()):
        parser.error('--live requires an explicit absolute --executable path; no provider request was started')
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error('Choose a new output directory; verification evidence is immutable.')
    output.mkdir(parents=True, mode=0o700)
    receipt = {'status': 'failed', 'mode': 'live' if args.live else 'synthetic_transport',
               'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'checks': [],
               'sourceData': 'synthetic public project Library and Active Memory only',
               'maxLiveCalls': 1 if args.live else 0, 'automaticRetry': False,
               'userMaterialRead': False, 'directCredentialFileAccess': False}

    def save(name, value):
        (output / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

    try:
        with tempfile.TemporaryDirectory(prefix='vela-knowledge-verification-') as temporary:
            base = Path(temporary).resolve()
            binary = base / 'vela'; shutil.copy2(args.binary.resolve(strict=True), binary)
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            receipt['frozenHelperSHA256'] = digest
            project, store, sources = base / 'project', base / 'store', base / 'sources'
            project.mkdir(); sources.mkdir()
            environment = dict(os.environ, VELA_HOME=str(store), VELA_SESSION_ROOT=str(sources), VELA_DISABLE_DISCOVERY='1')

            def call(method, params=None, succeeds=True):
                assert hashlib.sha256(binary.read_bytes()).hexdigest() == digest
                result = subprocess.run([str(binary), 'call', method, '--params-stdin', '--home', str(store)],
                                        input=json.dumps(params or {}), env=environment, capture_output=True, text=True, timeout=110)
                assert hashlib.sha256(binary.read_bytes()).hexdigest() == digest
                if not succeeds:
                    assert result.returncode != 0, (method, result.stdout)
                    return None
                assert result.returncode == 0, (method, result.stderr)
                return json.loads(result.stdout)

            call('projects.add', {'path': str(project)})
            public = call('library.add', {'project': str(project), 'title': 'Harbor synthetic release policy', 'private': False,
                'content': 'Harbor keeps project configuration local. A Harbor release requires passing the focused parser tests. The maximum valid page limit is 100.'})
            memory = call('memory.save', {'project': str(project), 'title': 'Harbor request boundary', 'scope': 'project', 'state': 'active',
                'type': 'constraint', 'content': 'Harbor preserves public response field names while tightening request validation.'})
            call('library.add', {'project': str(project), 'title': 'Harbor private synthetic notes', 'private': True,
                'content': 'PRIVATE_SYNTHETIC_SENTINEL must never enter a knowledge prompt.'})
            materials = [public, memory]
            save('synthetic-sources.json', {'sources': materials, 'privateNegativeFixture': 'A private sentinel source was created but excluded.'})
            if args.retrieval_mode == 'library_fts':
                indexed = call('library.index', {'project': str(project)})
                assert indexed['pageSucceeded'] and indexed['indexed'] == 1
                receipt['checks'].append('explicit_library_paragraph_index_before_fts_question')
            counter = base / 'calls.jsonl'
            if args.live:
                provider = args.executable.resolve(strict=True)
                version = subprocess.run([str(provider), '--version'], capture_output=True, text=True, timeout=10, check=True)
                receipt['providerVersion'] = version.stdout.strip()
            else:
                provider = base / 'synthetic-codex'
                code = '''#!/usr/bin/python3
import json,os,stat,sys
data=json.loads(sys.argv[-1].split('Frozen data:\\n',1)[1])
assert '--ignore-rules' in sys.argv and '--ignore-user-config' in sys.argv
assert sys.argv[sys.argv.index('--sandbox')+1]=='read-only'
assert stat.S_IMODE(os.stat(os.getcwd()).st_mode)==0o700
assert stat.S_IMODE(os.stat(sys.argv[sys.argv.index('--output-schema')+1]).st_mode)==0o600
assert 'PRIVATE_SYNTHETIC_SENTINEL' not in sys.argv[-1]
source=next(s for s in data['sources'] if s['sourceId'].startswith('library:'))
quote='A Harbor release requires passing the focused parser tests.'
assert quote in source['content']
with open(COUNTER,'a') as out: out.write(json.dumps({'scratch':os.getcwd(),'historyRounds':len(data['history'])})+'\\n')
answer={'claims':[{'text':'发布 Harbor 前需要通过解析器定点测试。','citations':[{'sourceId':source['sourceId'],'quote':quote}]}],'unanswered':[]}
for event in [{'type':'thread.started','thread_id':'synthetic-knowledge-session'},{'type':'item.completed','item':{'id':'answer','type':'agent_message','text':json.dumps(answer)}},{'type':'turn.completed','usage':{'input_tokens':7,'output_tokens':3}}]: print(json.dumps(event),flush=True)
'''.replace('COUNTER', repr(str(counter)))
                provider.write_text(code); provider.chmod(0o700)
            params = {'project': str(project), 'question': 'Harbor 发布前需要什么条件，修改请求验证时要保留什么？请按来源回答。',
                      'searchQuery': 'Harbor', 'executable': str(provider), 'model': args.model if args.live else 'synthetic-model',
                      'retrievalMode': args.retrieval_mode, 'effort': args.effort, 'timeoutSeconds': 90 if args.live else 5, 'maxSources': 8, 'maxSourceBytes': 24000}
            descriptor = call('ask.describe'); assert descriptor['maxCallsPerRound'] == 1
            pending = call('ask.create', params)
            save('frozen-request-approval.json', pending)
            request = pending['request']; allowed = {f"{item['kind']}:{item['id']}" for item in materials}
            assert pending['state'] == 'pending_approval' and pending['providerAttempts'] == 0
            assert {f"{item['kind']}:{item['id']}" for item in request['sources']} == allowed
            if args.retrieval_mode == 'library_fts':
                assert all('paragraph' in item for item in request['sources'] if item['kind'] == 'library')
            assert all(item['project'] == str(project) for item in materials)
            assert 'PRIVATE_SYNTHETIC_SENTINEL' not in json.dumps(pending)
            assert not counter.exists()
            save('input-review.json', {'syntheticOnly': True, 'exactAllowedSourceIds': sorted(item['sourceId'] for item in request['sources']), 'requestHash': pending['requestHash'],
                                      'commandHash': pending['commandHash'], 'sourceCount': len(request['sources']), 'approvedCalls': 1})
            receipt['checks'].append('frozen_public_sources_and_independent_pending_approval_before_any_model')
            approval = pending['approval']
            decision = call('approvals.decide', {'id': approval['id'], 'snapshotHash': approval['snapshotHash'], 'decision': 'approve'})
            save('approval-result.json', decision)
            done = call('ask.get', {'project': str(project), 'id': pending['id']})
            save('result.json', done)
            assert decision['state'] == 'executed', decision
            assert done['state'] == 'answered' and done['completedModelCalls'] == 1 and done['providerAttempts'] == 1
            assert done['metrics']['toolCalls'] == 0 and done['metrics']['protocolComplete']
            assert done['observedModel'] is None
            citations = call('ask.citations', {'project': str(project), 'id': done['id'], 'askHash': done['askHash']})
            frozen = {item['sourceId']: item for item in request['sources']}
            assert citations['citations']
            for citation in citations['citations']:
                assert citation['sourceId'] in frozen and citation['quote'] in frozen[citation['sourceId']]['content']
                assert citation['sourceHash'] == frozen[citation['sourceId']]['sourceHash']
            receipt['checks'].append('one_complete_toolless_answer_and_exact_frozen_quote_recheck')
            call('approvals.decide', {'id': approval['id'], 'snapshotHash': approval['snapshotHash'], 'decision': 'approve'}, succeeds=False)
            assert len(call('memory.list', {'project': str(project)})) == 1
            run = call('runs.get', {'id': done['runId']})
            assert run['purpose'] == 'knowledge_query' and run['state'] == 'completed'
            assert 'A Harbor release requires' not in json.dumps(run)
            receipt['checks'].append('dedicated_run_without_source_body_and_no_approval_replay_or_memory_activation')
            if not args.live:
                next_params = dict(params, id=done['id'], askHash=done['askHash'], question='再用一句话说明。')
                next_question = call('ask.followup', next_params)
                assert next_question['state'] == 'pending_approval' and next_question['round'] == 2
                next_approval = next_question['approval']
                assert len(counter.read_text().splitlines()) == 1
                assert call('approvals.decide', {'id': next_approval['id'], 'snapshotHash': next_approval['snapshotHash'], 'decision': 'approve'})['state'] == 'executed'
                receipt['checks'].append('followup_has_separate_approval_and_current_source_chain')
                empty = call('ask.create', dict(params, searchQuery='NOT_FOUND_SENTINEL'))
                assert empty['state'] == 'no_sources' and 'approval' not in empty
                receipt['checks'].append('no_eligible_source_creates_zero_call_dedicated_run')
                # Simulate a concurrent privacy writer in this disposable database.
                connection = sqlite3.connect(store / 'vela.sqlite3')
                row = json.loads(connection.execute("select json from objects where kind='library' and id=?", (public['id'],)).fetchone()[0])
                row['private'] = True
                connection.execute("update objects set private=1,json=? where kind='library' and id=?", (json.dumps(row), public['id']))
                connection.commit(); connection.close()
                stale = call('ask.get', {'project': str(project), 'id': done['id']})
                assert stale['state'] == 'sources_unavailable' and 'request' not in stale and 'result' not in stale
                call('ask.followup', next_params, succeeds=False)
                attempts = [json.loads(line) for line in counter.read_text().splitlines()]
                assert len(attempts) == 2 and [item['historyRounds'] for item in attempts] == [0, 1]
                assert all(not Path(item['scratch']).exists() for item in attempts)
                receipt['checks'].append('privacy_revocation_blocks_readback_and_followup_and_scratch_is_removed')
                receipt['syntheticProviderInvocations'] = 2
            receipt.update(status='pass', actualLiveCalls=1 if args.live else 0, semanticCorrectness='not_verified',
                           retrievalMode=args.retrieval_mode,
                           requestedModel=params['model'], requestedEffort=params['effort'], observedModel=None,
                           metrics=done['metrics'], citationCount=len(citations['citations']), durationMs=done['durationMs'])
        receipt['temporaryFixturesRemoved'] = not base.exists()
    except Exception as error:
        receipt['error'] = str(error)
        receipt['temporaryFixturesRemoved'] = 'base' in locals() and not base.exists()
        raise
    finally:
        receipt['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        save('receipt.json', receipt)
        print(json.dumps(receipt, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
