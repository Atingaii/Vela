import Foundation
import Darwin

struct QuotaReadError: Error {
    let kind: String
    let code: Int?
    init(_ kind: String, code: Int? = nil) { self.kind = kind; self.code = code }
}

/// Only account/rateLimits/read is available. No token file is opened by Vela,
/// and raw stdout/stderr/account identity is never persisted or returned.
final class ProviderQuotaService {
    let store: VelaStore
    let environment: [String: String]
    let timeout: Double
    private let lock = NSLock()
    init(store: VelaStore, environment: [String: String] = ProcessInfo.processInfo.environment, timeout: Double = 15) {
        self.store = store; self.environment = environment; self.timeout = timeout
    }
    func handle(_ method: String, _ params: JSON) throws -> Any? {
        guard method == "usage.quota.read" || method == "usage.quota.status" else { return nil }
        let provider = try requireString(params, "provider")
        guard provider == "codex" else { throw VelaError("Quota provider is not supported; no credentials were read") }
        let allowed = method == "usage.quota.read" ? Set(["provider", "executable"]) : Set(["provider"])
        guard Set(params.keys).isSubset(of: allowed) else { throw VelaError("Unsupported quota parameter") }
        if method == "usage.quota.status" { return try status() }
        let selected = try requireString(params, "executable")
        guard selected.hasPrefix("/"), !selected.contains("\0"), selected.utf8.count <= 4096 else { throw VelaError("Select an absolute Codex executable path") }
        // The caller selects a local CLI. The adapter supplies fixed arguments;
        // executable resolution never interprets shell metacharacters.
        lock.lock(); defer { lock.unlock() }
        let attemptedAt = isoNow()
        do {
            let result = try CodexQuotaTransport.read(executable: selected, cwd: store.root.path, environment: environment, timeout: timeout)
            let snapshot = try Self.normalize(result)
            _ = try store.putBatch([("quota_snapshot", snapshot), ("quota_attempt", ["id": "codex", "provider": "codex", "attemptedAt": attemptedAt, "succeeded": true])])
        } catch {
            let failure = error as? QuotaReadError ?? QuotaReadError("unavailable")
            _ = try store.put("quota_attempt", ["id": "codex", "provider": "codex", "attemptedAt": attemptedAt, "succeeded": false,
                                                "error": ["kind": failure.kind, "code": failure.code as Any? ?? NSNull()]])
        }
        return try status()
    }
    private func status() throws -> JSON {
        let snapshot = try store.get("quota_snapshot", "codex")
        let attempt = try store.get("quota_attempt", "codex")
        let date = snapshot.flatMap { ISO8601DateFormatter().date(from: string($0, "observedAt")) }
        let age = date.map { max(0, Date().timeIntervalSince($0)) }
        let stale = age == nil || age! > 300
        let failed = attempt?["succeeded"] as? Bool == false
        let state = failed ? "error" : snapshot == nil ? "never_read" : stale ? "stale" : "fresh"
        let windows = (snapshot?["buckets"] as? [JSON] ?? []).flatMap { $0["windows"] as? [JSON] ?? [] }
        let windowAvailable = windows.contains { window in
            guard window["usedPercent"] is NSNumber else { return false }
            return usageTokenCount(window["resetsAt"]).map { Double($0) > Date().timeIntervalSince1970 } ?? true
        }
        return ["provider": "codex", "status": state, "quotaAvailable": !stale && !failed && windowAvailable,
                "snapshot": snapshot as Any? ?? NSNull(), "lastAttempt": attempt as Any? ?? NSNull(),
                "sourceCapturedAt": snapshot?["observedAt"] ?? NSNull(), "lastAttemptAt": attempt?["attemptedAt"] ?? NSNull(),
                "stale": stale || failed, "ageSeconds": age as Any? ?? NSNull(), "source": "codex app-server account/rateLimits/read"]
    }
    static func normalize(_ result: JSON, now: Date = Date()) throws -> JSON {
        let rawBuckets: [(String, JSON)]
        if let value = result["rateLimitsByLimitId"], !(value is NSNull) {
            guard let buckets = value as? [String: Any], buckets.count <= 1000 else { throw QuotaReadError("invalid_response") }
            rawBuckets = try buckets.keys.sorted().map { key in
                guard key.utf8.count <= 256, let bucket = buckets[key] as? JSON else { throw QuotaReadError("invalid_response") }
                return (key, bucket)
            }
        } else if let legacy = result["rateLimits"] as? JSON {
            rawBuckets = [("legacy", legacy)]
        } else if (result["rateLimits"] == nil || result["rateLimits"] is NSNull),
                  result["rateLimits"] is NSNull || result["rateLimitsByLimitId"] is NSNull {
            rawBuckets = []
        } else { throw QuotaReadError("invalid_response") }
        var available = false
        func optionalText(_ value: Any?) -> Any {
            guard let text = value as? String, text.utf8.count <= 256 else { return NSNull() }
            return text
        }
        func number(_ value: Any?) -> Double? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
            return number.doubleValue
        }
        let buckets = try rawBuckets.map { key, raw -> JSON in
            var windows: [JSON] = []
            for windowName in ["primary", "secondary"] {
                guard let window = raw[windowName] as? JSON else {
                    if let value = raw[windowName], !(value is NSNull) { throw QuotaReadError("invalid_response") }
                    continue
                }
                let used = number(window["usedPercent"])
                let duration = usageTokenCount(window["windowDurationMins"]).flatMap { $0 > 0 ? $0 : nil }
                let reset = usageTokenCount(window["resetsAt"]).flatMap { $0 <= 253_402_300_799 ? $0 : nil }
                let expired = reset.map { Double($0) <= now.timeIntervalSince1970 }
                if used != nil, expired != true { available = true }
                windows.append(["name": windowName, "usedPercent": used as Any? ?? NSNull(),
                                "remainingPercent": used.map { max(0, min(100, 100 - $0)) } as Any? ?? NSNull(),
                                "windowDurationMins": duration as Any? ?? NSNull(), "resetsAt": reset as Any? ?? NSNull(),
                                "expired": expired as Any? ?? NSNull(), "complete": used != nil && duration != nil && reset != nil])
            }
            return ["key": key, "limitId": optionalText(raw["limitId"]), "limitName": optionalText(raw["limitName"]),
                    "planType": optionalText(raw["planType"]), "windows": windows]
        }
        return ["id": "codex", "provider": "codex", "observedAt": ISO8601DateFormatter().string(from: now), "quotaAvailable": available,
                "buckets": buckets, "source": "codex app-server account/rateLimits/read", "schema": 1]
    }
}

enum CodexQuotaTransport {
    static let frameLimit = 1_048_576
    static let totalLimit = 4_194_304

    static func read(executable: String, cwd: String, environment: [String: String], timeout: Double) throws -> JSON {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw QuotaReadError("executable_unavailable") }
        let binary = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&input) == 0 else { throw QuotaReadError("transport_unavailable") }
        guard pipe(&output) == 0 else { input.forEach { Darwin.close($0) }; throw QuotaReadError("transport_unavailable") }
        guard pipe(&errors) == 0 else { (input + output).forEach { Darwin.close($0) }; throw QuotaReadError("transport_unavailable") }
        defer { [input[1], output[0], errors[0]].forEach { Darwin.close($0) } }
        for fd in input + output + errors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_addchdir_np(&actions, cwd) == 0 else {
            [input[0], output[1], errors[1]].forEach { Darwin.close($0) }; throw QuotaReadError("transport_unavailable")
        }
        for pair in [(input[0], STDIN_FILENO), (output[1], STDOUT_FILENO), (errors[1], STDERR_FILENO)] {
            posix_spawn_file_actions_adddup2(&actions, pair.0, pair.1)
        }
        for fd in input + output + errors { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)); posix_spawnattr_setpgroup(&attributes, 0)
        // Pass only runtime location settings. Vela never forwards API-key/token
        // environment variables or opens the provider's credential storage.
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME", "XDG_CONFIG_HOME"] {
            if let value = environment[key] { env[key] = value }
        }
        env["NO_COLOR"] = "1"
        let command: [String] = [binary, "app-server", "--stdio"]
        let argv = command.map { strdup($0) } + [nil]
        let envp = env.keys.sorted().map { strdup($0 + "=" + env[$0]!) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { values in
                posix_spawn(&pid, binary, &actions, &attributes, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: values.baseAddress!))
            }
        }
        [input[0], output[1], errors[1]].forEach { Darwin.close($0) }
        guard spawned == 0 else { throw QuotaReadError("executable_unavailable", code: Int(spawned)) }
        for fd in [input[1], output[0], errors[0]] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        var reaped = false
        defer {
            kill(-pid, SIGTERM)
            let deadline = Date().addingTimeInterval(0.1)
            var exitStatus: Int32 = 0
            while !reaped && Date() < deadline {
                let result = waitpid(pid, &exitStatus, WNOHANG)
                if result == pid || (result < 0 && errno != EINTR) { reaped = true; break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            kill(-pid, SIGKILL)
            if !reaped { while waitpid(pid, &exitStatus, 0) < 0 && errno == EINTR {} }
        }
        var pending = Data()
        func send(_ request: JSON) throws { pending.append(Data((try jsonString(request) + "\n").utf8)) }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "vela", "title": "Vela", "version": "0.1.0"], "capabilities": ["experimentalApi": false]]])
        var frame = Data()
        var readBytes = 0
        var errorBytes = 0
        var initialized = false
        var quotaSent = false
        let deadline = Date().addingTimeInterval(max(0.1, min(timeout, 30)))
        var bytes = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            if !pending.isEmpty {
                let written = pending.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress!, $0.count) }
                if written > 0 { pending.removeFirst(written); if pending.isEmpty && initialized { quotaSent = true } }
                else if errno != EAGAIN && errno != EINTR { throw QuotaReadError("process_exited") }
            }
            // Fairly drain both descriptors; an unbounded stderr producer cannot
            // starve the JSON response or retain a child process indefinitely.
            for fd in [errors[0], output[0]] {
                for _ in 0..<32 {
                    let count = Darwin.read(fd, &bytes, bytes.count)
                    if count <= 0 { break }
                    if fd == errors[0] {
                        errorBytes += count
                        if errorBytes > totalLimit { throw QuotaReadError("output_limit") }
                        continue
                    }
                    readBytes += count
                    guard readBytes <= totalLimit else { throw QuotaReadError("output_limit") }
                    frame.append(contentsOf: bytes.prefix(count))
                    while let end = frame.firstIndex(of: 10) {
                        let length = frame.distance(from: frame.startIndex, to: end)
                        guard length <= frameLimit else { throw QuotaReadError("frame_limit") }
                        let line = Data(frame.prefix(length)); frame.removeFirst(length + 1)
                        if line.isEmpty { continue }
                        guard let response = (try? JSONSerialization.jsonObject(with: line)) as? JSON else { throw QuotaReadError("invalid_response") }
                        if response["method"] != nil {
                            if response["id"] != nil { throw QuotaReadError("unsupported_server_request") }
                            continue
                        }
                        guard let id = usageTokenCount(response["id"]), id == 1 || id == 2 else { continue }
                        if let error = response["error"] as? JSON {
                            let text = string(error, "message").lowercased()
                            let kind = text.contains("not authenticated") || text.contains("not logged in") || text.contains("login required") ? "login_required" : text.contains("not supported") ? "unsupported_auth_or_method" : "provider_error"
                            let code = (error["code"] as? NSNumber).flatMap { number in
                                CFGetTypeID(number) == CFBooleanGetTypeID() ? nil : Int(number.stringValue)
                            }
                            throw QuotaReadError(kind, code: code)
                        }
                        guard let result = response["result"] as? JSON else { throw QuotaReadError("invalid_response") }
                        if id == 1 {
                            guard !initialized else { throw QuotaReadError("invalid_response") }
                            initialized = true
                            try send(["method": "initialized"])
                            try send(["id": 2, "method": "account/rateLimits/read"])
                        } else {
                            guard initialized && quotaSent else { throw QuotaReadError("invalid_response") }
                            return result
                        }
                    }
                    guard frame.count <= frameLimit else { throw QuotaReadError("frame_limit") }
                }
            }
            var exitStatus: Int32 = 0
            let result = waitpid(pid, &exitStatus, WNOHANG)
            if result == pid { reaped = true; throw QuotaReadError("process_exited") }
            if result < 0 && errno != EINTR { reaped = true; throw QuotaReadError("process_exited") }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw QuotaReadError("timeout")
    }
}
