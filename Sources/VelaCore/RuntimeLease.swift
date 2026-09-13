import Foundation
import Darwin

/// An advisory, per-store process lease. Never infer ownership from a recycled PID.
public final class VelaRuntimeLease {
    private var descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { release() }

    public func release() {
        if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    }

    public static func acquire(root: URL, name: String) throws -> VelaRuntimeLease? {
        guard ["scheduler", "daemon", "composition"].contains(name) else { throw VelaError("Unknown runtime lease") }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw VelaError("Runtime store is unavailable") }
        defer { close(directory) }
        let descriptor = openat(directory, ".\(name).lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw VelaError("Runtime lease cannot be opened safely") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            close(descriptor); throw VelaError("Runtime lease must be an owner-only regular file")
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return VelaRuntimeLease(descriptor: descriptor) }
        let code = errno; close(descriptor)
        if code == EWOULDBLOCK || code == EAGAIN { return nil }
        throw VelaError("Runtime lease could not be acquired")
    }

    public static func isHeld(root: URL, name: String) throws -> Bool {
        guard let lease = try acquire(root: root, name: name) else { return true }
        lease.release(); return false
    }
}
