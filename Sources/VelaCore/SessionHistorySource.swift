import Foundation
import Darwin

enum SessionHistorySource {
    static let chunkBytes = 64 * 1024
    static let decoderVersion = "vela-history-jsonl-v1"
    static let providers = Set(["claude", "codex", "pi", "omp", "cursor"])
    static func identity(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    /// Resolve only the already configured canonical root; reject every link below it.
    static func open(_ path: String, root: String, directory: Bool = false) throws -> (Int32, stat) {
        let parts = path.split(separator: "/").map(String.init), rootParts = root.split(separator: "/").map(String.init)
        // Foundation standardization rewrites macOS /private/var to /var. Do
        // lexical validation here; openat checks each real component itself.
        guard path == root || path.hasPrefix(root + "/"), path.utf8.count <= 4096,
              !path.contains("\0"), path == "/" + parts.joined(separator: "/"),
              root == "/" + rootParts.joined(separator: "/"), !root.contains("\0"),
              !parts.contains("."), !parts.contains(".."), !rootParts.contains("."), !rootParts.contains("..") else { throw VelaError("History source is outside its configured root") }
        // The configured root is the authorized entry point. Opening its ancestors
        // individually can require macOS access that opening the root does not.
        var beforeRoot = stat()
        guard lstat(root, &beforeRoot) == 0 else { throw unavailable("root metadata") }
        guard beforeRoot.st_mode & S_IFMT == S_IFDIR else { throw VelaError("History configured root is not a real directory") }
        let rootDescriptor = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw unavailable("configured root") }
        defer { close(rootDescriptor) }
        try verifyRoot(rootDescriptor, root: root, expected: beforeRoot)
        var descriptor = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw unavailable("root descriptor") }
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        let descendants = Array(parts.dropFirst(rootParts.count))
        for (index, component) in descendants.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | ((index < descendants.count - 1 || directory) ? O_DIRECTORY : 0)
            let next = openat(descriptor, component, flags)
            guard next >= 0 else { throw unavailable("relative source component") }
            close(descriptor); descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1, info.st_size >= 0 else {
            throw VelaError("History source is not a supported filesystem object")
        }
        try verifyRoot(rootDescriptor, root: root, expected: beforeRoot)
        transferred = true
        return (descriptor, info)
    }
    private static func unavailable(_ stage: String) -> VelaError {
        VelaError("History \(stage) could not be opened or inspected (errno \(errno))")
    }
    private static func verifyRoot(_ descriptor: Int32, root: String, expected: stat) throws {
        var held = stat(), named = stat()
        guard fstat(descriptor, &held) == 0, lstat(root, &named) == 0 else { throw unavailable("root identity") }
        guard held.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
              held.st_dev == expected.st_dev, held.st_ino == expected.st_ino,
              named.st_dev == held.st_dev, named.st_ino == held.st_ino else { throw VelaError("History configured root identity changed") }
        var physical = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &physical) == 0 else { throw unavailable("root physical path") }
        // Use the same URL spelling as canonicalProject, without resolving the
        // configured name again and thereby accepting a newly redirected root.
        guard URL(fileURLWithPath: String(cString: physical)).path == root else { throw VelaError("History configured root physical path changed") }
    }
    static func verify(_ descriptor: Int32, path: String, root: String, version: String, directory: Bool = false) throws {
        var held = stat()
        let (fresh, info) = try open(path, root: root, directory: directory); defer { close(fresh) }
        guard fstat(descriptor, &held) == 0, identity(held) == version, identity(info) == version else { throw VelaError("History source version changed") }
    }
    static func header(path: String, root: String, provider: String) throws -> JSON {
        let (descriptor, info) = try open(path, root: root); let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? file.close() }
        let bytes = try file.read(upToCount: chunkBytes) ?? Data()
        var result: JSON?
        for raw in bytes.split(separator: 10).prefix(32) {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(raw))) as? JSON else { continue }
            let type = string(row, "type")
            let value = provider == "codex" ? (row["payload"] as? JSON ?? [:]) : row
            if ["pi", "omp"].contains(provider) {
                if type == "title", provider == "omp" { continue }
                guard type == "session", let version = row["version"].flatMap({ usageTokenCount($0) }) ?? (row["version"] == nil ? 1 : nil), (1...3).contains(version), !string(row, "id").isEmpty else { throw VelaError("Unsupported Pi/OMP history header") }
                result = ["sourceFormatVersion": version, "sourceSessionId": string(row, "id"), "project": string(row, "cwd"), "headerType": "session"]
                break
            }
            if provider == "codex", type != "session_meta" { continue }
            let cwd = string(value, "cwd", string(value, "projectPath"))
            if cwd.hasPrefix("/") {
                result = ["sourceFormatVersion": provider == "codex" ? "session_meta/response_item/event_msg" : "message/result", "sourceSessionId": string(value, provider == "codex" ? "id" : "sessionId"), "project": cwd, "headerType": type]
                break
            }
        }
        guard var result, string(result, "project").hasPrefix("/") else { throw VelaError("History source project/header is unavailable in the bounded probe") }
        result["project"] = canonicalProject(string(result, "project"))
        result["sourceVersion"] = identity(info); result["sourceBytes"] = Int(info.st_size)
        result["decoderVersion"] = decoderVersion
        try verify(descriptor, path: path, root: root, version: identity(info))
        return result
    }
    /// A bounded-memory lexical page. Reopening uses names, never stale readdir cookies.
    static func directoryPage(path: String, root: String, after: String, limit: Int) throws -> (names: [String], more: Bool, version: String) {
        let (descriptor, info) = try open(path, root: root, directory: true)
        guard let directory = fdopendir(descriptor) else { close(descriptor); throw VelaError("History directory cannot be read") }
        defer { closedir(directory) }
        var names: [String] = [], count = 0
        errno = 0
        while let item = readdir(directory) {
            count += 1
            guard count <= 100_000 else { throw VelaError("History directory exceeds the explicit 100,000-entry traversal budget") }
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
            guard name != ".", name != "..", name > after else { continue }
            names.append(name); names.sort()
            if names.count > limit + 1 { names.removeLast() }
        }
        guard errno == 0 else { throw VelaError("History directory traversal failed") }
        try verify(dirfd(directory), path: path, root: root, version: identity(info), directory: true)
        return (Array(names.prefix(limit)), names.count > limit, identity(info))
    }
}
