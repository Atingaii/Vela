import Foundation
import Security

protocol ConnectorCredentialVault {
    func create(_ secret: String, generation: String) throws
    func read(generation: String) throws -> String
    func remove(generation: String) throws
}

/// Secrets are referenced by a random generation, never stored in SQLite,
/// Markdown, workflow snapshots or an exported archive.
final class ConnectorKeychain: ConnectorCredentialVault {
    private let service: String
    init(root: URL) { service = "ai.vela.composio." + stableHash(root.path) }
    private func query(_ generation: String) throws -> [String: Any] {
        guard UUID(uuidString:generation) != nil else { throw VelaError("Invalid connector credential identity") }
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:generation,kSecAttrSynchronizable as String:false]
    }
    func create(_ secret: String, generation: String) throws {
        var item = try query(generation)
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Vela · Composio project key"
        let status = SecItemAdd(item as CFDictionary,nil)
        guard status == errSecSuccess else { throw VelaError("Keychain could not save this connector credential (\(status))") }
    }
    func read(generation: String) throws -> String {
        var item = try query(generation); item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary,&result)
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data:data,encoding:.utf8) else { throw VelaError("Connector credential is unavailable in Keychain (\(status)); reconnect explicitly") }
        return secret
    }
    func remove(generation: String) throws {
        let status = SecItemDelete(try query(generation) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VelaError("Keychain could not remove this connector credential (\(status))") }
    }
}

struct ConnectorRequest {
    let method: String
    let path: String
    var query: [String:String] = [:]
    var body: JSON? = nil
}

struct ConnectorHTTPError: Error, LocalizedError {
    let status: Int
    let outcomeUnknown: Bool
    let retryAfter: String?
    var errorDescription: String? {
        switch status {
        case 401: return "Composio rejected the project key; reconnect explicitly"
        case 403: return "Composio denied this permission; check the project key's access"
        case 429: return "Composio rate limit reached; this request was not retried"
        case 0: return outcomeUnknown ? "Connector transport ended with an unknown action outcome; inspect the provider before retrying" : "Connector transport failed; no automatic retry was attempted"
        default: return "Composio returned HTTP \(status); no automatic retry was attempted"
        }
    }
}

protocol ConnectorTransport {
    func send(_ request: ConnectorRequest, key: String) throws -> JSON
}

/// Fresh ephemeral session per bounded request: no cookies, disk cache, redirects
/// or arbitrary endpoints. Provider response bodies are never included in errors.
final class ComposioTransport: ConnectorTransport {
    static let baseURL = "https://backend.composio.dev/api/v3.1"
    let timeout: TimeInterval
    private let protocolClasses: [AnyClass]?
    init(timeout: TimeInterval = 30, protocolClasses: [AnyClass]? = nil) {
        self.timeout = max(1,min(timeout,60)); self.protocolClasses = protocolClasses
    }
    func send(_ request: ConnectorRequest, key: String) throws -> JSON {
        guard ["GET","POST","PATCH","DELETE"].contains(request.method),
              request.path.hasPrefix("/"), !request.path.contains(".."), !request.path.contains("?"),
              request.path.range(of:"^/[A-Za-z0-9_/-]+$",options:.regularExpression) != nil,
              !key.isEmpty, key.utf8.count <= 4096,
              key.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) else { throw VelaError("Invalid connector request boundary") }
        var components = URLComponents(string:Self.baseURL + request.path)!
        components.queryItems = request.query.keys.sorted().map { URLQueryItem(name:$0,value:request.query[$0]) }
        guard let url = components.url, url.host == "backend.composio.dev", url.scheme == "https" else { throw VelaError("Invalid connector endpoint") }
        var network = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:timeout)
        network.httpMethod = request.method
        network.setValue(key,forHTTPHeaderField:"x-api-key")
        network.setValue("application/json",forHTTPHeaderField:"Accept")
        network.setValue("Vela/0.1 Composio-REST-v3.1",forHTTPHeaderField:"User-Agent")
        if let body = request.body {
            let data = Data(try jsonString(body).utf8)
            guard data.count <= 1_048_576 else { throw VelaError("Connector request exceeds 1 MiB") }
            network.httpBody = data; network.setValue("application/json",forHTTPHeaderField:"Content-Type")
        }
        let receiver = ConnectorResponseBuffer(limit:4_194_304)
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.httpCookieStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration:config,delegate:receiver,delegateQueue:queue)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with:network); task.resume()
        guard receiver.done.wait(timeout:.now()+timeout+1) == .success else {
            task.cancel(); throw ConnectorHTTPError(status:0,outcomeUnknown:request.method != "GET",retryAfter:nil)
        }
        let result = receiver.result()
        guard result.error == nil, let response = result.response else { throw ConnectorHTTPError(status:0,outcomeUnknown:request.method != "GET",retryAfter:nil) }
        guard (200..<300).contains(response.statusCode) else {
            // Only explicit authentication/permission rejection proves the
            // request did not reach a tool. Other HTTP failures can originate
            // after partial side effects inside the upstream integration.
            throw ConnectorHTTPError(status:response.statusCode,outcomeUnknown:request.method != "GET" && ![401,403].contains(response.statusCode),retryAfter:response.value(forHTTPHeaderField:"Retry-After"))
        }
        if response.statusCode == 204 || result.data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with:result.data) as? JSON else { throw VelaError("Composio returned an invalid object; an action may already have occurred") }
        return object
    }
}

private final class ConnectorResponseBuffer: NSObject, URLSessionDataDelegate {
    let done = DispatchSemaphore(value:0)
    private let limit: Int
    private let lock = NSLock()
    private var data = Data(), response: HTTPURLResponse?, failure: Error?
    init(limit: Int) { self.limit = limit }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); self.response = response as? HTTPURLResponse
        let oversized = response.expectedContentLength > Int64(limit)
        if oversized { failure = VelaError("Connector response limit exceeded") }
        lock.unlock(); completionHandler(oversized ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive received: Data) {
        lock.lock(); let oversized = received.count > limit - data.count
        if oversized { failure = VelaError("Connector response limit exceeded") } else { data.append(received) }
        lock.unlock(); if oversized { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); if failure == nil { failure = error }; lock.unlock(); done.signal()
    }
    func result() -> (data:Data,response:HTTPURLResponse?,error:Error?) {
        lock.lock(); defer { lock.unlock() }; return (data,response,failure)
    }
}
