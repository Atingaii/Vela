import XCTest
@testable import VelaCore

final class KnowledgeQueryTests: XCTestCase {
    private func fixture(_ work: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-knowledge-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let raw = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:raw,withIntermediateDirectories:true)
        let root = URL(fileURLWithPath:canonicalProject(raw.path)), store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["title":"Knowledge fixture","path":root.path,"project":root.path])
        try work(root,store,AutomationService(store:store))
    }
    private func call(_ service: AutomationService, _ method: String, _ params: JSON) throws -> JSON {
        let valueToUnwrap = try service.handle(method,params) as? JSON
        return try XCTUnwrap(valueToUnwrap)
    }
    private func source(_ root: URL, _ store: VelaStore, kind: String = "library", extra: JSON = [:]) throws -> JSON {
        var item: JSON = ["title":"Harbor release notes","content":"Harbor retains local configuration. Publish only after the focused tests pass.","project":root.path,"state":"active","scope":"project","private":false]
        item.merge(extra) { _,new in new }; return try store.put(kind,item)
    }
    private func answer(_ item: JSON, quote: String = "Publish only after the focused tests pass.") -> JSON {
        ["claims":[["text":"发布前应通过定点测试。","citations":[["sourceId":string(item,"kind") + ":" + string(item,"id"),"quote":quote]]]],"unanswered":[]]
    }
    private func fake(_ root: URL, result: JSON, extraEvents: [JSON] = [], complete: Bool = true, mutation: String = "") throws -> URL {
        let path = root.appendingPathComponent("fake-codex-" + UUID().uuidString)
        var events: [JSON] = [["type":"thread.started","thread_id":"synthetic-knowledge-session"]] + extraEvents
        events.append(["type":"item.completed","item":["id":"answer-1","type":"agent_message","text":try jsonString(result)]])
        if complete { events.append(["type":"turn.completed","usage":["input_tokens":70,"output_tokens":30]]) }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'" }
        let script = "#!/bin/sh\nprintf 'called\\n' >> \(quote(root.appendingPathComponent("calls.txt").path))\nprintf '%s' \"$PWD\" > \(quote(root.appendingPathComponent("cwd.txt").path))\nprintf '%s\\0' \"$@\" > \(quote(root.appendingPathComponent("argv.bin").path))\n\(mutation)\ncat <<'VELA_KNOWLEDGE_FIXTURE_EOF'\n\(try events.map(jsonString).joined(separator:"\n"))\nVELA_KNOWLEDGE_FIXTURE_EOF\n"
        try Data(script.utf8).write(to:path); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path); return path
    }
    private func create(_ root: URL, _ service: AutomationService, _ binary: URL, extra: JSON = [:], followup: Bool = false) throws -> JSON {
        var params: JSON = ["project":root.path,"question":"Harbor 发布的条件是什么？","searchQuery":"Harbor","executable":binary.path,"model":"fixture-model","effort":"low"]
        params.merge(extra) { _,new in new }; return try call(service,followup ? "ask.followup" : "ask.create",params)
    }
    private func approve(_ service: AutomationService, _ query: JSON) throws -> JSON {
        let approval = try XCTUnwrap(query["approval"] as? JSON)
        return try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
    }
    private func current(_ root: URL, _ service: AutomationService, _ query: JSON) throws -> JSON { try call(service,"ask.get",["id":query["id"]!,"project":root.path]) }

    func testActualTransportRequiresApprovalAndKeepsSourceBoundCitations() throws {
        try fixture { root,store,service in
            let item = try source(root,store), binary = try fake(root,result:answer(item))
            let pending = try create(root,service,binary)
            XCTAssertEqual(string(pending,"state"),"pending_approval")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
            let approvalText = try jsonString(pending["approval"]!)
            XCTAssertFalse(approvalText.contains("Publish only after"))
            XCTAssertEqual(string(try approve(service,pending),"state"),"executed")
            let done = try current(root,service,pending)
            XCTAssertEqual(string(done,"state"),"answered"); XCTAssertEqual(done["completedModelCalls"] as? Int,1)
            XCTAssertEqual((done["metrics"] as? JSON)?["tokens"] as? Int,100)
            XCTAssertTrue(done["observedModel"] is NSNull)
            let citations = try call(service,"ask.citations",["id":done["id"]!,"project":root.path,"askHash":done["askHash"]!])
            XCTAssertEqual((citations["citations"] as? [JSON])?.count,1)
            XCTAssertEqual(try store.list("memory").count,0)
            let argv = try Data(contentsOf:root.appendingPathComponent("argv.bin")).split(separator:0).map { String(decoding:$0,as:UTF8.self) }
            for flag in ["--ignore-rules","--ignore-user-config","read-only","mcp_servers={}","code_mode_host","shell_tool","memories"] { XCTAssertTrue(argv.contains(flag)) }
            XCTAssertTrue(argv.last?.contains("Publish only after") == true)
            let cwd = try String(contentsOf:root.appendingPathComponent("cwd.txt")); XCTAssertTrue(cwd.contains("vela-knowledge-answer-")); XCTAssertFalse(FileManager.default.fileExists(atPath:cwd))
            XCTAssertThrowsError(try approve(service,pending)); XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("calls.txt")),"called\n")
            let run = try XCTUnwrap(store.get("run",string(done,"runId")))
            XCTAssertEqual(string(run,"purpose"),"knowledge_query"); XCTAssertEqual(string(run,"state"),"completed")
            XCTAssertFalse(try jsonString(run).contains("Publish only after"))
        }
    }
    func testPrivateMalformedInactiveForeignAndMismatchedScopedSourcesAreExcluded() throws {
        try fixture { root,store,service in
            for extra: JSON in [["private":true],["private":"false"],["sourceLabeledPrivate":true],["sourceLabeledPrivate":"false"],["scope":"private"],["sourcePath":root.appendingPathComponent("private/notes.md").path],["state":"archived"],["project":root.deletingLastPathComponent().path]] { _ = try source(root,store,extra:extra) }
            for extra: JSON in [["state":"candidate"],["scope":"global"],["scope":"branch","branch":"other"],["scope":"session","sourceSession":"other"],["private":1]] { _ = try source(root,store,kind:"memory",extra:extra) }
            let binary = try fake(root,result:["claims":[],"unanswered":["No source"]])
            let empty = try create(root,service,binary)
            XCTAssertEqual(string(empty,"state"),"no_sources"); XCTAssertNil(empty["approval"])
            XCTAssertEqual(try store.list("approval").count,0); XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
            let scoped = try source(root,store,kind:"memory",extra:["scope":"branch","branch":"main"])
            let selected = try create(root,service,binary,extra:["branch":"main"])
            let sources = (selected["request"] as? JSON)?["sources"] as? [JSON] ?? []
            XCTAssertEqual(sources.count,1); XCTAssertEqual(string(sources[0],"id"),string(scoped,"id"))
        }
    }
    func testChangedPrivateDeletedAndEditedSourcesStopBeforeModelAndHideOldContent() throws {
        try fixture { root,store,service in
            for mutation in ["private","delete","edit","missing_asset"] {
                let item = try source(root,store), pending = try create(root,service,fake(root,result:answer(item)))
                switch mutation {
                case "private": var changed = item; changed["private"] = true; _ = try store.put("library",changed)
                case "delete": try store.remove("library",string(item,"id"))
                case "edit": var changed = item; changed["content"] = "Harbor changed its conditions."; _ = try store.put("library",changed)
                default: try FileManager.default.removeItem(atPath:string(item,"assetPath"))
                }
                XCTAssertEqual(string(try approve(service,pending),"state"),"failed")
                let stale = try current(root,service,pending)
                XCTAssertEqual(string(stale,"state"),"sources_unavailable"); XCTAssertNil(stale["request"]); XCTAssertNil(stale["result"])
                XCTAssertThrowsError(try call(service,"ask.citations",["project":root.path,"id":stale["id"]!,"askHash":stale["askHash"]!]))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
        }
    }
    func testMissingFabricatedDuplicateCredentialAndToolAnswersNeverPublish() throws {
        try fixture { root,store,service in
            let item = try source(root,store)
            let citation: JSON = ["sourceId":"library:" + string(item,"id"),"quote":"Publish only after the focused tests pass."]
            let invalid: [JSON] = [answer(item,quote:"This quote never existed"),["claims":[["text":"Uncited claim","citations":[]]],"unanswered":[]],
                ["claims":[["text":"Duplicate","citations":[citation,citation]]],"unanswered":[]],
                ["claims":[["text":"password=synthetic-secret","citations":[citation]]],"unanswered":[]],
                ["claims":[],"unanswered":[],"tool":"shell.test"]]
            for response in invalid {
                let pending = try create(root,service,fake(root,result:response))
                XCTAssertEqual(string(try approve(service,pending),"state"),"failed")
                XCTAssertNil(try current(root,service,pending)["result"])
            }
            let tool: JSON = ["type":"item.completed","item":["id":"tool-1","type":"command_execution","command":"read private data","status":"completed","exit_code":0]]
            for binary in [try fake(root,result:answer(item),extraEvents:[tool]),try fake(root,result:answer(item),complete:false)] {
                let pending = try create(root,service,binary); XCTAssertEqual(string(try approve(service,pending),"state"),"failed")
            }
            XCTAssertFalse(try jsonString(store.list("knowledge_query")).contains("synthetic-secret"))
            XCTAssertFalse(try jsonString(store.list("approval")).contains("synthetic-secret"))
        }
    }
    func testSourceMutationDuringProviderRejectsPublicationWithoutSavingRawAnswer() throws {
        try fixture { root,store,service in
            let item = try source(root,store)
            let path = string(item,"assetPath").replacingOccurrences(of:"'",with:"'\\''")
            let binary = try fake(root,result:answer(item),mutation:"printf '%s' '<!-- Vela metadata: {} -->\n\n# Changed\n\nHarbor mutated during provider.\n' > '\(path)'")
            let pending = try create(root,service,binary)
            XCTAssertEqual(string(try approve(service,pending),"state"),"failed")
            let raw = try XCTUnwrap(store.get("knowledge_query",string(pending,"id")))
            XCTAssertNil(raw["result"]); XCTAssertNil(raw["rawProtocol"]); XCTAssertNotNil(raw["protocolHash"])
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("calls.txt")),"called\n")
        }
    }
    func testFollowupRequiresFreshHashAndRechecksAllPriorSources() throws {
        try fixture { root,store,service in
            let item = try source(root,store), binary = try fake(root,result:answer(item))
            let pending = try create(root,service,binary); _ = try approve(service,pending)
            let done = try current(root,service,pending)
            XCTAssertThrowsError(try create(root,service,binary,extra:["id":done["id"]!,"askHash":"stale"],followup:true))
            let next = try create(root,service,binary,extra:["id":done["id"]!,"askHash":done["askHash"]!,"question":"用英文再解释一次"],followup:true)
            XCTAssertEqual(next["round"] as? Int,2)
            let request = try XCTUnwrap(next["request"] as? JSON)
            XCTAssertEqual((request["history"] as? [JSON])?.count,1)
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("calls.txt")),"called\n")
            var hidden = item; hidden["private"] = true; _ = try store.put("library",hidden)
            XCTAssertEqual(string(try approve(service,next),"state"),"failed")
            XCTAssertThrowsError(try create(root,service,binary,extra:["id":done["id"]!,"askHash":done["askHash"]!],followup:true))
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("calls.txt")),"called\n")
        }
    }
    func testBoundedExcerptCannotBeCitedOutsideFrozenWindowAndRedactsSecrets() throws {
        try fixture { root,store,service in
            let item = try source(root,store,extra:["content":"Harbor api_key=synthetic-hidden-key\n" + String(repeating:"前",count:2000) + "Outside window."])
            let pending = try create(root,service,fake(root,result:answer(item,quote:"Outside window.")),extra:["maxSourceBytes":1000])
            let request = try XCTUnwrap(pending["request"] as? JSON), sources = try XCTUnwrap(request["sources"] as? [JSON])
            XCTAssertEqual(sources[0]["truncated"] as? Bool,true); XCTAssertLessThanOrEqual(string(sources[0],"content").utf8.count,1000)
            XCTAssertFalse(try jsonString(pending).contains("synthetic-hidden-key"))
            XCTAssertEqual(string(try approve(service,pending),"state"),"failed")
        }
    }
    func testLinkedAssetsCrossProjectReadsUnknownParametersAndBudgetTypesFailClosed() throws {
        try fixture { root,store,service in
            let item = try source(root,store), binary = try fake(root,result:answer(item)), pending = try create(root,service,binary)
            let other = root.deletingLastPathComponent(); _ = try store.put("project",["project":other.path,"path":other.path,"title":"Other"])
            XCTAssertThrowsError(try call(service,"ask.get",["id":pending["id"]!,"project":other.path]))
            for extra: JSON in [["maxSources":true],["maxSources":13],["maxSourceBytes":999],["timeoutSeconds":301],["includePrivate":true],["effort":"unknown"]] { XCTAssertThrowsError(try create(root,service,binary,extra:extra)) }
            let target = root.appendingPathComponent("linked.md"); try Data("Harbor secret".utf8).write(to:target)
            try FileManager.default.removeItem(atPath:string(item,"assetPath")); try FileManager.default.createSymbolicLink(atPath:string(item,"assetPath"),withDestinationPath:target.path)
            XCTAssertEqual(string(try approve(service,pending),"state"),"failed")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
        }
    }
    func testCancellationAndUncertainRecoveryDoNotReuseAuthorization() throws {
        try fixture { root,store,service in
            let item = try source(root,store), binary = try fake(root,result:answer(item)), pending = try create(root,service,binary)
            let cancelled = try call(service,"ask.cancel",["project":root.path,"id":pending["id"]!,"askHash":pending["askHash"]!])
            XCTAssertEqual(string(cancelled,"state"),"rejected"); XCTAssertThrowsError(try approve(service,pending))
            let next = try create(root,service,binary), approval = try XCTUnwrap(next["approval"] as? JSON)
            _ = try store.claimState(kind:"approval",id:string(approval,"id"),expected:"pending",newState:"executing")
            let reopened = AutomationService(store:try VelaStore(root:store.root))
            XCTAssertEqual(string(try current(root,reopened,next),"state"),"executing_or_uncertain")
            XCTAssertThrowsError(try approve(reopened,next))
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
        }
    }
    func testStalePendingQuestionCanBeCancelledAndListDoesNotReadSourceBodies() throws {
        try fixture { root,store,service in
            let item = try source(root,store), pending = try create(root,service,fake(root,result:answer(item)))
            try FileManager.default.removeItem(atPath:string(item,"assetPath"))
            let listed = try XCTUnwrap(service.handle("ask.list",["project":root.path]) as? [JSON])
            XCTAssertEqual(listed.count,1); XCTAssertNil(listed[0]["request"]); XCTAssertNil(listed[0]["result"]); XCTAssertNil(listed[0]["askHash"])
            XCTAssertEqual(string(listed[0],"sourceValidation"),"not_checked_on_list")
            let stale = try current(root,service,pending)
            _ = try call(service,"ask.cancel",["id":stale["id"]!,"project":root.path,"askHash":stale["askHash"]!])
            let approval = try XCTUnwrap(store.get("approval",string(pending,"approvalId")))
            XCTAssertEqual(string(approval,"state"),"rejected")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
        }
    }
    func testFrozenAskRequestMutationAndDirectExecutionAreRejected() throws {
        try fixture { root,store,service in
            let item = try source(root,store), pending = try create(root,service,fake(root,result:answer(item)))
            let approval = try XCTUnwrap(pending["approval"] as? JSON), arguments = try XCTUnwrap(approval["arguments"] as? JSON)
            XCTAssertThrowsError(try service.executeKnowledgeQuery(arguments,project:root.path))
            var altered = try XCTUnwrap(store.get("knowledge_query",string(pending,"id")))
            var request = try XCTUnwrap(altered["request"] as? JSON); request["question"] = "Changed question"; altered["request"] = request
            _ = try store.put("knowledge_query",altered)
            XCTAssertEqual(string(try approve(service,pending),"state"),"failed")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
        }
    }
    func testNewPrivateOriginLabelRevokesAnExistingPendingQuestion() throws {
        try fixture { root,store,service in
            var item = try source(root,store), pending = try create(root,service,fake(root,result:answer(item)))
            item["sourceLabeledPrivate"] = true; _ = try store.put("library",item)
            XCTAssertEqual(string(try approve(service,pending),"state"),"failed")
            XCTAssertEqual(string(try current(root,service,pending),"state"),"sources_unavailable")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
        }
    }
    func testExplicitLibraryFTSFreezesMatchingParagraphBeyondTheDefaultPrefix() throws {
        try fixture { root,store,service in
            let item = try source(root,store,extra:["title":"Release manual","content":"Introduction " + String(repeating:"ordinary text ",count:500) + "\n\n# Release\n\nCedarPolicy requires parser verification."])
            let index = try LibraryIndex(store:store)
            _ = try index.handle("library.index",["project":root.path])
            let matches = try index.handle("library.search",["project":root.path,"query":"CedarPolicy"])["items"] as? [JSON] ?? []
            let paragraph = try XCTUnwrap(matches.first)
            let result: JSON = ["claims":[["text":"CedarPolicy 要求解析器验证。","citations":[["sourceId":"library:" + string(paragraph,"citationId"),"quote":"CedarPolicy requires parser verification."]]]],"unanswered":[]]
            let pending = try create(root,service,fake(root,result:result),extra:["retrievalMode":"library_fts","searchQuery":"CedarPolicy"])
            let request = try XCTUnwrap(pending["request"] as? JSON), sources = try XCTUnwrap(request["sources"] as? [JSON])
            XCTAssertEqual(sources.count,1); XCTAssertEqual(string(sources[0],"content"),"CedarPolicy requires parser verification.")
            XCTAssertGreaterThan(intValue(sources[0],"fullSourceBytes"),6000)
            XCTAssertEqual((sources[0]["paragraph"] as? JSON)?["anchor"] as? String,string(paragraph,"anchor"))
            XCTAssertEqual((request["retrieval"] as? JSON)?["mode"] as? String,"library_fts")
            XCTAssertEqual((request["retrieval"] as? JSON)?["fallback"] as? Bool,false)
            XCTAssertEqual(string(try approve(service,pending),"state"),"executed")
            XCTAssertEqual(string(try current(root,service,pending),"state"),"answered")
            XCTAssertEqual(string(item,"kind"),"library")
        }
    }
    func testLibraryFTSDoesNotFallbackOrIndexImplicitlyAndRejectsStaleParagraphs() throws {
        try fixture { root,store,service in
            var item = try source(root,store)
            let binary = try fake(root,result:answer(item))
            let missing = try create(root,service,binary,extra:["retrievalMode":"library_fts"])
            XCTAssertEqual(string(missing,"state"),"no_sources")
            let index = try LibraryIndex(store:store)
            let status = try index.handle("library.index.status",["project":root.path])
            XCTAssertEqual(intValue(status,"indexedPublicDocuments"),0)
            _ = try index.handle("library.index",["project":root.path])
            let paragraph = try XCTUnwrap((try index.handle("library.search",["project":root.path,"query":"Harbor"])["items"] as? [JSON])?.first)
            item["content"] = "Harbor content changed after the index was created."; _ = try store.put("library",item)
            XCTAssertThrowsError(try KnowledgeQuery.source(try XCTUnwrap(store.get("library",string(item,"id"))),bytes:4000,paragraph:paragraph))
            let stale = try create(root,service,binary,extra:["retrievalMode":"library_fts"])
            XCTAssertEqual(string(stale,"state"),"no_sources")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls.txt").path))
        }
    }
}
