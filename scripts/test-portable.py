"""Run the same synchronous XCTest cases on macOS Command Line Tools without XCTest.

This is a fallback runner, not an XCTest implementation. It compiles the real core
and unchanged test bodies together, provides only the assertions used here, and
runs each test with its normal fixture setup/teardown. Full-Xcode CI runs XCTest.
"""
import pathlib, re, subprocess, tempfile

root = pathlib.Path(__file__).resolve().parents[1]
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
    for path in sorted((root/'Tests/VelaCoreTests').glob('*.swift')):
        source=path.read_text()
        case=re.search(r'final class (\w+): XCTestCase',source)
        assert case, f'Unsupported test declaration in {path}'
        methods=re.findall(r'\bfunc (test\w+)\(\)\s*(?:throws)?\s*\{',source)
        assert methods, f'No synchronous tests discovered in {path}'
        source=source.replace('import XCTest','import Foundation').replace('@testable import VelaCore','')
        generated=scratch/path.name; generated.write_text(source); test_sources.append(str(generated))
        for method in methods:
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
    (scratch/'Support.swift').write_text(support)
    (scratch/'main.swift').write_text('import Foundation\n'+''.join(invocations)+f'\nprint("Executed {len(invocations)} real-core test methods using the portable fallback runner.")\nif !testFailures.isEmpty {{ testFailures.forEach {{ fputs($0 + "\\n", stderr) }}; exit(1) }}\n')
    core_sources=[]
    for source in sorted((root/'Sources/VelaCore').glob('*.swift')):
        snapshot=scratch/source.name; snapshot.write_text(source.read_text()); core_sources.append(str(snapshot))
    command=['swiftc','-swift-version','5','-I',str(root/'Sources/CSQLite'),*core_sources,str(scratch/'Support.swift'),*test_sources,str(scratch/'main.swift'),'-o',str(scratch/'tests')]
    compilation=subprocess.run(command,capture_output=True,text=True,cwd=root)
    if compilation.returncode:
        print(compilation.stdout+compilation.stderr)
        compilation.check_returncode()
    warning_count=compilation.stderr.count('warning:')
    print(f'Compiled real core and test methods ({warning_count} compiler warnings).',flush=True)
    subprocess.run([str(scratch/'tests')],check=True,cwd=root,timeout=180)
