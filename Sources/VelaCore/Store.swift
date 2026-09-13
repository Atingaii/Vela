import Foundation
import CryptoKit
import CSQLite
import Darwin

public typealias JSON = [String: Any]
public struct VelaError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public func jsonString(_ value: Any) throws -> String {
    guard JSONSerialization.isValidJSONObject(value) else { throw VelaError("Invalid JSON object") }
    return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}
public func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }
public func stableHash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
public func canonicalProject(_ path: String) -> String {
    var candidate = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    var suffix: [String] = []
    while true {
        if let resolved = candidate.path.withCString({ realpath($0,nil) }) {
            defer { free(resolved) }
            var result = URL(fileURLWithPath:String(cString:resolved))
            for component in suffix.reversed() { result.appendPathComponent(component) }
            return result.path
        }
        if candidate.path == "/" { return URL(fileURLWithPath:path).standardizedFileURL.path }
        suffix.append(candidate.lastPathComponent); candidate.deleteLastPathComponent()
    }
}

func string(_ object: JSON, _ key: String, _ fallback: String = "") -> String { object[key] as? String ?? fallback }
func requireString(_ object: JSON, _ key: String) throws -> String {
    guard let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VelaError("Missing or empty \(key)") }
    return value
}
func intValue(_ object: JSON, _ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
func checkedProject(_ params: JSON, required: Bool = false) throws -> String? {
    guard let raw = params["project"] as? String, !raw.isEmpty else {
        if required { throw VelaError("A project root is required") }; return nil
    }
    guard raw.hasPrefix("/") || raw.hasPrefix("~/") else { throw VelaError("Project must be an absolute path") }
    return canonicalProject(raw)
}
func privateLibraryPath(_ path: String) -> Bool {
    let components = URL(fileURLWithPath:path).standardizedFileURL.pathComponents
    return components.enumerated().contains { index, component in
        guard ["private",".private"].contains(component.lowercased()) else { return false }
        // /private/var and /private/tmp are macOS system aliases, not a user privacy label.
        if index == 1, component == "private", components.count > 2, ["var","tmp","etc"].contains(components[2]) { return false }
        return true
    }
}

func tokenEstimate(_ text: String) -> Int {
    // Conservative for mixed CJK/code; deliberately overestimates instead of overflowing recall budgets.
    text.unicodeScalars.reduce(0) { $0 + ($1.value > 0x7f ? 2 : 1) }
}

public final class VelaStore {
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var isBatching = false
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let assetKinds: Set<String> = ["memory", "workflow", "guideline", "library", "checkpoint"]

    public init(root: URL) throws {
        self.root = URL(fileURLWithPath:canonicalProject(root.path))
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = self.root.appendingPathComponent("vela.sqlite3")
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw VelaError("Cannot open Vela SQLite database") }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("CREATE TABLE IF NOT EXISTS objects(kind TEXT NOT NULL,id TEXT NOT NULL,project TEXT NOT NULL DEFAULT '',title TEXT NOT NULL DEFAULT '',content TEXT NOT NULL DEFAULT '',private INTEGER NOT NULL DEFAULT 0,updatedAt TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(kind,id))")
        try execute("CREATE INDEX IF NOT EXISTS objects_project ON objects(project,kind,updatedAt)")
        try execute("CREATE INDEX IF NOT EXISTS objects_runtime_workflow ON objects(kind,project,json_extract(json,'$.workflowId'),json_extract(json,'$.state')) WHERE kind IN ('schedule_event','run')")
        // Read substring candidates in row order instead of following the
        // time-ordered listing index through every matching project's content.
        try execute("CREATE INDEX IF NOT EXISTS objects_search_project ON objects(project,private,kind)")
        try execute("CREATE TABLE IF NOT EXISTS memory_embeddings(memory_id TEXT NOT NULL,project TEXT NOT NULL,language TEXT NOT NULL,model TEXT NOT NULL,revision INTEGER NOT NULL,dimension INTEGER NOT NULL,source_hash TEXT NOT NULL,vector BLOB NOT NULL,PRIMARY KEY(memory_id,language))")
        try execute("CREATE INDEX IF NOT EXISTS memory_embeddings_scope ON memory_embeddings(project,language)")
        try execute("CREATE TRIGGER IF NOT EXISTS vela_memory_vector_delete AFTER DELETE ON objects WHEN OLD.kind='memory' BEGIN DELETE FROM memory_embeddings WHERE memory_id=OLD.id; END")
        try execute("CREATE TRIGGER IF NOT EXISTS vela_memory_vector_private AFTER UPDATE ON objects WHEN NEW.kind='memory' AND NEW.private<>0 BEGIN DELETE FROM memory_embeddings WHERE memory_id=NEW.id; END")
        // A one-row change counter keeps background analysis from rescanning session history
        // every timer tick. Triggers also observe writes made by another helper connection.
        try execute("CREATE TABLE IF NOT EXISTS session_change_counter(singleton INTEGER PRIMARY KEY CHECK(singleton=1),revision INTEGER NOT NULL)")
        try execute("INSERT OR IGNORE INTO session_change_counter(singleton,revision) VALUES(1,0)")
        try execute("CREATE TRIGGER IF NOT EXISTS vela_session_insert AFTER INSERT ON objects WHEN NEW.kind='session' BEGIN UPDATE session_change_counter SET revision=revision+1 WHERE singleton=1; END")
        try execute("CREATE TRIGGER IF NOT EXISTS vela_session_update AFTER UPDATE OF json ON objects WHEN NEW.kind='session' AND OLD.json<>NEW.json BEGIN UPDATE session_change_counter SET revision=revision+1 WHERE singleton=1; END")
        try execute("CREATE TRIGGER IF NOT EXISTS vela_session_delete AFTER DELETE ON objects WHEN OLD.kind='session' BEGIN UPDATE session_change_counter SET revision=revision+1 WHERE singleton=1; END")
        // Compact completion identities provide an unbounded durable cursor;
        // scheduling never rescans or loads entire session transcripts.
        try execute("CREATE TABLE IF NOT EXISTS session_completions(sequence INTEGER PRIMARY KEY AUTOINCREMENT,project TEXT NOT NULL,session_id TEXT NOT NULL,activity TEXT NOT NULL,UNIQUE(project,session_id,activity))")
        try execute("CREATE INDEX IF NOT EXISTS session_completions_project ON session_completions(project,sequence)")
        // An outer UPSERT can override INSERT OR IGNORE inside a trigger;
        // explicit UPSERT DO NOTHING preserves completion deduplication.
        let completionInsert = "INSERT INTO session_completions(project,session_id,activity) VALUES(NEW.project,NEW.id,COALESCE(json_extract(NEW.json,'$.lastActivity'),NEW.updatedAt)) ON CONFLICT(project,session_id,activity) DO NOTHING;"
        try execute("DROP TRIGGER IF EXISTS vela_completion_insert")
        try execute("DROP TRIGGER IF EXISTS vela_completion_update")
        try execute("CREATE TRIGGER IF NOT EXISTS vela_completion_insert_v2 AFTER INSERT ON objects WHEN NEW.kind='session' AND lower(json_extract(NEW.json,'$.state'))='completed' BEGIN " + completionInsert + " END")
        try execute("CREATE TRIGGER IF NOT EXISTS vela_completion_update_v2 AFTER UPDATE ON objects WHEN NEW.kind='session' AND lower(json_extract(NEW.json,'$.state'))='completed' AND (COALESCE(lower(json_extract(OLD.json,'$.state')),'')<>'completed' OR COALESCE(json_extract(OLD.json,'$.lastActivity'),OLD.updatedAt)<>COALESCE(json_extract(NEW.json,'$.lastActivity'),NEW.updatedAt)) BEGIN " + completionInsert + " END")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    deinit { sqlite3_close(db) }
    /// Lists must not deserialize bounded-but-large provider transcripts merely
    /// to discard them. Keep the allowed kinds and selected fields explicit.
    func runtimeSummaries(_ kind: String, project: String, limit: Int = 100) throws -> [JSON] {
        guard ["agent_loop","knowledge_query"].contains(kind), (1...100).contains(limit) else { throw VelaError("Unsupported runtime summary request") }
        lock.lock(); defer { lock.unlock() }
        // The approval journal is authoritative even when rejecting a pending
        // task never entered its executor to update the raw runtime record.
        let sql = """
        SELECT json_object(
          'id',r.id,'title',r.title,'kind',r.kind,'project',r.project,
          'state',CASE
            WHEN json_extract(a.json,'$.state')='rejected' THEN 'rejected'
            WHEN r.kind='knowledge_query' AND json_extract(a.json,'$.state') IN ('executing','needs_review') THEN 'executing_or_uncertain'
            WHEN r.kind='knowledge_query' AND json_extract(a.json,'$.state')='failed' THEN 'failed'
            WHEN r.kind='agent_loop' AND json_extract(a.json,'$.state')='needs_review' THEN 'needs_review'
            WHEN r.kind='agent_loop' AND json_extract(a.json,'$.state')='executing'
              AND json_extract(r.json,'$.state') NOT IN ('completed','failed','cancelled','budget_exhausted','needs_review') THEN 'running_or_uncertain'
            ELSE json_extract(r.json,'$.state') END,
          'runId',json_extract(r.json,'$.runId'),'approvalId',json_extract(r.json,'$.approvalId'),
          'createdAt',json_extract(r.json,'$.createdAt'),'updatedAt',r.updatedAt,
          'modelCalls',json_extract(r.json,'$.modelCalls'),'round',json_extract(r.json,'$.round'),
          'providerAttempts',json_extract(r.json,'$.providerAttempts'),'completedModelCalls',json_extract(r.json,'$.completedModelCalls'),
          'completedAt',json_extract(r.json,'$.completedAt'),'error',substr(json_extract(r.json,'$.error'),1,512))
        FROM objects r LEFT JOIN objects a ON a.kind='approval' AND a.id=json_extract(r.json,'$.approvalId') AND a.project=r.project
        WHERE r.kind=? AND r.project=? ORDER BY r.updatedAt DESC,r.id ASC LIMIT ?
        """
        return try select(sql,[kind,canonicalProject(project),limit])
    }
    public func sessionRevision() throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let pointer = try statement("SELECT revision FROM session_change_counter WHERE singleton=1")
        defer { sqlite3_finalize(pointer) }
        guard sqlite3_step(pointer) == SQLITE_ROW else { throw VelaError("Session change counter is unavailable") }
        return sqlite3_column_int64(pointer,0)
    }
    private func statement(_ sql: String, _ values: [Any] = []) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw VelaError("SQLite: \(String(cString: sqlite3_errmsg(db)))") }
        for (index, value) in values.enumerated() {
            if let number = value as? Int { sqlite3_bind_int64(pointer, Int32(index + 1), Int64(number)) }
            else if let data = value as? Data { _ = data.withUnsafeBytes { sqlite3_bind_blob(pointer, Int32(index + 1), $0.baseAddress, Int32($0.count), transient) } }
            else { sqlite3_bind_text(pointer, Int32(index + 1), String(describing: value), -1, transient) }
        }
        return pointer
    }
    private func execute(_ sql: String, _ values: [Any] = []) throws {
        let pointer = try statement(sql, values); defer { sqlite3_finalize(pointer) }
        let result = sqlite3_step(pointer)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw VelaError("SQLite: \(String(cString: sqlite3_errmsg(db)))") }
    }
    private func select(_ sql: String, _ values: [Any] = []) throws -> [JSON] {
        let pointer = try statement(sql, values); defer { sqlite3_finalize(pointer) }
        var result: [JSON] = []
        while true {
            let step = sqlite3_step(pointer)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW, let data = sqlite3_column_text(pointer, 0) else { throw VelaError("SQLite query failed") }
            guard let object = try JSONSerialization.jsonObject(with: Data(String(cString: data).utf8)) as? JSON else { throw VelaError("Corrupt stored JSON") }
            result.append(object)
        }
    }
    private func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty, value.count <= 150, value.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil, value != ".", value != ".." else { throw VelaError("Invalid object identifier") }
    }
    public func assetURL(kind: String, id: String) throws -> URL {
        try validateIdentifier(kind); try validateIdentifier(id)
        guard assetKinds.contains(kind) else { throw VelaError("This object has no Markdown asset") }
        let directory = root.appendingPathComponent("assets/\(kind)")
        // Create each component relative to a verified directory, never through a
        // path that may follow an existing assets/ or kind/ symbolic link.
        var directoryFD = Darwin.open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw VelaError("Cannot open asset store safely") }
        defer { Darwin.close(directoryFD) }
        for component in ["assets",kind] {
            var childFD = openat(directoryFD,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if childFD < 0, errno == ENOENT {
                guard mkdirat(directoryFD,component,0o700) == 0 || errno == EEXIST else { throw VelaError("Cannot create asset directory safely") }
                childFD = openat(directoryFD,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard childFD >= 0 else { throw VelaError("Refusing unsafe asset directory") }
            Darwin.close(directoryFD); directoryFD = childFD
        }
        guard canonicalProject(directory.path).hasPrefix(root.path + "/") else { throw VelaError("Asset directory escapes store") }
        let url = directory.appendingPathComponent(id + ".md")
        if (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true { throw VelaError("Refusing symlink asset") }
        return url
    }
    @discardableResult public func put(_ kind: String, _ object: JSON, createOnly: Bool = false) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        try validateIdentifier(kind)
        var item = object
        let id = string(item, "id", UUID().uuidString.lowercased()); try validateIdentifier(id)
        let previous = try get(kind, id)
        if kind == "library", privateLibraryPath(string(item,"sourcePath")) || string(item,"scope").lowercased() == "private" { item["private"] = true }
        item["id"] = id; item["kind"] = kind; item["createdAt"] = previous?["createdAt"] ?? item["createdAt"] ?? isoNow(); item["updatedAt"] = isoNow()
        if let project = item["project"] as? String, !project.isEmpty { item["project"] = canonicalProject(project) }
        var asset: URL?; var oldAsset: Data?
        if assetKinds.contains(kind) {
            asset = try assetURL(kind: kind, id: id)
            item["assetPath"] = asset!.path
        }
        let encoded = try jsonString(item)
        if !isBatching { try execute("BEGIN IMMEDIATE") }
        var attemptedAssetWrite = false
        do {
            if createOnly, try !select("SELECT json FROM objects WHERE kind=? AND id=?",[kind,id]).isEmpty {
                throw VelaError("An existing reference cannot be overwritten by a create-only request")
            }
            if let asset { oldAsset = try? Data(contentsOf:asset) }
            try execute("INSERT INTO objects(kind,id,project,title,content,private,updatedAt,json) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET project=excluded.project,title=excluded.title,content=excluded.content,private=excluded.private,updatedAt=excluded.updatedAt,json=excluded.json", [kind, id, string(item,"project"), string(item,"title"), string(item,"content"), (item["private"] as? Bool == true || string(item,"scope") == "private") ? 1 : 0, string(item,"updatedAt"), encoded])
            if let asset {
                var metadata = item; metadata.removeValue(forKey: "content")
                let markdown = "<!-- Vela metadata: \(try jsonString(metadata)) -->\n\n# \(string(item,"title",kind))\n\n\(string(item,"content"))\n"
                attemptedAssetWrite = true
                try Data(markdown.utf8).write(to: asset, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: asset.path)
            }
            if !isBatching { try execute("COMMIT") }
        } catch {
            if !isBatching { try? execute("ROLLBACK") }
            if attemptedAssetWrite, let asset {
                if let oldAsset { try? oldAsset.write(to: asset, options: .atomic) }
                else { try? FileManager.default.removeItem(at: asset) }
            }
            throw error
        }
        return item
    }
    @discardableResult public func putBatch(_ objects: [(String,JSON)], expecting: [(String,String,String)] = [], expectingAbsent: [(String,String)] = [], createOnly: Bool = false) throws -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        guard !isBatching else { throw VelaError("Nested store batches are unsupported") }
        var prepared: [(String,JSON)] = []
        for (kind,raw) in objects {
            var object = raw; let id = string(object,"id",UUID().uuidString.lowercased()); object["id"] = id
            try validateIdentifier(kind); try validateIdentifier(id)
            prepared.append((kind,object))
        }
        try execute("BEGIN IMMEDIATE"); isBatching = true
        var writtenBackups: [(URL,Data?)] = []
        do {
            // The write transaction excludes other Vela writers before checking
            // snapshots, taking backups, or touching any asset directory.
            for (kind,id,expectedHash) in expecting {
                try validateIdentifier(kind); try validateIdentifier(id)
                guard let current = try get(kind,id), stableHash(try jsonString(current)) == expectedHash else {
                    throw VelaError("Batch source changed or is missing; review the latest state before retrying")
                }
            }
            for (kind,id) in expectingAbsent {
                try validateIdentifier(kind); try validateIdentifier(id)
                guard try get(kind,id) == nil else { throw VelaError("A new batch identity already exists; no object was overwritten") }
            }
            var result: [JSON] = []
            for (kind,object) in prepared {
                var backup: (URL,Data?)?
                if assetKinds.contains(kind) {
                    let asset = try assetURL(kind:kind,id:string(object,"id"))
                    backup = (asset,try? Data(contentsOf:asset))
                }
                let saved = try put(kind,object,createOnly:createOnly)
                // A failing put restores its own partial asset write. Only a
                // completed write belongs to the outer batch rollback.
                if let backup { writtenBackups.append(backup) }
                result.append(saved)
            }
            try execute("COMMIT"); isBatching = false; return result
        } catch {
            var restorationErrors: [String] = []
            // Retain the DB write lock through file restoration so a waiting
            // process cannot write a newer asset before this rollback finishes.
            for (asset,data) in writtenBackups.reversed() {
                do {
                    if let data { try data.write(to:asset,options:.atomic) }
                    else if FileManager.default.fileExists(atPath:asset.path) { try FileManager.default.removeItem(at:asset) }
                } catch { restorationErrors.append(error.localizedDescription) }
            }
            try? execute("ROLLBACK"); isBatching = false
            if !restorationErrors.isEmpty { throw VelaError("Batch failed and asset restoration requires review: " + restorationErrors.joined(separator:"; ")) }
            throw error
        }
    }
    public func insertIfAbsent(_ kind: String, _ raw: JSON) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ["schedule_event","schedule","run","approval"].contains(kind), !isBatching else { throw VelaError("Insert claims are limited to runtime objects outside a batch") }
        let id = try requireString(raw,"id"); try validateIdentifier(id)
        var object = raw; object["id"] = id; object["kind"] = kind; object["createdAt"] = raw["createdAt"] ?? isoNow(); object["updatedAt"] = isoNow()
        if let project = raw["project"] as? String, !project.isEmpty { object["project"] = canonicalProject(project) }
        try execute("INSERT OR IGNORE INTO objects(kind,id,project,title,content,private,updatedAt,json) VALUES(?,?,?,?,?,?,?,?)",[kind,id,string(object,"project"),string(object,"title"),string(object,"content"),0,string(object,"updatedAt"),try jsonString(object)])
        return sqlite3_changes(db) == 1
    }
    func sessionCompletionRevision() throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let row = try select("SELECT json_object('revision',COALESCE(MAX(sequence),0)) FROM session_completions").first
        return (row?["revision"] as? NSNumber)?.int64Value ?? 0
    }
    func sessionCompletionPage(project: String, after: Int64, limit: Int = 100) throws -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        guard after >= 0, (1...200).contains(limit) else { throw VelaError("Invalid session completion cursor") }
        return try select("SELECT json_object('sequence',c.sequence,'sessionId',c.session_id,'activity',c.activity,'present',o.id IS NOT NULL,'project',COALESCE(o.project,''),'private',COALESCE(o.private,1),'scope',COALESCE(json_extract(o.json,'$.scope'),''),'internalRun',COALESCE(json_extract(o.json,'$.internalRun'),0),'sourcePath',COALESCE(json_extract(o.json,'$.sourcePath'),'')) FROM session_completions c LEFT JOIN objects o ON o.kind='session' AND o.id=c.session_id WHERE c.project=? AND c.sequence>? ORDER BY c.sequence LIMIT ?",[canonicalProject(project),after,limit])
    }
    func unresolvedScheduleEvent(workflowId: String, project: String) throws -> JSON? {
        lock.lock(); defer { lock.unlock() }
        return try select("SELECT json FROM objects WHERE kind='schedule_event' AND project=? AND json_extract(json,'$.workflowId')=? AND json_extract(json,'$.state') IN ('claimed','needs_review') ORDER BY updatedAt,id LIMIT 1",[canonicalProject(project),workflowId]).first
    }
    func activeWorkflowRun(workflowId: String, project: String, states: [String] = ["running","pending_approval","waiting_child","needs_review"]) throws -> JSON? {
        lock.lock(); defer { lock.unlock() }
        guard !states.isEmpty, states.allSatisfy({ ["running","pending_approval","waiting_child","needs_review"].contains($0) }) else { throw VelaError("Invalid active run states") }
        let placeholders = Array(repeating:"?",count:states.count).joined(separator:",")
        return try select("SELECT json FROM objects WHERE kind='run' AND project=? AND json_extract(json,'$.workflowId')=? AND json_extract(json,'$.state') IN (\(placeholders)) LIMIT 1",[canonicalProject(project),workflowId] + states).first
    }
    @discardableResult public func claimState(kind: String, id: String, expected: String, newState: String, fields: JSON = [:]) throws -> JSON? {
        lock.lock(); defer { lock.unlock() }
        guard ["approval","schedule","schedule_event","run"].contains(kind), !isBatching else { throw VelaError("State claims are limited to runtime objects outside a batch") }
        try validateIdentifier(id)
        guard fields["id"] == nil, fields["kind"] == nil, fields["project"] == nil, fields["createdAt"] == nil else { throw VelaError("State claim cannot replace object identity") }
        try execute("BEGIN IMMEDIATE")
        do {
            guard var object = try select("SELECT json FROM objects WHERE kind=? AND id=?",[kind,id]).first, string(object,"state") == expected else { try execute("COMMIT"); return nil }
            object.merge(fields) { _,new in new }; object["state"] = newState; object["updatedAt"] = isoNow()
            try execute("UPDATE objects SET updatedAt=?,json=? WHERE kind=? AND id=? AND json_extract(json,'$.state')=?",[string(object,"updatedAt"),try jsonString(object),kind,id,expected])
            let changed = sqlite3_changes(db) == 1
            try execute("COMMIT"); return changed ? object : nil
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func sessionSummaries(project: String? = nil, query: String = "", limit: Int = 500) throws -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        var sql = "SELECT json_remove(json,'$.messages','$.content','$.usageByMessage') FROM objects WHERE kind='session'"; var values: [Any] = []
        if let project { sql += " AND project=?"; values.append(canonicalProject(project)) }
        if !query.isEmpty {
            let term = "%" + query.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"%",with:"\\%").replacingOccurrences(of:"_",with:"\\_") + "%"
            sql += " AND (title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\')"; values += [term,term]
        }
        sql += " ORDER BY updatedAt DESC,id ASC LIMIT ?"; values.append(max(0,min(limit,10000)))
        return try select(sql,values)
    }
    public func get(_ kind: String, _ id: String) throws -> JSON? {
        lock.lock(); defer { lock.unlock() }
        guard let item = try select("SELECT json FROM objects WHERE kind=? AND id=?", [kind,id]).first else { return nil }
        return try readEditedAsset(item)
    }
    public func list(_ kind: String, project: String? = nil, limit: Int = 500) throws -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        var sql = "SELECT json FROM objects WHERE kind=?"; var values: [Any] = [kind]
        if let project { sql += " AND project=?"; values.append(canonicalProject(project)) }
        sql += " ORDER BY updatedAt DESC,id ASC LIMIT ?"; values.append(max(0,min(limit,10000)))
        return try select(sql,values).map { try readEditedAsset($0) }
    }
    // Workflow management enumerates identities without opening every asset.
    // One malformed Markdown file must not hide all other validation results.
    func workflowIdentities(project: String, after: String = "", limit: Int = 100) throws -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        return try select("SELECT json_object('id',id,'title',title,'project',project,'state',json_extract(json,'$.state'),'version',json_extract(json,'$.version'),'enabled',json_extract(json,'$.enabled')) FROM objects WHERE kind='workflow' AND project=? AND id>? ORDER BY id LIMIT ?",[canonicalProject(project),after,max(1,min(limit,1001))])
    }
    func loopConnectorActions(loopId: String, project: String) throws -> [JSON] {
        lock.lock(); defer { lock.unlock() }; try validateIdentifier(loopId)
        return try select("SELECT json FROM objects WHERE kind='connector_action' AND project=? AND json_extract(json,'$.request.origin.kind')='agent_loop' AND json_extract(json,'$.request.origin.id')=? ORDER BY json_extract(json,'$.request.origin.round'),id LIMIT 16",[canonicalProject(project),loopId])
    }
    func workflowRecord(_ id: String) throws -> JSON? {
        lock.lock(); defer { lock.unlock() }; try validateIdentifier(id)
        return try select("SELECT json FROM objects WHERE kind='workflow' AND id=?",[id]).first
    }
    // Internal, typed Memory-index access. No caller-supplied SQL or database handles.
    func semanticMemoryPage(project: String, after: String = "", limit: Int = 32) throws -> (items: [JSON], hasMore: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard (1...200).contains(limit) else { throw VelaError("Invalid semantic page size") }
        if !after.isEmpty { try validateIdentifier(after) }
        let pointer = try statement("SELECT json FROM objects WHERE kind='memory' AND (project=? OR project='') AND id>? ORDER BY id LIMIT ?",[project,after,limit+1])
        defer { sqlite3_finalize(pointer) }
        var items: [JSON] = []; var bytes = 0
        while true {
            let step = sqlite3_step(pointer)
            if step == SQLITE_DONE { return (items,false) }
            guard step == SQLITE_ROW, let raw = sqlite3_column_text(pointer,0) else { throw VelaError("Memory page is unavailable") }
            let count = Int(sqlite3_column_bytes(pointer,0))
            if items.count == limit || (!items.isEmpty && bytes + count > 2 * 1024 * 1024) { return (items,true) }
            guard count <= 2 * 1024 * 1024,
                  let item = try JSONSerialization.jsonObject(with:Data(bytes:raw,count:count)) as? JSON else { throw VelaError("Memory page contains an invalid record") }
            items.append(try readEditedAsset(item)); bytes += count
        }
    }
    func putSemanticVector(_ row: SemanticVectorRecord) throws {
        lock.lock(); defer { lock.unlock() }
        try validateIdentifier(row.memoryID)
        guard ["en","zh-Hans"].contains(row.language), row.model.count <= 256, row.revision > 0,
              row.dimension > 0, row.dimension <= 4096, row.vector.count == row.dimension,
              row.sourceHash.count == 64 else { throw VelaError("Invalid semantic vector identity") }
        _ = try SemanticVectorMath.normalized(row.vector)
        let bits = row.vector.map { $0.bitPattern.littleEndian }
        let blob = bits.withUnsafeBytes { Data($0) }
        guard !isBatching else { throw VelaError("Semantic indexing cannot run inside a store batch") }
        try execute("BEGIN IMMEDIATE")
        do {
            guard let source = try get("memory",row.memoryID), SemanticMemory.isIndexable(source,project:row.project),
                  string(source,"project") == row.project, try SemanticMemory.sourceHash(source) == row.sourceHash else { throw VelaError("Memory changed before indexing; index it again") }
            try execute("INSERT INTO memory_embeddings(memory_id,project,language,model,revision,dimension,source_hash,vector) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(memory_id,language) DO UPDATE SET project=excluded.project,model=excluded.model,revision=excluded.revision,dimension=excluded.dimension,source_hash=excluded.source_hash,vector=excluded.vector",[row.memoryID,row.project,row.language,row.model,row.revision,row.dimension,row.sourceHash,blob])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func semanticVectorMetadata(memoryID: String, language: String) throws -> JSON? {
        lock.lock(); defer { lock.unlock() }
        return try select("SELECT json_object('model',model,'revision',revision,'dimension',dimension,'sourceHash',source_hash,'bytes',length(vector)) FROM memory_embeddings WHERE memory_id=? AND language=?",[memoryID,language]).first
    }
    func removeSemanticVector(memoryID: String, language: String) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("DELETE FROM memory_embeddings WHERE memory_id=? AND language=?",[memoryID,language])
    }
    func forEachSemanticVector(project: String, language: String, _ visit: (SemanticVectorRecord) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let pointer = try statement("SELECT memory_id,project,language,model,revision,dimension,source_hash,vector FROM memory_embeddings WHERE (project=? OR project='') AND language=? ORDER BY memory_id",[project,language])
        defer { sqlite3_finalize(pointer) }
        func text(_ column: Int32) -> String { sqlite3_column_text(pointer,column).map { String(cString:$0) } ?? "" }
        while true {
            let step = sqlite3_step(pointer)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw VelaError("Semantic index is unavailable") }
            let dimension = Int(sqlite3_column_int(pointer,5)), bytes = Int(sqlite3_column_bytes(pointer,7))
            guard dimension > 0, dimension <= 4096, bytes == dimension * 4, let blob = sqlite3_column_blob(pointer,7) else { throw VelaError("Semantic index contains invalid vector bytes") }
            let data = Data(bytes:blob,count:bytes)
            let vector: [Float] = data.withUnsafeBytes { raw in (0..<dimension).map { Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:$0*4,as:UInt32.self))) } }
            try visit(SemanticVectorRecord(memoryID:text(0),project:text(1),language:text(2),model:text(3),revision:Int(sqlite3_column_int(pointer,4)),dimension:dimension,sourceHash:text(6),vector:vector))
        }
    }
    private func readEditedAsset(_ item: JSON) throws -> JSON {
        let kind = string(item,"kind")
        guard assetKinds.contains(kind), let storedPath = item["assetPath"] as? String else { return item }
        let expected = root.appendingPathComponent("assets/\(kind)/\(string(item,"id")).md")
        guard expected.path == storedPath, canonicalProject(expected.path) == expected.path, (try? expected.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else { throw VelaError("Asset path is unsafe") }
        guard let markdown = try FoundationFile.readUTF8(root:root,path:"assets/\(kind)/\(string(item,"id")).md"),
              let headerEnd = markdown.range(of:" -->\n\n# "), let titleEnd = markdown.range(of:"\n\n",range:headerEnd.upperBound..<markdown.endIndex) else { return item }
        let title = String(markdown[headerEnd.upperBound..<titleEnd.lowerBound])
        var content = String(markdown[titleEnd.upperBound...]); if content.hasSuffix("\n") { content.removeLast() }
        guard title != string(item,"title") || content != string(item,"content") else { return item }
        var edited = item; edited["title"] = title; edited["content"] = content; edited["tokens"] = tokenEstimate(content); edited["updatedAt"] = isoNow(); edited["humanEdited"] = true
        try execute("UPDATE objects SET title=?,content=?,updatedAt=?,json=? WHERE kind=? AND id=?",[title,content,string(edited,"updatedAt"),try jsonString(edited),kind,string(item,"id")])
        return edited
    }
    public func remove(_ kind: String, _ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try validateIdentifier(kind); try validateIdentifier(id)
        if assetKinds.contains(kind) {
            let asset = try assetURL(kind: kind, id: id)
            if FileManager.default.fileExists(atPath: asset.path) { try FileManager.default.removeItem(at: asset) }
        }
        try execute("DELETE FROM objects WHERE kind=? AND id=?", [kind,id])
    }
    public func search(_ query: String, project: String? = nil, includePrivate: Bool = false, limit: Int = 50) throws -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return [] }
        var sql = "SELECT json FROM objects WHERE kind IN ('session','memory','workflow','guideline','library','checkpoint','artifact') AND (title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\')"
        let term = "%" + query.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"%",with:"\\%").replacingOccurrences(of:"_",with:"\\_") + "%"
        var values: [Any] = [term,term]
        if let project { sql += " AND project=?"; values.append(canonicalProject(project)) }
        if !includePrivate { sql += " AND private=0" }
        sql += " ORDER BY updatedAt DESC,id ASC LIMIT ?"; values.append(max(0,min(limit,500)))
        return try select(sql,values).compactMap { item in
            guard string(item,"kind") == "library" else { return item }
            guard let current = try? LibrarySource.fresh(store:self,id:string(item,"id")),
                  string(current,"state","active") == "active",
                  includePrivate || LibraryIndex.isPublic(current,project:string(current,"project")),
                  string(current,"title").range(of:query,options:.caseInsensitive) != nil ||
                  string(current,"content").range(of:query,options:.caseInsensitive) != nil else { return nil }
            return current
        }
    }
}
