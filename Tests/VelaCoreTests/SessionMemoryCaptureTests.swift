import XCTest
import Foundation
@testable import VelaCore

final class SessionMemoryCaptureTests: XCTestCase {
    private func fixture(_ body: (URL, URL, VelaStore, FoundationService) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vela-session-memory-capture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project"), other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: project,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at: other,withIntermediateDirectories:true)
        let store = try VelaStore(root:root.appendingPathComponent("store"))
        let service = FoundationService(store:store,sourceRoots:[:],globalHome:root.appendingPathComponent("home"))
        _ = try service.handle("projects.add",["path":project.path])
        _ = try service.handle("projects.add",["path":other.path])
        try body(project,other,store,service)
    }

    private func session(_ project: URL, id: String = "session-1", source: String = "thread-1", messages: [JSON] = [["id":"message-1","role":"assistant","content":"Use SQLite WAL for local persistence."]], extra: JSON = [:]) -> JSON {
        var value: JSON = ["id":id,"project":project.path,"provider":"codex","sourceSessionId":source,"sourcePath":project.appendingPathComponent("logs/session.jsonl").path,"scope":"project","messages":messages]
        value.merge(extra) { _,new in new }; return value
    }

    private func object(_ service: FoundationService, _ method: String, _ params: JSON) throws -> JSON {
        try XCTUnwrap(try service.handle(method,params) as? JSON)
    }

    private func prepare(_ service: FoundationService, _ project: URL, sessionID: String = "session-1", messageID: String = "message-1") throws -> JSON {
        try object(service,"memory.capture.prepare",["project":project.path,"sessionId":sessionID,"messageId":messageID])
    }

    func testObservedSessionMessageProducesCandidateAndExactReplayIsIdempotent() throws {
        try fixture { project,_,store,service in
            _ = try store.put("session",session(project))
            let prepared = try prepare(service,project)
            XCTAssertEqual(string(prepared,"protocol"),"vela-session-memory-capture-v1")
            XCTAssertEqual(string(prepared,"sourceIdentity"),"codex:thread-1")
            XCTAssertEqual(string(prepared,"state"),"candidate")
            XCTAssertEqual(string(prepared,"sourceObservation"),"observed")
            let request: JSON = ["project":project.path,"sessionId":"session-1","messageId":"message-1","sourceIdentity":prepared["sourceIdentity"]!,"expectedSourceHash":prepared["expectedSourceHash"]!]
            let first = try object(service,"memory.capture",request)
            XCTAssertEqual(first["created"] as? Bool,true); XCTAssertEqual(string(first,"state"),"candidate")
            XCTAssertEqual(string(first,"type"),"observation"); XCTAssertEqual(first["requiresReview"] as? Bool,true); XCTAssertEqual(intValue(first,"modelCalls"),0)
            let provenance = try XCTUnwrap(first["provenance"] as? JSON)
            XCTAssertEqual(string(provenance,"origin"),"observed_session_capture")
            XCTAssertEqual(string(provenance,"sourceObservation"),"observed")
            XCTAssertEqual(string(provenance,"sourceHash"),string(prepared,"expectedSourceHash"))
            XCTAssertTrue(((try object(service,"recall",["project":project.path,"query":"SQLite"]))["items"] as? [JSON] ?? []).isEmpty)
            let replay = try object(service,"memory.capture",request)
            XCTAssertEqual(replay["created"] as? Bool,false); XCTAssertEqual(replay["idempotent"] as? Bool,true); XCTAssertEqual(string(replay,"id"),string(first,"id"))
            XCTAssertEqual(try store.list("memory",project:project.path).count,1)
        }
    }

    func testCrossProjectPrivateInternalMalformedAndAmbiguousMessagesNeverWrite() throws {
        try fixture { project,other,store,service in
            let rejected: [(String,JSON,JSON)] = [
                ("foreign",session(other,id:"foreign"),["project":project.path,"sessionId":"foreign","messageId":"message-1"]),
                ("private",session(project,id:"private",extra:["private":true]),["project":project.path,"sessionId":"private","messageId":"message-1"]),
                ("labeled",session(project,id:"labeled",extra:["sourceLabeledPrivate":true]),["project":project.path,"sessionId":"labeled","messageId":"message-1"]),
                ("malformed-private",session(project,id:"malformed-private",extra:["private":"false"]),["project":project.path,"sessionId":"malformed-private","messageId":"message-1"]),
                ("internal",session(project,id:"internal",extra:["internalRun":true]),["project":project.path,"sessionId":"internal","messageId":"message-1"]),
                ("control-source-identity",session(project,id:"control-source-identity",source:"thread\u{001b}bad"),["project":project.path,"sessionId":"control-source-identity","messageId":"message-1"]),
                ("overlong-source-identity",session(project,id:"overlong-source-identity",source:String(repeating:"x",count:1025)),["project":project.path,"sessionId":"overlong-source-identity","messageId":"message-1"]),
                ("ambiguous",session(project,id:"ambiguous",messages:[["id":"message-1","role":"assistant","content":"a"],["id":"message-1","role":"assistant","content":"b"]]),["project":project.path,"sessionId":"ambiguous","messageId":"message-1"]),
                ("tool",session(project,id:"tool",messages:[["id":"message-1","role":"tool","content":"secret-shaped tool output"]]),["project":project.path,"sessionId":"tool","messageId":"message-1"]),
                ("oversized",session(project,id:"oversized",messages:[["id":"message-1","role":"assistant","content":String(repeating:"界",count:16385)]]),["project":project.path,"sessionId":"oversized","messageId":"message-1"])
            ]
            for (_,item,request) in rejected { _ = try store.put("session",item); XCTAssertThrowsError(try service.handle("memory.capture.prepare",request)) }
            XCTAssertEqual(try store.list("memory").count,0)
        }
    }

    func testStaleHashAndChangedIdentityRefuseOverwrite() throws {
        try fixture { project,_,store,service in
            let original = try store.put("session",session(project))
            let prepared = try prepare(service,project)
            let request: JSON = ["project":project.path,"sessionId":"session-1","messageId":"message-1","sourceIdentity":prepared["sourceIdentity"]!,"expectedSourceHash":prepared["expectedSourceHash"]!]
            _ = try object(service,"memory.capture",request)
            var changed = original; changed["messages"] = [["id":"message-1","role":"assistant","content":"Use PostgreSQL for the revised project."]]
            _ = try store.put("session",changed)
            XCTAssertThrowsError(try service.handle("memory.capture",request))
            let fresh = try prepare(service,project)
            let changedRequest: JSON = ["project":project.path,"sessionId":"session-1","messageId":"message-1","sourceIdentity":fresh["sourceIdentity"]!,"expectedSourceHash":fresh["expectedSourceHash"]!]
            XCTAssertThrowsError(try service.handle("memory.capture",changedRequest))
            XCTAssertEqual(try store.list("memory",project:project.path).count,1)
        }
    }

    func testOrdinarySaveCannotForgeOrEraseCaptureProvenanceAndLabelsUserDerivation() throws {
        try fixture { project,_,store,service in
            _ = try store.put("session",session(project))
            let prepared = try prepare(service,project)
            let created = try object(service,"memory.capture",["project":project.path,"sessionId":"session-1","messageId":"message-1","sourceIdentity":prepared["sourceIdentity"]!,"expectedSourceHash":prepared["expectedSourceHash"]!])
            let id = string(created,"id")
            XCTAssertThrowsError(try service.handle("memory.save",["id":id,"project":project.path,"title":"Forged","content":"Use SQLite WAL for local persistence.","provenance":["origin":"user"]]))
            XCTAssertThrowsError(try service.handle("memory.save",["id":id,"project":project.path,"title":"Forged","content":"Use SQLite WAL for local persistence.","sourceHash":"forged"]))
            XCTAssertThrowsError(try service.handle("memory.save",["id":id,"project":project.path,"title":"Forged","content":"Use SQLite WAL for local persistence.","sourceSession":"forged-session"]))
            let unchangedSource = try object(service,"memory.save",["id":id,"project":project.path,"title":"Observed assistant message","content":"Use SQLite WAL for local persistence.","sourceSession":created["sourceSession"]!,"sourceMessage":created["sourceMessage"]!])
            XCTAssertEqual((try XCTUnwrap(unchangedSource["provenance"] as? JSON))["contentEqualsObservedSource"] as? Bool,true)
            let edited = try object(service,"memory.save",["id":id,"project":project.path,"title":"Observed assistant message","content":"Human explanation of the SQLite choice."])
            let provenance = try XCTUnwrap(edited["provenance"] as? JSON)
            XCTAssertEqual(string(provenance,"origin"),"observed_session_capture")
            XCTAssertEqual(provenance["contentEqualsObservedSource"] as? Bool,false)
            XCTAssertEqual(string(provenance,"derivedBy"),"user_edit")
            XCTAssertEqual(edited["derivedFromCapture"] as? Bool,true)
        }
    }

    func testUnrelatedSessionAppendPreservesPreparedCaptureAndExistingLifecycle() throws {
        try fixture { project,_,store,service in
            let original = try store.put("session",session(project))
            let prepared = try prepare(service,project)
            let request: JSON = ["project":project.path,"sessionId":"session-1","messageId":"message-1","sourceIdentity":prepared["sourceIdentity"]!,"expectedSourceHash":prepared["expectedSourceHash"]!]
            var appended = original
            appended["messages"] = (original["messages"] as? [JSON] ?? []) + [["id":"later-message","role":"assistant","content":"An unrelated later observation."]]
            _ = try store.put("session",appended)
            let created = try object(service,"memory.capture",request)
            XCTAssertEqual(created["created"] as? Bool,true)
            let id = string(created,"id")
            _ = try object(service,"memory.transition",["id":id,"state":"active"])
            let replay = try object(service,"memory.capture",request)
            XCTAssertEqual(replay["created"] as? Bool,false)
            XCTAssertEqual(string(replay,"state"),"active")
            XCTAssertEqual(replay["requiresReview"] as? Bool,true)
            let edited = try object(service,"memory.save",["id":id,"project":project.path,"title":"Edited","content":"A human derived summary."])
            let replayEdited = try object(service,"memory.capture",request)
            XCTAssertEqual(string(replayEdited,"content"),string(edited,"content"))
            XCTAssertEqual(string(replayEdited,"state"),"active")
            XCTAssertEqual((try XCTUnwrap(replayEdited["provenance"] as? JSON))["contentEqualsObservedSource"] as? Bool,false)
        }
    }

    func testCaptureRejectsCallerContentTitleAndUnregisteredProject() throws {
        try fixture { project,_,store,service in
            _ = try store.put("session",session(project))
            let prepared = try prepare(service,project)
            var request: JSON = ["project":project.path,"sessionId":"session-1","messageId":"message-1","sourceIdentity":prepared["sourceIdentity"]!,"expectedSourceHash":prepared["expectedSourceHash"]!]
            request["content"] = "caller supplied"; XCTAssertThrowsError(try service.handle("memory.capture",request))
            request.removeValue(forKey:"content"); request["title"] = "caller supplied"; XCTAssertThrowsError(try service.handle("memory.capture",request))
            XCTAssertThrowsError(try service.handle("memory.capture.prepare",["project":project.deletingLastPathComponent().appendingPathComponent("unregistered").path,"sessionId":"session-1","messageId":"message-1"]))
            XCTAssertEqual(try store.list("memory").count,0)
        }
    }
}
