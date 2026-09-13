import Foundation
import Darwin
import CoreFoundation

/// Read-only, bounded configuration observations with immutable sanitized
/// revisions. No provider command, import, hook or MCP endpoint is executed.
final class SetupInventoryService {
    private let store: VelaStore
    private let home: URL
    private let lock = NSRecursiveLock()
    static let maxFiles = 512, maxEntries = 15_000, maxBytes = 8_388_608, maxFileBytes = 1_048_576, maxProjects = 64
    init(store: VelaStore, home: URL) { self.store = store; self.home = URL(fileURLWithPath:canonicalProject(home.path)) }

    func handle(_ method: String,_ params: JSON) throws -> Any? {
        guard method.hasPrefix("setup.") else { return nil }
        lock.lock(); defer { lock.unlock() }
        let keys: Set<String>
        switch method {
        case "setup.catalog": keys = []
        case "setup.scan","setup.audit": keys = ["project","scope"]
        case "setup.list": keys = ["project","scope","includeInactive"]
        case "setup.get","setup.relations": keys = ["id","project","scope"]
        case "setup.history": keys = ["id","project","scope","before","limit"]
        case "setup.diff": keys = ["id","project","scope","from","to"]
        default: return nil
        }
        guard Set(params.keys).isSubset(of:keys) else { throw VelaError("Unsupported parameter for this setup operation") }
        switch method {
        case "setup.catalog": return SetupCatalog.description
        case "setup.list": return try list(params)
        case "setup.scan","setup.audit": return try scan(params)
        case "setup.get": return try artifact(params)
        case "setup.history":
            let item = try artifact(params), current = intValue(item,"revision")
            let before = try integer(params,"before",fallback:current + 1,minimum:1,maximum:current + 1)
            let limit = try integer(params,"limit",fallback:30,minimum:1,maximum:100)
            var versions: [JSON] = []; var cursor = before - 1
            while cursor > 0 && versions.count < limit {
                guard let revision = try store.get("setup_revision",revisionID(string(item,"id"),cursor)), string(revision,"artifactId") == string(item,"id"), string(revision,"project") == string(item,"project") else { throw VelaError("Configuration history is incomplete; no synthetic revision was substituted") }
                versions.append(revision.filter { $0.key != "content" }); cursor -= 1
            }
            return ["artifactId":item["id"]!,"revisions":versions,"nextBefore":cursor > 0 ? cursor + 1 : NSNull(),"historyOrigin":"observed_scans_only"] as JSON
        case "setup.diff": return try diff(params)
        case "setup.relations": return try relations(params)
        default: return nil
        }
    }

    private func integer(_ params: JSON,_ key: String,fallback: Int,minimum: Int,maximum: Int) throws -> Int {
        guard let value = params[key] else { return fallback }
        guard let number = usageTokenCount(value), (minimum...maximum).contains(number) else { throw VelaError("Invalid setup \(key)") }; return number
    }
    private func list(_ params: JSON) throws -> [JSON] {
        let project = try checkedProject(params)
        let onlyGlobal = try globalScope(params)
        if let raw = params["includeInactive"] { guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw VelaError("includeInactive must be boolean") } }
        return try store.list("artifact",project:project,limit:10000).filter { string($0,"origin") == "setup" && (!onlyGlobal || string($0,"scope") == "global") && (params["includeInactive"] as? Bool == true || !["deleted","excluded"].contains(string($0,"state"))) }
    }
    private func globalScope(_ params: JSON) throws -> Bool {
        guard let scope = params["scope"] else { return false }
        guard scope as? String == "global", params["project"] == nil else { throw VelaError("Only an explicit global scope without project is supported") }
        return true
    }
    private func artifact(_ params: JSON) throws -> JSON {
        guard let item = try store.get("artifact",requireString(params,"id")), string(item,"origin") == "setup" else { throw VelaError("Setup artifact not found") }
        if string(item,"scope") == "global" {
            guard string(params,"scope") == "global", params["project"] == nil else { throw VelaError("Global setup history requires explicit scope: global") }
        } else {
            guard let selected = try checkedProject(params,required:true), selected == string(item,"project") else { throw VelaError("Setup artifact belongs to another project") }
        }
        return item
    }
    private func revisionID(_ id: String,_ revision: Int) -> String { id + ".v" + String(revision) }

    private struct Candidate {
        let root: URL, relative: String, project: String, location: SetupCatalog.Location
        var path: String { root.appendingPathComponent(relative).path }
    }
    private func scan(_ params: JSON) throws -> JSON {
        let explicit = try checkedProject(params)
        let registered = try store.list("project",limit:10000).map { canonicalProject(string($0,"path")) }
        let selectedProjects = try globalScope(params) ? [] : explicit.map { [$0] } ?? Array(Set(registered)).sorted()
        let projects = Array(selectedProjects.prefix(Self.maxProjects))
        var candidates: [Candidate] = [], seen = Set<String>(), entries = 0, complete = selectedProjects.count <= Self.maxProjects
        var scanDiagnostics: [JSON] = []
        func append(_ root: URL,_ relative: String,_ project: String,_ location: SetupCatalog.Location) {
            let candidate = Candidate(root:root,relative:relative,project:project,location:location)
            guard seen.insert(candidate.path).inserted else { return }
            if candidates.count >= Self.maxFiles { complete = false; return }
            candidates.append(candidate)
        }
        func walk(_ root: URL,_ prefix: String,_ project: String,_ global: Bool) {
            let directory = root.appendingPathComponent(prefix)
            do {
                guard try SetupFileSnapshot.directoryExists(root:root,relative:prefix) else { if prefix.isEmpty { complete = false }; return }
            } catch {
                complete = false; scanDiagnostics.append(["code":"unreadable-source","path":directory.path,"severity":"warning","message":"Setup directory ancestry is unavailable or linked"]); return
            }
            var rootInfo = stat()
            guard lstat(directory.path,&rootInfo) == 0 else { if prefix.isEmpty || errno != ENOENT { complete = false }; return }
            guard rootInfo.st_mode & S_IFMT == S_IFDIR else {
                complete = false; scanDiagnostics.append(["code":"unreadable-source","path":directory.path,"severity":"warning","message":"Setup directory is not a regular directory; links are not followed"]); return
            }
            let keys: [URLResourceKey] = [.isDirectoryKey,.isSymbolicLinkKey]
            guard let iterator = FileManager.default.enumerator(at:directory,includingPropertiesForKeys:keys,options:[],errorHandler:{ _,_ in complete = false; return true }) else { complete = false; return }
            for case let url as URL in iterator {
                entries += 1
                if entries > Self.maxEntries || candidates.count >= Self.maxFiles { complete = false; break }
                let path = url.path
                let relative = String(path.dropFirst(root.path.count + 1))
                let metadata = try? url.resourceValues(forKeys:Set(keys))
                let components = relative.split(separator:"/")
                let nestedProject = !project.isEmpty && registered.contains { $0 != project && (path == $0 || path.hasPrefix($0 + "/")) }
                let protected = path == store.root.path || path.hasPrefix(store.root.path + "/") || privateLibraryPath(path) || nestedProject
                if metadata?.isDirectory == true {
                    if protected || SetupCatalog.excludedDirectories.contains(url.lastPathComponent) { iterator.skipDescendants(); continue }
                    if components.count >= 12 { complete = false; iterator.skipDescendants(); continue }
                }
                if metadata?.isSymbolicLink == true { iterator.skipDescendants() }
                guard !protected, !components.contains(where:{ SetupCatalog.excludedDirectories.contains(String($0)) }),
                      let location = SetupCatalog.match(relative,global:global) else { continue }
                append(root,relative,project,location)
            }
        }
        // Explicit scope never follows provider-defined custom roots or imports.
        var homeInfo = stat()
        if lstat(home.path,&homeInfo) != 0 || homeInfo.st_mode & S_IFMT != S_IFDIR { complete = false }
        for location in SetupCatalog.global {
            if location.tree { walk(home,location.path,"",true) }
            else {
                var info = stat(); let path = home.appendingPathComponent(location.path).path
                if lstat(path,&info) == 0 { append(home,location.path,"",location) }
                else if errno != ENOENT && errno != ENOTDIR { complete = false }
            }
        }
        for project in projects {
            guard !project.isEmpty, !privateLibraryPath(project), project != store.root.path, !project.hasPrefix(store.root.path + "/") else { throw VelaError("Cannot inventory private or product-managed storage as a project") }
            walk(URL(fileURLWithPath:project),"",project,false)
        }
        var items: [JSON] = [], bytes = 0, duplicates: [String:String] = [:]
        for candidate in candidates {
            if bytes >= Self.maxBytes { complete = false; break }
            var item: JSON = ["id":stableHash("setup:" + candidate.path),"origin":"setup","title":URL(fileURLWithPath:candidate.path).lastPathComponent,"type":candidate.location.type,"scope":candidate.project.isEmpty ? "global" : "project","provider":candidate.location.provider,"path":candidate.path,"relativePath":candidate.relative,"project":candidate.project,"state":"active","catalogVersion":SetupCatalog.version,"sourceURL":candidate.location.source,"runtimeLoadedState":"unavailable","sourceFilesModified":false]
            var diagnostics: [JSON] = []
            do {
                let snapshot = try SetupFileSnapshot.read(root:candidate.root,relative:candidate.relative,limit:min(Self.maxFileBytes,Self.maxBytes - bytes),metadataOnly:candidate.location.metadataOnly)
                item["sourceIdentity"] = snapshot.identity; item["sourceBytes"] = snapshot.bytes
                if let raw = snapshot.content {
                    bytes += raw.utf8.count; item["hash"] = stableHash(raw)
                    let sanitized = sanitize(raw,extension:URL(fileURLWithPath:candidate.path).pathExtension.lowercased())
                    item["content"] = sanitized.content; item["redacted"] = sanitized.redacted; item["contentStatus"] = sanitized.status
                    item["sanitizedHash"] = stableHash(sanitized.content); item["tokens"] = tokenEstimate(sanitized.content)
                    item["details"] = sanitized.details
                    if let diagnostic = sanitized.diagnostic { diagnostics.append(diagnostic.merging(["path":candidate.path]) { _,new in new }) }
                    if let other = duplicates[string(item,"project") + ":" + stableHash(raw)], !raw.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { diagnostics.append(["severity":"info","code":"duplicate-content","path":candidate.path,"relatedPath":other,"message":"Byte-identical observed configuration; provider loading or precedence is not established"] ) }
                    duplicates[string(item,"project") + ":" + stableHash(raw)] = candidate.path
                    if intValue(item,"tokens") > 6000 { diagnostics.append(["severity":"warning","code":"large-context","path":candidate.path,"message":"Observed sanitized text exceeds a conservative 6,000 token estimate; this does not prove it is always loaded"] ) }
                    item["containsHooks"] = sanitized.details["containsHooks"] ?? false; item["containsMCP"] = sanitized.details["containsMCP"] ?? false
                } else {
                    item["content"] = ""; item["hash"] = NSNull(); item["redacted"] = true; item["contentStatus"] = "metadata_only_mixed_auth_store"
                    diagnostics.append(["severity":"info","code":"credential-boundary","path":candidate.path,"message":"This documented file also contains authentication state; no contents or content hash were read"])
                }
            } catch {
                item["state"] = "unavailable"; item["content"] = ""; item["hash"] = NSNull(); item["contentStatus"] = "unavailable"
                diagnostics.append(["severity":"warning","code":"unreadable-source","path":candidate.path,"message":error.localizedDescription])
            }
            item["diagnostics"] = diagnostics
            items.append(try observe(item))
        }
        if complete {
            let scopes = Set(projects + [""])
            for previous in try store.list("artifact",limit:10000) where string(previous,"origin") == "setup" && scopes.contains(string(previous,"project")) && !seen.contains(string(previous,"path")) && !["deleted","excluded"].contains(string(previous,"state")) {
                var gone = previous
                gone["state"] = "deleted"; gone["hash"] = "absent"; gone["content"] = ""; gone["contentStatus"] = "source_missing"
                gone["sanitizedHash"] = stableHash(""); gone["details"] = JSON(); gone["diagnostics"] = [] as [JSON]
                _ = try observe(gone)
            }
        } else { scanDiagnostics.append(["code":"scan-incomplete","severity":"warning","message":"Discovery was limited, unreadable or interrupted by a bounded limit; unseen prior artifacts were retained"] ) }
        return ["artifacts":items,"diagnostics":scanDiagnostics + items.flatMap { $0["diagnostics"] as? [JSON] ?? [] },"scannedProjects":projects,"catalogVersion":SetupCatalog.version,"scanComplete":complete,"historyFullyObserved":false,"entriesVisited":entries,"sourceBytesRead":bytes,"sourceFilesModified":false,"scannedAt":isoNow(),"method":"bounded public-location inventory and sanitized observed revision history","globalScope":"known public files; mixed authentication stores are metadata-only"]
    }

    private func observe(_ source: JSON) throws -> JSON {
        var item = source
        let id = string(item,"id"), old = try store.get("artifact",id)
        let compared = ["hash","state","contentStatus","sanitizedHash","catalogVersion"]
        func fingerprint(_ row: JSON) throws -> String { stableHash(try jsonString(row.filter { compared.contains($0.key) })) }
        let changed = try old.map { try fingerprint($0) != fingerprint(item) || intValue($0,"revision") == 0 } ?? true
        item["observedAt"] = isoNow(); item["revision"] = old.map { intValue($0,"revision") } ?? 0
        if let old { item["createdAt"] = old["createdAt"] }
        var writes: [(String,JSON)] = [], absent: [(String,String)] = old == nil ? [("artifact",id)] : []
        if changed {
            let version = intValue(item,"revision") + 1
            item["revision"] = version; item["revisionId"] = revisionID(id,version)
            var revision = item
            revision["id"] = revisionID(id,version); revision["artifactId"] = id; revision["observedAt"] = item["observedAt"]
            revision.removeValue(forKey:"createdAt"); revision.removeValue(forKey:"updatedAt"); revision.removeValue(forKey:"assetPath")
            writes.append(("setup_revision",revision)); absent.append(("setup_revision",revisionID(id,version)))
        } else { item["revisionId"] = old?["revisionId"] }
        writes.append(("artifact",item))
        let expecting = try old.map { [("artifact",id,stableHash(try jsonString($0)))] } ?? []
        let saved = try store.putBatch(writes,expecting:expecting,expectingAbsent:absent)
        return saved.last!
    }

    private func diff(_ params: JSON) throws -> JSON {
        let item = try artifact(params), current = intValue(item,"revision")
        guard current > 0 else { throw VelaError("Scan this artifact to begin observed version history") }
        let from = try integer(params,"from",fallback:max(1,current-1),minimum:1,maximum:current)
        let to = try integer(params,"to",fallback:current,minimum:1,maximum:current)
        guard let before = try store.get("setup_revision",revisionID(string(item,"id"),from)),
              let after = try store.get("setup_revision",revisionID(string(item,"id"),to)),
              [before,after].allSatisfy({ string($0,"artifactId") == string(item,"id") && string($0,"project") == string(item,"project") }) else { throw VelaError("Requested observed revisions are unavailable") }
        let readable = [before,after].allSatisfy { ["sanitized","source_missing"].contains(string($0,"contentStatus")) }
        let a = string(before,"content"), b = string(after,"content")
        var result: JSON = ["artifactId":item["id"]!,"from":from,"to":to,"fromHash":before["hash"] ?? NSNull(),"toHash":after["hash"] ?? NSNull(),"sourceChanged":(try jsonString([before["hash"] ?? NSNull()])) != (try jsonString([after["hash"] ?? NSNull()])),"sanitizedTextChanged":a != b,"redacted":before["redacted"] as? Bool == true || after["redacted"] as? Bool == true,"diffAvailable":readable,"isApplyPatch":false,"historyOrigin":"observed_scans_only"]
        guard readable else { result["reason"] = "One revision has no safely stored textual representation"; return result }
        let left = a.components(separatedBy:"\n"), right = b.components(separatedBy:"\n")
        var prefix = 0, suffix = 0
        while prefix < min(left.count,right.count) && left[prefix] == right[prefix] { prefix += 1 }
        while suffix < min(left.count,right.count)-prefix && left[left.count-1-suffix] == right[right.count-1-suffix] { suffix += 1 }
        let removed = Array(left[prefix..<(left.count-suffix)]), added = Array(right[prefix..<(right.count-suffix)])
        guard removed.count + added.count <= 2000, a.utf8.count + b.utf8.count <= 262144 else { result["diffAvailable"] = false; result["reason"] = "Sanitized diff exceeds its 2,000 line or 256 KiB bound"; return result }
        result["format"] = "single_replacement_block_not_minimal"; result["startLine"] = prefix + 1; result["removed"] = removed; result["added"] = added
        return result
    }

    private func relations(_ params: JSON) throws -> JSON {
        let item = try artifact(params)
        let others = try store.list("artifact",project:string(item,"project").isEmpty ? nil : string(item,"project"),limit:10000).filter { string($0,"origin") == "setup" && string($0,"project") == string(item,"project") && string($0,"state") == "active" && string($0,"id") != string(item,"id") }
        var links: [JSON] = []
        for other in others {
            if !string(item,"hash").isEmpty, string(item,"hash") == string(other,"hash") { links.append(["relation":"identical_observed_bytes","artifactId":other["id"]!,"path":other["path"]!]) }
            let name = string(item["details"] as? JSON ?? [:],"name")
            if string(item,"type") == "skill", !name.isEmpty, name == string(other["details"] as? JSON ?? [:],"name") { links.append(["relation":"same_declared_skill_name","artifactId":other["id"]!,"path":other["path"]!,"providerMerge":"not_inferred"]) }
            if URL(fileURLWithPath:string(item,"path")).lastPathComponent == "AGENTS.override.md", URL(fileURLWithPath:string(other,"path")).lastPathComponent == "AGENTS.md", URL(fileURLWithPath:string(item,"path")).deletingLastPathComponent() == URL(fileURLWithPath:string(other,"path")).deletingLastPathComponent() {
                links.append(["relation":"documented_same_directory_override","artifactId":other["id"]!,"providers":["codex","pi"],"runtimeLoadedState":"unavailable"])
            }
        }
        return ["artifactId":item["id"]!,"relations":links,"runtimeLoadedState":"unavailable","method":"same-scope observed identities and documented same-directory conventions; no runtime merge inferred"]
    }

    private func sanitize(_ raw: String,extension ext: String) -> (content:String,redacted:Bool,status:String,details:JSON,diagnostic:JSON?) {
        if ["toml","yml","yaml"].contains(ext) {
            return ("",true,"withheld_unparsed_configuration",["format":ext,"syntaxValidated":false],["severity":"info","code":"format-redaction-unavailable","message":"A format-aware redactor is required before retaining TOML/YAML text. Only source identity and content hash were observed"])
        }
        if ext == "json" {
            guard let parsed = try? JSONSerialization.jsonObject(with:Data(raw.utf8)), parsed is JSON else {
                return ("",true,"withheld_invalid_json",["format":"json","syntaxValidated":false],["severity":"error","code":"invalid-json","message":"Expected a valid JSON configuration object; invalid source text was not persisted"])
            }
            let sanitized = redactJSON(parsed)
            let text = (try? String(data:JSONSerialization.data(withJSONObject:sanitized,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]),encoding:.utf8)) ?? ""
            let object = sanitized as? JSON ?? [:]
            var details: JSON = ["format":"json","syntaxValidated":true,"containsHooks":object["hooks"] != nil,"containsMCP":object["mcpServers"] != nil || object["mcp_servers"] != nil]
            if let servers = object["mcpServers"] as? JSON ?? object["mcp_servers"] as? JSON { details["mcpServerNames"] = servers.keys.sorted(); details["mcpServerCount"] = servers.count }
            if let hooks = object["hooks"] as? JSON { details["hookEvents"] = hooks.keys.sorted() }
            let changed = (try? jsonString(parsed)) != (try? jsonString(sanitized))
            return (text,changed,"sanitized",details,nil)
        }
        let text = redactText(raw)
        var details: JSON = ["format":"markdown","metadataParsing":"conservative_single_line_frontmatter"]
        let lines = text.components(separatedBy:"\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of:"---"), end <= 100 {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of:":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in:.whitespaces)
                guard ["name","description","globs","paths","alwaysApply","disable-model-invocation"].contains(key) else { continue }
                var value = String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces)
                if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value.removeFirst(); value.removeLast() }
                if !value.isEmpty && value != "|" && value != ">" { details[key] = String(value.prefix(2000)) }
            }
        }
        return (text,text != raw,"sanitized",details,nil)
    }
    private func redactJSON(_ value: Any,key: String = "",hidden: Bool = false) -> Any {
        if hidden || key.range(of:"(?i)(api.?key|token|secret|password|authorization|credential|cookie|private.?key|session.?key)",options:.regularExpression) != nil { return "[REDACTED]" }
        if ["env","headers","http_headers"].contains(key.lowercased()), !(value is JSON) { return "[REDACTED]" }
        if let object = value as? JSON { return object.reduce(into:JSON()) { $0[$1.key] = redactJSON($1.value,key:$1.key,hidden:["env","headers","http_headers"].contains(key.lowercased())) } }
        if let array = value as? [Any] { return array.map { redactJSON($0,key:key,hidden:hidden) } }
        if let text = value as? String { return redactText(text) }
        return value
    }
    private func redactText(_ text: String) -> String {
        var result = text
        for (pattern,replacement) in [
            ("(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----","[REDACTED PRIVATE KEY]"),
            ("(?i)(bearer\\s+)[A-Za-z0-9._~+/=-]+","$1[REDACTED]"),
            ("(?i)((?:api[_-]?key|access[_-]?token|auth[_-]?token|password|secret|authorization)\\s*[=:]\\s*)[^\\n,}]+","$1[REDACTED]"),
            ("(?i)(--(?:api-key|token|password|secret)(?:=|\\s+))\\S+","$1[REDACTED]"),
            ("\\b(?:sk-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\\b","[REDACTED]"),
            ("(?i)(https?://)[^/\\s:@]+:[^/\\s@]+@","$1[REDACTED]@"),
            ("(?i)([?&](?:token|api_key|key|access_token|password)=)[^&\\s]+","$1[REDACTED]")
        ] { result = result.replacingOccurrences(of:pattern,with:replacement,options:.regularExpression) }
        return result
    }
}

private enum SetupFileSnapshot {
    struct Snapshot { let content: String?, identity: JSON, bytes: Int }
    static func directoryExists(root: URL,relative: String) throws -> Bool {
        let fd = Darwin.open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { if errno == ENOENT { return false }; throw VelaError("Setup scope is not a safe directory") }
        var descriptors = [fd], parent = fd
        defer { descriptors.reversed().forEach { Darwin.close($0) } }
        for component in relative.split(separator:"/") {
            let next = openat(parent,String(component),O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { if errno == ENOENT { return false }; throw VelaError("Setup directory is missing or linked") }
            descriptors.append(next); parent = next
        }
        return true
    }
    static func read(root: URL,relative: String,limit: Int,metadataOnly: Bool) throws -> Snapshot {
        let components = relative.split(separator:"/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !relative.hasPrefix("/"), !relative.contains("\0") else { throw VelaError("Invalid setup source path") }
        let rootFD = Darwin.open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw VelaError("Setup scope is unavailable") }
        var descriptors = [rootFD], anchors: [(Int32,String,stat)] = []
        defer { descriptors.reversed().forEach { Darwin.close($0) } }
        var parent = rootFD
        for component in components.dropLast() {
            let child = openat(parent,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw VelaError("Setup ancestor is unavailable or linked") }
            var info = stat(); guard fstat(child,&info) == 0 else { Darwin.close(child); throw VelaError("Cannot verify setup ancestor") }
            anchors.append((parent,component,info)); descriptors.append(child); parent = child
        }
        var info = stat()
        guard fstatat(parent,components.last!,&info,AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw VelaError("Setup source must be a regular file without symbolic or hard links") }
        let identity: JSON = ["device":String(info.st_dev),"inode":String(info.st_ino),"bytes":info.st_size,"modifiedSeconds":info.st_mtimespec.tv_sec,"modifiedNanoseconds":info.st_mtimespec.tv_nsec]
        if metadataOnly { return Snapshot(content:nil,identity:identity,bytes:Int(info.st_size)) }
        guard info.st_size >= 0, info.st_size <= limit else { throw VelaError("Setup file exceeds its remaining byte limit") }
        let fd = openat(parent,components.last!,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw VelaError("Setup source cannot be opened safely") }; descriptors.append(fd)
        var opened = stat(); guard fstat(fd,&opened) == 0, same(info,opened) else { throw VelaError("Setup source changed before reading") }
        var data = Data(), buffer = [UInt8](repeating:0,count:65536)
        while true {
            let count = Darwin.read(fd,&buffer,buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw VelaError("Cannot read setup source") }
            guard data.count + count <= limit else { throw VelaError("Setup source grew beyond its byte limit") }
            data.append(buffer,count:count)
        }
        var after = stat(), linked = stat(), currentRoot = stat(), originalRoot = stat()
        guard fstat(fd,&after) == 0, same(opened,after), fstatat(parent,components.last!,&linked,AT_SYMLINK_NOFOLLOW) == 0, same(opened,linked),
              fstat(rootFD,&originalRoot) == 0, lstat(root.path,&currentRoot) == 0, originalRoot.st_dev == currentRoot.st_dev, originalRoot.st_ino == currentRoot.st_ino else { throw VelaError("Setup source identity changed during reading") }
        for (ancestor,name,expected) in anchors {
            var actual = stat()
            guard fstatat(ancestor,name,&actual,AT_SYMLINK_NOFOLLOW) == 0, actual.st_mode & S_IFMT == S_IFDIR, actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino else { throw VelaError("Setup ancestry changed during reading") }
        }
        guard let content = String(data:data,encoding:.utf8) else { throw VelaError("Setup source is not UTF-8") }
        return Snapshot(content:content,identity:identity,bytes:data.count)
    }
    private static func same(_ a: stat,_ b: stat) -> Bool {
        a.st_mode & S_IFMT == S_IFREG && b.st_mode & S_IFMT == S_IFREG && b.st_nlink == 1 && a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
