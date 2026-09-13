import XCTest
@testable import VelaCore

/// Independent regression cases for a queued change losing source eligibility
/// between observation and dispatch, including the before-only removal shape.
final class WorkflowWatchReviewTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vela-watch-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let project = temp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let root = URL(fileURLWithPath:canonicalProject(project.path))
        let store = try VelaStore(root:temp.appendingPathComponent("store"))
        _ = try store.put("project",["project":root.path,"path":root.path])
        XCTAssertEqual(try AutomationProcess.git(["init","-q"],cwd:root.path).exitCode,0)
        try body(root,store,AutomationService(store:store))
    }

    func testQueuedRemovalCannotDiscloseASourceRevokedDuringDebounce() throws {
        for mode in ["items","output"] {
            try fixture { root,store,service in
                let base = Date(timeIntervalSince1970:1_789_257_600)
                var item = try store.put("library",["id":"revoked-identity","project":root.path,"title":"Cedar","content":"cedar source","private":false,"state":"active"])
                let workflow = try XCTUnwrap(service.handle("workflows.save",[
                    "title":"Revocation during debounce","project":root.path,"trigger":"watch","enabled":true,
                    "watch":["source":"tool","tool":"library.retrieve","arguments":["query":"cedar","k":10],"mode":mode,"everySeconds":30,"minItems":1,"debounceSeconds":10],
                    "steps":[["tool":"git.status","arguments":JSON()]]
                ]) as? JSON)
                try service.tick(at:base)
                item["title"] = "Pine"; item["content"] = "pine source"; item = try store.put("library",item)
                try service.tick(at:base.addingTimeInterval(30))
                let waiting = try XCTUnwrap(store.get("watch_state",string(workflow,"id")))
                XCTAssertEqual((waiting["pending"] as? JSON)?.count,1)
                XCTAssertEqual(try store.list("run").count,0)
                // There is no subsequent read until t=60. This must still be
                // revoked at the dispatch boundary at t=40.
                item["private"] = true; _ = try store.put("library",item)
                try service.tick(at:base.addingTimeInterval(40))
                XCTAssertEqual(try store.list("run").count,0,"Mode \(mode) dispatched a revoked source")
                XCTAssertEqual(try store.list("schedule_event").count,0,"Revocation must happen before claiming an event")
                XCTAssertFalse(try jsonString(store.get("watch_state",string(workflow,"id"))?["pending"] ?? JSON()).contains("revoked-identity"))
            }
        }
    }
}
