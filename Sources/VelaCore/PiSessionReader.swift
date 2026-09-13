import Foundation
import Darwin

/// Read-only adaptation of the public Pi/OMP JSONL formats. The byte index keeps
/// branch ancestry without retaining all transcripts or following referenced paths.
struct PiSessionReader {
    static let maximumSourceBytes = 128 * 1024 * 1024
    static let maximumRecordBytes = 8 * 1024 * 1024
    static let maximumEntries = 100_000
    private struct Entry {
        let id: String
        let parent: String?
        let offset: UInt64
        let length: Int
        let type: String
        let usage: JSON?
    }
    let provider: String
    let url: URL
    let size: Int
    private let fractionalTimestamp: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    private let wholeTimestamp = ISO8601DateFormatter()

    func read() throws -> JSON {
        guard ["pi", "omp"].contains(provider) else { throw VelaError("Unsupported session provider") }
        guard size >= 0, size <= Self.maximumSourceBytes else { throw VelaError("Pi/OMP source exceeds the 128 MB scan limit; source left unchanged") }
        let descriptor = Darwin.open(url.path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw VelaError("Pi/OMP source cannot be opened without following symlinks") }
        let file = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        defer { try? file.close() }
        var information = stat()
        guard fstat(descriptor,&information) == 0, information.st_mode & S_IFMT == S_IFREG, information.st_size == Int64(size) else { throw VelaError("Pi/OMP source identity or size changed before reading") }
        var header: JSON?
        var version = 0
        var entries: [Entry] = []
        var byID: [String: Int] = [:]
        var currentTitle: String?
        var physicalTitle: String?
        var malformed = 0
        var unknown = 0
        var partialTail = false
        var consumed = 0
        let known = Set(["message", "model_change", "thinking_level_change", "service_tier_change", "compaction", "branch_summary", "reset_boundary", "custom", "custom_message", "label", "session_info", "title_change", "ttsr_injection", "credential_pin", "session_init", "mode_change"])
        var buffer = Data()
        var baseOffset: UInt64 = 0
        var bytesRead = 0
        func accept(_ bytes: Data, offset: UInt64, terminated: Bool) throws -> Bool {
            if bytes.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { return true }
            guard let row = (try? JSONSerialization.jsonObject(with: bytes)) as? JSON else {
                if !terminated { partialTail = true; return false }
                malformed += 1; return true
            }
            let type = string(row, "type")
            if type == "title", provider == "omp", header == nil, entries.isEmpty {
                physicalTitle = row["title"] as? String
                return true
            }
            if header == nil {
                guard type == "session", let id = row["id"] as? String, !id.isEmpty else {
                    throw VelaError("Pi/OMP log must begin with a session header")
                }
                let rawVersion = row["version"] == nil ? 1 : usageTokenCount(row["version"])
                guard let supported = rawVersion, (1...3).contains(supported) else {
                    throw VelaError("Unsupported Pi/OMP session format version; source left unchanged")
                }
                version = supported; header = row; currentTitle = row["title"] as? String
                return true
            }
            guard type != "session" else { throw VelaError("Duplicate Pi/OMP session header; source left unchanged") }
            guard entries.count < Self.maximumEntries else { throw VelaError("Pi/OMP source exceeds 100,000 entries; source left unchanged") }
            let id: String
            let parent: String?
            if version == 1 {
                id = string(row, "id", "legacy-byte-\(offset)")
                parent = entries.last?.id
            } else {
                guard let value = row["id"] as? String, !value.isEmpty,
                      row["parentId"] is NSNull || row["parentId"] is String else {
                    malformed += 1; return true
                }
                id = value; parent = row["parentId"] as? String
            }
            guard id.utf8.count <= 1024, (parent?.utf8.count ?? 0) <= 1024 else { throw VelaError("Pi/OMP entry identifier exceeds limit") }
            guard byID[id] == nil else { throw VelaError("Duplicate Pi/OMP entry identifier; source left unchanged") }
            if !known.contains(type) { unknown += 1 }
            if type == "session_info", let name = row["name"] as? String { currentTitle = name }
            if type == "title_change", let title = row["title"] as? String { currentTitle = title }
            let message = row["message"] as? JSON ?? [:]
            if type == "message", !["user", "developer", "assistant", "toolResult", "bashExecution", "pythonExecution", "fileMention", "custom", "hookMessage", "compactionSummary", "branchSummary"].contains(string(message, "role")) { unknown += 1 }
            var usage: JSON?
            if type == "message", string(message, "role") == "assistant" {
                usage = normalizedUsage(message["usage"] as? JSON)
            } else if let reported = (type == "message" ? message["usage"] : row["usage"]) as? JSON {
                usage = normalizedUsage(reported)
            }
            byID[id] = entries.count
            entries.append(Entry(id: id, parent: parent, offset: offset, length: bytes.count, type: type, usage: usage))
            return true
        }
        while bytesRead < size {
            let chunk = try file.read(upToCount: min(64 * 1024, size - bytesRead)) ?? Data()
            guard !chunk.isEmpty else { throw VelaError("Pi/OMP log changed while reading; retry refresh") }
            bytesRead += chunk.count; buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let length = buffer.distance(from: buffer.startIndex, to: end)
                guard length <= Self.maximumRecordBytes else { throw VelaError("Pi/OMP record exceeds the 8 MB limit") }
                _ = try accept(Data(buffer.prefix(length)), offset: baseOffset, terminated: true)
                let advance = length + 1
                buffer.removeFirst(advance); baseOffset += UInt64(advance); consumed = Int(baseOffset)
            }
            guard buffer.count <= Self.maximumRecordBytes else { throw VelaError("Pi/OMP record exceeds the 8 MB limit") }
        }
        if !buffer.isEmpty, try accept(buffer, offset: baseOffset, terminated: false) { consumed = size }
        guard let header else { throw VelaError("Pi/OMP session header is missing") }

        var session: JSON = ["sourceSessionId": string(header, "id"), "sourceFormatVersion": version,
                             "sourceFormat": provider + "-jsonl", "sourceBytes": size, "indexedBytes": consumed,
                             "state": "Unknown", "statusInferred": false, "liveStatusAvailable": false,
                             "statusSource": "persisted provider events; process liveness is not observed",
                             "branchSelectionSource": "last persisted entry ancestry; in-memory leaf changes are unavailable",
                             "transcriptMode": "persisted branch history; not reconstructed model context",
                             "historyFullyIndexed": malformed == 0 && unknown == 0 && !partialTail,
                             "historyTruncated": false, "sourceEntryCount": entries.count,
                             "branch": NSNull(), "model": NSNull(), "modelProvider": NSNull()]
        if let cwd = header["cwd"] as? String, cwd.hasPrefix("/") { session["cwd"] = cwd; session["project"] = canonicalProject(cwd) }
        if let parent = header["parentSession"] as? String { session["parentSession"] = String(parent.prefix(4096)) }
        let started = timestamp(header)
        session["startedAt"] = started; session["startedAtSource"] = started.isEmpty ? "unavailable" : "provider"
        session["lastActivity"] = started; session["lastActivitySource"] = started.isEmpty ? "unavailable" : "provider"
        if let title = physicalTitle ?? currentTitle, !title.isEmpty { session["title"] = String(title.prefix(512)) }
        if let last = entries.last { session["sourceLeafId"] = last.id }
        var path: [Int] = []
        var next = entries.last?.id
        var visited = Set<String>()
        var completeBranch = true
        while let id = next {
            guard visited.insert(id).inserted else { throw VelaError("Cyclic Pi/OMP branch; source left unchanged") }
            guard let index = byID[id] else { completeBranch = false; break }
            path.append(index); next = entries[index].parent
        }
        path.reverse()
        var messages: [JSON] = []
        var messageBytes = 0
        func appendMessage(_ item: JSON) {
            guard !string(item, "content").isEmpty else { return }
            messages.append(item); messageBytes += string(item, "content").utf8.count
            while messages.count > 1000 || messageBytes > 1024 * 1024 {
                messageBytes -= string(messages.removeFirst(), "content").utf8.count
                session["messagesTruncated"] = true
            }
        }
        for index in path {
            let entry = entries[index]
            try file.seek(toOffset: entry.offset)
            let bytes = try file.read(upToCount: entry.length) ?? Data()
            guard bytes.count == entry.length, let row = (try? JSONSerialization.jsonObject(with: bytes)) as? JSON else {
                throw VelaError("Pi/OMP log changed while reading its branch; retry refresh")
            }
            let time = timestamp(row)
            if !time.isEmpty { session["lastActivity"] = time; session["lastActivitySource"] = "provider" }
            if entry.type == "model_change", string(row, "role", "default") == "default" {
                session["model"] = row["modelId"] as? String ?? row["model"] as? String
                session["modelProvider"] = row["provider"] as? String
            }
            if entry.type == "thinking_level_change" { session["thinkingLevel"] = row["thinkingLevel"] as? String }
            if entry.type == "compaction" || entry.type == "branch_summary" {
                appendMessage(["id": entry.id, "role": "context", "content": String(string(row, "summary").prefix(64000)), "timestamp": time, "sourceEntryType": entry.type])
                continue
            }
            if entry.type == "custom_message" {
                appendMessage(["id": entry.id, "role": "context", "content": contentText(row["content"]), "timestamp": time, "sourceEntryType": entry.type])
                continue
            }
            guard entry.type == "message", let message = row["message"] as? JSON else { continue }
            let role = string(message, "role")
            let messageTime = time.isEmpty ? timestamp(message) : time
            var normalized: JSON = ["id": entry.id, "role": role, "content": contentText(message["content"]), "timestamp": messageTime, "sourceEntryType": "message", "sourceRole": role]
            normalized["parentId"] = entry.parent as Any? ?? NSNull()
            if role == "user" { session["state"] = "Unknown"; session["statusEvidence"] = "user message; agent execution unavailable" }
            if role == "assistant" {
                if let model = message["model"] as? String { session["model"] = model }
                if let modelProvider = message["provider"] as? String { session["modelProvider"] = modelProvider }
                let reason = string(message, "stopReason")
                session["state"] = reason == "stop" || reason == "length" ? "Completed" : reason == "error" ? "Error" : reason == "aborted" ? "Stopped" : "Unknown"
                session["statusEvidence"] = "assistant stopReason: " + (reason.isEmpty ? "unavailable" : reason)
                if let error = message["errorMessage"] as? String { normalized["error"] = String(error.prefix(4096)) }
            }
            if role == "toolResult" {
                normalized["role"] = "tool"; normalized["tool"] = string(message, "toolName")
                normalized["toolCallId"] = string(message, "toolCallId"); normalized["isError"] = (message["isError"] as? Bool) as Any? ?? NSNull()
            } else if role == "bashExecution" || role == "pythonExecution" {
                normalized["role"] = "tool"; normalized["tool"] = role == "bashExecution" ? "bash" : "python"
                normalized["content"] = String((string(message, role == "bashExecution" ? "command" : "code") + "\n" + string(message, "output")).prefix(64000))
                normalized["sourceExecution"] = "provider local command"
            } else if role == "fileMention" {
                normalized["role"] = "context"
                var text = ""
                for mentioned in message["files"] as? [JSON] ?? [] {
                    let excerpt = "[File: " + String(string(mentioned, "path").prefix(4096)) + "]\n" + String(string(mentioned, "content").prefix(64000))
                    text += String(excerpt.prefix(max(0, 64000 - text.count)))
                    if text.count >= 64000 { break }
                }
                normalized["content"] = text
            } else if role == "developer" || role == "custom" || role == "hookMessage" || role == "compactionSummary" || role == "branchSummary" {
                normalized["role"] = "context"
                if string(normalized, "content").isEmpty { normalized["content"] = String(string(message, "summary").prefix(64000)) }
            }
            if session["title"] == nil, role == "user" { session["title"] = String(string(normalized, "content").replacingOccurrences(of: "\n", with: " ").prefix(100)) }
            appendMessage(normalized)
            if role == "assistant" {
                for (blockIndex, block) in (message["content"] as? [JSON] ?? []).enumerated() where string(block, "type") == "toolCall" {
                    let arguments = (try? jsonString(block["arguments"] as? JSON ?? [:])) ?? "{}"
                    appendMessage(["id": entry.id + ":tool:" + String(blockIndex), "sourceEntryId": entry.id, "role": "tool", "tool": string(block, "name"), "toolCallId": string(block, "id"), "content": String(("[Tool: " + string(block, "name") + "]\n" + arguments).prefix(64000)), "timestamp": messageTime])
                }
            }
        }
        session["branchAncestryComplete"] = completeBranch
        if !completeBranch { session["historyFullyIndexed"] = false; session["historyTruncated"] = true }
        if session["messagesTruncated"] as? Bool == true { session["historyTruncated"] = true }
        session["messages"] = messages; session["messageCount"] = messages.count
        session["content"] = messages.map { string($0, "content") }.joined(separator: "\n")
        let ledger = entries.compactMap(\.usage)
        let inputs = ledger.compactMap { usageTokenCount($0["input"]) }
        let outputs = ledger.compactMap { usageTokenCount($0["output"]) }
        let input = usageTokenSum(inputs), output = usageTokenSum(outputs)
        let complete = malformed == 0 && unknown == 0 && !partialTail
        session["observedTokenInput"] = input as Any? ?? NSNull(); session["observedTokenOutput"] = output as Any? ?? NSNull()
        session["tokenInput"] = (complete && inputs.count == ledger.count ? input : nil) as Any? ?? NSNull()
        session["tokenOutput"] = (complete && outputs.count == ledger.count ? output : nil) as Any? ?? NSNull()
        session["usageOverflow"] = ledger.contains { $0["overflow"] as? Bool == true } || (!inputs.isEmpty && input == nil) || (!outputs.isEmpty && output == nil)
        session["usageCoverage"] = "persisted usage across all indexed branches; not subscription quota"
        session["usageEntryCount"] = ledger.count
        session["compatibilityWarnings"] = [malformed > 0 ? "Skipped \(malformed) malformed records" : nil, unknown > 0 ? "\(unknown) unknown entry types or message roles; interpretation is incomplete" : nil, partialTail ? "Incomplete trailing record awaits more bytes" : nil, !completeBranch ? "A branch ancestor is missing" : nil].compactMap { $0 }
        return session
    }

    private func normalizedUsage(_ value: JSON?) -> JSON {
        let value = value ?? [:]
        let components = ["input", "cacheRead", "cacheWrite"].map { usageTokenCount(value[$0]) }
        let known = components.compactMap { $0 }
        let input = known.count == components.count ? usageTokenSum(known) : nil
        return ["input": input as Any? ?? NSNull(), "output": usageTokenCount(value["output"]) as Any? ?? NSNull(), "overflow": known.count == components.count && input == nil]
    }

    private func contentText(_ value: Any?) -> String {
        if let value = value as? String { return String(value.prefix(64000)) }
        var result = ""
        for block in value as? [JSON] ?? [] {
            let type = string(block, "type")
            let text = type == "text" ? string(block, "text") : type == "image" ? "[Image omitted]" : ""
            if !text.isEmpty { result += (result.isEmpty ? "" : "\n") + String(text.prefix(64000 - min(result.count, 64000))) }
            if result.count >= 64000 { break }
        }
        return result
    }

    private func timestamp(_ row: JSON) -> String {
        if let value = row["timestamp"] as? String {
            if fractionalTimestamp.date(from: value) != nil || wholeTimestamp.date(from: value) != nil { return value }
        }
        if let milliseconds = usageTokenCount(row["timestamp"]), milliseconds <= 253_402_300_799_000 {
            return fractionalTimestamp.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
        }
        return ""
    }
}
