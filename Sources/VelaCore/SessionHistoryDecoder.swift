import Foundation

enum SessionHistoryDecoder {
    static let maximumRecordBytes = 8 * 1024 * 1024
    static func decode(_ bytes: Data, provider: String, state: inout JSON, ordinal: Int, terminated: Bool) -> JSON {
        var event: JSON = ["ordinal": ordinal, "type": "unknown", "normalized": false, "project": "", "timestamp": NSNull(), "timestampSource": "unavailable", "providerId": "", "parentId": NSNull(), "liveStatusAvailable": false]
        guard bytes.count <= maximumRecordBytes else {
            state["currentProject"] = ""; event["diagnostic"] = "record_exceeds_normalizer_budget"; return event
        }
        guard let row = (try? JSONSerialization.jsonObject(with: bytes)) as? JSON else {
            if bytes.allSatisfy({ [10, 13, 32, 9].contains($0) }) { event["type"] = "whitespace"; event["normalized"] = true; event["project"] = string(state, "currentProject"); return event }
            state["currentProject"] = ""; event["diagnostic"] = terminated ? "malformed_json_record" : "unterminated_invalid_tail"; return event
        }
        let type = string(row, "type"), payload = row["payload"] as? JSON ?? [:], message = row["message"] as? JSON ?? [:]
        let context = provider == "codex" ? payload : row
        if let cwd = context["cwd"] {
            state["currentProject"] = (cwd as? String).flatMap { $0.hasPrefix("/") ? canonicalProject($0) : nil } ?? ""
        }
        event["project"] = string(state, "currentProject")
        event["sourceType"] = type
        if let timestamp = row["timestamp"] as? String, timestamp.utf8.count <= 100 {
            event["timestamp"] = timestamp; event["timestampSource"] = "provider"
        } else if let timestamp = usageTokenCount(message["timestamp"]) {
            event["timestamp"] = timestamp; event["timestampSource"] = "provider_numeric_milliseconds"
        }
        if let branch = row["gitBranch"] as? String { event["gitBranch"] = String(branch.prefix(1024)) }
        if ["pi", "omp"].contains(provider) {
            if type == "session" {
                guard state["headerSeen"] as? Bool != true else { state["currentProject"] = ""; event["project"] = ""; event["diagnostic"] = "duplicate_session_header"; return event }
                state["headerSeen"] = true
                event["type"] = "metadata"; event["normalized"] = true
                event["sourceSessionId"] = string(row, "id"); return event
            }
            if provider == "omp", type == "title", ordinal == 0 {
                event["type"] = "metadata"; event["normalized"] = true; event["preview"] = preview(row["title"]); return event
            }
            let version = intValue(state, "sourceFormatVersion")
            let id = version == 1 ? string(row, "id", "legacy-record-\(ordinal)") : string(row, "id")
            guard !id.isEmpty, id.utf8.count <= 1024, version == 1 || row["parentId"] is NSNull || row["parentId"] is String else { event["diagnostic"] = "invalid_branch_identity"; return event }
            let parent: Any = version == 1 ? (state["lastProviderId"] as? String).map { $0 as Any } ?? NSNull() : row["parentId"] ?? NSNull()
            guard !(parent is String) || (parent as! String).utf8.count <= 1024 else { event["diagnostic"] = "invalid_parent_identity"; return event }
            event["providerId"] = id; event["parentId"] = parent
            state["lastProviderId"] = id
            event["parentSource"] = version == 1 ? "legacy_file_order" : "provider_parentId"
            let known = Set(["message", "model_change", "thinking_level_change", "service_tier_change", "compaction", "branch_summary", "reset_boundary", "custom", "custom_message", "label", "session_info", "title_change", "ttsr_injection", "credential_pin", "session_init", "mode_change"])
            event["normalized"] = known.contains(type)
            if type == "message" {
                let role = string(message, "role")
                event["normalized"] = Set(["user", "developer", "assistant", "toolResult", "bashExecution", "pythonExecution", "fileMention", "custom", "hookMessage", "compactionSummary", "branchSummary"]).contains(role)
                event["type"] = role == "toolResult" ? "tool_result" : "message"; event["role"] = role
                event["preview"] = preview(message["content"])
                if let usage = message["usage"] as? JSON { event["usage"] = usageSummary(usage, keys: ["input", "output", "cacheRead", "cacheWrite", "totalTokens"]) }
                if let model = message["model"] as? String { event["model"] = String(model.prefix(256)) }
                if let call = message["toolCallId"] as? String { event["toolCallId"] = String(call.prefix(1024)) }
                if let name = message["toolName"] as? String { event["toolName"] = String(name.prefix(256)) }
                if let reason = message["stopReason"] as? String { event["stopReason"] = String(reason.prefix(256)) }
            } else { event["type"] = known.contains(type) ? "context" : "unknown"; event["preview"] = preview(row["summary"] ?? row["text"] ?? row["title"] ?? row["name"]) }
        } else if provider == "claude" {
            event["providerId"] = String(string(row, "uuid", string(message, "id")).prefix(1024))
            if let parent = row["parentUuid"] as? String { event["parentId"] = String(parent.prefix(1024)); event["parentSource"] = "provider_parentUuid" }
            if !message.isEmpty {
                event["type"] = "message"; event["normalized"] = true; event["role"] = string(message, "role", type); event["preview"] = preview(message["content"])
                if let usage = message["usage"] as? JSON { event["usage"] = usageSummary(usage, keys: ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]) }
                if let model = message["model"] as? String { event["model"] = String(model.prefix(256)) }
            } else if ["result", "error", "permission_request", "approval_requested"].contains(type) {
                event["type"] = "state"; event["normalized"] = true; event["preview"] = preview(row["result"] ?? row["message"])
            }
        } else if provider == "codex" {
            event["providerId"] = String(string(payload, "id", string(payload, "call_id")).prefix(1024))
            let payloadType = string(payload, "type")
            if ["session_meta", "turn_context"].contains(type) {
                event["type"] = "context"; event["normalized"] = true
                if let git = payload["git"] as? JSON, let branch = git["branch"] as? String { event["gitBranch"] = String(branch.prefix(1024)) }
            } else if type == "response_item" {
                event["role"] = string(payload, "role")
                switch payloadType {
                case "message": event["type"] = "message"; event["preview"] = preview(payload["content"])
                case "function_call", "custom_tool_call": event["type"] = "tool_call"; event["toolName"] = String(string(payload, "name").prefix(256)); event["toolCallId"] = String(string(payload, "call_id").prefix(1024)); event["preview"] = preview(payload["arguments"] ?? payload["input"])
                case "function_call_output", "custom_tool_call_output": event["type"] = "tool_result"; event["toolCallId"] = String(string(payload, "call_id").prefix(1024)); event["preview"] = preview(payload["output"])
                case "reasoning": event["type"] = "reasoning"; event["preview"] = preview(payload["summary"])
                default: break
                }
                event["normalized"] = string(event, "type") != "unknown"
            } else if type == "event_msg" {
                if payloadType == "token_count", let info = payload["info"] as? JSON, let usage = info["total_token_usage"] as? JSON {
                    event["type"] = "usage"; event["usage"] = usageSummary(usage, keys: ["input_tokens", "output_tokens", "cached_input_tokens", "reasoning_output_tokens", "total_tokens"]); event["usageScope"] = "provider_cumulative"
                } else if ["task_complete", "turn_complete", "turn_aborted", "error", "task_started", "approval_requested", "request_approval", "permission_request"].contains(payloadType) { event["type"] = "state" }
                else if ["user_message", "agent_message"].contains(payloadType) { event["type"] = "message"; event["role"] = payloadType == "user_message" ? "user" : "assistant"; event["preview"] = preview(payload["message"]); event["projectionMayDuplicateResponseItem"] = true }
                event["normalized"] = string(event, "type") != "unknown"
            }
            event["sourcePayloadType"] = payloadType
        }
        if event["normalized"] as? Bool != true { event["diagnostic"] = event["diagnostic"] ?? "unknown_provider_event" }
        event["previewTruncated"] = (event["preview"] as? String)?.utf8.count == 4096
        return event
    }
    static func usageSummary(_ usage: JSON, keys: [String]) -> JSON {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, usageTokenCount(usage[$0]) as Any? ?? NSNull()) })
    }
    static func preview(_ value: Any?) -> String {
        var output = Data()
        func append(_ value: Any?, depth: Int) {
            guard output.count < 4096, depth < 8 else { return }
            if let text = value as? String { output.append(contentsOf: text.utf8.prefix(4096 - output.count)) }
            else if let blocks = value as? [JSON] {
                for block in blocks {
                    guard output.count < 4096 else { break }
                    append(block["text"] ?? block["content"], depth: depth + 1)
                }
            }
        }
        append(value, depth: 0)
        // A character split at the byte budget is excluded, never replaced in originals.
        while !output.isEmpty, String(data: output, encoding: .utf8) == nil { output.removeLast() }
        return String(data: output, encoding: .utf8) ?? ""
    }
}
