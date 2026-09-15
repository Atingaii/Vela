import Foundation

extension AutomationService {
    public func scheduleStatus(_ params: JSON) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        let selected = try checkedProject(params)
        return ["schedules": try store.list("schedule", project: selected, limit: 1000),
                "events": try store.list("schedule_event", project: selected, limit: 1000),
                "daemonRunning": try VelaRuntimeLease.isHeld(root: store.root, name: "daemon"),
                "intervalSeconds": 30]
    }

    public func resolveScheduledDispatch(_ params: JSON) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        guard string(params, "decision") == "acknowledge" else { throw VelaError("Only explicit acknowledgement is supported; uncertain effects cannot be retried") }
        guard let lease = try VelaRuntimeLease.acquire(root: store.root, name: "scheduler") else { throw VelaError("Scheduler is busy; no change was made") }
        defer { lease.release() }
        let event = try object("schedule_event", requireString(params, "id"))
        guard ["claimed", "needs_review", "acknowledged"].contains(string(event, "state")) else { throw VelaError("This dispatch does not need reconciliation") }
        let project = try self.project(requireString(params, "project"))
        guard string(event, "project") == project else { throw VelaError("Dispatch belongs to another project") }
        if try store.activeWorkflowRun(workflowId: string(event, "workflowId"), project: project, states: ["running", "pending_approval", "waiting_child"]) != nil {
            throw VelaError("Review or finish the existing run before acknowledging its dispatch")
        }
        var acknowledged = event
        acknowledged["state"] = "acknowledged"; acknowledged["acknowledgedAt"] = event["acknowledgedAt"] ?? isoNow(); acknowledged["retried"] = false
        var objects: [(String, JSON)] = [("schedule_event", acknowledged)]
        var expectations = [("schedule_event", string(event, "id"), stableHash(try jsonString(event)))]
        if var schedule = try store.get("schedule", string(event, "workflowId")) {
            expectations.append(("schedule", string(schedule, "id"), stableHash(try jsonString(schedule))))
            schedule["state"] = "idle"; schedule.removeValue(forKey: "reason"); schedule.removeValue(forKey: "error"); schedule.removeValue(forKey: "blockedEventId")
            objects.append(("schedule", schedule))
        }
        // Both runtime records commit together, with their reviewed snapshots
        // checked inside the same SQLite write transaction.
        return try store.putBatch(objects, expecting: expectations)[0]
    }
}
