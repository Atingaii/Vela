import Foundation
import CSQLite

/// History has its own narrow SQL projections. It never enlarges session JSON.
final class SessionHistoryStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(store: VelaStore) throws {
        guard sqlite3_open_v2(store.root.appendingPathComponent("vela.sqlite3").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw VelaError("Session history database is unavailable") }
        sqlite3_busy_timeout(db, 5000)
        try execute("CREATE TABLE IF NOT EXISTS history_objects_v1(kind TEXT NOT NULL,id TEXT NOT NULL,project TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(kind,id))")
        try execute("CREATE INDEX IF NOT EXISTS history_objects_project_v1 ON history_objects_v1(project,kind,id)")
        try execute("CREATE TABLE IF NOT EXISTS history_directories_v1(inventory TEXT NOT NULL,path TEXT NOT NULL,provider TEXT NOT NULL,root TEXT NOT NULL,after_name TEXT NOT NULL DEFAULT '',version TEXT NOT NULL DEFAULT '',done INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(inventory,path))")
        try execute("CREATE TABLE IF NOT EXISTS history_records_v1(epoch TEXT NOT NULL,ordinal INTEGER NOT NULL,project TEXT NOT NULL,provider_id TEXT NOT NULL DEFAULT '',parent_id TEXT,normalized INTEGER NOT NULL,json TEXT NOT NULL,PRIMARY KEY(epoch,ordinal))")
        try execute("CREATE INDEX IF NOT EXISTS history_records_provider_v1 ON history_records_v1(epoch,provider_id,ordinal)")
        try execute("CREATE TABLE IF NOT EXISTS history_chunks_v1(epoch TEXT NOT NULL,ordinal INTEGER NOT NULL,part INTEGER NOT NULL,data BLOB NOT NULL,PRIMARY KEY(epoch,ordinal,part))")
    }
    deinit { sqlite3_close(db) }
    func statement(_ sql: String, _ values: [Any] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw VelaError("Session history query is invalid") }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            if value is NSNull { sqlite3_bind_null(result, position) }
            else if let bytes = value as? Data { _ = bytes.withUnsafeBytes { sqlite3_bind_blob(result, position, $0.baseAddress, Int32(bytes.count), transient) } }
            else if let number = value as? Int { sqlite3_bind_int64(result, position, Int64(number)) }
            else { sqlite3_bind_text(result, position, String(describing: value), -1, transient) }
        }
        return result
    }
    func execute(_ sql: String, _ values: [Any] = []) throws {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw VelaError("Session history write failed") }
    }
    func rows(_ sql: String, _ values: [Any] = []) throws -> [JSON] {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        var items: [JSON] = []
        while true {
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { return items }
            guard step == SQLITE_ROW, let pointer = sqlite3_column_text(query, 0),
                  let value = try JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? JSON else { throw VelaError("Session history record is invalid") }
            items.append(value)
        }
    }
    func get(_ kind: String, _ id: String) throws -> JSON? {
        try rows("SELECT json FROM history_objects_v1 WHERE kind=? AND id=?", [kind, id]).first
    }
    func put(_ kind: String, _ object: JSON) throws {
        try execute("INSERT INTO history_objects_v1(kind,id,project,json) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET project=excluded.project,json=excluded.json", [kind, try requireString(object, "id"), string(object, "project"), try jsonString(object)])
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func blob(epoch: String, ordinal: Int, part: Int) throws -> Data? {
        let query = try statement("SELECT data FROM history_chunks_v1 WHERE epoch=? AND ordinal=? AND part=?", [epoch, ordinal, part]); defer { sqlite3_finalize(query) }
        let step = sqlite3_step(query)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw VelaError("Session history original chunk is unavailable") }
        let count = Int(sqlite3_column_bytes(query, 0))
        guard count <= SessionHistorySource.chunkBytes else { throw VelaError("Session history original chunk exceeds its storage contract") }
        if count == 0 { return Data() }
        guard let pointer = sqlite3_column_blob(query, 0) else { throw VelaError("Session history original chunk is invalid") }
        return Data(bytes: pointer, count: count)
    }
    func appendRaw(epoch: String, ordinal: Int, parts: Int, bytes: Data) throws -> Int {
        var count = parts, remaining = bytes
        if count > 0, var last = try blob(epoch: epoch, ordinal: ordinal, part: count - 1), last.count < SessionHistorySource.chunkBytes {
            let accepted = min(remaining.count, SessionHistorySource.chunkBytes - last.count)
            last.append(remaining.prefix(accepted)); remaining.removeFirst(accepted)
            try execute("UPDATE history_chunks_v1 SET data=? WHERE epoch=? AND ordinal=? AND part=?", [last, epoch, ordinal, count - 1])
        }
        if !remaining.isEmpty {
            guard remaining.count <= SessionHistorySource.chunkBytes else { throw VelaError("History raw append exceeds chunk budget") }
            try execute("INSERT INTO history_chunks_v1(epoch,ordinal,part,data) VALUES(?,?,?,?)", [epoch, ordinal, count, remaining]); count += 1
        }
        return count
    }
}
