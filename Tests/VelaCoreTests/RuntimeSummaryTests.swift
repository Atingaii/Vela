import Foundation
import XCTest
@testable import VelaCore

final class RuntimeSummaryTests: XCTestCase {
    func testRejectedAndUncertainApprovalsCannotLookPendingInTheRuntimeList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-runtime-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = try VelaStore(root:directory)
        for kind in ["agent_loop","knowledge_query"] {
            let approvalID = kind + "-approval"
            _ = try store.put(kind,["id":"runtime","project":"/synthetic","state":"pending_approval","approvalId":approvalID])
            _ = try store.put("approval",["id":approvalID,"project":"/synthetic","state":"rejected"])
            XCTAssertEqual(string(try XCTUnwrap(store.runtimeSummaries(kind,project:"/synthetic").first),"state"),"rejected")
            _ = try store.put("approval",["id":approvalID,"project":"/synthetic","state":"needs_review"])
            XCTAssertEqual(string(try XCTUnwrap(store.runtimeSummaries(kind,project:"/synthetic").first),"state"),kind == "agent_loop" ? "needs_review" : "executing_or_uncertain")
        }
    }
    func testRuntimeListsSelectOnlyBoundedMetadataAndRespectScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-runtime-summary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = try VelaStore(root:directory)
        let payload = String(repeating:"SYNTHETIC_PROVIDER_TRANSCRIPT",count:20_000)
        for kind in ["agent_loop","knowledge_query"] {
            for index in 0..<4 {
                _ = try store.put(kind,["id":"summary-" + String(index),"project":index == 3 ? "/foreign" : "/synthetic","title":"A bounded title","state":"completed","modelCalls":2,"request":["content":payload],"rounds":[["raw":payload]],"result":["answer":payload],"error":String(repeating:"x",count:2000)])
            }
            let rows = try store.runtimeSummaries(kind,project:"/synthetic",limit:2)
            XCTAssertEqual(rows.count,2)
            let encoded = try jsonString(rows)
            XCTAssertFalse(encoded.contains("SYNTHETIC_PROVIDER_TRANSCRIPT")); XCTAssertFalse(encoded.contains("/foreign"))
            XCTAssertLessThan(encoded.utf8.count,3000)
            XCTAssertEqual(intValue(rows[0],"modelCalls"),2)
            XCTAssertEqual(string(rows[0],"error").count,512)
        }
        XCTAssertThrowsError(try store.runtimeSummaries("library",project:"/synthetic"))
        XCTAssertThrowsError(try store.runtimeSummaries("agent_loop",project:"/synthetic",limit:101))
    }
}
