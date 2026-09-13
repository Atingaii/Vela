import Foundation

/// A bounded observation of explicit Codex metadata and tool acknowledgements.
/// It never interprets prompt prose, executes an agent, or infers process liveness.
enum SessionRelationProjection {
    static let version = "vela-codex-session-relations-v1"
    static let sourceCommit = "6b9826e3aa83b1a5947db50f4332cb9c65f1b340"
    static let maximumEvents = 128
    static let maximumPending = 32
    static let maximumSettled = 256
    static func empty() -> JSON {
        ["decoderVersion":version,"relationEpoch":UUID().uuidString.lowercased(),"provider":"codex","project":"",
         "headerState":"missing","sourceThreadId":NSNull(),"providerVersion":NSNull(),"parentCandidates":[String](),
         "parentThreadId":NSNull(),"forkedFromThreadId":NSNull(),"relationshipKind":"unknown","sourceSubtype":"unknown",
         "events":[JSON](),"pending":[JSON](),"settled":[JSON](),"sequence":0,"coverageLimited":false,
         "sourceContract":"codex-session-meta-and-multi-agent-v1-ack","referenceVersion":"0.154.0","sourceCommit":sourceCommit]
    }
    static func threadID(_ value: Any?) -> String? {
        guard let text = value as? String, text.utf8.count == 36, let parsed = UUID(uuidString:text) else { return nil }
        return parsed.uuidString.lowercased()
    }
    private static func bounded(_ value: Any?, _ maximum: Int = 256) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= maximum,
              value.rangeOfCharacter(from:.controlCharacters) == nil else { return nil }
        return value
    }
    private static func event(_ status: String, callID: String = "", child: String? = nil, reference: JSON, detail: String, state: inout JSON) {
        let sequence = intValue(state,"sequence") + 1; state["sequence"] = sequence
        var events = state["events"] as? [JSON] ?? []
        events.append(["sequence":sequence,"status":status,"tool":"spawn_agent","callId":callID,"childThreadId":child as Any? ?? NSNull(),"reference":reference,"detail":detail])
        if events.count > maximumEvents { events.removeFirst(events.count-maximumEvents); state["eventsTruncated"] = true }
        state["events"] = events
    }
    static func noteGap(_ reference: JSON, state: inout JSON) {
        state["pending"] = [JSON](); state["coverageLimited"] = true
        event("unknown",reference:reference,detail:"Unparsed or unobserved records invalidate pending spawn correlations",state:&state)
    }
    static func consume(_ row: JSON, reference: JSON, state: inout JSON, metadataOnly: Bool = false) {
        if state.isEmpty { state = empty() }
        guard let payload = row["payload"] as? JSON else { return }
        if string(row,"type") == "session_meta" {
            consumeHeader(payload,reference:reference,state:&state); return
        }
        guard !metadataOnly, string(row,"type") == "response_item", string(state,"headerState") == "observed" else { return }
        let type = string(payload,"type")
        if type == "function_call", let callID = bounded(payload["call_id"]), string(payload,"name") != "spawn_agent",
           (state["pending"] as? [JSON] ?? []).contains(where:{string($0,"callId") == callID}) {
            conflict(callID,reference:reference,state:&state); return
        }
        if type == "function_call", string(payload,"name") == "spawn_agent" {
            guard payload["namespace"] == nil || payload["namespace"] is NSNull || string(payload,"namespace") == "multi_agent_v1" else {
                if let callID = bounded(payload["call_id"]) { conflict(callID,reference:reference,state:&state) }
                event("unsupported_namespace",reference:reference,detail:"Only unnamespaced or multi_agent_v1 spawn acknowledgement format is supported",state:&state); return
            }
            guard let callID = bounded(payload["call_id"]), let arguments = payload["arguments"] as? String,
                  arguments.utf8.count <= 65536, let bytes = arguments.data(using:.utf8),
                  (try? JSONSerialization.jsonObject(with:bytes)) is JSON else {
                if let callID = bounded(payload["call_id"]) { conflict(callID,reference:reference,state:&state) }
                event("invalid_proposal",reference:reference,detail:"Spawn call identity or bounded JSON arguments are invalid",state:&state); return
            }
            var pending = state["pending"] as? [JSON] ?? []
            let hash = stableHash(arguments), settled = state["settled"] as? [JSON] ?? []
            if let old = pending.first(where:{string($0,"callId") == callID}) {
                if string(old,"argumentsHash") != hash { pending.removeAll{string($0,"callId") == callID}; state["pending"] = pending; event("conflict",callID:callID,reference:reference,detail:"One spawn call ID carried different arguments",state:&state); settle(callID,hash:"conflict",state:&state) }
                return
            }
            if settled.contains(where:{string($0,"callId") == callID}) {
                conflict(callID,reference:reference,state:&state); return
            }
            if pending.count >= maximumPending { pending.removeFirst(); state["coverageLimited"] = true }
            pending.append(["callId":callID,"argumentsHash":hash,"namespace":payload["namespace"] ?? NSNull(),"reference":reference]); state["pending"] = pending
            event("proposed",callID:callID,reference:reference,detail:"Provider recorded a spawn request; completion is not yet observed",state:&state)
        } else if type == "function_call_output", let callID = bounded(payload["call_id"]) {
            var pending = state["pending"] as? [JSON] ?? []
            guard let index = pending.firstIndex(where:{string($0,"callId") == callID}) else {
                if let old = (state["settled"] as? [JSON] ?? []).first(where:{string($0,"callId") == callID}) {
                    let compatible = (payload["name"] == nil || string(payload,"name") == "spawn_agent")
                        && (payload["namespace"] == nil || payload["namespace"] is NSNull || string(payload,"namespace") == "multi_agent_v1")
                    if !compatible || (payload["output"] as? String).map(stableHash) != string(old,"responseHash") { conflict(callID,reference:reference,state:&state) }
                }
                return
            }
            let proposed = pending.remove(at:index); state["pending"] = pending
            guard (payload["name"] == nil || string(payload,"name") == "spawn_agent"),
                  (payload["namespace"] == nil || payload["namespace"] is NSNull || string(payload,"namespace") == "multi_agent_v1"),
                  let output = payload["output"] as? String, output.utf8.count <= 16384,
                  let value = (try? JSONSerialization.jsonObject(with:Data(output.utf8))) as? JSON,
                  Set(value.keys).isSubset(of:["agent_id","nickname"]),
                  (value["nickname"] == nil || value["nickname"] is NSNull || bounded(value["nickname"],200) != nil),
                  let child = threadID(value["agent_id"]), child != string(state,"sourceThreadId") else {
                event("unknown_result",callID:callID,reference:reference,detail:"Spawn response is not the supported structured agent_id acknowledgement",state:&state)
                settle(callID,hash:"unknown",state:&state); return
            }
            var receipt = reference; receipt["proposalReference"] = proposed["reference"]
            event("reported_spawned",callID:callID,child:child,reference:receipt,detail:"Provider acknowledged an agent ID; child source and parent metadata are checked separately",state:&state)
            settle(callID,hash:stableHash(output),state:&state)
        }
    }
    private static func conflict(_ id: String, reference: JSON, state: inout JSON) {
        state["pending"] = (state["pending"] as? [JSON] ?? []).filter{string($0,"callId") != id}
        if !(state["settled"] as? [JSON] ?? []).contains(where:{string($0,"callId") == id}) { settle(id,hash:"conflict",state:&state) }
        var events = state["events"] as? [JSON] ?? []
        for index in events.indices where string(events[index],"callId") == id && string(events[index],"status") == "reported_spawned" {
            events[index]["reportedChildThreadId"] = events[index]["childThreadId"]; events[index]["childThreadId"] = NSNull(); events[index]["status"] = "conflict"
        }
        state["events"] = events
        event("conflict",callID:id,reference:reference,detail:"A spawn call has inconsistent observations; no unique child can be resolved",state:&state)
    }
    private static func settle(_ id: String, hash: String, state: inout JSON) {
        var records = state["settled"] as? [JSON] ?? []
        records.append(["callId":id,"responseHash":hash])
        if records.count > maximumSettled { records.removeFirst(records.count-maximumSettled); state["coverageLimited"] = true }
        state["settled"] = records
    }
    private static func consumeHeader(_ payload: JSON, reference: JSON, state: inout JSON) {
        let project = (payload["cwd"] as? String).flatMap { $0.hasPrefix("/") && $0.rangeOfCharacter(from:.controlCharacters) == nil ? canonicalProject($0) : nil } ?? ""
        let source = threadID(payload["id"])
        var facts: JSON = ["sourceThreadId":source as Any? ?? NSNull(),"project":project,"providerVersion":bounded(payload["cli_version"],128) as Any? ?? NSNull(),"parentCandidates":[String](),"parentThreadId":NSNull(),"forkedFromThreadId":NSNull(),"relationshipKind":"none_observed","sourceSubtype":"unknown","sourceInternal":false]
        var invalid = source == nil || project.isEmpty, candidates: [String] = [], claims: [JSON] = []
        func parent(_ value: Any?, field: String) {
            guard let value, !(value is NSNull) else { return }
            guard let id = threadID(value) else { invalid = true; return }
            candidates.append(id); claims.append(["field":field,"threadId":id])
        }
        parent(payload["parent_thread_id"],field:"parent_thread_id")
        if let value = payload["forked_from_id"], !(value is NSNull) {
            if let fork = threadID(value) { facts["forkedFromThreadId"] = fork } else { invalid = true }
        }
        if let simple = payload["source"] as? String { facts["sourceSubtype"] = bounded(simple,64) ?? "unknown" }
        else if let sourceObject = payload["source"] as? JSON, sourceObject["internal"] != nil {
            facts["sourceInternal"] = true
            let name = string(sourceObject,"internal")
            facts["sourceSubtype"] = ["guardian","memory_consolidation"].contains(name) ? "internal:" + name : "internal_unsupported"
        }
        else if let sourceObject = payload["source"] as? JSON, let subagent = sourceObject["subagent"] {
            facts["sourceSubtype"] = "subagent_unknown"
            if let nested = subagent as? JSON, let spawn = nested["thread_spawn"] as? JSON {
                facts["sourceSubtype"] = "thread_spawn"
                guard let depth = usageTokenCount(spawn["depth"]), depth <= 4294967295 else { invalid = true; finishHeader(facts,claims:claims,candidates:candidates,invalid:invalid,reference:reference,state:&state); return }
                facts["depth"] = depth
                if spawn["parent_thread_id"] == nil || spawn["parent_thread_id"] is NSNull { invalid = true }
                parent(spawn["parent_thread_id"],field:"source.subagent.thread_spawn.parent_thread_id")
                for key in ["agent_nickname","agent_role"] { if let text = bounded(spawn[key],200) { facts[key] = text } }
            } else if let malformed = subagent as? JSON, malformed["thread_spawn"] != nil { invalid = true
            } else if let named = subagent as? String { facts["sourceSubtype"] = "subagent:" + (bounded(named,64) ?? "unknown") }
            else if let named = (subagent as? JSON)?["other"] as? String { facts["sourceSubtype"] = "subagent:other:" + (bounded(named,64) ?? "unknown") }
        }
        if payload["source"] != nil, !(payload["source"] is String), !(payload["source"] is JSON) { invalid = true }
        finishHeader(facts,claims:claims,candidates:candidates,invalid:invalid,reference:reference,state:&state)
    }
    private static func finishHeader(_ input: JSON, claims: [JSON], candidates: [String], invalid: Bool, reference: JSON, state: inout JSON) {
        var facts = input; let unique = Array(Set(candidates)).sorted()
        facts["parentCandidates"] = unique; facts["parentClaims"] = claims
        let selfParent = unique.contains(string(facts,"sourceThreadId"))
        let status = invalid ? "invalid" : unique.count > 1 || selfParent ? "conflict" : "observed"
        if status == "observed", let parent = unique.first {
            facts["parentThreadId"] = parent
            facts["relationshipKind"] = string(facts,"sourceSubtype") == "thread_spawn" ? "thread_spawn" : "provider_parent_metadata"
        } else if status == "observed", facts["forkedFromThreadId"] is String { facts["relationshipKind"] = "fork_only" }
        else if status == "observed", string(facts,"sourceSubtype").hasPrefix("subagent") { facts["relationshipKind"] = "unresolved_subagent" }
        let fingerprint = (try? jsonString(facts)).map(stableHash) ?? ""
        if let existing = state["headerFingerprint"] as? String {
            guard existing != fingerprint else { return }
            if facts["sourceInternal"] as? Bool == true { state["sourceInternal"] = true }
            state["headerState"] = "conflict"; state["parentThreadId"] = NSNull(); state["parentCandidates"] = Array(Set((state["parentCandidates"] as? [String] ?? [])+unique)).sorted()
            state["pending"] = [JSON](); state["coverageLimited"] = true
            event("conflict",reference:reference,detail:"Conflicting metadata headers in one observed source epoch",state:&state); return
        }
        state.merge(facts){_,new in new}; state["headerFingerprint"] = fingerprint; state["headerState"] = status; state["headerEvidence"] = reference
        if status != "observed" { state["coverageLimited"] = true }
    }
    static func summary(_ state: JSON) -> JSON {
        state.filter{["decoderVersion","relationEpoch","sourceThreadId","headerState","relationshipKind","sourceSubtype","parentThreadId","forkedFromThreadId","coverageLimited"].contains($0.key)}
    }
}
