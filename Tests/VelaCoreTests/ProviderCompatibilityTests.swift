import XCTest
@testable import VelaCore

final class ProviderCompatibilityTests: XCTestCase {
    var root: URL!
    var project: URL!
    var logs: URL!
    var store: VelaStore!
    var service: FoundationService!
    let stamp = "2026-09-13T01:02:03.000Z"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: canonicalProject(FileManager.default.temporaryDirectory.path)).appendingPathComponent("vela-provider-compatibility-" + UUID().uuidString)
        project = root.appendingPathComponent("project"); logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sources = Dictionary(uniqueKeysWithValues: ["claude", "codex", "cursor", "pi", "omp"].map { ($0, [logs.appendingPathComponent($0)]) })
        for source in sources.values.flatMap({ $0 }) { try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true) }
        store = try VelaStore(root: root.appendingPathComponent("store"))
        service = FoundationService(store: store, sourceRoots: sources, globalHome: root.appendingPathComponent("home"))
    }
    override func tearDownWithError() throws {
        service?.stopWatching(); service = nil; store = nil
        if let root { try FileManager.default.removeItem(at: root) }
    }
    func header(_ version: Int = 3, id: String = "session-fixture") -> JSON {
        ["type": "session", "version": version, "id": id, "cwd": project.path, "timestamp": stamp]
    }
    func entry(_ id: String, parent: String? = nil, role: String = "user", content: Any = "Original 用户内容", extra: JSON = [:]) -> JSON {
        var message: JSON = ["role": role, "content": content, "timestamp": 1_789_261_323_000]
        message.merge(extra) { _, new in new }
        return ["type": "message", "id": id, "parentId": parent as Any? ?? NSNull(), "timestamp": stamp, "message": message]
    }
    func usage(_ input: Any = 10, _ output: Any = 5) -> JSON { ["input": input, "output": output, "cacheRead": 2, "cacheWrite": 3] }
    @discardableResult func write(_ provider: String, rows: [JSON], name: String = "fixture.jsonl") throws -> URL {
        let file = logs.appendingPathComponent(provider).appendingPathComponent(name)
        try Data((try rows.map { try jsonString($0) }.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file
    }
    func append(_ file: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }
    @discardableResult func refresh() throws -> JSON { try XCTUnwrap(service.handle("sessions.refresh", [:]) as? JSON) }
    func session(_ provider: String) throws -> JSON {
        let all = try XCTUnwrap(service.handle("sessions.list", ["project": project.path]) as? [JSON])
        let summary = try XCTUnwrap(all.first { string($0, "provider") == provider })
        return try XCTUnwrap(service.handle("sessions.get", ["id": string(summary, "id")]) as? JSON)
    }
    func messages(_ item: JSON) -> [JSON] { item["messages"] as? [JSON] ?? [] }

    func testPiAndOMPParseSourceIdentityToolsAndCompleteUsage() throws {
        for provider in ["pi", "omp"] {
            let call: JSON = ["type": "toolCall", "id": "call-one", "name": "read", "arguments": ["path": "原文's.swift"]]
            let rows = [header(id: provider + "-source"), entry("u"),
                        entry("a", parent: "u", role: "assistant", content: [["type": "text", "text": "Reading"], call], extra: ["model": "test-model", "provider": "test-provider", "stopReason": "toolUse", "usage": usage()]),
                        entry("r", parent: "a", role: "toolResult", content: [["type": "text", "text": "result 原文"]], extra: ["toolName": "read", "toolCallId": "call-one", "isError": true]),
                        entry("done", parent: "r", role: "assistant", content: "Done", extra: ["stopReason": "stop", "usage": usage(0, 0)])]
            let source = try write(provider, rows: rows); let before = try Data(contentsOf: source)
            _ = try refresh()
            let item = try session(provider)
            XCTAssertEqual(string(item, "sourceSessionId"), provider + "-source")
            XCTAssertEqual(string(item, "modelProvider"), "test-provider"); XCTAssertEqual(string(item, "model"), "test-model")
            XCTAssertEqual(item["sourceFormatVersion"] as? Int, 3); XCTAssertEqual(string(item, "state"), "Completed")
            XCTAssertEqual(item["liveStatusAvailable"] as? Bool, false); XCTAssertTrue(item["branch"] is NSNull)
            XCTAssertEqual(item["tokenInput"] as? Int, 20); XCTAssertEqual(item["tokenOutput"] as? Int, 5)
            XCTAssertEqual(item["usageAvailable"] as? Bool, true)
            let tools = messages(item).filter { string($0, "role") == "tool" }
            XCTAssertEqual(tools.count, 2); XCTAssertTrue(string(tools[0], "content").contains("原文's.swift"))
            XCTAssertEqual(string(tools[1], "toolCallId"), "call-one"); XCTAssertEqual(tools[1]["isError"] as? Bool, true)
            XCTAssertEqual(try Data(contentsOf: source), before)
        }
    }

    func testBranchSwitchExcludesAbandonedMessagesButCountsTheirObservedUsage() throws {
        let rows: [JSON] = [header(), entry("root"),
                           entry("old", parent: "root", role: "assistant", content: "ABANDONED BRANCH", extra: ["usage": usage(20, 10), "stopReason": "stop"]),
                           ["type": "branch_summary", "id": "summary", "parentId": "root", "timestamp": stamp, "summary": "Previous branch summary", "fromId": "old"],
                           entry("new", parent: "summary", role: "assistant", content: "SELECTED BRANCH", extra: ["usage": usage(30, 15), "stopReason": "stop"])]
        _ = try write("pi", rows: rows); _ = try refresh()
        let item = try session("pi")
        XCTAssertFalse(string(item, "content").contains("ABANDONED")); XCTAssertTrue(string(item, "content").contains("SELECTED"))
        XCTAssertTrue(string(item, "content").contains("Previous branch summary"))
        XCTAssertEqual(item["tokenInput"] as? Int, 60); XCTAssertEqual(item["tokenOutput"] as? Int, 25)
        XCTAssertEqual(string(item, "sourceLeafId"), "new"); XCTAssertEqual(item["branchAncestryComplete"] as? Bool, true)
        XCTAssertTrue(string(item, "branchSelectionSource").contains("in-memory"))
    }

    func testLegacyV1AndV2DoNotRewriteSourceAndPreserveHookMessages() throws {
        for version in [1, 2] {
            var first = entry("u"); var second = entry("h", parent: "u", role: "hookMessage", content: "Legacy hook context")
            if version == 1 { first.removeValue(forKey: "id"); first.removeValue(forKey: "parentId"); second.removeValue(forKey: "id"); second.removeValue(forKey: "parentId") }
            let source = try write("pi", rows: [header(version), first, second]); let before = try Data(contentsOf: source)
            _ = try refresh(); let item = try session("pi")
            XCTAssertEqual(item["sourceFormatVersion"] as? Int, version); XCTAssertEqual(messages(item).count, 2)
            XCTAssertEqual(string(messages(item)[1], "role"), "context"); XCTAssertEqual(try Data(contentsOf: source), before)
        }
    }

    func testOMPPhysicalTitleSlotAndSameLengthRenameRefresh() throws {
        let source = try write("omp", rows: [header(), entry("u")])
        let body = try Data(contentsOf: source)
        func slot(_ title: String) throws -> Data {
            let json = try jsonString(["type": "title", "title": title, "source": "user"])
            return Data((json + String(repeating: " ", count: 255 - json.utf8.count) + "\n").utf8)
        }
        try (slot("First title") + body).write(to: source); _ = try refresh()
        XCTAssertEqual(string(try session("omp"), "title"), "First title")
        try (slot("Other title") + body).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: source.path)
        _ = try refresh(); XCTAssertEqual(string(try session("omp"), "title"), "Other title")
    }

    func testPartialTailCompletesAndRotationReplacesOldMessages() throws {
        let source = try write("pi", rows: [header(), entry("u")])
        let next = try jsonString(entry("a", parent: "u", role: "assistant", content: "Finished", extra: ["stopReason": "stop", "usage": usage()]))
        try append(source, String(next.prefix(35))); _ = try refresh()
        XCTAssertEqual(messages(try session("pi")).count, 1); XCTAssertEqual(try session("pi")["historyFullyIndexed"] as? Bool, false)
        try append(source, String(next.dropFirst(35)) + "\n"); _ = try refresh()
        XCTAssertEqual(messages(try session("pi")).count, 2); XCTAssertEqual(try session("pi")["historyFullyIndexed"] as? Bool, true)
        _ = try write("pi", rows: [header(id: "replacement"), entry("new", content: "Replacement history")]); _ = try refresh()
        XCTAssertEqual(messages(try session("pi")).count, 1); XCTAssertFalse(string(try session("pi"), "content").contains("Finished"))
    }

    func testFutureVersionsAndDuplicateIDsRejectWithoutReplacingSnapshot() throws {
        _ = try write("omp", rows: [header(), entry("u")]); _ = try refresh()
        let original = try jsonString(try session("omp"))
        for rows in [[header(999), entry("future")], [header(), entry("same"), entry("same", content: "conflicting duplicate")]] {
            _ = try write("omp", rows: rows); let result = try refresh()
            XCTAssertFalse((result["diagnostics"] as? [JSON] ?? []).isEmpty)
            XCTAssertEqual(try jsonString(try session("omp")), original)
        }
    }

    func testUnknownMissingAndOverflowingUsageAreNeverInventedZero() throws {
        for invalid in [NSNull(), true, -1, 1.5, "10", 9_007_199_254_740_992] as [Any] {
            _ = try write("pi", rows: [header(), entry("a", role: "assistant", extra: ["usage": usage(invalid, 2)])]); _ = try refresh()
            let item = try session("pi"); XCTAssertTrue(item["tokenInput"] is NSNull); XCTAssertEqual(item["usageAvailable"] as? Bool, false)
        }
        _ = try write("pi", rows: [header(), entry("a", role: "assistant", extra: ["usage": usage(9_007_199_254_740_991, 0)])]); _ = try refresh()
        XCTAssertEqual(string(try session("pi"), "usageStatus"), "overflow")
        _ = try write("pi", rows: [header(), entry("a", role: "assistant")]); _ = try refresh()
        XCTAssertEqual(string(try session("pi"), "usageStatus"), "unavailable")
        _ = try write("pi", rows: [header(), entry("a", role: "assistant", extra: ["usage": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0]])]); _ = try refresh()
        XCTAssertEqual(try session("pi")["tokenInput"] as? Int, 0); XCTAssertEqual(try session("pi")["usageAvailable"] as? Bool, true)
    }

    func testBrokenAncestryAndUnknownEntriesCannotClaimFullCoverage() throws {
        _ = try write("pi", rows: [header(), entry("u", parent: "missing")]); _ = try refresh()
        XCTAssertEqual(try session("pi")["branchAncestryComplete"] as? Bool, false)
        XCTAssertEqual(try session("pi")["historyFullyIndexed"] as? Bool, false)
        let rows: [JSON] = [header(), entry("u"), ["type": "future_extension", "id": "x", "parentId": "u", "timestamp": stamp], entry("a", parent: "x", role: "assistant", extra: ["usage": usage()])]
        _ = try write("pi", rows: rows); _ = try refresh()
        let item = try session("pi"); XCTAssertEqual(messages(item).count, 2); XCTAssertTrue(item["tokenInput"] is NSNull)
        XCTAssertFalse((item["compatibilityWarnings"] as? [String] ?? []).isEmpty)
        let previous = try jsonString(item)
        _ = try write("pi", rows: [header(), entry("a", parent: "b"), entry("b", parent: "a")]); _ = try refresh()
        XCTAssertEqual(try jsonString(try session("pi")), previous)
    }

    func testLargePersistedTreeRetainsAncestorsBeyondOldTailWindow() throws {
        var rows = [header(), entry("root", content: "Root evidence")]
        for index in 0..<1200 { rows.append(entry("old-\(index)", parent: index == 0 ? "root" : "old-\(index-1)", content: String(repeating: "not current ", count: 25))) }
        rows.append(entry("new", parent: "root", content: "New branch"))
        let file = try write("pi", rows: rows)
        XCTAssertGreaterThan(try Data(contentsOf: file).count, 256 * 1024)
        _ = try refresh(); let item = try session("pi")
        XCTAssertEqual(messages(item).map { string($0, "id") }, ["root", "new"])
        XCTAssertEqual(item["sourceEntryCount"] as? Int, 1202); XCTAssertEqual(item["branchAncestryComplete"] as? Bool, true)
    }

    func testTranscriptRetentionDoesNotDropAllBranchUsageOrInventGitBranch() throws {
        var rows = [header()]
        for index in 0..<1005 { rows.append(entry("a-\(index)", parent: index == 0 ? nil : "a-\(index-1)", role: "assistant", content: "Response", extra: ["usage": usage(0, 1), "stopReason": "stop"])) }
        _ = try write("omp", rows: rows); _ = try refresh(); let item = try session("omp")
        XCTAssertEqual(messages(item).count, 1000); XCTAssertEqual(item["messagesTruncated"] as? Bool, true)
        XCTAssertEqual(item["tokenOutput"] as? Int, 1005); XCTAssertTrue(item["branch"] is NSNull)
    }

    func testFiveHarnessInventoryAndUnknownProviderIsNotCursor() throws {
        let list = try XCTUnwrap(service.handle("agents.list", [:]) as? [JSON])
        XCTAssertEqual(list.map { string($0, "id") }, ["claude", "codex", "cursor", "pi", "omp"])
        XCTAssertTrue(list.allSatisfy { $0["liveStatusAvailable"] as? Bool == false })
        let source = try write("pi", rows: [header(), entry("user")])
        let unknown = FoundationService(store: store, sourceRoots: ["future-agent": [source]], globalHome: root)
        let result = try XCTUnwrap(unknown.handle("sessions.refresh", [:]) as? JSON)
        XCTAssertFalse((result["diagnostics"] as? [JSON] ?? []).isEmpty)
        XCTAssertTrue(try XCTUnwrap(unknown.handle("sessions.list", [:]) as? [JSON]).isEmpty)
    }

    func testOnlyExplicitTerminalStatesAreClaimedAndNoPathsAreFollowed() throws {
        let states = ["stop": "Completed", "length": "Completed", "aborted": "Stopped", "error": "Error", "toolUse": "Unknown", "pending": "Unknown", "deferred": "Unknown", "future": "Unknown"]
        for (reason, expected) in states {
            var metadata = header(); metadata["parentSession"] = "/must/not/follow/private-history.jsonl"; metadata["additionalDirectories"] = ["/must/not/read"]
            _ = try write("omp", rows: [metadata, entry("a", role: "assistant", content: "State", extra: ["stopReason": reason])]); _ = try refresh()
            let item = try session("omp"); XCTAssertEqual(string(item, "state"), expected)
            XCTAssertEqual(string(item, "parentSession"), "/must/not/follow/private-history.jsonl")
            XCTAssertEqual(string(item, "project"), project.path); XCTAssertEqual(item["statusInferred"] as? Bool, false)
        }
    }

    func testSameSizeRewriteWithPreservedMtimeStillRefreshesTerminalState() throws {
        let preserved = Date(timeIntervalSince1970:1_700_000_000)
        for index in 0..<30 {
            let reason = index % 2 == 0 ? "future" : "length"
            let file = try write("omp",rows:[header(),entry("assistant",role:"assistant",content:"Stable size",extra:["stopReason":reason])])
            try FileManager.default.setAttributes([.modificationDate:preserved],ofItemAtPath:file.path)
            _ = try refresh()
            XCTAssertEqual(string(try session("omp"),"state"),reason == "length" ? "Completed" : "Unknown")
        }
    }

    func testSourceSizeAndRecordLimitsRejectWithoutMutatingOldSnapshot() throws {
        let file = try write("pi", rows: [header(), entry("u")]); _ = try refresh()
        let original = try jsonString(try session("pi"))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(PiSessionReader.maximumSourceBytes + 1)); try handle.close()
        var result = try refresh(); XCTAssertFalse((result["diagnostics"] as? [JSON] ?? []).isEmpty)
        XCTAssertEqual(try jsonString(try session("pi")), original)
        try Data(String(repeating: "x", count: PiSessionReader.maximumRecordBytes + 1).utf8).write(to: file)
        result = try refresh(); XCTAssertFalse((result["diagnostics"] as? [JSON] ?? []).isEmpty)
        XCTAssertEqual(try jsonString(try session("pi")), original)
    }

    func testPiFSEventsReadsAppendedEntryWithoutManualRefresh() throws {
        let file = try write("pi", rows: [header(), entry("u")]); _ = try refresh(); service.startWatching()
        try append(file, try jsonString(entry("next", parent: "u", content: "Observed live append")) + "\n")
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let item = try? session("pi"), messages(item).count == 2 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(messages(try session("pi")).count, 2)
        XCTAssertEqual(string(try session("pi"), "state"), "Unknown")
    }

    func testOMPDeveloperPythonAndFileMentionsRemainSourceContent() throws {
        let rows = [header(), entry("d", role: "developer", content: "Quoted developer instructions"),
                    entry("py", parent: "d", role: "pythonExecution", content: "", extra: ["code": "print(42)", "output": "42"]),
                    entry("f", parent: "py", role: "fileMention", content: "", extra: ["files": [["path": "/must/not/read/original.txt", "content": "Already in transcript"]]]),
                    entry("r", parent: "f", role: "toolResult", content: "Result", extra: ["toolCallId": "x", "toolName": "read"])]
        _ = try write("omp", rows: rows); _ = try refresh()
        let item = try session("omp"); let values = messages(item)
        XCTAssertEqual(values.map { string($0, "role") }, ["context", "tool", "context", "tool"])
        XCTAssertEqual(string(values[1], "tool"), "python"); XCTAssertTrue(string(values[1], "content").contains("print(42)"))
        XCTAssertTrue(string(values[2], "content").contains("Already in transcript")); XCTAssertTrue(values[3]["isError"] is NSNull)
        XCTAssertTrue((item["compatibilityWarnings"] as? [String] ?? []).isEmpty)
        _ = try write("omp", rows: [header(), entry("unknown", role: "notKnown", content: "Opaque role")]); _ = try refresh()
        XCTAssertFalse((try session("omp")["compatibilityWarnings"] as? [String] ?? []).isEmpty)
        XCTAssertEqual(try session("omp")["historyFullyIndexed"] as? Bool, false)
    }
}
