import XCTest
@testable import VelaCore

final class ConnectorTransportTests: XCTestCase {
    private final class FixtureProtocol: URLProtocol {
        static let lock = NSLock()
        static var requests: [URLRequest] = []
        static var status = 200
        static var bytes = Data("{\"items\":[]}".utf8)
        static var declaredLength: Int?
        static var headers: [String:String] = [:]
        static var stalls = false
        static func reset(status: Int = 200, bytes: Data = Data("{\"items\":[]}".utf8), declaredLength: Int? = nil, headers: [String:String] = [:], stalls: Bool = false) {
            lock.lock(); defer { lock.unlock() }
            requests = []; self.status = status; self.bytes = bytes; self.declaredLength = declaredLength; self.headers = headers; self.stalls = stalls
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock()
            Self.requests.append(request)
            let status = Self.status, bytes = Self.bytes, length = Self.declaredLength, stalls = Self.stalls
            var headers = Self.headers
            Self.lock.unlock()
            if stalls { return }
            if let length { headers["Content-Length"] = String(length) }
            let response = HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            // Small chunks exercise both declared and incremental byte bounds.
            for offset in stride(from:0,to:bytes.count,by:65_536) {
                client?.urlProtocol(self,didLoad:bytes.subdata(in:offset..<min(bytes.count,offset+65_536)))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private func transport() -> ComposioTransport { ComposioTransport(timeout:1,protocolClasses:[FixtureProtocol.self]) }

    func testTransportEncodesFrozenRequestWithoutRedirectOrCredentialInURL() throws {
        FixtureProtocol.reset()
        let result = try transport().send(ConnectorRequest(method:"POST",path:"/tools/execute/FIXTURE",query:["cursor":"cursor+/= &中文"],body:["arguments":["literal":"$(never execute)"],"version":"fixed_v1"]),key:"synthetic-transport-key")
        XCTAssertNotNil(result["items"])
        let request = try XCTUnwrap(FixtureProtocol.requests.first)
        XCTAssertEqual(FixtureProtocol.requests.count,1)
        XCTAssertEqual(request.url?.host,"backend.composio.dev")
        XCTAssertEqual(request.url?.path,"/api/v3.1/tools/execute/FIXTURE")
        XCTAssertEqual(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first?.value,"cursor+/= &中文")
        XCTAssertEqual(request.value(forHTTPHeaderField:"x-api-key"),"synthetic-transport-key")
        XCTAssertFalse(request.url!.absoluteString.contains("synthetic-transport-key"))
        XCTAssertEqual(request.httpMethod,"POST")
    }

    func testTransportRejectsUnsafeBoundariesBeforeStartingARequest() throws {
        FixtureProtocol.reset()
        for path in ["https://attacker.invalid", "/../tools", "/tools?key=value", "/tools/%2e%2e/"] {
            XCTAssertThrowsError(try transport().send(ConnectorRequest(method:"GET",path:path),key:"synthetic-key"))
        }
        XCTAssertThrowsError(try transport().send(ConnectorRequest(method:"GET",path:"/tools"),key:"synthetic-key\r\nInjected: value"))
        XCTAssertThrowsError(try transport().send(ConnectorRequest(method:"POST",path:"/tools",body:["oversized":String(repeating:"x",count:1_048_576)]),key:"synthetic-key"))
        XCTAssertTrue(FixtureProtocol.requests.isEmpty)
    }

    func testTransportRejectsBoundedResponsesAndRetainsMutationUncertainty() throws {
        for declared in [nil,4_194_305] as [Int?] {
            FixtureProtocol.reset(bytes:Data(repeating:120,count:4_194_305),declaredLength:declared)
            do {
                _ = try transport().send(ConnectorRequest(method:"POST",path:"/tools"),key:"synthetic-key")
                XCTFail("Oversized response was accepted")
            } catch {
                XCTAssertEqual((error as? ConnectorHTTPError)?.outcomeUnknown,true)
                XCTAssertFalse(error.localizedDescription.contains("synthetic-key"))
            }
            XCTAssertEqual(FixtureProtocol.requests.count,1)
        }
    }

    func testTransportNeverRetriesRedirectFailuresOrTimeouts() throws {
        for status in [302,401,403,408,422,429,500,503] {
            FixtureProtocol.reset(status:status,bytes:Data("provider error PRIVATE_BODY".utf8),headers:["Location":"https://attacker.invalid/collect","Retry-After":"1"])
            do {
                _ = try transport().send(ConnectorRequest(method:"POST",path:"/tools"),key:"synthetic-key")
                XCTFail("HTTP failure was accepted")
            } catch {
                XCTAssertEqual((error as? ConnectorHTTPError)?.status,status)
                XCTAssertEqual((error as? ConnectorHTTPError)?.outcomeUnknown,![401,403].contains(status))
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE_BODY"))
            }
            XCTAssertEqual(FixtureProtocol.requests.count,1)
        }
        FixtureProtocol.reset(stalls:true)
        let started = Date()
        do {
            _ = try transport().send(ConnectorRequest(method:"POST",path:"/tools"),key:"synthetic-key")
            XCTFail("Stalled request was accepted")
        } catch { XCTAssertEqual((error as? ConnectorHTTPError)?.outcomeUnknown,true) }
        XCTAssertLessThan(Date().timeIntervalSince(started),4)
        XCTAssertEqual(FixtureProtocol.requests.count,1)
    }
}
