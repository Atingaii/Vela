import XCTest
@testable import VelaCore

final class MCPToolsTests: XCTestCase {
    private final class Fixture {
        let temporary: URL
        let project: String
        let other: String
        let store: VelaStore
        var coreCalls: [String] = []
        var nextID = 10
        init() throws {
            temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-mcp-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at:temporary.appendingPathComponent("project"),withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:temporary.appendingPathComponent("other"),withIntermediateDirectories:true)
            project = canonicalProject(temporary.appendingPathComponent("project").path)
            other = canonicalProject(temporary.appendingPathComponent("other").path)
            store = try VelaStore(root:temporary.appendingPathComponent("store"))
            for root in [project,other] { _ = try store.put("project",["id":stableHash(root),"path":root,"project":root,"title":"Synthetic MCP project"]) }
        }
        deinit { try? FileManager.default.removeItem(at:temporary) }
        func server(_ contribute: Bool = false) -> MCPTools {
            MCPTools(store:store,contribute:contribute,serverVersion:"test") { [self] method,params in
                coreCalls.append(method)
                if let value = try MemoryService(store:store).handle(method,params) { return value }
                if let value = try ContextService(store:store).handle(method,params) { return value }
                throw VelaError("Unexpected Core dispatch")
            }
        }
        @discardableResult func handshake(_ server: MCPTools, version: String = "2025-11-25") throws -> JSON {
            let response = server.handle(request:["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":version,"capabilities":[:] as JSON,"clientInfo":["name":"Vela synthetic consumer","version":"1"]] as JSON])
            let result = try XCTUnwrap(response?["result"] as? JSON)
            XCTAssertNil(server.handle(request:["jsonrpc":"2.0","method":"notifications/initialized"]))
            return result
        }
        func call(_ server: MCPTools, _ name: String, _ input: JSON = [:], error: Bool = false) throws -> JSON {
            nextID += 1; var arguments = input
            if arguments["project"] == nil { arguments["project"] = project }
            let response = server.handle(request:["jsonrpc":"2.0","id":nextID,"method":"tools/call","params":["name":name,"arguments":arguments] as JSON])
            let result = try XCTUnwrap(response?["result"] as? JSON)
            XCTAssertEqual(result["isError"] as? Bool,error)
            return result
        }
        func value(_ result: JSON) throws -> Any {
            let blocks = try XCTUnwrap(result["content"] as? [JSON])
            return try JSONSerialization.jsonObject(with:Data(string(blocks[0],"text").utf8),options:[.fragmentsAllowed])
        }
        func object(_ result: JSON) throws -> JSON { let decoded = try value(result); return try XCTUnwrap(decoded as? JSON) }
        func array(_ result: JSON) throws -> [JSON] { let decoded = try value(result); return try XCTUnwrap(decoded as? [JSON]) }
        @discardableResult func source(_ kind: String = "memory", id: String = UUID().uuidString, extra: JSON = [:]) throws -> JSON {
            var row: JSON = ["id":id,"project":project,"title":"Synthetic Cedar reference","content":"CedarBoundary is public synthetic evidence.","scope":"project","state":"active","private":false]
            row.merge(extra){_,new in new}; return try store.put(kind,row)
        }
        func changeHeader(_ item: JSON, _ edits: JSON) throws {
            let path = string(item,"assetPath"), source = try String(contentsOfFile:path,encoding:.utf8)
            let end = try XCTUnwrap(source.range(of:" -->\n\n# "))
            var header = item; header.removeValue(forKey:"content"); header.merge(edits){_,new in new}
            try ("<!-- Vela metadata: " + jsonString(header) + String(source[end.lowerBound...])).write(toFile:path,atomically:true,encoding:.utf8)
        }
    }
    func testProtocolNegotiationAndOldCatalogAndTextCompatibility() throws {
        let f = try Fixture(); _ = try f.source()
        for version in MCPTools.supportedVersions {
            let server = f.server(); let initResult = try f.handshake(server,version:version)
            XCTAssertEqual(string(initResult,"protocolVersion"),version)
            XCTAssertEqual(server.catalog(protocolVersion:version).count,15)
            XCTAssertEqual(server.catalog(protocolVersion:version)[0]["annotations"] == nil,version == "2024-11-05")
            let result = try f.call(server,"vela_memory_list")
            XCTAssertEqual(try f.array(result).count,1)
            XCTAssertNotNil((result["_meta"] as? JSON)?["ai.vela/pagination"])
            XCTAssertEqual(result["structuredContent"] == nil,["2024-11-05","2025-03-26"].contains(version))
        }
        let future = f.server(); XCTAssertEqual(string(try f.handshake(future,version:"2099-01-01"),"protocolVersion"),"2025-11-25")
        XCTAssertTrue(f.coreCalls.isEmpty)
    }
    func testInitializationNotificationsAndDuplicateIDsCannotExecuteTools() throws {
        let f = try Fixture(), server = f.server(true)
        let early = server.handle(request:["jsonrpc":"2.0","id":2,"method":"tools/list"])
        XCTAssertEqual(intValue(early?["error"] as? JSON ?? [:],"code"),-32002)
        _ = try f.handshake(server)
        let idReuse = server.handle(request:["jsonrpc":"2.0","id":1,"method":"tools/list"])
        XCTAssertEqual(intValue(idReuse?["error"] as? JSON ?? [:],"code"),-32600)
        XCTAssertNil(server.handle(request:["jsonrpc":"2.0","method":"tools/call","params":["name":"vela_remember","arguments":["project":f.project,"title":"No write","content":"Notification"]] as JSON]))
        XCTAssertNil(server.handle(request:["jsonrpc":"2.0","method":"notifications/cancelled","params":["requestId":99] as JSON]))
        XCTAssertTrue(try f.store.list("memory").isEmpty)
        let bad = server.handle(request:["jsonrpc":"2.0","id":true,"method":"ping"])
        XCTAssertEqual(intValue(bad?["error"] as? JSON ?? [:],"code"),-32600)
        let invalid = server.handle(request:["jsonrpc":"2.0","id":4,"method":"initialize","params":[:]])
        XCTAssertEqual(intValue(invalid?["error"] as? JSON ?? [:],"code"),-32602)
    }
    func testCatalogSchemasAreClosedAndStrictlyRejectBoolFractionsAndUnknownFields() throws {
        let f = try Fixture(), server = f.server(true); _ = try f.handshake(server)
        XCTAssertEqual(server.catalog().count,22)
        for tool in server.catalog() {
            let schema = try XCTUnwrap(tool["inputSchema"] as? JSON)
            XCTAssertEqual(schema["additionalProperties"] as? Bool,false)
            XCTAssertTrue((schema["required"] as? [String] ?? []).contains("project"))
        }
        for invalid: JSON in [["limit":true],["limit":1.5],["limit":0],["includePrivate":true],["path":"/tmp"],["limit":101],["state":"active","operations":[]]] {
            _ = try f.call(server,"vela_memory_list",invalid,error:true)
        }
        for invalid: JSON in [["id":"existing"],["state":"active"],["scope":"global"],["private":false],["supersedes":"old"],["content":true],["content":"a\0b"]] {
            var input: JSON = ["title":"New","content":"Synthetic content"]; input.merge(invalid){_,new in new}
            _ = try f.call(server,"vela_remember",input,error:true)
        }
        XCTAssertTrue(try f.store.list("memory").isEmpty); XCTAssertTrue(f.coreCalls.isEmpty)
    }
    func testDefaultPermissionCatalogCannotCallContributionOrExecutionPrimitives() throws {
        let f = try Fixture(), server = f.server(); _ = try f.handshake(server)
        for name in ["vela_remember","vela_memory_contribute","vela_checkpoint_save","vela_local_archive_restore","workflows.run","tools.execute","ask.create","filesystem.read"] {
            f.nextID += 1
            let response = server.handle(request:["jsonrpc":"2.0","id":f.nextID,"method":"tools/call","params":["name":name,"arguments":["project":f.project]] as JSON])
            XCTAssertEqual(intValue(response?["error"] as? JSON ?? [:],"code"),-32602)
        }
        XCTAssertTrue(f.coreCalls.isEmpty)
    }
    func testRegisteredProjectAndCrossProjectAreEnforcedBeforeSourceRead() throws {
        let f = try Fixture(), server = f.server(); _ = try f.handshake(server)
        let item = try f.source(extra:["project":f.other])
        _ = try f.call(server,"vela_memory_get",["id":string(item,"id")],error:true)
        _ = try f.call(server,"vela_health",["project":f.temporary.path],error:true)
        _ = try f.call(server,"vela_health",["project":"relative"],error:true)
        let explicitOther = try f.object(f.call(server,"vela_memory_get",["project":f.other,"id":string(item,"id")]))
        XCTAssertEqual(string(explicitOther,"project"),f.other)
        XCTAssertTrue(f.coreCalls.isEmpty)
    }
    func testScopesAndCandidateReviewNeverBecomeDefaultRecall() throws {
        let f = try Fixture(), server = f.server(); _ = try f.handshake(server)
        _ = try f.source(id:"a-project")
        _ = try f.source(id:"b-branch",extra:["scope":"branch","branch":"release"])
        _ = try f.source(id:"c-candidate",extra:["state":"candidate"])
        _ = try f.source(id:"d-private",extra:["private":true])
        _ = try f.source(id:"e-global",extra:["scope":"global"])
        let defaults = try f.array(f.call(server,"vela_memory_list")); XCTAssertEqual(defaults.map{string($0,"id")},["a-project"])
        let branch = try f.array(f.call(server,"vela_memory_list",["branch":"release"])); XCTAssertEqual(branch.map{string($0,"id")},["a-project","b-branch"])
        let candidate = try f.array(f.call(server,"vela_memory_list",["state":"candidate"])); XCTAssertEqual(candidate.map{string($0,"id")},["c-candidate"])
        let review = try f.object(f.call(server,"vela_memory_get",["id":"c-candidate","state":"candidate"]))
        XCTAssertEqual(review["candidateReviewOnly"] as? Bool,true)
        let recall = try f.object(f.call(server,"vela_recall",["query":"CedarBoundary","budget":1000]))
        XCTAssertEqual((recall["items"] as? [JSON] ?? []).map{string($0,"id")},["a-project"])
    }
    func testFilteredEmptyPagesAdvanceAndLaterPublicRowsRemainReachable() throws {
        let f = try Fixture(), server = f.server(); _ = try f.handshake(server)
        _ = try f.source(id:"a-private",extra:["private":true]); _ = try f.source(id:"b-private",extra:["private":true]); _ = try f.source(id:"c-public")
        let first = try f.call(server,"vela_memory_list",["limit":1]); XCTAssertTrue(try f.array(first).isEmpty)
        let meta = try XCTUnwrap((first["_meta"] as? JSON)?["ai.vela/pagination"] as? JSON)
        XCTAssertEqual(string(meta,"nextCursor"),"a-private"); XCTAssertEqual(intValue(meta,"scanned"),1)
        let second = try f.call(server,"vela_memory_list",["limit":1,"after":string(meta,"nextCursor")]); XCTAssertTrue(try f.array(second).isEmpty)
        let secondMeta = try XCTUnwrap((second["_meta"] as? JSON)?["ai.vela/pagination"] as? JSON)
        let last = try f.array(f.call(server,"vela_memory_list",["limit":1,"after":string(secondMeta,"nextCursor")]))
        XCTAssertEqual(last.map{string($0,"id")},["c-public"])
    }
    func testGraphemePagesKeepChineseEmojiAndRequireUnchangedContinuationHash() throws {
        let f = try Fixture(), server = f.server(); _ = try f.handshake(server)
        let content = "中👨‍👩‍👧‍👦文e\u{301}🇨🇳尾"
        var item = try f.source(extra:["content":content]); let id = string(item,"id")
        let first = try f.object(f.call(server,"vela_memory_get",["id":id,"maxCharacters":2]))
        XCTAssertEqual(string(first,"content"),"中👨‍👩‍👧‍👦"); XCTAssertEqual(intValue(first,"nextOffset"),2)
        XCTAssertEqual(string(first,"offsetUnit"),"extended_grapheme_clusters")
        let second = try f.object(f.call(server,"vela_memory_get",["id":id,"offset":2,"maxCharacters":2,"sourceHash":string(first,"sourceHash")]))
        XCTAssertEqual(string(second,"content"),"文e\u{301}")
        _ = try f.call(server,"vela_memory_get",["id":id,"offset":2],error:true)
        item["content"] = content + "更新"; _ = try f.store.put("memory",item)
        _ = try f.call(server,"vela_memory_get",["id":id,"offset":2,"sourceHash":string(first,"sourceHash")],error:true)
    }
    func testCredentialTouchingChineseTextIsSanitizedBeforePaging() throws {
        let f = try Fixture(), server = f.server(); _ = try f.handshake(server)
        let secret = "sk-abcdefghijklmnopqrstuvwx"
        let item = try f.source(extra:["content":"始👩🏽‍💻" + secret + "结束"])
        let full = try f.object(f.call(server,"vela_memory_get",["id":string(item,"id")]))
        XCTAssertEqual(string(full,"content"),"始👩🏽‍💻[REDACTED]结束")
        XCTAssertEqual(full["contentRedacted"] as? Bool,true)
        var offset = 0, joined = ""
        for _ in 0..<20 {
            let page = try f.object(f.call(server,"vela_memory_get",["id":string(item,"id"),"offset":offset,"maxCharacters":3,"sourceHash":string(full,"sourceHash")]))
            joined += string(page,"content")
            guard let next = page["nextOffset"] as? Int else { break }; offset = next
        }
        XCTAssertEqual(joined,string(full,"content")); XCTAssertFalse(joined.contains(secret))
    }
    func testMissingLinkedAndHeaderRevokedSourcesFailClosed() throws {
        let f = try Fixture(), server = f.server(); _ = try f.handshake(server)
        let deleted = try f.source(id:"deleted"), linked = try f.source(id:"linked"), privateHeader = try f.source(id:"header-private"), candidateHeader = try f.source(id:"header-candidate")
        try FileManager.default.removeItem(atPath:string(deleted,"assetPath"))
        try FileManager.default.removeItem(atPath:string(linked,"assetPath"))
        try FileManager.default.createSymbolicLink(atPath:string(linked,"assetPath"),withDestinationPath:string(privateHeader,"assetPath"))
        try f.changeHeader(privateHeader,["private":true]); try f.changeHeader(candidateHeader,["state":"candidate"])
        for id in ["deleted","linked","header-private","header-candidate"] { _ = try f.call(server,"vela_memory_get",["id":id],error:true) }
        XCTAssertTrue(try f.array(f.call(server,"vela_memory_list")).isEmpty)
    }
    func testLibraryExplicitPublicIndexAndCurrentSourceAreRechecked() throws {
        let f = try Fixture(), server = f.server(); _ = try f.handshake(server)
        let publicItem = try f.source("library",id:"public")
        _ = try f.source("library",id:"private",extra:["private":true])
        _ = try f.source("library",id:"malformed",extra:["sourceLabeledPrivate":0])
        _ = try LibraryIndex(store:f.store).handle("library.index",["project":f.project])
        let found = try f.object(f.call(server,"vela_library_search",["query":"CedarBoundary"]))
        XCTAssertEqual((found["items"] as? [JSON] ?? []).map{string($0,"id")},["public"])
        try f.changeHeader(publicItem,["private":true])
        let revoked = try f.object(f.call(server,"vela_library_search",["query":"CedarBoundary"]))
        XCTAssertTrue((revoked["items"] as? [JSON] ?? []).isEmpty)
        _ = try f.call(server,"vela_library_get",["id":"public"],error:true)
    }
    func testCandidateBulkIsAtomicAndCannotForgeObservedSourceMessage() throws {
        let f = try Fixture(), server = f.server(true); _ = try f.handshake(server)
        _ = try f.call(server,"vela_remember_bulk",["items":[["title":"First","content":"Allowed"],["title":"Second","content":"Invalid conditional scope","scope":"branch"]] as [JSON]],error:true)
        XCTAssertTrue(try f.store.list("memory").isEmpty)
        _ = try f.call(server,"vela_remember",["title":"Forged","content":"No source","sourceMessage":"missing"],error:true)
        _ = try f.source("session",id:"session-a",extra:["messages":[["id":"message-a","content":"Synthetic observed fact"]] as [JSON]])
        _ = try f.call(server,"vela_remember",["title":"Forged","content":"No source","sourceSession":"session-a","sourceMessage":"absent"],error:true)
        let made = try f.object(f.call(server,"vela_remember_bulk",["items":[["title":"First","content":"Candidate A"],["title":"Second","content":"Candidate B","sourceSession":"session-a","sourceMessage":"message-a"]] as [JSON]]))
        XCTAssertEqual(intValue(made,"created"),2); XCTAssertEqual(made["atomic"] as? Bool,true)
        let memories = try f.store.list("memory"); XCTAssertEqual(memories.count,2)
        XCTAssertTrue(memories.allSatisfy{string($0,"state") == "candidate"})
        XCTAssertTrue(try f.array(f.call(server,"vela_memory_list")).isEmpty)
    }
    func testCheckpointSignalSuggestionUseOnlyKnownLocalCoreCalls() throws {
        let f = try Fixture(), server = f.server(true); _ = try f.handshake(server)
        _ = try f.source("session",id:"observed-session",extra:["messages":[["id":"message-a"]] as [JSON]])
        let checkpoint = try f.object(f.call(server,"vela_checkpoint_save",["goal":"Synthetic checkpoint","completed":["Unit test"]]))
        XCTAssertEqual(string(checkpoint,"kind"),"checkpoint")
        let signal = try f.object(f.call(server,"vela_signal_record",["title":"Evidence","content":"Synthetic","sourceSession":"observed-session","sourceMessage":"message-a"]))
        XCTAssertEqual(string(signal,"state"),"candidate")
        let suggestion = try f.object(f.call(server,"vela_suggestion_draft",["title":"Proposal","content":"Synthetic"])); XCTAssertEqual(string(suggestion,"state"),"draft")
        XCTAssertEqual(f.coreCalls,["checkpoint.save","signals.record","suggestions.draft"])
        let saved = try f.store.get("suggestion",string(suggestion,"id"))
        XCTAssertTrue((saved?["operations"] as? [JSON] ?? []).isEmpty)
    }
    func testLocalArchiveRestoreChecksStrictNestedSchemaAndImportsCandidatesOnly() throws {
        let f = try Fixture(), server = f.server(true); _ = try f.handshake(server)
        _ = try f.source()
        let exported = try MemoryArchiveService(store:f.store).handle("memory.archive.export",["project":f.project])
        let archive = try XCTUnwrap(exported["archive"] as? JSON)
        let restored = try f.object(f.call(server,"vela_local_archive_restore",["project":f.other,"archive":archive]))
        XCTAssertEqual(intValue(restored,"imported"),1); XCTAssertEqual(string(restored,"state"),"candidate")
        let repeatResult = try f.object(f.call(server,"vela_local_archive_restore",["project":f.other,"archive":archive])); XCTAssertEqual(intValue(repeatResult,"skipped"),1)
        var invalid = archive; invalid["path"] = "/tmp/untrusted"
        _ = try f.call(server,"vela_local_archive_restore",["archive":invalid],error:true)
        let target = try f.store.list("memory",project:f.other); XCTAssertEqual(target.count,1); XCTAssertEqual(string(target[0],"state"),"candidate")
    }
    func testReadSummariesExcludeRawTranscriptsAndToolArguments() throws {
        let f = try Fixture(), server = f.server(); _ = try f.handshake(server)
        _ = try f.source("eval",extra:["content":String(repeating:"private model transcript ",count:10000),"command":["private argv"],"stdout":"not public","state":"complete"])
        _ = try f.source("artifact",extra:["origin":"setup","sourceHash":"captured-source-hash"])
        let setup = try f.array(f.call(server,"vela_setup_list")); XCTAssertEqual(string(setup[0],"sourceHash"),"captured-source-hash")
        let summaries = try f.array(f.call(server,"vela_evals_list")); XCTAssertEqual(summaries.count,1)
        XCTAssertNil(summaries[0]["content"]); XCTAssertNil(summaries[0]["stdout"]); XCTAssertNil(summaries[0]["command"])
        XCTAssertEqual(string(summaries[0],"sourceState"),"captured_metadata")
        let health = try f.object(f.call(server,"vela_health")); XCTAssertEqual(health["modelExecution"] as? Bool,false)
        XCTAssertEqual(string(health,"remoteAccountStatus"),"not_queried")
    }
}
