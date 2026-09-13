import Foundation

/// Manual observations about a completed non-private workflow run. These records
/// are review evidence only; they never alter execution, approval, promotion, or
/// Health's objective success-rate arithmetic.
extension AutomationService {
    private static let feedbackKind = "run_feedback"
    private static let feedbackTerminalStates: Set<String> = ["completed", "failed", "cancelled", "rejected"]

    func runFeedback(_ method: String, _ params: JSON) throws -> Any {
        switch method {
        case "runs.feedback.prepare": return try prepareRunFeedback(params)
        case "runs.feedback.record": return try recordRunFeedback(params)
        case "runs.feedback.list": return try listRunFeedback(params)
        case "runs.feedback.get": return try getRunFeedback(params)
        case "runs.feedback.history.list": return try listRunFeedbackHistory(params)
        case "runs.feedback.history.get": return try getRunFeedbackHistory(params)
        default: throw VelaError("Unsupported run feedback method")
        }
    }

    private func prepareRunFeedback(_ params: JSON) throws -> JSON {
        try feedbackExactKeys(params,["project","runId"])
        let root = try project(requireString(params,"project"))
        let run = try feedbackEligibleRun(root:root,id:try feedbackID(params,"runId"))
        let hash = try stableHash(jsonString(run))
        let existing = try currentFeedback(root:root,run:run,runHash:hash)
        return ["runId":string(run,"id"),"workflowId":string(run,"workflowId"),"workflowVersion":run["workflowVersion"] ?? NSNull(),"state":string(run,"state"),"runHash":hash,"feedback":existing.map { feedbackView($0) } ?? NSNull()]
    }

    private func recordRunFeedback(_ params: JSON) throws -> JSON {
        try feedbackExactKeys(params,["project","runId","runHash","previousFeedbackHash","outcome","reason"])
        let root = try project(requireString(params,"project"))
        let run = try feedbackEligibleRun(root:root,id:try feedbackID(params,"runId"))
        let runHash = try feedbackHash(params["runHash"])
        guard runHash == (try stableHash(jsonString(run))) else { throw VelaError("Run changed; review the latest run feedback snapshot before recording") }
        let previousHash = try feedbackPreviousHash(params["previousFeedbackHash"])
        let outcome = try feedbackOutcome(params["outcome"]), reason = try feedbackReason(params["reason"])
        let id = feedbackRecordID(root, string(run,"id"), runHash)
        let prior = try store.get(Self.feedbackKind,id)
        let actualPrevious = try prior.map { try stableHash(jsonString($0)) }
        // Exact replay is harmless even after the caller's original snapshot is stale.
        if let prior, string(prior,"outcome") == outcome, string(prior,"reason") == reason { return feedbackView(prior,created:false,idempotent:true) }
        guard actualPrevious == previousHash else { throw VelaError("Feedback changed; review the latest feedback snapshot before recording") }
        let record: JSON = ["id":id,"project":root,"runId":string(run,"id"),"runHash":runHash,"workflowId":string(run,"workflowId"),"workflowVersion":run["workflowVersion"] ?? NSNull(),"outcome":outcome,"reason":reason,"source":"manual_observation","evidenceKind":"manual_run_feedback_v1","createdAt":prior?["createdAt"] ?? isoNow(),"revision":intValue(prior ?? [:],"revision") + 1]
        var objects: [(String,JSON)] = []
        var absent: [(String,String)] = []
        var expecting: [(String,String,String)] = [("run",string(run,"id"),runHash)]
        if let prior {
            let priorHash = try stableHash(jsonString(prior))
            expecting.append((Self.feedbackKind,id,priorHash))
            let historyID = "run-feedback-history-" + String(priorHash.prefix(32))
            objects.append(("run_feedback_history",["id":historyID,"project":root,"feedbackId":id,"superseded":prior,"createdAt":isoNow()]))
            absent.append(("run_feedback_history",historyID))
        } else { absent.append((Self.feedbackKind,id)) }
        objects.append((Self.feedbackKind,record))
        do { return feedbackView(try store.putBatch(objects,expecting:expecting,expectingAbsent:absent).last!,created:prior == nil,idempotent:false) }
        catch {
            // A concurrent exact replay may already have committed; only that exact
            // latest record is acknowledged, never a changed observation.
            if let existing = try? store.get(Self.feedbackKind,id), feedbackSame(existing,record) { return feedbackView(existing,created:false,idempotent:true) }
            throw error
        }
    }

    private func listRunFeedback(_ params: JSON) throws -> JSON {
        try feedbackList(params,kind:Self.feedbackKind,history:false)
    }
    private func listRunFeedbackHistory(_ params: JSON) throws -> JSON {
        try feedbackList(params,kind:"run_feedback_history",history:true)
    }
    private func feedbackList(_ params: JSON, kind: String, history: Bool) throws -> JSON {
        let allowed: Set<String> = ["project","runId","limit","cursor"]
        guard Set(params.keys).isSubset(of:allowed), params["project"] != nil else { throw VelaError("Unsupported run feedback list parameter") }
        let root = try project(requireString(params,"project")), limit = try WorkflowContext.integer(params["limit"],default:50,range:1...100,name:"run feedback limit")
        let target = params["runId"] == nil ? nil : try feedbackID(params,"runId")
        if let target { _ = try feedbackEligibleRun(root:root,id:target) }
        let scanned = try store.list(kind,project:root,limit:10_000)
        let eligible = scanned.compactMap { row -> JSON? in
            let feedback = history ? (row["superseded"] as? JSON) : row
            guard let feedback, target == nil || string(feedback,"runId") == target!,
                  let run = try? feedbackEligibleRun(root:root,id:string(feedback,"runId")),
                  let hash = try? stableHash(jsonString(run)), string(feedback,"runHash") == hash else { return nil }
            var view = feedbackView(feedback)
            if history { view["historyId"] = string(row,"id"); view["supersededAt"] = row["createdAt"] ?? NSNull() }
            return view
        }.sorted { left, right in
            guard history else { return string(left,"id") < string(right,"id") }
            let l = string(left,"supersededAt"), r = string(right,"supersededAt")
            if l != r { return l > r }
            let lr = intValue(left,"revision"), rr = intValue(right,"revision")
            return lr == rr ? string(left,"historyId") < string(right,"historyId") : lr > rr
        }
        func anchor(_ item: JSON) -> String { string(item,history ? "historyId" : "id") }
        let snapshot = stableHash(try jsonString(eligible.map { ["anchor":anchor($0),"feedbackHash":string($0,"feedbackHash")] }))
        let after = try feedbackCursor(params["cursor"],project:root,runID:target,snapshot:snapshot)
        let start: Int
        if after.isEmpty { start = 0 }
        else if let index = eligible.firstIndex(where: { anchor($0) == after }) { start = index + 1 }
        else { throw VelaError("Run feedback cursor is unavailable in this snapshot") }
        let page = Array(eligible.dropFirst(start).prefix(limit)); let more = eligible.count > start + page.count
        let next: Any = more ? try feedbackCursor(project:root,runID:target,snapshot:snapshot,after:anchor(page.last ?? [:])) : NSNull()
        return ["items":page,"cursor":next,"truncated":more || scanned.count == 10_000,"coverage":scanned.count == 10_000 ? "bounded_by_source_scan_cap" : "complete_within_project","snapshotHash":snapshot]
    }
    private func feedbackCursor(_ raw: Any?, project: String, runID: String?, snapshot: String) throws -> String {
        guard let raw else { return "" }; guard let value = raw as? String, value.utf8.count <= 2048, value.hasPrefix("vela-run-feedback-page-v1."), let bytes = Data(base64Encoded:String(value.dropFirst(26))), let object = try? JSONSerialization.jsonObject(with:bytes) as? JSON, Set(object.keys) == Set(["projectHash","runId","snapshot","after"]), string(object,"projectHash") == stableHash(project), string(object,"runId") == (runID ?? ""), string(object,"snapshot") == snapshot else { throw VelaError("Run feedback cursor does not match this project, filter or snapshot") }; return try feedbackID(object,"after")
    }
    private func feedbackCursor(project: String, runID: String?, snapshot: String, after: String) throws -> String {
        "vela-run-feedback-page-v1." + Data(try jsonString(["projectHash":stableHash(project),"runId":runID ?? "","snapshot":snapshot,"after":after]).utf8).base64EncodedString()
    }
    private func getRunFeedbackHistory(_ params: JSON) throws -> JSON {
        try feedbackExactKeys(params,["project","id"]); let root = try project(requireString(params,"project")), id = try feedbackID(params,"id")
        let history = try object("run_feedback_history",id); guard string(history,"project") == root, let prior = history["superseded"] as? JSON else { throw VelaError("Run feedback history belongs to another project") }
        let run = try feedbackEligibleRun(root:root,id:string(prior,"runId")); guard string(prior,"runHash") == (try stableHash(jsonString(run))) else { throw VelaError("Run feedback history source is no longer current") }
        var view = feedbackView(prior); view["historyId"] = id; view["supersededAt"] = history["createdAt"] ?? NSNull(); return view
    }

    private func getRunFeedback(_ params: JSON) throws -> JSON {
        try feedbackExactKeys(params,["project","id"])
        let root = try project(requireString(params,"project")), id = try feedbackID(params,"id")
        let record = try object(Self.feedbackKind,id)
        guard string(record,"project") == root else { throw VelaError("Run feedback belongs to another project") }
        let run = try feedbackEligibleRun(root:root,id:string(record,"runId"))
        guard string(record,"runHash") == (try stableHash(jsonString(run))) else { throw VelaError("Run feedback source is no longer current") }
        return feedbackView(record)
    }

    private func feedbackRecordID(_ root: String, _ runID: String, _ runHash: String) -> String { "run-feedback-" + String(stableHash(root + "\n" + runID + "\n" + runHash).prefix(32)) }
    private func feedbackProjectRun(_ root: String, _ id: String) throws -> JSON {
        let run = try object("run",id)
        guard string(run,"project") == root else { throw VelaError("Run belongs to another project") }
        return run
    }
    private func feedbackEligibleRun(root: String, id: String) throws -> JSON {
        let run = try feedbackProjectRun(root,id)
        guard Self.feedbackTerminalStates.contains(string(run,"state")), run["dryRun"] as? Bool != true,
              ModelImprovement.falseOrAbsent(run["private"]), ModelImprovement.falseOrAbsent(run["sourceLabeledPrivate"]),
              !privateLibraryPath(string(run,"sourcePath")) else { throw VelaError("Only a terminal non-private non-dry run can receive manual feedback") }
        return run
    }
    private func currentFeedback(root: String, run: JSON, runHash: String) throws -> JSON? {
        let id = feedbackRecordID(root,string(run,"id"),runHash)
        guard let row = try store.get(Self.feedbackKind,id), string(row,"project") == root,
              string(row,"runId") == string(run,"id"), string(row,"runHash") == runHash else { return nil }
        return row
    }
    func feedbackView(_ row: JSON, created: Bool? = nil, idempotent: Bool? = nil) -> JSON {
        var view: JSON = ["id":string(row,"id"),"project":string(row,"project"),"runId":string(row,"runId"),"runHash":string(row,"runHash"),"workflowId":string(row,"workflowId"),"workflowVersion":row["workflowVersion"] ?? NSNull(),"outcome":string(row,"outcome"),"reason":string(row,"reason"),"source":"manual_observation","createdAt":row["createdAt"] ?? NSNull(),"revision":row["revision"] ?? NSNull()]
        view["feedbackHash"] = (try? stableHash(jsonString(row))) ?? ""
        if let created { view["created"] = created }; if let idempotent { view["idempotent"] = idempotent }
        return view
    }
    private func feedbackSame(_ left: JSON, _ right: JSON) -> Bool {
        ["project","runId","runHash","workflowId","outcome","reason","source","evidenceKind"].allSatisfy { string(left,$0) == string(right,$0) } && intValue(left,"workflowVersion") == intValue(right,"workflowVersion")
    }
    private func feedbackExactKeys(_ params: JSON, _ keys: [String]) throws { guard Set(params.keys) == Set(keys) else { throw VelaError("Unsupported run feedback parameter") } }
    private func feedbackID(_ params: JSON, _ key: String) throws -> String { let value = try requireString(params,key); guard value.utf8.count <= 150, value.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil else { throw VelaError("Invalid run feedback identifier") }; return value }
    private func feedbackPreviousHash(_ value: Any?) throws -> String? { if value is NSNull { return nil }; guard let value = value as? String else { throw VelaError("Invalid previous feedback hash") }; return try feedbackHash(value) }
    private func feedbackHash(_ value: Any?) throws -> String { guard let value = value as? String, value.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else { throw VelaError("Invalid run feedback hash") }; return value }
    private func feedbackOutcome(_ value: Any?) throws -> String { guard let value = value as? String, ["good","bad","clear"].contains(value) else { throw VelaError("Run feedback outcome must be good, bad, or clear") }; return value }
    private func feedbackReason(_ value: Any?) throws -> String { guard let value = value as? String, !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, value.utf8.count <= 1000, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), ModelImprovement.redact(value) == value else { throw VelaError("Run feedback reason is invalid or contains sensitive content") }; return value }

    func verifiedManualFeedback(rows: [JSON], runs: [JSON]) throws -> [JSON] {
        let byID = Dictionary(uniqueKeysWithValues:runs.map { (string($0,"id"),$0) })
        return rows.filter { row in
            guard let run = byID[string(row,"runId")], (try? feedbackEligibleRun(root:string(run,"project"),id:string(run,"id"))) != nil,
                  let hash = try? stableHash(jsonString(run)) else { return false }
            return string(row,"runHash") == hash
        }
    }
}
