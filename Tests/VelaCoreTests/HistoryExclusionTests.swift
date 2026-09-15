import XCTest
@testable import VelaCore

final class HistoryExclusionTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var logs: URL!
    private var store: VelaStore!
    private var history: SessionHistoryService!
    private var rules: IngestionExclusionService!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: canonicalProject(FileManager.default.temporaryDirectory.path)).appendingPathComponent("vela-history-exclusions-" + UUID().uuidString)
        project = base.appendingPathComponent("project"); logs = base.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs.appendingPathComponent("claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs.appendingPathComponent("pi"), withIntermediateDirectories: true)
        store = try VelaStore(root:base.appendingPathComponent("store"))
        _ = try store.put("project", ["id":stableHash(project.path), "project":project.path, "path":project.path])
        history = SessionHistoryService(store:store, roots:["claude":[logs.appendingPathComponent("claude")], "pi":[logs.appendingPathComponent("pi")]])
        rules = IngestionExclusionService(store:store)
        rules.knownSource = { [weak history] project, provider, glob in history?.hasKnownSource(project:project, provider:provider, glob:glob) ?? false }
    }

    override func tearDownWithError() throws { if let base { try FileManager.default.removeItem(at:base) } }

    private func call(_ method: String, _ params: JSON = [:]) throws -> JSON {
        var input = params; input["project"] = input["project"] ?? project.path
        guard let result = try history.handle(method, input) as? JSON else { throw VelaError("History method returned no object") }
        return result
    }
    private func writeClaude(_ name: String, text: String = "original") throws -> URL {
        let row: JSON = ["type":"user", "uuid":"u", "sessionId":"s", "cwd":project.path, "message":["role":"user", "content":text]]
        let path = logs.appendingPathComponent("claude").appendingPathComponent(name)
        try Data((try jsonString(row) + "\n").utf8).write(to:path)
        return path
    }
    private func discover(_ provider: String = "claude") throws -> JSON {
        var inventory = try call("history.discover", ["provider":provider])
        while string(inventory,"state") != "completed" { inventory = try call("history.discover", ["inventoryId":string(inventory,"id")]) }
        let page = try call("history.sources", ["inventoryId":string(inventory,"id")])
        return try XCTUnwrap((page["items"] as? [JSON])?.first)
    }
    private func exclude(_ provider: String, _ glob: String) throws {
        _ = try rules.handle("ingestion.exclusions.upsert", ["project":project.path, "provider":provider, "pathGlob":glob])
    }

    func testKnownSourceRechecksRegularIdentityInsteadOfCachedPath() throws {
        let path = try writeClaude("known.jsonl")
        XCTAssertTrue(history.hasKnownSource(project:project.path, provider:"claude", glob:"known.jsonl"))
        let target = base.appendingPathComponent("outside.jsonl")
        try FileManager.default.moveItem(at:path, to:target)
        try FileManager.default.createSymbolicLink(at:path, withDestinationURL:target)
        XCTAssertFalse(history.hasKnownSource(project:project.path, provider:"claude", glob:"known.jsonl"))
    }

    func testExcludedEpochBlocksMetadataStateAndRawEntrypoints() throws {
        try writeClaude("blocked.jsonl")
        let source = try discover()
        let epoch = try call("history.start", ["sourceId":string(source,"id")])
        XCTAssertEqual(string(try call("history.pause", ["id":string(epoch,"id")]), "state"), "paused")
        _ = try call("history.resume", ["id":string(epoch,"id")])
        try exclude("claude", "blocked.jsonl")
        for method in ["history.get", "history.pause", "history.resume", "history.cancel", "history.advance", "history.page", "history.raw"] {
            XCTAssertThrowsError(try call(method, ["id":string(epoch,"id")]), method)
        }
        XCTAssertTrue((try call("history.jobs")["items"] as? [JSON] ?? []).isEmpty)
        _ = try store.put("ingestion_exclusion", ["id":"pi-blocked", "project":project.path, "scope":"source", "provider":"pi", "pathGlob":"blocked-pi.jsonl"])
        let db = try SessionHistoryStore(store:store)
        try db.put("source", ["id":"pi-source", "project":project.path, "provider":"pi", "relativePath":"blocked-pi.jsonl"])
        try db.put("epoch", ["id":"pi-epoch", "project":project.path, "sourceId":"pi-source", "provider":"pi", "branchIntegrity":true])
        XCTAssertThrowsError(try call("history.branch", ["id":"pi-epoch"]))
    }

    func testExplicitRemovalRestoresExistingEpochWithoutReingestion() throws {
        let sourcePath = try writeClaude("restore.jsonl", text:"retained original")
        let source = try discover()
        var epoch = try call("history.start", ["sourceId":string(source,"id")])
        epoch = try call("history.advance", ["id":string(epoch,"id"), "batchRecords":2000])
        XCTAssertEqual(string(epoch,"state"), "completed")
        let before = try call("history.get", ["id":string(epoch,"id")])
        let beforePage = try call("history.page", ["id":string(epoch,"id")])
        let beforeRaw = try call("history.raw", ["id":string(epoch,"id"), "ordinal":0])
        let originalBytes = try Data(contentsOf:sourcePath)
        XCTAssertEqual(intValue(before,"records"),1)
        XCTAssertEqual((beforePage["items"] as? [JSON])?.count,1)
        XCTAssertEqual(Data(base64Encoded:string(beforeRaw,"dataBase64")),originalBytes)
        let saved = try rules.handle("ingestion.exclusions.upsert", ["project":project.path, "provider":"claude", "pathGlob":"restore.jsonl"]) as? JSON
        let ruleID = try XCTUnwrap(saved?["id"] as? String)
        XCTAssertThrowsError(try call("history.get", ["id":string(epoch,"id")]))
        XCTAssertThrowsError(try call("history.page", ["id":string(epoch,"id")]))
        XCTAssertThrowsError(try call("history.raw", ["id":string(epoch,"id"), "ordinal":0]))
        _ = try rules.handle("ingestion.exclusions.remove", ["project":project.path, "id":ruleID])
        let restored = try call("history.get", ["id":string(epoch,"id")])
        let restoredPage = try call("history.page", ["id":string(epoch,"id")])
        let restoredRaw = try call("history.raw", ["id":string(epoch,"id"), "ordinal":0])
        XCTAssertEqual(intValue(restored,"records"), intValue(before,"records"))
        XCTAssertEqual(try jsonString(restoredPage), try jsonString(beforePage))
        XCTAssertEqual(string(restoredRaw,"dataBase64"), string(beforeRaw,"dataBase64"))
        XCTAssertEqual(try Data(contentsOf:sourcePath), originalBytes)
    }

    func testFilteredSourceAndJobsPaginationScansPastMoreThanOneRawBatch() throws {
        let db = try SessionHistoryStore(store:store)
        let inventory: JSON = ["id":"inventory", "project":project.path, "state":"completed", "traversalComplete":true]
        try db.put("inventory", inventory)
        _ = try store.put("ingestion_exclusion", ["id":"blocked", "project":project.path, "scope":"source", "provider":"claude", "pathGlob":"blocked/*"])
        for index in 0..<1105 {
            let id = String(format:"%05d", index)
            try db.put("source", ["id":id, "project":project.path, "inventoryId":"inventory", "provider":"claude", "relativePath":"blocked/\(id).jsonl", "root":logs.appendingPathComponent("claude").path])
            try db.put("epoch", ["id":"epoch-\(id)", "project":project.path, "sourceId":id, "state":"pending"])
        }
        try db.put("source", ["id":"zz-visible", "project":project.path, "inventoryId":"inventory", "provider":"claude", "relativePath":"visible.jsonl", "root":logs.appendingPathComponent("claude").path])
        try db.put("epoch", ["id":"zz-visible", "project":project.path, "sourceId":"zz-visible", "state":"pending"])
        let sources = try call("history.sources", ["inventoryId":"inventory", "limit":100])
        XCTAssertEqual((sources["items"] as? [JSON])?.map { string($0,"id") }, ["zz-visible"])
        XCTAssertTrue(sources["nextAfterId"] is NSNull)
        let jobs = try call("history.jobs")
        XCTAssertEqual((jobs["items"] as? [JSON])?.map { string($0,"id") }, ["zz-visible"])
        XCTAssertTrue(jobs["nextAfterId"] is NSNull)
    }
}
