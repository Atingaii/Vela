import Foundation
import Darwin

/// Optional user-scoped launchd registration; no root daemon or network listener.
public final class VelaDaemonService {
    private let store: VelaStore
    private let executable: String
    private let userHome: URL
    public init(store: VelaStore, executable: String, userHome: URL = URL(fileURLWithPath: NSHomeDirectory())) throws {
        self.store = store
        self.executable = try AutomationProcess.executable(executable)
        self.userHome = URL(fileURLWithPath: canonicalProject(userHome.path))
    }
    public var label: String { "ai.vela.scheduler." + String(stableHash(store.root.path).prefix(20)) }
    private var agentsDirectory: URL { userHome.appendingPathComponent("Library/LaunchAgents") }
    private var plistPath: URL { agentsDirectory.appendingPathComponent(label + ".plist") }

    public func configuration() -> JSON {
        ["Label": label, "ProgramArguments": [executable, "daemon", "run", "--home", store.root.path],
         "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 30,
         "ProcessType": "Background", "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
         "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
    }

    public func plan() throws -> JSON {
        let data = try PropertyListSerialization.data(fromPropertyList: configuration(), format: .xml, options: 0)
        return ["label": label, "path": plistPath.path, "configuration": configuration(),
                "plist": String(decoding: data, as: UTF8.self), "installed": FileManager.default.fileExists(atPath: plistPath.path),
                "scope": "current-user", "requiresRoot": false, "mutated": false]
    }

    public func status() throws -> JSON {
        let held = try VelaRuntimeLease.isHeld(root: store.root, name: "daemon")
        let recorded = try store.get("runtime", "daemon") ?? [:]
        return ["label": label, "running": held, "livenessSource": "exclusive-store-lease",
                "recorded": recorded, "installed": FileManager.default.fileExists(atPath: plistPath.path),
                "path": plistPath.path, "home": store.root.path]
    }

    /// Explicit CLI operation. Refuse to overwrite any different pre-existing job.
    public func install() throws -> JSON {
        let directory = try openAgentsDirectory(create: true)
        defer { close(directory) }
        let expected = try PropertyListSerialization.data(fromPropertyList: configuration(), format: .xml, options: 0)
        let name = label + ".plist"
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            guard errno == EEXIST, try installedConfigurationMatches(directory: directory) else { throw VelaError("An existing launch agent differs; it was not overwritten") }
        } else {
            var complete = false
            defer {
                // A failed write owns its opened inode, never a later replacement.
                if !complete && sameFile(directory: directory, name: name, descriptor: fd) { _ = unlinkat(directory, name, 0) }
                close(fd)
            }
            try expected.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw VelaError("Launch agent write failed") }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw VelaError("Launch agent could not be synchronized") }
            guard sameFile(directory: directory, name: name, descriptor: fd) else { throw VelaError("Launch agent was replaced during installation; replacement preserved") }
            complete = true
        }
        _ = fsync(directory)
        return ["installed": true, "started": false, "path": plistPath.path, "label": label]
    }

    public func start() throws -> JSON {
        _ = try install()
        let target = "gui/\(getuid())/\(label)"
        let check = try AutomationProcess.run(["/bin/launchctl", "print", target], cwd: store.root.path, timeout: 5, maxOutput: 4096)
        guard !check.timedOut, !check.truncated else { throw VelaError("Loaded launch agent identity is unavailable") }
        if check.exitCode == 0 {
            guard loadedJobMatches(check.output) else { throw VelaError("A different job owns this launchd label; it was not started") }
        }
        let directory = try openAgentsDirectory(create: false)
        defer { close(directory) }
        guard try installedConfigurationMatches(directory: directory) else { throw VelaError("Launch agent changed before start; it was not started") }
        let args = check.exitCode == 0 ? ["kickstart", target] : ["bootstrap", "gui/\(getuid())", plistPath.path]
        let result = try AutomationProcess.run(["/bin/launchctl"] + args, cwd: store.root.path, timeout: 10, maxOutput: 4096)
        guard result.exitCode == 0 else { throw VelaError("launchd start failed: \(result.output)") }
        return ["requested": true, "label": label, "status": try status()]
    }

    public func stop() throws -> JSON {
        let directory = try openAgentsDirectory(create: false)
        defer { close(directory) }
        guard try installedConfigurationMatches(directory: directory) else { throw VelaError("Installed launch agent identity differs; refusing to stop it") }
        let target = "gui/\(getuid())/\(label)"
        let check = try AutomationProcess.run(["/bin/launchctl", "print", target], cwd: store.root.path, timeout: 5, maxOutput: 4096)
        guard !check.timedOut, !check.truncated else { throw VelaError("Loaded launch agent identity is unavailable") }
        if check.exitCode == 0 {
            guard loadedJobMatches(check.output) else { throw VelaError("A different job owns this launchd label; it was not stopped") }
            let result = try AutomationProcess.run(["/bin/launchctl", "bootout", target], cwd: store.root.path, timeout: 10, maxOutput: 4096)
            guard result.exitCode == 0 else { throw VelaError("launchd stop failed: \(result.output)") }
        }
        return ["requested": true, "label": label, "status": try status()]
    }

    public func uninstall() throws -> JSON {
        _ = try stop()
        let directory = try openAgentsDirectory(create: false)
        defer { close(directory) }
        let name = label + ".plist"
        guard let original = try installedIdentity(directory: directory, name: name) else { throw VelaError("Launch agent changed; it was preserved") }
        let quarantine = "." + label + ".removing-" + UUID().uuidString + ".plist"
        guard renameatx_np(directory, name, directory, quarantine, UInt32(RENAME_EXCL)) == 0 else { throw VelaError("Launch agent could not be isolated for removal") }
        guard let moved = try installedIdentity(directory: directory, name: quarantine), moved == original else {
            // A concurrent replacement is moved back only if its original name
            // is still free; never overwrite either of the user's files.
            let restored = renameatx_np(directory, quarantine, directory, name, UInt32(RENAME_EXCL)) == 0
            throw VelaError(restored ? "Launch agent changed; its replacement was preserved" : "Launch agent changed; preserved at " + agentsDirectory.appendingPathComponent(quarantine).path)
        }
        guard unlinkat(directory, quarantine, 0) == 0 else { throw VelaError("Stopped launch agent remains at " + agentsDirectory.appendingPathComponent(quarantine).path) }
        _ = fsync(directory)
        return ["installed": false, "label": label, "storePreserved": true]
    }

    private func openAgentsDirectory(create: Bool) throws -> Int32 {
        var current = open(userHome.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw VelaError("User home is unavailable") }
        for part in ["Library", "LaunchAgents"] {
            if create && mkdirat(current, part, 0o700) != 0 && errno != EEXIST {
                close(current); throw VelaError("Launch agent directory could not be created")
            }
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else { throw VelaError("Launch agent directory must not be a symlink") }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
                close(next); throw VelaError("Launch agent directory has unsafe ownership or permissions")
            }
            current = next
        }
        return current
    }

    private struct FileIdentity: Equatable { let device: dev_t; let inode: ino_t }

    private func sameFile(directory: Int32, name: String, descriptor: Int32) -> Bool {
        var opened = stat(), named = stat()
        return fstat(descriptor, &opened) == 0 && fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0
            && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino && named.st_mode & S_IFMT == S_IFREG
    }

    private func installedConfigurationMatches(directory: Int32) throws -> Bool {
        try installedIdentity(directory: directory, name: label + ".plist") != nil
    }

    private func installedIdentity(directory: Int32, name: String) throws -> FileIdentity? {
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 32768 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        let size = bytes.count
        while offset < size {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), size - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }; offset += count
        }
        guard sameFile(directory: directory, name: name, descriptor: fd),
              let value = try? PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil) as? JSON,
              try jsonString(value) == jsonString(configuration()) else { return nil }
        return FileIdentity(device: info.st_dev,inode: info.st_ino)
    }

    /// launchctl print is diagnostic text, so unknown formatting fails closed.
    /// Disk contents alone do not prove the identity of an already loaded job.
    func loadedJobMatches(_ output: String) -> Bool {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.filter({ $0 == "path = " + plistPath.path }).count == 1,
              lines.filter({ $0 == "program = " + executable }).count == 1,
              let start = lines.firstIndex(of: "arguments = {"), let end = lines[(start + 1)...].firstIndex(of: "}") else { return false }
        return Array(lines[(start + 1)..<end]) == (configuration()["ProgramArguments"] as? [String] ?? [])
    }
}
