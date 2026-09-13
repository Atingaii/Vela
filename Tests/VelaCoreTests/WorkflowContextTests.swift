import XCTest
@testable import VelaCore

final class WorkflowContextTests: XCTestCase {
    private func fixture(_ work: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-workflow-context-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let root = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["title":"Context fixture","path":root.path,"project":root.path])
        try Data("printf '%s' \"$1\" > received.txt\nprintf '%s' \"$1\"\n".utf8).write(to:root.appendingPathComponent("receive.sh"))
        try work(root,store,AutomationService(store:store))
    }
    private func call(_ service: AutomationService, _ method: String, _ params: JSON) throws -> JSON {
        let valueToUnwrap = try service.handle(method,params) as? JSON
        return try XCTUnwrap(valueToUnwrap)
    }
    private func step() -> JSON {
        ["tool":"agent.run","arguments":["executable":"/bin/sh","args":["receive.sh",WorkflowContext.promptMarker],"promptMode":"workflow_context"]]
    }
    private func save(_ service: AutomationService, _ root: URL, _ context: JSON, guidelines: [String] = []) throws -> JSON {
        try call(service,"workflows.save",["title":"Context workflow","project":root.path,"context":context,"guidelines":guidelines,"steps":[step()]])
    }
    private func approve(_ service: AutomationService, _ store: VelaStore) throws -> JSON {
        let approval = try XCTUnwrap(store.list("approval").first { string($0,"state") == "pending" })
        return try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
    }

    func testApprovedProcessReceivesFrozenPromptAfterAssetsChange() throws {
        try fixture { root,store,service in
            let guideline = try XCTUnwrap(ContextService(store:store).handle("guidelines.save",["title":"Style","project":root.path,"content":"Use actual evidence, verbatim 中文." ]) as? JSON)
            let memory = try XCTUnwrap(MemoryService(store:store).handle("memory.save",["title":"Evidence preference","project":root.path,"content":"evidence: retain the source","state":"active"]) as? JSON)
            let template = "Evidence task: {{input.task}}\nSource: {{pasted}}\n{{guidelines}}\n{{memory}}"
            let workflow = try save(service,root,["version":1,"template":template,"inputs":[["id":"pasted","source":"stdin"]]],guidelines:[string(guideline,"id")])
            let incoming = "literal {{guidelines}} ' \" $(touch accidental) ; 中文"
            let run = try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":false,"inputs":["task":"review evidence"],"stdin":incoming])
            XCTAssertEqual(string(run,"state"),"pending_approval")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("received.txt").path))
            let snapshot = try XCTUnwrap(run["contextSnapshot"] as? JSON)
            let prompt = string(snapshot,"renderedPrompt")
            XCTAssertTrue(prompt.contains(incoming))
            XCTAssertTrue(prompt.contains("Use actual evidence, verbatim 中文."))
            XCTAssertTrue(prompt.contains("evidence: retain the source"))
            XCTAssertEqual((snapshot["guidelinesUsed"] as? [JSON])?.first?["version"] as? Int,1)
            XCTAssertEqual((snapshot["memoryUsed"] as? [JSON])?.first?["contentHash"] as? String,stableHash("evidence: retain the source"))
            _ = try ContextService(store:store).handle("guidelines.save",["id":guideline["id"]!,"title":"Style","project":root.path,"content":"LATER GUIDELINE"])
            _ = try MemoryService(store:store).handle("memory.save",["id":memory["id"]!,"title":"Evidence preference","project":root.path,"content":"LATER MEMORY","state":"active"])
            _ = try call(service,"workflows.save",["id":workflow["id"]!,"title":"Later workflow","project":root.path,"context":["version":1,"template":"LATER TEMPLATE"],"steps":[step()]])
            let decision = try approve(service,store)
            XCTAssertEqual(string(decision,"state"),"executed")
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("received.txt")),prompt)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("accidental").path))
            let completed = try XCTUnwrap(decision["run"] as? JSON)
            let result = try XCTUnwrap((completed["steps"] as? [JSON])?.first)
            XCTAssertEqual(string(result,"output"),prompt)
            XCTAssertEqual(string(result,"contextPromptHash"),stableHash(prompt))
            XCTAssertEqual(string(result,"contextDelivery"),"argv")
            XCTAssertThrowsError(try call(service,"approvals.decide",["id":decision["id"]!,"snapshotHash":decision["snapshotHash"]!,"decision":"approve"]))
        }
    }

    func testDryRunRendersWithoutExecutingAndLegacyArgumentsStayLiteral() throws {
        try fixture { root,store,service in
            let workflow = try save(service,root,["version":1,"template":"Hello {{input.name}}","memory":["enabled":false]])
            let run = try call(service,"workflows.run",["id":workflow["id"]!,"inputs":["name":"原文"],"dryRun":true])
            XCTAssertEqual(string(run,"state"),"completed")
            XCTAssertEqual((run["contextSnapshot"] as? JSON)?["renderedPrompt"] as? String,"Hello 原文")
            XCTAssertEqual((run["steps"] as? [JSON])?.first?["state"] as? String,"stubbed")
            XCTAssertEqual(try store.list("approval").count,0)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("received.txt").path))
            let legacy = try call(service,"workflows.save",["title":"Literal legacy","project":root.path,"steps":[["tool":"agent.run","arguments":["executable":"/bin/sh","args":["receive.sh",WorkflowContext.promptMarker]]]]])
            _ = try call(service,"workflows.run",["id":legacy["id"]!,"dryRun":false])
            _ = try approve(service,store)
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("received.txt")),WorkflowContext.promptMarker)
            XCTAssertThrowsError(try call(service,"workflows.run",["id":legacy["id"]!,"inputs":["unexpected":"data"]]))
        }
    }

    func testPrivateAndForeignAssetsCannotEnterContext() throws {
        try fixture { root,store,service in
            let other = root.deletingLastPathComponent().appendingPathComponent("foreign")
            for (id,extra) in [("private",["private":true] as JSON),("foreign",["project":other.path]),("candidate",["state":"candidate"])] {
                var item: JSON = ["id":id,"title":"evidence","project":root.path,"content":"FORBIDDEN \(id)","state":"active","scope":"project"]
                item.merge(extra) { _,new in new }; _ = try store.put("memory",item)
            }
            _ = try store.put("memory",["id":"allowed","title":"evidence","project":root.path,"content":"ALLOWED MEMORY","state":"active","scope":"project"])
            _ = try store.put("library",["title":"evidence","project":root.path,"content":"PUBLIC LIBRARY","private":false])
            _ = try store.put("library",["title":"evidence","project":root.path,"content":"FORBIDDEN LIBRARY","private":true])
            _ = try store.put("library",["title":"evidence","project":other.path,"content":"FORBIDDEN FOREIGN LIBRARY","private":false])
            let workflow = try save(service,root,["version":1,"template":"evidence {{references}}","inputs":[["id":"references","retrieve":["query":"evidence","k":5]]]])
            let run = try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":true])
            let text = try jsonString(try XCTUnwrap(run["contextSnapshot"] as? JSON))
            XCTAssertFalse(text.contains("FORBIDDEN"))
            XCTAssertTrue(text.contains("PUBLIC LIBRARY"))
            XCTAssertTrue(text.contains("ALLOWED MEMORY"))
            let foreignGuideline = try store.put("guideline",["title":"Foreign","scope":"project","project":other.path,"content":"FORBIDDEN GUIDELINE"])
            let denied = try save(service,root,["version":1,"template":"evidence"],guidelines:[string(foreignGuideline,"id")])
            let failed = try call(service,"workflows.run",["id":denied["id"]!,"dryRun":false])
            XCTAssertEqual(string(failed,"state"),"failed")
            XCTAssertFalse(try jsonString(failed).contains("FORBIDDEN GUIDELINE"))
            XCTAssertEqual(try store.list("approval").count,0)
        }
    }

    func testTypedTemplatesPreserveDataAndOptionalInputsAreExplicit() throws {
        try fixture { root,_,service in
            let context: JSON = ["version":1,"template":"Data {{second.items}} / flag={{input.flag}} / missing={{missing}}","memory":["enabled":false],"inputs":[
                ["id":"first","value":"{{input.payload}}"],
                ["id":"second","value":"{{first}}"],
                ["id":"missing","source":"stdin","optional":true]
            ]]
            let workflow = try save(service,root,context)
            let run = try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":true,"inputs":["payload":["items":[1,"{{guidelines}}",true]],"flag":true]])
            XCTAssertEqual(string(run,"state"),"completed")
            let snapshot = try XCTUnwrap(run["contextSnapshot"] as? JSON)
            let inputs = try XCTUnwrap(snapshot["inputs"] as? JSON)
            XCTAssertEqual(try jsonString(inputs["first"]!),try jsonString(inputs["second"]!))
            XCTAssertTrue(string(snapshot,"renderedPrompt").contains("{{guidelines}}"))
            XCTAssertTrue(string(snapshot,"renderedPrompt").contains("flag=true"))
            XCTAssertEqual(snapshot["degraded"] as? Bool,true)
            XCTAssertEqual((snapshot["inputsUsed"] as? [JSON])?.last?["state"] as? String,"degraded")
        }
    }

    func testInvalidContractsMissingInputsAndBudgetsFailClosed() throws {
        try fixture { root,store,service in
            for invalid in [
                ["version":true,"template":"x"] as JSON,
                ["version":1,"template":"x","memory":["budgetTokens":true]],
                ["version":1,"template":"x","inputs":[["id":"write","tool":"file.write","arguments":["path":"escape","content":"x"]]]],
                ["version":1,"template":"x","inputs":[["id":"same","value":1],["id":"same","value":2]]],
                ["version":1,"template":"x","inputs":[["id":"mixed","value":1,"source":"stdin"]]]
            ] { XCTAssertThrowsError(try save(service,root,invalid)) }
            XCTAssertThrowsError(try call(service,"workflows.save",["title":"No context","project":root.path,"steps":[step()]]))
            let missing = try save(service,root,["version":1,"template":"{{input.unknown}}"])
            let failed = try call(service,"workflows.run",["id":missing["id"]!,"dryRun":false])
            XCTAssertEqual(string(failed,"failureStage"),"context")
            XCTAssertEqual(string(failed,"state"),"failed")
            let oversized = try save(service,root,["version":1,"template":"{{input.big}} {{input.big}}","memory":["enabled":false]])
            let bigRun = try call(service,"workflows.run",["id":oversized["id"]!,"dryRun":false,"inputs":["big":String(repeating:"x",count:25_000)]])
            XCTAssertEqual(string(bigRun,"state"),"failed")
            XCTAssertEqual(try store.list("approval").count,0)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("received.txt").path))
        }
    }

    func testMemoryBudgetAndMissingGuidelinesDoNotPretendToInject() throws {
        try fixture { root,store,service in
            _ = try store.put("memory",["title":"evidence","project":root.path,"content":String(repeating:"evidence ",count:300),"state":"active","scope":"project"])
            let workflow = try save(service,root,["version":1,"template":"evidence","memory":["budgetTokens":10]])
            let run = try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":true])
            XCTAssertEqual((run["memoryUsed"] as? [JSON])?.count,0)
            XCTAssertEqual((run["contextSnapshot"] as? JSON)?["memoryUsedTokens"] as? Int,0)
            let missing = try save(service,root,["version":1,"template":"evidence"],guidelines:["does-not-exist"])
            let failure = try call(service,"workflows.run",["id":missing["id"]!,"dryRun":true])
            XCTAssertEqual(string(failure,"state"),"failed")
            XCTAssertNil(failure["contextSnapshot"])
        }
    }

    func testReplayUsesCapturedReadsAndContextWithoutExecutingAgain() throws {
        try fixture { root,store,service in
            XCTAssertEqual(try AutomationProcess.git(["init","-q"],cwd:root.path).exitCode,0)
            let workflow = try call(service,"workflows.save",["title":"Capture","project":root.path,"context":["version":1,"template":"Captured {{status.output}}","inputs":[["id":"status","tool":"git.status"]],"memory":["enabled":false]],"steps":[["tool":"git.status"],step()]])
            let run = try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":false])
            let readOutput = (run["steps"] as? [JSON])?.first?["output"] as? String
            try Data("new state".utf8).write(to:root.appendingPathComponent("new-after-capture.txt"))
            let replay = try call(service,"workflows.replay",["runId":run["id"]!])
            XCTAssertEqual(string(replay,"replayMode"),"captured_records_no_execution")
            XCTAssertEqual((replay["steps"] as? [JSON])?.first?["output"] as? String,readOutput)
            XCTAssertEqual(try jsonString(replay["contextSnapshot"]!),try jsonString(run["contextSnapshot"]!))
            XCTAssertFalse(try jsonString(replay).contains("new-after-capture.txt"))
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("received.txt").path))
            XCTAssertEqual(try store.list("approval").count,1)
        }
    }

    func testMarkdownContextEditsAreLoadedAndCrossProjectSaveIsRejected() throws {
        try fixture { root,_,service in
            let workflow = try save(service,root,["version":1,"template":"ORIGINAL TEMPLATE","memory":["enabled":false]])
            let path = string(workflow,"assetPath")
            let text = try String(contentsOfFile:path)
            // Edit the human-owned body frontmatter, leaving outer store metadata intact.
            let separator = try XCTUnwrap(text.range(of:"\n---\n"))
            let header = String(text[..<separator.upperBound])
            let body = String(text[separator.upperBound...]).replacingOccurrences(of:"ORIGINAL TEMPLATE",with:"EDITED TEMPLATE")
            try Data((header + body).utf8).write(to:URL(fileURLWithPath:path))
            let run = try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":true])
            XCTAssertEqual((run["contextSnapshot"] as? JSON)?["renderedPrompt"] as? String,"EDITED TEMPLATE")
            XCTAssertEqual(run["workflowVersion"] as? Int,2)
            XCTAssertThrowsError(try call(service,"workflows.save",["id":workflow["id"]!,"title":"Move","project":root.deletingLastPathComponent().path,"steps":[["tool":"git.status"]]]))
        }
    }
}
