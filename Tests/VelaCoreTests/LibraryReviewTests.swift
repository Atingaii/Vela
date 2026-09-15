import XCTest
@testable import VelaCore

/// Independent source and privacy review; these tests use only a disposable DB.
final class LibraryReviewTests: XCTestCase {
    private func fixture(_ work: (URL,VelaStore,LibraryIndex) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-library-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let raw = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:raw,withIntermediateDirectories:true)
        let project = URL(fileURLWithPath:canonicalProject(raw.path)), store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["title":"Library review","path":project.path,"project":project.path])
        try work(project,store,LibraryIndex(store:store))
    }
    private func source(_ root: URL, _ store: VelaStore, extra: JSON = [:]) throws -> JSON {
        var item: JSON = ["title":"Review source","project":root.path,"content":"CedarBoundary is synthetic source text.","state":"active"]
        item.merge(extra) { _,new in new }; return try store.put("library",item)
    }
    private func matches(_ index: LibraryIndex, _ root: URL) throws -> [JSON] {
        try XCTUnwrap(index.handle("library.search",["project":root.path,"query":"CedarBoundary"])["items"] as? [JSON])
    }
    func testMissingPublicConsentCannotEnterLibraryIndexOrSearch() throws {
        try fixture { root,store,index in
            _ = try source(root,store) // Deliberately missing public/private flag.
            let result = try index.handle("library.index",["project":root.path])
            XCTAssertEqual(intValue(result,"indexed"),0)
            XCTAssertTrue(try matches(index,root).isEmpty)
        }
    }
    func testDeletedManagedAssetCannotBeReturnedAsFreshIndexedContent() throws {
        try fixture { root,store,index in
            let item = try source(root,store,extra:["private":false])
            _ = try index.handle("library.index",["project":root.path])
            XCTAssertFalse(try matches(index,root).isEmpty)
            try FileManager.default.removeItem(atPath:string(item,"assetPath"))
            XCTAssertTrue(try matches(index,root).isEmpty)
            _ = try index.handle("library.index",["project":root.path])
            XCTAssertTrue(try matches(index,root).isEmpty)
        }
    }
    func testMalformedPrivateOriginLabelIsNotTreatedAsPublic() throws {
        try fixture { root,store,index in
            _ = try source(root,store,extra:["private":false,"sourceLabeledPrivate":"false"])
            let result = try index.handle("library.index",["project":root.path])
            XCTAssertEqual(intValue(result,"indexed"),0)
            XCTAssertTrue(try matches(index,root).isEmpty)
        }
    }
}
