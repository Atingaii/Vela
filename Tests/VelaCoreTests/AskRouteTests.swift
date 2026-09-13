import XCTest
@testable import VelaCore

final class AskRouteTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("vela-ask-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try VelaStore(root:root.appendingPathComponent("store"))
        _ = try store.put("project",["project":root.path,"path":root.path,"title":"Route fixture"])
        try body(root,store,AutomationService(store:store))
    }
    private func call(_ service: AutomationService, _ method: String, _ params: JSON) throws -> JSON {
        guard let value = try service.handle(method,params) as? JSON else { throw VelaError("No route response") }
        return value
    }
    private func source(_ store: VelaStore, _ root: URL, id: String, kind: String = "memory", extra: JSON = [:]) throws {
        var item: JSON = ["id":id,"project":root.path,"title":"Release policy","content":"Harbor release requires focused tests.","state":"active","scope":"project","private":false]
        item.merge(extra) { _,new in new }
        _ = try store.put(kind,item)
    }
    private func proposalProvider(_ root: URL, answer: JSON) throws -> URL {
        let executable = root.appendingPathComponent("ask-route-provider-\(UUID().uuidString).sh")
        let count = executable.deletingPathExtension().path + ".count"
        let events: [JSON] = [
            ["type":"thread.started","thread_id":"synthetic-ask-route"],
            ["type":"item.completed","item":["id":"answer","type":"agent_message","text":try jsonString(answer)]],
            ["type":"turn.completed","usage":["input_tokens":12,"output_tokens":8]]
        ]
        let script = "#!/bin/sh\ncount=0\n[ ! -f '\(count)' ] || count=$(cat '\(count)')\ncount=$((count+1))\nprintf '%s' \"$count\" > '\(count)'\ncat <<'VELA_ASK_ROUTE_JSON'\n" + (try events.map(jsonString).joined(separator:"\n")) + "\nVELA_ASK_ROUTE_JSON\n"
        try Data(script.utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        return executable
    }
    private func approve(_ service: AutomationService, _ proposal: JSON) throws -> JSON {
        let approval = try XCTUnwrap(proposal["approval"] as? JSON)
        return try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
    }

    func testKnowledgeRoutePersistsVisibleEvidenceWithoutCreatingAQueryOrApproval() throws {
        try fixture { root,store,service in
            try source(store,root,id:"visible")
            try source(store,root,id:"private",extra:["private":true,"content":"Harbor private secret"])
            let route = try call(service,"ask.route",["project":root.path,"question":"What is the Harbor release policy?"])
            XCTAssertEqual(string(route,"state"),"decided")
            XCTAssertEqual((route["decision"] as? JSON)?["kind"] as? String,"knowledge_query")
            XCTAssertEqual((route["decision"] as? JSON)?["nextMethod"] as? String,"ask.create")
            XCTAssertEqual((route["candidates"] as? [JSON])?.count,1)
            XCTAssertEqual(string((route["candidates"] as? [JSON])![0],"id"),"visible")
            XCTAssertFalse(try jsonString(route).contains("private secret"))
            XCTAssertEqual(try store.list("knowledge_query").count,0); XCTAssertEqual(try store.list("approval").count,0); XCTAssertEqual(try store.list("run").count,0)
            let reopened = try call(service,"ask.route.get",["project":root.path,"id":route["id"]!])
            XCTAssertEqual(string(reopened,"routeHash"),string(route,"routeHash"))
            let page = try call(service,"ask.route.list",["project":root.path])
            XCTAssertEqual((page["items"] as? [JSON])?.count,1)
            XCTAssertTrue(page["nextCursor"] is NSNull)
        }
    }

    func testFourKilobyteQuestionKeepsFullInputAndUsesCharacterSafeDisplayTitle() throws {
        try fixture { root,_,service in
            let question = String(repeating:"界",count:1333) + "a" // 4,000 UTF-8 bytes.
            XCTAssertEqual(question.utf8.count,4000)
            let route = try call(service,"ask.route",["project":root.path,"question":question])
            XCTAssertEqual(string(route,"question"),question)
            let title = string(route,"title")
            XCTAssertLessThanOrEqual(title.utf8.count,240)
            XCTAssertTrue(title.hasSuffix("…"))
            XCTAssertFalse(title.unicodeScalars.contains { $0.value == 0xFFFD })
        }
    }

    func testCandidateScanIncludesOlderMatchesBeyondDefaultStorePageForAllKinds() throws {
        try fixture { root,store,service in
            try source(store,root,id:"memory-needle",extra:["title":"Memory needle","content":"needle"])
            try source(store,root,id:"library-needle",kind:"library",extra:["title":"Library needle","content":"needle"])
            _ = try store.put("workflow",["id":"workflow-needle","project":root.path,"title":"Workflow needle","description":"needle","version":1,"enabled":true,"state":"active"])
            for number in 0..<500 {
                try source(store,root,id:"memory-noise-\(number)",extra:["title":"noise","content":"unrelated"])
                try source(store,root,id:"library-noise-\(number)",kind:"library",extra:["title":"noise","content":"unrelated"])
                _ = try store.put("workflow",["id":"workflow-noise-\(number)","project":root.path,"title":"noise","description":"unrelated","version":1,"enabled":true,"state":"active"])
            }
            let route = try call(service,"ask.route",["project":root.path,"question":"needle"])
            let candidates = route["candidates"] as? [JSON] ?? []
            XCTAssertTrue(candidates.contains { string($0,"id") == "memory-needle" })
            XCTAssertTrue(candidates.contains { string($0,"id") == "library-needle" })
            XCTAssertTrue((route["workflowCandidates"] as? [JSON] ?? []).contains { string($0,"id") == "workflow-needle" })
        }
    }

    func testPrivateCandidateBeforeProposalCreatesNoLedgerRecords() throws {
        try fixture { root,store,service in
            try source(store,root,id:"visible",extra:["title":"Visible candidate","content":"needle"])
            let route = try call(service,"ask.route",["project":root.path,"question":"needle"])
            var privateSource = try XCTUnwrap(store.get("memory","visible")); privateSource["private"] = true; _ = try store.put("memory",privateSource)
            XCTAssertThrowsError(try call(service,"ask.route.propose",["project":root.path,"id":route["id"]!,"routeHash":route["routeHash"]!,"executable":"/usr/bin/true","model":"fixture-model"]))
            XCTAssertTrue(try store.list("ask_route_proposal").isEmpty)
            XCTAssertTrue(try store.list("approval").isEmpty)
            XCTAssertTrue(try store.list("run").isEmpty)
        }
    }

    func testLegacyRouteHashRemainsReadableButCannotCreateProposal() throws {
        try fixture { root,store,service in
            let route = try call(service,"ask.route",["project":root.path,"question":"legacy route"])
            var legacy = route; legacy.removeValue(forKey:"routeHashVersion"); legacy["routeHash"] = try AskRoute.hash(legacy)
            _ = try store.put("ask_route",legacy)
            XCTAssertEqual(string(try call(service,"ask.route.get",["project":root.path,"id":legacy["id"]!]),"id"),string(legacy,"id"))
            XCTAssertThrowsError(try call(service,"ask.route.propose",["project":root.path,"id":legacy["id"]!,"routeHash":legacy["routeHash"]!,"executable":"/usr/bin/true","model":"fixture-model"]))
            XCTAssertTrue(try store.list("ask_route_proposal").isEmpty)
        }
    }

    func testPlanningAndExecutionRoutesOnlyReturnSeparateNextActions() throws {
        try fixture { root,store,service in
            let draft = try call(service,"ask.route",["project":root.path,"question":"Draft an automation workflow for releases"])
            XCTAssertEqual((draft["decision"] as? JSON)?["kind"] as? String,"workflow_draft")
            XCTAssertEqual((draft["decision"] as? JSON)?["nextMethod"] as? String,"workflows.plan")
            XCTAssertEqual(try store.list("workflow_plan").count,0); XCTAssertEqual(try store.list("approval").count,0)
            _ = try store.put("workflow",["id":"release-review","project":root.path,"title":"Release review","description":"Review release policy","version":1,"enabled":true,"state":"active"])
            let run = try call(service,"ask.route",["project":root.path,"question":"Run the release review"])
            XCTAssertEqual((run["decision"] as? JSON)?["kind"] as? String,"reviewed_execution")
            XCTAssertEqual((run["decision"] as? JSON)?["workflowId"] as? String,"release-review")
            XCTAssertEqual((run["decision"] as? JSON)?["requiresSeparateExplicitCall"] as? Bool,true)
            XCTAssertEqual(try store.list("run").count,0)
        }
    }

    func testCrossProjectPrivateScopeAndMalformedRequestsFailClosed() throws {
        try fixture { root,store,service in
            try source(store,root,id:"branch",extra:["scope":"branch","branch":"main"])
            let scoped = try call(service,"ask.route",["project":root.path,"question":"Harbor policy","branch":"main"])
            XCTAssertEqual((scoped["candidates"] as? [JSON])?.count,1)
            let unscoped = try call(service,"ask.route",["project":root.path,"question":"Harbor policy"])
            XCTAssertEqual((unscoped["candidates"] as? [JSON])?.count,0)
            let other = root.deletingLastPathComponent(); _ = try store.put("project",["project":other.path,"path":other.path,"title":"Other"])
            XCTAssertThrowsError(try call(service,"ask.route.get",["project":other.path,"id":scoped["id"]!]))
            XCTAssertThrowsError(try call(service,"ask.route",["project":root.path,"question":"sk-abcdefghijklmnopqrstuvwx"]))
            XCTAssertThrowsError(try call(service,"ask.route",["project":root.path,"question":"ok","includePrivate":true]))
        }
    }

    func testReviewedModelProposalUsesFrozenVisibleCandidatesAndNeverExecutesRoute() throws {
        try fixture { root,store,service in
            try source(store,root,id:"visible")
            let route = try call(service,"ask.route",["project":root.path,"question":"Harbor release policy"])
            let provider = try proposalProvider(root,answer:["kind":"knowledge_query","targetId":"memory:visible","reason":"visible release evidence matches"])
            let proposal = try call(service,"ask.route.propose",["project":root.path,"id":route["id"]!,"routeHash":route["routeHash"]!,"executable":provider.path,"model":"fixture-model"])
            XCTAssertFalse(FileManager.default.fileExists(atPath:provider.deletingPathExtension().path+".count"))
            XCTAssertEqual(string(proposal,"state"),"pending_approval")
            XCTAssertEqual(try store.list("knowledge_query").count,0)
            XCTAssertEqual(string(try approve(service,proposal),"state"),"executed")
            let saved = try call(service,"ask.route.proposal.get",["project":root.path,"id":proposal["id"]!])
            XCTAssertEqual(string(saved,"state"),"proposed")
            XCTAssertEqual((saved["result"] as? JSON)?["kind"] as? String,"knowledge_query")
            XCTAssertEqual(try String(contentsOfFile:provider.deletingPathExtension().path+".count"),"1")
            XCTAssertEqual(try store.list("knowledge_query").count,0)
            XCTAssertEqual(try store.list("workflow_plan").count,0)
        }
    }

    func testReviewedModelProposalFailsBeforeProviderWhenSourceChangesPrivate() throws {
        try fixture { root,store,service in
            try source(store,root,id:"visible")
            let route = try call(service,"ask.route",["project":root.path,"question":"Harbor release policy"])
            let provider = try proposalProvider(root,answer:["kind":"knowledge_query","targetId":"memory:visible","reason":"should not run"])
            let proposal = try call(service,"ask.route.propose",["project":root.path,"id":route["id"]!,"routeHash":route["routeHash"]!,"executable":provider.path,"model":"fixture-model"])
            var changed = try XCTUnwrap(store.get("memory","visible")); changed["private"] = true; _ = try store.put("memory",changed)
            XCTAssertEqual(string(try approve(service,proposal),"state"),"failed")
            XCTAssertFalse(FileManager.default.fileExists(atPath:provider.deletingPathExtension().path+".count"))
            let saved = try call(service,"ask.route.proposal.get",["project":root.path,"id":proposal["id"]!])
            XCTAssertEqual(string(saved,"state"),"failed")
            XCTAssertEqual(string(saved,"sourceValidation"),"unavailable")
            XCTAssertNil(saved["request"])
            XCTAssertEqual(try store.list("knowledge_query").count,0)
        }
    }

    func testPrivateSourceRevocationRedactsProposalAndScopedInbox() throws {
        try fixture { root,store,service in
            try source(store,root,id:"visible",extra:["title":"Visible before privacy revocation"])
            let route = try call(service,"ask.route",["project":root.path,"question":"Visible privacy revocation"])
            let provider = try proposalProvider(root,answer:["kind":"knowledge_query","targetId":"memory:visible","reason":"not called"])
            let proposal = try call(service,"ask.route.propose",["project":root.path,"id":route["id"]!,"routeHash":route["routeHash"]!,"executable":provider.path,"model":"fixture-model"])
            let other = root.deletingLastPathComponent(); _ = try store.put("project",["project":other.path,"path":other.path,"title":"Other"])
            var changed = try XCTUnwrap(store.get("memory","visible")); changed["private"] = true; _ = try store.put("memory",changed)
            let sameProject = try call(service,"ask.route.proposal.get",["project":root.path,"id":proposal["id"]!])
            XCTAssertEqual(string(sameProject,"sourceValidation"),"unavailable")
            XCTAssertNil(sameProject["request"]); XCTAssertFalse(try jsonString(sameProject).contains("Visible before privacy revocation"))
            XCTAssertThrowsError(try call(service,"ask.route.proposal.get",["project":other.path,"id":proposal["id"]!]))
            let globalInbox = try XCTUnwrap(service.handle("inbox.list",[:]) as? [JSON])
            XCTAssertFalse(globalInbox.contains { string($0,"id") == string((proposal["approval"] as? JSON) ?? [:],"id") })
            let scopedInbox = try XCTUnwrap(service.handle("inbox.list",["project":root.path]) as? [JSON])
            let approval = try XCTUnwrap(scopedInbox.first { string($0,"id") == string((proposal["approval"] as? JSON) ?? [:],"id") })
            let safeArguments = try XCTUnwrap(approval["arguments"] as? JSON)
            XCTAssertEqual(safeArguments["proposalId"] as? String,string(proposal,"id"))
            XCTAssertNil(safeArguments["request"])
            XCTAssertFalse(try jsonString(approval).contains("Visible before privacy revocation"))
            let foreignInbox = try XCTUnwrap(service.handle("inbox.list",["project":other.path]) as? [JSON])
            XCTAssertFalse(foreignInbox.contains { string($0,"id") == string(approval,"id") })
        }
    }

    func testRouteListUsesProjectBoundOpaqueCursorWithoutSilentHundredItemCutoff() throws {
        try fixture { root,store,service in
            for number in 0..<101 { _ = try call(service,"ask.route",["project":root.path,"question":"route page \(number)"]) }
            let first = try call(service,"ask.route.list",["project":root.path,"limit":100])
            let firstItems = try XCTUnwrap(first["items"] as? [JSON]), cursor = try XCTUnwrap(first["nextCursor"] as? String)
            XCTAssertEqual(firstItems.count,100); XCTAssertTrue(cursor.hasPrefix("vela-ask-route-page-v1."))
            let second = try call(service,"ask.route.list",["project":root.path,"limit":100,"cursor":cursor])
            let secondItems = try XCTUnwrap(second["items"] as? [JSON])
            XCTAssertEqual(secondItems.count,1); XCTAssertTrue(second["nextCursor"] is NSNull)
            let repeated = try call(service,"ask.route.list",["project":root.path,"limit":100,"cursor":cursor])
            XCTAssertEqual(secondItems.map { string($0,"id") },(repeated["items"] as? [JSON] ?? []).map { string($0,"id") })
            XCTAssertTrue(Set(firstItems.map { string($0,"id") }).isDisjoint(with:Set(secondItems.map { string($0,"id") })))
            let other = root.deletingLastPathComponent(); _ = try store.put("project",["project":other.path,"path":other.path,"title":"Other"])
            XCTAssertThrowsError(try call(service,"ask.route.list",["project":other.path,"limit":100,"cursor":cursor]))
            XCTAssertThrowsError(try call(service,"ask.route.list",["project":root.path,"limit":101]))
        }
    }

    func testProposalRejectionCrossProjectAndMalformedModelOutputFailClosed() throws {
        try fixture { root,store,service in
            try source(store,root,id:"visible")
            let route = try call(service,"ask.route",["project":root.path,"question":"Harbor release policy"])
            let rejectedProvider = try proposalProvider(root,answer:["kind":"knowledge_query","targetId":"memory:visible","reason":"not called after rejection"])
            let rejected = try call(service,"ask.route.propose",["project":root.path,"id":route["id"]!,"routeHash":route["routeHash"]!,"executable":rejectedProvider.path,"model":"fixture-model"])
            let other = root.deletingLastPathComponent(); _ = try store.put("project",["project":other.path,"path":other.path,"title":"Other"])
            XCTAssertThrowsError(try call(service,"ask.route.proposal.get",["project":other.path,"id":rejected["id"]!]))
            let rejection = rejected["approval"] as! JSON
            _ = try call(service,"approvals.decide",["id":rejection["id"]!,"snapshotHash":rejection["snapshotHash"]!,"decision":"reject"])
            XCTAssertEqual(string(try call(service,"ask.route.proposal.get",["project":root.path,"id":rejected["id"]!]),"state"),"rejected")
            XCTAssertFalse(FileManager.default.fileExists(atPath:rejectedProvider.deletingPathExtension().path+".count"))
            let badProvider = try proposalProvider(root,answer:["kind":"knowledge_query","targetId":"memory:outside","reason":"forged target"])
            let bad = try call(service,"ask.route.propose",["project":root.path,"id":route["id"]!,"routeHash":route["routeHash"]!,"executable":badProvider.path,"model":"fixture-model"])
            XCTAssertEqual(string(try approve(service,bad),"state"),"failed")
            XCTAssertEqual(string(try call(service,"ask.route.proposal.get",["project":root.path,"id":bad["id"]!]),"state"),"failed")
            XCTAssertEqual(try store.list("knowledge_query").count,0)
        }
    }
}
