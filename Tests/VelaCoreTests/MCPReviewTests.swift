import Foundation
import XCTest
@testable import VelaCore

/// Independent regressions for issues reproduced through the public MCP handler.
/// Every source and credential marker is synthetic and belongs to an isolated store.
final class MCPReviewTests: XCTestCase {
    private func withServer(_ body: (VelaStore, String, MCPTools) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vela-mcp-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = canonicalProject(directory.path)
        let store = try VelaStore(root: root.appendingPathComponent("store"))
        try store.put("project", ["id": stableHash(project), "path": project, "title": "Synthetic review project"])
        let server = MCPTools(store: store, contribute: false, serverVersion: "independent-review", coreCall: { _, _ in
            throw VelaError("This read-only fixture must not dispatch a downstream operation")
        })
        let initialized = try XCTUnwrap(server.handle(request: ["jsonrpc": "2.0", "id": "initialize", "method": "initialize", "params": [
            "protocolVersion": "2025-11-25", "capabilities": JSON(), "clientInfo": ["name": "independent-review", "version": "1"]
        ]]))
        XCTAssertNil(initialized["error"])
        XCTAssertNil(server.handle(request: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        try body(store, project, server)
    }

    private func call(_ server: MCPTools, _ name: String, _ arguments: JSON) throws -> JSON {
        let response = try XCTUnwrap(server.handle(request: ["jsonrpc": "2.0", "id": UUID().uuidString, "method": "tools/call", "params": ["name": name, "arguments": arguments]]))
        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? JSON)
        XCTAssertEqual(result["isError"] as? Bool, false)
        return try XCTUnwrap(result["structuredContent"] as? JSON)
    }

    func testPagedMemoryCannotReconstructCredentialRedactedByWholeRead() throws {
        try withServer { store, project, server in
            let credential = "sk-abcdefghijklmnopqrstuvwx"
            let original = "前👩🏽‍💻e\u{301} " + credential + " 后"
            try store.put("memory", ["id": "synthetic-secret", "project": project, "private": false, "scope": "project", "state": "active", "title": "Synthetic credential fixture", "content": original])
            let full = try call(server, "vela_memory_get", ["project": project, "id": "synthetic-secret", "maxCharacters": 100])
            let visible = try XCTUnwrap(full["content"] as? String)
            XCTAssertEqual(full["contentRedacted"] as? Bool, true)
            XCTAssertFalse(visible.contains(credential))
            XCTAssertTrue(visible.contains("👩🏽‍💻e\u{301}"))

            var offset = 0, assembled = ""
            for _ in 0..<20 {
                var arguments: JSON = ["project": project, "id": "synthetic-secret", "maxCharacters": 10, "offset": offset]
                if offset > 0 { arguments["sourceHash"] = full["sourceHash"] }
                let page = try call(server, "vela_memory_get", arguments)
                assembled += try XCTUnwrap(page["content"] as? String)
                XCTAssertEqual(page["offsetUnit"] as? String, "extended_grapheme_clusters")
                XCTAssertEqual(page["contentCharacters"] as? Int, visible.count)
                XCTAssertEqual(page["contentRedacted"] as? Bool, true)
                guard let next = page["nextOffset"] as? Int else { break }
                XCTAssertGreaterThan(next, offset)
                offset = next
            }
            XCTAssertEqual(assembled, visible)
            XCTAssertFalse(assembled.contains(credential))
        }
    }

    func testPublicLibrarySummaryDoesNotExposeCredentialInURLQuery() throws {
        try withServer { store, project, server in
            let credential = "sk-abcdefghijklmnopqrstuvwx"
            try store.put("library", ["id": "public-url", "project": project, "private": false, "scope": "project", "state": "active", "title": "Public URL fixture", "content": "Harmless public synthetic documentation.", "sourceURL": "https://example.invalid/docs?api_key=" + credential])
            let result = try call(server, "vela_library_list", ["project": project])
            let items = try XCTUnwrap(result["items"] as? [JSON])
            XCTAssertEqual(items.count, 1)
            XCTAssertFalse(try jsonString(result).contains(credential))
            XCTAssertEqual(items.first?["sourceURLRedacted"] as? Bool, true)
        }
    }
}
