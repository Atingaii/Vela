import Foundation

/// Read-only arithmetic over durable run and approval records. It never reads
/// outputs, prompts, arguments, or provider logs as health evidence.
extension AutomationService {
    private static let healthSourceScanCap = 10_000

    func workflowHealthReport(_ params: JSON) throws -> JSON {
        let allowed: Set<String> = ["project","id","workflowVersion","limit","cursor","since"]
        guard Set(params.keys).isSubset(of:allowed) else { throw VelaError("Unsupported workflow health parameter") }
        let root: String? = params["project"] == nil ? nil : try project(requireString(params,"project"))
        let id = string(params,"id"), cursor = string(params,"cursor")
        guard cursor.utf8.count <= 200 else { throw VelaError("Workflow health cursor is too long") }
        guard params["workflowVersion"] == nil || validPositiveInteger(params["workflowVersion"]) else { throw VelaError("workflowVersion must be a positive integer") }
        let version = (params["workflowVersion"] as? NSNumber)?.intValue
        let limit = try WorkflowContext.integer(params["limit"],default:50,range:1...100,name:"workflow health limit")
        let since = healthDate(params["since"])
        guard params["since"] == nil || since != nil else { throw VelaError("workflow health since must be a bounded ISO-8601 timestamp") }
        let scannedRuns = try (root.map { try store.list("run",project:$0,limit:Self.healthSourceScanCap) } ?? store.list("run",limit:Self.healthSourceScanCap))
        let runCapReached = scannedRuns.count == Self.healthSourceScanCap
        let all = scannedRuns.filter { run in
            (id.isEmpty || string(run,"workflowId") == id) && (version == nil || intValue(run,"workflowVersion") == version!) && (since == nil || healthDate(run["startedAt"]) ?? .distantPast >= since!)
        }
        .map { ($0, healthDate($0["startedAt"]) ?? .distantPast) }
        .sorted { left, right in left.1 == right.1 ? string(left.0,"id") > string(right.0,"id") : left.1 > right.1 }
        .map(\.0)
        let nonDry = all.filter { $0["dryRun"] as? Bool != true }
        let terminal = nonDry.filter { ["completed","failed"].contains(string($0,"state")) }
        let successes = terminal.filter { string($0,"state") == "completed" }, durations = terminal.compactMap { duration($0["durationMs"]) }
        let scannedApprovals = try (root.map { try store.list("approval",project:$0,limit:Self.healthSourceScanCap) } ?? store.list("approval",limit:Self.healthSourceScanCap))
        let approvalCapReached = scannedApprovals.count == Self.healthSourceScanCap
        let runIDs = Set(nonDry.map { string($0,"id") })
        let approvals = scannedApprovals.filter { runIDs.contains(string($0,"runId")) }
        let aggregateIncomplete = runCapReached || approvalCapReached
        let states = ["completed","failed","cancelled","rejected","pending_approval","running","needs_review"]
        var result: JSON = ["workflowId":id,"runs":nonDry.count,"completedRuns":terminal.count,"successes":successes.count,"failures":terminal.filter { string($0,"state") == "failed" }.count,"successRate":terminal.isEmpty ? NSNull() : Double(successes.count)/Double(terminal.count),"averageDurationMs":durations.isEmpty ? NSNull() : durations.reduce(0,+)/Double(durations.count),"durationAvailable":!durations.isEmpty,"durationSamples":durations.count,"durationMissing":terminal.count-durations.count,"approvalRejected":approvals.filter { string($0,"state") == "rejected" }.count,"tokens":NSNull(),"tokensAvailable":false,"guidelineInfluence":"not_measured","window":["since":params["since"] ?? NSNull(),"workflowVersion":version as Any? ?? NSNull(),"dryRunsExcluded":all.count-nonDry.count],"sourceScan":["cap":Self.healthSourceScanCap,"scope":root == nil ? "all_projects" : "project","runs":["scanned":scannedRuns.count,"capReached":runCapReached],"approvals":["scanned":scannedApprovals.count,"capReached":approvalCapReached]],"aggregateIncomplete":aggregateIncomplete,"coverage":aggregateIncomplete ? "bounded_by_source_scan_cap" : "complete_within_selected_store_scope","versionGroups":healthGroups(nonDry,states:states),"stateCounts":healthStateCounts(nonDry,states:states),"detailAvailability":root == nil ? "requires_project" : "project_scoped","items":[] as [JSON],"findings":[] as [JSON],"cursor":NSNull(),"truncated":aggregateIncomplete]
        guard root != nil else { return result }
        let start: Int
        if cursor.isEmpty { start = 0 } else if let index = nonDry.firstIndex(where: { string($0,"id") == cursor }) { start = index+1 } else { throw VelaError("Workflow health cursor is unavailable in this window") }
        let page = Array(nonDry.dropFirst(start).prefix(limit)), pageMore = nonDry.count > start+page.count
        result["items"] = page.map(healthSummary); result["findings"] = page.flatMap(healthFindings); result["cursor"] = pageMore ? string(page.last ?? [:],"id") : NSNull(); result["truncated"] = pageMore || aggregateIncomplete
        return result
    }

    private func validPositiveInteger(_ value: Any?) -> Bool { guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }; return n.intValue >= 1 && Double(n.intValue) == n.doubleValue }
    private func duration(_ value: Any?) -> Double? { guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0 else { return nil }; return n.doubleValue }
    private func healthDate(_ value: Any?) -> Date? { guard let text = value as? String, text.utf8.count <= 80 else { return nil }; let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return fractional.date(from:text) ?? ISO8601DateFormatter().date(from:text) }
    private func healthStateCounts(_ runs: [JSON], states: [String]) -> JSON { var counts = Dictionary(uniqueKeysWithValues:states.map { ($0,0) }); for run in runs where counts[string(run,"state")] != nil { counts[string(run,"state"),default:0] += 1 }; return counts }
    private func healthGroups(_ runs: [JSON], states: [String]) -> [JSON] {
        var grouped: [String:[JSON]] = [:]
        for run in runs { let key = string(run,"workflowId") + "\u{0}" + (validPositiveInteger(run["workflowVersion"]) ? String(intValue(run,"workflowVersion")) : "unknown"); grouped[key,default:[]].append(run) }
        return grouped.keys.sorted().map { key in
            let parts = key.split(separator:"\0",maxSplits:1,omittingEmptySubsequences:false), workflow = String(parts[0]), rawVersion = String(parts[1])
            let subset = grouped[key] ?? []
            let terminal = subset.filter { ["completed","failed"].contains(string($0,"state")) }, good = terminal.filter { string($0,"state") == "completed" }
            return ["workflowId":workflow,"workflowVersion":rawVersion == "unknown" ? NSNull() : Int(rawVersion)!,"versionAvailability":rawVersion == "unknown" ? "unknown" : "recorded","runs":subset.count,"completedRuns":terminal.count,"successes":good.count,"failures":terminal.filter { string($0,"state") == "failed" }.count,"successRate":terminal.isEmpty ? NSNull() : Double(good.count)/Double(terminal.count),"stateCounts":healthStateCounts(subset,states:states)]
        }
    }
    private func healthSummary(_ run: JSON) -> JSON {
        let steps = (run["steps"] as? [JSON] ?? []).map { step -> JSON in ["id":string(step,"id"),"tool":string(step,"tool"),"state":string(step,"state"),"exitCode":step["exitCode"] ?? NSNull(),"timedOut":step["timedOut"] ?? NSNull(),"truncated":step["truncated"] ?? NSNull()] }
        return ["id":string(run,"id"),"workflowId":string(run,"workflowId"),"workflowVersion":validPositiveInteger(run["workflowVersion"]) ? intValue(run,"workflowVersion") : NSNull(),"versionAvailability":validPositiveInteger(run["workflowVersion"]) ? "recorded" : "unknown","state":string(run,"state"),"startedAt":run["startedAt"] ?? NSNull(),"completedAt":run["completedAt"] ?? NSNull(),"durationMs":duration(run["durationMs"]) as Any? ?? NSNull(),"durationAvailable":duration(run["durationMs"]) != nil,"dryRun":run["dryRun"] ?? NSNull(),"stepStates":steps]
    }
    private func healthFindings(_ run: JSON) -> [JSON] {
        let steps = run["steps"] as? [JSON] ?? []; var findings: [JSON] = []
        func finding(_ code: String, step: JSON? = nil) -> JSON {
            var value: JSON = ["id":code + ":" + String(stableHash(string(run,"id") + ":" + string(step ?? [:],"id")).prefix(32)),"code":code,"runId":string(run,"id"),"workflowVersion":validPositiveInteger(run["workflowVersion"]) ? intValue(run,"workflowVersion") : NSNull(),"state":string(run,"state"),"evidence":"structured_run_or_step_field"]
            if let step { value["stepId"] = string(step,"id"); value["tool"] = string(step,"tool") }
            return value
        }
        if string(run,"state") == "needs_review" { findings.append(finding("uncertain_run")) }
        for step in steps where step["timedOut"] as? Bool == true { findings.append(finding("timeout_observed",step:step)) }
        for step in steps where string(step,"state") == "refused" || step["refused"] as? Bool == true { findings.append(finding("tool_refused_observed",step:step)) }
        for step in steps where step["turnCapReached"] as? Bool == true { findings.append(finding("turn_cap_observed",step:step)) }
        let concluded = steps.filter { ["completed","failed","rejected","cancelled","needs_review"].contains(string($0,"state")) }
        if string(run,"state") == "completed", !concluded.isEmpty, concluded.allSatisfy({ string($0,"state") == "failed" }) { findings.append(finding("inconsistent_completion")) }
        return findings
    }
}
