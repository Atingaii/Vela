import Foundation

extension AutomationService {
    /// A short cross-process lease serializes scheduling and its cursor updates.
    /// The injected clock makes sleep, restart and DST behavior reproducible in tests.
    public func tick(at now: Date = Date(), startupEvent: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard let lease = try VelaRuntimeLease.acquire(root: store.root, name: "scheduler") else { return }
        defer { lease.release() }
        let workflows = try store.list("workflow",limit:1000)
        var fileObserverError: Error?
        do { try fileWatchEvents.configure(workflows) } catch { fileObserverError = error }
        for workflow in workflows where workflow["enabled"] as? Bool == true {
            if VelaRuntimeShutdown.isRequested { break }
            do {
                if string(workflow,"trigger") == "watch" {
                    let definition = try loadCurrentWorkflow(string(workflow,"id"))
                    if string(definition["watch"] as? JSON ?? [:],"source") == "files", let fileObserverError { throw fileObserverError }
                    try tickWatchWorkflow(definition,at:now)
                }
                else { try tickWorkflow(workflow, at: now, startupEvent: startupEvent) }
            }
            catch {
                // One broken project must not prevent independent workflows from being checked.
                let id = string(workflow, "id")
                var schedule = try store.get("schedule", id) ?? ["id": id, "workflowId": id, "project": string(workflow, "project")]
                schedule["state"] = "failed"; schedule["error"] = error.localizedDescription
                schedule["checkedAt"] = ISO8601DateFormatter().string(from: now)
                _ = try store.put("schedule", schedule)
            }
        }
        if !VelaRuntimeShutdown.isRequested { try analyzeChangedSessionsIfEnabled() }
    }

    private func tickWorkflow(_ workflow: JSON, at now: Date, startupEvent: String?) throws {
        let id = string(workflow, "id"), trigger = string(workflow, "trigger", "manual")
        if trigger == "manual" { return }
        let root = string(workflow, "project")
        let previous = try store.get("schedule", id)
        var schedule = previous ?? ["id": id, "workflowId": id, "project": root, "state": "idle"]
        // Inspect all unresolved claims before computing a catch-up window. A
        // latest-only schedule must never skip a claim from an older minute.
        if let unresolved = try store.unresolvedScheduleEvent(workflowId: id, project: root) {
            schedule["state"] = "needs_review"; schedule["blockedEventId"] = unresolved["id"]
            schedule["reason"] = "An interrupted dispatch has an uncertain outcome; it will not be retried."
            if try previous.map({ try jsonString(schedule) != jsonString($0) }) ?? true { _ = try store.put("schedule", schedule) }
            return
        }
        // Reconcile the old two-write acknowledgement format as well. The event
        // ledger is authoritative; the schedule is a recoverable summary.
        if string(schedule, "state") == "needs_review" {
            schedule["state"] = "idle"; schedule.removeValue(forKey: "blockedEventId")
            schedule.removeValue(forKey: "reason"); schedule.removeValue(forKey: "error")
        }
        let currentMinute = Int(now.timeIntervalSince1970 / 60)
        var events: [(key: String, minute: Int?)] = []
        var completionRevisions: [String: Int64] = [:]
        var cronPolicy = "skip"
        switch trigger {
        case "app_start":
            if !appStartHandled.contains(id) {
                events = [("app_start:" + (startupEvent ?? UUID().uuidString.lowercased()), nil)]
            }
        case "cron":
            let policy = try VelaSchedulePolicy.read(workflow)
            cronPolicy = string(policy, "catchUp")
            let fingerprint = stableHash(try jsonString(["cron": string(workflow, "cron"), "policy": policy]))
            let retainedCursor = (schedule["lastCheckedMinute"] as? NSNumber)?.intValue
            let cursor = string(schedule, "scheduleFingerprint") == fingerprint ? (retainedCursor ?? currentMinute - 1) : currentMinute - 1
            let window = intValue(policy, "catchUpWindowHours") * 60
            let lower = cronPolicy == "skip" ? currentMinute : max(min(cursor + 1, currentMinute), currentMinute - window + 1)
            let zone = TimeZone(identifier: string(policy, "timeZone"))!
            let expression = string(workflow, "cron")
            let fields = try VelaCron.fields(expression)
            var due: [Int] = []
            if cursor < currentMinute || cronPolicy == "skip" || retainedCursor == nil {
                for minute in lower...currentMinute where VelaCron.matches(fields: fields, expression: expression, date: Date(timeIntervalSince1970: Double(minute) * 60), timeZone: zone) { due.append(minute) }
            }
            schedule["scheduleFingerprint"] = fingerprint
            schedule["timeZone"] = zone.identifier; schedule["catchUp"] = cronPolicy
            schedule["windowTruncated"] = cursor < currentMinute - window
            schedule["dueCount"] = due.count
            schedule["coalescedCount"] = cronPolicy == "latest" ? max(0, due.count - 1) : 0
            if cronPolicy == "latest", let latest = due.last { due = [latest] }
            if cronPolicy == "all" { due = Array(due.prefix(intValue(policy, "catchUpLimit"))) }
            events = due.map { ("cron:\($0)", $0) }
            if events.isEmpty { schedule["lastCheckedMinute"] = max(cursor, currentMinute); schedule["state"] = "idle" }
        case "session_completed", "agent_finished":
            let revision = try store.sessionCompletionRevision()
            if schedule["completionCursor"] == nil {
                // Enabling or migrating a schedule establishes a baseline. It
                // never silently runs all already imported historical sessions.
                schedule["completionCursor"] = revision; schedule["initialized"] = true
                schedule.removeValue(forKey: "sessionBaseline")
            } else if let cursor = (schedule["completionCursor"] as? NSNumber)?.int64Value, cursor < revision {
                let page = try store.sessionCompletionPage(project: root, after: cursor)
                for item in page {
                    let key = "session:" + string(item, "sessionId") + ":" + string(item, "activity")
                    let sequence = (item["sequence"] as? NSNumber)?.int64Value ?? cursor
                    // Private/deleted/relocated/internal evidence must not start
                    // a workflow. Still consume the identity so it cannot loop.
                    let eligible = intValue(item,"present") == 1 && intValue(item,"private") == 0 && intValue(item,"internalRun") == 0 && string(item,"scope") != "private" && string(item,"project") == root && !privateLibraryPath(string(item,"sourcePath"))
                    if eligible { events.append((key,nil)); completionRevisions[key] = sequence }
                    else if events.isEmpty { schedule["completionCursor"] = sequence }
                }
                if page.isEmpty { schedule["completionCursor"] = revision }
            }
        case "git_event":
            let head = try AutomationProcess.git(["rev-parse", "HEAD"], cwd: root)
            if head.exitCode == 0 {
                let event = "git:" + head.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if schedule["initialized"] == nil { schedule["lastEvent"] = event; schedule["initialized"] = true }
                else if event != string(schedule, "lastEvent") { events = [(event, nil)] }
            } else { throw VelaError("Scheduled Git project is unavailable") }
        case "usage_reset":
            schedule["state"] = "unavailable"; schedule["reason"] = "Provider quota/reset data is unavailable; no automatic reset trigger was executed."
        default:
            schedule["state"] = "unavailable"; schedule["reason"] = "Unsupported trigger"
        }
        for event in events {
            if VelaRuntimeShutdown.isRequested { break }
            let eventID = "event-" + String(stableHash(id + ":" + event.key).prefix(48))
            if let existing = try store.get("schedule_event", eventID) {
                if ["claimed", "needs_review"].contains(string(existing, "state")) {
                    schedule["state"] = "needs_review"; schedule["reason"] = "An interrupted dispatch has an uncertain outcome; it will not be retried."
                    break
                }
                if trigger == "app_start" { appStartHandled.insert(id) }
                if let minute = event.minute { schedule["lastCheckedMinute"] = minute }
                if let sequence = completionRevisions[event.key] { schedule["completionCursor"] = sequence }
                continue
            }
            if try store.activeWorkflowRun(workflowId: id, project: root) != nil {
                schedule["state"] = "deferred"; schedule["reason"] = "A previous run is active or waiting for approval"
                break
            }
            var record: JSON = ["id": eventID, "workflowId": id, "project": root, "eventKey": event.key, "state": "claimed", "claimedAt": ISO8601DateFormatter().string(from: now)]
            if let minute = event.minute {
                record["scheduledAt"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(minute) * 60))
                record["lateBySeconds"] = max(0, Int(now.timeIntervalSince1970) - minute * 60)
            }
            guard try store.insertIfAbsent("schedule_event", record) else { continue }
            if trigger == "app_start" { appStartHandled.insert(id) }
            schedule["lastEvent"] = event.key; schedule["state"] = "claimed"
            _ = try store.put("schedule", schedule)
            // The durable claim precedes every possible effect. Never automatically repeat it.
            do {
                var run = try startWorkflow(id: id, dryRun: false)
                run["scheduleEventId"] = eventID
                run["scheduledAt"] = record["scheduledAt"] ?? NSNull()
                run["lateBySeconds"] = record["lateBySeconds"] ?? 0
                run = try store.put("run", run)
                record["state"] = "dispatched"; record["runId"] = run["id"]
                schedule["state"] = string(run, "state"); schedule["lastRunId"] = run["id"]
                schedule.removeValue(forKey: "reason"); schedule.removeValue(forKey: "error")
            } catch {
                record["state"] = "needs_review"; record["error"] = error.localizedDescription
                schedule["state"] = "needs_review"; schedule["error"] = error.localizedDescription
            }
            _ = try store.put("schedule_event", record)
            if let minute = event.minute { schedule["lastCheckedMinute"] = cronPolicy == "all" ? minute : currentMinute }
            if let sequence = completionRevisions[event.key] { schedule["completionCursor"] = sequence }
            if string(schedule, "state") == "needs_review" { break }
        }
        let changed = try previous.map { try jsonString(schedule) != jsonString($0) } ?? true
        if changed { _ = try store.put("schedule", schedule) }
    }

    private func analyzeChangedSessionsIfEnabled() throws {
        guard try store.get("settings","preferences")?["analysisEnabled"] as? Bool == true else { return }
        let revision = try store.sessionRevision()
        let detectorVersion = "explicit-engineering-v2"
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
    static func matches(_ expression: String, date: Date, timeZone: TimeZone = .current) throws -> Bool {
        matches(fields: try fields(expression), expression: expression, date: date, timeZone: timeZone)
    }
    static func matches(fields sets: [Set<Int>], expression: String, date: Date, timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let components = calendar.dateComponents([.minute,.hour,.day,.month,.weekday],from:date)
        let values = [components.minute!,components.hour!,components.day!,components.month!,components.weekday!-1]
        guard sets[0].contains(values[0]),sets[1].contains(values[1]),sets[3].contains(values[3]) else { return false }
        let raw = expression.split(whereSeparator: {$0.isWhitespace})
        let dayMatch = sets[2].contains(values[2]); let weekdayMatch = sets[4].contains(values[4])
        return raw[2] == "*" || raw[4] == "*" ? dayMatch && weekdayMatch : dayMatch || weekdayMatch
    }
}
