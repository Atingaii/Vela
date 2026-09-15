#!/usr/bin/env python3
"""Freeze, but never approve, an Agent Lab evaluation from one owned Golden fixture."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def sha(data): return hashlib.sha256(data).hexdigest()


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def project_snapshot(project):
    rows = []
    for path in sorted(project.rglob('*')):
        relative = path.relative_to(project)
        if '.git' in relative.parts:
            continue
        info = path.lstat()
        if path.is_symlink():
            raise RuntimeError('Project snapshot rejects symlinks: ' + str(relative))
        if path.is_file():
            rows.append({'path': str(relative), 'bytes': info.st_size, 'sha256': sha(path.read_bytes())})
    encoded = json.dumps(rows, separators=(',', ':'), ensure_ascii=False).encode()
    status = subprocess.run(['/usr/bin/git', '-C', str(project), 'status', '--porcelain=v1', '--untracked-files=all'], text=True, capture_output=True, check=True).stdout
    return {'files': rows, 'manifestSHA256': sha(encoded), 'gitStatus': status, 'gitStatusSHA256': sha(status.encode())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--postverify', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New immediate output/parity child')
    parser.add_argument('--timeout', type=int, default=60)
    args = parser.parse_args()
    fixture, postverify, out = args.fixture.resolve(strict=True), args.postverify.resolve(strict=True), args.output.absolute()
    if not 30 <= args.timeout <= 120 or out.exists() or out.is_symlink() or out.parent != ROOT / 'output/parity':
        parser.error('Require a 30–120 second timeout and a new immediate output/parity child')
    owner = json.loads((fixture / '.owner.json').read_text())
    if owner.get('format') != 'vela-golden-live-owned-v1': parser.error('Fixture marker is not owned Golden evidence')
    verified = json.loads(postverify.read_text())
    if verified.get('status') != 'passed' or not verified.get('sameLiveSessionEvidence') or verified.get('newProviderRuns') != 0 or verified.get('manualRefresh') or verified.get('manualCandidateWrites'):
        parser.error('Post-verification receipt is not an eligible same-chain observation')
    out.mkdir(mode=0o700)
    receipt = {'format': 'vela-golden-agent-lab-freeze-v1', 'status': 'not_run', 'newProviderRuns': 0,
        'approvalDecision': 'not_sent', 'sameLiveSessionEvidence': True, 'postverifyReceipt': str(postverify),
        'postverifySHA256': sha(postverify.read_bytes()), 'cleanup': {}}
    rpc = None
    try:
        golden = load('golden_live', ROOT / 'scripts/test-golden-live.py')
        support = load('golden_postverify', ROOT / 'scripts/verify-golden-records.py')
        project, helper = fixture / 'Bounds', fixture / 'vela-frozen'
        if not project.is_dir() or not helper.is_file() or helper.is_symlink() or sha(helper.read_bytes()) != verified.get('helperSHA256'):
            raise RuntimeError('Owned project/helper no longer matches post-verification evidence')
        prior = json.loads(Path(verified['priorReceipt']).read_text())
        turns = prior.get('providerTurns', [])
        task = golden.TASK
        if len(turns) != 4 or any(row.get('exitCode') != 0 for row in turns):
            raise RuntimeError('Original provider receipt is incomplete')
        executable = Path(turns[0]['argv'][0]).resolve(strict=True)
        suggestion_ids = verified.get('steps', {}).get('improveAnalyze', {}).get('suggestionIds', [])
        candidate_ids = verified.get('steps', {}).get('improveAnalyze', {}).get('candidateIds', [])
        if len(suggestion_ids) != 1 or len(candidate_ids) != 3 or len(set(candidate_ids)) != 3:
            raise RuntimeError('Post-verification does not identify one suggestion and three candidate memories')
        before = project_snapshot(project); (out / 'project-before.json').write_text(json.dumps(before, indent=2) + '\n')
        env = {'VELA_HOME': str(fixture / 'store'), 'VELA_SESSION_ROOT': str(fixture / 'sources'), 'VELA_DISABLE_DISCOVERY': '1'}
        rpc = support.RPC(helper, env, fixture, out); deadline = time.monotonic() + args.timeout
        rpc.call('projects.add', {'path': str(project)}, deadline)
        suggestions = rpc.call('improve.list', {'project': str(project)}, deadline)
        suggestion = next((row for row in suggestions if row.get('id') == suggestion_ids[0]), None)
        if not suggestion or suggestion.get('project') != str(project) or set(suggestion.get('verificationCandidateMemoryIds', [])) != set(candidate_ids):
            raise RuntimeError('Suggestion no longer binds exactly the post-verified candidate memories')
        request = {'project': str(project), 'title': 'Golden observed verification-memory paired evaluation', 'kind': 'memory',
            'agent': {'provider': 'codex', 'executable': str(executable), 'model': 'gpt-5.6-terra', 'reasoningEffort': 'high'},
            'task': task, 'verificationCommand': ['/usr/bin/python3', 'verify.py'], 'verificationFiles': ['verify.py', 'README.md'],
            'outputFiles': ['bounds.py'], 'timeoutSeconds': 240, 'repetitions': 3,
            'baseline': {'label': 'Baseline', 'files': [], 'memoryIds': []},
            'candidate': {'label': 'Candidate', 'files': [], 'memoryIds': candidate_ids}, 'sourceSuggestionId': suggestion_ids[0]}
        (out / 'frozen-request.json').write_text(json.dumps(request, ensure_ascii=False, indent=2) + '\n')
        evaluation = rpc.call('lab.run', request, deadline)
        if evaluation.get('state') != 'pending_approval' or evaluation.get('evaluator') != 'codex_agent' or not evaluation.get('approvalId'):
            raise RuntimeError('Lab creation did not remain pending approval')
        if set(row.get('id') for row in evaluation.get('candidate', {}).get('memories', [])) != set(candidate_ids) or evaluation.get('sourceSuggestionId') != suggestion_ids[0]:
            raise RuntimeError('Frozen candidate does not exactly retain suggestion-linked memories')
        after = project_snapshot(project); (out / 'project-after.json').write_text(json.dumps(after, indent=2) + '\n')
        if before != after:
            raise RuntimeError('Freezing Lab changed project regular files or Git status')
        receipt.update(status='pending_approval_created', helperSHA256=sha(helper.read_bytes()), projectSnapshotBefore=before['manifestSHA256'], projectSnapshotAfter=after['manifestSHA256'], gitStatusBefore=before['gitStatusSHA256'], gitStatusAfter=after['gitStatusSHA256'], suggestionId=suggestion_ids[0], candidateMemoryIds=candidate_ids, evaluation=evaluation, approvalId=evaluation['approvalId'], taskSHA256=sha(task.encode()))
    except Exception as error:
        receipt.update(status='failed', failure=str(error)[:3000])
    finally:
        if rpc: rpc.close()
        receipt['cleanup']['helperStopped'] = rpc is None or rpc.process.poll() is not None
        (out / 'receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({'receipt': str(out / 'receipt.json'), 'status': receipt['status'], 'approvalDecision': 'not_sent', 'newProviderRuns': 0}, ensure_ascii=False))
    return 0 if receipt['status'] == 'pending_approval_created' else 1


if __name__ == '__main__': raise SystemExit(main())
