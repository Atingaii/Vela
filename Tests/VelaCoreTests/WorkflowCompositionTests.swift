import XCTest
@testable import VelaCore

final class WorkflowCompositionTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-composition-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let project = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        XCTAssertEqual(try AutomationProcess.git(["init","-q"],cwd:project.path).exitCode,0)
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["path":canonicalProject(project.path),"project":canonicalProject(project.path)])
        try body(project,store,AutomationService(store:store))
    }
    private func call(_ service: AutomationService,_ method: String,_ params: JSON) throws -> JSON { try XCTUnwrap(service.handle(method,params) as? JSON) }
    private func save(_ service: AutomationService,_ project: URL,_ id: String,_ arguments: JSON,_ extra: JSON = [:]) throws -> JSON {
        var definition: JSON = ["id":id,"title":id,"project":project.path,"steps":[["id":"report","tool":"agent.run","arguments":arguments]]]
        definition.merge(extra) { _,new in new }; return try call(service,"workflows.save",definition)
    }
    private func pipeline(_ service: AutomationService,_ project: URL,_ id: String,_ stages: [JSON],_ output: JSON = ["target":"stdout"]) throws -> JSON {
        try call(service,"workflows.save",["id":id,"title":id,"project":project.path,"pipeline":stages,"output":output])
    }
    private func run(_ service: AutomationService,_ workflow: JSON,_ dry: Bool = false) throws -> JSON { try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":dry]) }
    private func decide(_ service: AutomationService,_ store: VelaStore,_ decision: String = "approve") throws -> JSON {
        let pending = try XCTUnwrap(store.list("approval").first { string($0,"state") == "pending" })
        return try call(service,"approvals.decide",["id":pending["id"]!,"snapshotHash":pending["snapshotHash"]!,"decision":decision])
    }
    private func context(_ template: String,_ inputs: [JSON] = []) -> JSON { ["version":1,"template":template,"inputs":inputs,"memory":["enabled":false]] }
    private func contextualArgs(_ executable: String = "/bin/echo") -> JSON { ["executable":executable,"args":[WorkflowContext.promptMarker],"promptMode":"workflow_context"] }

    func testPipelineFreezesDefinitionsResumesApprovalsAndDeliversOnlyRootFile() throws {
        try fixture { project,store,service in
            _ = try save(service,project,"first",["executable":"/bin/echo","args":["original"]],["output":["target":"file","path":"child-first.md"]])
            _ = try save(service,project,"second",contextualArgs(),["context":context("received {{input.previous}}"),"output":["target":"file","path":"child-second.md"]])
            let flow = try pipeline(service,project,"sequence",[["workflowId":"first"],["workflowId":"second"]],["target":"file","path":"final.md","inbox":true])
            let started = try run(service,flow)
            XCTAssertEqual(string(started,"state"),"waiting_child")
            XCTAssertFalse(FileManager.default.fileExists(atPath:store.root.appendingPathComponent("output/final.md").path))
            _ = try save(service,project,"second",["executable":"/usr/bin/false","args":[]])
            _ = try decide(service,store)
            XCTAssertEqual(try store.list("approval").filter { string($0,"state") == "pending" }.count,1)
            let secondApproval = try XCTUnwrap(store.list("approval").first { string($0,"state") == "pending" })
            XCTAssertEqual((secondApproval["arguments"] as? JSON)?["args"] as? [String],["received original\n"])
            _ = try decide(service,store)
            let completed = try XCTUnwrap(store.get("run",string(started,"id")))
            XCTAssertEqual(string(completed,"state"),"completed")
            XCTAssertEqual(try String(contentsOf:store.root.appendingPathComponent("output/final.md")),"received original\n\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath:store.root.appendingPathComponent("output/child-first.md").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath:store.root.appendingPathComponent("output/child-second.md").path))
            XCTAssertEqual(try store.list("run").count,3)
            XCTAssertEqual(try store.list("run_output").count,1)
            XCTAssertEqual(try store.list("run_output").first?["unread"] as? Bool,true)
            _ = try call(service,"runs.resume",["id":started["id"]!,"project":project.path])
            XCTAssertEqual(try store.list("run_output").count,1)
            let journals = try store.list("apply_journal").count
            let replay = try call(service,"workflows.replay",["runId":started["id"]!])
            XCTAssertEqual(string(replay,"replayMode"),"captured_composition_records_no_execution")
            XCTAssertEqual(string(replay,"output"),string(completed,"output"))
            XCTAssertEqual(try store.list("approval").count,2)
            XCTAssertEqual(try store.list("run_output").count,1)
            XCTAssertEqual(try store.list("apply_journal").count,journals)
        }
    }

    func testSubworkflowUsesEarlierTypedInputAndReturnsTextToActualParentProcess() throws {
        try fixture { project,store,service in
            _ = try save(service,project,"child",contextualArgs(),["context":context("child {{input.topic}}")])
            let inputs: [JSON] = [["id":"topic","value":"{{input.topic}}"],["id":"summary","workflow":["id":"child","inputs":["topic":"{{topic.text}}"]]]]
            let parent = try save(service,project,"parent",contextualArgs(),["context":context("parent {{summary}}",inputs)])
            let started = try call(service,"workflows.run",["id":parent["id"]!,"dryRun":false,"inputs":["topic":["text":"原文 {{config.secret}}"]]])
            XCTAssertEqual(string(started,"state"),"waiting_child")
            _ = try decide(service,store)
            let pending = try XCTUnwrap(store.list("approval").first { string($0,"state") == "pending" })
            XCTAssertEqual((pending["arguments"] as? JSON)?["args"] as? [String],["parent child 原文 {{config.secret}}\n"])
            _ = try decide(service,store)
            let result = try XCTUnwrap(store.get("run",string(started,"id")))
            XCTAssertEqual(string(result,"output"),"parent child 原文 {{config.secret}}\n\n")
            XCTAssertEqual((result["inputsUsed"] as? [JSON])?.last?["source"] as? String,"workflow")
            XCTAssertEqual(try store.list("run").count,2)
        }
    }

    func testOptionalChildFailureDegradesButRequiredChildStops() throws {
        try fixture { project,store,service in
            _ = try save(service,project,"bad",["executable":"/usr/bin/false","args":[]])
            for optional in [true,false] {
                let parent = try save(service,project,"parent-\(optional)",contextualArgs(),["context":context("result {{child}}",[["id":"child","workflow":["id":"bad"],"optional":optional]])])
                let started = try run(service,parent)
                _ = try decide(service,store)
                let result = try XCTUnwrap(store.get("run",string(started,"id")))
                if optional {
                    XCTAssertEqual(string(result,"state"),"pending_approval")
                    XCTAssertEqual(result["degraded"] as? Bool,true)
                    _ = try decide(service,store,"reject")
                } else { XCTAssertEqual(string(result,"state"),"failed") }
            }
        }
    }

    func testConditionsSkipWithPassThroughAndUnknownDryRunCannotClaimNoOutput() throws {
        try fixture { project,store,service in
            _ = try save(service,project,"empty",["executable":"/usr/bin/true","args":[]])
            _ = try save(service,project,"skip",["executable":"/bin/echo","args":["should not run"]])
            _ = try save(service,project,"fallback",["executable":"/bin/echo","args":["fallback"]])
            let flow = try pipeline(service,project,"conditions",[["workflowId":"empty"],["workflowId":"skip","when":"has_output"],["workflowId":"fallback","when":"no_output"]])
            let started = try run(service,flow)
            _ = try decide(service,store); _ = try decide(service,store)
            let completed = try XCTUnwrap(store.get("run",string(started,"id")))
            XCTAssertEqual(string(completed,"output"),"fallback\n")
            XCTAssertEqual((completed["stageResults"] as? [JSON])?[1]["state"] as? String,"skipped")
            XCTAssertEqual(try store.list("approval").count,2)
            let dry = try run(service,flow,true)
            XCTAssertEqual(string(dry,"state"),"blocked")
            XCTAssertEqual(try store.list("approval").count,2)
        }
    }

    func testInvalidGraphsConditionsAndOutputPathsFailBeforeAnyApproval() throws {
        try fixture { project,store,service in
            _ = try save(service,project,"base",["executable":"/bin/echo","args":["x"]])
            let inner = try pipeline(service,project,"inner",[["workflowId":"base"]])
            XCTAssertThrowsError(try pipeline(service,project,"nested",[["workflowId":inner["id"]!]]))
            XCTAssertThrowsError(try pipeline(service,project,"bad-first",[["workflowId":"base","when":"has_output"]]))
            XCTAssertThrowsError(try pipeline(service,project,"missing",[["workflowId":"absent"]]))
            XCTAssertThrowsError(try pipeline(service,project,"bad-condition",[["workflowId":"base"],["workflowId":"base","when":"eval"]]))
            for path in ["../escape","/absolute","{secret}.md"] { XCTAssertThrowsError(try pipeline(service,project,"escape",[["workflowId":"base"]],["target":"file","path":path])) }
            _ = try save(service,project,"depends-on-base",contextualArgs(),["context":context("{{child}}",[["id":"child","workflow":["id":"base"]]])])
            XCTAssertThrowsError(try save(service,project,"base",contextualArgs(),["context":context("{{child}}",[["id":"child","workflow":["id":"depends-on-base"]]])]))
            XCTAssertEqual(try store.list("approval").count,0)
        }
    }

    func testExplicitResumeUsesKnownApprovalResultWithoutRepeatingActualProcess() throws {
        try fixture { project,store,service in
            let script = project.appendingPathComponent("once.sh")
            try Data("#!/bin/sh\nprintf 'called\\n' >> calls.txt\nprintf 'captured result'\n".utf8).write(to:script)
            _ = try save(service,project,"once",["executable":"/bin/sh","args":[script.path]])
            let flow = try pipeline(service,project,"recover",[["workflowId":"once"]])
            let parent = try run(service,flow)
            var approval = try XCTUnwrap(store.list("approval").first)
            _ = try store.claimState(kind:"approval",id:string(approval,"id"),expected:"pending",newState:"executing")
            let actual = try AutomationProcess.run(["/bin/sh",script.path],cwd:project.path)
            approval["state"] = "executed"; approval["result"] = actual.json; _ = try store.put("approval",approval)
            let reopened = AutomationService(store:try VelaStore(root:store.root))
            _ = try call(reopened,"runs.get",["id":parent["id"]!])
            XCTAssertEqual(try store.get("run",string(parent,"id"))?["state"] as? String,"waiting_child")
            let recovered = try call(reopened,"runs.resume",["id":parent["id"]!,"project":project.path])
            XCTAssertEqual(string(recovered,"state"),"completed")
            XCTAssertEqual(string(recovered,"output"),"captured result")
            XCTAssertEqual(try String(contentsOf:project.appendingPathComponent("calls.txt")),"called\n")
            XCTAssertEqual(try store.list("run").count,2)
        }
    }

    func testUncertainChildAndTamperedGraphNeverRetry() throws {
        try fixture { project,store,service in
            _ = try save(service,project,"leaf",["executable":"/bin/echo","args":["x"]])
            let flow = try pipeline(service,project,"uncertain",[["workflowId":"leaf"]])
            let parent = try run(service,flow)
            let approval = try XCTUnwrap(store.list("approval").first)
            _ = try store.claimState(kind:"approval",id:string(approval,"id"),expected:"pending",newState:"executing")
            let reopened = AutomationService(store:try VelaStore(root:store.root))
            XCTAssertEqual(string(try call(reopened,"runs.resume",["id":parent["id"]!,"project":project.path]),"state"),"waiting_child")
            XCTAssertEqual(try store.list("approval").count,1)
            var tampered = try XCTUnwrap(store.get("run",string(parent,"id"))); tampered["compositionDefinitions"] = JSON(); _ = try store.put("run",tampered)
            XCTAssertThrowsError(try call(reopened,"runs.resume",["id":parent["id"]!,"project":project.path]))
            XCTAssertEqual(try store.list("approval").count,1)
        }
    }

    func testOutputInboxScopeAndConcurrentManagedWrites() throws {
        try fixture { project,store,service in
            let flow = try save(service,project,"report",["executable":"/bin/echo","args":["inbox"]],["output":["target":"inbox"]])
            let started = try run(service,flow); _ = try decide(service,store)
            let output = try call(service,"outputs.get",["id":started["id"]!,"project":project.path])
            XCTAssertEqual(output["unread"] as? Bool,true)
            _ = try call(service,"outputs.markRead",["id":started["id"]!,"project":project.path])
            XCTAssertEqual(try store.get("run_output",string(started,"id"))?["unread"] as? Bool,false)
            let other = project.deletingLastPathComponent().appendingPathComponent("other")
            try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
            _ = try store.put("project",["project":other.path,"path":other.path])
            XCTAssertThrowsError(try call(service,"outputs.get",["id":started["id"]!,"project":other.path]))
            let writers = [SafeApplyService(store:store),SafeApplyService(store:try VelaStore(root:store.root))]
            let results = NSLock(); var failures = 0
            DispatchQueue.concurrentPerform(iterations:2) { index in
                do { _ = try writers[index].writeManagedOutput(path:"output/shared.md",content:String(repeating:String(index),count:10000)) }
                catch { results.lock(); failures += 1; results.unlock() }
            }
            XCTAssertEqual(failures,0)
            let final = try String(contentsOf:store.root.appendingPathComponent("output/shared.md"))
            XCTAssertTrue(final == String(repeating:"0",count:10000) || final == String(repeating:"1",count:10000))
        }
    }

    func testDepthExpandedSizeForeignProjectAndIndirectPipelineAreRejected() throws {
        try fixture { project,store,service in
            _ = try save(service,project,"depth-0",["executable":"/bin/echo","args":["x"]])
            for index in 1...7 {
                _ = try save(service,project,"depth-\(index)",contextualArgs(),["context":context("{{child}}",[["id":"child","workflow":["id":"depth-\(index-1)"]]])])
            }
            XCTAssertThrowsError(try save(service,project,"depth-8",contextualArgs(),["context":context("{{child}}",[["id":"child","workflow":["id":"depth-7"]]])]))
            let inputs: [JSON] = (0..<4).map { ["id":"input\($0)","workflow":["id":"depth-0"]] }
            _ = try save(service,project,"wide",contextualArgs(),["context":context("{{input0}}",inputs)])
            XCTAssertThrowsError(try pipeline(service,project,"too-wide",(0..<16).map { ["id":"s\($0)","workflowId":"wide"] }))
            _ = try pipeline(service,project,"inside",[["workflowId":"depth-0"]])
            _ = try save(service,project,"bridge",contextualArgs(),["context":context("{{child}}",[["id":"child","workflow":["id":"inside"]]])])
            XCTAssertThrowsError(try pipeline(service,project,"indirect",[["workflowId":"bridge"]]))
            let other = project.deletingLastPathComponent().appendingPathComponent("foreign")
            try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
            _ = try store.put("project",["project":other.path,"path":other.path])
            _ = try save(service,other,"foreign-child",["executable":"/bin/echo","args":["private"]])
            XCTAssertThrowsError(try pipeline(service,project,"cross-project",[["workflowId":"foreign-child"]]))
            XCTAssertEqual(try store.list("approval").count,0)
        }
    }

    func testOutputSymlinkCannotEscapeAndUncertainChildBlocksParent() throws {
        try fixture { project,store,service in
            let outside = project.appendingPathComponent("sentinel.txt")
            try Data("preserved".utf8).write(to:outside)
            try FileManager.default.createSymbolicLink(at:store.root.appendingPathComponent("output"),withDestinationURL:project)
            let flow = try save(service,project,"unsafe-output",["executable":"/bin/echo","args":["replacement"]],["output":["target":"file","path":"sentinel.txt"]])
            let started = try run(service,flow); _ = try decide(service,store)
            let ended = try XCTUnwrap(store.get("run",string(started,"id")))
            XCTAssertEqual(string(ended,"state"),"needs_review")
            XCTAssertEqual(string(ended,"failureStage"),"output")
            XCTAssertEqual(try String(contentsOf:outside),"preserved")
            _ = try save(service,project,"leaf-review",["executable":"/bin/echo","args":["x"]])
            let graph = try pipeline(service,project,"review-parent",[["workflowId":"leaf-review"]])
            let parent = try run(service,graph)
            var child = try XCTUnwrap(store.get("run",string(parent,"waitingChildId")))
            child["state"] = "needs_review"; _ = try store.put("run",child)
            let reviewed = try call(service,"runs.resume",["id":parent["id"]!,"project":project.path])
            XCTAssertEqual(string(reviewed,"state"),"needs_review")
            XCTAssertEqual(try store.list("approval").filter { string($0,"state") == "pending" }.count,1)
        }
    }
}
