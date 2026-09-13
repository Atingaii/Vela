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
    // Internal fixture hooks; neither is exposed through RPC, CLI, or renderer.
    var ingestionPolicyAfterRuleWriteForTesting: (() throws -> Void)?
    var ingestionPolicyBeforeCommitForTesting: (() throws -> Void)?
    // Configured by FoundationService. It maps an absolute provider log path
    // only when it is beneath an explicit provider ingestion root; it never
    // consults a derived Session projection.
    var ingestionSourceRelativePath: ((String,String) -> String?)?

    private static let currentSchemaVersion = 1

    /// Internal test-only fault points prove SQLite migration ordering and rollback.
    /// They expose neither caller-provided SQL nor an RPC/CLI entry point.
    init(root: URL, schemaMigrationFailureAfterStepForTesting: Int?, schemaMigrationBeforeWriteLockHookForTesting: (() -> Void)? = nil) throws {
        guard schemaMigrationFailureAfterStepForTesting == nil || schemaMigrationFailureAfterStepForTesting! > 0 else {
            throw VelaError("Invalid schema migration test fault point")
        }
        self.root = URL(fileURLWithPath:canonicalProject(root.path))
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = self.root.appendingPathComponent("vela.sqlite3")
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw VelaError("Cannot open Vela SQLite database") }
        sqlite3_busy_timeout(db, 5000)
        do {
            // Read the version before changing journal mode or issuing any schema/data
            // statement. A newer store must remain untouched by an older helper.
            let existingVersion = try pragmaUserVersion()
            try validateSupportedSchemaVersion(existingVersion)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            if existingVersion < Self.currentSchemaVersion {
                try applySchemaMigrations(failureAfterStepForTesting: schemaMigrationFailureAfterStepForTesting, beforeWriteLockHookForTesting: schemaMigrationBeforeWriteLockHookForTesting)
            } else {
                try validateCurrentSchema()
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            sqlite3_close(db); db = nil
            throw error
        }
    }

    public convenience init(root: URL) throws {
        try self.init(root: root, schemaMigrationFailureAfterStepForTesting: nil)
    }

    private func validateSupportedSchemaVersion(_ version: Int) throws {
        guard version >= 0 else { throw VelaError("Vela SQLite schema version is invalid") }
        guard version <= Self.currentSchemaVersion else {
            throw VelaError("Vela SQLite schema version \(version) is newer than this helper supports")
        }
    }

    private func pragmaUserVersion() throws -> Int {
        let pointer = try statement("PRAGMA user_version")
        defer { sqlite3_finalize(pointer) }
        guard sqlite3_step(pointer) == SQLITE_ROW else { throw VelaError("SQLite schema version is unavailable") }
        return Int(sqlite3_column_int64(pointer, 0))
    }

    private func applySchemaMigrations(failureAfterStepForTesting: Int?, beforeWriteLockHookForTesting: (() -> Void)?) throws {
        var completedSteps = 0
        beforeWriteLockHookForTesting?()
        try execute("BEGIN IMMEDIATE")
        do {
            // The first version read is only an early no-write guard. Another
            // helper can commit a migration while this connection waits for the
            // write lock, so advance from the value observed under that lock.
            var version = try pragmaUserVersion()
            try validateSupportedSchemaVersion(version)
            while version < Self.currentSchemaVersion {
                switch version {
                case 0:
                    try migrateSchema0To1 { sql in
                        try self.execute(sql)
                        completedSteps += 1
                        if completedSteps == failureAfterStepForTesting {
                            throw VelaError("Injected schema migration failure")
                        }
                    }
                    version = 1
                default:
                    throw VelaError("No Vela SQLite migration exists from version \(version)")
                }
            }
            try validateCurrentSchema()
            if try pragmaUserVersion() != Self.currentSchemaVersion {
                try execute("PRAGMA user_version=\(Self.currentSchemaVersion)")
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func schemaObjectExists(type: String, name: String) throws -> Bool {
        let pointer = try statement("SELECT 1 FROM sqlite_master WHERE type=? AND name=? LIMIT 1", [type, name])
        defer { sqlite3_finalize(pointer) }
        let result = sqlite3_step(pointer)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw VelaError("SQLite schema validation failed") }
        return result == SQLITE_ROW
    }

    private func tableContainsColumns(_ table: String, _ expected: Set<String>) throws -> Bool {
        let pointer = try statement("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(pointer) }
        var names: Set<String> = []
        while true {
            let result = sqlite3_step(pointer)
            if result == SQLITE_DONE { return expected.isSubset(of: names) }
            guard result == SQLITE_ROW, let raw = sqlite3_column_text(pointer, 1) else { throw VelaError("SQLite schema validation failed") }
            names.insert(String(cString: raw))
        }
    }

    private func validateCurrentSchema() throws {
        let tables = ["objects", "memory_embeddings", "session_change_counter", "session_completions"]
        let indexes = ["objects_project", "objects_runtime_workflow", "objects_search_project", "memory_embeddings_scope", "session_completions_project"]
        let triggers = ["vela_memory_vector_delete", "vela_memory_vector_private", "vela_session_insert", "vela_session_update", "vela_session_delete", "vela_completion_insert_v2", "vela_completion_update_v2"]
        guard try tables.allSatisfy({ try schemaObjectExists(type: "table", name: $0) }),
              try indexes.allSatisfy({ try schemaObjectExists(type: "index", name: $0) }),
              try triggers.allSatisfy({ try schemaObjectExists(type: "trigger", name: $0) }),
              try tableContainsColumns("objects", ["kind", "id", "project", "title", "content", "private", "updatedAt", "json"]) else {
            throw VelaError("Vela SQLite schema version \(Self.currentSchemaVersion) is incomplete or corrupt")
        }
    }

    private func migrateSchema0To1(_ apply: (String) throws -> Void) throws {
        try apply("CREATE TABLE IF NOT EXISTS objects(kind TEXT NOT NULL,id TEXT NOT NULL,project TEXT NOT NULL DEFAULT '',title TEXT NOT NULL DEFAULT '',content TEXT NOT NULL DEFAULT '',private INTEGER NOT NULL DEFAULT 0,updatedAt TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(kind,id))")
        try apply("CREATE INDEX IF NOT EXISTS objects_project ON objects(project,kind,updatedAt)")
        try apply("CREATE INDEX IF NOT EXISTS objects_runtime_workflow ON objects(kind,project,json_extract(json,'$.workflowId'),json_extract(json,'$.state')) WHERE kind IN ('schedule_event','run')")
        // Read substring candidates in row order instead of following the
        // time-ordered listing index through every matching project's content.
        try apply("CREATE INDEX IF NOT EXISTS objects_search_project ON objects(project,private,kind)")
        try apply("CREATE TABLE IF NOT EXISTS memory_embeddings(memory_id TEXT NOT NULL,project TEXT NOT NULL,language TEXT NOT NULL,model TEXT NOT NULL,revision INTEGER NOT NULL,dimension INTEGER NOT NULL,source_hash TEXT NOT NULL,vector BLOB NOT NULL,PRIMARY KEY(memory_id,language))")
        try apply("CREATE INDEX IF NOT EXISTS memory_embeddings_scope ON memory_embeddings(project,language)")
        try apply("CREATE TRIGGER IF NOT EXISTS vela_memory_vector_delete AFTER DELETE ON objects WHEN OLD.kind='memory' BEGIN DELETE FROM memory_embeddings WHERE memory_id=OLD.id; END")
        try apply("CREATE TRIGGER IF NOT EXISTS vela_memory_vector_private AFTER UPDATE ON objects WHEN NEW.kind='memory' AND NEW.private<>0 BEGIN DELETE FROM memory_embeddings WHERE memory_id=NEW.id; END")
        // A one-row change counter keeps background analysis from rescanning session history
        // every timer tick. Triggers also observe writes made by another helper connection.
        try apply("CREATE TABLE IF NOT EXISTS session_change_counter(singleton INTEGER PRIMARY KEY CHECK(singleton=1),revision INTEGER NOT NULL)")
        try apply("INSERT OR IGNORE INTO session_change_counter(singleton,revision) VALUES(1,0)")
        try apply("CREATE TRIGGER IF NOT EXISTS vela_session_insert AFTER INSERT ON objects WHEN NEW.kind='session' BEGIN UPDATE session_change_counter SET revision=revision+1 WHERE singleton=1; END")
        try apply("CREATE TRIGGER IF NOT EXISTS vela_session_update AFTER UPDATE OF json ON objects WHEN NEW.kind='session' AND OLD.json<>NEW.json BEGIN UPDATE session_change_counter SET revision=revision+1 WHERE singleton=1; END")
        try apply("CREATE TRIGGER IF NOT EXISTS vela_session_delete AFTER DELETE ON objects WHEN OLD.kind='session' BEGIN UPDATE session_change_counter SET revision=revision+1 WHERE singleton=1; END")
        // Compact completion identities provide an unbounded durable cursor;
        // scheduling never rescans or loads entire session transcripts.
        try apply("CREATE TABLE IF NOT EXISTS session_completions(sequence INTEGER PRIMARY KEY AUTOINCREMENT,project TEXT NOT NULL,session_id TEXT NOT NULL,activity TEXT NOT NULL,UNIQUE(project,session_id,activity))")
        try apply("CREATE INDEX IF NOT EXISTS session_completions_project ON session_completions(project,sequence)")
        // An outer UPSERT can override INSERT OR IGNORE inside a trigger;
        // explicit UPSERT DO NOTHING preserves completion deduplication.
        let completionInsert = "INSERT INTO session_completions(project,session_id,activity) VALUES(NEW.project,NEW.id,COALESCE(json_extract(NEW.json,'$.lastActivity'),NEW.updatedAt)) ON CONFLICT(project,session_id,activity) DO NOTHING;"
        // These names existed in an unversioned pre-v1 store. Dropping them
        // inside this transaction makes the corrected trigger definitions atomic.
        try apply("DROP TRIGGER IF EXISTS vela_completion_insert")
        try apply("DROP TRIGGER IF EXISTS vela_completion_update")
        try apply("CREATE TRIGGER IF NOT EXISTS vela_completion_insert_v2 AFTER INSERT ON objects WHEN NEW.kind='session' AND lower(json_extract(NEW.json,'$.state'))='completed' BEGIN " + completionInsert + " END")
        try apply("CREATE TRIGGER IF NOT EXISTS vela_completion_update_v2 AFTER UPDATE ON objects WHEN NEW.kind='session' AND lower(json_extract(NEW.json,'$.state'))='completed' AND (COALESCE(lower(json_extract(OLD.json,'$.state')),'')<>'completed' OR COALESCE(json_extract(OLD.json,'$.lastActivity'),OLD.updatedAt)<>COALESCE(json_extract(NEW.json,'$.lastActivity'),NEW.updatedAt)) BEGIN " + completionInsert + " END")
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
    // Session relations use current, narrow summaries, never conversation bodies.
    // Keep identities unfiltered until the service checks strict Boolean privacy
    // and source scope; child paging advances over withheld identities as well.
    private var relationSelect: String {
        "SELECT json_object('session',json(json_remove(s.json,'$.messages','$.content','$.usageByMessage')),'relation',json(r.json)) FROM objects s LEFT JOIN objects r ON r.kind='session_relation' AND r.id=s.id AND r.project=s.project WHERE s.kind='session' AND s.project=?"
    }
    func relationSource(project: String, id: String) throws -> JSON? {
        lock.lock(); defer { lock.unlock() }; try validateIdentifier(id)
        return try select(relationSelect + " AND s.id=?",[canonicalProject(project),id]).first
    }
    func relationThreadSources(project: String, threadID: String) throws -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        guard SessionRelationProjection.threadID(threadID) == threadID else { throw VelaError("Invalid provider thread identity") }
        return try select(relationSelect + " AND json_extract(s.json,'$.provider')='codex' AND lower(json_extract(s.json,'$.sourceSessionId'))=? ORDER BY s.id LIMIT 65",[canonicalProject(project),threadID])
    }
    func relationChildren(project: String, threadID: String, after: String, limit: Int) throws -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        guard SessionRelationProjection.threadID(threadID) == threadID, (1...101).contains(limit) else { throw VelaError("Invalid relation scan arguments") }
        if !after.isEmpty { try validateIdentifier(after) }
        return try select(relationSelect + " AND json_extract(s.json,'$.provider')='codex' AND s.id>? AND EXISTS(SELECT 1 FROM json_each(r.json,'$.parentCandidates') p WHERE p.value=?) ORDER BY s.id LIMIT ?",[canonicalProject(project),after,threadID,limit])
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
    // Replay cleanup reads identities only, after filtering the exact retained
    // fixture. Unrelated newer rows cannot hide a payload from deletion.
    func replayPayloadIDs(fixtureId: String, project: String, limit: Int = 129) throws -> [String] {
        lock.lock(); defer { lock.unlock() }; try validateIdentifier(fixtureId)
        return try select("SELECT json_object('id',p.id) FROM objects m JOIN objects p ON p.kind='replay_payload' AND p.id=m.id AND p.project=m.project WHERE m.kind='replay' AND m.project=? AND json_extract(m.json,'$.fixtureId')=? ORDER BY p.id LIMIT ?",[canonicalProject(project),fixtureId,max(1,min(limit,129))]).map { string($0,"id") }
    }
    func replayFixturePage(project: String, after: String = "", limit: Int = 33) throws -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        if !after.isEmpty { try validateIdentifier(after) }
        return try select("SELECT json_object('id',id,'project',project,'state',json_extract(json,'$.state'),'expiresAt',json_extract(json,'$.expiresAt')) FROM objects WHERE kind='replay_fixture' AND project=? AND id>? ORDER BY id LIMIT ?",[canonicalProject(project),after,max(1,min(limit,33))])
    }
    // MCP pages carry identities only. Every asset is refreshed and checked by
    // the MCP gate before it contributes text to a model-facing result.
    func mcpSourceIDs(kind: String, project: String, after: String = "", limit: Int = 21) throws -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        let kinds = ["memory","library","guideline","workflow","checkpoint","artifact","eval","session"]
        guard kinds.contains(kind) || kind == "search", after.utf8.count <= 640 else { throw VelaError("Unsupported MCP source page") }
        if kind == "search" {
            let split = after.split(separator:":",maxSplits:1,omittingEmptySubsequences:false)
            let priorKind = after.isEmpty ? "" : String(split[0]), priorID = split.count == 2 ? String(split[1]) : ""
            guard after.isEmpty || (split.count == 2 && kinds.contains(priorKind)) else { throw VelaError("Invalid MCP search cursor") }
            if !priorID.isEmpty { try validateIdentifier(priorID) }
            return try select("SELECT json_object('id',id,'kind',kind) FROM objects WHERE project=? AND kind IN ('memory','library','guideline','workflow','checkpoint','artifact','session') AND (kind>? OR (kind=? AND id>?)) ORDER BY kind,id LIMIT ?",[canonicalProject(project),priorKind,priorKind,priorID,max(1,min(limit,101))])
        }
        if !after.isEmpty { try validateIdentifier(after) }
        return try select("SELECT json_object('id',id,'kind',kind) FROM objects WHERE kind=? AND project=? AND id>? ORDER BY id LIMIT ?",[kind,canonicalProject(project),after,max(1,min(limit,101))])
    }
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
            guard let source = try get("memory",row.memoryID) else { throw VelaError("Memory changed before indexing; index it again") }
            let policyAllowsRecall: Bool
            if row.project.isEmpty { policyAllowsRecall = true }
            else { policyAllowsRecall = try IngestionExclusionService(store:self).allowsMemoryRecall(source,project:row.project) }
            guard SemanticMemory.isIndexable(source,project:row.project), policyAllowsRecall,
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
    /// A narrow internal transaction for policy changes and derived session withdrawal.
    /// No asset files participate; provider logs and canonical memories stay untouched.
    func withIngestionPolicyTransaction(_ body: () throws -> JSON) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        guard !isBatching else { throw VelaError("Nested ingestion policy transaction is not supported") }
        try execute("BEGIN IMMEDIATE"); isBatching = true
        do {
            let result = try body()
            try ingestionPolicyBeforeCommitForTesting?()
            try execute("COMMIT"); isBatching = false; return result
        } catch {
            try? execute("ROLLBACK"); isBatching = false; throw error
        }
    }
    /// Keyset pagination never truncates policy enforcement at the dashboard limit.
    func ingestionSourcePage(project: String, afterID: String = "") throws -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        return try select("SELECT json_object('id',id,'project',project,'provider',json_extract(json,'$.provider'),'sourcePath',json_extract(json,'$.sourcePath')) FROM objects WHERE kind='session' AND project=? AND id>? ORDER BY id LIMIT 256", [canonicalProject(project),afterID])
    }
    /// Creates a complete SQLite-and-canonical-asset snapshot while blocking Vela writers.
    /// The backup source must be a separate read-only connection: SQLite rejects a backup
    /// sourced from this connection while it owns BEGIN IMMEDIATE (covered by ADR 0044 probe).
    func writeCompleteBackupSnapshot(to bundle: URL) throws -> (databaseSHA256: String, assets: [JSON], outputs: [JSON]) {
        lock.lock(); defer { lock.unlock() }
        guard !isBatching else { throw VelaError("Store is busy; complete backup cannot nest a write transaction") }
        // SafeApply takes this flock before it writes its audit object or touches
        // store/output. Take it before BEGIN IMMEDIATE too, so backup and apply
        // share one order rather than deadlocking DB -> flock versus flock -> DB.
        let applyLockPath = root.appendingPathComponent("apply.lock").path
        let applyFD = Darwin.open(applyLockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard applyFD >= 0 else { throw VelaError("Cannot acquire SafeApply lock for complete backup") }
        var applyInfo = stat()
        guard fstat(applyFD, &applyInfo) == 0, (applyInfo.st_mode & S_IFMT) == S_IFREG, applyInfo.st_nlink == 1, flock(applyFD, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(applyFD); throw VelaError("Complete backup is unavailable while SafeApply owns its transaction lock") }
        defer { _ = flock(applyFD, LOCK_UN); Darwin.close(applyFD) }
        let snapshotDeadline = Date().addingTimeInterval(60)
        let maximumFileBytes = StoreBackupFiles.maximumFileBytes
        let maximumTotalBytes = StoreBackupFiles.maximumTotalBytes
        var copiedBytes = 0
        var runtimeLeases: [VelaRuntimeLease] = []
        for name in ["scheduler", "daemon", "composition"] {
            guard let lease = try VelaRuntimeLease.acquire(root:root,name:name) else { throw VelaError("Complete backup is unavailable while the \(name) runtime lease is held") }
            runtimeLeases.append(lease)
        }
        defer { runtimeLeases.forEach { $0.release() } }
        let manager = FileManager.default
        let database = bundle.appendingPathComponent("vela.sqlite3")
        guard !manager.fileExists(atPath: database.path) else { throw VelaError("Backup database destination already exists") }
        try execute("BEGIN IMMEDIATE"); isBatching = true
        do {
            // This check deliberately occurs after the barrier. A competing claim cannot
            // pass a preflight then start an external process before the snapshot begins.
            let unsafe = try select("SELECT json_object('count',COUNT(*)) FROM objects WHERE kind IN ('approval','connector_action','run','eval','agent_loop','replay','workflow_plan','ask_route_proposal','knowledge_query','model_improvement') AND json_extract(json,'$.state') IN ('executing','needs_review','running','running_or_uncertain','executing_or_uncertain','accepting','claimed') AND NOT (json_extract(json,'$.state')='needs_review' AND COALESCE(json_extract(json,'$.restoreRevoked'),0)=1)").first ?? [:]
            guard intValue(unsafe,"count") == 0 else { throw VelaError("Complete backup requires review of active or uncertain execution records") }
            var source: OpaquePointer?, destination: OpaquePointer?
            let sourcePath = root.appendingPathComponent("vela.sqlite3").path
            guard sqlite3_open_v2(sourcePath, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let source else { throw VelaError("Cannot open a read-only SQLite backup source") }
            defer { sqlite3_close(source) }
            guard sqlite3_open_v2(database.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let destination else { throw VelaError("Cannot create SQLite backup destination") }
            defer { sqlite3_close(destination) }
            sqlite3_busy_timeout(source, 5000); sqlite3_busy_timeout(destination, 5000)
            guard let backup = sqlite3_backup_init(destination, "main", source, "main") else { throw VelaError("SQLite backup initialization failed: \(String(cString: sqlite3_errmsg(destination)))") }
            // Do not use a single unbounded backup_step(-1) while holding the writer
            // barrier. Each bounded page batch gets a deadline check; BUSY/LOCKED is
            // a failed snapshot, never a partial bundle.
            let deadline = Date().addingTimeInterval(30)
            var stepped = SQLITE_OK
            repeat {
                guard Date() <= deadline else { _ = sqlite3_backup_finish(backup); throw VelaError("SQLite backup exceeded the 30 second snapshot deadline") }
                stepped = sqlite3_backup_step(backup, 256)
            } while stepped == SQLITE_OK
            let finished = sqlite3_backup_finish(backup)
            guard stepped == SQLITE_DONE, finished == SQLITE_OK else { throw VelaError("SQLite backup did not complete (step \(stepped), finish \(finished))") }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
            let rows = try select("SELECT json FROM objects WHERE kind IN ('memory','workflow','guideline','library','checkpoint') ORDER BY kind,id LIMIT 50001")
            guard rows.count <= StoreBackupFiles.maximumFiles else { throw VelaError("Complete backup exceeds the file count bound") }
            var manifestAssets: [JSON] = []; var sourceChecks: [(String,String)] = []
            for item in rows {
                guard Date() <= snapshotDeadline else { throw VelaError("Complete backup exceeded the 60 second deadline") }
                let kind = string(item,"kind"), id = string(item,"id")
                guard assetKinds.contains(kind), !id.isEmpty,
                      string(item,"assetPath") == root.appendingPathComponent("assets/\(kind)/\(id).md").path else { throw VelaError("Canonical asset metadata is invalid") }
                let relative = "assets/\(kind)/\(id).md"
                let copied = try StoreBackupFiles.copy(root:root,path:relative,destination:bundle,limit:min(maximumFileBytes,maximumTotalBytes-copiedBytes),deadline:snapshotDeadline)
                copiedBytes += copied.bytes
                manifestAssets.append(["path":relative,"sha256":copied.sha256,"bytes":copied.bytes,"kind":kind,"id":id])
                sourceChecks.append((relative,copied.sha256))
            }
            // Managed delivery output is canonical user result data, separate from
            // Markdown assets and protected by the SafeApply flock above. Preserve
            // only regular files below the fixed store/output root.
            var outputs: [JSON] = []
            let outputRoot = root.appendingPathComponent("output")
            if manager.fileExists(atPath: outputRoot.path) {
                guard (try? outputRoot.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]).isDirectory) == true,
                      (try? outputRoot.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else { throw VelaError("Managed output directory is unsafe") }
                let keys: Set<URLResourceKey> = [.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey]
                guard let files = manager.enumerator(at:outputRoot,includingPropertiesForKeys:Array(keys),options:[]) else { throw VelaError("Cannot enumerate managed output") }
                for case let file as URL in files {
                    guard Date() <= snapshotDeadline else { throw VelaError("Complete backup exceeded the 60 second deadline") }
                    let values=try file.resourceValues(forKeys:keys)
                    guard values.isSymbolicLink != true else { throw VelaError("Managed output contains a symbolic link") }
                    if values.isDirectory == true { continue }
                    guard values.isRegularFile == true else { throw VelaError("Managed output contains a non-regular file") }
                    let relative = "output/" + file.path.dropFirst(outputRoot.path.count + 1)
                    let components = relative.split(separator:"/",omittingEmptySubsequences:false)
                    guard components.count >= 2, !components.contains("."), !components.contains(".."), !components.contains(where: { $0.isEmpty }), manifestAssets.count + outputs.count < StoreBackupFiles.maximumFiles else { throw VelaError("Managed output path or file count exceeds the complete-backup bound") }
                    let copied = try StoreBackupFiles.copy(root:root,path:relative,destination:bundle,limit:min(maximumFileBytes,maximumTotalBytes-copiedBytes),deadline:snapshotDeadline)
                    copiedBytes += copied.bytes
                    outputs.append(["path":relative,"sha256":copied.sha256,"bytes":copied.bytes])
                    sourceChecks.append((relative,copied.sha256))
                }
            }
            // Vela writers are blocked by the barrier; this final pass catches a human
            // editor changing any earlier Markdown or managed-output file while later
            // files were copied.
            for (original, expected) in sourceChecks {
                let current = try StoreBackupFiles.digest(root:root,path:original,limit:maximumFileBytes,deadline:snapshotDeadline).sha256
                guard current == expected else { throw VelaError("Canonical data changed during complete backup") }
            }
            try execute("COMMIT"); isBatching = false
            let databaseHash = try StoreBackupFiles.digest(root:bundle,path:"vela.sqlite3",limit:StoreBackupFiles.maximumDatabaseBytes,deadline:snapshotDeadline).sha256
            return (databaseHash, manifestAssets, outputs)
        } catch { try? execute("ROLLBACK"); isBatching = false; throw error }
    }

    func rebindRestoredBackupAssets(_ entries: [JSON], assetRoot: URL? = nil) throws {
        let reboundRoot = assetRoot ?? root
        lock.lock(); defer { lock.unlock() }
        let expected = try Set(entries.map { entry -> String in
            let kind=string(entry,"kind"), id=string(entry,"id"), path=string(entry,"path")
            try validateIdentifier(kind); try validateIdentifier(id)
            guard assetKinds.contains(kind), path == "assets/\(kind)/\(id).md" else { throw VelaError("Backup asset manifest identity is invalid") }
            return kind + ":" + id
        })
        guard expected.count == entries.count else { throw VelaError("Backup asset manifest repeats an identity") }
        let rows = try select("SELECT json FROM objects WHERE kind IN ('memory','workflow','guideline','library','checkpoint')")
        guard Set(rows.map { string($0,"kind") + ":" + string($0,"id") }) == expected else { throw VelaError("Backup asset manifest does not exactly match restored canonical objects") }
        try execute("BEGIN IMMEDIATE")
        do { for item in rows { let kind=string(item,"kind"), id=string(item,"id"); var rebound=item; rebound["assetPath"]=reboundRoot.appendingPathComponent("assets/\(kind)/\(id).md").path; try execute("UPDATE objects SET json=? WHERE kind=? AND id=?",[try jsonString(rebound),kind,id]) }; try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    /// A restored store retains audit evidence but cannot resume an in-flight action.
    func revokeRestoredRuntimeEligibility() throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let at = isoNow()
            let reviewKinds = ["run","approval","agent_loop","replay","workflow_plan","ask_route_proposal","connector_action","schedule","schedule_event","knowledge_query","watch_state","apply_journal","model_improvement"]
            let revocable = Set(["pending","pending_approval","executing","running","running_or_uncertain","executing_or_uncertain","waiting_child","claimed","accepting","ready","queued","watching","accumulating","deferred","committing","prepared"])
            for kind in reviewKinds {
                for var record in try select("SELECT json FROM objects WHERE kind=?",[kind]) where revocable.contains(string(record,"state")) {
                    record["state"]="needs_review"; record["restoreRevoked"]=true; record["restoredAt"]=at; record["restoreReason"]="Restored local backup; automatic execution was revoked"
                    // A run cannot later resume a nested pending step merely because an
                    // old approval ID survived in its frozen steps array.
                    if kind == "run", var steps=record["steps"] as? [JSON] {
                        for index in steps.indices where revocable.contains(string(steps[index],"state")) { steps[index]["state"]="needs_review"; steps[index]["restoreReason"]="Restored local backup" }
                        record["steps"]=steps
                    }
                    try execute("UPDATE objects SET json=? WHERE kind=? AND id=?",[try jsonString(record),kind,string(record,"id")])
                }
            }
            // Lab and health proposal state names have different terminal semantics;
            // preserve their evidence but never retain an executable claim.
            for var record in try select("SELECT json FROM objects WHERE kind IN ('eval','workflow_health_proposal')") {
                let state=string(record,"state")
                guard ["pending","pending_approval","running","accepting"].contains(state) else { continue }
                record["state"] = string(record,"kind") == "workflow_health_proposal" ? "invalidated" : "needs_review"
                record["restoreRevoked"]=true; record["restoredAt"]=at; record["restoreReason"]="Restored local backup; execution eligibility was revoked"
                try execute("UPDATE objects SET json=? WHERE kind=? AND id=?",[try jsonString(record),string(record,"kind"),string(record,"id")])
            }
            try execute("UPDATE objects SET json=json_set(json,'$.enabled',0,'$.restoredAt',?,'$.restoreReason','Restored local backup; automatic trigger disabled') WHERE kind='workflow' AND json_extract(json,'$.trigger') <> 'manual'",[at])
            try execute("DELETE FROM objects WHERE kind='runtime'")
            try execute("DELETE FROM memory_embeddings")
            try execute("UPDATE session_change_counter SET revision=0 WHERE singleton=1")
            try execute("DELETE FROM session_completions")
            try execute("COMMIT")
            return ["runtimeRecordsRevoked":true,"semanticVectorsRetained":false,"sessionCompletionStateRetained":false,"restoredAt":at]
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func remove(_ kind: String, _ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try validateIdentifier(kind); try validateIdentifier(id)
        // Derived-session withdrawal already owns a policy transaction. Its records
        // have no filesystem asset, so preserve that atomic caller contract.
        if isBatching {
            guard !assetKinds.contains(kind) else { throw VelaError("Canonical asset removal cannot nest a store transaction") }
            try execute("DELETE FROM objects WHERE kind=? AND id=?", [kind,id]); return
        }
        let asset = assetKinds.contains(kind) ? try assetURL(kind:kind,id:id) : nil
        try execute("BEGIN IMMEDIATE"); isBatching=true
        var original: Data?
        do {
            // Read after the writer barrier. If the SQL delete fails, rollback
            // restores exactly the bytes this transaction removed.
            if let asset, FileManager.default.fileExists(atPath:asset.path) {
                original = try Data(contentsOf:asset)
                try FileManager.default.removeItem(at:asset)
            }
            try execute("DELETE FROM objects WHERE kind=? AND id=?", [kind,id])
            try execute("COMMIT"); isBatching=false
        } catch {
            try? execute("ROLLBACK"); isBatching=false
            if let asset, let original, !FileManager.default.fileExists(atPath:asset.path) {
                do { try original.write(to:asset,options:.atomic) }
                catch let recovery { throw VelaError("Asset removal failed (\(error.localizedDescription)); restoring its bytes also failed (\(recovery.localizedDescription))") }
            }
            throw error
        }
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
