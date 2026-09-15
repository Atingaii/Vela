import XCTest
@testable import VelaCore

/// Independent review fixtures reproduce process loss between durable writes.
final class SchedulerReviewTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_789_257_600)
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-scheduler-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let project = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        XCTAssertEqual(try AutomationProcess.git(["init","-q"],cwd:project.path).exitCode,0)
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["path":canonicalProject(project.path),"project":canonicalProject(project.path)])
        try body(project,store,AutomationService(store:store))
    }

    private func workflow(_ service: AutomationService, project: URL, trigger: String = "cron") throws -> JSON {
        try XCTUnwrap(service.handle("workflows.save",["title":"Independent scheduler review","project":project.path,"enabled":true,"trigger":trigger,"cron":"* * * * *","timeZone":"UTC","catchUp":"latest","steps":[["tool":"git.status","arguments":JSON()]]]) as? JSON)
    }

    func testAppStartEventSurvivesAnActiveRunUntilItCanDispatch() throws {
        try fixture { project,store,service in
            let workflow = try workflow(service,project:project,trigger:"app_start")
            var active = try store.put("run",["id":"previous-run","workflowId":workflow["id"]!,"project":canonicalProject(project.path),"state":"pending_approval"])
            try service.tick(at:base,startupEvent:"same-process-start")
            XCTAssertEqual(try store.list("schedule_event").count,0)
            XCTAssertEqual(try store.get("schedule",string(workflow,"id"))?["state"] as? String,"deferred")
            active["state"] = "completed"; _ = try store.put("run",active)
            try service.tick(at:base.addingTimeInterval(30),startupEvent:"same-process-start")
            XCTAssertEqual(try store.list("schedule_event").count,1)
            XCTAssertEqual(try store.list("run").count,2)
            try service.tick(at:base.addingTimeInterval(60),startupEvent:"same-process-start")
            XCTAssertEqual(try store.list("run").count,2)
        }
    }

    func testOlderUncertainClaimBlocksLatestCatchUpAfterRestart() throws {
        try fixture { project,store,service in
            let workflow = try workflow(service,project:project)
            try service.tick(at:base)
            let key = "cron:\(Int(base.timeIntervalSince1970 / 60) + 1)"
            let eventID = "event-" + String(stableHash(string(workflow,"id") + ":" + key).prefix(48))
            _ = try store.put("schedule_event",["id":eventID,"workflowId":workflow["id"]!,"project":canonicalProject(project.path),"eventKey":key,"state":"claimed"])
            var schedule = try XCTUnwrap(store.get("schedule",string(workflow,"id")))
            schedule["state"] = "claimed"; schedule["lastEvent"] = key
            _ = try store.put("schedule",schedule)
            let reopened = AutomationService(store:try VelaStore(root:store.root))
            try reopened.tick(at:base.addingTimeInterval(5 * 60))
            XCTAssertEqual(try store.list("run").count,1)
            XCTAssertEqual(try store.get("schedule",string(workflow,"id"))?["state"] as? String,"needs_review")
            XCTAssertEqual(try store.get("schedule_event",eventID)?["state"] as? String,"claimed")
        }
    }

    func testAcknowledgedEventRecoversIfProcessStoppedBeforeScheduleUnlock() throws {
        try fixture { project,store,service in
            let workflow = try workflow(service,project:project)
            let key = "cron:\(Int(base.timeIntervalSince1970 / 60))"
            let eventID = "event-" + String(stableHash(string(workflow,"id") + ":" + key).prefix(48))
            _ = try store.put("schedule_event",["id":eventID,"workflowId":workflow["id"]!,"project":canonicalProject(project.path),"eventKey":key,"state":"claimed"])
            try service.tick(at:base)
            XCTAssertEqual(try store.get("schedule",string(workflow,"id"))?["state"] as? String,"needs_review")
            // Exact persisted prefix of acknowledge: its CAS completed, its later
            // schedule update did not. Recovery must not repeat the old event.
            var acknowledged = try XCTUnwrap(store.get("schedule_event",eventID))
            acknowledged["state"] = "acknowledged"; acknowledged["acknowledgedAt"] = isoNow(); acknowledged["retried"] = false
            _ = try store.put("schedule_event",acknowledged)
            let reopened = AutomationService(store:try VelaStore(root:store.root))
            try reopened.tick(at:base.addingTimeInterval(60))
            XCTAssertEqual(try store.list("run").count,1)
            XCTAssertEqual(try store.get("schedule_event",eventID)?["state"] as? String,"acknowledged")
        }
    }
}
