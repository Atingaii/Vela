import Foundation
import XCTest
@testable import VelaCore

final class UsageIntegrityTests: XCTestCase {
    private func fixture(_ body: (URL,URL,VelaStore,FoundationService) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vela-usage-integrity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let logs = base.appendingPathComponent("sources"), project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        for provider in ["claude","codex"] { try FileManager.default.createDirectory(at:logs.appendingPathComponent(provider),withIntermediateDirectories:true) }
        let store = try VelaStore(root:base.appendingPathComponent("store"))
        let service = FoundationService(store:store,sourceRoots:["claude":[logs.appendingPathComponent("claude")],"codex":[logs.appendingPathComponent("codex")]],globalHome:base)
        try body(logs,project,store,service)
    }
    private func claude(_ id: String, project: URL, usage: JSON? = nil) -> JSON {
        var message: JSON = ["id":id,"role":"assistant","content":"Synthetic assistant evidence"]
        if let usage { message["usage"] = usage }
        return ["type":"assistant","uuid":id,"sessionId":id,"cwd":project.path,"timestamp":"2026-09-12T00:00:00Z","message":message]
    }
    private func codex(_ usage: JSON, project: URL) -> [JSON] {
        [["type":"session_meta","timestamp":"2026-09-12T00:00:00Z","payload":["id":"synthetic-codex","cwd":project.path]],
         ["type":"event_msg","timestamp":"2026-09-12T00:00:00Z","payload":["type":"token_count","info":["total_token_usage":usage]]]]
    }
    private func write(_ file: URL, _ rows: [JSON], append: Bool = false) throws {
        let data = Data((try rows.map { try jsonString($0) }.joined(separator:"\n") + "\n").utf8)
        if append {
            let handle = try FileHandle(forWritingTo:file); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf:data)
        } else { try data.write(to:file) }
    }
    private func object(_ service: FoundationService, _ method: String, _ params: JSON = [:]) throws -> JSON {
        try XCTUnwrap(service.handle(method,params) as? JSON)
    }
    private func sessions(_ service: FoundationService) throws -> [JSON] { try XCTUnwrap(service.handle("sessions.list",[:]) as? [JSON]) }

    func testMissingProviderUsageRemainsUnavailableAtEveryAggregationLevel() throws {
        try fixture { logs,project,_,service in
            try write(logs.appendingPathComponent("claude/missing.jsonl"),[claude("missing",project:project)])
            _ = try object(service,"sessions.refresh")
            let session = try XCTUnwrap(sessions(service).first)
            XCTAssertTrue(session["tokenInput"] is NSNull); XCTAssertTrue(session["tokenOutput"] is NSNull)
            XCTAssertEqual(session["usageStatus"] as? String,"unavailable")
            let usage = try object(service,"usage.get")
            let provider = try XCTUnwrap((usage["providers"] as? [JSON])?.first)
            let day = try XCTUnwrap((usage["daily"] as? [JSON])?.first)
            for bucket in [usage,provider,day] {
                XCTAssertTrue(bucket["totalTokens"] is NSNull); XCTAssertTrue(bucket["observedTotalTokens"] is NSNull)
                XCTAssertEqual(bucket["coverage"] as? String,"unavailable")
                XCTAssertEqual(bucket["usageAvailable"] as? Bool,false)
                XCTAssertEqual(bucket["missingUsageSessionCount"] as? Int,1)
            }
            XCTAssertTrue(day["tokens"] is NSNull); XCTAssertTrue(day["observedTokens"] is NSNull)
        }
    }

    func testExplicitZeroUsageIsAvailableAndNotMissing() throws {
        try fixture { logs,project,_,service in
            try write(logs.appendingPathComponent("codex/zero.jsonl"),codex(["input_tokens":0,"output_tokens":0],project:project))
            _ = try object(service,"sessions.refresh")
            let usage = try object(service,"usage.get")
            XCTAssertEqual(usage["totalTokens"] as? Int,0); XCTAssertEqual(usage["observedTotalTokens"] as? Int,0)
            XCTAssertEqual(usage["usageAvailable"] as? Bool,true); XCTAssertEqual(usage["coverage"] as? String,"complete")
            XCTAssertEqual(usage["missingUsageSessionCount"] as? Int,0)
        }
    }

    func testMixedBucketsExposeObservedSubtotalWithoutInventingCompleteTotal() throws {
        try fixture { logs,project,store,service in
            try write(logs.appendingPathComponent("claude/known.jsonl"),[claude("known",project:project,usage:["input_tokens":100,"cache_read_input_tokens":20,"output_tokens":30])])
            try write(logs.appendingPathComponent("claude/missing.jsonl"),[claude("missing",project:project)])
            _ = try object(service,"sessions.refresh")
            _ = try store.put("session",["id":"different-project","provider":"claude","project":project.appendingPathComponent("other").path,"tokenInput":999,"tokenOutput":1])
            let usage = try object(service,"usage.get",["project":project.path])
            let provider = try XCTUnwrap((usage["providers"] as? [JSON])?.first)
            let day = try XCTUnwrap((usage["daily"] as? [JSON])?.first)
            for bucket in [usage,provider,day] {
                XCTAssertTrue(bucket["inputTokens"] is NSNull); XCTAssertTrue(bucket["outputTokens"] is NSNull); XCTAssertTrue(bucket["totalTokens"] is NSNull)
                XCTAssertEqual(bucket["observedInputTokens"] as? Int,120); XCTAssertEqual(bucket["observedOutputTokens"] as? Int,30)
                XCTAssertEqual(bucket["observedTotalTokens"] as? Int,150); XCTAssertEqual(bucket["coverage"] as? String,"partial")
                XCTAssertEqual(bucket["sessionCount"] as? Int,2); XCTAssertEqual(bucket["observedSessionCount"] as? Int,1)
                XCTAssertEqual(bucket["missingUsageSessionCount"] as? Int,1)
            }
        }
    }

    func testClaudeInvalidAndExtremeCountersDoNotCrashOrCoerceIntoZero() throws {
        try fixture { logs,project,_,service in
            let invalid: [Any] = [Int.max,UInt64.max,-1,true,1.5,"123",NSNull()]
            for (index,value) in invalid.enumerated() {
                try write(logs.appendingPathComponent("claude/invalid-\(index).jsonl"),[claude("invalid-\(index)",project:project,usage:["input_tokens":value,"cache_read_input_tokens":1,"output_tokens":2])])
            }
            _ = try object(service,"sessions.refresh")
            let items = try sessions(service); XCTAssertEqual(items.count,invalid.count)
            for item in items {
                XCTAssertTrue(item["tokenInput"] is NSNull)
                XCTAssertEqual(item["tokenOutput"] as? Int,2)
                XCTAssertEqual(item["usageAvailable"] as? Bool,false)
            }
            let usage = try object(service,"usage.get")
            XCTAssertTrue(usage["inputTokens"] is NSNull); XCTAssertTrue(usage["totalTokens"] is NSNull)
            XCTAssertEqual(usage["observedTotalTokens"] as? Int,invalid.count * 2)
        }
    }

    func testClaudeCacheAdditionAndCodexAggregationCannotOverflow() throws {
        try fixture { logs,project,_,service in
            let largest = 9_007_199_254_740_991
            try write(logs.appendingPathComponent("claude/cache.jsonl"),[claude("cache",project:project,usage:["input_tokens":largest,"cache_creation_input_tokens":1,"output_tokens":1])])
            _ = try object(service,"sessions.refresh")
            let first = try object(service,"usage.get")
            XCTAssertTrue(first["totalTokens"] is NSNull); XCTAssertEqual(first["coverage"] as? String,"overflow")
            for index in 0..<2 {
                try write(logs.appendingPathComponent("codex/large-\(index).jsonl"),codex(["input_tokens":largest / 2 + 1,"output_tokens":0],project:project))
            }
            _ = try object(service,"sessions.refresh")
            let usage = try object(service,"usage.get")
            let codexBucket = try XCTUnwrap((usage["providers"] as? [JSON])?.first(where:{$0["provider"] as? String == "codex"}))
            XCTAssertEqual(codexBucket["sessionCount"] as? Int,2)
            XCTAssertTrue(codexBucket["inputTokens"] is NSNull); XCTAssertTrue(codexBucket["observedTotalTokens"] is NSNull)
            XCTAssertEqual(codexBucket["coverage"] as? String,"overflow")
            XCTAssertTrue(usage["totalTokens"] is NSNull)
        }
    }

    func testClaudeLateUsageAndRepeatedPartialEventsPreserveIdentity() throws {
        try fixture { logs,project,_,service in
            let file = logs.appendingPathComponent("claude/stream.jsonl")
            try write(file,[claude("message-a",project:project)])
            _ = try object(service,"sessions.refresh")
            XCTAssertTrue(try object(service,"usage.get")["totalTokens"] is NSNull)
            let final = claude("message-a",project:project,usage:["input_tokens":10,"output_tokens":5])
            try write(file,[final,final,claude("message-a",project:project),
                            claude("message-a",project:project,usage:["output_tokens":5]),
                            claude("message-a",project:project,usage:[:])],append:true)
            _ = try object(service,"sessions.refresh")
            XCTAssertEqual(try object(service,"usage.get")["totalTokens"] as? Int,15)
            try write(file,[claude("message-b",project:project)],append:true)
            _ = try object(service,"sessions.refresh")
            let partial = try object(service,"usage.get")
            XCTAssertTrue(partial["totalTokens"] is NSNull); XCTAssertEqual(partial["observedTotalTokens"] as? Int,15)
            try write(file,[claude("message-b",project:project,usage:["input_tokens":0,"output_tokens":0])],append:true)
            _ = try object(service,"sessions.refresh")
            let recovered = try object(service,"usage.get")
            XCTAssertEqual(recovered["totalTokens"] as? Int,15); XCTAssertEqual(recovered["usageAvailable"] as? Bool,true)
        }
    }

    func testCodexMissingComponentAndExtremeCounterRemainUnavailable() throws {
        try fixture { logs,project,_,service in
            try write(logs.appendingPathComponent("codex/partial.jsonl"),codex(["input_tokens":0],project:project))
            try write(logs.appendingPathComponent("codex/extreme.jsonl"),codex(["input_tokens":Int.max,"output_tokens":1],project:project))
            _ = try object(service,"sessions.refresh")
            let usage = try object(service,"usage.get")
            XCTAssertTrue(usage["totalTokens"] is NSNull); XCTAssertEqual(usage["observedTotalTokens"] as? Int,1)
            XCTAssertEqual(usage["missingUsageSessionCount"] as? Int,2)
        }
    }

    func testEmptyStoreHasNoFabricatedZeroUsage() throws {
        try fixture { _,_,_,service in
            let usage = try object(service,"usage.get")
            XCTAssertTrue(usage["totalTokens"] is NSNull); XCTAssertTrue(usage["observedTotalTokens"] is NSNull)
            XCTAssertEqual(usage["sessionCount"] as? Int,0); XCTAssertEqual(usage["coverage"] as? String,"unavailable")
            XCTAssertTrue((usage["providers"] as? [JSON])?.isEmpty == true); XCTAssertTrue((usage["daily"] as? [JSON])?.isEmpty == true)
        }
    }
}
