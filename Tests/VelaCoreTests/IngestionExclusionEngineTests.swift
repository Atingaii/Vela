import XCTest
import Foundation
import CSQLite
@testable import VelaCore

final class IngestionExclusionEngineTests: XCTestCase {
    var root: URL!, project: URL!, logs: URL!, store: VelaStore!, service: FoundationService!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath:canonicalProject(FileManager.default.temporaryDirectory.path)).appendingPathComponent("vela-exclusion-engine-" + UUID().uuidString)
        project = root.appendingPathComponent("project"); logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let roots = Dictionary(uniqueKeysWithValues:["claude","codex","cursor","pi","omp"].map { ($0,[logs.appendingPathComponent($0)]) })
        for url in roots.values.flatMap({$0}) { try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true) }
        store = try VelaStore(root:root.appendingPathComponent("store"))
        service = FoundationService(store:store,sourceRoots:roots,globalHome:root.appendingPathComponent("home"))
        _ = try service.handle("projects.add",["path":project.path])
    }
    override func tearDownWithError() throws {
        service?.stopWatching(); service = nil; store = nil
        if let root { try FileManager.default.removeItem(at:root) }
    }
    func object(_ method: String, _ params: JSON = [:]) throws -> JSON {
        var params = params; params["project"] = params["project"] ?? project.path
        let result = try service.handle(method,params)
        return try XCTUnwrap(result as? JSON)
    }
    func sessions() throws -> [JSON] { try XCTUnwrap(service.handle("sessions.list",["project":project.path]) as? [JSON]) }
    func makeSources() throws -> [URL:Data] {
        let stamp = "2026-09-14T00:00:00Z"
        var files: [URL] = []
        let rows: [String:[JSON]] = [
            "claude":[["type":"user","uuid":"claude-message","cwd":project.path,"message":["role":"user","content":"exclusion-fixture-marker"]]],
            "codex":[["type":"session_meta","payload":["id":"codex-source","cwd":project.path]], ["type":"response_item","payload":["id":"codex-message","type":"message","role":"user","content":[["type":"input_text","text":"exclusion-fixture-marker"]]]]],
            "pi":[["type":"session","version":3,"id":"pi-source","cwd":project.path,"timestamp":stamp], ["type":"message","id":"pi-message","parentId":NSNull(),"timestamp":stamp,"message":["role":"user","content":"exclusion-fixture-marker"]]],
            "omp":[["type":"session","version":3,"id":"omp-source","cwd":project.path,"timestamp":stamp], ["type":"message","id":"omp-message","parentId":NSNull(),"timestamp":stamp,"message":["role":"user","content":"exclusion-fixture-marker"]]]
        ]
        for (provider,lines) in rows {
            let file = logs.appendingPathComponent(provider).appendingPathComponent("fixture.jsonl")
            try Data((try lines.map { try jsonString($0) }.joined(separator:"\n") + "\n").utf8).write(to:file); files.append(file)
        }
        let cursor: JSON = ["name":"Cursor fixture","cwd":project.path,"conversation":[["type":1,"text":"exclusion-fixture-marker"]]]
        let export = logs.appendingPathComponent("cursor/fixture.json")
        try Data(try jsonString(cursor).utf8).write(to:export); files.append(export)
        let database = logs.appendingPathComponent("cursor/state.vscdb"); var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE ItemTable(key TEXT PRIMARY KEY,value TEXT)",nil,nil,nil),SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db,"INSERT INTO ItemTable VALUES('composerData:fixture',?)",-1,&statement,nil),SQLITE_OK)
        let value = try jsonString(cursor)
        sqlite3_bind_text(statement,1,value,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement),SQLITE_DONE); sqlite3_finalize(statement)
        files.append(database)
        return try Dictionary(uniqueKeysWithValues:files.map { ($0,try Data(contentsOf:$0)) })
    }
    func testWholeProjectRuleBlocksAllFiveProvidersAndBothCursorFormats() throws {
        let sources = try makeSources()
        let policy = try object("ingestion.exclusions.upsert")
        _ = try object("sessions.refresh")
        XCTAssertEqual(try sessions().count,0)
        XCTAssertTrue(try store.search("exclusion-fixture-marker",project:project.path).isEmpty)
        _ = try object("ingestion.exclusions.remove",["id":string(policy,"id")])
        XCTAssertEqual(try sessions().count,0)
        _ = try object("sessions.refresh")
        let imported = try sessions()
        XCTAssertEqual(imported.count,6)
        XCTAssertEqual(Set(imported.map { string($0,"provider") }),Set(["claude","codex","cursor","pi","omp"]))
        for (url,before) in sources { XCTAssertEqual(try Data(contentsOf:url),before) }
    }
    func testPolicyWithdrawsExistingDerivedViewsAndPreparedCaptureThenExplicitRefreshRestores() throws {
        let sources = try makeSources(); _ = try object("sessions.refresh")
        let imported = try sessions(); XCTAssertEqual(imported.count,6)
        let codex = try XCTUnwrap(imported.first { string($0,"provider") == "codex" })
        let detail = try object("sessions.get",["id":string(codex,"id")])
        let message = try XCTUnwrap((detail["messages"] as? [JSON])?.first)
        let prep = try object("memory.capture.prepare",["sessionId":string(codex,"id"),"messageId":string(message,"id")])
        let policy = try object("ingestion.exclusions.upsert")
        XCTAssertEqual(intValue(policy,"derivedSessionsRemoved"),6)
        XCTAssertEqual(try sessions().count,0)
        XCTAssertTrue(try store.search("exclusion-fixture-marker",project:project.path).isEmpty)
        XCTAssertThrowsError(try object("memory.capture",["sessionId":string(codex,"id"),"messageId":string(message,"id"),"sourceIdentity":prep["sourceIdentity"]!,"expectedSourceHash":prep["expectedSourceHash"]!]))
        for row in imported {
            XCTAssertNil(try store.get("session",string(row,"id")))
            XCTAssertNil(try store.get("session_plan",string(row,"id")))
            XCTAssertNil(try store.get("session_relation",string(row,"id")))
        }
        _ = try object("sessions.refresh"); XCTAssertEqual(try sessions().count,0)
        _ = try object("ingestion.exclusions.remove",["id":string(policy,"id")])
        _ = try object("sessions.refresh"); XCTAssertEqual(try sessions().count,6)
        for (url,before) in sources { XCTAssertEqual(try Data(contentsOf:url),before) }
    }
}
