import XCTest
@testable import VelaCore

final class WorkflowHealthTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("vela-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let store = try VelaStore(root:root.appendingPathComponent("store")); _ = try store.put("project",["project":root.path,"path":root.path])
        try body(root,store,AutomationService(store:store))
    }
    private func run(_ root: URL, id: String, state: String, version: Int = 1, dry: Bool = false, steps: [JSON] = []) -> JSON {
        ["id":id,"project":root.path,"workflowId":"digest","workflowVersion":version,"state":state,"dryRun":dry,"startedAt":"2026-09-13T01:00:00Z","completedAt":"2026-09-13T01:00:01Z","durationMs":100,"steps":steps]
    }
    func testStatesVersionsDryRunsAndEvidenceOnlyFindings() throws {
        try fixture { root,store,service in
            _ = try store.put("run",run(root,id:"ok",state:"completed",steps:[["id":"s1","tool":"git.status","state":"completed","exitCode":0]]))
            _ = try store.put("run",run(root,id:"bad",state:"failed",version:1,steps:[["id":"s2","tool":"git.diff","state":"failed","exitCode":1,"timedOut":true]]))
            _ = try store.put("run",run(root,id:"uncertain",state:"needs_review",version:2,steps:[["id":"s3","tool":"agent.loop","state":"needs_review","turnCapReached":true]]))
            _ = try store.put("run",run(root,id:"cancelled",state:"cancelled",version:2))
            _ = try store.put("run",run(root,id:"dry",state:"completed",dry:true))
            _ = try store.put("run",run(root,id:"inconsistent",state:"completed",version:2,steps:[["id":"s4","tool":"git.log","state":"failed","exitCode":1]]))
            let report = try service.workflowHealthReport(["project":root.path,"id":"digest","limit":2])
            XCTAssertEqual(intValue(report,"runs"),5); XCTAssertEqual(intValue(report,"completedRuns"),3); XCTAssertEqual(intValue(report,"successes"),2); XCTAssertEqual(intValue(report,"failures"),1)
            XCTAssertEqual((report["stateCounts"] as? JSON)?["cancelled"] as? Int,1)
            XCTAssertEqual((report["window"] as? JSON)?["dryRunsExcluded"] as? Int,1)
            let codes = Set((report["findings"] as? [JSON] ?? []).map { string($0,"code") })
            XCTAssertTrue(codes.contains("timeout_observed") || codes.contains("turn_cap_observed") || codes.contains("inconsistent_completion"))
            XCTAssertFalse(try jsonString(report).contains("output"))
            XCTAssertEqual((report["items"] as? [JSON])?.count,2); XCTAssertEqual(report["truncated"] as? Bool,true)
            let next = try service.workflowHealthReport(["project":root.path,"id":"digest","limit":2,"cursor":report["cursor"]!])
            XCTAssertFalse((next["items"] as? [JSON] ?? []).contains { string($0,"id") == string((report["items"] as? [JSON] ?? [[:]])[0],"id") })
        }
    }
    func testCompatibilityAggregateAndStrictScope() throws {
        try fixture { root,store,service in
            _ = try store.put("run",run(root,id:"ok",state:"completed"))
            let aggregate = try service.workflowHealthReport([:])
            XCTAssertEqual(aggregate["workflowId"] as? String,"")
            XCTAssertTrue(aggregate["successRate"] is Double); XCTAssertEqual((aggregate["items"] as? [JSON])?.count,0)
            XCTAssertEqual(aggregate["detailAvailability"] as? String,"requires_project")
            XCTAssertThrowsError(try service.workflowHealthReport(["project":root.path,"limit":true]))
            XCTAssertThrowsError(try service.workflowHealthReport(["project":root.path,"since":"not-a-date"]))
            XCTAssertThrowsError(try service.workflowHealthReport(["project":"/unregistered"]))
        }
    }
    func testSourceCapDurationVersionAndMissingMetadataRemainExplicit() throws {
        try fixture { root,store,service in
            let foreign = root.deletingLastPathComponent().appendingPathComponent("foreign")
            for index in 0..<10_000 {
                var row = run(foreign,id:"foreign-\(index)",state:"completed")
                row["workflowId"] = "foreign"; _ = try store.put("run",row)
                _ = try store.put("approval",["id":"foreign-approval-\(index)","project":foreign.path,"runId":"foreign-\(index)","state":"rejected"])
            }
            var target = run(root,id:"target",state:"completed",version:1); target.removeValue(forKey:"durationMs"); target["startedAt"] = "2026-09-13T01:00:00.250Z"; target["steps"] = [["id":"missing","tool":"git.status","state":"completed"]]
            _ = try store.put("run",target)
            var otherWorkflow = run(root,id:"other-v1",state:"failed",version:1); otherWorkflow["workflowId"] = "other"; otherWorkflow["durationMs"] = 0
            _ = try store.put("run",otherWorkflow)
            var unknown = run(root,id:"unknown",state:"completed"); unknown.removeValue(forKey:"workflowVersion"); unknown.removeValue(forKey:"durationMs")
            _ = try store.put("run",unknown)
            _ = try store.put("approval",["id":"target-rejected","project":root.path,"runId":"target","state":"rejected"])
            let report = try service.workflowHealthReport(["project":root.path,"since":"2026-09-13T01:00:00.100Z"])
            XCTAssertEqual(intValue(report,"runs"),1); XCTAssertEqual(report["aggregateIncomplete"] as? Bool,false)
            let sourceScan = report["sourceScan"] as? JSON
            XCTAssertTrue((((sourceScan?["runs"] as? JSON)?["capReached"]) as? Bool) == false)
            XCTAssertTrue((((sourceScan?["approvals"] as? JSON)?["capReached"]) as? Bool) == false)
            XCTAssertEqual(intValue(report,"approvalRejected"),1)
            XCTAssertEqual(intValue(report,"durationSamples"),0); XCTAssertEqual(intValue(report,"durationMissing"),1); XCTAssertTrue(report["averageDurationMs"] is NSNull)
            let firstStep = ((report["items"] as? [JSON])?.first?["stepStates"] as? [JSON])?.first
            XCTAssertTrue(firstStep?["timedOut"] is NSNull); XCTAssertTrue(firstStep?["truncated"] is NSNull)
            let full = try service.workflowHealthReport(["project":root.path])
            let groups = full["versionGroups"] as? [JSON] ?? []
            XCTAssertEqual(Set(groups.map { string($0,"workflowId") }),Set(["digest","other"]))
            XCTAssertTrue(groups.contains { string($0,"workflowId") == "digest" && string($0,"versionAvailability") == "unknown" })
            let globalStarted = Date()
            let global = try service.workflowHealthReport([:])
            let elapsed = Int(Date().timeIntervalSince(globalStarted) * 1000)
            XCTAssertEqual(global["aggregateIncomplete"] as? Bool,true); XCTAssertEqual(global["coverage"] as? String,"bounded_by_source_scan_cap")
            let globalScan = global["sourceScan"] as? JSON
            XCTAssertEqual(((globalScan?["approvals"] as? JSON)?["capReached"]) as? Bool,true)
            let scannedRuns = ((globalScan?["runs"] as? JSON)?["scanned"] as? Int) ?? -1
            let scannedApprovals = ((globalScan?["approvals"] as? JSON)?["scanned"] as? Int) ?? -1
            print("WorkflowHealth global capped scan runs=\(scannedRuns) approvals=\(scannedApprovals) elapsedMs=\(elapsed)")
        }
    }
}
