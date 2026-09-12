import Foundation

extension AutomationService {
    func analyze(_ params: JSON) throws -> JSON {
        let selectedProject = try checkedProject(params)
        let sessions = try store.list("session",project:selectedProject,limit:500)
        var emitted: [JSON] = []; var memories: [JSON] = []
        // Revalidate the bounded source window, not old detector output or arbitrary contributions.
        // Neither language matches nor tool invocations establish successful verification.
        for session in sessions where session["internalRun"] as? Bool != true {
            let root = string(session,"project")
            guard !root.isEmpty, !string(session,"id").isEmpty, (try? project(root)) != nil else { continue }
            let messages = session["messages"] as? [JSON] ?? []
            for message in messages where string(message,"role") == "user" {
                let text = string(message,"content")
                let messageID = string(message,"id")
                guard !messageID.isEmpty, let category = engineeringCorrection(text) else { continue }
                let id = String(stableHash("\(root):\(engineeringSessionIdentity(session)):\(messageID):explicit-engineering-v2").prefix(32))
                let evidence: JSON = ["sessionId":string(session,"id"),"messageId":messageID,"quote":text,"timestamp":message["timestamp"] ?? NSNull()]
                let signal = try store.put("signal",["id":id,"title":String(text.prefix(120)),"content":text,"project":root,"state":"observed","type":"Correction","detector":"explicit-engineering-v2","detectorLimit":"Bounded explicit engineering language; review the original message. No confidence or outcome is inferred.","clusterKey":category,"sourceSession":string(session,"id"),"sourceSessionIdentity":engineeringSessionIdentity(session),"sourceMessage":messageID,"evidence":[evidence]])
                emitted.append(signal)
                if category == "verification", explicitVerificationConstraint(text) {
                    let memoryID = "verification-" + id
                    // Never reset an adopted, archived or human-edited memory on reanalysis.
                    if let existing = try store.get("memory",memoryID) { memories.append(existing) }
                    else {
                        let provenance: JSON = ["origin":"session_explicit_constraint","sourceSession":string(session,"id"),"sourceMessage":messageID,"sourceFile":session["sourcePath"] ?? NSNull(),"sourceCommit":NSNull()]
                        do {
                            memories.append(try store.put("memory",["id":memoryID,"title":"Verification before handoff","content":text,"project":root,"scope":"project","type":"constraint","state":"candidate","sourceSession":string(session,"id"),"sourceSessionIdentity":engineeringSessionIdentity(session),"sourceMessage":messageID,"sourceFile":session["sourcePath"] ?? NSNull(),"sourceCommit":NSNull(),"provenance":provenance,"evidence":[evidence],"detector":"explicit-engineering-v2","lastConfirmed":NSNull(),"tokens":tokenEstimate(text)],createOnly:true))
                        } catch {
                            if let concurrent = try store.get("memory",memoryID) { memories.append(concurrent) }
                            else { throw error }
                        }
                    }
                }
            }
            if let sequence = verificationSequence(session) {
                let evidence = sequence["evidence"] as? [JSON] ?? []
                let key = "procedure-" + String(stableHash(string(sequence,"signature")).prefix(16))
                let id = String(stableHash("\(root):\(engineeringSessionIdentity(session)):\(key):tool-sequence-v1").prefix(32))
                emitted.append(try store.put("signal",["id":id,"title":"Git diff → tests → summary","content":"Observed ordered tool invocations followed by an assistant summary.","project":root,"state":"observed","type":"RepeatedWorkflow","detector":"tool-sequence-v1","clusterKey":key,"sourceSession":string(session,"id"),"sourceSessionIdentity":engineeringSessionIdentity(session),"sourceMessage":evidence.first?["messageId"] ?? NSNull(),"evidence":evidence,"workflowDraft":sequence["workflowDraft"] ?? [:],"executionEvidence":"tool invocation only; test success is not inferred"]))
            }
        }
        // Message IDs can repeat in malformed source input. Count each stable source once.
        let signals = Dictionary(emitted.map {(string($0,"id"),$0)},uniquingKeysWith: { first,_ in first }).values.sorted { string($0,"id") < string($1,"id") }
        let groups = Dictionary(grouping:signals) { string($0,"project") + "\n" + string($0,"clusterKey") }
        var clusters: [JSON] = []; var suggestions: [JSON] = []
        for key in groups.keys.sorted() {
            let group = groups[key]!.sorted { string($0,"id") < string($1,"id") }
            let sessions = Set(group.map {string($0,"sourceSessionIdentity",string($0,"sourceSession"))})
            let days = Set(group.flatMap { $0["evidence"] as? [JSON] ?? [] }.compactMap { ($0["timestamp"] as? String).map {String($0.prefix(10))} })
            let first = group[0]
            let discovered = string(first,"type") == "RepeatedWorkflow"
            let promoted = discovered ? sessions.count >= 3 : group.count >= 3 && sessions.count >= 2
            let clusterID = String(stableHash(key).prefix(32))
            let evidence = group.flatMap { $0["evidence"] as? [JSON] ?? [] }
            let cluster = try store.put("cluster",["id":clusterID,"title":string(first,"clusterKey"),"project":string(first,"project"),"state":promoted ? "promoted" : "observing","signalCount":group.count,"distinctSessions":sessions.count,"distinctDays":days.count,"promotionRule":discovered ? "ordered diff/test/summary in at least 3 distinct sessions" : "at least 3 distinct signals in at least 2 sessions","ruleVersion":2,"evidence":evidence,"signalIds":group.map {string($0,"id")}])
            clusters.append(cluster)
            guard promoted else { continue }
            let suggestionID = "suggestion-" + clusterID
            let sources = Set(group.map { string($0,"sourceSessionIdentity",string($0,"sourceSession")) + "\n" + string($0,"sourceMessage") })
            let memoryIDs = Set(memories.filter {
                string($0,"project") == string(first,"project") && ["candidate","active"].contains(string($0,"state")) && sources.contains(string($0,"sourceSessionIdentity",string($0,"sourceSession")) + "\n" + string($0,"sourceMessage"))
            }.map { string($0,"id") }).sorted()
            if var existing = try store.get("suggestion",suggestionID) {
                if existing["verificationCandidateMemoryIds"] as? [String] != memoryIDs {
                    existing["verificationCandidateMemoryIds"] = memoryIDs
                    existing = try store.put("suggestion",existing)
                }
                suggestions.append(existing); continue
            }
            let root = string(first,"project")
            let category = string(first,"clusterKey")
            let procedure = discovered || ["verification","change-review"].contains(category)
            let filename = discovered ? ".vela/workflows/observed-verification-\(clusterID.prefix(8)).md" : procedure ? ".vela/workflows/review-before-handoff.md" : ".vela/guidelines/observed-constraint-\(clusterID.prefix(8)).md"
            let path = URL(fileURLWithPath:root).appendingPathComponent(filename).path
            let title = procedure ? "Review and verify before handoff" : "Review repeated project constraint"
            let quotes = evidence.prefix(6).map { "> " + string($0,"quote").replacingOccurrences(of:"\n",with:"\n> ") }.joined(separator:"\n\n")
            let basis = discovered ? "ordered tool invocations followed by summaries" : "explicit corrections"
            let content = "# \(title)\n\nThis draft is based on \(group.count) \(basis) across \(sessions.count) sessions. Review the quoted evidence before adopting it.\n\n" + (procedure ? "1. Inspect the current Git diff.\n2. Choose and run the relevant project tests.\n3. Run the project's type check when available.\n4. Report test failures, unresolved issues, and the verified result.\n\n" : "Record the narrow project constraint supported by the evidence below. Do not generalize it to unrelated projects.\n\n") + "## Evidence\n\n" + quotes + "\n"
            let snapshot = try files.readSnapshot(project:root,path:path)
            var draft: JSON = ["id":suggestionID,"title":title,"project":root,"state":"draft","carrier":procedure ? "Workflow" : "Guideline","contextTokens":0,"contextCostKind":"on_demand","evidence":evidence,"clusterId":clusterID,"signalCount":group.count,"distinctSessions":sessions.count,"verificationCandidateMemoryIds":memoryIDs,"generator":"deterministic-evidence-draft-v2","limitations":"Review the original evidence. Tool invocation does not prove test success. Saving a draft is not execution or adoption; summary formatting remains a human step.","operations":[["path":path,"baseHash":string(snapshot,"hash"),"content":content]]]
            if discovered { draft["workflowDraft"] = first["workflowDraft"]; draft["discoveryKind"] = "tool-sequence" }
            let suggestion = try store.put("suggestion",draft)
            suggestions.append(suggestion)
        }
        let uniqueMemories = Dictionary(memories.map {(string($0,"id"),$0)},uniquingKeysWith:{ first,_ in first }).values.sorted { string($0,"id") < string($1,"id") }
        return ["signals":Array(signals),"clusters":clusters,"suggestions":suggestions,"candidateMemories":uniqueMemories,"detectorVersion":"explicit-engineering-v2","method":"bounded explicit engineering language and supported Codex tool sequences","modelCalled":false,"limitations":["Existing suggestions from older detectors are retained, not retroactively revalidated.","Only the bounded indexed source window is analyzed; absent provider tool arguments are not reconstructed."]]
    }

    private func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of:pattern,options:[.regularExpression,.caseInsensitive]) != nil
    }

    private func engineeringSessionIdentity(_ session: JSON) -> String {
        let provider = string(session,"provider"), source = string(session,"sourceSessionId")
        // File-based session IDs are navigation identities. Copies/rotations of one provider
        // session cannot supply independent evidence merely because their paths differ.
        return provider.isEmpty || source.isEmpty ? "indexed:" + string(session,"id") : provider + ":" + source
    }

    private func directEngineeringText(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 4000 else { return false }
        // Conservative near-miss exclusions. Recalled documents, examples and UI specifications
        // are not direct instructions about the coding agent's handoff behaviour.
        return !matches(text,"(?m)^\\s*>|```|[\"“”]|\\b(?:example|hypothetical|suppose|button|component|interface|tooltip|form|fixture)\\b|示例|假设|假如|按钮|组件|界面|表单")
            && !matches(text,"\\b(?:do not|don't|never)\\s+run\\s+(?:the\\s+)?tests?\\b|不要.{0,6}测试|无需.{0,6}测试|不用.{0,6}测试")
    }

    private func explicitVerificationConstraint(_ text: String) -> Bool {
        guard directEngineeringText(text) else { return false }
        let action = matches(text,"\\b(?:run|execute|running)\\s+(?:(?:the|relevant|project|unit|integration|all)\\s+){0,3}(?:tests?|typecheck)\\b|(?:跑|运行|执行).{0,6}(?:测试|类型检查)")
        let durable = matches(text,"\\b(?:always|from now on|every task)\\b|(?:以后|今后|每次).{0,20}(?:完成|任务|交付|提交)|(?:完成|交付|提交).{0,10}(?:前|之前).{0,8}(?:必须|一定)")
        let handoff = matches(text,"\\b(?:before|prior to)\\s+(?:handoff|handing|completing|completion|saying.{0,12}(?:done|ready))\\b|(?:完成|交付|提交|任务)")
        return action && durable && handoff
    }

    private func engineeringCorrection(_ text: String) -> String? {
        guard directEngineeringText(text) else { return nil }
        let explicitFailure = matches(text,"\\b(?:you forgot|you skipped|you did not|you didn't|why didn't you|don't forget|do not forget)\\b|(?:又忘|忘记|漏了|没跑测试|没有测试|没测试|未运行测试|跳过测试)")
        if matches(text,"\\b(?:tests?|typecheck|verification)\\b|测试|类型检查") && (explicitFailure || explicitVerificationConstraint(text)) { return "verification" }
        guard explicitFailure else { return nil }
        if matches(text,"\\b(?:npm|pnpm|yarn|bun)\\b|包管理") { return "package-manager" }
        if matches(text,"\\b(?:git|diff|commit)\\b|提交") { return "change-review" }
        return nil
    }

    private func verificationSequence(_ session: JSON) -> JSON? {
        // Only Codex currently retains an explicit tool name and JSON argument payload.
        guard string(session,"provider") == "codex" else { return nil }
        let root = string(session,"project")
        var diff: JSON?; var test: JSON?; var diffCommand = ""; var testCommand = ""
        for message in session["messages"] as? [JSON] ?? [] {
            let id = string(message,"id"), role = string(message,"role"), content = string(message,"content")
            guard !id.isEmpty else { continue }
            if role == "user" { diff = nil; test = nil; continue }
            if role == "tool" {
                guard let command = observedCommand(message,project:root) else {
                    if !string(message,"tool").isEmpty { diff = nil; test = nil }
                    continue
                }
                if matches(command,"^git (?:--no-pager )?diff(?: --(?:stat|name-only|name-status|cached|staged|no-ext-diff|no-textconv))*$") {
                    diff = message; test = nil; diffCommand = command
                } else if diff != nil && matches(command,"^(?:(?:npm|pnpm|yarn|bun) (?:run )?test(?::[a-z0-9_-]+)?(?: --(?:run|runInBand|watch=false))*|swift test|cargo test|go test \\./\\.\\.\\.|pytest|python3? -m pytest)$") {
                    test = message; testCommand = command
                } else { diff = nil; test = nil }
            } else if role == "assistant", let diff, let test,
                      matches(content,"(?m)^\\s*(?:#{1,3}\\s*)?(?:summary\\b|verification summary\\b|总结|验证总结)") {
                let parts = testCommand.split(separator:" ").map(String.init)
                let evidence = [diff,test,message].map { event -> JSON in
                    ["sessionId":string(session,"id"),"messageId":string(event,"id"),"quote":string(event,"content"),"timestamp":event["timestamp"] ?? NSNull()]
                }
                let draft: JSON = ["title":"Observed verification before handoff","project":root,"trigger":"manual","enabled":false,"description":"Inspect the diff, run the observed tests, then review and summarize the actual results. Tool invocation history does not prove success.","steps":[["title":"Review Git diff","tool":"git.diff","arguments":[:]],["title":"Run observed tests","tool":"shell.test","arguments":["executable":parts[0],"args":Array(parts.dropFirst())]]]]
                return ["signature":diffCommand + "\n" + testCommand + "\nsummary","evidence":evidence,"workflowDraft":draft]
            }
        }
        return nil
    }

    private func observedCommand(_ message: JSON, project: String) -> String? {
        let name = string(message,"tool")
        guard ["exec_command","shell_command","functions.exec_command","functions.shell_command"].contains(name) else { return nil }
        let content = string(message,"content"), prefix = "[Tool: \(name)]\n"
        guard content.hasPrefix(prefix), content.utf8.count <= 32_000,
              let data = String(content.dropFirst(prefix.count)).data(using:.utf8),
              let arguments = (try? JSONSerialization.jsonObject(with:data)) as? JSON,
              let command = arguments["cmd"] as? String ?? arguments["command"] as? String else { return nil }
        if let cwd = arguments["workdir"] as? String ?? arguments["cwd"] as? String {
            let path = canonicalProject(cwd)
            guard path == project else { return nil }
        }
        guard !command.contains("\n"), !command.contains("\r") else { return nil }
        return command.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:" +",with:" ",options:.regularExpression)
    }

    func previewSuggestion(_ params: JSON) throws -> JSON {
        var suggestion = try object("suggestion",requireString(params,"id"))
        let root = try project(requireString(suggestion,"project"))
        let operations = suggestion["operations"] as? [JSON] ?? []
        if string(suggestion,"state") == "applied" {
            let journal = try object("apply_journal",requireString(suggestion,"journalId"))
            let committed = journal["operations"] as? [JSON] ?? []
            guard string(journal,"project") == root, string(journal,"state") == "applied",
                  !committed.isEmpty, committed.count <= 32 else { throw VelaError("Applied suggestion has no matching committed journal") }
            try validateSuggestionTargets(committed,project:root)
            // An applied proposal displays its committed before/after snapshot. Undo still
            // checks the current file against the journal's afterHash before any mutation.
            suggestion["preview"] = committed
            suggestion["previewSource"] = "applied_journal"
            return suggestion
        }
        if operations.isEmpty {
            guard string(suggestion,"generator") == "vela-codex-hook-v1",
                  suggestion["alreadyInstalled"] as? Bool == true,
                  string(suggestion,"observedHookPath") == root + "/.codex/hooks.json" else {
                throw VelaError("An empty preview requires a verified, already-installed Vela hook")
            }
            let snapshot = try files.readSnapshot(project:root,path:root + "/.codex/hooks.json")
            guard snapshot["exists"] as? Bool == true,
                  string(snapshot,"hash") == string(suggestion,"observedHookHash") else {
                throw VelaError("Hook configuration changed; generate a new reuse preview")
            }
            suggestion["preview"] = [JSON]()
            return suggestion
        }
        suggestion["preview"] = try files.preview(project:root,operations:operations)
        return suggestion
    }

    func validateSuggestionTargets(_ operations: [JSON], project: String) throws {
        for operation in operations {
            let path = try safeWorkflowPath(requireString(operation,"path"),project:project)
            let relative = String(path.dropFirst(project.count+1))
            let exact: Set<String> = ["AGENTS.md","CLAUDE.md",".cursorrules",".codex/hooks.json"]
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
