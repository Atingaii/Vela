import Foundation
import XCTest
@testable import VelaCore

private struct FixtureEmbedding: SemanticEmbeddingProvider {
    let language = "en", model = "fixture.algorithm-vectors"
    var revision = 1
    let dimension = 2
    var vectors: [String:[Float]] = [:]
    func vector(_ text: String) throws -> [Float] { vectors[text] ?? [1,0] }
}

final class SemanticMemoryTests: XCTestCase {
    func testNamespaceVectorsRemainIsolatedAndNamespaceMutationInvalidatesHash() throws {
        try fixture { _,project,store in
            try save(store,project,"a",fields:["scope":"namespace","namespace":"main"])
            try save(store,project,"b",fields:["scope":"namespace","namespace":"other"])
            try save(store,project,"c")
            let semantic = service(store)
            _ = try semantic.handle("memory.semantic.index",["project":project.path])
            XCTAssertEqual((try recall(semantic,project:project,extra:["namespace":"main"])["items"] as? [JSON])?.map{string($0,"id")},["a"])
            XCTAssertEqual((try recall(semantic,project:project)["items"] as? [JSON])?.map{string($0,"id")},["c"])
            var item = try XCTUnwrap(store.get("memory","a"));item["namespace"] = "other";_ = try store.put("memory",item)
            XCTAssertEqual((try recall(semantic,project:project,extra:["namespace":"other"])["items"] as? [JSON])?.map{string($0,"id")},["b"])
        }
    }
    private func fixture(_ body: (URL, URL, VelaStore) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-semantic-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let project = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try FoundationService(store:store,sourceRoots:[:]).handle("projects.add",["path":project.path])
        try body(temporary,project,store)
    }
    @discardableResult private func save(_ store: VelaStore, _ project: URL, _ id: String, fields: JSON = [:]) throws -> JSON {
        var item: JSON = ["id":id,"title":id,"content":"original evidence","project":canonicalProject(project.path),"scope":"project","state":"active","type":"fact"]
        item.merge(fields) { _,new in new }; return try store.put("memory",item)
    }
    private func service(_ store: VelaStore, provider: FixtureEmbedding = FixtureEmbedding()) -> SemanticMemory {
        SemanticMemory(store:store,providerFactory:{ _ in provider })
    }
    private func recall(_ service: SemanticMemory, project: URL, extra: JSON = [:]) throws -> JSON {
        var params: JSON = ["project":project.path,"retrievalMode":"semantic","query":"query","language":"en","minSimilarity":0]
        params.merge(extra) { _,new in new }
        return try service.recall(params) { ["items":[]] }
    }

    func testVectorMathRejectsInvalidValuesAndDimensions() throws {
        XCTAssertEqual(try SemanticVectorMath.cosine([1,0],[0,1]),0)
        XCTAssertGreaterThan(try SemanticVectorMath.cosine([2,0],[1,0]),0.9999)
        for vector: [Float] in [[],[0,0],[.nan,1],[.infinity,1]] {
            XCTAssertThrowsError(try SemanticVectorMath.normalized(vector))
        }
        XCTAssertThrowsError(try SemanticVectorMath.cosine([1,0],[1]))
    }

    func testIndexPagesResumeAndReopenWithoutDuplicateVectors() throws {
        try fixture { _,project,store in
            for id in ["a","b","c","d","e"] { try save(store,project,id) }
            let semantic = service(store)
            var cursor: String?, indexed = 0, pages = 0
            repeat {
                var params: JSON = ["project":project.path,"language":"en","batchSize":2]
                if let cursor { params["cursor"] = cursor }
                let page = try semantic.handle("memory.semantic.index",params)
                XCTAssertLessThanOrEqual(intValue(page,"processed"),2)
                indexed += intValue(page,"indexed"); pages += 1; cursor = page["nextCursor"] as? String
            } while cursor != nil
            XCTAssertEqual(indexed,5); XCTAssertEqual(pages,3)
            let reopened = try VelaStore(root:store.root), next = service(try VelaStore(root:store.root))
            let status = try next.handle("memory.semantic.status",["project":project.path,"language":"en"])
            XCTAssertEqual(intValue(status,"indexed"),5); XCTAssertEqual(status["indexIncomplete"] as? Bool,false)
            let again = try next.handle("memory.semantic.index",["project":project.path])
            XCTAssertEqual(intValue(again,"indexed"),0); XCTAssertEqual(intValue(again,"unchanged"),5)
            var vectors = 0
            try reopened.forEachSemanticVector(project:canonicalProject(project.path),language:"en") { row in
                vectors += 1; XCTAssertEqual(row.vector,[1,0]); XCTAssertEqual(row.dimension,2)
            }
            XCTAssertEqual(vectors,5)
        }
    }

    func testProjectScopeLifecycleAndPrivateMemoryCannotReachSemanticRecall() throws {
        try fixture { temporary,project,store in
            try save(store,project,"project")
            try save(store,project,"global",fields:["project":"","scope":"global"])
            try save(store,project,"private",fields:["private":true])
            try save(store,project,"private-source",fields:["sourceFile":"/example/private/personal.md"])
            try save(store,project,"malformed-private",fields:["private":"false"])
            try save(store,project,"candidate",fields:["state":"candidate"])
            try save(store,project,"branch",fields:["scope":"branch","branch":"expected"])
            try save(store,project,"wrong-branch",fields:["scope":"branch","branch":"other"])
            try save(store,project,"task",fields:["scope":"task","task":"only-task"])
            try save(store,project,"session",fields:["scope":"session","sourceSession":"only-session"])
            try save(store,temporary.appendingPathComponent("other"),"other-project")
            _ = try store.put("library",["id":"private-library","title":"Secret","content":"Never index","private":true,"project":project.path])
            let semantic = service(store)
            _ = try semantic.handle("memory.semantic.index",["project":project.path])
            let result = try recall(semantic,project:project,extra:["branch":"expected"])
            XCTAssertEqual(Set((result["items"] as? [JSON] ?? []).map { string($0,"id") }),Set(["project","global","branch"]))
            var memory = try XCTUnwrap(store.get("memory","project")); memory["private"] = true
            _ = try store.put("memory",memory)
            XCTAssertNil(try store.semanticVectorMetadata(memoryID:"project",language:"en"))
            XCTAssertFalse((try recall(semantic,project:project)["items"] as? [JSON] ?? []).contains { string($0,"id") == "project" })
        }
    }

    func testHumanEditedContentExcludesStaleVectorUntilReindexed() throws {
        try fixture { _,project,store in
            let memory = try save(store,project,"changed")
            let semantic = service(store); _ = try semantic.handle("memory.semantic.index",["project":project.path])
            let asset = URL(fileURLWithPath:string(memory,"assetPath"))
            let old = try String(contentsOf:asset,encoding:.utf8)
            try Data(old.replacingOccurrences(of:"original evidence",with:"manually changed evidence").utf8).write(to:asset)
            let stale = try recall(semantic,project:project)
            XCTAssertTrue((stale["items"] as? [JSON])?.isEmpty == true)
            XCTAssertEqual(intValue(stale,"staleVectorsExcluded"),1)
            XCTAssertEqual(stale["indexIncomplete"] as? Bool,true)
            _ = try semantic.handle("memory.semantic.index",["project":project.path])
            XCTAssertEqual((try recall(semantic,project:project)["items"] as? [JSON])?.first?["content"] as? String,"manually changed evidence")
            try store.remove("memory","changed")
            XCTAssertNil(try store.semanticVectorMetadata(memoryID:"changed",language:"en"))
        }
    }

    func testModelRevisionAndCursorCannotCrossProjectOrLanguage() throws {
        try fixture { temporary,project,store in
            try save(store,project,"a"); try save(store,project,"b")
            let first = service(store)
            let page = try first.handle("memory.semantic.index",["project":project.path,"batchSize":1])
            let cursor = try XCTUnwrap(page["nextCursor"] as? String)
            var forged = try JSONSerialization.jsonObject(with:Data(base64Encoded:cursor)!) as! JSON
            forged["revision"] = true
            XCTAssertThrowsError(try first.handle("memory.semantic.index",["project":project.path,"cursor":Data(try jsonString(forged).utf8).base64EncodedString()]))
            let revised = service(store,provider:FixtureEmbedding(revision:2))
            XCTAssertThrowsError(try revised.handle("memory.semantic.index",["project":project.path,"cursor":cursor]))
            let result = try recall(revised,project:project)
            XCTAssertTrue((result["items"] as? [JSON])?.isEmpty == true)
            XCTAssertEqual(intValue(result,"staleVectorsExcluded"),1)
            let other = temporary.appendingPathComponent("other"); try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
            _ = try FoundationService(store:store,sourceRoots:[:]).handle("projects.add",["path":other.path])
            XCTAssertThrowsError(try first.handle("memory.semantic.index",["project":other.path,"cursor":cursor]))
            XCTAssertThrowsError(try first.handle("memory.semantic.index",["project":project.path,"language":"zh-Hans","cursor":cursor]))
        }
    }

    func testMissingModelIsUnavailableOrExplicitLexicalFallback() throws {
        try fixture { _,project,store in
            let row = try save(store,project,"fallback")
            let unavailable = SemanticMemory(store:store,providerFactory:{ _ in nil })
            let status = try unavailable.handle("memory.semantic.index",["project":project.path])
            XCTAssertEqual(status["status"] as? String,"unavailable"); XCTAssertEqual(status["downloadRequested"] as? Bool,false)
            XCTAssertEqual(try recall(unavailable,project:project)["status"] as? String,"unavailable")
            let hybrid = try unavailable.recall(["project":project.path,"query":"original","retrievalMode":"hybrid"]) { ["items":[row]] }
            XCTAssertEqual(hybrid["retrievalMode"] as? String,"lexical")
            XCTAssertEqual(hybrid["requestedRetrievalMode"] as? String,"hybrid")
            XCTAssertEqual((hybrid["items"] as? [JSON])?.count,1)
            XCTAssertNotNil(hybrid["fallbackReason"])
        }
    }

    func testThresholdBudgetAndExplicitRecencyImportanceRanking() throws {
        try fixture { _,project,store in
            try save(store,project,"old",fields:["createdAt":"2020-01-01T00:00:00Z","importance":0.9])
            try save(store,project,"fresh",fields:["createdAt":"2026-09-12T00:00:00Z","importance":0.1])
            let provider = FixtureEmbedding(vectors:["fresh\noriginal evidence":[0.8,0.6]])
            let semantic = SemanticMemory(store:store,providerFactory:{ _ in provider },now:{ ISO8601DateFormatter().date(from:"2026-09-13T00:00:00Z")! })
            _ = try semantic.handle("memory.semantic.index",["project":project.path])
            XCTAssertEqual((try recall(semantic,project:project)["items"] as? [JSON])?.first?["id"] as? String,"old")
            let recent = try recall(semantic,project:project,extra:["scoringWeights":["semantic":1,"recency":2]])
            XCTAssertEqual((recent["items"] as? [JSON])?.first?["id"] as? String,"fresh")
            let important = try recall(semantic,project:project,extra:["scoringWeights":["semantic":0,"importance":1]])
            XCTAssertEqual((important["items"] as? [JSON])?.first?["id"] as? String,"old")
            XCTAssertEqual((try recall(semantic,project:project,extra:["minSimilarity":0.95])["items"] as? [JSON])?.count,1)
            XCTAssertTrue((try recall(semantic,project:project,extra:["budget":0])["items"] as? [JSON])?.isEmpty == true)
            let limited = try recall(semantic,project:project,extra:["limit":1])
            XCTAssertEqual(limited["limited"] as? Bool,true); XCTAssertEqual(limited["truncated"] as? Bool,true)
            for bad: JSON in [["limit":true],["limit":0],["minSimilarity":Double.nan],["scoringWeights":["importance":-1]],["scoringWeights":["semantic":0]],["scoringWeights":["unknown":1]]] {
                XCTAssertThrowsError(try recall(semantic,project:project,extra:bad))
            }
        }
    }

    func testStoreRefusesWrongDimensionsZeroVectorsAndChangedSources() throws {
        try fixture { _,project,store in
            let memory = try save(store,project,"source"), hash = try SemanticMemory.sourceHash(try XCTUnwrap(store.get("memory","source")))
            for vector: [Float] in [[0,0],[.nan,0],[1]] {
                XCTAssertThrowsError(try store.putSemanticVector(SemanticVectorRecord(memoryID:"source",project:canonicalProject(project.path),language:"en",model:"fixture",revision:1,dimension:2,sourceHash:hash,vector:vector)))
            }
            var changed = memory; changed["content"] = "Changed during embedding"; _ = try store.put("memory",changed)
            XCTAssertThrowsError(try store.putSemanticVector(SemanticVectorRecord(memoryID:"source",project:canonicalProject(project.path),language:"en",model:"fixture",revision:1,dimension:2,sourceHash:hash,vector:[1,0])))
            XCTAssertNil(try store.semanticVectorMetadata(memoryID:"source",language:"en"))
        }
    }

    func testInstalledAppleEmbeddingsRankActualSynonymsWhenAvailable() throws {
        // This exercises a real installed model; the other tests intentionally use fixed algorithm vectors.
        // No download is requested. Hosts without the optional asset verify the unavailable branch instead.
        guard let provider = AppleSemanticEmbedding(language:"en") else {
            XCTAssertNil(AppleSemanticEmbedding(language:"en")); return
        }
        let query = try provider.vector("The vehicle needs repair.")
        let synonym = try provider.vector("The automobile requires maintenance.")
        let unrelated = try provider.vector("Bake a chocolate cake for the birthday party.")
        XCTAssertEqual(query.count,provider.dimension)
        XCTAssertGreaterThan(try SemanticVectorMath.cosine(query,synonym),try SemanticVectorMath.cosine(query,unrelated))
        XCTAssertGreaterThan(provider.revision,0)
        if let chinese = AppleSemanticEmbedding(language:"zh-Hans") {
            let vector = try chinese.vector("项目约束需要在下一次会话中保留。")
            XCTAssertEqual(vector.count,chinese.dimension)
            XCTAssertNoThrow(try SemanticVectorMath.normalized(vector))
        }
    }
}
