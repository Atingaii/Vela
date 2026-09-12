import Foundation
import Darwin

/// Avoid Foundation's /private/var -> /var alias rewriting for existing paths.
/// Arbitrary symlinks are validated later through directory descriptors and O_NOFOLLOW.
func automationPath(_ raw: String, project: String) -> String {
    let root = canonicalProject(project)
    var path = raw.hasPrefix("/") ? raw : root + "/" + raw
    if root.hasPrefix("/private/") {
        let alias = String(root.dropFirst("/private".count))
        if path.hasPrefix(alias + "/") { path = root + String(path.dropFirst(alias.count)) }
    }
    return "/" + path.split(separator:"/",omittingEmptySubsequences:true).filter {$0 != "."}.joined(separator:"/")
}

struct AutomationProcessResult {
    var exitCode: Int32
    var output: String
    var durationMs: Int
    var timedOut: Bool
    var truncated: Bool
    var json: JSON { ["exitCode": Int(exitCode), "output": output, "durationMs": durationMs, "timedOut": timedOut, "truncated": truncated] }
}

enum AutomationProcess {
    static func executable(_ name: String) throws -> String {
        guard !name.isEmpty, !name.contains("\0"), name.count < 4096 else { throw VelaError("Invalid executable") }
        if name.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: name) else { throw VelaError("Executable is unavailable: \(name)") }
            return URL(fileURLWithPath: name).resolvingSymlinksInPath().path
        }
        guard !name.contains("/"), !name.contains(where: { $0.isWhitespace }) else { throw VelaError("Use an executable and separate arguments, not a shell command string") }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = String(directory) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path }
        }
        throw VelaError("Executable is unavailable: \(name)")
    }

    static func command(_ arguments: JSON) throws -> [String] {
        let executableName = try requireString(arguments, "executable")
        let args = arguments["args"] as? [String] ?? arguments["arguments"] as? [String] ?? []
        guard args.count <= 128, args.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 64_000 }) else { throw VelaError("Command argument limit exceeded") }
        return [try executable(executableName)] + args
    }

    static func run(_ command: [String], cwd: String, timeout: Double = 60, maxOutput: Int = 1_048_576) throws -> AutomationProcessResult {
        guard let first = command.first else { throw VelaError("A command is required") }
        let started = Date()
        let binary = try executable(first)
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            let key = key.uppercased()
            return !["KEY", "TOKEN", "SECRET", "PASSWORD", "COOKIE", "AUTHORIZATION", "CREDENTIAL"].contains(where: key.contains)
                && !key.hasPrefix("AWS_") && !key.hasPrefix("GIT_") && !key.hasPrefix("DYLD_") && !key.hasPrefix("LD_")
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["NO_COLOR"] = "1"
        environment["VELA_INTERNAL_RUN"] = "1"
        var descriptors: [Int32] = [0,0]
        guard pipe(&descriptors) == 0 else { throw VelaError("Could not create process output pipe") }
        defer { Darwin.close(descriptors[0]) }
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_addchdir_np(&actions,cwd) == 0 else { Darwin.close(descriptors[1]); throw VelaError("Could not set process directory") }
        posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0)
        posix_spawn_file_actions_adddup2(&actions,descriptors[1],STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions,descriptors[1],STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions,descriptors[0])
        posix_spawn_file_actions_addclose(&actions,descriptors[1])
        // Start a new process group before exec, so timeout cancellation reaches descendants.
        posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes,0)
        let args = ([binary] + command.dropFirst()).map { strdup($0) } + [nil]
        let env = environment.keys.sorted().map { strdup($0 + "=" + environment[$0]!) } + [nil]
        defer { args.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnError = args.withUnsafeBufferPointer { argv in
            env.withUnsafeBufferPointer { envp in
                posix_spawn(&pid,binary,&actions,&attributes,UnsafeMutablePointer(mutating:argv.baseAddress!),UnsafeMutablePointer(mutating:envp.baseAddress!))
            }
        }
        Darwin.close(descriptors[1])
        guard spawnError == 0 else { throw VelaError("Could not start executable: \(String(cString:strerror(spawnError)))") }
        _ = fcntl(descriptors[0],F_SETFL,O_NONBLOCK)
        let capture = ProcessCapture(limit:maxOutput)
        var buffer = [UInt8](repeating:0,count:8192)
        func drain() {
            for _ in 0..<128 {
                let size = Darwin.read(descriptors[0],&buffer,buffer.count)
                if size <= 0 { return }
                capture.append(Data(buffer.prefix(size)))
            }
        }
        let deadline = started.addingTimeInterval(max(1,min(timeout,3600)))
        var status: Int32 = 0
        var timedOut = false
        while true {
            drain()
            let result = waitpid(pid,&status,WNOHANG)
            if result == pid { break }
            if result < 0 && errno != EINTR { kill(-pid,SIGKILL); throw VelaError("Could not read command exit status") }
            if Date() >= deadline {
                timedOut = true
                kill(-pid,SIGTERM)
                let grace = Date().addingTimeInterval(0.3)
                while Date() < grace { drain(); Thread.sleep(forTimeInterval:0.01) }
                kill(-pid,SIGKILL)
                while waitpid(pid,&status,0) < 0 && errno == EINTR {}
                break
            }
            Thread.sleep(forTimeInterval:0.01)
        }
        // Test/analysis commands may not leave untracked background descendants running.
        kill(-pid,SIGTERM)
        drain()
        let signal = status & 0x7f
        let exitCode: Int32 = timedOut ? 124 : signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return AutomationProcessResult(exitCode:exitCode,output:capture.text,durationMs:Int(Date().timeIntervalSince(started)*1000),timedOut:timedOut,truncated:capture.truncated)
    }

    static func git(_ arguments: [String], cwd: String, timeout: Double = 30) throws -> AutomationProcessResult {
        // Disable execution hooks and external diff/filter entry points on observation paths.
        try run(["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "diff.external="] + arguments, cwd: cwd, timeout: timeout)
    }
}

private final class ProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private let limit: Int
    private var clipped = false
    init(limit: Int) { self.limit = limit }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, limit - bytes.count)
        bytes.append(data.prefix(remaining))
        if data.count > remaining { clipped = true }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return clipped }
}
