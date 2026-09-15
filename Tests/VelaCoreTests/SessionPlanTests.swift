import XCTest
@testable import VelaCore

final class SessionPlanTests: XCTestCase {
    var root: URL!
    var project: URL!
    var logs: URL!
    var store: VelaStore!
    var service: FoundationService!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: canonicalProject(FileManager.default.temporaryDirectory.path)).appendingPathComponent("vela-session-plan-" + UUID().uuidString)
        project = root.appendingPathComponent("project"); logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for name in ["codex", "claude"] { try FileManager.default.createDirectory(at: logs.appendingPathComponent(name), withIntermediateDirectories: true) }
        store = try VelaStore(root: root.appendingPathComponent("store"))
        service = FoundationService(store: store, sourceRoots: ["codex":[logs.appendingPathComponent("codex")],"claude":[logs.appendingPathComponent("claude")]], globalHome: root.appendingPathComponent("empty-home"))
        _ = try service.handle("projects.add", ["path":project.path])
    }
    override func tearDownWithError() throws {
        service?.stopWatching(); service = nil; store = nil
        if let root { try FileManager.default.removeItem(at: root) }
    }
    func rpc(_ method: String, _ params: JSON = [:]) throws -> JSON {
        let result = try service.handle(method,params)
        return try XCTUnwrap(result as? JSON)
    }
    func source(_ provider: String) -> URL { logs.appendingPathComponent(provider).appendingPathComponent("synthetic.jsonl") }
    func sessionID(_ provider: String) -> String { stableHash(provider + ":" + source(provider).path) }
    func write(_ provider: String, _ rows: [JSON]) throws {
        try Data((try rows.map { try jsonString($0) }.joined(separator:"\n") + "\n").utf8).write(to:source(provider))
    }
    func append(_ provider: String, _ rows: [JSON]) throws {
        let handle = try FileHandle(forWritingTo: source(provider)); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf:Data((try rows.map { try jsonString($0) }.joined(separator:"\n") + "\n").utf8))
    }
    func plan(_ provider: String) throws -> JSON { try rpc("sessions.plan.get",["project":project.path,"id":sessionID(provider)]) }
    func events(_ provider: String) throws -> [JSON] { try rpc("sessions.plan.events",["project":project.path,"id":sessionID(provider),"limit":100])["items"] as? [JSON] ?? [] }
    func header(_ provider: String) -> JSON {
        provider == "codex" ? ["type":"session_meta","payload":["id":"codex-source","cwd":project.path,"cli_version":"0.114.0"]] : ["type":"user","uuid":"header","sessionId":"claude-source","cwd":project.path,"version":"synthetic-sdk-contract","message":["role":"user","content":"Synthetic fixture"]]
    }
    func codex(_ id: String, _ status: String = "completed", content: String = "核验解析") throws -> JSON {
        ["type":"response_item","payload":["type":"function_call","name":"update_plan","call_id":id,"arguments":try jsonString(["plan":[["step":content,"status":status]]])]]
    }
    func codexResult(_ id: String, output: Any = "Plan updated") -> JSON { ["type":"response_item","payload":["type":"function_call_output","call_id":id,"output":output]] }
    func claude(_ id: String, _ tool: String, _ input: JSON) -> JSON {
        ["type":"assistant","uuid":"a-"+id,"message":["role":"assistant","content":[["type":"tool_use","id":id,"name":tool,"input":input]]]]
    }
    func claudeResult(_ id: String, _ output: Any, error: Any = false) -> JSON {
        ["type":"user","uuid":"r-"+id,"message":["role":"user","content":[["type":"tool_result","tool_use_id":id,"is_error":error,"content":"Synthetic acknowledgement"]]],"tool_use_result":output]
    }
    func item(_ status: String = "pending", id: String = "7") -> JSON { ["id":id,"subject":"Build parser","status":status] }

    func testCodexRequiresExactMatchingAcknowledgementAndRetainsSourceProof() throws {
        try write("codex",[header("codex"),try codex("p")]); _ = try rpc("sessions.refresh")
        XCTAssertEqual(try plan("codex")["available"] as? Bool,false)
        XCTAssertTrue(try plan("codex")["total"] is NSNull)
        try append("codex",[codexResult("wrong"),["type":"event_msg","payload":["type":"task_complete"]]])
        _ = try rpc("sessions.refresh"); XCTAssertEqual(try plan("codex")["available"] as? Bool,false)
        try append("codex",[codexResult("p")]); _ = try rpc("sessions.refresh")
        let actual = try plan("codex"), counts = actual["counts"] as? JSON ?? [:]
        XCTAssertEqual(counts["completed"] as? Int,1); XCTAssertEqual(actual["workVerified"] as? Bool,false)
        XCTAssertEqual(string(actual,"sourceSessionId"),"codex-source"); XCTAssertEqual(string(actual,"providerVersion"),"0.114.0")
        let proof = try XCTUnwrap(events("codex").last?["source"] as? JSON)
        XCTAssertFalse(string(proof,"sha256").isEmpty); XCTAssertGreaterThan(intValue(proof,"byteOffset"),0)
        XCTAssertNotNil(proof["callSource"] as? JSON)
        let visible = try rpc("sessions.get",["id":sessionID("codex")])
        XCTAssertEqual((visible["plan"] as? JSON)?["available"] as? Bool,true)
        XCTAssertNil((visible["plan"] as? JSON)?["pending"])
    }
    func testCodexFailureDuplicateAndOrdinaryTextCannotCompletePlan() throws {
        try write("codex",[header("codex"),try codex("bad"),codexResult("bad",output:"Error: failed"),
                           try codex("repeat"),try codex("repeat"),codexResult("repeat"),
                           ["type":"response_item","payload":["type":"message","role":"assistant","content":[["type":"output_text","text":"All tasks completed. Plan updated"]]]]])
        _ = try rpc("sessions.refresh")
        XCTAssertEqual(try plan("codex")["available"] as? Bool,false)
        XCTAssertTrue(try events("codex").contains { string($0,"state") == "unknown" })
    }
    func testCodexContentArrayAcknowledgementAndUnknownStatusAreExplicit() throws {
        try write("codex",[header("codex"),try codex("future","blocked_by_future"),codexResult("future",output:[["type":"input_text","text":"Plan updated"]])])
        _ = try rpc("sessions.refresh")
        let rows = try plan("codex")["items"] as? [JSON] ?? []
        XCTAssertEqual(string(rows[0],"status"),"unknown"); XCTAssertEqual(string(rows[0],"sourceStatus"),"blocked_by_future")
        XCTAssertEqual((try plan("codex")["counts"] as? JSON)?["completed"] as? Int,0)
    }
    func testClaudeTodoUsesPersistedOutputNotProposedCompletionAndEmptyIsKnown() throws {
        let proposed: JSON = ["content":"Ship","status":"completed","activeForm":"Shipping"]
        let persisted: JSON = ["content":"Ship","status":"pending","activeForm":"Shipping"]
        try write("claude",[header("claude"),claude("t","TodoWrite",["todos":[proposed]]),claudeResult("t",["oldTodos":[],"newTodos":[persisted]])])
        _ = try rpc("sessions.refresh")
        XCTAssertEqual((try plan("claude")["counts"] as? JSON)?["pending"] as? Int,1)
        try append("claude",[claude("empty","TodoWrite",["todos":[]]),claudeResult("empty",["oldTodos":[persisted],"newTodos":[]])]); _ = try rpc("sessions.refresh")
        XCTAssertEqual(try plan("claude")["available"] as? Bool,true); XCTAssertEqual(try plan("claude")["total"] as? Int,0)
    }
    func testClaudeTaskLifecycleRequiresSuccessfulStatusChangeAndSupportsDeletion() throws {
        try write("claude",[header("claude"),claude("create","TaskCreate",["subject":"Build parser","description":"Synthetic","active_form":"Building"]),claudeResult("create",["task":["id":"7","subject":"Build parser"]]),
                           claude("fail","TaskUpdate",["taskId":"7","status":"completed"]),claudeResult("fail",["success":false,"taskId":"7","updatedFields":[],"error":"Synthetic failure"]),
                           claude("noop","TaskUpdate",["taskId":"7","status":"completed"]),claudeResult("noop",["success":true,"taskId":"7","updatedFields":[]])])
        _ = try rpc("sessions.refresh")
        XCTAssertEqual((try plan("claude")["counts"] as? JSON)?["pending"] as? Int,1)
        try append("claude",[claude("done","TaskUpdate",["task_id":"7","status":"completed"]),claudeResult("done",["success":true,"taskId":"7","updatedFields":["status"],"statusChange":["from":"pending","to":"completed"]])]); _ = try rpc("sessions.refresh")
        XCTAssertEqual((try plan("claude")["counts"] as? JSON)?["completed"] as? Int,1)
        try append("claude",[claude("delete","TaskUpdate",["id":"7","status":"deleted"]),claudeResult("delete",["success":true,"taskId":"7","updatedFields":["status"],"statusChange":["from":"completed","to":"deleted"]])]); _ = try rpc("sessions.refresh")
        XCTAssertEqual(try plan("claude")["total"] as? Int,0)
        XCTAssertEqual((try plan("claude")["counts"] as? JSON)?["deleted"] as? Int,1)
        XCTAssertTrue(try events("claude").contains { string($0,"state") == "failed" })
    }
    func testTaskListReplacesSnapshotTaskGetIsPartialAndUnknownUpdateIsNotCreated() throws {
        try write("claude",[header("claude"),claude("unknown","TaskUpdate",["taskId":"7","status":"completed"]),claudeResult("unknown",["success":true,"taskId":"7","updatedFields":["status"],"statusChange":["from":"pending","to":"completed"]]),
                           claude("get","TaskGet",["taskId":"7"]),claudeResult("get",["task":item()])])
        _ = try rpc("sessions.refresh"); XCTAssertEqual(try plan("claude")["itemSetComplete"] as? Bool,false)
        try append("claude",[claude("missing","TaskGet",["taskId":"7"]),claudeResult("missing",["task":NSNull()]),claude("list","TaskList",[:]),claudeResult("list",["tasks":[item("completed",id:"9")]])]); _ = try rpc("sessions.refresh")
        let rows = try plan("claude")["items"] as? [JSON] ?? []
        XCTAssertEqual(rows.count,1); XCTAssertEqual(string(rows[0],"id"),"9"); XCTAssertEqual(try plan("claude")["itemSetComplete"] as? Bool,true)
    }
    func testResultErrorInvalidBooleanAmbiguousBlocksAndUndocumentedAliasDoNotCommit() throws {
        let create = ["subject":"Build parser","description":"Synthetic"]
        var camel = claudeResult("camel",["task":["id":"7","subject":"Build parser"]]); camel["toolUseResult"] = camel.removeValue(forKey:"tool_use_result")
        var multiple = claudeResult("multi",["task":["id":"7","subject":"Build parser"]])
        multiple["message"] = ["role":"user","content":[["type":"tool_result","tool_use_id":"multi"],["type":"tool_result","tool_use_id":"another"]]]
        try write("claude",[header("claude"),claude("error","TaskCreate",create),claudeResult("error",["task":["id":"7","subject":"Build parser"]],error:true),
                           claude("numeric","TaskCreate",create),claudeResult("numeric",["task":["id":"7","subject":"Build parser"]],error:0),claude("camel","TaskCreate",create),camel,
                           claude("multi","TaskCreate",create),multiple])
        _ = try rpc("sessions.refresh"); XCTAssertEqual(try plan("claude")["available"] as? Bool,false)
    }
    func testRestartBetweenCallAndResultKeepsCorrelationAndNoRefreshDuplicates() throws {
        try write("codex",[header("codex"),try codex("restart")]); _ = try rpc("sessions.refresh")
        service = FoundationService(store:store,sourceRoots:["codex":[logs.appendingPathComponent("codex")]],globalHome:root.appendingPathComponent("empty-home"))
        try append("codex",[codexResult("restart")]); _ = try rpc("sessions.refresh")
        XCTAssertEqual(try plan("codex")["confirmedRevision"] as? Int,1)
        _ = try rpc("sessions.refresh"); XCTAssertEqual(try events("codex").count,2)
    }
    func testSameSizeRewriteAndTruncationDoNotKeepOldCompletion() throws {
        try write("codex",[header("codex"),try codex("a"),codexResult("a")]); _ = try rpc("sessions.refresh")
        let old = try Data(contentsOf:source("codex")), text = String(data:old,encoding:.utf8)!
        try Data(text.replacingOccurrences(of:"completed",with:"not_known").utf8).write(to:source("codex"))
        XCTAssertEqual(try Data(contentsOf:source("codex")).count,old.count)
        _ = try rpc("sessions.refresh"); XCTAssertEqual((try plan("codex")["counts"] as? JSON)?["unknown"] as? Int,1)
        try write("codex",[header("codex")]); _ = try rpc("sessions.refresh")
        XCTAssertEqual(try plan("codex")["available"] as? Bool,false)
    }
    func testScopeChangeAndMalformedGapCannotCorrelateEarlierProposal() throws {
        try write("codex",[header("codex"),try codex("cross"),["type":"turn_context","payload":["cwd":root.appendingPathComponent("other").path]],codexResult("cross")])
        _ = try rpc("sessions.refresh")
        XCTAssertThrowsError(try plan("codex"))
        try write("codex",[header("codex"),try codex("gap")]); _ = try rpc("sessions.refresh")
        let handle = try FileHandle(forWritingTo:source("codex")); try handle.seekToEnd(); try handle.write(contentsOf:Data("malformed\n".utf8)); try handle.close()
        _ = try rpc("sessions.refresh")
        try append("codex",[codexResult("gap")]); _ = try rpc("sessions.refresh")
        XCTAssertEqual(try plan("codex")["available"] as? Bool,false)
    }
    func testBudgetsPaginationAndCrossProjectReadAreStrict() throws {
        var rows = [header("codex")]
        for index in 0..<80 { rows.append(try codex("p-\(index)")); rows.append(codexResult("p-\(index)")) }
        try write("codex",rows); _ = try rpc("sessions.refresh")
        let page = try rpc("sessions.plan.events",["project":project.path,"id":sessionID("codex"),"limit":7])
        XCTAssertEqual((page["items"] as? [JSON])?.count,7); XCTAssertEqual(page["eventsTruncated"] as? Bool,true)
        XCTAssertGreaterThan(intValue(page,"oldestRetainedSequence"),1)
        XCTAssertThrowsError(try rpc("sessions.plan.events",["project":project.path,"id":sessionID("codex"),"limit":true]))
        XCTAssertThrowsError(try rpc("sessions.plan.get",["project":project.path,"id":sessionID("codex"),"path":"/etc/passwd"]))
        XCTAssertThrowsError(try rpc("sessions.plan.get",["project":root.path,"id":sessionID("codex")]))
        XCTAssertThrowsError(try rpc("sessions.plan.get",["id":sessionID("codex")]))
        XCTAssertEqual(try rpc("sessions.plan.describe")["readOnly"] as? Bool,true)
    }
    func testOversizedAndConflictingTaskInputsRemainUnavailable() throws {
        let tooMany = (0...256).map { ["content":"item-\($0)","status":"completed"] }
        try write("claude",[header("claude"),claude("large","TodoWrite",["todos":tooMany]),claudeResult("large",["newTodos":tooMany]),
                           claude("conflict","TaskUpdate",["taskId":"7","task_id":"8","status":"completed"]),claudeResult("conflict",["success":true,"taskId":"7","updatedFields":["status"],"statusChange":["from":"pending","to":"completed"]])])
        _ = try rpc("sessions.refresh"); XCTAssertEqual(try plan("claude")["available"] as? Bool,false)
    }

    func testMalformedRepeatedCallCannotBorrowEarlierValidProposal() throws {
        try write("codex",[header("codex"),try codex("reused"),
                           ["type":"response_item","payload":["type":"function_call","name":"update_plan","call_id":"reused","arguments":"malformed"]],codexResult("reused")])
        _ = try rpc("sessions.refresh"); XCTAssertEqual(try plan("codex")["available"] as? Bool,false)
    }
    func testSessionIdentityChangeCannotKeepOldPlanOrPendingCorrelation() throws {
        try write("codex",[header("codex"),try codex("old"),codexResult("old"),try codex("pending")]); _ = try rpc("sessions.refresh")
        try append("codex",[["type":"session_meta","payload":["id":"new-source","cwd":project.path,"cli_version":"0.114.0"]],codexResult("pending")])
        _ = try rpc("sessions.refresh"); XCTAssertEqual(try plan("codex")["available"] as? Bool,false)
        XCTAssertEqual(string(try plan("codex"),"sourceSessionId"),"new-source")
    }
    func testTaskFamilySwitchDoesNotMergeOldTodoListIntoNewTaskIDs() throws {
        let todo: JSON = ["content":"Old todo","status":"completed","activeForm":"Doing"]
        try write("claude",[header("claude"),claude("todo","TodoWrite",["todos":[todo]]),claudeResult("todo",["newTodos":[todo]]),
                           claude("task","TaskCreate",["subject":"New task","description":"Synthetic"]),claudeResult("task",["task":["id":"7","subject":"New task"]])])
        _ = try rpc("sessions.refresh"); XCTAssertEqual(try plan("claude")["total"] as? Int,1)
        XCTAssertEqual((try plan("claude")["counts"] as? JSON)?["completed"] as? Int,0)
        XCTAssertEqual(try plan("claude")["itemSetComplete"] as? Bool,false)
    }
    func testNumericStructuredSuccessAndMismatchedMessageRoleFailClosed() throws {
        var mismatch = claude("mismatch","TaskCreate",["subject":"New task","description":"Synthetic"]); mismatch["type"] = "user"
        try write("claude",[header("claude"),mismatch,claudeResult("mismatch",["task":["id":"7","subject":"New task"]]),
                           claude("numeric","TaskCreate",["subject":"New task","description":"Synthetic"]),claudeResult("numeric",["success":1,"task":["id":"7","subject":"New task"]])])
        _ = try rpc("sessions.refresh"); XCTAssertEqual(try plan("claude")["available"] as? Bool,false)
    }
    func testConcurrentReadersCannotDuplicatePlanRevisionsOrOverwriteLaterCursor() throws {
        var rows = [header("codex")]
        for index in 0..<30 { rows.append(try codex("c-\(index)")); rows.append(codexResult("c-\(index)")) }
        try write("codex",rows)
        let group = DispatchGroup()
        let rootPath = root.appendingPathComponent("store"), sourceRoot = logs.appendingPathComponent("codex"), isolatedHome = root.appendingPathComponent("empty-home")
        for _ in 0..<6 {
            group.enter(); DispatchQueue.global(qos:.userInitiated).async {
                defer { group.leave() }
                if let another = try? VelaStore(root:rootPath) {
                    let reader = FoundationService(store:another,sourceRoots:["codex":[sourceRoot]],globalHome:isolatedHome)
                    _ = try? reader.handle("sessions.refresh",[:])
                }
            }
        }
        XCTAssertEqual(group.wait(timeout:.now()+10),.success)
        _ = try rpc("sessions.refresh")
        XCTAssertEqual(try plan("codex")["confirmedRevision"] as? Int,30)
        XCTAssertEqual(try events("codex").count,60)
        let saved = try store.get("ingestion",stableHash(source("codex").path))
        XCTAssertEqual(saved?["offset"] as? Int,try Data(contentsOf:source("codex")).count)
    }
    func testPlanEventRetentionDoesNotTrimExplicitHistoryOriginals() throws {
        var rows = [header("codex")]
        for index in 0..<70 { rows.append(try codex("history-\(index)")); rows.append(codexResult("history-\(index)")) }
        try write("codex",rows); _ = try rpc("sessions.refresh")
        XCTAssertEqual(try rpc("sessions.plan.events",["project":project.path,"id":sessionID("codex")])["eventsTruncated"] as? Bool,true)
        var inventory = try rpc("history.discover",["project":project.path,"provider":"codex"])
        while string(inventory,"state") != "completed" {
            inventory = try rpc("history.discover",["project":project.path,"inventoryId":string(inventory,"id")])
        }
        let sources = try rpc("history.sources",["project":project.path,"inventoryId":string(inventory,"id")])["items"] as? [JSON] ?? []
        let chosen = try XCTUnwrap(sources.first)
        var epoch = try rpc("history.start",["project":project.path,"sourceId":string(chosen,"id")])
        while string(epoch,"state") == "pending" { epoch = try rpc("history.advance",["project":project.path,"id":string(epoch,"id"),"batchRecords":13]) }
        XCTAssertEqual(epoch["records"] as? Int,rows.count); XCTAssertEqual(epoch["rawBytesComplete"] as? Bool,true)
        let original = try rpc("history.raw",["project":project.path,"id":string(epoch,"id"),"ordinal":1])
        XCTAssertEqual(Data(base64Encoded:string(original,"dataBase64")),Data((try jsonString(rows[1])+"\n").utf8))
    }
}
