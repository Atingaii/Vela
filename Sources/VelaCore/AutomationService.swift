import Foundation
import CoreFoundation

public final class AutomationService {
    let store: VelaStore
    let files: SafeApplyService
    let lock = NSRecursiveLock()
    let readTools: Set<String> = ["git.status", "git.diff", "git.log"]
    let executableTools: Set<String> = ["shell.test", "shell.typecheck", "agent.run"]
    var appStartHandled = Set<String>()
    let fileWatchEvents = WorkflowFileEvents()
    var compositionLeaseDepth = 0
    var connectorService: ConnectorService?
    /// Tests may inject a deterministic clock through the Core initializer.
    /// No renderer or RPC method can supply a clock.
    let approvalClock: () -> Date

    public init(store: VelaStore, recoverInterruptedFiles: Bool = true, approvalClock: @escaping () -> Date = Date.init) {
        self.store = store
        files = SafeApplyService(store: store)
        self.approvalClock = approvalClock
        if recoverInterruptedFiles { try? files.recoverInterrupted() }
        // Executing approvals are intentionally not retried after a crash: external side effects
        // may already have happened. The ledger keeps the uncertain result visible for review.
    }

    public func handle(_ method: String, _ params: JSON) throws -> Any? {
        lock.lock(); defer { lock.unlock() }
        switch method {
        case "workflows.list": return try store.list("workflow", project: checkedProject(params)).filter { params["includeArchived"] as? Bool == true || string($0,"state") != "archived" }
        case "workflows.save": return try saveWorkflow(params)
        case "workflows.get": return try inspectWorkflow(params)
        case "workflows.validate": return try validateWorkflows(params)
        case "workflows.clone": return try cloneWorkflow(params)
        case "workflows.setEnabled": return try setWorkflowEnabled(params)
        case "workflows.remove": return try archiveWorkflow(params)
        case "workflows.restore": return try restoreWorkflow(params)
        case "workflows.run":
            guard params["inputs"] == nil || params["inputs"] is JSON, params["stdin"] == nil || params["stdin"] is String else { throw VelaError("Workflow inputs must be an object and stdin must be text") }
            return try startWorkflow(id: requireString(params,"id"), dryRun: params["dryRun"] as? Bool ?? true, suppliedInputs:params["inputs"] as? JSON ?? [:], stdin:params["stdin"] as? String)
        case "workflows.health": return try workflowHealthReport(params)
        case "workflows.health.proposeTimeout", "workflows.health.proposal.get", "workflows.health.proposal.list", "workflows.health.proposal.decide": return try workflowHealthProposal(method,params)
        case "watches.describe": return ["protocol":WorkflowWatch.version,"sources":["tool","files"],"tools":try AgentLoop.builtinIDs.map(AgentLoop.builtin),"externalToolsSupported":false,"minimumIntervalSeconds":30,"fileEvents":"macOS FSEvents with bounded SHA256 observations"]
        case "watches.get": return try watchDetails(params)
        case "watches.preview": return try previewWatch(params)
        case "workflows.replay": return try replay(params)
        case "replay.describe","replay.fixtures.inspect","replay.fixtures.capture","replay.fixtures.get","replay.fixtures.list","replay.fixtures.forget","replay.fixtures.prune","replay.create","replay.get","replay.list","replay.cancel","replay.review","replay.results": return try handleWorkflowReplay(method,params)
        case "ask.describe","ask.create","ask.followup","ask.get","ask.list","ask.cancel","ask.citations": return try handleKnowledgeQuery(method,params)
        case "ask.route","ask.route.get","ask.route.list","ask.route.propose","ask.route.proposal.get": return try handleAskRoute(method,params)
        case "loops.describe": return ["protocol":AgentLoop.protocolVersion,"builtinTools":try AgentLoop.builtinIDs.map(AgentLoop.builtin),"connectorAccess":"queued_approval_only"]
        case "loops.plan": return try createAgentLoop(params)
        case "loops.get": return try agentLoop(params)
        case "loops.cancel": return try cancelAgentLoop(params)
        case "loops.list": return try store.runtimeSummaries("agent_loop",project:project(requireString(params,"project"))).map { $0.filter { ["id","title","project","state","runId","approvalId","createdAt","updatedAt","modelCalls"].contains($0.key) } }
        case "workflows.plan": return try createWorkflowPlan(params)
        case "workflows.plan.get": return try workflowPlan(params)
        case "workflows.plan.list":
            let root = try project(requireString(params,"project"))
            return try store.list("workflow_plan",project:root,limit:100).map {
                try workflowPlan(["id":string($0,"id"),"project":root]).filter { ["id","title","project","state","planHash","runId","approvalId","createdAt","updatedAt","questions","unresolved"].contains($0.key) }
            }
        case "workflows.plan.cancel": return try cancelWorkflowPlan(params)
        case "runs.list": return try store.list("run", project: checkedProject(params)).map { row -> JSON in
            var summary = row
            summary.removeValue(forKey:"compositionDefinitions")
            if var delivery = summary["outputDelivery"] as? JSON { delivery.removeValue(forKey:"content"); summary["outputDelivery"] = delivery }
            if let output = summary["output"] as? String, output.utf8.count > 2048 {
                summary.removeValue(forKey:"output"); summary["outputPreview"] = String(output.prefix(512)); summary["outputTruncated"] = true
            }
            return summary
        }
        case "runs.get": return try object("run", requireString(params,"id"))
        case "runs.feedback.prepare", "runs.feedback.record", "runs.feedback.list", "runs.feedback.get", "runs.feedback.history.list", "runs.feedback.history.get": return try runFeedback(method,params)
        case "runs.resume": return try resumeComposition(params)
        case "outputs.list", "outputs.inbox":
            let selected = try project(requireString(params,"project"))
            return try store.list("run_output",project:selected,limit:100).filter { method != "outputs.inbox" || (string($0,"state") == "delivered" && $0["unread"] as? Bool == true) }.map { $0.filter { $0.key != "content" } }
        case "outputs.get", "outputs.markRead":
            let selected = try project(requireString(params,"project"))
            var output = try object("run_output",requireString(params,"id"))
            guard string(output,"project") == selected else { throw VelaError("Output belongs to another project") }
            if method == "outputs.markRead" { output["unread"] = false; output = try store.put("run_output",output) }
            return output
        case "inbox.list":
            guard params.isEmpty || Set(params.keys) == Set(["project"]) else { throw VelaError("Unsupported inbox parameter") }
            let selected = params["project"] == nil ? nil : try project(requireString(params,"project"))
            return try store.list("approval").compactMap { raw -> JSON? in
                let approval = try approvalRecord(string(raw,"id"))
                guard ["pending","executing","needs_review"].contains(string(approval,"state")) else { return nil }
                // Existing global Inbox callers retain their non-Ask approvals. Ask
                // proposals must opt into a registered project so their frozen
                // evidence cannot cross the global project boundary.
                if string(approval,"tool") == "ask.route.proposal.execute" { return selected != nil && string(approval,"project") == selected ? askRouteInboxApproval(approval) : nil }
                return selected == nil || string(approval,"project") == selected ? askRouteInboxApproval(approval) : nil
            }
        case "approvals.get": return try approvalGet(params)
        case "approvals.list": return try approvalList(params)
        case "approvals.decide": return try decideApproval(params)
        case "improve.analyze": return try analyze(params)
        case "improve.model.plan": return try createModelImprovement(params)
        case "improve.model.describe": return describeModelImprovement()
        case "improve.model.list": return try listModelImprovements(params)
        case "improve.model.get": return try modelImprovement(params)
        case "improve.model.transition": return try transitionModelSuggestion(params)
        case "connectors.status", "connectors.configure", "connectors.forget", "connectors.tools.list", "connectors.tools.search", "connectors.tools.get", "connectors.toolkits.list", "connectors.accounts.list", "connectors.authConfigs.list": return try connector().handle(method,params)
        case "connectors.action.plan": return try createConnectorAction(params)
        case "connectors.action.preview": return try createConnectorAction(params,dryRun:true)
        case "connectors.action.get": return try connectorAction(params)
        case "connectors.action.resolve": return try acknowledgeConnectorAction(params)
        case "connectors.action.list": return try store.list("connector_action",project:project(requireString(params,"project")),limit:100).map { try connectorAction(["project":string($0,"project"),"id":string($0,"id")]).filter { ["id","project","state","requestHash","runId","approvalId","createdAt","completedAt"].contains($0.key) } }
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

    func saveWorkflow(_ params: JSON, validatingDependencies: Bool = true, persist: Bool = true, allowArchived: Bool = false) throws -> JSON {
        let title = try requireString(params,"title")
        guard title.count <= 240 else { throw VelaError("Workflow title exceeds 240 characters") }
        let root = try project(requireString(params,"project"))
        let trigger = string(params,"trigger","manual")
        let triggers = ["manual","cron","app_start","session_completed","agent_finished","git_event","usage_reset","watch"]
        guard triggers.contains(trigger) else { throw VelaError("Unsupported workflow trigger") }
        let cron = string(params,"cron")
        if trigger == "cron" { try VelaCron.validate(cron) }
        guard params["guidelines"] == nil || params["guidelines"] is [String] else { throw VelaError("Workflow guidelines must be an array of IDs") }
        let guidelineIDs = params["guidelines"] as? [String] ?? []
        guard guidelineIDs.count <= 32, Set(guidelineIDs).count == guidelineIDs.count,
              guidelineIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 }) else { throw VelaError("Invalid or duplicate workflow guideline IDs") }
        let pipeline = try WorkflowComposition.stages(params["pipeline"])
        guard params["steps"] == nil || params["steps"] is [JSON] else { throw VelaError("Workflow steps must be an array") }
        let rawSteps = params["steps"] as? [JSON] ?? []
        guard pipeline == nil ? (!rawSteps.isEmpty && rawSteps.count <= 40) : (rawSteps.isEmpty && params["context"] == nil && guidelineIDs.isEmpty) else { throw VelaError("Use either 1–40 steps or a pipeline without its own context/guidelines") }
        let steps = try rawSteps.enumerated().map { index, step -> JSON in
            let tool = try requireString(step,"tool")
            guard readTools.contains(tool) || executableTools.contains(tool) || ["file.write","connector.call","agent.loop"].contains(tool) else { throw VelaError("Unsupported tool: \(tool)") }
            let args = step["arguments"] as? JSON ?? [:]
            try validateTool(tool, arguments:args, project:root, resolve:false)
            var normalized: JSON = ["id": string(step,"id",UUID().uuidString.lowercased()),"title":string(step,"title","Step \(index+1)"),"tool":tool,"arguments":args]
            if step["retry"] != nil { normalized["retry"] = try WorkflowRetry.policy(step:step,tool:tool).json }
            return normalized
        }
        let id = string(params,"id",UUID().uuidString.lowercased())
        let prior = try persist ? store.get("workflow",id) : store.workflowRecord(id)
        guard prior == nil || string(prior!,"project") == root else { throw VelaError("Workflow cannot be moved between project scopes") }
        guard allowArchived || prior == nil || string(prior!,"state") != "archived" else { throw VelaError("Restore the archived workflow before editing it") }
        let version = (prior.map { intValue($0,"version") } ?? 0) + 1
        var workflow: JSON = ["id":id,"title":title,"project":root,"description":string(params,"description"),"trigger":trigger,"cron":cron,"enabled":params["enabled"] as? Bool ?? false,"steps":steps,"guidelines":params["guidelines"] as? [String] ?? [],"version":version,"state":"active"]
        workflow.merge(try VelaSchedulePolicy.validate(params)) { _,new in new }
        if trigger == "watch" { workflow["watch"] = try WorkflowWatch.validate(params["watch"]) }
        else if params["watch"] != nil { throw VelaError("A watch definition requires trigger watch") }
        if let context = try WorkflowContext.validate(params["context"],steps:steps) { workflow["context"] = context }
        if let pipeline { workflow["pipeline"] = pipeline }
        if let output = try WorkflowComposition.output(params["output"],steps:steps,scheduled:trigger != "manual") { workflow["output"] = output }
        else if pipeline != nil { workflow["output"] = ["target":trigger == "manual" ? "stdout" : "inbox"] }
        if let markdownBody = params["markdownBody"] as? String {
            guard markdownBody.utf8.count <= 128 * 1024 else { throw VelaError("Workflow Markdown body is too large") }
            workflow["markdownBody"] = markdownBody
        } else if let markdownBody = prior?["markdownBody"] { workflow["markdownBody"] = markdownBody }
        if let source = prior?["clonedFrom"] { workflow["clonedFrom"] = source }
        if validatingDependencies && WorkflowComposition.isComposite(workflow) { _ = try compositionDefinitions(workflow,synchronizingAssets:persist) }
        workflow["content"] = try workflowMarkdown(workflow)
        var snapshot = workflow; snapshot["id"] = "\(id).v\(version)"
        guard persist else { return workflow }
        let expected = try prior.map { [("workflow",id,stableHash(try jsonString($0)))] } ?? []
        return try store.putBatch([("workflow_version",snapshot),("workflow",workflow)],expecting:expected,expectingAbsent:prior == nil ? [("workflow",id),("workflow_version",string(snapshot,"id"))] : [("workflow_version",string(snapshot,"id"))])[1]
    }

    func workflowMarkdown(_ workflow: JSON) throws -> String {
        var metadata: JSON = ["id":string(workflow,"id"),"version":intValue(workflow,"version"),"scope":["project":string(workflow,"project")],"trigger":["type":string(workflow,"trigger"),"cron":string(workflow,"cron")],"guidelines":workflow["guidelines"] ?? [],"approval":["writes":"confirm"],"steps":workflow["steps"] ?? []]
        metadata["schedule"] = workflow.filter { ["timeZone","catchUp","catchUpLimit","catchUpWindowHours"].contains($0.key) }
        if let watch = workflow["watch"] { metadata["watch"] = watch }
        if let context = workflow["context"] { metadata["context"] = context }
        if let pipeline = workflow["pipeline"] { metadata["pipeline"] = pipeline }
        if let output = workflow["output"] { metadata["output"] = output }
        let body = workflow["markdownBody"] as? String ?? ("\n\n" + string(workflow,"description") + "\n\n" + ((workflow["steps"] as? [JSON]) ?? []).enumerated().map { index, step in "\(index+1). **\(string(step,"title"))** — `\(string(step,"tool"))`" }.joined(separator:"\n"))
        return "---\n" + (try jsonString(metadata)) + "\n---" + body

    }

    func loadCurrentWorkflow(_ id: String, validatingDependencies: Bool = true, synchronize: Bool = true) throws -> JSON {
        guard let stored = try store.workflowRecord(id) else { throw VelaError("Workflow not found") }
        guard string(stored,"state") != "archived" else { throw VelaError("Workflow is archived; restore it before use") }
        let relative = "assets/workflow/" + id + ".md"
        guard string(stored,"assetPath") == store.root.appendingPathComponent(relative).path,
              let text = try FoundationFile.readUTF8(root:store.root,path:relative) else { throw VelaError("Workflow Markdown asset is missing or unsafe") }
        guard let heading = text.range(of:" -->\n\n# "), let bodyStart = text.range(of:"\n\n",range:heading.upperBound..<text.endIndex) else { throw VelaError("Workflow Markdown header is invalid; repair the asset before running") }
        let title = String(text[heading.upperBound..<bodyStart.lowerBound])
        var body = String(text[bodyStart.upperBound...])
        if body.hasSuffix("\n") { body.removeLast() }
        guard body.hasPrefix("---\n"), let end = body.range(of:"\n---",range:body.index(body.startIndex,offsetBy:4)..<body.endIndex) else { throw VelaError("Workflow requires JSON frontmatter between --- delimiters (JSON is the supported YAML subset)") }
        let data = Data(body[body.index(body.startIndex,offsetBy:4)..<end.lowerBound].utf8)
        guard let definition = try JSONSerialization.jsonObject(with:data) as? JSON,
              let steps = definition["steps"] as? [JSON], let scope = definition["scope"] as? JSON,
              let trigger = definition["trigger"] as? JSON else { throw VelaError("Workflow frontmatter is invalid") }
        guard string(definition,"id") == id, canonicalProject(string(scope,"project")) == string(stored,"project") else { throw VelaError("Editing workflow identity or project in Markdown is not allowed; save a new workflow") }
        guard definition["schedule"] == nil || definition["schedule"] is JSON else { throw VelaError("Invalid workflow schedule policy") }
        let schedule = definition["schedule"] as? JSON ?? stored.filter { ["timeZone","catchUp","catchUpLimit","catchUpWindowHours"].contains($0.key) }
        let structureChanged = try jsonString(steps) != jsonString(stored["steps"] ?? [])
            || string(trigger,"type") != string(stored,"trigger") || string(trigger,"cron") != string(stored,"cron")
            || jsonString(definition["guidelines"] ?? []) != jsonString(stored["guidelines"] ?? [])
            || jsonString(["value":definition["context"] ?? NSNull()]) != jsonString(["value":stored["context"] ?? NSNull()])
            || jsonString(["value":definition["pipeline"] ?? NSNull()]) != jsonString(["value":stored["pipeline"] ?? NSNull()])
            || jsonString(["value":definition["output"] ?? NSNull()]) != jsonString(["value":stored["output"] ?? NSNull()])
            || jsonString(["value":definition["watch"] ?? NSNull()]) != jsonString(["value":stored["watch"] ?? NSNull()])
            || jsonString(schedule) != jsonString(stored.filter { ["timeZone","catchUp","catchUpLimit","catchUpWindowHours"].contains($0.key) })
        if structureChanged || body != string(stored,"content") || title != string(stored,"title") || stored["humanEdited"] as? Bool == true {
            var params: JSON = ["id":id,"title":title,"project":string(stored,"project"),"description":string(stored,"description"),"steps":steps,"trigger":string(trigger,"type","manual"),"cron":string(trigger,"cron"),"enabled":stored["enabled"] ?? false,"guidelines":definition["guidelines"] ?? []]
            params.merge(schedule) { _,new in new }
            if schedule.isEmpty { params["catchUp"] = "skip" }
            params["markdownBody"] = String(body[end.upperBound...])
            if let context = definition["context"] { params["context"] = context }
            if let pipeline = definition["pipeline"] { params["pipeline"] = pipeline }
            if let output = definition["output"] { params["output"] = output }
            if let watch = definition["watch"] { params["watch"] = watch }
            return try saveWorkflow(params,validatingDependencies:validatingDependencies,persist:synchronize)
        }
        if !synchronize {
            var definition = stored; definition["id"] = id
            _ = try saveWorkflow(definition,validatingDependencies:validatingDependencies,persist:false)
        }
        return stored
    }

    func validateTool(_ tool: String, arguments: JSON, project: String, resolve: Bool) throws {
        try WorkflowContext.validateCommand(tool,arguments)
        if tool == "agent.loop" { try AgentLoop.validateArguments(arguments); return }
        if tool == "connector.call" { try ConnectorService.validateWorkflowArguments(arguments); return }
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
        if tool == "agent.loop" { return try freezeLoopArguments(arguments,project:project) }
        var frozen = arguments
        if tool == "connector.call" {
            try ConnectorService.validateWorkflowArguments(arguments)
            let request = try connector().prepare(arguments.merging(["action":"tool","project":project]) { _,new in new })
            return ["request":request,"requestHash":stableHash(try jsonString(request))]
        } else if executableTools.contains(tool) {
            let command = try AutomationProcess.command(arguments)
            frozen["executable"] = command[0]; frozen["args"] = Array(command.dropFirst())
            frozen.removeValue(forKey:"arguments")
        } else if tool == "file.write" {
            let path = try safeWorkflowPath(requireString(arguments,"path"),project:project)
            frozen["path"] = path
            // Freeze the real bounded descriptor read; apply independently
            // checks the same base and file identity again after approval.
            let snapshot = try files.readSnapshot(project:project,path:path)
            frozen["baseHash"] = snapshot["hash"]

        }
        return frozen
    }

    func startWorkflow(id: String, dryRun: Bool, snapshot: JSON? = nil, replayOf: String? = nil, suppliedInputs: JSON = [:], stdin: String? = nil, ancestry: JSON? = nil) throws -> JSON {
        let workflow = try snapshot ?? loadCurrentWorkflow(id)
        let root = try project(requireString(workflow,"project"))
        if WorkflowComposition.isComposite(workflow) { return try startCompositeWorkflow(workflow,dryRun:dryRun,inputs:suppliedInputs,stdin:stdin,ancestry:ancestry) }
        if let runID = ancestry?["runId"] as? String, let existing = try store.get("run",runID) { return existing }
        guard workflow["context"] != nil || (suppliedInputs.isEmpty && stdin == nil) else { throw VelaError("Named inputs and stdin require an explicit workflow context") }
        let frozenSteps = (workflow["steps"] as? [JSON] ?? []).map { step -> JSON in var copy = step; copy["state"] = "queued"; return copy }
        var run: JSON = ["title":string(workflow,"title"),"project":root,"workflowId":id,"workflowVersion":intValue(workflow,"version"),"workflowSnapshot":workflow,"state":"running","steps":frozenSteps,"startedAt":isoNow(),"startedEpoch":Date().timeIntervalSince1970,"dryRun":dryRun,"guidelinesUsed":[],"memoryUsed":[],"inputs":[:],"durationMs":0]
        var guidelines: [JSON] = []
        for id in workflow["context"] == nil ? (workflow["guidelines"] as? [String] ?? []) : [] {
            if let guideline = try store.get("guideline",id), guideline["private"] as? Bool != true,
               string(guideline,"project") == root || (string(guideline,"scope") == "global" && string(guideline,"project").isEmpty) { guidelines.append(guideline) }
        }
        run["guidelinesUsed"] = guidelines
        run["guidelineUseMode"] = "snapshot_only_not_injected"
        if let replayOf { run["replayOf"] = replayOf }
        if let ancestry {
            run["id"] = ancestry["runId"]; run["parentRunId"] = ancestry["parentRunId"]; run["rootRunId"] = ancestry["rootRunId"]; run["outputMode"] = "memory"
            run["suppliedInputs"] = suppliedInputs; if let stdin { run["suppliedStdin"] = stdin }
            guard try store.insertIfAbsent("run",run) else { return try object("run",string(run,"id")) }
            run = try object("run",string(run,"id"))
        } else { run = try store.put("run",run) }
        if workflow["context"] != nil {
            do {
                _ = try WorkflowContext.validate(workflow["context"],steps:workflow["steps"] as? [JSON] ?? [])
                let context = try freezeWorkflowContext(workflow,supplied:suppliedInputs,stdin:stdin)
                run["contextSnapshot"] = context
                run["inputs"] = context?["inputs"]
                run["inputsUsed"] = context?["inputsUsed"]
                run["guidelinesUsed"] = context?["guidelinesUsed"]
                run["memoryUsed"] = context?["memoryUsed"]
                run["guidelineUseMode"] = "frozen_prompt_argv"
                run["degraded"] = context?["degraded"]
                run["steps"] = try frozenSteps.map { step -> JSON in
                    var copy = step
                    copy["arguments"] = try contextArguments(step["arguments"] as? JSON ?? [:],snapshot:context)
                    return copy
                }
                run = try store.put("run",run)
            } catch {
                run["state"] = "failed"; run["failureStage"] = "context"; run["error"] = error.localizedDescription; run["completedAt"] = isoNow()
                return try store.put("run",run)
            }
        }
        return try continueRun(run)
    }

    func continueRun(_ source: JSON) throws -> JSON {
        var run = source
        let sourceHash = stableHash(try jsonString(source))
        guard let persistedSource = try store.get("run",string(source,"id")), stableHash(try jsonString(persistedSource)) == sourceHash else {
            throw VelaError("Workflow run changed before continuation; review the latest state before retrying")
        }
        var finalExpectedHash = sourceHash
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
                    var frozen = try freezeArguments(tool:tool,arguments:args,project:root)
                    if tool == "agent.loop", var request = frozen["request"] as? JSON {
                        let librarySources = (run["inputsUsed"] as? [JSON] ?? []).filter { string($0,"source") == "library" }.flatMap { $0["value"] as? [JSON] ?? [] }
                        request["contextSources"] = (run["memoryUsed"] as? [JSON] ?? []) + (run["guidelinesUsed"] as? [JSON] ?? []) + librarySources
                        frozen["request"] = request; frozen["requestHash"] = stableHash(try jsonString(request))
                    }
                    let originalHash = stableHash(try jsonString(run))
                    let approval = try pendingApproval(title:string(steps[index],"title"),tool:tool,arguments:frozen,project:root,runId:string(run,"id"),stepIndex:index)
                    steps[index]["state"] = "pending_approval"; steps[index]["approvalId"] = approval["id"]
                    run["steps"] = steps; run["state"] = "pending_approval"
                    do {
                        var objects: [(String,JSON)] = [("approval",approval),("run",run)]
                        if tool == "agent.loop" {
                            let librarySources = (run["inputsUsed"] as? [JSON] ?? []).filter { string($0,"source") == "library" }.flatMap { $0["value"] as? [JSON] ?? [] }
                            let sources = (run["memoryUsed"] as? [JSON] ?? []) + (run["guidelinesUsed"] as? [JSON] ?? []) + librarySources
                            objects.append(("agent_loop",loopRecord(arguments:frozen,project:root,runId:string(run,"id"),approvalId:string(approval,"id"),contextSources:sources)))
                        }
                        let saved = try store.putBatch(objects,expecting:[("run",string(run,"id"),originalHash)],expectingAbsent:[("approval",string(approval,"id"))] + (tool == "agent.loop" ? [("agent_loop",string(frozen,"loopId"))] : []))
                        return saved[1]
                    } catch {
                        // A concurrent continuation wins without being overwritten
                        // by this stale caller's generic failure handling.
                        if let current = try store.get("run",string(run,"id")), stableHash(try jsonString(current)) != originalHash { return current }
                        throw error
                    }
                } else {
                    let runID = string(run,"id")
                    var retryStep = steps[index]
                    let result = try WorkflowRetry.execute(step:&retryStep,tool:tool,deadline:Date().addingTimeInterval((args["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 120),cancelled:{
                        VelaRuntimeShutdown.isRequested
                    },checkpoint:{ updated in
                        guard var current = try self.store.get("run",runID), var persistedSteps = current["steps"] as? [JSON], persistedSteps.indices.contains(index), string(persistedSteps[index],"id") == string(updated,"id") else { throw VelaError("Workflow retry step changed; it will not replay") }
                        let expected = stableHash(try jsonString(current))
                        persistedSteps[index] = updated; current["steps"] = persistedSteps
                        run = try self.store.putBatch([("run",current)],expecting:[("run",runID,expected)])[0]
                        finalExpectedHash = stableHash(try jsonString(run))
                        steps = run["steps"] as? [JSON] ?? steps
                    },operation:{ try self.executeTool(tool,arguments:args,project:root) })
                    steps[index] = retryStep
                    steps[index].merge(result) { _, new in new }
                    if result["outcomeUnknown"] as? Bool == true { steps[index]["state"] = "needs_review"; run["state"] = "needs_review"; break }
                    if string(retryStep,"retryState") == "cancelled" { steps[index]["state"] = "cancelled"; run["state"] = "cancelled"; break }
                    steps[index]["state"] = intValue(result,"exitCode") == 0 ? "completed" : "failed"
                    if string(steps[index],"state") == "failed" { run["state"] = "failed"; break }
                }
            } catch {
                steps[index]["state"] = "failed"; steps[index]["output"] = error.localizedDescription
                run["state"] = "failed"; break
            }
            let expectedRunHash = stableHash(try jsonString(run))
            run["steps"] = steps; run = try store.putBatch([("run",run)],expecting:[("run",string(run,"id"),expectedRunHash)])[0]
            finalExpectedHash = stableHash(try jsonString(run))
        }
        run["steps"] = steps
        if !["failed","cancelled","needs_review"].contains(string(run,"state")) { run["state"] = "completed" }
        run["completedAt"] = isoNow()
        run["durationMs"] = steps.reduce(0) { $0 + intValue($1,"durationMs") }
        return try finalizeWorkflowOutput(run,expectingRunHash:finalExpectedHash)
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
            if result["timedOut"] as? Bool == true || intValue(result,"terminationSignal") > 0 {
                result["outcomeUnknown"] = true
            }
            result["command"] = command; result["evaluator"] = tool == "agent.run" ? "user_selected_agent_cli" : "deterministic_command"
            if let hash = arguments["contextPromptHash"] { result["contextPromptHash"] = hash; result["contextDelivery"] = "argv" }
            return result
        case "file.write":
            let began = Date()
            let journal = try files.apply(project:project,operations:[arguments])
            return ["exitCode":0,"output":"Wrote \(string(arguments,"path"))","journalId":string(journal,"id"),"durationMs":Int(Date().timeIntervalSince(began)*1000)]
        case "lab.execute": return try executeEvaluation(arguments)
        case "knowledge.answer": return try executeKnowledgeQuery(arguments,project:project)
        case "ask.route.proposal.execute": return try executeAskRouteProposal(arguments,project:project)
        case "workflow.replay.execute": return try executeWorkflowReplay(arguments,project:project)
        case "agent.loop": return try executeAgentLoop(arguments,project:project)
        case "workflow.plan.execute": return try executeWorkflowPlan(arguments,project:project)
        case "improve.model.execute": return try executeModelImprovement(arguments,project:project)
        case "connector.execute": return try executeConnectorAction(arguments,project:project)
        case "connector.call":
            guard let request = arguments["request"] as? JSON, string(request,"action") == "tool", stableHash(try jsonString(request)) == string(arguments,"requestHash") else { throw VelaError("External workflow tool requires its frozen request") }
            return try connector().execute(request)
        default: throw VelaError("Unsupported external tool: \(tool)")
        }
    }

    func frozenPayload(_ approval: JSON) -> JSON {
        ["tool":string(approval,"tool"),"arguments":approval["arguments"] ?? [:],"project":string(approval,"project"),"runId":string(approval,"runId"),"stepIndex":intValue(approval,"stepIndex")]
    }

    private enum PendingApprovalClaim {
        case expired(JSON)
        case claimed(JSON, JSON?)
    }

    private func approvalTimestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from:date) }

    /// Every pending approval is built here so all creation surfaces share the
    /// local policy and the exact same frozen-payload hash contract.
    func pendingApproval(id: String = UUID().uuidString.lowercased(), title: String, tool: String, arguments: JSON, project: String, runId: String, stepIndex: Int) throws -> JSON {
        let now = approvalClock()
        let root = canonicalProject(project)
        var approval: JSON = ["id":id,"title":title,"tool":tool,"arguments":arguments,"project":root,"runId":runId,"stepIndex":stepIndex,"state":"pending","createdAt":approvalTimestamp(now)]
        let seconds = try approvalExpirySeconds()
        if seconds > 0 { approval["expiresAt"] = approvalTimestamp(now.addingTimeInterval(TimeInterval(seconds))) }
        else { approval["expiryMode"] = "disabled" }
        approval["snapshotHash"] = stableHash(try jsonString(frozenPayload(approval)))
        return approval
    }

    func createApproval(title: String, tool: String, arguments: JSON, project: String, runId: String, stepIndex: Int) throws -> JSON {
        try store.put("approval",pendingApproval(title:title,tool:tool,arguments:arguments,project:project,runId:runId,stepIndex:stepIndex))
    }

    private func approvalExpirySeconds() throws -> Int {
        let preferences = try VelaPreferences.read(from:store)
        guard let seconds = preferences["approvalExpirySeconds"] as? NSNumber,
              CFGetTypeID(seconds) != CFBooleanGetTypeID(), seconds.doubleValue.isFinite, seconds.doubleValue.rounded() == seconds.doubleValue,
              (0...31_536_000).contains(seconds.intValue), Double(seconds.intValue) == seconds.doubleValue else {
            throw VelaError("Approval expiry policy is invalid")
        }
        return seconds.intValue
    }

    private func expiryDate(_ approval: JSON) -> Date? {
        guard let text = approval["expiresAt"] as? String else { return nil } // legacy_unbounded
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return fractional.date(from:text) ?? ISO8601DateFormatter().date(from:text)
    }

    private func isExpired(_ approval: JSON, at now: Date) -> Bool {
        guard approval["expiresAt"] != nil else { return false }
        guard let expiry = expiryDate(approval) else { return true } // malformed new record fails closed
        return expiry <= now
    }

    private func approvalOwner(_ approval: JSON) throws -> (kind: String, id: String)? {
        let tool = string(approval,"tool"), arguments = approval["arguments"] as? JSON ?? [:]
        switch tool {
        case "lab.execute": return ("eval",string(approval,"runId"))
        case "knowledge.answer": return ("knowledge_query",try requireString(arguments,"askId"))
        case "ask.route.proposal.execute": return ("ask_route_proposal",try requireString(arguments,"proposalId"))
        case "workflow.replay.execute": return ("replay",try requireString(arguments,"replayId"))
        case "agent.loop": return ("agent_loop",try requireString(arguments,"loopId"))
        case "workflow.plan.execute": return ("workflow_plan",try requireString(arguments,"planId"))
        case "improve.model.execute": return ("model_improvement",try requireString(arguments,"planId"))
        case "connector.execute": return ("connector_action",try requireString(arguments,"actionId"))
        default: return nil
        }
    }

    /// Must be called inside `withApprovalTransaction`. It changes only a
    /// pending approval and its already-linked owner/run/step; executing and
    /// uncertain records are deliberately never rewritten as expired.
    private func expirePendingApproval(_ source: JSON, at now: Date) throws -> JSON {
        var approval = source
        guard string(approval,"state") == "pending" else { throw VelaError("Approval is no longer pending") }
        approval["state"] = "expired"; approval["expiredAt"] = approvalTimestamp(now); approval["expiryReason"] = "approval_ttl_elapsed"
        let tool = string(approval,"tool"), runID = string(approval,"runId")
        if tool != "lab.execute" {
            var run = try object("run",runID), steps = run["steps"] as? [JSON] ?? []
            let index = intValue(approval,"stepIndex")
            guard string(run,"state") == "pending_approval", string(run,"project") == string(approval,"project"), steps.indices.contains(index), string(steps[index],"state") == "pending_approval", string(steps[index],"approvalId") == string(approval,"id") else {
                throw VelaError("Approval owner is no longer its pending run step")
            }
            steps[index]["state"] = "expired"; steps[index]["expiredAt"] = approval["expiredAt"]
            run["steps"] = steps; run["state"] = "expired"; run["completedAt"] = approval["expiredAt"]
            _ = try store.put("run",run)
        }
        if let ownerReference = try approvalOwner(approval) {
            guard var owner = try store.get(ownerReference.kind,ownerReference.id) else { throw VelaError("Approval owner is missing") }
            guard string(owner,"project") == string(approval,"project"),
                  (ownerReference.kind == "eval" || string(owner,"runId") == runID),
                  string(owner,"approvalId") == string(approval,"id"), string(owner,"state") == "pending_approval" else {
                throw VelaError("Approval owner is no longer pending")
            }
            owner["state"] = "expired"; owner["expiredAt"] = approval["expiredAt"]
            _ = try store.put(ownerReference.kind,owner)
        }
        return try store.put("approval",approval)
    }

    /// Reads the deadline only after BEGIN IMMEDIATE succeeds. Therefore a
    /// contender queued behind another writer cannot reuse a pre-lock time.
    private func claimOrExpireApproval(id: String, snapshotHash: String, decision: String) throws -> PendingApprovalClaim {
        try store.withApprovalTransaction {
            let now = approvalClock()
            var approval = try object("approval",id)
            guard string(approval,"state") == "pending" else { throw VelaError("This action was already decided or started. It will not execute again.") }
            let actual = stableHash(try jsonString(frozenPayload(approval)))
            guard actual == snapshotHash, actual == string(approval,"snapshotHash") else { throw VelaError("Approval snapshot changed; review the frozen action again") }
            if isExpired(approval,at:now) { return .expired(try expirePendingApproval(approval,at:now)) }
            let tool = string(approval,"tool")
            var pendingRun: JSON?
            if tool != "lab.execute" {
                let run = try object("run",string(approval,"runId")), steps = run["steps"] as? [JSON] ?? [], index = intValue(approval,"stepIndex")
                guard string(run,"state") == "pending_approval", canonicalProject(string(run,"project")) == canonicalProject(string(approval,"project")), steps.indices.contains(index), string(steps[index],"state") == "pending_approval", string(steps[index],"approvalId") == string(approval,"id") else { throw VelaError("The frozen action is no longer the pending step in this run") }
                pendingRun = run
            }
            approval["decidedAt"] = approvalTimestamp(now)
            if decision == "reject" {
                approval["state"] = "rejected"
                if var run = pendingRun {
                    var steps = run["steps"] as? [JSON] ?? []; steps[intValue(approval,"stepIndex")]["state"] = "rejected"
                    run["steps"] = steps; run["state"] = "rejected"; run["completedAt"] = approval["decidedAt"]
                    _ = try store.put("run",run)
                } else {
                    var evaluation = try object("eval",string(approval,"runId"))
                    guard string(evaluation,"state") == "pending_approval" else { throw VelaError("Evaluation is no longer pending approval") }
                    evaluation["state"] = "rejected"; _ = try store.put("eval",evaluation)
                }
                return .claimed(try store.put("approval",approval),pendingRun)
            }
            approval["state"] = "executing"
            return .claimed(try store.put("approval",approval),pendingRun)
        }
    }

    func decideApproval(_ params: JSON) throws -> JSON {
        let id = try requireString(params,"id"), provided = try requireString(params,"snapshotHash"), decision = try requireString(params,"decision")
        guard ["approve","reject"].contains(decision) else { throw VelaError("Decision must be approve or reject") }
        let claim = try claimOrExpireApproval(id:id,snapshotHash:provided,decision:decision)
        guard case let .claimed(claimed,pendingRun) = claim else {
            if case var .expired(expired) = claim {
                if string(expired,"tool") != "lab.execute", let run = try store.get("run",string(expired,"runId")), run["parentRunId"] != nil {
                    do { expired["parentRun"] = try advanceAncestors(of:run) } catch { expired["continuationError"] = error.localizedDescription }
                }
                // The expiry transaction has committed. Do not return a
                // decision-shaped success to older renderer callers that only
                // distinguish resolve/reject by a non-error response.
                throw VelaError("Approval expired; no action was executed. Review a new request.")
            }
            throw VelaError("Approval claim failed")
        }
        var approval = claimed, tool = string(claimed,"tool")
        if decision == "reject" {
            if tool != "lab.execute", let run = try store.get("run",string(approval,"runId")), run["parentRunId"] != nil {
                do { approval["parentRun"] = try advanceAncestors(of:run) } catch { approval["continuationError"] = error.localizedDescription }
            }
            if tool == "ask.route.proposal.execute" { try markAskRouteProposalRejected(approval["arguments"] as? JSON ?? [:],project:try project(requireString(approval,"project"))) }
            return approval
        }
        let root = try project(requireString(approval,"project"))
        guard stableHash(try jsonString(frozenPayload(approval))) == provided, string(approval,"snapshotHash") == provided else {
            approval["state"] = "needs_review"; _ = try store.put("approval",approval)
            throw VelaError("Approval changed while it was being claimed; no action was executed")
        }
        let result: JSON
        do {
            if let run = pendingRun { try verifyFrozenWorkflowMemories(run,project:root) }
            result = try executeTool(tool,arguments:approval["arguments"] as? JSON ?? [:],project:root)
            approval["state"] = result["outcomeUnknown"] as? Bool == true ? "needs_review" : intValue(result,"exitCode") == 0 ? "executed" : "failed"
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
            run["steps"] = steps; run["state"] = string(approval,"state") == "needs_review" ? "needs_review" : string(approval,"state") == "executed" ? "running" : "failed"
            if string(run,"state") == "failed" { run["completedAt"] = isoNow(); run["durationMs"] = steps.reduce(0) {$0+intValue($1,"durationMs")} }
            run = try store.put("run",run)
            if string(run,"state") == "running" { run = try continueRun(run) }
            approval["run"] = run
            if run["parentRunId"] != nil {
                do { approval["parentRun"] = try advanceAncestors(of:run) } catch { approval["continuationError"] = error.localizedDescription }
            }
        }
        return approval
    }

    private func approvalView(_ approval: JSON) -> JSON {
        var view = approval
        if approval["expiresAt"] != nil { view["expiryMode"] = "ttl" }
        else if string(approval,"expiryMode") != "disabled" { view["expiryMode"] = "legacy_unbounded" }
        return view
    }

    private func approvalCursor(_ approval: JSON) throws -> String {
        let value = string(approval,"createdAt") + "\n" + string(approval,"id")
        guard !string(approval,"createdAt").isEmpty else { throw VelaError("Approval has no creation timestamp") }
        return Data(value.utf8).base64EncodedString()
    }

    private func parseApprovalCursor(_ value: String) throws -> (createdAt: String, id: String)? {
        guard !value.isEmpty else { return nil }
        guard value.utf8.count <= 512, let data = Data(base64Encoded:value), let text = String(data:data,encoding:.utf8) else { throw VelaError("Invalid approval cursor") }
        let parts = text.split(separator:"\n",maxSplits:1,omittingEmptySubsequences:false)
        let createdAt = parts.count == 2 ? String(parts[0]) : ""
        let id = parts.count == 2 ? String(parts[1]) : ""
        // Validate the whole keyset tuple before an expired-list projection can
        // acquire its write transaction. Store.approvalPage repeats this check
        // as a defence in depth boundary for non-RPC callers.
        guard !createdAt.isEmpty, createdAt.utf8.count <= 80,
              !id.isEmpty, id.count <= 150,
              id.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil,
              id != ".", id != ".." else { throw VelaError("Invalid approval cursor") }
        return (createdAt,id)
    }

    private func approvalRecord(_ id: String) throws -> JSON {
        let current = try object("approval",id)
        guard string(current,"state") == "pending" else { return approvalView(current) }
        // Reject is never used for reads. The transaction can only claim an
        // elapsed record as expired, or return the still-pending current row.
        var result = try store.withApprovalTransaction {
            let now = approvalClock(), latest = try object("approval",id)
            guard string(latest,"state") == "pending" else { return approvalView(latest) }
            return approvalView(isExpired(latest,at:now) ? try expirePendingApproval(latest,at:now) : latest)
        }
        if string(result,"state") == "expired", string(result,"tool") != "lab.execute",
           let run = try store.get("run",string(result,"runId")), run["parentRunId"] != nil {
            do { _ = try advanceAncestors(of:run) } catch { result["continuationError"] = error.localizedDescription }
        }
        return result
    }

    func approvalGet(_ params: JSON) throws -> JSON {
        guard Set(params.keys) == Set(["id"]) else { throw VelaError("approvals.get requires only id") }
        return try approvalRecord(requireString(params,"id"))
    }

    func approvalList(_ params: JSON) throws -> JSON {
        let allowed: Set<String> = ["project","state","limit","cursor"]
        guard Set(params.keys).isSubset(of:allowed), params["state"] == nil || params["state"] is String,
              params["cursor"] == nil || params["cursor"] is String else { throw VelaError("Unsupported approvals.list parameter") }
        let selected = params["project"] == nil ? nil : try project(requireString(params,"project"))
        let state = string(params,"state","pending")
        let supported: Set<String> = ["pending","executing","executed","failed","rejected","needs_review","acknowledged","expired"]
        guard supported.contains(state) else { throw VelaError("Unsupported approval state") }
        let limit = try WorkflowContext.integer(params["limit"],default:50,range:1...100,name:"approval list limit")
        // Validate before a list-triggered expiry projection can write state.
        let after = try parseApprovalCursor(string(params,"cursor"))
        // An explicit expired view may be the first read after a process was
        // offline. Sweep one bounded oldest-first pending page before querying
        // that terminal view; decide itself remains the complete safety gate.
        var dueProjection: JSON? = nil
        if state == "expired" {
            let now = approvalTimestamp(approvalClock())
            let due = try store.dueApprovalPage(project:selected,now:now,limit:200)
            for row in due {
                _ = try approvalRecord(string(row,"id"))
            }
            dueProjection = ["scanned":due.count,"cap":200,"mayHaveMore":due.count == 200,"continuation":"repeat_same_expired_query_when_mayHaveMore"]
        }
        let source = try store.approvalPage(project:selected,states:[state],after:after,limit:limit + 1)
        let page = Array(source.prefix(limit)); var items: [JSON] = []
        for row in page {
            let current = try approvalRecord(string(row,"id"))
            if string(current,"state") == state { items.append(current) }
        }
        let next: Any = source.count > limit && !page.isEmpty ? try approvalCursor(page.last!) : NSNull()
        var result: JSON = ["items":items,"cursor":next,"order":"createdAt_asc_id_asc","state":state]
        if let dueProjection { result["expiredProjection"] = dueProjection }
        return result
    }

    /// Approval executes the already hashed prompt/argv unchanged. This only
    /// checks whether the persisted Memory receipts remain eligible to enter
    /// the selected project's context; ordinary title/content edits do not
    /// invalidate a reviewed frozen prompt.
    private func verifyFrozenWorkflowMemories(_ run: JSON, project root: String) throws {
        let receipts = run["memoryUsed"] as? [JSON] ?? []
        guard receipts.count <= 100 else { throw VelaError("Frozen workflow Memory receipts exceed the supported bound") }
        guard !receipts.isEmpty else { return }
        let policy = try IngestionExclusionService(store:store).memoryRecallPolicy(project:root)
        for receipt in receipts {
            guard string(receipt,"kind") == "memory", let current = try store.get("memory",string(receipt,"id")),
                  SemanticMemory.canRecall(current,params:[:],project:root), policy.allows(current) else {
                throw VelaError("Frozen workflow Memory became private, inactive, out of scope or excluded; no process was started")
            }
        }
    }

    func replay(_ params: JSON) throws -> JSON {
        let previous = try object("run",requireString(params,"runId"))
        guard let workflow = previous["workflowSnapshot"] as? JSON else { throw VelaError("This run has no frozen workflow snapshot") }
        // A replay must not quietly substitute today's Git state for yesterday's input.
        // This is a captured-record replay, not a model evaluation or a fresh execution.
        let root = try project(requireString(previous,"project"))
        if previous["compositionMode"] != nil { return try replayComposition(previous,workflow:workflow,project:root) }
        var steps = previous["steps"] as? [JSON] ?? []
        var incomplete = false
        for index in steps.indices {
            if readTools.contains(string(steps[index],"tool")) {
                if ["completed","failed"].contains(string(steps[index],"state")), steps[index]["output"] != nil {
                    steps[index]["replayedFromCapture"] = true
                } else { steps[index]["state"] = "unavailable"; steps[index]["output"] = "Historical read output was not captured"; incomplete = true }
            } else {
                steps[index]["state"] = "stubbed"; steps[index]["output"] = "Captured replay: no command, model or write was executed."
                steps[index].removeValue(forKey:"approvalId")
            }
            steps[index]["durationMs"] = 0
        }
        var run: JSON = ["title":string(previous,"title"),"project":root,"workflowId":string(previous,"workflowId"),"workflowVersion":intValue(previous,"workflowVersion"),"workflowSnapshot":workflow,"state":incomplete ? "failed" : "completed","steps":steps,"dryRun":true,"replayOf":string(previous,"id"),"replayMode":"captured_records_no_execution","startedAt":isoNow(),"completedAt":isoNow(),"durationMs":0,"inputs":previous["inputs"] ?? [:],"inputsUsed":previous["inputsUsed"] ?? [],"guidelinesUsed":previous["guidelinesUsed"] ?? [],"memoryUsed":previous["memoryUsed"] ?? [],"guidelineUseMode":string(previous,"guidelineUseMode")]
        if let context = previous["contextSnapshot"] as? JSON {
            guard stableHash(string(context,"renderedPrompt")) == string(context,"promptHash") else { throw VelaError("Historical context snapshot hash is inconsistent") }
            run["contextSnapshot"] = context
        }
        return try store.put("run",run)
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
