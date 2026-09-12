import XCTest
@testable import VelaCore

/// Controlled fake Codex protocol executables exercise the real Lab, approval, Git worktrees
/// and verifier. They are not model runs, quality measurements or Golden Scenario evidence.
final class AgentLabIntegrityTests: XCTestCase {
    private let originalBounds = "def clamp(value, lower, upper):\n    return value\n"
    private let verifier = "from bounds import clamp\nassert clamp(-5, 0, 10) == 0\nassert clamp(15, 0, 10) == 10\nassert clamp(4, 0, 10) == 4\nprint('independent bounds verification passed')\n"
    private let launcher = "import runpy\nrunpy.run_path('verify.py', run_name='__main__')\n"

    private func fixture(_ mode: String, _ work: (URL,URL,URL,VelaStore,AutomationService) throws -> Void) throws {
        let base = URL(fileURLWithPath:canonicalProject(FileManager.default.temporaryDirectory.path)).appendingPathComponent("vela-agent-lab-integrity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let contents = ["bounds.py":originalBounds,"verify.py":verifier,"launcher.py":launcher,"package.json":"{\"scripts\":{\"test\":\"python3 launcher.py\"}}\n"]
        for (name,text) in contents { try Data(text.utf8).write(to:root.appendingPathComponent(name)) }
        XCTAssertEqual(try AutomationProcess.git(["init","-q"],cwd:root.path).exitCode,0)
        XCTAssertEqual(try AutomationProcess.git(["add","."],cwd:root.path).exitCode,0)
        XCTAssertEqual(try AutomationProcess.git(["-c","user.name=Vela fixture","-c","user.email=fixture@example.invalid","commit","-qm","Committed verifier and failing task"],cwd:root.path).exitCode,0)
        let executable = base.appendingPathComponent("fake-codex-protocol.py")
        // Fixed modes only; neither task text nor arbitrary CLI arguments become executable code.
        let program = """
        #!/usr/bin/python3 -I
        import json, pathlib, subprocess, sys
        if '--version' in sys.argv:
            print('fake-codex-protocol-fixture 1; not a model')
            raise SystemExit(0)
        mode = '\(mode)'
        if mode == 'correct-output':
            pathlib.Path('bounds.py').write_text('def clamp(value, lower, upper):\\n    return min(upper, max(lower, value))\\n')
        elif mode == 'noop-launcher':
            pathlib.Path('launcher.py').write_text('raise SystemExit(0)\\n')
            pathlib.Path('package.json').write_text('{"scripts":{"test":"true"}}\\n')
        elif mode == 'tamper-verifier':
            pathlib.Path('verify.py').write_text('raise SystemExit(0)\\n')
        else:
            raise SystemExit('unknown fixed fixture mode')
        result = subprocess.run(['/usr/bin/python3', 'launcher.py'], capture_output=True, text=True)
        events = [
            {'type':'thread.started', 'thread_id':'fake-protocol-' + pathlib.Path.cwd().name},
            {'type':'item.completed', 'item':{'id':'fixture-command', 'type':'command_execution', 'command':'/usr/bin/python3 launcher.py', 'exit_code':result.returncode, 'status':'completed', 'aggregated_output':result.stdout + result.stderr}},
            {'type':'item.completed', 'item':{'id':'fixture-summary', 'type':'agent_message', 'text':'Controlled test fixture completed; no model was called.'}},
            {'type':'turn.completed', 'usage':{'input_tokens':100, 'output_tokens':20}}
        ]
        for event in events:
            print(json.dumps(event), flush=True)
        """
        try Data(program.utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        let store = try VelaStore(root:base.appendingPathComponent("store"))
        _ = try store.put("project",["path":root.path,"project":root.path,"title":"Isolated fake-protocol Lab fixture"])
        try work(base,root,executable,store,AutomationService(store:store))
    }

    private func specification(_ root: URL, executable: URL) -> JSON {
        ["title":"Fake protocol integrity check; not Agent quality","project":root.path,"kind":"context","task":"Controlled fixture task; no model is invoked.","agent":["provider":"codex","model":"fake-protocol-model","executable":executable.path,"reasoningEffort":"high"],"verificationCommand":["/usr/bin/python3","launcher.py"],"verificationFiles":["verify.py"],"outputFiles":["bounds.py"],"repetitions":1,"timeoutSeconds":15,"baseline":["files":[]],"candidate":["files":[]]]
    }

    private func runThroughApproval(_ params: JSON, store: VelaStore, service: AutomationService) throws -> JSON {
        let created = try XCTUnwrap(service.handle("lab.run",params) as? JSON)
        XCTAssertEqual(string(created,"state"),"pending_approval")
        XCTAssertTrue((created["results"] as? [JSON] ?? []).isEmpty)
        let approval = try XCTUnwrap(store.get("approval",string(created,"approvalId")))
        XCTAssertEqual(string(approval,"state"),"pending")
        _ = try service.handle("approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
        let finished = try XCTUnwrap(store.get("eval",string(created,"id")))
        XCTAssertEqual(string(finished,"state"),"completed",string(finished,"error"))
        XCTAssertEqual((finished["results"] as? [JSON])?.count,2)
        XCTAssertTrue(finished["originalGitStatusUnchanged"] as? Bool == true)
        XCTAssertTrue((finished["cleanupFailures"] as? [String] ?? ["missing"]).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.root.appendingPathComponent("lab-worktrees/" + string(created,"id")).path))
        return finished
    }

    func testFakeProtocolCorrectOutputPassesCleanIndependentVerifier() throws {
        try fixture("correct-output") { _,root,executable,store,service in
            let result = try runThroughApproval(specification(root,executable:executable),store:store,service:service)
            for row in result["results"] as? [JSON] ?? [] {
                XCTAssertEqual(row["verificationIntact"] as? Bool,true)
                XCTAssertEqual((row["verification"] as? JSON)?["exitCode"] as? Int,0)
                XCTAssertTrue(string(row["verification"] as? JSON ?? [:],"output").contains("independent bounds verification passed"))
                XCTAssertEqual(string(row,"verificationIsolation"),"clean commit plus frozen output-file allowlist only")
            }
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("bounds.py")),originalBounds)
            XCTAssertNotEqual(string(result["summary"] as? JSON ?? [:],"decision"),"ready_for_review")
        }
    }

    func testFakeProtocolNoopLauncherCannotGameIndependentVerification() throws {
        try fixture("noop-launcher") { _,root,executable,store,service in
            let result = try runThroughApproval(specification(root,executable:executable),store:store,service:service)
            for row in result["results"] as? [JSON] ?? [] {
                XCTAssertEqual(row["verificationIntact"] as? Bool,true)
                XCTAssertEqual((row["agentMetrics"] as? JSON)?["successfulTestInvocations"] as? Int,1)
                XCTAssertNotEqual((row["verification"] as? JSON)?["exitCode"] as? Int,0)
                XCTAssertTrue(string(row["verification"] as? JSON ?? [:],"output").contains("AssertionError"))
            }
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("launcher.py")),launcher)
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("bounds.py")),originalBounds)
        }
    }

    func testFakeProtocolModifiedProtectedVerifierInvalidatesComparison() throws {
        try fixture("tamper-verifier") { _,root,executable,store,service in
            let result = try runThroughApproval(specification(root,executable:executable),store:store,service:service)
            for row in result["results"] as? [JSON] ?? [] {
                XCTAssertEqual(row["verificationIntact"] as? Bool,false)
                XCTAssertTrue((row["verification"] as? JSON)?["exitCode"] is NSNull)
                XCTAssertNil(row["verificationIsolation"])
            }
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("verify.py")),verifier)
            XCTAssertNotEqual(string(result["summary"] as? JSON ?? [:],"decision"),"ready_for_review")
        }
    }

    func testNormalizedProtectedPathOverlapIsRejectedBeforeCreatingEvaluation() throws {
        try fixture("correct-output") { _,root,executable,store,service in
            var params = specification(root,executable:executable)
            params["verificationFiles"] = ["./verify.py"]
            params["candidate"] = ["files":[["path":"verify.py","content":"raise SystemExit(0)\n"]]]
            XCTAssertThrowsError(try service.handle("lab.run",params))
            XCTAssertTrue(try store.list("eval").isEmpty)
            XCTAssertTrue(try store.list("approval").isEmpty)
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("verify.py")),verifier)
        }
    }

    func testUnrelatedSuggestionCandidateIsRejectedBeforeCreatingEvaluation() throws {
        try fixture("correct-output") { _,root,executable,store,service in
            let suggestion = try store.put("suggestion",["project":root.path,"state":"draft","title":"Source candidate","operations":[["path":"AGENTS.md","baseHash":"absent","content":"Run tests before handoff."]]])
            var params = specification(root,executable:executable)
            params["sourceSuggestionId"] = suggestion["id"]
            params["candidate"] = ["files":[["path":"AGENTS.md","content":"Unrelated formatting preference."]]]
            XCTAssertThrowsError(try service.handle("lab.run",params))
            XCTAssertTrue(try store.list("eval").isEmpty)
            XCTAssertTrue(try store.list("approval").isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("AGENTS.md").path))
        }
    }

    func testCodexCommandConstructsScalarConfigurationAndPreservesLiteralTask() throws {
        let specification = try AgentEvaluation.specification(["provider":"codex","model":"fake-protocol-model","executable":"/usr/bin/true","reasoningEffort":"high"])
        let task = "Keep this literal: $(not-a-shell-command)"
        let context = "Run tests before saying \"done\".\nKeep the results."
        let args = try AgentEvaluation.command(specification,task:task,context:context)
        XCTAssertEqual(args.last,task)
        XCTAssertTrue(args.contains("model_reasoning_effort=\"high\""))
        let config = try XCTUnwrap(args.first { $0.hasPrefix("developer_instructions=") })
        let encoded = String(config.dropFirst("developer_instructions=".count))
        let decoded = try JSONSerialization.jsonObject(with:Data(encoded.utf8),options:[.fragmentsAllowed])
        XCTAssertEqual(decoded as? String,context)
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertTrue(args.contains("workspace-write"))
    }
}
