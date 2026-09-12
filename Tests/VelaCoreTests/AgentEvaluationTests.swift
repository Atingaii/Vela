import XCTest
@testable import VelaCore

final class AgentEvaluationTests: XCTestCase {
    private func fixture(_ work: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-agent-evaluation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let root = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["path":root.path,"project":root.path,"title":"Agent acceptance fixture"])
        try work(root,store,AutomationService(store:store))
    }
    private func eventStream() throws -> String {
        let events: [JSON] = [
            ["type":"thread.started","thread_id":"provider-session-1"],
            ["type":"item.completed","item":["id":"test-1","type":"command_execution","command":"/bin/zsh -lc '/usr/bin/python3 verify.py'","exit_code":0,"status":"completed","aggregated_output":"passed"]],
            ["type":"item.completed","item":["id":"test-1","type":"command_execution","command":"/usr/bin/python3 verify.py","exit_code":0,"status":"completed"]],
            ["type":"item.completed","item":["id":"message-1","type":"agent_message","text":"Verified."]],
            ["type":"turn.completed","usage":["input_tokens":1000,"cached_input_tokens":200,"output_tokens":100]]
        ]
        return try events.map(jsonString).joined(separator:"\n")
    }
    func testProtocolUsesActualCompletedEventsAndNeverInfersMissingUsage() throws {
        let result = AgentEvaluation.metrics(try eventStream(),truncated:false,verificationCommand:["/usr/bin/python3","verify.py"])
        XCTAssertEqual(result["protocolComplete"] as? Bool,true)
        XCTAssertEqual(result["testInvocations"] as? Int,1)
        XCTAssertEqual(result["toolCalls"] as? Int,1)
        XCTAssertEqual(result["tokens"] as? Int,1100)
        XCTAssertTrue(result["corrections"] is NSNull)
        let clipped = AgentEvaluation.metrics(try eventStream(),truncated:true,verificationCommand:["/usr/bin/python3","verify.py"])
        XCTAssertEqual(clipped["protocolComplete"] as? Bool,false)
        XCTAssertTrue(clipped["tokens"] is NSNull)
        XCTAssertTrue(clipped["testInvocations"] is NSNull)
        let missing = AgentEvaluation.metrics("{\"type\":\"turn.completed\"}",truncated:false,verificationCommand:[])
        XCTAssertTrue(missing["tokens"] is NSNull)
        XCTAssertEqual(missing["protocolComplete"] as? Bool,false)
    }
    func testTestCommandMatchingRejectsEchoSubstitutionAndDifferentExecutable() throws {
        let expected = ["/usr/bin/python3","verify.py"]
        XCTAssertTrue(AgentEvaluation.matchesVerification("/bin/zsh -lc '/usr/bin/python3 verify.py'",expected:expected))
        XCTAssertFalse(AgentEvaluation.matchesVerification("echo '/usr/bin/python3 verify.py'",expected:expected))
        XCTAssertFalse(AgentEvaluation.matchesVerification("/tmp/fake/python3 verify.py",expected:expected))
        XCTAssertFalse(AgentEvaluation.matchesVerification("/usr/bin/python3 verify.py; true",expected:expected))
        XCTAssertNil(AgentEvaluation.shellWords("python3 \"$(touch marker)\""))
        XCTAssertNil(AgentEvaluation.shellWords("python3 \"`touch marker`\""))
        XCTAssertEqual(AgentEvaluation.verificationMatch("/bin/zsh -lc '/usr/bin/python3 verify.py && echo summary'",expected:expected),"unconditional_leading_invocation")
        XCTAssertNil(AgentEvaluation.verificationMatch("/bin/zsh -lc 'false && /usr/bin/python3 verify.py'",expected:expected))
        XCTAssertNil(AgentEvaluation.verificationMatch("/bin/zsh -lc 'echo /usr/bin/python3 verify.py'",expected:expected))
        XCTAssertFalse(AgentEvaluation.matchesVerification("/bin/zsh -lc '/usr/bin/python3\nverify.py'",expected:expected))
        XCTAssertNil(AgentEvaluation.verificationMatch("/bin/zsh -lc '/usr/bin/python3\nverify.py'",expected:expected))
    }
    private func sample(_ variant: String, success: Bool = true, ranTests: Bool, tokens: Int = 1000) -> JSON {
        ["variant":variant,"exitCode":0,"timedOut":false,"durationMs":100,"verificationIntact":true,"verification":["exitCode":success ? 0 : 1],"agentMetrics":["protocolComplete":true,"successfulTestInvocations":ranTests ? 1 : 0,"testExecutionObserved":ranTests,"tokens":tokens]]
    }
    func testWorseMissingAndTiedCandidatesCannotBecomePromotionReady() throws {
        try fixture { _,_,service in
            let baseline = (0..<3).map {_ in sample("baseline",ranTests:true)}
            let worse = (0..<3).map {_ in sample("candidate",success:false,ranTests:false)}
            XCTAssertEqual(string(service.agentEvaluationSummary(baseline+worse,expectedRepetitions:3),"decision"),"reject")
            let tie = (0..<3).map {_ in sample("candidate",ranTests:true)}
            XCTAssertEqual(string(service.agentEvaluationSummary(baseline+tie,expectedRepetitions:3),"decision"),"inconclusive")
            XCTAssertEqual(string(service.agentEvaluationSummary(baseline+Array(tie.prefix(1)),expectedRepetitions:3),"decision"),"inconclusive")
            let costly = (0..<3).map {_ in sample("candidate",ranTests:true,tokens:3000)}
            XCTAssertEqual(string(service.agentEvaluationSummary(baseline+costly,expectedRepetitions:3),"decision"),"reject")
            let noTestBaseline = (0..<3).map {_ in sample("baseline",ranTests:false)}
            XCTAssertEqual(string(service.agentEvaluationSummary(noTestBaseline+tie,expectedRepetitions:3),"decision"),"ready_for_review")
            let large = (0..<5).map {_ in sample("candidate",ranTests:true,tokens:Int.max/2)}
            let hugeSummary = service.agentEvaluationSummary(large,expectedRepetitions:5)
            XCTAssertTrue(((hugeSummary["candidate"] as? JSON)?["averageTokens"] as? Double)?.isFinite == true)
        }
    }
    func testHookSupersessionProjectPrivacyAndReceipts() throws {
        try fixture { root,store,service in
            let memory = MemoryService(store:store)
            let previous = try XCTUnwrap(memory.handle("memory.save",["title":"Manager","content":"Use npm","project":root.path,"state":"active"]) as? JSON)
            let next = try XCTUnwrap(memory.handle("memory.save",["title":"Manager","content":"Use pnpm","project":root.path]) as? JSON)
            _ = try memory.handle("memory.transition",["id":next["id"]!,"state":"active","supersedes":previous["id"]!])
            _ = try memory.handle("memory.save",["title":"Private","content":"never send private sentinel","project":root.path,"state":"active","private":true])
            let event: JSON = ["hook_event_name":"SessionStart","session_id":"provider-session-1","cwd":root.path,"source":"startup","model":"fixture-model"]
            let result = try service.hookContext(["project":root.path,"event":event])
            let context = string(result["hookSpecificOutput"] as? JSON ?? [:],"additionalContext")
            XCTAssertTrue(context.contains("Use pnpm")); XCTAssertFalse(context.contains("Use npm")); XCTAssertFalse(context.contains("private sentinel"))
            _ = try service.hookContext(["project":root.path,"event":event])
            XCTAssertEqual(try store.list("recall_receipt").count,1)
            var wrong = event; wrong["cwd"] = root.deletingLastPathComponent().path
            XCTAssertThrowsError(try service.hookContext(["project":root.path,"event":wrong]))
            let outcomes = try service.reuseOutcomes(["project":root.path,"id":next["id"]!])
            XCTAssertEqual(intValue(outcomes,"offeredSessions"),1)
            XCTAssertEqual(intValue(outcomes,"matchedSessions"),0)
            XCTAssertTrue(outcomes["verificationCorrectionCount"] is NSNull)
            XCTAssertTrue(outcomes["correctionRateReduction"] is NSNull)
        }
    }
    func testHookInstallPreservesOtherHooksAndRejectsStaleEdits() throws {
        try fixture { root,_,service in
            let directory = root.appendingPathComponent(".codex")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let path = directory.appendingPathComponent("hooks.json")
            let before = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo existing\"}]}]}}"
            try Data(before.utf8).write(to:path)
            let draft = try service.previewReuseHook(["project":root.path,"helperExecutable":"/usr/bin/true"])
            XCTAssertTrue(string((draft["operations"] as? [JSON] ?? [[:]])[0],"content").contains("echo existing"))
            XCTAssertEqual(try String(contentsOf:path),before)
            try Data("manual edit".utf8).write(to:path)
            XCTAssertThrowsError(try service.applySuggestion(["id":draft["id"]!]))
            XCTAssertEqual(try String(contentsOf:path),"manual edit")
        }
    }
    func testReuseJoinRequiresCodexProviderAndCountsCopiedLogsOnce() throws {
        try fixture { root,store,service in
            let memory = try store.put("memory",["title":"Verification","content":"Run tests before handoff.","scope":"project","project":root.path,"state":"active"])
            let event: JSON = ["hook_event_name":"SessionStart","session_id":"shared-id","cwd":root.path,"source":"startup"]
            _ = try service.hookContext(["project":root.path,"event":event])
            let receipts = try store.list("recall_receipt")
            XCTAssertEqual(receipts.count,1)
            XCTAssertEqual(receipts.first?["provider"] as? String,"codex")
            // These are synthetic persisted records for a join test, not model activity.
            for (id,provider,source,internalRun) in [("codex-original","codex","shared-id",false),("codex-copy","codex","shared-id",false),("claude-collision","claude","shared-id",false),("cursor-collision","cursor","shared-id",false),("codex-internal","codex","shared-id",true),("codex-other","codex","other-id",false)] {
                _ = try store.put("session",["id":id,"provider":provider,"sourceSessionId":source,"project":root.path,"internalRun":internalRun])
                _ = try store.put("signal",["id":"signal-" + id,"sourceSession":id,"sourceMessage":"message-1","project":root.path,"clusterKey":"verification"])
            }
            _ = try store.put("session",["id":"other-project","provider":"codex","sourceSessionId":"shared-id","project":root.path + "-other"])
            func assertJoin() throws {
                let result = try service.reuseOutcomes(["project":root.path,"id":memory["id"]!])
                XCTAssertEqual(result["offeredSessions"] as? Int,1)
                XCTAssertEqual(result["matchedSessions"] as? Int,1)
                XCTAssertEqual(result["indexedSessionRecords"] as? Int,2)
                XCTAssertEqual(result["sessionIds"] as? [String],["codex-copy","codex-original"])
                XCTAssertEqual(Set((result["observedVerificationSignals"] as? [JSON] ?? []).map {string($0,"sourceSession")}),Set(["codex-copy","codex-original"]))
                XCTAssertTrue(result["verificationCorrectionCount"] is NSNull)
                XCTAssertTrue(result["correctionRateReduction"] is NSNull)
            }
            try assertJoin()
            var legacy = try XCTUnwrap(receipts.first); legacy.removeValue(forKey:"provider")
            _ = try store.put("recall_receipt",legacy)
            try assertJoin()
            legacy["delivery"] = "unknown"
            _ = try store.put("recall_receipt",legacy)
            let unknown = try service.reuseOutcomes(["project":root.path,"id":memory["id"]!])
            XCTAssertEqual(unknown["matchedSessions"] as? Int,0)
            XCTAssertEqual(unknown["offeredSessions"] as? Int,0)
            legacy["provider"] = "claude"; legacy["delivery"] = "provided_to_hook_stdout"
            _ = try store.put("recall_receipt",legacy)
            let wrongProvider = try service.reuseOutcomes(["project":root.path,"id":memory["id"]!])
            XCTAssertEqual(wrongProvider["matchedSessions"] as? Int,0)
        }
    }
    func testPromotionRejectsChangedMemoryAndOnlyActivatesTestedContext() throws {
        try fixture { root,store,service in
            let memory = try store.put("memory",["title":"Verification","content":"Run the project tests before handoff.","scope":"project","project":root.path,"state":"candidate"])
            let snapshot: JSON = ["id":memory["id"]!,"title":memory["title"]!,"content":memory["content"]!,"contentHash":stableHash(string(memory,"title") + "\n" + string(memory,"content"))]
            // Synthetic service-state fixture tests the promotion guard; this is not an agent experiment.
            let noTests = try [["type":"thread.started","thread_id":"baseline"] as JSON,["type":"turn.completed","usage":["input_tokens":1000,"output_tokens":100]] as JSON].map(jsonString).joined(separator:"\n")
            let rows = try (0..<3).flatMap { _ -> [JSON] in
                var b = sample("baseline",ranTests:false); b["output"] = noTests; b["truncated"] = false
                var c = sample("candidate",ranTests:true); c["output"] = try eventStream(); c["truncated"] = false
                return [b,c]
            }
            let evaluation = try store.put("eval",["project":root.path,"state":"completed","evaluator":"codex_agent","repetitions":3,"command":["/usr/bin/python3","verify.py"],"results":rows,"summary":["decision":"ready_for_review"],"candidate":["files":[],"memories":[snapshot],"context":string(memory,"title") + "\n" + string(memory,"content")]])
            var edited = memory; edited["content"] = "Do something untested"; _ = try store.put("memory",edited)
            XCTAssertThrowsError(try service.promoteEvaluation(["id":evaluation["id"]!]))
            XCTAssertEqual(try store.get("memory",string(memory,"id"))?["state"] as? String,"candidate")
            _ = try store.put("memory",memory)
            _ = try service.promoteEvaluation(["id":evaluation["id"]!])
            XCTAssertEqual(try store.get("memory",string(memory,"id"))?["state"] as? String,"active")
            XCTAssertEqual(try store.get("memory",string(memory,"id"))?["sourceEvalId"] as? String,string(evaluation,"id"))
            XCTAssertThrowsError(try service.promoteEvaluation(["id":evaluation["id"]!]))
        }
    }
}
