import Foundation
import NaturalLanguage
import CoreFoundation

struct SemanticVectorRecord {
    let memoryID: String, project: String, language: String, model: String
    let revision: Int, dimension: Int
    let sourceHash: String
    let vector: [Float]
}

enum SemanticVectorMath {
    static func normalized(_ vector: [Float]) throws -> [Float] {
        guard !vector.isEmpty, vector.count <= 4096, vector.allSatisfy({ $0.isFinite }) else { throw VelaError("Invalid semantic vector") }
        let length = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard length.isFinite, length > 0 else { throw VelaError("Semantic vector has zero norm") }
        return vector.map { Float(Double($0) / length) }
    }
    static func cosine(_ a: [Float], _ b: [Float]) throws -> Double {
        guard a.count == b.count else { throw VelaError("Semantic vector dimensions do not match") }
        let x = try normalized(a), y = try normalized(b)
        return max(-1,min(1,zip(x,y).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }))
    }
}

protocol SemanticEmbeddingProvider {
    var language: String { get }
    var model: String { get }
    var revision: Int { get }
    var dimension: Int { get }
    func vector(_ text: String) throws -> [Float]
}

final class AppleSemanticEmbedding: SemanticEmbeddingProvider {
    let language: String
    let model = "apple.naturallanguage.sentence.mean512.v1"
    let embedding: NLEmbedding
    var revision: Int { embedding.revision }
    var dimension: Int { embedding.dimension }
    init?(language: String) {
        let nlLanguage: NLLanguage
        switch language { case "en": nlLanguage = .english; case "zh-Hans": nlLanguage = .simplifiedChinese; default: return nil }
        // Reading installed model availability does not request/download language assets.
        guard let embedding = NLEmbedding.sentenceEmbedding(for:nlLanguage) else { return nil }
        self.language = language; self.embedding = embedding
    }
    func vector(_ text: String) throws -> [Float] {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.utf8.count <= 520 * 1024 else { throw VelaError("Semantic text is empty or exceeds its limit") }
        // Bounded chunks cover the entire input. Their normalized sentence vectors are mean pooled.
        // Record this algorithm in the model identity; it is not an Apple document-embedding API.
        let scalars = Array(text.unicodeScalars)
        var total = [Double](repeating:0,count:dimension); var count = 0
        for start in stride(from:0,to:scalars.count,by:512) {
            let chunk = String(String.UnicodeScalarView(scalars[start..<min(start+512,scalars.count)]))
            guard !chunk.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { continue }
            guard let value = embedding.vector(for:chunk), value.count == dimension else { throw VelaError("Installed model could not embed this text") }
            let normalized = try SemanticVectorMath.normalized(value.map(Float.init))
            for i in normalized.indices { total[i] += Double(normalized[i]) }; count += 1
        }
        guard count > 0 else { throw VelaError("Semantic text has no embeddable content") }
        return try SemanticVectorMath.normalized(total.map { Float($0 / Double(count)) })
    }
}

final class SemanticMemory {
    private let store: VelaStore
    private let exclusions: IngestionExclusionService
    private let providerFactory: (String) -> SemanticEmbeddingProvider?
    private let now: () -> Date
    init(store: VelaStore, providerFactory: @escaping (String) -> SemanticEmbeddingProvider? = { AppleSemanticEmbedding(language:$0) }, now: @escaping () -> Date = Date.init) {
        self.store = store; self.exclusions = IngestionExclusionService(store:store); self.providerFactory = providerFactory; self.now = now
    }
    static func sourceHash(_ item: JSON) throws -> String {
        var source: JSON = [:]
        for key in ["title","content","project","scope","branch","worktree","task","sourceSession"] { source[key] = string(item,key) }
        if string(item,"scope") == "namespace" { source["namespace"] = string(item,"namespace") }
        return stableHash(try jsonString(source))
    }
    static func isIndexable(_ item: JSON, project: String) -> Bool {
        guard string(item,"state").lowercased() == "active", !privateLibraryPath(string(item,"sourceFile")) else { return false }
        if let privacy = item["private"] {
            guard let value = privacy as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(), !value.boolValue else { return false }
        }
        let scope = string(item,"scope","project").lowercased()
        guard ["global","project","repository","branch","worktree","task","session","namespace"].contains(scope) else { return false }
        if scope == "namespace" { guard !string(item,"namespace").isEmpty else { return false } }
        return scope == "global" ? string(item,"project").isEmpty : string(item,"project") == project
    }
    static func canRecall(_ item: JSON, params: JSON, project: String) -> Bool {
        guard isIndexable(item,project:project) else { return false }
        let namespace = string(params,"namespace"), scope = string(item,"scope").lowercased()
        if !namespace.isEmpty { return scope == "namespace" && string(item,"namespace") == namespace }
        if scope == "namespace" { return false }
        switch string(item,"scope","project").lowercased() {
        case "branch": return !string(params,"branch").isEmpty && string(item,"branch") == string(params,"branch")
        case "worktree": return !string(params,"worktree").isEmpty && canonicalProject(string(params,"worktree")) == string(item,"worktree")
        case "task": return !string(params,"task").isEmpty && string(item,"task") == string(params,"task")
        case "session": return !string(params,"sessionId").isEmpty && string(item,"sourceSession") == string(params,"sessionId")
        default: return true
        }
    }
    private func canRecall(_ item: JSON, params: JSON, project: String, policy: IngestionExclusionService.MemoryRecallPolicy) -> Bool {
        Self.canRecall(item,params:params,project:project) && policy.allows(item)
    }
    private func project(_ params: JSON) throws -> String {
        let project = try checkedProject(params,required:true)!
        guard let item = try store.get("project",stableHash(project)), string(item,"path") == project else { throw VelaError("Semantic memory requires a registered project") }
        return project
    }
    private func language(_ params: JSON) throws -> String {
        guard params["language"] == nil || params["language"] is String else { throw VelaError("Semantic language must be a string") }
        let language = string(params,"language","en")
        guard ["en","zh-Hans"].contains(language) else { throw VelaError("Semantic language must be en or zh-Hans") }
        return language
    }
    private func number(_ params: JSON, _ key: String, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
        guard let raw = params[key] else { return fallback }
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, range.contains(value.doubleValue) else { throw VelaError("Invalid semantic numeric parameter: " + key) }
        return value.doubleValue
    }
    private func integer(_ params: JSON, _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        let value = try number(params,key,default:Double(fallback),range:Double(range.lowerBound)...Double(range.upperBound))
        guard value.rounded() == value else { throw VelaError("Semantic parameter must be an integer: " + key) }; return Int(value)
    }
    private func modelInfo(_ provider: SemanticEmbeddingProvider) -> JSON {
        ["id":provider.model,"language":provider.language,"revision":provider.revision,"dimension":provider.dimension,"runtime":provider.model.hasPrefix("apple.naturallanguage.") ? "macOS NaturalLanguage; no model download requested" : "injected test provider"]
    }
    private func modelIdentity(_ provider: SemanticEmbeddingProvider) -> JSON {
        ["id":provider.model,"language":provider.language,"revision":provider.revision,"dimension":provider.dimension]
    }
    private func matches(_ metadata: JSON?, sourceHash: String, provider: SemanticEmbeddingProvider) -> Bool {
        guard let metadata else { return false }
        return string(metadata,"model") == provider.model && intValue(metadata,"revision") == provider.revision && intValue(metadata,"dimension") == provider.dimension && intValue(metadata,"bytes") == provider.dimension * 4 && string(metadata,"sourceHash") == sourceHash
    }
    func handle(_ method: String, _ params: JSON) throws -> JSON {
        if ["memory.semantic.embed","memory.semantic.query","memory.semantic.recent"].contains(method) {
            return try explicitQuery(method,params)
        }
        let allowed: Set<String> = method == "memory.semantic.index" ? ["project","language","batchSize","cursor"] : ["project","language"]
        guard Set(params.keys).isSubset(of:allowed) else { throw VelaError("Unsupported semantic index fields") }
        let project = try project(params), language = try language(params)
        guard let provider = providerFactory(language) else { return ["status":"unavailable","language":language,"model":NSNull(),"reason":"The requested Apple sentence embedding is not installed","downloadRequested":false,"indexIncomplete":true] }
        let policy = try exclusions.memoryRecallPolicy(project:project)
        if method == "memory.semantic.status" { return try status(project:project,provider:provider,policy:policy) }
        guard method == "memory.semantic.index" else { throw VelaError("Unknown semantic memory method") }
        let batchSize = try integer(params,"batchSize",default:32,range:1...200)
        var after = ""
        if let raw = params["cursor"] {
            guard let encoded = raw as? String, encoded.count <= 4096, let data = Data(base64Encoded:encoded),
                  let cursor = try JSONSerialization.jsonObject(with:data) as? JSON,
                  Set(cursor.keys) == ["project","language","model","revision","after"],
                  string(cursor,"project") == project, string(cursor,"language") == language,
                  string(cursor,"model") == provider.model,
                  let revision = cursor["revision"] as? NSNumber, CFGetTypeID(revision) != CFBooleanGetTypeID(), revision.doubleValue == Double(provider.revision),
                  let value = cursor["after"] as? String else { throw VelaError("Semantic cursor does not match this project or model") }
            after = value
        }
        let page = try store.semanticMemoryPage(project:project,after:after,limit:batchSize)
        var indexed = 0, unchanged = 0, skipped = 0, failed = 0
        for item in page.items {
            let id = string(item,"id")
            guard Self.isIndexable(item,project:project), policy.allows(item) else { skipped += 1; try store.removeSemanticVector(memoryID:id,language:language); continue }
            let hash = try Self.sourceHash(item)
            if try matches(store.semanticVectorMetadata(memoryID:id,language:language),sourceHash:hash,provider:provider) { unchanged += 1; continue }
            do {
                let vector = try provider.vector(string(item,"title") + "\n" + string(item,"content"))
                try store.putSemanticVector(SemanticVectorRecord(memoryID:id,project:string(item,"project"),language:language,model:provider.model,revision:provider.revision,dimension:provider.dimension,sourceHash:hash,vector:vector))
                indexed += 1
            } catch { failed += 1 }
        }
        var nextCursor: Any = NSNull()
        if page.hasMore, let last = page.items.last {
            let cursor: JSON = ["project":project,"language":language,"model":provider.model,"revision":provider.revision,"after":string(last,"id")]
            nextCursor = Data(try jsonString(cursor).utf8).base64EncodedString()
        }
        return ["status":failed > 0 ? "partial" : "ok","model":modelInfo(provider),"processed":page.items.count,"indexed":indexed,"unchanged":unchanged,"skipped":skipped,"failed":failed,"nextCursor":nextCursor,"hasMore":page.hasMore,"indexCompleteness":"Call memory.semantic.status after all pages; concurrent edits may require another pass","downloadRequested":false]
    }
    private func status(project: String, provider: SemanticEmbeddingProvider, scope: JSON? = nil, policy: IngestionExclusionService.MemoryRecallPolicy) throws -> JSON {
        var after = "", eligible = 0, indexed = 0, stale = 0, scanned = 0
        while true {
            let page = try store.semanticMemoryPage(project:project,after:after,limit:200)
            for item in page.items {
                if let scope, !canRecall(item,params:scope,project:project,policy:policy) { continue }
                scanned += 1
                guard Self.isIndexable(item,project:project), policy.allows(item) else { continue }
                eligible += 1
                let metadata = try store.semanticVectorMetadata(memoryID:string(item,"id"),language:provider.language)
                if try matches(metadata,sourceHash:Self.sourceHash(item),provider:provider) { indexed += 1 }
                else if metadata != nil { stale += 1 }
            }
            guard page.hasMore, let last = page.items.last else { break }; after = string(last,"id")
        }
        return ["status":"ok","model":modelInfo(provider),"scanned":scanned,"eligible":eligible,"indexed":indexed,"stale":stale,"missing":eligible-indexed,"indexIncomplete":eligible != indexed,"measurement":"Current per-record source/metadata check; not a transaction-wide snapshot","coverageScope":scope == nil ? "project index" : "query-eligible scope only","downloadRequested":false]
    }
    private struct RetrievalOptions {
        let limit: Int, budget: Int
        let threshold: Double, sort: String
        let semanticWeight: Double, recencyWeight: Double, importanceWeight: Double, halfLife: Double
    }
    private func options(_ params: JSON) throws -> RetrievalOptions {
        let limit = try integer(params,"limit",default:20,range:1...100)
        let budget = try integer(params,"budget",default:2000,range:0...4000)
        let threshold = try number(params,"minSimilarity",default:0.2,range:0...1)
        guard params["sort"] == nil || params["sort"] is String else { throw VelaError("Invalid semantic sort") }
        let sort = string(params,"sort","relevance")
        guard ["relevance","recent"].contains(sort), sort != "recent" || params["scoringWeights"] == nil else { throw VelaError("Recent sorting does not accept scoring weights") }
        let weights = params["scoringWeights"] as? JSON ?? [:]
        guard params["scoringWeights"] == nil || params["scoringWeights"] as? JSON != nil,
              Set(weights.keys).isSubset(of:["semantic","recency","recencyHalfLifeDays","importance"]) else { throw VelaError("Invalid semantic scoring weights") }
        let semanticWeight = try number(weights,"semantic",default:1,range:0...10)
        let recencyWeight = try number(weights,"recency",default:0,range:0...10)
        let importanceWeight = try number(weights,"importance",default:0,range:0...10)
        let halfLife = try number(weights,"recencyHalfLifeDays",default:30,range:0.01...3650)
        guard semanticWeight + recencyWeight + importanceWeight > 0 else { throw VelaError("At least one semantic ranking weight must be positive") }
        return RetrievalOptions(limit:limit,budget:budget,threshold:threshold,sort:sort,semanticWeight:semanticWeight,recencyWeight:recencyWeight,importanceWeight:importanceWeight,halfLife:halfLife)
    }
    private func validateScope(_ params: JSON) throws {
        for key in ["namespace","branch","worktree","task","sessionId"] where params[key] != nil {
            guard let value = params[key] as? String, !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= (key == "namespace" ? 256 : 4096), value.rangeOfCharacter(from:.controlCharacters) == nil else { throw VelaError("Invalid semantic scope: " + key) }
        }
        if params["namespace"] != nil {
            guard ["branch","worktree","task","sessionId"].allSatisfy({ params[$0] == nil }) else { throw VelaError("Namespace cannot be combined with another semantic scope") }
        }
    }
    private func explicitQuery(_ method: String, _ input: JSON) throws -> JSON {
        let common: Set<String> = ["project","namespace","branch","worktree","task","sessionId","limit","budget","minSimilarity"]
        let allowed: Set<String>
        switch method {
        case "memory.semantic.embed": allowed = ["project","language","text"]
        case "memory.semantic.recent": allowed = common.union(["query","language"])
        default: allowed = common.union(["model","vector","sort","scoringWeights"])
        }
        guard Set(input.keys).isSubset(of:allowed) else { throw VelaError("Unsupported semantic query fields") }
        let project = try project(input)
        var params = input
        try validateScope(params)
        var suppliedVector: [Float]?, identity: JSON?
        if method == "memory.semantic.query" {
            guard let model = params["model"] as? JSON, Set(model.keys) == ["id","language","revision","dimension"],
                  let id = model["id"] as? String, !id.isEmpty, id.utf8.count <= 160,
                  let values = params["vector"] as? [Any], !values.isEmpty, values.count <= 4096 else { throw VelaError("Invalid semantic model identity or vector") }
            _ = try integer(model,"revision",default:0,range:1...Int(Int32.max))
            let dimension = try integer(model,"dimension",default:0,range:1...4096)
            guard values.count == dimension else { throw VelaError("Semantic vector dimension mismatch") }
            suppliedVector = try SemanticVectorMath.normalized(values.map { raw in
                guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                      abs(value.doubleValue) <= Double(Float.greatestFiniteMagnitude) else { throw VelaError("Invalid semantic vector value") }
                return Float(value.doubleValue)
            })
            identity = model; params["language"] = try language(model)
        }
        let language = try language(params)
        var text = ""
        if method != "memory.semantic.query" {
            text = try requireString(params,method == "memory.semantic.embed" ? "text" : "query")
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= (method == "memory.semantic.embed" ? 64 * 1024 : 16 * 1024) else { throw VelaError("Semantic text is empty or exceeds its limit") }
        }
        if method == "memory.semantic.recent" { params["sort"] = "recent" }
        let options = try options(params)
        guard let provider = providerFactory(language) else {
            let base: JSON = ["status":"unavailable","model":NSNull(),"language":language,"reason":"The requested Apple sentence embedding is not installed","downloadRequested":false,"persisted":false,"indexIncomplete":true]
            return method == "memory.semantic.embed" ? base : pack(items:[],budget:options.budget,base:base)
        }
        guard provider.language == language, (1...4096).contains(provider.dimension), provider.revision > 0 else { throw VelaError("Invalid semantic provider identity") }
        if let identity {
            guard string(identity,"id") == provider.model, string(identity,"language") == provider.language,
                  intValue(identity,"revision") == provider.revision, intValue(identity,"dimension") == provider.dimension else { throw VelaError("Semantic query model does not match the installed provider") }
        }
        let vector: [Float]
        if let suppliedVector { vector = suppliedVector }
        else { vector = try SemanticVectorMath.normalized(provider.vector(text)) }
        guard vector.count == provider.dimension else { throw VelaError("Query model dimension mismatch") }
        if method == "memory.semantic.embed" {
            return ["status":"ok","model":modelIdentity(provider),"vector":vector.map(Double.init),"inputBytes":text.utf8.count,"persisted":false,"downloadRequested":false,"runtime":"local"]
        }
        let policy = try exclusions.memoryRecallPolicy(project:project)
        return try retrieve(params,project:project,provider:provider,queryVector:vector,options:options,requested:"semantic",querySource:suppliedVector == nil ? "text" : "precomputed-vector",policy:policy,lexical:{ ["items":[]] })
    }
    func recall(_ params: JSON, lexical: () throws -> JSON) throws -> JSON {
        let project = try project(params), language = try language(params)
        let requested = string(params,"retrievalMode")
        guard ["semantic","hybrid"].contains(requested) else { throw VelaError("Invalid retrieval mode") }
        let query = try requireString(params,"query")
        guard query.utf8.count <= 16 * 1024 else { throw VelaError("Semantic query exceeds 16 KiB") }
        let options = try options(params)
        let limit = options.limit, budget = options.budget
        let policy = try exclusions.memoryRecallPolicy(project:project)
        guard let provider = providerFactory(language) else {
            if requested == "hybrid" {
                var result = try lexical(); result["requestedRetrievalMode"] = requested; result["retrievalMode"] = "lexical"; result["fallbackReason"] = "Apple sentence embedding is unavailable"; result["indexIncomplete"] = true; result["model"] = NSNull(); result["downloadRequested"] = false
                // Even fallback uses semantic mode's stricter private/source rules and explicit limit.
                let items = (result["items"] as? [JSON] ?? []).filter { self.canRecall($0,params:params,project:project,policy:policy) }
                return pack(items:Array(items.prefix(limit)),budget:budget,base:result)
            }
            return pack(items:[],budget:budget,base:["status":"unavailable","retrievalMode":"unavailable","requestedRetrievalMode":requested,"model":NSNull(),"indexIncomplete":true,"reason":"Apple sentence embedding is unavailable","downloadRequested":false])
        }
        let queryVector = try SemanticVectorMath.normalized(provider.vector(query))
        guard queryVector.count == provider.dimension else { throw VelaError("Query model dimension mismatch") }
        return try retrieve(params,project:project,provider:provider,queryVector:queryVector,options:options,requested:requested,querySource:"text",policy:policy,lexical:lexical)
    }
    private func retrieve(_ params: JSON, project: String, provider: SemanticEmbeddingProvider, queryVector: [Float], options: RetrievalOptions, requested: String, querySource: String, policy: IngestionExclusionService.MemoryRecallPolicy, lexical: () throws -> JSON) throws -> JSON {
        let limit = options.limit, budget = options.budget, threshold = options.threshold
        let semanticWeight = options.semanticWeight, recencyWeight = options.recencyWeight, importanceWeight = options.importanceWeight, halfLife = options.halfLife
        var best: [(Double,Double?,JSON)] = [], stale = 0, valid = 0, matched = 0, limited = false
        let date = now()
        let standard = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        func timestamp(_ item: JSON) -> (Date?,String) {
            let raw = string(item,"createdAt")
            guard !raw.isEmpty else { return (nil,"missing") }
            guard let stamp = standard.date(from:raw) ?? fractional.date(from:raw) else { return (nil,"invalid") }
            guard stamp <= date else { return (nil,"future") }
            return (stamp,"valid")
        }
        func ranking(_ item: JSON, similarity: Double) -> Double {
            let stamp = timestamp(item).0
            let recency = stamp.map { $0 <= date ? pow(0.5,date.timeIntervalSince($0)/86400/halfLife) : 0 } ?? 0
            let importance: Double
            if let value = item["importance"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, (0...1).contains(value.doubleValue) { importance = value.doubleValue }
            else { importance = 0 }
            return semanticWeight * similarity + recencyWeight * recency + importanceWeight * importance
        }
        func keep(_ item: JSON, score: Double) {
            let (stamp,state) = timestamp(item)
            var item = item
            item["rankingTimestamp"] = stamp == nil ? NSNull() : string(item,"createdAt") as Any
            item["rankingTimestampState"] = state
            best.append((score,stamp?.timeIntervalSince1970,item))
            best.sort {
                if options.sort == "recent", $0.1 != $1.1 {
                    guard let lhs = $0.1 else { return false }
                    guard let rhs = $1.1 else { return true }
                    return lhs > rhs
                }
                return $0.0 == $1.0 ? string($0.2,"id") < string($1.2,"id") : $0.0 > $1.0
            }
            if best.count > limit { best.removeLast(); limited = true }
        }
        try store.forEachSemanticVector(project:project,language:provider.language) { row in
            guard let item = try store.get("memory",row.memoryID), canRecall(item,params:params,project:project,policy:policy) else { return }
            guard row.model == provider.model, row.revision == provider.revision, row.dimension == provider.dimension,
                  row.project == string(item,"project"), try row.sourceHash == Self.sourceHash(item) else { stale += 1; return }
            valid += 1
            let similarity = try SemanticVectorMath.cosine(queryVector,row.vector)
            guard similarity >= threshold else { return }
            matched += 1
            var result = item; result["semanticSimilarity"] = similarity; result["retrievalSource"] = "semantic"
            let score = ranking(item,similarity:similarity); result["rankingScore"] = score
            keep(result,score:score)
        }
        if requested == "hybrid" {
            let lexicalItems = (try lexical()["items"] as? [JSON]) ?? []
            for var item in lexicalItems {
                guard canRecall(item,params:params,project:project,policy:policy) else { continue }
                if let existing = best.firstIndex(where: { string($0.2,"id") == string(item,"id") }) {
                    best[existing].2["retrievalSource"] = "semantic+lexical"; continue
                }
                let lexicalScore = min(1,Double(intValue(item,"relevance"))/20)
                item["retrievalSource"] = "lexical"; item["rankingScore"] = lexicalScore * 0.5
                keep(item,score:lexicalScore * 0.5)
            }
        }
        let coverage = try status(project:project,provider:provider,scope:params,policy:policy)
        let base: JSON = ["status":"ok","retrievalMode":requested,"model":modelInfo(provider),"indexIncomplete":coverage["indexIncomplete"] ?? true,"indexCoverage":coverage,"validVectors":valid,"matchedVectors":matched,"staleVectorsExcluded":stale,"scopeExcluded":NSNull(),"scopeCountPolicy":"Out-of-scope counts are withheld","querySource":querySource,"sort":options.sort,"minSimilarity":threshold,"limit":limit,"limited":limited,"rankingPolicy":options.sort == "recent" ? "all eligible cosine matches before newest-first top-K; unknown/future dates last, then cosine, then stable ID; token packing after top-K" : "semantic score plus optional recency/importance; hybrid lexical-only fallback score capped at 0.5; top-K before token packing","downloadRequested":false]
        return pack(items:best.map(\.2),budget:budget,base:base)
    }
    private func pack(items: [JSON], budget: Int, base: JSON) -> JSON {
        var used = 0, packed: [JSON] = []
        for var item in items {
            let cost = tokenEstimate(string(item,"title") + "\n" + string(item,"content")) + 32
            if used + cost > budget { continue }; used += cost; item["recallTokens"] = cost; packed.append(item)
        }
        var result = base; result["items"] = packed; result["usedTokens"] = used; result["budget"] = budget; result["truncated"] = packed.count < items.count || (base["limited"] as? Bool == true)
        result["tokenAccounting"] = "conservative character upper bound; CJK counts as 2 tokens"; return result
    }
}
