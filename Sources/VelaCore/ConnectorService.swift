import Foundation
import CoreFoundation

final class ConnectorService {
    let store: VelaStore
    let transport: ConnectorTransport
    let vault: ConnectorCredentialVault
    init(store: VelaStore, transport: ConnectorTransport = ComposioTransport(), vault: ConnectorCredentialVault? = nil) {
        self.store = store; self.transport = transport; self.vault = vault ?? ConnectorKeychain(root:store.root)
    }
    static func identifier(_ value: String) throws -> String {
        guard value.range(of:"^[A-Za-z0-9_-]{1,160}$",options:.regularExpression) != nil else { throw VelaError("Invalid connector identifier") }; return value
    }
    static func text(_ object: JSON, _ key: String, limit: Int = 4000) throws -> String {
        let value = try requireString(object,key)
        guard value.utf8.count <= limit, !value.contains("\0") else { throw VelaError("Invalid connector field: " + key) }; return value
    }
    static func keys(_ params: JSON, _ allowed: Set<String>) throws {
        guard Set(params.keys).isSubset(of:allowed) else { throw VelaError("Unsupported connector parameters") }
    }
    static func boolean(_ object: JSON, _ key: String, default fallback: Bool) throws -> Bool {
        guard let raw = object[key] else { return fallback }
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw VelaError("Invalid connector boolean: " + key) }; return value.boolValue
    }
    static func validateWorkflowArguments(_ params: JSON) throws {
        try keys(params,["toolSlug","version","catalogHash","connectedAccountId","arguments"])
        _ = try identifier(requireString(params,"toolSlug")); _ = try identifier(requireString(params,"version"))
        guard string(params,"version").lowercased() != "latest", string(params,"catalogHash").range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              let args = params["arguments"] as? JSON, try jsonString(args).utf8.count <= 524_288 else { throw VelaError("An external workflow step requires concrete tool version, reviewed catalog hash and bounded arguments") }
        if let account = params["connectedAccountId"] { guard let id = account as? String else { throw VelaError("Invalid account ID") }; _ = try identifier(id) }
    }
    func profile() throws -> JSON {
        guard let profile = try store.get("connector_profile","composio"), string(profile,"state") == "configured" else { throw VelaError("Configure Composio explicitly before using external tools") }
        return profile
    }
    func send(_ request: ConnectorRequest, profile: JSON) throws -> JSON {
        try sendAuthenticated(request,key:vault.read(generation:requireString(profile,"generation")))
    }
    private func sendAuthenticated(_ request: ConnectorRequest, key: String) throws -> JSON {
        do {
            let response = try transport.send(request,key:key)
            // Reject credential echoes before any catalog cache, approval, run,
            // or RPC result can receive the provider's response. Do not silently
            // rewrite a reviewed tool schema to conceal a credential leak.
            guard !Self.containsCredential(response,key:key) else {
                throw ConnectorHTTPError(status:0,outcomeUnknown:request.method != "GET",retryAfter:nil)
            }
            return response
        } catch let error as ConnectorHTTPError { throw error }
        catch {
            // An arbitrary transport/parser error may also contain credentials.
            // A submitted mutation has no trustworthy failure receipt here.
            throw ConnectorHTTPError(status:0,outcomeUnknown:request.method != "GET",retryAfter:nil)
        }
    }
    private static func containsCredential(_ value: Any, key: String) -> Bool {
        if let text = value as? String { return text.contains(key) }
        if let object = value as? JSON { return object.contains { $0.key.contains(key) || containsCredential($0.value,key:key) } }
        if let array = value as? [Any] { return array.contains { containsCredential($0,key:key) } }
        return false
    }
    private static func redactResult(_ value: Any, count: inout Int, depth: Int = 0) -> Any {
        guard depth < 64 else { count += 1; return "[REDACTED: nesting limit]" }
        if let object = value as? JSON {
            let secretFields: Set<String> = ["apikey","accesstoken","refreshtoken","idtoken","clientsecret","password","privatekey","authorization","cookie","setcookie","credential","credentials","secret","token","linktoken"]
            return object.reduce(into: JSON()) { result, field in
                let normalized = field.key.lowercased().filter { $0.isLetter || $0.isNumber }
                if secretFields.contains(normalized), !(field.value is NSNull) {
                    count += 1; result[field.key] = "[REDACTED]"
                } else { result[field.key] = redactResult(field.value,count:&count,depth:depth+1) }
            }
        }
        if let array = value as? [Any] { return array.map { redactResult($0,count:&count,depth:depth+1) } }
        return value
    }
    func handle(_ method: String, _ params: JSON) throws -> Any? {
        switch method {
        case "connectors.status":
            try Self.keys(params,[])
            return try store.get("connector_profile","composio") ?? ["id":"composio","state":"not_configured","networkRequested":false]
        case "connectors.configure":
            try Self.keys(params,["apiKey","userId"])
            let key = try Self.text(params,"apiKey",limit:4096)
            guard key.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) else { throw VelaError("Invalid project key") }
            let userID = try Self.text(params,"userId",limit:160)
            let prior = try store.get("connector_profile","composio")
            // Permission verification happens before storing a new credential.
            let probe = try sendAuthenticated(ConnectorRequest(method:"GET",path:"/auth_configs",query:["limit":"1"]),key:key)
            guard probe["items"] is [JSON] else { throw VelaError("Composio returned an invalid authentication catalog") }
            let generation = UUID().uuidString.lowercased()
            try vault.create(key,generation:generation)
            do {
                let value: JSON = ["id":"composio","provider":"composio","state":"configured","userId":userID,"generation":generation,"verifiedAt":isoNow(),"endpoint":ComposioTransport.baseURL,"secretStorage":"macOS Keychain","toolCallsVerified":false]
                let expected = try prior.map { [("connector_profile","composio",stableHash(try jsonString($0)))] } ?? []
                let saved = try store.putBatch([("connector_profile",value)],expecting:expected,createOnly:prior == nil)[0]
                if let old = prior?["generation"] as? String { try? vault.remove(generation:old) }
                return saved
            } catch { try? vault.remove(generation:generation); throw error }
        case "connectors.forget":
            try Self.keys(params,["generation"])
            guard let old = try store.get("connector_profile","composio") else { throw VelaError("Connector is not configured") }
            guard string(old,"generation") == (try requireString(params,"generation")) else { throw VelaError("Connector changed; review the current connection") }
            var disconnected = old; disconnected["state"] = "disconnected"
            let saved = try store.putBatch([("connector_profile",disconnected)],expecting:[("connector_profile","composio",stableHash(try jsonString(old)))])[0]
            try vault.remove(generation:string(old,"generation"))
            return saved
        case "connectors.tools.list":
            try Self.keys(params,[])
            let generation = string(try profile(),"generation")
            return try store.list("connector_tool",limit:1000).filter { string($0,"generation") == generation }
        case "connectors.tools.search", "connectors.toolkits.list", "connectors.accounts.list", "connectors.authConfigs.list":
            return try browse(method,params)
        case "connectors.tools.get":
            try Self.keys(params,["slug","version"])
            return try tool(slug:Self.identifier(requireString(params,"slug")),version:params["version"] as? String,profile:profile())
        default: return nil
        }
    }
    private func browse(_ method: String, _ params: JSON) throws -> JSON {
        try Self.keys(params,["query","toolkit","cursor","limit"])
        let profile = try profile()
        let limit = try WorkflowContext.integer(params["limit"],default:25,range:1...(method == "connectors.authConfigs.list" ? 50 : 100),name:"connector page size")
        var query = ["limit":String(limit)]
        if let cursor = params["cursor"] { guard let value = cursor as? String, value.utf8.count <= 4096 else { throw VelaError("Invalid connector cursor") }; query["cursor"] = value }
        if let text = params["query"] { guard let value = text as? String, value.utf8.count <= 500, !value.contains("\0") else { throw VelaError("Invalid connector query") }; query[method == "connectors.authConfigs.list" ? "search" : "query"] = value }
        if let toolkit = params["toolkit"] as? String { query[method == "connectors.accounts.list" ? "toolkit_slugs" : "toolkit_slug"] = try Self.identifier(toolkit) }
        let path: String
        switch method {
        case "connectors.tools.search": path = "/tools"; query["include_deprecated"] = "false"
        case "connectors.toolkits.list": path = "/toolkits"
        case "connectors.accounts.list": path = "/connected_accounts"; query["user_ids"] = string(profile,"userId")
        default: path = "/auth_configs"
        }
        let response = try send(ConnectorRequest(method:"GET",path:path,query:query),profile:profile)
        guard let rows = response["items"] as? [JSON], rows.count <= 1000 else { throw VelaError("Invalid connector page") }
        let items: [JSON]
        switch method {
        case "connectors.tools.search":
            items = try rows.map { try catalogTool($0,profile:profile) }
            if !items.isEmpty { _ = try store.putBatch(items.map { ("connector_tool",$0) }) }
        case "connectors.accounts.list":
            items = try rows.filter { string($0,"user_id") == string(profile,"userId") }.map(Self.account)
        case "connectors.authConfigs.list": items = try rows.map(Self.authConfig)
        default: items = rows.map { $0.filter { ["slug","name","description","meta","auth_schemes","no_auth"].contains($0.key) } }
        }
        let next = response["next_cursor"] as? String
        guard next == nil || next!.utf8.count <= 4096 else { throw VelaError("Invalid provider pagination cursor") }
        return ["items":items,"nextCursor":next as Any? ?? NSNull(),"hasMore":next?.isEmpty == false,"sourceCapturedAt":isoNow(),"provider":"composio","apiVersion":"v3.1","networkRequested":true]
    }
    static func account(_ raw: JSON) throws -> JSON {
        let id = try identifier(requireString(raw,"id"))
        guard let toolkit = raw["toolkit"] as? JSON else { throw VelaError("Account has no toolkit identity") }
        let auth = raw["auth_config"] as? JSON ?? [:]
        // Do not return state.val, data, credential fields, proxy data or tokens.
        return ["id":id,"toolkit":try identifier(requireString(toolkit,"slug")),"userId":try text(raw,"user_id",limit:160),"status":string(raw,"status"),"disabled":try boolean(raw,"is_disabled",default:false),"authConfigId":string(auth,"id"),"authScheme":string(auth,"auth_scheme",string(raw,"authScheme")),"alias":String(string(raw,"alias").prefix(240))]
    }
    static func authConfig(_ raw: JSON) throws -> JSON {
        guard let toolkit = raw["toolkit"] as? JSON else { throw VelaError("Auth configuration has no toolkit identity") }
        return ["id":try identifier(requireString(raw,"id")),"toolkit":try identifier(requireString(toolkit,"slug")),"name":String(string(raw,"name").prefix(240)),"scheme":string(raw,"auth_scheme"),"status":string(raw,"status"),"managed":raw["is_composio_managed"] as? Bool ?? false,"restrictedTools":raw["restrict_to_following_tools"] as? [String] ?? []]
    }
    func account(id: String, profile: JSON, active: Bool) throws -> JSON {
        let raw = try send(ConnectorRequest(method:"GET",path:"/connected_accounts/" + Self.identifier(id)),profile:profile)
        let value = try Self.account(raw)
        guard string(value,"id") == id, string(value,"userId") == string(profile,"userId") else { throw VelaError("Selected account does not belong to this configured user") }
        if active { guard string(value,"status") == "ACTIVE", value["disabled"] as? Bool == false else { throw VelaError("Selected account is not active; reconnect before planning this action") } }
        return value
    }
    func catalogTool(_ raw: JSON, profile: JSON) throws -> JSON {
        let slug = try Self.identifier(requireString(raw,"slug")), version = try Self.identifier(requireString(raw,"version"))
        guard version.lowercased() != "latest", let toolkit = raw["toolkit"] as? JSON, let schema = raw["input_parameters"] as? JSON else { throw VelaError("A tool must expose a concrete version, toolkit and parameter schema") }
        let tool: JSON = ["slug":slug,"version":version,"toolkit":try Self.identifier(requireString(toolkit,"slug")),"name":String(string(raw,"name",slug).prefix(500)),"description":String(string(raw,"description").prefix(16000)),"inputSchema":schema,"outputSchema":raw["output_parameters"] as? JSON ?? [:],"noAuth":try Self.boolean(raw,"no_auth",default:false),"tags":raw["tags"] as? [String] ?? [],"scopes":raw["scopes"] as? [String] ?? [],"scopeRequirements":raw["scope_requirements"] as? JSON ?? [:],"deprecated":try Self.boolean(raw,"is_deprecated",default:false)]
        guard try jsonString(tool).utf8.count <= 262_144 else { throw VelaError("Tool schema exceeds its 256 KiB limit") }
        var result = tool
        result["id"] = stableHash(string(profile,"generation") + ":" + slug + ":" + version)
        result["generation"] = string(profile,"generation"); result["catalogHash"] = stableHash(try jsonString(tool))
        result["sourceCapturedAt"] = isoNow(); result["approvalRequired"] = true
        return result
    }
    func tool(slug: String, version: String?, profile: JSON) throws -> JSON {
        var query: [String:String] = [:]
        if let version { query["version"] = try Self.identifier(version) }
        let raw = try send(ConnectorRequest(method:"GET",path:"/tools/" + Self.identifier(slug),query:query),profile:profile)
        let result = try catalogTool(raw,profile:profile)
        guard string(result,"slug") == slug, version == nil || string(result,"version") == version else { throw VelaError("Provider returned a different tool version") }
        _ = try store.put("connector_tool",result); return result
    }
    func prepare(_ params: JSON) throws -> JSON {
        try Self.keys(params,["project","action","toolSlug","version","catalogHash","connectedAccountId","arguments","authConfigId","toolkit"])
        let profile = try profile(), action = try Self.text(params,"action",limit:40)
        var request: JSON = ["protocol":"vela-composio-v3.1-v1","action":action,"generation":string(profile,"generation"),"userId":string(profile,"userId")]
        switch action {
        case "tool":
            try Self.keys(params,["project","action","toolSlug","version","catalogHash","connectedAccountId","arguments"])
            let slug = try Self.identifier(requireString(params,"toolSlug")), version = try Self.identifier(requireString(params,"version"))
            let selected = try tool(slug:slug,version:version,profile:profile)
            guard string(selected,"catalogHash") == (try requireString(params,"catalogHash")), selected["deprecated"] as? Bool == false,
                  let args = params["arguments"] as? JSON, try jsonString(args).utf8.count <= 524_288 else { throw VelaError("Review the current nondeprecated tool schema and bounded argument object") }
            request["tool"] = selected; request["arguments"] = args
            if selected["noAuth"] as? Bool != true {
                let account = try account(id:requireString(params,"connectedAccountId"),profile:profile,active:true)
                guard string(account,"toolkit") == string(selected,"toolkit") else { throw VelaError("Account toolkit does not match the selected tool") }; request["account"] = account
            } else if params["connectedAccountId"] != nil { throw VelaError("This no-auth tool does not take a connected account") }
        case "connect":
            try Self.keys(params,["project","action","authConfigId","toolkit"])
            let id = try Self.identifier(requireString(params,"authConfigId"))
            let config = try Self.authConfig(send(ConnectorRequest(method:"GET",path:"/auth_configs/" + id),profile:profile))
            guard string(config,"id") == id, string(config,"status") == "ENABLED", string(config,"toolkit") == (try Self.identifier(requireString(params,"toolkit"))) else { throw VelaError("Review an enabled auth configuration for the selected toolkit") }
            request["authConfig"] = config
        case "disable","enable","disconnect","revoke","reauthenticate":
            try Self.keys(params,["project","action","connectedAccountId"])
            request["account"] = try account(id:requireString(params,"connectedAccountId"),profile:profile,active:false)
        default: throw VelaError("Unsupported connector action")
        }
        return request
    }
    func execute(_ frozen: JSON) throws -> JSON {
        let profile = try profile()
        guard string(frozen,"protocol") == "vela-composio-v3.1-v1", string(profile,"generation") == string(frozen,"generation"), string(profile,"userId") == string(frozen,"userId") else { throw VelaError("Connector identity changed after approval; create a new reviewed action") }
        let action = string(frozen,"action")
        var currentAccount: JSON?
        if let old = frozen["account"] as? JSON {
            let current = try account(id:requireString(old,"id"),profile:profile,active:action == "tool")
            for key in ["id","toolkit","userId","authConfigId","authScheme","status","disabled"] {
                guard try WorkflowContext.jsonText(old[key] ?? NSNull()) == WorkflowContext.jsonText(current[key] ?? NSNull()) else { throw VelaError("Connected account changed after review") }
            }
            currentAccount = current
        }
        let request: ConnectorRequest
        switch action {
        case "tool":
            guard let selected = frozen["tool"] as? JSON, let args = frozen["arguments"] as? JSON else { throw VelaError("Missing frozen tool request") }
            let current = try tool(slug:requireString(selected,"slug"),version:requireString(selected,"version"),profile:profile)
            guard string(current,"catalogHash") == string(selected,"catalogHash") else { throw VelaError("Tool schema changed after review") }
            var body: JSON = ["arguments":args,"version":string(selected,"version"),"user_id":string(profile,"userId")]
            if let currentAccount { body["connected_account_id"] = string(currentAccount,"id") }
            request = ConnectorRequest(method:"POST",path:"/tools/execute/" + (try Self.identifier(requireString(selected,"slug"))),body:body)
        case "connect":
            guard let old = frozen["authConfig"] as? JSON else { throw VelaError("Missing frozen auth configuration") }
            let id = try Self.identifier(requireString(old,"id"))
            let current = try Self.authConfig(send(ConnectorRequest(method:"GET",path:"/auth_configs/" + id),profile:profile))
            guard try jsonString(old) == jsonString(current) else { throw VelaError("Auth configuration changed after review") }
            request = ConnectorRequest(method:"POST",path:"/connected_accounts/link",body:["auth_config_id":id,"user_id":string(profile,"userId")])
        default:
            guard let account = currentAccount else { throw VelaError("Missing frozen account") }
            let path = "/connected_accounts/" + (try Self.identifier(requireString(account,"id")))
            switch action {
            case "disable","enable": request = ConnectorRequest(method:"PATCH",path:path + "/status",body:["enabled":action == "enable"])
            case "disconnect": request = ConnectorRequest(method:"DELETE",path:path)
            case "revoke": request = ConnectorRequest(method:"POST",path:path + "/revoke",body:[:])
            case "reauthenticate": request = ConnectorRequest(method:"POST",path:path + "/refresh",body:[:])
            default: throw VelaError("Unsupported connector action")
            }
        }
        let started = Date()
        do {
            let response = try send(request,profile:profile)
            let result: JSON
            if action == "tool" {
                guard response["successful"] != nil else { throw VelaError("Tool response has no success evidence") }
                let success = try Self.boolean(response,"successful",default:false)
                if success, let error = response["error"], !(error is NSNull), (error as? String)?.isEmpty != true { throw VelaError("Tool response has contradictory success and error evidence") }
                var redactedCount = 0
                let data = Self.redactResult(response["data"] ?? [:],count:&redactedCount)
                let providerError = Self.redactResult(response["error"] ?? NSNull(),count:&redactedCount)
                // successful:false describes the provider's result, not proof
                // that an external tool had no partial effects. Never continue
                // a dependent workflow or permit an automatic retry from it.
                result = ["exitCode":success ? 0 : 1,"output":try WorkflowContext.jsonText(data),"providerSuccessful":success,"providerError":providerError,"logId":(response["log_id"] as? String).map { String($0.prefix(4096)) } as Any? ?? NSNull(),"outcomeUnknown":!success,"redactedFields":redactedCount]
            } else if ["connect","reauthenticate"].contains(action) {
                let rawURL = string(response,"redirect_url",string(response,"redirectUrl"))
                guard let url = URL(string:rawURL), url.scheme == "https", url.user == nil, url.password == nil, let host = url.host, host == "composio.dev" || host.hasSuffix(".composio.dev") else { throw VelaError("Provider returned an unrecognized authentication link; no URL was opened") }
                result = ["exitCode":0,"output":"Authentication link created; account activation still requires user consent and status verification","redirectURL":url.absoluteString,"expiresAt":response["expires_at"] ?? NSNull(),"connectedAccountId":response["connected_account_id"] ?? NSNull(),"connectionVerified":false,"outcomeUnknown":false]
            } else { result = ["exitCode":0,"output":"Provider accepted the account action; refresh accounts to verify its current state","outcomeUnknown":false] }
            return result.merging(["durationMs":Int(Date().timeIntervalSince(started)*1000),"provider":"composio","apiVersion":"v3.1","retried":false]) { _,new in new }
        } catch {
            return ["exitCode":-1,"output":error.localizedDescription,"outcomeUnknown":(error as? ConnectorHTTPError)?.outcomeUnknown ?? true,"httpStatus":(error as? ConnectorHTTPError)?.status ?? 0,"durationMs":Int(Date().timeIntervalSince(started)*1000),"retried":false]
        }
    }
}

extension AutomationService {
    func connector() -> ConnectorService {
        if let connectorService { return connectorService }
        let service = ConnectorService(store:store); connectorService = service; return service
    }
    func createConnectorAction(_ params: JSON, dryRun: Bool = false) throws -> JSON {
        let root = try project(requireString(params,"project"))
        let request = try connector().prepare(params), hash = stableHash(try jsonString(request))
        if dryRun { return ["project":root,"request":request,"requestHash":hash,"dryRun":true,"externalActionExecuted":false,"saved":false] }
        return try createPreparedConnectorAction(request,project:root)
    }
    // Internal only: callers must have prepared and verified this exact request.
    // Execute still rechecks generation, account identity and the tool schema.
    func createPreparedConnectorAction(_ request: JSON, project root: String) throws -> JSON {
        _ = try project(root)
        let hash = stableHash(try jsonString(request))
        let actionID = UUID().uuidString.lowercased(), runID = UUID().uuidString.lowercased(), approvalID = UUID().uuidString.lowercased()
        let args: JSON = ["actionId":actionID,"request":request,"requestHash":hash]
        let approval = try pendingApproval(id:approvalID,title:"Review external " + string(request,"action"),tool:"connector.execute",arguments:args,project:root,runId:runID,stepIndex:0)
        let run: JSON = ["id":runID,"title":"External connector action","project":root,"purpose":"connector","workflowId":"","state":"pending_approval","steps":[["title":"Reviewed external action","tool":"connector.execute","arguments":args,"state":"pending_approval","approvalId":approvalID]],"dryRun":false,"startedAt":isoNow()]
        let action: JSON = ["id":actionID,"project":root,"request":request,"requestHash":hash,"state":"pending_approval","runId":runID,"approvalId":approvalID]
        _ = try store.putBatch([("connector_action",action),("run",run),("approval",approval)],createOnly:true)
        return action.merging(["approval":approval]) { _,new in new }
    }
    func executeConnectorAction(_ arguments: JSON, project: String) throws -> JSON {
        var action = try object("connector_action",requireString(arguments,"actionId"))
        guard let request = arguments["request"] as? JSON, string(action,"project") == project,
              stableHash(try jsonString(request)) == string(arguments,"requestHash"), string(action,"requestHash") == string(arguments,"requestHash"),
              try jsonString(action["request"] ?? [:]) == jsonString(request), string(action,"state") == "pending_approval",
              let approval = try store.get("approval",string(action,"approvalId")), string(approval,"state") == "executing" else { throw VelaError("External request no longer matches its executing approval") }
        action["state"] = "executing_or_uncertain"; _ = try store.put("connector_action",action)
        let result = try connector().execute(request)
        action["result"] = result; action["state"] = result["outcomeUnknown"] as? Bool == true ? "needs_review" : intValue(result,"exitCode") == 0 ? "completed" : "failed"
        action["completedAt"] = isoNow(); _ = try store.put("connector_action",action)
        return result
    }
    func connectorAction(_ params: JSON) throws -> JSON {
        let root = try project(requireString(params,"project"))
        var action = try object("connector_action",requireString(params,"id"))
        guard string(action,"project") == root else { throw VelaError("Connector action belongs to another project") }
        if let approval = try store.get("approval",string(action,"approvalId")) {
            switch string(approval,"state") {
            case "rejected", "expired": action["state"] = string(approval,"state")
            case "executing": action["state"] = "executing_or_uncertain"
            case "needs_review": action["state"] = "needs_review"
            case "failed": if string(action,"state") != "needs_review" { action["state"] = "failed" }
            default: break
            }
            action["approval"] = approval
        }
        return action
    }
    func acknowledgeConnectorAction(_ params: JSON) throws -> JSON {
        try ConnectorService.keys(params,["id","project","requestHash","decision"])
        guard string(params,"decision") == "acknowledge_no_retry" else { throw VelaError("Only acknowledgement without retry is supported") }
        let root = try project(requireString(params,"project"))
        var action = try object("connector_action",requireString(params,"id"))
        guard string(action,"project") == root, string(action,"requestHash") == (try requireString(params,"requestHash")),
              let originalApproval = try store.get("approval",string(action,"approvalId")), string(originalApproval,"state") == "needs_review",
              var run = try store.get("run",string(action,"runId")), string(run,"state") == "needs_review" else { throw VelaError("Inspect the current uncertain outcome before acknowledging it") }
        let expected = [("connector_action",string(action,"id"),stableHash(try jsonString(action))),
                        ("approval",string(originalApproval,"id"),stableHash(try jsonString(originalApproval))),
                        ("run",string(run,"id"),stableHash(try jsonString(run)))]
        action["state"] = "acknowledged"; action["acknowledgedAt"] = isoNow(); action["retried"] = false
        var approval = originalApproval; approval["state"] = "acknowledged"; approval["acknowledgedAt"] = isoNow()
        // Preserve unknown effect evidence. Acknowledgement is not proof that
        // nothing happened, and cannot execute another step in this run.
        run["state"] = "failed"; run["completedAt"] = isoNow(); run["uncertaintyAcknowledged"] = true
        _ = try store.putBatch([("connector_action",action),("approval",approval),("run",run)],expecting:expected)
        return action
    }
}
