"""Run the same synchronous XCTest cases on macOS Command Line Tools without XCTest.

This is a fallback runner, not an XCTest implementation. It compiles the real core
and unchanged test bodies together, provides only the assertions used here, and
runs each test with its normal fixture setup/teardown. Full-Xcode CI runs XCTest.
"""
import argparse, datetime, hashlib, json, pathlib, re, subprocess, tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--filter', action='append', default=[], help='Run methods whose fully qualified name contains this text; repeat to select several groups.')
parser.add_argument('--receipt', type=pathlib.Path, help='Write hashes of the exact compiled source snapshot and its result; keep separate receipts for separate runs.')
args = parser.parse_args()

root = pathlib.Path(__file__).resolve().parents[1]
def source_paths():
    return sorted((root/'Sources/VelaCore').glob('*.swift')) + sorted((root/'Tests/VelaCoreTests').glob('*.swift'))
paths = source_paths()
source_snapshot = {path: path.read_bytes() for path in paths}
if paths != source_paths() or any(not path.exists() or path.read_bytes() != value for path, value in source_snapshot.items()):
    raise RuntimeError('Source changed while the snapshot was captured; rerun after the edits settle.')
source_hashes = {str(path.relative_to(root)): hashlib.sha256(value).hexdigest() for path, value in source_snapshot.items()}
snapshot_hash = hashlib.sha256(json.dumps(source_hashes, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
receipt = {'format':'vela-portable-source-snapshot-v1','startedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),
           'snapshotSHA256':snapshot_hash,'sourceSHA256':source_hashes,'runnerSHA256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
           'filter':args.filter,'runner':'portable synchronous assertion compatibility layer; not XCTest','passed':False}
if args.receipt and args.receipt.exists():
    parser.error('Choose a new receipt path; existing evidence is not overwritten.')
def save_receipt():
    receipt['matchesWorkingTreeAtEnd'] = paths == source_paths() and all(path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == source_hashes[str(path.relative_to(root))] for path in paths)
    if args.receipt:
        args.receipt.parent.mkdir(parents=True,exist_ok=True)
        args.receipt.write_text(json.dumps(receipt,indent=2)+'\n')
support = r'''
import Foundation
var testFailures: [String] = []
class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}
func recordFailure(_ message: String, _ file: StaticString = #file, _ line: UInt = #line) {
    testFailures.append("\(file):\(line): \(message)")
}
func XCTFail(_ message: String = "Failure", file: StaticString = #file, line: UInt = #line) { recordFailure(message,file,line) }
func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: String = "Expected true", file: StaticString = #file, line: UInt = #line) {
    do { if try !expression() { recordFailure(message,file,line) } } catch { recordFailure("\(error)",file,line) }
}
func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: String = "Expected false", file: StaticString = #file, line: UInt = #line) {
    do { if try expression() { recordFailure(message,file,line) } } catch { recordFailure("\(error)",file,line) }
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, _ message: String = "Values differ", file: StaticString = #file, line: UInt = #line) {
    do { let a = try lhs(), b = try rhs(); if a != b { recordFailure("\(message): \(a) != \(b)",file,line) } } catch { recordFailure("\(error)",file,line) }
}
func XCTAssertNotEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, _ message: String = "Values equal", file: StaticString = #file, line: UInt = #line) {
    do { if try lhs() == rhs() { recordFailure(message,file,line) } } catch { recordFailure("\(error)",file,line) }
}
func XCTAssertGreaterThan<T: Comparable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, _ message: String = "Expected greater", file: StaticString = #file, line: UInt = #line) {
    do { if try lhs() <= rhs() { recordFailure(message,file,line) } } catch { recordFailure("\(error)",file,line) }
}
func XCTAssertLessThan<T: Comparable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, _ message: String = "Expected less", file: StaticString = #file, line: UInt = #line) {
    do { if try lhs() >= rhs() { recordFailure(message,file,line) } } catch { recordFailure("\(error)",file,line) }
}
func XCTAssertLessThanOrEqual<T: Comparable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, _ message: String = "Expected <=", file: StaticString = #file, line: UInt = #line) {
    do { if try lhs() > rhs() { recordFailure(message,file,line) } } catch { recordFailure("\(error)",file,line) }
}
func XCTAssertNotNil<T>(_ expression: @autoclosure () throws -> T?, _ message: String = "Expected nonnil", file: StaticString = #file, line: UInt = #line) {
    do { if try expression() == nil { recordFailure(message,file,line) } } catch { recordFailure("\(error)",file,line) }
}
func XCTAssertNil<T>(_ expression: @autoclosure () throws -> T?, _ message: String = "Expected nil", file: StaticString = #file, line: UInt = #line) {
    do { if try expression() != nil { recordFailure(message,file,line) } } catch { recordFailure("\(error)",file,line) }
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "Expected error", file: StaticString = #file, line: UInt = #line, _ errorHandler: (Error) -> Void = { _ in }) {
    do { _ = try expression(); recordFailure(message,file,line) } catch { errorHandler(error) }
}
func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: String = "Unexpected error", file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression() } catch { recordFailure("\(message): \(error)",file,line) }
}
func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?, _ message: String = "Expected nonnil", file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value = try expression() else { throw VelaError("\(file):\(line): \(message)") }; return value
}
'''

with tempfile.TemporaryDirectory(prefix='vela-portable-tests-') as temporary:
    scratch=pathlib.Path(temporary)
    test_sources=[]; invocations=[]
    for path in (path for path in paths if path.parent == root/'Tests/VelaCoreTests'):
        source=source_snapshot[path].decode('utf-8')
        case=re.search(r'final class (\w+): XCTestCase',source)
        assert case, f'Unsupported test declaration in {path}'
        methods=re.findall(r'\bfunc (test\w+)\(\)\s*(?:throws)?\s*\{',source)
        assert methods, f'No synchronous tests discovered in {path}'
        source=source.replace('import XCTest','import Foundation').replace('@testable import VelaCore','')
        generated=scratch/path.name; generated.write_text(source); test_sources.append(str(generated))
        for method in methods:
            if args.filter and not any(value in case.group(1) + '.' + method for value in args.filter):
                continue
            invocations.append(f'''
do {{
    let instance = {case.group(1)}()
    let priorCount = testFailures.count
    do {{ try instance.setUpWithError(); try instance.{method}() }}
    catch {{ recordFailure("{case.group(1)}.{method}: \\(error)") }}
    do {{ try instance.tearDownWithError() }} catch {{ recordFailure("teardown: \\(error)") }}
    print("\\(testFailures.count == priorCount ? "PASS" : "FAIL") {case.group(1)}.{method}")
}}
''')
    assert invocations, 'No tests matched the requested filter'
    (scratch/'Support.swift').write_text(support)
    (scratch/'main.swift').write_text('import Foundation\n'+''.join(invocations)+f'\nprint("Executed {len(invocations)} real-core test methods using the portable fallback runner.")\nif !testFailures.isEmpty {{ testFailures.forEach {{ fputs($0 + "\\n", stderr) }}; exit(1) }}\n')
    core_sources=[]
    for source in (path for path in paths if path.parent == root/'Sources/VelaCore'):
        snapshot=scratch/source.name; snapshot.write_bytes(source_snapshot[source]); core_sources.append(str(snapshot))
    command=['swiftc','-swift-version','5','-I',str(root/'Sources/CSQLite'),*core_sources,str(scratch/'Support.swift'),*test_sources,str(scratch/'main.swift'),'-o',str(scratch/'tests')]
    compilation=subprocess.run(command,capture_output=True,text=True,cwd=root)
    if compilation.returncode:
        receipt.update(phase='compile',exitCode=compilation.returncode); save_receipt()
        print(compilation.stdout+compilation.stderr)
        compilation.check_returncode()
    warning_count=compilation.stderr.count('warning:')
    print(f'Compiled real core and test methods ({warning_count} compiler warnings); source snapshot {snapshot_hash}.',flush=True)
    receipt.update(methodCount=len(invocations),compilerWarnings=warning_count,phase='execute')
    try:
        completed = subprocess.run([str(scratch/'tests')],cwd=root,timeout=180)
    except subprocess.TimeoutExpired:
        receipt.update(timedOut=True); save_receipt(); raise
    receipt.update(passed=completed.returncode == 0,exitCode=completed.returncode); save_receipt()
    completed.check_returncode()
