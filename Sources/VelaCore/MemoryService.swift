import Foundation

final class MemoryService {
    let store: VelaStore
    init(store: VelaStore) { self.store = store }
    private let scopes: Set<String> = ["global","project","repository","branch","worktree","task","session","namespace"]
    private let types: Set<String> = ["decision","constraint","preference","failure","fact","workflow knowledge","observation","hypothesis","checkpoint"]
    private let states: Set<String> = ["candidate","active","superseded","archived"]

    func handle(_ method: String, _ params: JSON) throws -> Any? {
        switch method {
        case "memory.integration.capture", "memory.integration.recall", "memory.integration.stats":
            return try MemoryIntegrationService(store:store).handle(method,params)
        case "memory.archive.export", "memory.archive.validate", "memory.archive.import", "memory.archive.fromWalrusRecords":
            return try MemoryArchiveService(store:store).handle(method,params)
        case "memory.semantic.index", "memory.semantic.status", "memory.semantic.embed", "memory.semantic.query", "memory.semantic.recent":
            return try SemanticMemory(store:store).handle(method,params)
        case "memory.list": return try store.list("memory",project: checkedProject(params))
        case "memory.capture.prepare": return try prepareSessionCapture(params)
        case "memory.capture": return try captureSessionMessage(params)
        case "memory.save":
            let existing = try (params["id"] as? String).flatMap { try store.get("memory",$0) }
            let existingProvenance = existing?["provenance"] as? JSON ?? [:]
            let isObservedCapture = string(existingProvenance,"origin") == "observed_session_capture"
            let reservedCaptureKeys: Set<String> = ["provenance","captureProtocol","captureIdentity","sourceHash","sourceIdentity","sourceObservation","requiresReview","modelCalls","capturedAt","originalContentHash"]
            guard Set(params.keys).intersection(reservedCaptureKeys).isEmpty else { throw VelaError("Session capture provenance is managed by Core") }
            if let existing, isObservedCapture {
                for key in ["sourceSession","sourceMessage","sourceFile","sourceCommit"] where params[key] != nil {
                    guard captureFieldEqual(params[key], existing[key]) else {
                        throw VelaError("Observed capture source fields are immutable")
                    }
                }
            }
            var object = existing ?? [:]; object.merge(params) { _,new in new }
            let title = try requireString(params,"title"); let content = try requireString(params,"content")
            guard title.count <= 300, content.utf8.count <= 512 * 1024 else { throw VelaError("Memory is too large") }
            let scope = string(object,"scope","project").lowercased(); let type = string(object,"type","fact").lowercased()
            let state = string(params,"state",existing.map { string($0,"state","candidate") } ?? "candidate").lowercased()
            guard scopes.contains(scope), types.contains(type), states.contains(state) else { throw VelaError("Invalid memory scope, type or state") }
            if let existing, string(existing,"state").lowercased() != state { throw VelaError("Use memory.transition to change memory lifecycle state") }
            object["scope"] = scope; object["type"] = type; object["state"] = state
            if scope == "global" { object.removeValue(forKey:"project") }
            else { object["project"] = try checkedProject(object,required:true) }
            switch scope {
            case "branch": _ = try requireString(object,"branch")
            case "worktree": object["worktree"] = canonicalProject(try requireString(object,"worktree"))
            case "task": _ = try requireString(object,"task")
            case "session": _ = try requireString(object,"sourceSession")
            case "namespace":
                let namespace = try requireString(object,"namespace")
                guard namespace.utf8.count <= 256, namespace.rangeOfCharacter(from:.controlCharacters) == nil else { throw VelaError("Invalid memory namespace") }
            default: break
            }
            if let id = params["id"] as? String, let existing = try store.get("memory",id), string(existing,"project") != string(object,"project") { throw VelaError("Memory cannot be moved between project scopes") }
            object["tokens"] = tokenEstimate(content)
            object["lastConfirmed"] = state == "active" ? isoNow() : NSNull()
            if isObservedCapture {
                var provenance = existingProvenance
                let originalHash = string(provenance,"originalContentHash")
                guard !originalHash.isEmpty else { throw VelaError("Observed capture provenance is incomplete") }
                if stableHash(content) == originalHash {
                    provenance["contentEqualsObservedSource"] = true
                } else {
                    provenance["contentEqualsObservedSource"] = false
                    provenance["derivedBy"] = "user_edit"
                    provenance["userEditedAt"] = isoNow()
                    object["derivedFromCapture"] = true
                }
                object["provenance"] = provenance
            } else {
                object["provenance"] = ["sourceSession": object["sourceSession"] ?? NSNull(),"sourceMessage": object["sourceMessage"] ?? NSNull(),"sourceFile": object["sourceFile"] ?? NSNull(),"sourceCommit": object["sourceCommit"] ?? NSNull(),"origin": "user"] as JSON
            }
            return try store.put("memory",object)
        case "memory.transition":
            let id = try requireString(params,"id"); let newState = try requireString(params,"state").lowercased()
            guard var memory = try store.get("memory",id) else { throw VelaError("Memory not found") }
            let oldState = string(memory,"state","candidate").lowercased()
            let transitions: [String:Set<String>] = ["candidate":["active","archived"],"active":["superseded","archived"],"superseded":["archived"],"archived":[]]
            guard oldState == newState || transitions[oldState,default:[]].contains(newState) else { throw VelaError("Invalid transition from \(oldState) to \(newState)") }
            var supersededMemory: JSON?
            if let previousId = params["supersedes"] as? String {
                guard previousId != id, newState == "active", var previous = try store.get("memory",previousId), string(previous,"project") == string(memory,"project"), string(previous,"state").lowercased() == "active" else { throw VelaError("Superseded memory must be active and in the same project") }
                previous["state"] = "superseded"; previous["supersededBy"] = id
                supersededMemory = previous; memory["supersedes"] = previousId
            }
            memory["state"] = newState
            if newState == "active" { memory["lastConfirmed"] = isoNow() }
            if let supersededMemory { return try store.putBatch([("memory",supersededMemory),("memory",memory)]).last! }
            return try store.put("memory",memory)
        case "recall": return try recall(params)
        case "search": return try store.search(try requireString(params,"query"),project:checkedProject(params),includePrivate:params["includePrivate"] as? Bool ?? false)
        case let name where name.hasPrefix("library."):
            return try LibraryService(store:store).handle(name,params)
        case "checkpoint.list": return try store.list("checkpoint",project:checkedProject(params))
        case "checkpoint.save":
            var item = params; item["project"] = try checkedProject(params,required:true)
            let goal = try requireString(params,"goal"); item["title"] = string(params,"title","Checkpoint — " + String(goal.prefix(70)))
            var content = "## Goal\n\n" + goal
            for (key,label) in [("completed","Completed"),("pending","Pending"),("tests","Tests"),("nextActions","Next actions")] {
                if let entries = params[key] as? [String], !entries.isEmpty { content += "\n\n## \(label)\n\n" + entries.map { "- " + $0 }.joined(separator:"\n") }
                else if let entry = params[key] as? String, !entry.isEmpty { content += "\n\n## \(label)\n\n" + entry }
            }
            let project = string(item,"project")
            let git = try? FoundationCommand.run("/usr/bin/git",["-C",project,"status","--porcelain=v1"],timeout:5)
            if let git, git.code == 0 {
                let branch = try? FoundationCommand.run("/usr/bin/git",["-C",project,"branch","--show-current"],timeout:5)
                let commit = try? FoundationCommand.run("/usr/bin/git",["-C",project,"rev-parse","HEAD"],timeout:5)
                item["gitState"] = ["branch":branch?.output.trimmingCharacters(in:.whitespacesAndNewlines) ?? "","commit":commit?.output.trimmingCharacters(in:.whitespacesAndNewlines) ?? "","status":git.output,"capturedAt":isoNow()] as JSON
                content += "\n\n## Git state\n\nBranch: \(branch?.output.trimmingCharacters(in:.whitespacesAndNewlines) ?? "unknown")\nCommit: \(commit?.output.trimmingCharacters(in:.whitespacesAndNewlines) ?? "unknown")\n\n```text\n\(git.output)```"
            }
            for (key,label) in [("decisions","Decisions"),("failures","Failures"),("changedFiles","Changed files")] {
                if let entries = params[key] as? [String], !entries.isEmpty { content += "\n\n## \(label)\n\n" + entries.map { "- " + $0 }.joined(separator:"\n") }
            }
            item["content"] = content; item["state"] = "active"
            return try store.put("checkpoint",item)
        case "checkpoint.export":
            guard let item = try store.get("checkpoint",try requireString(params,"id")) else { throw VelaError("Checkpoint not found") }
            let provider = string(params,"provider","codex").lowercased()
            guard ["codex","claude","cursor"].contains(provider) else { throw VelaError("Unsupported handoff provider") }
            let path = try store.assetURL(kind:"checkpoint",id:string(item,"id")).path
            let quoted = "'" + path.replacingOccurrences(of:"'",with:"'\\''") + "'"
            return ["path":path,"content":string(item,"content"),"command":"Read the Vela handoff file at \(quoted) and continue the pending work.","provider":provider,"executed":false] as JSON
        default: return nil
        }
    }

    private static let sessionCaptureProtocol = "vela-session-memory-capture-v1"
    private static let sessionCaptureMaximumBytes = 32 * 1024

    private func captureFieldEqual(_ supplied: Any?, _ existing: Any?) -> Bool {
        guard let supplied, let existing else { return supplied == nil && existing == nil }
        return (try? jsonString(["value": supplied])) == (try? jsonString(["value": existing]))
    }

    /// Resolves one already-indexed message. This never reads provider files or
    /// follows caller paths; the later capture call re-resolves the same record.
    private func resolvedSessionCapture(_ params: JSON, capture: Bool) throws -> (project: String, session: JSON, message: JSON, identity: String, sourceHash: String) {
        let expectedKeys: Set<String> = capture ? ["project","sessionId","messageId","expectedSourceHash","sourceIdentity"] : ["project","sessionId","messageId"]
        guard Set(params.keys) == expectedKeys else { throw VelaError("Unsupported session memory capture parameter") }
        let project = try checkedProject(params,required:true)!
        guard let registration = try store.get("project",stableHash(project)), string(registration,"path") == project else {
            throw VelaError("Session memory capture requires a registered project")
        }
        let sessionID = try captureIdentifier(params,"sessionId"), messageID = try captureIdentifier(params,"messageId")
        guard let session = try store.get("session",sessionID), capturableSession(session,project:project) else {
            throw VelaError("Session source is unavailable, private, internal or outside the selected project")
        }
        let matching = (session["messages"] as? [JSON] ?? []).filter { string($0,"id") == messageID }
        guard matching.count == 1, let message = matching.first, ModelImprovement.falseOrAbsent(message["private"]) else {
            throw VelaError("Session message is unavailable, private or ambiguous")
        }
        let role = string(message,"role")
        guard ["user","assistant"].contains(role) else { throw VelaError("Only observed user or assistant messages can be captured") }
        let content = string(message,"content")
        guard !content.isEmpty, !content.contains("\0"), content.utf8.count <= Self.sessionCaptureMaximumBytes,
              ModelImprovement.redact(content) == content else { throw VelaError("Session message is oversized or contains a credential pattern") }
        let identity = ModelImprovement.identity(session)
        guard !identity.isEmpty, identity.utf8.count <= 1024,
              identity.rangeOfCharacter(from:.controlCharacters) == nil else { throw VelaError("Session source identity is unavailable") }
        // A later unrelated message must not invalidate this observed message. Current
        // session visibility is rechecked above and the final create uses a whole-record CAS.
        let snapshot: JSON = ["protocol":Self.sessionCaptureProtocol,"project":project,"sessionId":sessionID,
                              "provider":string(session,"provider"),"sourceIdentity":identity,
                              "messageId":messageID,"role":role,"contentHash":stableHash(content)]
        let sourceHash = stableHash(try jsonString(snapshot))
        if params["expectedSourceHash"] != nil || params["sourceIdentity"] != nil {
            guard string(params,"expectedSourceHash") == sourceHash, string(params,"sourceIdentity") == identity else {
                throw VelaError("Session source changed; prepare a new capture")
            }
        }
        return (project,session,message,identity,sourceHash)
    }

    private func captureIdentifier(_ params: JSON, _ key: String) throws -> String {
        let value = try requireString(params,key)
        guard value.utf8.count <= 512, value.rangeOfCharacter(from:.controlCharacters) == nil else { throw VelaError("Invalid session memory capture \(key)") }
        return value
    }

    private func capturableSession(_ session: JSON, project: String) -> Bool {
        guard string(session,"project") == project,
              ["claude","codex","cursor","pi","omp"].contains(string(session,"provider")),
              ModelImprovement.falseOrAbsent(session["private"]),
              ModelImprovement.falseOrAbsent(session["sourceLabeledPrivate"]),
              ModelImprovement.falseOrAbsent(session["internalRun"]),
              (session["scope"] == nil || session["scope"] is String),
              ["","project"].contains(string(session,"scope").lowercased()),
              !privateLibraryPath(string(session,"sourcePath")) else { return false }
        return true
    }

    private func prepareSessionCapture(_ params: JSON) throws -> JSON {
        let source = try resolvedSessionCapture(params,capture:false)
        return ["protocol":Self.sessionCaptureProtocol,"project":source.project,"sessionId":string(source.session,"id"),
                "messageId":string(source.message,"id"),"sourceIdentity":source.identity,"expectedSourceHash":source.sourceHash,
                "role":string(source.message,"role"),"content":string(source.message,"content"),"contentBytes":string(source.message,"content").utf8.count,
                "sourceCoverage":"currently indexed session message; not a complete provider-history assertion",
                "state":"candidate","sourceObservation":"observed","modelCalls":0] as JSON
    }

    private func captureSessionMessage(_ params: JSON) throws -> JSON {
        guard Set(params.keys) == Set(["project","sessionId","messageId","expectedSourceHash","sourceIdentity"]) else {
            throw VelaError("Unsupported session memory capture parameter")
        }
        let source = try resolvedSessionCapture(params,capture:true)
        let sessionID = string(source.session,"id"), messageID = string(source.message,"id"), provider = string(source.session,"provider")
        // The durable identity intentionally excludes caller presentation fields and
        // source bytes. A replay of the same observed snapshot returns this object;
        // a changed source with the same provider/session/message identity is refused.
        let identityKey = provider + "\0" + source.identity + "\0" + sessionID + "\0" + messageID
        let id = "capture-" + String(stableHash(Self.sessionCaptureProtocol + "\0" + source.project + "\0" + identityKey).prefix(32))
        if let existing = try store.get("memory",id) {
            let provenance = existing["provenance"] as? JSON ?? [:]
            guard string(provenance,"captureIdentity") == identityKey,
                  string(provenance,"sourceHash") == source.sourceHash,
                  string(existing,"project") == source.project else {
                throw VelaError("Captured session identity changed; do not overwrite the existing candidate")
            }
            var result = existing; result["created"] = false; result["idempotent"] = true
            return result
        }
        let content = string(source.message,"content"), role = string(source.message,"role")
        let title = "Observed \(role) message"
        let memory: JSON = ["id":id,"title":title,"content":content,"type":"observation","scope":"project","project":source.project,
                            "state":"candidate","tokens":tokenEstimate(content),"provenance":["origin":"observed_session_capture","sourceObservation":"observed",
                            "captureProtocol":Self.sessionCaptureProtocol,"captureIdentity":identityKey,"sourceHash":source.sourceHash,
                            "originalContentHash":stableHash(content),"contentEqualsObservedSource":true,"sourceIdentity":source.identity,"sessionId":sessionID,"messageId":messageID,"provider":provider,
                            "sourceSession":source.session["sourceSessionId"] ?? NSNull(),"sourcePath":source.session["sourcePath"] ?? NSNull(),
                            "sourceCoverage":"currently indexed session message; not a complete provider-history assertion"] as JSON,
                            "sourceSession":sessionID,"sourceMessage":messageID,"capturedAt":isoNow(),"requiresReview":true,"modelCalls":0]
        let saved = try store.putBatch([("memory",memory)],expecting:[("session",sessionID,stableHash(try jsonString(source.session)))],expectingAbsent:[("memory",id)],createOnly:true).last!
        var result = saved; result["created"] = true; result["idempotent"] = false; result["requiresReview"] = true
        return result
    }

    func recall(_ params: JSON) throws -> JSON {
        guard params["retrievalMode"] == nil || params["retrievalMode"] is String else { throw VelaError("Invalid retrieval mode") }
        let mode = string(params,"retrievalMode","lexical")
        guard ["lexical","semantic","hybrid"].contains(mode) else { throw VelaError("Invalid retrieval mode") }
        if mode != "lexical" { return try SemanticMemory(store:store).recall(params) { try self.lexicalRecall(params) } }
        return try lexicalRecall(params)
    }
    private func lexicalRecall(_ params: JSON) throws -> JSON {
        let project = try checkedProject(params,required:true)!
        let budget = max(0,min(params["budget"] == nil ? 2000 : intValue(params,"budget"),4000))
        let query = string(params,"query").lowercased()
        let terms = query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        var candidates = try store.list("memory",limit:10000).filter { item in
            guard string(item,"state").lowercased() == "active", ModelImprovement.falseOrAbsent(item["private"]), !privateLibraryPath(string(item,"sourceFile")) else { return false }
            let scope = string(item,"scope","project").lowercased()
            guard scope == "global" || string(item,"project") == project else { return false }
            let namespace = string(params,"namespace")
            if !namespace.isEmpty { return scope == "namespace" && string(item,"namespace") == namespace }
            switch scope {
            case "global","project","repository": return true
            case "branch": return !string(params,"branch").isEmpty && string(item,"branch") == string(params,"branch")
            case "worktree": return !string(params,"worktree").isEmpty && canonicalProject(string(params,"worktree")) == string(item,"worktree")
            case "task": return !string(params,"task").isEmpty && string(item,"task") == string(params,"task")
            case "session": return !string(params,"sessionId").isEmpty && string(item,"sourceSession") == string(params,"sessionId")
            default: return false
            }
        }
        func score(_ item: JSON) -> Int {
            let title = string(item,"title").lowercased(); let body = string(item,"content").lowercased()
            var score = terms.reduce(0) { $0 + (title.contains($1) ? 6 : 0) + (body.contains($1) ? 2 : 0) }
            for file in params["files"] as? [String] ?? [] { if body.contains(file.lowercased()) || string(item,"sourceFile").contains(file) { score += 5 } }
            for symbol in params["symbols"] as? [String] ?? [] { if body.contains(symbol.lowercased()) { score += 4 } }
            return score
        }
        if !terms.isEmpty { candidates = candidates.filter { score($0) > 0 } }
        candidates.sort { let a = score($0), b = score($1); return a == b ? string($0,"id") < string($1,"id") : a > b }
        var used = 0; var items: [JSON] = []
        for var candidate in candidates {
            let cost = tokenEstimate(string(candidate,"title") + "\n" + string(candidate,"content")) + 32
            if used + cost > budget { continue }
            candidate["recallTokens"] = cost; candidate["relevance"] = score(candidate); items.append(candidate); used += cost
        }
        return ["items":items,"usedTokens":used,"budget":budget,"tokenAccounting":"conservative character upper bound; CJK counts as 2 tokens","truncated":items.count < candidates.count]
    }
}
