import Foundation
import VelaCore

let version = "0.1.0-preview.2"
let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
    return arguments[i + 1]
}
let root = URL(fileURLWithPath: option("--home") ?? ProcessInfo.processInfo.environment["VELA_HOME"] ?? NSHomeDirectory() + "/.vela", isDirectory: true)
let outputLock = NSLock()
func emit(_ object: Any) {
    outputLock.lock(); defer { outputLock.unlock() }
    do { print(try jsonString(object)); fflush(stdout) }
    catch { fputs("Vela: response serialization failed\n", stderr) }
}
func fail(_ message: String) -> Never { fputs("Vela: \(message)\n", stderr); exit(1) }

final class Router {
    let store: VelaStore
    let foundation: FoundationService
    let automation: AutomationService
    let context: ContextService
    init() throws {
        store = try VelaStore(root: root)
        if let fixtureRoot = ProcessInfo.processInfo.environment["VELA_SESSION_ROOT"] {
            let fixtures = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
            foundation = FoundationService(store: store, sourceRoots: ["claude":[fixtures.appendingPathComponent("claude")],"codex":[fixtures.appendingPathComponent("codex")],"cursor":[fixtures.appendingPathComponent("cursor")]], globalHome: fixtures)
        } else if ProcessInfo.processInfo.environment["VELA_DISABLE_DISCOVERY"] == "1" {
            foundation = FoundationService(store: store, sourceRoots: [:], globalHome: store.root)
        } else {
            foundation = FoundationService(store: store)
        }
        automation = AutomationService(store: store)
        context = ContextService(store: store)
    }
    func call(_ method: String, _ params: JSON) throws -> Any {
        guard method.count < 100, params.count < 80 else { throw VelaError("Invalid request") }
        switch method {
        case "reuse.preview":
            var input = params
            input["helperExecutable"] = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.path
            return try automation.handle(method,input) ?? [:]
        case "system.version": return ["version": version, "platform": "macOS", "home": store.root.path]
        case "settings.get":
            return try VelaPreferences.read(from: store)
        case "settings.save":
            return try VelaPreferences.save(params, in: store)
        case "ask":
            let query = params["query"] as? String ?? ""
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VelaError("请输入要查找的工程问题") }
            let results = try store.search(query, project: params["project"] as? String, includePrivate: false, limit: 12)
            return ["query":query, "items":results, "mode":"local-retrieval", "message":results.isEmpty ? "没有找到相关证据。尝试项目名、关键字或文件名。" : "以下是本地证据匹配；未调用外部模型。"]
        case "doctor":
            let harnesses = try foundation.handle("agents.list", [:]) ?? []
            return ["version":version,"database":"ok","store":store.root.path,"privacy":"local-first","telemetry":false,"harnesses":harnesses]
        default:
            if let result = try context.handle(method, params) { return result }
            if let result = try foundation.handle(method, params) { return result }
            if let result = try automation.handle(method, params) { return result }
            throw VelaError("不支持的方法：\(method)")
        }
    }
}

let mcpRead: [(String, String, String)] = [
    ("vela_search", "Search local engineering evidence; private library is always excluded.", "search"),
    ("vela_recall", "Recall active scoped memories within a token budget. Requires project and query.", "recall"),
    ("vela_memory_list", "List nonprivate project memories.", "memory.list"),
    ("vela_setup_list", "Read sanitized setup artifacts.", "setup.list"),
    ("vela_workflows_list", "Read workflow definitions without executing them.", "workflows.list"),
    ("vela_evals_list", "Read recorded evaluation evidence.", "lab.list"),
    ("vela_checkpoints_list", "Read provider-neutral checkpoints.", "checkpoint.list")
]
let mcpContribute: [(String, String, String)] = [
    ("vela_memory_contribute", "Create a candidate memory; cannot activate or replace existing memory.", "memory.save"),
    ("vela_checkpoint_save", "Save a new checkpoint in Vela's store.", "checkpoint.save"),
    ("vela_signal_record", "Contribute evidence tied to an existing project session.", "signals.record"),
    ("vela_suggestion_draft", "Create a suggestion draft without file operations or promotion.", "suggestions.draft")
]

func handleMCP(_ request: JSON, router: Router, contribute: Bool) throws -> Any? {
    guard let method = request["method"] as? String else { throw VelaError("Missing JSON-RPC method") }
    let params = request["params"] as? JSON ?? [:]
    let available = mcpRead + (contribute ? mcpContribute : [])
    switch method {
    case "initialize": return ["protocolVersion":"2024-11-05","capabilities":["tools":[:]],"serverInfo":["name":"Vela","version":version],"instructions":"Local engineering context. Scope all requests by project. Private library is inaccessible. Execution and applying changes are never exposed."] as JSON
    case "notifications/initialized", "notifications/cancelled": return nil
    case "ping": return JSON()
    case "tools/list":
        return ["tools":available.map { tool -> JSON in
            let properties: JSON = ["query":["type":"string"],"project":["type":"string"],"budget":["type":"integer","minimum":0,"maximum":4000],"title":["type":"string"],"content":["type":"string"],"type":["type":"string"],"scope":["type":"string"],"sourceSession":["type":"string"],"sourceMessage":["type":"string"],"goal":["type":"string"],"completed":["type":"string"],"pending":["type":"string"],"nextActions":["type":"string"],"branch":["type":"string"],"worktree":["type":"string"],"task":["type":"string"],"sessionId":["type":"string"],"files":["type":"array","items":["type":"string"]],"symbols":["type":"array","items":["type":"string"]]]
            return ["name":tool.0,"description":tool.1,"inputSchema":["type":"object","properties":properties,"required":["project"],"additionalProperties":false],"annotations":["readOnlyHint": mcpRead.contains(where: { $0.0 == tool.0 }),"destructiveHint":false,"openWorldHint":false]]
        }]
    case "tools/call":
        guard let name = params["name"] as? String, let tool = available.first(where: { $0.0 == name }) else { throw VelaError("Tool unavailable in this MCP permission mode") }
        var input = params["arguments"] as? JSON ?? [:]
        guard let rawProject = input["project"] as? String, rawProject.hasPrefix("/") else { throw VelaError("MCP tools require an absolute registered project path") }
        let project = canonicalProject(rawProject)
        guard try router.store.list("project").contains(where: { canonicalProject($0["path"] as? String ?? "") == project }) else { throw VelaError("Register this project in Vela before using MCP") }
        input["project"] = project
        input.removeValue(forKey:"includePrivate"); input.removeValue(forKey:"id")
        input.removeValue(forKey:"path"); input.removeValue(forKey:"supersedes")
        if name == "vela_memory_contribute" { input["state"] = "Candidate" }
        if name == "vela_search" { input["includePrivate"] = false }
        var result = try router.call(tool.2, input)
        if name == "vela_memory_list", let memories = result as? [JSON] { result = memories.filter { $0["private"] as? Bool != true } }
        return ["content":[["type":"text","text":try jsonString(result)]],"isError":false]
    default: throw VelaError("Unknown MCP method")
    }
}

if arguments.isEmpty || arguments.contains("--help") || arguments.first == "help" {
    print("""
    Vela \(version) — The engineering layer for coding agents

    vela doctor [--home PATH]                   检查本地工作台
    vela rpc [--home PATH]                      启动 JSONL 原生桥接
    vela mcp [--contribute] [--home PATH]        启动 stdio MCP（默认只读）
    vela call METHOD [JSON] [--home PATH]        调用明确的本地 API
    vela search QUERY [--project PATH]          搜索本地证据
    vela recall QUERY --project PATH            召回 1000 tokens 内的有效 Memory
    vela sessions                              查看已导入会话
    vela refresh                               增量更新会话
    vela hook --project PATH [--home PATH]      Codex SessionStart 上下文 Hook

    所有资产保存在 ~/.vela，可用 VELA_HOME 或 --home 更改。
    第一次连接项目：vela call projects.add '{"path":"/path/to/project"}'
    """)
    exit(0)
}
if arguments.first == "--version" { print(version); exit(0) }

do {
    let router = try Router()
    let command = arguments[0]
    if command == "hook" {
        // Paired Lab runs freeze their context explicitly and must not acquire live Vela memory.
        if ProcessInfo.processInfo.environment["VELA_INTERNAL_RUN"] == "1" { exit(0) }
        guard let selected = option("--project") else { fail("Hook requires --project") }
        let reader = BoundedInputReader(maximumBytes:64_000)
        guard let frame = try reader.next(), case .data(let data) = frame,
              let event = try JSONSerialization.jsonObject(with:data) as? JSON else { fail("Hook requires one bounded JSON event") }
        let result = try router.call("reuse.context",["project":selected,"event":event])
        if let object = result as? JSON, !object.isEmpty { emit(object) }
    } else if command == "rpc" || command == "mcp" {
        let isMCP = command == "mcp"
        let watchEnabled = !isMCP && !arguments.contains("--no-watch")
        if watchEnabled { router.foundation.onChange = { emit(["event":"data.changed"]) } }
        if watchEnabled { router.foundation.startWatching() }
        let foundationQueue = DispatchQueue(label:"ai.vela.foundation",qos:.userInitiated)
        let automationQueue = DispatchQueue(label:"ai.vela.automation",qos:.utility)
        let pending = DispatchGroup()
        let queueBound = DispatchSemaphore(value:32)
        let timer: DispatchSourceTimer? = isMCP ? nil : DispatchSource.makeTimerSource(queue:automationQueue)
        if let timer {
            timer.schedule(deadline:.now()+10,repeating:30)
            timer.setEventHandler { do { try router.automation.tick() } catch { fputs("Vela scheduler: \(error.localizedDescription)\n",stderr) } }
            timer.resume()
        }
        let inputReader = BoundedInputReader()
        while let frame = try inputReader.next() {
            let data: Data
            switch frame {
            case .data(let payload): data = payload
            case .tooLong:
                if isMCP { emit(["jsonrpc":"2.0","id":NSNull(),"error":["code":-32600,"message":"Request exceeds 2 MB limit"]]) }
                else { emit(["error":["message":"Request exceeds 2 MB limit"]]) }
                continue
            }
            guard let request = (try? JSONSerialization.jsonObject(with:data)) as? JSON else {
                if isMCP { emit(["jsonrpc":"2.0","id":NSNull(),"error":["code":-32700,"message":"Parse error"]]) }
                else { emit(["error":["message":"Invalid JSON request"]]) }
                continue
            }
            guard let method = request["method"] as? String else { emit(["id":request["id"] ?? NSNull(),"error":["message":"Missing method"]]); continue }
            queueBound.wait(); pending.enter()
            let automationMethods = ["workflows.","runs.","improve.","lab.","reuse.","approvals.","inbox.","evidence."]
            let queue = !isMCP && automationMethods.contains(where:method.hasPrefix) ? automationQueue : foundationQueue
            queue.async {
                defer { pending.leave(); queueBound.signal() }
                do {
                    if isMCP {
                        if let result = try handleMCP(request, router:router, contribute:arguments.contains("--contribute")), request["id"] != nil {
                            emit(["jsonrpc":"2.0","id":request["id"]!,"result":result])
                        }
                    } else {
                        let result = try router.call(method,request["params"] as? JSON ?? [:])
                        emit(["id":request["id"] ?? NSNull(),"result":result])
                    }
                } catch {
                    var response: JSON = ["id":request["id"] ?? NSNull(),"error":["message":error.localizedDescription,"code":-32602]]
                    if isMCP { response["jsonrpc"] = "2.0" }
                    if !isMCP || request["id"] != nil { emit(response) }
                }
            }
        }
        pending.wait()
        timer?.cancel()
        if watchEnabled { router.foundation.stopWatching() }
    } else {
        var method = command, params: JSON = [:]
        switch command {
        case "call":
            guard arguments.count > 1 else { fail("Missing method") }
            method = arguments[1]
            if arguments.count > 2, !arguments[2].hasPrefix("--") {
                guard let data = arguments[2].data(using:.utf8), let json = try JSONSerialization.jsonObject(with:data) as? JSON else { fail("Expected JSON object") }
                params = json
            }
        case "sessions": method = "sessions.list"
        case "refresh": method = "sessions.refresh"
        case "search", "recall":
            guard arguments.count > 1 else { fail("Missing search query") }
            params["query"] = arguments[1]
            if let project = option("--project") { params["project"] = project }
            if command == "recall" { params["budget"] = 1000 }
        case "doctor": break
        default: fail("Unknown command. Run vela --help")
        }
        emit(try router.call(method,params))
    }
} catch { fail(error.localizedDescription) }
