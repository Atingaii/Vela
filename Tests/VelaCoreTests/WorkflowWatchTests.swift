import XCTest
@testable import VelaCore

final class WorkflowWatchTests: XCTestCase {
    private let base = Date(timeIntervalSince1970:1_789_257_600)
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vela-watch-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let raw = temp.appendingPathComponent("project"); try FileManager.default.createDirectory(at:raw,withIntermediateDirectories:true)
        let root = URL(fileURLWithPath:canonicalProject(raw.path)), store = try VelaStore(root:temp.appendingPathComponent("store"))
        _ = try store.put("project",["project":root.path,"path":root.path])
        XCTAssertEqual(try AutomationProcess.git(["init","-q"],cwd:root.path).exitCode,0)
        try body(root,store,AutomationService(store:store))
    }
    private func call(_ service: AutomationService, _ method: String, _ params: JSON) throws -> JSON {
        let valueToUnwrap = try service.handle(method,params) as? JSON
        return try XCTUnwrap(valueToUnwrap)
    }
    private func definition(_ root: URL, tool: String = "git.status", minimum: Int = 1, debounce: Int = 0, write: Bool = false) -> JSON {
        let step: JSON = write ? ["tool":"file.write","arguments":["path":"reviewed.txt","content":"WATCH_APPROVED_ONCE"]] : ["tool":"git.status","arguments":JSON()]
        let arguments: JSON = tool == "library.retrieve" ? ["query":"cedar","k":10] : JSON()
        return ["title":"Read tool watch","project":root.path,"trigger":"watch","enabled":true,"watch":["source":"tool","tool":tool,"arguments":arguments,"everySeconds":30,"minItems":minimum,"debounceSeconds":debounce],"steps":[step]]
    }
    private func putLibrary(_ store: VelaStore, _ root: URL, _ id: String) throws -> JSON { try store.put("library",["id":id,"project":root.path,"title":"Cedar " + id,"content":"cedar public text " + id,"private":false,"state":"active"]) }

    func testFirstPollOnlyBaselinesAndStableReadsDoNotDispatchOrPollTooOften() throws {
        try fixture { root,store,service in
            let workflow = try call(service,"workflows.save",definition(root))
            try service.tick(at:base); try service.tick(at:base.addingTimeInterval(10))
            XCTAssertEqual(try store.list("run").count,0)
            XCTAssertEqual(intValue(try XCTUnwrap(store.get("watch_state",string(workflow,"id"))),"pollCount"),1)
            try service.tick(at:base.addingTimeInterval(30))
            XCTAssertEqual(try store.list("run").count,0)
            XCTAssertEqual(try store.list("schedule_event").count,0)
            try Data("one".utf8).write(to:root.appendingPathComponent("added.txt"))
            try service.tick(at:base.addingTimeInterval(60)); try service.tick(at:base.addingTimeInterval(61))
            XCTAssertEqual(try store.list("run").count,1)
            let event = try XCTUnwrap(store.list("schedule_event").first)
            XCTAssertEqual(string(event,"state"),"dispatched")
            XCTAssertTrue(try jsonString(event["watchInput"]!).contains("added.txt"))
            let reopened = AutomationService(store:try VelaStore(root:store.root))
            try reopened.tick(at:base.addingTimeInterval(90))
            XCTAssertEqual(try store.list("run").count,1)
        }
    }
    func testKeysAccumulateAcrossRestartAndDebounceUsesLatestChange() throws {
        try fixture { root,store,service in
            _ = try call(service,"workflows.save",definition(root,tool:"library.retrieve",minimum:2,debounce:10))
            try service.tick(at:base)
            _ = try putLibrary(store,root,"first"); try service.tick(at:base.addingTimeInterval(30))
            XCTAssertEqual(try store.list("run").count,0)
            let reopened = AutomationService(store:try VelaStore(root:store.root))
            _ = try putLibrary(store,root,"second"); try reopened.tick(at:base.addingTimeInterval(60))
            try reopened.tick(at:base.addingTimeInterval(69)); XCTAssertEqual(try store.list("run").count,0)
            try reopened.tick(at:base.addingTimeInterval(70))
            XCTAssertEqual(try store.list("run").count,1)
            let event = try XCTUnwrap(store.list("schedule_event").first), input = try XCTUnwrap(event["watchInput"] as? JSON)
            XCTAssertEqual((input["changes"] as? [JSON])?.count,2)
            XCTAssertFalse(try jsonString(input).contains("cedar public text"))
        }
    }
    func testPreviewAndWorkflowDryRunDoNotAdvanceWatchOrCreateApproval() throws {
        try fixture { root,store,service in
            let workflow = try call(service,"workflows.save",definition(root,write:true))
            let first = try call(service,"watches.preview",["project":root.path,"id":workflow["id"]!])
            XCTAssertEqual(first["wouldInitializeBaseline"] as? Bool,true)
            XCTAssertEqual(try store.list("watch_state").count,0)
            try service.tick(at:base)
            let before = try jsonString(XCTUnwrap(store.get("watch_state",string(workflow,"id"))))
            try Data("preview".utf8).write(to:root.appendingPathComponent("preview.txt"))
            let preview = try call(service,"watches.preview",["project":root.path,"id":workflow["id"]!])
            XCTAssertEqual(preview["wouldMeetMinimum"] as? Bool,true)
            XCTAssertEqual(try jsonString(XCTUnwrap(store.get("watch_state",string(workflow,"id")))),before)
            let run = try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":true])
            XCTAssertEqual(string(run,"state"),"completed")
            XCTAssertEqual(run["dryRun"] as? Bool,true)
            XCTAssertEqual(string((run["steps"] as? [JSON] ?? []).first ?? [:],"state"),"stubbed")
            XCTAssertEqual(try store.list("approval").count,0)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("reviewed.txt").path))
            XCTAssertEqual(try store.list("schedule_event").count,0)
        }
    }
    func testPendingApprovalsRetainLaterChangesAndRejectDoesNotWrite() throws {
        try fixture { root,store,service in
            let workflow = try call(service,"workflows.save",definition(root,write:true))
            try service.tick(at:base)
            try Data("a".utf8).write(to:root.appendingPathComponent("one.txt")); try service.tick(at:base.addingTimeInterval(30))
            try Data("b".utf8).write(to:root.appendingPathComponent("two.txt")); try service.tick(at:base.addingTimeInterval(60))
            XCTAssertEqual(try store.list("run").count,1)
            let state = try XCTUnwrap(store.get("watch_state",string(workflow,"id")))
            XCTAssertEqual((state["pending"] as? JSON)?.count,1)
            let approval = try XCTUnwrap(store.list("approval").first)
            _ = try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"reject"])
            try service.tick(at:base.addingTimeInterval(61))
            XCTAssertEqual(try store.list("run").count,2)
            XCTAssertEqual(try store.list("approval").count,2)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("reviewed.txt").path))
        }
    }
    func testClaimRecoveryBlocksBeforePollingAndAcknowledgementNeverRedispatchesClaim() throws {
        try fixture { root,store,service in
            let workflow = try call(service,"workflows.save",definition(root))
            try service.tick(at:base)
            try Data("a".utf8).write(to:root.appendingPathComponent("one.txt")); try service.tick(at:base.addingTimeInterval(30))
            var event = try XCTUnwrap(store.list("schedule_event").first); event["state"] = "claimed"; _ = try store.put("schedule_event",event)
            let reopened = AutomationService(store:try VelaStore(root:store.root))
            try reopened.tick(at:base.addingTimeInterval(60)); XCTAssertEqual(try store.list("run").count,1)
            XCTAssertEqual(string(try XCTUnwrap(store.get("schedule",string(workflow,"id"))),"state"),"needs_review")
            _ = try reopened.resolveScheduledDispatch(["project":root.path,"id":event["id"]!,"decision":"acknowledge"])
            try reopened.tick(at:base.addingTimeInterval(90)); XCTAssertEqual(try store.list("run").count,1)
            XCTAssertEqual(try store.list("schedule_event").count,1)
        }
    }
    func testPrivateRevocationAndMissingAssetsDropPendingIdentitiesWithoutInjectingOldContent() throws {
        try fixture { root,store,service in
            let workflow = try call(service,"workflows.save",definition(root,tool:"library.retrieve",minimum:2))
            try service.tick(at:base)
            var first = try putLibrary(store,root,"first"); try service.tick(at:base.addingTimeInterval(30))
            first["sourceLabeledPrivate"] = true; _ = try store.put("library",first)
            _ = try putLibrary(store,root,"second"); try service.tick(at:base.addingTimeInterval(60))
            XCTAssertEqual(try store.list("run").count,0)
            let state = try XCTUnwrap(store.get("watch_state",string(workflow,"id")))
            XCTAssertEqual((state["pending"] as? JSON)?.count,1)
            XCTAssertFalse(try jsonString(state["pending"]!).contains("first"))
            let second = try XCTUnwrap(store.get("library","second")); try FileManager.default.removeItem(atPath:string(second,"assetPath"))
            try service.tick(at:base.addingTimeInterval(90))
            XCTAssertEqual((try store.get("watch_state",string(workflow,"id"))?["pending"] as? JSON)?.count,0)
        }
    }
    func testValidationRejectsMutatingToolsInvalidSchemasAndUnusableKeys() throws {
        try fixture { root,store,service in
            for tool in ["file.write","shell.test","connector.call","agent.loop"] {
                var params = definition(root); params["watch"] = ["tool":tool,"arguments":JSON()]
                XCTAssertThrowsError(try call(service,"workflows.save",params))
            }
            for bad: JSON in [["everySeconds":true],["everySeconds":29],["minItems":2],["key":"a..b"],["mode":1]] {
                var params = definition(root), watch = params["watch"] as? JSON ?? [:]; watch.merge(bad) { _,new in new }; params["watch"] = watch
                XCTAssertThrowsError(try call(service,"workflows.save",params))
            }
            var params = definition(root,tool:"library.retrieve"), watch = params["watch"] as? JSON ?? [:]; watch["key"] = "missing"; params["watch"] = watch
            _ = try call(service,"workflows.save",params); _ = try putLibrary(store,root,"first")
            try service.tick(at:base)
            XCTAssertEqual(try store.list("watch_state").count,0)
            XCTAssertEqual(string(try XCTUnwrap(store.list("schedule").first),"state"),"failed")
            XCTAssertEqual(try store.list("run").count,0)
        }
    }
    func testMarkdownWatchRoundTripDisabledResumeBaselineAndCrossProjectPreview() throws {
        try fixture { root,store,service in
            let workflow = try call(service,"workflows.save",definition(root))
            XCTAssertEqual(string(try XCTUnwrap(service.loadCurrentWorkflow(string(workflow,"id"))["watch"] as? JSON),"tool"),"git.status")
            try service.tick(at:base)
            let inspected = try call(service,"workflows.get",["id":workflow["id"]!,"project":root.path])
            _ = try call(service,"workflows.setEnabled",["id":workflow["id"]!,"project":root.path,"snapshotHash":inspected["snapshotHash"]!,"enabled":false])
            try Data("a".utf8).write(to:root.appendingPathComponent("disabled.txt")); try service.tick(at:base.addingTimeInterval(30))
            XCTAssertEqual(try store.list("run").count,0)
            let disabled = try call(service,"workflows.get",["id":workflow["id"]!,"project":root.path])
            _ = try call(service,"workflows.setEnabled",["id":workflow["id"]!,"project":root.path,"snapshotHash":disabled["snapshotHash"]!,"enabled":true])
            try service.tick(at:base.addingTimeInterval(60)); XCTAssertEqual(try store.list("run").count,0)
            XCTAssertThrowsError(try call(service,"watches.preview",["id":workflow["id"]!,"project":"/foreign"]))
        }
    }
    func testNetChangesDuplicateKeysAndPendingBoundsAreExplicit() throws {
        let a = try WorkflowWatch.entries([["id":"a","v":1]],key:"id"), b = try WorkflowWatch.entries([["id":"a","v":2]],key:"id")
        let first = try WorkflowWatch.merge(previous:a,current:b,pending:[:])
        XCTAssertEqual(first.count,1)
        XCTAssertEqual(try WorkflowWatch.merge(previous:b,current:a,pending:first).count,0)
        let addition = try WorkflowWatch.merge(previous:[:],current:a,pending:[:])
        XCTAssertEqual(try WorkflowWatch.merge(previous:a,current:[:],pending:addition).count,0)
        XCTAssertThrowsError(try WorkflowWatch.entries([["id":"same"],["id":"same"]],key:"id"))
        let many = try WorkflowWatch.entries((1...101).map { ["id":"item-\($0)"] },key:"id")
        XCTAssertThrowsError(try WorkflowWatch.merge(previous:[:],current:many,pending:[:]))
    }
    func testActualApprovedProcessReceivesOnlyTheFrozenWatchInput() throws {
        try fixture { root,store,service in
            var params = definition(root)
            params["context"] = ["version":1,"template":"{{input.watch}}","memory":["enabled":false],"inputs":[] as [JSON]]
            params["steps"] = [["tool":"agent.run","arguments":["executable":"/usr/bin/printf","args":["%s",WorkflowContext.promptMarker],"promptMode":"workflow_context"]]]
            _ = try call(service,"workflows.save",params)
            try service.tick(at:base)
            try Data("frozen".utf8).write(to:root.appendingPathComponent("first-event.txt")); try service.tick(at:base.addingTimeInterval(30))
            let approval = try XCTUnwrap(store.list("approval").first)
            XCTAssertTrue(try jsonString(approval).contains("first-event.txt"))
            try Data("later".utf8).write(to:root.appendingPathComponent("later-event.txt")); try service.tick(at:base.addingTimeInterval(60))
            _ = try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
            let run = try XCTUnwrap(store.get("run",string(approval,"runId"))), step = (run["steps"] as? [JSON] ?? []).first ?? [:]
            XCTAssertEqual(string(run,"state"),"completed")
            XCTAssertTrue(string(step,"output").contains("first-event.txt"))
            XCTAssertFalse(string(step,"output").contains("later-event.txt"))
            XCTAssertEqual(try store.list("run").count,1)
        }
    }
    func testConcurrentSchedulersPublishOneEventAndFailedReadRetainsItsWatermark() throws {
        try fixture { root,store,service in
            let workflow = try call(service,"workflows.save",definition(root))
            try service.tick(at:base)
            try Data("new".utf8).write(to:root.appendingPathComponent("race.txt"))
            let services = [service,AutomationService(store:try VelaStore(root:store.root))]
            DispatchQueue.concurrentPerform(iterations:16) { index in try? services[index % 2].tick(at:base.addingTimeInterval(30)) }
            XCTAssertEqual(try store.list("run").count,1); XCTAssertEqual(try store.list("schedule_event").count,1)
            let prior = try jsonString(XCTUnwrap(store.get("watch_state",string(workflow,"id"))))
            try FileManager.default.moveItem(at:root.appendingPathComponent(".git"),to:root.appendingPathComponent("moved-git"))
            try service.tick(at:base.addingTimeInterval(60))
            XCTAssertEqual(try jsonString(XCTUnwrap(store.get("watch_state",string(workflow,"id")))),prior)
            XCTAssertEqual(string(try XCTUnwrap(store.get("schedule",string(workflow,"id"))),"state"),"failed")
            XCTAssertEqual(try store.list("run").count,1)
        }
    }
}
