import XCTest
@testable import VelaCore

final class SessionRelationReviewTests: XCTestCase {
    func testForeignNamespaceReusingPendingCallIDCannotReportUniqueSpawn() throws {
        let parent = "00000000-0000-4000-8000-000000000001"
        let child = "00000000-0000-4000-8000-000000000002"
        var state = SessionRelationProjection.empty()
        SessionRelationProjection.consume(["type":"session_meta","payload":["id":parent,"cwd":"/synthetic/project","source":"cli"] as JSON],reference:[:],state:&state)
        for namespace in ["multi_agent_v1","foreign_namespace"] {
            let call: JSON = ["type":"function_call","name":"spawn_agent","namespace":namespace,"call_id":"same-call","arguments":"{}"]
            SessionRelationProjection.consume(["type":"response_item","payload":call],reference:[:],state:&state)
        }
        SessionRelationProjection.consume(["type":"response_item","payload":["type":"function_call_output","call_id":"same-call","output":try jsonString(["agent_id":child])] as JSON],reference:[:],state:&state)
        XCTAssertFalse((state["events"] as? [JSON] ?? []).contains { string($0,"status") == "reported_spawned" },"An unsupported call reused the identity, so the unnamespaced output has no unique proposal")
    }

    func testConflictingSourceHeadersCannotResolveLatestIdentityAsParent() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-relation-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let project = temporary.appendingPathComponent("project"), logs = temporary.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true)
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        let service = FoundationService(store:store,sourceRoots:["codex":[logs]],globalHome:temporary)
        _ = try store.put("project",["id":stableHash(canonicalProject(project.path)),"path":canonicalProject(project.path),"project":canonicalProject(project.path)])
        let first = "00000000-0000-4000-8000-000000000001", second = "00000000-0000-4000-8000-000000000002", child = "00000000-0000-4000-8000-000000000003"
        func header(_ id: String, parent: String? = nil) -> JSON {
            var payload: JSON = ["id":id,"cwd":project.path,"source":"cli"]
            if let parent { payload["parent_thread_id"] = parent }
            return ["type":"session_meta","payload":payload]
        }
        let ambiguousPath = logs.appendingPathComponent("ambiguous.jsonl"), childPath = logs.appendingPathComponent("child.jsonl")
        try ([header(first),header(second)].map { try jsonString($0) }.joined(separator:"\n") + "\n").write(to:ambiguousPath,atomically:true,encoding:.utf8)
        try (jsonString(header(child,parent:second)) + "\n").write(to:childPath,atomically:true,encoding:.utf8)
        _ = try service.handle("sessions.refresh",[:])
        let resolvedValue = try service.handle("sessions.relations.resolve",["project":project.path,"threadId":second])
        let resolved = try XCTUnwrap(resolvedValue as? JSON)
        XCTAssertNotEqual(string(resolved,"status"),"resolved","Conflicting source headers cannot establish the last observed thread identity")
        let detailValue = try service.handle("sessions.relations.get",["project":project.path,"id":stableHash("codex:" + canonicalProject(childPath.path))])
        let detail = try XCTUnwrap(detailValue as? JSON)
        XCTAssertEqual((detail["parent"] as? JSON)?["resolved"] as? Bool,false)
    }
}
