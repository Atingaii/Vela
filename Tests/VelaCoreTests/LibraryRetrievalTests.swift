import Foundation
import XCTest
@testable import VelaCore

final class LibraryRetrievalTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,LibraryIndex,String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-library-fts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let project = directory.appendingPathComponent("project"); try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:directory.appendingPathComponent("store"))
        try body(directory,store,LibraryIndex(store:store),canonicalProject(project.path))
    }
    @discardableResult private func save(_ store: VelaStore,_ project: String,_ id: String,_ content: String, fields: JSON = [:]) throws -> JSON {
        var item: JSON = ["id":id,"title":id,"content":content,"project":project,"private":false,"state":"active"]
        item.merge(fields) { _,new in new }; return try store.put("library",item)
    }
    private func search(_ index: LibraryIndex,_ project: String,_ query: String, extra: JSON = [:]) throws -> [JSON] {
        var params: JSON = ["project":project,"query":query]; params.merge(extra) { _,new in new }
        let valueToUnwrap = try index.handle("library.search",params)["items"] as? [JSON]
        return try XCTUnwrap(valueToUnwrap)
    }
    func testUnicodeAccentsCJKAndLiteralQuerySyntaxReturnRealParagraphs() throws {
        try fixture { _,store,index,project in
            let content = "## Café\n\nRésumé validation preserves naïve user input.\n\n## 发布\n\n部署失败需要回滚数据库迁移。"
            try save(store,project,"unicode",content)
            _ = try index.handle("library.index",["project":project])
            for query in ["resume naive","部署失败","回滚","部"] {
                let hits = try search(index,project,query)
                XCTAssertFalse(hits.isEmpty,query)
                for hit in hits {
                    XCTAssertTrue(content.contains(string(hit,"content")))
                    let range = try XCTUnwrap(hit["rangeUTF16"] as? JSON)
                    XCTAssertEqual((content as NSString).substring(with:NSRange(location:intValue(range,"location"),length:intValue(range,"length"))),string(hit,"content"))
                }
            }
            XCTAssertEqual(try search(index,project,"\" OR * NOT NEAR(foo,bar) title:x").count,0)
            XCTAssertThrowsError(try search(index,project,"query",extra:["kind":"memory"]))
            XCTAssertThrowsError(try search(index,project,"query",extra:["k":true]))
            XCTAssertThrowsError(try search(index,project,"query",extra:["includePrivate":true]))
        }
    }
    func testIndexPagesReopenAndIncrementalChangesDoNotLeaveDuplicateOrStaleHits() throws {
        try fixture { _,store,index,project in
            for id in ["a","b","c","d","e"] { try save(store,project,id,"version one target") }
            var cursor: String?, processed = 0
            repeat {
                var params: JSON = ["project":project,"batchSize":2]; if let cursor { params["cursor"] = cursor }
                let page = try index.handle("library.index",params); processed += intValue(page,"processed"); cursor = page["nextCursor"] as? String
                XCTAssertEqual((page["failures"] as? [JSON])?.count,0)
            } while cursor != nil
            XCTAssertEqual(processed,5)
            let reopened = try LibraryIndex(store:VelaStore(root:store.root))
            XCTAssertEqual(intValue(try reopened.handle("library.index.status",["project":project]),"indexedPublicDocuments"),5)
            XCTAssertEqual(intValue(try reopened.handle("library.index",["project":project]),"unchanged"),5)
            try save(store,project,"a","new unrelated source")
            XCTAssertEqual(try search(index,project,"target").count,4)
            _ = try index.handle("library.index",["project":project])
            XCTAssertEqual(try search(index,project,"new unrelated").count,1)
            try store.remove("library","a")
            XCTAssertEqual(try search(index,project,"unrelated").count,0)
        }
    }
    func testPrivateForeignArchivedAndMalformedPrivacyNeverEnterAgentRetrieval() throws {
        try fixture { _,store,index,project in
            try save(store,project,"public","needle public")
            try save(store,project,"private","needle private",fields:["private":true])
            try save(store,project,"scope","needle scope",fields:["scope":"private"])
            try save(store,project,"path","needle private path",fields:["sourcePath":"/workspace/private/secret.md"])
            try save(store,project,"alias","needle alias",fields:["sourceLabeledPrivate":true])
            try save(store,project,"malformed","needle malformed",fields:["private":"false"])
            try save(store,project,"archived","needle archived",fields:["state":"archived"])
            try save(store,project + "-other","foreign","needle foreign")
            _ = try index.handle("library.index",["project":project]); _ = try index.handle("library.index",["project":project + "-other"])
            XCTAssertEqual(try search(index,project,"needle").map { string($0,"id") },["public"])
            try save(store,project,"public","needle changed private",fields:["private":true])
            XCTAssertEqual(try search(index,project,"needle").count,0)
        }
    }
    func testManualAssetEditInvalidatesCandidateAndRequiresExplicitReindex() throws {
        try fixture { _,store,index,project in
            let item = try save(store,project,"edited","Old searchable evidence")
            _ = try index.handle("library.index",["project":project])
            let path = URL(fileURLWithPath:string(item,"assetPath"))
            let original = try String(contentsOf:path)
            try original.replacingOccurrences(of:"Old searchable evidence",with:"New verified evidence").write(to:path,atomically:true,encoding:.utf8)
            let result = try index.handle("library.search",["project":project,"query":"searchable"])
            XCTAssertEqual((result["items"] as? [JSON])?.count,0); XCTAssertEqual(intValue(result,"staleSourcesExcluded"),1)
            XCTAssertEqual(intValue(try index.handle("library.index.status",["project":project]),"pendingDocuments"),1)
            _ = try index.handle("library.index",["project":project])
            XCTAssertEqual(try search(index,project,"verified").count,1)
        }
    }
    func testParagraphAnchorsRemainUniqueAndSurrogatesAreNeverSplit() throws {
        let content = "## Same\n\n" + String(repeating:"🧑🏽‍💻",count:700) + "\n\n## Same\n\nRepeat paragraph.\n\nRepeat paragraph."
        let item: JSON = ["id":"repeated","project":"/synthetic","content":content,"title":"Long Unicode"]
        let chunks = LibraryIndex.paragraphs(item)
        XCTAssertGreaterThan(chunks.count,5)
        XCTAssertEqual(Set(chunks.map { string($0,"anchor") }).count,chunks.count)
        for chunk in chunks {
            XCTAssertFalse(string(chunk,"content").contains("�")); XCTAssertTrue(content.contains(string(chunk,"content")))
            XCTAssertEqual(string(chunk,"sourceHash"),stableHash(content))
        }
        XCTAssertEqual(try jsonString(chunks),try jsonString(LibraryIndex.paragraphs(item)))
    }
    func testLiteralSearchRechecksTheQueryAfterSynchronizingAnEditedAsset() throws {
        try fixture { _,store,_,project in
            let item = try save(store,project,"fresh-match","Old cedar source")
            let path = URL(fileURLWithPath:string(item,"assetPath"))
            let original = try String(contentsOf:path)
            try original.replacingOccurrences(of:"Old cedar source",with:"New pine source").write(to:path,atomically:true,encoding:.utf8)
            XCTAssertEqual(try store.search("cedar",project:project).count,0)
            let current = try store.search("PINE",project:project)
            XCTAssertEqual(current.count,1)
            XCTAssertEqual(string(current.first ?? [:],"content"),"New pine source")
        }
    }
    func testCoverageAndProximityRerankingAreDeterministicAndOptional() throws {
        try fixture { _,store,index,project in
            try save(store,project,"all","alpha beta gamma")
            try save(store,project,"partial","alpha alpha alpha")
            try save(store,project,"distant","alpha " + String(repeating:"padding ",count:50) + "beta gamma")
            _ = try index.handle("library.index",["project":project])
            let ranked = try search(index,project,"alpha beta gamma")
            XCTAssertEqual(string(ranked.first ?? [:],"id"),"all")
            XCTAssertEqual(try jsonString(ranked),try jsonString(search(index,project,"alpha beta gamma")))
            let unranked = try index.handle("library.search",["project":project,"query":"alpha beta gamma","rerank":false,"k":1])
            XCTAssertEqual(unranked["reranked"] as? Bool,false); XCTAssertEqual((unranked["items"] as? [JSON])?.count,1)
        }
    }
}
