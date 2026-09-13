import Foundation
import XCTest
@testable import VelaCore

final class MemoryIntegrationTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,MemoryIntegrationService) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vela-integration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:root.appendingPathComponent("store"))
        _ = try FoundationService(store:store,sourceRoots:[:]).handle("projects.add",["path":project.path])
        try body(project,store,MemoryIntegrationService(store:store))
    }
    func testCaptureRequiresReviewAndIsIdempotentAfterReview() throws {
        try fixture { project,store,service in
            let args: JSON = ["project":project.path,"namespace":"researcher","integration":"openclaw","sourceID":"run-1","records":[["id":"1","role":"user","content":"We prefer SQLite for offline project persistence."]]]
            let first = try service.handle("memory.integration.capture",args)
            let id = try XCTUnwrap((first["ids"] as? [String])?.first)
            XCTAssertEqual(intValue(first,"created"),1)
            let query: JSON = ["project":project.path,"namespace":"researcher","query":"SQLite"]
            XCTAssertTrue((try service.handle("memory.integration.recall",query)["items"] as? [JSON])?.isEmpty == true)
            var item = try XCTUnwrap(store.get("memory",id));item["state"] = "active";_ = try store.put("memory",item)
            XCTAssertEqual(intValue(try service.handle("memory.integration.capture",args),"skipped"),1)
            XCTAssertEqual(string(try XCTUnwrap(store.get("memory",id)),"state"),"active")
            XCTAssertEqual((try service.handle("memory.integration.recall",query)["items"] as? [JSON])?.count,1)
            XCTAssertTrue((try MemoryService(store:store).recall(["project":project.path,"query":"SQLite"])["items"] as? [JSON])?.isEmpty == true)
            XCTAssertTrue((try service.handle("memory.integration.recall",["project":project.path,"namespace":"main","query":"SQLite"])["items"] as? [JSON])?.isEmpty == true)
        }
    }
    func testNamespaceNeverInheritsProjectGlobalPrivateOrOtherAgent() throws {
        try fixture { project,store,service in
            for (id,fields): (String,JSON) in [("correct",["namespace":"main"]),("other",["namespace":"other"]),("project",["scope":"project"]),("global",["scope":"global","project":""]),("private",["namespace":"main","private":true]),("malformed",["namespace":"main","private":"false"]),("privatepath",["namespace":"main","sourceFile":"/private/personal.md"])] {
                var item: JSON = ["id":id,"title":"SQLite","content":"SQLite persistence","state":"active","project":project.path,"scope":"namespace"]
                item.merge(fields) { _,new in new };_ = try store.put("memory",item)
            }
            let items = try service.handle("memory.integration.recall",["project":project.path,"namespace":"main","query":"SQLite"])["items"] as? [JSON]
            XCTAssertEqual(items?.map{string($0,"id")},["correct"])
            let stats = try service.handle("memory.integration.stats",["project":project.path,"namespace":"main"])
            XCTAssertEqual(intValue(stats,"observedRecords"),1)
        }
    }
    func testUnregisteredUnknownFieldsAndCredentialBatchFailWithoutPartialWrite() throws {
        try fixture { project,store,service in
            let good: JSON = ["id":"1","role":"user","content":"An ordinary observation for later review."]
            let bad: JSON = ["id":"2","role":"user","content":"api_key=sk-abcdefghijklmnopqrstuvxyz"]
            let args: JSON = ["project":project.path,"namespace":"main","integration":"openclaw","sourceID":"run","records":[good,bad]]
            XCTAssertThrowsError(try service.handle("memory.integration.capture",args))
            XCTAssertEqual(try store.list("memory").count,0)
            XCTAssertThrowsError(try service.handle("memory.integration.recall",["project":project.path,"namespace":"main","query":"text","agent":"other"]))
            XCTAssertThrowsError(try service.handle("memory.integration.stats",["project":project.deletingLastPathComponent().path,"namespace":"main"]))
            XCTAssertThrowsError(try service.handle("memory.integration.stats",["project":project.path,"namespace":"main\nother"]))
        }
    }
    func testDirectIntegrationRecallEnforcesLimitWithoutPretendingLexicalCosine() throws {
        try fixture { project,store,service in
            for id in ["a","b","c"] { _ = try store.put("memory",["id":id,"title":"SQLite","content":"SQLite local storage","scope":"namespace","namespace":"main","state":"active","project":project.path]) }
            let params: JSON = ["project":project.path,"namespace":"main","query":"SQLite","limit":1]
            let result = try service.handle("memory.integration.recall",params)
            let items = try XCTUnwrap(result["items"] as? [JSON]);XCTAssertEqual(items.count,1);XCTAssertEqual(result["truncated"] as? Bool,true)
            XCTAssertEqual(intValue(result,"usedTokens"),intValue(items[0],"recallTokens"));XCTAssertNil(items[0]["cosineSimilarity"])
            for invalid: Any in [0,51,1.5,true,"1"] { var changed = params;changed["limit"] = invalid;XCTAssertThrowsError(try service.handle("memory.integration.recall",changed)) }
        }
    }
}
