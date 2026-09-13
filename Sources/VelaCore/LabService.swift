import Foundation

extension AutomationService {
    func createEvaluation(_ params: JSON) throws -> JSON {
        let root = try project(requireString(params,"project"))
        let kind = try requireString(params,"kind")
        guard ["context","memory","workflow"].contains(kind) else { throw VelaError("Unknown evaluation kind") }
        let agent = try (params["agent"] as? JSON).map(AgentEvaluation.specification)
        let task = agent == nil ? "" : try requireString(params,"task")
        guard task.utf8.count <= 32_000 else { throw VelaError("Lab task exceeds 32 KB") }
        let requested = agent == nil ? params["command"] as? [String] : params["verificationCommand"] as? [String]
        guard let requestedCommand = requested, !requestedCommand.isEmpty, requestedCommand.count <= 128, requestedCommand.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 64_000 }) else { throw VelaError("Lab requires an executable and argument array") }
        let command = [try AutomationProcess.executable(requestedCommand[0])] + requestedCommand.dropFirst()
        let repetitions = (params["repetitions"] as? NSNumber)?.intValue ?? 1
        guard repetitions >= 1, repetitions <= 5 else { throw VelaError("Lab supports 1–5 repetitions per variant") }
        let timeout = (params["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 120
        guard timeout >= 1, timeout <= 600 else { throw VelaError("Lab timeout must be 1–600 seconds") }
        let head = try AutomationProcess.git(["rev-parse","--verify","HEAD"],cwd:root)
        guard head.exitCode == 0 else { throw VelaError("Lab requires a Git repository with an existing commit") }
        let commit = head.output.trimmingCharacters(in:.whitespacesAndNewlines)
        guard commit.range(of:"^[a-f0-9]{40,64}$",options:.regularExpression) != nil else { throw VelaError("Git returned an invalid commit") }
        let baseline = try evaluationVariant(params["baseline"] as? JSON ?? [:],project:root)
        let candidate = try evaluationVariant(params["candidate"] as? JSON ?? [:],project:root)
        var evaluation: JSON = ["title":string(params,"title","Paired evaluation"),"evaluationKind":kind,"project":root,"state":"pending_approval","evaluator":agent == nil ? "deterministic_command" : "codex_agent","command":command,"timeoutSeconds":timeout,"repetitions":repetitions,"commit":commit,"baseline":baseline,"candidate":candidate,"results":[],"limitations":["Commands run in separate Git worktrees, not an operating system sandbox.","Only committed repository files are copied. Dependencies may need explicit setup.","Independent command success does not establish future correction reduction."],"tokensAvailable":false]
        if let source = params["sourceSuggestionId"] as? String {
            let suggestion = try object("suggestion",source)
            guard string(suggestion,"project") == root else { throw VelaError("Suggestion and evaluation projects must match") }
            let linkedMemoryIDs = Set(suggestion["verificationCandidateMemoryIds"] as? [String] ?? [])
            let selectedMemoryIDs = (candidate["memories"] as? [JSON] ?? []).map { string($0,"id") }
            let candidateFiles = candidate["files"] as? [JSON] ?? []
            let operations = suggestion["operations"] as? [JSON] ?? []
            let sameFiles = !operations.isEmpty && operations.count == candidateFiles.count && operations.allSatisfy { op in candidateFiles.contains { file in
                automationPath(string(op,"path"),project:root) == automationPath(string(file,"path"),project:root) && string(op,"content") == string(file,"content")
            } }
            let linkedMemories = !selectedMemoryIDs.isEmpty && selectedMemoryIDs.allSatisfy { linkedMemoryIDs.contains($0) }
            guard sameFiles || linkedMemories else { throw VelaError("Candidate must contain the suggestion's exact file changes or its linked verification memories") }
            evaluation["sourceSuggestionId"] = source
            evaluation["sourceSuggestionHash"] = stableHash(try jsonString(suggestion["operations"] ?? []))
            evaluation["sourceRelationship"] = linkedMemories ? "evaluates_linked_memory" : "evaluates_exact_file_changes"
        }
        var protectedFiles: [JSON] = []
        if let agent {
            guard let paths = params["verificationFiles"] as? [String], !paths.isEmpty, paths.count <= 32 else { throw VelaError("Agent Lab requires 1–32 committed verification files") }
            var seen = Set<String>()
            for rawPath in paths {
                let variant = try evaluationVariant(["files":[["path":rawPath,"content":""]]],project:root)
                let path = string((variant["files"] as? [JSON] ?? [[:]])[0],"path")
                guard seen.insert(path).inserted else { throw VelaError("Duplicate verification file") }
                let blob = try AutomationProcess.git(["show",commit + ":" + path],cwd:root)
                guard blob.exitCode == 0, !blob.truncated else { throw VelaError("Verification files must be bounded committed text files") }
                protectedFiles.append(["path":path,"hash":stableHash(blob.output)])
            }
            for variant in [baseline,candidate] {
                guard !(variant["files"] as? [JSON] ?? []).contains(where:{ seen.contains(string($0,"path")) }) else { throw VelaError("Candidate context must not change verification files") }
            }
            guard let rawOutputs = params["outputFiles"] as? [String], !rawOutputs.isEmpty, rawOutputs.count <= 32 else { throw VelaError("Agent Lab requires 1–32 explicit task output files for independent verification") }
            let outputs = try rawOutputs.map { path -> String in
                let validated = try evaluationVariant(["files":[["path":path,"content":""]]],project:root)
                let value = string((validated["files"] as? [JSON] ?? [[:]])[0],"path")
                guard !seen.contains(value) else { throw VelaError("Task outputs cannot replace protected verification files") }
                return value
            }
            guard Set(outputs).count == outputs.count else { throw VelaError("Duplicate task output file") }
            evaluation["agent"] = agent; evaluation["task"] = task
            evaluation["verificationFiles"] = protectedFiles; evaluation["verificationCommand"] = command
            evaluation["outputFiles"] = outputs
            evaluation["modelIdentity"] = ["requested":string(agent,"model"),"requestFixed":true,"providerResolvedVersion":NSNull()] as JSON
            evaluation["promotionPolicy"] = ["minimumRepetitions":3,"maximumTokenRatio":1.2,"absoluteTokenTolerance":100,"requireTaskSuccess":true,"requireMeasuredImprovement":true]
        }
        evaluation = try store.put("eval",evaluation)
        var frozen: JSON = ["evalId":string(evaluation,"id"),"project":root,"commit":commit,"command":command,"timeoutSeconds":timeout,"repetitions":repetitions,"baseline":baseline,"candidate":candidate]
        if let agent { frozen["agent"] = agent; frozen["task"] = task; frozen["verificationFiles"] = protectedFiles; frozen["outputFiles"] = evaluation["outputFiles"] }
        if let source = evaluation["sourceSuggestionId"] { frozen["sourceSuggestionId"] = source; frozen["sourceSuggestionHash"] = evaluation["sourceSuggestionHash"] }
        let approval = try createApproval(title:"Run paired evaluation: " + string(evaluation,"title"),tool:"lab.execute",arguments:frozen,project:root,runId:string(evaluation,"id"),stepIndex:0)
        evaluation["approvalId"] = approval["id"]
        return try store.put("eval",evaluation)
    }

    /// Legacy `memoryIds` remain an explicit caller-selected context channel.  Recall is
    /// opt-in and always carries its own frozen receipt so a record whose kind happens
    /// to be memory is never represented as a retrieval result.
    func evaluationVariant(_ input: JSON, project: String) throws -> JSON {
        let allowed: Set<String> = ["files","label","context","memoryIds","recall"]
        guard Set(input.keys).isSubset(of: allowed) else { throw VelaError("Unsupported Lab variant field") }
        let files = input["files"] as? [JSON] ?? []
        guard files.count <= 16 else { throw VelaError("An evaluation variant supports at most 16 files") }
        var seen = Set<String>()
        let validated = try files.map { file -> JSON in
            let path = try requireString(file,"path")
            guard !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator:"/").contains(".."), !path.split(separator:"/").contains(".git") else { throw VelaError("Evaluation files require relative paths inside the worktree") }
            let relative = path.split(separator:"/").filter {$0 != "."}.joined(separator:"/")
            guard !relative.isEmpty else { throw VelaError("Evaluation file path is empty") }
            guard let content = file["content"] as? String, content.utf8.count <= 1_048_576 else { throw VelaError("Evaluation file exceeds 1 MiB or is not text") }
            let normalized = URL(fileURLWithPath:project).appendingPathComponent(path).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { throw VelaError("Duplicate evaluation file") }
            return ["path":relative,"content":content]
        }
        let context = string(input,"context")
        guard context.utf8.count <= 32_000 else { throw VelaError("Variant context exceeds 32 KB") }
        let ids = input["memoryIds"] as? [String] ?? []
        guard ids.count <= 16, Set(ids).count == ids.count else { throw VelaError("At most 16 distinct memories per variant") }
        let exclusions = IngestionExclusionService(store:store)
        let memories = try ids.map { id -> JSON in
            let memory = try object("memory",id)
            guard string(memory,"project") == project, string(memory,"scope") == "project", memory["private"] as? Bool != true, !privateLibraryPath(string(memory,"sourceFile")), ["active","candidate"].contains(string(memory,"state")), try exclusions.allowsMemoryRecall(memory,project:project) else { throw VelaError("Evaluation memory is excluded by the current ingestion policy") }
            return explicitMemoryReceipt(memory)
        }
        let recall = try evaluationRecall(input["recall"], project:project, explicitIDs:Set(ids))
        if recall["strictOff"] as? Bool == true, !memories.isEmpty { throw VelaError("A strict Recall-OFF variant cannot also carry explicit memoryIds") }
        let recalled = recall["items"] as? [JSON] ?? []
        let sections = [context] + memories.map { string($0,"title") + "\n" + string($0,"content") } + recalled.map { string($0,"title") + "\n" + string($0,"content") }
        let combined = sections.filter {!$0.isEmpty}.joined(separator:"\n\n")
        guard combined.utf8.count <= 32_000 else { throw VelaError("Combined variant context exceeds 32 KB") }
        return ["files":validated,"label":string(input,"label"),"context":combined,"finalContextHash":stableHash(combined),"memories":memories,"recall":recall,
                "memoryInjection": memories.isEmpty ? (recalled.isEmpty ? "none" : "recall") : (recalled.isEmpty ? "explicit_ids" : "explicit_ids_plus_recall")]
    }

    private func explicitMemoryReceipt(_ memory: JSON) -> JSON {
        ["id":string(memory,"id"),"title":string(memory,"title"),"content":string(memory,"content"),
         "contentHash":stableHash(string(memory,"title") + "\n" + string(memory,"content")),"state":string(memory,"state"),
         "sourceHash":labMemorySourceHash(memory),"selection":"explicit_memory_id"]
    }

    private func labMemorySourceHash(_ memory: JSON) -> String {
        let source: JSON = ["id":string(memory,"id"),"project":string(memory,"project"),"scope":string(memory,"scope"),
                            "state":string(memory,"state"),"private":memory["private"] as? Bool ?? false,
                            "sourceFile":string(memory,"sourceFile"),"title":string(memory,"title"),"content":string(memory,"content")]
        return stableHash((try? jsonString(source)) ?? "")
    }

    private func evaluationRecall(_ raw: Any?, project: String, explicitIDs: Set<String>) throws -> JSON {
        guard let raw else { return ["enabled":false,"strictOff":false,"selection":"not_requested","items":[],"usedTokens":0,"budget":NSNull(),"finalContextHash":stableHash("")] }
        guard let input = raw as? JSON, Set(input.keys).isSubset(of:["enabled","strictOff","query","mode","scope","budget"]) else { throw VelaError("Unsupported Lab Recall field") }
        let enabled = input["enabled"] as? Bool ?? false
        guard input["enabled"] == nil || input["enabled"] is Bool, input["strictOff"] == nil || input["strictOff"] is Bool else { throw VelaError("Lab Recall enabled and strictOff must be booleans") }
        let strictOff = input["strictOff"] as? Bool ?? false
        guard !enabled || !strictOff else { throw VelaError("Lab Recall cannot be enabled and strictOff") }
        if !enabled {
            guard Set(input.keys).isSubset(of:["enabled","strictOff"]) else { throw VelaError("A disabled Lab Recall accepts no query, mode, scope or budget") }
            return ["enabled":false,"strictOff":strictOff,"selection":"explicitly_disabled","items":[],"usedTokens":0,"budget":NSNull(),"finalContextHash":stableHash("")]
        }
        guard Set(input.keys).isSubset(of:["enabled","query","mode","scope","budget"]), let query = input["query"] as? String,
              !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, query.utf8.count <= 4_000, query.rangeOfCharacter(from:.controlCharacters) == nil else { throw VelaError("An enabled Lab Recall requires bounded query text") }
        let mode = string(input,"mode","lexical")
        guard ["lexical","semantic","hybrid"].contains(mode) else { throw VelaError("Unsupported Lab Recall mode") }
        guard string(input,"scope") == "project" else { throw VelaError("Lab Recall is limited to project scope") }
        guard let budgetNumber = input["budget"] as? NSNumber, CFGetTypeID(budgetNumber) != CFBooleanGetTypeID(), budgetNumber.doubleValue.rounded() == budgetNumber.doubleValue,
              (1...4_000).contains(budgetNumber.intValue) else { throw VelaError("Lab Recall budget must be an integer from 1 to 4000") }
        let budget = budgetNumber.intValue
        let result = try MemoryService(store:store).recall(["project":project,"query":query,"retrievalMode":mode,"budget":budget])
        let actualMode = string(result,"retrievalMode", mode), status = string(result,"status","ok")
        guard actualMode == mode, status == "ok", result["indexIncomplete"] as? Bool != true else {
            throw VelaError("Lab Recall did not obtain the requested \(mode) retrieval; choose lexical explicitly or retry when semantic indexing is available")
        }
        let items = (result["items"] as? [JSON] ?? []).filter { memory in
            string(memory,"project") == project && string(memory,"scope").lowercased() == "project" && string(memory,"state").lowercased() == "active" &&
            memory["private"] as? Bool != true && !privateLibraryPath(string(memory,"sourceFile")) && !explicitIDs.contains(string(memory,"id"))
        }.map { memory -> JSON in
            ["id":string(memory,"id"),"title":string(memory,"title"),"content":string(memory,"content"),
             "contentHash":stableHash(string(memory,"title") + "\n" + string(memory,"content")),"sourceHash":labMemorySourceHash(memory),
             "state":string(memory,"state"),"scope":string(memory,"scope"),"project":string(memory,"project"),
             "recallTokens":intValue(memory,"recallTokens"),"relevance":memory["relevance"] ?? NSNull(),"selection":"memory_service_recall"]
        }
        let used = items.reduce(0) { $0 + intValue($1,"recallTokens") }
        // A mode may return an ineligible/global item. It is deliberately dropped; the
        // retained receipt says the actual Recall result was filtered to Lab's narrower boundary.
        guard used <= budget else { throw VelaError("Lab Recall result exceeded its frozen budget") }
        let recalledContext = items.map { string($0,"title") + "\n" + string($0,"content") }.joined(separator:"\n\n")
        return ["enabled":true,"strictOff":false,"query":query,"mode":mode,"scope":"project","budget":budget,"usedTokens":used,
                "tokenAccounting":string(result,"tokenAccounting"),"retrievalMode":actualMode,"requestedRetrievalMode":mode,"status":status,"indexIncomplete":result["indexIncomplete"] as? Bool ?? false,"truncated":result["truncated"] as? Bool ?? false,
                "items":items,"finalContextHash":stableHash(recalledContext),"selection":"memory_service_recall_project_active_only"]
    }

    private func revalidateVariantRecall(_ variant: JSON, project: String) throws {
        let exclusions = IngestionExclusionService(store:store)
        let explicit = variant["memories"] as? [JSON] ?? []
        for frozen in explicit {
            // Older Lab records stored direct IDs/content without a source receipt. They
            // cannot establish that a later private/lifecycle change is safe to send.
            guard !string(frozen,"sourceHash").isEmpty else { throw VelaError("Frozen explicit Lab memory lacks a source receipt; prepare a new evaluation") }
            let current = try object("memory",try requireString(frozen,"id"))
            guard string(current,"project") == project, string(current,"scope").lowercased() == "project", ["active","candidate"].contains(string(current,"state").lowercased()),
                  current["private"] as? Bool != true, !privateLibraryPath(string(current,"sourceFile")),
                  stableHash(string(current,"title") + "\n" + string(current,"content")) == string(frozen,"contentHash"),
                  labMemorySourceHash(current) == string(frozen,"sourceHash"), try exclusions.allowsMemoryRecall(current,project:project) else { throw VelaError("Frozen explicit Lab memory changed, became private, was excluded, or is no longer eligible; prepare a new evaluation") }
        }
        let recall = variant["recall"] as? JSON ?? [:]
        for frozen in recall["items"] as? [JSON] ?? [] {
            let current = try object("memory",try requireString(frozen,"id"))
            guard string(current,"project") == project, string(current,"scope").lowercased() == "project", string(current,"state").lowercased() == "active",
                  current["private"] as? Bool != true, !privateLibraryPath(string(current,"sourceFile")),
                  stableHash(string(current,"title") + "\n" + string(current,"content")) == string(frozen,"contentHash"),
                  labMemorySourceHash(current) == string(frozen,"sourceHash"), try exclusions.allowsMemoryRecall(current,project:project) else { throw VelaError("Frozen Lab Recall source changed, became private, was excluded, or is no longer active; prepare a new evaluation") }
        }
        if !explicit.isEmpty || recall["enabled"] as? Bool == true {
            guard !string(variant,"finalContextHash").isEmpty, stableHash(string(variant,"context")) == string(variant,"finalContextHash") else { throw VelaError("Frozen Lab memory context is invalid") }
        }
    }

    func executeEvaluation(_ frozen: JSON) throws -> JSON {
        let id = try requireString(frozen,"evalId")
        var evaluation = try object("eval",id)
        guard string(evaluation,"state") == "pending_approval" else { throw VelaError("Evaluation was already started") }
        let root = try project(requireString(frozen,"project"))
        let command = frozen["command"] as? [String] ?? []
        let commit = try requireString(frozen,"commit")
        let timeout = (frozen["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 120
        let repetitions = max(1,min(5,intValue(frozen,"repetitions")))
        let agent = frozen["agent"] as? JSON
        evaluation["state"] = "running"; evaluation["startedAt"] = isoNow(); evaluation = try store.put("eval",evaluation)
        let tempRoot = store.root.appendingPathComponent("lab-worktrees/" + id)
        guard tempRoot.standardizedFileURL.path.hasPrefix(store.root.path + "/lab-worktrees/") else { throw VelaError("Invalid Lab workspace root") }
        try FileManager.default.createDirectory(at:tempRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var results: [JSON] = []
        var cleanupFailures: [String] = []
        var ownedWorktrees = Set<String>()
        var interrupted = false
        var originalStatus: String?
        func removeKnownWorktree(_ worktree: URL) {
            let removed: AutomationProcessResult?
            do {
                removed = try AutomationProcess.git(["worktree","remove","--force",worktree.path],cwd:root)
            } catch {
                // A normal Git observation may have raced with the shutdown gate.
                // Only the exact, tracked Lab path may use the dedicated cleanup path.
                removed = VelaRuntimeShutdown.isRequested ? try? AutomationProcess.removeOwnedWorktree(worktree.path,cwd:root) : nil
            }
            if removed?.exitCode != 0 && VelaRuntimeShutdown.isRequested {
                let retry = try? AutomationProcess.removeOwnedWorktree(worktree.path,cwd:root)
                if retry?.exitCode == 0 { ownedWorktrees.remove(worktree.path) }
                else { cleanupFailures.append(worktree.path) }
            } else if removed?.exitCode == 0 {
                ownedWorktrees.remove(worktree.path)
            } else {
                cleanupFailures.append(worktree.path)
            }
        }
        do {
            originalStatus = try AutomationProcess.git(["status","--porcelain=v1"],cwd:root).output
            if let agent {
                let version = try AutomationProcess.run([try requireString(agent,"executable"),"--version"],cwd:root,timeout:10,maxOutput:4096)
                guard version.exitCode == 0, !version.truncated, !version.timedOut else { throw VelaError("Could not record the approved Agent CLI version") }
                evaluation["agentVersion"] = version.output.trimmingCharacters(in:.whitespacesAndNewlines)
                evaluation = try store.put("eval",evaluation)
            }
            for repetition in 1...repetitions {
                // Alternate order so the candidate does not always receive warmer filesystem caches.
                let variants = repetition % 2 == 1 ? ["baseline","candidate"] : ["candidate","baseline"]
                for variant in variants {
                    guard !VelaRuntimeShutdown.isRequested else { throw VelaError("Lab evaluation interrupted before starting another variant") }
                    let variantSpec = frozen[variant] as? JSON ?? [:]
                    // Revalidate before allocating a worktree: a stale Recall source must not
                    // launch an agent or leave a new child workspace behind.
                    try revalidateVariantRecall(variantSpec,project:root)
                    let worktree = tempRoot.appendingPathComponent("\(variant)-\(repetition)")
                    let added = try AutomationProcess.git(["worktree","add","--detach",worktree.path,commit],cwd:root,timeout:60)
                    if FileManager.default.fileExists(atPath:worktree.path) { ownedWorktrees.insert(worktree.path) }
                    guard added.exitCode == 0 else {
                        if ownedWorktrees.contains(worktree.path) {
                            let cleanup = try? AutomationProcess.removeOwnedWorktree(worktree.path,cwd:root)
                            if cleanup?.exitCode != 0 { cleanupFailures.append(worktree.path) } else { ownedWorktrees.remove(worktree.path) }
                        }
                        throw VelaError("Could not create isolated worktree: \(added.output)")
                    }
                    for change in variantSpec["files"] as? [JSON] ?? [] {
                        let relative = try requireString(change,"path")
                        let before = try files.readSnapshot(project:worktree.path,path:relative)
                        _ = try files.apply(project:worktree.path,operations:[["path":relative,"baseHash":string(before,"hash"),"content":string(change,"content")]])
                    }
                    let baselineStatus = try AutomationProcess.git(["status","--porcelain=v1"],cwd:worktree.path).output
                    let actualCommand = try agent.map { try AgentEvaluation.command($0,task:string(frozen,"task"),context:string(variantSpec,"context")) } ?? command
                    var result = try AutomationProcess.run(actualCommand,cwd:worktree.path,timeout:timeout).json
                    var partialRecorded = false
                    var phase = "post-agent-command"
                    func recordPartial(_ phase: String) throws {
                            guard !partialRecorded else { return }
                            result["variant"] = variant; result["repetition"] = repetition; result["commit"] = commit; result["command"] = command
                            result["configuredChanges"] = baselineStatus.split(separator:"\n").map(String.init)
                            result["interrupted"] = true; result["outcomeUnknown"] = true; result["interruptionPhase"] = phase
                            results.append(result); evaluation["results"] = results
                            evaluation["state"] = "interrupted"; evaluation["interruptedAt"] = isoNow()
                            evaluation["interruptionReason"] = "Runtime shutdown interrupted an approved Lab child; no later variant or verifier was started."
                            evaluation["partialResults"] = results.count
                            evaluation = try store.put("eval",evaluation)
                            partialRecorded = true
                    }
                    func persistInterruption(_ phase: String) throws {
                            try recordPartial(phase)
                            throw VelaError("Lab evaluation interrupted while an approved child command was running")
                    }
                    do {
                        if VelaRuntimeShutdown.isRequested {
                            // Retain the real, partial child receipt, but do not start an independent
                            // verifier or another variant while shutdown is in progress.
                            try persistInterruption("agent")
                        }
                        if let agent {
                            let metrics = AgentEvaluation.metrics(string(result,"output"),truncated:result["truncated"] as? Bool ?? true,verificationCommand:command)
                            result["agentMetrics"] = metrics; result["agent"] = agent
                            result["agentCommand"] = actualCommand
                            let protected = frozen["verificationFiles"] as? [JSON] ?? []
                            let intact = protected.allSatisfy { entry in
                                let target = worktree.appendingPathComponent(string(entry,"path"))
                                guard canonicalProject(target.path) == target.path,
                                      let metadata = try? target.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]), metadata.isRegularFile == true, (metadata.fileSize ?? Int.max) <= 1_048_576,
                                      let text = try? String(contentsOf:target,encoding:.utf8) else { return false }
                                return stableHash(text) == string(entry,"hash")
                            }
                            result["verificationIntact"] = intact
                            if intact {
                                phase = "pre-verifier-worktree"
                                if VelaRuntimeShutdown.isRequested { try persistInterruption(phase) }
                                let verifier = tempRoot.appendingPathComponent("verify-\(variant)-\(repetition)")
                                let addedVerifier = try AutomationProcess.git(["worktree","add","--detach",verifier.path,commit],cwd:root,timeout:60)
                                if FileManager.default.fileExists(atPath:verifier.path) { ownedWorktrees.insert(verifier.path) }
                                guard addedVerifier.exitCode == 0 else {
                                    if ownedWorktrees.contains(verifier.path) {
                                        let cleanup = try? AutomationProcess.removeOwnedWorktree(verifier.path,cwd:root)
                                        if cleanup?.exitCode != 0 { cleanupFailures.append(verifier.path) } else { ownedWorktrees.remove(verifier.path) }
                                    }
                                    throw VelaError("Could not create independent verifier worktree")
                                }
                                if VelaRuntimeShutdown.isRequested { try persistInterruption(phase) }
                                do {
                                    phase = "verifier"
                                    for relative in frozen["outputFiles"] as? [String] ?? [] {
                                        let source = try files.readSnapshot(project:worktree.path,path:relative)
                                        guard source["exists"] as? Bool == true, let content = source["content"] as? String, content.utf8.count <= 1_048_576 else { throw VelaError("Task output is missing or too large: " + relative) }
                                        let before = try files.readSnapshot(project:verifier.path,path:relative)
                                        _ = try files.apply(project:verifier.path,operations:[["path":relative,"content":content,"baseHash":string(before,"hash")]])
                                    }
                                    result["verification"] = try AutomationProcess.run(command,cwd:verifier.path,timeout:timeout).json
                                    result["verificationIsolation"] = "clean commit plus frozen output-file allowlist only"
                                } catch {
                                    result["verification"] = ["exitCode":NSNull(),"output":error.localizedDescription] as JSON
                                    result["verificationIntact"] = false
                                }
                                removeKnownWorktree(verifier)
                                if VelaRuntimeShutdown.isRequested { try persistInterruption("verifier") }
                            }
                            else { result["verification"] = ["exitCode":NSNull(),"output":"Verification files changed; comparison invalid and verifier was not executed."] as JSON }
                            result["tokens"] = metrics["tokens"]; result["tokensAvailable"] = metrics["tokens"] is Int
                        }
                        if VelaRuntimeShutdown.isRequested { try persistInterruption("post-verifier") }
                        phase = "diff"
                        let diff = try AutomationProcess.git(["diff","--no-ext-diff","--no-textconv","--stat",commit],cwd:worktree.path)
                        phase = "status"
                        let status = try AutomationProcess.git(["status","--porcelain=v1"],cwd:worktree.path)
                        if VelaRuntimeShutdown.isRequested { try persistInterruption("post-status") }
                        result["variant"] = variant; result["repetition"] = repetition; result["commit"] = commit; result["command"] = command
                        result["configuredChanges"] = baselineStatus.split(separator:"\n").map(String.init)
                        result["changedFiles"] = status.output.split(separator:"\n").map(String.init)
                        result["diffStat"] = diff.output
                        if agent == nil { result["tokens"] = NSNull(); result["tokensAvailable"] = false }
                        results.append(result)
                        evaluation["results"] = results; evaluation = try store.put("eval",evaluation)
                        if VelaRuntimeShutdown.isRequested {
                            results.removeLast()
                            try persistInterruption("post-append")
                        }
                    } catch {
                        if VelaRuntimeShutdown.isRequested && !partialRecorded { try? recordPartial(phase) }
                        // This is the exact worktree created above for this evaluation. The
                        // dedicated cleanup API is the sole shutdown-exempt child path.
                        let cleanup = try? AutomationProcess.removeOwnedWorktree(worktree.path,cwd:root)
                        if cleanup?.exitCode != 0 { cleanupFailures.append(worktree.path) } else { ownedWorktrees.remove(worktree.path) }
                        throw error
                    }
                    removeKnownWorktree(worktree)
                }
            }
            guard !VelaRuntimeShutdown.isRequested else { throw VelaError("Lab evaluation interrupted before completion") }
            evaluation["state"] = "completed"
        } catch {
            interrupted = VelaRuntimeShutdown.isRequested
            evaluation["state"] = interrupted ? "interrupted" : "failed"; evaluation["error"] = error.localizedDescription
            if interrupted {
                if !results.isEmpty, results[results.count - 1]["interrupted"] as? Bool != true {
                    results[results.count - 1]["interrupted"] = true
                    results[results.count - 1]["outcomeUnknown"] = true
                    results[results.count - 1]["interruptionPhase"] = "post-persist"
                }
                evaluation["interruptedAt"] = evaluation["interruptedAt"] ?? isoNow()
                evaluation["interruptionReason"] = evaluation["interruptionReason"] ?? "Runtime shutdown interrupted an approved Lab child; no later variant or verifier was started."
                evaluation["partialResults"] = results.count
                evaluation["results"] = results
            }
        }
        if VelaRuntimeShutdown.isRequested {
            evaluation["originalGitStatusUnchanged"] = NSNull()
            evaluation["originalGitStatusReason"] = "Unavailable: runtime shutdown prevented a post-run original Git status observation."
        } else {
            let afterStatus = try? AutomationProcess.git(["status","--porcelain=v1"],cwd:root).output
            if let originalStatus, let afterStatus { evaluation["originalGitStatusUnchanged"] = afterStatus == originalStatus }
            else { evaluation["originalGitStatusUnchanged"] = NSNull(); evaluation["originalGitStatusReason"] = "Unavailable: original or post-run Git status observation failed." }
        }
        evaluation["originalWorktreeUnchanged"] = NSNull() // Status equality is not a file-content snapshot.
        evaluation["results"] = results; evaluation["completedAt"] = isoNow(); evaluation["cleanupFailures"] = cleanupFailures
        evaluation["summary"] = agent == nil ? evaluationSummary(results) : agentEvaluationSummary(results,expectedRepetitions:repetitions)
        if agent != nil { evaluation["analysisVersion"] = "codex-test-observation-v3" }
        evaluation["tokensAvailable"] = agent != nil && !results.isEmpty && results.allSatisfy { $0["tokensAvailable"] as? Bool == true }
        evaluation["ownedWorktreesRemaining"] = ownedWorktrees.sorted()
        if cleanupFailures.isEmpty && ownedWorktrees.isEmpty {
            // Only this evaluation's known temporary directory is eligible for cleanup.
            try? FileManager.default.removeItem(at:tempRoot)
        }
        evaluation = try store.put("eval",evaluation)
        return ["exitCode":string(evaluation,"state") == "completed" ? 0 : 1,"output":string(evaluation,"error","Paired evaluation completed"),"evaluation":evaluation,"durationMs":results.reduce(0) {$0+intValue($1,"durationMs")},"outcomeUnknown":interrupted]
    }

    func evaluationSummary(_ results: [JSON]) -> JSON {
        func aggregate(_ variant: String) -> JSON {
            let values = results.filter { string($0,"variant") == variant }
            let successes = values.filter { intValue($0,"exitCode") == 0 && $0["timedOut"] as? Bool != true }.count
            let runtimes = values.map {Double(intValue($0,"durationMs"))}
            let mean = runtimes.isEmpty ? 0 : runtimes.reduce(0,+)/Double(runtimes.count)
            return ["runs":values.count,"successes":successes,"passRate":values.isEmpty ? NSNull() : Double(successes)/Double(values.count),"averageDurationMs":values.isEmpty ? NSNull() : mean,"runtimeVariance":runtimes.count < 2 ? NSNull() : runtimes.reduce(0) {$0+pow($1-mean,2)}/Double(runtimes.count-1)]
        }
        let baseline = aggregate("baseline"); let candidate = aggregate("candidate")
        let runtimeDelta: Any = (baseline["averageDurationMs"] as? Double).flatMap { b in (candidate["averageDurationMs"] as? Double).map {$0-b} } as Any? ?? NSNull()
        let successDelta: Any = (baseline["passRate"] as? Double).flatMap { b in (candidate["passRate"] as? Double).map {$0-b} } as Any? ?? NSNull()
        return ["baseline":baseline,"candidate":candidate,"runtimeDeltaMs":runtimeDelta,"successDelta":successDelta,"interpretation":"Measured command outcomes. No causal improvement claim or model-generated score is inferred."]
    }
}
