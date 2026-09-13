import Foundation
import Darwin

/// A one-way, process-local shutdown gate for CLI modes that own child processes.
/// Spawn and registration share a lock so a signal cannot miss a new child.
public enum VelaRuntimeShutdown {
    private static let lock = NSLock()
    private static var requested = false
    private static var groups = Set<pid_t>()

    public static var isRequested: Bool {
        lock.lock(); defer { lock.unlock() }; return requested
    }

    public static var activeProcessCount: Int {
        lock.lock(); defer { lock.unlock() }; return groups.count
    }

    public static func request() {
        lock.lock(); defer { lock.unlock() }
        requested = true
        for group in groups { _ = kill(-group,SIGTERM) }
    }

    /// The bounded shutdown fallback still targets only groups spawned here.
    public static func forceStopOwnedProcesses() {
        lock.lock(); defer { lock.unlock() }
        for group in groups { _ = kill(-group,SIGKILL) }
    }

    static func spawn(allowDuringShutdown: Bool = false, _ operation: (inout pid_t) -> Int32) throws -> (Int32,pid_t) {
        lock.lock(); defer { lock.unlock() }
        guard !requested || allowDuringShutdown else { throw VelaError("Runtime is stopping; no new command was started") }
        var pid: pid_t = 0
        let result = operation(&pid)
        if result == 0 { groups.insert(pid) }
        return (result,pid)
    }

    static func finished(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }; groups.remove(pid)
    }
}
