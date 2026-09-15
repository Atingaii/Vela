import XCTest
@testable import VelaCore

final class SetupEditTests: XCTestCase {
    private func fixture(_ body: (URL, URL, VelaStore, FoundationService, AutomationService) throws -> Void) throws {
        // Foundation canonicalizes /var to /private/var. Keep every derived
        // fixture URL on that same spelling, including the artifact lookup.
        let base = URL(fileURLWithPath:canonicalProject(FileManager.default.temporaryDirectory.path)).appendingPathComponent("vela-setup-edit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let project = base.appendingPathComponent("project"), home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        let store = try VelaStore(root:base.appendingPathComponent("store"))
        let foundation = FoundationService(store:store,sourceRoots:[:],globalHome:home)
        _ = try foundation.handle("projects.add",["path":project.path])
        try body(project,home,store,foundation,AutomationService(store:store))
    }

    private func write(_ path: URL, _ content: String) throws {
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(content.utf8).write(to:path)
    }

    private func scan(_ foundation: FoundationService, _ project: URL) throws {
        _ = try foundation.handle("setup.scan",["project":project.path])
    }

    private func artifact(_ store: VelaStore, _ path: URL) throws -> JSON {
        try XCTUnwrap(try store.get("artifact",stableHash("setup:" + path.path)))
    }

    private func call(_ service: AutomationService, _ method: String, _ params: JSON) throws -> JSON {
        guard let result = try service.handle(method,params) as? JSON else {
            throw VelaError("Expected JSON result for \(method)")
        }
        return result
    }

    private func editable(_ service: AutomationService, _ project: URL, _ artifact: JSON) throws -> JSON {
        let value = try call(service,"setup.edit.get",["project":project.path,"artifactId":artifact["id"]!])
        XCTAssertEqual(value["editable"] as? Bool,true)
        return value
    }

    private func request(_ project: URL, _ artifact: JSON, _ opened: JSON, content: String) -> JSON {
        ["project":project.path,"artifactId":artifact["id"]!,"baseHash":opened["baseHash"]!,"sourceIdentity":opened["sourceIdentity"]!,"content":content]
    }

    func testInstructionAndSkillEditFreezeApprovalApplyRestartUndo() throws {
        try fixture { project,_,store,foundation,service in
            let agents = project.appendingPathComponent("AGENTS.md")
            let skill = project.appendingPathComponent(".agents/skills/review/SKILL.md")
            try write(agents,"# Team rules\n\nVerify the diff.\n")
            try write(skill,"---\nname: review\n---\n\nReview sources.\n")
            try scan(foundation,project)
            let agentsArtifact = try artifact(store,agents), skillArtifact = try artifact(store,skill)
            let opened = try editable(service,project,agentsArtifact)
            XCTAssertEqual(opened["content"] as? String,"# Team rules\n\nVerify the diff.\n")
            let params = request(project,agentsArtifact,opened,content:"# Team rules\n\nVerify the real result.\n")
            let preview = try call(service,"setup.edit.preview",params)
            XCTAssertEqual(preview["path"] as? String,"AGENTS.md")
            XCTAssertEqual(preview["before"] as? String,"# Team rules\n\nVerify the diff.\n")
            XCTAssertEqual(preview["after"] as? String,"# Team rules\n\nVerify the real result.\n")
            let prepared = try call(service,"setup.edit.prepare",params)
            XCTAssertEqual(try String(contentsOf:agents),"# Team rules\n\nVerify the diff.\n")
            let approval = try XCTUnwrap(prepared["approval"] as? JSON)
            XCTAssertEqual(string(approval,"tool"),"setup.file.edit")
            let approvalResult = try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
            XCTAssertEqual(string(approvalResult,"state"),"executed")
            XCTAssertEqual(try String(contentsOf:agents),"# Team rules\n\nVerify the real result.\n")
            XCTAssertThrowsError(try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"]))
            let after = try editable(service,project,agentsArtifact)
            let change = try XCTUnwrap((after["changes"] as? [JSON])?.first)
            XCTAssertEqual(string(change,"state"),"applied")
            XCTAssertEqual(change["canUndo"] as? Bool,true)
            let journalID = try requireString(change,"journalId")
            let journal = try XCTUnwrap(store.get("apply_journal",journalID))
            XCTAssertEqual(string(journal,"origin"),"setup_edit")
            XCTAssertEqual(string(journal,"setupArtifactId"),string(agentsArtifact,"id"))
            XCTAssertThrowsError(try call(service,"setup.edit.undo",["project":project.path,"artifactId":skillArtifact["id"]!,"journalId":journalID]))
            let restarted = AutomationService(store:try VelaStore(root:store.root))
            let undone = try call(restarted,"setup.edit.undo",["project":project.path,"artifactId":agentsArtifact["id"]!,"journalId":journalID])
            XCTAssertEqual(string(undone,"state"),"undone")
            XCTAssertEqual(try String(contentsOf:agents),"# Team rules\n\nVerify the diff.\n")

            let skillOpened = try editable(restarted,project,skillArtifact)
            let skillPreview = try call(restarted,"setup.edit.preview",request(project,skillArtifact,skillOpened,content:""))
            XCTAssertEqual(skillPreview["after"] as? String,"")
        }
    }

    func testStaleIdentityAndSecretsNeverApplyOrEnterReviewPayload() throws {
        try fixture { project,_,store,foundation,service in
            let path = project.appendingPathComponent("AGENTS.md")
            try write(path,"# Safe source\n")
            try scan(foundation,project)
            let source = try artifact(store,path), opened = try editable(service,project,source)
            var stale = request(project,source,opened,content:"# New safe source\n")
            stale["baseHash"] = stableHash("different")
            XCTAssertThrowsError(try call(service,"setup.edit.preview",stale))
            stale = request(project,source,opened,content:"api_key = secret-value")
            XCTAssertThrowsError(try call(service,"setup.edit.preview",stale))
            XCTAssertEqual(try store.list("approval").count,0)

            let prepared = try call(service,"setup.edit.prepare",request(project,source,opened,content:"# Frozen new source\n"))
            let approval = try XCTUnwrap(prepared["approval"] as? JSON)
            try write(path,"# External edit\n")
            let result = try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
            XCTAssertEqual(string(result,"state"),"failed")
            XCTAssertEqual(try String(contentsOf:path),"# External edit\n")
            XCTAssertFalse(try jsonString(store.list("approval")).contains("secret-value"))

            let fresh = try editable(service,project,source)
            let sameBytes = try call(service,"setup.edit.prepare",request(project,source,fresh,content:"# Would not write\n"))
            service.setupEdits.afterVerifiedBeforeApplyForTesting = {
                let replacement = path.deletingLastPathComponent().appendingPathComponent("same-bytes-replacement")
                try Data("# External edit\n".utf8).write(to:replacement)
                guard Darwin.rename(replacement.path,path.path) == 0 else { throw VelaError("Could not atomically replace test source") }
            }
            defer { service.setupEdits.afterVerifiedBeforeApplyForTesting = nil }
            let sameBytesApproval = try XCTUnwrap(sameBytes["approval"] as? JSON)
            let sameBytesResult = try call(service,"approvals.decide",["id":sameBytesApproval["id"]!,"snapshotHash":sameBytesApproval["snapshotHash"]!,"decision":"approve"])
            XCTAssertEqual(string(sameBytesResult,"state"),"failed")
            XCTAssertEqual(try String(contentsOf:path),"# External edit\n")
            XCTAssertEqual(try store.list("apply_journal").count,0)
        }
    }

    func testGlobalUnsupportedRedactedAndLinkedArtifactsAreNotEditable() throws {
        try fixture { project,home,store,foundation,service in
            let global = home.appendingPathComponent(".claude/CLAUDE.md")
            let config = project.appendingPathComponent(".claude/settings.json")
            let agents = project.appendingPathComponent("AGENTS.md")
            try write(global,"Global instruction")
            try write(config,"{}")
            try write(agents,"api_key=synthetic-value")
            _ = try foundation.handle("setup.scan",["scope":"global"])
            try scan(foundation,project)
            let globalArtifact = try artifact(store,global), configArtifact = try artifact(store,config), agentsArtifact = try artifact(store,agents)
            let globalEdit = try call(service,"setup.edit.get",["project":project.path,"artifactId":globalArtifact["id"]!])
            XCTAssertEqual(globalEdit["editable"] as? Bool,false); XCTAssertEqual(globalEdit["reason"] as? String,"global")
            let configEdit = try call(service,"setup.edit.get",["project":project.path,"artifactId":configArtifact["id"]!])
            XCTAssertEqual(configEdit["editable"] as? Bool,false); XCTAssertEqual(configEdit["reason"] as? String,"unsupported_type")
            let redactedEdit = try call(service,"setup.edit.get",["project":project.path,"artifactId":agentsArtifact["id"]!])
            XCTAssertEqual(redactedEdit["editable"] as? Bool,false); XCTAssertEqual(redactedEdit["reason"] as? String,"redacted")

            try write(agents,"# Safe\n"); try scan(foundation,project)
            let safeArtifact = try artifact(store,agents), opened = try editable(service,project,safeArtifact)
            let outside = project.deletingLastPathComponent().appendingPathComponent("outside.md")
            try write(outside,"Outside")
            try FileManager.default.removeItem(at:agents)
            try FileManager.default.createSymbolicLink(at:agents,withDestinationURL:outside)
            let linked = try call(service,"setup.edit.get",["project":project.path,"artifactId":safeArtifact["id"]!])
            XCTAssertEqual(linked["editable"] as? Bool,false)
            XCTAssertThrowsError(try call(service,"setup.edit.prepare",request(project,safeArtifact,opened,content:"# Attempt\n")))
            XCTAssertEqual(try String(contentsOf:outside),"Outside")
        }
    }

    func testAppliedFileWithLinkageFailureRemainsNeedsReviewWithoutReplay() throws {
        try fixture { project,_,store,foundation,service in
            let path = project.appendingPathComponent("AGENTS.md")
            try write(path,"# Before\n"); try scan(foundation,project)
            let source = try artifact(store,path), opened = try editable(service,project,source)
            let prepared = try call(service,"setup.edit.prepare",request(project,source,opened,content:"# After\n"))
            service.setupEdits.afterApplyBeforeLinkForTesting = { throw VelaError("injected setup ledger failure") }
            defer { service.setupEdits.afterApplyBeforeLinkForTesting = nil }
            let approval = try XCTUnwrap(prepared["approval"] as? JSON)
            let result = try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
            XCTAssertEqual(string(result,"state"),"needs_review")
            XCTAssertEqual(try String(contentsOf:path),"# After\n")
            let journalID = try requireString(try XCTUnwrap(result["result"] as? JSON),"journalId")
            let journal = try XCTUnwrap(store.get("apply_journal",journalID))
            XCTAssertEqual(string(journal,"origin"),"setup_edit")
            let view = try editable(service,project,source)
            let change = try XCTUnwrap((view["changes"] as? [JSON])?.first)
            XCTAssertEqual(string(change,"state"),"needs_review")
            XCTAssertEqual(change["canUndo"] as? Bool,false)
            XCTAssertThrowsError(try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"]))
        }
    }

    func testUndoneFileWithLinkageFailureRemainsNeedsReviewWithoutRetry() throws {
        try fixture { project,_,store,foundation,service in
            let path = project.appendingPathComponent("AGENTS.md")
            try write(path,"# Before undo\n"); try scan(foundation,project)
            let source = try artifact(store,path), opened = try editable(service,project,source)
            let prepared = try call(service,"setup.edit.prepare",request(project,source,opened,content:"# After undo\n"))
            let approval = try XCTUnwrap(prepared["approval"] as? JSON)
            _ = try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
            let applied = try editable(service,project,source)
            let journalID = try requireString(try XCTUnwrap((applied["changes"] as? [JSON])?.first),"journalId")
            service.setupEdits.afterUndoBeforeLinkForTesting = { throw VelaError("injected undo ledger failure") }
            defer { service.setupEdits.afterUndoBeforeLinkForTesting = nil }
            let result = try call(service,"setup.edit.undo",["project":project.path,"artifactId":source["id"]!,"journalId":journalID])
            XCTAssertEqual(string(result,"state"),"needs_review")
            XCTAssertEqual(result["outcomeUnknown"] as? Bool,true)
            XCTAssertEqual(try String(contentsOf:path),"# Before undo\n")
            let view = try editable(service,project,source)
            let change = try XCTUnwrap((view["changes"] as? [JSON])?.first)
            XCTAssertEqual(string(change,"state"),"needs_review")
            XCTAssertEqual(change["canUndo"] as? Bool,false)
            XCTAssertThrowsError(try call(service,"setup.edit.undo",["project":project.path,"artifactId":source["id"]!,"journalId":journalID]))
            XCTAssertEqual(string(try XCTUnwrap(store.get("apply_journal",journalID)),"state"),"undone")
        }
    }
}
