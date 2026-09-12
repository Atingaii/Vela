import Foundation
import Darwin

/// Journaled multi-file replacement. Paths are opened relative to verified directory descriptors.
/// Each rename is atomic; interrupted multi-file transactions are recovered from the durable journal.
public final class SafeApplyService {
    private let store: VelaStore
    private let lock = NSRecursiveLock()
    private var transactionFD: Int32 = -1
    private var transactionDepth = 0
    public init(store: VelaStore) { self.store = store }

    public func preview(project: String, operations: [JSON]) throws -> [JSON] {
        lock.lock(); defer { lock.unlock() }
        return try prepare(project: project, operations: operations, createParents: false).map { target in
            defer { target.close() }
            return target.record
        }
    }

    @discardableResult public func apply(project: String, operations: [JSON]) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        _ = try acquireTransactionLock(); defer { releaseTransactionLock() }
        let targets = try prepare(project: project, operations: operations, createParents: true)
        defer { targets.forEach { $0.close() } }
        var journal: JSON = ["title": "Configuration transaction", "project": project, "state": "prepared", "operations": targets.map(\.record)]
        journal = try store.put("apply_journal", journal)
        do {
            for target in targets { try target.stage() }
            // Recheck the entire batch after staging, before changing any target.
            for target in targets { try target.verifyOriginal() }
            journal["state"] = "committing"; journal = try store.put("apply_journal", journal)
            for target in targets {
                try target.commit()
            }
            journal["state"] = "applied"
            journal["completedAt"] = isoNow()
            return try store.put("apply_journal", journal)
        } catch {
            var rollbackErrors: [String] = []
            for target in targets.reversed() where target.didMutate {
                do { try target.rollback() } catch { rollbackErrors.append(error.localizedDescription) }
            }
            journal["state"] = rollbackErrors.isEmpty ? "rolled_back" : "needs_review"
            journal["error"] = error.localizedDescription
            journal["rollbackErrors"] = rollbackErrors
            _ = try? store.put("apply_journal", journal)
            if !rollbackErrors.isEmpty { throw VelaError("Apply failed and rollback needs review: \(rollbackErrors.joined(separator: "; "))") }
            throw error
        }
    }

    @discardableResult public func undo(journalID: String) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        _ = try acquireTransactionLock(); defer { releaseTransactionLock() }
        guard var prior = try store.get("apply_journal", journalID), string(prior,"state") == "applied" else { throw VelaError("No applied transaction is available to undo") }
        let operations = (prior["operations"] as? [JSON] ?? []).map { operation -> JSON in
            var result: JSON = ["path": string(operation,"path"), "baseHash": string(operation,"afterHash")]
            if operation["before"] is NSNull { result["delete"] = true; result["content"] = "" }
            else { result["content"] = string(operation,"before") }
            return result
        }
        let undo = try apply(project: string(prior,"project"), operations: operations)
        prior["state"] = "undone"; prior["undoJournalId"] = undo["id"]
        _ = try store.put("apply_journal", prior)
        return undo
    }

    public func recoverInterrupted() throws {
        lock.lock(); defer { lock.unlock() }
        guard try acquireTransactionLock(nonblocking:true) else { return }
        defer { releaseTransactionLock() }
        for var journal in try store.list("apply_journal", limit: 1000) where ["prepared","committing"].contains(string(journal,"state")) {
            do {
                let project = try requireString(journal,"project")
                var reverse: [JSON] = []
                for entry in journal["operations"] as? [JSON] ?? [] {
                    let target = try SafeTarget(project: project, operation: ["path": string(entry,"path"), "baseHash": string(entry,"afterHash"), "content": ""], createParents: false, verifyBase: false)
                    defer { target.close() }
                    let current = try target.current()
                    let currentHash = current.map(stableHash) ?? "absent"
                    try target.cleanupStaging(string(entry,"stageName"),expectedHash:string(entry,"afterHash"))
                    if currentHash == string(entry,"beforeHash") { continue }
                    guard currentHash == string(entry,"afterHash") else { throw VelaError("Interrupted apply target was changed; manual review is required") }
                    var operation: JSON = ["path": string(entry,"path"), "baseHash": currentHash, "content": string(entry,"before")]
                    if entry["before"] is NSNull { operation["delete"] = true }
                    reverse.append(operation)
                }
                if !reverse.isEmpty { _ = try apply(project: project, operations: reverse) }
                journal["state"] = "recovered"
            } catch { journal["state"] = "needs_review"; journal["error"] = error.localizedDescription }
            _ = try store.put("apply_journal", journal)
        }
    }

    private func acquireTransactionLock(nonblocking: Bool = false) throws -> Bool {
        if transactionDepth > 0 { transactionDepth += 1; return true }
        let path = store.root.appendingPathComponent("apply.lock").path
        let fd = Darwin.open(path,O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw VelaError("Cannot open configuration transaction lock safely") }
        var info = stat()
        guard fstat(fd,&info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { Darwin.close(fd); throw VelaError("Unsafe configuration transaction lock") }
        if flock(fd,LOCK_EX | (nonblocking ? LOCK_NB : 0)) != 0 {
            let busy = errno == EWOULDBLOCK; Darwin.close(fd)
            if nonblocking && busy { return false }
            throw VelaError("Cannot acquire configuration transaction lock")
        }
        transactionFD = fd; transactionDepth = 1
        return true
    }
    private func releaseTransactionLock() {
        transactionDepth -= 1
        if transactionDepth == 0, transactionFD >= 0 { _ = flock(transactionFD,LOCK_UN); Darwin.close(transactionFD); transactionFD = -1 }
    }

    private func prepare(project: String, operations: [JSON], createParents: Bool) throws -> [SafeTarget] {
        guard !operations.isEmpty, operations.count <= 32 else { throw VelaError("Apply requires 1–32 operations") }
        var result: [SafeTarget] = []
        var seen = Set<String>()
        do {
            for operation in operations {
                let target = try SafeTarget(project: project, operation: operation, createParents: createParents)
                guard seen.insert(target.path).inserted else { target.close(); throw VelaError("Duplicate operation path") }
                result.append(target)
            }
            return result
        } catch { result.forEach { $0.close() }; throw error }
    }
}

private final class SafeTarget {
    let path: String
    let before: String?
    let content: String
    let delete: Bool
    let baseHash: String
    private let rootPath: String
    private var descriptors: [Int32] = []
    private var anchors: [(Int32, String, Int32)] = []
    private var parent: Int32 = -1
    private let filename: String
    private var staged: String?
    private let stagingName = ".vela-stage-" + UUID().uuidString.lowercased()
    private var mode: mode_t = 0o600
    private var createdParents: [(Int32, String)] = []
    private(set) var didMutate = false

    var record: JSON {
        ["path": path, "before": before as Any? ?? NSNull(), "beforeHash": before.map(stableHash) ?? "absent", "content": content, "afterHash": delete ? "absent" : stableHash(content), "delete": delete, "stageName":stagingName]
    }

    init(project: String, operation: JSON, createParents: Bool, verifyBase: Bool = true) throws {
        let raw = try requireString(operation,"path")
        guard project.hasPrefix("/"), !raw.contains("\0"), raw.utf8.count < 4096 else { throw VelaError("Invalid apply path") }
        rootPath = canonicalProject(project)
        let normalized = automationPath(raw,project:rootPath)
        guard normalized.hasPrefix(rootPath + "/"), !raw.split(separator:"/").contains("..") else { throw VelaError("Path is outside the allowed project") }
        let relative = String(normalized.dropFirst(rootPath.count + 1))
        let components = relative.split(separator:"/").map(String.init)
        guard !components.isEmpty, !components.contains(".git"), !components.contains(where: {$0 == ".env" || $0.hasPrefix(".env.")}) else { throw VelaError("Protected target path") }
        path = normalized; filename = components.last!
        content = operation["content"] as? String ?? ""
        delete = operation["delete"] as? Bool == true
        guard content.utf8.count <= 2_097_152 else { throw VelaError("File content exceeds 2 MiB") }
        baseHash = try requireString(operation,"baseHash")
        guard baseHash == "absent" || baseHash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else { throw VelaError("Invalid or missing base hash") }
        var old: String?
        do {
            let rootFD = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw VelaError("Cannot open project root safely") }
            descriptors.append(rootFD); parent = rootFD
            for component in components.dropLast() {
                var next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, createParents {
                    let made = mkdirat(parent, component, 0o700)
                    guard made == 0 || errno == EEXIST else { throw VelaError("Cannot create target parent") }
                    if made == 0 { createdParents.append((parent,component)) }
                    next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                if next < 0, errno == ENOENT, !createParents { parent = -1; break }
                guard next >= 0 else { throw VelaError("Target parent is missing, inaccessible, or a symlink") }
                descriptors.append(next); anchors.append((parent,component,next)); parent = next
            }
            old = parent < 0 ? nil : try Self.read(parent: parent, name: filename)
            if let old { guard old.utf8.count <= 2_097_152 else { throw VelaError("Existing target exceeds 2 MiB") } }
            if verifyBase, (old.map(stableHash) ?? "absent") != baseHash { throw VelaError("Base hash mismatch; review the current file before applying") }
            var info = stat()
            if parent >= 0, fstatat(parent, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 { mode = info.st_mode & 0o777 }
        } catch {
            for (fd,name) in createdParents.reversed() { _ = unlinkat(fd,name,AT_REMOVEDIR) }; createdParents = []
            for fd in descriptors { Darwin.close(fd) }; descriptors = []
            throw error
        }
        before = old
    }

    func current() throws -> String? { try verifyAnchors(); return parent < 0 ? nil : try Self.read(parent: parent, name: filename) }
    func verifyOriginal() throws {
        guard (try current()).map(stableHash) ?? "absent" == baseHash else { throw VelaError("Target changed during apply") }
    }
    private func verifyAnchors() throws {
        guard let root = descriptors.first else { throw VelaError("Closed apply target") }
        var opened = stat(); var linked = stat()
        guard fstat(root,&opened) == 0, lstat(rootPath,&linked) == 0, opened.st_ino == linked.st_ino, opened.st_dev == linked.st_dev else { throw VelaError("Project path changed during apply") }
        for (parent,name,child) in anchors {
            guard fstat(child,&opened) == 0, fstatat(parent,name,&linked,AT_SYMLINK_NOFOLLOW) == 0, (linked.st_mode & S_IFMT) == S_IFDIR, opened.st_ino == linked.st_ino, opened.st_dev == linked.st_dev else { throw VelaError("Target path changed during apply") }
        }
    }
    private static func read(parent: Int32, name: String) throws -> String? {
        let fd = openat(parent,name,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw VelaError("Refusing unsafe or unreadable target") }
        defer { Darwin.close(fd) }
        var opened = stat(); var linked = stat()
        guard fstat(fd,&opened) == 0, fstatat(parent,name,&linked,AT_SYMLINK_NOFOLLOW) == 0, (opened.st_mode & S_IFMT) == S_IFREG, opened.st_nlink == 1, opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino, opened.st_size <= 2_097_152 else { throw VelaError("Target is not a safe bounded regular file") }
        var data = Data(); var buffer = [UInt8](repeating:0,count:8192)
        while true {
            let size = Darwin.read(fd,&buffer,buffer.count)
            if size == 0 { break }; if size < 0 { throw VelaError("Could not read target") }
            data.append(contentsOf: buffer.prefix(size))
            if data.count > 2_097_152 { throw VelaError("Target grew beyond file limit") }
        }
        guard let text = String(data:data,encoding:.utf8) else { throw VelaError("Only UTF-8 text targets are supported") }
        return text
    }
    func stage() throws {
        try verifyAnchors()
        if delete { return }
        staged = try writeStage(content,name:stagingName)
    }
    private func writeStage(_ text: String, name: String = ".vela-stage-" + UUID().uuidString.lowercased()) throws -> String {
        let fd = openat(parent,name,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,mode)
        guard fd >= 0 else { throw VelaError("Could not create safe staging file") }
        defer { Darwin.close(fd) }
        do {
            try Data(text.utf8).withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                    guard written > 0 else { throw VelaError("Could not write staging file") }; offset += written
                }
            }
            guard fsync(fd) == 0 else { throw VelaError("Could not flush staging file") }
            return name
        } catch { _ = unlinkat(parent,name,0); throw error }
    }
    func cleanupStaging(_ name: String, expectedHash: String) throws {
        guard !name.isEmpty, parent >= 0 else { return }
        guard name.range(of:"^\\.vela-stage-[a-f0-9-]{36}$",options:.regularExpression) != nil else { throw VelaError("Invalid journal staging identity") }
        try verifyAnchors()
        var info = stat()
        if fstatat(parent,name,&info,AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return }; throw VelaError("Cannot inspect interrupted staging file") }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw VelaError("Interrupted staging file changed identity") }
        guard let content = try Self.read(parent:parent,name:name), stableHash(content) == expectedHash else { throw VelaError("Interrupted staging content changed; retained for review") }
        guard unlinkat(parent,name,0) == 0 else { throw VelaError("Cannot remove interrupted staging file") }
    }
    func commit() throws {
        try verifyOriginal()
        if delete {
            guard unlinkat(parent,filename,0) == 0 || errno == ENOENT else { throw VelaError("Could not remove target") }
        } else {
            guard let staged, renameat(parent,staged,parent,filename) == 0 else { throw VelaError("Could not atomically replace target") }
            self.staged = nil
        }
        didMutate = true
        guard fsync(parent) == 0 else { throw VelaError("Could not flush target directory") }
    }
    func rollback() throws {
        try verifyAnchors()
        let expected = delete ? "absent" : stableHash(content)
        guard (try current()).map(stableHash) ?? "absent" == expected else { throw VelaError("Rollback target changed; manual review required") }
        if let before {
            let name = try writeStage(before)
            guard renameat(parent,name,parent,filename) == 0 else { _ = unlinkat(parent,name,0); throw VelaError("Could not restore original file") }
        } else if unlinkat(parent,filename,0) != 0 && errno != ENOENT { throw VelaError("Could not remove newly created file") }
        guard fsync(parent) == 0 else { throw VelaError("Could not flush rollback") }
        didMutate = false
    }
    func close() {
        if let staged, parent >= 0 { _ = unlinkat(parent,staged,0) }; staged = nil
        for (fd,name) in createdParents.reversed() { _ = unlinkat(fd,name,AT_REMOVEDIR) }; createdParents = []
        descriptors.reversed().forEach { Darwin.close($0) }; descriptors = []; parent = -1
    }
    deinit { close() }
}
