import XCTest
@testable import VelaCore

final class ConnectorTests: XCTestCase {
    private final class Vault: ConnectorCredentialVault {
        var values: [String:String] = [:]
        func create(_ secret: String, generation: String) throws { guard values[generation] == nil else { throw VelaError("duplicate key") }; values[generation] = secret }
        func read(generation: String) throws -> String { guard let value = values[generation] else { throw VelaError("no key") }; return value }
        func remove(generation: String) throws { values.removeValue(forKey:generation) }
    }
    private final class Provider: ConnectorTransport {
        var calls: [ConnectorRequest] = []
        var tool: JSON = ["slug":"FIXTURE_READ","version":"20260913_01","toolkit":["slug":"fixture"],"name":"Fixture read","description":"Reads synthetic values","input_parameters":["type":"object","properties":["value":["type":"string"]],"required":["value"]],"output_parameters":["type":"object"],"no_auth":false,"tags":["read_only"],"is_deprecated":false]
        var account: JSON = ["id":"ca_fixture","toolkit":["slug":"fixture"],"user_id":"user_fixture","status":"ACTIVE","is_disabled":false,"auth_config":["id":"ac_fixture","auth_scheme":"OAUTH2"],"state":["val":["access_token":"SECRET_ACCOUNT_TOKEN"]],"data":["password":"SECRET_ACCOUNT_PASSWORD"]]
        var config: JSON = ["id":"ac_fixture","toolkit":["slug":"fixture"],"name":"Fixture auth","status":"ENABLED","auth_scheme":"OAUTH2","is_composio_managed":true,"credentials":["client_secret":"SECRET_AUTH_CONFIG"]]
        var failWrites = false, rejectKey = false, writes = 0
        var reviewResponse: JSON?
        var link = "https://connect.composio.dev/link/synthetic-only"
        func send(_ request: ConnectorRequest, key: String) throws -> JSON {
            calls.append(request)
            if rejectKey { throw ConnectorHTTPError(status:403,outcomeUnknown:false,retryAfter:nil) }
            guard key.hasPrefix("synthetic-project-key") else { throw VelaError("unexpected fixture key") }
            if request.method != "GET" {
                writes += 1
                if failWrites { throw ConnectorHTTPError(status:0,outcomeUnknown:true,retryAfter:nil) }
                if request.path == "/tools/execute/FIXTURE_READ" { return reviewResponse ?? ["successful":true,"data":["received":request.body?["arguments"] ?? [:]],"error":NSNull(),"log_id":"fixture-log"] }
                if request.path == "/connected_accounts/link" || request.path.hasSuffix("/refresh") { return ["redirect_url":link,"connected_account_id":"ca_fixture","link_token":"DO_NOT_PERSIST_LINK_TOKEN"] }
                return ["success":true]
            }
            switch request.path {
            case "/auth_configs": return ["items":[config]]
            case "/auth_configs/ac_fixture": return config
            case "/connected_accounts": return ["items":[account]]
            case "/connected_accounts/ca_fixture": return account
            case "/tools": return ["items":[tool],"next_cursor":"page-two"]
            case "/tools/FIXTURE_READ": return tool
            case "/toolkits": return ["items":[["slug":"fixture","name":"Fixture"]]]
            default: throw VelaError("unexpected fixture route")
            }
        }
    }
    private func fixture(_ body: (URL,VelaStore,AutomationService,ConnectorService,Provider,Vault) throws -> Void) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vela-connector-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let project = temp.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:temp.appendingPathComponent("store"))
        _ = try store.put("project",["project":project.path,"path":project.path])
        let provider = Provider(), vault = Vault(), service = AutomationService(store:store)
        let connector = ConnectorService(store:store,transport:provider,vault:vault); service.connectorService = connector
        try body(project,store,service,connector,provider,vault)
    }
    private func configure(_ connector: ConnectorService) throws -> JSON {
        try XCTUnwrap(connector.handle("connectors.configure",["apiKey":"synthetic-project-key-one","userId":"user_fixture"]) as? JSON)
    }
    private func params(_ project: URL, _ connector: ConnectorService) throws -> JSON {
        let tool = try XCTUnwrap(connector.handle("connectors.tools.get",["slug":"FIXTURE_READ","version":"20260913_01"]) as? JSON)
        return ["project":project.path,"action":"tool","toolSlug":"FIXTURE_READ","version":"20260913_01","catalogHash":tool["catalogHash"]!,"connectedAccountId":"ca_fixture","arguments":["value":"literal {{config.secret}} $(do-not-execute)","extraNested":["number":7,"flag":true]]]
    }
    private func approve(_ service: AutomationService, _ action: JSON) throws -> JSON {
        let approval = try XCTUnwrap(action["approval"] as? JSON)
        return try XCTUnwrap(service.handle("approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"]) as? JSON)
    }

    func testConfigureVerifiesPermissionBeforeSavingAndNeverPersistsSecrets() throws {
        try fixture { _,store,_,connector,provider,vault in
            _ = try connector.handle("connectors.status",[:]); XCTAssertTrue(provider.calls.isEmpty)
            provider.rejectKey = true
            XCTAssertThrowsError(try configure(connector)); XCTAssertTrue(vault.values.isEmpty)
            XCTAssertNil(try store.get("connector_profile","composio"))
            provider.rejectKey = false
            let profile = try configure(connector)
            XCTAssertEqual(vault.values.count,1)
            XCTAssertFalse(try jsonString(profile).contains("synthetic-project-key"))
            let count = provider.calls.count
            _ = try connector.handle("connectors.status",[:]); XCTAssertEqual(provider.calls.count,count)
            _ = try connector.handle("connectors.forget",["generation":profile["generation"]!])
            XCTAssertTrue(vault.values.isEmpty)
            XCTAssertEqual(try store.get("connector_profile","composio")?["state"] as? String,"disconnected")
            XCTAssertEqual(provider.writes,0)
        }
    }
    func testCatalogPaginationRetainsSchemaAndDiscardsAccountCredentials() throws {
        try fixture { _,_,_,connector,provider,_ in
            _ = try configure(connector)
            let page = try XCTUnwrap(connector.handle("connectors.tools.search",["toolkit":"fixture","query":"read + files","cursor":"cursor+/=","limit":12]) as? JSON)
            XCTAssertEqual(page["hasMore"] as? Bool,true); XCTAssertEqual(string(page,"nextCursor"),"page-two")
            XCTAssertEqual(provider.calls.last?.query["query"],"read + files")
            XCTAssertEqual(provider.calls.last?.query["cursor"],"cursor+/=")
            let tool = try XCTUnwrap((page["items"] as? [JSON])?.first)
            XCTAssertEqual(try jsonString(tool["inputSchema"]!),try jsonString(provider.tool["input_parameters"]!))
            XCTAssertEqual(tool["approvalRequired"] as? Bool,true)
            for method in ["connectors.accounts.list","connectors.authConfigs.list"] {
                let result = try XCTUnwrap(connector.handle(method,[:]))
                XCTAssertFalse(try jsonString(result).contains("SECRET_"))
            }
            provider.account["user_id"] = "another-user"
            let accounts = try XCTUnwrap(connector.handle("connectors.accounts.list",[:]) as? JSON)
            XCTAssertTrue((accounts["items"] as? [JSON])?.isEmpty == true)
            XCTAssertThrowsError(try connector.account(id:"ca_fixture",profile:connector.profile(),active:true))
        }
    }
    func testExactActionIsOnlyExecutedOnceAfterFrozenApproval() throws {
        try fixture { project,store,service,connector,provider,_ in
            _ = try configure(connector)
            let request = try params(project,connector)
            let preview = try service.createConnectorAction(request,dryRun:true)
            XCTAssertEqual(preview["saved"] as? Bool,false); XCTAssertTrue(try store.list("approval").isEmpty)
            let action = try service.createConnectorAction(request)
            XCTAssertEqual(provider.writes,0)
            let decision = try approve(service,action)
            XCTAssertEqual(string(decision,"state"),"executed"); XCTAssertEqual(provider.writes,1)
            let sent = try XCTUnwrap(provider.calls.last)
            XCTAssertEqual(sent.path,"/tools/execute/FIXTURE_READ")
            XCTAssertEqual(sent.body?["connected_account_id"] as? String,"ca_fixture")
            XCTAssertEqual(sent.body?["version"] as? String,"20260913_01")
            XCTAssertEqual(try jsonString(sent.body?["arguments"] ?? [:]),try jsonString(request["arguments"]!))
            XCTAssertThrowsError(try approve(service,action)); XCTAssertEqual(provider.writes,1)
            XCTAssertFalse(try jsonString(store.list("connector_action")).contains("synthetic-project-key"))
        }
    }
    func testChangedSchemaAccountAndCredentialGenerationFailBeforeAction() throws {
        try fixture { project,_,service,connector,provider,_ in
            _ = try configure(connector)
            let action = try service.createConnectorAction(params(project,connector))
            provider.tool["description"] = "Changed after review"
            XCTAssertEqual(string(try approve(service,action),"state"),"failed")
            XCTAssertEqual(provider.writes,0)
            let second = try service.createConnectorAction(params(project,connector))
            provider.account["is_disabled"] = true
            XCTAssertEqual(string(try approve(service,second),"state"),"failed")
            XCTAssertEqual(provider.writes,0); provider.account["is_disabled"] = false
            let third = try service.createConnectorAction(params(project,connector))
            _ = try connector.handle("connectors.configure",["apiKey":"synthetic-project-key-two","userId":"user_fixture"])
            XCTAssertEqual(string(try approve(service,third),"state"),"failed")
            XCTAssertEqual(provider.writes,0)
        }
    }
    func testUnknownNetworkOutcomeIsRetainedAndNeverAutomaticallyRetried() throws {
        try fixture { project,store,service,connector,provider,_ in
            _ = try configure(connector)
            let action = try service.createConnectorAction(params(project,connector))
            provider.failWrites = true
            XCTAssertEqual(string(try approve(service,action),"state"),"needs_review")
            let recorded = try service.connectorAction(["project":project.path,"id":action["id"]!])
            XCTAssertEqual(string(recorded,"state"),"needs_review")
            XCTAssertEqual((recorded["result"] as? JSON)?["outcomeUnknown"] as? Bool,true)
            let reopened = AutomationService(store:try VelaStore(root:store.root)); reopened.connectorService = connector
            XCTAssertThrowsError(try approve(reopened,action)); XCTAssertEqual(provider.writes,1)
            let acknowledged = try reopened.acknowledgeConnectorAction(["project":project.path,"id":action["id"]!,"requestHash":action["requestHash"]!,"decision":"acknowledge_no_retry"])
            XCTAssertEqual(string(acknowledged,"state"),"acknowledged")
            XCTAssertEqual((acknowledged["result"] as? JSON)?["outcomeUnknown"] as? Bool,true)
            XCTAssertEqual(provider.writes,1)
            XCTAssertTrue(try store.list("approval").allSatisfy { string($0,"state") == "acknowledged" })
        }
    }
    func testAuthLinkUsesCurrentEndpointAndNeverClaimsAccountActivation() throws {
        try fixture { project,store,service,connector,provider,_ in
            _ = try configure(connector)
            let action = try service.createConnectorAction(["project":project.path,"action":"connect","authConfigId":"ac_fixture","toolkit":"fixture"])
            XCTAssertEqual(provider.writes,0)
            let decision = try approve(service,action)
            XCTAssertEqual(string(decision,"state"),"executed")
            XCTAssertEqual(provider.calls.last?.path,"/connected_accounts/link")
            let result = try XCTUnwrap(decision["result"] as? JSON)
            XCTAssertEqual(result["connectionVerified"] as? Bool,false)
            XCTAssertEqual(string(result,"redirectURL"),provider.link)
            XCTAssertFalse(try jsonString(store.list("connector_action")).contains("DO_NOT_PERSIST_LINK_TOKEN"))
            provider.link = "https://attacker.invalid/link"
            let bad = try service.createConnectorAction(["project":project.path,"action":"connect","authConfigId":"ac_fixture","toolkit":"fixture"])
            // The link response is invalid after a POST. Preserve uncertainty
            // about the remote auth session instead of asserting no mutation.
            XCTAssertEqual(string(try approve(service,bad),"state"),"needs_review")
        }
    }
    func testInvalidIdentitiesPrivateCredentialFieldsAndCrossProjectReadsAreRejected() throws {
        try fixture { project,_,service,connector,provider,_ in
            _ = try configure(connector)
            for slug in ["../tools","http://attacker","tool?version=x","a/b"] { XCTAssertThrowsError(try connector.handle("connectors.tools.get",["slug":slug])) }
            provider.account["is_disabled"] = "true"
            XCTAssertThrowsError(try connector.account(id:"ca_fixture",profile:connector.profile(),active:true))
            provider.account["is_disabled"] = false
            let action = try service.createConnectorAction(params(project,connector))
            XCTAssertThrowsError(try service.connectorAction(["project":project.deletingLastPathComponent().path,"id":action["id"]!]))
            var extra = try params(project,connector); extra["apiKey"] = "must-not-enter-approval"
            XCTAssertThrowsError(try service.createConnectorAction(extra))
            XCTAssertEqual(provider.writes,0)
        }
    }
    func testWorkflowDryRunNeverConnectsAndRealRunUsesItsOwnOneShotApproval() throws {
        try fixture { project,_,service,connector,provider,_ in
            _ = try configure(connector)
            var input = try params(project,connector); input.removeValue(forKey:"project"); input.removeValue(forKey:"action")
            let workflow = try XCTUnwrap(service.handle("workflows.save",["project":project.path,"title":"External workflow fixture","steps":[["tool":"connector.call","arguments":input]]]) as? JSON)
            let before = provider.calls.count
            let preview = try service.startWorkflow(id:string(workflow,"id"),dryRun:true)
            XCTAssertEqual(string(preview,"state"),"completed"); XCTAssertEqual(provider.calls.count,before)
            let run = try service.startWorkflow(id:string(workflow,"id"),dryRun:false)
            XCTAssertEqual(string(run,"state"),"pending_approval"); XCTAssertEqual(provider.writes,0)
            let inbox = try XCTUnwrap(service.handle("inbox.list",[:]) as? [JSON])
            let approval = try XCTUnwrap(inbox.first)
            let decision = try approve(service,["approval":approval])
            XCTAssertEqual(string(decision,"state"),"executed"); XCTAssertEqual(provider.writes,1)
            XCTAssertEqual(string(decision["run"] as? JSON ?? [:],"state"),"completed")
        }
    }

    func testProviderFailureCannotProveAbsenceOfPartialExternalEffects() throws {
        try fixture { project,_,service,connector,provider,_ in
            _ = try configure(connector)
            let action = try service.createConnectorAction(params(project,connector))
            provider.reviewResponse = ["successful":false,"data":["sent":true],"error":"upstream timeout after sending"]
            XCTAssertEqual(string(try approve(service,action),"state"),"needs_review")
            let recorded = try service.connectorAction(["project":project.path,"id":action["id"]!])
            XCTAssertEqual(string(recorded,"state"),"needs_review")
            XCTAssertEqual((recorded["result"] as? JSON)?["outcomeUnknown"] as? Bool,true)
            XCTAssertThrowsError(try approve(service,action)); XCTAssertEqual(provider.writes,1)
        }
    }

    func testProjectCredentialEchoIsRejectedBeforeAnyPersistence() throws {
        try fixture { project,store,service,connector,provider,_ in
            _ = try configure(connector)
            let action = try service.createConnectorAction(params(project,connector))
            provider.reviewResponse = ["successful":true,"data":["debug":"prefix synthetic-project-key-one suffix"],"error":NSNull()]
            XCTAssertEqual(string(try approve(service,action),"state"),"needs_review")
            for kind in ["connector_action","approval","run","connector_tool","connector_profile"] {
                XCTAssertFalse(try jsonString(store.list(kind)).contains("synthetic-project-key-one"))
            }
            provider.tool["description"] = "synthetic-project-key-one"
            XCTAssertThrowsError(try connector.handle("connectors.tools.get",["slug":"FIXTURE_READ"]))
            XCTAssertFalse(try jsonString(store.list("connector_tool")).contains("synthetic-project-key-one"))
            XCTAssertEqual(provider.writes,1)
        }
    }

    func testResultCredentialFieldsAreExplicitlyRedactedWithoutLosingOrdinaryData() throws {
        try fixture { project,store,service,connector,provider,_ in
            _ = try configure(connector)
            let action = try service.createConnectorAction(params(project,connector))
            provider.reviewResponse = ["successful":true,"data":["message":"synthetic result","nested":[["access_token":"PRIVATE_REMOTE_ACCESS","clientSecret":"PRIVATE_REMOTE_CLIENT"]]],"error":NSNull()]
            let decision = try approve(service,action)
            XCTAssertEqual(string(decision,"state"),"executed")
            let result = try XCTUnwrap(decision["result"] as? JSON)
            XCTAssertEqual(intValue(result,"redactedFields"),2)
            XCTAssertTrue(string(result,"output").contains("synthetic result"))
            XCTAssertTrue(string(result,"output").contains("[REDACTED]"))
            for kind in ["connector_action","approval","run"] { XCTAssertFalse(try jsonString(store.list(kind)).contains("PRIVATE_REMOTE_")) }
        }
    }
    func testSuccessfulScalarAndNullResponsesPreserveActualCompletion() throws {
        try fixture { project,store,service,connector,provider,_ in
            _ = try configure(connector)
            for data: Any in ["synthetic completion",42,true,NSNull()] {
                let action = try service.createConnectorAction(params(project,connector))
                provider.reviewResponse = ["successful":true,"data":data,"error":NSNull()]
                let decision = try approve(service,action)
                XCTAssertEqual(string(decision,"state"),"executed")
                let result = try XCTUnwrap(decision["result"] as? JSON)
                XCTAssertEqual(result["outcomeUnknown"] as? Bool,false)
                let decoded = try JSONSerialization.jsonObject(with:Data(string(result,"output").utf8),options:[.fragmentsAllowed])
                XCTAssertEqual(try WorkflowContext.jsonText(decoded),try WorkflowContext.jsonText(data))
            }
            XCTAssertEqual(provider.writes,4)
        }
    }
}
