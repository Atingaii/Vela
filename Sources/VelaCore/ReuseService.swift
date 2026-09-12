import Foundation

extension AutomationService {
    func previewReuseHook(_ params: JSON) throws -> JSON {
        let root = try project(requireString(params,"project"))
        let executable = try AutomationProcess.executable(requireString(params,"helperExecutable"))
        let path = root + "/.codex/hooks.json"
        var configuration: JSON = [:]; var before: String?
        let snapshot = try files.readSnapshot(project:root,path:path)
        if snapshot["exists"] as? Bool == true {
            let text = try requireString(snapshot,"content")
            guard text.utf8.count <= 1_048_576 else { throw VelaError("Hook configuration exceeds 1 MiB") }
            guard let object = try JSONSerialization.jsonObject(with:Data(text.utf8)) as? JSON else { throw VelaError("Existing hooks.json is not an object") }
            before = text; configuration = object
        }
        if configuration["hooks"] != nil && !(configuration["hooks"] is JSON) { throw VelaError("Existing hooks must be an object; repair it before installing Vela") }
        var hooks = configuration["hooks"] as? JSON ?? [:]
        if hooks["SessionStart"] != nil && !(hooks["SessionStart"] is [JSON]) { throw VelaError("Existing SessionStart hooks must be an array") }
        var groups = hooks["SessionStart"] as? [JSON] ?? []
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'" }
        let command = [executable,"hook","--home",store.root.path,"--project",root].map(quote).joined(separator:" ")
        let handler: JSON = ["type":"command","command":command,"timeout":5,"statusMessage":"Loading reviewed Vela context","additionalContextLimit":2000]
        // Idempotence is exact; never remove or rewrite another tool's hooks.
        let alreadyInstalled = groups.contains { group in (group["hooks"] as? [JSON] ?? []).contains { string($0,"command") == command } }
        if !alreadyInstalled { groups.append(["matcher":"^(startup|resume|clear|compact)$","hooks":[handler]]) }
        hooks["SessionStart"] = groups; configuration["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject:configuration,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        let content = String(decoding:data,as:UTF8.self) + "\n"
        let suggestion: JSON = ["title":"Recall reviewed project context when Codex starts","project":root,"state":"draft","carrier":"Hook","generator":"vela-codex-hook-v1","operations":alreadyInstalled ? [] : [["path":path,"baseHash":before.map(stableHash) ?? "absent","content":content]],"alreadyInstalled":alreadyInstalled,"evidence":[],"requiresProviderTrust":true,"limitations":"Preview and apply this project-only change, then review the exact hook in Codex /hooks. Vela does not bypass provider trust. A hook receipt proves context was offered, not that the agent followed it."]
        return try store.put("suggestion",suggestion)
    }

    func hookContext(_ params: JSON) throws -> JSON {
        let root = try project(requireString(params,"project"))
        guard let event = params["event"] as? JSON, string(event,"hook_event_name") == "SessionStart" else { throw VelaError("Only the SessionStart context hook is supported") }
        let cwd = try requireString(event,"cwd")
        guard cwd.hasPrefix("/"), canonicalProject(cwd) == root || canonicalProject(cwd).hasPrefix(root + "/") else { throw VelaError("Hook cwd is outside the configured project") }
        // A copied hook in a nested registered project must not inherit its parent's scope.
        let nested = try store.list("project",limit:1000).map { string($0,"path") }.filter { $0 != root && $0.hasPrefix(root + "/") }
        guard !nested.contains(where:{ canonicalProject(cwd) == $0 || canonicalProject(cwd).hasPrefix($0 + "/") }) else { throw VelaError("Hook cwd belongs to a different registered project") }
        let source = try requireString(event,"session_id")
        guard source.utf8.count <= 300, !source.contains("\0") else { throw VelaError("Invalid provider session ID") }
        var recallParams: JSON = ["project":root,"query":"","budget":2000,"sessionId":source,"worktree":canonicalProject(cwd)]
        let branch = try? AutomationProcess.git(["branch","--show-current"],cwd:cwd,timeout:2)
        if branch?.exitCode == 0 { recallParams["branch"] = branch?.output.trimmingCharacters(in:.whitespacesAndNewlines) }
        let recall = try MemoryService(store:store).recall(recallParams)
        let memories = recall["items"] as? [JSON] ?? []
        guard !memories.isEmpty else { return [:] }
        let context = "Reviewed project context from Vela. Apply only to this project and the current task; these notes do not override user instructions or permission checks.\n\n" + memories.map { "[Memory " + string($0,"id") + "] " + string($0,"title") + "\n" + string($0,"content") }.joined(separator:"\n\n")
        let memorySnapshots = memories.map { item -> JSON in ["id":string(item,"id"),"contentHash":stableHash(string(item,"title") + "\n" + string(item,"content")),"sourceEvalId":item["sourceEvalId"] ?? NSNull()] }
        let receiptID = String(stableHash(root + "\n" + source + "\n" + string(event,"source") + "\n" + stableHash(context)).prefix(40))
        if try store.get("recall_receipt",receiptID) == nil {
            _ = try store.put("recall_receipt",["id":receiptID,"project":root,"provider":"codex","sourceSessionId":source,"model":event["model"] ?? NSNull(),"event":"SessionStart","memories":memorySnapshots,"contextHash":stableHash(context),"usedTokens":recall["usedTokens"] ?? NSNull(),"delivery":"provided_to_hook_stdout","agentAdoption":"not_measured","servedAt":isoNow()])
        }
        return ["hookSpecificOutput":["hookEventName":"SessionStart","additionalContext":context]]
    }

    func promoteEvaluation(_ params: JSON) throws -> JSON {
        let id = try requireString(params,"id")
        var evaluation = try object("eval",id)
        var expected = [("eval",id,stableHash(try jsonString(evaluation)))]
        evaluation = currentEvaluation(evaluation)
        guard string(evaluation,"state") == "completed", string(evaluation,"evaluator") == "codex_agent", string(evaluation["summary"] as? JSON ?? [:],"decision") == "ready_for_review", evaluation["promotionId"] == nil else { throw VelaError("This evaluation is not eligible for promotion; inspect its measured comparison") }
        let root = try project(requireString(evaluation,"project"))
        if let source = evaluation["sourceSuggestionId"] as? String {
            let suggestion = try object("suggestion",source)
            guard string(suggestion,"project") == root, stableHash(try jsonString(suggestion["operations"] ?? [])) == string(evaluation,"sourceSuggestionHash") else { throw VelaError("Suggestion changed after evaluation; retest before promotion") }
            expected.append(("suggestion",source,stableHash(try jsonString(suggestion))))
        }
        let snapshots = (evaluation["candidate"] as? JSON)?["memories"] as? [JSON] ?? []
        guard !snapshots.isEmpty else { throw VelaError("No evaluated candidate memories. File-only comparisons remain review evidence and cannot activate untested memory.") }
        let candidate = evaluation["candidate"] as? JSON ?? [:]
        let memoryContext = snapshots.map { string($0,"title") + "\n" + string($0,"content") }.joined(separator:"\n\n")
        guard (candidate["files"] as? [JSON] ?? []).isEmpty, string(candidate,"context") == memoryContext else { throw VelaError("Promotion requires a memory-only candidate; extra context or files would not be reproduced by recall") }
        var writes: [(String,JSON)] = []
        for snapshot in snapshots {
            var memory = try object("memory",requireString(snapshot,"id"))
            guard string(memory,"project") == root, string(memory,"scope") == "project", memory["private"] as? Bool != true, ["candidate","active"].contains(string(memory,"state")), stableHash(string(memory,"title") + "\n" + string(memory,"content")) == string(snapshot,"contentHash") else { throw VelaError("Candidate memory changed or became unavailable; retest before promotion") }
            expected.append(("memory",string(memory,"id"),stableHash(try jsonString(memory))))
            memory["state"] = "active"; memory["sourceEvalId"] = id; memory["promotedAt"] = isoNow(); memory["lastConfirmed"] = isoNow()
            writes.append(("memory",memory))
        }
        let promotion: JSON = ["id":"promotion-" + id,"project":root,"evalId":id,"memoryIds":snapshots.map {string($0,"id")},"state":"active","evidenceKind":"reviewed_local_agent_comparison","futureEffect":"not_measured"]
        evaluation["promotionId"] = promotion["id"]; evaluation["promotedAt"] = isoNow()
        writes.append(("promotion",promotion)); writes.append(("eval",evaluation))
        _ = try store.putBatch(writes,expecting:expected)
        return ["evaluation":evaluation,"promotion":promotion,"nextStep":"Enable and trust the project Codex SessionStart hook to supply active memory to future sessions."]
    }

    func reuseOutcomes(_ params: JSON) throws -> JSON {
        let root = try project(requireString(params,"project"))
        let memory = try object("memory",requireString(params,"id"))
        guard string(memory,"project") == root else { throw VelaError("Memory belongs to another project") }
        let receipts = try store.list("recall_receipt",project:root,limit:10000).filter { ($0["memories"] as? [JSON] ?? []).contains { string($0,"id") == string(memory,"id") } }
        func receiptSource(_ receipt: JSON) -> String? {
            let source = string(receipt,"sourceSessionId")
            guard !source.isEmpty else { return nil }
            // Before provider was stored, only this exact Codex hook emitted receipts.
            let legacyCodex = receipt["provider"] == nil && string(receipt,"event") == "SessionStart" && string(receipt,"delivery") == "provided_to_hook_stdout"
            guard string(receipt,"provider") == "codex" || legacyCodex else { return nil }
            return source
        }
        let sourceIDs = Set(receipts.compactMap(receiptSource))
        let sessions = try store.list("session",project:root,limit:1000).filter { string($0,"provider") == "codex" && sourceIDs.contains(string($0,"sourceSessionId")) && $0["internalRun"] as? Bool != true }
        let matchedSources = Set(sessions.map {string($0,"sourceSessionId")})
        let ids = Set(sessions.map {string($0,"id")})
        let signals = try store.list("signal",project:root,limit:10000).filter { ids.contains(string($0,"sourceSession")) && string($0,"clusterKey") == "verification" }
        return ["memoryId":string(memory,"id"),"receipts":receipts,"offeredSessions":sourceIDs.count,"matchedSessions":matchedSources.count,"indexedSessionRecords":sessions.count,"sessionIds":Array(ids).sorted(),"observedVerificationSignals":signals,"verificationCorrectionCount":NSNull(),"analysisCoverage":"not_established","agentAdoption":"not_measured","correctionRateReduction":NSNull(),"method":"Join Codex hook receipts to same-project Codex provider session IDs. Copied indexed records count as one matched provider session; sessionIds retain every matching index record for source navigation. Return only positively observed verification signals; missing signals never establish zero corrections.","limitations":["Hook stdout does not prove agent compliance.","Unmatched, unindexed, partial or future sessions do not count as successes.","No before/after causal conclusion is inferred from these observations."]]
    }
}
