"""Check the fallback assertion semantics without importing or running its suite.

An error expected by an outer assertion must not erase a failure already
recorded by XCTUnwrap. This caught a difference from hosted XCTest in CI.
"""
import argparse
import ast
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--runner', type=Path, default=Path(__file__).with_name('test-portable.py'))
args = parser.parse_args()
tree = ast.parse(args.runner.read_text())
support = next(ast.literal_eval(node.value) for node in tree.body
               if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == 'support' for target in node.targets))
checks = r'''
struct VelaError: Error { let message: String; init(_ message: String) { self.message = message } }
enum FixtureError: Error { case expected }
func require(_ value: Bool, _ message: String) {
    if !value { fputs(message + "\n", stderr); exit(1) }
}
var evaluations = 0
func throwingValue() throws -> Int? { evaluations += 1; throw FixtureError.expected }
func invalidWrapper() throws -> Int { try XCTUnwrap(throwingValue()) }
func correctWrapper() throws -> Int {
    let optional = try throwingValue()
    return try XCTUnwrap(optional)
}
XCTAssertThrowsError(try invalidWrapper())
require(evaluations == 1 && testFailures.count == 1,
        "Caught XCTUnwrap expression errors must still record one failure")
testFailures.removeAll(); evaluations = 0
XCTAssertThrowsError(try correctWrapper())
require(evaluations == 1 && testFailures.isEmpty,
        "A business error evaluated outside XCTUnwrap must reach its own assertion")
let missing: Int? = nil
XCTAssertThrowsError(try XCTUnwrap(missing))
require(testFailures.count == 1, "Caught nil unwraps must still record one failure")
testFailures.removeAll()
let present = try XCTUnwrap(Optional(42))
require(present == 42 && testFailures.isEmpty, "Unwrapping a present value must succeed")
print("Portable assertion semantics: 4 checks passed")
'''
with tempfile.TemporaryDirectory(prefix='vela-assertion-semantics-') as temporary:
    root = Path(temporary)
    source, binary = root / 'main.swift', root / 'assertion-semantics'
    source.write_text(support + '\n' + checks)
    subprocess.run(['xcrun', 'swiftc', str(source), '-o', str(binary)], check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=10)
