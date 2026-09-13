import Foundation
import CoreFoundation

/// Deterministic workflow composition, not an autonomous model/tool loop.
enum WorkflowComposition {
    static func isComposite(_ workflow: JSON) -> Bool {
        workflow["pipeline"] != nil || ((workflow["context"] as? JSON)?["inputs"] as? [JSON] ?? []).contains { $0["workflow"] != nil }
    }
    static func stages(_ raw: Any?) throws -> [JSON]? {
        guard let raw else { return nil }
        guard let stages = raw as? [JSON], !stages.isEmpty, stages.count <= 16 else { throw VelaError("Pipeline requires 1–16 stages") }
        return try stages.enumerated().map { index,stage in
            guard Set(stage.keys).isSubset(of:["id","workflowId","when","inputs"]), stage["inputs"] == nil || stage["inputs"] is JSON else { throw VelaError("Invalid pipeline stage") }
            guard stage["when"] == nil || stage["when"] is String,
                  stage["id"] == nil || stage["id"] is String else { throw VelaError("Stage id and condition must be text") }
            let stageID = string(stage,"id","stage-\(index+1)")
            guard stageID.range(of:"^[A-Za-z0-9_-]{1,64}$",options:.regularExpression) != nil else { throw VelaError("Invalid stage ID") }
            let condition = string(stage,"when","always")
            guard ["always","has_output","no_output"].contains(condition), index != 0 || condition == "always" else { throw VelaError("Invalid pipeline condition or a condition on the first stage") }
            return ["id":stageID,"workflowId":try requireString(stage,"workflowId"),"when":condition,"inputs":stage["inputs"] ?? JSON()]
        }
    }
    static func output(_ raw: Any?, steps: [JSON], scheduled: Bool) throws -> JSON? {
        guard let raw else { return nil }
        guard let output = raw as? JSON, Set(output.keys).isSubset(of:["target","path","inbox","stepId"]),
              ["stdout","file","inbox"].contains(string(output,"target")),
              !scheduled || string(output,"target") != "stdout" else { throw VelaError("Invalid output target; scheduled output must use file or inbox") }
        guard output["path"] == nil || output["path"] is String else { throw VelaError("Output path must be text") }
        if let flag = output["inbox"] { guard let number = flag as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw VelaError("Output inbox must be boolean") } }
        if let step = output["stepId"] as? String {
            guard steps.filter({ string($0,"id") == step }).count == 1 else { throw VelaError("Output stepId must identify exactly one step") }
        } else if output["stepId"] != nil { throw VelaError("Invalid output stepId") }
        if string(output,"target") == "file" {
            _ = try outputPath(string(output,"path","output-{datetime}.md"),at:Date())
        } else if output["path"] != nil { throw VelaError("Only file outputs have a path") }
        return output
    }
    static func outputPath(_ template: String, at date: Date) throws -> String {
        guard !template.isEmpty, template.utf8.count < 2048, !template.hasPrefix("/"), !template.contains("\0"), !template.split(separator:"/").contains("..") else { throw VelaError("Output path must remain inside the store output directory") }
        let format = DateFormatter(); format.locale = Locale(identifier:"en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT:0)
        var path = template
        for (key,pattern) in [("datetime","yyyyMMdd'T'HHmmss'Z'"),("date","yyyy-MM-dd"),("time","HHmmss")] {
            format.dateFormat = pattern
            path = path.replacingOccurrences(of:"{{"+key+"}}",with:format.string(from:date)).replacingOccurrences(of:"{"+key+"}",with:format.string(from:date))
        }
        guard !path.contains("{"), !path.contains("}"), !path.hasSuffix("/") else { throw VelaError("Unknown output path placeholder") }
        return "output/" + path
    }
    static func childID(parent: String, slot: String) -> String { "child-" + String(stableHash(parent + ":" + slot).prefix(48)) }
}

extension AutomationService {
    func withCompositionLease<T>(_ body: () throws -> T) throws -> T {
        if compositionLeaseDepth > 0 { return try body() }
        guard let lease = try VelaRuntimeLease.acquire(root:store.root,name:"composition") else { throw VelaError("Workflow composition is being advanced by another process; no action was repeated") }
        compositionLeaseDepth += 1
        defer { compositionLeaseDepth -= 1; lease.release() }
        return try body()
    }

    func compositionDefinitions(_ workflow: JSON, synchronizingAssets: Bool = true) throws -> JSON {
        let project = string(workflow,"project")
        var definitions: JSON = [:], count = 0
        func visit(_ item: JSON, stack: [String]) throws {
            let id = try requireString(item,"id")
            guard !stack.contains(id), stack.count < 8, count < 65, string(item,"project") == project else { throw VelaError("Workflow dependency is cyclic, too deep, too large, or belongs to another project") }
            if item["pipeline"] != nil && stack.contains(where:{ (definitions[$0] as? JSON)?["pipeline"] != nil }) { throw VelaError("Nested pipelines are unsupported, including through a sub-workflow input") }
            count += 1; definitions[id] = item
            if let stages = try WorkflowComposition.stages(item["pipeline"]) {
                guard Set(stages.map { string($0,"id") }).count == stages.count else { throw VelaError("Pipeline stage IDs must be unique") }
                for stage in stages {
                    let child = try loadCurrentWorkflow(requireString(stage,"workflowId"),validatingDependencies:false,synchronize:synchronizingAssets)
                    guard child["pipeline"] == nil else { throw VelaError("A pipeline stage cannot be another pipeline") }
                    guard (stage["inputs"] as? JSON ?? [:]).isEmpty || child["context"] != nil else { throw VelaError("Stage input bindings require an explicit child context") }
                    try visit(child,stack:stack+[id])
                }
            }
            for input in (item["context"] as? JSON)?["inputs"] as? [JSON] ?? [] {
                if let reference = input["workflow"] as? JSON { try visit(loadCurrentWorkflow(requireString(reference,"id"),validatingDependencies:false,synchronize:synchronizingAssets),stack:stack+[id]) }
            }
        }
        try visit(workflow,stack:[])
        guard try jsonString(definitions).utf8.count <= 1_048_576 else { throw VelaError("Frozen workflow graph exceeds 1 MB") }
        return definitions
    }

    func runDefinitions(_ run: JSON) throws -> JSON {
        let rootID = string(run,"rootRunId",string(run,"id"))
        let root = rootID == string(run,"id") ? run : try object("run",rootID)
        guard let definitions = root["compositionDefinitions"] as? JSON,
              stableHash(try jsonString(definitions)) == string(root,"compositionHash") else { throw VelaError("Frozen workflow graph changed; no dependency was started") }
        return definitions
    }

    func startCompositeWorkflow(_ workflow: JSON, dryRun: Bool, inputs: JSON, stdin: String?, ancestry: JSON?) throws -> JSON {
        try withCompositionLease {
            try WorkflowContext.bounded(inputs)
            if let stdin { try WorkflowContext.bounded(stdin) }
            let id = ancestry?["runId"] as? String ?? UUID().uuidString.lowercased()
            if let existing = try store.get("run",id) { return existing }
            let definitions: JSON
            if let parent = ancestry { definitions = try runDefinitions(object("run",requireString(parent,"parentRunId"))) }
            else { definitions = try compositionDefinitions(workflow) }
            let mode = workflow["pipeline"] == nil ? "context" : "pipeline"
            let rootID = ancestry?["rootRunId"] as? String ?? id
            var run: JSON = ["id":id,"title":string(workflow,"title"),"project":string(workflow,"project"),"workflowId":string(workflow,"id"),"workflowVersion":intValue(workflow,"version"),"workflowSnapshot":workflow,"state":"running","dryRun":dryRun,"startedAt":isoNow(),"rootRunId":rootID,"compositionMode":mode,"compositionCursor":0,"values":["input":inputs],"inputsUsed":[],"degraded":false,"suppliedInputs":inputs,"steps":[],"previousOutput":stdin ?? "","previousOutputKnown":true,"stageResults":[]]
            if let stdin { run["suppliedStdin"] = stdin }
            if let parent = ancestry { run["parentRunId"] = parent["parentRunId"]; run["outputMode"] = "memory" }
            if rootID == id { run["compositionDefinitions"] = definitions; run["compositionHash"] = stableHash(try jsonString(definitions)) }
            guard try store.insertIfAbsent("run",run) else { return try object("run",id) }
            run = try object("run",id)
            return try advanceCompositeRun(run)
        }
    }

    func advanceCompositeRun(_ source: JSON) throws -> JSON {
        var run = source
        guard ["running","waiting_child"].contains(string(run,"state")) else { return run }
        let workflow = try WorkflowPlanning.requireObject(run,"workflowSnapshot")
        let definitions = try runDefinitions(run)
        let isPipeline = string(run,"compositionMode") == "pipeline"
        let stages = isPipeline ? (try WorkflowComposition.stages(workflow["pipeline"]) ?? []) : ((workflow["context"] as? JSON)?["inputs"] as? [JSON] ?? [])
        var cursor = intValue(run,"compositionCursor")
        while cursor < stages.count {
            if VelaRuntimeShutdown.isRequested { run["state"] = "waiting_child"; return try store.put("run",run) }
            let stage = stages[cursor]
            do {
                if !isPipeline && stage["workflow"] == nil {
                    var values = run["values"] as? JSON ?? [:]
                    let receipt = try resolveOrdinaryContextInput(stage,values:values,project:string(run,"project"),stdin:run["suppliedStdin"] as? String)
                    values[string(stage,"id")] = receipt["value"]; try WorkflowContext.bounded(values)
                    run["values"] = values; run["inputsUsed"] = (run["inputsUsed"] as? [JSON] ?? []) + [receipt]
                    run["degraded"] = (run["degraded"] as? Bool ?? false) || string(receipt,"state") == "degraded"
                    cursor += 1; run["compositionCursor"] = cursor; run = try store.put("run",run); continue
                }
                let condition = isPipeline ? string(stage,"when","always") : "always"
                if isPipeline && condition != "always" {
                    guard run["previousOutputKnown"] as? Bool == true else {
                        run["state"] = "blocked"; run["reason"] = "Dry Run did not execute the prior producer; its output condition is unknown"
                        return try store.put("run",run)
                    }
                    let hasOutput = !string(run,"previousOutput").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
                    if (condition == "has_output" && !hasOutput) || (condition == "no_output" && hasOutput) {
                        run["stageResults"] = (run["stageResults"] as? [JSON] ?? []) + [["id":string(stage,"id"),"state":"skipped","passedThrough":true]]
                        cursor += 1; run["compositionCursor"] = cursor; run = try store.put("run",run); continue
                    }
                }
                let reference = isPipeline ? ["id":string(stage,"workflowId"),"inputs":stage["inputs"] ?? JSON()] : (stage["workflow"] as? JSON ?? [:])
                let childWorkflowID = try requireString(reference,"id")
                guard let childWorkflow = definitions[childWorkflowID] as? JSON else { throw VelaError("Child definition is absent from the frozen graph") }
                let childID = WorkflowComposition.childID(parent:string(run,"id"),slot:"\(cursor):"+string(stage,"id"))
                run["waitingChildId"] = childID; run["state"] = "waiting_child"; run = try store.put("run",run)
                let child: JSON
                if let existing = try store.get("run",childID) {
                    guard string(existing,"parentRunId") == string(run,"id"), string(existing,"project") == string(run,"project"),
                          string(existing,"workflowId") == childWorkflowID,
                          try jsonString(existing["workflowSnapshot"] ?? JSON()) == jsonString(childWorkflow) else {
                        run["state"] = "needs_review"; run["error"] = "Child identity or frozen definition changed; no action was repeated"
                        return try store.put("run",run)
                    }
                    child = try resumeKnownChild(existing)
                }
                else {
                    let values: JSON = isPipeline ? ["input":run["suppliedInputs"] ?? JSON(),"previous":string(run,"previousOutput")] : (run["values"] as? JSON ?? [:])
                    var input = try WorkflowContext.render(reference["inputs"] ?? JSON(),values:values) as? JSON ?? [:]
                    let piped = isPipeline ? string(run,"previousOutput") : nil
                    let suppliedStdin: String?
                    if let raw = reference["stdin"] {
                        guard let rendered = try WorkflowContext.render(raw,values:values) as? String else { throw VelaError("Child stdin must resolve to text") }
                        suppliedStdin = rendered
                    } else { suppliedStdin = piped }
                    if isPipeline && childWorkflow["context"] != nil { input["previous"] = piped ?? "" }
                    let ancestry: JSON = ["runId":childID,"parentRunId":string(run,"id"),"rootRunId":string(run,"rootRunId",string(run,"id"))]
                    child = try startWorkflow(id:childWorkflowID,dryRun:run["dryRun"] as? Bool ?? true,snapshot:childWorkflow,suppliedInputs:input,stdin:isPipeline && childWorkflow["context"] == nil ? nil : suppliedStdin,ancestry:ancestry)
                }
                let state = string(child,"state")
                if ["running","waiting_child","pending_approval"].contains(state) { return try store.put("run",run) }
                if state != "completed" {
                    if !isPipeline && stage["optional"] as? Bool == true && ["failed","rejected"].contains(state) {
                        var values = run["values"] as? JSON ?? [:]; values[string(stage,"id")] = ""; run["values"] = values; run["degraded"] = true
                        run["inputsUsed"] = (run["inputsUsed"] as? [JSON] ?? []) + [["id":string(stage,"id"),"source":"workflow","childRunId":childID,"state":"degraded","value":"","error":"Child run " + state]]
                    } else { run["state"] = ["blocked","needs_review"].contains(state) ? state : "failed"; run["error"] = "Child run " + childID + " ended as " + state; return try store.put("run",run) }
                } else if isPipeline {
                    run["previousOutput"] = child["output"] ?? ""; run["previousOutputKnown"] = child["outputKnown"] ?? false
                    run["stageResults"] = (run["stageResults"] as? [JSON] ?? []) + [["id":string(stage,"id"),"state":"completed","childRunId":childID,"outputHash":child["outputHash"] ?? NSNull()]]
                } else {
                    guard child["outputKnown"] as? Bool == true else { run["state"] = "blocked"; run["reason"] = "Dry Run child output is unknown"; return try store.put("run",run) }
                    var values = run["values"] as? JSON ?? [:]; values[string(stage,"id")] = child["output"] ?? ""; try WorkflowContext.bounded(values); run["values"] = values
                    run["inputsUsed"] = (run["inputsUsed"] as? [JSON] ?? []) + [["id":string(stage,"id"),"source":"workflow","childRunId":childID,"workflowVersion":child["workflowVersion"] ?? NSNull(),"state":"resolved","value":child["output"] ?? "","valueHash":child["outputHash"] ?? NSNull()]]
                }
                cursor += 1; run["compositionCursor"] = cursor; run["state"] = "running"; run.removeValue(forKey:"waitingChildId"); run = try store.put("run",run)
            } catch {
                run["state"] = "failed"; run["error"] = error.localizedDescription; run["completedAt"] = isoNow(); return try store.put("run",run)
            }
        }
        if isPipeline {
            run["state"] = "completed"; run["output"] = run["previousOutput"] ?? ""; run["outputKnown"] = run["previousOutputKnown"] ?? false; run["completedAt"] = isoNow()
            return try finalizeWorkflowOutput(run)
        }
        do {
            let context = try finishWorkflowContext(workflow,values:run["values"] as? JSON ?? [:],receipts:run["inputsUsed"] as? [JSON] ?? [],degraded:run["degraded"] as? Bool ?? false)
            run["contextSnapshot"] = context; run["inputs"] = context["inputs"]; run["guidelinesUsed"] = context["guidelinesUsed"]; run["memoryUsed"] = context["memoryUsed"]; run["guidelineUseMode"] = "frozen_prompt_argv"
            run["steps"] = try (workflow["steps"] as? [JSON] ?? []).map { step -> JSON in var copy = step; copy["state"] = "queued"; copy["arguments"] = try contextArguments(step["arguments"] as? JSON ?? [:],snapshot:context); return copy }
            run["compositionPrepared"] = true; run["state"] = "running"; run = try store.put("run",run)
            return try continueRun(run)
        } catch { run["state"] = "failed"; run["failureStage"] = "context"; run["error"] = error.localizedDescription; return try store.put("run",run) }
    }

    func resumeKnownChild(_ source: JSON) throws -> JSON {
        var run = try object("run",requireString(source,"id"))
        guard string(run,"project") == string(source,"project") else { throw VelaError("Run recovery project changed") }
        if run["compositionMode"] != nil && run["compositionPrepared"] as? Bool != true { return try advanceCompositeRun(run) }
        if string(run,"state") == "pending_approval" {
            let originalHash = stableHash(try jsonString(run))
            var steps = run["steps"] as? [JSON] ?? []
            guard let index = steps.firstIndex(where:{ string($0,"state") == "pending_approval" }),
                  let approval = try store.get("approval",string(steps[index],"approvalId")), ["executed","failed","rejected","needs_review"].contains(string(approval,"state")) else { return run }
            guard string(approval,"runId") == string(run,"id"), string(approval,"project") == string(run,"project"),
                  intValue(approval,"stepIndex") == index,
                  stableHash(try jsonString(frozenPayload(approval))) == string(approval,"snapshotHash"),
                  string(approval,"state") != "executed" || (approval["result"] as? JSON)?["exitCode"] as? Int == 0 else {
                run["state"] = "needs_review"; run["error"] = "Approval recovery identity or result changed; no action was repeated"
                do { return try store.putBatch([("run",run)],expecting:[("run",string(run,"id"),originalHash)])[0] }
                catch { return try object("run",string(run,"id")) }
            }
            steps[index].merge(approval["result"] as? JSON ?? [:]) { _,new in new }
            steps[index]["state"] = string(approval,"state") == "executed" ? "completed" : string(approval,"state")
            run["steps"] = steps; run["state"] = string(approval,"state") == "executed" ? "running" : string(approval,"state") == "needs_review" ? "needs_review" : "failed"
            do { run = try store.putBatch([("run",run)],expecting:[("run",string(run,"id"),originalHash)])[0] }
            catch { return try object("run",string(run,"id")) }
        }
        if string(run,"state") == "running" {
            if let workflow = run["workflowSnapshot"] as? JSON, workflow["context"] != nil && run["contextSnapshot"] == nil {
                // No approval exists before context preparation. Recollecting these
                // reads is allowed only on explicit recovery, before any next approval.
                let snapshot = try freezeWorkflowContext(workflow,supplied:run["suppliedInputs"] as? JSON ?? [:],stdin:run["suppliedStdin"] as? String)
                run["contextSnapshot"] = snapshot
                run["steps"] = try (run["steps"] as? [JSON] ?? []).map { step -> JSON in var copy = step; copy["arguments"] = try contextArguments(step["arguments"] as? JSON ?? [:],snapshot:snapshot); return copy }
                run = try store.put("run",run)
            }
            return try continueRun(run)
        }
        return run
    }

    func resumeComposition(_ params: JSON) throws -> JSON {
        let selected = try project(requireString(params,"project"))
        let run = try object("run",requireString(params,"id"))
        guard string(run,"project") == selected, run["compositionMode"] != nil || run["parentRunId"] != nil else { throw VelaError("This is not a composition run in the selected project") }
        return try withCompositionLease {
            let resumed = try resumeKnownChild(object("run",string(run,"id")))
            _ = try advanceAncestors(of:resumed)
            return try object("run",string(run,"id"))
        }
    }

    @discardableResult func advanceAncestors(of child: JSON) throws -> JSON? {
        try withCompositionLease {
            var current = child, last: JSON?
            for _ in 0..<8 {
                guard let parentID = current["parentRunId"] as? String else { break }
                current = try resumeKnownChild(object("run",parentID)); last = current
            }
            return last
        }
    }

    func replayComposition(_ previous: JSON, workflow: JSON, project: String) throws -> JSON {
        let text = string(previous,"output")
        let available = previous["outputKnown"] as? Bool == true && string(previous,"state") == "completed" && stableHash(text) == string(previous,"outputHash")
        var replay: JSON = ["title":string(previous,"title"),"project":project,"workflowId":string(previous,"workflowId"),"workflowVersion":intValue(previous,"workflowVersion"),"workflowSnapshot":workflow,"state":available ? "completed" : "failed","dryRun":true,"replayOf":string(previous,"id"),"replayMode":"captured_composition_records_no_execution","capturedStages":previous["stageResults"] ?? [],"inputsUsed":previous["inputsUsed"] ?? [],"guidelinesUsed":previous["guidelinesUsed"] ?? [],"memoryUsed":previous["memoryUsed"] ?? [],"output":available ? text : "","outputKnown":available,"outputDelivery":"stubbed","durationMs":0,"startedAt":isoNow(),"completedAt":isoNow()]
        if available { replay["outputHash"] = stableHash(text) }
        else { replay["error"] = "A complete, hash-verified historical composition output is unavailable; no child or tool was executed" }
        return try store.put("run",replay)
    }

    func finalizeWorkflowOutput(_ source: JSON, expectingRunHash: String? = nil) throws -> JSON {
        do { return try deliverWorkflowOutput(source,expectingRunHash:expectingRunHash) }
        catch {
            var failed = source
            failed["state"] = "needs_review"; failed["failureStage"] = "output"; failed["error"] = error.localizedDescription
            failed["completedAt"] = isoNow()
            return try persistFinalWorkflowRun(failed,expecting:expectingRunHash)
        }
    }

    private func persistFinalWorkflowRun(_ run: JSON, expecting: String?) throws -> JSON {
        guard let expecting else { return try store.put("run",run) }
        return try store.putBatch([("run",run)],expecting:[("run",string(run,"id"),expecting)])[0]
    }

    private func deliverWorkflowOutput(_ source: JSON, expectingRunHash: String? = nil) throws -> JSON {
        var run = source
        guard string(run,"state") == "completed", let workflow = run["workflowSnapshot"] as? JSON else { return try persistFinalWorkflowRun(run,expecting:expectingRunHash) }
        let output = workflow["output"] as? JSON ?? ["target":"stdout"]
        if run["output"] == nil {
            let steps = run["steps"] as? [JSON] ?? []
            let step = (output["stepId"] as? String).flatMap { id in steps.first { string($0,"id") == id } } ?? steps.last
            run["output"] = step.map { string($0,"output") } ?? ""
            run["outputKnown"] = step.map { string($0,"state") == "completed" } ?? true
        }
        let text = string(run,"output")
        guard text.utf8.count <= 1_048_576 else { throw VelaError("Workflow output exceeds 1 MB") }
        run["outputHash"] = stableHash(text)
        guard string(run,"outputMode") != "memory", run["dryRun"] as? Bool != true, run["outputKnown"] as? Bool == true else {
            run["outputDelivery"] = string(run,"outputMode") == "memory" ? "memory" : "stubbed"
            return try persistFinalWorkflowRun(run,expecting:expectingRunHash)
        }
        guard workflow["output"] != nil || run["compositionMode"] != nil else { run["outputDelivery"] = "record"; return try persistFinalWorkflowRun(run,expecting:expectingRunHash) }
        let id = string(run,"id")
        let existing = try store.get("run_output",id)
        func validateRecord(_ candidate: JSON) throws {
            guard string(candidate,"runId") == id, string(candidate,"project") == string(run,"project"),
                  string(candidate,"target") == string(output,"target","stdout"),
                  string(candidate,"contentHash") == stableHash(text), string(candidate,"content") == text,
                  ["prepared","delivered"].contains(string(candidate,"state")) else {
                throw VelaError("Output delivery identity changed; no duplicate delivery was performed")
            }
        }
        if let existing {
            try validateRecord(existing)
            if string(existing,"state") == "delivered" { run["outputDelivery"] = existing; return try persistFinalWorkflowRun(run,expecting:expectingRunHash) }
        }
        var record: JSON = existing ?? ["id":id,"runId":id,"project":string(run,"project"),"title":string(run,"title"),"target":string(output,"target","stdout"),"content":text,"contentHash":stableHash(text),"state":"prepared","unread":string(output,"target") == "inbox" || output["inbox"] as? Bool == true]
        if string(output,"target") == "file" {
            guard let timestamp = ISO8601DateFormatter().date(from:string(run,"startedAt")) else { throw VelaError("Output delivery requires the original run timestamp") }
            let path = try WorkflowComposition.outputPath(string(output,"path","output-{datetime}.md"),at:timestamp)
            let absolutePath = store.root.appendingPathComponent(path).path
            if let existing { guard string(existing,"path") == absolutePath else { throw VelaError("Prepared output path changed") } }
            record["path"] = absolutePath
            // A legacy prepared row without a base can only reconcile an
            // already-identical artifact. It cannot acquire a new write grant.
            let expected = existing.map { string($0,"baseHash","unavailable") }
            let journal = try files.writeManagedOutput(path:path,content:text,expectedBaseHash:expected) { before in
                if let latest = try self.store.get("run_output",id) {
                    try validateRecord(latest)
                    guard string(latest,"path") == absolutePath else { throw VelaError("Prepared output path changed") }
                    let base = string(latest,"baseHash","unavailable")
                    guard string(before,"hash") == base || string(before,"hash") == stableHash(text) else {
                        throw VelaError("Managed output changed after delivery was prepared; the newer artifact was preserved")
                    }
                    record = latest
                } else {
                    record["baseHash"] = string(before,"hash")
                    record = try self.store.putBatch([("run_output",record)],expectingAbsent:[("run_output",id)])[0]
                }
            }
            record["journalId"] = journal["id"] ?? record["journalId"] ?? NSNull()
        }
        record["state"] = "delivered"; record["deliveredAt"] = record["deliveredAt"] ?? isoNow(); record = try store.put("run_output",record)
        run["outputDelivery"] = record
        return try persistFinalWorkflowRun(run,expecting:expectingRunHash)
    }
}
