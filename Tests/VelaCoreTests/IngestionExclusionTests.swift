import XCTest
@testable import VelaCore

final class IngestionExclusionTests: XCTestCase {
    var root: URL!, project: URL!, other: URL!, logs: URL!, store: VelaStore!, service: FoundationService!
    override func setUpWithError() throws {
        root=URL(fileURLWithPath:canonicalProject(FileManager.default.temporaryDirectory.path)).appendingPathComponent("vela-ingestion-exclusion-"+UUID().uuidString)
        project=root.appendingPathComponent("project"); other=root.appendingPathComponent("other"); logs=root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true); try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:logs.appendingPathComponent("claude/nested"),withIntermediateDirectories:true)
        store=try VelaStore(root:root.appendingPathComponent("store")); service=FoundationService(store:store,sourceRoots:["claude":[logs.appendingPathComponent("claude")]],globalHome:root)
        _=try call("projects.add",["path":project.path]); _=try call("projects.add",["path":other.path])
        let row: JSON=["type":"user","uuid":"known","sessionId":"known","cwd":project.path,"message":["role":"user","content":"known"]]
        try Data((try jsonString(row)+"\n").utf8).write(to:logs.appendingPathComponent("claude/nested/known.jsonl")); _=try call("sessions.refresh")
    }
    override func tearDownWithError() throws { service=nil; store=nil; try? FileManager.default.removeItem(at:root) }
    func call(_ method:String,_ params:JSON = [:]) throws -> JSON {
        let result = try service.handle(method,params)
        return try XCTUnwrap(result as? JSON)
    }
    func testStrictRuleInputsOwnershipBoundAndIdempotency() throws {
        for key in ["pathGlob","provider","id"] { XCTAssertThrowsError(try call("ingestion.exclusions.upsert",["project":project.path,key:1])) }
        XCTAssertThrowsError(try call("ingestion.exclusions.upsert",["project":"relative","pathGlob":"nested/*.jsonl","provider":"claude"]))
        XCTAssertThrowsError(try call("ingestion.exclusions.upsert",["project":root.appendingPathComponent("missing").path]))
        for glob in ["/x","a//b","a/./b","a/../b","a\u{0}b","a[b]"] { XCTAssertThrowsError(try call("ingestion.exclusions.upsert",["project":project.path,"provider":"claude","pathGlob":glob])) }
        let first=try call("ingestion.exclusions.upsert",["project":project.path,"provider":"claude","pathGlob":"nested/*.jsonl"]); let id=string(first,"id")
        let revisionBefore = try store.get("ingestion_policy_revision",stableHash(project.path))
        let second=try call("ingestion.exclusions.upsert",["project":project.path,"provider":"claude","pathGlob":"nested/*.jsonl"]); XCTAssertEqual(string(second,"id"),id)
        XCTAssertEqual(try jsonString(revisionBefore ?? [:]),try jsonString(store.get("ingestion_policy_revision",stableHash(project.path)) ?? [:]))
        XCTAssertThrowsError(try call("ingestion.exclusions.upsert",["id":id,"project":other.path]))
        XCTAssertThrowsError(try call("ingestion.exclusions.remove",["id":id,"project":other.path]))
        for i in 0..<256 { _ = try call("ingestion.exclusions.upsert",["id":"cap-\(i)","project":other.path]) }
        let listed = try XCTUnwrap(service.handle("ingestion.exclusions.list",["project":other.path]) as? [JSON])
        XCTAssertEqual(listed.count,256)
        XCTAssertThrowsError(try call("ingestion.exclusions.upsert",["id":"cap-overflow","project":other.path]))
        XCTAssertNil(try store.get("ingestion_exclusion","cap-overflow"))
        _ = try store.put("ingestion_exclusion",["id":"manual-overflow","project":other.path,"scope":"project","provider":"","pathGlob":NSNull()])
        XCTAssertThrowsError(try service.handle("ingestion.exclusions.list",["project":other.path]))
        XCTAssertThrowsError(try IngestionExclusionService(store:store).excludes(project:other.path,provider:"codex",relative:"x.jsonl"))
    }
}
