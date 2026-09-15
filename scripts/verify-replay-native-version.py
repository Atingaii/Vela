"""Check a private native executable copy using --version only; no model or account calls."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--executable', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
if not args.executable.is_absolute() or args.output.exists() or args.output.is_symlink():
    parser.error('Explicit absolute executable and new evidence path required.')
receipt = dict(status='failed', startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), modelCalls=0, accountCalls=0, sourcePath=str(args.executable), dependencyClosurePinned=False)
try:
    with tempfile.TemporaryDirectory(prefix='vela-replay-native-version-') as temporary:
        base = Path(temporary).resolve(); copy = base/'provider'
        source = args.executable.resolve(strict=True)
        assert source.is_file() and source.stat().st_size <= 536870912
        with source.open('rb') as stream:
            assert stream.read(4) in [bytes.fromhex(x) for x in ['feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']]
        original = hashlib.sha256(source.read_bytes()).hexdigest()
        with source.open('rb') as incoming, copy.open('xb') as outgoing:
            shutil.copyfileobj(incoming, outgoing, length=1048576)
        copied = hashlib.sha256(copy.read_bytes()).hexdigest()
        assert copied == original
        copy.chmod(0o500)
        (base/'home').mkdir(); (base/'codex-home').mkdir()
        env = dict(os.environ, HOME=str(base/'home'), CODEX_HOME=str(base/'codex-home'), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        process = subprocess.run([str(copy), '--version'], cwd=base, env=env, capture_output=True, text=True, timeout=20)
        assert process.returncode == 0 and len(process.stdout.encode()) < 4096
        assert hashlib.sha256(copy.read_bytes()).hexdigest() == original
        receipt.update(status='passed', nativeExecutableSHA256=original, copiedExecutableSHA256=copied, version=process.stdout.strip(), exitCode=process.returncode)
except Exception as error:
    receipt['error'] = str(error)
    raise
finally:
    receipt['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    receipt['temporaryDataRemoved'] = True
    receipt['scriptSHA256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps(dict(status=receipt['status'], version=receipt.get('version'), receipt=str(args.output))))
