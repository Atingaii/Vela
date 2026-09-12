import Foundation

public final class AutomationService {
    let store: VelaStore
    let files: SafeApplyService
    let lock = NSRecursiveLock()
    let readTools: Set<String> = ["git.status", "git.diff", "git.log"]
    let executableTools: Set<String> = ["shell.test", "shell.typecheck", "agent.run"]
    var appStartHandled = Set<String>()

    public init(store: VelaStore) {
        self.store = store
        files = SafeApplyService(store: store)
        try? files.recoverInterrupted()
        // Executing approvals are intentionally not retried after a crash: external side effects
        // may already have happened. The ledger keeps the uncertain result visible for review.
    }

    public func handle(_ method: String, _ params: JSON) throws -> Any? {
        lock.lock(); defer { lock.unlock() }
        switch method {
        case "workflows.list": return try store.list("workflow", project: checkedProject(params))
        case "workflows.save": return try saveWorkflow(params)
        case "workflows.run": return try startWorkflow(id: requireString(params,"id"), dryRun: params["dryRun"] as? Bool ?? true)
        case "workflows.health": return try workflowHealth(params)
        case "workflows.replay": return try replay(params)
        case "runs.list": return try store.list("run", project: checkedProject(params))
        case "runs.get": return try object("run", requireString(params,"id"))
        case "inbox.list": return try store.list("approval").filter { ["pending","executing","needs_review"].contains(string($0,"state")) }
        case "approvals.decide": return try decideApproval(params)
        case "improve.analyze": return try analyze(params)
        case "improve.list": return try store.list("suggestion", project: checkedProject(params))
        case "improve.preview": return try previewSuggestion(params)
        case "improve.apply": return try applySuggestion(params)
        case "improve.undo": return try undoSuggestion(params)
        case "improve.dismiss":
            var suggestion = try object("suggestion", requireString(params,"id"))
            suggestion["state"] = "dismissed"; return try store.put("suggestion",suggestion)
        case "lab.list": return try store.list("eval", project: checkedProject(params)).map(currentEvaluation)
        case "lab.run": return try createEvaluation(params)
        case "lab.compare": return currentEvaluation(try object("eval", requireString(params,"id")))
        case "lab.promote": return try promoteEvaluation(params)
        case "reuse.preview": return try previewReuseHook(params)
        case "reuse.context": return try hookContext(params)
        case "reuse.outcomes": return try reuseOutcomes(params)
        case "evidence.get": return try evidence(params)
        default: return nil
        }
    }

    func object(_ kind: String, _ id: String) throws -> JSON {
        guard let result = try store.get(kind,id) else { throw VelaError("\(kind) not found") }; return result
    }
    func project(_ raw: String) throws -> String {
        guard raw.hasPrefix("/"), raw.count < 4096 else { throw VelaError("An absolute registered project is required") }
        let value = canonicalProject(raw)
        var directory: ObjCBool = false
        guard value != "/", FileManager.default.fileExists(atPath:value,isDirectory:&directory), directory.boolValue else { throw VelaError("Project directory is unavailable") }
        let known = try store.list("project",limit:1000)
        guard known.contains(where: { row in
            [string(row,"path"),string(row,"root"),string(row,"project")].filter { !$0.isEmpty }.contains { canonicalProject($0) == value }
        }) else { throw VelaError("Register this project before allowing automation") }
        return value
    }

    func saveWorkflow(_ params: JSON) throws -> JSON {
        let title = try requireString(params,"title")
        guard title.count <= 240 else { throw VelaError("Workflow title exceeds 240 characters") }
        let root = try project(requireString(params,"project"))
        let trigger = string(params,"trigger","manual")
        let triggers = ["manual","cron","app_start","session_completed","agent_finished","git_event","usage_reset"]
        guard triggers.contains(trigger) else { throw VelaError("Unsupported workflow trigger") }
        let cron = string(params,"cron")
        if trigger == "cron" { try VelaCron.validate(cron) }
        guard let rawSteps = params["steps"] as? [JSON], !rawSteps.isEmpty, rawSteps.count <= 40 else { throw VelaError("Workflow requires 1–40 steps") }
        let steps = try rawSteps.enumerated().map { index, step -> JSON in
            let tool = try requireString(step,"tool")
            guard readTools.contains(tool) || executableTools.contains(tool) || tool == "file.write" else { throw VelaError("Unsupported tool: \(tool). External providers are not connected.") }
            let args = step["arguments"] as? JSON ?? [:]
            try validateTool(tool, arguments:args, project:root, resolve:false)
            return ["id": string(step,"id",UUID().uuidString.lowercased()),"title":string(step,"title","Step \(index+1)"),"tool":tool,"arguments":args]
        }
        let id = string(params,"id",UUID().uuidString.lowercased())
        let prior = try store.get("workflow",id)
        let version = (prior.map { intValue($0,"version") } ?? 0) + 1
        var workflow: JSON = ["id":id,"title":title,"project":root,"description":string(params,"description"),"trigger":trigger,"cron":cron,"enabled":params["enabled"] as? Bool ?? false,"steps":steps,"guidelines":params["guidelines"] as? [String] ?? [],"version":version,"state":"active"]
        workflow["content"] = try workflowMarkdown(workflow)
        var snapshot = workflow; snapshot["id"] = "\(id).v\(version)"
        _ = try store.put("workflow_version",snapshot)
        return try store.put("workflow",workflow)
    }

    func workflowMarkdown(_ workflow: JSON) throws -> String {
        let metadata: JSON = ["id":string(workflow,"id"),"version":intValue(workflow,"version"),"scope":["project":string(workflow,"project")],"trigger":["type":string(workflow,"trigger"),"cron":string(workflow,"cron")],"guidelines":workflow["guidelines"] ?? [],"approval":["writes":"confirm"],"steps":workflow["steps"] ?? []]
        return "---\n" + (try jsonString(metadata)) + "\n---\n\n" + string(workflow,"description") + "\n\n" + ((workflow["steps"] as? [JSON]) ?? []).enumerated().map { index, step in "\(index+1). **\(string(step,"title"))** — `\(string(step,"tool"))`" }.joined(separator:"\n")
    }

    func loadCurrentWorkflow(_ id: String) throws -> JSON {
        let stored = try object("workflow",id)
        let path = try requireString(stored,"assetPath")
        let text = try String(contentsOfFile:path,encoding:.utf8)
        guard let heading = text.range(of:" -->\n\n# "), let bodyStart = text.range(of:"\n\n",range:heading.upperBound..<text.endIndex) else { throw VelaError("Workflow Markdown header is invalid; repair the asset before running") }
        let body = String(text[bodyStart.upperBound...])
        guard body.hasPrefix("---\n"), let end = body.range(of:"\n---",range:body.index(body.startIndex,offsetBy:4)..<body.endIndex) else { throw VelaError("Workflow requires JSON frontmatter between --- delimiters (JSON is the supported YAML subset)") }
        let data = Data(body[body.index(body.startIndex,offsetBy:4)..<end.lowerBound].utf8)
        guard let definition = try JSONSerialization.jsonObject(with:data) as? JSON,
              let steps = definition["steps"] as? [JSON], let scope = definition["scope"] as? JSON,
              let trigger = definition["trigger"] as? JSON else { throw VelaError("Workflow frontmatter is invalid") }
        guard string(definition,"id") == id, canonicalProject(string(scope,"project")) == string(stored,"project") else { throw VelaError("Editing workflow identity or project in Markdown is not allowed; save a new workflow") }
        let structureChanged = try jsonString(steps) != jsonString(stored["steps"] ?? [])
            || string(trigger,"type") != string(stored,"trigger") || string(trigger,"cron") != string(stored,"cron")
            || jsonString(definition["guidelines"] ?? []) != jsonString(stored["guidelines"] ?? [])
        if structureChanged || stored["humanEdited"] as? Bool == true {
            return try saveWorkflow(["id":id,"title":string(stored,"title"),"project":string(stored,"project"),"description":string(stored,"description"),"steps":steps,"trigger":string(trigger,"type","manual"),"cron":string(trigger,"cron"),"enabled":stored["enabled"] ?? false,"guidelines":definition["guidelines"] ?? []])
        }
        return stored
    }

    func validateTool(_ tool: String, arguments: JSON, project: String, resolve: Bool) throws {
        if readTools.contains(tool) { return }
        if executableTools.contains(tool) {
            _ = try requireString(arguments,"executable")
            if arguments["args"] != nil && !(arguments["args"] is [String]) { throw VelaError("Command args must be strings") }
            if resolve { _ = try AutomationProcess.command(arguments) }
            return
        }
        if tool == "file.write" {
            let path = try requireString(arguments,"path")
            guard arguments["content"] is String else { throw VelaError("file.write content must be a string") }
            _ = try safeWorkflowPath(path, project:project)
            return
        }
        throw VelaError("Unsupported tool: \(tool)")
    }

    func safeWorkflowPath(_ raw: String, project: String) throws -> String {
        guard !raw.contains("\0"), !raw.split(separator:"/").contains("..") else { throw VelaError("Unsafe target path") }
        let root = canonicalProject(project)
        let path = automationPath(raw,project:root)
        guard path.hasPrefix(root + "/"), !path.split(separator:"/").contains(".git") else { throw VelaError("Target must be inside the selected project") }
        return path
    }

    func freezeArguments(tool: String, arguments: JSON, project: String) throws -> JSON {
        var frozen = arguments
        if executableTools.contains(tool) {
            let command = try AutomationProcess.command(arguments)
            frozen["executable"] = command[0]; frozen["args"] = Array(command.dropFirst())
            frozen.removeValue(forKey:"arguments")
        } else if tool == "file.write" {
            let path = try safeWorkflowPath(requireString(arguments,"path"),project:project)
            frozen["path"] = path
            // This is an approval snapshot only. The descriptor based writer verifies again.
            if FileManager.default.fileExists(atPath:path) {
                guard canonicalProject(path) == path else { throw VelaError("Refusing symlink target") }
                let data = try Data(contentsOf:URL(fileURLWithPath:path),options:.mappedIfSafe)
                guard data.count <= 2_097_152, let text = String(data:data,encoding:.utf8) else { throw VelaError("Target is too large or not UTF-8") }
                frozen["baseHash"] = stableHash(text)
            } else { frozen["baseHash"] = "absent" }
        }
        return frozen
    }

    func startWorkflow(id: String, dryRun: Bool, snapshot: JSON? = nil, replayOf: String? = nil) throws -> JSON {
        let workflow = try snapshot ?? loadCurrentWorkflow(id)
        let root = try project(requireString(workflow,"project"))
        let frozenSteps = (workflow["steps"] as? [JSON] ?? []).map { step -> JSON in var copy = step; copy["state"] = "queued"; return copy }
        var run: JSON = ["title":string(workflow,"title"),"project":root,"workflowId":id,"workflowVersion":intValue(workflow,"version"),"workflowSnapshot":workflow,"state":"running","steps":frozenSteps,"startedAt":isoNow(),"startedEpoch":Date().timeIntervalSince1970,"dryRun":dryRun,"guidelinesUsed":[],"memoryUsed":[],"inputs":[:],"durationMs":0]
        var guidelines: [JSON] = []
        for id in workflow["guidelines"] as? [String] ?? [] {
            if let guideline = try store.get("guideline",id), guideline["private"] as? Bool != true, string(guideline,"project") == root || string(guideline,"scope") == "global" { guidelines.append(guideline) }
        }
        run["guidelinesUsed"] = guidelines
        run["guidelineUseMode"] = "snapshot_only_not_injected"
        if let replayOf { run["replayOf"] = replayOf }
        run = try store.put("run",run)
        return try continueRun(run)
    }

    func continueRun(_ source: JSON) throws -> JSON {
        var run = source
        var steps = run["steps"] as? [JSON] ?? []
        let root = try project(requireString(run,"project"))
        let dryRun = run["dryRun"] as? Bool ?? true
        for index in steps.indices where string(steps[index],"state") == "queued" {
            let tool = string(steps[index],"tool")
            let args = steps[index]["arguments"] as? JSON ?? [:]
            do {
                if dryRun && !readTools.contains(tool) {
                    steps[index]["state"] = "stubbed"
                    steps[index]["output"] = "Would execute \(tool). No side effect was performed."
                    steps[index]["durationMs"] = 0
                } else if !readTools.contains(tool) {
                    let frozen = try freezeArguments(tool:tool,arguments:args,project:root)
                    let approval = try createApproval(title:string(steps[index],"title"),tool:tool,arguments:frozen,project:root,runId:string(run,"id"),stepIndex:index)
                    steps[index]["state"] = "pending_approval"; steps[index]["approvalId"] = approval["id"]
                    run["steps"] = steps; run["state"] = "pending_approval"
                    return try store.put("run",run)
                } else {
                    let result = try executeTool(tool,arguments:args,project:root)
                    steps[index].merge(result) { _, new in new }
                    steps[index]["state"] = intValue(result,"exitCode") == 0 ? "completed" : "failed"
                    if string(steps[index],"state") == "failed" { run["state"] = "failed"; break }
                }
            } catch {
                steps[index]["state"] = "failed"; steps[index]["output"] = error.localizedDescription
                run["state"] = "failed"; break
            }
            run["steps"] = steps; run = try store.put("run",run)
        }
        run["steps"] = steps
        if string(run,"state") != "failed" { run["state"] = "completed" }
        run["completedAt"] = isoNow()
        run["durationMs"] = steps.reduce(0) { $0 + intValue($1,"durationMs") }
        return try store.put("run",run)
    }

    func executeTool(_ tool: String, arguments: JSON, project: String) throws -> JSON {
        switch tool {
        case "git.status": return try AutomationProcess.git(["status","--porcelain=v1","--untracked-files=normal"],cwd:project).json
        case "git.diff": return try AutomationProcess.git(["diff","--no-ext-diff","--no-textconv","--stat","HEAD"],cwd:project).json
        case "git.log": return try AutomationProcess.git(["log","-10","--format=%h %s"],cwd:project).json
        case "shell.test","shell.typecheck","agent.run":
            let command = try AutomationProcess.command(arguments)
            let timeout = (arguments["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 120
            var result = try AutomationProcess.run(command,cwd:project,timeout:timeout).json
            result["command"] = command; result["evaluator"] = tool == "agent.run" ? "user_selected_agent_cli" : "deterministic_command"
            return result
        case "file.write":
            let began = Date()
            let journal = try files.apply(project:project,operations:[arguments])
            return ["exitCode":0,"output":"Wrote \(string(arguments,"path"))","journalId":string(journal,"id"),"durationMs":Int(Date().timeIntervalSince(began)*1000)]
        case "lab.execute": return try executeEvaluation(arguments)
        default: throw VelaError("Unsupported external tool: \(tool)")
        }
    }

    func frozenPayload(_ approval: JSON) -> JSON {
        ["tool":string(approval,"tool"),"arguments":approval["arguments"] ?? [:],"project":string(approval,"project"),"runId":string(approval,"runId"),"stepIndex":intValue(approval,"stepIndex")]
    }

    func createApproval(title: String, tool: String, arguments: JSON, project: String, runId: String, stepIndex: Int) throws -> JSON {
        var approval: JSON = ["title":title,"tool":tool,"arguments":arguments,"project":project,"runId":runId,"stepIndex":stepIndex,"state":"pending"]
        approval["snapshotHash"] = stableHash(try jsonString(frozenPayload(approval)))
        return try store.put("approval",approval)
    }

    func decideApproval(_ params: JSON) throws -> JSON {
        var approval = try object("approval",requireString(params,"id"))
        guard string(approval,"state") == "pending" else { throw VelaError("This action was already decided or started. It will not execute again.") }
        let provided = try requireString(params,"snapshotHash")
        let actual = stableHash(try jsonString(frozenPayload(approval)))
        guard actual == provided, actual == string(approval,"snapshotHash") else { throw VelaError("Approval snapshot changed; review the frozen action again") }
        let decision = try requireString(params,"decision")
        guard ["approve","reject"].contains(decision) else { throw VelaError("Decision must be approve or reject") }
        approval["decidedAt"] = isoNow()
        let tool = string(approval,"tool")
        if decision == "reject" {
            guard let claimed = try store.claimState(kind:"approval",id:string(approval,"id"),expected:"pending",newState:"rejected",fields:["decidedAt":isoNow()]) else { throw VelaError("Another process already decided this approval") }
            approval = claimed
            if tool == "lab.execute" {
                var evaluation = try object("eval",string(approval,"runId")); evaluation["state"] = "rejected"; _ = try store.put("eval",evaluation)
            } else {
                var run = try object("run",string(approval,"runId")); var steps = run["steps"] as? [JSON] ?? []
                let index = intValue(approval,"stepIndex")
                if steps.indices.contains(index) { steps[index]["state"] = "rejected" }
                run["steps"] = steps; run["state"] = "rejected"; _ = try store.put("run",run)
            }
            return approval
        }
        let root = try project(requireString(approval,"project"))
        if tool != "lab.execute" {
            let run = try object("run",string(approval,"runId"))
            let steps = run["steps"] as? [JSON] ?? []; let index = intValue(approval,"stepIndex")
            guard string(run,"state") == "pending_approval", steps.indices.contains(index), string(steps[index],"state") == "pending_approval", string(steps[index],"approvalId") == string(approval,"id") else { throw VelaError("The frozen action is no longer the pending step in this run") }
        }
        guard let claimed = try store.claimState(kind:"approval",id:string(approval,"id"),expected:"pending",newState:"executing",fields:["decidedAt":isoNow()]) else { throw VelaError("Another process already started or rejected this action") }
        approval = claimed
        guard stableHash(try jsonString(frozenPayload(approval))) == provided, string(approval,"snapshotHash") == provided else {
            approval["state"] = "needs_review"; _ = try store.put("approval",approval)
            throw VelaError("Approval changed while it was being claimed; no action was executed")
        }
        let result: JSON
        do {
            result = try executeTool(tool,arguments:approval["arguments"] as? JSON ?? [:],project:root)
            approval["state"] = intValue(result,"exitCode") == 0 ? "executed" : "failed"
            approval["result"] = result
        } catch {
            result = ["exitCode":-1,"output":error.localizedDescription]
            approval["state"] = "failed"; approval["result"] = result
            if tool == "lab.execute", var evaluation = try? object("eval",string(approval,"runId")) { evaluation["state"] = "failed"; evaluation["error"] = error.localizedDescription; _ = try? store.put("eval",evaluation) }
        }
        approval["completedAt"] = isoNow(); approval = try store.put("approval",approval)
        if tool != "lab.execute" {
            var run = try object("run",string(approval,"runId")); var steps = run["steps"] as? [JSON] ?? []
            let index = intValue(approval,"stepIndex")
            guard steps.indices.contains(index), string(steps[index],"approvalId") == string(approval,"id") else { throw VelaError("Run no longer matches the approved action; inspect the action ledger") }
            steps[index].merge(result) { _,new in new }
            steps[index]["state"] = string(approval,"state") == "executed" ? "completed" : "failed"
            run["steps"] = steps; run["state"] = string(approval,"state") == "executed" ? "running" : "failed"
            if string(run,"state") == "failed" { run["completedAt"] = isoNow(); run["durationMs"] = steps.reduce(0) {$0+intValue($1,"durationMs")} }
            run = try store.put("run",run)
            if string(run,"state") == "running" { run = try continueRun(run) }
            approval["run"] = run
        }
        return approval
    }

    func replay(_ params: JSON) throws -> JSON {
        let previous = try object("run",requireString(params,"runId"))
        guard let workflow = previous["workflowSnapshot"] as? JSON else { throw VelaError("This run has no frozen workflow snapshot") }
        return try startWorkflow(id:string(previous,"workflowId"),dryRun:true,snapshot:workflow,replayOf:string(previous,"id"))
    }

    func workflowHealth(_ params: JSON) throws -> JSON {
        let id = string(params,"id")
        let runs = try store.list("run",limit:10000).filter { (id.isEmpty || string($0,"workflowId") == id) && $0["dryRun"] as? Bool != true }
        let finished = runs.filter { ["completed","failed","rejected"].contains(string($0,"state")) }
        let successful = finished.filter { string($0,"state") == "completed" }.count
        let approvals = try store.list("approval",limit:10000).filter { row in runs.contains { string($0,"id") == string(row,"runId") } }
        return ["workflowId":id,"runs":runs.count,"completedRuns":finished.count,"successes":successful,"failures":finished.filter {string($0,"state") == "failed"}.count,"successRate":finished.isEmpty ? NSNull() : Double(successful)/Double(finished.count),"averageDurationMs":finished.isEmpty ? NSNull() : Double(finished.reduce(0) {$0+intValue($1,"durationMs")})/Double(finished.count),"approvalRejected":approvals.filter {string($0,"state") == "rejected"}.count,"tokens":NSNull(),"tokensAvailable":false,"guidelineInfluence":"not_measured"]
    }

    func evidence(_ params: JSON) throws -> JSON {
        let id = try requireString(params,"id")
        for kind in ["memory","signal","cluster","suggestion","run","eval","workflow","session","approval"] {
            if let result = try store.get(kind,id) {
                var references: [JSON] = result["evidence"] as? [JSON] ?? []
                if let session = result["sourceSession"] as? String { references.append(["kind":"session","id":session]) }
                if let run = result["runId"] as? String { references.append(["kind":"run","id":run]) }
                return ["object":kind == "eval" ? currentEvaluation(result) : result,"references":references]
            }
        }
        throw VelaError("Evidence object not found")
    }
}
