import Foundation

public final class FoundationService {
    public let store: VelaStore
    private let sessions: SessionEngine
    private let memory: MemoryService
    private let lock = NSRecursiveLock()
    private let globalHome: URL

    public init(store: VelaStore, sourceRoots: [String:[URL]]? = nil, globalHome: URL? = nil) {
        self.globalHome = globalHome ?? FileManager.default.homeDirectoryForCurrentUser
        self.store = store; sessions = SessionEngine(store:store,sourceRoots:sourceRoots); memory = MemoryService(store:store)
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
        lock.lock(); defer { lock.unlock() }
        if let result = try memory.handle(method,params) { return result }
        switch method {
        case "dashboard.get":
            var dashboard: JSON = [:]
            let selectedProject = try checkedProject(params)
            for (key,kind) in [("projects","project"),("sessions","session"),("memories","memory"),("workflows","workflow"),("runs","run"),("suggestions","suggestion"),("approvals","approval"),("evals","eval"),("artifacts","artifact"),("library","library"),("harnesses","harness")] {
                let items = try kind == "session" ? store.sessionSummaries(project:selectedProject) : store.list(kind,project:kind == "project" || kind == "harness" ? nil : selectedProject); dashboard[key] = kind == "session" ? items.map(sessionSummary) : items
            }
            dashboard["harnesses"] = agentList()
            dashboard["usage"] = try usage(params); dashboard["settings"] = try store.get("settings","preferences") ?? ["telemetry":false]
            dashboard["stats"] = ["sessionCount":(dashboard["sessions"] as? [JSON])?.count ?? 0,"memoryCount":(dashboard["memories"] as? [JSON])?.count ?? 0,"activeMemoryCount":(dashboard["memories"] as? [JSON])?.filter { string($0,"state").lowercased() == "active" }.count ?? 0,"workflowCount":(dashboard["workflows"] as? [JSON])?.count ?? 0]
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
        case "setup.list": return try setupList(params)
        case "setup.scan": return try scanSetup(params)
        case "setup.audit":
            _ = try scanSetup(params)
            let items = try setupList(params)
            return ["artifacts":items,"diagnostics":items.flatMap { $0["diagnostics"] as? [JSON] ?? [] },"auditedAt":isoNow(),"method":"deterministic content, syntax, duplication and context-size checks"] as JSON
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
        return ["claude","codex","cursor"].map { provider in
            let executable = paths.map { URL(fileURLWithPath:$0).appendingPathComponent(provider).path }.first { FileManager.default.isExecutableFile(atPath:$0) }
            let sources = sessions.sourceRoots[provider] ?? []
            return ["id":provider,"provider":provider,"title":provider == "claude" ? "Claude Code" : provider.capitalized,"installed":executable != nil || sources.contains { FileManager.default.fileExists(atPath:$0.path) },"executable":executable as Any? ?? NSNull(),"sourceDirectories":sources.map(\.path),"quotaAvailable":false,"liveStatusAvailable":false,"capabilities":provider == "cursor" ? ["JSON/JSONL exports","known read-only SQLite composer records"] : ["bounded JSONL history","incremental log ingestion","observed token usage"]] as JSON
        }
    }
    private func usage(_ params: JSON) throws -> JSON {
        let all = try store.sessionSummaries(project:checkedProject(params),limit:10000)
        var providers: [String:JSON] = [:]; var daily: [String:Int] = [:]
        for item in all {
            let provider = string(item,"provider","unknown"); var bucket = providers[provider] ?? ["provider":provider,"inputTokens":0,"outputTokens":0,"totalTokens":0,"sessionCount":0,"quotaAvailable":false]
            let input = intValue(item,"tokenInput"), output = intValue(item,"tokenOutput")
            bucket["inputTokens"] = intValue(bucket,"inputTokens") + input; bucket["outputTokens"] = intValue(bucket,"outputTokens") + output
            bucket["totalTokens"] = intValue(bucket,"totalTokens") + input + output; bucket["sessionCount"] = intValue(bucket,"sessionCount") + 1
            providers[provider] = bucket
            let date = String(string(item,"startedAt",string(item,"createdAt")).prefix(10)); daily[date,default:0] += input + output
        }
        return ["providers":providers.keys.sorted().compactMap { providers[$0] },"daily":daily.keys.sorted().map { ["date":$0,"tokens":daily[$0]!] as JSON },"totalTokens":providers.values.reduce(0) { $0 + intValue($1,"totalTokens") },"sessionCount":all.count,"coverage":"observed indexed logs only; daily totals attributed to session start date","quotaAvailable":false,"costAvailable":false,"historyFullyIndexed":false]
    }
    private func setupList(_ params: JSON) throws -> [JSON] {
        try store.list("artifact",project:checkedProject(params),limit:10000).filter { string($0,"origin") == "setup" }
    }
    private func scanSetup(_ params: JSON) throws -> JSON {
        let explicitProject = try checkedProject(params)
        let projects: [String]
        if let explicitProject { projects = [explicitProject] }
        else { projects = try store.list("project").map { string($0,"path") }.filter { !$0.isEmpty } }
        let home = globalHome
        var candidates: [(URL,String,String,String)] = [
            (home.appendingPathComponent(".claude/CLAUDE.md"),"global","claude","instruction"),
            (home.appendingPathComponent(".claude/settings.json"),"global","claude","configuration"),
            (home.appendingPathComponent(".claude.json"),"global","claude","configuration"),
            (home.appendingPathComponent(".codex/AGENTS.md"),"global","codex","instruction"),
            (home.appendingPathComponent(".codex/config.toml"),"global","codex","configuration"),
            (home.appendingPathComponent(".cursor/mcp.json"),"global","cursor","mcp")
        ]
        for project in projects {
            let root = URL(fileURLWithPath:project)
            for (path,provider,type) in [("AGENTS.md","shared","instruction"),("CLAUDE.md","claude","instruction"),(".claude/settings.json","claude","configuration"),(".claude/settings.local.json","claude","configuration"),(".mcp.json","shared","mcp"),(".cursor/mcp.json","cursor","mcp"),(".codex/config.toml","codex","configuration")] { candidates.append((root.appendingPathComponent(path),project,provider,type)) }
            for (relative,provider,type) in [(".claude/skills","claude","skill"),(".agents/skills","shared","skill"),(".cursor/rules","cursor","rule"),(".claude/commands","claude","command")] {
                let directory = root.appendingPathComponent(relative)
                guard canonicalProject(directory.path).hasPrefix(project + "/"), let iterator = FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles]) else { continue }
                var count = 0
                for case let file as URL in iterator {
                    count += 1; if count > 1000 { break }
                    let metadata = try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                    guard metadata?.isRegularFile == true,metadata?.isSymbolicLink != true, ["md","mdc"].contains(file.pathExtension.lowercased()) else { continue }
                    candidates.append((file,project,provider,type))
                }
            }
        }
        var items: [JSON] = []; var duplicateHashes: [String:String] = [:]; var seenPaths: Set<String> = []
        for (url,scope,provider,type) in candidates where FileManager.default.fileExists(atPath:url.path) {
            guard seenPaths.insert(url.path).inserted else { continue }
            var item: JSON = ["id":stableHash("setup:" + url.path),"origin":"setup","title":url.lastPathComponent,"type":type,"scope":scope == "global" ? "global" : "project","provider":provider,"path":url.path,"project":scope == "global" ? "" : scope,"state":"active"]
            var diagnostics: [JSON] = []
            do {
                let meta = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
                guard meta.isRegularFile == true,meta.isSymbolicLink != true, (meta.fileSize ?? Int.max) <= 1024 * 1024 else { throw VelaError("Skipped nonregular, symlinked or larger than 1 MB setup file") }
                if scope != "global", !canonicalProject(url.path).hasPrefix(scope + "/") { throw VelaError("Setup file resolves outside the selected project") }
                guard let content = String(data:try Data(contentsOf:url),encoding:.utf8) else { throw VelaError("Setup file is not UTF-8") }
                let sanitized: String
                if url.pathExtension == "json" {
                    do { let value = try JSONSerialization.jsonObject(with:Data(content.utf8)); sanitized = try jsonString(["configuration":redactJSON(value)]) }
                    catch { sanitized = redactText(content); diagnostics.append(["severity":"error","code":"invalid-json","path":url.path,"message":"Configuration is not valid JSON: \(error.localizedDescription)"]) }
                } else { sanitized = redactText(content) }
                let hash = stableHash(content); let tokens = tokenEstimate(sanitized)
                item["content"] = sanitized; item["hash"] = hash; item["tokens"] = tokens; item["redacted"] = sanitized != content
                if let other = duplicateHashes[hash], !content.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { diagnostics.append(["severity":"info","code":"duplicate-content","path":url.path,"relatedPath":other,"message":"Identical content is present in another scanned file; verify whether both are loaded by your agent."]) }
                duplicateHashes[hash] = url.path
                if tokens > 6000 { diagnostics.append(["severity":"warning","code":"large-context","path":url.path,"message":"Conservative context estimate exceeds 6,000 tokens; review always-loaded instructions."]) }
                if type == "configuration", sanitized.contains("hooks") { item["containsHooks"] = true }
                if sanitized.contains("mcpServers") || sanitized.contains("mcp_servers") { item["containsMCP"] = true }
            } catch { item["content"] = ""; diagnostics.append(["severity":"warning","code":"unreadable-source","path":url.path,"message":error.localizedDescription]) }
            item["diagnostics"] = diagnostics; items.append(try store.put("artifact",item))
        }
        // Only remove stale indexed setup metadata from exactly the scopes scanned; never touch source files.
        let scannedScopes = Set(projects + [""])
        for item in try store.list("artifact",limit:10000) where string(item,"origin") == "setup" && scannedScopes.contains(string(item,"project")) && !seenPaths.contains(string(item,"path")) { try store.remove("artifact",string(item,"id")) }
        return ["artifacts":items,"diagnostics":items.flatMap { $0["diagnostics"] as? [JSON] ?? [] },"scannedProjects":projects,"globalScope":"known agent configuration files only","sourceFilesModified":false,"scannedAt":isoNow()]
    }
    private func redactJSON(_ value: Any, key: String = "", insideEnvironment: Bool = false) -> Any {
        let sensitive = key.range(of:"(?i)(api.?key|token|secret|password|authorization|credential|cookie)",options:.regularExpression) != nil
        if sensitive { return "[REDACTED]" }
        if let dictionary = value as? JSON { return dictionary.reduce(into: JSON()) { output, entry in output[entry.key] = redactJSON(entry.value,key:entry.key,insideEnvironment:insideEnvironment || key.lowercased() == "env" || key.lowercased() == "headers") } }
        if let array = value as? [Any] { return array.map { redactJSON($0,key:key,insideEnvironment:insideEnvironment) } }
        if insideEnvironment { return "[REDACTED]" }
        if let text = value as? String { return redactText(text) }
        return value
    }
    private func redactText(_ text: String) -> String {
        var result = text
        for (pattern,replacement) in [
            ("(?i)(bearer\\s+)[A-Za-z0-9._~+/=-]+","$1[REDACTED]"),
            ("(?i)((?:api[_-]?key|access[_-]?token|auth[_-]?token|password|secret|authorization)\\s*[=:]\\s*)[^\\n,}]+","$1[REDACTED]"),
            ("(?i)(--(?:api-key|token|password|secret)(?:=|\\s+))\\S+","$1[REDACTED]"),
            ("\\b(?:sk-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\\b","[REDACTED]")
        ] { result = result.replacingOccurrences(of:pattern,with:replacement,options:.regularExpression) }
        return result
    }
}
