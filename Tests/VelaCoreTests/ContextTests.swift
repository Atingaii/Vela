import XCTest
@testable import VelaCore

final class ContextTests: XCTestCase {
    private func call(_ service: ContextService, _ method: String, _ params: JSON) throws -> JSON {
        let value = try service.handle(method,params)
        return try XCTUnwrap(value as? JSON)
    }

    func testGuidelineVersionAndProjectBoundary() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-context-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let root = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        let context = ContextService(store:store)
        let first = try call(context,"guidelines.save",["title":"Review convention","content":"Explain the observed failure.","project":root.path])
        let second = try call(context,"guidelines.save",["id":first["id"]!,"title":"Review convention","content":"Explain the observed failure and its regression test.","project":root.path])
        XCTAssertEqual(second["version"] as? Int,2)
        XCTAssertEqual(try store.list("guideline_version").count,2)
        XCTAssertThrowsError(try context.handle("guidelines.save",["id":first["id"]!,"title":"Cross project","content":"Move","project":temporary.path]))
    }

    func testWorkflowDraftUsesActualPackageScriptsAndDoesNotExecuteOrSave() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-draft-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let root = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data(#"{"packageManager":"pnpm@9.0.0","scripts":{"test":"touch should-not-exist","typecheck":"tsc --noEmit"}}"#.utf8).write(to:root.appendingPathComponent("package.json"))
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["title":"Fixture","path":root.path,"project":root.path])
        let context = ContextService(store:store)
        let result = try call(context,"workflows.build",["project":root.path,"description":"Agent 完成后查看 diff，运行测试和 typecheck"])
        let workflow = try XCTUnwrap(result["workflow"] as? JSON)
        let steps = try XCTUnwrap(workflow["steps"] as? [JSON])
        XCTAssertEqual(steps.count,3)
        XCTAssertEqual((steps[1]["arguments"] as? JSON)?["executable"] as? String,"pnpm")
        XCTAssertEqual(workflow["trigger"] as? String,"session_completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("should-not-exist").path))
        XCTAssertEqual(try store.list("workflow").count,0)
        XCTAssertEqual(result["saved"] as? Bool,false)
    }
}
