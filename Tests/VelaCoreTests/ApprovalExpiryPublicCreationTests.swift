import XCTest
@testable import VelaCore

/// Expiry regressions use only public AutomationService creators; no approval/run/owner is fabricated.
final class ApprovalExpiryPublicCreationTests: XCTestCase {
    private final class Clock { var now: Date; init(_ value: Date) { now = value } }
    private final class ConnectorVault: ConnectorCredentialVault {
        var values: [String:String] = [:]
        func create(_ secret: String, generation: String) throws { values[generation] = secret }
        func read(generation: String) throws -> String { guard let value = values[generation] else { throw VelaError("missing synthetic credential") }; return value }
        func remove(generation: String) throws { values.removeValue(forKey:generation) }
    }
    private final class ConnectorMock: ConnectorTransport {
        var requests: [ConnectorRequest] = []
        var writes = 0
        func send(_ request: ConnectorRequest, key: String) throws -> JSON {
            requests.append(request)
            guard key == "synthetic-expiry-key" else { throw VelaError("unexpected synthetic credential") }
            if request.method != "GET" { writes += 1; return ["successful":true,"data":[:]] }
            switch request.path {
            case "/auth_configs": return ["items":[["id":"expiry-auth","toolkit":["slug":"fixture"],"name":"Fixture","status":"ENABLED","auth_scheme":"OAUTH2","is_composio_managed":true]]]
            case "/connected_accounts": return ["items":[["id":"expiry-account","toolkit":["slug":"fixture"],"user_id":"expiry-user","status":"ACTIVE","is_disabled":false,"auth_config":["id":"expiry-auth","auth_scheme":"OAUTH2"]]]]
            case "/connected_accounts/expiry-account": return ["id":"expiry-account","toolkit":["slug":"fixture"],"user_id":"expiry-user","status":"ACTIVE","is_disabled":false,"auth_config":["id":"expiry-auth","auth_scheme":"OAUTH2"]]
            case "/tools/FIXTURE_READ": return ["slug":"FIXTURE_READ","version":"20260914_01","toolkit":["slug":"fixture"],"name":"Fixture read","description":"Read only fixture","input_parameters":["type":"object","properties":["value":["type":"string"]],"required":["value"]],"output_parameters":["type":"object"],"no_auth":false,"tags":["read_only"],"is_deprecated":false]
            default: throw VelaError("unexpected mock route \(request.path)")
            }
        }
    }
    private func fixture(_ body: (URL,VelaStore,AutomationService,Clock) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vela-public-approval-expiry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:base.appendingPathComponent("store"))
        _ = try store.put("project",["id":"public-expiry-project","title":"Public expiry","path":project.path,"project":project.path])
        let clock = Clock(Date(timeIntervalSince1970:1_800_000_000))
        let service = AutomationService(store:store,approvalClock:{ clock.now })
        _ = try VelaPreferences.save(["approvalExpirySeconds":1],in:store)
        try body(project,store,service,clock)
    }
    private func call(_ service: AutomationService,_ method: String,_ params: JSON) throws -> JSON { try XCTUnwrap(try service.handle(method,params) as? JSON) }
    private func synthetic(_ root: URL,_ name: String) throws -> URL {
        let path = root.appendingPathComponent(name)
        try Data("#!/bin/sh\nprintf called >> '\(root.appendingPathComponent("provider-calls").path)'\n".utf8).write(to:path)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path)
        return path
    }
    private func expireByRead(_ service: AutomationService, store: VelaStore, clock: Clock, approval: JSON, ownerKind: String, ownerID: String, project: URL) throws {
        XCTAssertEqual(string(approval,"state"),"pending")
        let runID = string(approval,"runId")
        XCTAssertFalse(runID.isEmpty); XCTAssertFalse(ownerID.isEmpty)
        XCTAssertNotEqual(ownerID,runID,"owner must be a real independent public owner ID")
        clock.now = clock.now.addingTimeInterval(2)
        let read = try call(service,"approvals.get",["id":approval["id"]!])
        XCTAssertEqual(string(read,"state"),"expired")
        XCTAssertEqual(string(try XCTUnwrap(store.get("approval",string(approval,"id"))),"state"),"expired")
        XCTAssertEqual(string(try XCTUnwrap(store.get(ownerKind,ownerID)),"state"),"expired")
        let run = try XCTUnwrap(store.get("run",runID))
        XCTAssertEqual(string(run,"state"),"expired")
        XCTAssertEqual(string((run["steps"] as? [JSON] ?? [[:]])[0],"state"),"expired")
        XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent("provider-calls").path))
    }
    func testPublicWorkflowLoopPlanAndModelImprovementExpiry() throws {
        try fixture { project,store,service,clock in
            let workflow = try self.call(service,"workflows.save",["title":"expiry write","project":project.path,"steps":[["title":"write","tool":"file.write","arguments":["path":"must-not-write","content":"no"]]]])
            _ = try self.call(service,"workflows.run",["id":workflow["id"]!,"dryRun":false])
            let approval = try XCTUnwrap(store.list("approval").first)
            clock.now = clock.now.addingTimeInterval(2)
            XCTAssertThrowsError(try service.handle("approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"]))
            XCTAssertEqual(string(try self.call(service,"approvals.get",["id":approval["id"]!]),"state"),"expired")
            XCTAssertEqual(string(try XCTUnwrap(store.get("run",string(approval,"runId"))),"state"),"expired")
            XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent("must-not-write").path))

            let loopClock = Clock(Date(timeIntervalSince1970:1_800_000_100)); let loopService = AutomationService(store:store,approvalClock:{ loopClock.now })
            let loop = try self.call(loopService,"loops.plan",["project":project.path,"prompt":"Return final.","agent":["executable":try self.synthetic(project,"loop-provider").path,"model":"synthetic","reasoningEffort":"low"],"tools":["git.status"],"limits":["maxModelCalls":1,"timeoutSeconds":5,"totalTimeoutSeconds":10]])
            try self.expireByRead(loopService,store:store,clock:loopClock,approval:try XCTUnwrap(loop["approval"] as? JSON),ownerKind:"agent_loop",ownerID:string(loop,"id"),project:project)

            let planClock = Clock(Date(timeIntervalSince1970:1_800_000_200)); let planService = AutomationService(store:store,approvalClock:{ planClock.now })
            let plan = try self.call(planService,"workflows.plan",["project":project.path,"description":"Describe current local state.","executable":try self.synthetic(project,"plan-provider").path,"model":"synthetic","effort":"low","timeoutSeconds":5])
            try self.expireByRead(planService,store:store,clock:planClock,approval:try XCTUnwrap(plan["approval"] as? JSON),ownerKind:"workflow_plan",ownerID:string(plan,"id"),project:project)

            let improveClock = Clock(Date(timeIntervalSince1970:1_800_000_300)); let improveService = AutomationService(store:store,approvalClock:{ improveClock.now })
            try FileManager.default.createDirectory(at:project.appendingPathComponent(".vela/docs"),withIntermediateDirectories:true)
            try Data("# synthetic\n".utf8).write(to:project.appendingPathComponent(".vela/docs/handoff.md"))
            _ = try store.put("session",["id":"public-expiry-session","project":project.path,"provider":"codex","sourceSessionId":"public-expiry-source","messages":[["id":"message-1","role":"user","content":"Validate before handoff."]]])
            let improvement = try self.call(improveService,"improve.model.plan",["project":project.path,"sessionIds":["public-expiry-session"],"targets":[["carrier":"Doc","path":".vela/docs/handoff.md"]],"executable":try self.synthetic(project,"improve-provider").path,"model":"synthetic","effort":"low","timeoutSeconds":5])
            try self.expireByRead(improveService,store:store,clock:improveClock,approval:try XCTUnwrap(improvement["approval"] as? JSON),ownerKind:"model_improvement",ownerID:string(improvement,"id"),project:project)

            let askClock = Clock(Date(timeIntervalSince1970:1_800_000_400)); let askService = AutomationService(store:store,approvalClock:{ askClock.now })
            let source = try store.put("library",["id":"expiry-knowledge-source","project":project.path,"title":"Expiry evidence","content":"Public source for expiry.","state":"active","scope":"project","private":false])
            let ask = try self.call(askService,"ask.create",["project":project.path,"question":"What is the expiry evidence?","searchQuery":"expiry","executable":try self.synthetic(project,"ask-provider").path,"model":"synthetic","effort":"low"])
            try self.expireByRead(askService,store:store,clock:askClock,approval:try XCTUnwrap(ask["approval"] as? JSON),ownerKind:"knowledge_query",ownerID:string(ask,"id"),project:project)
            XCTAssertEqual(string(source,"state"),"active")

            let routeClock = Clock(Date(timeIntervalSince1970:1_800_000_500)); let routeService = AutomationService(store:store,approvalClock:{ routeClock.now })
            _ = try store.put("memory",["id":"expiry-route-source","project":project.path,"title":"Route evidence","content":"Route expiry evidence.","state":"active","scope":"project","private":false])
            let route = try self.call(routeService,"ask.route",["project":project.path,"question":"Route expiry evidence"])
            let proposal = try self.call(routeService,"ask.route.propose",["project":project.path,"id":route["id"]!,"routeHash":route["routeHash"]!,"executable":try self.synthetic(project,"route-provider").path,"model":"synthetic"])
            try self.expireByRead(routeService,store:store,clock:routeClock,approval:try XCTUnwrap(proposal["approval"] as? JSON),ownerKind:"ask_route_proposal",ownerID:string(proposal,"id"),project:project)
        }
    }
    func testPublicLabRunExpiresBeforeSyntheticProviderStarts() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vela-public-lab-expiry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        try Data("assert True\n".utf8).write(to:project.appendingPathComponent("verify.py"))
        XCTAssertEqual(try AutomationProcess.git(["init","-q"],cwd:project.path).exitCode,0)
        XCTAssertEqual(try AutomationProcess.git(["add","verify.py"],cwd:project.path).exitCode,0)
        XCTAssertEqual(try AutomationProcess.git(["-c","user.name=Vela fixture","-c","user.email=fixture@example.invalid","commit","-qm","Lab expiry fixture"],cwd:project.path).exitCode,0)
        let marker = base.appendingPathComponent("provider-started")
        let agent = base.appendingPathComponent("synthetic-lab-agent")
        try Data("#!/bin/sh\nprintf started > '\(marker.path)'\nexit 0\n".utf8).write(to:agent)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:agent.path)
        let store = try VelaStore(root:base.appendingPathComponent("store"))
        _ = try store.put("project",["id":"lab-expiry-project","title":"Lab expiry","path":project.path,"project":project.path])
        let clock = Clock(Date(timeIntervalSince1970:1_800_001_000))
        let service = AutomationService(store:store,approvalClock:{ clock.now })
        _ = try VelaPreferences.save(["approvalExpirySeconds":1],in:store)
        let created = try call(service,"lab.run",["project":project.path,"title":"Lab expiry public creation","kind":"context","task":"Synthetic expiry fixture; do not invoke provider.","agent":["provider":"codex","executable":agent.path,"model":"synthetic","reasoningEffort":"low"],"verificationCommand":["/usr/bin/python3","verify.py"],"verificationFiles":["verify.py"],"outputFiles":["result.txt"],"timeoutSeconds":15,"repetitions":1,"baseline":["files":[]],"candidate":["files":[]]])
        XCTAssertEqual(string(created,"state"),"pending_approval")
        let approval = try XCTUnwrap(store.get("approval",string(created,"approvalId")))
        XCTAssertEqual(string(approval,"runId"),string(created,"id"),"Lab eval intentionally owns the same ID as its approval run")
        clock.now = clock.now.addingTimeInterval(2)
        let expired = try call(service,"approvals.get",["id":approval["id"]!])
        XCTAssertEqual(string(expired,"state"),"expired")
        XCTAssertEqual(string(try XCTUnwrap(store.get("eval",string(created,"id"))),"state"),"expired")
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    }

    func testPublicConnectorActionExpiresBeforeMockTransportWrites() throws {
        try fixture { project,store,service,clock in
            let transport = ConnectorMock(), vault = ConnectorVault()
            let connector = ConnectorService(store:store,transport:transport,vault:vault)
            service.connectorService = connector
            _ = try connector.handle("connectors.configure",["apiKey":"synthetic-expiry-key","userId":"expiry-user"])
            let tool = try XCTUnwrap(try connector.handle("connectors.tools.get",["slug":"FIXTURE_READ","version":"20260914_01"]) as? JSON)
            let action = try call(service,"connectors.action.plan",[
                "project":project.path,"action":"tool","toolSlug":"FIXTURE_READ","version":"20260914_01",
                "catalogHash":tool["catalogHash"]!,"connectedAccountId":"expiry-account","arguments":["value":"expiry fixture"]
            ])
            XCTAssertEqual(transport.writes,0)
            let approval = try XCTUnwrap(action["approval"] as? JSON)
            try expireByRead(service,store:store,clock:clock,approval:approval,ownerKind:"connector_action",ownerID:string(action,"id"),project:project)
            XCTAssertEqual(transport.writes,0,"expired approval must not invoke the mock connector")
        }
    }

    func testPublicReplayCreationExpiresOwnerWithoutStartingProvider() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vela-public-replay-expiry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:base.appendingPathComponent("store"))
        _ = try store.put("project",["id":"replay-expiry-project","title":"Replay expiry","path":project.path,"project":project.path])
        let clock = Clock(Date(timeIntervalSince1970:1_800_002_000))
        let service = AutomationService(store:store,approvalClock:{ clock.now })
        _ = try VelaPreferences.save(["approvalExpirySeconds":1],in:store)
        let contextA: JSON = ["version":1,"template":"VERSION_A {{input.task}}","inputs":[["id":"task","source":"stdin"]],"memory":["enabled":false]]
        let workflow = try call(service,"workflows.save",["title":"Replay expiry source","project":project.path,"steps":[["tool":"agent.run","arguments":["executable":"/usr/bin/false","args":[WorkflowContext.promptMarker],"promptMode":"workflow_context"]]],"context":contextA])
        let run = try call(service,"workflows.run",["id":workflow["id"]!,"dryRun":true,"inputs":["task":"synthetic replay input"],"stdin":"synthetic replay stdin"])
        XCTAssertEqual(string(run,"state"),"completed")
        var contextB = contextA; contextB["template"] = "VERSION_B {{input.task}}"
        _ = try call(service,"workflows.save",["id":workflow["id"]!,"title":"Replay expiry source","project":project.path,"steps":[["tool":"agent.run","arguments":["executable":"/usr/bin/false","args":[WorkflowContext.promptMarker],"promptMode":"workflow_context"]]],"context":contextB])
        let inspected = try call(service,"replay.fixtures.inspect",["project":project.path,"runId":run["id"]!])
        let captured = try call(service,"replay.fixtures.capture",["project":project.path,"runId":run["id"]!,"runHash":inspected["runHash"]!,"consent":true,"retentionDays":1])
        let marker = base.appendingPathComponent("replay-provider-started")
        let provider = base.appendingPathComponent("replay-provider")
        let providerSource = provider.appendingPathExtension("c")
        try Data("#include <stdio.h>\nint main(void) { FILE *f=fopen(\"\(marker.path)\", \"w\"); if(f) { fputs(\"started\",f); fclose(f); } return 0; }\n".utf8).write(to:providerSource)
        let compiled = try AutomationProcess.run(["/usr/bin/clang","-Os",providerSource.path,"-o",provider.path],cwd:base.path,timeout:20,maxOutput:8000)
        XCTAssertEqual(compiled.exitCode,0,compiled.output)
        let replay = try call(service,"replay.create",["project":project.path,"fixtureId":captured["id"]!,"fixtureHash":captured["fixtureHash"]!,"versions":[1,2],"executable":provider.path,"model":"synthetic","effort":"low","timeoutSeconds":5])
        // replay.create returns a deliberately redacted approval view. Read the persisted
        // approval by ID so expiry verifies its real run/step linkage.
        let approvalView = try XCTUnwrap(replay["approval"] as? JSON)
        let approval = try XCTUnwrap(store.get("approval",string(approvalView,"id")))
        try expireByRead(service,store:store,clock:clock,approval:approval,ownerKind:"replay",ownerID:string(replay,"id"),project:project)
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    }

}
