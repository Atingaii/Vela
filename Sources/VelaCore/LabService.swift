import Foundation

extension AutomationService {
    func createEvaluation(_ params: JSON) throws -> JSON {
        let root = try project(requireString(params,"project"))
        let kind = try requireString(params,"kind")
        guard ["context","memory","workflow"].contains(kind) else { throw VelaError("Unknown evaluation kind") }
        guard let requestedCommand = params["command"] as? [String], !requestedCommand.isEmpty, requestedCommand.count <= 128, requestedCommand.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 64_000 }) else { throw VelaError("Lab requires an executable and argument array") }
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
        var evaluation: JSON = ["title":string(params,"title","Paired evaluation"),"evaluationKind":kind,"project":root,"state":"pending_approval","evaluator":"deterministic_command","command":command,"timeoutSeconds":timeout,"repetitions":repetitions,"commit":commit,"baseline":baseline,"candidate":candidate,"results":[],"limitations":["Commands run in separate Git worktrees, not an operating system sandbox.","Only committed repository files are copied. Dependencies may need explicit setup.","Task success means command exit status, not an independently assessed model outcome."],"tokensAvailable":false]
        evaluation = try store.put("eval",evaluation)
        let frozen: JSON = ["evalId":string(evaluation,"id"),"project":root,"commit":commit,"command":command,"timeoutSeconds":timeout,"repetitions":repetitions,"baseline":baseline,"candidate":candidate]
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
            guard !path.hasPrefix("/"), !path.split(separator:"/").contains(".."), path != ".git", !path.hasPrefix(".git/") else { throw VelaError("Evaluation files require relative paths inside the worktree") }
            guard let content = file["content"] as? String, content.utf8.count <= 1_048_576 else { throw VelaError("Evaluation file exceeds 1 MiB or is not text") }
            let normalized = URL(fileURLWithPath:project).appendingPathComponent(path).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { throw VelaError("Duplicate evaluation file") }
            return ["path":path,"content":content]
        }
        return ["files":validated,"label":string(input,"label")]
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
        evaluation["state"] = "running"; evaluation["startedAt"] = isoNow(); evaluation = try store.put("eval",evaluation)
        let tempRoot = store.root.appendingPathComponent("lab-worktrees/" + id)
        guard tempRoot.standardizedFileURL.path.hasPrefix(store.root.path + "/lab-worktrees/") else { throw VelaError("Invalid Lab workspace root") }
        try FileManager.default.createDirectory(at:tempRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var results: [JSON] = []
        var cleanupFailures: [String] = []
        let originalStatus = try AutomationProcess.git(["status","--porcelain=v1"],cwd:root).output
        do {
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
                            let path = worktree.appendingPathComponent(relative).path
                            let before = try? String(contentsOfFile:path,encoding:.utf8)
                            _ = try files.apply(project:worktree.path,operations:[["path":relative,"baseHash":before.map(stableHash) ?? "absent","content":string(change,"content")]])
                        }
                        let baselineStatus = try AutomationProcess.git(["status","--porcelain=v1"],cwd:worktree.path).output
                        var result = try AutomationProcess.run(command,cwd:worktree.path,timeout:timeout).json
                        let diff = try AutomationProcess.git(["diff","--no-ext-diff","--no-textconv","--stat",commit],cwd:worktree.path)
                        let status = try AutomationProcess.git(["status","--porcelain=v1"],cwd:worktree.path)
                        result["variant"] = variant; result["repetition"] = repetition; result["commit"] = commit; result["command"] = command
                        result["configuredChanges"] = baselineStatus.split(separator:"\n").map(String.init)
                        result["changedFiles"] = status.output.split(separator:"\n").map(String.init)
                        result["diffStat"] = diff.output
                        result["tokens"] = NSNull(); result["tokensAvailable"] = false
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
        evaluation["originalWorktreeUnchanged"] = afterStatus == originalStatus
        evaluation["results"] = results; evaluation["completedAt"] = isoNow(); evaluation["cleanupFailures"] = cleanupFailures
        evaluation["summary"] = evaluationSummary(results)
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
