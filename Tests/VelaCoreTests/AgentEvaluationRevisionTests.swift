import XCTest
@testable import VelaCore

final class AgentEvaluationRevisionTests: XCTestCase {
    private func stream(command: String, exit: Int, usage: JSON = ["input_tokens":1000,"output_tokens":100]) throws -> String {
        try ([
            ["type":"thread.started","thread_id":"revision-fixture"] as JSON,
            ["type":"item.completed","item":["id":"cmd","type":"command_execution","command":command,"status":"completed","exit_code":exit]] as JSON,
            ["type":"turn.completed","usage":usage] as JSON
        ]).map(jsonString).joined(separator:"\n")
    }

    func testCompositeParseFailureIsUnknownInsteadOfExecutedOrZero() throws {
        for command in ["/bin/zsh -lc '/usr/bin/python3 verify.py &&'", "/bin/zsh -lc '/usr/bin/python3 verify.py && echo done\n)'", "/bin/zsh -lc 'false && /usr/bin/python3 verify.py'"] {
            let metrics = AgentEvaluation.metrics(try stream(command:command,exit:2),truncated:false,verificationCommand:["/usr/bin/python3","verify.py"])
            XCTAssertTrue(metrics["testExecutionObserved"] is NSNull)
            XCTAssertEqual(metrics["testCountIsLowerBound"] as? Bool,true)
        }
        let leading = AgentEvaluation.metrics(try stream(command:"/bin/zsh -lc '/usr/bin/python3 verify.py && echo done'",exit:0),truncated:false,verificationCommand:["/usr/bin/python3","verify.py"])
        XCTAssertEqual(leading["testExecutionObserved"] as? Bool,true)
        XCTAssertTrue(((leading["testCommands"] as? [JSON])?.first)?["testExitCode"] is NSNull)
        let failedSimple = AgentEvaluation.metrics(try stream(command:"/usr/bin/python3 verify.py",exit:1),truncated:false,verificationCommand:["/usr/bin/python3","verify.py"])
        XCTAssertEqual(failedSimple["testExecutionObserved"] as? Bool,true)
        XCTAssertEqual(failedSimple["successfulTestInvocations"] as? Int,0)
    }

    func testAllEvidenceViewsRecomputeStaleReadyAndPromotionRefusesIt() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-analysis-revision-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let store = try VelaStore(root:temporary)
        let service = AutomationService(store:store)
        let output = try stream(command:"/bin/zsh -lc '/usr/bin/python3 verify.py && echo done'",exit:0,usage:["input_tokens":Int.max,"output_tokens":1])
        let rows: [JSON] = ["baseline","candidate"].flatMap { variant in
            (0..<3).map { _ in ["variant":variant,"output":output,"truncated":false,"exitCode":0,"timedOut":false,"durationMs":1,"verificationIntact":true,"verification":["exitCode":0],"tokens":42,"tokensAvailable":true] as JSON }
        }
        let stored = try store.put("eval",["evaluator":"codex_agent","state":"completed","repetitions":3,"command":["/usr/bin/python3","verify.py"],"results":rows,"tokensAvailable":true,"summary":["decision":"ready_for_review"]])
        let id = string(stored,"id")
        let compare = try XCTUnwrap(service.handle("lab.compare",["id":id]) as? JSON)
        let list = try XCTUnwrap(service.handle("lab.list",[:]) as? [JSON])
        let evidence = try XCTUnwrap(service.handle("evidence.get",["id":id]) as? JSON)
        for view in [compare,try XCTUnwrap(list.first),try XCTUnwrap(evidence["object"] as? JSON)] {
            XCTAssertEqual(string(view["summary"] as? JSON ?? [:],"decision"),"inconclusive")
            XCTAssertEqual(view["tokensAvailable"] as? Bool,false)
            XCTAssertEqual(string(view["previousAnalysisSummary"] as? JSON ?? [:],"decision"),"ready_for_review")
            for row in view["results"] as? [JSON] ?? [] {
                XCTAssertTrue(row["tokens"] is NSNull)
                XCTAssertEqual(row["tokensAvailable"] as? Bool,false)
                XCTAssertEqual((row["agentMetrics"] as? JSON)?["testExecutionObserved"] as? Bool,true)
            }
        }
        XCTAssertThrowsError(try service.handle("lab.promote",["id":id]))
        XCTAssertEqual(try jsonString(try store.get("eval",id)!),try jsonString(stored))
    }
}
