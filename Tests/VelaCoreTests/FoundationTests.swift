import XCTest
import CSQLite
import AppKit
import CoreText
@testable import VelaCore

final class FoundationTests: XCTestCase {
    var temporary: URL!
    var store: VelaStore!
    var service: FoundationService!
    var logs: URL!
    var project: URL!
    override func setUpWithError() throws {
        temporary = URL(fileURLWithPath:canonicalProject(FileManager.default.temporaryDirectory.path)).appendingPathComponent("vela-foundation-tests-" + UUID().uuidString,isDirectory:true)
        logs = temporary.appendingPathComponent("logs"); project = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        store = try VelaStore(root:temporary.appendingPathComponent("store"))
        service = FoundationService(store:store,sourceRoots:["claude":[logs.appendingPathComponent("claude")],"codex":[logs.appendingPathComponent("codex")],"cursor":[logs.appendingPathComponent("cursor")]],globalHome:temporary.appendingPathComponent("home"))
    }
    override func tearDownWithError() throws {
        service?.stopWatching(); service = nil; store = nil
        if let temporary, FileManager.default.fileExists(atPath:temporary.path) { try FileManager.default.removeItem(at:temporary) }
    }
    @discardableResult func rpc(_ method:String,_ params:JSON = [:]) throws -> Any {
        let value = try service.handle(method,params)
        return try XCTUnwrap(value)
    }
    func rows(_ method:String,_ params:JSON = [:]) throws -> [JSON] {
        let value = try rpc(method,params)
        return try XCTUnwrap(value as? [JSON])
    }
    func object(_ method:String,_ params:JSON = [:]) throws -> JSON {
        let value = try rpc(method,params)
        return try XCTUnwrap(value as? JSON)
    }
    func write(_ url:URL,_ text:String) throws { try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try Data(text.utf8).write(to:url) }
    func jsonl(_ objects:[JSON]) throws -> String { try objects.map { try jsonString($0) }.joined(separator:"\n") + "\n" }
    func append(_ url:URL,_ text:String) throws { let handle = try FileHandle(forWritingTo:url); defer { try? handle.close() }; try handle.seekToEnd(); try handle.write(contentsOf:Data(text.utf8)) }

    func testSQLitePersistenceIsolationAndBoundQueries() throws {
        let entry = try store.put("memory",["id":"a","title":"Needle","content":"safe needle","project":project.path,"state":"active"])
        let reopened = try VelaStore(root:store.root)
        XCTAssertEqual(try reopened.get("memory","a")?["content"] as? String,"safe needle")
        XCTAssertEqual(try reopened.search("needle",project:project.path).count,1)
        XCTAssertTrue(try reopened.search("needle",project:temporary.appendingPathComponent("different").path).isEmpty)
        XCTAssertTrue(try reopened.search("%' OR 1=1 --").isEmpty)
        XCTAssertThrowsError(try reopened.put("memory",["id":"../escape","title":"bad"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath:try XCTUnwrap(entry["assetPath"] as? String)))
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open_v2(store.root.appendingPathComponent("vela.sqlite3").path,&db,SQLITE_OPEN_READONLY,nil),SQLITE_OK); defer { sqlite3_close(db) }
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db,"PRAGMA journal_mode",-1,&statement,nil),SQLITE_OK); defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW)
        XCTAssertEqual(String(cString:sqlite3_column_text(statement,0)),"wal")
    }
    func testCanonicalProjectAndNoSymlinkAssetEscape() throws {
        let link = temporary.appendingPathComponent("project-link"); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:project)
        let added = try object("projects.add",["path":link.path])
        XCTAssertEqual(added["path"] as? String,project.path)
        _ = try store.put("library",["id":"private-link","title":"safe","content":"before","project":link.path])
        XCTAssertEqual(try store.list("library",project:project.path).count,1)
        let asset = try store.assetURL(kind:"library",id:"private-link")
        try FileManager.default.removeItem(at:asset)
        let outside = temporary.appendingPathComponent("user.txt"); try write(outside,"never overwrite")
        try FileManager.default.createSymbolicLink(at:asset,withDestinationURL:outside)
        XCTAssertThrowsError(try store.put("library",["id":"private-link","title":"bad","content":"overwrite"]))
        XCTAssertEqual(try String(contentsOf:outside,encoding:.utf8),"never overwrite")
    }
    func testRecallAllScopesStateAndBudget() throws {
        let otherProject = temporary.appendingPathComponent("other").path
        let definitions:[JSON] = [
            ["title":"global","scope":"global"], ["title":"project","scope":"project","project":project.path],
            ["title":"repository","scope":"repository","project":project.path], ["title":"branch","scope":"branch","project":project.path,"branch":"main"],
            ["title":"worktree","scope":"worktree","project":project.path,"worktree":project.path], ["title":"task","scope":"task","project":project.path,"task":"build"],
            ["title":"session","scope":"session","project":project.path,"sourceSession":"session-1"], ["title":"other","scope":"project","project":otherProject],
            ["title":"candidate","scope":"project","project":project.path,"state":"candidate"], ["title":"private","scope":"project","project":project.path,"private":true]
        ]
        for definition in definitions { var params:JSON = ["content":"记忆 memory","state":"active","type":"fact"]; params.merge(definition) { _,new in new }; _ = try rpc("memory.save",params) }
        let simple = try object("recall",["project":project.path,"query":"memory","budget":2000])
        XCTAssertEqual(Set((simple["items"] as? [JSON] ?? []).map { string($0,"title") }),Set(["global","project","repository"]))
        let all = try object("recall",["project":project.path,"query":"memory","branch":"main","worktree":project.path,"task":"build","sessionId":"session-1","budget":2000])
        XCTAssertEqual((all["items"] as? [JSON])?.count,7)
        let zero = try object("recall",["project":project.path,"query":"memory","budget":0]); XCTAssertEqual(intValue(zero,"usedTokens"),0); XCTAssertTrue((zero["items"] as? [JSON] ?? []).isEmpty)
        let tiny = try object("recall",["project":project.path,"query":"memory","budget":12]); XCTAssertLessThanOrEqual(intValue(tiny,"usedTokens"),12)
        XCTAssertGreaterThan(tokenEstimate("中文"),2)
        XCTAssertThrowsError(try rpc("memory.save",["title":"invalid","content":"x","scope":"branch","project":project.path]))
    }
    func testMemoryLifecycleAndHumanMarkdownEdits() throws {
        let old = try object("memory.save",["title":"Old tool","content":"Use npm","scope":"project","project":project.path,"state":"active"])
        let new = try object("memory.save",["title":"New tool","content":"Use pnpm","scope":"project","project":project.path])
        _ = try rpc("memory.transition",["id":string(new,"id"),"state":"active","supersedes":string(old,"id")])
        XCTAssertEqual(try store.get("memory",string(old,"id"))?["state"] as? String,"superseded")
        XCTAssertThrowsError(try rpc("memory.transition",["id":string(old,"id"),"state":"active"]))
        let asset = URL(fileURLWithPath:try XCTUnwrap(new["assetPath"] as? String))
        let original = try String(contentsOf:asset,encoding:.utf8); try write(asset,original.replacingOccurrences(of:"Use pnpm",with:"Use bun after migration"))
        let edited = try XCTUnwrap(store.get("memory",string(new,"id")))
        XCTAssertEqual(string(edited,"content"),"Use bun after migration"); XCTAssertEqual(edited["humanEdited"] as? Bool,true)
        XCTAssertEqual(try store.search("bun",project:project.path).count,1)
    }
    func testPrivateLibraryAlwaysExcludedFromAgentSearch() throws {
        let file = temporary.appendingPathComponent("private/secret.md"); try write(file,"secret needle")
        let imported = try object("library.add",["title":"Personal","path":file.path,"project":project.path,"private":false])
        XCTAssertEqual(imported["private"] as? Bool,true)
        XCTAssertTrue(try store.search("needle",project:project.path,includePrivate:false).isEmpty)
        XCTAssertEqual(try store.search("needle",project:project.path,includePrivate:true).count,1)
        _ = try rpc("library.add",["title":"Default private","content":"secret needle","project":project.path])
        XCTAssertTrue(try store.search("needle",project:project.path,includePrivate:false).isEmpty)
        _ = try rpc("library.add",["title":"Public","content":"public needle","project":project.path,"private":false])
        XCTAssertEqual(try store.search("needle",project:project.path,includePrivate:false).count,1)
    }
    func testClaudeStreamingOffsetAndUsageDeduplication() throws {
        let file = logs.appendingPathComponent("claude/project/session.jsonl")
        let first:JSON = ["type":"user","uuid":"u1","sessionId":"real-session","cwd":project.path,"timestamp":isoNow(),"message":["role":"user","content":"Implement a real parser"]]
        let assistant:JSON = ["type":"assistant","uuid":"row-a","timestamp":isoNow(),"message":["id":"message-a","role":"assistant","model":"claude-test-model","content":[["type":"text","text":"Implemented parser"]],"usage":["input_tokens":100,"cache_read_input_tokens":20,"output_tokens":30]]]
        try write(file,jsonl([first,assistant,assistant])); _ = try rpc("sessions.refresh")
        var all = try rows("sessions.list"); XCTAssertEqual(all.count,1); XCTAssertEqual(intValue(all[0],"tokenInput"),120); XCTAssertEqual(intValue(all[0],"tokenOutput"),30)
        XCTAssertEqual(intValue(all[0],"messageCount"),2); XCTAssertEqual(string(all[0],"project"),project.path); XCTAssertEqual(all[0]["statusInferred"] as? Bool,true)
        let unchanged = try object("sessions.refresh"); XCTAssertEqual(intValue(unchanged,"sourcesUpdated"),0)
        try append(file,jsonl([["type":"user","uuid":"u2","timestamp":isoNow(),"message":["role":"user","content":"Run its tests"]]]))
        _ = try rpc("sessions.refresh"); all = try rows("sessions.list"); XCTAssertEqual(intValue(all[0],"messageCount"),3)
        let sourceSize = (try file.resourceValues(forKeys:[.fileSizeKey])).fileSize
        let cursor = try XCTUnwrap(store.get("ingestion",stableHash(file.path))); XCTAssertEqual(intValue(cursor,"offset"),sourceSize)
    }
    func testGrowingRewriteBeforeIndexedOffsetRotatesAndLegacyCursorFailsClosed() throws {
        _ = try object("projects.add",["path":project.path])
        let file = logs.appendingPathComponent("claude/growing-rewrite.jsonl")
        func user(_ content: String) -> JSON {
            ["type":"user","uuid":"rewrite-user","sessionId":"rewrite-source","cwd":project.path,"timestamp":"2026-09-14T00:00:00Z","message":["role":"user","content":content]]
        }
        func assistant(_ id: String, _ content: String) -> JSON {
            ["type":"assistant","uuid":id,"timestamp":"2026-09-14T00:00:01Z","message":["id":id,"role":"assistant","content":[["type":"text","text":content]]]]
        }
        func sessionMessages(_ item: JSON) -> [JSON] { item["messages"] as? [JSON] ?? [] }
        let old = String(repeating:"O",count:40), rewritten = String(repeating:"R",count:40), legacyRewrite = String(repeating:"L",count:40)
        try write(file,jsonl([user(old),assistant("initial","initial response")]))
        _ = try rpc("sessions.refresh")
        var item = try XCTUnwrap(rows("sessions.list",["project":project.path]).first)
        let id = string(item,"id"), initialCursor = try XCTUnwrap(store.get("ingestion",stableHash(file.path)))
        XCTAssertEqual(string(initialCursor,"indexedPrefixSHA256").count,64)

        // The old user line changes at the same byte width, then a later row
        // grows the file.  This must not be mistaken for a pure append.
        try write(file,jsonl([user(rewritten),assistant("initial","initial response"),assistant("later","appended response")]))
        _ = try rpc("sessions.refresh")
        item = try object("sessions.get",["id":id])
        XCTAssertTrue(sessionMessages(item).contains { string($0,"id") == "rewrite-user" && string($0,"content") == rewritten })
        XCTAssertTrue(sessionMessages(item).contains { string($0,"id") == "later" && string($0,"content") == "appended response" })
        let rebuiltCursor = try XCTUnwrap(store.get("ingestion",stableHash(file.path)))
        XCTAssertEqual(intValue(rebuiltCursor,"offset"),try Data(contentsOf:file).count)
        XCTAssertEqual(string(rebuiltCursor,"indexedPrefixSHA256").count,64)

        // A normal append still keeps the accepted prefix and reads only the
        // new complete record.
        try append(file,jsonl([assistant("normal","normal append")]))
        _ = try rpc("sessions.refresh")
        item = try object("sessions.get",["id":id])
        XCTAssertTrue(sessionMessages(item).contains { string($0,"id") == "normal" && string($0,"content") == "normal append" })

        // Migration safety: a pre-digest cursor cannot verify a growing
        // prefix, so it rebuilds once rather than preserving stale content.
        var legacy = try XCTUnwrap(store.get("ingestion",stableHash(file.path))); legacy.removeValue(forKey:"indexedPrefixSHA256"); _ = try store.put("ingestion",legacy)
        try write(file,jsonl([user(legacyRewrite),assistant("initial","initial response"),assistant("later","appended response"),assistant("normal","normal append"),assistant("migration","migration append")]))
        _ = try rpc("sessions.refresh")
        item = try object("sessions.get",["id":id])
        XCTAssertTrue(sessionMessages(item).contains { string($0,"id") == "rewrite-user" && string($0,"content") == legacyRewrite })
        XCTAssertTrue(sessionMessages(item).contains { string($0,"id") == "migration" })
        XCTAssertEqual(string(try XCTUnwrap(store.get("ingestion",stableHash(file.path))),"indexedPrefixSHA256").count,64)

        // An incomplete append leaves the completed-prefix digest in place;
        // completing that same line later is still ingested exactly once.
        let partial = try jsonString(assistant("partial","completed after partial tail"))
        try append(file,String(partial.prefix(37))); _ = try rpc("sessions.refresh")
        item = try object("sessions.get",["id":id]); XCTAssertFalse(sessionMessages(item).contains { string($0,"id") == "partial" })
        try append(file,String(partial.dropFirst(37)) + "\n"); _ = try rpc("sessions.refresh")
        item = try object("sessions.get",["id":id]); XCTAssertEqual(sessionMessages(item).filter { string($0,"id") == "partial" }.count,1)
    }
    func testCodexGrowingRewriteBeforeIndexedOffsetRebuildsMessages() throws {
        _ = try object("projects.add",["path":project.path])
        let file = logs.appendingPathComponent("codex/growing-rewrite.jsonl")
        func message(_ id: String, _ role: String, _ content: String) -> JSON {
            ["type":"response_item","timestamp":"2026-09-14T00:00:01Z","payload":["id":id,"type":"message","role":role,"content":[["type":role == "user" ? "input_text" : "output_text","text":content]]]]
        }
        let old = String(repeating:"C",count:32), rewritten = String(repeating:"N",count:32)
        func source(_ user: String, _ includeLater: Bool) -> [JSON] {
            var rows:[JSON] = [["type":"session_meta","timestamp":"2026-09-14T00:00:00Z","payload":["id":"codex-growing-source","cwd":project.path,"git":["branch":"main"]]],message("codex-growing-user","user",user)]
            if includeLater { rows.append(message("codex-growing-later","assistant","later Codex append")) }
            return rows
        }
        func sessionMessages(_ item: JSON) -> [JSON] { item["messages"] as? [JSON] ?? [] }
        try write(file,jsonl(source(old,false))); _ = try rpc("sessions.refresh")
        let before = try XCTUnwrap(rows("sessions.list",["project":project.path]).first { string($0,"provider") == "codex" })
        try write(file,jsonl(source(rewritten,true))); _ = try rpc("sessions.refresh")
        let after = try object("sessions.get",["id":string(before,"id")])
        XCTAssertTrue(sessionMessages(after).contains { string($0,"id") == "codex-growing-user" && string($0,"content") == rewritten })
        XCTAssertTrue(sessionMessages(after).contains { string($0,"id") == "codex-growing-later" })
        XCTAssertEqual(string(try XCTUnwrap(store.get("ingestion",stableHash(file.path))),"indexedPrefixSHA256").count,64)
    }
    func testCodexBoundedTailRetainsHeaderAndCumulativeUsage() throws {
        let file = logs.appendingPathComponent("codex/2026/09/12/rollout.jsonl")
        var records:[JSON] = [["type":"session_meta","timestamp":isoNow(),"payload":["id":"real-codex-id","cwd":project.path,"git":["branch":"main"]]]]
        for index in 0..<1200 { records.append(["type":"response_item","timestamp":isoNow(),"payload":["id":"m\(index)","type":"message","role":"assistant","content":[["type":"output_text","text":String(repeating:"x",count:350)]]]]) }
        records.append(["type":"event_msg","timestamp":isoNow(),"payload":["type":"token_count","info":["total_token_usage":["input_tokens":12345,"output_tokens":678]]]])
        records.append(["type":"event_msg","timestamp":isoNow(),"payload":["type":"task_complete"]])
        try write(file,jsonl(records)); _ = try rpc("sessions.refresh")
        let session = try XCTUnwrap(rows("sessions.list").first)
        XCTAssertEqual(string(session,"project"),project.path); XCTAssertEqual(string(session,"sourceSessionId"),"real-codex-id")
        XCTAssertEqual(session["historyTruncated"] as? Bool,true); XCTAssertEqual(session["historyFullyIndexed"] as? Bool,false)
        XCTAssertLessThan(intValue(session,"messageCount"),1200); XCTAssertEqual(intValue(session,"tokenInput"),12345); XCTAssertEqual(string(session,"state"),"Completed")
    }
    func testPartialJSONLAndRotation() throws {
        let file = logs.appendingPathComponent("claude/a.jsonl")
        let a = try jsonl([["type":"user","uuid":"a","cwd":project.path,"message":["role":"user","content":"First"]]])
        let b = try jsonl([["type":"user","uuid":"b","message":["role":"user","content":"Second"]]])
        try write(file,a + String(b.prefix(20))); _ = try rpc("sessions.refresh")
        XCTAssertEqual(try rows("sessions.list").first?["messageCount"] as? Int,1)
        try append(file,String(b.dropFirst(20))); _ = try rpc("sessions.refresh")
        XCTAssertEqual(try rows("sessions.list").first?["messageCount"] as? Int,2)
        try write(file,try jsonl([["type":"user","uuid":"c","message":["role":"user","content":"After rotation"]]])); _ = try rpc("sessions.refresh")
        XCTAssertEqual(try rows("sessions.list").first?["messageCount"] as? Int,1)
    }
    func testCursorReadOnlySQLiteAndUnsupportedSchemaDiagnostics() throws {
        let directory = logs.appendingPathComponent("cursor"); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let database = directory.appendingPathComponent("state.vscdb"); var db:OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE ItemTable(key TEXT PRIMARY KEY,value BLOB)",nil,nil,nil),SQLITE_OK)
        var statement:OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db,"INSERT INTO ItemTable VALUES(?,?)",-1,&statement,nil),SQLITE_OK)
        let value = try jsonString(["name":"Cursor real fixture","cwd":project.path,"conversation":[["type":1,"text":"Fix parser"],["type":2,"text":"Fixed parser"]]])
        sqlite3_bind_text(statement,1,"composerData:fixture",-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)); sqlite3_bind_text(statement,2,value,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement),SQLITE_DONE); sqlite3_finalize(statement); sqlite3_close(db)
        let before = try Data(contentsOf:database); _ = try rpc("sessions.refresh")
        let session = try XCTUnwrap(rows("sessions.list").first); XCTAssertEqual(string(session,"provider"),"cursor"); XCTAssertEqual(intValue(session,"messageCount"),2); XCTAssertEqual(string(session,"state"),"Unknown")
        XCTAssertEqual(before,try Data(contentsOf:database))
        let bad = directory.appendingPathComponent("unknown.sqlite"); XCTAssertEqual(sqlite3_open(bad.path,&db),SQLITE_OK); sqlite3_exec(db,"CREATE TABLE unknown(x TEXT)",nil,nil,nil); sqlite3_close(db)
        let refreshed = try object("sessions.refresh"); let diagnostics = refreshed["diagnostics"] as? [JSON] ?? []
        XCTAssertTrue(diagnostics.contains { string($0,"message").contains("Unsupported Cursor SQLite schema") })
    }
    func testSetupScanningRedactsSecretsAndStaysInExplicitScope() throws {
        let config = project.appendingPathComponent(".mcp.json")
        let content = try jsonString(["mcpServers":["test":["command":"tool","env":["CUSTOM_CREDENTIAL":"abc-super-secret","OTHER":"another-secret"],"headers":["Authorization":"Bearer hidden-token"],"apiKey":"sk-do-not-expose-secret"]]])
        try write(config,content); try write(project.appendingPathComponent("AGENTS.md"),"Use real tests")
        let outside = temporary.appendingPathComponent("outside/CLAUDE.md"); try write(outside,"external private content")
        try FileManager.default.createSymbolicLink(at:project.appendingPathComponent("CLAUDE.md"),withDestinationURL:outside)
        let scanned = try object("setup.scan",["project":project.path]); let encoded = try jsonString(scanned)
        XCTAssertFalse(encoded.contains("abc-super-secret")); XCTAssertFalse(encoded.contains("another-secret")); XCTAssertFalse(encoded.contains("sk-do-not-expose-secret")); XCTAssertFalse(encoded.contains("external private content")); XCTAssertTrue(encoded.contains("REDACTED"))
        XCTAssertEqual(try String(contentsOf:config,encoding:.utf8),content)
        let diagnostics = scanned["diagnostics"] as? [JSON] ?? []
        XCTAssertTrue(diagnostics.contains { string($0,"code") == "unreadable-source" })
        XCTAssertFalse(diagnostics.contains { string($0,"code").contains("conflict") })
    }
    func testHTMLAndDOCXLibraryImport() throws {
        let html = temporary.appendingPathComponent("reference.html"); try write(html,"<html><script>doNotIndex()</script><h1>Useful title</h1><p>One &amp; two</p></html>")
        let item = try object("library.add",["title":"HTML","path":html.path]); XCTAssertTrue(string(item,"content").contains("One & two")); XCTAssertFalse(string(item,"content").contains("doNotIndex"))
        let text = temporary.appendingPathComponent("source.txt"); try write(text,"A real DOCX reference")
        let docx = temporary.appendingPathComponent("source.docx")
        let conversion = try FoundationCommand.run("/usr/bin/textutil",["-convert","docx","-output",docx.path,text.path],timeout:15)
        XCTAssertEqual(conversion.code,0)
        let imported = try object("library.add",["title":"DOCX","path":docx.path]); XCTAssertTrue(string(imported,"content").contains("A real DOCX reference"))
    }
    func testCheckpointCapturesActualGitAndExportDoesNotExecute() throws {
        XCTAssertEqual(try FoundationCommand.run("/usr/bin/git",["-C",project.path,"init"],timeout:5).code,0)
        try write(project.appendingPathComponent("tracked.txt"),"initial")
        _ = try FoundationCommand.run("/usr/bin/git",["-C",project.path,"add","tracked.txt"],timeout:5)
        XCTAssertEqual(try FoundationCommand.run("/usr/bin/git",["-C",project.path,"-c","user.name=Vela Test","-c","user.email=test@example.invalid","commit","-m","fixture"],timeout:5).code,0)
        try write(project.appendingPathComponent("tracked.txt"),"changed")
        let checkpoint = try object("checkpoint.save",["project":project.path,"goal":"Finish parser","completed":["initial parser"],"pending":["tests"],"decisions":["stream JSONL"]])
        XCTAssertTrue(string(checkpoint,"content").contains("tracked.txt")); XCTAssertEqual((checkpoint["gitState"] as? JSON)?["commit"] as? String,try FoundationCommand.run("/usr/bin/git",["-C",project.path,"rev-parse","HEAD"],timeout:5).output.trimmingCharacters(in:.whitespacesAndNewlines))
        let exported = try object("checkpoint.export",["id":string(checkpoint,"id"),"provider":"codex"])
        XCTAssertEqual(exported["executed"] as? Bool,false); XCTAssertTrue(FileManager.default.fileExists(atPath:string(exported,"path")))
    }
    func testAtomicBatchRestoresBothSQLiteAndMarkdownOnFailure() throws {
        let original = try store.put("memory",["id":"batch-original","title":"Original","content":"before","project":project.path,"state":"active"])
        let asset = URL(fileURLWithPath:string(original,"assetPath")); let before = try Data(contentsOf:asset)
        XCTAssertThrowsError(try store.putBatch([
            ("memory",["id":"batch-original","title":"Changed","content":"after","project":project.path]),
            ("memory",["id":"batch-failure","title":"Failure","content":Date()])
        ]))
        XCTAssertEqual(try store.get("memory","batch-original")?["content"] as? String,"before")
        XCTAssertEqual(try Data(contentsOf:asset),before)
        XCTAssertNil(try store.get("memory","batch-failure"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:try store.assetURL(kind:"memory",id:"batch-failure").path))
        _ = try rpc("memory.transition",["id":"batch-original","state":"archived"])
        XCTAssertThrowsError(try rpc("memory.save",["id":"batch-original","title":"Resurrect","content":"after","project":project.path,"scope":"project","state":"active"]))
    }
    func testCheckpointGitDoesNotExecuteProjectFsmonitor() throws {
        _ = try FoundationCommand.run("/usr/bin/git",["-C",project.path,"init"],timeout:5)
        let hook = project.appendingPathComponent("malicious-monitor"); let marker = project.appendingPathComponent("unexpected-execution")
        try write(hook,"#!/bin/sh\ntouch '\(marker.path)'\n")
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:hook.path)
        _ = try FoundationCommand.run("/usr/bin/git",["-C",project.path,"config","core.fsmonitor",hook.path],timeout:5)
        _ = try rpc("checkpoint.save",["project":project.path,"goal":"Read Git safely"])
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    }
    func testFSEventsIngestsOnlyChangedLogWithoutManualRefresh() throws {
        let file = logs.appendingPathComponent("claude/watched.jsonl")
        try write(file,jsonl([["type":"user","uuid":"watch-1","cwd":project.path,"message":["role":"user","content":"Watch this log"]]]))
        let engine = SessionEngine(store:store,sourceRoots:["claude":[logs.appendingPathComponent("claude")]])
        _ = try engine.refresh(); let signal = DispatchSemaphore(value:0)
        engine.onChange = { signal.signal() }; engine.startWatching(); defer { engine.stopWatching() }
        try append(file,jsonl([["type":"user","uuid":"watch-2","message":["role":"user","content":"The log has changed"]]]))
        XCTAssertEqual(signal.wait(timeout:.now()+5),.success)
        XCTAssertEqual(try store.list("session").first?["messageCount"] as? Int,2)
    }

    func testStateClaimAcrossTwoSQLiteConnectionsHasOneWinner() throws {
        _ = try store.put("approval",["id":"one-claim","title":"Explicit action","state":"pending"])
        let otherStore = try VelaStore(root:store.root)
        let group = DispatchGroup(); let resultLock = NSLock(); var winners = 0; var failures:[String] = []
        for candidate in [store!,otherStore] {
            group.enter(); DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let claimed = try candidate.claimState(kind:"approval",id:"one-claim",expected:"pending",newState:"executing")
                    resultLock.lock(); if claimed != nil { winners += 1 }; resultLock.unlock()
                } catch { resultLock.lock(); failures.append(error.localizedDescription); resultLock.unlock() }
            }
        }
        XCTAssertEqual(group.wait(timeout:.now()+5),.success)
        XCTAssertTrue(failures.isEmpty); XCTAssertEqual(winners,1)
        XCTAssertEqual(try store.get("approval","one-claim")?["state"] as? String,"executing")
        XCTAssertThrowsError(try store.claimState(kind:"memory",id:"one-claim",expected:"pending",newState:"active"))
    }

    func testPDFAndExplicitURLImportEnforceDocumentLimits() throws {
        let pdfBytes = NSMutableData(); var bounds = CGRect(x:0,y:0,width:400,height:300)
        let consumer = try XCTUnwrap(CGDataConsumer(data:pdfBytes as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer:consumer,mediaBox:&bounds,nil))
        context.beginPDFPage(nil); context.textPosition = CGPoint(x:30,y:220)
        let text = NSAttributedString(string:"Extractable PDF reference",attributes:[.font:NSFont.systemFont(ofSize:14)])
        CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString),context)
        context.endPDFPage(); context.closePDF()
        let pdf = temporary.appendingPathComponent("reference.pdf"); try (pdfBytes as Data).write(to:pdf)
        let imported = try object("library.add",["title":"PDF","path":pdf.path,"private":false])
        XCTAssertTrue(string(imported,"content").contains("Extractable PDF reference")); XCTAssertEqual(imported["private"] as? Bool,false)
        try write(temporary.appendingPathComponent("remote.html"),"<h1>Explicit URL reference</h1><p>Import only this document.</p>")
        try write(temporary.appendingPathComponent("large.txt"),String(repeating:"x",count:2 * 1024 * 1024 + 1))
        let server = Process(); let output = Pipe()
        server.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        server.arguments = ["-u","-c","import http.server,functools,sys; h=functools.partial(http.server.SimpleHTTPRequestHandler,directory=sys.argv[1]); s=http.server.ThreadingHTTPServer(('127.0.0.1',0),h); print(s.server_port,flush=True); s.serve_forever()",temporary.path]
        server.standardOutput = output; server.standardError = FileHandle.nullDevice; server.standardInput = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        let port = String(decoding:output.fileHandleForReading.availableData,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        XCTAssertNotNil(Int(port))
        let remote = try object("library.add",["title":"URL","url":"http://127.0.0.1:\(port)/remote.html"])
        XCTAssertTrue(string(remote,"content").contains("Explicit URL reference")); XCTAssertEqual(remote["private"] as? Bool,true)
        XCTAssertThrowsError(try rpc("library.add",["title":"Too large","url":"http://127.0.0.1:\(port)/large.txt"]))
        XCTAssertThrowsError(try rpc("library.add",["title":"Invalid protocol","url":"file:///etc/passwd"]))
    }

}
