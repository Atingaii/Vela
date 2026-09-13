import Foundation
import CoreFoundation

extension MCPTools {
    func mcpProject(_ input: JSON) throws -> String {
        let raw = try requireString(input,"project")
        guard raw.hasPrefix("/"), raw.rangeOfCharacter(from:.controlCharacters) == nil else { throw VelaError("MCP requires an absolute registered project") }
        let root = canonicalProject(raw)
        guard let record = try store.get("project",stableHash(root)), string(record,"path") == root,
              FileManager.default.fileExists(atPath:root) else { throw VelaError("Register the selected project in Vela before using MCP") }
        return root
    }
    private func mcpVisible(_ row: JSON, project: String, state: String = "active", scope: JSON = [:], policy: IngestionExclusionService.MemoryRecallPolicy? = nil) throws -> Bool {
        guard string(row,"project") == project, ModelImprovement.falseOrAbsent(row["private"]), ModelImprovement.falseOrAbsent(row["sourceLabeledPrivate"]),
              ["private","global"].contains(string(row,"scope").lowercased()) == false, row["scope"] == nil || row["scope"] is String else { return false }
        for key in ["sourcePath","sourceFile","assetPath","path"] where privateLibraryPath(string(row,key)) { return false }
        if string(row,"kind") == "session", !ModelImprovement.falseOrAbsent(row["internalRun"]) { return false }
        if string(row,"kind") == "guideline", string(row,"state").lowercased() != "active" { return false }
        if string(row,"kind") == "memory" {
            let recallPolicy = try policy ?? IngestionExclusionService(store:store).memoryRecallPolicy(project:project)
            guard recallPolicy.allows(row) else { return false }
            guard string(row,"state").lowercased() == state else { return false }
            switch string(row,"scope","project") {
            case "project","repository": return true
            case "branch": return !string(scope,"branch").isEmpty && string(row,"branch") == string(scope,"branch")
            case "worktree": return !string(scope,"worktree").isEmpty && string(row,"worktree") == canonicalProject(string(scope,"worktree"))
            case "task": return !string(scope,"task").isEmpty && string(row,"task") == string(scope,"task")
            case "session": return !string(scope,"sessionId").isEmpty && string(row,"sourceSession") == string(scope,"sessionId")
            case "namespace": return !string(scope,"namespace").isEmpty && string(row,"namespace") == string(scope,"namespace")
            default: return false
            }
        }
        return !["archived","deleted","excluded"].contains(string(row,"state").lowercased())
    }
    func mcpFresh(kind: String, id: String, project: String, input: JSON, policy: IngestionExclusionService.MemoryRecallPolicy? = nil) throws -> JSON {
        guard let raw = try store.get(kind,id), try mcpVisible(raw,project:project,state:string(input,"state","active"),scope:input,policy:policy) else { throw VelaError("Source is missing, private, inactive, excluded or outside the selected project/scope") }
        var row = raw
        if ["memory","library","guideline","workflow","checkpoint"].contains(kind) {
            let relative = "assets/\(kind)/\(id).md"
            guard string(raw,"assetPath") == store.root.appendingPathComponent(relative).path,
                  let markdown = try FoundationFile.readUTF8(root:store.root,path:relative),
                  markdown.hasPrefix("<!-- Vela metadata: "), let end = markdown.range(of:" -->\n\n# "),
                  let header = try JSONSerialization.jsonObject(with:Data(markdown[markdown.index(markdown.startIndex,offsetBy:"<!-- Vela metadata: ".count)..<end.lowerBound].utf8)) as? JSON,
                  string(header,"id") == id, string(header,"kind") == kind, string(header,"project") == project,
                  try mcpVisible(header,project:project,state:string(input,"state","active"),scope:input,policy:policy),
                  ModelImprovement.falseOrAbsent(header["private"]), ModelImprovement.falseOrAbsent(header["sourceLabeledPrivate"]),
                  string(header,"scope") != "private", !["archived","deleted"].contains(string(header,"state").lowercased()),
                  markdown.hasSuffix("\n\n# " + string(row,"title") + "\n\n" + string(row,"content") + "\n") else { throw VelaError("Source managed asset is missing, linked, changed or marked private") }
            for key in ["sourcePath","sourceFile","path"] where privateLibraryPath(string(header,key)) { throw VelaError("Source asset header refers to private material") }
            if kind == "library" {
                row = try LibrarySource.fresh(store:store,id:id)
                guard LibraryIndex.isPublic(row,project:project), let flag = header["private"] as? NSNumber,
                      CFGetTypeID(flag) == CFBooleanGetTypeID(), !flag.boolValue else { throw VelaError("Library must be explicitly public") }
            }
        }
        if kind == "artifact", string(row,"origin") != "setup" { throw VelaError("Only captured setup metadata is exposed") }
        return row
    }
    private func mcpRedactedMetadata(_ value: Any) -> Any {
        if let text = value as? String { return Self.sanitizedText(text) }
        if let object = value as? JSON { return object.mapValues(mcpRedactedMetadata) }
        if let array = value as? [Any] { return array.map(mcpRedactedMetadata) }
        return value
    }
    private func mcpSummary(_ row: JSON) throws -> JSON {
        let allowed = ["id","kind","project","title","scope","state","version","updatedAt","createdAt","provider","status","evaluationKind","evaluator","decision","commit","tokensAvailable","sourceHash","folder","sourceURL","sourceCapturedAt","category","harness","format","formatSupport","redacted"]
        var value = row.filter{allowed.contains($0.key)}
        value["contentCharacters"] = Self.sanitizedText(string(row,"content")).count
        let capturedMetadata = ["artifact","eval","session"].contains(string(row,"kind"))
        if !capturedMetadata { value["sourceHash"] = stableHash(string(row,"content")) }
        value["sourceState"] = capturedMetadata ? "captured_metadata" : "fresh_managed_asset"
        // Summaries never carry captured tasks, raw model transcripts or argv.
        if let title = value["title"] as? String { value["title"] = String(Self.sanitizedText(title).prefix(300)) }
        if let url = value["sourceURL"] as? String, Self.sanitizedText(url) != url || URL(string:url)?.user != nil || URL(string:url)?.password != nil { value.removeValue(forKey:"sourceURL"); value["sourceURLRedacted"] = true }
        return value
    }
    private func mcpList(kind: String, input: JSON, legacy: Bool, query: String? = nil) throws -> MCPToolOutput {
        let root = try mcpProject(input), limit = (input["limit"] as? Int ?? 20), after = string(input,"after")
        let policy = try IngestionExclusionService(store:store).memoryRecallPolicy(project:root)
        let rows = try store.mcpSourceIDs(kind:kind,project:root,after:after,limit:limit+1)
        var items: [JSON] = [], cursor = after, omitted = 0
        for identity in rows.prefix(limit) {
            let id = string(identity,"id"), actualKind = string(identity,"kind")
            cursor = kind == "search" ? actualKind + ":" + id : id
            guard let row = try? mcpFresh(kind:actualKind,id:id,project:root,input:input,policy:policy) else { omitted += 1; continue }
            if let query, string(row,"title").range(of:query,options:.caseInsensitive) == nil && string(row,"content").range(of:query,options:.caseInsensitive) == nil { continue }
            var summary = try mcpSummary(row)
            if query != nil, ["memory","library","guideline","workflow","checkpoint"].contains(actualKind) {
                summary["content"] = String(Self.sanitizedText(string(row,"content")).prefix(240))
                summary["excerptTruncated"] = string(row,"content").count > 240
            }
            items.append(summary)
        }
        let page: JSON = ["nextCursor":rows.count > limit ? cursor as Any : NSNull(),"scanned":min(limit,rows.count),"omitted":omitted,"pageLimit":limit,"complete":rows.count <= limit]
        if legacy { return MCPToolOutput(value:items,metadata:page) }
        var result = page; result["items"] = items
        return MCPToolOutput(value:result)
    }
    private func mcpRead(kind: String, input: JSON) throws -> MCPToolOutput {
        let root = try mcpProject(input), row = try mcpFresh(kind:kind,id:requireString(input,"id"),project:root,input:input)
        let original = string(row,"content"), text = Self.sanitizedText(original)
        let hash = stableHash(original), offset = intValue(input,"offset"), maximum = (input["maxCharacters"] as? Int ?? 4000)
        guard offset <= text.count, offset == 0 || string(input,"sourceHash") == hash,
              input["sourceHash"] == nil || string(input,"sourceHash") == hash else { throw VelaError("Source changed or continuation hash is missing; restart from offset 0") }
        let start = text.index(text.startIndex,offsetBy:offset), end = text.index(start,offsetBy:min(maximum,text.count-offset))
        var result = try mcpSummary(row)
        let excerpt = String(text[start..<end])
        result["content"] = excerpt; result["contentRedacted"] = text != original; result["offset"] = offset; result["offsetUnit"] = "extended_grapheme_clusters"
        result["nextOffset"] = offset+maximum < text.count ? offset+maximum as Any : NSNull()
        result["sourceHash"] = hash; result["candidateReviewOnly"] = string(row,"state") == "candidate"
        return MCPToolOutput(value:result)
    }
    private func mcpRecall(_ input: JSON) throws -> MCPToolOutput {
        var params = input; let root = try mcpProject(input); params["project"] = root
        guard var result = try coreCall("recall",params) as? JSON, let recalled = result["items"] as? [JSON] else { throw VelaError("Core recall returned an invalid response") }
        let budget = (input["budget"] as? Int ?? 2000), limit = (input["limit"] as? Int ?? 100)
        let policy = try IngestionExclusionService(store:store).memoryRecallPolicy(project:root)
        var items: [JSON] = [], used = 0, omitted = 0
        for old in recalled {
            guard let fresh = try? mcpFresh(kind:"memory",id:string(old,"id"),project:root,input:input,policy:policy), string(old,"content") == string(fresh,"content") else { omitted += 1; continue }
            let cost = tokenEstimate(string(fresh,"title") + "\n" + string(fresh,"content")) + 32
            guard used+cost <= budget, items.count < limit else { omitted += 1; continue }
            var row = try mcpSummary(fresh)
            row["content"] = Self.sanitizedText(string(fresh,"content")); row["contentRedacted"] = string(row,"content") != string(fresh,"content")
            row["recallTokens"] = cost
            for key in ["relevance","score","similarity","scoring"] where old[key] != nil { row[key] = old[key] }
            items.append(row); used += cost
        }
        result["items"] = items; result["usedTokens"] = used; result["budget"] = budget; result["omittedAfterFreshScopeCheck"] = omitted
        result["truncated"] = omitted > 0 || result["truncated"] as? Bool == true
        return MCPToolOutput(value:result)
    }
    private func mcpSourceSession(_ input: JSON, project: String) throws {
        guard let id = input["sourceSession"] as? String else {
            guard input["sourceMessage"] == nil else { throw VelaError("Source message requires a verified source session") }; return
        }
        let row = try mcpFresh(kind:"session",id:id,project:project,input:input)
        if let messageID = input["sourceMessage"] as? String {
            guard (row["messages"] as? [JSON] ?? []).contains(where:{string($0,"id") == messageID}) else { throw VelaError("Source message is not present in the selected session's observed window") }
        }
    }
    private func mcpCandidate(_ input: JSON, project: String) throws -> JSON {
        try mcpSourceSession(input,project:project)
        let scope = string(input,"scope","project").lowercased()
        for (value,field) in [("branch","branch"),("worktree","worktree"),("task","task"),("session","sourceSession"),("namespace","namespace")] where scope == value { _ = try requireString(input,field) }
        if let worktree = input["worktree"] as? String, !worktree.hasPrefix("/") { throw VelaError("Memory worktree must be absolute") }
        guard Self.sanitizedText(try jsonString(input)) == (try jsonString(input)) else { throw VelaError("MCP contribution contains credential-like text; it was not stored") }
        var row = input; row["id"] = UUID().uuidString.lowercased(); row["project"] = project; row["state"] = "candidate"; row["scope"] = scope; row["type"] = string(input,"type","fact").lowercased()
        if let path = input["worktree"] as? String { row["worktree"] = canonicalProject(path) }
        row["private"] = false; row["tokens"] = tokenEstimate(string(input,"content")); row["lastConfirmed"] = NSNull()
        row["provenance"] = ["origin":"mcp_contribution","authenticated":false,"sourceSession":input["sourceSession"] ?? NSNull(),"sourceMessage":input["sourceMessage"] ?? NSNull()]
        return row
    }
    func dispatchMCPTool(_ name: String, arguments input: JSON) throws -> MCPToolOutput {
        let root = try mcpProject(input)
        switch name {
        case "vela_search": return try mcpList(kind:"search",input:input,legacy:true,query:requireString(input,"query"))
        case "vela_recall": return try mcpRecall(input)
        case "vela_memory_list": return try mcpList(kind:"memory",input:input,legacy:true)
        case "vela_setup_list": return try mcpList(kind:"artifact",input:input,legacy:true)
        case "vela_workflows_list": return try mcpList(kind:"workflow",input:input,legacy:true)
        case "vela_evals_list": return try mcpList(kind:"eval",input:input,legacy:true)
        case "vela_checkpoints_list": return try mcpList(kind:"checkpoint",input:input,legacy:true)
        case "vela_library_list": return try mcpList(kind:"library",input:input,legacy:false)
        case "vela_guidelines_list": return try mcpList(kind:"guideline",input:input,legacy:false)
        case "vela_memory_get": return try mcpRead(kind:"memory",input:input)
        case "vela_library_get": return try mcpRead(kind:"library",input:input)
        case "vela_guidelines_read": return try mcpRead(kind:"guideline",input:input)
        case "vela_workflows_read": return try mcpRead(kind:"workflow",input:input)
        case "vela_library_search":
            var params = input; params["project"] = root
            guard var found = try coreCall("library.search",params) as? JSON, let candidates = found["items"] as? [JSON] else { throw VelaError("Core Library search returned an invalid response") }
            var items: [JSON] = []
            for candidate in candidates {
                guard let source = try? mcpFresh(kind:"library",id:string(candidate,"id"),project:root,input:input), stableHash(string(source,"content")) == string(candidate,"sourceHash"),
                      string(source,"content").contains(string(candidate,"content")) else { continue }
                var item = mcpRedactedMetadata(candidate) as! JSON
                let originalExcerpt = string(candidate,"content")
                let fullSource = string(source,"content"), redactedSource = Self.sanitizedText(fullSource)
                // A paragraph can bisect a credential pattern. If the source
                // required redaction, return no raw paragraph unless it survives
                // in the fully sanitized source unchanged.
                guard redactedSource == fullSource || redactedSource.contains(originalExcerpt) else { continue }
                item["content"] = Self.sanitizedText(originalExcerpt); item["contentRedacted"] = string(item,"content") != originalExcerpt; items.append(item)
            }
            found["items"] = items; found["omittedAfterFreshScopeCheck"] = candidates.count-items.count
            return MCPToolOutput(value:found)
        case "vela_health": return MCPToolOutput(value:["server":"Vela","serverVersion":serverVersion,"transport":"stdio","project":root,"storageRead":"succeeded","permissionMode":contribute ? "contribute" : "read","toolCount":catalog().count,"modelExecution":false,"remoteAccountStatus":"not_queried","requestBudgetPerConnection":Self.maximumRequests])
        case "vela_memory_contribute","vela_remember":
            let row = try mcpCandidate(input,project:root)
            let saved = try store.put("memory",row,createOnly:true)
            return MCPToolOutput(value:try mcpSummary(saved))
        case "vela_remember_bulk":
            let items = try (input["items"] as? [JSON] ?? []).map { try mcpCandidate($0,project:root) }
            let saved = try store.putBatch(items.map{("memory",$0)},createOnly:true)
            return MCPToolOutput(value:["items":try saved.map(mcpSummary),"created":saved.count,"state":"candidate","atomic":true])
        case "vela_checkpoint_save":
            var params = input; params["project"] = root
            guard let value = try coreCall("checkpoint.save",params) as? JSON else { throw VelaError("Core checkpoint response was invalid") }
            return MCPToolOutput(value:try mcpSummary(value))
        case "vela_signal_record","vela_suggestion_draft":
            try mcpSourceSession(input,project:root)
            var params = input; params["project"] = root
            let method = name == "vela_signal_record" ? "signals.record" : "suggestions.draft"
            guard let value = try coreCall(method,params) as? JSON else { throw VelaError("Core contribution response was invalid") }
            return MCPToolOutput(value:value.filter{["id","kind","project","title","state","origin","carrier","createdAt","sourceSession","sourceMessage"].contains($0.key)})
        case "vela_local_archive_restore":
            var params = input; params["project"] = root
            let value = try coreCall("memory.archive.import",params)
            return MCPToolOutput(value:value)
        default: throw VelaError("Unsupported MCP tool dispatch")
        }
    }
}
