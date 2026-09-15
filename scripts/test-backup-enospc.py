#!/usr/bin/env python3
"""Bounded local ENOSPC acceptance for `vela backup create`.

The harness owns its HFS+ disk image, mount point, fixture, and filler. It never
writes filler bytes outside that mounted image, and detaches only the device hdiutil
returns for this invocation.
"""
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRANSCRIPT = []

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def source_hashes(root):
    return {str(p.relative_to(root)): sha(p) for p in sorted((root / 'Sources').rglob('*.swift'))}

def tree_hashes(root):
    return {str(p.relative_to(root)): sha(p) for p in sorted(root.rglob('*')) if p.is_file() and not p.is_symlink()}

def text_value(value):
    if isinstance(value, bytes):
        return value.decode('utf-8', 'replace')
    return value or ''

def invoke(argv, *, env=None, cwd=ROOT, data=None, timeout=60, name=None):
    started = time.time()
    try:
        result = subprocess.run(argv, input=data, text=True, capture_output=True, env=env, cwd=cwd, timeout=timeout)
        entry = {'name': name, 'argv': [str(x) for x in argv], 'exitCode': result.returncode,
                 'stdout': text_value(result.stdout), 'stderr': text_value(result.stderr), 'startedAt': started, 'durationSeconds': time.time()-started}
    except subprocess.TimeoutExpired as error:
        entry = {'name': name, 'argv': [str(x) for x in argv], 'exitCode': None,
                 'stdout': text_value(error.stdout), 'stderr': text_value(error.stderr), 'timeout': True,
                 'startedAt': started, 'durationSeconds': time.time()-started}
        TRANSCRIPT.append(entry)
        raise RuntimeError(f'{name or argv[0]} deadline exceeded')
    TRANSCRIPT.append(entry)
    return result

def write_filler(mount, reserve_bytes, max_bytes=64 * 1024 * 1024):
    filler = mount / '.vela-enospc-filler'
    block = b'V' * (1024 * 1024)
    written = 0
    rounds = 0
    with filler.open('wb', buffering=0) as stream:
        while rounds < 128 and written < max_bytes:
            free = os.statvfs(mount).f_bavail * os.statvfs(mount).f_frsize
            if free <= reserve_bytes:
                break
            amount = min(len(block), free - reserve_bytes, max_bytes - written)
            if amount <= 0:
                break
            stream.write(block[:amount])
            stream.flush()
            os.fsync(stream.fileno())
            written += amount
            rounds += 1
    free = os.statvfs(mount).f_bavail * os.statvfs(mount).f_frsize
    return filler, free, written, rounds

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=ROOT / '.build/debug/vela')
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path, default=ROOT / 'output/parity/backup-enospc-14f188c-r5.json')
    parser.add_argument('--image-size', choices=['64m'], default='64m', help='fixed safe owned-image size')
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    source = args.source_root.resolve(strict=True)
    output = args.output.resolve()
    raw = output.with_suffix('.raw.json')
    if output.exists() or raw.exists() or output.is_symlink() or raw.is_symlink():
        parser.error('new output and raw paths are required')
    output.parent.mkdir(parents=True, exist_ok=True)
    (ROOT / '.task-tmp').mkdir(exist_ok=True)
    receipt = {
        'status': 'failed', 'commit': subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip(),
        'helperSHA256Before': sha(binary), 'sourceBefore': source_hashes(source), 'checks': [],
        'providerRuns': 0, 'synthetic': True, 'scope': 'owned HFS+ image only'
    }
    base = Path(tempfile.mkdtemp(prefix='backup-enospc-', dir=ROOT / '.task-tmp')).resolve()
    image = base / 'owned-enospc.dmg'
    mount = base / 'owned-mount'
    device = None
    attach_attempted = False
    attach_succeeded = False
    mount_verified = False
    source_before = {}
    project_before = {}
    def check(name, passed, **detail):
        receipt['checks'].append({'name': name, 'passed': bool(passed), **detail})
    try:
        helper = base / 'vela'
        shutil.copy2(binary, helper)
        home, project = base / 'home', base / 'project'
        project.mkdir()
        init = invoke(['/usr/bin/git', 'init', '-q'], cwd=project, name='git-init')
        if init.returncode:
            raise RuntimeError(init.stderr.strip())
        (project / 'README.md').write_text('owned ENOSPC backup fixture\n')
        commit = invoke(['/usr/bin/git', 'add', 'README.md'], cwd=project, name='git-add')
        if commit.returncode:
            raise RuntimeError(commit.stderr.strip())
        commit = invoke(['/usr/bin/git', '-c', 'user.name=Vela Test', '-c', 'user.email=vela@example.invalid', 'commit', '-qm', 'owned fixture'], cwd=project, name='git-commit')
        if commit.returncode:
            raise RuntimeError(commit.stderr.strip())
        env = dict(os.environ, HOME=str(base), VELA_HOME=str(home), VELA_SESSION_ROOT=str(base / 'sessions'),
                   VELA_DISABLE_DISCOVERY='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        rpc = invoke([str(helper), 'call', 'projects.add', '--params-stdin', '--home', str(home)], env=env, cwd=project,
                     data=json.dumps({'path': str(project)}), name='fixture-projects-add')
        if rpc.returncode:
            raise RuntimeError('fixture setup failed: ' + (rpc.stderr.strip() or rpc.stdout.strip()))
        memory = invoke([str(helper), 'call', 'memory.save', '--params-stdin', '--home', str(home)], env=env, cwd=project,
                        data=json.dumps({'id': 'enospc-public', 'project': str(project), 'title': 'ENOSPC fixture',
                                         'content': 'ENOSPC backup source record', 'private': False, 'state': 'active'}), name='fixture-memory-save')
        if memory.returncode:
            raise RuntimeError('fixture setup failed: ' + (memory.stderr.strip() or memory.stdout.strip()))
        source_before = tree_hashes(home)
        project_before = tree_hashes(project)
        receipt['sourceStoreBytesBefore'] = sum((home / p).stat().st_size for p in source_before)
        receipt['projectBytesBefore'] = sum((project / p).stat().st_size for p in project_before)
        volume_name = 'VelaENOSPC-' + uuid.uuid4().hex[:10]
        created = invoke(['hdiutil', 'create', '-size', args.image_size, '-fs', 'HFS+', '-volname', volume_name,
                          '-type', 'UDIF', '-nospotlight', str(image)], name='hdiutil-create')
        if created.returncode:
            raise RuntimeError('hdiutil create failed: ' + created.stderr.strip())
        mount.mkdir()
        attach_attempted = True
        attached = invoke(['hdiutil', 'attach', '-nobrowse', '-noverify', '-plist', '-mountpoint', str(mount), str(image)], name='hdiutil-attach')
        if attached.returncode:
            raise RuntimeError('hdiutil attach failed: ' + attached.stderr.strip())
        attach_succeeded = True
        plist = plistlib.loads(attached.stdout.encode())
        entities = plist.get('system-entities', [])
        device = next((e.get('dev-entry') for e in entities if e.get('mount-point') == str(mount) and e.get('dev-entry')), None)
        info = invoke(['hdiutil', 'info', '-plist'], name='hdiutil-info-owned-image')
        if info.returncode:
            raise RuntimeError('hdiutil info failed: ' + info.stderr.strip())
        image_record = next((record for record in plistlib.loads(info.stdout.encode()).get('images', [])
                             if Path(record.get('image-path', '')).resolve() == image.resolve()), None)
        info_entity = next((entity for entity in (image_record or {}).get('system-entities', [])
                            if entity.get('mount-point') == str(mount) and entity.get('dev-entry') == device), None)
        base_device = os.stat(base).st_dev
        mount_device = os.stat(mount).st_dev if mount.exists() else None
        mount_verified = bool(device and mount.is_dir() and mount.resolve() == mount and info_entity and mount_device != base_device)
        receipt['ownedImageSize'] = args.image_size
        receipt['ownedDevice'] = device
        receipt['ownedMount'] = str(mount)
        receipt['mountDevice'] = mount_device
        receipt['parentDevice'] = base_device
        receipt['hdiutilImageVerified'] = bool(image_record and info_entity)
        if not mount_verified:
            raise RuntimeError('owned image/device/mount verification failed before filler write')
        initial_free = os.statvfs(mount).f_bavail * os.statvfs(mount).f_frsize
        source_bytes = receipt['sourceStoreBytesBefore']
        reserve = max(16 * 1024, min(48 * 1024, max(16 * 1024, source_bytes // 8)))
        filler, remaining, filler_bytes, filler_rounds = write_filler(mount, reserve)
        receipt['spaceBeforeFiller'] = initial_free
        receipt['spaceAfterFiller'] = remaining
        receipt['reserveTargetBytes'] = reserve
        receipt['fillerBytesWritten'] = filler_bytes
        receipt['fillerRounds'] = filler_rounds
        check('owned-image-mounted-and-bounded', mount_verified and initial_free > 0 and filler_bytes <= 64 * 1024 * 1024 and remaining <= reserve + 8192 and filler.is_file(), initialFree=initial_free, remainingFree=remaining, fillerBytes=filler_bytes)
        destination = mount / 'backup-bundle'
        created_backup = invoke([str(helper), 'backup', 'create', '--destination', str(destination)], env=env, cwd=project, timeout=90, name='backup-create-enospc')
        combined = (created_backup.stdout + '\n' + created_backup.stderr).lower()
        receipt['backupExitCode'] = created_backup.returncode
        receipt['backupError'] = created_backup.stderr.strip() or created_backup.stdout.strip()
        receipt['destinationExistsAfterFailure'] = destination.exists()
        receipt['destinationEntriesAfterFailure'] = sorted(str(p.relative_to(mount)) for p in mount.rglob('*') if p != filler)
        actual_enospc = ('no space left on device' in combined or 'enospc' in combined or 'errno 28' in combined or 'sqlite backup did not complete (step 13' in combined)
        no_success = '"complete":true' not in ''.join(created_backup.stdout.split()).lower()
        no_bundle = not destination.exists()
        check('backup-reports-actual-enospc', created_backup.returncode != 0 and actual_enospc, error=receipt['backupError'])
        check('no-successful-bundle-or-owned-temp-residue', no_success and no_bundle and not receipt['destinationEntriesAfterFailure'], destinationExists=destination.exists(), remainingEntries=receipt['destinationEntriesAfterFailure'])
        source_after_fixture = tree_hashes(home)
        changed_paths = sorted(set(source_before) ^ set(source_after_fixture) | {p for p in set(source_before) & set(source_after_fixture) if source_before[p] != source_after_fixture[p]})
        transient_runtime_paths = {'.composition.lock', '.daemon.lock', '.scheduler.lock', 'vela.sqlite3-shm'}
        persistent_before = {p: value for p, value in source_before.items() if p not in transient_runtime_paths}
        persistent_after = {p: value for p, value in source_after_fixture.items() if p not in transient_runtime_paths}
        receipt['sourceStoreChangedPaths'] = changed_paths
        receipt['transientRuntimePaths'] = sorted(set(changed_paths) & transient_runtime_paths)
        receipt['persistentStoreChangedPaths'] = sorted(set(persistent_before) ^ set(persistent_after) | {p for p in set(persistent_before) & set(persistent_after) if persistent_before[p] != persistent_after[p]})
        check('source-store-persistent-data-and-assets-unchanged', persistent_after == persistent_before, persistentChangedPaths=receipt['persistentStoreChangedPaths'], transientRuntimePaths=receipt['transientRuntimePaths'])
        check('project-unchanged', tree_hashes(project) == project_before)
        receipt['status'] = 'passed' if all(item['passed'] for item in receipt['checks']) else 'failed'
    except Exception as error:
        receipt['failure'] = f'{type(error).__name__}: {error}'
        receipt['status'] = 'failed'
    finally:
        detached = not attach_attempted
        attach_confirmed_absent = False
        if attach_succeeded and device:
            try:
                detached_result = invoke(['hdiutil', 'detach', device], timeout=60, name='hdiutil-detach')
                receipt['detachExitCode'] = detached_result.returncode
                detached = detached_result.returncode == 0
            except Exception as detach_error:
                receipt['detachError'] = f'{type(detach_error).__name__}: {detach_error}'
                detached = False
        elif attach_attempted:
            # A timed-out or failed attach may still have mounted asynchronously.
            # Clean up only after hdiutil explicitly says this exact owned image is absent.
            try:
                info_after = invoke(['hdiutil', 'info', '-plist'], timeout=30, name='hdiutil-info-after-attach')
                if info_after.returncode == 0:
                    images_after = plistlib.loads(info_after.stdout.encode()).get('images', [])
                    attach_confirmed_absent = not any(Path(record.get('image-path', '')).resolve() == image.resolve() for record in images_after)
                else:
                    receipt['attachStateCheckError'] = info_after.stderr.strip()
            except Exception as state_error:
                receipt['attachStateCheckError'] = f'{type(state_error).__name__}: {state_error}'
            if not attach_confirmed_absent:
                receipt['detachError'] = 'attach was attempted but no safe owned detach/absence confirmation was available; fixture retained for manual cleanup'
            detached = attach_confirmed_absent
        receipt['attachAttempted'] = attach_attempted
        receipt['attachConfirmedAbsent'] = attach_confirmed_absent
        receipt['detached'] = detached
        try:
            receipt['helperSHA256After'] = sha(binary)
            receipt['sourceAfter'] = source_hashes(source)
            receipt['helperUnchanged'] = receipt['helperSHA256Before'] == receipt['helperSHA256After']
            receipt['sourceUnchanged'] = receipt['sourceBefore'] == receipt['sourceAfter']
        except Exception as hash_error:
            receipt['hashFinalizationError'] = f'{type(hash_error).__name__}: {hash_error}'
            receipt['helperUnchanged'] = False
            receipt['sourceUnchanged'] = False
        cleanup_safe = not attach_attempted or detached
        if cleanup_safe:
            try:
                if base.exists():
                    shutil.rmtree(base)
            except Exception as cleanup_error:
                receipt['cleanupError'] = f'{type(cleanup_error).__name__}: {cleanup_error}'
                receipt['status'] = 'failed'
        else:
            receipt['cleanupDeferred'] = True
            receipt['retainedOwnedFixture'] = str(base)
        receipt['fixtureRemoved'] = not base.exists()
        if not detached or not receipt.get('fixtureRemoved') or not receipt.get('helperUnchanged') or not receipt.get('sourceUnchanged'):
            receipt['status'] = 'failed'
        try:
            raw.write_text(json.dumps(TRANSCRIPT, ensure_ascii=False, indent=2) + '\n')
        except Exception as raw_error:
            receipt['rawWriteError'] = f'{type(raw_error).__name__}: {raw_error}'
            receipt['status'] = 'failed'
        try:
            output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
        except Exception as receipt_error:
            print(json.dumps({'status': 'failed', 'receiptWriteError': f'{type(receipt_error).__name__}: {receipt_error}'}, ensure_ascii=False))
    print(json.dumps(receipt, ensure_ascii=False, indent=2))
    return 0 if receipt['status'] == 'passed' else 1

if __name__ == '__main__':
    raise SystemExit(main())
