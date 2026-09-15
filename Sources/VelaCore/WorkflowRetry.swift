import Foundation

/// Retry is deliberately narrow: these are Vela's fixed local Git observations.
/// A step which could write, call a provider, or have an unknown effect never
/// reaches this helper and therefore can never be replayed automatically.
enum WorkflowRetry {
    static let supportedReadTools: Set<String> = ["git.status","git.diff","git.log"]

    struct Policy {
        let maxAttempts: Int
        let initialBackoffMs: Int
        let maxBackoffMs: Int
        var enabled: Bool { maxAttempts > 1 }
        var json: JSON { ["maxAttempts":maxAttempts,"initialBackoffMs":initialBackoffMs,"maxBackoffMs":maxBackoffMs] }
    }

    static func policy(step: JSON, tool: String) throws -> Policy {
        guard step["retry"] == nil || step["retry"] is JSON else { throw VelaError("Workflow retry must be an object") }
        guard let raw = step["retry"] as? JSON else { return Policy(maxAttempts:1,initialBackoffMs:0,maxBackoffMs:0) }
        guard supportedReadTools.contains(tool), Set(raw.keys) == Set(["maxAttempts","initialBackoffMs","maxBackoffMs"]) else { throw VelaError("Retry is supported only for fixed read tools and requires its complete bounded policy") }
        func value(_ key: String, range: ClosedRange<Int>) throws -> Int {
            guard let number = raw[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), range.contains(number.intValue), Double(number.intValue) == number.doubleValue else { throw VelaError("Invalid workflow retry \(key)") }
            return number.intValue
        }
        let attempts = try value("maxAttempts",range:1...3)
        let initial = try value("initialBackoffMs",range:50...5_000)
        let maximum = try value("maxBackoffMs",range:50...10_000)
        guard initial <= maximum else { throw VelaError("Workflow retry initialBackoffMs cannot exceed maxBackoffMs") }
        return Policy(maxAttempts:attempts,initialBackoffMs:initial,maxBackoffMs:maximum)
    }

    /// Executes an already-validated local read. `checkpoint` must durably save
    /// the containing run before/after each attempt when wired into the runner.
    static func execute(step: inout JSON, tool: String, deadline: Date, cancelled: () -> Bool, checkpoint: (JSON) throws -> Void, operation: () throws -> JSON) throws -> JSON {
        let policy = try policy(step:step,tool:tool)
        var attempts = step["attempts"] as? [JSON] ?? []
        if !attempts.isEmpty {
            step["retryState"] = "needs_review"; try checkpoint(step)
            return ["exitCode":1,"output":"A read step has an incomplete recorded attempt and requires review; it will not replay after restart","durationMs":0,"timedOut":false,"truncated":false,"outcomeUnknown":true,"retryState":"needs_review"]
        }
        step["retryPolicy"] = policy.json
        // Existing AutomationProcess owns the in-flight Git process timeout.
        // This deadline prevents another attempt and bounds waiting; it cannot
        // preempt a process already handed to that runner.
        step["retryDeadlineScope"] = "between_attempts_and_backoff"
        for index in 1...policy.maxAttempts {
            guard !cancelled(), Date() < deadline else {
                step["retryState"] = cancelled() ? "cancelled" : "deadline_exceeded"; step["attempts"] = attempts
                try checkpoint(step)
                return ["exitCode":1,"output":cancelled() ? "Read retry cancelled before a new attempt" : "Read retry deadline elapsed before a new attempt","durationMs":0,"timedOut":false,"truncated":false,"retryState":step["retryState"]!]
            }
            let attempt: JSON = ["index":index,"state":"started","startedAt":isoNow()]
            attempts.append(attempt); step["attempts"] = attempts; step["retryState"] = "executing"
            try checkpoint(step)
            let result: JSON
            do { result = try operation() }
            catch {
                attempts[index-1]["state"] = "failed_before_result"; attempts[index-1]["finishedAt"] = isoNow(); step["attempts"] = attempts; step["retryState"] = "needs_review"; try checkpoint(step)
                throw error
            }
            guard let exitCode = processExitCode(result) else {
                attempts[index-1]["state"] = "invalid_result"; attempts[index-1]["finishedAt"] = isoNow(); step["attempts"] = attempts; step["retryState"] = "needs_review"; try checkpoint(step)
                return ["exitCode":-1,"output":"Read retry received no valid process exit code; it will not retry","durationMs":0,"timedOut":false,"truncated":false,"outcomeUnknown":true,"retryState":"needs_review"]
            }
            attempts[index-1]["exitCode"] = exitCode; attempts[index-1]["timedOut"] = result["timedOut"] ?? false; attempts[index-1]["truncated"] = result["truncated"] ?? false; attempts[index-1]["terminationSignal"] = intValue(result,"terminationSignal"); attempts[index-1]["durationMs"] = intValue(result,"durationMs"); attempts[index-1]["finishedAt"] = isoNow()
            if exitCode == 0, result["truncated"] as? Bool != true {
                attempts[index-1]["state"] = "completed"; step["attempts"] = attempts; step["retryState"] = "completed"; try checkpoint(step); return result
            }
            attempts[index-1]["state"] = "failed"; step["attempts"] = attempts
            guard index < policy.maxAttempts, !cancelled(), Date() < deadline else { step["retryState"] = cancelled() ? "cancelled" : "failed"; try checkpoint(step); return result }
            let delay = min(policy.maxBackoffMs, policy.initialBackoffMs * (1 << (index - 1)))
            attempts[index-1]["backoffMs"] = delay; step["attempts"] = attempts; step["retryState"] = "backing_off"; try checkpoint(step)
            let until = min(deadline,Date().addingTimeInterval(Double(delay) / 1000))
            while Date() < until {
                if cancelled() { step["retryState"] = "cancelled"; try checkpoint(step); return ["exitCode":1,"output":"Read retry cancelled during backoff","durationMs":0,"timedOut":false,"truncated":false,"retryState":"cancelled"] }
                Thread.sleep(forTimeInterval:0.025)
            }
        }
        throw VelaError("Workflow retry exhausted unexpectedly")
    }

    private static func processExitCode(_ result: JSON) -> Int? {
        guard let number = result["exitCode"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), Double(number.intValue) == number.doubleValue, (0...255).contains(number.intValue) else { return nil }
        return number.intValue
    }
}
