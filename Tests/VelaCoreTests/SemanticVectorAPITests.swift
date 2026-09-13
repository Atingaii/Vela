import Foundation
import XCTest
@testable import VelaCore

private final class QueryFixtureEmbedding: SemanticEmbeddingProvider {
    let language = "en", model = "fixture.semantic-pooling.v1", revision = 3, dimension = 2
    var calls = 0
    var values: [String:[Float]] = [:]
    func vector(_ text: String) throws -> [Float] { calls += 1; return values[text] ?? [1,0] }
}

final class SemanticVectorAPITests: XCTestCase {
    private func fixture(_ body: (URL,URL,VelaStore,QueryFixtureEmbedding,SemanticMemory) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vela-vector-api-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:root.appendingPathComponent("store"))
        _ = try FoundationService(store:store,sourceRoots:[:]).handle("projects.add",["path":project.path])
        let provider = QueryFixtureEmbedding()
        let service = SemanticMemory(store:store,providerFactory:{ _ in provider },now:{ ISO8601DateFormatter().date(from:"2026-09-13T00:00:00Z")! })
        try body(root,project,store,provider,service)
    }
    @discardableResult private func save(_ store: VelaStore, _ project: URL, _ id: String, _ fields: JSON = [:]) throws -> JSON {
        var item: JSON = ["id":id,"title":id,"content":"evidence","project":project.path,"scope":"project","state":"active","createdAt":"2020-01-01T00:00:00Z"]
        item.merge(fields) { _,value in value }; return try store.put("memory",item)
    }
    private func query(_ service: SemanticMemory, _ project: URL, _ fields: JSON = [:]) throws -> JSON {
        var params: JSON = ["project":project.path,"model":["id":"fixture.semantic-pooling.v1","language":"en","revision":3,"dimension":2],"vector":[1,0],"minSimilarity":0]
        params.merge(fields) { _,value in value }; return try service.handle("memory.semantic.query",params)
    }
    private func ids(_ result: JSON) -> [String] { (result["items"] as? [JSON] ?? []).map{string($0,"id")} }

    func testExplicitEmbedDoesNotPersistOrReadPrivateSourcesAndVectorQueryDoesNotEmbed() throws {
        try fixture { _,project,store,provider,service in
            try save(store,project,"safe")
            _ = try store.put("library",["id":"private","title":"Secret","content":"private source is not an embed input","project":project.path,"private":true])
            let result = try service.handle("memory.semantic.embed",["project":project.path,"text":"Explicit synthetic user text"])
            XCTAssertEqual(provider.calls,1); XCTAssertEqual(result["persisted"] as? Bool,false)
            XCTAssertNil(result["text"]); XCTAssertNil(result["inputHash"])
            XCTAssertEqual(try store.list("memory").count,1)
            XCTAssertNil(try store.semanticVectorMetadata(memoryID:"safe",language:"en"))
            _ = try service.handle("memory.semantic.index",["project":project.path])
            let before = provider.calls
            let response = try query(service,project,["model":result["model"]!,"vector":result["vector"]!])
            XCTAssertEqual(provider.calls,before); XCTAssertEqual(ids(response),["safe"])
            XCTAssertEqual(response["querySource"] as? String,"precomputed-vector")
            XCTAssertEqual((response["items"] as? [JSON])?.first?["retrievalSource"] as? String,"semantic")
            for extra: JSON in [["path":"/private/personal.md"],["memoryID":"safe"],["includePrivate":true],["namespace":"other"]] {
                var request: JSON = ["project":project.path,"text":"explicit"]
                request.merge(extra){_,value in value}
                XCTAssertThrowsError(try service.handle("memory.semantic.embed",request))
            }
        }
    }
    func testRecentConsidersMatchingVectorsBeyondFiftyCosineCandidates() throws {
        try fixture { _,project,store,provider,service in
            for i in 0..<60 { try save(store,project,"old-\(i)") }
            try save(store,project,"newest",["createdAt":"2026-09-12T00:00:00Z"])
            try save(store,project,"irrelevant-newest",["createdAt":"2026-09-12T23:00:00Z"])
            provider.values["newest\nevidence"] = [0.8,0.6]
            provider.values["irrelevant-newest\nevidence"] = [0,1]
            _ = try service.handle("memory.semantic.index",["project":project.path,"batchSize":100])
            let relevance = try query(service,project,["limit":1,"minSimilarity":0.7])
            XCTAssertTrue(ids(relevance).first?.hasPrefix("old-") == true)
            let newest = try service.handle("memory.semantic.recent",["project":project.path,"query":"query","limit":1,"minSimilarity":0.7])
            XCTAssertEqual(ids(newest),["newest"]); XCTAssertEqual(intValue(newest,"matchedVectors"),61)
            XCTAssertEqual(newest["limited"] as? Bool,true)
            XCTAssertEqual(ids(try query(service,project,["sort":"recent","limit":1,"minSimilarity":0.7])),["newest"])
        }
    }
    func testRecentTimestampStatesStableTiesThresholdAndBudget() throws {
        try fixture { _,project,store,provider,service in
            for id in ["a","b"] { try save(store,project,id,["createdAt":"2026-09-12T00:00:00.123Z"]) }
            try save(store,project,"nearer",["createdAt":"2026-09-12T00:00:00.123Z"])
            provider.values["a\nevidence"] = [0.8,0.6]; provider.values["b\nevidence"] = [0.8,0.6]
            try save(store,project,"old")
            try save(store,project,"future",["createdAt":"2099-01-01T00:00:00Z"])
            try save(store,project,"invalid",["createdAt":"not-a-date"])
            try save(store,project,"missing",["createdAt":""])
            _ = try service.handle("memory.semantic.index",["project":project.path])
            let result = try query(service,project,["sort":"recent"])
            XCTAssertEqual(ids(result),["nearer","a","b","old","future","invalid","missing"])
            let items = result["items"] as? [JSON] ?? []
            XCTAssertEqual(items.map{string($0,"rankingTimestampState")},["valid","valid","valid","valid","future","invalid","missing"])
            XCTAssertTrue(items.suffix(3).allSatisfy{ $0["rankingTimestamp"] is NSNull })
            XCTAssertTrue(ids(try query(service,project,["sort":"recent","budget":0])).isEmpty)
            XCTAssertEqual(ids(try query(service,project,["sort":"recent","limit":1])),["nearer"])
            XCTAssertFalse(ids(try query(service,project,["minSimilarity":0.9])).contains("a"))
        }
    }
    func testVectorQueriesKeepNamespacePrivateLifecycleAndSourceFreshness() throws {
        try fixture { root,project,store,provider,service in
            let active = try save(store,project,"a",["scope":"namespace","namespace":"main"])
            try save(store,project,"b",["scope":"namespace","namespace":"other"])
            try save(store,project,"plain")
            try save(store,project,"private",["scope":"namespace","namespace":"main","private":true])
            try save(store,project,"private-path",["scope":"namespace","namespace":"main","sourceFile":"/example/private/secret.md"])
            try save(store,project,"malformed-private",["scope":"namespace","namespace":"main","private":"false"])
            try save(store,project,"candidate",["scope":"namespace","namespace":"main","state":"candidate"])
            try save(store,project,"archived",["scope":"namespace","namespace":"main","state":"archived"])
            try save(store,root.appendingPathComponent("other"),"other-project")
            _ = try service.handle("memory.semantic.index",["project":project.path])
            let response = try query(service,project,["namespace":"main"])
            XCTAssertEqual(ids(response),["a"])
            XCTAssertEqual(intValue(response["indexCoverage"] as? JSON ?? [:],"eligible"),1)
            XCTAssertTrue(response["scopeExcluded"] is NSNull)
            let reopened = SemanticMemory(store:try VelaStore(root:store.root),providerFactory:{_ in provider})
            XCTAssertEqual(ids(try query(reopened,project)),["plain"])
            let path = URL(fileURLWithPath:string(active,"assetPath"))
            let source = try String(contentsOf:path,encoding:.utf8)
            try Data(source.replacingOccurrences(of:"evidence",with:"human changed content").utf8).write(to:path)
            let changed = try query(service,project,["namespace":"main"])
            XCTAssertTrue(ids(changed).isEmpty); XCTAssertEqual(intValue(changed,"staleVectorsExcluded"),1)
            XCTAssertEqual(changed["indexIncomplete"] as? Bool,true)
        }
    }
    func testStrictIdentityVectorAndScopeFieldsRejectBeforeEmbeddingOrWriting() throws {
        try fixture { _,project,store,provider,service in
            try save(store,project,"a"); _ = try service.handle("memory.semantic.index",["project":project.path])
            let before = provider.calls
            for bad: JSON in [["vector":[0,0]],["vector":[1]],["vector":[true,0]],["vector":[Double.nan,0]],["vector":[Double.infinity,0]],["vector":[Double.greatestFiniteMagnitude,0]],["vector":["1",0]],["namespace":true],["namespace":""],["namespace":"main","branch":"branch"],["includePrivate":true],["sort":"recent","scoringWeights":["semantic":1]],["sort":"other"],["now":"2099-01-01"]] {
                XCTAssertThrowsError(try query(service,project,bad))
            }
            let identity: JSON = ["id":"fixture.semantic-pooling.v1","language":"en","revision":3,"dimension":2]
            for changes: JSON in [["id":"same-dimension-other-pooling"],["revision":4],["dimension":3],["revision":true],["language":"zh-Hans"],["unknown":1]] {
                var model = identity; model.merge(changes){_,value in value}
                XCTAssertThrowsError(try query(service,project,["model":model]))
            }
            XCTAssertEqual(provider.calls,before)
            XCTAssertEqual(try store.list("memory").count,1)
        }
    }
    func testUnavailableModelsAndExplicitInputSizeNeverDownloadOrStore() throws {
        try fixture { root,project,store,_,service in
            for text in ["",String(repeating:" ",count:20),String(repeating:"中",count:21846)] {
                XCTAssertThrowsError(try service.handle("memory.semantic.embed",["project":project.path,"text":text]))
            }
            let exact = try service.handle("memory.semantic.embed",["project":project.path,"text":String(repeating:"x",count:65536)])
            XCTAssertEqual(intValue(exact,"inputBytes"),65536)
            XCTAssertThrowsError(try service.handle("memory.semantic.embed",["project":root.path,"text":"text"]))
            let unavailable = SemanticMemory(store:store,providerFactory:{ _ in nil })
            for (method,extra): (String,JSON) in [("memory.semantic.embed",["text":"text"]),("memory.semantic.recent",["query":"query"])] {
                var input = extra; input["project"] = project.path
                let result = try unavailable.handle(method,input)
                XCTAssertEqual(result["status"] as? String,"unavailable"); XCTAssertEqual(result["downloadRequested"] as? Bool,false)
                XCTAssertNil(result["vector"])
            }
            XCTAssertEqual(try query(unavailable,project)["status"] as? String,"unavailable")
            XCTAssertTrue(try store.list("memory").isEmpty)
        }
    }
    func testActualAppleEmbedQueryAndRecentEnglishAndChineseWhenInstalled() throws {
        try fixture { _,project,store,_,_ in
            let service = SemanticMemory(store:store)
            for (language,text) in [("en","The automobile requires maintenance."),("zh-Hans","项目约束需要在下一次会话中保留。") ] {
                let embedded = try service.handle("memory.semantic.embed",["project":project.path,"language":language,"text":text])
                guard string(embedded,"status") == "ok" else {
                    XCTAssertEqual(embedded["downloadRequested"] as? Bool,false); XCTAssertNil(embedded["vector"]); continue
                }
                try save(store,project,language,["title":"","content":text])
                _ = try service.handle("memory.semantic.index",["project":project.path,"language":language])
                let result = try service.handle("memory.semantic.query",["project":project.path,"model":embedded["model"]!,"vector":embedded["vector"]!,"minSimilarity":0.99])
                XCTAssertTrue(ids(result).contains(language))
                let recent = try service.handle("memory.semantic.recent",["project":project.path,"language":language,"query":text,"minSimilarity":0.99])
                XCTAssertTrue(ids(recent).contains(language))
            }
        }
    }
}
