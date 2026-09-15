import XCTest
@testable import VelaCore

final class SchedulerReliabilityTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_789_257_600)
    private func fixture(_ body: (URL, VelaStore, AutomationService) throws -> Void) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vela-schedule-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let project = temp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        XCTAssertEqual(try AutomationProcess.git(["init", "-q"], cwd: project.path).exitCode, 0)
        let store = try VelaStore(root: temp.appendingPathComponent("store"))
        _ = try store.put("project", ["path": canonicalProject(project.path), "project": canonicalProject(project.path)])
        try body(project, store, AutomationService(store: store))
    }
    private func save(_ service: AutomationService, _ project: URL, _ policy: String, limit: Int = 10, write: Bool = false) throws -> JSON {
        let step: JSON = write ? ["tool": "file.write", "arguments": ["path": "scheduled.txt", "content": "review first"]] : ["tool": "git.status", "arguments": JSON()]
        return try XCTUnwrap(service.handle("workflows.save", ["title": "Schedule fixture", "project": project.path, "trigger": "cron", "cron": "* * * * *", "timeZone": "UTC", "catchUp": policy, "catchUpLimit": limit, "catchUpWindowHours": 24, "enabled": true, "steps": [step]]) as? JSON)
    }

    func testLatestCatchUpCoalescesMissedTimesAndRetainsLateness() throws {
        try fixture { project, store, service in
            let workflow = try save(service, project, "latest")
            try service.tick(at: base)
            try service.tick(at: base.addingTimeInterval(7 * 60 + 9))
            XCTAssertEqual(try store.list("run").count, 2)
            let late = try XCTUnwrap(store.list("schedule_event").first { intValue($0, "lateBySeconds") == 9 })
            XCTAssertEqual(string(late, "state"), "dispatched")
            XCTAssertEqual(try store.get("schedule", string(workflow, "id"))?["coalescedCount"] as? Int, 6)
            try service.tick(at: base.addingTimeInterval(7 * 60 + 20))
            XCTAssertEqual(try store.list("run").count, 2)
        }
    }

    func testAllCatchUpDrainsInBoundedBatchesAcrossRestarts() throws {
        try fixture { project, store, service in
            _ = try save(service, project, "all", limit: 2)
            try service.tick(at: base)
            let resumed = AutomationService(store: try VelaStore(root: store.root))
            try resumed.tick(at: base.addingTimeInterval(5 * 60))
            XCTAssertEqual(try store.list("run").count, 3)
            try resumed.tick(at: base.addingTimeInterval(5 * 60))
            XCTAssertEqual(try store.list("run").count, 5)
            try resumed.tick(at: base.addingTimeInterval(5 * 60))
            XCTAssertEqual(try store.list("run").count, 6)
            XCTAssertEqual(Set(try store.list("schedule_event").map { string($0, "eventKey") }).count, 6)
        }
    }

    func testSkipAndLegacyNeverReplayMissedMinutes() throws {
        try fixture { project, store, service in
            var workflow = try save(service, project, "skip")
            try service.tick(at: base)
            try service.tick(at: base.addingTimeInterval(3600))
            XCTAssertEqual(try store.list("run").count, 2)
            for key in ["timeZone", "catchUp", "catchUpLimit", "catchUpWindowHours"] { workflow.removeValue(forKey: key) }
            XCTAssertEqual(string(try VelaSchedulePolicy.read(workflow), "catchUp"), "skip")
        }
    }

    func testPendingApprovalDefersCatchUpWithoutExecutingAndThenResumes() throws {
        try fixture { project, store, service in
            let workflow = try save(service, project, "latest", write: true)
            try service.tick(at: base)
            try service.tick(at: base.addingTimeInterval(300))
            XCTAssertEqual(try store.list("run").count, 1)
            XCTAssertEqual(try store.get("schedule", string(workflow, "id"))?["state"] as? String, "deferred")
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("scheduled.txt").path))
            let approval = try XCTUnwrap(store.list("approval").first)
            _ = try service.handle("approvals.decide", ["id": approval["id"]!, "decision": "reject", "snapshotHash": approval["snapshotHash"]!])
            try service.tick(at: base.addingTimeInterval(300))
            XCTAssertEqual(try store.list("run").count, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("scheduled.txt").path))
        }
    }

    func testAnInterruptedClaimRequiresExplicitReviewAndIsNeverRetried() throws {
        try fixture { project, store, service in
            let workflow = try save(service, project, "latest")
            let key = "cron:\(Int(base.timeIntervalSince1970 / 60))"
            let eventID = "event-" + String(stableHash(string(workflow, "id") + ":" + key).prefix(48))
            _ = try store.put("schedule_event", ["id": eventID, "workflowId": workflow["id"]!, "project": canonicalProject(project.path), "eventKey": key, "state": "claimed"])
            try service.tick(at: base)
            try service.tick(at: base.addingTimeInterval(60))
            XCTAssertEqual(try store.list("run").count, 0)
            XCTAssertEqual(try store.get("schedule", string(workflow, "id"))?["state"] as? String, "needs_review")
            XCTAssertThrowsError(try service.resolveScheduledDispatch(["id": eventID, "project": project.path, "decision": "retry"]))
            _ = try service.resolveScheduledDispatch(["id": eventID, "project": project.path, "decision": "acknowledge"])
            try service.tick(at: base.addingTimeInterval(60))
            XCTAssertEqual(try store.list("run").count, 1)
            XCTAssertEqual(try store.get("schedule_event", eventID)?["state"] as? String, "acknowledged")
        }
    }

    func testExplicitTimeZonesAndDSTDoNotDependOnHostZone() throws {
        let formatter = ISO8601DateFormatter()
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let before = try XCTUnwrap(formatter.date(from: "2026-03-07T14:00:00Z"))
        let after = try XCTUnwrap(formatter.date(from: "2026-03-08T13:00:00Z"))
        XCTAssertTrue(try VelaCron.matches("0 9 * * *", date: before, timeZone: newYork))
        XCTAssertTrue(try VelaCron.matches("0 9 * * *", date: after, timeZone: newYork))
        XCTAssertFalse(try VelaCron.matches("0 9 * * *", date: after, timeZone: TimeZone(secondsFromGMT: 0)!))
        XCTAssertThrowsError(try VelaSchedulePolicy.validate(["timeZone": "Mars/Olympus"]))
        XCTAssertThrowsError(try VelaSchedulePolicy.validate(["catchUpLimit": true]))
        XCTAssertThrowsError(try VelaSchedulePolicy.validate(["catchUpWindowHours": 169]))
        XCTAssertThrowsError(try VelaSchedulePolicy.validate(["catchUp": "unlimited"]))
    }

    func testCatchUpWindowIsExplicitAndDoesNotReplayTheEntireHistory() throws {
        try fixture { project, store, service in
            let workflow = try save(service, project, "all", limit: 2)
            try service.tick(at: base)
            try service.tick(at: base.addingTimeInterval(48 * 3600))
            let state = try XCTUnwrap(store.get("schedule", string(workflow, "id")))
            XCTAssertEqual(state["windowTruncated"] as? Bool, true)
            XCTAssertEqual(state["dueCount"] as? Int, 1440)
            XCTAssertEqual(try store.list("run").count, 3)
        }
    }

    func testConcurrentSchedulersCannotRaceDifferentCatchUpCursors() throws {
        try fixture { project, store, service in
            _ = try save(service, project, "all", limit: 2)
            try service.tick(at: base)
            let services = [service, AutomationService(store: try VelaStore(root: store.root))]
            DispatchQueue.concurrentPerform(iterations: 2) { index in try? services[index].tick(at: base.addingTimeInterval(300)) }
            let events = try store.list("schedule_event")
            XCTAssertEqual(Set(events.map { string($0, "eventKey") }).count, events.count)
            XCTAssertEqual(try store.list("run").count, events.count)
            XCTAssertLessThanOrEqual(events.count, 5)
        }
    }

    func testMultipleNewCompletedSessionsAreNotCollapsedToOnlyTheLatest() throws {
        try fixture { project, store, service in
            _ = try service.handle("workflows.save", ["title": "Each session", "project": project.path, "trigger": "session_completed", "enabled": true, "steps": [["tool": "git.status", "arguments": JSON()]]])
            try service.tick(at: base)
            for index in 1...3 { _ = try store.put("session", ["id": "done-\(index)", "project": canonicalProject(project.path), "state": "completed", "lastActivity": "2026-09-13T00:00:0\(index)Z"]) }
            try service.tick(at: base.addingTimeInterval(30))
            try service.tick(at: base.addingTimeInterval(60))
            XCTAssertEqual(try store.list("run").count, 3)
        }
    }

    func testCompletionJournalPagesBeyondUIHistoryLimitAndSurvivesReopen() throws {
        try fixture { project, store, _ in
            let root = canonicalProject(project.path)
            let sessions: [(String, JSON)] = (0..<1007).map { index in
                ("session", ["id":"bulk-\(index)","project":root,"state":"completed","lastActivity":"activity-\(index)"])
            }
            _ = try store.putBatch(sessions)
            let reopened = try VelaStore(root: store.root)
            var cursor: Int64 = 0; var seen = Set<String>(); var pages = 0
            while true {
                let page = try reopened.sessionCompletionPage(project:root,after:cursor,limit:100)
                if page.isEmpty { break }
                XCTAssertLessThanOrEqual(page.count,100)
                for item in page {
                    XCTAssertTrue(seen.insert(string(item,"sessionId")).inserted)
                    cursor = (item["sequence"] as? NSNumber)?.int64Value ?? 0
                }
                pages += 1
            }
            XCTAssertEqual(seen.count,1007); XCTAssertEqual(pages,11)
            XCTAssertEqual(cursor,try reopened.sessionCompletionRevision())
            // Re-indexing unchanged completed history does not create another identity.
            _ = try store.putBatch(sessions)
            XCTAssertTrue(try reopened.sessionCompletionPage(project:root,after:cursor).isEmpty)
            // A source can correct an inferred status without changing its
            // activity identity. The outer objects UPSERT must still succeed.
            for state in ["Unknown","Completed","Unknown","Completed"] {
                _ = try store.put("session",["id":"bulk-0","project":root,"state":state,"lastActivity":"activity-0"])
                XCTAssertEqual(try reopened.get("session","bulk-0")?["state"] as? String,state)
            }
            XCTAssertEqual(try reopened.sessionCompletionRevision(),cursor)
        }
    }

    func testCompletionCursorSkipsPrivateInternalAndDeletedSourcesWithoutRunning() throws {
        try fixture { project, store, service in
            let root = canonicalProject(project.path)
            let workflow = try XCTUnwrap(service.handle("workflows.save", ["title":"Scope completion","project":root,"trigger":"session_completed","enabled":true,"steps":[["tool":"git.status","arguments":JSON()]]]) as? JSON)
            try service.tick(at:base)
            for index in 0..<4 {
                var item: JSON = ["id":"excluded-\(index)","project":root,"state":"completed","lastActivity":"done"]
                if index == 0 { item["private"] = true }
                if index == 1 { item["internalRun"] = true }
                if index == 2 { item["sourcePath"] = root + "/private/session.jsonl" }
                if index == 3 { item["scope"] = "private" }
                _ = try store.put("session",item)
            }
            _ = try store.put("session",["id":"deleted-completion","project":root,"state":"completed","lastActivity":"done"])
            try store.remove("session","deleted-completion")
            try service.tick(at:base.addingTimeInterval(30))
            XCTAssertTrue(try store.list("run").isEmpty)
            let cursor = (try store.get("schedule",string(workflow,"id"))?["completionCursor"] as? NSNumber)?.int64Value
            XCTAssertEqual(cursor,try store.sessionCompletionRevision())
            _ = try store.put("session",["id":"public-completion","project":root,"state":"completed","lastActivity":"done"])
            let reopened = AutomationService(store:try VelaStore(root:store.root))
            try reopened.tick(at:base.addingTimeInterval(60))
            try reopened.tick(at:base.addingTimeInterval(90))
            XCTAssertEqual(try store.list("run").count,1)
        }
    }

    func testRuntimeLeaseRejectsSymlinksAndProvesExclusiveOwnership() throws {
        try fixture { _, store, _ in
            let first = try XCTUnwrap(VelaRuntimeLease.acquire(root: store.root, name: "daemon"))
            XCTAssertTrue(try VelaRuntimeLease.isHeld(root: store.root, name: "daemon"))
            XCTAssertNil(try VelaRuntimeLease.acquire(root: store.root, name: "daemon"))
            first.release()
            XCTAssertFalse(try VelaRuntimeLease.isHeld(root: store.root, name: "daemon"))
            let sentinel = store.root.appendingPathComponent("sentinel")
            try Data("unchanged".utf8).write(to: sentinel)
            let link = store.root.appendingPathComponent(".scheduler.lock")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
            XCTAssertThrowsError(try VelaRuntimeLease.acquire(root: store.root, name: "scheduler"))
            XCTAssertEqual(try String(contentsOf: sentinel), "unchanged")
        }
    }

    func testLaunchAgentPlanAndInstallAreScopedAndNeverOverwrite() throws {
        try fixture { _, store, _ in
            let fakeHome = store.root.appendingPathComponent("fake-user")
            try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
            let daemon = try VelaDaemonService(store: store, executable: "/usr/bin/true", userHome: fakeHome)
            let plan = try daemon.plan()
            XCTAssertEqual(plan["mutated"] as? Bool, false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fakeHome.appendingPathComponent("Library").path))
            let configuration = try XCTUnwrap(plan["configuration"] as? JSON)
            XCTAssertEqual(configuration["ProgramArguments"] as? [String], ["/usr/bin/true", "daemon", "run", "--home", store.root.path])
            _ = try daemon.install(); _ = try daemon.install()
            let path = try requireString(plan, "path")
            try Data("user replacement".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try daemon.install())
            XCTAssertEqual(try String(contentsOfFile: path), "user replacement")
            XCTAssertFalse(try VelaRuntimeLease.isHeld(root: store.root, name: "daemon"))
        }
    }
}
