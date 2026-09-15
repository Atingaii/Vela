import XCTest
import CSQLite
import Dispatch
@testable import VelaCore

final class StoreMigrationTests: XCTestCase {
    private struct LogicalState: Equatable {
        let version: Int64
        let legacyContent: String
        let receipt: String
        let hasEmbeddings: Bool
        let hasProjectIndex: Bool
    }

    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = URL(fileURLWithPath: canonicalProject(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("vela-store-migration-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporary, FileManager.default.fileExists(atPath: temporary.path) {
            try FileManager.default.removeItem(at: temporary)
        }
    }

    private func database(_ root: URL) -> URL { root.appendingPathComponent("vela.sqlite3") }

    private func withRawDatabase<T>(_ root: URL, flags: Int32 = SQLITE_OPEN_READWRITE, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database(root).path, &db, flags, nil), SQLITE_OK)
        let opened = try XCTUnwrap(db)
        defer { sqlite3_close(opened) }
        return try body(opened)
    }

    private func rawExecute(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        defer { if let error { sqlite3_free(error) } }
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            throw VelaError(error.map { String(cString: $0) } ?? "SQLite fixture write failed")
        }
    }

    private func rawInt(_ root: URL, _ sql: String) throws -> Int64 {
        try withRawDatabase(root, flags: SQLITE_OPEN_READONLY) { db in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
            let prepared = try XCTUnwrap(statement)
            defer { sqlite3_finalize(prepared) }
            XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
            return sqlite3_column_int64(prepared, 0)
        }
    }

    private func rawString(_ root: URL, _ sql: String) throws -> String {
        try withRawDatabase(root, flags: SQLITE_OPEN_READONLY) { db in
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
            let prepared = try XCTUnwrap(statement)
            defer { sqlite3_finalize(prepared) }
            XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
            return String(cString: try XCTUnwrap(sqlite3_column_text(prepared, 0)))
        }
    }

    private func hasSchemaObject(_ root: URL, type: String, name: String) throws -> Bool {
        try rawInt(root, "SELECT count(*) FROM sqlite_master WHERE type='\(type)' AND name='\(name)'") == 1
    }

    private func createUnversionedLegacyStore(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try withRawDatabase(root, flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE) { db in
            try rawExecute(db, "CREATE TABLE objects(kind TEXT NOT NULL,id TEXT NOT NULL,project TEXT NOT NULL DEFAULT '',title TEXT NOT NULL DEFAULT '',content TEXT NOT NULL DEFAULT '',private INTEGER NOT NULL DEFAULT 0,updatedAt TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(kind,id))")
            try rawExecute(db, "INSERT INTO objects(kind,id,project,title,content,private,updatedAt,json) VALUES('memory','legacy-memory','/legacy/project','Legacy memory','preserved content',0,'2026-09-14T00:00:00Z','{\"id\":\"legacy-memory\",\"kind\":\"memory\",\"project\":\"/legacy/project\",\"title\":\"Legacy memory\",\"content\":\"preserved content\",\"private\":false,\"updatedAt\":\"2026-09-14T00:00:00Z\"}')")
            try rawExecute(db, "CREATE TABLE retained_receipts(id TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try rawExecute(db, "INSERT INTO retained_receipts(id,value) VALUES('receipt-1','preserve unrelated object')")
            try rawExecute(db, "PRAGMA user_version=0")
        }
    }

    // WAL uses sidecar files and checkpoints, so migration safety is checked via
    // committed schema/data values instead of volatile raw database file bytes.
    private func logicalState(_ root: URL) throws -> LogicalState {
        LogicalState(
            version: try rawInt(root, "PRAGMA user_version"),
            legacyContent: try rawString(root, "SELECT content FROM objects WHERE kind='memory' AND id='legacy-memory'"),
            receipt: try rawString(root, "SELECT value FROM retained_receipts WHERE id='receipt-1'"),
            hasEmbeddings: try hasSchemaObject(root, type: "table", name: "memory_embeddings"),
            hasProjectIndex: try hasSchemaObject(root, type: "index", name: "objects_project")
        )
    }

    private let migratedState = LogicalState(version: 1, legacyContent: "preserved content", receipt: "preserve unrelated object", hasEmbeddings: true, hasProjectIndex: true)

    func testUnversionedLegacyStoreMigratesAtomicallyAndReopens() throws {
        let root = temporary.appendingPathComponent("legacy-store")
        try createUnversionedLegacyStore(root)
        XCTAssertEqual(try rawInt(root, "PRAGMA user_version"), 0)

        let migrated = try VelaStore(root: root)
        XCTAssertEqual(try migrated.get("memory", "legacy-memory")?["content"] as? String, "preserved content")
        XCTAssertEqual(try logicalState(root), migratedState)

        let reopened = try VelaStore(root: root)
        XCTAssertEqual(try reopened.get("memory", "legacy-memory")?["title"] as? String, "Legacy memory")
        XCTAssertEqual(try rawInt(root, "SELECT count(*) FROM session_change_counter"), 1)
    }

    func testCurrentStoreUsesRecordedVersionAndReopensWithoutMigrationFault() throws {
        let root = temporary.appendingPathComponent("current-store")
        let first = try VelaStore(root: root)
        _ = try first.put("guideline", ["id": "g", "title": "Current", "content": "unchanged", "project": "/current"])
        XCTAssertEqual(try rawInt(root, "PRAGMA user_version"), 1)

        // The seam is only consulted while a lower version is being migrated.
        let reopened = try VelaStore(root: root, schemaMigrationFailureAfterStepForTesting: 1)
        XCTAssertEqual(try reopened.get("guideline", "g")?["content"] as? String, "unchanged")
        XCTAssertEqual(try rawInt(root, "PRAGMA user_version"), 1)
    }

    func testFutureVersionRefusesBeforeSchemaOrDataWrites() throws {
        let root = temporary.appendingPathComponent("future-store")
        try createUnversionedLegacyStore(root)
        try withRawDatabase(root) { db in try rawExecute(db, "PRAGMA user_version=2") }
        let before = try logicalState(root)

        XCTAssertThrowsError(try VelaStore(root: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("newer than this helper supports"))
        }

        XCTAssertEqual(try logicalState(root), before)
        XCTAssertFalse(try hasSchemaObject(root, type: "table", name: "memory_embeddings"))
    }

    func testNegativeVersionRefusesBeforeSchemaRepair() throws {
        let root = temporary.appendingPathComponent("negative-store")
        try createUnversionedLegacyStore(root)
        try withRawDatabase(root) { db in try rawExecute(db, "PRAGMA user_version=-1") }

        XCTAssertThrowsError(try VelaStore(root: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("schema version is invalid"))
        }
        XCTAssertEqual(try rawInt(root, "PRAGMA user_version"), -1)
        XCTAssertFalse(try hasSchemaObject(root, type: "table", name: "memory_embeddings"))
    }

    func testRecordedCurrentVersionWithMissingCanonicalSchemaRefusesWithoutRepair() throws {
        let root = temporary.appendingPathComponent("broken-current-store")
        try createUnversionedLegacyStore(root)
        try withRawDatabase(root) { db in try rawExecute(db, "PRAGMA user_version=1") }

        XCTAssertThrowsError(try VelaStore(root: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("incomplete or corrupt"))
        }
        XCTAssertEqual(try rawInt(root, "PRAGMA user_version"), 1)
        XCTAssertFalse(try hasSchemaObject(root, type: "table", name: "memory_embeddings"))
        XCTAssertEqual(try rawString(root, "SELECT content FROM objects WHERE kind='memory' AND id='legacy-memory'"), "preserved content")
    }

    func testConcurrentFutureVersionCommitIsRereadUnderMigrationWriteLock() throws {
        let root = temporary.appendingPathComponent("concurrent-store")
        try createUnversionedLegacyStore(root)
        let reachedWriteLock = DispatchSemaphore(value: 0)
        let allowWriteLock = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result: Result<Void, Error>?

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try VelaStore(root: root, schemaMigrationFailureAfterStepForTesting: nil, schemaMigrationBeforeWriteLockHookForTesting: {
                    reachedWriteLock.signal()
                    _ = allowWriteLock.wait(timeout: .now() + 2)
                })
                resultLock.lock(); result = .success(()); resultLock.unlock()
            } catch {
                resultLock.lock(); result = .failure(error); resultLock.unlock()
            }
            completed.signal()
        }
        XCTAssertEqual(reachedWriteLock.wait(timeout: .now() + 2), .success)
        try withRawDatabase(root) { db in
            try rawExecute(db, "BEGIN IMMEDIATE")
            try rawExecute(db, "PRAGMA user_version=2")
            try rawExecute(db, "COMMIT")
        }
        allowWriteLock.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        resultLock.lock(); let finished = result; resultLock.unlock()
        guard case let .failure(error)? = finished else { return XCTFail("Older helper unexpectedly opened a concurrently upgraded store") }
        XCTAssertTrue(error.localizedDescription.contains("newer than this helper supports"))
        XCTAssertEqual(try rawInt(root, "PRAGMA user_version"), 2)
        XCTAssertFalse(try hasSchemaObject(root, type: "table", name: "memory_embeddings"))
    }

    func testHalfMigrationFailureRollsBackAndRetryPreservesLegacyData() throws {
        let root = temporary.appendingPathComponent("retry-store")
        try createUnversionedLegacyStore(root)
        let before = try logicalState(root)

        XCTAssertThrowsError(try VelaStore(root: root, schemaMigrationFailureAfterStepForTesting: 3)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Injected schema migration failure"))
        }
        XCTAssertEqual(try logicalState(root), before)
        XCTAssertFalse(try hasSchemaObject(root, type: "table", name: "memory_embeddings"))
        XCTAssertFalse(try hasSchemaObject(root, type: "index", name: "objects_project"))

        let retried = try VelaStore(root: root)
        XCTAssertEqual(try retried.get("memory", "legacy-memory")?["content"] as? String, "preserved content")
        XCTAssertEqual(try logicalState(root), migratedState)
    }
}
