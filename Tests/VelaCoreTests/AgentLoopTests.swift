import XCTest
@testable import VelaCore

final class AgentLoopTests: XCTestCase {
    private final class Vault: ConnectorCredentialVault {
        var secret = ""
        func create(_ secret: String,generation: String) throws { self.secret = secret }
        func read(generation: String) throws -> String { secret }
        func remove(generation: String) throws { secret = "" }
    }
    private final class Provider: ConnectorTransport {
        var writes = 0, reads = 0
        var tool: JSON = ["slug":"FIXTURE_SEND","version":"20260913","toolkit":["slug":"fixture"],"name":"Fixture send","description":"Queue this synthetic message only","input_parameters":["type":"object","properties":["body":["type":"string"]],"required":["body"],"additionalProperties":false],"output_parameters":["type":"object"],"no_auth":true,"is_deprecated":false]
        func send(_ request: ConnectorRequest,key: String) throws -> JSON {
            if request.method != "GET" { writes += 1; return ["successful":true,"data":["body":request.body?["arguments"] ?? [:]],"error":NSNull()] }
            reads += 1
            if request.path == "/auth_configs" { return ["items":[] as [JSON]] }
            if request.path == "/tools/FIXTURE_SEND" { return tool }
            throw VelaError("Unexpected fixture connector route")
        }
    }
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-loop-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let project = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        XCTAssertEqual(try AutomationProcess.git(["init","-q"],cwd:project.path).exitCode,0)
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["path":project.path,"project":project.path])
        try body(project,store,AutomationService(store:store))
    }
    private func call(_ service: AutomationService,_ method: String,_ params: JSON) throws -> JSON {
        let valueToUnwrap = try service.handle(method,params) as? JSON
        return try XCTUnwrap(valueToUnwrap)
    }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'" }
    private func fake(_ project: URL,_ decisions: [JSON],partial: Bool = false, tool: Bool = false, delay: Bool = false) throws -> URL {
        let prefix = project.appendingPathComponent("fake-" + UUID().uuidString)
        let executable = prefix.appendingPathExtension("sh")
        var script = "#!/bin/sh\ncount=0\n[ ! -f \(quote(prefix.path+".count")) ] || count=$(cat \(quote(prefix.path+".count")))\ncount=$((count+1))\nprintf '%s' \"$count\" > \(quote(prefix.path+".count"))\nprintf '%s\\0' \"$@\" > \(quote(prefix.path)).argv.$count\nprintf '%s' \"$PWD\" > \(quote(prefix.path)).cwd.$count\n"
        if delay { script += "sleep 30\n" }
        script += "case $count in\n"
        for (index,decision) in decisions.enumerated() {
            var events: [JSON] = [["type":"thread.started","thread_id":"fixture-loop-\(index)"]]
            if tool { events.append(["type":"item.completed","item":["id":"illegal","type":"command_execution","command":"not-allowed","status":"completed","exit_code":0]]) }
            events.append(["type":"item.completed","item":["id":"message","type":"agent_message","text":try jsonString(["decision":decision])]])
            if !partial { events.append(["type":"turn.completed","usage":["input_tokens":80,"output_tokens":20]]) }
            script += "\(index+1)) cat <<'VELA_LOOP_JSON_EOF'\n" + (try events.map(jsonString).joined(separator:"\n")) + "\nVELA_LOOP_JSON_EOF\n;;\n"
        }
        script += "*) exit 17;;\nesac\n"
        try Data(script.utf8).write(to:executable); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        return executable
    }
    private func args(_ executable: URL,_ tools: [Any] = ["git.status"],limits: JSON = [:]) -> JSON {
        ["prompt":"Report facts from the selected tools. Keep literal {{text}}.","agent":["executable":executable.path,"model":"fixture","reasoningEffort":"high"],"tools":tools,"limits":limits]
    }
    private func plan(_ service: AutomationService,_ project: URL,_ args: JSON) throws -> JSON { try call(service,"loops.plan",args.merging(["project":project.path]) { _,new in new }) }
    private func approve(_ service: AutomationService,_ loop: JSON) throws -> JSON {
        let approval = try XCTUnwrap(loop["approval"] as? JSON)
        return try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
    }
    private func get(_ service: AutomationService,_ project: URL,_ loop: JSON) throws -> JSON { try call(service,"loops.get",["project":project.path,"id":loop["id"]!]) }
    private func calls(_ executable: URL) throws -> String { try String(contentsOfFile:executable.deletingPathExtension().path+".count") }
    private func argv(_ executable: URL,_ index: Int) throws -> [String] { try Data(contentsOf:URL(fileURLWithPath:executable.deletingPathExtension().path+".argv.\(index)")).split(separator:0).map { String(decoding:$0,as:UTF8.self) } }

    func testRealReadFeedsNextModelProcessAndFinalIsNotAnotherRead() throws {
        try fixture { project,store,service in
            try Data("fixture".utf8).write(to:project.appendingPathComponent("real-observed-file.txt"))
            let executable = try fake(project,[["kind":"tool","toolId":"git.status","arguments":JSON()],["kind":"final","answer":"Observed a working tree change."]])
            let pending = try plan(service,project,args(executable))
            XCTAssertFalse(FileManager.default.fileExists(atPath:executable.deletingPathExtension().path+".count"))
            XCTAssertEqual(string(try approve(service,pending),"state"),"executed")
            let completed = try get(service,project,pending)
            XCTAssertEqual(string(completed,"state"),"completed")
            XCTAssertEqual(try calls(executable),"2")
            XCTAssertTrue(try argv(executable,2).last?.contains("real-observed-file.txt") == true)
            XCTAssertTrue(try argv(executable,1).contains("shell_tool"))
            XCTAssertTrue(try argv(executable,1).contains("mcp_servers={}"))
            XCTAssertEqual(intValue(completed,"observedTokens"),200)
            XCTAssertEqual((completed["rounds"] as? [JSON])?.count,2)
            XCTAssertThrowsError(try approve(service,pending))
            XCTAssertEqual(try store.list("approval").count,1)
            let cwd = try String(contentsOfFile:executable.deletingPathExtension().path+".cwd.1")
            XCTAssertFalse(FileManager.default.fileExists(atPath:cwd))
        }
    }

    func testUnknownToolMalformedArgumentsAndPartialOrToolProtocolStopBeforeDispatch() throws {
        try fixture { project,store,service in
            for (decision,partial,tool) in [(["kind":"tool","toolId":"shell.test","arguments":JSON()] as JSON,false,false),(["kind":"tool","toolId":"git.status","arguments":["path":"outside"]] as JSON,false,false),(["kind":"final","answer":"incomplete"] as JSON,true,false),(["kind":"final","answer":"forged"] as JSON,false,true)] {
                let executable = try fake(project,[decision],partial:partial,tool:tool)
                let pending = try plan(service,project,args(executable))
                XCTAssertEqual(string(try approve(service,pending),"state"),"needs_review")
                XCTAssertEqual(try calls(executable),"1")
                XCTAssertEqual(string(try get(service,project,pending),"state"),"needs_review")
            }
            XCTAssertTrue(try store.list("connector_action").isEmpty)
        }
    }

    func testActualMemoryAndLibraryReadsExcludePrivateForeignAndInactiveSources() throws {
        try fixture { project,store,service in
            _ = try store.put("memory",["id":"public-memory","project":project.path,"title":"topic","content":"PUBLIC_MEMORY","state":"active","scope":"project","private":false])
            _ = try store.put("memory",["id":"private-memory","project":project.path,"title":"topic","content":"PRIVATE_MEMORY_SENTINEL","state":"active","scope":"project","private":true])
            _ = try store.put("memory",["id":"foreign-memory","project":"/foreign","title":"topic","content":"FOREIGN_MEMORY_SENTINEL","state":"active","scope":"project","private":false])
            _ = try store.put("library",["id":"public-library","project":project.path,"title":"topic","content":"PUBLIC_LIBRARY","state":"active","private":false])
            _ = try store.put("library",["id":"private-library","project":project.path,"title":"topic","content":"PRIVATE_LIBRARY_SENTINEL","state":"active","private":true])
            let executable = try fake(project,[["kind":"tool","toolId":"memory.recall","arguments":["query":"topic","budgetTokens":1000]],["kind":"tool","toolId":"library.retrieve","arguments":["query":"topic","k":5]],["kind":"final","answer":"Sources considered."]])
            let pending = try plan(service,project,args(executable,["memory.recall","library.retrieve"]))
            XCTAssertEqual(string(try approve(service,pending),"state"),"executed")
            let prompt = try XCTUnwrap(argv(executable,3).last)
            XCTAssertTrue(prompt.contains("PUBLIC_MEMORY")); XCTAssertTrue(prompt.contains("PUBLIC_LIBRARY"))
            XCTAssertFalse(prompt.contains("PRIVATE_MEMORY_SENTINEL")); XCTAssertFalse(prompt.contains("PRIVATE_LIBRARY_SENTINEL")); XCTAssertFalse(prompt.contains("FOREIGN_MEMORY_SENTINEL"))
        }
    }

    func testBudgetCapCancellationAndTimeoutNeverBlindlyRetry() throws {
        try fixture { project,_,service in
            let repeated: [JSON] = (0..<3).map { _ in ["kind":"tool","toolId":"git.status","arguments":JSON()] }
            let capped = try fake(project,repeated)
            let plan1 = try plan(service,project,args(capped,limits:["maxModelCalls":2]))
            XCTAssertEqual(string(try approve(service,plan1),"state"),"failed")
            XCTAssertEqual(string(try get(service,project,plan1),"state"),"budget_exhausted"); XCTAssertEqual(try calls(capped),"2")
            let tokens = try fake(project,repeated)
            let plan2 = try plan(service,project,args(tokens,limits:["observedTokenBudget":50]))
            _ = try approve(service,plan2); XCTAssertEqual(try calls(tokens),"1")
            let cancelled = try fake(project,[["kind":"final","answer":"never"]])
            let plan3 = try plan(service,project,args(cancelled))
            _ = try call(service,"loops.cancel",["project":project.path,"id":plan3["id"]!,"loopHash":plan3["loopHash"]!])
            XCTAssertThrowsError(try approve(service,plan3))
            XCTAssertFalse(FileManager.default.fileExists(atPath:cancelled.deletingPathExtension().path+".count"))
            let timeout = try fake(project,[["kind":"final","answer":"never"]],delay:true)
            let plan4 = try plan(service,project,args(timeout,limits:["timeoutSeconds":1]))
            XCTAssertEqual(string(try approve(service,plan4),"state"),"needs_review")
            XCTAssertEqual(try calls(timeout),"1"); XCTAssertThrowsError(try approve(service,plan4))
        }
    }

    func testWorkflowLoopContextIsFrozenAndDryRunDoesNotCallModel() throws {
        try fixture { project,store,service in
            let executable = try fake(project,[["kind":"final","answer":"done"]])
            var arguments = args(executable)
            arguments["promptMode"] = "workflow_context"; arguments["prompt"] = WorkflowContext.promptMarker
            let workflow = try call(service,"workflows.save",["title":"contextual loop","project":project.path,"context":["version":1,"template":"Exact {{input.topic}}","inputs":[] as [JSON],"memory":["enabled":false]],"steps":[["tool":"agent.loop","arguments":arguments]]])
            _ = try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":true,"inputs":["topic":"dry"]])
            XCTAssertTrue(try store.list("agent_loop").isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath:executable.deletingPathExtension().path+".count"))
            _ = try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":false,"inputs":["topic":"literal {{data}}"]])
            let loop = try XCTUnwrap(store.list("agent_loop").first)
            let pending = try get(service,project,loop)
            _ = try approve(service,pending)
            XCTAssertTrue(try argv(executable,1).last?.contains("Exact literal {{data}}") == true)
        }
    }
    func testConnectorDecisionQueuesItsOwnFrozenApprovalThenModelFinishes() throws {
        try fixture { project,store,service in
            let provider = Provider(), vault = Vault()
            let connector = ConnectorService(store:store,transport:provider,vault:vault); service.connectorService = connector
            _ = try connector.handle("connectors.configure",["apiKey":"synthetic-test-key","userId":"fixture-user"])
            let catalog = try XCTUnwrap(connector.handle("connectors.tools.get",["slug":"FIXTURE_SEND","version":"20260913"]) as? JSON)
            let binding: JSON = ["toolSlug":"FIXTURE_SEND","version":"20260913","catalogHash":catalog["catalogHash"]!]
            let executable = try fake(project,[["kind":"tool","toolId":"connector:FIXTURE_SEND@20260913","arguments":["body":"literal {{data}}"]],["kind":"final","answer":"The proposed message is ready for your review."]])
            let pending = try plan(service,project,args(executable,[binding]))
            XCTAssertEqual(provider.writes,0)
            XCTAssertEqual(string(try approve(service,pending),"state"),"executed")
            XCTAssertEqual(provider.writes,0)
            let completed = try get(service,project,pending)
            XCTAssertEqual(string(completed,"state"),"completed")
            let queued = try XCTUnwrap((completed["queuedActions"] as? [JSON])?.first)
            XCTAssertTrue(string(completed,"output").contains("NOT been executed"))
            XCTAssertTrue(string(completed,"output").contains(string(queued,"approvalId")))
            XCTAssertTrue(try argv(executable,2).last?.contains(string(queued,"approvalId")) == true)
            let actionApproval = try XCTUnwrap(store.get("approval",string(queued,"approvalId")))
            XCTAssertNotEqual(string(actionApproval,"id"),string(pending["approval"] as? JSON ?? [:],"id"))
            _ = try call(service,"approvals.decide",["id":actionApproval["id"]!,"snapshotHash":actionApproval["snapshotHash"]!,"decision":"approve"])
            XCTAssertEqual(provider.writes,1); XCTAssertEqual(try calls(executable),"2")
            // Simulate the crash boundary where action creation was committed
            // but its parent loop receipt was not yet written.
            var missingReceipt = try XCTUnwrap(store.get("agent_loop",string(pending,"id")))
            missingReceipt["queuedActions"] = [] as [JSON]; _ = try store.put("agent_loop",missingReceipt)
            let recovered = try get(service,project,pending)
            XCTAssertEqual((recovered["queuedActions"] as? [JSON])?.count,1)
            XCTAssertEqual((recovered["queuedActions"] as? [JSON])?.first?["approvalId"] as? String,queued["approvalId"] as? String)
            XCTAssertEqual(provider.writes,1); XCTAssertEqual(try calls(executable),"2")
        }
    }

    func testUnsupportedSchemaAndSourceMadePrivateBeforeApprovalNeverReachModel() throws {
        try fixture { project,store,service in
            XCTAssertThrowsError(try AgentLoop.validateSchema(["type":"object","properties":[:],"patternProperties":[".*":["type":"string"]]]))
            let executable = try fake(project,[["kind":"final","answer":"must not run"]])
            let library = try store.put("library",["id":"later-private","project":project.path,"title":"topic","content":"LATER_PRIVATE_CONTENT","state":"active","private":false])
            var arguments = args(executable); arguments["prompt"] = WorkflowContext.promptMarker; arguments["promptMode"] = "workflow_context"
            let workflow = try call(service,"workflows.save",["title":"privacy","project":project.path,"context":["version":1,"template":"{{sources}}","inputs":[["id":"sources","retrieve":["query":"topic","k":1]]],"memory":["enabled":false]],"steps":[["tool":"agent.loop","arguments":arguments]]])
            _ = try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":false])
            let loop = try XCTUnwrap(store.list("agent_loop").first)
            var privateSource = library; privateSource["private"] = true; _ = try store.put("library",privateSource)
            XCTAssertEqual(string(try approve(service,get(service,project,loop)),"state"),"needs_review")
            XCTAssertFalse(FileManager.default.fileExists(atPath:executable.deletingPathExtension().path+".count"))
        }
    }

    func testCancellationDuringActualModelCallStopsBeforeToolDispatch() throws {
        try fixture { project,store,service in
            let executable = try fake(project,[["kind":"tool","toolId":"git.status","arguments":JSON()],["kind":"final","answer":"never"]])
            let ready = project.appendingPathComponent("ready"), release = project.appendingPathComponent("release")
            let script = try String(contentsOf:executable).replacingOccurrences(of:"case $count in",with:"touch " + quote(ready.path) + "\nwhile [ ! -f " + quote(release.path) + " ]; do sleep 0.01; done\ncase $count in")
            try Data(script.utf8).write(to:executable)
            let pending = try plan(service,project,args(executable,limits:["timeoutSeconds":5]))
            let other = AutomationService(store:try VelaStore(root:store.root))
            let group = DispatchGroup(), resultLock = NSLock(); var failure: String?
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { _ = try self.approve(service,pending) }
                catch { resultLock.lock(); failure = error.localizedDescription; resultLock.unlock() }
            }
            let deadline = Date().addingTimeInterval(3)
            while !FileManager.default.fileExists(atPath:ready.path), Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
            XCTAssertTrue(FileManager.default.fileExists(atPath:ready.path))
            let current = try get(other,project,pending)
            _ = try call(other,"loops.cancel",["project":project.path,"id":pending["id"]!,"loopHash":current["loopHash"]!])
            try Data().write(to:release)
            XCTAssertTrue(group.wait(timeout:.now()+7) == .success)
            resultLock.lock(); let error = failure; resultLock.unlock(); XCTAssertNil(error)
            let cancelled = try get(other,project,pending)
            XCTAssertEqual(string(cancelled,"state"),"cancelled"); XCTAssertEqual(try calls(executable),"1")
            XCTAssertNil((cancelled["rounds"] as? [JSON])?.first?["receipt"])
        }
    }

    func testContextArgvCompatibilityDoesNotConfuseUnusedPromptFieldWithLoop() throws {
        try fixture { _,_,service in
            let prompt = "actual frozen text"
            let args: JSON = ["promptMode":"workflow_context","args":[WorkflowContext.promptMarker],"prompt":WorkflowContext.promptMarker]
            let frozen = try service.contextArguments(args,snapshot:["renderedPrompt":prompt,"promptHash":stableHash(prompt)])
            XCTAssertEqual(frozen["args"] as? [String],[prompt])
            XCTAssertEqual(frozen["prompt"] as? String,WorkflowContext.promptMarker)
        }
    }

    func testQueueDoesNotRefreshChangedIdentityAndSeparateExecutionRejectsIt() throws {
        for changed in ["profile","schema"] {
            try fixture { project,store,service in
                let provider = Provider(), vault = Vault()
                let connector = ConnectorService(store:store,transport:provider,vault:vault); service.connectorService = connector
                _ = try connector.handle("connectors.configure",["apiKey":"synthetic-test-key","userId":"fixture-user"])
                let catalog = try XCTUnwrap(connector.handle("connectors.tools.get",["slug":"FIXTURE_SEND","version":"20260913"]) as? JSON)
                let binding: JSON = ["toolSlug":"FIXTURE_SEND","version":"20260913","catalogHash":catalog["catalogHash"]!]
                let executable = try fake(project,[["kind":"tool","toolId":"connector:FIXTURE_SEND@20260913","arguments":["body":"review before sending"]],["kind":"final","answer":"Queued only."]])
                let pending = try plan(service,project,args(executable,[binding]))
                if changed == "profile" { _ = try connector.handle("connectors.configure",["apiKey":"different-synthetic-key","userId":"fixture-user"]) }
                else { provider.tool["description"] = "Schema metadata changed after planning" }
                let reads = provider.reads
                _ = try approve(service,pending)
                XCTAssertEqual(provider.reads,reads)
                XCTAssertEqual(provider.writes,0)
                let done = try get(service,project,pending)
                let queued = try XCTUnwrap((done["queuedActions"] as? [JSON])?.first)
                let approval = try XCTUnwrap(store.get("approval",string(queued,"approvalId")))
                let rejected = try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
                XCTAssertEqual(string(rejected,"state"),"failed")
                XCTAssertEqual(provider.writes,0)
                XCTAssertEqual(try calls(executable),"2")
            }
        }
    }

}
