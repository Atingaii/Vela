import Foundation
import Darwin
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

/// RPC normally has no resident lifecycle. EOF first closes admission and drains
/// requests already accepted by the pipe. SIGINT/SIGTERM instead close the runtime
/// gate, stop only Vela-owned child process groups, and allow the in-flight request
/// to persist its own terminal record. A bounded fallback never claims forced
/// cleanup was graceful.
final class RPCShutdown {
    private enum State: Equatable { case accepting, draining, stopping, finished }
    private let lock = NSLock()
    private var state: State = .accepting
    private let pending: DispatchGroup
    private let timer: DispatchSourceTimer?
    private let stopWatching: () -> Void
    init(pending: DispatchGroup, timer: DispatchSourceTimer?, stopWatching: @escaping () -> Void) {
        self.pending = pending; self.timer = timer; self.stopWatching = stopWatching
    }
    /// Admission and pending.enter share the same lock as shutdown state. A signal
    /// therefore cannot make the wait group look drained while a request is racing
    /// toward a queue.
    func admit() -> Bool {
        lock.lock()
        guard state == .accepting else { lock.unlock(); return false }
        pending.enter()
        lock.unlock()
        return true
    }
    /// EOF preserves legacy pipe behavior: it drains requests that were already
    /// accepted, without cancelling an approved command simply because its writer
    /// closed stdin after one JSONL frame.
    func drainAfterEOF() {
        lock.lock()
        guard state == .accepting else { lock.unlock(); return }
        state = .draining
        lock.unlock()
        DispatchQueue.global(qos:.userInitiated).async {
            self.pending.wait(); self.finish(expected:.draining,code:0)
        }
    }
    /// Signals differ from EOF: stop Vela-owned descendants and let the active
    /// request persist an interrupted ledger state before the helper exits.
    func interrupt() {
        lock.lock()
        guard state != .stopping && state != .finished else { lock.unlock(); return }
        state = .stopping
        lock.unlock()
        VelaRuntimeShutdown.request()
        DispatchQueue.global(qos:.userInitiated).async {
            self.pending.wait(); self.finish(expected:.stopping,code:0)
        }
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+5) {
            self.lock.lock(); let pending = self.state == .stopping; self.lock.unlock()
            guard pending else { return }
            VelaRuntimeShutdown.forceStopOwnedProcesses()
            // The fallback only stops known process groups. The final state may still
            // be unavailable if the helper itself cannot persist after this bound.
            DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+1) { self.finish(expected:.stopping,code:1) }
        }
    }
    private func finish(expected: State, code: Int32) {
        lock.lock()
        guard state == expected else { lock.unlock(); return }
        state = .finished
        lock.unlock()
        timer?.cancel(); stopWatching(); exit(code)
    }
}

final class Router {
    static let controlMethods: Set<String> = ["loops.get","loops.list","loops.cancel","ask.get","ask.list","ask.cancel","ask.citations",
        "replay.get","replay.list","replay.cancel","replay.fixtures.get","replay.fixtures.list","replay.fixtures.forget","replay.fixtures.prune"]
    let store: VelaStore
    let foundation: FoundationService
    let automation: AutomationService
    private let controlAutomation: AutomationService
    let context: ContextService
    init() throws {
        store = try VelaStore(root: root)
        if let fixtureRoot = ProcessInfo.processInfo.environment["VELA_SESSION_ROOT"] {
            let fixtures = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
            foundation = FoundationService(store: store, sourceRoots: ["claude":[fixtures.appendingPathComponent("claude")],"codex":[fixtures.appendingPathComponent("codex")],"cursor":[fixtures.appendingPathComponent("cursor")],"pi":[fixtures.appendingPathComponent("pi")],"omp":[fixtures.appendingPathComponent("omp")]], globalHome: fixtures)
        } else if ProcessInfo.processInfo.environment["VELA_DISABLE_DISCOVERY"] == "1" {
            foundation = FoundationService(store: store, sourceRoots: [:], globalHome: store.root)
        } else {
            foundation = FoundationService(store: store)
        }
        automation = AutomationService(store: store)
        // A separate instance lock keeps control reads/cancellation responsive
        // while the execution service awaits a provider. Recovery runs once in
        // the execution service at startup, never as a side effect of polling.
        controlAutomation = AutomationService(store:store,recoverInterruptedFiles:false)
        context = ContextService(store: store)
    }
    func call(_ method: String, _ params: JSON) throws -> Any {
        guard method.count < 100, params.count < 80 else { throw VelaError("Invalid request") }
        if Self.controlMethods.contains(method) {
            guard let result = try controlAutomation.handle(method,params) else { throw VelaError("Unsupported control method") }
            return result
        }
        switch method {
        case "reuse.preview":
            var input = params
            input["helperExecutable"] = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.path
            return try automation.handle(method,input) ?? [:]
        case "schedules.list": return try automation.scheduleStatus(params)
        case "schedules.resolve": return try automation.resolveScheduledDispatch(params)
        case "daemon.status", "daemon.plan":
            let daemon = try VelaDaemonService(store: store, executable: CommandLine.arguments[0])
            return try method == "daemon.status" ? daemon.status() : daemon.plan()
        case "daemon.install", "daemon.start", "daemon.stop", "daemon.uninstall":
            guard params.isEmpty else { throw VelaError("Daemon lifecycle operations take no arbitrary arguments") }
            let daemon = try VelaDaemonService(store: store, executable: CommandLine.arguments[0])
            switch method {
            case "daemon.install": return try daemon.install()
            case "daemon.start": return try daemon.start()
            case "daemon.stop": return try daemon.stop()
            default: return try daemon.uninstall()
            }
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

if arguments.isEmpty || arguments.contains("--help") || arguments.first == "help" {
    print("""
    Vela \(version) — The engineering layer for coding agents

    vela doctor [--home PATH]                   检查本地工作台
    vela rpc [--home PATH] [--no-schedule]      启动 JSONL 原生桥接
    vela mcp [--contribute] [--home PATH]        启动 stdio MCP（默认只读）
    vela call METHOD [JSON] [--home PATH]        调用明确的本地 API
    vela call METHOD --params-stdin             从一行 JSON 标准输入读取参数（避免密钥进入 argv）
    vela search QUERY [--project PATH]          搜索本地证据
    vela recall QUERY --project PATH            召回 1000 tokens 内的有效 Memory
    vela sessions                              查看已导入会话
    vela refresh                               增量更新会话
    vela backup create --destination PATH       创建完整本地 Store bundle（仅 CLI）
    vela backup restore --bundle PATH --target PATH  恢复到新的空 Store（仅 CLI）
    vela hook --project PATH [--home PATH]      Codex SessionStart 上下文 Hook
    vela daemon run [--home PATH]              独立运行观察与调度（不依赖窗口或 stdin）
    vela daemon plan|status [--home PATH]       查看用户级后台服务配置与运行证据
    vela daemon install|start|stop|uninstall    显式管理当前用户的 launchd 服务
    vela call schedules.list [JSON]            查看调度、补跑和待核对事件

    所有资产保存在 ~/.vela，可用 VELA_HOME 或 --home 更改。
    第一次连接项目：vela call projects.add '{"path":"/path/to/project"}'
    """)
    exit(0)
}
if arguments.first == "--version" { print(version); exit(0) }

do {
    let command = arguments[0]
    // Backup must not initialize AutomationService: startup recovery can write
    // project files. Restore must also avoid opening the caller's default Store.
    if command == "backup" {
        guard arguments.count >= 2 else { fail("Backup requires create or restore") }
        switch arguments[1] {
        case "create":
            guard let destination = option("--destination") else { fail("Backup create requires --destination PATH") }
            let store = try VelaStore(root:root)
            emit(try StoreBackupService(store:store).create(destination:URL(fileURLWithPath:destination)))
        case "restore":
            guard let bundle = option("--bundle"), let target = option("--target") else { fail("Backup restore requires --bundle PATH --target PATH") }
            emit(try StoreBackupService.restore(bundle:URL(fileURLWithPath:bundle),target:URL(fileURLWithPath:target)))
        default: fail("Backup requires create or restore")
        }
        exit(0)
    }
    let router = try Router()
    if command == "daemon" {
        guard arguments.count > 1 else { fail("Daemon requires run, plan, status, install, start, stop or uninstall") }
        let daemon = try VelaDaemonService(store: router.store, executable: CommandLine.arguments[0])
        switch arguments[1] {
        case "plan": emit(try daemon.plan())
        case "status": emit(try daemon.status())
        case "install": emit(try daemon.install())
        case "start": emit(try daemon.start())
        case "stop": emit(try daemon.stop())
        case "uninstall": emit(try daemon.uninstall())
        case "run":
            guard let lease = try VelaRuntimeLease.acquire(root: router.store.root, name: "daemon") else { fail("A daemon already owns this store") }
            let instance = UUID().uuidString.lowercased()
            let queue = DispatchQueue(label: "ai.vela.daemon", qos: .utility)
            let control = DispatchQueue(label: "ai.vela.daemon.control", qos: .userInitiated)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            var runtime: JSON = ["id": "daemon", "state": "running", "pid": ProcessInfo.processInfo.processIdentifier, "instance": instance, "startedAt": isoNow()]
            _ = try router.store.put("runtime", runtime)
            let watch = !arguments.contains("--no-watch")
            if watch { router.foundation.startWatching() }
            timer.schedule(deadline: .now(), repeating: 30, leeway: .seconds(1))
            timer.setEventHandler {
                do {
                    try router.automation.tick(startupEvent: instance)
                    runtime["lastTickAt"] = isoNow(); runtime.removeValue(forKey: "error")
                } catch { runtime["error"] = error.localizedDescription }
                _ = try? router.store.put("runtime", runtime)
            }
            signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: control)
            let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: control)
            var stopping = false // Only the serial control queue accesses this flag.
            let stop = {
                guard !stopping else { return }
                stopping = true
                timer.cancel()
                VelaRuntimeShutdown.request()
                // This callback follows the active tick. Its durable event/run
                // recovery writes finish before a clean stop is recorded.
                queue.async {
                    if watch { router.foundation.stopWatching() }
                    guard VelaRuntimeShutdown.activeProcessCount == 0 else { return }
                    runtime["state"] = "stopped"; runtime["stoppedAt"] = isoNow()
                    do { _ = try router.store.put("runtime", runtime) }
                    catch { fputs("Vela daemon could not persist its clean shutdown: \(error.localizedDescription)\n",stderr); exit(1) }
                    lease.release(); exit(0)
                }
                control.asyncAfter(deadline: .now() + 5) {
                    // Never mislabel an unfinished tick as stopped, or reuse a
                    // historical PID. Only this process's registered groups die.
                    VelaRuntimeShutdown.forceStopOwnedProcesses()
                    fputs("Vela daemon shutdown exceeded five seconds; interrupted claims require review.\n",stderr)
                    exit(1)
                }
            }
            termination.setEventHandler(handler: stop); interruption.setEventHandler(handler: stop)
            termination.resume(); interruption.resume(); timer.resume()
            emit(["state": "running", "instance": instance, "pid": ProcessInfo.processInfo.processIdentifier, "home": router.store.root.path])
            dispatchMain()
        default: fail("Unknown daemon operation")
        }
    } else if command == "hook" {
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
        let mcpTools = MCPTools(store: router.store, contribute: arguments.contains("--contribute"), serverVersion: version, coreCall: { try router.call($0, $1) })
        let watchEnabled = !isMCP && !arguments.contains("--no-watch")
        if watchEnabled { router.foundation.onChange = { emit(["event":"data.changed"]) } }
        if watchEnabled { router.foundation.startWatching() }
        let foundationQueue = DispatchQueue(label:"ai.vela.foundation",qos:.userInitiated)
        let automationQueue = DispatchQueue(label:"ai.vela.automation",qos:.utility)
        let providerQueue = DispatchQueue(label:"ai.vela.provider-queries",qos:.utility)
        let historyQueue = DispatchQueue(label:"ai.vela.history-batches",qos:.utility)
        let controlQueue = DispatchQueue(label:"ai.vela.controls",qos:.userInitiated)
        let pending = DispatchGroup()
        let queueBound = DispatchSemaphore(value:32)
        let controlBound = DispatchSemaphore(value:8)
        let timer: DispatchSourceTimer? = isMCP || arguments.contains("--no-schedule") ? nil : DispatchSource.makeTimerSource(queue:automationQueue)
        if let timer {
            timer.schedule(deadline:.now()+10,repeating:30)
            timer.setEventHandler { do { if try !VelaRuntimeLease.isHeld(root: router.store.root, name: "daemon") { try router.automation.tick() } } catch { fputs("Vela scheduler: \(error.localizedDescription)\n",stderr) } }
            timer.resume()
        }
        let shutdown = RPCShutdown(pending:pending,timer:timer,stopWatching:{ if watchEnabled { router.foundation.stopWatching() } })
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal:SIGTERM,queue:.global(qos:.userInitiated))
        let interruption = DispatchSource.makeSignalSource(signal:SIGINT,queue:.global(qos:.userInitiated))
        termination.setEventHandler { shutdown.interrupt() }; interruption.setEventHandler { shutdown.interrupt() }
        termination.resume(); interruption.resume()
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
            guard let method = request["method"] as? String else {
                if isMCP { emit(["jsonrpc":"2.0","id":NSNull(),"error":["code":-32600,"message":"Invalid request: method must be a string"]]) }
                else { emit(["id":request["id"] ?? NSNull(),"error":["message":"Missing method"]]) }
                continue
            }
            let isControl = !isMCP && Router.controlMethods.contains(method)
            let capacity = isControl ? controlBound : queueBound
            // Do not block stdin while admitting work: doing so would also
            // prevent a later cancellation frame from reaching its own queue.
            guard capacity.wait(timeout:.now()) == .success else {
                var response: JSON = ["id":request["id"] ?? NSNull(),"error":["code":-32001,"message":"Helper request queue is full; inspect status before retrying a mutation"]]
                if isMCP { response["jsonrpc"] = "2.0" }
                if !isMCP || request["id"] != nil { emit(response) }
                continue
            }
            guard shutdown.admit() else {
                capacity.signal()
                var response: JSON = ["id":request["id"] ?? NSNull(),"error":["code":-32001,"message":"Helper is stopping; the request was not accepted"]]
                if isMCP { response["jsonrpc"] = "2.0" }
                if !isMCP || request["id"] != nil { emit(response) }
                continue
            }
            let automationMethods = ["workflows.","runs.","improve.","lab.","reuse.","daemon.","schedules.","watches.","approvals.","inbox.","outputs.","connectors.","evidence.","ask.","loops.","replay."]
            let queue = isControl ? controlQueue : !isMCP && method == "history.advance" ? historyQueue : !isMCP && method == "usage.quota.read" ? providerQueue : (!isMCP && automationMethods.contains(where:method.hasPrefix) ? automationQueue : foundationQueue)
            queue.async {
                defer { pending.leave(); capacity.signal() }
                do {
                    if isMCP {
                        if let response = mcpTools.handle(request: request) { emit(response) }
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
        shutdown.drainAfterEOF()
        dispatchMain()
    } else {
        var method = command, params: JSON = [:]
        switch command {
        case "call":
            guard arguments.count > 1 else { fail("Missing method") }
            method = arguments[1]
            if arguments.contains("--params-stdin") {
                guard arguments.count <= 2 || arguments[2].hasPrefix("--") else { fail("Use either an argument object or --params-stdin, not both") }
                let reader = BoundedInputReader(maximumBytes:1_048_576)
                guard let frame = try reader.next(), case .data(let data) = frame,
                      let json = try JSONSerialization.jsonObject(with:data) as? JSON else { fail("Expected one bounded JSON object on stdin") }
                params = json
            } else if arguments.count > 2, !arguments[2].hasPrefix("--") {
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
