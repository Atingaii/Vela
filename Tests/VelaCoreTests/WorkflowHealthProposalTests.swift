import XCTest
@testable import VelaCore

final class WorkflowHealthProposalTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("vela-health-proposal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let store = try VelaStore(root:root.appendingPathComponent("store")); _ = try store.put("project",["project":root.path,"path":root.path])
        try body(root,store,AutomationService(store:store))
    }
    private func call(_ service: AutomationService,_ method: String,_ params: JSON) throws -> JSON {
        guard let value = try service.handle(method,params) as? JSON else { throw VelaError("Expected JSON response") }
        return value
    }
    private func workflow(_ service: AutomationService,_ root: URL,id: String = "timeout") throws -> JSON {
        try call(service,"workflows.save",["id":id,"title":"Observed timeout","project":root.path,"enabled":true,"steps":[["id":"step-time","title":"Bounded test","tool":"shell.test","arguments":["executable":"/usr/bin/true","args":[String](),"timeoutSeconds":120]]]])
    }
    private func run(_ root: URL,id: String = "run-timeout",state: String = "needs_review") -> JSON {
        ["id":id,"project":root.path,"workflowId":"timeout","workflowVersion":1,"state":state,"dryRun":false,"startedAt":"2026-09-13T00:00:00Z","steps":[["id":"step-time","tool":"shell.test","state":state,"timedOut":true,"truncated":false,"outcomeUnknown":true]]]
    }
    private func proposal(_ service: AutomationService,_ root: URL,runID: String = "run-timeout") throws -> JSON {
        let view = try call(service,"workflows.get",["project":root.path,"id":"timeout"])
        let finding = "timeout_observed:" + String(stableHash(runID + ":step-time").prefix(32))
        return try call(service,"workflows.health.proposeTimeout",["project":root.path,"workflowId":"timeout","workflowVersion":1,"snapshotHash":view["snapshotHash"]!,"runId":runID,"stepId":"step-time","findingId":finding,"newTimeoutSeconds":240])
    }

    func testUncertainTimeoutCreatesOnlyReviewableDisabledCandidate() throws {
        try fixture { root,store,service in
            let original = try workflow(service,root); _ = try store.put("run",run(root))
            let pending = try proposal(service,root)
            XCTAssertEqual(string(pending,"state"),"pending_review"); XCTAssertEqual(pending["sourceOutcomeUnknown"] as? Bool,true)
            XCTAssertEqual(try store.list("workflow").count,1); XCTAssertTrue(try store.list("approval").isEmpty); XCTAssertTrue(try store.list("run").contains { string($0,"id") == "run-timeout" })
            XCTAssertThrowsError(try call(service,"workflows.health.proposal.decide",["project":root.path,"id":pending["id"]!,"proposalHash":pending["proposalHash"]!,"decision":"accept","acknowledgeUncertainSource":false]))
            let accepted = try call(service,"workflows.health.proposal.decide",["project":root.path,"id":pending["id"]!,"proposalHash":pending["proposalHash"]!,"decision":"accept","acknowledgeUncertainSource":true])
            XCTAssertEqual(string(accepted,"state"),"accepted")
            XCTAssertEqual(string(try XCTUnwrap(store.get("workflow","timeout")),"id"),string(original,"id")); XCTAssertEqual(intValue(try XCTUnwrap(store.get("workflow","timeout")),"version"),1)
            let candidate = try XCTUnwrap(store.get("workflow",string(accepted,"acceptedWorkflowId")))
            XCTAssertEqual(candidate["enabled"] as? Bool,false); XCTAssertEqual(intValue(candidate,"version"),1)
            let step = try XCTUnwrap((candidate["steps"] as? [JSON])?.first); XCTAssertEqual(intValue(step["arguments"] as? JSON ?? [:],"timeoutSeconds"),240)
            XCTAssertTrue(try store.list("approval").isEmpty); XCTAssertEqual(try store.list("run").count,1)
        }
    }

    func testRejectCrossProjectAndChangedEvidenceNeverCreateCandidate() throws {
        try fixture { root,store,service in
            _ = try workflow(service,root); _ = try store.put("run",run(root))
            let pending = try proposal(service,root)
            let foreign = root.appendingPathComponent("foreign-health-proposal")
            try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:true); _ = try store.put("project",["project":foreign.path,"path":foreign.path])
            XCTAssertThrowsError(try call(service,"workflows.health.proposal.get",["project":foreign.path,"id":pending["id"]!]))
            _ = try call(service,"workflows.health.proposal.decide",["project":root.path,"id":pending["id"]!,"proposalHash":pending["proposalHash"]!,"decision":"reject"])
            XCTAssertEqual(try store.list("workflow").count,1); XCTAssertEqual(try store.list("run").count,1)
            var fresh = run(root,id:"run-changed"); _ = try store.put("run",fresh)
            let second = try proposal(service,root,runID:"run-changed")
            fresh["changed"] = true; _ = try store.put("run",fresh)
            XCTAssertThrowsError(try call(service,"workflows.health.proposal.decide",["project":root.path,"id":second["id"]!,"proposalHash":second["proposalHash"]!,"decision":"accept","acknowledgeUncertainSource":true]))
            XCTAssertEqual(try store.list("workflow").count,1)
        }
    }

    func testWorkflowSnapshotConflictAndScanCapFailClosedBeforeProposalWrite() throws {
        try fixture { root,store,service in
            _ = try workflow(service,root); _ = try store.put("run",run(root))
            let pending = try proposal(service,root)
            _ = try call(service,"workflows.save",["id":"timeout","title":"Changed reviewed source","project":root.path,"enabled":true,"steps":[["id":"step-time","title":"Bounded test","tool":"shell.test","arguments":["executable":"/usr/bin/true","args":[String](),"timeoutSeconds":120]]]])
            XCTAssertThrowsError(try call(service,"workflows.health.proposal.decide",["project":root.path,"id":pending["id"]!,"proposalHash":pending["proposalHash"]!,"decision":"accept","acknowledgeUncertainSource":true]))
            XCTAssertEqual(try store.list("workflow").count,1)
        }
        try fixture { root,store,service in
            _ = try workflow(service,root)
            for index in 0..<10_000 { _ = try store.put("run",["id":"cap-\(index)","project":root.path,"workflowId":"other","workflowVersion":1,"state":"completed","dryRun":false,"steps":[JSON]()]) }
            let view = try call(service,"workflows.get",["project":root.path,"id":"timeout"])
            let before = try store.list("workflow_health_proposal").count
            XCTAssertThrowsError(try call(service,"workflows.health.proposeTimeout",["project":root.path,"workflowId":"timeout","workflowVersion":1,"snapshotHash":view["snapshotHash"]!,"runId":"cap-0","stepId":"step-time","findingId":"timeout:bad","newTimeoutSeconds":240]))
            XCTAssertEqual(try store.list("workflow_health_proposal").count,before)
        }
    }
}

extension WorkflowHealthProposalTests {
    func testAbsentTimeoutFreezesExistingDefaultBeforeCreatingCandidate() throws {
        try fixture { root,store,service in
            _ = try call(service,"workflows.save",["id":"timeout","title":"Default timeout","project":root.path,"enabled":true,"steps":[["id":"step-time","title":"Bounded test","tool":"shell.test","arguments":["executable":"/usr/bin/true","args":[String]()]]]])
            _ = try store.put("run",run(root))
            let view = try call(service,"workflows.get",["project":root.path,"id":"timeout"])
            let finding = "timeout_observed:" + String(stableHash("run-timeout:step-time").prefix(32))
            let pending = try call(service,"workflows.health.proposeTimeout",["project":root.path,"workflowId":"timeout","workflowVersion":1,"snapshotHash":view["snapshotHash"]!,"runId":"run-timeout","stepId":"step-time","findingId":finding,"newTimeoutSeconds":240])
            XCTAssertEqual(intValue(pending,"fromTimeoutSeconds"),120); XCTAssertEqual(pending["timeoutDefaulted"] as? Bool,true)
        }
    }
}

extension WorkflowHealthProposalTests {
    func testAcceptingProposalRequiresExplicitCasProtectedRecovery() throws {
        try fixture { root,store,service in
            _ = try workflow(service,root); _ = try store.put("run",run(root))
            let pending = try proposal(service,root)
            var claimed = try XCTUnwrap(store.get("workflow_health_proposal",string(pending,"id")))
            claimed["state"] = "accepting"; claimed["decision"] = "accept"
            _ = try store.put("workflow_health_proposal",claimed)
            XCTAssertThrowsError(try call(service,"workflows.health.proposal.decide",["project":root.path,"id":pending["id"]!,"proposalHash":pending["proposalHash"]!,"decision":"accept","acknowledgeUncertainSource":true]))
            let recovered = try call(service,"workflows.health.proposal.decide",["project":root.path,"id":pending["id"]!,"proposalHash":pending["proposalHash"]!,"decision":"recover"])
            XCTAssertEqual(string(recovered,"state"),"pending_review")
            XCTAssertEqual(string(recovered,"decision"),"recovered")
            XCTAssertEqual(try store.list("workflow").count,1)
        }
    }
}
