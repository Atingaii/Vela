import XCTest
import Dispatch
@testable import VelaCore

private struct RecallFixtureEmbedding: SemanticEmbeddingProvider {
    let language = "en", model = "fixture.ingestion-recall"
    let revision = 1, dimension = 2
    func vector(_ text: String) throws -> [Float] { [1,0] }
}

final class IngestionRecallEligibilityTests: XCTestCase {
    private func fixture(_ body: (URL, URL, VelaStore, FoundationService) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vela-ingestion-recall-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let project = base.appendingPathComponent("project"), logs = base.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true)
        try Data("{}\n".utf8).write(to:logs.appendingPathComponent("captured.jsonl"))
        try Data("{}\n".utf8).write(to:logs.appendingPathComponent("other.jsonl"))
        let store = try VelaStore(root:base.appendingPathComponent("store"))
        let service = FoundationService(store:store,sourceRoots:["codex":[logs]],globalHome:base.appendingPathComponent("home"))
        _ = try service.handle("projects.add",["path":project.path])
        _ = try store.put("session",["id":"captured-session","project":project.path,"provider":"codex","sourcePath":logs.appendingPathComponent("captured.jsonl").path,"sourceSessionId":"thread","scope":"project","messages":[["id":"m","role":"assistant","content":"captured needle"]],"ingestionSource":["provider":"codex","relativePath":"captured.jsonl"] as JSON])
        _ = try store.put("session",["id":"other-session","project":project.path,"provider":"codex","sourcePath":logs.appendingPathComponent("other.jsonl").path,"sourceSessionId":"other-thread","scope":"project","messages":[],"ingestionSource":["provider":"codex","relativePath":"other.jsonl"] as JSON])
        try body(base,project,store,service)
    }
    private func captured(_ id: String, _ project: URL, relative: String) -> JSON {
        ["id":id,"project":project.path,"scope":"project","state":"active","private":false,"title":id,"content":"needle " + id,"type":"observation","provenance":["origin":"observed_session_capture","captureProtocol":"vela-session-memory-capture-v1","ingestionSource":["provider":"codex","relativePath":relative] as JSON] as JSON]
    }
    private func ids(_ result: JSON) -> Set<String> { Set((result["items"] as? [JSON] ?? []).map { string($0,"id") }) }
    private func removeRule(_ service: FoundationService, _ project: URL, _ rule: JSON) throws {
        _ = try service.handle("ingestion.exclusions.remove",["project":project.path,"id":rule["id"]!])
    }

    func testSourceAndProjectRulesFilterLexicalSemanticAndRecentAcrossReopenWithoutDeletingMemories() throws {
        try fixture { base,project,store,foundation in
            _ = try store.put("memory",captured("captured",project,relative:"captured.jsonl"))
            _ = try store.put("memory",["id":"legacy","project":project.path,"scope":"project","state":"active","private":false,"title":"legacy","content":"needle legacy","type":"observation","provenance":["origin":"observed_session_capture","captureProtocol":"vela-session-memory-capture-v1","provider":"codex","sourcePath":project.deletingLastPathComponent().appendingPathComponent("codex/captured.jsonl").path] as JSON])
            _ = try store.put("memory",captured("unrelated",project,relative:"other.jsonl"))
            _ = try store.put("memory",["id":"manual","project":project.path,"scope":"project","state":"active","private":false,"title":"manual","content":"needle manual","type":"fact","provenance":["origin":"user","ingestionSource":["provider":"codex","relativePath":"captured.jsonl"] as JSON] as JSON])
            _ = try store.put("memory",["id":"global","project":"","scope":"global","state":"active","private":false,"title":"global","content":"needle global","type":"fact"])
            _ = try store.put("memory",["id":"namespaced","project":project.path,"scope":"namespace","namespace":"isolated","state":"active","private":false,"title":"namespaced","content":"needle namespaced","type":"fact"])
            let memory = MemoryService(store:store)
            let semantic = SemanticMemory(store:store,providerFactory:{ _ in RecallFixtureEmbedding() })
            _ = try semantic.handle("memory.semantic.index",["project":project.path,"language":"en"])
            XCTAssertEqual(ids(try memory.recall(["project":project.path,"query":"needle"])),Set(["captured","legacy","unrelated","manual","global"]))
            let sourceRule = try XCTUnwrap(try foundation.handle("ingestion.exclusions.upsert",["project":project.path,"provider":"codex","pathGlob":"captured.jsonl"]) as? JSON)
            XCTAssertEqual(try store.list("memory",project:project.path).count,5)
            XCTAssertEqual(ids(try memory.recall(["project":project.path,"query":"needle"])),Set(["unrelated","manual","global"]))
            XCTAssertEqual(ids(try memory.recall(["project":project.path,"query":"needle","namespace":"isolated"])),Set(["namespaced"]))
            let semanticResult = try semantic.recall(["project":project.path,"query":"needle","retrievalMode":"semantic","language":"en","minSimilarity":0]) { ["items":[]] }
            XCTAssertEqual(ids(semanticResult),Set(["unrelated","manual","global"]))
            let recent = try semantic.handle("memory.semantic.recent",["project":project.path,"query":"needle","language":"en","minSimilarity":0])
            XCTAssertEqual(ids(recent),Set(["unrelated","manual","global"]))
            _ = try semantic.handle("memory.semantic.index",["project":project.path,"language":"en"])
            XCTAssertNil(try store.semanticVectorMetadata(memoryID:"captured",language:"en"))
            XCTAssertNil(try store.semanticVectorMetadata(memoryID:"legacy",language:"en"))
            // The persisted rule works in newly constructed services after a
            // store reopen, without consulting the now-withdrawn Session.
            let reopened = try VelaStore(root:store.root)
            let restarted = FoundationService(store:reopened,sourceRoots:["codex":[base.appendingPathComponent("codex")]],globalHome:base.appendingPathComponent("home-restarted"))
            let restartedLexical = try XCTUnwrap(try restarted.handle("recall",["project":project.path,"query":"needle"]) as? JSON)
            XCTAssertEqual(ids(restartedLexical),Set(["unrelated","manual","global"]))
            let freshSemantic = SemanticMemory(store:reopened,providerFactory:{ _ in RecallFixtureEmbedding() })
            let freshSemanticResult = try freshSemantic.recall(["project":project.path,"query":"needle","retrievalMode":"semantic","language":"en","minSimilarity":0]) { ["items":[]] }
            XCTAssertEqual(ids(freshSemanticResult),Set(["unrelated","manual","global"]))
            let freshRecent = try freshSemantic.handle("memory.semantic.recent",["project":project.path,"query":"needle","language":"en","minSimilarity":0])
            XCTAssertEqual(ids(freshRecent),Set(["unrelated","manual","global"]))
            let projectRule = try XCTUnwrap(try foundation.handle("ingestion.exclusions.upsert",["project":project.path]) as? JSON)
            XCTAssertTrue(ids(try memory.recall(["project":project.path,"query":"needle"])).isEmpty)
            XCTAssertTrue(ids(try memory.recall(["project":project.path,"query":"needle","namespace":"isolated"])).isEmpty)
            let blockedSemantic = try semantic.recall(["project":project.path,"query":"needle","retrievalMode":"semantic","language":"en","minSimilarity":0]) { ["items":[]] }
            XCTAssertTrue(ids(blockedSemantic).isEmpty)
            let blockedRecent = try semantic.handle("memory.semantic.recent",["project":project.path,"query":"needle","language":"en","minSimilarity":0])
            XCTAssertTrue(ids(blockedRecent).isEmpty)
            XCTAssertEqual(try store.list("memory",project:project.path).count,5)
            let otherProject = base.appendingPathComponent("allowed-project")
            try FileManager.default.createDirectory(at:otherProject,withIntermediateDirectories:true)
            _ = try foundation.handle("projects.add",["path":otherProject.path])
            XCTAssertEqual(ids(try memory.recall(["project":otherProject.path,"query":"needle"])),Set(["global"]))
            try removeRule(foundation,project,projectRule)
            XCTAssertEqual(ids(try memory.recall(["project":project.path,"query":"needle"])),Set(["unrelated","manual","global"]))
            _ = try store.put("session",["id":"refreshed-other-session","project":project.path,"provider":"codex","sourcePath":base.appendingPathComponent("codex/other.jsonl").path,"scope":"project","messages":[]])
            let updatedRule = try XCTUnwrap(try foundation.handle("ingestion.exclusions.upsert",["project":project.path,"id":sourceRule["id"]!,"provider":"codex","pathGlob":"other.jsonl"]) as? JSON)
            XCTAssertEqual(ids(try memory.recall(["project":project.path,"query":"needle"])),Set(["captured","legacy","manual","global"]))
            try removeRule(foundation,project,updatedRule)
            XCTAssertEqual(ids(try memory.recall(["project":project.path,"query":"needle"])),Set(["captured","legacy","unrelated","manual","global"]))
        }
    }

    func testCaptureCarriesPolicyCASAcrossConcurrentExclusion() throws {
        try fixture { _,project,store,_ in
            let memory = MemoryService(store:store)
            let prepared = try XCTUnwrap(try memory.handle("memory.capture.prepare",["project":project.path,"sessionId":"captured-session","messageId":"m"]) as? JSON)
            let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0), finished = DispatchSemaphore(value:0)
            let resultLock = NSLock()
            var resultDescription = ""
            memory.captureAfterIngestionAdmissionForTesting = {
                entered.signal()
                guard release.wait(timeout:.now()+2) == .success else { throw VelaError("capture policy barrier timed out") }
            }
            defer { memory.captureAfterIngestionAdmissionForTesting = nil }
            DispatchQueue.global(qos:.userInitiated).async {
                do { _ = try memory.handle("memory.capture",["project":project.path,"sessionId":"captured-session","messageId":"m","sourceIdentity":prepared["sourceIdentity"]!,"expectedSourceHash":prepared["expectedSourceHash"]!]) }
                catch {
                    resultLock.lock(); resultDescription = error.localizedDescription; resultLock.unlock()
                }
                finished.signal()
            }
            XCTAssertEqual(entered.wait(timeout:.now()+2),.success)
            let writer = try VelaStore(root:store.root)
            _ = try IngestionExclusionService(store:writer).handle("ingestion.exclusions.upsert",["project":project.path])
            release.signal()
            XCTAssertEqual(finished.wait(timeout:.now()+2),.success)
            resultLock.lock(); let rejection = resultDescription; resultLock.unlock()
            XCTAssertFalse(rejection.isEmpty)
            XCTAssertTrue(rejection.contains("Batch source changed or is missing"), "actual capture rejection: \(rejection)")
            XCTAssertTrue(try store.list("memory",project:project.path).isEmpty)
        }
    }

    func testLegacyCaptureFailsClosedForItsProviderWhenAReopenedStoreUsesDifferentRoots() throws {
        try fixture { base,project,store,foundation in
            _ = try store.put("memory",["id":"legacy-root-change","project":project.path,"scope":"project","state":"active","private":false,"title":"legacy","content":"needle legacy","type":"observation","provenance":["origin":"observed_session_capture","captureProtocol":"vela-session-memory-capture-v1","provider":"codex","sourcePath":base.appendingPathComponent("codex/captured.jsonl").path] as JSON])
            _ = try foundation.handle("ingestion.exclusions.upsert",["project":project.path,"provider":"codex","pathGlob":"captured.jsonl"])
            let reopened = try VelaStore(root:store.root)
            let otherRoot = base.appendingPathComponent("different-codex-root")
            try FileManager.default.createDirectory(at:otherRoot,withIntermediateDirectories:true)
            let restarted = FoundationService(store:reopened,sourceRoots:["codex":[otherRoot]],globalHome:base.appendingPathComponent("other-home"))
            try withExtendedLifetime(restarted) {
                let recalled = try MemoryService(store:reopened).recall(["project":project.path,"query":"needle"])
                XCTAssertFalse(ids(recalled).contains("legacy-root-change"))
            }
            XCTAssertEqual(try reopened.list("memory",project:project.path).count,1)
        }
    }

    func testFrozenLabExplicitMemoryRechecksProjectPolicyBeforeExecution() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vela-ingestion-lab-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let project = base.appendingPathComponent("project"); try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        try Data("ok\n".utf8).write(to:project.appendingPathComponent("fixture.txt"))
        XCTAssertEqual(try AutomationProcess.git(["init","-q"],cwd:project.path).exitCode,0)
        XCTAssertEqual(try AutomationProcess.git(["add","."],cwd:project.path).exitCode,0)
        XCTAssertEqual(try AutomationProcess.git(["-c","user.name=fixture","-c","user.email=fixture@example.invalid","commit","-qm","fixture"],cwd:project.path).exitCode,0)
        let store = try VelaStore(root:base.appendingPathComponent("store"))
        let foundation = FoundationService(store:store,sourceRoots:["codex":[]],globalHome:base.appendingPathComponent("home"))
        _ = try foundation.handle("projects.add",["path":project.path])
        _ = try store.put("memory",["id":"lab-memory","project":project.path,"scope":"project","state":"active","private":false,"title":"lab","content":"needle","type":"fact"])
        let automation = AutomationService(store:store)
        let request: JSON = ["project":project.path,"kind":"memory","command":["/usr/bin/true"],"repetitions":1,"baseline":["files":[]],"candidate":["files":[],"memoryIds":["lab-memory"]]]
        let created = try XCTUnwrap(try automation.handle("lab.run",request) as? JSON)
        _ = try foundation.handle("ingestion.exclusions.upsert",["project":project.path])
        let approval = try XCTUnwrap(store.get("approval",string(created,"approvalId")))
        let decided = try XCTUnwrap(try automation.handle("approvals.decide",["id":approval["id"]!,"decision":"approve","snapshotHash":approval["snapshotHash"]!]) as? JSON)
        XCTAssertEqual(string(decided,"state"),"failed")
        XCTAssertTrue(string(decided["result"] as? JSON ?? [:],"output").contains("was excluded"))
    }
}
