import Foundation
import CoreServices
import CSQLite
import Darwin
import CryptoKit

// Token counts cross JSON into WebKit, so require exact nonnegative integers
// within both Swift and JavaScript's supported integer range. Never coerce bools,
// fractions, strings or overflowing provider numbers into fabricated zeroes.
func usageTokenCount(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          let count = Int(number.stringValue), count >= 0, count <= 9_007_199_254_740_991 else { return nil }
    return count
}
func usageTokenSum(_ values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    var total = 0
    for value in values {
        guard value >= 0 else { return nil }
        let addition = total.addingReportingOverflow(value)
        guard !addition.overflow, addition.partialValue <= 9_007_199_254_740_991 else { return nil }
        total = addition.partialValue
    }
    return total
}

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
            "cursor":[home.appendingPathComponent(".cursor/exports"),home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage"),home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")],
            "pi":[home.appendingPathComponent(".pi/agent/sessions")],
            "omp":[home.appendingPathComponent(".omp/agent/sessions")]
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
        guard ["claude","codex","cursor","pi","omp"].contains(provider) else { return false }
        return ["jsonl","ndjson"].contains(url.pathExtension.lowercased()) || (provider == "cursor" && ["json","vscdb","sqlite","sqlite3"].contains(url.pathExtension.lowercased()))
    }
    private func ingest(_ url: URL, provider: String) throws -> Bool {
        guard ["claude","codex","cursor","pi","omp"].contains(provider) else { throw VelaError("Unsupported session provider") }
        let metadata = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey,.fileResourceIdentifierKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { throw VelaError("Only regular log files are read") }
        if provider == "cursor", ["vscdb","sqlite","sqlite3"].contains(url.pathExtension) { return try ingestCursorDatabase(url) }
        if provider == "cursor", url.pathExtension == "json" { return try ingestCursorExport(url) }
        let size = metadata.fileSize ?? 0
        let cursorId = stableHash(url.path); var cursor = try store.get("ingestion",cursorId) ?? [:]
        let originalCursor = cursor
        let fingerprint = metadata.fileResourceIdentifier.map { String(describing:$0) } ?? ""
        let oldOffset = intValue(cursor,"offset")
        let modified = metadata.contentModificationDate?.timeIntervalSince1970 ?? 0
        if provider == "pi" || provider == "omp" {
            // URL resource values may be cached, and a Double timestamp cannot
            // retain filesystem nanoseconds. OMP edits its fixed title slot and
            // providers can rewrite same-size records while preserving mtime.
            let before = try piSourceVersion(url)
            if oldOffset == before.size, string(cursor,"sourceVersion") == before.version { return false }
            var session: JSON
            do { session = try PiSessionReader(provider:provider,url:url,size:before.size).read() }
            catch {
                if (try? piSourceVersion(url).version) != before.version { changed.insert(url.path) }
                throw error
            }
            guard try piSourceVersion(url).version == before.version else {
                changed.insert(url.path); throw VelaError("Pi/OMP source changed during scan; previous snapshot retained")
            }
            session["id"] = stableHash(provider + ":" + url.path); session["provider"] = provider
            session["sourcePath"] = url.path; session["project"] = session["project"] ?? ""
            session["title"] = session["title"] ?? url.deletingPathExtension().lastPathComponent
            finalizeUsage(provider:provider,session:&session)
            cursor = ["id":cursorId,"offset":intValue(session,"indexedBytes"),"sourcePath":url.path,"fingerprint":fingerprint,"modified":modified,"sourceVersion":before.version]
            _ = try store.putBatch([("session",session),("ingestion",cursor)])
            return true
        }
        let sourceVersion = try piSourceVersion(url).version
        let planCompatible = string(cursor,"planDecoderVersion") == SessionPlanProjection.version
            && (provider != "codex" || string(cursor,"relationDecoderVersion") == SessionRelationProjection.version)
        if oldOffset == size, string(cursor,"sourceVersion") == sourceVersion, planCompatible { return false }
        let rewritten = oldOffset == size && !string(cursor,"sourceVersion").isEmpty && string(cursor,"sourceVersion") != sourceVersion
        // A source that grew may still have rewritten bytes before the prior
        // completed offset.  Stat identity/version changes for normal appends
        // too, so it cannot distinguish that case.  Re-hash the complete
        // already-indexed prefix on growth.  This is deliberately O(prefix)
        // I/O but streams fixed chunks and never retains the prefix in memory.
        // Legacy cursors without the digest rotate once on their next growth
        // rather than treating an unverifiable prefix as append-only.
        var indexedPrefixChanged = false
        if size > oldOffset, oldOffset > 0 {
            let expectedPrefix = string(cursor,"indexedPrefixSHA256")
            if expectedPrefix.isEmpty { indexedPrefixChanged = true }
            else { indexedPrefixChanged = try indexedPrefixSHA256(url,length:oldOffset) != expectedPrefix }
        }
        let sessionId = stableHash(provider + ":" + url.path)
        let originalSession = try store.get("session",sessionId), originalPlan = try store.get("session_plan",sessionId)
        let originalRelation = provider == "codex" ? try store.get("session_relation",sessionId) : nil
        // Keep the relation-specific header evidence as provenance.  The
        // complete indexed-prefix digest above now protects every previously
        // accepted byte before this append path is reused.
        var headerChanged = false
        if provider == "codex", size > oldOffset, oldOffset > 0,
           let evidence = originalRelation?["headerEvidence"] as? JSON {
            let length = intValue(evidence,"byteLength"), offset = intValue(evidence,"byteOffset")
            if length > 0, length <= tailWindow, offset >= 0, offset <= size-length {
                let source = try FileHandle(forReadingFrom:url); defer { try? source.close() }
                try source.seek(toOffset:UInt64(offset))
                let bytes = try source.read(upToCount:length) ?? Data()
                let hash = SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
                headerChanged = bytes.count != length || hash != string(evidence,"sha256")
            } else { headerChanged = true }
        }
        let rotated = size < oldOffset || rewritten || indexedPrefixChanged || headerChanged || !planCompatible || (!string(cursor,"fingerprint").isEmpty && string(cursor,"fingerprint") != fingerprint)
        var session = rotated ? [:] : (originalSession ?? [:])
        var plan = rotated ? SessionPlanProjection.empty(provider: provider) : (originalPlan ?? SessionPlanProjection.empty(provider: provider))
        var relation = provider == "codex" ? (rotated ? SessionRelationProjection.empty() : (originalRelation ?? SessionRelationProjection.empty())) : [:]
        func planReference(_ bytes: Data, offset: Int) -> JSON {
            ["sourceIdentity": sessionId, "sourcePath": url.path, "sourceVersion": sourceVersion,
             "byteOffset": offset, "byteLength": bytes.count,
             "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
        }
        var offset: Int = rotated ? 0 : oldOffset
        let firstRead = cursor.isEmpty || rotated
        if firstRead, size > tailWindow { offset = size - tailWindow; session["historyTruncated"] = true }
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        if firstRead, offset > 0 {
            let header = try handle.read(upToCount:32768) ?? Data()
            var headerOffset = 0
            for line in header.split(separator:10,omittingEmptySubsequences:false) {
                defer { headerOffset += line.count + 1 }
                guard let row = (try? JSONSerialization.jsonObject(with:Data(line))) as? JSON else { continue }
                SessionPlanProjection.consume(row, provider: provider, reference: [:], state: &plan, metadataOnly: true)
                // A prefix can end on syntactically valid JSON before the real
                // record ends. Only a newline proves this header row is whole.
                if provider == "codex", headerOffset + line.count < header.count { SessionRelationProjection.consume(row,reference:planReference(Data(line),offset:headerOffset),state:&relation,metadataOnly:true) }
                if provider == "codex", ["session_meta","turn_context"].contains(string(row,"type")) { mergeEvent(row,provider:provider,session:&session) }
                if provider == "claude" {
                    if let cwd = row["cwd"] as? String, cwd.hasPrefix("/") { session["cwd"] = cwd; session["project"] = canonicalProject(cwd) }
                    if let branch = row["gitBranch"] { session["branch"] = branch }
                    if let sessionId = row["sessionId"] { session["sourceSessionId"] = sessionId }
                    if let timestamp = row["timestamp"] as? String,session["startedAt"] == nil {
                        session["startedAt"] = timestamp; session["startedAtSource"] = "provider"
                    }
                }
            }
        }
        if provider == "codex", firstRead, offset > 0 { SessionRelationProjection.noteGap(["unobservedBeforeOffset":offset],state:&relation) }
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
                    if recognizedRecord(object,provider:provider) {
                        mergeEvent(object,provider:provider,session:&session)
                        SessionPlanProjection.consume(object, provider: provider, reference: planReference(row, offset: offset + start), state: &plan)
                        if provider == "codex" { SessionRelationProjection.consume(object,reference:planReference(row,offset:offset+start),state:&relation) }
                        parsed += 1
                    } else { malformed += 1; SessionPlanProjection.noteGap(planReference(row, offset: offset + start), state: &plan); if provider == "codex" { SessionRelationProjection.noteGap(planReference(row,offset:offset+start),state:&relation) } }
                } else if newline == nil { break }
                else { malformed += 1; SessionPlanProjection.noteGap(planReference(row, offset: offset + start), state: &plan); if provider == "codex" { SessionRelationProjection.noteGap(planReference(row,offset:offset+start),state:&relation) } }
            }
            consumed = newline.map { data.index(after:$0) } ?? end
            start = consumed
        }
        if consumed == 0, data.count >= readLimit { throw VelaError("A log record exceeds the 8 MB streaming record limit; source left unchanged") }
        if parsed == 0, malformed == 0, !firstRead { return false }
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
        session["project"] = session["project"] ?? ""
        if session["startedAt"] == nil { session["startedAt"] = isoNow(); session["startedAtSource"] = "ingestion_fallback" }
        let messages = session["messages"] as? [JSON] ?? []
        session["messageCount"] = messages.count; session["content"] = messages.map { string($0,"content") }.joined(separator:"\n")
        finalizeUsage(provider:provider,session:&session)
        if malformed > 0 { session["parseWarning"] = "Skipped \(malformed) malformed records" }
        // Compute the completed-prefix digest before the final source-version guard.  No
        // source reads are permitted after that guard: otherwise a concurrent rewrite
        // could pair this projection with a digest of a different source revision.
        let completedPrefixSHA256 = try indexedPrefixSHA256(url,length:offset + consumed)
        guard try piSourceVersion(url).version == sourceVersion else {
            changed.insert(url.path); throw VelaError("Session source changed while reading; prior session and plan retained")
        }
        if string(plan,"project") != string(session,"project") { plan = SessionPlanProjection.empty(provider: provider); plan["id"] = sessionId; plan["project"] = string(session,"project"); plan["coverageLimited"] = true }
        plan["id"] = sessionId; plan["sourceIdentity"] = sessionId
        session["planSummary"] = SessionPlanProjection.summary(plan, provider: provider, historyTruncated: session["historyTruncated"] as? Bool == true)
        cursor["id"] = cursorId; cursor["offset"] = offset + consumed; cursor["sourcePath"] = url.path; cursor["fingerprint"] = fingerprint; cursor["modified"] = modified
        cursor["sourceVersion"] = sourceVersion; cursor["indexedPrefixSHA256"] = completedPrefixSHA256; cursor["planDecoderVersion"] = SessionPlanProjection.version
        if provider == "codex" {
            if string(relation,"project") != string(session,"project") {
                relation = SessionRelationProjection.empty(); relation["project"] = string(session,"project")
                relation["sourceThreadId"] = SessionRelationProjection.threadID(session["sourceSessionId"]) as Any? ?? NSNull()
                relation["headerState"] = "scope_changed"; relation["coverageLimited"] = true
            }
            relation["id"] = sessionId; relation["observedSourceVersion"] = sourceVersion
            relation["coverageLimited"] = relation["coverageLimited"] as? Bool == true || session["historyTruncated"] as? Bool == true
            session["relationSummary"] = SessionRelationProjection.summary(relation)
            cursor["relationDecoderVersion"] = SessionRelationProjection.version
        }
        var originals: [(String,String,JSON?)] = [("session",sessionId,originalSession),("session_plan",sessionId,originalPlan),("ingestion",cursorId,originalCursor.isEmpty ? nil : originalCursor)]
        if provider == "codex" { originals.append(("session_relation",sessionId,originalRelation)) }
        var expected: [(String,String,String)] = []; var absent: [(String,String)] = []
        for (kind,id,original) in originals {
            if let original { expected.append((kind,id,stableHash(try jsonString(original)))) }
            else { absent.append((kind,id)) }
        }
        var writes: [(String,JSON)] = [("session",session),("session_plan",plan),("ingestion",cursor)]
        if provider == "codex" { writes.append(("session_relation",relation)) }
        _ = try store.putBatch(writes,expecting:expected,expectingAbsent:absent)
        if offset + data.count < size { changed.insert(url.path) }
        return true
    }

    private func piSourceVersion(_ url: URL) throws -> (size: Int, version: String) {
        var information = stat()
        guard lstat(url.path,&information) == 0, information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0, information.st_size <= Int64(Int.max) else { throw VelaError("Pi/OMP source is not an available regular file") }
        let version = "\(information.st_dev):\(information.st_ino):\(information.st_size):\(information.st_mtimespec.tv_sec):\(information.st_mtimespec.tv_nsec):\(information.st_ctimespec.tv_sec):\(information.st_ctimespec.tv_nsec)"
        return (Int(information.st_size),version)
    }
    private func indexedPrefixSHA256(_ url: URL, length: Int) throws -> String {
        guard length >= 0 else { throw VelaError("Indexed source offset is invalid") }
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        var remaining = length, digest = SHA256()
        while remaining > 0 {
            // FileHandle's Foundation bridge can autorelease its Data result.  This
            // scope drains every 64 KiB chunk before the next read, so a long-lived
            // RPC helper does not retain one temporary Data object per prefix chunk.
            try autoreleasepool { () throws -> Void in
                let data = try handle.read(upToCount:min(64 * 1024,remaining)) ?? Data()
                guard !data.isEmpty else { throw VelaError("Session source became shorter while verifying indexed prefix") }
                digest.update(data:data); remaining -= data.count
            }
        }
        return digest.finalize().map { String(format:"%02x",$0) }.joined()
    }
    private func recognizedRecord(_ row: JSON, provider: String) -> Bool {
        if provider == "codex" { return ["session_meta","turn_context","response_item","event_msg"].contains(string(row,"type")) && row["payload"] is JSON }
        if provider == "claude" { return row["message"] is JSON || ["result","error","permission_request","approval_requested"].contains(string(row,"type")) }
        return provider == "cursor" && (row["content"] != nil || row["text"] != nil || row["message"] != nil)
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
        let timestampSource = row["timestamp"] is String ? "provider" : "ingestion_fallback"
        if session["startedAt"] == nil { session["startedAt"] = timestamp; session["startedAtSource"] = timestampSource }
        session["lastActivity"] = timestamp; session["lastActivitySource"] = timestampSource
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
                if role == "assistant" || message["usage"] != nil {
                    var totals = session["usageByMessage"] as? [String:JSON] ?? [:]
                    let key = string(message,"id",string(row,"uuid",stableHash(timestamp + textContent(message["content"]))))
                    if let usage = message["usage"] as? JSON {
                        let previous = totals[key] ?? [:]
                        let hasInput = ["input_tokens","cache_read_input_tokens","cache_creation_input_tokens"].contains { usage[$0] != nil }
                        let base = usageTokenCount(usage["input_tokens"])
                        let read = usage["cache_read_input_tokens"] == nil ? 0 : usageTokenCount(usage["cache_read_input_tokens"])
                        let creation = usage["cache_creation_input_tokens"] == nil ? 0 : usageTokenCount(usage["cache_creation_input_tokens"])
                        let input = hasInput ? base.flatMap { base in read.flatMap { read in creation.flatMap { usageTokenSum([base,read,$0]) } } } : usageTokenCount(previous["input"])
                        let output = usage["output_tokens"] == nil ? usageTokenCount(previous["output"]) : usageTokenCount(usage["output_tokens"])
                        let overflow = hasInput ? base != nil && read != nil && creation != nil && input == nil : previous["overflow"] as? Bool == true
                        totals[key] = ["input":input as Any? ?? NSNull(),"output":output as Any? ?? NSNull(),
                                       "overflow":overflow]
                    } else if totals[key] == nil {
                        // A later partial event must not erase usage already
                        // reported for the same assistant message identifier.
                        totals[key] = ["input":NSNull(),"output":NSNull()]
                    }
                    if totals.count > 4096, let first = totals.keys.sorted().first(where:{$0 != key}) {
                        totals.removeValue(forKey:first); session["usageLedgerTruncated"] = true
                    }
                    session["usageByMessage"] = totals
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
                        session["tokenInput"] = usageTokenCount(usage["input_tokens"]) as Any? ?? NSNull()
                        session["tokenOutput"] = usageTokenCount(usage["output_tokens"]) as Any? ?? NSNull()
                        session["usageCoverage"] = "provider-reported cumulative tokens"
                    }
                case "task_complete","turn_complete": session["state"] = "Completed"
                case "turn_aborted": session["state"] = "Stopped"
                case "error": session["state"] = "Error"
                case "task_started": session["lastObservedState"] = "Running"; session["state"] = "Running"; session["statusEvidence"] = "task_started log event"
                case "approval_requested","request_approval","permission_request": session["state"] = "Needs Approval"; session["statusEvidence"] = string(payload,"type")
                default: break
                }
            }
        } else if provider == "cursor" {
            let role = string(row,"role",string(row,"type","assistant"))
            addMessage(row,role:role,content:textContent(row["content"] ?? row["text"] ?? row["message"]),timestamp:timestamp,session:&session)
            if let model = row["model"] as? String { session["model"] = model }
        }
    }
    private func finalizeUsage(provider: String, session: inout JSON) {
        if provider == "claude" {
            let entries = Array((session["usageByMessage"] as? [String:JSON] ?? [:]).values)
            let inputs = entries.compactMap { usageTokenCount($0["input"]) }
            let outputs = entries.compactMap { usageTokenCount($0["output"]) }
            let input = usageTokenSum(inputs), output = usageTokenSum(outputs)
            let truncated = session["usageLedgerTruncated"] as? Bool == true
            session["observedTokenInput"] = input as Any? ?? NSNull()
            session["observedTokenOutput"] = output as Any? ?? NSNull()
            session["tokenInput"] = (!truncated && inputs.count == entries.count ? input : nil) as Any? ?? NSNull()
            session["tokenOutput"] = (!truncated && outputs.count == entries.count ? output : nil) as Any? ?? NSNull()
            session["usageOverflow"] = entries.contains { $0["overflow"] as? Bool == true } || (!inputs.isEmpty && input == nil) || (!outputs.isEmpty && output == nil)
            session["usageCoverage"] = truncated ? "bounded usage ledger; older counters unavailable" : (session["historyTruncated"] as? Bool == true ? "indexed tail only" : "indexed assistant messages only")
        } else if provider != "pi" && provider != "omp" {
            session["tokenInput"] = usageTokenCount(session["tokenInput"]) as Any? ?? NSNull()
            session["tokenOutput"] = usageTokenCount(session["tokenOutput"]) as Any? ?? NSNull()
            session["observedTokenInput"] = session["tokenInput"]
            session["observedTokenOutput"] = session["tokenOutput"]
            let hasCounter = usageTokenCount(session["tokenInput"]) != nil || usageTokenCount(session["tokenOutput"]) != nil
            session["usageCoverage"] = provider == "codex" && hasCounter ? "provider-reported cumulative tokens" : "provider usage unavailable"
        }
        let input = usageTokenCount(session["tokenInput"]), output = usageTokenCount(session["tokenOutput"])
        let observedInput = usageTokenCount(session["observedTokenInput"]), observedOutput = usageTokenCount(session["observedTokenOutput"])
        let available = input != nil && output != nil && usageTokenSum([input!,output!]) != nil
        let overflow = session["usageOverflow"] as? Bool == true || (observedInput != nil && observedOutput != nil && usageTokenSum([observedInput!,observedOutput!]) == nil)
        session["usageAvailable"] = available && !overflow
        session["usageStatus"] = overflow ? "overflow" : available ? "complete" : (observedInput != nil || observedOutput != nil) ? "partial" : "unavailable"
        if !available { session["usageCoverage"] = string(session,"usageCoverage","provider usage unavailable") + "; missing, invalid or out-of-range counters are unavailable" }
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
