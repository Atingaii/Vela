import Foundation
import CoreServices
import CSQLite

final class SessionEngine {
    let store: VelaStore
    let sourceRoots: [String:[URL]]
    private let lock = NSRecursiveLock()
    private var stream: FSEventStreamRef?
    private let watchQueue = DispatchQueue(label:"ai.vela.session-events",qos:.utility)
    private var changed: Set<String> = []
    private var refreshPending = false
    private let diagnosticLock = NSLock()
    private var diagnosticStorage: [JSON] = []
    private(set) var diagnostics: [JSON] {
        get { diagnosticLock.lock(); defer { diagnosticLock.unlock() }; return diagnosticStorage }
        set { diagnosticLock.lock(); diagnosticStorage = newValue; diagnosticLock.unlock() }
    }
    private(set) var initialScanFinished = false
    private let initialFiles = 60
    private let tailWindow = 256 * 1024
    private let readLimit = 8 * 1024 * 1024
    var onChange: (() -> Void)?

    init(store: VelaStore, sourceRoots: [String:[URL]]? = nil) {
        self.store = store
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configuredRoots = sourceRoots ?? [
            "claude":[home.appendingPathComponent(".claude/projects")],
            "codex":[home.appendingPathComponent(".codex/sessions"),home.appendingPathComponent(".codex/archived_sessions")],
            "cursor":[home.appendingPathComponent(".cursor/exports"),home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage"),home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")]
        ]
        self.sourceRoots = configuredRoots.mapValues { $0.map { URL(fileURLWithPath:canonicalProject($0.path)) } }
    }
    deinit { stopWatching() }
    func startWatching() {
        lock.lock(); defer { lock.unlock() }
        guard stream == nil else { return }
        let paths = sourceRoots.values.flatMap { $0 }.map { url -> String in
            var candidate = url
            while !FileManager.default.fileExists(atPath:candidate.path), candidate.path != "/" { candidate.deleteLastPathComponent() }
            return candidate.path
        }
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let engine = Unmanaged<SessionEngine>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths,to:NSArray.self) as? [String] ?? []
            engine.receiveEvents(paths,flags:flags,count:count)
        }, &context, Array(Set(paths)) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),0.1,FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        if let stream { FSEventStreamSetDispatchQueue(stream,watchQueue); if !FSEventStreamStart(stream) { diagnostics.append(["severity":"warning","message":"FSEvents unavailable; manual refresh remains available"]); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil } }
    }
    func stopWatching() {
        lock.lock(); defer { lock.unlock() }
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
    }
    private func receiveEvents(_ paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        for (index,path) in paths.enumerated() where index < count {
            if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 { initialScanFinished = false }
            if provider(for:path) != nil { changed.insert(path) }
        }
        guard !refreshPending, !changed.isEmpty || !initialScanFinished else { return }
        refreshPending = true
        watchQueue.asyncAfter(deadline:.now() + 0.075) { [weak self] in
            guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
            self.refreshPending = false; _ = try? self.refresh(discover:!self.initialScanFinished)
        }
    }
    private func provider(for path: String) -> String? {
        let canonicalPath = canonicalProject(path)
        for (provider,roots) in sourceRoots { if roots.contains(where:{ canonicalPath == $0.path || canonicalPath.hasPrefix($0.path + "/") }) { return provider } }
        return nil
    }
    func refresh(discover: Bool = true) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        diagnostics = []
        var files: [(String,URL)] = []
        if discover || !initialScanFinished {
            for provider in sourceRoots.keys.sorted() {
                var candidates: [(URL,Date)] = []; var enumerated = 0
                for root in sourceRoots[provider] ?? [] {
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath:root.path,isDirectory:&isDir) else { continue }
                    if !isDir.boolValue { candidates.append((root,(try? root.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)); continue }
                    guard let iterator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey],options:[.skipsHiddenFiles]) else { continue }
                    for case let url as URL in iterator {
                        enumerated += 1
                        if enumerated > 50000 { diagnostics.append(["provider":provider,"severity":"warning","message":"Discovery capped at 50,000 directory entries; history is not fully indexed"]); break }
                        let metadata = try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey])
                        guard metadata?.isRegularFile == true, metadata?.isSymbolicLink != true, supports(url,provider:provider) else { continue }
                        candidates.append((url,metadata?.contentModificationDate ?? .distantPast))
                    }
                }
                candidates.sort { $0.1 > $1.1 }
                if candidates.count > initialFiles { diagnostics.append(["provider":provider,"severity":"info","message":"Indexed the \(initialFiles) most recently modified sources; older source files remain on disk and are not fully indexed","discoveredFiles":candidates.count]) }
                files += candidates.prefix(initialFiles).map { (provider,$0.0) }
            }
            initialScanFinished = true
        }
        for path in changed {
            let url = URL(fileURLWithPath:path)
            if let provider = provider(for:path), supports(url,provider:provider), FileManager.default.fileExists(atPath:path) { files.append((provider,url)) }
            if path.hasSuffix("-wal"), let provider = provider(for:path) { let main = URL(fileURLWithPath:String(path.dropLast(4))); if supports(main,provider:provider) { files.append((provider,main)) } }
        }
        changed.removeAll()
        var seen: Set<String> = []; var updated = 0
        for (provider,url) in files where seen.insert(url.path).inserted {
            do { updated += try ingest(url,provider:provider) ? 1 : 0 }
            catch { diagnostics.append(["provider":provider,"path":url.path,"severity":"warning","message":error.localizedDescription]) }
        }
        if !changed.isEmpty, !refreshPending {
            refreshPending = true
            watchQueue.asyncAfter(deadline:.now()+0.075) { [weak self] in
                guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
                self.refreshPending = false; _ = try? self.refresh(discover:false)
            }
        }
        if updated > 0 { onChange?() }
        return ["sourceFilesChecked":seen.count,"sourcesUpdated":updated,"sessionCount":try store.sessionSummaries(limit:10000).count,"historyFullyIndexed":false,"initialFileLimit":initialFiles,"initialTailBytes":tailWindow,"diagnostics":diagnostics]
    }
    private func supports(_ url: URL, provider: String) -> Bool {
        ["jsonl","ndjson"].contains(url.pathExtension.lowercased()) || (provider == "cursor" && ["json","vscdb","sqlite","sqlite3"].contains(url.pathExtension.lowercased()))
    }
    private func ingest(_ url: URL, provider: String) throws -> Bool {
        let metadata = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey,.fileResourceIdentifierKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { throw VelaError("Only regular log files are read") }
        if ["vscdb","sqlite","sqlite3"].contains(url.pathExtension) { return try ingestCursorDatabase(url) }
        if url.pathExtension == "json" { return try ingestCursorExport(url) }
        let size = metadata.fileSize ?? 0
        let cursorId = stableHash(url.path); var cursor = try store.get("ingestion",cursorId) ?? [:]
        let fingerprint = metadata.fileResourceIdentifier.map { String(describing:$0) } ?? ""
        let oldOffset = intValue(cursor,"offset")
        let modified = metadata.contentModificationDate?.timeIntervalSince1970 ?? 0
        if oldOffset == size, (cursor["modified"] as? Double) == modified, string(cursor,"fingerprint") == fingerprint { return false }
        let rotated = size < oldOffset || (!string(cursor,"fingerprint").isEmpty && string(cursor,"fingerprint") != fingerprint)
        let sessionId = stableHash(provider + ":" + url.path)
        var session = rotated ? [:] : (try store.get("session",sessionId) ?? [:])
        var offset: Int = rotated ? 0 : oldOffset
        let firstRead = cursor.isEmpty || rotated
        if firstRead, size > tailWindow { offset = size - tailWindow; session["historyTruncated"] = true }
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        if firstRead, offset > 0 {
            let header = try handle.read(upToCount:32768) ?? Data()
            for line in header.split(separator:10) {
                guard let row = (try? JSONSerialization.jsonObject(with:Data(line))) as? JSON else { continue }
                if provider == "codex", ["session_meta","turn_context"].contains(string(row,"type")) { mergeEvent(row,provider:provider,session:&session) }
                if provider == "claude" {
                    if let cwd = row["cwd"] as? String, cwd.hasPrefix("/") { session["cwd"] = cwd; session["project"] = canonicalProject(cwd) }
                    if let branch = row["gitBranch"] { session["branch"] = branch }
                    if let sessionId = row["sessionId"] { session["sourceSessionId"] = sessionId }
                    if let timestamp = row["timestamp"],session["startedAt"] == nil { session["startedAt"] = timestamp }
                }
            }
        }
        try handle.seek(toOffset:UInt64(offset))
        let data = try handle.read(upToCount:min(readLimit,max(0,size-offset))) ?? Data()
        var start = data.startIndex
        if firstRead && offset > 0 {
            if let newline = data.firstIndex(of:10) { start = data.index(after:newline) }
            else { start = data.endIndex }
        }
        var consumed: Int = start; var parsed = 0; var malformed = 0
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of:10)
            let end = newline ?? data.endIndex
            let row = Data(data[start..<end])
            if !row.isEmpty {
                if let value = try? JSONSerialization.jsonObject(with:row), let object = value as? JSON {
                    if recognizedRecord(object,provider:provider) { mergeEvent(object,provider:provider,session:&session); parsed += 1 } else { malformed += 1 }
                } else if newline == nil { break }
                else { malformed += 1 }
            }
            consumed = newline.map { data.index(after:$0) } ?? end
            start = consumed
        }
        if consumed == 0, data.count >= readLimit { throw VelaError("A log record exceeds the 8 MB streaming record limit; source left unchanged") }
        if parsed == 0, !firstRead { return false }
        guard parsed > 0 || !session.isEmpty else {
            if malformed > 0 { throw VelaError("No recognized JSONL records in bounded log window") }
            return false
        }
        session["id"] = sessionId; session["provider"] = provider; session["sourcePath"] = url.path
        session["state"] = session["state"] ?? "Unknown"; session["statusSource"] = "log evidence; process liveness is not verified"
        session["statusInferred"] = true; session["historyTruncated"] = session["historyTruncated"] ?? false
        session["historyFullyIndexed"] = session["historyTruncated"] as? Bool != true && offset + consumed >= size
        session["indexedBytes"] = offset + consumed; session["sourceBytes"] = size
        session["title"] = session["title"] ?? url.deletingPathExtension().lastPathComponent
        session["project"] = session["project"] ?? ""; session["startedAt"] = session["startedAt"] ?? isoNow()
        let messages = session["messages"] as? [JSON] ?? []
        session["messageCount"] = messages.count; session["content"] = messages.map { string($0,"content") }.joined(separator:"\n")
        if malformed > 0 { session["parseWarning"] = "Skipped \(malformed) malformed records" }
        _ = try store.put("session",session)
        cursor["id"] = cursorId; cursor["offset"] = offset + consumed; cursor["sourcePath"] = url.path; cursor["fingerprint"] = fingerprint; cursor["modified"] = modified
        _ = try store.put("ingestion",cursor)
        if offset + data.count < size { changed.insert(url.path) }
        return true
    }
    private func recognizedRecord(_ row: JSON, provider: String) -> Bool {
        if provider == "codex" { return ["session_meta","turn_context","response_item","event_msg"].contains(string(row,"type")) && row["payload"] is JSON }
        if provider == "claude" { return row["message"] is JSON || ["result","error","permission_request","approval_requested"].contains(string(row,"type")) }
        return row["content"] != nil || row["text"] != nil || row["message"] != nil
    }
    private func textContent(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [JSON] {
            return blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                if let content = block["content"] { return textContent(content) }
                if string(block,"type") == "tool_use" { return "[Tool: \(string(block,"name"))]" }
                if string(block,"type") == "tool_result" { return "[Tool result]" }
                return nil
            }.joined(separator:"\n")
        }
        return ""
    }
    private func addMessage(_ raw: JSON, role: String, content: String, timestamp: String, session: inout JSON, tool: String? = nil) {
        guard !content.isEmpty else { return }
        let id = string(raw,"id",string(raw,"uuid",stableHash(role + ":" + timestamp + ":" + content)))
        var messages = session["messages"] as? [JSON] ?? []
        var message: JSON = ["id":id,"role":role,"content":String(content.prefix(64000)),"timestamp":timestamp]
        if let tool { message["tool"] = tool }
        if let index = messages.firstIndex(where:{ string($0,"id") == id }) { messages[index] = message }
        else { messages.append(message) }
        if messages.count > 1000 { messages.removeFirst(messages.count-1000); session["messagesTruncated"] = true }
        var bytes = messages.reduce(0) { $0 + string($1,"content").utf8.count }
        while bytes > 1024 * 1024, messages.count > 1 { bytes -= string(messages.removeFirst(),"content").utf8.count; session["messagesTruncated"] = true }
        session["messages"] = messages
        if role == "user", session["title"] == nil { session["title"] = String(content.replacingOccurrences(of:"\n",with:" ").prefix(100)) }
    }
    private func mergeEvent(_ row: JSON, provider: String, session: inout JSON) {
        let timestamp = string(row,"timestamp",isoNow()); let type = string(row,"type")
        session["startedAt"] = session["startedAt"] ?? timestamp; session["lastActivity"] = timestamp
        if let cwd = row["cwd"] as? String, cwd.hasPrefix("/") { session["cwd"] = cwd; session["project"] = canonicalProject(cwd) }
        if let branch = row["gitBranch"] as? String { session["branch"] = branch }
        if let sourceId = row["sessionId"] as? String { session["sourceSessionId"] = sourceId }
        if provider == "claude" {
            if let message = row["message"] as? JSON {
                let role = string(message,"role",type)
                session["state"] = "Running"; session["statusEvidence"] = "recent message in agent log"
                var identity = message; if identity["id"] == nil { identity["id"] = row["uuid"] }
                addMessage(identity,role:role,content:textContent(message["content"]),timestamp:timestamp,session:&session)
                if let model = message["model"] as? String { session["model"] = model }
                if let usage = message["usage"] as? JSON {
                    var totals = session["usageByMessage"] as? [String:JSON] ?? [:]
                    let key = string(message,"id",string(row,"uuid",stableHash(timestamp + ((try? jsonString(usage)) ?? ""))))
                    let previous = totals[key] ?? [:]
                    totals[key] = ["input":intValue(usage,"input_tokens") + intValue(usage,"cache_read_input_tokens") + intValue(usage,"cache_creation_input_tokens"),"output":intValue(usage,"output_tokens")]
                    session["tokenInput"] = intValue(session,"tokenInput") + intValue(totals[key]!,"input") - intValue(previous,"input")
                    session["tokenOutput"] = intValue(session,"tokenOutput") + intValue(totals[key]!,"output") - intValue(previous,"output")
                    if totals.count > 4096, let first = totals.keys.sorted().first, first != key { totals.removeValue(forKey:first) }
                    session["usageByMessage"] = totals
                    session["usageCoverage"] = session["historyTruncated"] as? Bool == true ? "indexed tail only" : "indexed messages"
                }
            }
            if row["isApiErrorMessage"] as? Bool == true || type == "error" { session["state"] = "Error" }
            if ["permission_request","approval_requested"].contains(type) { session["state"] = "Needs Approval"; session["statusEvidence"] = type }
            if type == "result" { session["state"] = row["is_error"] as? Bool == true ? "Error" : "Completed" }
        } else if provider == "codex" {
            let payload = row["payload"] as? JSON ?? [:]
            if type == "session_meta" {
                session["sourceSessionId"] = payload["id"]
                if let cwd = payload["cwd"] as? String, cwd.hasPrefix("/") { session["cwd"] = cwd; session["project"] = canonicalProject(cwd) }
                if let git = payload["git"] as? JSON { session["branch"] = git["branch"] }
            }
            if type == "turn_context" { session["model"] = payload["model"]; if let cwd = payload["cwd"] as? String, cwd.hasPrefix("/") { session["cwd"] = cwd; session["project"] = canonicalProject(cwd) } }
            if type == "response_item" {
                session["state"] = "Running"; session["statusEvidence"] = "recent response item in agent log"
                let itemType = string(payload,"type")
                if itemType == "message" { addMessage(payload,role:string(payload,"role","assistant"),content:textContent(payload["content"]),timestamp:timestamp,session:&session) }
                else if itemType == "function_call" { addMessage(payload,role:"tool",content:"[Tool: \(string(payload,"name"))]\n\(string(payload,"arguments"))",timestamp:timestamp,session:&session,tool:string(payload,"name")) }
                else if itemType == "function_call_output" { addMessage(payload,role:"tool",content:textContent(payload["output"]),timestamp:timestamp,session:&session) }
            }
            if type == "event_msg" {
                switch string(payload,"type") {
                case "token_count":
                    if let info = payload["info"] as? JSON, let usage = info["total_token_usage"] as? JSON {
                        session["tokenInput"] = intValue(usage,"input_tokens"); session["tokenOutput"] = intValue(usage,"output_tokens"); session["usageCoverage"] = "provider-reported cumulative tokens"
                    }
                case "task_complete","turn_complete": session["state"] = "Completed"
                case "turn_aborted": session["state"] = "Stopped"
                case "error": session["state"] = "Error"
                case "task_started": session["lastObservedState"] = "Running"; session["state"] = "Running"; session["statusEvidence"] = "task_started log event"
                case "approval_requested","request_approval","permission_request": session["state"] = "Needs Approval"; session["statusEvidence"] = string(payload,"type")
                default: break
                }
            }
        } else {
            let role = string(row,"role",string(row,"type","assistant"))
            addMessage(row,role:role,content:textContent(row["content"] ?? row["text"] ?? row["message"]),timestamp:timestamp,session:&session)
            if let model = row["model"] as? String { session["model"] = model }
        }
    }
    private func ingestCursorExport(_ url: URL) throws -> Bool {
        let size = (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard size <= readLimit else { throw VelaError("Cursor JSON export exceeds 8 MB; use JSONL for streaming import") }
        let value = try JSONSerialization.jsonObject(with:Data(contentsOf:url))
        let object = value as? JSON ?? [:]
        let messages = value as? [JSON] ?? object["messages"] as? [JSON] ?? object["conversation"] as? [JSON]
        guard let messages else { throw VelaError("Unsupported Cursor JSON export: expected messages or conversation array") }
        let id = stableHash("cursor:" + url.path)
        let hash = stableHash(try jsonString(["value":value]))
        if let existing = try store.get("session",id), string(existing,"sourceHash") == hash { return false }
        var session: JSON = ["id":id,"provider":"cursor","sourcePath":url.path,"sourceHash":hash,"state":"Unknown","statusInferred":true,"statusSource":"imported Cursor export; no live process evidence","title":string(object,"name",string(object,"title",url.deletingPathExtension().lastPathComponent)),"historyFullyIndexed":true]
        if let cwd = object["cwd"] as? String ?? object["projectPath"] as? String { session["cwd"] = cwd; session["project"] = canonicalProject(cwd) }
        for row in messages { mergeEvent(row,provider:"cursor",session:&session) }
        let normalized = session["messages"] as? [JSON] ?? []
        session["messageCount"] = normalized.count; session["content"] = normalized.map { string($0,"content") }.joined(separator:"\n")
        _ = try store.put("session",session); return true
    }
    private func ingestCursorDatabase(_ url: URL) throws -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { sqlite3_close(db); throw VelaError("Cursor database cannot be opened read-only") }
        defer { sqlite3_close(db) }; sqlite3_busy_timeout(db,200)
        var imported = 0; var supported = false
        for table in ["ItemTable","cursorDiskKV"] {
            var statement: OpaquePointer?
            let sql = "SELECT key,value FROM \(table) WHERE key LIKE 'composerData:%' AND length(value)<=8388608 LIMIT 60"
            guard sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK else { continue }
            supported = true; defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let keyRaw = sqlite3_column_text(statement,0), let valueRaw = sqlite3_column_text(statement,1) else { continue }
                let key = String(cString:keyRaw); let value = String(cString:valueRaw)
                guard let object = (try? JSONSerialization.jsonObject(with:Data(value.utf8))) as? JSON else { continue }
                guard let messages = object["conversation"] as? [JSON] ?? object["messages"] as? [JSON] else { continue }
                let id = stableHash("cursor:" + url.path + ":" + key); let hash = stableHash(value)
                if let existing = try store.get("session",id), string(existing,"sourceHash") == hash { continue }
                var session: JSON = ["id":id,"provider":"cursor","title":string(object,"name","Cursor conversation"),"sourcePath":url.path,"sourceKey":key,"sourceHash":hash,"state":"Unknown","statusInferred":true,"statusSource":"read-only Cursor SQLite snapshot; no live status","historyFullyIndexed":false]
                if let cwd = object["cwd"] as? String ?? object["projectPath"] as? String { session["cwd"] = cwd; session["project"] = canonicalProject(cwd) }
                for var row in messages {
                    if row["role"] == nil, let type = row["type"] as? Int { row["role"] = type == 1 ? "user" : "assistant" }
                    mergeEvent(row,provider:"cursor",session:&session)
                }
                let normalized = session["messages"] as? [JSON] ?? []; session["messageCount"] = normalized.count; session["content"] = normalized.map { string($0,"content") }.joined(separator:"\n")
                _ = try store.put("session",session); imported += 1
            }
        }
        if !supported { throw VelaError("Unsupported Cursor SQLite schema; only known composerData records are imported") }
        if imported == 0 { diagnostics.append(["provider":"cursor","path":url.path,"severity":"info","message":"No new supported composerData conversation records. Cursor versions using separate bubble records require an export."]) }
        return imported > 0
    }
}
