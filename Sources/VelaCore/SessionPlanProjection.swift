import Foundation

/// An observation of provider acknowledgements, never a verifier of the work.
/// The private correlation ledger lives outside the dashboard session object.
enum SessionPlanProjection {
    static let version = "vela-session-plans-v1"
    static let maximumItems = 256
    static let maximumContentBytes = 65536
    static let maximumEvents = 128
    static let maximumPending = 16
    static let tools: Set<String> = ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskGet", "TaskList"]

    static func empty(provider: String) -> JSON {
        ["decoderVersion": version, "provider": provider, "project": "", "items": [JSON](),
         "pending": [JSON](), "events": [JSON](), "sequence": 0, "confirmedRevision": 0,
         "itemSetComplete": false, "coverageLimited": false, "workVerified": false]
    }

    static func consume(_ row: JSON, provider: String, reference: JSON, state: inout JSON, metadataOnly: Bool = false) {
        guard ["codex", "claude"].contains(provider) else { return }
        if state.isEmpty { state = empty(provider: provider) }
        let payload = row["payload"] as? JSON ?? [:]
        let type = string(row, "type"), context = provider == "codex" ? payload : row
        let sourceSession = provider == "codex" && type == "session_meta" ? boundedString(payload["id"], 1024) : provider == "claude" ? boundedString(row["sessionId"], 1024) : nil
        if let sourceSession, !string(state,"sourceSessionId").isEmpty, sourceSession != string(state,"sourceSessionId") {
            state = empty(provider:provider)
            // A new session in the same file needs its own explicit scope too.
            state["coverageLimited"] = true
        }
        if let cwd = context["cwd"] {
            let project = (cwd as? String).flatMap { $0.hasPrefix("/") ? canonicalProject($0) : nil } ?? ""
            if project != string(state, "project") {
                let wasKnown = !string(state, "project").isEmpty
                state["items"] = [JSON](); state["pending"] = [JSON](); state["itemSetComplete"] = false
                state["confirmedRevision"] = 0; state.removeValue(forKey: "lastConfirmed")
                // A source changing project must not return old project contents.
                state["events"] = [JSON](); state["settledCallIds"] = [String](); state["project"] = project
                if wasKnown && !metadataOnly { record("scope_changed", tool: "", callID: "", reference: reference, detail: "Previous project plan and correlations discarded", state: &state) }
            }
        }
        if provider == "codex", type == "session_meta" {
            if let value = boundedString(payload["id"], 1024) { state["sourceSessionId"] = value }
            state["providerVersion"] = boundedString(payload["cli_version"], 128) as Any? ?? NSNull()
            state["formatContract"] = "codex-rollout-function-call-v1"
        } else if provider == "claude" {
            if let value = boundedString(row["sessionId"], 1024) { state["sourceSessionId"] = value }
            if let value = boundedString(row["version"], 128) { state["providerVersion"] = value }
            state["formatContract"] = "claude-tool-use-result-v1"
        }
        guard !metadataOnly else { return }
        if provider == "codex", type == "response_item" {
            if string(payload, "type") == "function_call", string(payload, "name") == "update_plan" {
                let arguments = boundedString(payload["arguments"], maximumContentBytes)
                let input = arguments.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? JSON }
                propose(tool: "update_plan", callID: string(payload, "call_id"), input: input, reference: reference, state: &state)
            } else if string(payload, "type") == "function_call_output" {
                complete(callID: string(payload, "call_id"), result: payload["output"], isError: nil, reference: reference, state: &state)
            }
        } else if provider == "claude", let message = row["message"] as? JSON,
                  let blocks = message["content"] as? [JSON] {
            if type == "assistant", string(message, "role", type) == "assistant" {
                for block in blocks where string(block, "type") == "tool_use" && tools.contains(string(block, "name")) {
                    propose(tool: string(block, "name"), callID: string(block, "id"), input: block["input"] as? JSON, reference: reference, state: &state)
                }
            } else if type == "user", string(message, "role", type) == "user" {
                let results = blocks.filter { string($0, "type") == "tool_result" }
                // SDK's structured output belongs to the message, not each block.
                // Do not assign one output to several different tool invocations.
                let output = row["tool_use_result"]
                for block in results {
                    complete(callID: string(block, "tool_use_id"), result: results.count == 1 ? output : nil,
                             isError: block["is_error"], reference: reference, state: &state)
                }
            }
        }
    }

    static func noteGap(_ reference: JSON, state: inout JSON) {
        guard !state.isEmpty else { return }
        state["pending"] = [JSON](); state["coverageLimited"] = true
        record("unknown", tool: "", callID: "", reference: reference, detail: "Malformed source record; pending correlations cleared", state: &state)
    }

    private static func boundedString(_ value: Any?, _ bytes: Int) -> String? {
        guard let text = value as? String, text.utf8.count <= bytes, !text.contains("\0") else { return nil }
        return text
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func canonicalInput(_ raw: JSON, tool: String) throws -> JSON {
        guard (try jsonString(raw)).utf8.count <= maximumContentBytes else { throw VelaError("Plan input exceeds budget") }
        var input = raw
        if tool == "TaskUpdate" || tool == "TaskGet" {
            let ids = ["taskId", "id", "task_id"].compactMap { raw[$0] as? String }
            guard let id = ids.first, !id.isEmpty, boundedString(id, 256) != nil, Set(ids).count == 1 else { throw VelaError("Task ID is absent or ambiguous") }
            input["taskId"] = id
        }
        if raw["activeForm"] != nil || raw["active_form"] != nil {
            let values = ["activeForm", "active_form"].compactMap { raw[$0] as? String }
            guard let value = values.first, Set(values).count == 1, boundedString(value, 4096) != nil else { throw VelaError("Task active form is invalid") }
            input["activeForm"] = value
        }
        switch tool {
        case "update_plan":
            guard let rows = raw["plan"] as? [JSON] else { throw VelaError("Plan is not an item array") }
            _ = try normalizedItems(rows, style: "codex")
        case "TodoWrite":
            guard let rows = raw["todos"] as? [JSON] else { throw VelaError("Todos is not an item array") }
            _ = try normalizedItems(rows, style: "todo")
        case "TaskCreate":
            guard let subject = boundedString(raw["subject"], 4096), !subject.isEmpty else { throw VelaError("Task subject is invalid") }
        case "TaskUpdate", "TaskGet", "TaskList": break
        default: throw VelaError("Unsupported plan tool")
        }
        return input
    }

    private static func normalizedItems(_ rows: [JSON], style: String) throws -> [JSON] {
        guard rows.count <= maximumItems, (try jsonString(rows)).utf8.count <= maximumContentBytes else { throw VelaError("Plan item budget exceeded") }
        var ids: Set<String> = []
        return try rows.enumerated().map { index, raw in
            let textKey = style == "codex" ? "step" : style == "todo" ? "content" : "subject"
            guard let text = boundedString(raw[textKey], 4096), !text.isEmpty,
                  let status = boundedString(raw["status"], 128), !status.isEmpty else { throw VelaError("Plan item shape is unknown") }
            let id = style == "task" ? boundedString(raw["id"], 256) ?? "" : "position-\(index)"
            guard !id.isEmpty, ids.insert(id).inserted else { throw VelaError("Task identity is absent or repeated") }
            var item: JSON = ["id": id, "content": text, "status": ["pending", "in_progress", "completed", "deleted"].contains(status) ? status : "unknown", "sourceStatus": status]
            if style != "task", status == "deleted" { item["status"] = "unknown" }
            if let active = raw["activeForm"] {
                guard let text = boundedString(active, 4096) else { throw VelaError("Active form is invalid") }
                item["activeForm"] = text
            }
            if style == "task" {
                for key in ["description", "owner"] where raw[key] != nil {
                    guard let text = boundedString(raw[key], 8192) else { throw VelaError("Task detail exceeds budget") }
                    item[key] = text
                }
                for key in ["blocks", "blockedBy"] where raw[key] != nil {
                    guard let values = raw[key] as? [String], values.count <= maximumItems, values.allSatisfy({ boundedString($0, 256) != nil }) else { throw VelaError("Task dependency identity is invalid") }
                    item[key] = values
                }
            }
            return item
        }
    }

    private static func propose(tool: String, callID: String, input: JSON?, reference: JSON, state: inout JSON) {
        guard !string(state, "project").isEmpty else { record("unknown", tool: tool, callID: "", reference: reference, detail: "Project identity unavailable", state: &state); return }
        guard !callID.isEmpty, boundedString(callID, 1024) != nil else {
            record("unknown", tool: tool, callID: "", reference: reference, detail: "Unsupported or over-budget tool input", state: &state); return
        }
        var pending = state["pending"] as? [JSON] ?? []
        if let existing = pending.firstIndex(where: { string($0, "callId") == callID }) {
            // Duplicate or revised calls cannot share an acknowledgement safely.
            pending[existing]["ambiguous"] = true; state["pending"] = pending
            record("unknown", tool: tool, callID: callID, reference: reference, detail: "Repeated call ID is ambiguous", state: &state); return
        }
        let completed = state["settledCallIds"] as? [String] ?? []
        if completed.contains(callID) { record("unknown", tool: tool, callID: callID, reference: reference, detail: "Previously settled call ID was reused", state: &state); return }
        guard let input, let canonical = try? canonicalInput(input, tool: tool) else {
            record("unknown", tool: tool, callID: callID, reference: reference, detail: "Unsupported or over-budget tool input", state: &state); return
        }
        if pending.count >= maximumPending || ((try? jsonString(pending).utf8.count) ?? 0) + ((try? jsonString(canonical).utf8.count) ?? 0) > 262144 {
            state["coverageLimited"] = true
            record("unknown", tool: tool, callID: callID, reference: reference, detail: "Pending correlation budget exceeded", state: &state); return
        }
        let event = record("proposed", tool: tool, callID: callID, reference: reference, detail: "Awaiting matching provider acknowledgement", state: &state)
        pending.append(["callId": callID, "tool": tool, "input": canonical, "source": reference, "sequence": event, "project": string(state, "project")])
        state["pending"] = pending
    }

    private static func codexSuccess(_ value: Any?) -> Bool {
        if let text = value as? String { return text == "Plan updated" }
        if let blocks = value as? [JSON], blocks.count == 1 {
            return string(blocks[0], "type") == "input_text" && string(blocks[0], "text") == "Plan updated"
        }
        return false
    }
    private static func complete(callID: String, result: Any?, isError: Any?, reference: JSON, state: inout JSON) {
        var pending = state["pending"] as? [JSON] ?? []
        guard let index = pending.firstIndex(where: { string($0, "callId") == callID }) else { return }
        let call = pending.remove(at: index); state["pending"] = pending
        var settled = state["settledCallIds"] as? [String] ?? []
        settled.append(callID); if settled.count > 512 { settled.removeFirst(settled.count - 512); state["coverageLimited"] = true }
        state["settledCallIds"] = settled
        let tool = string(call, "tool"), input = call["input"] as? JSON ?? [:]
        var proof = reference; proof["callSource"] = call["source"]; proof["callSequence"] = call["sequence"]
        guard call["ambiguous"] as? Bool != true, string(call, "project") == string(state, "project") else {
            record("unknown", tool: tool, callID: callID, reference: proof, detail: "Ambiguous or cross-project result", state: &state); return
        }
        if boolean(isError) == true {
            record("failed", tool: tool, callID: callID, reference: proof, detail: "Provider tool_result is_error", state: &state); return
        }
        if isError != nil && boolean(isError) == nil {
            record("unknown", tool: tool, callID: callID, reference: proof, detail: "Invalid error marker", state: &state); return
        }
        let output = result as? JSON ?? [:]
        if output["success"] != nil, boolean(output["success"]) == nil {
            record("unknown", tool: tool, callID: callID, reference: proof, detail: "Invalid structured success marker", state: &state); return
        }
        if tool != "update_plan", boolean(output["success"]) == false {
            record("failed", tool: tool, callID: callID, reference: proof, detail: "Provider structured success is false", state: &state); return
        }
        do {
            var items = state["items"] as? [JSON] ?? []
            var completeSet = state["itemSetComplete"] as? Bool == true
            let family = tool == "update_plan" ? "codex_plan" : tool == "TodoWrite" ? "claude_todos" : "claude_tasks"
            if !string(state,"family").isEmpty, string(state,"family") != family { items = []; completeSet = false }
            switch tool {
            case "update_plan":
                guard codexSuccess(result) else { throw VelaError("No recognized Codex success acknowledgement") }
                items = try normalizedItems(input["plan"] as? [JSON] ?? [], style: "codex"); completeSet = true
            case "TodoWrite":
                guard let rows = output["newTodos"] as? [JSON] else { throw VelaError("No structured persisted TodoWrite snapshot") }
                items = try normalizedItems(rows, style: "todo"); completeSet = true
            case "TaskCreate":
                guard let task = output["task"] as? JSON, let id = boundedString(task["id"], 256), !id.isEmpty,
                      let subject = boundedString(task["subject"], 4096), !subject.isEmpty,
                      !items.contains(where: { string($0, "id") == id }) else { throw VelaError("TaskCreate ID is missing or already known") }
                var created: JSON = ["id": id, "subject": subject, "status": "pending"]
                if let active = input["activeForm"] { created["activeForm"] = active }
                items += try normalizedItems([created], style: "task")
            case "TaskUpdate":
                let id = string(input, "taskId")
                guard boolean(output["success"]) == true, string(output, "taskId") == id,
                      let updated = output["updatedFields"] as? [String], updated.count <= 32 else { throw VelaError("No matching successful TaskUpdate acknowledgement") }
                guard let index = items.firstIndex(where: { string($0, "id") == id }) else { throw VelaError("TaskUpdate has no observed task baseline") }
                if updated.contains("status") {
                    guard let change = output["statusChange"] as? JSON, let to = boundedString(change["to"], 128), !to.isEmpty,
                          let from = boundedString(change["from"], 128), from == string(items[index], "sourceStatus"),
                          to == input["status"] as? String else { throw VelaError("TaskUpdate status transition lacks a matching baseline") }
                    items[index]["sourceStatus"] = to; items[index]["status"] = ["pending", "in_progress", "completed", "deleted"].contains(to) ? to : "unknown"
                }
                for key in ["subject", "activeForm", "description", "owner"] where updated.contains(key) {
                    guard let text = boundedString(input[key], key == "description" ? 8192 : 4096) else { throw VelaError("Updated task field unavailable") }
                    items[index][key == "subject" ? "content" : key] = text
                }
                if updated.contains(where: { !["status", "subject", "activeForm", "description", "owner"].contains($0) }) { state["coverageLimited"] = true }
            case "TaskGet":
                guard let task = output["task"] as? JSON, string(task, "id") == string(input, "taskId") else { throw VelaError("TaskGet is unavailable or has another identity") }
                let read = try normalizedItems([task], style: "task")[0]
                if let index = items.firstIndex(where: { string($0, "id") == string(read, "id") }) { items[index] = read } else { items.append(read) }
            case "TaskList":
                guard let rows = output["tasks"] as? [JSON] else { throw VelaError("TaskList snapshot unavailable") }
                items = try normalizedItems(rows, style: "task"); completeSet = true
            default: throw VelaError("Unsupported tool")
            }
            guard items.count <= maximumItems, (try jsonString(items)).utf8.count <= maximumContentBytes else { throw VelaError("Accumulated task budget exceeded") }
            state["items"] = items; state["itemSetComplete"] = completeSet; state["family"] = family
            state["confirmedRevision"] = intValue(state, "confirmedRevision") + 1
            let sequence = record("confirmed", tool: tool, callID: callID, reference: proof, detail: "Provider acknowledgement; work correctness is not verified", state: &state)
            state["lastConfirmed"] = ["sequence": sequence, "tool": tool, "callId": callID, "source": proof]
        } catch {
            record("unknown", tool: tool, callID: callID, reference: proof, detail: error.localizedDescription, state: &state)
        }
    }

    @discardableResult private static func record(_ status: String, tool: String, callID: String, reference: JSON, detail: String, state: inout JSON) -> Int {
        let sequence = intValue(state, "sequence") + 1; state["sequence"] = sequence
        var events = state["events"] as? [JSON] ?? []
        events.append(["sequence": sequence, "state": status, "tool": tool, "callId": String(callID.prefix(1024)), "source": reference,
                       "detail": detail, "sourceSessionId": state["sourceSessionId"] ?? NSNull(), "providerVersion": state["providerVersion"] ?? NSNull()])
        if events.count > maximumEvents { events.removeFirst(events.count - maximumEvents); state["eventsTruncated"] = true }
        state["events"] = events
        return sequence
    }

    static func summary(_ state: JSON, provider: String, historyTruncated: Bool = false) -> JSON {
        let items = state["items"] as? [JSON] ?? [], active = items.filter { string($0, "status") != "deleted" }
        let known = intValue(state, "confirmedRevision") > 0
        let counts: JSON = Dictionary(uniqueKeysWithValues: ["pending", "in_progress", "completed", "unknown", "deleted"].map { status in (status, items.filter { string($0, "status") == status }.count) })
        return ["supported": ["claude", "codex"].contains(provider), "available": known, "decoderVersion": version,
                "total": known ? active.count as Any : NSNull(), "counts": known ? counts as Any : NSNull(),
                "itemSetComplete": state["itemSetComplete"] as? Bool == true, "pendingUpdates": (state["pending"] as? [JSON] ?? []).count,
                "coverageLimited": historyTruncated || state["coverageLimited"] as? Bool == true || state["eventsTruncated"] as? Bool == true,
                "sourceCoverage": "bounded indexed JSONL observations", "workVerified": false,
                "confirmedRevision": intValue(state, "confirmedRevision"), "lastConfirmed": state["lastConfirmed"] ?? NSNull()]
    }

    static func visible(_ state: JSON, provider: String, historyTruncated: Bool = false) -> JSON {
        var result = summary(state, provider: provider, historyTruncated: historyTruncated)
        for key in ["id", "project", "sourceSessionId", "providerVersion", "formatContract", "sourceIdentity"] { result[key] = state[key] ?? NSNull() }
        result["provider"] = provider; result["items"] = state["items"] as? [JSON] ?? []
        return result
    }
}
