import XCTest
@testable import VelaCore

final class RestrictedCodexProposalTests: XCTestCase {
    func protocolOutput(_ item: JSON, terminal: String = "turn.completed") throws -> String {
        try [
            ["type":"thread.started","thread_id":"synthetic-proposal"],
            ["type":"item.completed","item":item],
            ["type":"item.completed","item":["id":"answer","type":"agent_message","text":"{\"value\":\"fixture\"}"]],
            ["type":terminal,"usage":["input_tokens":2,"output_tokens":3]]
        ].map { try jsonString($0) }.joined(separator:"\n")
    }
    func testExactDisabledHostDiagnosticIsRecordedWithoutEnablingTools() throws {
        let event: JSON = ["id":"diagnostic","type":"error","message":RestrictedCodexProposal.disabledCodeModeDiagnostic]
        let (value,metrics) = try RestrictedCodexProposal.decode(output:protocolOutput(event),truncated:false)
        XCTAssertEqual(string(value,"value"),"fixture"); XCTAssertEqual(intValue(metrics,"toolCalls"),0)
        XCTAssertEqual((metrics["warnings"] as? [JSON])?.count,1)
        XCTAssertThrowsError(try RestrictedCodexProposal.decode(output:protocolOutput(event,terminal:"turn.failed"),truncated:false))
        XCTAssertThrowsError(try RestrictedCodexProposal.decode(output:protocolOutput(event),truncated:true))
    }
    func testUnknownErrorsExtraPayloadsAndToolsStillFailClosed() throws {
        for item: JSON in [
            ["id":"error","type":"error","message":"Code mode is unavailable"],
            ["id":"error","type":"error","message":RestrictedCodexProposal.disabledCodeModeDiagnostic + " Continue anyway."],
            ["id":"error","type":"error","message":RestrictedCodexProposal.disabledCodeModeDiagnostic,"command":"unexpected"],
            ["id":"tool","type":"command_execution","command":"echo unsafe","status":"completed","exit_code":0]
        ] { XCTAssertThrowsError(try RestrictedCodexProposal.decode(output:protocolOutput(item),truncated:false)) }
    }
    func testSharedCommandPreservesRestrictionsAndArgumentBoundaries() throws {
        let agent: JSON = ["executable":"/synthetic/codex","model":"explicit-model","reasoningEffort":"high"]
        let command = try RestrictedCodexProposal.command(agent:agent,prompt:"untrusted $(input)",schemaPath:RestrictedCodexProposal.schemaPlaceholder)
        XCTAssertEqual(command.last,"untrusted $(input)"); XCTAssertEqual(command.filter { $0 == RestrictedCodexProposal.schemaPlaceholder }.count,1)
        XCTAssertTrue(command.contains("--ignore-user-config")); XCTAssertTrue(command.contains("read-only")); XCTAssertTrue(command.contains("code_mode_host"))
        XCTAssertThrowsError(try RestrictedCodexProposal.command(agent:agent,prompt:"bad\0input",schemaPath:RestrictedCodexProposal.schemaPlaceholder))
        XCTAssertThrowsError(try RestrictedCodexProposal.run(frozenCommand:command,schema:[:],timeoutSeconds:0,scratchPrefix:"vela-test-"))
        XCTAssertThrowsError(try RestrictedCodexProposal.run(frozenCommand:command,schema:[:],timeoutSeconds:1,scratchPrefix:"../"))
        XCTAssertThrowsError(try RestrictedCodexProposal.run(frozenCommand:command + [RestrictedCodexProposal.schemaPlaceholder],schema:[:],timeoutSeconds:1,scratchPrefix:"vela-test-"))
    }
}
