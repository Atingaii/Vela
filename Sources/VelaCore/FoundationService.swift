import Foundation

public final class FoundationService {
    public let store: VelaStore
    private let sessions: SessionEngine
    private let memory: MemoryService
    private let lock = NSRecursiveLock()
    private let globalHome: URL
    private let quotas: ProviderQuotaService
    private let setup: SetupInventoryService
    private let history: SessionHistoryService

    public init(store: VelaStore, sourceRoots: [String:[URL]]? = nil, globalHome: URL? = nil) {
        self.globalHome = globalHome ?? FileManager.default.homeDirectoryForCurrentUser
        self.store = store; sessions = SessionEngine(store:store,sourceRoots:sourceRoots); memory = MemoryService(store:store)
        quotas = ProviderQuotaService(store:store)
        setup = SetupInventoryService(store:store,home:self.globalHome)
        history = SessionHistoryService(store: store, roots: sessions.sourceRoots)
    }
    public var onChange: (() -> Void)? { get { sessions.onChange } set { sessions.onChange = newValue } }
    public func startWatching() {
        sessions.startWatching()
        DispatchQueue.global(qos:.utility).async { [weak self] in
            guard let self else { return }
            _ = try? self.sessions.refresh()
        }
    }
    public func stopWatching() { sessions.stopWatching() }
    public func handle(_ method: String, _ params: JSON) throws -> Any? {
        if let result = try quotas.handle(method,params) { return result }
        if let result = try history.handle(method,params) { return result }
        lock.lock(); defer { lock.unlock() }
        if let result = try memory.handle(method,params) { return result }
        if let result = try setup.handle(method,params) { return result }
        switch method {
        case "dashboard.get":
            var dashboard: JSON = [:]
            let selectedProject = try checkedProject(params)
            for (key,kind) in [("projects","project"),("sessions","session"),("memories","memory"),("workflows","workflow"),("runs","run"),("suggestions","suggestion"),("approvals","approval"),("evals","eval"),("artifacts","artifact"),("library","library"),("harnesses","harness")] {
                let items = try kind == "session" ? store.sessionSummaries(project:selectedProject) : store.list(kind,project:kind == "project" || kind == "harness" ? nil : selectedProject); dashboard[key] = kind == "session" ? items.map(sessionSummary) : items
            }
            dashboard["harnesses"] = agentList()
            dashboard["usage"] = try usage(params); dashboard["settings"] = try VelaPreferences.read(from: store)
            dashboard["notificationScope"] = selectedProject ?? "*"
            let sessionRows = dashboard["sessions"] as? [JSON] ?? []
            let memories = dashboard["memories"] as? [JSON] ?? []
            let workflows = dashboard["workflows"] as? [JSON] ?? []
            let activeMemories = memories.filter { string($0,"state").lowercased() == "active" }
            let stats: JSON = ["sessionCount": sessionRows.count, "memoryCount": memories.count,
                               "activeMemoryCount": activeMemories.count, "workflowCount": workflows.count]
            dashboard["stats"] = stats
            dashboard["ingestion"] = ["diagnostics":sessions.diagnostics,"historyFullyIndexed":false,"mode":"bounded initial index with incremental FSEvents"]
            return dashboard
        case "projects.list": return try store.list("project")
        case "projects.add":
            let raw = try requireString(params,"path")
            guard raw.hasPrefix("/") || raw.hasPrefix("~/") else { throw VelaError("Project path must be absolute") }
            let path = canonicalProject(raw); var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath:path,isDirectory:&isDirectory),isDirectory.boolValue else { throw VelaError("Project directory does not exist") }
            return try store.put("project",["id":stableHash(path),"title":URL(fileURLWithPath:path).lastPathComponent,"path":path,"project":path,"state":"active"])
        case "projects.remove":
            let id = try requireString(params,"id"); guard try store.get("project",id) != nil else { throw VelaError("Project not found") }
            try store.remove("project",id); return ["removed":true,"filesDeleted":false]
        case "agents.list": return agentList()
        case "sessions.refresh": return try sessions.refresh()
        case "sessions.list":
            let query = string(params,"query").lowercased()
            return try store.sessionSummaries(project:checkedProject(params),query:query).map(sessionSummary)
        case "sessions.get":
            guard var session = try store.get("session",try requireString(params,"id")) else { throw VelaError("Session not found") }
            session.removeValue(forKey:"usageByMessage"); return inferredSession(session)
        case "usage.get": return try usage(params)
        default: return nil
        }
    }
    private func sessionSummary(_ session: JSON) -> JSON {
        var result = inferredSession(session); result.removeValue(forKey:"messages"); result.removeValue(forKey:"content"); result.removeValue(forKey:"usageByMessage"); return result
    }
    private func inferredSession(_ item: JSON) -> JSON {
        var item = item
        if string(item,"state") == "Running" {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            let timestamp = formatter.date(from:string(item,"lastActivity")) ?? ISO8601DateFormatter().date(from:string(item,"lastActivity"))
            let age = timestamp.map { Date().timeIntervalSince($0) } ?? .infinity
            if age > 6 * 3600 { item["state"] = "Unknown" }
            else if age > 45 { item["state"] = "Idle" }
            item["statusInferred"] = true
        }
        return item
    }
    private func agentList() -> [JSON] {
        let home = globalHome
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator:":").map(String.init) + ["/opt/homebrew/bin","/usr/local/bin",home.appendingPathComponent(".local/bin").path]
        return ["claude","codex","cursor","pi","omp"].map { provider in
            let executable = paths.map { URL(fileURLWithPath:$0).appendingPathComponent(provider).path }.first { FileManager.default.isExecutableFile(atPath:$0) }
            let sources = sessions.sourceRoots[provider] ?? []
            let title = provider == "claude" ? "Claude Code" : provider == "omp" ? "OMP" : provider.capitalized
            let capabilities = provider == "cursor" ? ["JSON/JSONL exports","known read-only SQLite composer records"] : (provider == "pi" || provider == "omp") ? ["versioned JSONL history","persisted branch ancestry","source-linked tool events","observed token usage"] : ["bounded JSONL history","incremental log ingestion","observed token usage"]
            return ["id":provider,"provider":provider,"title":title,"installed":executable != nil || sources.contains { FileManager.default.fileExists(atPath:$0.path) },"executable":executable as Any? ?? NSNull(),"sourceDirectories":sources.map(\.path),"quotaAvailable":false,"quotaReadSupported":provider == "codex","liveStatusAvailable":false,"capabilities":capabilities] as JSON
        }
    }
    private func usage(_ params: JSON) throws -> JSON {
        let all = try store.sessionSummaries(project:checkedProject(params),limit:10000)
        func aggregate(_ items: [JSON]) -> JSON {
            var inputs: [Int] = [], outputs: [Int] = [], observedInputs: [Int] = [], observedOutputs: [Int] = []
            var observedSessions = 0, completeSessions = 0
            for item in items {
                let input = usageTokenCount(item["tokenInput"]), output = usageTokenCount(item["tokenOutput"])
                let observedInput = usageTokenCount(item["observedTokenInput"] ?? item["tokenInput"])
                let observedOutput = usageTokenCount(item["observedTokenOutput"] ?? item["tokenOutput"])
                if let input { inputs.append(input) }; if let output { outputs.append(output) }
                if let observedInput { observedInputs.append(observedInput) }; if let observedOutput { observedOutputs.append(observedOutput) }
                if observedInput != nil || observedOutput != nil { observedSessions += 1 }
                if let input, let output, usageTokenSum([input,output]) != nil, item["usageAvailable"] as? Bool != false { completeSessions += 1 }
            }
            let observedInput = usageTokenSum(observedInputs), observedOutput = usageTokenSum(observedOutputs)
            let observedTotal = usageTokenSum(observedInputs + observedOutputs)
            let input = inputs.count == items.count ? usageTokenSum(inputs) : nil
            let output = outputs.count == items.count ? usageTokenSum(outputs) : nil
            let total = completeSessions == items.count ? usageTokenSum(inputs + outputs) : nil
            let overflow = items.contains { string($0,"usageStatus") == "overflow" } ||
                (!observedInputs.isEmpty && observedInput == nil) || (!observedOutputs.isEmpty && observedOutput == nil) ||
                ((!observedInputs.isEmpty || !observedOutputs.isEmpty) && observedTotal == nil)
            let available = total != nil && !overflow
            return ["inputTokens":input as Any? ?? NSNull(),"outputTokens":output as Any? ?? NSNull(),"totalTokens":(available ? total : nil) as Any? ?? NSNull(),
                    "observedInputTokens":observedInput as Any? ?? NSNull(),"observedOutputTokens":observedOutput as Any? ?? NSNull(),
                    "observedTotalTokens":(overflow ? nil : observedTotal) as Any? ?? NSNull(),
                    "usageAvailable":available,"coverage":overflow ? "overflow" : available ? "complete" : observedSessions > 0 ? "partial" : "unavailable",
                    "sessionCount":items.count,"observedSessionCount":observedSessions,"missingUsageSessionCount":items.count - completeSessions,"quotaAvailable":false]
        }
        let providers = Dictionary(grouping:all,by:{ string($0,"provider","unknown") })
        let days = Dictionary(grouping:all,by:{ String(string($0,"startedAt",string($0,"createdAt")).prefix(10)) })
        var result = aggregate(all)
        result["providers"] = providers.keys.sorted().map { key -> JSON in var bucket = aggregate(providers[key]!); bucket["provider"] = key; return bucket }
        result["daily"] = days.keys.sorted().map { key -> JSON in
            var day = aggregate(days[key]!); day["date"] = key; day["tokens"] = day["totalTokens"]; day["observedTokens"] = day["observedTotalTokens"]; return day
        }
        result["coverageDescription"] = "observed indexed logs only; completeness applies to selected indexed sessions, not full provider history; daily totals attributed to session start date"
        result["costAvailable"] = false; result["historyFullyIndexed"] = false
        return result
    }
}
