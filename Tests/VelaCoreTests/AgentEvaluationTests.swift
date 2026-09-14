import XCTest
@testable import VelaCore

final class AgentEvaluationTests: XCTestCase {
    private func fixture(_ work: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-agent-evaluation-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at:temporary) }
        let rawRoot = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:rawRoot,withIntermediateDirectories:true)
        let root = URL(fileURLWithPath:canonicalProject(rawRoot.path))
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["id":stableHash(root.path),"path":root.path,"project":root.path,"title":"Agent acceptance fixture"])
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
    private func completedPromotionEvaluation(_ service: AutomationService, store: VelaStore, project: URL, memoryIDs: [String]) throws -> JSON {
        // The candidate receipt must come from the same Lab variant freezer that
        // production uses. In particular, sourceHash is never hand-authored here.
        for id in memoryIDs {
            let memory = try XCTUnwrap(store.get("memory",id))
            XCTAssertEqual(string(memory,"project"),project.path)
            XCTAssertEqual(string(memory,"scope"),"project")
            XCTAssertEqual(string(memory,"state"),"candidate")
            XCTAssertEqual(memory["private"] as? Bool,false)
        }
        let candidate = try service.evaluationVariant(["memoryIds":memoryIDs],project:project.path)
        let receipts = candidate["memories"] as? [JSON] ?? []
        XCTAssertEqual(receipts.count,memoryIDs.count)
        XCTAssertTrue(receipts.allSatisfy { !string($0,"sourceHash").isEmpty })
        let noTests = try [["type":"thread.started","thread_id":"baseline"] as JSON,["type":"turn.completed","usage":["input_tokens":1000,"output_tokens":100]] as JSON].map(jsonString).joined(separator:"\n")
        let rows = try (0..<3).flatMap { _ -> [JSON] in
            var baseline = sample("baseline",ranTests:false); baseline["output"] = noTests; baseline["truncated"] = false
            var candidateRun = sample("candidate",ranTests:true); candidateRun["output"] = try eventStream(); candidateRun["truncated"] = false
            return [baseline,candidateRun]
        }
        return try store.put("eval",["project":project.path,"state":"completed","evaluator":"codex_agent","repetitions":3,"command":["/usr/bin/python3","verify.py"],"results":rows,"summary":["decision":"ready_for_review"],"candidate":candidate])
    }
    private func promotionMemory(_ project: URL, id: String, title: String = "Verification") -> JSON {
        ["id":id,"title":title,"content":"Run the project tests before handoff.","scope":"project","project":project.path,"state":"candidate","private":false,
         "provenance":["origin":"observed_session_capture","captureProtocol":"vela-session-memory-capture-v1","ingestionSource":["provider":"codex","relativePath":"captured/" + id + ".jsonl"] as JSON] as JSON]
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
    func testInstalledHookPreviewIsReadOnlyAndRejectsStaleOrUnverifiedNoOps() throws {
        try fixture { root,store,service in
            let draft = try service.previewReuseHook(["project":root.path,"helperExecutable":"/usr/bin/true"])
            _ = try service.applySuggestion(["id":draft["id"]!])
            let path = root.appendingPathComponent(".codex/hooks.json")
            let before = try Data(contentsOf:path)
            let installed = try service.previewReuseHook(["project":root.path,"helperExecutable":"/usr/bin/true"])
            XCTAssertEqual(installed["alreadyInstalled"] as? Bool,true)
            let preview = try service.previewSuggestion(["id":installed["id"]!])
            XCTAssertEqual((preview["preview"] as? [JSON])?.count,0)
            XCTAssertEqual(try Data(contentsOf:path),before)
            XCTAssertThrowsError(try service.applySuggestion(["id":installed["id"]!]))
            XCTAssertEqual(try Data(contentsOf:path),before)
            let arbitrary = try store.put("suggestion",["project":root.path,"state":"draft","operations":[JSON]()])
            XCTAssertThrowsError(try service.previewSuggestion(["id":arbitrary["id"]!]))
            try Data("manual change".utf8).write(to:path)
            XCTAssertThrowsError(try service.previewSuggestion(["id":installed["id"]!]))
            XCTAssertEqual(try String(contentsOf:path),"manual change")
        }
    }
    func testAppliedSuggestionPreviewUsesJournalAndUndoStillChecksCurrentHash() throws {
        try fixture { root,_,service in
            let path = root.appendingPathComponent(".codex/hooks.json")
            try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
            let before = "{\"hooks\":{\"Stop\":[]}}"
            try Data(before.utf8).write(to:path)
            let draft = try service.previewReuseHook(["project":root.path,"helperExecutable":"/usr/bin/true"])
            _ = try service.applySuggestion(["id":draft["id"]!])
            let appliedBytes = try Data(contentsOf:path)
            let preview = try service.previewSuggestion(["id":draft["id"]!])
            XCTAssertEqual(string(preview,"previewSource"),"applied_journal")
            XCTAssertEqual((preview["preview"] as? [JSON])?.first?["before"] as? String,before)
            XCTAssertEqual(try Data(contentsOf:path),appliedBytes)
            try Data("manual change".utf8).write(to:path)
            XCTAssertEqual(string(try service.previewSuggestion(["id":draft["id"]!]),"state"),"applied")
            XCTAssertThrowsError(try service.undoSuggestion(["id":draft["id"]!]))
            XCTAssertEqual(try String(contentsOf:path),"manual change")
            try appliedBytes.write(to:path)
            _ = try service.undoSuggestion(["id":draft["id"]!])
            XCTAssertEqual(try String(contentsOf:path),before)
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
    func testPromotionUsesFrozenVariantReceiptAndOnlyActivatesTestedContext() throws {
        try fixture { root,store,service in
            let memory = try store.put("memory",promotionMemory(root,id:"eligible"))
            let evaluation = try completedPromotionEvaluation(service,store:store,project:root,memoryIDs:[string(memory,"id")])
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

    func testPromotionRevalidatesLifecyclePrivacyPathsAndExclusions() throws {
        try fixture { root,store,service in
            let cases: [(String,(inout JSON) -> Void)] = [
                ("global scope", { $0["scope"] = "global" }),
                ("retired lifecycle", { $0["state"] = "archived" }),
                ("candidate to active lifecycle", { $0["state"] = "active" }),
                ("boolean private", { $0["private"] = true }),
                ("string private", { $0["private"] = "false" }),
                ("boolean source label", { $0["sourceLabeledPrivate"] = true }),
                ("string source label", { $0["sourceLabeledPrivate"] = "false" }),
                ("private sourcePath", { $0["sourcePath"] = root.appendingPathComponent("private/origin.jsonl").path }),
                ("private sourceFile", { $0["sourceFile"] = root.appendingPathComponent(".private/origin.jsonl").path }),
                ("different public sourcePath", { $0["sourcePath"] = root.appendingPathComponent("public/other.jsonl").path })
            ]
            for (index, entry) in cases.enumerated() {
                let memory = try store.put("memory",promotionMemory(root,id:"changed-\(index)",title:entry.0))
                let evaluation = try completedPromotionEvaluation(service,store:store,project:root,memoryIDs:[string(memory,"id")])
                var changed = memory; entry.1(&changed); changed = try store.put("memory",changed)
                let evaluationBefore = try XCTUnwrap(store.get("eval",string(evaluation,"id")))
                XCTAssertThrowsError(try service.promoteEvaluation(["id":evaluation["id"]!]),entry.0)
                XCTAssertEqual(try jsonString(try XCTUnwrap(store.get("memory",string(memory,"id")))),try jsonString(changed),entry.0)
                XCTAssertNil(try store.get("promotion","promotion-" + string(evaluation,"id")),entry.0)
                XCTAssertEqual(try jsonString(try XCTUnwrap(store.get("eval",string(evaluation,"id")))),try jsonString(evaluationBefore),entry.0)
            }

            let sourceMemory = try store.put("memory",promotionMemory(root,id:"source-rule"))
            let sourceEvaluation = try completedPromotionEvaluation(service,store:store,project:root,memoryIDs:[string(sourceMemory,"id")])
            let sourceRules = IngestionExclusionService(store:store)
            sourceRules.knownSource = { project,provider,glob in project == root.path && provider == "codex" && glob == "captured/source-rule.jsonl" }
            _ = try sourceRules.handle("ingestion.exclusions.upsert",["project":root.path,"provider":"codex","pathGlob":"captured/source-rule.jsonl"])
            let sourceBefore = try XCTUnwrap(store.get("eval",string(sourceEvaluation,"id")))
            XCTAssertThrowsError(try service.promoteEvaluation(["id":sourceEvaluation["id"]!]),"source exclusion must invalidate a completed evaluation")
            XCTAssertEqual(try store.get("memory",string(sourceMemory,"id"))?["state"] as? String,"candidate")
            XCTAssertNil(try store.get("promotion","promotion-" + string(sourceEvaluation,"id")))
            XCTAssertEqual(try jsonString(try XCTUnwrap(store.get("eval",string(sourceEvaluation,"id")))),try jsonString(sourceBefore))
        }
    }

    func testPromotionRejectsLegacyReceiptsWholeProjectExclusionAndNeverPartiallyActivates() throws {
        try fixture { root,store,service in
            let legacyMemory = try store.put("memory",promotionMemory(root,id:"legacy"))
            var legacyEvaluation = try completedPromotionEvaluation(service,store:store,project:root,memoryIDs:[string(legacyMemory,"id")])
            var legacyCandidate = try XCTUnwrap(legacyEvaluation["candidate"] as? JSON)
            var legacySnapshots = try XCTUnwrap(legacyCandidate["memories"] as? [JSON])
            legacySnapshots[0].removeValue(forKey:"sourceHash")
            legacyCandidate["memories"] = legacySnapshots; legacyEvaluation["candidate"] = legacyCandidate
            _ = try store.put("eval",legacyEvaluation)
            XCTAssertThrowsError(try service.promoteEvaluation(["id":legacyEvaluation["id"]!]),"legacy memory-only Lab records without a source receipt must fail closed")
            XCTAssertEqual(try store.get("memory",string(legacyMemory,"id"))?["state"] as? String,"candidate")

            let contextMemory = try store.put("memory",promotionMemory(root,id:"context-hash"))
            var contextEvaluation = try completedPromotionEvaluation(service,store:store,project:root,memoryIDs:[string(contextMemory,"id")])
            var invalidCandidate = try XCTUnwrap(contextEvaluation["candidate"] as? JSON)
            invalidCandidate["finalContextHash"] = "not-a-frozen-context-hash"; contextEvaluation["candidate"] = invalidCandidate
            _ = try store.put("eval",contextEvaluation)
            XCTAssertThrowsError(try service.promoteEvaluation(["id":contextEvaluation["id"]!]),"promotion must reject a candidate whose full frozen context hash changed")
            XCTAssertEqual(try store.get("memory",string(contextMemory,"id"))?["state"] as? String,"candidate")
            XCTAssertNil(try store.get("promotion","promotion-" + string(contextEvaluation,"id")))

            let first = try store.put("memory",promotionMemory(root,id:"batch-first"))
            let second = try store.put("memory",promotionMemory(root,id:"batch-second"))
            let batch = try completedPromotionEvaluation(service,store:store,project:root,memoryIDs:[string(first,"id"),string(second,"id")])
            var nowPrivate = second; nowPrivate["sourceLabeledPrivate"] = true; _ = try store.put("memory",nowPrivate)
            XCTAssertThrowsError(try service.promoteEvaluation(["id":batch["id"]!]),"one ineligible memory must reject the whole promotion batch")
            XCTAssertEqual(try store.get("memory",string(first,"id"))?["state"] as? String,"candidate")
            XCTAssertEqual(try store.get("memory",string(second,"id"))?["state"] as? String,"candidate")
            XCTAssertNil(try store.get("promotion","promotion-" + string(batch,"id")))

            let excluded = try store.put("memory",promotionMemory(root,id:"whole-project"))
            let excludedEvaluation = try completedPromotionEvaluation(service,store:store,project:root,memoryIDs:[string(excluded,"id")])
            _ = try IngestionExclusionService(store:store).handle("ingestion.exclusions.upsert",["project":root.path])
            XCTAssertThrowsError(try service.promoteEvaluation(["id":excludedEvaluation["id"]!]),"whole-project exclusion must invalidate a completed evaluation")
            XCTAssertEqual(try store.get("memory",string(excluded,"id"))?["state"] as? String,"candidate")
        }
    }

    func testPromotionCASRejectsPolicyOrMemoryChangesCommittedAfterValidation() throws {
        // No policy revision exists at admission: the final create-only expectation
        // must reject a whole-project policy committed by another VelaStore.
        try fixture { root,store,service in
            let memory = try store.put("memory",promotionMemory(root,id:"absent-policy"))
            let evaluation = try completedPromotionEvaluation(service,store:store,project:root,memoryIDs:[string(memory,"id")])
            let before = try XCTUnwrap(store.get("eval",string(evaluation,"id")))
            let writer = try VelaStore(root:store.root)
            service.promotionAfterValidationForTesting = {
                _ = try IngestionExclusionService(store:writer).handle("ingestion.exclusions.upsert",["project":root.path])
            }
            defer { service.promotionAfterValidationForTesting = nil }
            XCTAssertThrowsError(try service.promoteEvaluation(["id":evaluation["id"]!]))
            XCTAssertEqual(try store.get("memory",string(memory,"id"))?["state"] as? String,"candidate")
            XCTAssertNil(try store.get("promotion","promotion-" + string(evaluation,"id")))
            XCTAssertEqual(try jsonString(try XCTUnwrap(store.get("eval",string(evaluation,"id")))),try jsonString(before))
            XCTAssertNotNil(try store.get("ingestion_policy_revision",stableHash(root.path)))
        }

        // A revision already exists at admission: its exact hash, rather than only
        // absence, must guard the final atomic promotion batch.
        try fixture { root,store,service in
            let initialRules = IngestionExclusionService(store:store)
            initialRules.knownSource = { project,provider,glob in project == root.path && provider == "codex" && glob == "captured/other.jsonl" }
            _ = try initialRules.handle("ingestion.exclusions.upsert",["project":root.path,"provider":"codex","pathGlob":"captured/other.jsonl"])
            let revisionBefore = try XCTUnwrap(store.get("ingestion_policy_revision",stableHash(root.path)))
            let memory = try store.put("memory",promotionMemory(root,id:"expected-policy"))
            let evaluation = try completedPromotionEvaluation(service,store:store,project:root,memoryIDs:[string(memory,"id")])
            let writer = try VelaStore(root:store.root)
            let writerRules = IngestionExclusionService(store:writer)
            writerRules.knownSource = { project,provider,glob in project == root.path && provider == "codex" && glob == "captured/later.jsonl" }
            var writerCommitted = false
            service.promotionAfterValidationForTesting = {
                _ = try writerRules.handle("ingestion.exclusions.upsert",["project":root.path,"provider":"codex","pathGlob":"captured/later.jsonl"])
                writerCommitted = true
            }
            defer { service.promotionAfterValidationForTesting = nil }
            XCTAssertThrowsError(try service.promoteEvaluation(["id":evaluation["id"]!])) { error in
                XCTAssertTrue(error.localizedDescription.contains("Batch source changed"),"unexpected rejection stage: \(error)")
            }
            XCTAssertTrue(writerCommitted,"post-validation writer did not commit its policy revision")
            let revisionAfter = try XCTUnwrap(store.get("ingestion_policy_revision",stableHash(root.path)))
            XCTAssertNotEqual(try jsonString(revisionBefore),try jsonString(revisionAfter))
            XCTAssertEqual(try store.get("memory",string(memory,"id"))?["state"] as? String,"candidate")
            XCTAssertNil(try store.get("promotion","promotion-" + string(evaluation,"id")))
        }

        // The Memory object read during validation must be the one putBatch CASes;
        // a separate connection changing content after validation cannot be promoted.
        try fixture { root,store,service in
            let memory = try store.put("memory",promotionMemory(root,id:"memory-cas"))
            let evaluation = try completedPromotionEvaluation(service,store:store,project:root,memoryIDs:[string(memory,"id")])
            let writer = try VelaStore(root:store.root)
            service.promotionAfterValidationForTesting = {
                var changed = try XCTUnwrap(writer.get("memory",string(memory,"id")))
                changed["content"] = "Changed after promotion validation."
                _ = try writer.put("memory",changed)
            }
            defer { service.promotionAfterValidationForTesting = nil }
            XCTAssertThrowsError(try service.promoteEvaluation(["id":evaluation["id"]!]))
            XCTAssertEqual(try store.get("memory",string(memory,"id"))?["state"] as? String,"candidate")
            XCTAssertEqual(try store.get("memory",string(memory,"id"))?["content"] as? String,"Changed after promotion validation.")
            XCTAssertNil(try store.get("promotion","promotion-" + string(evaluation,"id")))
        }
    }
}
