"""Verify explicit history imports using a frozen CLI and synthetic sources only."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=repo / '.build/debug/vela')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or args.output.is_symlink():
        parser.error('Choose a new receipt path; old evidence is never replaced.')
    receipt = {'status': 'failed', 'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'checks': [], 'realProviderCalls': 0, 'userMaterialRead': False, 'sourceData': 'synthetic only'}
    try:
        with tempfile.TemporaryDirectory(prefix='vela-history-rpc-') as temporary:
            base = Path(temporary).resolve(); helper = base / 'vela'
            shutil.copy2(args.binary.resolve(strict=True), helper)
            digest = hashlib.sha256(helper.read_bytes()).hexdigest()
            receipt['frozenHelperSHA256'] = digest
            project, logs, store = base / 'project', base / 'logs', base / 'store'
            project.mkdir()
            for name in ('claude', 'codex', 'pi', 'omp', 'cursor'): (logs / name).mkdir(parents=True)
            env = dict(os.environ, VELA_DISABLE_DISCOVERY='1', VELA_SESSION_ROOT=str(logs))
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
            def request(method, **values): return call(method, dict(project=str(project), **values))
            def message(identifier, text='history evidence', cwd=None):
                row = {'type': 'user', 'uuid': identifier, 'message': {'role': 'user', 'content': text}}
                if cwd: row['cwd'] = cwd
                return row
            def encode(rows): return b''.join((json.dumps(row, ensure_ascii=False, sort_keys=True) + '\n').encode() for row in rows)
            call('projects.add', {'path': str(project)})
            assert call('history.describe')['decoderVersion'] == 'vela-history-jsonl-v1'
            long_row = message('long', 'original 中文🙂 ' * 12000)
            rows = [message('header', cwd=str(project)), long_row] + [message(f'm-{i}') for i in range(1200)]
            path = logs / 'claude' / '000-main.jsonl'; path.write_bytes(encode(rows))
            for number in range(1, 73): (logs / 'claude' / f'{number:03}.jsonl').write_bytes(encode([message('header', cwd=str(project))]))
            inventory = request('history.discover', provider='claude', limit=13)
            while inventory['state'] != 'completed':
                inventory = request('history.discover', inventoryId=inventory['id'], limit=13)
            assert inventory['discovered'] == 73 and inventory['traversalComplete']
            sources, after = [], ''
            while True:
                page = request('history.sources', inventoryId=inventory['id'], afterId=after, limit=17)
                sources.extend(page['items']); after = page['nextAfterId']
                if after is None: break
            main_source = next(item for item in sources if item['relativePath'] == '000-main.jsonl')
            receipt['checks'].append('73_sources_discovered_with_persistent_inventory_and_source_pages')
            epoch = request('history.start', sourceId=main_source['id'])
            epoch = request('history.advance', id=epoch['id'], batchBytes=1024)
            assert epoch['offset'] == 1024 and epoch['records'] == 1
            request('history.pause', id=epoch['id'])
            assert request('history.advance', id=epoch['id'])['state'] == 'paused'
            request('history.resume', id=epoch['id'])
            batches = 1; started = time.monotonic()
            while epoch['state'] == 'pending':
                epoch = request('history.advance', id=epoch['id'], batchRecords=79, batchBytes=65536); batches += 1
            assert epoch['state'] == 'completed' and epoch['rawBytesComplete'] and epoch['normalizationComplete']
            assert epoch['records'] == len(rows)
            receipt.update(importSeconds=round(time.monotonic()-started, 4), importBatches=batches, importedRecords=epoch['records'], sourceBytes=epoch['sourceBytes'])
            receipt['checks'].append('fresh_process_midrecord_checkpoint_pause_resume_and_complete_import')
            events, cursor = [], ''
            while True:
                page = request('history.page', id=epoch['id'], cursor=cursor, limit=89)
                events.extend(page['items']); cursor = page['nextCursor']
                if cursor is None: break
            assert [event['ordinal'] for event in events] == list(range(len(rows)))
            original, part = b'', 0
            import base64
            while True:
                chunk = request('history.raw', id=epoch['id'], ordinal=1, part=part)
                original += base64.b64decode(chunk['dataBase64']); part = chunk['nextPart']
                if part is None: break
            assert original == encode([long_row])
            assert hashlib.sha256(original).hexdigest() == events[1]['rawSHA256']
            assert len(events[1]['preview'].encode()) <= 4096
            receipt['checks'].append('1202_stable_events_and_exact_unicode_original_chunk_reconstruction')
            assert request('sessions.list') == []
            receipt['checks'].append('history_does_not_expand_default_session_dashboard')
            first_page = request('history.page', id=epoch['id'], limit=1)
            call('history.page', {'project': str(project), 'id': epoch['id'], 'cursor': first_page['nextCursor'], 'direction': 'backward'}, succeeds=False)
            path.write_bytes(encode([message('replacement', cwd=str(project))]))
            newer = request('history.start', sourceId=main_source['id'])
            assert newer['id'] != epoch['id']
            old_page = request('history.page', id=epoch['id'], cursor=first_page['nextCursor'], limit=1)
            assert old_page['items'][0]['ordinal'] == 1
            path.write_bytes(encode([message('changed-again', cwd=str(project))]))
            assert request('history.advance', id=newer['id'])['state'] == 'stale'
            receipt['checks'].append('source_epoch_cursor_binding_and_stale_unfinished_import')
            private_project = base / 'other'; private_project.mkdir()
            call('projects.add', {'path': str(private_project)})
            call('history.raw', {'project': str(private_project), 'id': epoch['id'], 'ordinal': 1}, succeeds=False)
            call('history.start', {'project': str(project), 'path': str(path)}, succeeds=False)
            receipt['checks'].append('cross_project_and_arbitrary_path_requests_rejected')
            receipt['status'] = 'pass'
        receipt['temporaryStoreAndSourcesRemoved'] = not base.exists()
    except Exception as error:
        receipt['error'] = str(error)
        raise
    finally:
        receipt['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2)+'\n')
        print(json.dumps(receipt, ensure_ascii=False, indent=2))


if __name__ == '__main__': main()
