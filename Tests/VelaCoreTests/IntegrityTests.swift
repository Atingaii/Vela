import Foundation
import XCTest
@testable import VelaCore

final class IntegrityTests: XCTestCase {
    private func fixture(_ body: (URL, URL, VelaStore, MemoryService) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-integrity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let project = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        try body(temporary,project,store,MemoryService(store:store))
    }

    func testPrivateLibraryCannotLoseItsSourceByReusingAnIdentifier() throws {
        try fixture { _,project,store,memory in
            let source = project.appendingPathComponent("private/reference.md")
            try FileManager.default.createDirectory(at:source.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data("synthetic-private-library-needle".utf8).write(to:source)
            let imported = try XCTUnwrap(memory.handle("library.add",["title":"Private reference","path":source.path,"project":project.path,"private":false]) as? JSON)
            let id = try XCTUnwrap(imported["id"] as? String)
            let asset = URL(fileURLWithPath:try XCTUnwrap(imported["assetPath"] as? String))
            let before = try Data(contentsOf:asset)
            XCTAssertEqual(imported["private"] as? Bool,true)

            XCTAssertThrowsError(try memory.handle("library.add",["id":id,"title":"Replacement","content":"synthetic-private-library-needle","project":project.path,"private":false]))

            let persisted = try XCTUnwrap(store.get("library",id))
            XCTAssertEqual(persisted["private"] as? Bool,true)
            XCTAssertEqual(persisted["sourcePath"] as? String,canonicalProject(source.path))
            XCTAssertEqual(persisted["title"] as? String,"Private reference")
            XCTAssertEqual(try Data(contentsOf:asset),before)
            XCTAssertTrue(try store.search("synthetic-private-library-needle",project:canonicalProject(project.path)).isEmpty)
            XCTAssertEqual(try store.search("synthetic-private-library-needle",project:canonicalProject(project.path),includePrivate:true).count,1)
        }
    }

    func testLibraryIdentifierCannotReplaceAnotherProjectsReference() throws {
        try fixture { temporary,project,store,memory in
            let other = temporary.appendingPathComponent("other")
            try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
            let imported = try XCTUnwrap(memory.handle("library.add",["title":"Original reference","content":"project-a-needle","project":project.path,"private":false]) as? JSON)
            let id = try XCTUnwrap(imported["id"] as? String)
            let before = try Data(contentsOf:URL(fileURLWithPath:try XCTUnwrap(imported["assetPath"] as? String)))

            XCTAssertThrowsError(try memory.handle("library.add",["id":id,"title":"Wrong project","content":"project-b-needle","project":other.path,"private":false]))

            let persisted = try XCTUnwrap(store.get("library",id))
            XCTAssertEqual(persisted["project"] as? String,canonicalProject(project.path))
            XCTAssertEqual(persisted["content"] as? String,"project-a-needle")
            XCTAssertEqual(try store.list("library",project:canonicalProject(other.path)).count,0)
            XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:try XCTUnwrap(persisted["assetPath"] as? String))),before)
            let fresh = try XCTUnwrap(memory.handle("library.add",["title":"Independent import","content":"project-b-needle","project":other.path,"private":false]) as? JSON)
            XCTAssertNotEqual(fresh["id"] as? String,id)
            XCTAssertEqual(try store.list("library",project:canonicalProject(other.path)).count,1)
        }
    }

    func testAssetAncestorSymlinksRejectWithoutCreatingOutsideDirectories() throws {
        try fixture { temporary,project,_,_ in
            for linkedComponent in ["assets","memory"] {
                let storeRoot = temporary.appendingPathComponent("store-" + linkedComponent)
                let store = try VelaStore(root:storeRoot)
                let outside = temporary.appendingPathComponent("outside-" + linkedComponent)
                try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
                let sentinel = outside.appendingPathComponent("keep.txt")
                try Data("outside must not change".utf8).write(to:sentinel)
                let link: URL
                if linkedComponent == "assets" { link = store.root.appendingPathComponent("assets") }
                else {
                    let assets = store.root.appendingPathComponent("assets")
                    try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:false)
                    link = assets.appendingPathComponent("memory")
                }
                try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
                let originalNames = try FileManager.default.contentsOfDirectory(atPath:outside.path).sorted()

                XCTAssertThrowsError(try MemoryService(store:store).handle("memory.save",["title":"Must stay in store","content":"fixture","project":project.path]))

                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:outside.path).sorted(),originalNames)
                XCTAssertEqual(try String(contentsOf:sentinel,encoding:.utf8),"outside must not change")
                XCTAssertEqual(try store.list("memory").count,0)
                XCTAssertTrue((try link.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink == true)
            }
        }
    }

    func testConcurrentLibraryCreationCannotReplaceTheWinningReference() throws {
        try fixture { _,project,store,_ in
            let otherStore = try VelaStore(root:store.root)
            let group = DispatchGroup()
            let start = DispatchSemaphore(value:0)
            let resultLock = NSLock()
            var successes: [String] = []
            var failures = 0
            for (index,candidateStore) in [store,otherStore].enumerated() {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    start.wait()
                    let title = "Writer \(index)"
                    do {
                        _ = try candidateStore.put("library",["id":"contended-reference","title":title,"content":"original from \(index)","project":project.path,"private":true],createOnly:true)
                        resultLock.lock(); successes.append(title); resultLock.unlock()
                    } catch {
                        resultLock.lock(); failures += 1; resultLock.unlock()
                    }
                }
            }
            start.signal(); start.signal()
            XCTAssertEqual(group.wait(timeout:.now()+5),.success)
            XCTAssertEqual(successes.count,1)
            XCTAssertEqual(failures,1)
            let persisted = try XCTUnwrap(store.get("library","contended-reference"))
            XCTAssertEqual(persisted["title"] as? String,successes.first)
            let asset = URL(fileURLWithPath:try XCTUnwrap(persisted["assetPath"] as? String))
            let markdown = try String(contentsOf:asset,encoding:.utf8)
            XCTAssertTrue(markdown.contains("# " + (successes.first ?? "missing winner")))
            XCTAssertEqual(persisted["private"] as? Bool,true)
        }
    }

    func testSafeAssetDirectoriesSupportAllPersistentKindsAndReopen() throws {
        try fixture { temporary,project,_,_ in
            let root = temporary.appendingPathComponent("nested/local/store")
            let store = try VelaStore(root:root)
            let kinds = ["memory","library","workflow","guideline","checkpoint"]
            for kind in kinds {
                _ = try store.put(kind,["id":"persistent-" + kind,"title":kind,"content":"durable fixture","project":project.path])
            }
            let reopened = try VelaStore(root:root)
            for kind in kinds {
                let item = try XCTUnwrap(reopened.get(kind,"persistent-" + kind))
                XCTAssertEqual(item["content"] as? String,"durable fixture")
                let asset = try reopened.assetURL(kind:kind,id:"persistent-" + kind)
                XCTAssertTrue(FileManager.default.fileExists(atPath:asset.path))
                XCTAssertTrue(canonicalProject(asset.path).hasPrefix(reopened.root.path + "/assets/"))
            }
        }
    }

    func testGuardedBatchRejectsStaleSourceBeforeChangingAnyAssets() throws {
        try fixture { _,project,store,_ in
            let original = try store.put("memory",["id":"reviewed-candidate","title":"Candidate","content":"reviewed version","state":"candidate","project":project.path])
            let expectedHash = stableHash(try jsonString(original))
            let otherStore = try VelaStore(root:store.root)
            var newer = original; newer["content"] = "a newer edit from another connection"
            _ = try otherStore.put("memory",newer)
            let existingAsset = URL(fileURLWithPath:try XCTUnwrap(original["assetPath"] as? String))
            let latestBytes = try Data(contentsOf:existingAsset)
            let newAssetDirectory = store.root.appendingPathComponent("assets/guideline")
            XCTAssertFalse(FileManager.default.fileExists(atPath:newAssetDirectory.path))
            var promoted = original; promoted["state"] = "active"

            XCTAssertThrowsError(try store.putBatch([
                ("guideline",["id":"must-not-be-created","title":"Proposed guideline","content":"stale promotion","project":project.path]),
                ("memory",promoted)
            ],expecting:[("memory","reviewed-candidate",expectedHash)]))

            let current = try XCTUnwrap(otherStore.get("memory","reviewed-candidate"))
            XCTAssertEqual(current["state"] as? String,"candidate")
            XCTAssertEqual(current["content"] as? String,"a newer edit from another connection")
            XCTAssertEqual(try Data(contentsOf:existingAsset),latestBytes)
            XCTAssertNil(try store.get("guideline","must-not-be-created"))
            XCTAssertFalse(FileManager.default.fileExists(atPath:newAssetDirectory.path))
        }
    }

    func testGuardedBatchCommitsFreshSourcesAndTheirAssetsTogether() throws {
        try fixture { _,project,store,_ in
            let candidate = try store.put("memory",["id":"fresh-candidate","title":"Candidate","content":"verified context","state":"candidate","project":project.path])
            let evaluation = try store.put("eval",["id":"fresh-evaluation","title":"Evidence","state":"completed","project":project.path])
            var promoted = candidate; promoted["state"] = "active"
            let output = try store.putBatch([
                ("memory",promoted),
                ("guideline",["id":"new-guideline","title":"Approved context","content":"run verification","project":project.path])
            ],expecting:[
                ("memory","fresh-candidate",stableHash(try jsonString(candidate))),
                ("eval","fresh-evaluation",stableHash(try jsonString(evaluation)))
            ])
            XCTAssertEqual(output.count,2)
            let reopened = try VelaStore(root:store.root)
            let memory = try XCTUnwrap(reopened.get("memory","fresh-candidate"))
            let guideline = try XCTUnwrap(reopened.get("guideline","new-guideline"))
            XCTAssertEqual(memory["state"] as? String,"active")
            XCTAssertEqual(memory["content"] as? String,"verified context")
            XCTAssertEqual(guideline["content"] as? String,"run verification")
            let asset = URL(fileURLWithPath:try XCTUnwrap(memory["assetPath"] as? String))
            XCTAssertTrue(try String(contentsOf:asset,encoding:.utf8).contains("\"state\":\"active\""))
            let unchangedEvaluation = try XCTUnwrap(reopened.get("eval","fresh-evaluation"))
            XCTAssertEqual(stableHash(try jsonString(unchangedEvaluation)),stableHash(try jsonString(evaluation)))
        }
    }
}
