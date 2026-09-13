import XCTest
import CryptoKit
@testable import VelaCore

final class SessionHistoryTests: XCTestCase {
    var root: URL!, project: URL!, logs: URL!, store: VelaStore!, service: FoundationService!
    var roots: [String: [URL]] = [:]
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: canonicalProject(FileManager.default.temporaryDirectory.path)).appendingPathComponent("vela-history-tests-" + UUID().uuidString)
        project = root.appendingPathComponent("project"); logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        roots = Dictionary(uniqueKeysWithValues: ["claude", "codex", "pi", "omp", "cursor"].map { ($0, [logs.appendingPathComponent($0)]) })
        for directory in roots.values.flatMap({ $0 }) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        store = try VelaStore(root: root.appendingPathComponent("store")); service = FoundationService(store: store, sourceRoots: roots, globalHome: root)
        _ = try service.handle("projects.add", ["path": project.path])
    }
    override func tearDownWithError() throws {
        service?.stopWatching(); service = nil; store = nil
        if let root { try FileManager.default.removeItem(at: root) }
    }
    func call(_ method: String, _ params: JSON = [:]) throws -> JSON {
        var input = params; input["project"] = input["project"] ?? project.path
        return try XCTUnwrap(service.handle(method, input) as? JSON)
    }
    func claude(_ id: String, _ text: String = "original 内容", cwd: String? = nil, timestamp: String? = nil) -> JSON {
        var row: JSON = ["type": "user", "uuid": id, "sessionId": "synthetic-history", "message": ["role": "user", "content": text]]
        if let cwd { row["cwd"] = cwd }; if let timestamp { row["timestamp"] = timestamp }; return row
    }
    @discardableResult func write(_ rows: [JSON], name: String = "fixture.jsonl", newline: Bool = true) throws -> URL { try write("claude", rows, name: name, newline: newline) }
    @discardableResult func write(_ provider: String, _ rows: [JSON], name: String = "fixture.jsonl", newline: Bool = true) throws -> URL {
        let path = logs.appendingPathComponent(provider).appendingPathComponent(name)
        try Data((try rows.map { try jsonString($0) }.joined(separator: "\n") + (newline ? "\n" : "")).utf8).write(to: path)
        return path
    }
    func discover(_ provider: String = "claude", limit: Int = 64) throws -> (JSON, [JSON]) {
        var inventory = try call("history.discover", ["provider": provider, "limit": limit]), calls = 1
        while string(inventory, "state") != "completed" {
            guard calls < 1000 else { throw VelaError("Discovery did not progress") }
            inventory = try call("history.discover", ["inventoryId": string(inventory, "id"), "limit": limit]); calls += 1
        }
        var rows: [JSON] = [], after = ""
        repeat {
            let page = try call("history.sources", ["inventoryId": string(inventory, "id"), "limit": 20, "afterId": after])
            rows += page["items"] as? [JSON] ?? []; after = string(page, "nextAfterId")
        } while !after.isEmpty
        return (inventory, rows)
    }
    func start(_ provider: String = "claude") throws -> JSON {
        let source = try XCTUnwrap(discover(provider).1.first)
        return try call("history.start", ["sourceId": string(source, "id")])
    }
    func finish(_ source: JSON, batchBytes: Int = 4 * 1024 * 1024, batchRecords: Int = 2000) throws -> JSON {
        var epoch = source, calls = 0
        while string(epoch, "state") == "pending" {
            guard calls < 10000 else { throw VelaError("Import did not progress") }
            epoch = try call("history.advance", ["id": string(epoch, "id"), "batchBytes": batchBytes, "batchRecords": batchRecords]); calls += 1
        }
        return epoch
    }
    func allRows(_ epoch: JSON, limit: Int = 100) throws -> [JSON] {
        var rows: [JSON] = [], cursor = ""
        repeat {
            let page = try call("history.page", ["id": string(epoch, "id"), "cursor": cursor, "limit": limit])
            rows += page["items"] as? [JSON] ?? []; cursor = string(page, "nextCursor")
        } while !cursor.isEmpty
        return rows
    }
    func original(_ epoch: JSON, ordinal: Int) throws -> Data {
        var data = Data(), part = 0
        while true {
            let chunk = try call("history.raw", ["id": string(epoch, "id"), "ordinal": ordinal, "part": part])
            data.append(try XCTUnwrap(Data(base64Encoded: string(chunk, "dataBase64"))))
            if chunk["nextPart"] is NSNull { return data }; part = intValue(chunk, "nextPart")
        }
    }

    func testExplicitDiscoveryIncludesMoreThanSixtySourcesAndDoesNotChangeDashboard() throws {
        for index in 0..<73 { try write([claude("u", cwd: project.path)], name: String(format: "%03d.jsonl", index)) }
        let (inventory, sources) = try discover(limit: 7)
        XCTAssertEqual(sources.count, 73); XCTAssertEqual(inventory["traversalComplete"] as? Bool, true)
        XCTAssertEqual(Set(sources.map { string($0, "id") }).count, 73)
        XCTAssertEqual((try store.list("session")).count, 0)
        XCTAssertEqual((try call("dashboard.get")["sessions"] as? [JSON])?.count, 0)
    }
    func testDeepHistoryAndLongOriginalSurviveOldMessageAndByteCaps() throws {
        let long = String(repeating: "原文🙂", count: 50_000)
        var rows = [claude("header", cwd: project.path), claude("first", long)]
        for index in 0..<1205 { rows.append(claude("m-\(index)", "item \(index)")) }
        try write(rows)
        let epoch = try finish(start(), batchBytes: 64 * 1024, batchRecords: 37)
        XCTAssertEqual(string(epoch, "state"), "completed"); XCTAssertEqual(epoch["rawBytesComplete"] as? Bool, true)
        XCTAssertEqual(epoch["normalizationComplete"] as? Bool, true)
        let events = try allRows(epoch, limit: 43)
        XCTAssertEqual(events.count, 1207); XCTAssertEqual(events.map { intValue($0, "ordinal") }, Array(0..<1207))
        XCTAssertLessThanOrEqual(string(events[1], "preview").utf8.count, 4096)
        let raw = try original(epoch, ordinal: 1)
        XCTAssertEqual(raw, Data((try jsonString(rows[1]) + "\n").utf8))
        XCTAssertEqual(string(events[1], "rawSHA256"), SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined())
    }
    func testMidRecordRestartUsesAtomicByteCheckpointAndDoesNotDuplicate() throws {
        let row = claude("long", String(repeating: "é🙂", count: 10000), cwd: project.path)
        try write([claude("header", cwd: project.path), row, claude("tail")])
        var epoch = try start()
        epoch = try call("history.advance", ["id": string(epoch, "id"), "batchBytes": 777])
        XCTAssertEqual(epoch["offset"] as? Int, 777); XCTAssertEqual(epoch["records"] as? Int, 1)
        service = nil; store = try VelaStore(root: root.appendingPathComponent("store")); service = FoundationService(store: store, sourceRoots: roots, globalHome: root)
        epoch = try finish(call("history.get", ["id": string(epoch, "id")]), batchBytes: 997)
        XCTAssertEqual((try allRows(epoch)).count, 3)
        XCTAssertEqual(try original(epoch, ordinal: 1), Data((try jsonString(row) + "\n").utf8))
        XCTAssertEqual(try jsonString(finish(epoch)), try jsonString(epoch))
    }
    func testSourceMutationMarksUnfinishedEpochStaleAndPreservesCompletedEpochCursor() throws {
        let file = try write([claude("a", "AAAA", cwd: project.path), claude("b")])
        let originalSource = try XCTUnwrap(discover().1.first)
        var pending = try call("history.start", ["sourceId": string(originalSource, "id")])
        pending = try call("history.advance", ["id": string(pending, "id"), "batchRecords": 1])
        try write([claude("a", "BBBB", cwd: project.path), claude("b")])
        let stale = try finish(pending); XCTAssertEqual(string(stale, "state"), "stale"); XCTAssertEqual(stale["records"] as? Int, 1)
        let newer = try finish(call("history.start", ["sourceId": string(originalSource, "id")]))
        XCTAssertNotEqual(string(newer, "id"), string(stale, "id"))
        let first = try call("history.page", ["id": string(newer, "id"), "limit": 1]); let cursor = string(first, "nextCursor")
        try FileManager.default.removeItem(at: file)
        let tail = try call("history.page", ["id": string(newer, "id"), "cursor": cursor])
        XCTAssertEqual((tail["items"] as? [JSON])?.count, 1)
        XCTAssertThrowsError(try call("history.page", ["id": string(stale, "id"), "cursor": cursor]))
    }
    func testDuplicateMessageIDsAndOutOfOrderTimestampsKeepPhysicalEvidence() throws {
        try write([claude("same", "earlier", cwd: project.path, timestamp: "2026-09-13T03:00:00Z"), claude("same", "later revision", timestamp: "2020-01-01T00:00:00Z"), claude("no-time")])
        let epoch = try finish(start()), rows = try allRows(epoch)
        XCTAssertEqual(rows.count, 3); XCTAssertEqual(rows[1]["previousSameProviderIdOrdinal"] as? Int, 0)
        XCTAssertTrue(rows[2]["timestamp"] is NSNull)
        let reverse = try call("history.page", ["id": string(epoch, "id"), "direction": "backward"])
        XCTAssertEqual((reverse["items"] as? [JSON] ?? []).map { intValue($0, "ordinal") }, [2, 1, 0])
    }
    func testPauseResumeCancelArePersistentAndDoNotPerformWork() throws {
        try write([claude("a", cwd: project.path), claude("b")]); let epoch = try start(), id = string(epoch, "id")
        _ = try call("history.pause", ["id": id]); XCTAssertEqual(string(try call("history.advance", ["id": id]), "state"), "paused")
        _ = try call("history.resume", ["id": id]); _ = try call("history.cancel", ["id": id])
        let cancelled = try call("history.advance", ["id": id]); XCTAssertEqual(string(cancelled, "state"), "cancelled"); XCTAssertEqual(cancelled["offset"] as? Int, 0)
        XCTAssertEqual(string(try call("history.resume", ["id": id]), "state"), "pending")
        XCTAssertEqual(string(try finish(call("history.get", ["id": id])), "state"), "completed")
    }
    func testCrossProjectRecordsAndOriginalsNeverEnterSelectedProjectPages() throws {
        let foreign = root.appendingPathComponent("foreign").path
        try write([claude("a", cwd: project.path), claude("foreign", "FOREIGN_SENTINEL", cwd: foreign), claude("inherits", "FOREIGN_SENTINEL_2"), claude("back", cwd: project.path)])
        let epoch = try finish(start()), rows = try allRows(epoch)
        XCTAssertEqual(rows.map { intValue($0, "ordinal") }, [0, 3]); XCTAssertEqual(epoch["excludedRecords"] as? Int, 2)
        XCTAssertEqual(epoch["projectScopeComplete"] as? Bool, false)
        XCTAssertThrowsError(try call("history.raw", ["id": string(epoch, "id"), "ordinal": 1]))
        XCTAssertThrowsError(try call("history.page", ["id": string(epoch, "id"), "project": foreign]))
    }
    func testPiAndOMPKeepAllBranchesAndPageExplicitAncestry() throws {
        for provider in ["pi", "omp"] {
            func entry(_ id: String, _ parent: Any = NSNull()) -> JSON { ["type": "message", "id": id, "parentId": parent, "message": ["role": "user", "content": id]] }
            try write(provider, [["type": "session", "version": 3, "id": "source", "cwd": project.path], entry("root"), entry("abandoned", "root"), entry("new", "root"), entry("leaf", "new")])
            let epoch = try finish(start(provider), batchRecords: 1)
            XCTAssertEqual((try allRows(epoch)).count, 5)
            let first = try call("history.branch", ["id": string(epoch, "id"), "limit": 2])
            XCTAssertEqual((first["items"] as? [JSON] ?? []).map { string($0, "providerId") }, ["leaf", "new"])
            let next = try call("history.branch", ["id": string(epoch, "id"), "cursor": string(first, "nextCursor")])
            XCTAssertEqual((next["items"] as? [JSON] ?? []).map { string($0, "providerId") }, ["root"])
            let old = try call("history.branch", ["id": string(epoch, "id"), "leafId": "abandoned"])
            XCTAssertEqual((old["items"] as? [JSON] ?? []).map { string($0, "providerId") }, ["abandoned", "root"])
        }
    }
    func testPiBrokenOrDuplicateIdentityCannotClaimBranchIntegrity() throws {
        for entries: [JSON] in [
            [["type": "message", "id": "x", "parentId": "missing", "message": ["role": "user", "content": "orphan"]]],
            [["type": "message", "id": "x", "parentId": NSNull(), "message": ["role": "user", "content": "first"]], ["type": "message", "id": "x", "parentId": NSNull(), "message": ["role": "user", "content": "second"]]]
        ] {
            try write("pi", [["type": "session", "version": 3, "id": "source", "cwd": project.path]] + entries)
            let epoch = try finish(start("pi")); XCTAssertEqual(epoch["branchIntegrity"] as? Bool, false)
            XCTAssertThrowsError(try call("history.branch", ["id": string(epoch, "id")]))
        }
    }
    func testCodexToolsUsageAndUnknownEventsHaveOriginalSourceReferences() throws {
        let rows: [JSON] = [["type": "session_meta", "payload": ["id": "codex-source", "cwd": project.path]],
            ["type": "response_item", "payload": ["type": "function_call", "call_id": "c", "name": "read", "arguments": "{}"]],
            ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c", "output": "tool result"]],
            ["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 0, "output_tokens": 3]]]],
            ["type": "future_extension", "payload": ["text": "unrecognized"]]]
        try write("codex", rows); let epoch = try finish(start("codex")), events = try allRows(epoch)
        XCTAssertEqual(events.map { string($0, "type") }, ["context", "tool_call", "tool_result", "usage", "unknown"])
        XCTAssertEqual((events[3]["usage"] as? JSON)?["input_tokens"] as? Int, 0)
        XCTAssertTrue((events[3]["usage"] as? JSON)?["cached_input_tokens"] is NSNull)
        XCTAssertEqual(epoch["rawBytesComplete"] as? Bool, true); XCTAssertEqual(epoch["normalizationComplete"] as? Bool, false)
    }
    func testMalformedTailResetsScopeAndSeparatesRawCoverage() throws {
        let file = try write([claude("a", cwd: project.path)])
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken\n".utf8)); try handle.write(contentsOf: Data((try jsonString(claude("unknown-scope"))).utf8)); try handle.close()
        let epoch = try finish(start())
        XCTAssertEqual(epoch["records"] as? Int, 3); XCTAssertEqual((try allRows(epoch)).count, 1)
        XCTAssertEqual(epoch["rawBytesComplete"] as? Bool, true); XCTAssertEqual(epoch["normalizationComplete"] as? Bool, false)
        XCTAssertEqual(epoch["projectScopeComplete"] as? Bool, false)
    }
    func testSymlinkAndUnknownHeaderAreExcludedAndNoArbitraryPathAPIsExist() throws {
        let external = root.appendingPathComponent("external.jsonl")
        try Data((try jsonString(claude("external", cwd: project.path)) + "\n").utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("claude/link.jsonl"), withDestinationURL: external)
        try write("pi", [["type": "session", "version": 999, "id": "future", "cwd": project.path]])
        XCTAssertEqual(try discover().1.count, 0); XCTAssertEqual(try discover("pi").1.count, 0)
        XCTAssertThrowsError(try call("history.start", ["path": external.path]))
        try write([claude("real", cwd: project.path)]); let epoch = try start()
        let original = logs.appendingPathComponent("claude/fixture.jsonl"); try FileManager.default.removeItem(at: original); try FileManager.default.createSymbolicLink(at: original, withDestinationURL: external)
        XCTAssertEqual(string(try finish(epoch), "state"), "stale")
    }
    func testConcurrentIndependentServicesCommitEachRecordOnce() throws {
        try write((0..<180).map { claude("m-\($0)", cwd: $0 == 0 ? project.path : nil) })
        let epoch = try start(), id = string(epoch, "id")
        let services = (0..<8).map { _ in FoundationService(store: store, sourceRoots: roots, globalHome: root) }
        let group = DispatchGroup(), mutex = NSLock(); var failures: [String] = []
        for peer in services {
            group.enter(); DispatchQueue.global().async {
                defer { group.leave() }
                do { for _ in 0..<4 { _ = try peer.handle("history.advance", ["project": self.project.path, "id": id, "batchRecords": 10]) } }
                catch { mutex.lock(); failures.append(error.localizedDescription); mutex.unlock() }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success); XCTAssertTrue(failures.isEmpty)
        let final = try call("history.get", ["id": id]); XCTAssertEqual(string(final, "state"), "completed")
        XCTAssertEqual((try allRows(final)).map { intValue($0, "ordinal") }, Array(0..<180))
    }
    func testBudgetsAndCursorBindingsRejectInvalidInput() throws {
        try write([claude("a", cwd: project.path), claude("b")]); let source = try XCTUnwrap(discover().1.first)
        XCTAssertThrowsError(try call("history.start", ["sourceId": string(source, "id"), "maxBytes": 1]))
        let epoch = try finish(start()), first = try call("history.page", ["id": string(epoch, "id"), "limit": 1])
        for invalid: Any in [true, 1.5, -1, 101] { XCTAssertThrowsError(try call("history.page", ["id": string(epoch, "id"), "limit": invalid])) }
        XCTAssertThrowsError(try call("history.page", ["id": string(epoch, "id"), "cursor": string(first, "nextCursor"), "direction": "backward"]))
        XCTAssertThrowsError(try call("history.advance", ["id": string(epoch, "id"), "batchBytes": false]))
        XCTAssertThrowsError(try call("history.page", ["id": string(epoch, "id"), "cursor": false]))
    }
    func testOversizeRecordIsRetainedWithExplicitScopeAndNormalizationFailure() throws {
        let huge = String(repeating: "x", count: SessionHistoryDecoder.maximumRecordBytes + 17)
        try write([claude("header", cwd: project.path), claude("oversize", huge), claude("unknown-scope"), claude("restored", cwd: project.path)])
        let epoch = try finish(start())
        XCTAssertEqual(epoch["rawBytesComplete"] as? Bool, true); XCTAssertEqual(epoch["normalizationComplete"] as? Bool, false)
        XCTAssertEqual(epoch["invalidRecords"] as? Int, 1); XCTAssertEqual(epoch["excludedRecords"] as? Int, 2)
        XCTAssertEqual((try allRows(epoch)).map { intValue($0, "ordinal") }, [0, 3])
        XCTAssertThrowsError(try call("history.raw", ["id": string(epoch, "id"), "ordinal": 1]))
    }
    func testUnknownPiRolesDuplicateHeadersAndOversizeHeaderProbeNeverClaimCompatibility() throws {
        try write([claude("long-first", String(repeating: "x", count: 70000), cwd: project.path)])
        let (inventory, sources) = try discover(); XCTAssertTrue(sources.isEmpty); XCTAssertEqual(inventory["unavailableSources"] as? Int, 1)
        let header: JSON = ["type": "session", "version": 3, "id": "synthetic", "cwd": project.path]
        try write("pi", [header, ["type": "message", "id": "future", "parentId": NSNull(), "message": ["role": "future-role", "content": "unknown"]]])
        var epoch = try finish(start("pi")); XCTAssertEqual(epoch["normalizationComplete"] as? Bool, false)
        try write("pi", [header, header])
        epoch = try finish(start("pi")); XCTAssertEqual(epoch["normalizationComplete"] as? Bool, false); XCTAssertEqual(epoch["branchIntegrity"] as? Bool, false)
    }
}
