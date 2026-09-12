import Foundation

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
