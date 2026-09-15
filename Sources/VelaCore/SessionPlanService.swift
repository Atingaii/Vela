import Foundation

enum SessionPlanService {
    static func handle(_ method: String, _ params: JSON, store: VelaStore) throws -> Any? {
        guard ["sessions.plan.describe", "sessions.plan.get", "sessions.plan.events"].contains(method) else { return nil }
        if method == "sessions.plan.describe" {
            guard params.isEmpty else { throw VelaError("Plan describe takes no parameters") }
            return ["decoderVersion": SessionPlanProjection.version, "providers": ["codex", "claude"],
                    "tools": ["update_plan"] + SessionPlanProjection.tools.sorted(), "readOnly": true,
                    "maximumItems": SessionPlanProjection.maximumItems, "retainedEvents": SessionPlanProjection.maximumEvents,
                    "requiresProviderAcknowledgement": true, "workVerified": false,
                    "limitations": ["bounded recent JSONL observation", "no implicit full-history replay", "Claude SDK snake_case structured results only; undocumented transcript aliases unavailable"]] as JSON
        }
        let allowed: Set<String> = method == "sessions.plan.get" ? ["project", "id"] : ["project", "id", "afterSequence", "limit"]
        guard Set(params.keys).isSubset(of: allowed), let project = try checkedProject(params, required: true),
              try store.get("project",stableHash(project)) != nil else { throw VelaError("A registered project is required") }
        let id = try requireString(params,"id")
        guard id.utf8.count <= 256, !id.contains("\0"), let session = try store.get("session",id), string(session,"project") == project else { throw VelaError("Session is unavailable in the selected project") }
        let plan = try store.get("session_plan",id) ?? [:]
        guard plan.isEmpty || string(plan,"project") == project else { throw VelaError("Plan source project changed") }
        if method == "sessions.plan.get" { return SessionPlanProjection.visible(plan, provider: string(session,"provider"), historyTruncated: session["historyTruncated"] as? Bool == true) }
        let after = try integer(params,"afterSequence",defaultValue:0,range:0...9_007_199_254_740_991)
        let limit = try integer(params,"limit",defaultValue:50,range:1...100)
        let events = plan["events"] as? [JSON] ?? [], selected = Array(events.filter { intValue($0,"sequence") > after }.prefix(limit))
        return ["items":selected, "nextAfterSequence":selected.last.map { intValue($0,"sequence") } as Any? ?? NSNull(),
                "oldestRetainedSequence":events.first.map { intValue($0,"sequence") } as Any? ?? NSNull(),
                "eventsTruncated":plan["eventsTruncated"] as? Bool == true, "decoderVersion":SessionPlanProjection.version] as JSON
    }
    private static func integer(_ params: JSON, _ key: String, defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = params[key] else { return defaultValue }
        guard let integer = usageTokenCount(value), range.contains(integer) else { throw VelaError("Invalid plan pagination argument: \(key)") }
        return integer
    }
}
