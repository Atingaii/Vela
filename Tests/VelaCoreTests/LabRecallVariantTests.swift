import XCTest
@testable import VelaCore

/// Exercises the real Lab approval/worktree/agent argv path with a fixed local JSONL
/// executable. This is not a provider run or a quality claim.
final class LabRecallVariantTests: XCTestCase {
    private func fixture(_ work: (URL, URL, VelaStore, AutomationService) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vela-lab-recall-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("project"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("assert True\n".utf8).write(to: root.appendingPathComponent("verify.py"))
        XCTAssertEqual(try AutomationProcess.git(["init", "-q"], cwd: root.path).exitCode, 0)
        XCTAssertEqual(try AutomationProcess.git(["add", "."], cwd: root.path).exitCode, 0)
        XCTAssertEqual(try AutomationProcess.git(["-c", "user.name=Vela fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], cwd: root.path).exitCode, 0)
        let agent = base.appendingPathComponent("fixed-jsonl-agent.py")
        let source = """
        #!/usr/bin/env python3 -I
        import json, pathlib, sys
        if '--version' in sys.argv:
            print('fixed-jsonl-agent 1')
            raise SystemExit(0)
        encoded = next(arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('developer_instructions='))
        context = json.loads(encoded)
        pathlib.Path('observed-context.txt').write_text(context)
        print(json.dumps({'type':'thread.started','thread_id':'fixed-recall'}), flush=True)
        print(json.dumps({'type':'item.completed','item':{'id':'message','type':'agent_message','text':'fixed local fixture'}}), flush=True)
        print(json.dumps({'type':'turn.completed','usage':{'input_tokens':1,'output_tokens':1}}), flush=True)
        """
        try Data(source.utf8).write(to: agent); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        let store = try VelaStore(root: base.appendingPathComponent("store"))
        _ = try FoundationService(store:store,sourceRoots:[:],globalHome:base.appendingPathComponent("home")).handle("projects.add",["path":root.path])
        try work(root, agent, store, AutomationService(store: store))
    }

    private func request(_ root: URL, _ agent: URL, baseline: JSON, candidate: JSON) -> JSON {
        ["project":root.path,"title":"Fixed Recall variant test","kind":"memory",
         "agent":["provider":"codex","executable":agent.path,"model":"fixed-local","reasoningEffort":"high"],
         "task":"Write the received developer context to the allowed fixture output.",
         "verificationCommand":["/usr/bin/python3","verify.py"],"verificationFiles":["verify.py"],
         "outputFiles":["observed-context.txt"],"timeoutSeconds":15,"repetitions":1,
         "baseline":baseline,"candidate":candidate]
    }

    private func approve(_ service: AutomationService, _ store: VelaStore, _ created: JSON) throws -> JSON {
        let approval = try XCTUnwrap(store.get("approval", string(created,"approvalId")))
        _ = try service.handle("approvals.decide", ["id":approval["id"]!,"decision":"approve","snapshotHash":approval["snapshotHash"]!])
        return try XCTUnwrap(store.get("eval", string(created,"id")))
    }

    /// The source-receipt shape emitted before the privacy/path fields joined the
    /// hash. It is intentionally reproduced only to verify conservative upgrade
    /// behavior for already-pending evaluations.
    private func legacyLabMemorySourceHash(_ memory: JSON) throws -> String {
        let source: JSON = ["id":string(memory,"id"),"project":string(memory,"project"),"scope":string(memory,"scope"),
                            "state":string(memory,"state"),"private":memory["private"] as? Bool ?? false,
                            "sourceFile":string(memory,"sourceFile"),"title":string(memory,"title"),"content":string(memory,"content")]
        return stableHash(try jsonString(source))
    }

    func testExplicitOffAndRecallOnReachRealAgentContextWithActiveProjectBudgetOnly() throws {
        try fixture { root, agent, store, service in
            let active = try store.put("memory", ["id":"active-hit","project":root.path,"scope":"project","state":"active","private":false,"title":"Clamp guidance","content":"Use a bounded clamp implementation."])
            _ = try store.put("memory", ["id":"candidate-hit","project":root.path,"scope":"project","state":"candidate","private":false,"title":"Clamp draft","content":"bounded clamp draft"])
            _ = try store.put("memory", ["id":"private-hit","project":root.path,"scope":"project","state":"active","private":true,"title":"Clamp secret","content":"private clamp secret"])
            _ = try store.put("memory", ["id":"source-labeled-hit","project":root.path,"scope":"project","state":"active","private":false,"sourceLabeledPrivate":true,"title":"Clamp source label","content":"RECALL_SOURCE_LABELED_SENTINEL"])
            let other = root.deletingLastPathComponent().appendingPathComponent("other"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            _ = try store.put("project", ["path":other.path,"project":other.path,"title":"other"])
            _ = try store.put("memory", ["id":"cross-hit","project":other.path,"scope":"project","state":"active","private":false,"title":"Clamp cross","content":"cross project"])
            let created = try XCTUnwrap(service.handle("lab.run", request(root,agent,baseline:["files":[],"recall":["enabled":false,"strictOff":true]],candidate:["files":[],"recall":["enabled":true,"query":"bounded clamp","mode":"lexical","scope":"project","budget":500]])) as? JSON)
            let frozenCandidate = try XCTUnwrap(created["candidate"] as? JSON)
            XCTAssertEqual(string(frozenCandidate,"memoryInjection"), "recall")
            let recall = try XCTUnwrap(frozenCandidate["recall"] as? JSON)
            XCTAssertEqual((recall["items"] as? [JSON])?.map { string($0,"id") }, [string(active,"id")])
            XCTAssertEqual(intValue(recall,"usedTokens") <= 500, true)
            XCTAssertEqual(string(frozenCandidate,"finalContextHash"), stableHash(string(frozenCandidate,"context")))
            let approval = try XCTUnwrap(store.get("approval", string(created,"approvalId")))
            XCTAssertFalse(string(approval,"snapshotHash").isEmpty)
            XCTAssertEqual(string((approval["arguments"] as? JSON ?? [:])["candidate"] as? JSON ?? [:],"finalContextHash"), string(frozenCandidate,"finalContextHash"))
            let finished = try approve(service,store,created)
            XCTAssertEqual(string(finished,"state"), "completed", string(finished,"error"))
            let rows = finished["results"] as? [JSON] ?? []
            XCTAssertEqual(rows.count, 2)
            let contexts = try Dictionary(uniqueKeysWithValues: rows.map { row -> (String,String) in
                guard let config = (row["agentCommand"] as? [String])?.first(where: { $0.hasPrefix("developer_instructions=") }) else { return (string(row,"variant"),"") }
                let text = String(config.dropFirst("developer_instructions=".count))
                return (string(row,"variant"), try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8), options:[.fragmentsAllowed]) as? String))
            })
            XCTAssertFalse(contexts["baseline", default: "unexpected"].contains("Clamp guidance"))
            XCTAssertTrue(contexts["candidate", default: ""].contains("Clamp guidance"))
            XCTAssertFalse(contexts["candidate", default: "unexpected"].contains("private clamp secret"))
            XCTAssertFalse(contexts["candidate", default: "unexpected"].contains("cross project"))
            XCTAssertFalse(contexts["candidate", default: "unexpected"].contains("RECALL_SOURCE_LABELED_SENTINEL"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("lab-worktrees/" + string(created,"id")).path))
        }
    }

    func testStrictOffWithExplicitIDsAndChangedRecallSourceAreRejectedBeforeAgentExecution() throws {
        try fixture { root, agent, store, service in
            let memory = try store.put("memory", ["id":"source","project":root.path,"scope":"project","state":"active","private":false,"title":"Needle","content":"needle source"])
            XCTAssertThrowsError(try service.handle("lab.run", request(root,agent,baseline:["files":[],"memoryIds":["source"],"recall":["enabled":false,"strictOff":true]],candidate:["files":[]])))
            XCTAssertTrue(try store.list("eval").isEmpty)
            let created = try XCTUnwrap(service.handle("lab.run", request(root,agent,baseline:["files":[],"recall":["enabled":false,"strictOff":true]],candidate:["files":[],"recall":["enabled":true,"query":"needle","mode":"lexical","scope":"project","budget":300]])) as? JSON)
            var changed = memory; changed["content"] = "changed after approval preview"; _ = try store.put("memory", changed)
            let approval = try XCTUnwrap(store.get("approval", string(created,"approvalId")))
            let decision = try XCTUnwrap(service.handle("approvals.decide", ["id":approval["id"]!,"decision":"approve","snapshotHash":approval["snapshotHash"]!]) as? JSON)
            XCTAssertEqual(string(decision,"state"), "failed")
            XCTAssertTrue(string(decision["result"] as? JSON ?? [:],"output").contains("Frozen Lab Recall source changed"))
            let evaluation = try XCTUnwrap(store.get("eval",string(created,"id")))
            XCTAssertEqual(string(evaluation,"state"), "failed")
            XCTAssertEqual((evaluation["results"] as? [JSON] ?? []).map { string($0,"variant") }, ["baseline"])
            XCTAssertFalse((evaluation["results"] as? [JSON] ?? []).contains { string($0,"variant") == "candidate" })
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("lab-worktrees/" + string(created,"id")).path))
            let privateAfterPreview = try XCTUnwrap(service.handle("lab.run", request(root,agent,baseline:["files":[],"recall":["enabled":false,"strictOff":true]],candidate:["files":[],"recall":["enabled":true,"query":"needle","mode":"lexical","scope":"project","budget":300]])) as? JSON)
            var revoked = changed; revoked["private"] = true; _ = try store.put("memory", revoked)
            let privateApproval = try XCTUnwrap(store.get("approval", string(privateAfterPreview,"approvalId")))
            let privateDecision = try XCTUnwrap(service.handle("approvals.decide", ["id":privateApproval["id"]!,"decision":"approve","snapshotHash":privateApproval["snapshotHash"]!]) as? JSON)
            XCTAssertEqual(string(privateDecision,"state"), "failed")
            XCTAssertTrue(string(privateDecision["result"] as? JSON ?? [:],"output").contains("became private"))
        }
    }
    func testSemanticAndHybridNeverFreezeUnavailableOrDowngradedMode() throws { try fixture { root, agent, store, service in
        _ = try store.put("memory", ["id":"unindexed","project":root.path,"scope":"project","state":"active","private":false,"title":"Semantic needle","content":"semantic needle unindexed active memory"])
        for mode in ["semantic","hybrid"] {
            let candidate: JSON = ["files":[],"recall":["enabled":true,"query":"semantic needle","mode":mode,"scope":"project","budget":300]]
            do {
                guard let created = try service.handle("lab.run",request(root,agent,baseline:["files":[],"recall":["enabled":false,"strictOff":true]],candidate:candidate)) as? JSON else { XCTFail("Lab Recall must return an evaluation"); continue }
                guard let recall = (created["candidate"] as? JSON)?["recall"] as? JSON else { XCTFail("Lab Recall receipt is missing"); continue }
                XCTAssertEqual(string(recall,"requestedRetrievalMode"),mode); XCTAssertEqual(string(recall,"retrievalMode"),mode); XCTAssertEqual(string(recall,"status"),"ok"); XCTAssertFalse(recall["indexIncomplete"] as? Bool ?? true)
            } catch let error as VelaError {
                XCTAssertTrue(error.message.contains("Lab Recall did not obtain the requested " + mode + " retrieval"), error.message)
                XCTAssertTrue(try store.list("eval").isEmpty); XCTAssertTrue(try store.list("approval").isEmpty)
            } catch { XCTFail("Unexpected semantic Lab error: \(error)") }
        }
    } }

    func testSourceLabeledMemoryIsRejectedAtFreezeAndBeforeCandidateExecution() throws {
        try fixture { root,agent,store,service in
            let labeled = try store.put("memory", ["id":"source-labeled","project":root.path,"scope":"project","state":"active","private":false,"sourceLabeledPrivate":true,"title":"Needle labeled","content":"source labeled needle"])
            XCTAssertThrowsError(try service.handle("lab.run", request(root,agent,baseline:["files":[]],candidate:["files":[],"memoryIds":[string(labeled,"id")]])))
            var available = labeled; available["sourceLabeledPrivate"] = false; _ = try store.put("memory",available)
            let created = try XCTUnwrap(service.handle("lab.run", request(root,agent,baseline:["files":[],"recall":["enabled":false,"strictOff":true]],candidate:["files":[],"recall":["enabled":true,"query":"source labeled needle","mode":"lexical","scope":"project","budget":300]])) as? JSON)
            var relabeled = available; relabeled["sourceLabeledPrivate"] = true; _ = try store.put("memory",relabeled)
            let approval = try XCTUnwrap(store.get("approval",string(created,"approvalId")))
            let decision = try XCTUnwrap(service.handle("approvals.decide",["id":approval["id"]!,"decision":"approve","snapshotHash":approval["snapshotHash"]!]) as? JSON)
            XCTAssertEqual(string(decision,"state"),"failed")
            let evaluation = try XCTUnwrap(store.get("eval",string(created,"id")))
            XCTAssertEqual(string(evaluation,"state"),"failed")
            XCTAssertEqual((evaluation["results"] as? [JSON] ?? []).map { string($0,"variant") },["baseline"])
            XCTAssertFalse((evaluation["results"] as? [JSON] ?? []).contains { string($0,"variant") == "candidate" })
        }
    }

    func testLegacyRecallReceiptFailsClosedAndARebuiltEvaluationExecutes() throws {
        try fixture { root,agent,store,service in
            let memory = try store.put("memory", ["id":"legacy-receipt-source","project":root.path,"scope":"project","state":"active","private":false,"title":"Legacy receipt source","content":"legacy recall fixture"])
            let candidate: JSON = ["files":[],"recall":["enabled":true,"query":"legacy recall fixture","mode":"lexical","scope":"project","budget":300]]
            let created = try XCTUnwrap(service.handle("lab.run",request(root,agent,baseline:["files":[],"recall":["enabled":false,"strictOff":true]],candidate:candidate)) as? JSON)
            var evaluation = try XCTUnwrap(store.get("eval",string(created,"id")))
            let currentApproval = try XCTUnwrap(store.get("approval",string(created,"approvalId")))
            var legacyCandidate = try XCTUnwrap(evaluation["candidate"] as? JSON)
            var legacyRecall = try XCTUnwrap(legacyCandidate["recall"] as? JSON)
            var legacyItems = try XCTUnwrap(legacyRecall["items"] as? [JSON])
            XCTAssertEqual(legacyItems.count,1)
            legacyItems[0]["sourceHash"] = try legacyLabMemorySourceHash(memory)
            legacyRecall["items"] = legacyItems; legacyCandidate["recall"] = legacyRecall; evaluation["candidate"] = legacyCandidate
            var frozen = try XCTUnwrap(currentApproval["arguments"] as? JSON); frozen["candidate"] = legacyCandidate
            let legacyApproval = try service.pendingApproval(id:"legacy-receipt-approval",title:string(currentApproval,"title"),tool:"lab.execute",arguments:frozen,project:root.path,runId:string(evaluation,"id"),stepIndex:0)
            try store.remove("approval",string(currentApproval,"id")); evaluation["approvalId"] = legacyApproval["id"]
            _ = try store.putBatch([("eval",evaluation),("approval",legacyApproval)],expectingAbsent:[("approval",string(legacyApproval,"id"))],createOnly:false)
            let rejected = try XCTUnwrap(service.handle("approvals.decide",["id":legacyApproval["id"]!,"decision":"approve","snapshotHash":legacyApproval["snapshotHash"]!]) as? JSON)
            XCTAssertEqual(string(rejected,"state"),"failed")
            XCTAssertTrue(string(rejected["result"] as? JSON ?? [:],"output").contains("Frozen Lab Recall source changed"))
            let failed = try XCTUnwrap(store.get("eval",string(created,"id")))
            XCTAssertEqual(string(failed,"state"),"failed")
            XCTAssertEqual((failed["results"] as? [JSON] ?? []).map { string($0,"variant") },["baseline"])
            let rebuilt = try XCTUnwrap(service.handle("lab.run",request(root,agent,baseline:["files":[],"recall":["enabled":false,"strictOff":true]],candidate:candidate)) as? JSON)
            let completed = try approve(service,store,rebuilt)
            XCTAssertEqual(string(completed,"state"),"completed",string(completed,"error"))
            XCTAssertEqual((completed["results"] as? [JSON] ?? []).map { string($0,"variant") },["baseline","candidate"])
        }
    }
}
