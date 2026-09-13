import Foundation
import XCTest
@testable import VelaCore

final class MemoryArchiveTests: XCTestCase {
    func testWalrusRawRecordsConstructThenImportIdempotentlyWithoutAuthenticationClaim() throws {
        try fixture { _,project,store,service in
            let content = "Original MemWal UTF-8 内容 / café remains exact."
            let blob = Data(repeating:3,count:32).base64EncodedString().replacingOccurrences(of:"=",with:"")
            let source: JSON = ["network":"testnet", "packageID":"0x" + String(repeating:"1",count:64), "accountID":"0x" + String(repeating:"2",count:64), "owner":"0x" + String(repeating:"3",count:64), "namespace":"中文/isolated"]
            let receipt: JSON = ["sealAuthenticated":true, "expectedChecksumVerified":false, "actualSHA256":stableHash(content), "plaintextBytes":content.utf8.count, "manifestSHA256":String(repeating:"a",count:64), "manifestAuthenticated":false]
            let record: JSON = ["blobID":blob, "title":"Recovered original", "content":content, "sha256":stableHash(content), "private":false, "receipt":receipt]
            let converted = try service.handle("memory.archive.fromWalrusRecords",["source":source, "records":[record], "intendedUse":"candidate-review"])
            XCTAssertEqual(converted["writesPerformed"] as? Bool,false)
            XCTAssertEqual(try store.list("memory").count,0)
            let archive = try XCTUnwrap(converted["archive"] as? JSON)
            let first = try service.handle("memory.archive.import",["project":project.path, "archive":archive])
            let second = try service.handle("memory.archive.import",["project":project.path, "archive":archive])
            XCTAssertEqual(first["imported"] as? Int,1); XCTAssertEqual(second["skipped"] as? Int,1)
            let id = try XCTUnwrap((first["ids"] as? [String])?.first), restored = try XCTUnwrap(store.get("memory",id))
            XCTAssertEqual(restored["content"] as? String,content); XCTAssertEqual(restored["state"] as? String,"candidate")
            let provenance = try XCTUnwrap(restored["provenance"] as? JSON), metadata = try XCTUnwrap(provenance["sourceMetadata"] as? JSON)
            XCTAssertEqual(provenance["authenticated"] as? Bool,false)
            let verification = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(string(metadata,"sourceMessage").utf8)) as? JSON)
            XCTAssertEqual(verification["remoteAuthenticationVerifiedByCore"] as? Bool,false)
            XCTAssertEqual((verification["reportedReceipt"] as? JSON)?["sealAuthenticated"] as? Bool,true)
            XCTAssertTrue((try MemoryService(store:store).recall(["project":project.path,"query":"MemWal"])["items"] as? [JSON])?.isEmpty == true)
        }
    }

    func testWalrusRawConversionRejectsPrivacyDowngradeChecksumAndReceiptLies() throws {
        try fixture { _,_,store,service in
            let source: JSON = ["network":"testnet", "packageID":"0x" + String(repeating:"1",count:64), "accountID":"0x" + String(repeating:"2",count:64), "owner":"0x" + String(repeating:"3",count:64), "namespace":"isolated"]
            let record: JSON = ["blobID":String(repeating:"A",count:43), "title":"Original", "content":"text", "sha256":stableHash("text"), "private":false]
            let invalid: [JSON] = [["private":true], ["private":0], ["sha256":String(repeating:"0",count:64)], ["blobID":"../../escape"], ["scope":"global"], ["receipt":["sealAuthenticated":true]]]
            for fields in invalid {
                var changed = record; changed.merge(fields) { _,new in new }
                XCTAssertThrowsError(try service.handle("memory.archive.fromWalrusRecords",["source":source,"records":[changed],"intendedUse":"candidate-review"]))
            }
            XCTAssertThrowsError(try service.handle("memory.archive.fromWalrusRecords",["source":source,"records":[record,record],"intendedUse":"candidate-review"]))
            XCTAssertThrowsError(try service.handle("memory.archive.fromWalrusRecords",["source":source,"records":[record],"intendedUse":"automatic-agent-context"]))
            XCTAssertEqual(try store.list("memory").count,0)
        }
    }
    private func fixture(_ body: (URL, URL, VelaStore, MemoryArchiveService) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-memory-archive-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let project = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:temporary.appendingPathComponent("source"))
        _ = try FoundationService(store:store,sourceRoots:[:]).handle("projects.add",["path":project.path])
        try body(temporary,project,store,MemoryArchiveService(store:store))
    }

    private func memory(_ store: VelaStore, _ project: URL, id: String = "source-memory", fields: JSON = [:]) throws {
        var item: JSON = ["id":id, "title":"原文 'exact' <tag>", "content":"Retain café 中文 and path /tmp/original — no translation.", "project":canonicalProject(project.path), "scope":"branch", "branch":"feature/原文", "state":"active", "type":"constraint"]
        item.merge(fields) { _,new in new }
        _ = try store.put("memory",item)
    }

    private func archive(_ service: MemoryArchiveService, _ project: URL, ids: [String]? = nil) throws -> JSON {
        var params: JSON = ["project":project.path]; if let ids { params["ids"] = ids }
        return try XCTUnwrap(service.handle("memory.archive.export",params)["archive"] as? JSON)
    }

    private func reseal(_ archive: JSON, change: (inout JSON) -> Void) throws -> JSON {
        var archive = archive; var entries = archive["entries"] as! [JSON]
        var record = entries[0]["record"] as! JSON; change(&record)
        entries[0] = ["record":record, "sha256":stableHash(try jsonString(record))]
        archive["entries"] = entries; archive.removeValue(forKey:"sha256")
        archive["sha256"] = stableHash(try jsonString(archive)); return archive
    }

    func testRoundTripIntoFreshStorePreservesTextAndRequiresActivation() throws {
        try fixture { temporary,project,store,service in
            try memory(store,project)
            let exported = try archive(service,project)
            let target = temporary.appendingPathComponent("target-project")
            try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            let restored = try VelaStore(root:temporary.appendingPathComponent("restored"))
            _ = try FoundationService(store:restored,sourceRoots:[:]).handle("projects.add",["path":target.path])
            let importer = MemoryArchiveService(store:restored)
            let result = try importer.handle("memory.archive.import",["project":target.path, "archive":exported])
            XCTAssertEqual(result["imported"] as? Int,1)
            let id = try XCTUnwrap((result["ids"] as? [String])?.first)
            let record = try XCTUnwrap(restored.get("memory",id))
            XCTAssertEqual(record["title"] as? String,"原文 'exact' <tag>")
            XCTAssertEqual(record["content"] as? String,"Retain café 中文 and path /tmp/original — no translation.")
            XCTAssertEqual(record["state"] as? String,"candidate")
            XCTAssertEqual(record["scope"] as? String,"project")
            XCTAssertNil(record["branch"])
            XCTAssertEqual((record["provenance"] as? JSON)?["sourceScope"] as? String,"branch")
            let recall = try MemoryService(store:restored).recall(["project":target.path, "query":"Retain"])
            XCTAssertTrue((recall["items"] as? [JSON])?.isEmpty == true)
            let reopened = try VelaStore(root:restored.root)
            XCTAssertEqual(try reopened.get("memory",id)?["content"] as? String,record["content"] as? String)
            XCTAssertTrue(try reopened.search("café",project:canonicalProject(target.path)).contains { string($0,"id") == id })
        }
    }

    func testRepeatImportIsIdempotentAndPreservesSubsequentReview() throws {
        try fixture { _,project,store,service in
            try memory(store,project)
            let exported = try archive(service,project)
            let first = try service.handle("memory.archive.import",["project":project.path, "archive":exported])
            let id = try XCTUnwrap((first["ids"] as? [String])?.first)
            _ = try MemoryService(store:store).handle("memory.transition",["id":id, "state":"active"])
            var edited = try XCTUnwrap(store.get("memory",id)); edited["content"] = "User revised this after review."
            _ = try store.put("memory",edited)
            let before = try Data(contentsOf:try store.assetURL(kind:"memory",id:id))
            let second = try service.handle("memory.archive.import",["project":project.path, "archive":exported])
            XCTAssertEqual(second["imported"] as? Int,0)
            XCTAssertEqual(second["skipped"] as? Int,1)
            XCTAssertEqual(try store.get("memory",id)?["state"] as? String,"active")
            XCTAssertEqual(try Data(contentsOf:try store.assetURL(kind:"memory",id:id)),before)
        }
    }

    func testExportExcludesPrivateGlobalAndOtherProjectsWithoutLeakingMetadata() throws {
        try fixture { temporary,project,store,service in
            try memory(store,project)
            try memory(store,project,id:"private",fields:["private":true, "content":"private unique marker"])
            try memory(store,project,id:"malformed-privacy",fields:["private":"true"])
            try memory(store,project,id:"private-source",fields:["sourceFile":"/example/private/personal.md"])
            try memory(store,project,id:"global",fields:["scope":"global", "project":""])
            try memory(store,temporary.appendingPathComponent("other"),id:"other")
            _ = try store.put("library",["title":"Private Library", "content":"private-library-marker", "project":project.path, "private":true])
            let exported = try archive(service,project)
            XCTAssertEqual((exported["entries"] as? [JSON])?.count,1)
            XCTAssertFalse(try jsonString(exported).contains("private unique marker"))
            XCTAssertFalse(try jsonString(exported).contains("private-library-marker"))
            for id in ["private", "malformed-privacy", "private-source", "global", "other", "missing"] {
                XCTAssertThrowsError(try archive(service,project,ids:[id]))
            }
        }
    }

    func testValidationRejectsTamperingUnknownFieldsAndPrivacyDowngrades() throws {
        try fixture { _,project,store,service in
            try memory(store,project)
            let exported = try archive(service,project)
            XCTAssertEqual(try service.handle("memory.archive.validate",["archive":exported])["valid"] as? Bool,true)
            var badHash = exported; badHash["sha256"] = String(repeating:"0",count:64)
            XCTAssertThrowsError(try service.handle("memory.archive.validate",["archive":badHash]))
            for value: Any in [true, 2, "1"] {
                var wrongVersion = exported; wrongVersion["version"] = value
                XCTAssertThrowsError(try service.handle("memory.archive.validate",["archive":wrongVersion]))
            }
            let changes: [(inout JSON) -> Void] = [
                { $0["private"] = true }, { $0["private"] = 0 }, { $0["private"] = "false" },
                { $0["scope"] = "global" }, { $0["scope"] = "private" }, { $0["state"] = "running" },
                { $0["assetPath"] = "/tmp/escape" }, { $0["sourceId"] = "../escape" },
                { $0["metadata"] = ["sourceFile":"/example/private/secret.md"] },
                { $0["metadata"] = ["ownerPrivateKey":"not-a-real-key"] }
            ]
            for change in changes {
                let invalid = try reseal(exported,change:change)
                XCTAssertThrowsError(try service.handle("memory.archive.import",["project":project.path, "archive":invalid]))
            }
            XCTAssertEqual(try store.list("memory").count,1)
        }
    }

    func testBoundsExplicitProjectAndNoPartialMalformedImport() throws {
        try fixture { _,project,store,service in
            try memory(store,project)
            let exported = try archive(service,project)
            XCTAssertThrowsError(try service.handle("memory.archive.import",["archive":exported]))
            XCTAssertThrowsError(try service.handle("memory.archive.import",["project":"/unregistered", "archive":exported]))
            XCTAssertThrowsError(try service.handle("memory.archive.export",["project":project.path, "includePrivate":true]))
            XCTAssertThrowsError(try archive(service,project,ids:["source-memory", "source-memory"]))
            let oversized = try reseal(exported) { $0["content"] = String(repeating:"中",count:180000) }
            XCTAssertThrowsError(try service.handle("memory.archive.import",["project":project.path, "archive":oversized]))
            var repeated = exported; repeated["entries"] = Array(repeating:(exported["entries"] as! [JSON])[0],count:101)
            XCTAssertThrowsError(try service.handle("memory.archive.validate",["archive":repeated]))
            var partial = exported; partial["entries"] = (exported["entries"] as! [JSON]) + [["record":[:], "sha256":"bad"]]
            XCTAssertThrowsError(try service.handle("memory.archive.import",["project":project.path, "archive":partial]))
            XCTAssertEqual(try store.list("memory").count,1)
        }
    }

    func testCreateOnlyBatchRollsBackEarlierFilesAndLeavesConflictUntouched() throws {
        try fixture { _,project,store,_ in
            try memory(store,project,id:"existing")
            let existingAsset = try store.assetURL(kind:"memory",id:"existing")
            let bytes = try Data(contentsOf:existingAsset)
            XCTAssertThrowsError(try store.putBatch([
                ("memory",["id":"earlier", "title":"New", "content":"must rollback", "project":project.path]),
                ("memory",["id":"existing", "title":"Overwrite", "content":"must reject", "project":project.path])
            ],createOnly:true))
            XCTAssertNil(try store.get("memory","earlier"))
            XCTAssertFalse(FileManager.default.fileExists(atPath:try store.assetURL(kind:"memory",id:"earlier").path))
            XCTAssertEqual(try Data(contentsOf:existingAsset),bytes)
        }
    }

    func testConcurrentCreateOnlyBatchesDoNotOverwriteOrPartiallyCommit() throws {
        try fixture { _,project,store,_ in
            let otherStore = try VelaStore(root:store.root)
            let group = DispatchGroup(), start = DispatchSemaphore(value:0), resultLock = NSLock()
            var successes: [Int] = []; var failures = 0
            for (index,writer) in [store,otherStore].enumerated() {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }; start.wait()
                    do {
                        _ = try writer.putBatch([
                            ("memory",["id":"first-\(index)", "title":"Writer \(index)", "content":"batch marker", "project":project.path]),
                            ("memory",["id":"contended", "title":"Writer \(index)", "content":"batch marker", "project":project.path])
                        ],createOnly:true)
                        resultLock.lock(); successes.append(index); resultLock.unlock()
                    } catch { resultLock.lock(); failures += 1; resultLock.unlock() }
                }
            }
            start.signal(); start.signal()
            XCTAssertEqual(group.wait(timeout:.now()+10),.success)
            XCTAssertEqual(successes.count,1); XCTAssertEqual(failures,1)
            let winner = try XCTUnwrap(successes.first)
            XCTAssertEqual(try store.get("memory","contended")?["title"] as? String,"Writer \(winner)")
            XCTAssertNil(try store.get("memory","first-\(1-winner)"))
            XCTAssertFalse(FileManager.default.fileExists(atPath:try store.assetURL(kind:"memory",id:"first-\(1-winner)").path))
            XCTAssertEqual(try store.list("memory").count,2)
        }
    }

    func testArchiveImportRejectsAnUnrelatedDeterministicIDWithoutOverwriting() throws {
        try fixture { _,project,store,service in
            try memory(store,project)
            let exported = try archive(service,project)
            let first = try service.handle("memory.archive.import",["project":project.path, "archive":exported])
            let id = try XCTUnwrap((first["ids"] as? [String])?.first)
            _ = try store.put("memory",["id":id, "project":project.path, "title":"Unrelated content", "content":"never replace"])
            let bytes = try Data(contentsOf:try store.assetURL(kind:"memory",id:id))
            XCTAssertThrowsError(try service.handle("memory.archive.import",["project":project.path, "archive":exported]))
            XCTAssertEqual(try Data(contentsOf:try store.assetURL(kind:"memory",id:id)),bytes)
        }
    }

    func testArchiveImportRejectsUnsafeAssetDirectoryAndLeavesOutsideUntouched() throws {
        try fixture { temporary,project,store,service in
            try memory(store,project)
            let exported = try archive(service,project)
            let target = try VelaStore(root:temporary.appendingPathComponent("unsafe-target"))
            _ = try FoundationService(store:target,sourceRoots:[:]).handle("projects.add",["path":project.path])
            let outside = temporary.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
            try Data("keep me".utf8).write(to:outside.appendingPathComponent("sentinel"))
            try FileManager.default.createSymbolicLink(at:target.root.appendingPathComponent("assets"),withDestinationURL:outside)
            XCTAssertThrowsError(try MemoryArchiveService(store:target).handle("memory.archive.import",["project":project.path, "archive":exported]))
            XCTAssertTrue(try target.list("memory").isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:outside.path),["sentinel"])
            XCTAssertEqual(try String(contentsOf:outside.appendingPathComponent("sentinel"),encoding:.utf8),"keep me")
        }
    }
}
