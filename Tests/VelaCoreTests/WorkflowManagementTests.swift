import XCTest
@testable import VelaCore
import Darwin

final class WorkflowManagementTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-workflow-management-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:directory.appendingPathComponent("store"))
        _ = try store.put("project",["path":project.path,"project":project.path])
        try body(project,store,AutomationService(store:store))
    }
    private func call(_ service: AutomationService,_ method: String,_ params: JSON) throws -> JSON {
        let valueToUnwrap = try service.handle(method,params) as? JSON
        return try XCTUnwrap(valueToUnwrap)
    }
    private func save(_ service: AutomationService,_ project: URL,_ id: String,_ extra: JSON = [:]) throws -> JSON {
        var params: JSON = ["id":id,"title":id,"project":project.path,"description":"Original body","steps":[["id":"echo","tool":"agent.run","arguments":["executable":"/bin/echo","args":["data"]]]]]
        params.merge(extra) { _,new in new }; return try call(service,"workflows.save",params)
    }
    private func request(_ service: AutomationService,_ project: URL,_ id: String,_ extra: JSON = [:]) throws -> JSON {
        let inspected = try call(service,"workflows.get",["id":id,"project":project.path])
        var result: JSON = ["id":id,"project":project.path,"snapshotHash":inspected["snapshotHash"]!]
        result.merge(extra) { _,new in new }; return result
    }

    func testInspectAndValidationDoNotImportHandEditsOrRunAnything() throws {
        try fixture { project,store,service in
            let saved = try save(service,project,"edited")
            let path = try XCTUnwrap(saved["assetPath"] as? String)
            let markdown = try String(contentsOfFile:path).replacingOccurrences(of:"Original body",with:"人工保留的说明\n下一段 {{literal}}")
            try Data(markdown.utf8).write(to:URL(fileURLWithPath:path))
            let original = try jsonString(try XCTUnwrap(store.workflowRecord("edited")))
            let inspected = try call(service,"workflows.get",["id":"edited","project":project.path])
            XCTAssertEqual(inspected["valid"] as? Bool,true)
            XCTAssertTrue(string(inspected["definition"] as? JSON ?? [:],"markdownBody").contains("人工保留的说明"))
            _ = try call(service,"workflows.validate",["project":project.path])
            XCTAssertEqual(try jsonString(try XCTUnwrap(store.workflowRecord("edited"))),original)
            XCTAssertTrue(try store.list("run").isEmpty)
            XCTAssertTrue(try store.list("approval").isEmpty)
            _ = try call(service,"workflows.setEnabled",try request(service,project,"edited",["enabled":false]))
            XCTAssertTrue(try String(contentsOfFile:path).contains("人工保留的说明\n下一段 {{literal}}"))
        }
    }

    func testValidationPagesIsolateMalformedUnsafeAndOversizedAssets() throws {
        try fixture { project,store,service in
            let bad = try save(service,project,"a-bad")
            let link = try save(service,project,"b-link")
            let large = try save(service,project,"c-large")
            _ = try save(service,project,"d-good")
            try Data("invalid header".utf8).write(to:URL(fileURLWithPath:string(bad,"assetPath")))
            try FileManager.default.removeItem(atPath:string(link,"assetPath"))
            try FileManager.default.createSymbolicLink(atPath:string(link,"assetPath"),withDestinationPath:project.appendingPathComponent("outside").path)
            try Data(repeating:65,count:2_097_153).write(to:URL(fileURLWithPath:string(large,"assetPath")))
            let page1 = try call(service,"workflows.validate",["project":project.path,"limit":2])
            XCTAssertEqual((page1["results"] as? [JSON])?.count,2)
            XCTAssertTrue((page1["results"] as? [JSON] ?? []).allSatisfy { $0["valid"] as? Bool == false })
            let page2 = try call(service,"workflows.validate",["project":project.path,"limit":2,"cursor":page1["cursor"]!])
            XCTAssertEqual((page2["results"] as? [JSON])?.map { string($0,"id") },["c-large","d-good"])
            XCTAssertEqual((page2["results"] as? [JSON])?.last?["valid"] as? Bool,true)
            XCTAssertTrue(page2["cursor"] is NSNull)
            XCTAssertEqual(try store.workflowIdentities(project:project.path).count,4)
        }
    }

    func testCloneIsDisabledWithExactProvenanceAndStaleReviewCannotMutate() throws {
        try fixture { project,store,service in
            let original = try save(service,project,"source",["enabled":true])
            let reviewed = try request(service,project,"source",["title":"copy"])
            let clone = try call(service,"workflows.clone",reviewed)
            XCTAssertNotEqual(string(clone,"id"),"source")
            XCTAssertEqual(clone["enabled"] as? Bool,false)
            XCTAssertEqual((clone["clonedFrom"] as? JSON)?["workflowId"] as? String,"source")
            XCTAssertEqual((clone["clonedFrom"] as? JSON)?["snapshotHash"] as? String,reviewed["snapshotHash"] as? String)
            XCTAssertEqual(try jsonString(try XCTUnwrap(store.workflowRecord("source"))),try jsonString(original))
            _ = try save(service,project,"source",["description":"changed"])
            var stale = reviewed; stale["enabled"] = false
            XCTAssertThrowsError(try call(service,"workflows.setEnabled",stale))
            XCTAssertThrowsError(try call(service,"workflows.remove",stale))
            XCTAssertThrowsError(try call(service,"workflows.clone",stale))
            XCTAssertTrue(try store.list("run").isEmpty)
        }
    }

    func testArchivePreservesHistoryBlocksUseAndRestoresDisabled() throws {
        try fixture { project,store,service in
            let original = try save(service,project,"recover",["enabled":true])
            _ = try call(service,"workflows.run",["id":"recover","dryRun":true])
            let archived = try call(service,"workflows.remove",try request(service,project,"recover"))
            XCTAssertEqual(string(archived,"state"),"archived")
            XCTAssertEqual(archived["enabled"] as? Bool,false)
            XCTAssertTrue(FileManager.default.fileExists(atPath:string(original,"assetPath")))
            XCTAssertEqual(try store.list("run").count,1)
            XCTAssertThrowsError(try call(service,"workflows.run",["id":"recover","dryRun":false]))
            XCTAssertThrowsError(try save(service,project,"recover"))
            let restored = try call(service,"workflows.restore",try request(service,project,"recover"))
            XCTAssertEqual(string(restored,"state"),"active")
            XCTAssertEqual(restored["enabled"] as? Bool,false)
            XCTAssertEqual(intValue(restored,"version"),3)
            XCTAssertEqual(try store.list("workflow_version").count,3)
        }
    }

    func testArchivedEditsArePreservedUntilOriginalAssetIsRepaired() throws {
        try fixture { project,_,service in
            _ = try save(service,project,"archived-edits")
            let archived = try call(service,"workflows.remove",try request(service,project,"archived-edits"))
            let url = URL(fileURLWithPath:string(archived,"assetPath"))
            let original = try Data(contentsOf:url)
            let edited = String(decoding:original,as:UTF8.self).replacingOccurrences(of:"Original body",with:"Do not discard my edit")
            try Data(edited.utf8).write(to:url)
            XCTAssertThrowsError(try call(service,"workflows.restore",try request(service,project,"archived-edits")))
            XCTAssertEqual(try String(contentsOf:url),edited)
            try original.write(to:url)
            let restored = try call(service,"workflows.restore",try request(service,project,"archived-edits"))
            XCTAssertEqual(string(restored,"state"),"active")
        }
    }

    func testArchiveRefusesActiveRunDependencyAndForeignProject() throws {
        try fixture { project,store,service in
            _ = try save(service,project,"child")
            _ = try call(service,"workflows.save",["id":"parent","title":"parent","project":project.path,"pipeline":[["workflowId":"child"]]])
            XCTAssertThrowsError(try call(service,"workflows.remove",try request(service,project,"child")))
            _ = try call(service,"workflows.remove",try request(service,project,"parent"))
            _ = try call(service,"workflows.run",["id":"child","dryRun":false])
            XCTAssertThrowsError(try call(service,"workflows.remove",try request(service,project,"child")))
            let foreign = project.deletingLastPathComponent().appendingPathComponent("foreign")
            try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:true)
            _ = try store.put("project",["path":foreign.path,"project":foreign.path])
            XCTAssertThrowsError(try call(service,"workflows.get",["project":foreign.path,"id":"child"]))
            XCTAssertEqual(try store.list("approval").count,1)
        }
    }

    func testBoundedReaderRejectsFIFOsLinksAndHardlinksWithoutBlocking() throws {
        try fixture { project,store,service in
            let workflow = try save(service,project,"fifo")
            let path = string(workflow,"assetPath")
            try FileManager.default.removeItem(atPath:path)
            XCTAssertEqual(mkfifo(path,0o600),0)
            let began = Date()
            XCTAssertThrowsError(try store.get("workflow","fifo"))
            XCTAssertThrowsError(try service.files.readSnapshot(project:store.root.path,path:"assets/workflow/fifo.md"))
            XCTAssertLessThan(Date().timeIntervalSince(began),1)
            let target = project.appendingPathComponent("blocked-output")
            XCTAssertEqual(mkfifo(target.path,0o600),0)
            XCTAssertThrowsError(try service.freezeArguments(tool:"file.write",arguments:["path":"blocked-output","content":"must not write"],project:project.path))
            try FileManager.default.removeItem(atPath:path)
            let source = project.appendingPathComponent("source")
            try Data("text".utf8).write(to:source)
            XCTAssertEqual(link(source.path,path),0)
            XCTAssertThrowsError(try store.get("workflow","fifo"))
            try FileManager.default.removeItem(atPath:path)
            try FileManager.default.createSymbolicLink(atPath:path,withDestinationPath:source.path)
            XCTAssertThrowsError(try FoundationFile.readUTF8(root:store.root,path:"assets/workflow/fifo.md"))
        }
    }
}
