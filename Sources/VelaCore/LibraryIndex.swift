import Foundation
import CoreFoundation
import CSQLite

/// Rebuildable local index. The object and its current asset, never the index,
/// remain authoritative for source content, scope and privacy.
final class LibraryIndex {
    let store: VelaStore
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init(store: VelaStore) throws {
        self.store = store
        guard sqlite3_open_v2(store.root.appendingPathComponent("vela.sqlite3").path,&db,SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { throw VelaError("Library index database is unavailable") }
        sqlite3_busy_timeout(db,5000)
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS library_fts_v1 USING fts5(title_terms,body_terms,doc_id UNINDEXED,project UNINDEXED,source_hash UNINDEXED,citation_json UNINDEXED,tokenize='unicode61 remove_diacritics 2')")
        try execute("CREATE TABLE IF NOT EXISTS library_index_sources_v1(doc_id TEXT PRIMARY KEY,project TEXT NOT NULL,source_json TEXT NOT NULL,paragraphs INTEGER NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS library_index_project_v1 ON library_index_sources_v1(project)")
        for (suffix,event) in [("update","UPDATE OF json"),("delete","DELETE")] {
            try execute("CREATE TRIGGER IF NOT EXISTS library_index_" + suffix + "_v1 AFTER " + event + " ON objects WHEN OLD.kind='library' BEGIN DELETE FROM library_fts_v1 WHERE doc_id=OLD.id; DELETE FROM library_index_sources_v1 WHERE doc_id=OLD.id; END")
        }
    }
    deinit { sqlite3_close(db) }
    private func statement(_ sql: String, _ values: [Any] = []) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&pointer,nil) == SQLITE_OK, let pointer else { throw VelaError("Library index query could not be prepared") }
        for (index,value) in values.enumerated() {
            if let number = value as? Int { sqlite3_bind_int64(pointer,Int32(index + 1),Int64(number)) }
            else { sqlite3_bind_text(pointer,Int32(index + 1),String(describing:value),-1,transient) }
        }
        return pointer
    }
    private func execute(_ sql: String, _ values: [Any] = []) throws {
        let pointer = try statement(sql,values); defer { sqlite3_finalize(pointer) }
        guard sqlite3_step(pointer) == SQLITE_DONE else { throw VelaError("Library index write failed") }
    }
    private func text(_ pointer: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(pointer,column).map { String(cString:$0) } ?? ""
    }
    private func rows(_ sql: String, _ values: [Any] = []) throws -> [JSON] {
        let pointer = try statement(sql,values); defer { sqlite3_finalize(pointer) }
        var rows: [JSON] = []
        while true {
            let step = sqlite3_step(pointer)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW, let row = try JSONSerialization.jsonObject(with:Data(text(pointer,0).utf8)) as? JSON else { throw VelaError("Library index row is invalid") }
            rows.append(row)
        }
    }
    static func isPublic(_ item: JSON, project: String) -> Bool {
        let privacy: Bool
        if let value = item["private"] { privacy = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue } ?? false }
        else { privacy = false }
        let labeled: Bool
        if let value = item["sourceLabeledPrivate"] { labeled = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue } ?? false }
        else { labeled = true }
        return privacy && labeled && string(item,"project") == project && string(item,"kind","library") == "library" && string(item,"state","active") == "active" && string(item,"scope").lowercased() != "private" && !privateLibraryPath(string(item,"sourcePath"))
    }
    func handle(_ method: String, _ params: JSON) throws -> JSON {
        let project = try checkedProject(params,required:true)!
        switch method {
        case "library.index": return try index(params,project:project)
        case "library.index.status": return try status(project)
        case "library.search": return try search(params,project:project)
        default: throw VelaError("Unknown library index method")
        }
    }
    private func boundedInt(_ params: JSON, _ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = params[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue), range.contains(number.intValue) else { throw VelaError("Invalid library " + key) }
        return number.intValue
    }
    private func index(_ params: JSON, project: String) throws -> JSON {
        guard Set(params.keys).isSubset(of:["project","cursor","batchSize"]), params["cursor"] == nil || params["cursor"] is String, string(params,"cursor").utf8.count <= 150 else { throw VelaError("Invalid library index page") }
        let limit = try boundedInt(params,"batchSize",fallback:25,range:1...100)
        let ids = try rows("SELECT json_object('id',id) FROM objects WHERE kind='library' AND project=? AND id>? ORDER BY id LIMIT ?",[project,string(params,"cursor"),limit + 1])
        var indexed = 0, unchanged = 0, excluded = 0, failures: [JSON] = []
        for identity in ids.prefix(limit) {
            let id = string(identity,"id")
            do {
                let current = try LibrarySource.fresh(store:store,id:id)
                guard Self.isPublic(current,project:project) else { try purge(id); excluded += 1; continue }
                let source = try jsonString(current), sourceHash = stableHash(try jsonString(current))
                if try rows("SELECT json_object('id',doc_id) FROM library_index_sources_v1 WHERE doc_id=? AND source_json=?",[id,source]).first != nil { unchanged += 1; continue }
                guard string(current,"content").utf8.count <= 2_097_152 else { throw VelaError("Library content exceeds the indexing limit") }
                let chunks = Self.paragraphs(current)
                try execute("BEGIN IMMEDIATE")
                do {
                    guard try rows("SELECT json FROM objects WHERE kind='library' AND id=? AND project=? AND json=?",[id,project,source]).first != nil else { throw VelaError("Library source changed during indexing") }
                    try purge(id)
                    for citation in chunks {
                        try execute("INSERT INTO library_fts_v1(title_terms,body_terms,doc_id,project,source_hash,citation_json) VALUES(?,?,?,?,?,?)",[Self.tokens(string(current,"title")).joined(separator:" "),Self.tokens(string(citation,"content")).joined(separator:" "),id,project,sourceHash,try jsonString(citation)])
                    }
                    try execute("INSERT INTO library_index_sources_v1(doc_id,project,source_json,paragraphs) VALUES(?,?,?,?)",[id,project,source,chunks.count])
                    try execute("COMMIT"); indexed += 1
                } catch { try? execute("ROLLBACK"); throw error }
            } catch { try? purge(id); failures.append(["id":id,"message":error.localizedDescription]) }
        }
        return ["processed":min(limit,ids.count),"indexed":indexed,"unchanged":unchanged,"excluded":excluded,"failures":failures,"nextCursor":ids.count > limit ? string(ids[limit - 1],"id") as Any : NSNull(),"pageSucceeded":failures.isEmpty,"networkRequests":0,"indexVersion":1]
    }
    private func purge(_ id: String) throws {
        try execute("DELETE FROM library_fts_v1 WHERE doc_id=?",[id]); try execute("DELETE FROM library_index_sources_v1 WHERE doc_id=?",[id])
    }
    private func status(_ project: String) throws -> JSON {
        let pointer = try statement("SELECT json_object('id',o.id,'kind','library','project',o.project,'private',json_extract(o.json,'$.private'),'privateType',json_type(o.json,'$.private'),'labelType',json_type(o.json,'$.sourceLabeledPrivate'),'state',COALESCE(json_extract(o.json,'$.state'),'active'),'scope',COALESCE(json_extract(o.json,'$.scope'),''),'sourcePath',COALESCE(json_extract(o.json,'$.sourcePath'),''),'sourceLabeledPrivate',COALESCE(json_extract(o.json,'$.sourceLabeledPrivate'),json('false'))),m.source_json=o.json FROM objects o LEFT JOIN library_index_sources_v1 m ON m.doc_id=o.id WHERE o.kind='library' AND o.project=?",[project])
        defer { sqlite3_finalize(pointer) }
        var total = 0, eligible = 0, indexed = 0
        while true {
            let step = sqlite3_step(pointer); if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, var metadata = try JSONSerialization.jsonObject(with:Data(text(pointer,0).utf8)) as? JSON else { throw VelaError("Library index status is unavailable") }
            // SQL JSON extraction returns 0/1, restore only the privacy flags
            // from their database representation for this metadata-only count.
            if metadata["private"] is NSNull { metadata.removeValue(forKey:"private") }
            else if ["true","false"].contains(string(metadata,"privateType")) { metadata["private"] = string(metadata,"privateType") == "true" }
            if metadata["labelType"] is NSNull { metadata.removeValue(forKey:"sourceLabeledPrivate") }
            else if ["true","false"].contains(string(metadata,"labelType")) { metadata["sourceLabeledPrivate"] = string(metadata,"labelType") == "true" }
            total += 1
            if Self.isPublic(metadata,project:project) { eligible += 1; if sqlite3_column_int(pointer,1) == 1 { indexed += 1 } }
        }
        return ["totalDocuments":total,"eligiblePublicDocuments":eligible,"indexedPublicDocuments":indexed,"pendingDocuments":eligible - indexed,"databaseCoverageComplete":eligible == indexed,"assetEditsChecked":"on indexing and candidate retrieval","indexVersion":1,"backend":"SQLite FTS5 / BM25","networkRequests":0]
    }
    private func search(_ params: JSON, project: String) throws -> JSON {
        guard Set(params.keys).isSubset(of:["project","query","k","rerank","kind"]), params["rerank"] == nil || (params["rerank"] as? NSNumber).map({CFGetTypeID($0) == CFBooleanGetTypeID()}) == true else { throw VelaError("Invalid library search fields") }
        if let kind = params["kind"] { guard kind as? String == "library" else { throw VelaError("Library search kind must be library") } }
        let query = try requireString(params,"query"), k = try boundedInt(params,"k",fallback:10,range:1...50)
        guard query.utf8.count <= 1024 else { throw VelaError("Library query exceeds 1024 bytes") }
        let terms = Array(Set(Self.tokens(query))).sorted()
        guard terms.count <= 64 else { throw VelaError("Library query contains more than 64 terms") }
        var results: [JSON] = [], checked: [String:JSON] = [:], rejected: Set<String> = [], stale = 0, candidates = 0
        if !terms.isEmpty {
            // Only generated quoted terms reach MATCH; user boolean, column,
            // wildcard and NEAR syntax is always treated as literal text.
            let match = terms.map { "\"" + $0.replacingOccurrences(of:"\"",with:"\"\"") + "\"" }.joined(separator:" OR ")
            let pointer = try statement("SELECT f.citation_json,f.source_hash,bm25(library_fts_v1,4.0,1.0) FROM library_fts_v1 f JOIN library_index_sources_v1 m ON m.doc_id=f.doc_id JOIN objects o ON o.kind='library' AND o.id=f.doc_id AND o.json=m.source_json WHERE library_fts_v1 MATCH ? AND f.project=? AND o.private=0 ORDER BY bm25(library_fts_v1,4.0,1.0),f.doc_id LIMIT 200",[match,project])
            // Collect candidates before get() may synchronize an edited asset
            // and invalidate this index through another SQLite connection.
            var raw: [(JSON,String,Double)] = []
            do {
                defer { sqlite3_finalize(pointer) }
                while true {
                    let step = sqlite3_step(pointer); if step == SQLITE_DONE { break }
                    guard step == SQLITE_ROW, let citation = try JSONSerialization.jsonObject(with:Data(text(pointer,0).utf8)) as? JSON else { throw VelaError("Library search result is invalid") }
                    raw.append((citation,text(pointer,1),sqlite3_column_double(pointer,2)))
                }
            }
            candidates = raw.count
            for (var citation,snapshot,score) in raw {
                let id = string(citation,"id")
                if rejected.contains(id) { continue }
                if checked[id] == nil {
                    guard let current = try? LibrarySource.fresh(store:store,id:id), Self.isPublic(current,project:project), stableHash(try jsonString(current)) == snapshot else { rejected.insert(id); stale += 1; try? purge(id); continue }
                    checked[id] = current
                }
                let paragraph = string(citation,"content"), normalized = Self.tokens(paragraph), unique = Set(normalized)
                let coverage = Double(terms.filter { unique.contains($0) }.count) / Double(terms.count)
                let positions = terms.compactMap { normalized.firstIndex(of:$0) }
                let proximity = positions.count > 1 ? 1.0 / Double((positions.max()! - positions.min()!) + 1) : 0
                citation["bm25"] = score; citation["coverage"] = coverage; citation["proximity"] = proximity
                results.append(citation)
            }
            if params["rerank"] as? Bool != false {
                results.sort {
                    for key in ["coverage","proximity"] {
                        let a = ($0[key] as? Double) ?? 0, b = ($1[key] as? Double) ?? 0
                        if a != b { return a > b }
                    }
                    let a = ($0["bm25"] as? Double) ?? 0, b = ($1["bm25"] as? Double) ?? 0
                    return a == b ? string($0,"citationId") < string($1,"citationId") : a < b
                }
            }
        }
        return ["items":Array(results.prefix(k)),"query":query,"candidateCount":candidates,"candidateLimit":200,"candidateLimitReached":candidates == 200,"staleSourcesExcluded":stale,"reranked":params["rerank"] as? Bool != false,"index":try status(project),"queryMode":"literal terms; Unicode fold and CJK bigrams","networkRequests":0]
    }
    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options:[.diacriticInsensitive,.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))
        var result: [String] = [], word = "", cjk: [Unicode.Scalar] = []
        func flushWord() { if !word.isEmpty { result.append(word); word = "" } }
        func flushCJK() {
            result.append(contentsOf:cjk.map(String.init))
            if cjk.count > 1 { for index in 0..<(cjk.count - 1) { result.append(String(cjk[index]) + String(cjk[index + 1])) } }
            cjk.removeAll(keepingCapacity:true)
        }
        for scalar in folded.unicodeScalars {
            let value = scalar.value, ideographic = (0x3400...0x9fff).contains(value) || (0x20000...0x3134f).contains(value) || (0x3040...0x30ff).contains(value) || (0xac00...0xd7af).contains(value)
            if ideographic { flushWord(); cjk.append(scalar) }
            else if CharacterSet.alphanumerics.contains(scalar) { flushCJK(); word.unicodeScalars.append(scalar) }
            else { flushWord(); flushCJK() }
        }
        flushWord(); flushCJK(); return result
    }
    static func paragraphs(_ item: JSON) -> [JSON] {
        let content = string(item,"content"), ns = content as NSString
        let regex = try! NSRegularExpression(pattern:"(?s)\\S.*?(?=\\r?\\n[ \\t]*\\r?\\n|\\z)")
        let contentHash = stableHash(content), snapshotHash = stableHash((try? jsonString(item)) ?? "")
        var results: [JSON] = [], heading = ""
        for match in regex.matches(in:content,range:NSRange(location:0,length:ns.length)) {
            let block = ns.substring(with:match.range)
            if block.hasPrefix("#") { heading = String(block.split(separator:"\n",maxSplits:1)[0]).trimmingCharacters(in:CharacterSet(charactersIn:"# ")) }
            var offset = match.range.location
            while offset < NSMaxRange(match.range) {
                let proposedEnd = min(NSMaxRange(match.range),offset + 1800)
                let range = ns.rangeOfComposedCharacterSequences(for:NSRange(location:offset,length:proposedEnd - offset))
                let excerpt = ns.substring(with:range), anchor = "p-" + String(results.count + 1) + "-" + String(stableHash(excerpt).prefix(10))
                results.append(["id":string(item,"id"),"kind":"library","project":string(item,"project"),"title":string(item,"title"),"content":excerpt,"sourceHash":contentHash,"sourceSnapshotHash":snapshotHash,"excerptHash":stableHash(excerpt),"anchor":anchor,"citationId":string(item,"id") + "#" + anchor,"heading":heading,"rangeUTF16":["location":range.location,"length":range.length],"sourceURL":item["sourceURL"] ?? NSNull(),"sourcePath":item["sourcePath"] ?? NSNull()])
                offset = NSMaxRange(range)
            }
        }
        return results
    }
}
