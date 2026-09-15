import Foundation
import CoreFoundation

/// Only the statically published schema subset is accepted; clients cannot
/// install schemas, commands or custom handlers through this interface.
enum MCPInput {
    static func text(_ maximum: Int, minimum: Int = 1) -> JSON { ["type":"string","minLength":minimum,"maxLength":maximum] }
    static func integer(_ minimum: Int, _ maximum: Int) -> JSON { ["type":"integer","minimum":minimum,"maximum":maximum] }
    static func number(_ minimum: Double, _ maximum: Double) -> JSON { ["type":"number","minimum":minimum,"maximum":maximum] }
    static func enumeration(_ values: [String]) -> JSON { ["type":"string","enum":values] }
    static func object(_ properties: JSON, required: [String] = []) -> JSON { ["type":"object","properties":properties,"required":required,"additionalProperties":false] }
    static func array(_ item: JSON, maximum: Int, minimum: Int = 0) -> JSON { ["type":"array","items":item,"minItems":minimum,"maxItems":maximum] }
    static func validate(_ value: Any, schema: JSON, path: String = "arguments", depth: Int = 0) throws {
        guard depth <= 12 else { throw VelaError("MCP input nesting exceeds its limit") }
        if let alternatives = schema["anyOf"] as? [JSON] {
            guard alternatives.contains(where:{ (try? validate(value,schema:$0,path:path,depth:depth+1)) != nil }) else { throw VelaError("MCP \(path) does not match any accepted type") }; return
        }
        switch string(schema,"type") {
        case "object":
            guard let value = value as? JSON, let properties = schema["properties"] as? JSON else { throw VelaError("MCP \(path) must be an object") }
            guard Set(value.keys).isSubset(of:Set(properties.keys)) else { throw VelaError("MCP \(path) contains unsupported fields; create-only tools never accept update IDs or promotion arguments") }
            for key in schema["required"] as? [String] ?? [] where value[key] == nil { throw VelaError("MCP \(path).\(key) is required") }
            for (key,item) in value { try validate(item,schema:properties[key] as! JSON,path:path + "." + key,depth:depth+1) }
        case "array":
            guard let items = value as? [Any], items.count >= intValue(schema,"minItems"), items.count <= intValue(schema,"maxItems"), let child = schema["items"] as? JSON else { throw VelaError("MCP \(path) must be a bounded array") }
            for (index,item) in items.enumerated() { try validate(item,schema:child,path:path + "[\(index)]",depth:depth+1) }
        case "string":
            guard let value = value as? String, value.unicodeScalars.count >= intValue(schema,"minLength"), value.unicodeScalars.count <= (schema["maxLength"] as? Int ?? Int.max), !value.contains("\0") else { throw VelaError("MCP \(path) must be bounded non-NUL text") }
            if let choices = schema["enum"] as? [String], !choices.contains(value) { throw VelaError("MCP \(path) has an unsupported value") }
        case "integer","number":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue >= ((schema["minimum"] as? NSNumber)?.doubleValue ?? -Double.greatestFiniteMagnitude),
                  number.doubleValue <= ((schema["maximum"] as? NSNumber)?.doubleValue ?? Double.greatestFiniteMagnitude) else { throw VelaError("MCP \(path) must be a number in the published range") }
            if string(schema,"type") == "integer", number.doubleValue.rounded() != number.doubleValue { throw VelaError("MCP \(path) must be an integer, not a Boolean or fraction") }
        case "boolean":
            guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw VelaError("MCP \(path) must be a Boolean") }
            if let expected = schema["const"] as? Bool, flag.boolValue != expected { throw VelaError("MCP \(path) has a forbidden Boolean value") }
        default: throw VelaError("Unsupported built-in MCP schema")
        }
    }
}

struct MCPToolDefinition {
    let name: String
    let description: String
    let schema: JSON
    let contribution: Bool
    var json: JSON { ["name":name,"description":description,"inputSchema":schema,"annotations":["readOnlyHint":!contribution,"destructiveHint":false,"idempotentHint":!contribution || name == "vela_local_archive_restore","openWorldHint":false]] }
}
struct MCPToolOutput {
    let value: Any
    var metadata: JSON = [:]
}

/// Stateful stdio protocol surface. The CLI supplies its existing Router, so
/// constructing an MCP session never initializes a second discovery service.
public final class MCPTools {
    let store: VelaStore
    let coreCall: (String,JSON) throws -> Any
    let contribute: Bool
    let serverVersion: String
    let lock = NSRecursiveLock()
    private var negotiated: String?
    private var ready = false
    private var requestIDs = Set<String>()
    static let supportedVersions = ["2024-11-05","2025-03-26","2025-06-18","2025-11-25"]
    static let maximumRequests = 8192
    static func sanitizedText(_ text: String) -> String {
        // Provider key alphabets are ASCII. Unicode word boundaries would miss
        // a key directly next to Chinese prose even though its token is complete.
        ModelImprovement.redact(text).replacingOccurrences(of:"(?<![A-Za-z0-9_])(?:sk-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})(?![A-Za-z0-9_-])",with:"[REDACTED]",options:.regularExpression)
    }
    public init(store: VelaStore, contribute: Bool, serverVersion: String, coreCall: @escaping (String,JSON) throws -> Any) {
        self.store = store; self.contribute = contribute; self.serverVersion = serverVersion; self.coreCall = coreCall
    }
    static var definitions: [MCPToolDefinition] {
        let project = MCPInput.text(1024), id = MCPInput.text(160), title = MCPInput.text(200), content = MCPInput.text(4000)
        let scopes: JSON = ["branch":MCPInput.text(256),"worktree":project,"task":MCPInput.text(256),"sessionId":id,"namespace":MCPInput.text(64)]
        var list: JSON = ["project":project,"limit":MCPInput.integer(1,100),"after":MCPInput.text(160,minimum:0)]
        let simpleList = list
        list.merge(scopes){_,new in new}
        var memoryList = list; memoryList["state"] = MCPInput.enumeration(["active","candidate"])
        var page: JSON = ["project":project,"id":id,"offset":MCPInput.integer(0,2097152),"maxCharacters":MCPInput.integer(1,16000),"sourceHash":MCPInput.text(64)]
        let simplePage = page
        page.merge(scopes){_,new in new}
        var memoryPage = page; memoryPage["state"] = MCPInput.enumeration(["active","candidate"])
        var search = list; search["query"] = MCPInput.text(250); search["after"] = MCPInput.text(180,minimum:0)
        var recall = search; recall.removeValue(forKey:"after")
        recall.merge(["budget":MCPInput.integer(0,4000),"files":MCPInput.array(MCPInput.text(256),maximum:32),"symbols":MCPInput.array(MCPInput.text(128),maximum:32),"retrievalMode":MCPInput.enumeration(["lexical","semantic","hybrid"]),"language":MCPInput.enumeration(["en","zh-Hans"]),"minSimilarity":MCPInput.number(0,1),"scoringWeights":MCPInput.object(["semantic":MCPInput.number(0,10),"recency":MCPInput.number(0,10),"importance":MCPInput.number(0,10),"recencyHalfLifeDays":MCPInput.number(0.01,3650)])]){_,new in new}
        let types = ["decision","constraint","preference","failure","fact","workflow knowledge","observation","hypothesis","checkpoint"]
        let candidateScopes = ["project","repository","branch","worktree","task","session","namespace"]
        var memory: JSON = ["title":title,"content":content,"type":MCPInput.enumeration(types + types.map{$0.capitalized}),"scope":MCPInput.enumeration(candidateScopes + candidateScopes.map{$0.capitalized}),"state":MCPInput.enumeration(["candidate","Candidate"]),"sourceSession":id,"sourceMessage":id]
        memory.merge(scopes.filter{$0.key != "sessionId"}){_,new in new}
        var single = memory; single["project"] = project
        var checkpoint: JSON = ["project":project,"goal":MCPInput.text(2000),"title":title]
        let notes: JSON = ["anyOf":[MCPInput.text(4000,minimum:0),MCPInput.array(MCPInput.text(500),maximum:32)]]
        for key in ["completed","pending","tests","nextActions"] { checkpoint[key] = notes }
        for key in ["decisions","failures","changedFiles"] { checkpoint[key] = MCPInput.array(MCPInput.text(500),maximum:32) }
        let archiveMetadata = MCPInput.object(Dictionary(uniqueKeysWithValues:["branch","worktree","task","namespace","sourceSession","sourceMessage","sourceFile","sourceCommit"].map {($0,MCPInput.text(1024,minimum:0))}))
        let record = MCPInput.object(["sourceId":id,"title":MCPInput.text(300),"content":MCPInput.text(131072),"type":MCPInput.enumeration(types),"scope":MCPInput.enumeration(["project","repository","branch","worktree","task","session","namespace"]),"state":MCPInput.enumeration(["candidate","active","superseded","archived"]),"private":["type":"boolean","const":false],"metadata":archiveMetadata],required:["sourceId","title","content","type","scope","state","private","metadata"])
        let archive = MCPInput.object(["format":MCPInput.enumeration(["vela.memory-archive"]),"version":MCPInput.integer(1,1),"source":MCPInput.object(["project":project,"namespace":MCPInput.text(80)],required:["project","namespace"]),"entries":MCPInput.array(MCPInput.object(["record":record,"sha256":MCPInput.text(64)],required:["record","sha256"]),maximum:100),"sha256":MCPInput.text(64)],required:["format","version","source","entries","sha256"])
        func tool(_ name: String, _ description: String, _ fields: JSON, _ required: [String] = ["project"], contribution: Bool = false) -> MCPToolDefinition {
            MCPToolDefinition(name:name,description:description,schema:MCPInput.object(fields,required:required),contribution:contribution)
        }
        return [
            tool("vela_search","Search a bounded page of safe project evidence; source bodies are refreshed before excerpts. Legacy text result is an array; pagination is in result._meta.",search,["project","query"]),
            tool("vela_recall","Recall active scoped project memories within a token budget. Global/private/stale sources are excluded.",recall,["project","query"]),
            tool("vela_memory_list","List active project memories; explicit state=candidate is for review, not activation. Legacy array plus result._meta pagination.",memoryList),
            tool("vela_setup_list","List captured sanitized project setup metadata; no rescan or provider configuration execution. Legacy array plus result._meta pagination.",simpleList),
            tool("vela_workflows_list","List fresh project workflow summaries, without execution. Legacy array plus result._meta pagination.",simpleList),
            tool("vela_evals_list","List recorded project evaluation summaries, without running models or returning raw model transcripts. Legacy array plus result._meta pagination.",simpleList),
            tool("vela_checkpoints_list","List project checkpoint summaries. Legacy array plus result._meta pagination.",simpleList),
            tool("vela_memory_get","Read a fresh active memory page, or an explicit candidate review page. Offset counts complete characters of fully sanitized text; continuation requires the raw sourceHash.",memoryPage,["project","id"]),
            tool("vela_library_search","Search indexed public project Library paragraphs; index availability is explicit, with no automatic import or model.",["project":project,"query":MCPInput.text(250),"k":MCPInput.integer(1,50),"rerank":["type":"boolean"]],["project","query"]),
            tool("vela_library_list","List fresh explicitly public project Library summaries with a scan cursor.",simpleList),
            tool("vela_library_get","Read a fresh public Library body page. Offset counts complete characters of fully sanitized text; continuation requires unchanged raw sourceHash.",simplePage,["project","id"]),
            tool("vela_guidelines_list","List fresh active project Guideline summaries with a scan cursor.",simpleList),
            tool("vela_guidelines_read","Read an active project Guideline page without modifying it.",simplePage,["project","id"]),
            tool("vela_workflows_read","Read current project Workflow Markdown in bounded character pages; never evaluates inputs, runs or saves the workflow.",simplePage,["project","id"]),
            tool("vela_health","Report this stdio server's permission mode and registered-project store read, not provider or remote-account health.",["project":project]),
            tool("vela_memory_contribute","Create one new candidate memory. No update id, activation, global scope or superseding is accepted.",single,["project","title","content"],contribution:true),
            tool("vela_remember","Remember one candidate in this local project; alias of vela_memory_contribute, with no automatic activation.",single,["project","title","content"],contribution:true),
            tool("vela_remember_bulk","Atomically create 1–20 candidate memories in the selected project. All entries validate before any write.",["project":project,"items":MCPInput.array(MCPInput.object(memory,required:["title","content"]),maximum:20,minimum:1)],["project","items"],contribution:true),
            tool("vela_checkpoint_save","Create a local checkpoint and capture fixed read-only Git status/branch/HEAD with hooks/fsmonitor disabled. No project files are changed.",checkpoint,["project","goal"],contribution:true),
            tool("vela_signal_record","Record candidate evidence tied to an existing public session in this project.",["project":project,"title":title,"content":content,"sourceSession":id,"sourceMessage":id],["project","title","content","sourceSession"],contribution:true),
            tool("vela_suggestion_draft","Create a suggestion draft with no operations or promotion.",["project":project,"title":title,"content":content],["project","title","content"],contribution:true),
            tool("vela_local_archive_restore","Validate and import an explicit local Vela memory archive as candidates. No file path, remote account, decrypt, network restore or activation is performed.",["project":project,"archive":archive],["project","archive"],contribution:true)
        ]
    }
    public func catalog(protocolVersion: String = "2025-11-25") -> [JSON] {
        Self.definitions.filter{contribute || !$0.contribution}.map { definition in
            var value = definition.json
            if protocolVersion == "2024-11-05" { value.removeValue(forKey:"annotations") }
            return value
        }
    }
    private func responseID(_ value: Any?) -> String? {
        if let value = value as? String, value.unicodeScalars.count <= 256 { return "s:" + value }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              abs(number.doubleValue) <= 9007199254740991, number.doubleValue.rounded() == number.doubleValue else { return nil }
        return "n:" + String(number.int64Value)
    }
    private func error(_ code: Int, _ message: String, id: Any = NSNull()) -> JSON { ["jsonrpc":"2.0","id":id,"error":["code":code,"message":message]] }
    public func handle(request: JSON) -> JSON? {
        lock.lock(); defer { lock.unlock() }
        guard string(request,"jsonrpc") == "2.0", let method = request["method"] as? String, !method.isEmpty,
              Set(request.keys).isSubset(of:["jsonrpc","id","method","params"]) else { return error(-32600,"Invalid JSON-RPC request") }
        guard request["params"] == nil || request["params"] is JSON else { return request["id"] == nil ? nil : error(-32602,"MCP params must be an object",id:request["id"] ?? NSNull()) }
        let params = request["params"] as? JSON ?? [:]
        if request["id"] == nil {
            if method == "notifications/initialized", negotiated != nil,
               Set(params.keys).isSubset(of:["_meta"]), params["_meta"] == nil || params["_meta"] is JSON { ready = true }
            // Unknown, malformed, completed and non-cancellable local atomic
            // notifications are ignored. They never invoke a contribution.
            return nil
        }
        guard let id = request["id"], let identity = responseID(id) else { return error(-32600,"MCP request ID must be a bounded string or integer") }
        guard requestIDs.count < Self.maximumRequests else { return error(-32000,"MCP session request budget reached; reconnect without retrying uncertain contributions",id:id) }
        guard requestIDs.insert(identity).inserted else { return error(-32600,"MCP request IDs cannot be reused within a session",id:id) }
        func reply(_ value: JSON) -> JSON { ["jsonrpc":"2.0","id":id,"result":value] }
        do {
            if let meta = params["_meta"] { guard meta is JSON, try jsonString(meta).utf8.count <= 8192 else { return error(-32602,"Invalid MCP metadata",id:id) } }
            switch method {
            case "initialize":
                guard negotiated == nil, Set(params.keys).isSubset(of:["protocolVersion","capabilities","clientInfo","_meta"]),
                      let requested = params["protocolVersion"] as? String, requested.count <= 30, params["capabilities"] is JSON,
                      let client = params["clientInfo"] as? JSON, let name = client["name"] as? String, !name.isEmpty, name.count <= 200,
                      let clientVersion = client["version"] as? String, !clientVersion.isEmpty, clientVersion.count <= 100 else { return error(-32602,"Initialize requires a protocolVersion, capabilities object and clientInfo name/version, exactly once",id:id) }
                negotiated = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions.last!
                return reply(["protocolVersion":negotiated!,"capabilities":["tools":[:]],"serverInfo":["name":"Vela","version":serverVersion],"instructions":"Project-scoped local engineering records. Private and stale assets are withheld. Default tools only read; contribute mode creates candidates and local records. No model, workflow execution, activation, apply, remote account or arbitrary filesystem tool is exposed. Candidate records are unreviewed proposals, not accepted instructions."])
            case "ping":
                guard Set(params.keys).isSubset(of:["_meta"]) else { return error(-32602,"Ping takes no tool arguments",id:id) }; return reply([:])
            case "tools/list":
                guard ready else { return error(-32002,"Complete initialize and notifications/initialized first",id:id) }
                guard Set(params.keys).isSubset(of:["cursor","_meta"]), params["cursor"] == nil else { return error(-32602,"The complete bounded catalog has no continuation cursor",id:id) }
                return reply(["tools":catalog(protocolVersion:negotiated!)])
            case "tools/call":
                guard ready else { return error(-32002,"Complete initialize and notifications/initialized first",id:id) }
                guard Set(params.keys).isSubset(of:["name","arguments","_meta"]), let name = params["name"] as? String,
                      params["arguments"] == nil || params["arguments"] is JSON else { return error(-32602,"Malformed MCP tools/call request",id:id) }
                guard let tool = Self.definitions.first(where:{$0.name == name && (contribute || !$0.contribution)}) else { return error(-32602,"Tool is unavailable in this MCP permission mode",id:id) }
                do {
                    let arguments = params["arguments"] as? JSON ?? [:]
                    guard try jsonString(arguments).utf8.count <= 1_048_576 else { throw VelaError("MCP arguments exceed 1 MiB") }
                    try MCPInput.validate(arguments,schema:tool.schema)
                    let output = try dispatchMCPTool(name,arguments:arguments)
                    let encoded = try WorkflowContext.jsonText(output.value)
                    guard encoded.utf8.count <= 524288 else { throw VelaError("MCP result exceeds 512 KiB; request a smaller page") }
                    var result: JSON = ["content":[["type":"text","text":encoded]],"isError":false]
                    if !output.metadata.isEmpty { result["_meta"] = ["ai.vela/pagination":output.metadata] }
                    if ["2025-06-18","2025-11-25"].contains(negotiated!) { result["structuredContent"] = output.value as? JSON ?? ["items":output.value] }
                    return reply(result)
                } catch {
                    let safe = String(Self.sanitizedText(error.localizedDescription).prefix(1200))
                    return reply(["content":[["type":"text","text":safe]],"isError":true])
                }
            default: return error(-32601,"Unknown MCP method",id:id)
            }
        } catch { return self.error(-32602,"MCP protocol parameters are invalid",id:id) }
    }
}
