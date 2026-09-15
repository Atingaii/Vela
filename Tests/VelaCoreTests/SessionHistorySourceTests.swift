import XCTest
import Darwin
@testable import VelaCore

final class SessionHistorySourceTests: XCTestCase {
    private final class Fixture {
        let temporary: URL, root: URL, project: URL, source: URL
        init() throws {
            let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            temporary = workspace.appendingPathComponent(".task-tmp/history-root-test-" + UUID().uuidString)
            root = temporary.appendingPathComponent("logs"); project = temporary.appendingPathComponent("project"); source = root.appendingPathComponent("source.jsonl")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let row: JSON = ["type":"session_meta","payload":["id":"00000000-0000-4000-8000-000000000001","cwd":project.path,"source":"cli"] as JSON]
            try (jsonString(row) + "\n").write(to: source, atomically: true, encoding: .utf8)
        }
        deinit { try? FileManager.default.removeItem(at: temporary) }
        func openAndClose(_ path: String, root configuredRoot: String? = nil, directory: Bool = false) throws {
            let (descriptor, _) = try SessionHistorySource.open(path, root: configuredRoot ?? root.path, directory: directory)
            close(descriptor)
        }
    }
    func testConfiguredWorkspaceRootSupportsDiscoveryAndExactRead() throws {
        let f = try Fixture(), root = canonicalProject(f.root.path)
        let page = try SessionHistorySource.directoryPage(path: root, root: root, after: "", limit: 5)
        XCTAssertEqual(page.names, ["source.jsonl"])
        let header = try SessionHistorySource.header(path: f.source.path, root: root, provider: "codex")
        XCTAssertEqual(string(header,"project"), canonicalProject(f.project.path))
        let (descriptor, info) = try SessionHistorySource.open(f.source.path, root: root)
        defer { close(descriptor) }
        XCTAssertNotEqual(fcntl(descriptor,F_GETFD) & FD_CLOEXEC, 0)
        try SessionHistorySource.verify(descriptor, path: f.source.path, root: root, version: SessionHistorySource.identity(info))
        let store = try VelaStore(root: f.temporary.appendingPathComponent("store"))
        let service = FoundationService(store: store, sourceRoots: ["codex":[f.root]], globalHome: f.temporary)
        _ = try service.handle("projects.add", ["path":f.project.path])
        let inventory = try XCTUnwrap(try service.handle("history.discover", ["project":f.project.path,"provider":"codex"]) as? JSON)
        XCTAssertEqual(intValue(inventory,"failures"), 0); XCTAssertEqual(intValue(inventory,"discovered"), 1)
        XCTAssertEqual(inventory["traversalComplete"] as? Bool, true)
    }
    func testRootAndDescendantLinksAndFileHardLinksAreRejected() throws {
        let f = try Fixture(), linkedRoot = f.temporary.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: f.root)
        XCTAssertThrowsError(try f.openAndClose(linkedRoot.path, root: linkedRoot.path, directory: true))
        let linkedFile = f.root.appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: f.source)
        XCTAssertThrowsError(try f.openAndClose(linkedFile.path))
        let linkedDirectory = f.root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: f.root)
        XCTAssertThrowsError(try f.openAndClose(linkedDirectory.appendingPathComponent("source.jsonl").path))
        let hardLink = f.root.appendingPathComponent("hard.jsonl")
        try FileManager.default.linkItem(at: f.source, to: hardLink)
        XCTAssertThrowsError(try f.openAndClose(hardLink.path))
        XCTAssertThrowsError(try f.openAndClose(f.source.path))
    }
    func testLexicalTraversalAndSiblingPrefixCannotEscapeRoot() throws {
        let f = try Fixture()
        for path in [f.root.path + "/../logs/source.jsonl", f.root.path + "/./source.jsonl", f.root.path + "//source.jsonl", f.root.path + "-sibling/source.jsonl", f.source.path + "\0"] {
            XCTAssertThrowsError(try f.openAndClose(path))
        }
        XCTAssertThrowsError(try f.openAndClose(f.source.path, root: f.root.path + "/.."))
    }
    func testRedirectedAncestorOfConfiguredRootIsRejectedByPhysicalIdentity() throws {
        let f = try Fixture(), old = f.temporary.appendingPathComponent("moved-logs")
        let nested = f.root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let path = nested.appendingPathComponent("source.jsonl")
        try Data(contentsOf: f.source).write(to: path)
        let configured = canonicalProject(nested.path)
        try FileManager.default.moveItem(at: f.root, to: old)
        try FileManager.default.createSymbolicLink(at: f.root, withDestinationURL: old)
        XCTAssertThrowsError(try f.openAndClose(path.path, root: configured))
    }
    func testRootReplacementCannotValidateAnAlreadyOpenSource() throws {
        let f = try Fixture(), root = canonicalProject(f.root.path)
        let (descriptor, info) = try SessionHistorySource.open(f.source.path, root: root)
        defer { close(descriptor) }
        let old = f.temporary.appendingPathComponent("old-root")
        try FileManager.default.moveItem(at: f.root, to: old)
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        try Data(contentsOf: old.appendingPathComponent("source.jsonl")).write(to: f.source)
        XCTAssertThrowsError(try SessionHistorySource.verify(descriptor, path: f.source.path, root: root, version: SessionHistorySource.identity(info)))
    }
    func testSourceRewriteAndDescendantDirectoryReplacementFailVerification() throws {
        let f = try Fixture(), nested = f.root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let path = nested.appendingPathComponent("source.jsonl")
        try Data(contentsOf: f.source).write(to: path)
        let (descriptor, info) = try SessionHistorySource.open(path.path, root: f.root.path)
        defer { close(descriptor) }
        try Data("changed".utf8).write(to: path)
        XCTAssertThrowsError(try SessionHistorySource.verify(descriptor, path: path.path, root: f.root.path, version: SessionHistorySource.identity(info)))
        try FileManager.default.removeItem(at: nested)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: f.root)
        XCTAssertThrowsError(try SessionHistorySource.verify(descriptor, path: path.path, root: f.root.path, version: SessionHistorySource.identity(info)))
    }
}
