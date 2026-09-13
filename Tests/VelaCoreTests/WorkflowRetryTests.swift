import XCTest
@testable import VelaCore

final class WorkflowRetryTests: XCTestCase {
    private func step(_ retry: JSON? = nil) -> JSON {
        var value: JSON = ["tool":"git.status","arguments":JSON()]
        if let retry { value["retry"] = retry }
        return value
    }
    func testRealReadProcessRetriesOnceAndPersistsAttemptReceipts() throws {
        let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("vela-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let count = root.appendingPathComponent("count")
        var current = step(["maxAttempts":2,"initialBackoffMs":50,"maxBackoffMs":50]), checkpoints: [JSON] = []
        let result = try WorkflowRetry.execute(step:&current,tool:"git.status",deadline:Date().addingTimeInterval(3),cancelled:{ false },checkpoint:{ checkpoints.append($0) }) {
            let command = "n=0; [ ! -f '\(count.path)' ] || n=$(cat '\(count.path)'); n=$((n+1)); printf '%s' \"$n\" > '\(count.path)'; [ \"$n\" -eq 1 ] && exit 7; printf ok"
            return try AutomationProcess.run(["/bin/sh","-c",command],cwd:root.path,timeout:1).json
        }
        XCTAssertEqual(intValue(result,"exitCode"),0); XCTAssertEqual(try String(contentsOf:count),"2")
        XCTAssertEqual((current["attempts"] as? [JSON])?.count,2); XCTAssertEqual((current["attempts"] as? [JSON])?.first?["exitCode"] as? Int,7)
        XCTAssertEqual((current["attempts"] as? [JSON])?.last?["state"] as? String,"completed"); XCTAssertTrue(checkpoints.count >= 4)
        XCTAssertEqual(current["retryDeadlineScope"] as? String,"between_attempts_and_backoff")
    }
    func testDefaultDisabledInvalidAndEffectfulPoliciesFailClosed() throws {
        XCTAssertEqual(try WorkflowRetry.policy(step:step(),tool:"git.status").maxAttempts,1)
        for invalid in [["maxAttempts":4,"initialBackoffMs":50,"maxBackoffMs":50] as JSON,["maxAttempts":2,"initialBackoffMs":100,"maxBackoffMs":50],["maxAttempts":true,"initialBackoffMs":50,"maxBackoffMs":50],["maxAttempts":2,"initialBackoffMs":50,"maxBackoffMs":50,"extra":1]] { XCTAssertThrowsError(try WorkflowRetry.policy(step:step(invalid),tool:"git.status")) }
        XCTAssertThrowsError(try WorkflowRetry.policy(step:step(["maxAttempts":2,"initialBackoffMs":50,"maxBackoffMs":50]),tool:"file.write"))
    }
    func testCancellationDeadlineAndThrownProcessErrorDoNotReplay() throws {
        var cancelled = step(["maxAttempts":3,"initialBackoffMs":100,"maxBackoffMs":100]), calls = 0
        let stopped = try WorkflowRetry.execute(step:&cancelled,tool:"git.status",deadline:Date().addingTimeInterval(2),cancelled:{ calls > 0 },checkpoint:{ _ in }) { calls += 1; return ["exitCode":7,"output":"safe read failed","durationMs":0,"timedOut":false,"truncated":false] }
        XCTAssertEqual(calls,1); XCTAssertEqual(cancelled["retryState"] as? String,"cancelled"); XCTAssertEqual(intValue(stopped,"exitCode"),7)
        var expired = step(["maxAttempts":2,"initialBackoffMs":50,"maxBackoffMs":50]); calls = 0
        _ = try WorkflowRetry.execute(step:&expired,tool:"git.status",deadline:Date().addingTimeInterval(-1),cancelled:{ false },checkpoint:{ _ in }) { calls += 1; return JSON() }
        XCTAssertEqual(calls,0); XCTAssertEqual(expired["retryState"] as? String,"deadline_exceeded")
        var error = step(["maxAttempts":2,"initialBackoffMs":50,"maxBackoffMs":50]); calls = 0
        XCTAssertThrowsError(try WorkflowRetry.execute(step:&error,tool:"git.status",deadline:Date().addingTimeInterval(1),cancelled:{ false },checkpoint:{ _ in }) { calls += 1; throw VelaError("process setup uncertain") })
        XCTAssertEqual(calls,1); XCTAssertEqual(error["retryState"] as? String,"needs_review")
        for invalid in [JSON(),["exitCode":true],["exitCode":"0"],["exitCode":-1]] {
            var malformed = step(["maxAttempts":2,"initialBackoffMs":50,"maxBackoffMs":50]); calls = 0
            let result = try WorkflowRetry.execute(step:&malformed,tool:"git.status",deadline:Date().addingTimeInterval(1),cancelled:{ false },checkpoint:{ _ in }) { calls += 1; return invalid }
            XCTAssertEqual(calls,1); XCTAssertEqual(result["outcomeUnknown"] as? Bool,true); XCTAssertEqual(malformed["retryState"] as? String,"needs_review")
        }
    }
    func testWorkflowIntegrationFreezesPolicyAndDoesNotReplayRecordedAttempt() throws {
        let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("vela-retry-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let store = try VelaStore(root:root.appendingPathComponent("store")); _ = try store.put("project",["project":root.path,"path":root.path])
        let service = AutomationService(store:store)
        let workflow = try XCTUnwrap(service.handle("workflows.save",["title":"Retry fixed read","project":root.path,"steps":[["tool":"git.status","retry":["maxAttempts":2,"initialBackoffMs":50,"maxBackoffMs":50]]]]) as? JSON)
        let run = try XCTUnwrap(service.handle("workflows.run",["id":workflow["id"]!,"dryRun":false]) as? JSON)
        let attempts = try XCTUnwrap((run["steps"] as? [JSON])?.first?["attempts"] as? [JSON])
        XCTAssertEqual(attempts.count,2); XCTAssertEqual(string(run,"state"),"failed")
        var stranded = try XCTUnwrap(store.get("run",string(run,"id"))); var steps = stranded["steps"] as! [JSON]
        steps[0]["state"] = "queued"; steps[0]["attempts"] = [["index":1,"state":"started"]]; stranded["steps"] = steps; stranded["state"] = "running"; _ = try store.put("run",stranded)
        let recovered = try service.continueRun(try XCTUnwrap(store.get("run",string(run,"id"))))
        XCTAssertEqual(string(recovered,"state"),"needs_review")
        XCTAssertEqual((recovered["steps"] as? [JSON])?.first?["state"] as? String,"needs_review")
    }
    func testFinalReceiptCompareAndSwapPreservesConcurrentRunUpdate() throws {
        let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("vela-retry-cas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let store = try VelaStore(root:root.appendingPathComponent("store"))
        _ = try store.put("run",["id":"retry-run","project":root.path,"state":"running","steps":[["id":"read","state":"queued"]]])
        var final = try XCTUnwrap(store.get("run","retry-run")); let expected = stableHash(try jsonString(final))
        var external = try XCTUnwrap(store.get("run","retry-run")); external["externalUpdate"] = "must-survive"; _ = try store.put("run",external)
        var steps = final["steps"] as! [JSON]; steps[0]["state"] = "completed"; final["steps"] = steps
        XCTAssertThrowsError(try store.putBatch([("run",final)],expecting:[("run","retry-run",expected)]))
        let current = try XCTUnwrap(store.get("run","retry-run"))
        XCTAssertEqual(current["externalUpdate"] as? String,"must-survive")
        XCTAssertEqual((current["steps"] as? [JSON])?.first?["state"] as? String,"queued")
    }
    func testContinueRunAndFinalDeliveryNeverOverwriteConcurrentTerminalUpdate() throws {
        let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("vela-retry-finalize-cas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let store = try VelaStore(root:root.appendingPathComponent("store")); _ = try store.put("project",["project":root.path,"path":root.path])
        let service = AutomationService(store:store)
        func staleRun(_ id: String, state: String, steps: [JSON]) throws -> JSON {
            _ = try store.put("run",["id":id,"project":root.path,"state":state,"dryRun":true,"steps":steps,"startedAt":"2026-09-13T00:00:00Z"])
            return try XCTUnwrap(store.get("run",id))
        }
        func race(_ source: JSON) throws {
            var newer = source; newer["externalUpdate"] = "must-survive"; _ = try store.put("run",newer)
            XCTAssertThrowsError(try service.continueRun(source))
            XCTAssertEqual((try store.get("run",string(source,"id")))?["externalUpdate"] as? String,"must-survive")
        }
        try race(staleRun("success",state:"running",steps:[["id":"write","tool":"file.write","state":"queued","arguments":JSON()]]))
        try race(staleRun("failed",state:"failed",steps:[["id":"read","tool":"git.status","state":"failed","arguments":JSON()]]))

        _ = try store.put("run_output",["id":"delivery","runId":"delivery","project":root.path,"target":"stdout","content":"done","contentHash":stableHash("done"),"state":"delivered"])
        _ = try store.put("run",["id":"delivery","project":root.path,"state":"completed","dryRun":false,"workflowSnapshot":["output":["target":"stdout"]],"output":"done","outputKnown":true,"steps":[]])
        let delivery = try XCTUnwrap(store.get("run","delivery")); let expected = stableHash(try jsonString(delivery))
        var newer = delivery; newer["externalUpdate"] = "must-survive"; _ = try store.put("run",newer)
        XCTAssertThrowsError(try service.finalizeWorkflowOutput(delivery,expectingRunHash:expected))
        XCTAssertEqual((try store.get("run","delivery"))?["externalUpdate"] as? String,"must-survive")
        XCTAssertEqual(string(try XCTUnwrap(store.get("run_output","delivery")),"state"),"delivered")
    }
}
