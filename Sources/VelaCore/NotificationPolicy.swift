import Foundation

public enum VelaNotificationKind: String, CaseIterable {
    case approval, completed, error
    public var soundFilename: String { "vela-\(rawValue).wav" }
    fileprivate var preference: String {
        switch self {
        case .approval: return "notifyApprovals"
        case .completed: return "notifyCompleted"
        case .error: return "notifyErrors"
        }
    }
}

/// A native host decides how to present this evidence; the policy never plays audio.
public struct VelaNotificationEvent {
    public let kind: VelaNotificationKind
    public let source: String
    public let recordID: String
    public let project: String
    public let title: String
    public let inferred: Bool
    public let sources: [String]
    public let spansProjects: Bool
    public var count: Int
    public var isAggregate: Bool { count > 1 }
}

/// Consume only unfiltered dashboard snapshots, on the native host's serial queue.
/// State is bounded and intentionally not persisted: restart establishes a quiet baseline.
public struct VelaNotificationPolicy {
    private struct Observation { var state: String; var sequence: Int; var created: Date? }
    private var previous: [String: [String: Observation]] = [:]
    private var baselineDates: [String: Date] = [:]
    private var sequence = 0
    private let maximumRecords = 2048
    private var retiredFreshness: [String: Date] = [:]

    public init() {}

    public mutating func events(from dashboard: JSON, now: Date = Date()) -> [VelaNotificationEvent] {
        guard dashboard["notificationScope"] as? String == "*" else { return [] }
        sequence += 1
        var candidates: [VelaNotificationEvent] = []
        for (collection, source) in [("sessions", "session"), ("runs", "run"), ("approvals", "approval")] {
            guard let records = dashboard[collection] as? [JSON] else { continue }
            let initial = baselineDates[source] == nil
            // Store timestamps currently have second precision. A baseline with
            // fractional seconds would lose approvals created later in that second.
            if initial { baselineDates[source] = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)) }
            var observations = previous[source] ?? [:]
            for record in records.prefix(maximumRecords) {
                let id = string(record, "id", string(record, "sessionId"))
                guard !id.isEmpty else { continue }
                let normalized = Self.normalized(string(record, "state"))
                let old = observations[id]?.state
                let created = Self.freshness(record, source: source) ?? observations[id]?.created
                observations[id] = Observation(state: normalized, sequence: sequence, created: created)
                guard !initial, old != normalized,
                      let kind = Self.classify(normalized, source: source) else { continue }
                if old == nil {
                    // A fast local run may finish between polls. Session creation,
                    // however, is index time: only provider-sourced activity can
                    // establish that a newly observed approval happened this run.
                    guard source == "run" || kind == .approval,
                          let created = Self.freshness(record, source: source),
                          created >= (baselineDates[source] ?? now),
                          created <= now,
                          retiredFreshness[source].map({ created > $0 }) ?? true else { continue }
                }
                // Workflow approval records are authoritative and prevent a second
                // notification for the containing run's pending_approval state.
                if source == "run", kind == .approval { continue }
                // Approval completion/failure is reflected by its run. Standalone
                // approvals requiring manual recovery may report an error directly.
                if source == "approval", kind != .approval, !string(record, "runId").isEmpty { continue }
                candidates.append(VelaNotificationEvent(kind: kind, source: source,
                    recordID: id, project: string(record, "project"),
                    title: String(string(record, "title", string(record, "provider", source)).prefix(240)),
                    inferred: source == "session", sources: [source], spansProjects: false, count: 1))
            }
            if observations.count > maximumRecords {
                let ordered = observations.sorted {
                    $0.value.sequence == $1.value.sequence ? $0.key < $1.key : $0.value.sequence > $1.value.sequence
                }
                // A creation/provider-activity watermark prevents evicted records
                // from alerting again, without retaining an unbounded ID set.
                for (_, retired) in ordered.dropFirst(maximumRecords) {
                    if let created = retired.created, created <= now, created > (retiredFreshness[source] ?? .distantPast) {
                        retiredFreshness[source] = created
                    }
                }
                observations = Dictionary(uniqueKeysWithValues: ordered.prefix(maximumRecords).map { ($0.key, $0.value) })
            }
            previous[source] = observations
        }
        let preferences = dashboard["settings"] as? JSON ?? [:]
        guard preferences["notifications"] as? Bool == true else { return [] }
        var output: [VelaNotificationEvent] = []
        // At most one notification per category per snapshot, including bulk changes.
        for kind in VelaNotificationKind.allCases where preferences[kind.preference] as? Bool != false {
            let matching = candidates.filter { $0.kind == kind }
            guard let representative = matching.first else { continue }
            let sources = Array(Set(matching.map(\.source))).sorted()
            let projects = Set(matching.map(\.project))
            output.append(VelaNotificationEvent(kind: kind,
                source: sources.count == 1 ? sources[0] : "mixed",
                recordID: matching.count == 1 ? representative.recordID : "",
                project: projects.count == 1 ? representative.project : "",
                title: matching.count == 1 ? representative.title : "",
                inferred: matching.allSatisfy(\.inferred), sources: sources,
                spansProjects: projects.count > 1, count: matching.count))
        }
        return output
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
    }
    private static func classify(_ state: String, source: String) -> VelaNotificationKind? {
        if ["needsapproval", "pendingapproval"].contains(state) || (source == "approval" && state == "pending") { return .approval }
        if ["completed", "succeeded"].contains(state) { return .completed }
        if ["error", "failed", "needsreview"].contains(state) { return .error }
        return nil
    }
    private static func freshness(_ record: JSON, source: String) -> Date? {
        if source != "session" { return date(string(record, "createdAt")) }
        // Older indexes lack provenance; ingestion timestamps are not evidence.
        for field in ["lastActivity", "startedAt"] where string(record, field + "Source") == "provider" {
            if let value = date(string(record, field)) { return value }
        }
        return nil
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
