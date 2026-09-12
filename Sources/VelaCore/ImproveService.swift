import Foundation

extension AutomationService {
    func analyze(_ params: JSON) throws -> JSON {
        let selectedProject = try checkedProject(params)
        let sessions = try store.list("session",project:selectedProject,limit:500)
        var emitted: [JSON] = []
        // Deliberately deterministic. These detectors record explicit user language; they do not
        // pretend to infer intent, pain scores, or confidence through a model that was never run.
        for session in sessions where session["internalRun"] as? Bool != true {
            let root = string(session,"project")
            guard !root.isEmpty else { continue }
            let messages = session["messages"] as? [JSON] ?? []
            for message in messages where string(message,"role") == "user" {
                let text = string(message,"content")
                let lower = text.lowercased()
                let correctionMarkers = ["not correct","that's wrong","this is wrong","you forgot","again","still failing","don't forget","do not forget","不对","又忘","还是错","重复","忘记","没跑测试","没有测试","先测试","不要再","再次","必须测试","每次"]
                guard correctionMarkers.contains(where:lower.contains), text.utf8.count <= 32_000 else { continue }
                let category: String
                if ["test","typecheck","测试","验证","检查"].contains(where:lower.contains) { category = "verification" }
                else if ["commit","diff","git ","提交"].contains(where:lower.contains) { category = "change-review" }
                else if ["npm","pnpm","yarn","bun","包管理"].contains(where:lower.contains) { category = "package-manager" }
                else { category = "correction-" + String(stableHash(lower.trimmingCharacters(in:.whitespacesAndNewlines)).prefix(12)) }
                let messageID = string(message,"id",stableHash(text))
                let id = String(stableHash("\(string(session,"id")):\(messageID):detector-v1").prefix(32))
                let evidence: JSON = ["sessionId":string(session,"id"),"messageId":messageID,"quote":text,"timestamp":message["timestamp"] ?? NSNull()]
                let signal = try store.put("signal",["id":id,"title":String(text.prefix(120)),"content":text,"project":root,"state":"observed","type":"Correction","detector":"explicit-language-v1","detectorLimit":"Heuristic language match; review the original message.","clusterKey":category,"sourceSession":string(session,"id"),"sourceMessage":messageID,"evidence":[evidence]])
                emitted.append(signal)
            }
        }
        let signals = try store.list("signal",project:selectedProject,limit:10000)
        let groups = Dictionary(grouping:signals) { string($0,"project") + "\n" + string($0,"clusterKey") }
        var clusters: [JSON] = []; var suggestions: [JSON] = []
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let sessions = Set(group.map {string($0,"sourceSession")})
            let days = Set(group.flatMap { $0["evidence"] as? [JSON] ?? [] }.compactMap { ($0["timestamp"] as? String).map {String($0.prefix(10))} })
            let promoted = group.count >= 3 && sessions.count >= 2
            let first = group[0]
            let clusterID = String(stableHash(key).prefix(32))
            let evidence = group.flatMap { $0["evidence"] as? [JSON] ?? [] }
            let cluster = try store.put("cluster",["id":clusterID,"title":string(first,"clusterKey"),"project":string(first,"project"),"state":promoted ? "promoted" : "observing","signalCount":group.count,"distinctSessions":sessions.count,"distinctDays":days.count,"promotionRule":"at least 3 distinct signals in at least 2 sessions","ruleVersion":1,"evidence":evidence,"signalIds":group.map {string($0,"id")}])
            clusters.append(cluster)
            guard promoted else { continue }
            let suggestionID = "suggestion-" + clusterID
            if let existing = try store.get("suggestion",suggestionID) { suggestions.append(existing); continue }
            let root = string(first,"project")
            let category = string(first,"clusterKey")
            let procedure = ["verification","change-review"].contains(category)
            let filename = procedure ? ".vela/workflows/review-before-handoff.md" : ".vela/guidelines/observed-constraint-\(clusterID.prefix(8)).md"
            let path = URL(fileURLWithPath:root).appendingPathComponent(filename).path
            let title = procedure ? "Review and verify before handoff" : "Review repeated project constraint"
            let quotes = evidence.prefix(6).map { "> " + string($0,"quote").replacingOccurrences(of:"\n",with:"\n> ") }.joined(separator:"\n\n")
            let content = "# \(title)\n\nThis draft is based on \(group.count) explicit corrections across \(sessions.count) sessions. Review the quoted evidence before adopting it.\n\n" + (procedure ? "1. Inspect the current Git diff.\n2. Choose and run the relevant project tests.\n3. Run the project's type check when available.\n4. Report test failures, unresolved issues, and the verified result.\n\n" : "Record the narrow project constraint supported by the evidence below. Do not generalize it to unrelated projects.\n\n") + "## Evidence\n\n" + quotes + "\n"
            let before = try? String(contentsOfFile:path,encoding:.utf8)
            let suggestion = try store.put("suggestion",["id":suggestionID,"title":title,"project":root,"state":"draft","carrier":procedure ? "Workflow" : "Guideline","contextTokens":0,"contextCostKind":"on_demand","evidence":evidence,"clusterId":clusterID,"signalCount":group.count,"distinctSessions":sessions.count,"generator":"deterministic-evidence-draft-v1","limitations":"This is a reviewable Markdown draft. Workflow execution requires saving explicit tools in the workflow builder.","operations":[["path":path,"baseHash":before.map(stableHash) ?? "absent","content":content]]])
            suggestions.append(suggestion)
        }
        return ["signals":emitted,"clusters":clusters,"suggestions":suggestions,"method":"deterministic explicit-language detection","modelCalled":false]
    }

    func previewSuggestion(_ params: JSON) throws -> JSON {
        var suggestion = try object("suggestion",requireString(params,"id"))
        let root = try project(requireString(suggestion,"project"))
        let operations = suggestion["operations"] as? [JSON] ?? []
        suggestion["preview"] = try files.preview(project:root,operations:operations)
        return suggestion
    }

    func validateSuggestionTargets(_ operations: [JSON], project: String) throws {
        for operation in operations {
            let path = try safeWorkflowPath(requireString(operation,"path"),project:project)
            let relative = String(path.dropFirst(project.count+1))
            let exact: Set<String> = ["AGENTS.md","CLAUDE.md",".cursorrules"]
            let prefixes = [".vela/", ".cursor/rules/", ".claude/skills/", ".agents/skills/", ".codex/skills/"]
            guard exact.contains(relative) || prefixes.contains(where:relative.hasPrefix) else { throw VelaError("Suggestions may only change approved context artifact locations") }
        }
    }

    func applySuggestion(_ params: JSON) throws -> JSON {
        var suggestion = try object("suggestion",requireString(params,"id"))
        guard ["draft","needs_review","undone"].contains(string(suggestion,"state")) else { throw VelaError("Suggestion is not available to apply") }
        let root = try project(requireString(suggestion,"project"))
        let operations = suggestion["operations"] as? [JSON] ?? []
        try validateSuggestionTargets(operations,project:root)
        do {
            let journal = try files.apply(project:root,operations:operations)
            suggestion["state"] = "applied"; suggestion["journalId"] = journal["id"]; suggestion["appliedAt"] = isoNow()
        } catch {
            suggestion["state"] = "needs_review"; suggestion["error"] = error.localizedDescription
            _ = try store.put("suggestion",suggestion); throw error
        }
        return try store.put("suggestion",suggestion)
    }

    func undoSuggestion(_ params: JSON) throws -> JSON {
        var suggestion = try object("suggestion",requireString(params,"id"))
        guard string(suggestion,"state") == "applied" else { throw VelaError("Suggestion is not applied") }
        _ = try project(requireString(suggestion,"project"))
        _ = try files.undo(journalID:requireString(suggestion,"journalId"))
        suggestion["state"] = "undone"; suggestion["undoneAt"] = isoNow()
        return try store.put("suggestion",suggestion)
    }
}
