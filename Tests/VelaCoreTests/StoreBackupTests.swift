import Foundation
import CryptoKit
import XCTest
@testable import VelaCore

final class StoreBackupTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,StoreBackupService) throws -> Void) throws {
        let base = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".task-tmp/store-backup-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:base) }
        let store = try VelaStore(root:base.appendingPathComponent("source")); try body(base,store,StoreBackupService(store:store))
    }
    func testCompleteBackupRestoresPrivateAssetsHistoryPreferencesAndRevokesRuntime() throws {
        try fixture { base,store,service in
            let project = base.appendingPathComponent("project"); try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
            _ = try store.put("project",["id":stableHash(project.path),"project":project.path,"path":project.path])
            _ = try store.put("memory",["id":"private-memory","project":project.path,"title":"Private","content":"private exact payload","private":true,"scope":"project","state":"active"])
            _ = try store.put("workflow",["id":"watch-flow","project":project.path,"title":"Watch","content":"workflow","enabled":true,"trigger":"cron"])
            _ = try store.put("run",["id":"run-a","project":project.path,"state":"pending"])
            _ = try store.put("approval",["id":"approval-a","project":project.path,"state":"pending"])
            _ = try store.put("apply_journal",["id":"journal-a","project":project.path,"state":"prepared","operations":[]])
            let output = store.root.appendingPathComponent("output/reports/result.txt"); try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true); try Data("user delivery".utf8).write(to:output)
            _ = try VelaPreferences.save(["locale":"en"],in:store)
            let history = try SessionHistoryStore(store:store); try history.put("epoch",["id":"epoch-a","project":project.path,"state":"completed","sourceReceipt":"persisted"]); try history.transaction { _ = try history.appendRaw(epoch:"epoch-a",ordinal:1,parts:0,bytes:Data("raw private history".utf8)) }
            let sourceDBHash = SHA256.hash(data:try Data(contentsOf:store.root.appendingPathComponent("vela.sqlite3"))).map { String(format:"%02x",$0) }.joined()
            let bundle = base.appendingPathComponent("bundle"), target = base.appendingPathComponent("restored")
            let create = try service.create(destination:bundle); XCTAssertEqual(create["privateDataIncluded"] as? Bool,true)
            XCTAssertEqual(SHA256.hash(data:try Data(contentsOf:store.root.appendingPathComponent("vela.sqlite3"))).map { String(format:"%02x",$0) }.joined(),sourceDBHash)
            _ = try StoreBackupService.restore(bundle:bundle,target:target)
            let restored = try VelaStore(root:target)
            XCTAssertEqual(try restored.get("memory","private-memory")?["content"] as? String,"private exact payload")
            XCTAssertEqual(try restored.get("memory","private-memory")?["private"] as? Bool,true)
            XCTAssertEqual(try VelaPreferences.read(from:restored)["locale"] as? String,"en")
            XCTAssertEqual(try restored.get("workflow","watch-flow")?["enabled"] as? Bool,false)
            XCTAssertEqual(try restored.get("run","run-a")?["state"] as? String,"needs_review")
            XCTAssertEqual(try restored.get("approval","approval-a")?["state"] as? String,"needs_review")
            XCTAssertEqual(try restored.get("apply_journal","journal-a")?["state"] as? String,"needs_review")
            XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("output/reports/result.txt")),Data("user delivery".utf8))
            XCTAssertEqual(try restored.get("memory","private-memory")?["assetPath"] as? String,target.appendingPathComponent("assets/memory/private-memory.md").path)
            let restoredHistory=try SessionHistoryStore(store:restored); XCTAssertEqual(try restoredHistory.get("epoch","epoch-a")?["sourceReceipt"] as? String,"persisted")
            XCTAssertEqual(try restoredHistory.blob(epoch:"epoch-a",ordinal:1,part:0),Data("raw private history".utf8))
        }
    }
    func testRejectsTamperedBundleAndNonemptyTarget() throws {
        try fixture { base,store,service in
            _ = try store.put("memory",["id":"one","title":"One","content":"payload","private":false])
            let bundle=base.appendingPathComponent("bundle"), target=base.appendingPathComponent("target"); _ = try service.create(destination:bundle)
            try Data("{}".utf8).write(to:bundle.appendingPathComponent("manifest.json"),options:.atomic)
            XCTAssertThrowsError(try StoreBackupService.restore(bundle:bundle,target:target)); XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
            let fresh=base.appendingPathComponent("fresh"); _ = try service.create(destination:fresh); try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            XCTAssertThrowsError(try StoreBackupService.restore(bundle:fresh,target:target))
        }
    }
    func testRejectsBackupWhileUncertainActionExists() throws {
        try fixture { base,store,service in
            _ = try store.put("approval",["id":"uncertain","state":"needs_review"])
            XCTAssertThrowsError(try service.create(destination:base.appendingPathComponent("bundle")))
        }
    }
    func testRestoreRevokesEveryPendingRuntimeAndRejectsSymlinkBundleFile() throws {
        try fixture { base,store,service in
            for kind in ["knowledge_query","agent_loop","replay","workflow_plan","connector_action","schedule","schedule_event","watch_state","eval"] { _ = try store.put(kind,["id":kind,"project":base.path,"state":"pending_approval"]) }
            _ = try store.put("workflow_health_proposal",["id":"health","project":base.path,"state":"accepting"])
            let bundle=base.appendingPathComponent("bundle"), target=base.appendingPathComponent("target")
            _ = try service.create(destination:bundle); _ = try StoreBackupService.restore(bundle:bundle,target:target)
            let restored=try VelaStore(root:target)
            for kind in ["knowledge_query","agent_loop","replay","workflow_plan","connector_action","schedule","schedule_event","watch_state","eval"] { XCTAssertEqual(try restored.get(kind,kind)?["state"] as? String,"needs_review") }
            XCTAssertEqual(try restored.get("workflow_health_proposal","health")?["state"] as? String,"invalidated")
            let unsafe=base.appendingPathComponent("unsafe"); _ = try service.create(destination:unsafe)
            try FileManager.default.removeItem(at:unsafe.appendingPathComponent("vela.sqlite3")); try FileManager.default.createSymbolicLink(at:unsafe.appendingPathComponent("vela.sqlite3"),withDestinationURL:store.root.appendingPathComponent("vela.sqlite3"))
            XCTAssertThrowsError(try StoreBackupService.restore(bundle:unsafe,target:base.appendingPathComponent("unsafe-target")))
        }
    }

    func testCanonicalPrivateTmpCreateAndRestoreRejectsUserSymlinkAlias() throws {
        let base=URL(fileURLWithPath:"/private/tmp/vela-store-backup-canonical-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:base) }
        XCTAssertEqual(canonicalProject(base.path),base.path)
        let store=try VelaStore(root:base.appendingPathComponent("source"))
        _ = try store.put("memory",["id":"canonical-private","title":"Canonical private","content":"retained","private":true])
        let service=StoreBackupService(store:store), bundle=base.appendingPathComponent("bundle"), target=base.appendingPathComponent("restored")
        let created=try service.create(destination:bundle)
        XCTAssertEqual(created["destination"] as? String,bundle.path)
        let restored=try StoreBackupService.restore(bundle:bundle,target:target)
        XCTAssertEqual(restored["target"] as? String,target.path)
        XCTAssertEqual(try VelaStore(root:target).get("memory","canonical-private")?["content"] as? String,"retained")

        let alias=base.appendingPathComponent("user-alias")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:base)
        XCTAssertThrowsError(try service.create(destination:alias.appendingPathComponent("forbidden-bundle")))
        XCTAssertFalse(FileManager.default.fileExists(atPath:base.appendingPathComponent("forbidden-bundle").path))
    }

}
