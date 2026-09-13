import Foundation

/// A deterministic, persisted routing decision. It never invokes a model, tool,
/// workflow, or approval; callers must explicitly perform the returned next step.
enum AskRoute {
    static let protocolVersion = "vela-ask-route-v1"
    static let proposalProtocol = "vela-ask-route-proposal-v1"
    static let routeHashVersion = 2
    static let candidateScanLimit = 10_000
    static let proposalSchema: JSON = ModelImprovement.objectSchema([
        "kind":ModelImprovement.textSchema,
        "targetId":ModelImprovement.textSchema,
        "reason":ModelImprovement.textSchema
    ])

    static func safeText(_ params: JSON, _ key: String, limit: Int) throws -> String {
        let value = try requireString(params,key)
        guard !value.contains("\0"), value.utf8.count <= limit, ModelImprovement.redact(value) == value else { throw VelaError("Invalid or credential-bearing Ask route \(key)") }
        return value
    }

    /// A route keeps the complete, validated question separately. Its short title
    /// is presentation-only and must never reject a legal question or split a
    /// user-visible character while observing the storage title bound.
    static func displayTitle(_ value: String, limit: Int = 240) -> String {
        guard value.utf8.count > limit else { return value }
        let suffix = "…"
        var title = ""
        for character in value {
            let next = String(character)
            guard title.utf8.count + next.utf8.count + suffix.utf8.count <= limit else { break }
            title.append(character)
        }
        return title.isEmpty ? "Ask route" : title + suffix
    }

    static func terms(_ question: String) -> [String] {
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.utf8.count >= 2 }
        return Array(Set(words)).sorted().prefix(12).map { $0 }
    }

    static func score(_ title: String, _ words: [String]) -> Int {
        let haystack = title.lowercased()
        return words.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
    }

    static func isPlanningQuestion(_ question: String) -> Bool {
        let lower = question.lowercased()
        return ["workflow","work flow","automate","automation","draft","计划","工作流","自动化","草稿"].contains { lower.contains($0) }
    }

    static func hash(_ item: JSON) throws -> String {
        let legacy = ["id","project","question","scope","decision","candidates","createdAt"]
        let fields = intValue(item,"routeHashVersion") == routeHashVersion
            ? legacy + ["routeHashVersion","workflowCandidates"]
            : legacy
        return stableHash(try jsonString(item.filter { fields.contains($0.key) }))
    }

    static func pageCursor(project: String, anchorID: String) throws -> String {
        let payload: JSON = ["version":1,"projectHash":stableHash(project),"anchorID":anchorID]
        return "vela-ask-route-page-v1." + Data((try jsonString(payload)).utf8).base64EncodedString()
    }

    static func pageAnchor(_ value: String, project: String) throws -> String {
        let prefix = "vela-ask-route-page-v1."
        guard value.hasPrefix(prefix),
              let data = Data(base64Encoded:String(value.dropFirst(prefix.count))),
              let payload = try JSONSerialization.jsonObject(with:data) as? JSON,
              Set(payload.keys) == Set(["version","projectHash","anchorID"]),
              intValue(payload,"version") == 1,
              string(payload,"projectHash") == stableHash(project),
              UUID(uuidString:string(payload,"anchorID")) != nil else {
            throw VelaError("Ask route page is unavailable")
        }
        return string(payload,"anchorID")
    }
}

extension AutomationService {
    func handleAskRoute(_ method: String, _ params: JSON) throws -> Any? {
        switch method {
        case "ask.route": return try createAskRoute(params)
        case "ask.route.get":
            guard Set(params.keys) == Set(["id","project"]) else { throw VelaError("Unsupported Ask route parameter") }
            let root = try project(requireString(params,"project"))
            return try askRouteView(try askRoute(id:requireString(params,"id"),project:root),project:root)
        case "ask.route.list": return try listAskRoutes(params)
        case "ask.route.propose": return try createAskRouteProposal(params)
        case "ask.route.proposal.get":
            guard Set(params.keys) == Set(["id","project"]) else { throw VelaError("Unsupported Ask route proposal parameter") }
            let root = try project(requireString(params,"project"))
            guard let item = try store.get("ask_route_proposal",requireString(params,"id")), string(item,"project") == root else { throw VelaError("Ask route proposal is unavailable for this project") }
            return try askRouteProposalView(item,project:root)
        default: return nil
        }
    }

    private func askRoute(id: String, project root: String) throws -> JSON {
        guard let item = try store.get("ask_route",id), string(item,"project") == root else { throw VelaError("Ask route is unavailable for this project") }
        return item
    }

    private func listAskRoutes(_ params: JSON) throws -> JSON {
        let allowed: Set<String> = ["project","limit","cursor"]
        guard Set(params.keys).isSubset(of:allowed) else { throw VelaError("Unsupported Ask route parameter") }
        let root = try project(requireString(params,"project"))
        let limit = try WorkflowContext.integer(params["limit"],default:50,range:1...100,name:"Ask route page limit")
        let routes = try store.list("ask_route",project:root,limit:10_000)
        guard routes.count < 10_000 else { throw VelaError("Ask route index limit reached") }
        let start: Int
        if let cursor = params["cursor"] as? String {
            let anchor = try AskRoute.pageAnchor(cursor,project:root)
            guard let index = routes.firstIndex(where: { string($0,"id") == anchor }) else { throw VelaError("Ask route page is unavailable") }
            start = index + 1
        } else if params["cursor"] == nil {
            start = 0
        } else {
            throw VelaError("Ask route page is unavailable")
        }
        let items = try Array(routes.dropFirst(start).prefix(limit)).map { row in
            try askRouteView(row,project:root).filter { ["id","project","title","state","decision","routeHash","routeHashVersion","createdAt","sourceValidation"].contains($0.key) }
        }
        let nextCursor: Any = start + items.count < routes.count && !items.isEmpty ? try AskRoute.pageCursor(project:root,anchorID:string(items.last ?? [:],"id")) : NSNull()
        return ["items":items,"nextCursor":nextCursor,"limit":limit]
    }

    /// Stored Ask previews are audit records. Once a source is private, missing,
    /// or changed, do not use that record as an API path back to its title or ID.
    private func askRouteView(_ route: JSON, project root: String) throws -> JSON {
        let permitted = askRouteCandidates(route)
        let request: JSON = ["routeId":string(route,"id"),"routeHash":string(route,"routeHash"),"scope":route["scope"] ?? [:],"candidates":permitted]
        do {
            try verifyAskRouteProposalCandidates(request,project:root)
            return route
        } catch {
            return route.filter { ["id","project","title","state","decision","routeHash","createdAt","protocol"].contains($0.key) }
                .merging(["sourceValidation":"unavailable"]) { _,new in new }
        }
    }

    private func askRouteProposalView(_ proposal: JSON, project root: String) throws -> JSON {
        guard let request = proposal["request"] as? JSON else { return proposal.filter { ["id","project","routeId","routeHash","requestHash","state","runId","approvalId","createdAt","completedAt","modelCalls","error"].contains($0.key) } }
        do {
            try verifyAskRouteProposalCandidates(request,project:root)
            return proposal
        } catch {
            return proposal.filter { ["id","project","routeId","routeHash","requestHash","state","runId","approvalId","createdAt","completedAt","modelCalls","error"].contains($0.key) }
                .merging(["sourceValidation":"unavailable"]) { _,new in new }
        }
    }

    func askRouteInboxApproval(_ approval: JSON) -> JSON {
        guard string(approval,"tool") == "ask.route.proposal.execute" else { return approval }
        let arguments = approval["arguments"] as? JSON ?? [:]
        return approval.filter { ["id","title","tool","project","runId","stepIndex","snapshotHash","state","decidedAt","completedAt"].contains($0.key) }
            .merging(["arguments":["proposalId":string(arguments,"proposalId"),"requestHash":string(arguments,"requestHash")]] as JSON) { _,new in new }
    }

    private func askRouteCandidates(_ route: JSON) -> [JSON] {
        let candidates = route["candidates"] as? [JSON] ?? [], workflows = route["workflowCandidates"] as? [JSON] ?? []
        return candidates.map { ["id":string($0,"kind") + ":" + string($0,"id"),"kind":string($0,"kind"),"title":string($0,"title"),"sourceHash":string($0,"sourceHash")] as JSON }
            + workflows.map { ["id":string($0,"id"),"kind":"workflow","title":string($0,"title"),"version":intValue($0,"version")] as JSON }
    }

    private func createAskRoute(_ params: JSON) throws -> JSON {
        let allowed: Set<String> = ["project","question","branch","worktree","task","sessionId"]
        guard Set(params.keys).isSubset(of:allowed) else { throw VelaError("Unsupported Ask route parameter") }
        let root = try project(requireString(params,"project")), question = try AskRoute.safeText(params,"question",limit:4000)
        let scope = try KnowledgeQuery.scope(params), words = AskRoute.terms(question)
        var candidates: [JSON] = []
        let memories = try boundedAskRouteScan("memory",project:root)
        for item in memories where KnowledgeQuery.visible(item,project:root,scope:scope) {
            let title = string(item,"title"), score = AskRoute.score(title + " " + string(item,"content"),words)
            if score > 0 { candidates.append(["kind":"memory","id":string(item,"id"),"title":try AskRoute.safeText(["title":title],"title",limit:240),"sourceHash":try KnowledgeQuery.sourceHash(item),"score":score]) }
        }
        let libraries = try boundedAskRouteScan("library",project:root)
        for item in libraries where KnowledgeQuery.visible(item,project:root,scope:scope) {
            let title = string(item,"title"), score = AskRoute.score(title + " " + string(item,"content"),words)
            if score > 0 { candidates.append(["kind":"library","id":string(item,"id"),"title":try AskRoute.safeText(["title":title],"title",limit:240),"sourceHash":try KnowledgeQuery.sourceHash(item),"score":score]) }
        }
        let workflows = try boundedAskRouteScan("workflow",project:root).filter { string($0,"state") != "archived" && $0["enabled"] as? Bool == true }
        let workflowMatches = workflows.map { item -> JSON in
            ["id":string(item,"id"),"title":string(item,"title"),"version":intValue(item,"version"),"score":AskRoute.score(string(item,"title") + " " + string(item,"description"),words)]
        }.filter { intValue($0,"score") > 0 }.sorted { intValue($0,"score") > intValue($1,"score") }
        candidates.sort { intValue($0,"score") > intValue($1,"score") }
        candidates = Array(candidates.prefix(12))
        let decision: JSON
        if let workflow = workflowMatches.first, !AskRoute.isPlanningQuestion(question) {
            decision = ["kind":"reviewed_execution","reason":"enabled_workflow_title_or_description_matches_question","workflowId":string(workflow,"id"),"workflowVersion":intValue(workflow,"version"),"nextMethod":"workflows.run","requiresSeparateExplicitCall":true,"neverAutoExecutes":true]
        } else if AskRoute.isPlanningQuestion(question) {
            decision = ["kind":"workflow_draft","reason":"question_requests_workflow_or_automation","nextMethod":"workflows.plan","requiresAgentSelectionAndSeparateApproval":true,"neverAutoExecutes":true]
        } else {
            decision = ["kind":"knowledge_query","reason":candidates.isEmpty ? "no_visible_source_match; ask.create will record no_sources without a model call" : "visible_public_source_candidates_found","nextMethod":"ask.create","requiresAgentSelectionAndSeparateApproval":true,"neverAutoExecutes":true]
        }
        var item: JSON = ["id":UUID().uuidString,"project":root,"title":AskRoute.displayTitle(question),"question":question,"scope":scope,"state":"decided","decision":decision,"candidates":candidates,"workflowCandidates":Array(workflowMatches.prefix(8)),"routeHashVersion":AskRoute.routeHashVersion,"createdAt":isoNow(),"protocol":AskRoute.protocolVersion]
        item["routeHash"] = try AskRoute.hash(item)
        _ = try store.put("ask_route",item)
        return item
    }

    private func createAskRouteProposal(_ params: JSON) throws -> JSON {
        let allowed: Set<String> = ["id","project","routeHash","executable","model","effort","timeoutSeconds"]
        guard Set(params.keys).isSubset(of:allowed) else { throw VelaError("Unsupported Ask route proposal parameter") }
        let root = try project(requireString(params,"project")), route = try askRoute(id:requireString(params,"id"),project:root)
        let suppliedHash = try requireString(params,"routeHash")
        guard intValue(route,"routeHashVersion") == AskRoute.routeHashVersion else { throw VelaError("Ask route uses a legacy frozen hash; create a new route before proposing") }
        guard string(route,"routeHash") == suppliedHash, try AskRoute.hash(route) == suppliedHash else { throw VelaError("Ask route changed; review current candidates") }
        let permitted = askRouteCandidates(route)
        try verifyAskRouteProposalCandidates(["routeId":string(route,"id"),"routeHash":string(route,"routeHash"),"scope":route["scope"] ?? [:],"candidates":permitted],project:root)
        var agent = try AgentEvaluation.specification(["provider":"codex","executable":try requireString(params,"executable"),"model":try requireString(params,"model"),"reasoningEffort":string(params,"effort","low")]); agent["sandbox"] = "read-only"
        let timeout = try WorkflowContext.integer(params["timeoutSeconds"],default:120,range:1...300,name:"Ask route proposal timeout")
        let request: JSON = ["protocol":AskRoute.proposalProtocol,"routeId":string(route,"id"),"routeHash":string(route,"routeHash"),"question":string(route,"question"),"scope":route["scope"] ?? [:],"candidates":permitted,"agent":agent,"timeoutSeconds":timeout,"outputSchema":AskRoute.proposalSchema]
        let requestHash = stableHash(try jsonString(request))
        let id = UUID().uuidString.lowercased(), runID = UUID().uuidString.lowercased(), approvalID = UUID().uuidString.lowercased()
        let arguments: JSON = ["proposalId":id,"requestHash":requestHash]
        var approval: JSON = ["id":approvalID,"title":"Classify Ask route","tool":"ask.route.proposal.execute","arguments":arguments,"project":root,"runId":runID,"stepIndex":0,"state":"pending"]
        approval["snapshotHash"] = stableHash(try jsonString(frozenPayload(approval)))
        let proposal: JSON = ["id":id,"project":root,"routeId":string(route,"id"),"routeHash":string(route,"routeHash"),"request":request,"requestHash":requestHash,"state":"pending_approval","runId":runID,"approvalId":approvalID,"createdAt":isoNow(),"modelCalls":0]
        let run: JSON = ["id":runID,"title":"Ask route proposal","project":root,"purpose":"ask_route_proposal","state":"pending_approval","steps":[["tool":"ask.route.proposal.execute","arguments":arguments,"state":"pending_approval","approvalId":approvalID]],"startedAt":isoNow(),"durationMs":0]
        _ = try store.putBatch([("ask_route_proposal",proposal),("run",run),("approval",approval)],createOnly:true)
        return proposal.merging(["approval":approval]) { _,new in new }
    }

    private func boundedAskRouteScan(_ kind: String, project root: String) throws -> [JSON] {
        let rows = try store.list(kind,project:root,limit:AskRoute.candidateScanLimit)
        guard rows.count < AskRoute.candidateScanLimit else { throw VelaError("Ask route \(kind) candidate scan limit reached; refine the project evidence before routing") }
        return rows
    }

    func executeAskRouteProposal(_ arguments: JSON, project root: String) throws -> JSON {
        let id = try requireString(arguments,"proposalId"); var proposal = try object("ask_route_proposal",id)
        let request = try WorkflowPlanning.requireObject(proposal,"request")
        let requestHash = stableHash(try jsonString(request)), schemaMatches = try jsonString(request["outputSchema"] ?? [:]) == jsonString(AskRoute.proposalSchema)
        let frozen = try RestrictedCodexProposal.command(agent:try WorkflowPlanning.requireObject(request,"agent"),prompt:try askRoutePrompt(request),schemaPath:RestrictedCodexProposal.schemaPlaceholder)
        let approval = try store.get("approval",string(proposal,"approvalId"))
        guard string(proposal,"project") == root, string(proposal,"state") == "pending_approval", requestHash == string(arguments,"requestHash"), string(proposal,"requestHash") == string(arguments,"requestHash"), string(request,"protocol") == AskRoute.proposalProtocol, schemaMatches, let approval, string(approval,"state") == "executing" else { throw VelaError("Ask route proposal no longer matches its executing approval") }
        proposal["state"] = "executing_or_uncertain"; _ = try store.put("ask_route_proposal",proposal)
        do {
            try verifyAskRouteProposalCandidates(request,project:root)
            let process = try RestrictedCodexProposal.run(frozenCommand:frozen,schema:AskRoute.proposalSchema,timeoutSeconds:intValue(request,"timeoutSeconds"),scratchPrefix:"vela-ask-route-")
            guard process.exitCode == 0, !process.timedOut, !process.truncated else { throw VelaError("Ask route proposal provider did not finish") }
            let (value,metrics) = try RestrictedCodexProposal.decode(output:process.output,truncated:false,maxAnswerBytes:8000); try ModelImprovement.checkKeys(value,["kind","targetId","reason"])
            let kind = try AskRoute.safeText(value,"kind",limit:40), target = try AskRoute.safeText(value,"targetId",limit:300), reason = try AskRoute.safeText(value,"reason",limit:1000)
            guard ["knowledge_query","workflow_draft","reviewed_execution","reviewed_agent_path"].contains(kind) else { throw VelaError("Ask route proposal chose an unsupported kind") }
            let candidates = request["candidates"] as? [JSON] ?? []
            let selected = candidates.first { string($0,"id") == target }
            guard (kind == "workflow_draft" && target.isEmpty) || (kind == "knowledge_query" && selected != nil && ["memory","library"].contains(string(selected ?? [:],"kind"))) || (["reviewed_execution","reviewed_agent_path"].contains(kind) && selected != nil && string(selected ?? [:],"kind") == "workflow") else { throw VelaError("Ask route proposal chose a target outside its frozen route kind") }
            if kind == "reviewed_agent_path" {
                guard let workflow = try store.get("workflow",target), ((workflow["steps"] as? [JSON]) ?? []).contains(where: { string($0,"tool") == "agent.loop" }) else { throw VelaError("Ask route proposal target does not expose a reviewed agent path") }
            }
            proposal["state"] = "proposed"; proposal["result"] = ["kind":kind,"targetId":target,"reason":reason,"neverAutoExecutes":true]; proposal["metrics"] = metrics; proposal["modelCalls"] = 1; proposal["completedAt"] = isoNow(); _ = try store.put("ask_route_proposal",proposal)
            return ["proposalId":id,"output":"Ask route proposal recorded; no workflow, query or tool was executed.","modelCalls":1]
        } catch { proposal["state"] = "failed"; proposal["error"] = "Ask route proposal failed protocol or frozen-candidate validation"; proposal["completedAt"] = isoNow(); _ = try store.put("ask_route_proposal",proposal); throw error }
    }

    func markAskRouteProposalRejected(_ arguments: JSON, project root: String) throws {
        let id = try requireString(arguments,"proposalId")
        guard var proposal = try store.get("ask_route_proposal",id), string(proposal,"project") == root, string(proposal,"state") == "pending_approval" else { throw VelaError("Ask route proposal no longer matches its rejected approval") }
        proposal["state"] = "rejected"; proposal["completedAt"] = isoNow()
        _ = try store.put("ask_route_proposal",proposal)
    }

    private func askRoutePrompt(_ request: JSON) throws -> String {
        let frozen = try jsonString(request.filter { ["question","candidates"].contains($0.key) })
        return "Select one safe next route. Return exact JSON kind,targetId,reason. kind is knowledge_query, workflow_draft, reviewed_execution, or reviewed_agent_path. targetId is exact frozen candidate ID, or empty only for workflow_draft. Do not execute, create commands, or choose tools.\nFrozen request: " + frozen
    }

    /// A preview becomes stale when any candidate changes, becomes private, leaves
    /// the project/scope, or an enabled workflow is revised. Refuse before spawning
    /// the restricted provider so a reviewed route cannot reason over new evidence.
    private func verifyAskRouteProposalCandidates(_ request: JSON, project root: String) throws {
        let route = try askRoute(id:requireString(request,"routeId"),project:root)
        guard string(route,"routeHash") == string(request,"routeHash"), try AskRoute.hash(route) == string(request,"routeHash") else { throw VelaError("Ask route changed; create a new proposal") }
        let scope = request["scope"] as? JSON ?? [:]
        guard let candidates = request["candidates"] as? [JSON], candidates.count <= 20 else { throw VelaError("Ask route proposal has invalid frozen candidates") }
        for candidate in candidates {
            let kind = try requireString(candidate,"kind"), id = try requireString(candidate,"id")
            switch kind {
            case "memory", "library":
                let prefix = kind + ":"
                guard id.hasPrefix(prefix), let item = try store.get(kind,String(id.dropFirst(prefix.count))), KnowledgeQuery.visible(item,project:root,scope:scope), try KnowledgeQuery.sourceHash(item) == string(candidate,"sourceHash") else { throw VelaError("Ask route source changed or became private; create a new proposal") }
            case "workflow":
                guard let workflow = try store.get("workflow",id), string(workflow,"project") == root, string(workflow,"state") != "archived", workflow["enabled"] as? Bool == true, string(workflow,"title") == string(candidate,"title"), intValue(workflow,"version") == intValue(candidate,"version") else { throw VelaError("Ask route workflow changed or is unavailable; create a new proposal") }
            default: throw VelaError("Ask route proposal has an unsupported candidate")
            }
        }
    }
}
