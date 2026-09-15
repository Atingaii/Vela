import XCTest
@testable import VelaCore

/// Independent recovery-boundary regressions. Crash fixtures reproduce the
/// exact persisted rows surrounding delivery; they never run a real agent.
final class CompositionReviewTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-composition-review-" + UUID().uuidString)
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
    private func start(_ service: AutomationService,_ project: URL,_ id: String,_ text: String) throws -> JSON {
        _ = try call(service,"workflows.save",["id":id + "-child","title":id + " child","project":project.path,"steps":[["id":"emit","tool":"agent.run","arguments":["executable":"/bin/echo","args":[text]]]],"output":["target":"file","path":"must-stay-memory.md"]])
        let workflow = try call(service,"workflows.save",["id":id,"title":id,"project":project.path,"pipeline":[["id":"emit","workflowId":id + "-child"]],"output":["target":"file","path":"shared.md"]])
        return try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":false])
    }
    private func approval(_ store: VelaStore,_ parent: JSON) throws -> JSON {
        try XCTUnwrap(store.list("approval").first { string($0,"runId") == string(parent,"waitingChildId") })
    }
    private func decide(_ service: AutomationService,_ approval: JSON) throws -> JSON {
        try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
    }

    func testPreparedDeliveryRecoveryCannotOverwriteANewerRootOutput() throws {
        try fixture { project,store,service in
            let first = try start(service,project,"first","first artifact")
            _ = try decide(service,approval(store,first))
            var beforeDelivery = try XCTUnwrap(store.get("run",string(first,"id")))
            XCTAssertEqual(string(beforeDelivery,"state"),"completed")
            var prepared = try XCTUnwrap(store.get("run_output",string(first,"id")))
            // The child and SafeApply journal are durable, but the parent is
            // still at the last saved cursor and run_output is only prepared.
            // These are the rows if the process dies after writeManagedOutput
            // returns and before its caller saves the delivered receipt.
            beforeDelivery["state"] = "running"
            for key in ["output","outputHash","outputKnown","outputDelivery","completedAt"] { beforeDelivery.removeValue(forKey:key) }
            prepared["state"] = "prepared"
            for key in ["journalId","deliveredAt"] { prepared.removeValue(forKey:key) }
            _ = try store.put("run",beforeDelivery); _ = try store.put("run_output",prepared)
            let second = try start(service,project,"second","newer artifact")
            _ = try decide(service,approval(store,second))
            let output = store.root.appendingPathComponent("output/shared.md")
            XCTAssertEqual(try String(contentsOf:output),"newer artifact\n")
            let journals = try store.list("apply_journal").count
            let reopened = AutomationService(store:try VelaStore(root:store.root))
            let resumed = try call(reopened,"runs.resume",["project":project.path,"id":first["id"]!])
            // Recovery may reconcile its own durable journal or demand review;
            // it must not replace an output belonging to a later root run.
            XCTAssertEqual(try String(contentsOf:output),"newer artifact\n")
            XCTAssertEqual(try store.list("apply_journal").count,journals)
            XCTAssertTrue(["completed","needs_review"].contains(string(resumed,"state")))
            XCTAssertEqual(try store.list("approval").count,2)
        }
    }

    func testPersistedUncertainApprovalPropagatesWithoutRepeatingChild() throws {
        try fixture { project,store,service in
            let parent = try start(service,project,"uncertain","must not run")
            var pending = try approval(store,parent)
            // An external operation returned uncertainty and saved its ledger,
            // then the process died before updating the child run record.
            pending["state"] = "needs_review"
            pending["result"] = ["exitCode":-1,"outcomeUnknown":true,"output":"synthetic uncertain outcome"]
            pending["completedAt"] = isoNow()
            _ = try store.put("approval",pending)
            let reopened = AutomationService(store:try VelaStore(root:store.root))
            let resumed = try call(reopened,"runs.resume",["project":project.path,"id":parent["id"]!])
            XCTAssertEqual(string(resumed,"state"),"needs_review")
            let child = try XCTUnwrap(store.get("run",string(parent,"waitingChildId")))
            XCTAssertEqual(string(child,"state"),"needs_review")
            XCTAssertEqual(try store.list("approval").count,1)
            XCTAssertTrue(try store.list("run_output").isEmpty)
            XCTAssertThrowsError(try decide(reopened,pending))
        }
    }

    func testConcurrentResumeOfCompletedGraphNeverRepeatsRootOrChildDelivery() throws {
        try fixture { project,store,service in
            let parent = try start(service,project,"completed","single artifact")
            _ = try decide(service,approval(store,parent))
            let beforeJournals = try store.list("apply_journal").count
            let services = try (0..<2).map { _ in AutomationService(store:try VelaStore(root:store.root)) }
            let resultLock = NSLock(); var errors: [String] = []
            DispatchQueue.concurrentPerform(iterations:16) { index in
                do { _ = try call(services[index % services.count],"runs.resume",["project":project.path,"id":parent["id"]!]) }
                catch {
                    // A busy nonblocking composition lease is an explicit,
                    // side-effect-free response; all other failures matter.
                    if !error.localizedDescription.contains("being advanced by another process") {
                        resultLock.lock(); errors.append(error.localizedDescription); resultLock.unlock()
                    }
                }
            }
            XCTAssertTrue(errors.isEmpty)
            XCTAssertEqual(try store.list("run").count,2)
            XCTAssertEqual(try store.list("approval").count,1)
            XCTAssertEqual(try store.list("run_output").count,1)
            XCTAssertEqual(try store.list("apply_journal").count,beforeJournals)
            XCTAssertFalse(FileManager.default.fileExists(atPath:store.root.appendingPathComponent("output/must-stay-memory.md").path))
        }
    }

    func testAStaleChildSnapshotCannotReopenAlreadyExecutedLaterSteps() throws {
        try fixture { project,store,service in
            _ = try call(service,"workflows.save",["id":"two-steps","title":"Two real steps","project":project.path,"steps":[
                ["id":"first","tool":"agent.run","arguments":["executable":"/bin/echo","args":["first"]]],
                ["id":"second","tool":"agent.run","arguments":["executable":"/bin/echo","args":["second"]]]
            ]])
            let flow = try call(service,"workflows.save",["id":"stale-resume","title":"Stale resume","project":project.path,"pipeline":[["workflowId":"two-steps"]]])
            let parent = try call(service,"workflows.run",["id":flow["id"]!,"dryRun":false])
            // runs.resume obtains this row before acquiring composition lease.
            // A different caller can finish both steps before that lease is
            // acquired; the old snapshot must never revert the durable run.
            let oldChild = try XCTUnwrap(store.get("run",string(parent,"waitingChildId")))
            _ = try decide(service,approval(store,parent))
            let second = try XCTUnwrap(store.list("approval").first { string($0,"state") == "pending" })
            _ = try decide(service,second)
            let finished = try XCTUnwrap(store.get("run",string(oldChild,"id")))
            XCTAssertEqual(string(finished,"state"),"completed")
            let recovered = try service.withCompositionLease { try service.resumeKnownChild(oldChild) }
            XCTAssertEqual(string(recovered,"state"),"completed")
            XCTAssertEqual(try store.list("approval").count,2)
            XCTAssertTrue(try store.list("approval").allSatisfy { string($0,"state") == "executed" })
            XCTAssertEqual((try store.get("run",string(oldChild,"id"))?["steps"] as? [JSON])?.map { string($0,"state") },["completed","completed"])
        }
    }
}
