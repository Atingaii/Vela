import XCTest
@testable import VelaCore

/// Independent regressions for source revocation, schema rejection and recovery.
final class AgentLoopReviewTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-loop-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let raw = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:raw,withIntermediateDirectories:true)
        let root = URL(fileURLWithPath:canonicalProject(raw.path)), store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["project":root.path,"path":root.path,"title":"Loop review"])
        try body(root,store,AutomationService(store:store))
    }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'" }
    private func fake(_ root: URL) throws -> URL {
        let path = root.appendingPathComponent("synthetic-codex")
        let answer: JSON = ["decision":["kind":"final","answer":"Synthetic final answer."]]
        let events: [JSON] = [["type":"thread.started","thread_id":"synthetic-review"],["type":"item.completed","item":["id":"answer","type":"agent_message","text":try jsonString(answer)]],["type":"turn.completed","usage":["input_tokens":20,"output_tokens":10]]]
        let script = "#!/bin/sh\nprintf 'called\\n' >> \(quote(root.appendingPathComponent("calls.txt").path))\nprintf '%s\\0' \"$@\" > \(quote(root.appendingPathComponent("argv.bin").path))\ncat <<'VELA_LOOP_REVIEW_EOF'\n\(try events.map(jsonString).joined(separator:"\n"))\nVELA_LOOP_REVIEW_EOF\n"
        try Data(script.utf8).write(to:path); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path); return path
    }
    private func call(_ service: AutomationService, _ method: String, _ params: JSON) throws -> JSON {
        let valueToUnwrap = try service.handle(method,params) as? JSON
        return try XCTUnwrap(valueToUnwrap)
    }
    private func args(_ binary: URL) -> JSON { ["prompt":"Use the selected read-only facts.","agent":["executable":binary.path,"model":"synthetic-model","reasoningEffort":"low"],"tools":["git.status"],"limits":["maxModelCalls":2,"timeoutSeconds":5,"totalTimeoutSeconds":10]] }
    private func approve(_ service: AutomationService, _ loop: JSON) throws -> JSON {
        let approval = try XCTUnwrap(loop["approval"] as? JSON)
        return try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
    }
    private func get(_ service: AutomationService, _ root: URL, _ loop: JSON) throws -> JSON { try call(service,"loops.get",["project":root.path,"id":loop["id"]!]) }
    private func contextualLoop(_ root: URL, _ store: VelaStore, _ service: AutomationService, _ binary: URL) throws -> (JSON,JSON) {
        let library = try store.put("library",["title":"Cedar source","content":"Cedar_PRIVATE_ORIGIN_SENTINEL is synthetic content.","project":root.path,"private":false,"state":"active"])
        var arguments = args(binary); arguments["promptMode"] = "workflow_context"; arguments["prompt"] = WorkflowContext.promptMarker
        let workflow = try call(service,"workflows.save",["project":root.path,"title":"Source-bound review","context":["version":1,"template":"{{sources}}","inputs":[["id":"sources","retrieve":["query":"Cedar","k":1]]],"memory":["enabled":false]],"steps":[["tool":"agent.loop","arguments":arguments]]])
        _ = try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":false])
        return (library,try get(service,root,XCTUnwrap(store.list("agent_loop").first)))
    }
    func testPrivateOriginRevocationAfterFreezingStopsBeforeTheFirstModelCall() throws {
        try fixture { root,store,service in
            let binary = try fake(root)
            var (source,loop) = try contextualLoop(root,store,service,binary)
            source["sourceLabeledPrivate"] = true; _ = try store.put("library",source)
            let decision = try approve(service,loop)
            XCTAssertEqual(string(decision,"state"),"needs_review")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
        }
    }
    func testMissingFrozenLibraryAssetStopsBeforeTheFirstModelCall() throws {
        try fixture { root,store,service in
            let binary = try fake(root), (source,loop) = try contextualLoop(root,store,service,binary)
            try FileManager.default.removeItem(atPath:string(source,"assetPath"))
            XCTAssertEqual(string(try approve(service,loop),"state"),"needs_review")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
        }
    }
    func testUnsupportedSchemaRepresentationsDoNotSilentlyRelaxConstraints() throws {
        for schema: JSON in [
            ["type":"object","properties":JSON(),"additionalProperties":1],
            ["type":"string","maxLength":1.5],
            ["type":"array","items":["type":"string"],"minItems":0.5],
            ["type":"string","minLength":-1]
        ] {
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(jsonString(schema).utf8)) as? JSON)
            XCTAssertThrowsError(try AgentLoop.validateSchema(parsed))
        }
    }
    func testClaimedOrReceivedCrashRecordsCannotRestartCompletedModelCalls() throws {
        try fixture { root,store,service in
            let binary = try fake(root)
            var params = args(binary); params["project"] = root.path
            let pending = try call(service,"loops.plan",params)
            XCTAssertEqual(string(try approve(service,pending),"state"),"executed")
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("calls.txt")),"called\n")
            let complete = try XCTUnwrap(store.get("agent_loop",string(pending,"id")))
            for phase in ["claimed","response_received","decided"] {
                // Construct durable states from the same actual completed call,
                // as if the helper died before publishing its final ledger.
                var loop = complete; loop["state"] = "running_or_uncertain"
                var rounds = loop["rounds"] as? [JSON] ?? []; rounds[0]["state"] = phase; loop["rounds"] = rounds
                _ = try store.put("agent_loop",loop)
                var approval = try XCTUnwrap(store.get("approval",string(loop,"approvalId"))); approval["state"] = "executing"; _ = try store.put("approval",approval)
                var run = try XCTUnwrap(store.get("run",string(loop,"runId"))); run["state"] = "pending_approval"
                var steps = run["steps"] as? [JSON] ?? []; steps[0]["state"] = "pending_approval"; run["steps"] = steps; _ = try store.put("run",run)
                let reopened = AutomationService(store:try VelaStore(root:store.root))
                XCTAssertEqual(string(try get(reopened,root,loop),"state"),"running_or_uncertain")
                XCTAssertThrowsError(try approve(reopened,pending))
                _ = try? call(reopened,"runs.resume",["id":run["id"]!,"project":root.path])
                XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("calls.txt")),"called\n")
                XCTAssertEqual(try store.list("approval").count,1)
            }
        }
    }
}
