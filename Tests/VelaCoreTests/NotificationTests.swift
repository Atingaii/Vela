import XCTest
@testable import VelaCore

final class NotificationTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func snapshot(_ fields: JSON = [:], settings: JSON = ["notifications": true]) -> JSON {
        var value = fields
        value["notificationScope"] = "*"
        value["settings"] = settings
        return value
    }
    private func record(_ id: String, _ state: String, time: Date? = nil) -> JSON {
        ["id": id, "state": state, "title": "Synthetic task", "project": "/synthetic/project",
         "createdAt": ISO8601DateFormatter().string(from: time ?? epoch)]
    }

    func testEachCollectionEstablishesItsOwnQuietBaseline() {
        var policy = VelaNotificationPolicy()
        XCTAssertTrue(policy.events(from: snapshot(["sessions": [record("s", "Running")]]), now: epoch).isEmpty)
        XCTAssertTrue(policy.events(from: snapshot(["approvals": [record("old", "pending")]]), now: epoch).isEmpty)
        XCTAssertTrue(policy.events(from: snapshot(["runs": [record("r", "completed")]]), now: epoch).isEmpty)
        let events = policy.events(from: snapshot(["sessions": [record("s", "Completed")]]), now: epoch)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .completed)
        XCTAssertEqual(events.first?.inferred, true)
        XCTAssertTrue(policy.events(from: snapshot(["sessions": [record("s", "Completed")]]), now: epoch).isEmpty)
    }

    func testFilteredSnapshotsCannotResetGlobalNotificationState() {
        var policy = VelaNotificationPolicy()
        _ = policy.events(from: snapshot(["sessions": [record("s", "Running")]]), now: epoch)
        var filtered = snapshot(["sessions": [record("s", "Error")]])
        filtered["notificationScope"] = "/synthetic/project"
        XCTAssertTrue(policy.events(from: filtered, now: epoch).isEmpty)
        XCTAssertEqual(policy.events(from: snapshot(["sessions": [record("s", "Error")]]), now: epoch).first?.kind, .error)
    }

    func testMutedTransitionsAreConsumedWithoutRetroactiveAlerts() {
        var policy = VelaNotificationPolicy()
        _ = policy.events(from: snapshot(["sessions": [record("s", "Running")]]), now: epoch)
        let completed: JSON = ["sessions": [record("s", "Completed")]]
        XCTAssertTrue(policy.events(from: snapshot(completed, settings: ["notifications": false]), now: epoch).isEmpty)
        XCTAssertTrue(policy.events(from: snapshot(completed), now: epoch).isEmpty)
        XCTAssertTrue(policy.events(from: snapshot(["sessions": [record("s", "Error")]], settings: ["notifications": true, "notifyErrors": false]), now: epoch).isEmpty)
        XCTAssertTrue(policy.events(from: snapshot(["sessions": [record("s", "Error")]]), now: epoch).isEmpty)
    }

    func testFreshApprovalOnlyAndWorkflowDoesNotNotifyTwice() {
        var policy = VelaNotificationPolicy()
        _ = policy.events(from: snapshot(["runs": [record("r", "running")], "approvals": []]), now: epoch)
        let later = epoch.addingTimeInterval(1)
        let events = policy.events(from: snapshot([
            "runs": [record("r", "pending_approval")],
            "approvals": [record("historical", "pending", time: epoch.addingTimeInterval(-60)), record("fresh", "pending", time: later)]
        ]), now: later)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .approval)
        XCTAssertEqual(events.first?.recordID, "fresh")
        XCTAssertEqual(events.first?.count, 1)
        XCTAssertEqual(events.first?.inferred, false)
    }

    func testHistoricalImportsAndRoutineStatesRemainQuiet() {
        var policy = VelaNotificationPolicy()
        _ = policy.events(from: snapshot(["sessions": [record("live", "Running")]]), now: epoch)
        for state in ["Idle", "Running", "Stopped", "Unknown", "tool_call"] {
            XCTAssertTrue(policy.events(from: snapshot(["sessions": [record("live", state), record("historical", "Completed")]]), now: epoch).isEmpty)
        }
        XCTAssertEqual(policy.events(from: snapshot(["sessions": [record("live", "Needs Approval")]]), now: epoch).first?.kind, .approval)
    }

    func testApprovalCreatedInBaselineSecondIsNotLost() {
        var policy = VelaNotificationPolicy()
        _ = policy.events(from: snapshot(["approvals": []]), now: epoch.addingTimeInterval(0.1))
        let events = policy.events(from: snapshot(["approvals": [record("same-second", "pending")]]), now: epoch.addingTimeInterval(0.9))
        XCTAssertEqual(events.first?.recordID, "same-second")
    }

    func testEvictedApprovalDoesNotNotifyAgainOnReappearance() {
        var policy = VelaNotificationPolicy()
        _ = policy.events(from: snapshot(["approvals": []]), now: epoch)
        let first = record("original", "pending", time: epoch.addingTimeInterval(1))
        XCTAssertEqual(policy.events(from: snapshot(["approvals": [first]]), now: epoch.addingTimeInterval(1)).count, 1)
        let later = (0..<2048).map { record("new-\($0)", "pending", time: epoch.addingTimeInterval(2)) }
        XCTAssertEqual(policy.events(from: snapshot(["approvals": later]), now: epoch.addingTimeInterval(2)).first?.count, 2048)
        XCTAssertTrue(policy.events(from: snapshot(["approvals": [first]]), now: epoch.addingTimeInterval(3)).isEmpty)
    }

    func testBulkTransitionsProduceOneNotificationPerCategory() {
        var policy = VelaNotificationPolicy()
        let initial = (0..<100).map { record("s\($0)", "Running") }
        _ = policy.events(from: snapshot(["sessions": initial]), now: epoch)
        let terminal = (0..<100).map { record("s\($0)", $0 < 80 ? "Completed" : "Error") }
        let events = policy.events(from: snapshot(["sessions": terminal]), now: epoch)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first(where: { $0.kind == .completed })?.count, 80)
        XCTAssertEqual(events.first(where: { $0.kind == .error })?.count, 20)
        XCTAssertEqual(VelaNotificationKind.approval.soundFilename, "vela-approval.wav")
    }

    func testFreshRunsThatFinishBetweenPollsNotifyOnce() {
        var policy = VelaNotificationPolicy()
        _ = policy.events(from: snapshot(["runs": []]), now: epoch)
        let later = epoch.addingTimeInterval(1)
        let runs = [record("fast-success", "completed", time: later), record("fast-failure", "failed", time: later)]
        let events = policy.events(from: snapshot(["runs": runs]), now: later)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first(where: { $0.kind == .completed })?.recordID, "fast-success")
        XCTAssertEqual(events.first(where: { $0.kind == .error })?.recordID, "fast-failure")
        XCTAssertTrue(policy.events(from: snapshot(["runs": runs]), now: later).isEmpty)
    }

    func testFirstObservedRunRejectsHistoricalMissingAndFutureCreation() {
        var policy = VelaNotificationPolicy()
        _ = policy.events(from: snapshot(["runs": []]), now: epoch)
        var missing = record("missing", "completed"); missing.removeValue(forKey: "createdAt")
        var malformed = record("malformed", "failed"); malformed["createdAt"] = "invalid"
        let runs = [record("historical", "completed", time: epoch.addingTimeInterval(-60)),
                    record("future", "failed", time: epoch.addingTimeInterval(60)), missing, malformed]
        XCTAssertTrue(policy.events(from: snapshot(["runs": runs]), now: epoch).isEmpty)
    }

    func testFirstObservedSessionApprovalRequiresProviderActivity() {
        var policy = VelaNotificationPolicy()
        _ = policy.events(from: snapshot(["sessions": []]), now: epoch)
        let later = epoch.addingTimeInterval(1)
        func session(_ id: String, source: String?, at time: Date) -> JSON {
            var result = record(id, "Needs Approval", time: later)
            result["lastActivity"] = ISO8601DateFormatter().string(from: time)
            if let source = source { result["lastActivitySource"] = source }
            return result
        }
        let records = [session("fresh", source: "provider", at: later),
                       session("fallback", source: "ingestion_fallback", at: later),
                       session("legacy", source: nil, at: later),
                       session("historical", source: "provider", at: epoch.addingTimeInterval(-60)),
                       session("future", source: "provider", at: later.addingTimeInterval(60))]
        let events = policy.events(from: snapshot(["sessions": records]), now: later)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.recordID, "fresh")
        XCTAssertEqual(events.first?.inferred, true)
        var started = session("started", source: "ingestion_fallback", at: later)
        started["startedAtSource"] = "provider"
        started["startedAt"] = ISO8601DateFormatter().string(from: later)
        XCTAssertEqual(policy.events(from: snapshot(["sessions": [started]]), now: later).first?.recordID, "started")
        var importedCompletion = session("imported-completion", source: "provider", at: later)
        importedCompletion["state"] = "Completed"
        XCTAssertTrue(policy.events(from: snapshot(["sessions": [importedCompletion]]), now: later).isEmpty)
    }

    func testTimestampProvenanceComesFromRealIngestion() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-notification-ingestion-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let logs = temporary.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let store = try VelaStore(root: temporary.appendingPathComponent("store"))
        let service = FoundationService(store: store, sourceRoots: ["claude": [logs]], globalHome: temporary)
        for (name, timestamp) in [("provider", "2023-11-14T22:13:20Z"), ("fallback", "")] {
            var row: JSON = ["type": "approval_requested", "sessionId": name, "cwd": temporary.path]
            if !timestamp.isEmpty { row["timestamp"] = timestamp }
            try (try jsonString(row) + "\n").write(to: logs.appendingPathComponent(name + ".jsonl"), atomically: true, encoding: .utf8)
        }
        _ = try service.handle("sessions.refresh", [:])
        let rows = try store.list("session")
        XCTAssertEqual(rows.count, 2)
        let provider = rows.first { string($0, "sourceSessionId") == "provider" }
        let fallback = rows.first { string($0, "sourceSessionId") == "fallback" }
        XCTAssertEqual(provider?["lastActivitySource"] as? String, "provider")
        XCTAssertEqual(provider?["startedAtSource"] as? String, "provider")
        XCTAssertEqual(fallback?["lastActivitySource"] as? String, "ingestion_fallback")
        XCTAssertEqual(fallback?["startedAtSource"] as? String, "ingestion_fallback")
        var policy = VelaNotificationPolicy()
        _ = policy.events(from: snapshot(["sessions": []]), now: Date().addingTimeInterval(-5))
        XCTAssertTrue(policy.events(from: snapshot(["sessions": rows])).isEmpty,
                      "Indexing a historical or untimestamped approval must not make it a new event.")
    }

    func testAggregateAcrossProjectsRoutesToGlobalScope() {
        var policy = VelaNotificationPolicy()
        var first = record("a", "Running"); first["project"] = "/project-a"
        var second = record("b", "Running"); second["project"] = "/project-b"
        _ = policy.events(from: snapshot(["sessions": [first, second]]), now: epoch)
        first["state"] = "Completed"; second["state"] = "Completed"
        let event = policy.events(from: snapshot(["sessions": [first, second]]), now: epoch).first
        XCTAssertEqual(event?.count, 2)
        XCTAssertEqual(event?.project, "")
        XCTAssertEqual(event?.recordID, "")
        XCTAssertEqual(event?.sources, ["session"])
        XCTAssertEqual(event?.source, "session")
        XCTAssertEqual(event?.isAggregate, true)
        XCTAssertEqual(event?.spansProjects, true)
    }

    func testMixedAggregateDoesNotMisrepresentOneSource() {
        var policy = VelaNotificationPolicy()
        _ = policy.events(from: snapshot(["sessions": [record("s", "Running")], "runs": [record("r", "running")]]), now: epoch)
        let event = policy.events(from: snapshot(["sessions": [record("s", "Completed")], "runs": [record("r", "completed")]]), now: epoch).first
        XCTAssertEqual(event?.source, "mixed")
        XCTAssertEqual(event?.sources, ["run", "session"])
        XCTAssertEqual(event?.recordID, "")
        XCTAssertEqual(event?.project, "/synthetic/project")
        XCTAssertEqual(event?.spansProjects, false)
        XCTAssertEqual(event?.inferred, false)
        XCTAssertEqual(event?.count, 2)
    }

    func testEvictedRunCannotAlertTwiceButNewRunStillCan() {
        var policy = VelaNotificationPolicy()
        _ = policy.events(from: snapshot(["runs": []]), now: epoch)
        let first = record("original", "completed", time: epoch.addingTimeInterval(1))
        XCTAssertEqual(policy.events(from: snapshot(["runs": [first]]), now: epoch.addingTimeInterval(1)).count, 1)
        let later = (0..<2048).map { record("new-\($0)", "completed", time: epoch.addingTimeInterval(2)) }
        XCTAssertEqual(policy.events(from: snapshot(["runs": later]), now: epoch.addingTimeInterval(2)).first?.count, 2048)
        let fresh = record("fresh", "completed", time: epoch.addingTimeInterval(3))
        let events = policy.events(from: snapshot(["runs": [first, fresh]]), now: epoch.addingTimeInterval(3))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.recordID, "fresh")
    }

    func testPreferenceMigrationAndStrictBooleanValidation() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-preferences-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try VelaStore(root: temporary)
        _ = try store.put("settings", ["id": "preferences", "notifications": true, "analysisEnabled": true])
        let restored = try VelaPreferences.read(from: store)
        XCTAssertEqual(restored["notifications"] as? Bool, true)
        XCTAssertEqual(restored["notificationSound"] as? Bool, true)
        XCTAssertEqual(restored["notifyErrors"] as? Bool, true)
        let saved = try VelaPreferences.save(["notificationSound": false, "notifyApprovals": false], in: store)
        XCTAssertEqual(saved["analysisEnabled"] as? Bool, true)
        XCTAssertEqual(saved["notificationSound"] as? Bool, false)
        XCTAssertEqual(saved["telemetry"] as? Bool, false)
        let bad = try JSONSerialization.jsonObject(with: Data(#"{"notifications":1}"#.utf8)) as! JSON
        XCTAssertThrowsError(try VelaPreferences.save(bad, in: store))
        XCTAssertThrowsError(try VelaPreferences.save(["notifyErrors": "false"], in: store))
        XCTAssertThrowsError(try VelaPreferences.save(["telemetry": true], in: store))
        XCTAssertEqual(try VelaPreferences.read(from: store)["notifications"] as? Bool, true)
    }
}
