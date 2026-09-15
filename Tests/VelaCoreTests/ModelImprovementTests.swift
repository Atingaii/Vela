import XCTest
@testable import VelaCore

final class ModelImprovementTests: XCTestCase {
    var root: URL!, project: URL!, store: VelaStore!, service: AutomationService!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath:canonicalProject(FileManager.default.temporaryDirectory.path)).appendingPathComponent("vela-model-improve-tests-" + UUID().uuidString)
        project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        store = try VelaStore(root:root.appendingPathComponent("store")); service = AutomationService(store:store)
        _ = try store.put("project",["id":"project","path":project.path])
    }
    override func tearDownWithError() throws {
        service = nil; store = nil
        if let root { try FileManager.default.removeItem(at:root) }
    }
    func sessions(_ count: Int = 3, messages: Int = 2) throws -> [String] {
        try (0..<count).map { index in
            let id = "session-\(index)"
            _ = try store.put("session",["id":id,"project":project.path,"provider":"codex","sourceSessionId":"provider-\(index)","messages":(0..<messages).map { ["id":"message-\($0)","role":"user","content":"Please validate the task \(index) result before handoff, correction \($0).","timestamp":"2026-09-13T00:00:00Z"] }])
            return id
        }
    }
    func fake(_ mode: String = "success") throws -> String {
        let executable = root.appendingPathComponent("fake-codex")
        let configuration: JSON = ["mode":mode,"counter":root.appendingPathComponent("calls.jsonl").path,"project":project.path]
        let script = """
        #!/usr/bin/python3
        import json, os, stat, sys
        config = \(try jsonString(configuration))
        args = sys.argv[1:]
        assert args[0] == 'exec' and '--ignore-user-config' in args and '--ignore-rules' in args
        assert args[args.index('--sandbox')+1] == 'read-only'
        assert os.getcwd() != config['project'] and stat.S_IMODE(os.stat(os.getcwd()).st_mode) == 0o700
        schema_path = args[args.index('--output-schema')+1]
        assert stat.S_IMODE(os.stat(schema_path).st_mode) == 0o600
        assert os.environ.get('VELA_INTERNAL_RUN') == '1'
        assert 'sk-THISISASYNTHETICSECRETFIXTURE' not in args[-1]
        data = json.loads(args[-1].split('Frozen input:\\n', 1)[1])
        stage = data['stage']
        with open(config['counter'], 'a') as handle:
            handle.write(json.dumps({'stage':stage,'scratch':os.getcwd()})+'\\n')
        mode = config['mode']
        if mode == 'process_error':
            sys.exit(2)
        if mode == 'flood':
            print('x' * 300000); sys.exit(0)
        def emit(value): print(json.dumps(value), flush=True)
        emit({'type':'thread.started','thread_id':'synthetic-'+stage})
        if mode == 'tool':
            emit({'type':'item.completed','item':{'id':'unsafe','type':'command_execution','command':'echo unwanted','status':'completed','exit_code':0}})
        if stage == 'extract':
            refs = [e['id'] for e in data['evidence']]
            if mode == 'bad_evidence': refs = ['invented-source']
            result = {'observations':[{'id':'observation-1','summary':'Repeated request to validate before handoff','kind':'correction','evidenceIds':refs}],'unresolved':[]}
        elif stage == 'cluster':
            result = {'clusters':[{'id':'cluster-'+t['id'],'title':'Review delivery practice','rationale':'Review source evidence before adopting this hypothesis','carrier':t['carrier'],'observationIds':['observation-1']} for t in data['targets']],'unresolved':[]}
        else:
            proposals=[]
            for t in data['targets']:
                content='# Reviewed project note\\n\\nCheck the actual result before handoff.\\n'
                if t['carrier']=='Hook': content=json.dumps({'hooks':{'SessionStart':[]}})
                if t['carrier']=='Workflow': content=json.dumps({'title':'Review current status','summary':'A disabled review draft','template':'Review {{git_status.output}}','readTools':['git.status'],'questions':[],'unresolved':[]})
                if mode=='secret_output': content='api_key=SHOULD_NOT_PERSIST'
                proposals.append({'id':'proposal-'+t['id'],'title':'Review project handoff','summary':'Candidate based on cited messages','clusterId':'cluster-'+t['id'],'targetId':t['id'],'content':content})
            if mode=='bad_target': proposals[0]['targetId']='invented-target'
            result={'proposals':proposals,'unresolved':[]}
        emit({'type':'item.completed','item':{'id':'answer','type':'agent_message','text':json.dumps(result)}})
        emit({'type':'turn.completed','usage':{'input_tokens':10,'output_tokens':20}})
        """
        try Data(script.utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        return executable.path
    }
    func request(_ ids: [String], carrier: String = "Doc", mode: String = "success") throws -> JSON {
        ["project":project.path,"sessionIds":ids,"targets":[["carrier":carrier,"path":carrier == "Rule" ? "AGENTS.md" : ".vela/docs/handoff.md"]],"executable":try fake(mode),"model":"synthetic-explicit-model","effort":"high","timeoutSeconds":3]
    }
    func plan(_ params: JSON) throws -> JSON {
        let valueToUnwrap = try service.handle("improve.model.plan",params) as? JSON
        return try XCTUnwrap(valueToUnwrap)
    }
    func approve(_ plan: JSON) throws -> JSON {
        let approval = try XCTUnwrap(plan["approval"] as? JSON)
        let valueToUnwrap = try service.handle("approvals.decide",["id":string(approval,"id"),"snapshotHash":string(approval,"snapshotHash"),"decision":"approve"]) as? JSON
        return try XCTUnwrap(valueToUnwrap)
    }
    func current(_ plan: JSON) throws -> JSON { try XCTUnwrap(service.handle("improve.model.get",["project":project.path,"id":string(plan,"id")]) as? JSON) }
    func calls() throws -> [JSON] {
        let path = root.appendingPathComponent("calls.jsonl")
        guard FileManager.default.fileExists(atPath:path.path) else { return [] }
        return try String(contentsOf:path).split(separator:"\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with:Data($0.utf8)) as? JSON) }
    }

    func testPendingRequestFreezesActualEvidenceAndDoesNotCallModelOrWriteTarget() throws {
        let value = try plan(request(sessions()))
        XCTAssertEqual(string(value,"state"),"pending_approval"); XCTAssertTrue(try calls().isEmpty)
        let request = try XCTUnwrap(value["request"] as? JSON)
        XCTAssertEqual(intValue(request,"maxCalls"),3); XCTAssertEqual(string(request,"trigger"),"manual")
        let evidence = try XCTUnwrap(request["evidence"] as? [JSON])
        XCTAssertEqual(evidence.count,6); XCTAssertEqual(string(evidence[0],"sessionId"),"session-0")
        XCTAssertFalse(string(evidence[0],"sourceHash").isEmpty)
        XCTAssertTrue(try store.list("suggestion").isEmpty); XCTAssertTrue(try store.list("memory").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent(".vela").path))
    }
    func testActualThreeStageSubprocessProducesDiffThenSeparateApplyAndUndo() throws {
        let value = try plan(request(sessions()))
        let approval = try approve(value); XCTAssertEqual(string(approval,"state"),"executed")
        let done = try current(value)
        XCTAssertEqual(string(done,"state"),"drafts"); XCTAssertEqual(intValue(done,"modelCalls"),3)
        XCTAssertEqual(try calls().map { string($0,"stage") },["extract","cluster","plan"])
        for call in try calls() { XCTAssertFalse(FileManager.default.fileExists(atPath:string(call,"scratch"))) }
        let suggestion = try XCTUnwrap((done["suggestions"] as? [JSON])?.first)
        XCTAssertEqual(string(suggestion,"claimStatus"),"unverified_proposal"); XCTAssertFalse((suggestion["preview"] as? [JSON] ?? []).isEmpty)
        let path = project.appendingPathComponent(".vela/docs/handoff.md").path
        XCTAssertFalse(FileManager.default.fileExists(atPath:path))
        _ = try service.handle("improve.apply",["id":string(suggestion,"id"),"project":project.path,"suggestionHash":string(suggestion,"suggestionHash")])
        XCTAssertTrue(FileManager.default.fileExists(atPath:path))
        _ = try service.handle("improve.undo",["id":string(suggestion,"id")])
        XCTAssertFalse(FileManager.default.fileExists(atPath:path)); XCTAssertTrue(try store.list("memory").isEmpty)
        XCTAssertThrowsError(try approve(value)); XCTAssertEqual(try calls().count,3)
    }
    func testAllFiveCarriersRetainEvidenceAndWorkflowStaysDisabledAndUnsaved() throws {
        var params = try request(sessions())
        params["targets"] = [["carrier":"Rule","path":"AGENTS.md"],["carrier":"Skill","path":".agents/skills/handoff/SKILL.md"],["carrier":"Hook","path":".codex/hooks.json"],["carrier":"Doc","path":".vela/docs/handoff.md"],["carrier":"Workflow","path":".vela/workflows/handoff.md"]]
        let value = try plan(params); _ = try approve(value)
        let done = try current(value); let suggestions = try XCTUnwrap(done["suggestions"] as? [JSON])
        XCTAssertEqual(suggestions.count,5); XCTAssertEqual(Set(suggestions.map { string($0,"carrier") }),Set(ModelImprovement.carriers))
        for suggestion in suggestions { XCTAssertEqual(intValue(suggestion,"distinctSessions"),3); XCTAssertFalse((suggestion["evidence"] as? [JSON] ?? []).isEmpty) }
        let workflow = try XCTUnwrap(suggestions.first { string($0,"carrier") == "Workflow" }?["workflowDraft"] as? JSON)
        XCTAssertEqual(workflow["enabled"] as? Bool,false); XCTAssertEqual(string(workflow,"trigger"),"manual")
        XCTAssertTrue(try store.list("workflow").isEmpty); XCTAssertTrue(try store.list("memory").isEmpty)
    }
    func testSingleComplaintAndCopiedProviderSessionsCannotBecomePermanentRule() throws {
        var ids = try sessions(1,messages:1)
        var params = try request(ids,carrier:"Rule")
        let one = try plan(params); _ = try approve(one)
        XCTAssertEqual(string(try current(one),"state"),"observations_only"); XCTAssertTrue(try store.list("suggestion").isEmpty)
        let original = try XCTUnwrap(store.get("session",ids[0]))
        for number in 1...3 { var copy = original; copy["id"] = "copied-\(number)"; _ = try store.put("session",copy); ids.append(string(copy,"id")) }
        params["sessionIds"] = ids
        let copies = try plan(params); _ = try approve(copies)
        XCTAssertEqual(string(try current(copies),"state"),"observations_only"); XCTAssertTrue(try store.list("suggestion").isEmpty)
    }
    func testChangedSourceOrTargetStopsBeforeModelAndNeverCreatesCandidates() throws {
        let ids = try sessions(), first = try plan(request(ids))
        var source = try XCTUnwrap(store.get("session",ids[0])); source["private"] = true; _ = try store.put("session",source)
        XCTAssertEqual(string(try approve(first),"state"),"failed"); XCTAssertTrue(try calls().isEmpty)
        source["private"] = false; _ = try store.put("session",source)
        let second = try plan(request(ids,carrier:"Rule"))
        try Data("Human edit\n".utf8).write(to:project.appendingPathComponent("AGENTS.md"))
        XCTAssertEqual(string(try approve(second),"state"),"failed"); XCTAssertTrue(try calls().isEmpty)
        XCTAssertTrue(try store.list("suggestion").isEmpty)
    }
    func testPrivateCrossProjectInternalAndUnsupportedSessionsAreExcluded() throws {
        let ids = try sessions(1)
        let original = try XCTUnwrap(store.get("session",ids[0]))
        for override: JSON in [["private":true],["private":"false"],["private":0],["private":NSNull()],["scope":"private"],["scope":"Private"],["scope":NSNull()],["scope":0],["project":"/another-project"],["internalRun":true],["internalRun":"false"],["provider":"unknown"],["sourcePath":"/some/Private/Library/session.jsonl"]] {
            var value = original; value.merge(override) { _,new in new }; _ = try store.put("session",value)
            XCTAssertThrowsError(try plan(request(ids)))
        }
        XCTAssertTrue(try calls().isEmpty)
        XCTAssertTrue(try store.list("model_improvement").isEmpty)
    }
    func testPromptRedactsEvidenceAndRejectsExistingTargetWithSecrets() throws {
        let ids = try sessions(1)
        var session = try XCTUnwrap(store.get("session",ids[0]))
        session["messages"] = [["id":"secret-message","role":"user","content":"Please remove sk-THISISASYNTHETICSECRETFIXTURE from example files."]]
        _ = try store.put("session",session)
        let value = try plan(request(ids)); let raw = try jsonString(try XCTUnwrap(value["request"] as? JSON))
        XCTAssertFalse(raw.contains("sk-THISISASYNTHETICSECRETFIXTURE")); XCTAssertTrue(raw.contains("REDACTED"))
        _ = try approve(value); XCTAssertEqual(string(try current(value),"state"),"drafts")
        try Data("api_key=synthetic-value\n".utf8).write(to:project.appendingPathComponent("AGENTS.md"))
        XCTAssertThrowsError(try plan(request(ids,carrier:"Rule")))
    }
    func testInvalidEvidenceTargetsToolsOutputsAndProviderFailureCannotMakeSuggestions() throws {
        let ids = try sessions()
        for mode in ["bad_evidence","bad_target","tool","secret_output","process_error","flood"] {
            let value = try plan(request(ids,mode:mode)); let approval = try approve(value)
            XCTAssertEqual(string(approval,"state"),"failed"); XCTAssertEqual(string(try current(value),"state"),"failed")
            XCTAssertTrue(try store.list("suggestion").isEmpty)
            XCTAssertFalse(try jsonString(try current(value)).contains("SHOULD_NOT_PERSIST"))
        }
    }
    func testFrozenApprovalAndModelCommandCannotBeMutatedOrReused() throws {
        let ids = try sessions(), value = try plan(request(ids))
        var approval = try XCTUnwrap(value["approval"] as? JSON), arguments = try XCTUnwrap(approval["arguments"] as? JSON), request = try XCTUnwrap(arguments["request"] as? JSON)
        request["maxCalls"] = 8; arguments["request"] = request; approval["arguments"] = arguments; _ = try store.put("approval",approval)
        XCTAssertThrowsError(try approve(value)); XCTAssertTrue(try calls().isEmpty)
        let second = try plan(self.request(ids)); var stored = try XCTUnwrap(store.get("model_improvement",string(second,"id")))
        var secondRequest = try XCTUnwrap(stored["request"] as? JSON); secondRequest["commandTemplate"] = ["/bin/echo"]
        stored["request"] = secondRequest; _ = try store.put("model_improvement",stored)
        XCTAssertEqual(string(try approve(second),"state"),"failed"); XCTAssertTrue(try calls().isEmpty)
    }
    func testSnoozeDismissReopenRequireCurrentHashAndCannotHideAppliedChange() throws {
        let value = try plan(request(sessions())); _ = try approve(value)
        var suggestion = try XCTUnwrap((try current(value)["suggestions"] as? [JSON])?.first)
        func transition(_ action: String, hash: String? = nil) throws -> JSON {
            var params: JSON = ["project":project.path,"id":string(suggestion,"id"),"suggestionHash":hash ?? string(suggestion,"suggestionHash"),"action":action]
            if action == "snooze" { params["until"] = ISO8601DateFormatter().string(from:Date().addingTimeInterval(3600)) }
            let valueToUnwrap = try service.handle("improve.model.transition",params) as? JSON
            return try XCTUnwrap(valueToUnwrap)
        }
        let firstHash = string(suggestion,"suggestionHash")
        suggestion = try transition("snooze"); XCTAssertEqual(string(suggestion,"state"),"snoozed")
        XCTAssertThrowsError(try transition("reopen",hash:firstHash))
        suggestion = try transition("dismiss"); suggestion = try transition("reopen")
        XCTAssertEqual(string(suggestion,"state"),"draft"); XCTAssertNil(suggestion["snoozedUntil"])
        _ = try service.handle("improve.apply",["id":string(suggestion,"id"),"project":project.path,"suggestionHash":string(suggestion,"suggestionHash")])
        suggestion = try XCTUnwrap((try current(value)["suggestions"] as? [JSON])?.first)
        XCTAssertThrowsError(try transition("dismiss")); XCTAssertEqual(try calls().count,3)
    }
    func testBudgetsTargetsAndEvidenceOmissionsAreExplicit() throws {
        let ids = try sessions(1,messages:100), base = try request(ids)
        for override: JSON in [["maxCalls":4],["maxEvidence":81],["timeoutSeconds":301],["maxPromptBytes":64001],["background":true],["sessionIds":[ids[0],ids[0]]],["targets":[["carrier":"Doc","path":"../outside.md"]]],["targets":[["carrier":"Hook","path":"AGENTS.md"]]]] {
            var params = base; params.merge(override) { _,new in new }; XCTAssertThrowsError(try plan(params))
        }
        var bounded = base; bounded["maxEvidence"] = 5
        let request = try XCTUnwrap(plan(bounded)["request"] as? JSON)
        XCTAssertEqual((request["evidence"] as? [JSON])?.count,5); XCTAssertEqual(intValue(request,"omittedMessages"),95)
        XCTAssertTrue(try calls().isEmpty)
    }

    func testModelApplyRequiresReviewedHashProjectAndUnchangedCitedEvidence() throws {
        let ids = try sessions(), value = try plan(request(ids)); _ = try approve(value)
        let suggestion = try XCTUnwrap((try current(value)["suggestions"] as? [JSON])?.first)
        let params: JSON = ["id":string(suggestion,"id"),"project":project.path,"suggestionHash":string(suggestion,"suggestionHash")]
        XCTAssertThrowsError(try service.handle("improve.apply",["id":string(suggestion,"id"),"project":project.path]))
        let other = root.appendingPathComponent("other-project"); try FileManager.default.createDirectory(at:other,withIntermediateDirectories:false)
        _ = try store.put("project",["id":"other","path":other.path])
        var wrongProject = params; wrongProject["project"] = other.path
        XCTAssertThrowsError(try service.handle("improve.apply",wrongProject))
        var changed = suggestion; changed["operations"] = [["path":project.appendingPathComponent(".vela/docs/handoff.md").path,"baseHash":"absent","content":"Unreviewed replacement"]]
        _ = try store.put("suggestion",changed)
        XCTAssertThrowsError(try service.handle("improve.apply",params))
        _ = try store.put("suggestion",suggestion)
        var session = try XCTUnwrap(store.get("session",ids[0])); let original = session
        session["private"] = true; _ = try store.put("session",session)
        XCTAssertThrowsError(try service.handle("improve.apply",params))
        session = original; var messages = try XCTUnwrap(session["messages"] as? [JSON]); messages[0]["content"] = "Changed cited message"; session["messages"] = messages
        _ = try store.put("session",session)
        XCTAssertThrowsError(try service.handle("improve.apply",params))
        XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent(".vela/docs/handoff.md").path))
        session = original; messages = try XCTUnwrap(session["messages"] as? [JSON]); messages.append(["id":"unrelated-new","role":"user","content":"An unrelated appended task"]); session["messages"] = messages
        _ = try store.put("session",session)
        _ = try service.handle("improve.apply",params)
        XCTAssertTrue(FileManager.default.fileExists(atPath:project.appendingPathComponent(".vela/docs/handoff.md").path))
    }

    func testDescribeAndScopedListNeverCallProviderAndRejectedPlanStaysRejected() throws {
        let description = try XCTUnwrap(service.handle("improve.model.describe",[:]) as? JSON)
        XCTAssertEqual(description["manualOnly"] as? Bool,true); XCTAssertEqual(description["privateLibraryAllowed"] as? Bool,false)
        let value = try plan(request(sessions()))
        let approval = try XCTUnwrap(value["approval"] as? JSON)
        _ = try service.handle("approvals.decide",["id":string(approval,"id"),"snapshotHash":string(approval,"snapshotHash"),"decision":"reject"])
        let list = try XCTUnwrap(service.handle("improve.model.list",["project":project.path]) as? [JSON])
        XCTAssertEqual(list.count,1); XCTAssertEqual(string(list[0],"state"),"rejected"); XCTAssertNil(list[0]["request"])
        XCTAssertEqual(string(try current(value),"state"),"rejected"); XCTAssertThrowsError(try approve(value)); XCTAssertTrue(try calls().isEmpty)
    }
}
