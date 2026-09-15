import XCTest
@testable import VelaCore

final class ApprovalExpiryTests: XCTestCase {
    private final class ClockBox { var value: Date; init(_ value: Date) { self.value = value } }
    private func fixture(_ work: (URL,VelaStore,AutomationService,() -> Date,(Date) -> Void) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-approval-expiry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let project = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["title":"Approval expiry fixture","path":project.path,"project":project.path])
        var now = Date(timeIntervalSince1970:1_800_000_000)
        let service = AutomationService(store:store,approvalClock:{ now })
        try work(project,store,service,{ now },{ now = $0 })
    }

    private func call(_ service: AutomationService,_ method: String,_ params: JSON) throws -> JSON {
        try XCTUnwrap(try service.handle(method,params) as? JSON)
    }

    // XCTest's XCTUnwrap records a test failure even when its thrown error is
    // deliberately asserted.  Keep rejection-path assertions on a plain
    // throwing bridge so the portable compatibility runner observes the
    // intended `XCTAssertThrowsError`, not a mirrored framework failure.
    private func raw(_ service: AutomationService,_ method: String,_ params: JSON) throws -> JSON {
        guard let value = try service.handle(method,params) as? JSON else { throw VelaError("Expected JSON response") }
        return value
    }

    func testPolicyAndUnifiedFactoryCoverAllCreationTools() throws {
        try fixture { project,store,service,now,_ in
            XCTAssertEqual((try VelaPreferences.read(from:store)["approvalExpirySeconds"] as? NSNumber)?.intValue,604_800)
            XCTAssertThrowsError(try VelaPreferences.save(["approvalExpirySeconds":-1],in:store))
            XCTAssertThrowsError(try VelaPreferences.save(["approvalExpirySeconds":31_536_001],in:store))
            XCTAssertThrowsError(try VelaPreferences.save(["approvalExpirySeconds":true],in:store))
            _ = try VelaPreferences.save(["approvalExpirySeconds":2],in:store)
            let tools = ["workflow.step","lab.execute","knowledge.answer","ask.route.proposal.execute","workflow.replay.execute","agent.loop","workflow.plan.execute","improve.model.execute","connector.execute"]
            for (index,tool) in tools.enumerated() {
                let approval = try service.pendingApproval(id:"pending-\(index)",title:tool,tool:tool,arguments:["index":index],project:project.path,runId:"run-\(index)",stepIndex:0)
                XCTAssertEqual(string(approval,"state"),"pending")
                XCTAssertFalse(string(approval,"expiresAt").isEmpty)
                XCTAssertEqual(string(approval,"snapshotHash"),stableHash(try jsonString(service.frozenPayload(approval))))
            }
            XCTAssertEqual(now(),Date(timeIntervalSince1970:1_800_000_000))
            _ = try VelaPreferences.save(["approvalExpirySeconds":0],in:store)
            let disabled = try service.pendingApproval(title:"disabled",tool:"workflow.step",arguments:[:],project:project.path,runId:"disabled",stepIndex:0)
            XCTAssertNil(disabled["expiresAt"]); XCTAssertEqual(string(disabled,"expiryMode"),"disabled")
        }
    }

    func testExpiryIsTerminalAndDoesNotExecuteFrozenWorkflow() throws {
        try fixture { project,store,service,now,setNow in
            _ = try VelaPreferences.save(["approvalExpirySeconds":1],in:store)
            let saved = try self.call(service,"workflows.save",["title":"write","project":project.path,"trigger":"manual","steps":[["title":"write","tool":"file.write","arguments":["path":"expired.txt","content":"must not write"]]]])
            _ = try self.call(service,"workflows.run",["id":saved["id"]!,"dryRun":false])
            let pending = try XCTUnwrap(store.list("approval").first)
            setNow(now().addingTimeInterval(2))
            XCTAssertThrowsError(try self.raw(service,"approvals.decide",["id":pending["id"]!,"snapshotHash":pending["snapshotHash"]!,"decision":"approve"]))
            XCTAssertEqual(string(try self.call(service,"approvals.get",["id":pending["id"]!]),"state"),"expired")
            XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent("expired.txt").path))
            let run = try XCTUnwrap(store.get("run",string(pending,"runId")))
            XCTAssertEqual(string(run,"state"),"expired")
            XCTAssertEqual(string((run["steps"] as? [JSON] ?? [[:]])[0],"state"),"expired")
            let health = try self.call(service,"workflows.health",["project":project.path])
            XCTAssertEqual(intValue(health,"expiredRuns"),1)
            XCTAssertEqual(intValue(health,"failures"),0)
        }
    }

    func testExpiredApprovalAtomicallyMarksEveryOwnerAndRun() throws {
        try fixture { project,store,service,now,setNow in
            _ = try VelaPreferences.save(["approvalExpirySeconds":1],in:store)
            let owners: [(String,String?,String?)] = [
                ("workflow.step",nil,nil),("lab.execute","eval",nil),("knowledge.answer","knowledge_query","askId"),
                ("ask.route.proposal.execute","ask_route_proposal","proposalId"),("workflow.replay.execute","replay","replayId"),
                ("agent.loop","agent_loop","loopId"),("workflow.plan.execute","workflow_plan","planId"),
                ("improve.model.execute","model_improvement","planId"),("connector.execute","connector_action","actionId")
            ]
            var approvals: [JSON] = []
            for (index,entry) in owners.enumerated() {
                let runID = "owner-run-\(index)", ownerID = entry.1 == nil || entry.0 == "lab.execute" ? runID : "owner-object-\(index)"
                let arguments: JSON = entry.2 == nil ? [:] : [entry.2!:ownerID]
                let approval = try service.pendingApproval(id:"owner-approval-\(index)",title:entry.0,tool:entry.0,arguments:arguments,project:project.path,runId:runID,stepIndex:0)
                approvals.append(approval)
                _ = try store.put("approval",approval)
                if entry.0 != "lab.execute" {
                    _ = try store.put("run",["id":runID,"project":project.path,"state":"pending_approval","steps":[["approvalId":approval["id"]!,"state":"pending_approval"]]])
                }
                if let kind = entry.1 { _ = try store.put(kind,["id":ownerID,"project":project.path,"state":"pending_approval","runId":runID,"approvalId":approval["id"]!]) }
            }
            setNow(now().addingTimeInterval(2))
            for (index,approval) in approvals.enumerated() {
                XCTAssertThrowsError(try self.raw(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"]))
                XCTAssertEqual(string(try self.call(service,"approvals.get",["id":approval["id"]!]),"state"),"expired")
                let (tool,owner,ownerKey) = owners[index], runID = string(approval,"runId")
                if tool != "lab.execute" {
                    let run = try XCTUnwrap(store.get("run",runID)); XCTAssertEqual(string(run,"state"),"expired"); XCTAssertEqual(string((run["steps"] as? [JSON] ?? [[:]])[0],"state"),"expired")
                }
                if let owner { let ownerID = ownerKey == nil ? runID : string(approval["arguments"] as? JSON ?? [:],ownerKey!); XCTAssertEqual(string(try XCTUnwrap(store.get(owner,ownerID)),"state"),"expired") }
            }
        }
    }

    func testInvalidCursorCannotTriggerExpiryProjectionAndDisabledModeSurvivesGet() throws {
        try fixture { project,store,service,now,setNow in
            _ = try VelaPreferences.save(["approvalExpirySeconds":1],in:store)
            let expiring = try service.pendingApproval(id:"cursor-expiring",title:"cursor",tool:"lab.execute",arguments:[:],project:project.path,runId:"cursor-eval",stepIndex:0)
            _ = try store.put("approval",expiring); _ = try store.put("eval",["id":"cursor-eval","project":project.path,"state":"pending_approval","approvalId":expiring["id"]!])
            setNow(now().addingTimeInterval(2))
            XCTAssertThrowsError(try self.raw(service,"approvals.list",["project":project.path,"state":"expired","cursor":true]))
            XCTAssertEqual(string(try XCTUnwrap(store.get("approval","cursor-expiring")),"state"),"pending")
            let traversalCursor = Data("2027-01-01T00:00:00Z\n../bad".utf8).base64EncodedString()
            XCTAssertThrowsError(try self.raw(service,"approvals.list",["project":project.path,"state":"expired","cursor":traversalCursor]))
            XCTAssertEqual(string(try XCTUnwrap(store.get("approval","cursor-expiring")),"state"),"pending","cursor must be validated before an expired sweep writes")
            _ = try VelaPreferences.save(["approvalExpirySeconds":0],in:store)
            let disabled = try service.pendingApproval(id:"disabled-get",title:"disabled",tool:"lab.execute",arguments:[:],project:project.path,runId:"disabled-eval",stepIndex:0)
            _ = try store.put("approval",disabled); _ = try store.put("eval",["id":"disabled-eval","project":project.path,"state":"pending_approval","approvalId":disabled["id"]!])
            XCTAssertEqual(string(try self.call(service,"approvals.get",["id":"disabled-get"]),"expiryMode"),"disabled")
            let projected = try self.call(service,"approvals.list",["project":project.path,"state":"expired"])
            XCTAssertEqual((projected["expiredProjection"] as? JSON)?["scanned"] as? Int,1)
            XCTAssertEqual(string(try XCTUnwrap(store.get("approval","cursor-expiring")),"state"),"expired")
        }
    }

    func testGetExpiryAdvancesWaitingCompositionParentWithoutExecutingChild() throws {
        try fixture { project,store,service,now,setNow in
            _ = try VelaPreferences.save(["approvalExpirySeconds":1],in:store)
            let child = try self.call(service,"workflows.save",["id":"expiry-child","title":"expiry child","project":project.path,"steps":[["id":"write","title":"write","tool":"file.write","arguments":["path":"child-should-not-exist","content":"no"]]]])
            let parent = try self.call(service,"workflows.save",["id":"expiry-parent","title":"expiry parent","project":project.path,"pipeline":[["id":"only","workflowId":child["id"]!]],"output":["target":"stdout"]])
            let started = try self.call(service,"workflows.run",["id":parent["id"]!,"dryRun":false])
            XCTAssertEqual(string(started,"state"),"waiting_child")
            let approval = try XCTUnwrap(store.list("approval").first)
            setNow(now().addingTimeInterval(2))
            let expired = try self.call(service,"approvals.get",["id":approval["id"]!])
            XCTAssertEqual(string(expired,"state"),"expired")
            let parentRun = try XCTUnwrap(store.get("run",string(started,"id")))
            XCTAssertEqual(string(parentRun,"state"),"expired")
            XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent("child-should-not-exist").path))
        }
    }

    func testExpiredOptionalCompositionChildStopsParentBeforeFollowingWriteCanStart() throws {
        try fixture { project,store,service,now,setNow in
            _ = try VelaPreferences.save(["approvalExpirySeconds":1],in:store)
            let child = try self.call(service,"workflows.save",["id":"optional-expiry-child","title":"optional expiry child","project":project.path,"steps":[["id":"child-write","title":"child write","tool":"file.write","arguments":["path":"child-expired.txt","content":"no"]]]])
            let parent = try self.call(service,"workflows.save",[
                "id":"optional-expiry-parent","title":"optional expiry parent","project":project.path,
                "context":["version":1,"template":"child {{child}}","inputs":[["id":"child","workflow":["id":child["id"]!],"optional":true]],"memory":["enabled":false]],
                "steps":[["id":"after-child","title":"after child","tool":"agent.run","arguments":["executable":"/bin/echo","args":[WorkflowContext.promptMarker],"promptMode":"workflow_context"]]],"output":["target":"file","path":"parent-after-expiry.txt"]
            ])
            let started = try self.call(service,"workflows.run",["id":parent["id"]!,"dryRun":false])
            XCTAssertEqual(string(started,"state"),"waiting_child")
            let childApproval = try XCTUnwrap(store.list("approval").first)
            setNow(now().addingTimeInterval(2))
            XCTAssertEqual(string(try self.call(service,"approvals.get",["id":childApproval["id"]!]),"state"),"expired")
            let parentRun = try XCTUnwrap(store.get("run",string(started,"id")))
            XCTAssertEqual(string(parentRun,"state"),"expired")
            XCTAssertEqual(try store.list("approval").count,1,"expired optional child must not prepare a following parent step")
            XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent("parent-after-expiry.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent("child-expired.txt").path))
        }
    }

    func testWaitingClaimReadsClockOnlyAfterOtherConnectionReleasesWriteLock() throws {
        try fixture { project,store,service,now,setNow in
            _ = try VelaPreferences.save(["approvalExpirySeconds":1],in:store)
            let workflow = try self.call(service,"workflows.save",["title":"blocked approval","project":project.path,"trigger":"manual","steps":[["title":"write","tool":"file.write","arguments":["path":"lock-expired.txt","content":"must not write"]]]])
            _ = try self.call(service,"workflows.run",["id":workflow["id"]!,"dryRun":false])
            let approval = try XCTUnwrap(store.list("approval").first)
            let blocker = try VelaStore(root:store.root), claimantStore = try VelaStore(root:store.root)
            let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0), started = DispatchSemaphore(value:0), clockRead = DispatchSemaphore(value:0), finished = DispatchSemaphore(value:0)
            let blockerQueue = DispatchQueue(label:"approval-expiry-blocker")
            blockerQueue.async {
                _ = try? blocker.withApprovalTransaction {
                    entered.signal(); _ = release.wait(timeout:.now() + 2); return ()
                }
            }
            XCTAssertEqual(entered.wait(timeout:.now() + 1),.success)
            let clock = ClockBox(now())
            let claimant = AutomationService(store:claimantStore,approvalClock:{ clockRead.signal(); return clock.value })
            let resultLock = NSLock(); var result: Result<JSON,Error>?
            DispatchQueue.global().async {
                started.signal()
                resultLock.lock(); defer { resultLock.unlock(); finished.signal() }
                result = Result { try self.raw(claimant,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"]) }
            }
            XCTAssertEqual(started.wait(timeout:.now() + 1),.success)
            // If a future refactor samples the clock before BEGIN IMMEDIATE,
            // this signal arrives while the other connection still owns it.
            XCTAssertEqual(clockRead.wait(timeout:.now() + .milliseconds(150)),.timedOut)
            clock.value = now().addingTimeInterval(2); release.signal()
            XCTAssertEqual(finished.wait(timeout:.now() + 2),.success)
            resultLock.lock(); let captured = result; resultLock.unlock()
            XCTAssertThrowsError(try captured?.get())
            XCTAssertEqual(string(try self.call(service,"approvals.get",["id":approval["id"]!]),"state"),"expired")
            XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent("lock-expired.txt").path))
        }
    }

    func testLegacyIsUnboundedAndReadPaginationIsOldestFirst() throws {
        try fixture { project,store,service,now,setNow in
            let legacy: JSON = ["id":"legacy","title":"old","tool":"lab.execute","arguments":[:],"project":project.path,"runId":"legacy-eval","stepIndex":0,"state":"pending","snapshotHash":"legacy"]
            _ = try store.put("approval",legacy); _ = try store.put("eval",["id":"legacy-eval","project":project.path,"state":"pending_approval"])
            _ = try VelaPreferences.save(["approvalExpirySeconds":1],in:store)
            for index in 0..<3 {
                let approval = try service.pendingApproval(id:"page-\(index)",title:"page",tool:"lab.execute",arguments:[:],project:project.path,runId:"page-eval-\(index)",stepIndex:0)
                _ = try store.put("approval",approval); _ = try store.put("eval",["id":"page-eval-\(index)","project":project.path,"state":"pending_approval","approvalId":approval["id"]!])
                setNow(now().addingTimeInterval(1))
            }
            for index in 0..<201 { _ = try store.put("approval",["id":"legacy-prefix-\(index)","title":"legacy","tool":"lab.execute","arguments":[:],"project":project.path,"runId":"legacy-prefix-run-\(index)","stepIndex":0,"state":"pending","snapshotHash":"legacy"]) }
            setNow(now().addingTimeInterval(10))
            let legacyRead = try self.call(service,"approvals.get",["id":"legacy"])
            XCTAssertEqual(string(legacyRead,"state"),"pending"); XCTAssertEqual(string(legacyRead,"expiryMode"),"legacy_unbounded")
            let expired = try self.call(service,"approvals.list",["project":project.path,"state":"expired","limit":2])
            XCTAssertEqual((expired["items"] as? [JSON] ?? []).count,2)
            let cursor = try XCTUnwrap(expired["cursor"] as? String)
            let next = try self.call(service,"approvals.list",["project":project.path,"state":"expired","limit":2,"cursor":cursor])
            XCTAssertEqual((next["items"] as? [JSON] ?? []).count,1)
            XCTAssertTrue((next["cursor"] is NSNull))
        }
    }
}
