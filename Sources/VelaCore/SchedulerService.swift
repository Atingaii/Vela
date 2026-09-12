import Foundation

extension AutomationService {
    public func tick() throws {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        for workflow in try store.list("workflow",limit:1000) where workflow["enabled"] as? Bool == true {
            let id = string(workflow,"id")
            let trigger = string(workflow,"trigger","manual")
            if trigger == "manual" { continue }
            let root = string(workflow,"project")
            var schedule = try store.get("schedule",id) ?? ["id":id,"workflowId":id,"project":root,"state":"idle"]
            var event: String?
            switch trigger {
            case "app_start":
                if !appStartHandled.contains(id) { event = "app_start:" + UUID().uuidString.lowercased(); appStartHandled.insert(id) }
            case "cron":
                if try VelaCron.matches(string(workflow,"cron"),date:now) { event = "cron:\(Int(now.timeIntervalSince1970 / 60))" }
            case "session_completed","agent_finished":
                let sessions = try store.list("session",project:root,limit:1000).filter {string($0,"state").lowercased() == "completed"}
                let latest = sessions.sorted { string($0,"updatedAt") > string($1,"updatedAt") }.first
                if let latest { event = "session:" + string(latest,"id") + ":" + string(latest,"lastActivity",string(latest,"updatedAt")) }
                if schedule["initialized"] == nil { schedule["lastEvent"] = event ?? ""; event = nil; schedule["initialized"] = true }
            case "git_event":
                let head = try AutomationProcess.git(["rev-parse","HEAD"],cwd:root)
                if head.exitCode == 0 { event = "git:" + head.output.trimmingCharacters(in:.whitespacesAndNewlines) }
                if schedule["initialized"] == nil { schedule["lastEvent"] = event ?? ""; event = nil; schedule["initialized"] = true }
            case "usage_reset":
                // Provider quotas are explicitly unavailable in the initial adapters. Never infer
                // a reset from cumulative session tokens or fabricate a percentage.
                schedule["state"] = "unavailable"; schedule["reason"] = "Provider quota/reset data is unavailable; no automatic reset trigger was executed."
            default: schedule["state"] = "unavailable"; schedule["reason"] = "Unsupported trigger"
            }
            if let event, event != string(schedule,"lastEvent") {
                let active = try store.list("run",project:root).contains { string($0,"workflowId") == id && ["running","pending_approval"].contains(string($0,"state")) }
                if active {
                    schedule["state"] = "deferred"; schedule["reason"] = "A previous run is active or waiting for approval"
                } else {
                    // Claim before starting. A crash never replays an event with unknown effects.
                    let eventID = "event-" + String(stableHash(id + ":" + event).prefix(48))
                    let didClaim = try store.insertIfAbsent("schedule_event",["id":eventID,"workflowId":id,"project":root,"eventKey":event,"state":"claimed","claimedAt":isoNow()])
                    if !didClaim { continue }
                    schedule["lastEvent"] = event; schedule["state"] = "claimed"; schedule["claimedAt"] = isoNow()
                    _ = try store.put("schedule",schedule)
                    do {
                        let run = try startWorkflow(id:id,dryRun:false)
                        schedule["state"] = string(run,"state"); schedule["lastRunId"] = run["id"]
                    } catch { schedule["state"] = "failed"; schedule["error"] = error.localizedDescription }
                }
            }
            _ = try store.put("schedule",schedule)
        }
        try analyzeChangedSessionsIfEnabled()
    }

    private func analyzeChangedSessionsIfEnabled() throws {
        guard try store.get("settings","preferences")?["analysisEnabled"] as? Bool == true else { return }
        let revision = try store.sessionRevision()
        let detectorVersion = "explicit-language-v1"
        let previous = try store.get("analysis_state","background")
        if let previous, (previous["sessionRevision"] as? NSNumber)?.int64Value == revision,
           string(previous,"detectorVersion") == detectorVersion { return }
        // Only the existing local deterministic detector is invoked: no process, model call,
        // project file change or automatic Apply. Do not advance the cursor if it throws.
        let result = try analyze([:])
        _ = try store.put("analysis_state",["id":"background","title":"Background evidence analysis","state":"completed","sessionRevision":revision,"detectorVersion":detectorVersion,"completedAt":isoNow(),"modelCalled":false,"signalsObserved":(result["signals"] as? [JSON])?.count ?? 0,"suggestionsObserved":(result["suggestions"] as? [JSON])?.count ?? 0])
        // A session arriving during analysis increments the counter beyond this snapshot and
        // is processed on the following tick, rather than accidentally being marked consumed.
    }
}

enum VelaCron {
    static func validate(_ expression: String) throws { _ = try fields(expression) }
    static func fields(_ expression: String) throws -> [Set<Int>] {
        let components = expression.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard components.count == 5 else { throw VelaError("Cron requires five fields: minute hour day month weekday") }
        let bounds = [(0,59),(0,23),(1,31),(1,12),(0,6)]
        return try zip(components,bounds).map { component, bound in
            var values = Set<Int>()
            for part in component.split(separator:",",omittingEmptySubsequences:false) {
                let split = part.split(separator:"/",omittingEmptySubsequences:false)
                guard split.count <= 2, !split.isEmpty else { throw VelaError("Invalid cron field") }
                let step = split.count == 2 ? Int(split[1]) ?? 0 : 1
                guard step > 0, step <= bound.1-bound.0+1 else { throw VelaError("Invalid cron step") }
                let range: ClosedRange<Int>
                if split[0] == "*" { range = bound.0...bound.1 }
                else if split[0].contains("-") {
                    let pair = split[0].split(separator:"-")
                    guard pair.count == 2, let from = Int(pair[0]), let to = Int(pair[1]), from <= to, from >= bound.0, to <= bound.1 else { throw VelaError("Invalid cron range") }
                    range = from...to
                } else {
                    guard split.count == 1, let number = Int(split[0]), number >= bound.0, number <= bound.1 else { throw VelaError("Invalid cron value") }
                    range = number...number
                }
                for value in stride(from:range.lowerBound,through:range.upperBound,by:step) { values.insert(value) }
            }
            guard !values.isEmpty else { throw VelaError("Empty cron field") }; return values
        }
    }
    static func matches(_ expression: String, date: Date) throws -> Bool {
        let sets = try fields(expression)
        let components = Calendar.current.dateComponents([.minute,.hour,.day,.month,.weekday],from:date)
        let values = [components.minute!,components.hour!,components.day!,components.month!,components.weekday!-1]
        guard sets[0].contains(values[0]),sets[1].contains(values[1]),sets[3].contains(values[3]) else { return false }
        let raw = expression.split(whereSeparator: {$0.isWhitespace})
        let dayMatch = sets[2].contains(values[2]); let weekdayMatch = sets[4].contains(values[4])
        return raw[2] == "*" || raw[4] == "*" ? dayMatch && weekdayMatch : dayMatch || weekdayMatch
    }
}
