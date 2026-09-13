import XCTest
import CSQLite
import Dispatch
@testable import VelaCore

final class IngestionPolicyConcurrencyTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var store: VelaStore!
    private var service: IngestionExclusionService!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: canonicalProject(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("vela-ingestion-policy-concurrency-" + UUID().uuidString, isDirectory: true)
        project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        store = try VelaStore(root: root.appendingPathComponent("store"))
        _ = try store.put("project", ["id": stableHash(project.path), "project": project.path, "path": project.path])
        service = IngestionExclusionService(store: store)
        service.relativeSourcePath = { path, _ in URL(fileURLWithPath: path).lastPathComponent }
    }

    override func tearDownWithError() throws {
        store = nil
        if let root, FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    private func sourcePath(_ suffix: String) -> String { root.appendingPathComponent("sources/\(suffix)").path }

    private func putDerived(_ id: String, source: String, provider: String = "codex") throws {
        _ = try store.putBatch([
            ("session", ["id": id, "project": project.path, "provider": provider, "sourcePath": source, "title": id, "content": "derived session"]),
            ("session_plan", ["id": id, "project": project.path, "title": "plan", "content": "derived plan"]),
            ("session_relation", ["id": id, "project": project.path, "title": "relation", "content": "derived relation"]),
            ("ingestion", ["id": stableHash(source), "project": project.path, "sourcePath": source, "title": "cursor", "content": "derived cursor"]),
        ])
    }

    private func saveCanonicalMemory() throws {
        _ = try store.put("memory", ["id": "memory-kept", "project": project.path, "scope": "project", "state": "active", "title": "Canonical memory", "content": "must survive policy withdrawal"])
    }

    private func call(_ method: String, _ fields: JSON) throws -> JSON {
        var params = fields
        params["project"] = project.path
        return try XCTUnwrap(try service.handle(method, params) as? JSON)
    }

    private func objectCount(_ kind: String) throws -> Int64 {
        let path = store.root.appendingPathComponent("vela.sqlite3").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let opened = try XCTUnwrap(db)
        defer { sqlite3_close(opened) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(opened, "SELECT count(*) FROM objects WHERE kind=? AND project=?", -1, &statement, nil), SQLITE_OK)
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }
        sqlite3_bind_text(prepared, 1, kind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(prepared, 2, project.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
        return sqlite3_column_int64(prepared, 0)
    }

    func testAdmissionSnapshotRejectsDerivedBatchAfterAnotherConnectionCommitsRule() throws {
        let writer = try VelaStore(root: store.root)
        let writerService = IngestionExclusionService(store: writer)
        let admitted = try service.admission(project: project.path, provider: "codex", relative: "regular.jsonl")
        XCTAssertFalse(admitted.excluded)
        XCTAssertTrue(admitted.expected.isEmpty)
        XCTAssertEqual(admitted.absent.map { $0.0 }, ["ingestion_policy_revision"])

        _ = try writerService.handle("ingestion.exclusions.upsert", ["project": project.path])
        XCTAssertThrowsError(try store.putBatch([
            ("session", ["id": "stale-derived", "project": project.path, "provider": "codex", "sourcePath": sourcePath("regular.jsonl")])
        ], expecting: admitted.expected, expectingAbsent: admitted.absent)) { error in
            XCTAssertTrue(error.localizedDescription.contains("new batch identity"))
        }
        XCTAssertNil(try store.get("session", "stale-derived"))
    }

    func testSourceRuleAndAllDerivedWithdrawalAreAtomicallyVisibleAcrossConnections() throws {
        let source = sourcePath("regular.jsonl")
        try putDerived("session-regular", source: source)
        try saveCanonicalMemory()
        // Open the observing connection before the writer transaction. VelaStore
        // initialization itself may issue schema DDL and must not be used as the
        // operation whose uncommitted view this test observes.
        let observer = try VelaStore(root: store.root)
        let entered = DispatchSemaphore(value: 0)
        let continueCommit = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result: Result<JSON, Error>?
        service.knownSource = { _, _, _ in true }
        // This hook is reached only after the rule and policy generation were
        // written inside BEGIN IMMEDIATE, before derived-session withdrawal.
        // A second VelaStore must still observe the prior committed snapshot.
        store.ingestionPolicyAfterRuleWriteForTesting = {
            entered.signal()
            guard continueCommit.wait(timeout: .now() + 2) == .success else {
                throw VelaError("Timed out while holding ingestion policy transaction")
            }
        }
        defer { store.ingestionPolicyAfterRuleWriteForTesting = nil }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let value = try self.call("ingestion.exclusions.upsert", ["provider": "codex", "pathGlob": "regular.jsonl"])
                resultLock.lock(); result = .success(value); resultLock.unlock()
            } catch {
                resultLock.lock(); result = .failure(error); resultLock.unlock()
            }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(try observer.list("ingestion_exclusion", project: project.path).isEmpty)
        for kind in ["session", "session_plan", "session_relation", "ingestion"] {
            XCTAssertNotNil(try observer.get(kind, kind == "ingestion" ? stableHash(source) : "session-regular"), kind)
        }
        continueCommit.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        resultLock.lock(); let finishedResult = result; resultLock.unlock()
        guard case let .success(value)? = finishedResult else { return XCTFail("Policy update unexpectedly failed") }
        XCTAssertEqual(intValue(value, "derivedSessionsRemoved"), 1)
        XCTAssertEqual(try observer.list("ingestion_exclusion", project: project.path).count, 1)
        for kind in ["session", "session_plan", "session_relation", "ingestion"] {
            XCTAssertNil(try observer.get(kind, kind == "ingestion" ? stableHash(source) : "session-regular"), kind)
        }
        XCTAssertNotNil(try observer.get("memory", "memory-kept"))
    }

    func testWithdrawalPagesPastTenThousandSessionsAndKeepsCanonicalMemory() throws {
        let total = 10_257
        var sessions: [(String, JSON)] = []
        sessions.reserveCapacity(total)
        for index in 0..<total {
            let id = String(format: "session-%05d", index)
            sessions.append(("session", ["id": id, "project": project.path, "provider": "claude", "sourcePath": sourcePath("bulk/\(id).jsonl"), "title": id, "content": "derived session"]))
        }
        _ = try store.putBatch(sessions)
        try saveCanonicalMemory()

        let result = try call("ingestion.exclusions.upsert", [:])
        XCTAssertEqual(intValue(result, "derivedSessionsRemoved"), total)
        XCTAssertEqual(try objectCount("session"), 0)
        XCTAssertEqual(try store.ingestionSourcePage(project: project.path).count, 0)
        XCTAssertNotNil(try store.get("memory", "memory-kept"))
    }

    func testPreCommitFailureRollsBackRuleRevisionAndAllDerivedDeletes() throws {
        let source = sourcePath("fault.jsonl")
        try putDerived("session-fault", source: source)
        try saveCanonicalMemory()
        store.ingestionPolicyBeforeCommitForTesting = { throw VelaError("injected policy pre-commit failure") }
        defer { store.ingestionPolicyBeforeCommitForTesting = nil }

        XCTAssertThrowsError(try service.handle("ingestion.exclusions.upsert", ["project": project.path])) { error in
            XCTAssertTrue(error.localizedDescription.contains("injected policy pre-commit failure"))
        }
        XCTAssertTrue(try store.list("ingestion_exclusion", project: project.path).isEmpty)
        XCTAssertNil(try store.get("ingestion_policy_revision", stableHash(project.path)))
        for kind in ["session", "session_plan", "session_relation", "ingestion"] {
            XCTAssertNotNil(try store.get(kind, kind == "ingestion" ? stableHash(source) : "session-fault"), kind)
        }
        XCTAssertNotNil(try store.get("memory", "memory-kept"))
    }
}
