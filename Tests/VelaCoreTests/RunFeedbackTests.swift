import XCTest
@testable import VelaCore

final class RunFeedbackTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("vela-feedback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let store = try VelaStore(root:root.appendingPathComponent("store")); _ = try store.put("project",["project":root.path,"path":root.path])
        try body(root,store,AutomationService(store:store))
    }
    private func run(_ root: URL, _ id: String = "run") -> JSON { ["id":id,"project":root.path,"workflowId":"digest","workflowVersion":1,"state":"completed","dryRun":false,"startedAt":"2026-09-14T00:00:00Z","completedAt":"2026-09-14T00:00:01Z","durationMs":10,"steps":[] as [JSON]] }
    func testRecordReplayAndHealthUsesManualObservationWithoutChangingRate() throws { try fixture { root,store,service in
        _ = try store.put("run",run(root)); let prepared = try service.handle("runs.feedback.prepare",["project":root.path,"runId":"run"]) as! JSON
        let p:[String:Any] = ["project":root.path,"runId":"run","runHash":prepared["runHash"]!,"previousFeedbackHash":NSNull(),"outcome":"bad","reason":"The result needs manual correction."]
        let first = try service.handle("runs.feedback.record",p) as! JSON; XCTAssertEqual(first["created"] as? Bool,true)
        let replay = try service.handle("runs.feedback.record",p) as! JSON; XCTAssertEqual(replay["idempotent"] as? Bool,true)
        let health = try service.workflowHealthReport(["project":root.path]); XCTAssertEqual(intValue(health,"successes"),1); XCTAssertEqual((health["successRate"] as? Double),1); XCTAssertEqual((((health["manualFeedback"] as? JSON)?["bad"]) as? Int),1)
        XCTAssertEqual(((try service.handle("runs.feedback.list",["project":root.path]) as! JSON)["items"] as? [JSON])?.count,1)
    } }
    func testRejectsCrossProjectPrivateStaleAndInvalidWithoutWriting() throws { try fixture { root,store,service in
        _ = try store.put("run",run(root)); let prepared = try service.handle("runs.feedback.prepare",["project":root.path,"runId":"run"]) as! JSON
        var changed = try store.get("run","run")!; changed["state"] = "failed"; _ = try store.put("run",changed)
        XCTAssertThrowsError(try service.handle("runs.feedback.record",["project":root.path,"runId":"run","runHash":prepared["runHash"]!,"previousFeedbackHash":NSNull(),"outcome":"good","reason":"ok"]))
        changed["private"] = true; _ = try store.put("run",changed); XCTAssertThrowsError(try service.handle("runs.feedback.prepare",["project":root.path,"runId":"run"]))
        XCTAssertEqual(try store.list("run_feedback").count,0)
    } }
}

extension RunFeedbackTests {
    func testConcurrentExactReplayLeavesOneImmutableRecord() throws { try fixture { root,store,service in
        _ = try store.put("run",run(root)); let pre = try service.handle("runs.feedback.prepare",["project":root.path,"runId":"run"]) as! JSON
        let params: JSON = ["project":root.path,"runId":"run","runHash":pre["runHash"]!,"previousFeedbackHash":NSNull(),"outcome":"clear","reason":"Concurrent reviewer acknowledgement."]
        let storeRoot = store.root; let lock = NSLock(); var replies:[JSON] = []; var failures = 0
        DispatchQueue.concurrentPerform(iterations:2) { _ in do { let value = try AutomationService(store:try VelaStore(root:storeRoot)).handle("runs.feedback.record",params) as! JSON; lock.lock(); replies.append(value); lock.unlock() } catch { lock.lock(); failures += 1; lock.unlock() } }
        XCTAssertEqual(failures,0); XCTAssertEqual(replies.count,2); XCTAssertEqual(try store.list("run_feedback").count,1)
    } }
    func testPrivateFlipHidesGetListAndHealthAndTerminalRejects() throws { try fixture { root,store,service in
        _ = try store.put("run",run(root)); let pre = try service.handle("runs.feedback.prepare",["project":root.path,"runId":"run"]) as! JSON
        let saved = try service.handle("runs.feedback.record",["project":root.path,"runId":"run","runHash":pre["runHash"]!,"previousFeedbackHash":NSNull(),"outcome":"good","reason":"Visible review."]) as! JSON
        XCTAssertEqual(((try service.handle("runs.feedback.get",["project":root.path,"id":saved["id"]!]) as! JSON)["outcome"] as? String),"good")
        var hidden = try store.get("run","run")!; hidden["private"] = true; _ = try store.put("run",hidden)
        XCTAssertThrowsError(try service.handle("runs.feedback.get",["project":root.path,"id":saved["id"]!]))
        XCTAssertEqual(((try service.handle("runs.feedback.list",["project":root.path]) as! JSON)["items"] as? [JSON])?.count,0)
        let health = try service.workflowHealthReport(["project":root.path]); XCTAssertEqual((((health["manualFeedback"] as? JSON)?["observed"]) as? Int),0)
        hidden["private"] = false; hidden["state"] = "running"; _ = try store.put("run",hidden)
        XCTAssertThrowsError(try service.handle("runs.feedback.prepare",["project":root.path,"runId":"run"]))
    } }

}
