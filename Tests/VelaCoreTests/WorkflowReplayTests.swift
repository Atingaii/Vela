import XCTest
import Darwin
@testable import VelaCore

final class WorkflowReplayTests: XCTestCase {
    private func fixture(_ work: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-replay-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let raw = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:raw,withIntermediateDirectories:true)
        let root = URL(fileURLWithPath:canonicalProject(raw.path)), store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["id":stableHash(root.path),"title":"Synthetic replay","path":root.path,"project":root.path])
        try work(root,store,AutomationService(store:store))
    }
    private func call(_ service: AutomationService, _ method: String, _ params: JSON) throws -> JSON {
        let result = try service.handle(method,params)
        return try XCTUnwrap(result as? JSON)
    }
    private func step() -> JSON { ["tool":"agent.run","arguments":["executable":"/usr/bin/false","args":[WorkflowContext.promptMarker],"promptMode":"workflow_context"]] }
    private func history(_ root: URL, _ store: VelaStore, _ service: AutomationService, text: String = "HISTORICAL_INPUT", sources: Bool = false) throws -> (JSON,JSON) {
        var guidelines: [String] = []
        if sources {
            _ = try store.put("library",["id":"replay-library","title":"evidence","content":"LIBRARY_ORIGINAL","project":root.path,"state":"active","private":false,"scope":"project"])
            _ = try store.put("memory",["id":"replay-memory","title":"evidence","content":"MEMORY_ORIGINAL","project":root.path,"state":"active","private":false,"scope":"project"])
            let g = try store.put("guideline",["id":"replay-guideline","title":"Style","content":"GUIDELINE_ORIGINAL","project":root.path,"state":"active","scope":"project"]); guidelines = [string(g,"id")]
        }
        var context: JSON = ["version":1,"template":"VERSION_A evidence {{input.task}} {{pasted}}","inputs":[["id":"pasted","source":"stdin"]],"memory":["enabled":sources]]
        if sources { context["inputs"] = [["id":"pasted","source":"stdin"],["id":"reference","retrieve":["query":"evidence","k":3]]] as [JSON] }
        let a = try call(service,"workflows.save",["title":"Replay fixture","project":root.path,"steps":[step()],"context":context,"guidelines":guidelines])
        let run = try call(service,"workflows.run",["id":a["id"]!,"dryRun":true,"inputs":["task":text],"stdin":"literal {{guidelines}} 中文"])
        XCTAssertEqual(string(run,"state"),"completed")
        context["template"] = "VERSION_B evidence {{input.task}} {{pasted}}"
        _ = try call(service,"workflows.save",["id":a["id"]!,"title":"Replay fixture","project":root.path,"steps":[step()],"context":context,"guidelines":guidelines])
        let inspected = try call(service,"replay.fixtures.inspect",["project":root.path,"runId":run["id"]!])
        let captured = try call(service,"replay.fixtures.capture",["project":root.path,"runId":run["id"]!,"runHash":inspected["runHash"]!,"consent":true,"retentionDays":1])
        return (run,captured)
    }
    private func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of:"'",with:"'\\''") + "'" }
    private func fake(_ root: URL, mode: String = "valid", barrier: Bool = false) throws -> URL {
        let binary = root.appendingPathComponent("synthetic-codex-" + UUID().uuidString)
        var events: [JSON] = [["type":"thread.started","thread_id":"synthetic-replay"]]
        if mode == "tool" { events.append(["type":"item.completed","item":["id":"tool","type":"command_execution","command":"touch forbidden","exit_code":0]]) }
        events.append(["type":"item.completed","item":["id":"answer","type":"agent_message","text":try jsonString(["output":"OUTPUT_LINE\nSYNTHETIC_ONLY"])]] )
        if mode != "incomplete" { events.append(["type":"turn.completed","usage":["input_tokens":42,"output_tokens":13]]) }
        let base = root.path
        let wait = barrier ? "touch \(quote(base + "/entered"))\ni=0; while [ ! -f \(quote(base + "/release")) ]; do i=$((i+1)); [ $i -lt 800 ] || exit 9; sleep 0.01; done\n" : ""
        let sleep = mode == "timeout" ? "sleep 3\n" : ""
        let unexpected = try jsonString(["type":"item.completed","item":["id":"unexpected","type":"command_execution","command":"forbidden","exit_code":0]])
        let secondTool = mode == "tool_second" ? "case \"$last\" in *VERSION_B*) printf '%s\\n' \(quote(unexpected));; esac\n" : ""
        let script = "#!/bin/sh\nprintf 'called\\n' >> \(quote(base + "/calls"))\nfor last do :; done\nprintf '%s\\n' \"$last\" >> \(quote(base + "/prompts"))\nprintf '%s\\0' \"$@\" > \(quote(base + "/argv"))\nprintf '%s' \"$PWD\" > \(quote(base + "/cwd"))\n\(wait)\(sleep)\(secondTool)cat <<'VELA_REPLAY_SYNTHETIC_EOF'\n\(try events.map(jsonString).joined(separator:"\n"))\nVELA_REPLAY_SYNTHETIC_EOF\n"
        let source = binary.appendingPathExtension("c")
        let c = """
        #include <unistd.h>
        #include <stdlib.h>
        int main(int argc, char **argv) {
            char **next = calloc((size_t)argc + 4, sizeof(char *));
            if (!next) return 120;
            next[0] = "/bin/sh"; next[1] = "-c";
            next[2] = \(try WorkflowContext.jsonText(script)); next[3] = "synthetic-provider";
            for (int i = 1; i < argc; i++) next[i + 3] = argv[i];
            execv(next[0], next); return 121;
        }
        """
        try Data(c.utf8).write(to:source); defer { try? FileManager.default.removeItem(at:source) }
        let compiled = try AutomationProcess.run(["/usr/bin/clang","-Os",source.path,"-o",binary.path],cwd:root.path,timeout:20,maxOutput:8000)
        guard compiled.exitCode == 0 else { throw VelaError("Synthetic native provider fixture compilation failed: " + compiled.output) }
        return binary
    }
    private func create(_ root: URL, _ service: AutomationService, _ fixture: JSON, _ binary: URL, extra: JSON = [:]) throws -> JSON {
        var params: JSON = ["project":root.path,"fixtureId":fixture["id"]!,"fixtureHash":fixture["fixtureHash"]!,"versions":[1,2],"executable":binary.path,"model":"synthetic-model","effort":"low","timeoutSeconds":2]
        params.merge(extra){_,new in new}; return try call(service,"replay.create",params)
    }
    private func current(_ root: URL, _ service: AutomationService, _ item: JSON) throws -> JSON { try call(service,"replay.get",["project":root.path,"id":item["id"]!]) }
    private func detail(_ root: URL, _ service: AutomationService, _ item: JSON, method: String = "replay.results") throws -> JSON {
        let view = try current(root,service,item)
        return try call(service,method,["project":root.path,"id":item["id"]!,"replayHash":view["replayHash"]!])
    }
    private func approve(_ service: AutomationService, _ item: JSON) throws -> JSON {
        let approval = try XCTUnwrap(item["approval"] as? JSON)
        return try call(service,"approvals.decide",["id":approval["id"]!,"snapshotHash":approval["snapshotHash"]!,"decision":"approve"])
    }
    private func awaitFile(_ path: URL) throws {
        let deadline = Date().addingTimeInterval(4)
        while !FileManager.default.fileExists(atPath:path.path) {
            guard Date() < deadline else { throw VelaError("Synthetic provider did not reach its barrier") }
            Thread.sleep(forTimeInterval:0.005)
        }
    }
    func testTwoIndependentFixturesReceiveSameHistoricalInputsWithNoBusinessTools() throws {
        try fixture { root,store,service in
            for text in ["INPUT_ONE","输入二 {{memory}}"] {
                let (run,captured) = try history(root,store,service,text:text)
                let pending = try create(root,service,captured,fake(root))
                XCTAssertEqual(string(pending,"state"),"pending_approval")
                let review = try detail(root,service,pending,method:"replay.review")
                let request = try XCTUnwrap(review["request"] as? JSON), commands = try XCTUnwrap(request["commands"] as? [[String]])
                XCTAssertEqual(commands.count,2); XCTAssertTrue(commands[0].last?.contains(text) == true); XCTAssertTrue(commands[1].last?.contains(text) == true)
                XCTAssertTrue(commands[0].last?.contains("VERSION_A") == true); XCTAssertTrue(commands[1].last?.contains("VERSION_B") == true)
                for command in commands { for flag in ["--ignore-user-config","--ignore-rules","read-only","mcp_servers={}","shell_tool","code_mode_host","memories"] { XCTAssertTrue(command.contains(flag)) } }
                XCTAssertEqual(string(try approve(service,pending),"state"),"executed")
                let done = try current(root,service,pending), result = try detail(root,service,done)
                XCTAssertEqual(string(done,"state"),"completed"); XCTAssertEqual(intValue(done,"completedModelCalls"),2)
                let receipts = try XCTUnwrap(result["receipts"] as? [JSON]); XCTAssertEqual(receipts.count,2)
                XCTAssertEqual((receipts[0]["metrics"] as? JSON)?["toolCalls"] as? Int,0)
                XCTAssertEqual((receipts[1]["metrics"] as? JSON)?["tokens"] as? Int,55)
                XCTAssertEqual((result["comparison"] as? JSON)?["semanticEffect"] as? String,"unknown")
                XCTAssertFalse(try jsonString(done).contains("OUTPUT_LINE")); XCTAssertFalse(try jsonString(done).contains(text))
                let audit = try XCTUnwrap(store.get("run",string(done,"runId")))
                XCTAssertFalse(try jsonString(audit).contains("OUTPUT_LINE")); XCTAssertFalse(try jsonString(audit).contains(text))
                XCTAssertThrowsError(try approve(service,pending))
                let cwd = try String(contentsOf:root.appendingPathComponent("cwd")); XCTAssertFalse(FileManager.default.fileExists(atPath:cwd))
                let old = try call(service,"workflows.replay",["runId":run["id"]!])
                XCTAssertEqual(string(old,"replayMode"),"captured_records_no_execution")
            }
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("calls")).split(separator:"\n").count,4)
            XCTAssertEqual(try store.list("memory").count,0); XCTAssertEqual(try store.list("run_output").count,0)
        }
    }
    func testEditedPublicSourcesKeepHistoricalTextButPrivateArchiveAndMissingStop() throws {
        try fixture { root,store,service in
            let (_,captured) = try history(root,store,service,sources:true)
            for kind in ["library","memory","guideline"] {
                var source = try XCTUnwrap(store.get(kind,"replay-" + kind)); source["content"] = "TODAYS_REPLACEMENT"; _ = try store.put(kind,source)
            }
            let pending = try create(root,service,captured,fake(root))
            let request = try detail(root,service,pending,method:"replay.review")
            XCTAssertTrue(try jsonString(request).contains("MEMORY_ORIGINAL")); XCTAssertFalse(try jsonString(request).contains("TODAYS_REPLACEMENT"))
            for (kind,field,value) in [("library","private",true as Any),("memory","state","archived" as Any),("guideline","scope","private" as Any)] {
                let old = try XCTUnwrap(store.get(kind,"replay-" + kind)); var changed = old; changed[field] = value; _ = try store.put(kind,changed)
                XCTAssertThrowsError(try detail(root,service,pending,method:"replay.review"))
                XCTAssertThrowsError(try create(root,service,captured,fake(root)))
                _ = try store.put(kind,old)
            }
            let asset = store.root.appendingPathComponent("assets/library/replay-library.md"); try FileManager.default.removeItem(at:asset)
            XCTAssertThrowsError(try detail(root,service,pending)); XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls").path))
        }
    }
    func testConsentHashesScopeAndUnsupportedHistoriesFailClosed() throws {
        try fixture { root,store,service in
            let (run,captured) = try history(root,store,service)
            for consent: Any in [false,1,"true"] {
                XCTAssertThrowsError(try call(service,"replay.fixtures.capture",["project":root.path,"runId":run["id"]!,"runHash":captured["sourceRunHash"]!,"consent":consent]))
            }
            XCTAssertThrowsError(try call(service,"replay.fixtures.capture",["project":root.path,"runId":run["id"]!,"runHash":"stale","consent":true]))
            let binary = try fake(root)
            for extra: JSON in [["versions":[1,1]],["versions":[true,2]],["versions":[1,999]],["timeoutSeconds":0],["fixtureHash":"stale"]] {
                XCTAssertThrowsError(try create(root,service,captured,binary,extra:extra))
            }
            for mutation in ["missing","hash","degraded","input_hash","shape"] {
                var damaged = run; damaged["id"] = "damaged-" + mutation
                var snapshot = run["contextSnapshot"] as! JSON
                switch mutation {
                case "missing": damaged.removeValue(forKey:"contextSnapshot")
                case "hash": snapshot["promptHash"] = "bad"; damaged["contextSnapshot"] = snapshot
                case "degraded": snapshot["degraded"] = true; damaged["contextSnapshot"] = snapshot
                case "input_hash": var receipts = snapshot["inputsUsed"] as! [JSON]; receipts[0]["valueHash"] = "bad"; snapshot["inputsUsed"] = receipts; damaged["inputsUsed"] = receipts; damaged["contextSnapshot"] = snapshot
                default: var workflow = run["workflowSnapshot"] as! JSON; workflow["steps"] = [step(),step()]; damaged["workflowSnapshot"] = workflow
                }
                _ = try store.put("run",damaged)
                XCTAssertThrowsError(try call(service,"replay.fixtures.inspect",["project":root.path,"runId":damaged["id"]!]))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls").path))
        }
    }
    func testChangedApprovalRequestAndExecutableDoNotSend() throws {
        try fixture { root,store,service in
            let (_,captured) = try history(root,store,service), binary = try fake(root)
            let pending = try create(root,service,captured,binary)
            var payload = try XCTUnwrap(store.get("replay_payload",string(pending,"id"))), request = payload["request"] as! JSON
            request["maxCalls"] = 9; payload["request"] = request; _ = try store.put("replay_payload",payload)
            XCTAssertThrowsError(try detail(root,service,pending,method:"replay.review"))
            XCTAssertEqual(string(try approve(service,pending),"state"),"failed")
            let next = try create(root,service,captured,binary)
            var original = try Data(contentsOf:binary); original.append(Data("modified".utf8)); try original.write(to:binary)
            XCTAssertEqual(string(try approve(service,next),"state"),"failed")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls").path))
        }
    }
    func testUncertainMalformedToolAndTimeoutRetainOneReceiptAndNeverSendB() throws {
        try fixture { root,store,service in
            let (_,captured) = try history(root,store,service)
            for mode in ["tool","incomplete","timeout"] {
                let pending = try create(root,service,captured,fake(root,mode:mode),extra:["timeoutSeconds":1])
                XCTAssertEqual(string(try approve(service,pending),"state"),"needs_review")
                let done = try current(root,service,pending), result = try detail(root,service,done)
                XCTAssertEqual(string(done,"state"),"needs_review"); XCTAssertEqual(intValue(done,"providerAttempts"),1)
                XCTAssertEqual((result["receipts"] as? [JSON])?.count,1); XCTAssertTrue(result["comparison"] is NSNull)
                XCTAssertThrowsError(try approve(service,pending))
            }
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("calls")).split(separator:"\n").count,3)
        }
    }
    func testCancelBeforeApprovalAndClaimedRestartDoNotReplay() throws {
        try fixture { root,store,service in
            let (_,captured) = try history(root,store,service), binary = try fake(root)
            let pending = try create(root,service,captured,binary)
            let cancelled = try call(service,"replay.cancel",["project":root.path,"id":pending["id"]!,"replayHash":pending["replayHash"]!])
            XCTAssertEqual(string(cancelled,"state"),"cancelled"); XCTAssertThrowsError(try approve(service,pending))
            let uncertain = try create(root,service,captured,binary)
            var meta = try XCTUnwrap(store.get("replay",string(uncertain,"id"))); meta["state"] = "executing"; meta["providerAttempts"] = 1; _ = try store.put("replay",meta)
            XCTAssertEqual(string(try approve(AutomationService(store:store),uncertain),"state"),"failed")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls").path))
        }
    }
    func testForgetExpiryAndArchiveExportsNeverReturnReplayBodies() throws {
        try fixture { root,store,service in
            let (_,captured) = try history(root,store,service), pending = try create(root,service,captured,fake(root))
            _ = try call(service,"replay.fixtures.forget",["project":root.path,"id":captured["id"]!,"fixtureHash":captured["fixtureHash"]!])
            XCTAssertNil(try store.get("replay_fixture_payload",string(captured,"id"))); XCTAssertNil(try store.get("replay_payload",string(pending,"id")))
            XCTAssertThrowsError(try detail(root,service,pending)); XCTAssertEqual(string(try approve(service,pending),"state"),"failed")
            let (_,expiry) = try history(root,store,service,text:"EXPIRED_MARKER")
            var expired = try XCTUnwrap(store.get("replay_fixture",string(expiry,"id"))); expired["expiresAt"] = "2000-01-01T00:00:00Z"; _ = try store.put("replay_fixture",expired)
            XCTAssertThrowsError(try create(root,service,expiry,fake(root)))
            let pruned = try call(service,"replay.fixtures.prune",["project":root.path]); XCTAssertGreaterThan(intValue(pruned,"pruned"),0)
            XCTAssertNil(try store.get("replay_fixture_payload",string(expiry,"id")))
            let archive = try MemoryService(store:store).handle("memory.archive.export",["project":root.path])
            XCTAssertFalse(try jsonString(archive ?? [:]).contains("EXPIRED_MARKER")); XCTAssertFalse(try jsonString(archive ?? [:]).contains("HISTORICAL_INPUT"))
        }
    }
    func testCancelAndForgetDuringCallCannotSendBOrResurrectPayload() throws {
        for action in ["cancel","forget","private"] {
            try fixture { root,store,service in
                let (_,captured) = try history(root,store,service,sources:true)
                let pending = try create(root,service,captured,fake(root,barrier:true),extra:["timeoutSeconds":10])
                let done = DispatchSemaphore(value:0)
                DispatchQueue.global().async { _ = try? self.approve(service,pending); done.signal() }
                defer { try? Data().write(to:root.appendingPathComponent("release")); _ = done.wait(timeout:.now()+12) }
                try awaitFile(root.appendingPathComponent("entered"))
                let control = AutomationService(store:store,recoverInterruptedFiles:false), view = try current(root,control,pending)
                switch action {
                case "cancel": _ = try call(control,"replay.cancel",["project":root.path,"id":pending["id"]!,"replayHash":view["replayHash"]!])
                case "forget": _ = try call(control,"replay.fixtures.forget",["project":root.path,"id":captured["id"]!,"fixtureHash":captured["fixtureHash"]!])
                default: var library = try XCTUnwrap(store.get("library","replay-library")); library["private"] = true; _ = try store.put("library",library)
                }
                try Data().write(to:root.appendingPathComponent("release")); XCTAssertEqual(done.wait(timeout:.now()+12),.success); done.signal()
                XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("calls")),"called\n")
                if action == "forget" { XCTAssertNil(try store.get("replay_payload",string(pending,"id"))); XCTAssertNil(try store.get("replay_fixture_payload",string(captured,"id"))) }
                if action == "private" { XCTAssertThrowsError(try detail(root,control,pending)) }
                if action == "cancel" { XCTAssertEqual(string(try current(root,control,pending),"state"),"cancelled"); XCTAssertEqual((try detail(root,control,pending)["receipts"] as? [JSON])?.count,1) }
            }
        }
    }
    func testOriginalRunPrivacyAndChangedInputPoliciesStopNewReplay() throws {
        try fixture { root,store,service in
            let (run,captured) = try history(root,store,service), binary = try fake(root)
            let pending = try create(root,service,captured,binary)
            var hidden = run; hidden["private"] = true; _ = try store.put("run",hidden)
            XCTAssertThrowsError(try detail(root,service,pending)); XCTAssertThrowsError(try create(root,service,captured,binary))
            _ = try store.put("run",run)
            var revision = try XCTUnwrap(store.get("workflow_version",string(run,"workflowId") + ".v2"))
            var context = revision["context"] as! JSON; context["memory"] = ["enabled":true]; revision["context"] = context
            _ = try store.put("workflow_version",revision)
            XCTAssertThrowsError(try create(root,service,captured,binary))
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("calls").path))
        }
    }
    func testRequestMutationBetweenCallsStopsBAndPreservesOnlyFirstReceipt() throws {
        try fixture { root,store,service in
            let (_,captured) = try history(root,store,service), pending = try create(root,service,captured,fake(root,barrier:true),extra:["timeoutSeconds":10])
            let done = DispatchSemaphore(value:0)
            DispatchQueue.global().async { _ = try? self.approve(service,pending); done.signal() }
            defer { try? Data().write(to:root.appendingPathComponent("release")); _ = done.wait(timeout:.now()+12) }
            try awaitFile(root.appendingPathComponent("entered"))
            var payload = try XCTUnwrap(store.get("replay_payload",string(pending,"id"))), request = payload["request"] as! JSON
            request["timeoutSeconds"] = 1; payload["request"] = request; _ = try store.put("replay_payload",payload)
            try Data().write(to:root.appendingPathComponent("release")); XCTAssertEqual(done.wait(timeout:.now()+12),.success); done.signal()
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("calls")),"called\n")
            XCTAssertThrowsError(try detail(root,AutomationService(store:store),pending))
            let saved = try XCTUnwrap(store.get("replay_payload",string(pending,"id")))
            XCTAssertEqual((saved["receipts"] as? [JSON])?.count,1)
        }
    }
    func testCleanupFiltersBeforeWindowAndReturnsProgressAcrossPages() throws {
        try fixture { root,store,service in
            let (_,captured) = try history(root,store,service)
            var objects: [(String,JSON)] = []
            for index in 0..<130 {
                let id = "zz-target-" + String(format:"%04d",index)
                objects += [("replay",["id":id,"project":root.path,"fixtureId":captured["id"]!]),("replay_payload",["id":id,"project":root.path,"body":"retained synthetic data"])]
            }
            _ = try store.putBatch(objects,createOnly:true)
            for batch in 0..<10 {
                _ = try store.putBatch((0..<1001).map { index in ("replay",["id":"noise-\(batch)-\(index)","project":root.path,"fixtureId":"unrelated"] as JSON) },createOnly:true)
            }
            let first = try call(service,"replay.fixtures.forget",["project":root.path,"id":captured["id"]!,"fixtureHash":captured["fixtureHash"]!])
            XCTAssertEqual(first["cleanupPending"] as? Bool,true); XCTAssertEqual(first["payloadRemoved"] as? Bool,false)
            XCTAssertEqual(first["payloadsRemovedThisCall"] as? Int,128)
            let second = try call(service,"replay.fixtures.forget",["project":root.path,"id":captured["id"]!,"fixtureHash":captured["fixtureHash"]!])
            XCTAssertEqual(second["cleanupPending"] as? Bool,false); XCTAssertEqual(second["payloadsRemovedThisCall"] as? Int,2)
            XCTAssertTrue(try store.replayPayloadIDs(fixtureId:string(captured,"id"),project:root.path).isEmpty)
            for index in 0..<5 {
                let id = "page-\(index)"
                _ = try store.put("replay_fixture",["id":id,"project":root.path,"state":index < 4 ? "forgotten" : "active","fixtureHash":"fixture-\(index)","expiresAt":"2000-01-01T00:00:00Z"])
                _ = try store.put("replay_fixture_payload",["id":id,"project":root.path,"frozen":["marker":"must-clean"]])
            }
            var cursor = "", pages = 0
            while true {
                let result = try call(service,"replay.fixtures.prune",["project":root.path,"limit":2,"after":cursor]); pages += 1
                if result["nextCursor"] is NSNull { break }
                cursor = try requireString(result,"nextCursor")
                guard pages < 8 else { throw VelaError("Prune cursor failed to advance") }
            }
            XCTAssertGreaterThan(pages,1); XCTAssertNil(try store.get("replay_fixture_payload","page-4"))
        }
    }
    func testNativeEntrypointSnapshotSurvivesOriginalReplacementAndRejectsWrappers() throws {
        try fixture { root,_,_ in
            let binary = try fake(root), hash = try WorkflowReplay.executableHash(binary.path)
            let snapshot = try ReplayExecutableSnapshot(path:binary.path,expectedHash:hash)
            let copiedPath = snapshot.executable
            XCTAssertEqual(try WorkflowReplay.executableHash(copiedPath),hash)
            try Data("#!/bin/sh\nexit 97\n".utf8).write(to:binary)
            XCTAssertThrowsError(try WorkflowReplay.executableHash(binary.path))
            XCTAssertThrowsError(try ReplayExecutableSnapshot(path:binary.path,expectedHash:hash))
            let ran = try AutomationProcess.run([copiedPath,"synthetic-task"],cwd:root.path,timeout:3,maxOutput:8000)
            XCTAssertEqual(ran.exitCode,0); XCTAssertTrue(ran.output.contains("turn.completed"))
            XCTAssertEqual(try WorkflowReplay.executableHash(copiedPath),hash)
            snapshot.remove(); XCTAssertFalse(FileManager.default.fileExists(atPath:copiedPath))
        }
    }
    func testSecondFailureKeepsFirstValidatedOutputWithoutInventingComparison() throws {
        try fixture { root,store,service in
            let (_,captured) = try history(root,store,service)
            let pending = try create(root,service,captured,fake(root,mode:"tool_second"))
            XCTAssertEqual(string(try approve(service,pending),"state"),"needs_review")
            let done = try current(root,service,pending), result = try detail(root,service,pending)
            XCTAssertEqual(intValue(done,"providerAttempts"),2); XCTAssertEqual(intValue(done,"completedModelCalls"),1)
            let receipts = try XCTUnwrap(result["receipts"] as? [JSON]); XCTAssertEqual(receipts.count,2)
            XCTAssertEqual(string(receipts[0],"state"),"validated"); XCTAssertEqual(string(receipts[1],"state"),"response_received")
            XCTAssertTrue(result["comparison"] is NSNull); XCTAssertThrowsError(try approve(service,pending))
        }
    }
    func testOriginalEntrypointReplacementAfterAStillRunsBothFromSamePinnedBytes() throws {
        try fixture { root,store,service in
            let (_,captured) = try history(root,store,service), binary = try fake(root,barrier:true)
            let pending = try create(root,service,captured,binary,extra:["timeoutSeconds":10]), expected = try WorkflowReplay.executableHash(binary.path)
            let done = DispatchSemaphore(value:0)
            DispatchQueue.global().async { _ = try? self.approve(service,pending); done.signal() }
            defer { try? Data().write(to:root.appendingPathComponent("release")); _ = done.wait(timeout:.now()+12) }
            try awaitFile(root.appendingPathComponent("entered"))
            try Data("#!/bin/sh\nexit 97\n".utf8).write(to:binary)
            try Data().write(to:root.appendingPathComponent("release")); XCTAssertEqual(done.wait(timeout:.now()+12),.success); done.signal()
            XCTAssertEqual(string(try current(root,service,pending),"state"),"completed")
            let result = try detail(root,service,pending), receipts = try XCTUnwrap(result["receipts"] as? [JSON])
            XCTAssertEqual(receipts.count,2)
            XCTAssertTrue(receipts.allSatisfy{string($0,"executableSnapshotHash") == expected})
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("calls")),"called\ncalled\n")
        }
    }
    func testNativeIdentityRejectsFIFOAndLinksBeforeReadingBytes() throws {
        try fixture { root,_,_ in
            let fifo = root.appendingPathComponent("provider-pipe")
            XCTAssertEqual(mkfifo(fifo.path,0o700),0)
            let began = Date()
            XCTAssertThrowsError(try WorkflowReplay.executableHash(fifo.path))
            XCTAssertLessThan(Date().timeIntervalSince(began),1)
            let binary = try fake(root), link = root.appendingPathComponent("provider-link")
            try FileManager.default.createSymbolicLink(at:link,withDestinationURL:binary)
            XCTAssertThrowsError(try ReplayExecutableSnapshot.read(link.path))
            XCTAssertEqual(try ReplayExecutableSnapshot.read(binary.path),try WorkflowReplay.executableHash(binary.path))
        }
    }
    func testLineComparisonKeepsCompleteNonminimalDifferenceAndUnknownSemantics() throws {
        let comparison = WorkflowReplay.comparison("start\na\nb\nend","start\nc\nend")
        XCTAssertEqual(comparison["removedLines"] as? [String],["a","b"]); XCTAssertEqual(comparison["addedLines"] as? [String],["c"])
        XCTAssertEqual(intValue(comparison,"churnLines"),3); XCTAssertEqual(string(comparison,"semanticEffect"),"unknown")
        XCTAssertEqual(intValue(WorkflowReplay.comparison("same","same"),"churnLines"),0)
    }
}
