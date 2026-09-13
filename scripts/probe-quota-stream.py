"""Measure real bounded quota-pipe handling on an immutable Core snapshot.

Uses the existing synthetic executable fixture and real POSIX transport. This
diagnostic does not read an account, change a production timeout, or assert a
machine-independent performance threshold. Keep before/after receipts separate.
"""
import argparse, ast, hashlib, json, pathlib, shutil, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-directory', type=pathlib.Path, default=ROOT)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--iterations', type=int, default=4)
args = parser.parse_args()
source = args.source_directory.resolve(strict=True)
assert 1 <= args.iterations <= 16 and not args.output.exists()
runner = (source/'scripts/test-portable.py').read_text()
support = next(ast.literal_eval(node.value) for node in ast.parse(runner).body
               if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id=='support' for t in node.targets))
paths = sorted((source/'Sources/VelaCore').glob('*.swift')) + [source/'Tests/VelaCoreTests/ProviderQuotaTests.swift']
snapshot = {p.relative_to(source).as_posix():p.read_bytes() for p in paths}
hashes = {name:hashlib.sha256(data).hexdigest() for name,data in snapshot.items()}
with tempfile.TemporaryDirectory(prefix='vela-quota-stream-probe-') as temporary:
    scratch = pathlib.Path(temporary)
    files=[]
    for name, data in snapshot.items():
        path=scratch/pathlib.Path(name).name
        text=data.decode().replace('import XCTest','import Foundation').replace('@testable import VelaCore','')
        path.write_text(text); files.append(str(path))
    (scratch/'Support.swift').write_text(support)
    (scratch/'main.swift').write_text('''import Foundation
var rows: [JSON] = []
for mode in ["flood","stderr_flood"] {
  for round in 0..<ITERATIONS {
    let instance = ProviderQuotaTests()
    try instance.setUpWithError()
    let executable = try instance.fixture(mode)
    let started = Date()
    let value = try instance.read(instance.service(timeout:2),executable)
    let attempt = value["lastAttempt"] as? JSON ?? [:]
    rows.append(["mode":mode,"round":round,"elapsedSeconds":Date().timeIntervalSince(started),"errorKind":string(attempt["error"] as? JSON ?? [:],"kind")])
    try instance.tearDownWithError()
  }
}
print(try jsonString(["results":rows,"assertionFailures":testFailures]))
'''.replace('ITERATIONS',str(args.iterations)))
    compiled=subprocess.run(['swiftc','-swift-version','5','-I',str(source/'Sources/CSQLite'),*files,str(scratch/'Support.swift'),str(scratch/'main.swift'),'-o',str(scratch/'probe')],capture_output=True,text=True,timeout=180)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.with_suffix('.compile.log').write_text(compiled.stdout+compiled.stderr)
    compiled.check_returncode()
    result=subprocess.run([str(scratch/'probe')],capture_output=True,text=True,timeout=120)
    args.output.with_suffix('.run.log').write_text(result.stdout+result.stderr)
    result.check_returncode()
    receipt=json.loads(result.stdout)
    receipt.update(sourceSHA256=hashes,sourceSnapshotSHA256=hashlib.sha256(json.dumps(hashes,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
                   productionSourceChanged=False,sourceUnchanged=all((source/name).read_bytes()==data for name,data in snapshot.items()),
                   existingAccountsUsed=False,timeoutSeconds=2,temporaryFilesRemoved=True)
args.output.write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt['results']))
