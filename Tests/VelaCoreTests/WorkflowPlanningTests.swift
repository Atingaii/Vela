import XCTest
@testable import VelaCore

final class WorkflowPlanningTests: XCTestCase {
    private func fixture(_ work: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-planning-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let root = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["title":"Planning fixture","path":root.path,"project":root.path])
        try work(root,store,AutomationService(store:store))
    }
    private func call(_ service: AutomationService, _ method: String, _ params: JSON) throws -> JSON {
        try XCTUnwrap(service.handle(method,params) as? JSON)
    }
    private func answer() -> JSON {
        ["title":"Review current changes","summary":"Summarize tracked changes and current status","template":"Summarize {{git_status.output}} and {{git_diff.output}}","readTools":["git.status","git.diff"],"questions":[],"unresolved":[]]
    }
    private func fake(_ root: URL, result: JSON, complete: Bool = true, tool: Bool = false, exitCode: Int = 0) throws -> URL {
        let executable = root.appendingPathComponent("fake-codex-" + UUID().uuidString)
        var events: [JSON] = [["type":"thread.started","thread_id":"synthetic-planner-session"]]
        if tool { events.append(["type":"item.completed","item":["id":"tool-1","type":"command_execution","command":"touch forbidden","status":"completed","exit_code":0]]) }
        events.append(["type":"item.completed","item":["id":"message-1","type":"agent_message","text":try jsonString(result)]])
        if complete { events.append(["type":"turn.completed","usage":["input_tokens":80,"output_tokens":40]]) }
        let lines = try events.map { try jsonString($0) }.joined(separator:"\n")
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of:"'",with:"'\\''") + "'" }
        let script = "#!/bin/sh\nprintf 'called\\n' >> \(quote(root.appendingPathComponent("calls.txt").path))\nprintf '%s' \"$PWD\" > \(quote(root.appendingPathComponent("cwd.txt").path))\nprintf '%s\\0' \"$@\" > \(quote(root.appendingPathComponent("argv.bin").path))\ncat <<'VELA_SYNTHETIC_PLAN_EOF'\n\(lines)\nVELA_SYNTHETIC_PLAN_EOF\nexit \(exitCode)\n"
        try Data(script.utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        return executable
    }
    private func plan(_ root: URL, _ service: AutomationService, executable: URL, extra: JSON = [:]) throws -> JSON {
        var params: JSON = ["project":root.path,"description":"请总结当前变更；保留原文 ' {{config.secret}}","executable":executable.path,"model":"fixture-model","effort":"high"]
        params.merge(extra) { _,new in new }
        return try call(service,"workflows.plan",params)
    }
    private func approve(_ service: AutomationService, _ plan: JSON) throws -> JSON {
        let approval = try XCTUnwrap(plan["approval"] as? JSON)
        return try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
    }
    private func current(_ root: URL, _ service: AutomationService, _ plan: JSON) throws -> JSON {
        try call(service,"workflows.plan.get",["project":root.path,"id":plan["id"]!])
    }

    func testPlannerRequiresApprovalAndActualCLIOnlyReturnsUnsavedDraft() throws {
        try fixture { root,store,service in
            let binary = try fake(root,result:answer())
            let pending = try plan(root,service,executable:binary,extra:["answers":["只需要本地报告"]])
            XCTAssertEqual(string(pending,"state"),"pending_approval")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
            let decision = try approve(service,pending)
            XCTAssertEqual(string(decision,"state"),"executed")
            let completed = try current(root,service,pending)
            XCTAssertEqual(string(completed,"state"),"draft")
            let draft = try XCTUnwrap(completed["draft"] as? JSON)
            XCTAssertEqual(draft["enabled"] as? Bool,false)
            XCTAssertEqual(string(draft,"trigger"),"manual")
            let draftArgs = try XCTUnwrap(((draft["steps"] as? [JSON])?.first?["arguments"] as? JSON)?["args"] as? [String])
            XCTAssertTrue(draftArgs.contains("mcp_servers={}"))
            XCTAssertTrue(draftArgs.contains("shell_tool"))
            XCTAssertFalse(draftArgs.contains("--output-schema"))
            XCTAssertEqual(try store.list("workflow").count,0)
            XCTAssertEqual(try store.list("guideline").count,0)
            XCTAssertEqual((completed["metrics"] as? JSON)?["tokens"] as? Int,120)
            let cwd = try String(contentsOf:root.appendingPathComponent("cwd.txt"))
            XCTAssertTrue(cwd.contains("vela-workflow-plan-"))
            XCTAssertNotEqual(canonicalProject(cwd),canonicalProject(root.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath:cwd))
            let argv = try Data(contentsOf:root.appendingPathComponent("argv.bin")).split(separator:0).map { String(decoding:$0,as:UTF8.self) }
            XCTAssertTrue(argv.contains("--ignore-user-config"))
            XCTAssertTrue(argv.contains("--ignore-rules"))
            XCTAssertTrue(argv.contains("read-only"))
            XCTAssertTrue(argv.contains("mcp_servers={}"))
            XCTAssertTrue(argv.last?.contains("只需要本地报告") == true)
            XCTAssertTrue(argv.last?.contains("{{config.secret}}") == true)
            XCTAssertThrowsError(try approve(service,pending))
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("calls.txt")),"called\n")
            let listed = try XCTUnwrap(service.handle("workflows.plan.list",["project":root.path]) as? [JSON])
            XCTAssertEqual(listed.count,1)
            XCTAssertNil(listed[0]["rawProtocol"])
            XCTAssertNil(listed[0]["approval"])
            let accepted = try call(service,"workflows.save",draft)
            XCTAssertEqual(accepted["enabled"] as? Bool,false)
        }
    }

    func testUnsupportedToolsExecutableFieldsAndObservedToolCallsAreRejected() throws {
        try fixture { root,store,service in
            var unknown = answer(); unknown["readTools"] = ["slack.post_message"]
            var executable = answer(); executable["executable"] = "/bin/sh"
            var template = answer(); template["template"] = "{{config.secret}}"
            for response in [unknown,executable,template] {
                let pending = try plan(root,service,executable:fake(root,result:response))
                XCTAssertEqual(string(try approve(service,pending),"state"),"failed")
                XCTAssertNil(try current(root,service,pending)["draft"])
            }
            let calledTool = try plan(root,service,executable:fake(root,result:answer(),tool:true))
            XCTAssertEqual(string(try approve(service,calledTool),"state"),"failed")
            XCTAssertEqual(try store.list("workflow").count,0)
            XCTAssertEqual(try store.list("guideline").count,0)
        }
    }

    func testPartialProtocolAndNonzeroProcessNeverProduceDraft() throws {
        try fixture { root,store,service in
            for binary in [try fake(root,result:answer(),complete:false),try fake(root,result:answer(),exitCode:9)] {
                let pending = try plan(root,service,executable:binary)
                XCTAssertEqual(string(try approve(service,pending),"state"),"failed")
                let failed = try current(root,service,pending)
                XCTAssertEqual(string(failed,"state"),"failed")
                XCTAssertNil(failed["draft"])
            }
            XCTAssertEqual(try store.list("workflow").count,0)
        }
    }

    func testFollowupUsesPreviousHashAndPreservesOriginalRequestAndAnswers() throws {
        try fixture { root,_,service in
            var response = answer(); response["questions"] = ["报告需要什么格式？"]; response["unresolved"] = ["Slack is not connected"]
            let binary = try fake(root,result:response)
            let first = try plan(root,service,executable:binary,extra:["answers":["第一轮回答"]])
            _ = try approve(service,first)
            let ready = try current(root,service,first)
            XCTAssertEqual(string(ready,"state"),"needs_clarification")
            XCTAssertNil(ready["draft"])
            XCTAssertThrowsError(try plan(root,service,executable:binary,extra:["previousPlanId":ready["id"]!,"previousPlanHash":"stale"]))
            let next = try plan(root,service,executable:binary,extra:["previousPlanId":ready["id"]!,"previousPlanHash":ready["planHash"]!,"description":"改为纯本地报告","answers":["三条要点"]])
            let request = try XCTUnwrap(next["request"] as? JSON)
            XCTAssertEqual(string(request,"originalRequest"),(first["request"] as? JSON)?["originalRequest"] as? String)
            XCTAssertEqual(request["answerHistory"] as? [String],["第一轮回答","三条要点"])
            XCTAssertEqual(request["previousQuestions"] as? [String],["报告需要什么格式？"])
            XCTAssertEqual(request["round"] as? Int,2)
        }
    }

    func testCancelAndReopenNeverExecuteOrRetryAnUncertainPlan() throws {
        try fixture { root,store,service in
            let binary = try fake(root,result:answer())
            let pending = try plan(root,service,executable:binary)
            let cancelled = try call(service,"workflows.plan.cancel",["project":root.path,"id":pending["id"]!,"planHash":pending["planHash"]!])
            XCTAssertEqual(string(cancelled,"state"),"rejected")
            XCTAssertThrowsError(try approve(service,pending))
            let uncertain = try plan(root,service,executable:binary)
            let approval = try XCTUnwrap(uncertain["approval"] as? JSON)
            _ = try store.claimState(kind:"approval",id:string(approval,"id"),expected:"pending",newState:"executing")
            let reopened = AutomationService(store:try VelaStore(root:store.root))
            let seen = try current(root,reopened,uncertain)
            XCTAssertEqual(string(seen,"state"),"executing_or_uncertain")
            XCTAssertThrowsError(try approve(reopened,uncertain))
            XCTAssertThrowsError(try plan(root,reopened,executable:binary,extra:["previousPlanId":seen["id"]!,"previousPlanHash":seen["planHash"]!]))
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
        }
    }

    func testChangedRequestAndCrossProjectReadFailBeforeExecution() throws {
        try fixture { root,store,service in
            let pending = try plan(root,service,executable:fake(root,result:answer()))
            var changed = try XCTUnwrap(store.get("workflow_plan",string(pending,"id")))
            var request = try XCTUnwrap(changed["request"] as? JSON); request["description"] = "tampered"
            changed["request"] = request; _ = try store.put("workflow_plan",changed)
            XCTAssertEqual(string(try approve(service,pending),"state"),"failed")
            let other = root.deletingLastPathComponent()
            _ = try store.put("project",["title":"Other","path":other.path,"project":other.path])
            XCTAssertThrowsError(try call(service,"workflows.plan.get",["project":other.path,"id":pending["id"]!]))
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
        }
    }
}
