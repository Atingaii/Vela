import Foundation
import Darwin

struct FoundationCommand {
    struct Result { let output: String; let code: Int32 }
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> Result {
        let process = Process(); process.executableURL = URL(fileURLWithPath:executable); process.arguments = executable == "/usr/bin/git" ? ["-c","core.fsmonitor=false","-c","core.hooksPath=/dev/null"] + arguments : arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        if executable == "/usr/bin/git" {
            environment = environment.filter { !$0.key.hasPrefix("GIT_") }; environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_CONFIG_GLOBAL"] = "/dev/null"; environment["GIT_CONFIG_NOSYSTEM"] = "1"
        }
        process.environment = environment
        let output = FoundationBuffer(); let group = DispatchGroup()
        try process.run(); group.enter()
        DispatchQueue.global(qos:.utility).async {
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                if !output.append(data,limit:2 * 1024 * 1024) { if process.isRunning { process.terminate() }; break }
            }
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval:0.02) }
        if process.isRunning { process.terminate(); throw VelaError("Local document or Git command timed out") }
        guard group.wait(timeout:.now()+2) == .success else { throw VelaError("Command output did not close") }
        if output.overflow { throw VelaError("Command output exceeded 2 MB") }
        return Result(output:String(decoding:output.data,as:UTF8.self),code:process.terminationStatus)
    }
}
private final class FoundationBuffer: @unchecked Sendable {
    private let lock = NSLock(); private var bytes = Data(); private var exceeded = false
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var overflow: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    func append(_ data: Data,limit:Int) -> Bool { lock.lock(); defer { lock.unlock() }; guard bytes.count + data.count <= limit else { exceeded = true; return false }; bytes.append(data); return true }
}
final class FoundationDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value:0)
    private var bytes = Data(); private var failure: Error?; private var mime = ""; private let lock = NSLock()
    static func fetch(_ url: URL) throws -> (Data,String) {
        let delegate = FoundationDownload(); let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20; configuration.urlCache = nil; configuration.httpCookieStorage = nil
        let session = URLSession(configuration:configuration,delegate:delegate,delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url:url); request.setValue("Vela/1.0 document import",forHTTPHeaderField:"User-Agent")
        session.dataTask(with:request).resume()
        guard delegate.semaphore.wait(timeout:.now()+22) == .success else { throw VelaError("Library URL import timed out") }
        delegate.lock.lock(); defer { delegate.lock.unlock() }
        if let failure = delegate.failure { throw failure }
        return (delegate.bytes,delegate.mime)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), response.expectedContentLength <= 2 * 1024 * 1024 else { failure = VelaError("Library URL returned an error or exceeded 2 MB"); completionHandler(.cancel); return }
        mime = response.mimeType ?? ""; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard bytes.count + data.count <= 2 * 1024 * 1024 else { failure = VelaError("Library URL exceeded the 2 MB limit"); dataTask.cancel(); return }; bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { lock.lock(); if failure == nil { failure = error }; lock.unlock(); semaphore.signal() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ["http","https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { completionHandler(nil); return }; completionHandler(request)
    }
}

/// Bounded text reads relative to verified directory descriptors. This helper
/// does not create files, initialize services, or synchronize database assets.
enum FoundationFile {
    static func readUTF8(root: URL, path: String, limit: Int = 2_097_152) throws -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator:"/").contains(where:{ $0 == "." || $0 == ".." }) else { throw VelaError("Invalid relative text path") }
        let components = path.split(separator:"/").map(String.init)
        guard components.count <= 64, let name = components.last else { throw VelaError("Text path is too deep") }
        let rootFD = Darwin.open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw VelaError("Text root is unavailable or unsafe") }
        var descriptors = [rootFD], anchors: [(Int32,String,Int32)] = []
        defer { descriptors.reversed().forEach { Darwin.close($0) } }
        var parent = rootFD
        for component in components.dropLast() {
            let next = openat(parent,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 { if errno == ENOENT { return nil }; throw VelaError("Text path contains an unsafe directory") }
            anchors.append((parent,component,next)); descriptors.append(next); parent = next
        }
        let result = try readUTF8(parent:parent,name:name,limit:limit)
        var opened = stat(), linked = stat()
        guard fstat(rootFD,&opened) == 0, lstat(root.path,&linked) == 0, opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino else { throw VelaError("Text root changed during read") }
        for (directory,component,child) in anchors {
            guard fstat(child,&opened) == 0, fstatat(directory,component,&linked,AT_SYMLINK_NOFOLLOW) == 0, linked.st_mode & S_IFMT == S_IFDIR, opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino else { throw VelaError("Text directory changed during read") }
        }
        return result
    }

    static func readUTF8(parent: Int32, name: String, limit: Int = 2_097_152) throws -> String? {
        guard let data = try readData(parent:parent,name:name,limit:limit) else { return nil }
        guard let text = String(data:data,encoding:.utf8) else { throw VelaError("Text file is not UTF-8") }
        return text
    }

    static func readData(parent: Int32, name: String, limit: Int = 2_097_152) throws -> Data? {
        guard limit > 0, limit <= 2_097_152, !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else { throw VelaError("Invalid bounded text read") }
        let descriptor = openat(parent,name,O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 { if errno == ENOENT { return nil }; throw VelaError("Refusing unsafe or unreadable text file") }
        defer { Darwin.close(descriptor) }
        var before = stat(), linked = stat()
        guard fstat(descriptor,&before) == 0, fstatat(parent,name,&linked,AT_SYMLINK_NOFOLLOW) == 0,
              before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_dev == linked.st_dev,
              before.st_ino == linked.st_ino, before.st_size >= 0, before.st_size <= limit else { throw VelaError("Text target is not a safe bounded regular file") }
        var data = Data(), buffer = [UInt8](repeating:0,count:8192)
        while true {
            let count = Darwin.read(descriptor,&buffer,buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw VelaError("Could not read bounded text") }
            guard data.count + count <= limit else { throw VelaError("Text file grew beyond its read limit") }
            data.append(contentsOf:buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor,&after) == 0, fstatat(parent,name,&linked,AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == linked.st_dev, before.st_ino == linked.st_ino, after.st_nlink == 1,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw VelaError("File changed during read") }
        return data
    }
}
