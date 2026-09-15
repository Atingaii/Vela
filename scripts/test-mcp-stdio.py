"""Independent real stdio MCP consumer; isolated synthetic sources, zero providers."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import selectors
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
        parser.error('Choose a new receipt path; earlier evidence is never overwritten.')
    receipt = dict(status='failed', startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   consumer='real stdio JSON-RPC process, synthetic project sources only',
                   providerCalls=0, projectToolExecutions=0, checks=[], protocolVersions=[])
    try:
        with tempfile.TemporaryDirectory(prefix='vela-mcp-stdio-') as temporary:
            base = Path(temporary).resolve()
            helper = base / 'vela'; shutil.copy2(args.binary.resolve(strict=True), helper)
            helper_hash = hashlib.sha256(helper.read_bytes()).hexdigest()
            receipt['helperSHA256'] = helper_hash
            for name in ['home', 'sources', 'project', 'other']:
                (base / name).mkdir()
            store = base / 'store'; project = str(base / 'project'); other = str(base / 'other')
            env = dict(os.environ, HOME=str(base/'home'), VELA_HOME=str(store),
                       VELA_DISABLE_DISCOVERY='1', VELA_SESSION_ROOT=str(base/'sources'),
                       GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
            def core(method, params):
                result = subprocess.run([str(helper), 'call', method, '--params-stdin', '--home', str(store)],
                                        input=json.dumps(params), capture_output=True, text=True, env=env, timeout=30)
                assert result.returncode == 0, (method, result.stderr)
                return json.loads(result.stdout)
            for path in [project, other]:
                core('projects.add', dict(path=path))
            logs = base / 'sources' / 'codex'; logs.mkdir()
            stamp = '2026-09-13T00:00:00Z'
            rows = [dict(type='session_meta', timestamp=stamp, payload=dict(id='mcp-synthetic-session', cwd=project)),
                    dict(type='response_item', timestamp=stamp, payload=dict(id='mcp-observed-message', type='message', role='user', content=[dict(type='input_text', text='Synthetic observed source for candidate evidence.')]))]
            (logs/'synthetic.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
            core('sessions.refresh', {})
            sessions = core('sessions.list', dict(project=project))
            observed = next(row for row in sessions if row['sourceSessionId'] == 'mcp-synthetic-session')
            observed_message = core('sessions.get', dict(id=observed['id']))['messages'][0]['id']
            def memory(identity, text, **extra):
                return core('memory.save', dict(id=identity, project=project, title='Synthetic reference',
                                               content=text, state='active', **extra))
            memory('a-private', 'MCP_PRIVATE_MARKER', private=True)
            memory('b-private', 'MCP_PRIVATE_MARKER', private=True)
            memory('c-public', 'MCP_PUBLIC_MARKER')
            source = memory('u-text', '中👨‍👩‍👧‍👦文e\u0301🇨🇳尾')
            synthetic_secret = 'sk-abcdefghijklmnopqrstuvwx'
            memory('z-sanitized', '始👩🏽‍💻' + synthetic_secret + '结束')
            foreign = core('memory.save', dict(project=other, title='Other project', content='MCP_FOREIGN_MARKER', state='active'))
            guideline = core('guidelines.save', dict(project=project, title='Synthetic guideline', content='MCP_GUIDELINE_MARKER'))
            workflow = core('workflows.save', dict(project=project, title='Read only workflow', description='Never execute',
                                                   trigger='manual', steps=[dict(tool='file.write', arguments=dict(path='must-not-exist.txt', content='not authorized'))]))
            library = core('library.add', dict(project=project, title='Public document', content='CedarMCP synthetic public paragraph.', private=False))
            core('library.add', dict(project=project, title='Private document', content='MCP_PRIVATE_MARKER', private=True))
            core('library.index', dict(project=project))

            class Session:
                def __init__(self, contribute=False):
                    self.stderr = tempfile.TemporaryFile()
                    self.process = subprocess.Popen([str(helper), 'mcp', '--home', str(store), '--no-watch'] + (['--contribute'] if contribute else []),
                                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr, env=env)
                    self.serial = 0
                def send(self, value):
                    self.process.stdin.write((json.dumps(value, ensure_ascii=False) + '\n').encode()); self.process.stdin.flush()
                def receive(self):
                    with selectors.DefaultSelector() as selector:
                        selector.register(self.process.stdout, selectors.EVENT_READ)
                        assert selector.select(timeout=15), 'MCP response deadline exceeded'
                    line = self.process.stdout.readline()
                    assert line, 'MCP process ended unexpectedly'
                    return json.loads(line)
                def request(self, method, params=None):
                    self.serial += 1
                    self.send(dict(jsonrpc='2.0', id=self.serial, method=method, params=params or {}))
                    result = self.receive()
                    assert result.get('id') == self.serial, result
                    return result
                def initialize(self, version):
                    response = self.request('initialize', dict(protocolVersion=version, capabilities={}, clientInfo=dict(name='vela-independent-synthetic-consumer', version='1')))
                    assert response['result']['protocolVersion'] == version
                    self.send(dict(jsonrpc='2.0', method='notifications/initialized'))
                def tool(self, name, arguments=None, error=False):
                    values = dict(project=project); values.update(arguments or {})
                    response = self.request('tools/call', dict(name=name, arguments=values))
                    assert 'result' in response, response
                    result = response['result']
                    assert result['isError'] == error, result
                    return result if error else json.loads(result['content'][0]['text'])
                def close(self):
                    if self.process.stdin and not self.process.stdin.closed:
                        self.process.stdin.close()
                    try:
                        self.process.wait(timeout=10)
                        assert self.process.returncode == 0
                    except subprocess.TimeoutExpired:
                        self.process.kill(); self.process.wait(); raise
                    finally:
                        self.process.stdout.close(); self.stderr.close()
                def __enter__(self): return self
                def __exit__(self, *unused): self.close()

            for version in ['2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25']:
                with Session() as session:
                    assert session.request('tools/list')['error']['code'] == -32002
                    session.initialize(version)
                    tools = session.request('tools/list')['result']['tools']
                    assert len(tools) == 15
                    assert all(t['inputSchema']['additionalProperties'] is False for t in tools)
                    assert all(('annotations' not in t) == (version == '2024-11-05') for t in tools)
                    result = session.request('tools/call', dict(name='vela_memory_list', arguments=dict(project=project, limit=1)))['result']
                    assert json.loads(result['content'][0]['text']) == []
                    assert result['_meta']['ai.vela/pagination']['nextCursor'] == 'a-private'
                    assert ('structuredContent' in result) == (version in ['2025-06-18', '2025-11-25'])
                    assert session.request('tools/call', dict(name='vela_remember', arguments=dict(project=project)))['error']['code'] == -32602
                    session.send(dict(jsonrpc='2.0', method='tools/call', params=dict(name='vela_remember', arguments=dict(project=project, title='NO_NOTIFICATION_WRITE', content='No'))))
                    assert session.request('ping')['result'] == {}
                    receipt['protocolVersions'].append(version)
            receipt['checks'].append('four protocol negotiations, initialized gate, legacy arrays, annotations/structuredContent compatibility and notification non-execution')

            with Session() as session:
                session.initialize('2025-11-25')
                session.tool('vela_memory_get', dict(id=foreign['id']), error=True)
                session.tool('vela_health', dict(project=str(base)), error=True)
                for bad in [dict(limit=True), dict(limit=1.5), dict(limit=0), dict(includePrivate=True), dict(path='/tmp/anywhere')]:
                    session.tool('vela_memory_list', bad, error=True)
                second = session.request('tools/call', dict(name='vela_memory_list', arguments=dict(project=project, limit=1, after='a-private')))['result']
                assert json.loads(second['content'][0]['text']) == []
                cursor = second['_meta']['ai.vela/pagination']['nextCursor']
                assert session.tool('vela_memory_list', dict(limit=1, after=cursor))[0]['id'] == 'c-public'
                first = session.tool('vela_memory_get', dict(id=source['id'], maxCharacters=2))
                assert first['content'] == '中👨‍👩‍👧‍👦' and first['offsetUnit'] == 'extended_grapheme_clusters'
                second = session.tool('vela_memory_get', dict(id=source['id'], maxCharacters=2, offset=first['nextOffset'], sourceHash=first['sourceHash']))
                assert second['content'] == '文e\u0301'
                memory('u-text', 'Changed source')
                session.tool('vela_memory_get', dict(id=source['id'], offset=2, sourceHash=first['sourceHash']), error=True)
                full = session.tool('vela_memory_get', dict(id='z-sanitized'))
                pieces, offset = [], 0
                while True:
                    page = session.tool('vela_memory_get', dict(id='z-sanitized', offset=offset, maxCharacters=3, sourceHash=full['sourceHash']))
                    assert synthetic_secret not in page['content']
                    pieces.append(page['content'])
                    if page['nextOffset'] is None: break
                    offset = page['nextOffset']
                assert ''.join(pieces) == full['content'] and synthetic_secret not in ''.join(pieces)
                assert synthetic_secret not in json.dumps(session.tool('vela_library_list'))
                assert synthetic_secret not in json.dumps(session.tool('vela_library_search', dict(query='CedarMCP')))
                assert isinstance(session.tool('vela_search', dict(query='MCP_PUBLIC_MARKER', limit=100)), list)
                assert any(row['id'] == 'c-public' for row in session.tool('vela_recall', dict(query='MCP_PUBLIC_MARKER', budget=1000))['items'])
                assert isinstance(session.tool('vela_setup_list'), list)
                assert isinstance(session.tool('vela_evals_list'), list)
                assert any(row['id'] == workflow['id'] for row in session.tool('vela_workflows_list'))
                assert any(row['id'] == guideline['id'] for row in session.tool('vela_guidelines_list')['items'])
                assert 'CedarMCP' in session.tool('vela_library_get', dict(id=library['id']))['content']
                assert 'MCP_GUIDELINE_MARKER' in session.tool('vela_guidelines_read', dict(id=guideline['id']))['content']
                assert session.tool('vela_workflows_read', dict(id=workflow['id']))['content']
                assert session.tool('vela_health')['modelExecution'] is False
                path = Path(library['assetPath']); raw = path.read_text(); prefix = '<!-- Vela metadata: '
                end = raw.index(' -->\n\n# '); header = json.loads(raw[len(prefix):end]); header['private'] = True
                path.write_text(prefix + json.dumps(header) + raw[end:])
                session.tool('vela_library_get', dict(id=library['id']), error=True)
                assert session.tool('vela_library_search', dict(query='CedarMCP'))['items'] == []
                session.process.stdin.write(b'{invalid-json\n'); session.process.stdin.flush()
                assert session.receive()['error']['code'] == -32700
                session.send(dict(jsonrpc='2.0', id=1, method='ping'))
                assert session.receive()['error']['code'] == -32600
            receipt['checks'].append('registered project, cross-project/private gates, strict types, private-page progress, grapheme/hash pagination, whole-source redaction, header privacy revocation, parse/duplicate-ID errors')

            with Session(contribute=True) as session:
                session.initialize('2025-11-25')
                assert len(session.request('tools/list')['result']['tools']) == 22
                before = len(core('memory.list', dict(project=project)))
                session.tool('vela_remember_bulk', dict(items=[dict(title='Would be first', content='Candidate'), dict(title='Invalid', content='Candidate', scope='branch')]), error=True)
                assert len(core('memory.list', dict(project=project))) == before
                for unsafe in [dict(id='c-public'), dict(state='Active'), dict(scope='global'), dict(private=False)]:
                    session.tool('vela_remember', dict(title='NO_INVALID_WRITE', content='Candidate', **unsafe), error=True)
                legacy = session.tool('vela_memory_contribute', dict(title='Legacy candidate', content='Proposed new knowledge', type='Fact', scope='Project'))
                assert legacy['state'] == 'candidate'
                bulk = session.tool('vela_remember_bulk', dict(items=[dict(title='One', content='Candidate one'), dict(title='Two', content='Candidate two')]))
                assert bulk['created'] == 2 and bulk['atomic'] is True
                assert all(row['state'] == 'candidate' for row in bulk['items'])
                checkpoint = session.tool('vela_checkpoint_save', dict(goal='Synthetic checkpoint', completed=['Local observation']))
                assert any(row['id'] == checkpoint['id'] for row in session.tool('vela_checkpoints_list'))
                signal = session.tool('vela_signal_record', dict(title='Observed evidence', content='Synthetic candidate signal', sourceSession=observed['id'], sourceMessage=observed_message))
                assert signal['state'] == 'candidate'
                remembered = session.tool('vela_remember', dict(title='Direct candidate', content='Candidate-only memory'))
                assert remembered['state'] == 'candidate'
                draft = session.tool('vela_suggestion_draft', dict(title='Review suggestion', content='Synthetic proposal'))
                assert draft['state'] == 'draft'
                archive = core('memory.archive.export', dict(project=project, ids=['c-public']))['archive']
                restored = session.tool('vela_local_archive_restore', dict(project=other, archive=archive))
                assert restored['imported'] == 1 and restored['state'] == 'candidate'
                assert session.tool('vela_local_archive_restore', dict(project=other, archive=archive))['skipped'] == 1
                active_ids = {row['id'] for row in session.tool('vela_memory_list', dict(limit=100))}
                assert legacy['id'] not in active_ids
                assert all(row['id'] not in active_ids for row in bulk['items'])
            receipt['checks'].append('contribute-only legacy safe inputs, candidate bulk atomicity, no activation/overwrite, local checkpoint and draft, idempotent candidate archive restore')
            assert not (base/'project'/'must-not-exist.txt').exists()
            records = core('memory.list', dict(project=project))
            assert not any(row['title'] in ['NO_NOTIFICATION_WRITE', 'NO_INVALID_WRITE'] for row in records)
            assert hashlib.sha256(helper.read_bytes()).hexdigest() == helper_hash
            receipt['status'] = 'passed'; receipt['cleanup'] = 'All own helper processes, temporary fixture stores and copied binaries removed by context managers.'
    except BaseException as error:
        receipt['error'] = str(error)
        raise
    finally:
        receipt['completedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
