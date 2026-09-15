import XCTest
@testable import VelaCore

final class LabApprovalAtomicityTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vela-lab-approval-atomic-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        try Data("fixture\n".utf8).write(to:project.appendingPathComponent("fixture.txt"))
        XCTAssertEqual(try AutomationProcess.git(["init","-q"],cwd:project.path).exitCode,0)
        XCTAssertEqual(try AutomationProcess.git(["add","."],cwd:project.path).exitCode,0)
        XCTAssertEqual(try AutomationProcess.git(["-c","user.name=fixture","-c","user.email=fixture@example.invalid","commit","-qm","fixture"],cwd:project.path).exitCode,0)
        let store = try VelaStore(root:base.appendingPathComponent("store"))
        _ = try FoundationService(store:store,sourceRoots:[:],globalHome:base.appendingPathComponent("home")).handle("projects.add",["path":project.path])
        try body(project,store,AutomationService(store:store))
    }

    private func request(_ project: URL) -> JSON {
        ["project":project.path,"title":"Atomic Lab fixture","kind":"context","command":["/usr/bin/true"],"timeoutSeconds":10,"repetitions":1,"baseline":["files":[]],"candidate":["files":[]]]
    }

    func testApprovalInsertFailureRollsBackEvalAndLaterApprovalExecutesExactlyOnce() throws {
        try fixture { project,store,service in
            let database = store.root.appendingPathComponent("vela.sqlite3").path
            let installed = try AutomationProcess.run(["/usr/bin/sqlite3",database,"CREATE TRIGGER reject_lab_approval BEFORE INSERT ON objects WHEN NEW.kind='approval' BEGIN SELECT RAISE(ABORT,'fixture approval write failure'); END;"],cwd:project.path)
            XCTAssertEqual(installed.exitCode,0,installed.output)
            defer { _ = try? AutomationProcess.run(["/usr/bin/sqlite3",database,"DROP TRIGGER IF EXISTS reject_lab_approval;"],cwd:project.path) }
            XCTAssertThrowsError(try service.handle("lab.run",request(project))) { error in
                XCTAssertTrue(error.localizedDescription.contains("fixture approval write failure"),error.localizedDescription)
            }
            XCTAssertTrue(try store.list("eval").isEmpty)
            XCTAssertTrue(try store.list("approval").isEmpty)
            let removed = try AutomationProcess.run(["/usr/bin/sqlite3",database,"DROP TRIGGER reject_lab_approval;"],cwd:project.path)
            XCTAssertEqual(removed.exitCode,0,removed.output)
            let created = try XCTUnwrap(service.handle("lab.run",request(project)) as? JSON)
            let evalID = string(created,"id"), approvalID = string(created,"approvalId")
            let evaluation = try XCTUnwrap(store.get("eval",evalID)), approval = try XCTUnwrap(store.get("approval",approvalID))
            XCTAssertEqual(string(evaluation,"approvalId"),approvalID)
            XCTAssertEqual(string(approval,"runId"),evalID)
            XCTAssertEqual(string((approval["arguments"] as? JSON ?? [:]),"evalId"),evalID)
            let decided = try XCTUnwrap(service.handle("approvals.decide",["id":approvalID,"decision":"approve","snapshotHash":approval["snapshotHash"]!]) as? JSON)
            XCTAssertEqual(string(decided,"state"),"executed")
            XCTAssertEqual(string(try XCTUnwrap(store.get("eval",evalID)),"state"),"completed")
            XCTAssertThrowsError(try service.handle("approvals.decide",["id":approvalID,"decision":"approve","snapshotHash":approval["snapshotHash"]!]))
            XCTAssertEqual(try store.list("eval").count,1)
            XCTAssertEqual(try store.list("approval").count,1)
        }
    }
}
