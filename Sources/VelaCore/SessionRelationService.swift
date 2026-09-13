import Foundation

/// Project-scoped metadata queries. No request rescans a provider or reads prose.
enum SessionRelationService {
    static let methods: Set<String> = ["sessions.relations.describe","sessions.relations.get","sessions.relations.children","sessions.relations.events","sessions.relations.resolve"]
    static func handle(_ method: String, _ params: JSON, store: VelaStore) throws -> Any? {
        guard methods.contains(method) else { return nil }
        if method == "sessions.relations.describe" {
            guard params.isEmpty else { throw VelaError("Relation describe takes no arguments") }
            return ["decoderVersion":SessionRelationProjection.version,"providers":["codex"],"referenceVersion":"0.154.0","referenceCommit":SessionRelationProjection.sourceCommit,
                    "readOnly":true,"modelsExecuted":false,"liveness":"unknown","maxPageSize":100,"retainedEvents":SessionRelationProjection.maximumEvents,
                    "knownSpawnResult":"multi_agent_v1 or unnamespaced function_call/function_call_output; text JSON agent_id",
                    "limits":["bounded observed JSONL window","not all Codex code-mode/v2 output forms","not a complete historical graph","fork is separate from parent"]] as JSON
        }
        var allowed: Set<String> = ["project","id"]
        if method == "sessions.relations.resolve" { allowed = ["project","threadId"] }
        if method == "sessions.relations.children" { allowed.formUnion(["after","limit"]) }
        if method == "sessions.relations.events" { allowed.formUnion(["afterSequence","epoch","limit"]) }
        guard Set(params.keys).isSubset(of:allowed), let raw = params["project"] as? String, raw.hasPrefix("/"), raw.rangeOfCharacter(from:.controlCharacters) == nil,
              let project = try checkedProject(params,required:true), let registration = try store.get("project",stableHash(project)), string(registration,"path") == project else { throw VelaError("Relations require an absolute registered project and supported arguments") }
        let query = Query(store:store,project:project)
        if method == "sessions.relations.resolve" {
            guard let id = SessionRelationProjection.threadID(params["threadId"]) else { throw VelaError("Invalid Codex thread UUID") }
            let resolved = try query.resolve(id)
            var result: JSON = ["threadId":id,"status":resolved.status,"liveness":"unknown"]
            if let row = resolved.row { result["source"] = query.summary(row); result["relation"] = query.relationSummary(row) }
            return result
        }
        let id = try requireString(params,"id")
        guard id.utf8.count <= 160, let row = try store.relationSource(project:project,id:id), query.visible(row) else { throw VelaError("Session is unavailable in the selected project") }
        let relation = query.relation(row)
        if method == "sessions.relations.get" {
            var result: JSON = ["source":query.summary(row),"relation":query.relationSummary(row),"parent":try query.parent(row),"liveness":"unknown","stateAggregation":"parent and child observations are independent"]
            if !relation.isEmpty { result["headerEvidence"] = relation["headerEvidence"] ?? NSNull(); result["parentClaims"] = relation["parentClaims"] ?? [JSON]() }
            return result
        }
        guard !relation.isEmpty else { throw VelaError("Relation projection is unavailable; explicitly refresh supported sources first") }
        if method == "sessions.relations.children" {
            let limit = try integer(params,"limit",defaultValue:20,range:1...100)
            let binding = stableHash(project + ":" + id + ":" + string(relation,"relationEpoch") + ":" + string(relation,"sourceThreadId"))
            var after = ""
            if let rawCursor = params["after"] {
                guard let cursor = rawCursor as? String, cursor.utf8.count <= 1024,
                      let bytes = Data(base64Encoded:cursor), let object = (try? JSONSerialization.jsonObject(with:bytes)) as? JSON,
                      Set(object.keys) == ["binding","after"], string(object,"binding") == binding,
                      let prior = object["after"] as? String, prior.utf8.count <= 160 else { throw VelaError("Relation cursor is invalid or its source epoch changed") }
                after = prior
            }
            guard let thread = SessionRelationProjection.threadID(relation["sourceThreadId"]) else { throw VelaError("Source has no valid Codex thread identity") }
            let anchorResolution = try query.resolve(thread)
            guard anchorResolution.status == "resolved", string(anchorResolution.row?["session"] as? JSON ?? [:],"id") == id else { throw VelaError("Anchor thread identity is ambiguous or unavailable") }
            let candidates = try store.relationChildren(project:project,threadID:thread,after:after,limit:limit+1)
            var items: [JSON] = [], cursor = after, omitted = 0
            for child in candidates.prefix(limit) {
                cursor = string(child["session"] as? JSON ?? [:],"id")
                guard query.visible(child), !query.relation(child).isEmpty else { omitted += 1; continue }
                let facts = query.relation(child)
                var status = string(facts,"headerState") == "observed" && string(facts,"parentThreadId") == thread ? "explicit_parent_metadata" : "conflict"
                let uniqueChild = try query.resolve(string(facts,"sourceThreadId"))
                if uniqueChild.status != "resolved" { status = "ambiguous_child_identity" }
                items.append(["source":query.summary(child),"relation":query.relationSummary(child),"status":status,"stateSource":"each child's own observed log","liveness":"unknown"])
            }
            let next = candidates.count > limit ? Data(try jsonString(["binding":binding,"after":cursor]).utf8).base64EncodedString() as Any : NSNull()
            return ["items":items,"nextCursor":next,"scanned":min(limit,candidates.count),"omitted":omitted,"pageComplete":candidates.count <= limit,
                    "relationEpoch":string(relation,"relationEpoch"),"order":"source_identity","coverage":"currently indexed child metadata; spawn-only reports are in events",
                    "childErrorsOnPage":items.filter{string($0["source"] as? JSON ?? [:],"observedState") == "Error"}.count,
                    "parentState":query.summary(row)["observedState"] ?? NSNull(),"stateAggregation":"child errors never rewrite parent state"] as JSON
        }
        let after = try integer(params,"afterSequence",defaultValue:0,range:0...9_007_199_254_740_991)
        let limit = try integer(params,"limit",defaultValue:50,range:1...100)
        if params["epoch"] != nil || after > 0 {
            guard let epoch = params["epoch"] as? String, epoch == string(relation,"relationEpoch") else { throw VelaError("Relation event epoch changed or is missing; restart from sequence zero") }
        }
        let events = relation["events"] as? [JSON] ?? [], selected = events.filter{intValue($0,"sequence") > after}
        var result: [JSON] = []
        for var event in selected.prefix(limit) {
            if string(event,"status") == "reported_spawned", let childID = SessionRelationProjection.threadID(event["childThreadId"]) {
                guard string(relation,"headerState") == "observed" else {
                    event["childResolution"] = ["status":"source_metadata_conflict"]
                    result.append(event); continue
                }
                let child = try query.resolve(childID)
                var resolution: JSON = ["status":child.status]
                if let observed = child.row {
                    let childRelation = query.relation(observed)
                    resolution["source"] = query.summary(observed)
                    resolution["parentEvidence"] = string(childRelation,"headerState") != "observed" ? "unavailable_or_conflicting" : string(childRelation,"parentThreadId") == string(relation,"sourceThreadId") ? "corroborated" : childRelation["parentThreadId"] is String ? "conflict" : "not_declared"
                }
                event["childResolution"] = resolution
            }
            result.append(event)
        }
        return ["items":result,"nextAfterSequence":result.last.map{intValue($0,"sequence")} as Any? ?? NSNull(),"hasMore":selected.count > limit,
                "relationEpoch":string(relation,"relationEpoch"),"oldestRetainedSequence":events.first.map{intValue($0,"sequence")} as Any? ?? NSNull(),
                "eventsTruncated":relation["eventsTruncated"] as? Bool == true,"coverageLimited":relation["coverageLimited"] as? Bool == true,
                "observationOnly":true,"liveness":"unknown"] as JSON
    }
    private static func integer(_ params: JSON, _ key: String, defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = params[key] else { return defaultValue }
        guard let value = usageTokenCount(raw), range.contains(value) else { throw VelaError("Invalid relation pagination argument: \(key)") }; return value
    }
    private struct Query {
        let store: VelaStore
        let project: String
        func visible(_ row: JSON) -> Bool {
            guard let session = row["session"] as? JSON else { return false }
            return string(session,"project") == project && string(session,"provider") == "codex"
                && ModelImprovement.falseOrAbsent(session["private"]) && ModelImprovement.falseOrAbsent(session["sourceLabeledPrivate"])
                && ModelImprovement.falseOrAbsent(session["internalRun"]) && ModelImprovement.falseOrAbsent((row["relation"] as? JSON)?["sourceInternal"])
                && (session["scope"] == nil || session["scope"] is String)
                && ["","project"].contains(string(session,"scope").lowercased()) && !privateLibraryPath(string(session,"sourcePath"))
        }
        func relation(_ row: JSON) -> JSON {
            guard let facts = row["relation"] as? JSON, let session = row["session"] as? JSON,
                  string(facts,"decoderVersion") == SessionRelationProjection.version, string(facts,"project") == project,
                  SessionRelationProjection.threadID(session["sourceSessionId"]) == SessionRelationProjection.threadID(facts["sourceThreadId"]),
                  string(facts,"id") == string(session,"id") else { return [:] }
            return facts
        }
        func relationSummary(_ row: JSON) -> JSON {
            let facts = relation(row)
            guard !facts.isEmpty else { return ["status":"not_indexed","needsRefresh":true] }
            var result = SessionRelationProjection.summary(facts)
            result["providerVersion"] = facts["providerVersion"] ?? NSNull()
            result["headerCoverage"] = string(facts,"headerState")
            result["observedSourceVersion"] = facts["observedSourceVersion"] ?? NSNull()
            result["sourceContinuity"] = "header verified; other prior records rely on append-only provider behavior"
            result["historyCoverage"] = "bounded current source observation"
            return result
        }
        func summary(_ row: JSON) -> JSON {
            let session = row["session"] as? JSON ?? [:]
            return ["id":string(session,"id"),"project":project,"provider":"codex","sourceThreadId":SessionRelationProjection.threadID(session["sourceSessionId"]) as Any? ?? NSNull(),
                    "title":ModelImprovement.redact(String(string(session,"title").prefix(300))),"observedState":session["state"] ?? NSNull(),
                    "statusSource":session["statusSource"] ?? "persisted log observation","liveness":"unknown","lastActivity":session["lastActivity"] ?? NSNull(),
                    "historyTruncated":session["historyTruncated"] as? Bool == true]
        }
        func resolve(_ thread: String) throws -> (status: String, row: JSON?) {
            guard SessionRelationProjection.threadID(thread) == thread else { return ("unavailable",nil) }
            let scanned = try store.relationThreadSources(project:project,threadID:thread)
            let visible = scanned.filter(visible)
            if scanned.count >= 65 { return ("ambiguity_scan_limit",nil) }
            guard visible.count == 1 else { return (visible.isEmpty ? "unavailable" : "ambiguous",nil) }
            let observed = relation(visible[0])
            guard !observed.isEmpty else { return ("not_indexed",nil) }
            guard string(observed,"headerState") == "observed" else { return ("conflicting_or_invalid_metadata",nil) }
            return ("resolved",visible[0])
        }
        func parent(_ row: JSON) throws -> JSON {
            let facts = relation(row)
            guard !facts.isEmpty else { return ["status":"not_indexed"] }
            guard string(facts,"headerState") == "observed" else { return ["status":string(facts,"headerState"),"resolved":false] }
            guard let thread = facts["parentThreadId"] as? String else {
                return ["status":"none_declared","relationshipKind":string(facts,"relationshipKind"),"resolved":false]
            }
            let resolution = try resolve(thread)
            guard let parent = resolution.row else { return ["status":resolution.status,"resolved":false,"declaredThreadId":thread] }
            let childID = string(facts,"sourceThreadId")
            let own = try resolve(childID)
            guard own.status == "resolved" else { return ["status":"ambiguous_child_identity","resolved":false,"declaredThreadId":thread] }
            var seen: Set<String> = [childID], current: JSON? = parent, ancestry = "complete"
            for depth in 0..<32 {
                guard let currentRow = current else { break }
                let currentFacts = relation(currentRow)
                guard let currentID = SessionRelationProjection.threadID((currentRow["session"] as? JSON)?["sourceSessionId"]), !seen.contains(currentID) else {
                    return ["status":"cycle","resolved":false,"declaredThreadId":thread]
                }
                seen.insert(currentID)
                guard string(currentFacts,"headerState") == "observed" else { ancestry = "unresolved_ancestor"; break }
                guard let next = currentFacts["parentThreadId"] as? String else { break }
                if depth == 31 { ancestry = "depth_limit"; break }
                let nextSource = try resolve(next)
                current = nextSource.row
                if current == nil { ancestry = "unavailable_ancestor"; break }
            }
            return ["status":"explicit_parent_metadata","resolved":true,"declaredThreadId":thread,"source":summary(parent),
                    "relationshipKind":string(facts,"relationshipKind"),"ancestryCheck":ancestry,"liveness":"unknown"]
        }
    }
}
