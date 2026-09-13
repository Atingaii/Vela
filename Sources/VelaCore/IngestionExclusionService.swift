import Foundation

final class IngestionExclusionService {
    private static let ruleLimit = 256
    let store: VelaStore
    var knownSource: ((String,String,String) -> Bool)?
    var relativeSourcePath: ((String,String) -> String?)?
    init(store: VelaStore) { self.store = store }
    func handle(_ method: String, _ params: JSON) throws -> Any? {
        if method == "ingestion.exclusions.upsert" || method == "ingestion.exclusions.remove" {
            // History has its own lock/database. Resolve the read-only source
            // association before taking the core write lock to avoid lock inversion.
            var sourceKnown = false
            if method == "ingestion.exclusions.upsert", let glob = params["pathGlob"] as? String, valid(glob),
               let provider = params["provider"] as? String, ["claude","codex","cursor","pi","omp"].contains(provider.lowercased()) {
                sourceKnown = knownSource?(try checkedProject(params),provider.lowercased(),glob) == true
            }
            return try store.withIngestionPolicyTransaction { try self.handleInsideTransaction(method,params,sourceKnown:sourceKnown) as? JSON ?? [:] }
        }
        return try handleInsideTransaction(method,params)
    }
    private func handleInsideTransaction(_ method: String, _ params: JSON, sourceKnown: Bool = false) throws -> Any? {
        switch method {
        case "ingestion.exclusions.list":
            guard Set(params.keys).isSubset(of:["project"]) else { throw VelaError("Unknown ingestion exclusion field") }
            return try rules(project:checkedProject(params)).map(view)
        case "ingestion.exclusions.upsert":
            guard Set(params.keys).isSubset(of:["id","project","provider","pathGlob"]) else { throw VelaError("Unknown ingestion exclusion field") }
            for key in ["provider","pathGlob","id"] where params[key] != nil {
                guard let value = params[key] as? String, !value.isEmpty else { throw VelaError("\(key) must be a nonempty string when supplied") }
            }
            let project = try checkedProject(params), provider = string(params,"provider").lowercased(), pathGlob = params["pathGlob"] as? String
            guard try store.get("project",stableHash(project)) != nil else { throw VelaError("Select a registered project") }
            if let pathGlob { guard ["claude","codex","cursor","pi","omp"].contains(provider), valid(pathGlob) else { throw VelaError("Source exclusion requires a provider and safe provider-root-relative glob") } }
            else if !provider.isEmpty { throw VelaError("Whole-project exclusion must not name a provider") }
            let id = (params["id"] as? String) ?? stableHash(project + "\u{0}" + provider + "\u{0}" + (pathGlob ?? "<project>"))
            let previous = try store.get("ingestion_exclusion",id)
            if let previous, string(previous,"project") != project { throw VelaError("Ingestion exclusion belongs to another project") }
            let current = try rules(project:project)
            guard previous != nil || current.count < Self.ruleLimit else { throw VelaError("Project ingestion exclusion limit reached") }
            let unchanged = previous.map { string($0,"provider") == provider && ($0["pathGlob"] as? String) == pathGlob } ?? false
            if unchanged, let previous { return view(previous) }
            if pathGlob != nil, !sourceKnown { throw VelaError("Source exclusion must match a known regular source in this project") }
            let object: JSON = ["id":id,"project":project,"scope":pathGlob == nil ? "project" : "source","provider":provider,"pathGlob":pathGlob as Any? ?? NSNull()]
            let saved = try store.put("ingestion_exclusion",object)
            try advanceGeneration(project)
            try store.ingestionPolicyAfterRuleWriteForTesting?()
            var result = view(saved); result["derivedSessionsRemoved"] = try withdraw(project:project)
            return result
        case "ingestion.exclusions.remove":
            guard Set(params.keys).isSubset(of:["project","id"]) else { throw VelaError("Unknown ingestion exclusion field") }
            let project = try checkedProject(params), id = try requireString(params,"id")
            guard let rule = try store.get("ingestion_exclusion",id), string(rule,"project") == project else { throw VelaError("Ingestion exclusion not found for project") }
            try store.remove("ingestion_exclusion",id); try advanceGeneration(project)
            return ["removed":true,"automaticReingestion":false]
        default: return nil
        }
    }
    private func advanceGeneration(_ project: String) throws {
        _ = try store.put("ingestion_policy_revision",["id":stableHash(project),"project":project,"revision":UUID().uuidString])
    }
    /// Read the revision before the rules. If policy changes during classification,
    /// putBatch's transactional expectation rejects the stale derived write.
    func admission(project: String, provider: String, relative: String) throws -> (excluded: Bool, expected: [(String,String,String)], absent: [(String,String)]) {
        guard !project.isEmpty else { return (false,[],[]) }
        let project = canonicalProject(project), id = stableHash(project)
        let revision = try store.get("ingestion_policy_revision",id)
        let blocked = try excludes(project:project,provider:provider,relative:relative)
        if let revision { return (blocked,[("ingestion_policy_revision",id,stableHash(try jsonString(revision)))],[]) }
        return (blocked,[],[("ingestion_policy_revision",id)])
    }
    private func withdraw(project: String) throws -> Int {
        let active = try rules(project:project)
        var after = "", removed = 0
        while true {
            let page = try store.ingestionSourcePage(project:project,afterID:after)
            if page.isEmpty { break }
            for row in page {
                let id = string(row,"id"), provider = string(row,"provider"), path = string(row,"sourcePath")
                let relative = relativeSourcePath?(path,provider)
                let blocked = active.contains { rule in
                    string(rule,"scope") == "project" || (string(rule,"provider") == provider && relative.map { matches($0,string(rule,"pathGlob")) } == true)
                }
                if blocked {
                    for kind in ["session","session_plan","session_relation"] { try store.remove(kind,id) }
                    if !path.isEmpty { try store.remove("ingestion",stableHash(path)) }
                    removed += 1
                }
            }
            after = string(page.last!,"id")
        }
        return removed
    }
    func excludes(project: String, provider: String, relative: String) throws -> Bool {
        for rule in try rules(project:canonicalProject(project)) {
            if string(rule,"scope") == "project" || (string(rule,"provider") == provider && matches(relative,string(rule,"pathGlob"))) { return true }
        }; return false
    }
    private func rules(project: String) throws -> [JSON] {
        let result = try store.list("ingestion_exclusion",project:project,limit:Self.ruleLimit + 1)
        guard result.count <= Self.ruleLimit else { throw VelaError("Ingestion rules exceed the supported bound; remove a rule before continuing") }
        return result
    }
    private func checkedProject(_ params: JSON) throws -> String {
        let raw = try requireString(params,"project")
        guard raw.hasPrefix("/"), !raw.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw VelaError("Ingestion exclusion requires an absolute project path") }
        let project = canonicalProject(raw)
        guard try store.get("project",stableHash(project)) != nil else { throw VelaError("Select a registered project") }
        return project
    }
    private func view(_ rule: JSON) -> JSON { ["id":string(rule,"id"),"project":string(rule,"project"),"scope":string(rule,"scope"),"provider":string(rule,"provider").isEmpty ? NSNull() : string(rule,"provider"),"pathGlob":rule["pathGlob"] ?? NSNull()] }
    private func valid(_ glob: String) -> Bool { !glob.isEmpty && glob.utf8.count <= 512 && !glob.hasPrefix("/") && !glob.contains("\\") && !glob.contains(where:{"[]{}".contains($0)}) && !glob.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) && !glob.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0=="." || $0==".." || $0.isEmpty}) }
    func matches(_ value: String,_ pattern: String) -> Bool { let p=Array(pattern), v=Array(value); var prior=Array(repeating:false,count:p.count+1); prior[0]=true; for i in p.indices where p[i] == "*" { prior[i+1]=prior[i] }; for c in v { var current=Array(repeating:false,count:p.count+1); for i in p.indices { if p[i] == "*" { current[i+1]=current[i] || prior[i+1] } else if p[i] == "?" || p[i] == c { current[i+1]=prior[i] } }; prior=current }; return prior[p.count] }
}
