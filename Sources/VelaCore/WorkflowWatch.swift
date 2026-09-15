import Foundation

/// Read-only tool watches share the scheduler's lease and dispatch journal.
/// The observed data is bounded and authoritative; wall time is not a change.
enum WorkflowWatch {
    static let version = "vela-read-tool-watch-v1"
    static func validate(_ raw: Any?) throws -> JSON {
        if let input = raw as? JSON, string(input,"source") == "files" { return try WorkflowFileWatch.validate(input) }
        guard let input = raw as? JSON, Set(input.keys).isSubset(of:["source","tool","arguments","mode","key","everySeconds","minItems","debounceSeconds"]),
              input["source"] == nil || input["source"] as? String == "tool", input["mode"] == nil || input["mode"] is String,
              input["key"] == nil || input["key"] is String, let arguments = input["arguments"] as? JSON else { throw VelaError("Watch requires an explicit supported read tool and typed arguments") }
        let tool = try requireString(input,"tool"), capability = try AgentLoop.builtin(tool)
        try AgentLoop.validateValue(arguments,schema:capability["argumentsSchema"] as? JSON ?? [:])
        let mode = string(input,"mode",tool.hasPrefix("git.") ? "output" : "items")
        guard ["output","items"].contains(mode), !tool.hasPrefix("git.") || mode == "output" else { throw VelaError("Git watches compare bounded command output; context watches may compare item keys") }
        let key = string(input,"key","id")
        guard key.utf8.count <= 128, !key.isEmpty, key.split(separator:".",omittingEmptySubsequences:false).allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) }) else { throw VelaError("Watch key must be a bounded dot path") }
        let every = try WorkflowContext.integer(input["everySeconds"],default:60,range:30...86400,name:"watch polling interval")
        let minimum = try WorkflowContext.integer(input["minItems"],default:1,range:1...100,name:"watch minimum items")
        guard mode != "output" || minimum == 1 else { throw VelaError("A whole-output watch has one key and requires minItems 1") }
        return ["source":"tool","tool":tool,"arguments":arguments,"mode":mode,"key":key,"everySeconds":every,"minItems":minimum,"debounceSeconds":try WorkflowContext.integer(input["debounceSeconds"],default:5,range:0...300,name:"watch debounce")]
    }
    static func key(_ item: JSON, path: String) throws -> String {
        var value: Any = item
        for component in path.split(separator:".") {
            guard let next = (value as? JSON)?[String(component)] else { throw VelaError("Watch key is missing from a returned item") }; value = next
        }
        guard value is String || value is NSNumber, !(value is NSNull) else { throw VelaError("Watch keys must be scalar values") }
        let encoded = try WorkflowContext.jsonText(value)
        guard encoded.utf8.count <= 256 else { throw VelaError("Watch item key exceeds 256 bytes") }
        return encoded
    }
    static func entries(_ values: [JSON], key path: String) throws -> JSON {
        guard values.count <= 2000 else { throw VelaError("Watch snapshot exceeds 2000 items; watermark was not advanced") }
        var entries: JSON = [:]
        for value in values {
            let key = try key(value,path:path), identity = stableHash(key)
            guard entries[identity] == nil else { throw VelaError("Watch returned duplicate keys; watermark was not advanced") }
            entries[identity] = ["key":key,"value":value,"hash":stableHash(try jsonString(value))]
        }
        guard try jsonString(entries).utf8.count <= 128_000 else { throw VelaError("Watch snapshot exceeds 128 KB; watermark was not advanced") }
        return entries
    }
    static func merge(previous: JSON, current: JSON, pending: JSON, ignored: Set<String> = []) throws -> JSON {
        var result = pending
        for identity in Set(previous.keys).union(current.keys).union(ignored).sorted() {
            if ignored.contains(identity) { result.removeValue(forKey:identity); continue }
            let before = previous[identity] as? JSON, after = current[identity] as? JSON
            if before.map({string($0,"hash")}) == after.map({string($0,"hash")}) { continue }
            let retained = result[identity] as? JSON
            let original = retained? ["before"] as? JSON ?? before
            // An addition subsequently removed before dispatch has no net item.
            let originallyAbsent = retained?["before"] is NSNull || (retained == nil && before == nil)
            if (originallyAbsent && after == nil) || (!originallyAbsent && original.map({string($0,"hash")}) == after.map({string($0,"hash")})) { result.removeValue(forKey:identity); continue }
            result[identity] = ["key":after?["key"] ?? original?["key"] ?? "", "type":originallyAbsent ? "added" : (after == nil ? "removed" : "modified"), "before":originallyAbsent ? NSNull() : (original as Any? ?? NSNull()),"after":after as Any? ?? NSNull()]
        }
        guard result.count <= 100, try jsonString(result).utf8.count <= 192_000 else { throw VelaError("Watch pending changes exceed the bounded journal; watermark was not advanced") }
        return result
    }
}

extension AutomationService {
    func watchDetails(_ params: JSON) throws -> JSON {
        let root = try project(requireString(params,"project")), id = try requireString(params,"id")
        let definition = try loadCurrentWorkflow(id,synchronize:false)
        guard string(definition,"project") == root, string(definition,"trigger") == "watch" else { throw VelaError("Watch belongs to another project or is not configured") }
        return ["id":id,"project":root,"definition":try WorkflowWatch.validate(definition["watch"]),"state":try store.get("watch_state",id) as Any? ?? NSNull(),"schedule":try store.get("schedule",id) as Any? ?? NSNull(),"protocol":WorkflowWatch.version]
    }
    func previewWatch(_ params: JSON) throws -> JSON {
        let root = try project(requireString(params,"project")), id = try requireString(params,"id")
        let definition = try loadCurrentWorkflow(id,synchronize:false)
        guard string(definition,"project") == root, string(definition,"trigger") == "watch" else { throw VelaError("Watch belongs to another project or is not configured") }
        let policy = try WorkflowWatch.validate(definition["watch"]), captured = try captureWatch(policy,project:root)
        let existing = try store.get("watch_state",id), fingerprint = try watchFingerprint(definition,policy:policy)
        let baseline = existing == nil || string(existing!,"fingerprint") != fingerprint
        let entries = captured["entries"] as? JSON ?? [:]
        let ignored = try excludedWatchIdentities(existing?["observed"] as? JSON ?? [:],policy:policy,project:root)
        let merged = baseline ? JSON() : try WorkflowWatch.merge(previous:existing?["observed"] as? JSON ?? [:],current:entries,pending:existing?["pending"] as? JSON ?? [:],ignored:ignored)
        let pending = try pruneWatchPending(merged,policy:policy,project:root)
        let changes = string(policy,"source") == "files" ? WorkflowFileWatch.changes(pending) : pending.keys.sorted().compactMap { pending[$0] as? JSON }
        return ["dryRun":true,"mutated":false,"protocol":WorkflowWatch.version,"wouldInitializeBaseline":baseline,"snapshot":captured,"pending":pending,"changes":changes,"wouldMeetMinimum":changes.count >= intValue(policy,"minItems"),"workflowExecuted":false,"externalRequests":0]
    }
    private func watchFingerprint(_ workflow: JSON, policy: JSON) throws -> String {
        stableHash(try jsonString(["protocol":WorkflowWatch.version,"policy":policy,"workflowVersion":workflow["version"] ?? 0,"project":string(workflow,"project")]))
    }
    private func captureWatch(_ policy: JSON, project: String) throws -> JSON {
        if string(policy,"source") == "files" { return try WorkflowFileWatch.scan(project:project,policy:policy) }
        let tool = string(policy,"tool"), result = try executeLoopRead(tool,args:policy["arguments"] as? JSON ?? [:],project:project,timeoutSeconds:15)
        guard intValue(result,"exitCode") == 0, result["timedOut"] as? Bool != true, intValue(result,"terminationSignal") == 0 else { throw VelaError("Watch read did not complete; watermark was not advanced") }
        let entries: JSON
        if tool.hasPrefix("git.") {
            guard result["truncated"] as? Bool != true else { throw VelaError("Watch Git read was truncated; watermark was not advanced") }
            let value: JSON = ["id":"output","output":string(result,"output")]
            entries = try WorkflowWatch.entries([value],key:"id")
        } else {
            // Only public identities and content hashes enter the event input.
            // Text must be retrieved again through a workflow's scoped input.
            let sources = result["sources"] as? [JSON] ?? []
            let items = sources.map { ["id":string($0,"id"),"kind":string($0,"kind"),"contentHash":string($0,"contentHash")] as JSON }
            if string(policy,"mode") == "output" {
                entries = try WorkflowWatch.entries([["id":"output","items":items]],key:"id")
            } else { entries = try WorkflowWatch.entries(items,key:string(policy,"key")) }
        }
        return ["entries":entries,"snapshotHash":stableHash(try jsonString(entries)),"tool":tool,"argumentsHash":stableHash(try jsonString(policy["arguments"] ?? JSON())),"durationMs":result["durationMs"] ?? NSNull(),"window":"selected bounded read result; not an exhaustive remote catalogue","capturedAt":isoNow(),"externalRequests":0]
    }
    private func excludedWatchIdentities(_ entries: JSON, policy: JSON, project: String) throws -> Set<String> {
        guard ["memory.recall","library.retrieve"].contains(string(policy,"tool")) else { return [] }
        var excluded = Set<String>()
        for (key,raw) in entries {
            let entry = raw as? JSON ?? [:], value = entry["value"] as? JSON ?? [:]
            let sources = string(policy,"mode") == "output" ? value["items"] as? [JSON] ?? [] : [value]
            for source in sources {
                let id = string(source,"id"), kind = string(source,"kind")
                let allowed: Bool
                if kind == "library" { allowed = (try? LibrarySource.fresh(store:store,id:id)).map { LibraryIndex.isPublic($0,project:project) } ?? false }
                else if kind == "memory", let current = try store.get("memory",id) {
                    allowed = ModelImprovement.falseOrAbsent(current["private"]) && !privateLibraryPath(string(current,"sourcePath")) && string(current,"scope") != "private" && string(current,"state","active") == "active" && (string(current,"project") == project || (string(current,"scope") == "global" && string(current,"project").isEmpty))
                } else { allowed = false }
                if !allowed { excluded.insert(key) }
            }
        }
        return excluded
    }

    private func pruneWatchPending(_ pending: JSON, policy: JSON, project: String) throws -> JSON {
        // A removal has no `after`, and an output change may retain a revoked
        // source only in `before`. Neither can bypass the outbound boundary.
        var history: JSON = [:]
        for (key,raw) in pending {
            guard let change = raw as? JSON else { throw VelaError("Invalid durable watch change") }
            for side in ["before","after"] { if let entry = change[side] as? JSON { history[key + "|" + side] = entry } }
        }
        let revoked = try excludedWatchIdentities(history,policy:policy,project:project)
        let keys = Set(revoked.map { String($0.split(separator:"|")[0]) })
        return pending.filter { !keys.contains($0.key) }
    }

    /// Invoked only while the existing scheduler lease is held.
    func tickWatchWorkflow(_ workflow: JSON, at now: Date) throws {
        let id = string(workflow,"id"), root = string(workflow,"project"), policy = try WorkflowWatch.validate(workflow["watch"])
        let fingerprint = try watchFingerprint(workflow,policy:policy)
        var prior = try store.get("watch_state",id)
        var state = prior ?? ["id":id,"project":root,"workflowId":id]
        var schedule = try store.get("schedule",id) ?? ["id":id,"project":root,"workflowId":id]
        if let event = try store.unresolvedScheduleEvent(workflowId:id,project:root) {
            schedule["state"] = "needs_review"; schedule["blockedEventId"] = event["id"]; schedule["reason"] = "A watch dispatch has an uncertain outcome and will not be retried"
            if let previous = try store.get("schedule",id), try jsonString(previous) == jsonString(schedule) { return }
            _ = try store.put("schedule",schedule); return
        }
        let clock = now.timeIntervalSince1970
        let lastPoll = (state["lastPollEpoch"] as? NSNumber)?.doubleValue
        let initialize = prior == nil || string(state,"fingerprint") != fingerprint
        let isFile = string(policy,"source") == "files"
        let signal = isFile ? try fileWatchEvents.signal(id) : JSON()
        let fileChanged = isFile && (string(state,"fileObserverInstance") != string(signal,"instance") || intValue(state,"fileEventSerial") != intValue(signal,"serial"))
        let needsPoll = isFile ? fileChanged : (lastPoll == nil || clock < lastPoll! || clock - lastPoll! >= Double(intValue(policy,"everySeconds")))
        if initialize || needsPoll {
            let captured = try captureWatch(policy,project:root), current = captured["entries"] as? JSON ?? [:]
            let observed = state["observed"] as? JSON ?? [:], oldPending = state["pending"] as? JSON ?? [:]
            let ignored = try excludedWatchIdentities(observed,policy:policy,project:root)
            let merged = initialize ? JSON() : try WorkflowWatch.merge(previous:observed,current:current,pending:oldPending,ignored:ignored)
            let pending = try pruneWatchPending(merged,policy:policy,project:root)
            if initialize { state["initializedAt"] = ISO8601DateFormatter().string(from:now); state["discardedOnDefinitionChange"] = oldPending.count }
            if try jsonString(pending) != jsonString(oldPending) { state["lastChangeEpoch"] = clock }
            state["fingerprint"] = fingerprint; state["policy"] = policy; state["observed"] = current; state["pending"] = pending
            state["snapshotHash"] = captured["snapshotHash"]; state["receipt"] = captured.filter { $0.key != "entries" }
            state["lastPollEpoch"] = clock; state["nextPollEpoch"] = clock + Double(intValue(policy,"everySeconds")); state["revokedIdentitiesExcluded"] = ignored.count
            if isFile {
                let resumed = !initialize && string(state,"fileObserverInstance") != string(signal,"instance")
                state["fileObserverInstance"] = signal["instance"]; state["fileEventSerial"] = signal["serial"]; state["fileEventID"] = signal["eventID"]
                state["historyIncomplete"] = signal["historyIncomplete"] as? Bool == true || resumed || (!initialize && state["historyIncomplete"] as? Bool == true); state["nextPollEpoch"] = NSNull()
            }
            state["pollCount"] = intValue(state,"pollCount") + 1; state["state"] = pending.isEmpty ? "watching" : "accumulating"
            let expectations = try prior.map { [("watch_state",id,stableHash(try jsonString($0)))] } ?? []
            state = try store.putBatch([("watch_state",state)],expecting:expectations,expectingAbsent:prior == nil ? [("watch_state",id)] : [])[0]
            prior = state
        }
        let oldPending = state["pending"] as? JSON ?? [:]
        let pending = try pruneWatchPending(oldPending,policy:policy,project:root)
        if pending.count != oldPending.count {
            state["pending"] = pending; state["revokedIdentitiesExcluded"] = oldPending.count - pending.count
            state = try store.putBatch([("watch_state",state)],expecting:[("watch_state",id,stableHash(try jsonString(prior!)))])[0]; prior = state
        }
        schedule["trigger"] = "watch"; schedule["pendingItems"] = pending.count; schedule["nextPollEpoch"] = state["nextPollEpoch"]
        schedule["state"] = pending.isEmpty ? "watching" : "accumulating"
        schedule.removeValue(forKey:"reason"); schedule.removeValue(forKey:"error"); schedule.removeValue(forKey:"blockedEventId")
        let changedAt = (state["lastChangeEpoch"] as? NSNumber)?.doubleValue ?? clock
        let dispatchChanges = isFile ? WorkflowFileWatch.changes(pending) : pending.keys.sorted().compactMap { pending[$0] as? JSON }
        if dispatchChanges.count >= intValue(policy,"minItems"), clock - changedAt >= Double(intValue(policy,"debounceSeconds")) {
            if isFile, intValue(try fileWatchEvents.signal(id),"serial") != intValue(state,"fileEventSerial") {
                schedule["reason"] = "A newer file event arrived during capture; waiting for the next coherent observation"
                _ = try store.put("schedule",schedule); return
            }
            if try store.activeWorkflowRun(workflowId:id,project:root) != nil {
                schedule["state"] = "deferred"; schedule["reason"] = "The previous run is active or waiting for approval; new changes remain pending"
            } else if !VelaRuntimeShutdown.isRequested {
                // Recheck all queued context identities immediately before dispatch.
                let reviewed = try pruneWatchPending(pending,policy:policy,project:root)
                if reviewed.count != pending.count {
                    state["pending"] = reviewed; state["revokedIdentitiesExcluded"] = pending.count - reviewed.count
                    _ = try store.putBatch([("watch_state",state)],expecting:[("watch_state",id,stableHash(try jsonString(prior!)))])
                    return
                }
                let sequence = intValue(state,"dispatchSequence") + 1
                let input: JSON = ["protocol":WorkflowWatch.version,"source":string(policy,"source"),"tool":isFile ? "filesystem.snapshot" : string(policy,"tool"),"changes":dispatchChanges,"snapshotHash":state["snapshotHash"] ?? "","observedAt":state["receipt"].flatMap { ($0 as? JSON)?["capturedAt"] } ?? "","sequence":sequence]
                let key = "watch:" + fingerprint + ":" + String(sequence) + ":" + stableHash(try jsonString(input))
                let eventID = "event-" + String(stableHash(id + ":" + key).prefix(48))
                var event: JSON = ["id":eventID,"workflowId":id,"project":root,"eventKey":key,"state":"claimed","claimedAt":ISO8601DateFormatter().string(from:now),"watchInput":input,"inputHash":stableHash(try jsonString(input))]
                state["pending"] = JSON(); state["dispatchSequence"] = sequence; state["lastEventId"] = eventID; state["state"] = "claimed"
                schedule["state"] = "claimed"; schedule["lastEvent"] = key; schedule["pendingItems"] = 0
                _ = try store.putBatch([("schedule_event",event),("watch_state",state),("schedule",schedule)],expecting:[("watch_state",id,stableHash(try jsonString(prior!)))],expectingAbsent:[("schedule_event",eventID)])
                do {
                    let supplied: JSON = workflow["context"] != nil || WorkflowComposition.isComposite(workflow) ? ["watch":input] : [:]
                    var run = try startWorkflow(id:id,dryRun:false,snapshot:workflow,suppliedInputs:supplied)
                    run["scheduleEventId"] = eventID; run["watchInput"] = input; run = try store.put("run",run)
                    event["state"] = "dispatched"; event["runId"] = run["id"]
                    schedule["state"] = string(run,"state"); schedule["lastRunId"] = run["id"]
                } catch {
                    event["state"] = "needs_review"; event["error"] = error.localizedDescription
                    schedule["state"] = "needs_review"; schedule["error"] = error.localizedDescription
                }
                _ = try store.putBatch([("schedule_event",event),("schedule",schedule)])
                return
            }
        }
        if let previous = try store.get("schedule",id), try jsonString(previous) == jsonString(schedule) { return }
        _ = try store.put("schedule",schedule)
    }
}
