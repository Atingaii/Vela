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

    func evaluationVariant(_ input: JSON, project: String) throws -> JSON {
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
        let memories = try ids.map { id -> JSON in
            let memory = try object("memory",id)
            guard string(memory,"project") == project, string(memory,"scope") == "project", memory["private"] as? Bool != true, ["active","candidate"].contains(string(memory,"state")) else { throw VelaError("Evaluation memory must be active/candidate, nonprivate and in this project scope") }
            return ["id":id,"title":string(memory,"title"),"content":string(memory,"content"),"contentHash":stableHash(string(memory,"title") + "\n" + string(memory,"content")),"state":string(memory,"state")]
        }
        let combined = ([context] + memories.map { string($0,"title") + "\n" + string($0,"content") }).filter {!$0.isEmpty}.joined(separator:"\n\n")
        guard combined.utf8.count <= 32_000 else { throw VelaError("Combined variant context exceeds 32 KB") }
        return ["files":validated,"label":string(input,"label"),"context":combined,"memories":memories]
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
        let originalStatus = try AutomationProcess.git(["status","--porcelain=v1"],cwd:root).output
        do {
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
                    let worktree = tempRoot.appendingPathComponent("\(variant)-\(repetition)")
                    let added = try AutomationProcess.git(["worktree","add","--detach",worktree.path,commit],cwd:root,timeout:60)
                    guard added.exitCode == 0 else { throw VelaError("Could not create isolated worktree: \(added.output)") }
                    do {
                        let variantSpec = frozen[variant] as? JSON ?? [:]
                        for change in variantSpec["files"] as? [JSON] ?? [] {
                            let relative = try requireString(change,"path")
                            let before = try files.readSnapshot(project:worktree.path,path:relative)
                            _ = try files.apply(project:worktree.path,operations:[["path":relative,"baseHash":string(before,"hash"),"content":string(change,"content")]])
                        }
                        let baselineStatus = try AutomationProcess.git(["status","--porcelain=v1"],cwd:worktree.path).output
                        let actualCommand = try agent.map { try AgentEvaluation.command($0,task:string(frozen,"task"),context:string(variantSpec,"context")) } ?? command
                        var result = try AutomationProcess.run(actualCommand,cwd:worktree.path,timeout:timeout).json
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
                                let verifier = tempRoot.appendingPathComponent("verify-\(variant)-\(repetition)")
                                let addedVerifier = try AutomationProcess.git(["worktree","add","--detach",verifier.path,commit],cwd:root,timeout:60)
                                guard addedVerifier.exitCode == 0 else { throw VelaError("Could not create independent verifier worktree") }
                                do {
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
                                let removedVerifier = try AutomationProcess.git(["worktree","remove","--force",verifier.path],cwd:root)
                                if removedVerifier.exitCode != 0 { cleanupFailures.append(verifier.path) }
                            }
                            else { result["verification"] = ["exitCode":NSNull(),"output":"Verification files changed; comparison invalid and verifier was not executed."] as JSON }
                            result["tokens"] = metrics["tokens"]; result["tokensAvailable"] = metrics["tokens"] is Int
                        }
                        let diff = try AutomationProcess.git(["diff","--no-ext-diff","--no-textconv","--stat",commit],cwd:worktree.path)
                        let status = try AutomationProcess.git(["status","--porcelain=v1"],cwd:worktree.path)
                        result["variant"] = variant; result["repetition"] = repetition; result["commit"] = commit; result["command"] = command
                        result["configuredChanges"] = baselineStatus.split(separator:"\n").map(String.init)
                        result["changedFiles"] = status.output.split(separator:"\n").map(String.init)
                        result["diffStat"] = diff.output
                        if agent == nil { result["tokens"] = NSNull(); result["tokensAvailable"] = false }
                        results.append(result)
                        evaluation["results"] = results; evaluation = try store.put("eval",evaluation)
                    } catch {
                        let cleanup = try? AutomationProcess.git(["worktree","remove","--force",worktree.path],cwd:root)
                        if cleanup?.exitCode != 0 { cleanupFailures.append(worktree.path) }
                        throw error
                    }
                    let removed = try AutomationProcess.git(["worktree","remove","--force",worktree.path],cwd:root)
                    if removed.exitCode != 0 { cleanupFailures.append(worktree.path) }
                }
            }
            evaluation["state"] = "completed"
        } catch {
            evaluation["state"] = "failed"; evaluation["error"] = error.localizedDescription
        }
        let afterStatus = try? AutomationProcess.git(["status","--porcelain=v1"],cwd:root).output
        evaluation["originalGitStatusUnchanged"] = afterStatus == originalStatus
        evaluation["originalWorktreeUnchanged"] = NSNull() // Status equality is not a file-content snapshot.
        evaluation["results"] = results; evaluation["completedAt"] = isoNow(); evaluation["cleanupFailures"] = cleanupFailures
        evaluation["summary"] = agent == nil ? evaluationSummary(results) : agentEvaluationSummary(results,expectedRepetitions:repetitions)
        if agent != nil { evaluation["analysisVersion"] = "codex-test-observation-v3" }
        evaluation["tokensAvailable"] = agent != nil && !results.isEmpty && results.allSatisfy { $0["tokensAvailable"] as? Bool == true }
        if cleanupFailures.isEmpty {
            // Only this evaluation's known temporary directory is eligible for cleanup.
            try? FileManager.default.removeItem(at:tempRoot)
        }
        evaluation = try store.put("eval",evaluation)
        return ["exitCode":string(evaluation,"state") == "completed" ? 0 : 1,"output":string(evaluation,"error","Paired evaluation completed"),"evaluation":evaluation,"durationMs":results.reduce(0) {$0+intValue($1,"durationMs")}]
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
