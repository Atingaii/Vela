import XCTest
@testable import VelaCore

final class ApprovalRecoveryTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-approval-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:directory.appendingPathComponent("store"))
        _ = try store.put("project",["path":project.path,"project":project.path])
        try body(project,store,AutomationService(store:store))
    }
    private func call(_ service: AutomationService,_ method: String,_ params: JSON) throws -> JSON {
        let valueToUnwrap = try service.handle(method,params) as? JSON
        return try XCTUnwrap(valueToUnwrap)
    }
    private func approve(_ service: AutomationService,_ approval: JSON,_ decision: String = "approve") throws -> JSON {
        try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":decision])
    }

    func testExpectingAbsentCollisionAndStaleSourceRollBackWholeBatch() throws {
        try fixture { _,store,_ in
            let run = try store.put("run",["id":"run","state":"running"])
            let existing = try store.put("approval",["id":"occupied","state":"pending","tool":"original"])
            let hash = stableHash(try jsonString(run))
            XCTAssertThrowsError(try store.putBatch([("run",["id":"run","state":"pending_approval"]),("approval",["id":"occupied","tool":"replacement"])],expecting:[("run","run",hash)],expectingAbsent:[("approval","occupied")]))
            XCTAssertEqual(try jsonString(try XCTUnwrap(store.get("run","run"))),try jsonString(run))
            XCTAssertEqual(try jsonString(try XCTUnwrap(store.get("approval","occupied"))),try jsonString(existing))
            XCTAssertThrowsError(try store.putBatch([("approval",["id":"new","state":"pending"]),("run",["id":"run","state":"pending_approval"])],expecting:[("run","run","stale")],expectingAbsent:[("approval","new")]))
            XCTAssertNil(try store.get("approval","new"))
        }
    }

    func testConcurrentPendingCreationLeavesOneBoundApproval() throws {
        try fixture { project,store,_ in
            let source = try store.put("run",["id":"queued","project":canonicalProject(project.path),"state":"running","dryRun":false,"steps":[["id":"act","tool":"agent.run","state":"queued","arguments":["executable":"/bin/echo","args":["test"]]]]])
            let services = try (0..<2).map { _ in AutomationService(store:try VelaStore(root:store.root)) }
            let lock = NSLock(); var failures: [String] = []
            DispatchQueue.concurrentPerform(iterations:2) { index in
                do { _ = try services[index].continueRun(source) }
                catch { lock.lock(); failures.append(error.localizedDescription); lock.unlock() }
            }
            XCTAssertTrue(failures.isEmpty)
            let current = try XCTUnwrap(store.get("run","queued"))
            let approvals = try store.list("approval")
            XCTAssertEqual(approvals.count,1)
            XCTAssertEqual(string(current,"state"),"pending_approval")
            XCTAssertEqual((current["steps"] as? [JSON])?.first?["approvalId"] as? String,approvals.first?["id"] as? String)
            XCTAssertEqual(string(approvals[0],"runId"),"queued")
        }
    }

    func testStaleApprovalCannotApproveOrRejectChangedRunBinding() throws {
        try fixture { project,store,service in
            let workflow = try call(service,"workflows.save",["title":"binding","project":project.path,"steps":[["tool":"agent.run","arguments":["executable":"/bin/echo","args":["never"]]]]])
            var run = try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":false])
            let approval = try XCTUnwrap(store.list("approval").first)
            var steps = run["steps"] as? [JSON] ?? []
            steps[0]["approvalId"] = "different"
            run["steps"] = steps; run = try store.put("run",run)
            let unchanged = try jsonString(run)
            XCTAssertThrowsError(try approve(service,approval))
            XCTAssertThrowsError(try approve(service,approval,"reject"))
            XCTAssertEqual(try jsonString(try XCTUnwrap(store.get("run",string(run,"id")))),unchanged)
            XCTAssertEqual(string(try XCTUnwrap(store.get("approval",string(approval,"id"))),"state"),"pending")
        }
    }

    func testActualSignalsAreDistinctFromNormalHighExitStatus() throws {
        try fixture { project,_,service in
            let signaled = try service.executeTool("agent.run",arguments:["executable":"/bin/sh","args":["-c","kill -TERM $$"]],project:project.path)
            XCTAssertEqual(intValue(signaled,"terminationSignal"),15)
            XCTAssertEqual(signaled["outcomeUnknown"] as? Bool,true)
            let normal = try service.executeTool("agent.run",arguments:["executable":"/bin/sh","args":["-c","exit 200"]],project:project.path)
            XCTAssertEqual(intValue(normal,"exitCode"),200)
            XCTAssertEqual(intValue(normal,"terminationSignal"),0)
            XCTAssertNil(normal["outcomeUnknown"])
        }
    }

    func testTimedOutOptionalChildRequiresReviewAndCannotAdvanceOrRetry() throws {
        try fixture { project,store,service in
            _ = try call(service,"workflows.save",["id":"child","title":"child","project":project.path,"steps":[["tool":"agent.run","arguments":["executable":"/bin/sh","args":["-c","printf x >> marker; sleep 30"],"timeoutSeconds":1]]]])
            let parent = try call(service,"workflows.save",["title":"parent","project":project.path,"context":["version":1,"template":"{{result}}","inputs":[["id":"result","workflow":["id":"child"],"optional":true]],"memory":["enabled":false]],"steps":[["tool":"agent.run","arguments":["executable":"/bin/echo","args":[WorkflowContext.promptMarker],"promptMode":"workflow_context"]]]])
            let run = try call(service,"workflows.run",["id":parent["id"]!,"dryRun":false])
            let pending = try XCTUnwrap(store.list("approval").first)
            let decided = try approve(service,pending)
            XCTAssertEqual(string(decided,"state"),"needs_review")
            XCTAssertEqual((decided["result"] as? JSON)?["timedOut"] as? Bool,true)
            XCTAssertEqual(string(try XCTUnwrap(store.get("run",string(run,"id"))),"state"),"needs_review")
            XCTAssertEqual(try String(contentsOf:project.appendingPathComponent("marker")),"x")
            _ = try call(service,"runs.resume",["id":run["id"]!,"project":project.path])
            XCTAssertThrowsError(try approve(service,pending))
            XCTAssertEqual(try store.list("approval").count,1)
            XCTAssertEqual(try String(contentsOf:project.appendingPathComponent("marker")),"x")
        }
    }
}
