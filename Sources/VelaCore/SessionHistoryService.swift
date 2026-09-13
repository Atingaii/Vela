import Foundation
import CoreFoundation
import CryptoKit
import Darwin

final class SessionHistoryService {
    private let store: VelaStore
    private let roots: [String: [URL]]
    private let lock = NSRecursiveLock()
    init(store: VelaStore, roots: [String: [URL]]) { self.store = store; self.roots = roots }
    func handle(_ method: String, _ params: JSON) throws -> Any? {
        guard Self.methods.contains(method) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if method == "history.describe" { return ["version": 1, "methods": Self.methods.sorted(), "decoderVersion": SessionHistorySource.decoderVersion, "defaultDiscovery": "explicit_only", "batchBytes": 4 * 1024 * 1024, "batchRecords": 2000, "pageRecords": 100, "rawChunkBytes": SessionHistorySource.chunkBytes, "normalizerRecordBytes": SessionHistoryDecoder.maximumRecordBytes, "providers": ["claude", "codex", "pi", "omp"], "cursorCompatibility": "not_yet_imported", "networkRequests": 0, "liveStatusAvailable": false] as JSON }
        let project = try checkedProject(params, required: true)!
        guard try store.get("project", stableHash(project)) != nil else { throw VelaError("History requires a registered project") }
        let db = try SessionHistoryStore(store: store)
        switch method {
        case "history.discover": return try discover(params, project: project, db: db)
        case "history.sources": return try sources(params, project: project, db: db)
        case "history.start": return try start(params, project: project, db: db)
        case "history.advance": return try advance(params, project: project, db: db)
        case "history.get": try allowed(params, ["project", "id"]); return try scoped(db, "epoch", requireString(params, "id"), project)
        case "history.jobs":
            try allowed(params, ["project", "afterId"])
            let rows = try db.rows("SELECT json FROM history_objects_v1 WHERE kind='epoch' AND project=? AND id>? ORDER BY id LIMIT 101", [project, string(params, "afterId")])
            return ["items": Array(rows.prefix(100)), "nextAfterId": rows.count > 100 ? string(rows[99], "id") as Any : NSNull(), "limit": 100] as JSON
        case "history.pause", "history.resume", "history.cancel":
            try allowed(params, ["project", "id"])
            return try db.transaction {
                var epoch = try scoped(db, "epoch", requireString(params, "id"), project)
                let state = string(epoch, "state")
                guard ["pending", "paused"].contains(state) || (method == "history.resume" && ["failed", "cancelled"].contains(state)) else { throw VelaError("History task is not pausable or resumable") }
                epoch["state"] = method == "history.cancel" ? "cancelled" : method == "history.pause" ? "paused" : "pending"
                epoch["updatedAt"] = isoNow(); try db.put("epoch", epoch); return epoch
            }
        case "history.page": return try page(params, project: project, db: db)
        case "history.raw": return try raw(params, project: project, db: db)
        case "history.branch": return try branch(params, project: project, db: db)
        default: return nil
        }
    }
    static let methods = Set(["history.describe", "history.discover", "history.sources", "history.start", "history.advance", "history.get", "history.jobs", "history.pause", "history.resume", "history.cancel", "history.page", "history.raw", "history.branch"])
    private func integer(_ params: JSON, _ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = params[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue == Double(number.intValue), range.contains(number.intValue) else { throw VelaError("Invalid history " + key) }
        return number.intValue
    }
    private func allowed(_ params: JSON, _ keys: Set<String>) throws {
        guard Set(params.keys).isSubset(of: keys) else { throw VelaError("Unknown history request field") }
        let numbers = Set(["limit", "maxBytes", "batchBytes", "batchRecords", "ordinal", "part"])
        for (key, value) in params where !numbers.contains(key) {
            guard let text = value as? String, text.utf8.count <= (key == "cursor" ? 512 : 4096), !text.contains("\0") else { throw VelaError("Invalid history " + key) }
        }
    }
    private func scoped(_ db: SessionHistoryStore, _ kind: String, _ id: String, _ project: String) throws -> JSON {
        guard id.utf8.count <= 128, let item = try db.get(kind, id), string(item, "project") == project else { throw VelaError("History record is unavailable in this project") }
        return item
    }
    private func configured(_ source: JSON) throws {
        let provider = string(source, "provider"), root = string(source, "root")
        guard roots[provider]?.contains(where: { $0.path == root }) == true else { throw VelaError("History source root is no longer configured") }
    }
    private func discover(_ params: JSON, project: String, db: SessionHistoryStore) throws -> JSON {
        try allowed(params, ["project", "inventoryId", "provider", "limit"])
        let limit = try integer(params, "limit", fallback: 64, range: 1...128)
        return try db.transaction {
            var inventory: JSON
            if !string(params, "inventoryId").isEmpty { inventory = try scoped(db, "inventory", string(params, "inventoryId"), project) }
            else {
                let requested = string(params, "provider")
                guard requested.isEmpty || SessionHistorySource.providers.contains(requested) else { throw VelaError("Unsupported history provider") }
                let id = UUID().uuidString.lowercased()
                inventory = ["id": id, "project": project, "state": "discovering", "createdAt": isoNow(), "discovered": 0, "examined": 0, "excluded": 0, "unavailableSources": 0, "unsupportedSources": 0, "failures": 0, "traversalComplete": false, "pointInTimeInventory": false]
                for provider in roots.keys.sorted() where requested.isEmpty || provider == requested {
                    for root in roots[provider] ?? [] {
                        try db.execute("INSERT OR IGNORE INTO history_directories_v1(inventory,path,provider,root) VALUES(?,?,?,?)", [id, root.path, provider, root.path])
                    }
                }
            }
            if string(inventory, "state") == "completed" { return inventory }
            let id = string(inventory, "id")
            let pending = try db.rows("SELECT json_object('path',path,'provider',provider,'root',root,'after',after_name,'version',version) FROM history_directories_v1 WHERE inventory=? AND done=0 ORDER BY path LIMIT 1", [id]).first
            var diagnostics: [JSON] = [], found: [JSON] = []
            if let pending {
                let path = string(pending, "path"), root = string(pending, "root"), provider = string(pending, "provider")
                do {
                    try configured(pending)
                    let page = try SessionHistorySource.directoryPage(path: path, root: root, after: string(pending, "after"), limit: limit)
                    guard string(pending, "version").isEmpty || string(pending, "version") == page.version else { throw VelaError("Directory changed between history inventory pages; start a new inventory") }
                    for name in page.names {
                        inventory["examined"] = intValue(inventory, "examined") + 1
                        let child = URL(fileURLWithPath: path).appendingPathComponent(name)
                        var info = stat()
                        guard lstat(child.path, &info) == 0 else { inventory["excluded"] = intValue(inventory, "excluded") + 1; continue }
                        if info.st_mode & S_IFMT == S_IFDIR {
                            if child.path.split(separator: "/").count - root.split(separator: "/").count >= 32 { diagnostics.append(["name": name, "code": "directory_depth_budget"]); inventory["failures"] = intValue(inventory, "failures") + 1 }
                            else { try db.execute("INSERT OR IGNORE INTO history_directories_v1(inventory,path,provider,root) VALUES(?,?,?,?)", [id, child.path, provider, root]) }
                            continue
                        }
                        if provider == "cursor", ["json", "jsonl", "ndjson", "sqlite", "sqlite3", "vscdb"].contains(child.pathExtension.lowercased()) { inventory["unsupportedSources"] = intValue(inventory, "unsupportedSources") + 1 }
                        guard info.st_mode & S_IFMT == S_IFREG, ["jsonl", "ndjson"].contains(child.pathExtension.lowercased()), provider != "cursor" else { inventory["excluded"] = intValue(inventory, "excluded") + 1; continue }
                        do {
                            let header = try SessionHistorySource.header(path: child.path, root: root, provider: provider)
                            guard string(header, "project") == project else { inventory["excluded"] = intValue(inventory, "excluded") + 1; continue }
                            let sourceId = stableHash(id + ":" + provider + ":" + child.path)
                            var source = header
                            source.merge(["id": sourceId, "inventoryId": id, "project": project, "provider": provider, "path": child.path, "root": root, "relativePath": String(child.path.dropFirst(root.count + 1)), "discoveredAt": isoNow(), "sourceIdentity": stableHash(provider + ":" + child.path)]) { _, new in new }
                            try db.put("source", source); found.append(source); inventory["discovered"] = intValue(inventory, "discovered") + 1
                        } catch { inventory["excluded"] = intValue(inventory, "excluded") + 1; inventory["unavailableSources"] = intValue(inventory, "unavailableSources") + 1; diagnostics.append(["name": name, "code": "unavailable_or_unknown_header", "message": error.localizedDescription]) }
                    }
                    try db.execute("UPDATE history_directories_v1 SET after_name=?,version=?,done=? WHERE inventory=? AND path=?", [page.names.last ?? string(pending, "after"), page.version, page.more ? 0 : 1, id, path])
                } catch {
                    diagnostics.append(["directory": path, "message": error.localizedDescription]); inventory["failures"] = intValue(inventory, "failures") + 1
                    try db.execute("UPDATE history_directories_v1 SET done=1 WHERE inventory=? AND path=?", [id, path])
                }
            }
            let remaining = try db.rows("SELECT json_object('count',COUNT(*)) FROM history_directories_v1 WHERE inventory=? AND done=0", [id]).first ?? [:]
            inventory["pendingDirectories"] = intValue(remaining, "count")
            if intValue(remaining, "count") == 0 { inventory["state"] = "completed"; inventory["traversalComplete"] = intValue(inventory, "failures") == 0 }
            inventory["updatedAt"] = isoNow(); inventory["lastDiagnostics"] = diagnostics
            inventory["coverage"] = "bounded per-directory observation; unknown/unscoped formats excluded; no simultaneous filesystem snapshot"
            try db.put("inventory", inventory)
            var result = inventory; result["items"] = found; return result
        }
    }
    private func sources(_ params: JSON, project: String, db: SessionHistoryStore) throws -> JSON {
        try allowed(params, ["project", "inventoryId", "afterId", "limit"])
        let inventory = try scoped(db, "inventory", requireString(params, "inventoryId"), project)
        let limit = try integer(params, "limit", fallback: 50, range: 1...100)
        let items = try db.rows("SELECT json FROM history_objects_v1 WHERE kind='source' AND project=? AND json_extract(json,'$.inventoryId')=? AND id>? ORDER BY id LIMIT ?", [project, string(inventory, "id"), string(params, "afterId"), limit + 1])
        return ["items": Array(items.prefix(limit)), "nextAfterId": items.count > limit ? string(items[limit - 1], "id") as Any : NSNull(), "inventoryState": string(inventory, "state"), "traversalComplete": inventory["traversalComplete"] ?? false]
    }
    private func start(_ params: JSON, project: String, db: SessionHistoryStore) throws -> JSON {
        try allowed(params, ["project", "sourceId", "maxBytes"])
        let source = try scoped(db, "source", requireString(params, "sourceId"), project); try configured(source)
        let current = try SessionHistorySource.header(path: string(source, "path"), root: string(source, "root"), provider: string(source, "provider"))
        guard string(current, "project") == project else { throw VelaError("History source project changed") }
        let maximum = try integer(params, "maxBytes", fallback: 256 * 1024 * 1024, range: 1...8 * 1024 * 1024 * 1024)
        guard intValue(current, "sourceBytes") <= maximum else { throw VelaError("History source exceeds the explicitly selected source-byte budget") }
        let id = stableHash(string(source, "sourceIdentity") + ":" + string(current, "sourceVersion") + ":" + SessionHistorySource.decoderVersion + ":" + project)
        return try db.transaction {
            if let existing = try db.get("epoch", id) { return existing }
            var epoch = source; epoch.merge(current) { _, new in new }
            epoch.merge(["id": id, "sourceId": string(source, "id"), "state": "pending", "offset": 0, "recordStart": 0, "ordinal": 0, "recordParts": 0, "recordBytes": 0, "recordChainHash": "", "records": 0, "visibleRecords": 0, "unknownRecords": 0, "invalidRecords": 0, "excludedRecords": 0, "currentProject": project, "rawBytesComplete": false, "normalizationComplete": false, "projectScopeComplete": false, "branchIntegrity": true, "maxBytes": maximum, "createdAt": isoNow(), "updatedAt": isoNow()]) { _, new in new }
            try db.put("epoch", epoch); return epoch
        }
    }
    private func advance(_ params: JSON, project: String, db: SessionHistoryStore) throws -> JSON {
        try allowed(params, ["project", "id", "batchBytes", "batchRecords"])
        let byteBudget = try integer(params, "batchBytes", fallback: 4 * 1024 * 1024, range: 1...4 * 1024 * 1024)
        let recordBudget = try integer(params, "batchRecords", fallback: 2000, range: 1...2000)
        return try db.transaction {
            var epoch = try scoped(db, "epoch", requireString(params, "id"), project)
            guard string(epoch, "state") == "pending" else { return epoch }
            try configured(epoch)
            let id = string(epoch, "id"), path = string(epoch, "path"), root = string(epoch, "root"), version = string(epoch, "sourceVersion")
            let descriptor: Int32
            do { let opened = try SessionHistorySource.open(path, root: root); descriptor = opened.0
                if SessionHistorySource.identity(opened.1) != version { close(descriptor); throw VelaError("History source version changed") }
            } catch { epoch["state"] = "stale"; epoch["error"] = error.localizedDescription; epoch["updatedAt"] = isoNow(); try db.put("epoch", epoch); return epoch }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? file.close() }
            try file.seek(toOffset: UInt64(intValue(epoch, "offset")))
            try db.execute("SAVEPOINT history_batch")
            let original = epoch
            var sourceChanged = false
            do {
                var consumed = 0, completed = 0
                let deadline = Date().addingTimeInterval(1)
                while consumed < byteBudget, completed < recordBudget, intValue(epoch, "offset") < intValue(epoch, "sourceBytes") {
                    if consumed > 0 && Date() >= deadline { break }
                    let bytes = try file.read(upToCount: min(SessionHistorySource.chunkBytes, byteBudget - consumed)) ?? Data()
                    guard !bytes.isEmpty else { throw VelaError("History source ended before its frozen size") }
                    var position = bytes.startIndex
                    while position < bytes.endIndex, completed < recordBudget {
                        let newline = bytes[position...].firstIndex(of: 10)
                        let end = newline.map { bytes.index(after: $0) } ?? bytes.endIndex
                        let chunk = Data(bytes[position..<end])
                        epoch["recordParts"] = try db.appendRaw(epoch: id, ordinal: intValue(epoch, "ordinal"), parts: intValue(epoch, "recordParts"), bytes: chunk)
                        epoch["recordBytes"] = intValue(epoch, "recordBytes") + chunk.count
                        epoch["recordChainHash"] = stableHash(string(epoch, "recordChainHash") + ":" + SHA256.hash(data: chunk).map { String(format: "%02x", $0) }.joined())
                        epoch["offset"] = intValue(epoch, "offset") + chunk.count
                        consumed += chunk.count; position = end
                        if newline != nil { try finishRecord(&epoch, db: db, terminated: true); completed += 1 }
                    }
                    if completed == recordBudget { break }
                }
                if intValue(epoch, "offset") == intValue(epoch, "sourceBytes"), intValue(epoch, "recordBytes") > 0 { try finishRecord(&epoch, db: db, terminated: false) }
                do { try SessionHistorySource.verify(descriptor, path: path, root: root, version: version) }
                catch { sourceChanged = true; throw error }
                if intValue(epoch, "offset") == intValue(epoch, "sourceBytes") {
                    epoch["state"] = "completed"; epoch["rawBytesComplete"] = true
                    epoch["normalizationComplete"] = intValue(epoch, "unknownRecords") == 0 && intValue(epoch, "invalidRecords") == 0
                    epoch["projectScopeComplete"] = intValue(epoch, "excludedRecords") == 0
                }
                epoch["updatedAt"] = isoNow(); epoch["lastBatchBytes"] = consumed
                try db.put("epoch", epoch); try db.execute("RELEASE history_batch"); return epoch
            } catch {
                try db.execute("ROLLBACK TO history_batch"); try db.execute("RELEASE history_batch")
                epoch = original; epoch["state"] = sourceChanged ? "stale" : "failed"; epoch["error"] = error.localizedDescription; epoch["updatedAt"] = isoNow(); try db.put("epoch", epoch); return epoch
            }
        }
    }
    private func finishRecord(_ epoch: inout JSON, db: SessionHistoryStore, terminated: Bool) throws {
        let id = string(epoch, "id"), ordinal = intValue(epoch, "ordinal"), count = intValue(epoch, "recordBytes")
        var bytes = Data()
        if count <= SessionHistoryDecoder.maximumRecordBytes {
            for part in 0..<intValue(epoch, "recordParts") { guard let chunk = try db.blob(epoch: id, ordinal: ordinal, part: part) else { throw VelaError("History original chunk is missing") }; bytes.append(chunk) }
            guard bytes.count == count else { throw VelaError("History original length mismatch") }
        }
        var event: JSON
        if count > SessionHistoryDecoder.maximumRecordBytes {
            event = ["ordinal": ordinal, "normalized": false, "project": "", "type": "unknown", "diagnostic": "record_exceeds_normalizer_budget", "timestamp": NSNull(), "providerId": "", "parentId": NSNull()]
            epoch["currentProject"] = ""
        } else { event = SessionHistoryDecoder.decode(bytes, provider: string(epoch, "provider"), state: &epoch, ordinal: ordinal, terminated: terminated) }
        event.merge(["epochId": id, "recordStart": intValue(epoch, "recordStart"), "recordBytes": count, "rawParts": intValue(epoch, "recordParts"), "terminated": terminated, "rawSHA256": bytes.isEmpty && count > 0 ? NSNull() as Any : SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "chunkChainHash": string(epoch, "recordChainHash"), "decoderVersion": SessionHistorySource.decoderVersion]) { _, new in new }
        let providerId = string(event, "providerId")
        if ["pi", "omp"].contains(string(epoch, "provider")), ["duplicate_session_header", "invalid_branch_identity", "invalid_parent_identity", "record_exceeds_normalizer_budget", "malformed_json_record", "unterminated_invalid_tail"].contains(string(event, "diagnostic")) { epoch["branchIntegrity"] = false }
        if !providerId.isEmpty {
            let previous = try db.rows("SELECT json FROM history_records_v1 WHERE epoch=? AND provider_id=? ORDER BY ordinal DESC LIMIT 1", [id, providerId]).first
            if let previous {
                event["previousSameProviderIdOrdinal"] = intValue(previous, "ordinal")
                if ["pi", "omp"].contains(string(epoch, "provider")) { epoch["branchIntegrity"] = false; event["branchDiagnostic"] = "duplicate_provider_id" }
            }
            if ["pi", "omp"].contains(string(epoch, "provider")), let parent = event["parentId"] as? String {
                if try db.rows("SELECT json FROM history_records_v1 WHERE epoch=? AND provider_id=? ORDER BY ordinal LIMIT 2", [id, parent]).count != 1 { epoch["branchIntegrity"] = false; event["branchDiagnostic"] = "missing_or_ambiguous_earlier_parent" }
            }
        }
        let project = string(event, "project")
        if project == string(epoch, "project") { epoch["visibleRecords"] = intValue(epoch, "visibleRecords") + 1 }
        else { epoch["excludedRecords"] = intValue(epoch, "excludedRecords") + 1 }
        if event["normalized"] as? Bool != true { epoch["unknownRecords"] = intValue(epoch, "unknownRecords") + 1 }
        if ["malformed_json_record", "unterminated_invalid_tail", "record_exceeds_normalizer_budget"].contains(string(event, "diagnostic")) { epoch["invalidRecords"] = intValue(epoch, "invalidRecords") + 1 }
        try db.execute("INSERT INTO history_records_v1(epoch,ordinal,project,provider_id,parent_id,normalized,json) VALUES(?,?,?,?,?,?,?)", [id, ordinal, project, providerId, event["parentId"] ?? NSNull(), event["normalized"] as? Bool == true ? 1 : 0, try jsonString(event)])
        epoch["records"] = intValue(epoch, "records") + 1; epoch["ordinal"] = ordinal + 1
        epoch["recordStart"] = intValue(epoch, "offset"); epoch["recordParts"] = 0; epoch["recordBytes"] = 0; epoch["recordChainHash"] = ""
    }
    private func cursor(_ value: String, binding: String) throws -> Int? {
        guard !value.isEmpty else { return nil }
        guard value.utf8.count <= 512, let bytes = Data(base64Encoded: value), let object = try JSONSerialization.jsonObject(with: bytes) as? JSON,
              string(object, "binding") == binding else { throw VelaError("History cursor does not match this source and page order") }
        return try integer(object, "ordinal", fallback: -1, range: 0...Int.max)
    }
    private func encodeCursor(_ ordinal: Int, binding: String) throws -> String { Data(try jsonString(["ordinal": ordinal, "binding": binding]).utf8).base64EncodedString() }
    private func page(_ params: JSON, project: String, db: SessionHistoryStore) throws -> JSON {
        try allowed(params, ["project", "id", "cursor", "direction", "limit", "type"])
        let epoch = try scoped(db, "epoch", requireString(params, "id"), project)
        let id = string(epoch, "id"), direction = string(params, "direction", "forward"), type = string(params, "type")
        guard ["forward", "backward"].contains(direction), type.utf8.count <= 64 else { throw VelaError("Invalid history page order") }
        let limit = try integer(params, "limit", fallback: 50, range: 1...100)
        let binding = stableHash(id + ":" + project + ":" + direction + ":" + type)
        let after = try cursor(string(params, "cursor"), binding: binding) ?? (direction == "forward" ? -1 : Int.max)
        let comparison = direction == "forward" ? ">" : "<", order = direction == "forward" ? "ASC" : "DESC"
        let query = "SELECT json FROM history_records_v1 WHERE epoch=? AND project=? AND ordinal" + comparison + "?" + (type.isEmpty ? "" : " AND json_extract(json,'$.type')=?") + " ORDER BY ordinal " + order + " LIMIT ?"
        var values: [Any] = [id, project, after]; if !type.isEmpty { values.append(type) }; values.append(limit + 1)
        let items = try db.rows(query, values)
        return ["items": Array(items.prefix(limit)), "nextCursor": items.count > limit ? try encodeCursor(intValue(items[limit - 1], "ordinal"), binding: binding) as Any : NSNull(), "endCursor": try items.prefix(limit).last.map { try encodeCursor(intValue($0, "ordinal"), binding: binding) } as Any? ?? NSNull(), "epochId": id, "state": string(epoch, "state"), "rawBytesComplete": epoch["rawBytesComplete"] ?? false, "normalizationComplete": epoch["normalizationComplete"] ?? false, "projectScopeComplete": epoch["projectScopeComplete"] ?? false, "order": "source_physical_ordinal", "mutableSourceRead": false]
    }
    private func raw(_ params: JSON, project: String, db: SessionHistoryStore) throws -> JSON {
        try allowed(params, ["project", "id", "ordinal", "part"])
        let epoch = try scoped(db, "epoch", requireString(params, "id"), project)
        let ordinal = try integer(params, "ordinal", fallback: -1, range: 0...Int.max), part = try integer(params, "part", fallback: 0, range: 0...Int.max)
        guard let event = try db.rows("SELECT json FROM history_records_v1 WHERE epoch=? AND ordinal=? AND project=?", [string(epoch, "id"), ordinal, project]).first,
              let chunk = try db.blob(epoch: string(epoch, "id"), ordinal: ordinal, part: part) else { throw VelaError("History original is unavailable in this project") }
        return ["epochId": string(epoch, "id"), "ordinal": ordinal, "part": part, "dataBase64": chunk.base64EncodedString(), "bytes": chunk.count, "nextPart": part + 1 < intValue(event, "rawParts") ? part + 1 as Any : NSNull(), "rawSHA256": event["rawSHA256"] ?? NSNull(), "includesOriginalTerminator": true]
    }
    private func branch(_ params: JSON, project: String, db: SessionHistoryStore) throws -> JSON {
        try allowed(params, ["project", "id", "leafId", "cursor", "limit"])
        let epoch = try scoped(db, "epoch", requireString(params, "id"), project)
        guard ["pi", "omp"].contains(string(epoch, "provider")), epoch["branchIntegrity"] as? Bool == true else { throw VelaError("History branch ancestry is unavailable or ambiguous") }
        let id = string(epoch, "id"), leaf = string(params, "leafId", string(epoch, "lastProviderId"))
        guard !leaf.isEmpty, leaf.utf8.count <= 1024 else { throw VelaError("History branch leaf is required") }
        let binding = stableHash(id + ":" + project + ":branch:" + leaf), limit = try integer(params, "limit", fallback: 50, range: 1...100)
        var current: JSON?
        if let ordinal = try cursor(string(params, "cursor"), binding: binding) { current = try db.rows("SELECT json FROM history_records_v1 WHERE epoch=? AND ordinal=?", [id, ordinal]).first }
        else { current = try db.rows("SELECT json FROM history_records_v1 WHERE epoch=? AND provider_id=? ORDER BY ordinal DESC LIMIT 1", [id, leaf]).first }
        var items: [JSON] = []
        while let item = current, items.count < limit {
            guard string(item, "project") == project else { throw VelaError("History branch crosses unavailable project scope") }
            items.append(item)
            if let parent = item["parentId"] as? String {
                let parents = try db.rows("SELECT json FROM history_records_v1 WHERE epoch=? AND provider_id=? ORDER BY ordinal LIMIT 2", [id, parent])
                guard parents.count == 1, intValue(parents[0], "ordinal") < intValue(item, "ordinal") else { throw VelaError("History branch ancestry is invalid") }; current = parents[0]
            } else { current = nil }
        }
        return ["items": items, "nextCursor": try current.map { try encodeCursor(intValue($0, "ordinal"), binding: binding) } as Any? ?? NSNull(), "leafId": leaf, "branchSelectionSource": "explicit leaf or last persisted entry; in-memory leaf unavailable", "order": "leaf_to_ancestor", "branchIntegrity": true]
    }
}
