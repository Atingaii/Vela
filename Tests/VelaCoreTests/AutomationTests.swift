import XCTest
@testable import VelaCore

final class AutomationTests: XCTestCase {
    private func fixture(_ work: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-automation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let root = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["title":"Fixture","path":root.path,"project":root.path])
        try work(root,store,AutomationService(store:store))
    }
    private func workflow(_ service: AutomationService, root: URL, steps: [JSON]) throws -> JSON {
        try XCTUnwrap(service.handle("workflows.save",["title":"Test workflow","project":root.path,"trigger":"manual","steps":steps]) as? JSON)
    }
    private func call(_ service: AutomationService, _ method: String, _ params: JSON) throws -> JSON {
        try XCTUnwrap(service.handle(method,params) as? JSON)
    }
    private func approve(_ service: AutomationService, store: VelaStore) throws -> JSON {
        let approval = try XCTUnwrap(store.list("approval").first {string($0,"state") == "pending"})
        return try call(service,"approvals.decide",["id":approval["id"]!,"decision":"approve","snapshotHash":approval["snapshotHash"]!])
    }
    private func gitRepository(_ root: URL) throws {
        XCTAssertEqual(try AutomationProcess.git(["init","-q"],cwd:root.path).exitCode,0)
        try Data("baseline\n".utf8).write(to:root.appendingPathComponent("value.txt"))
        XCTAssertEqual(try AutomationProcess.git(["add","value.txt"],cwd:root.path).exitCode,0)
        XCTAssertEqual(try AutomationProcess.git(["-c","user.name=Vela Test","-c","user.email=vela@example.invalid","commit","-qm","Initial fixture"],cwd:root.path).exitCode,0)
    }

    func testDryRunStubsEverySideEffect() throws {
        try fixture { root,store,service in
            try gitRepository(root)
            let saved = try workflow(service,root:root,steps:[
                ["title":"Status","tool":"git.status","arguments":[:]],
                ["title":"Write","tool":"file.write","arguments":["path":"would-write.txt","content":"changed"]],
                ["title":"Test","tool":"shell.test","arguments":["executable":"/usr/bin/touch","args":["would-run.txt"]]]
            ])
            let run = try call(service,"workflows.run",["id":saved["id"]!,"dryRun":true])
            XCTAssertEqual(string(run,"state"),"completed")
            let steps = try XCTUnwrap(run["steps"] as? [JSON])
            XCTAssertEqual(steps.map {string($0,"state")},["completed","stubbed","stubbed"])
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("would-write.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("would-run.txt").path))
            XCTAssertEqual(try store.list("approval").count,0)
        }
    }

    func testFrozenApprovalExecutesOnceAndIgnoresWorkflowEdits() throws {
        try fixture { root,store,service in
            let saved = try workflow(service,root:root,steps:[["title":"Write frozen content","tool":"file.write","arguments":["path":"answer.txt","content":"original snapshot"]]])
            _ = try call(service,"workflows.run",["id":saved["id"]!,"dryRun":false])
            let approval = try XCTUnwrap(store.list("approval").first)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("answer.txt").path))
            XCTAssertThrowsError(try call(service,"approvals.decide",["id":approval["id"]!,"decision":"approve","snapshotHash":"bad"]))
            _ = try call(service,"workflows.save",["id":saved["id"]!,"title":"Edited after preview","project":root.path,"steps":[["title":"Changed","tool":"file.write","arguments":["path":"answer.txt","content":"new payload"]]]])
            let decision = try approve(service,store:store)
            XCTAssertEqual(string(decision,"state"),"executed")
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("answer.txt")),"original snapshot")
            XCTAssertThrowsError(try call(service,"approvals.decide",["id":approval["id"]!,"decision":"approve","snapshotHash":approval["snapshotHash"]!]))
            XCTAssertEqual(try store.list("run").first?["state"] as? String,"completed")
        }
    }

    func testApprovalRejectsChangedFileWithoutOverwrite() throws {
        try fixture { root,store,service in
            let target = root.appendingPathComponent("existing.txt")
            try Data("before".utf8).write(to:target)
            let saved = try workflow(service,root:root,steps:[["title":"Write","tool":"file.write","arguments":["path":"existing.txt","content":"after"]]])
            _ = try call(service,"workflows.run",["id":saved["id"]!,"dryRun":false])
            try Data("manual change".utf8).write(to:target)
            let decision = try approve(service,store:store)
            XCTAssertEqual(string(decision,"state"),"failed")
            XCTAssertEqual(try String(contentsOf:target),"manual change")
        }
    }

    func testRejectStopsWorkflowAndReplayIsDry() throws {
        try fixture { root,store,service in
            let saved = try workflow(service,root:root,steps:[["title":"Write","tool":"file.write","arguments":["path":"rejected.txt","content":"no"]]])
            let run = try call(service,"workflows.run",["id":saved["id"]!,"dryRun":false])
            let approval = try XCTUnwrap(store.list("approval").first)
            _ = try call(service,"approvals.decide",["id":approval["id"]!,"decision":"reject","snapshotHash":approval["snapshotHash"]!])
            XCTAssertEqual(try store.get("run",string(run,"id"))?["state"] as? String,"rejected")
            let replay = try call(service,"workflows.replay",["runId":run["id"]!])
            XCTAssertEqual(replay["dryRun"] as? Bool,true)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("rejected.txt").path))
        }
    }

    func testSafeApplyUndoAndStaleBatchAreRealFilesystemTransactions() throws {
        try fixture { root,store,_ in
            let files = SafeApplyService(store:store)
            let original = root.appendingPathComponent("AGENTS.md")
            try Data("old rules".utf8).write(to:original)
            let operations: [JSON] = [["path":"AGENTS.md","baseHash":stableHash("old rules"),"content":"new rules"],["path":"nested/reference.md","baseHash":"absent","content":"reference"]]
            let preview = try files.preview(project:root.path,operations:operations)
            XCTAssertEqual(preview.count,2)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("nested").path))
            let journal = try files.apply(project:root.path,operations:operations)
            XCTAssertEqual(try String(contentsOf:original),"new rules")
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("nested/reference.md")),"reference")
            _ = try files.undo(journalID:string(journal,"id"))
            XCTAssertEqual(try String(contentsOf:original),"old rules")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("nested/reference.md").path))
            XCTAssertThrowsError(try files.apply(project:root.path,operations:[["path":"created/first.md","baseHash":"absent","content":"x"],["path":"AGENTS.md","baseHash":stableHash("wrong"),"content":"overwrite"]]))
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("created").path))
            XCTAssertEqual(try String(contentsOf:original),"old rules")
        }
    }

    func testSafeApplyRejectsSymlinkTraversalMissingHashAndUnsafeUndo() throws {
        try fixture { root,store,_ in
            let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
            try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
            try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("escape"),withDestinationURL:outside)
            let files = SafeApplyService(store:store)
            XCTAssertThrowsError(try files.apply(project:root.path,operations:[["path":"escape/file.md","baseHash":"absent","content":"x"]]))
            XCTAssertThrowsError(try files.apply(project:root.path,operations:[["path":"../outside/file.md","baseHash":"absent","content":"x"]]))
            XCTAssertThrowsError(try files.apply(project:root.path,operations:[["path":"AGENTS.md","content":"missing hash"]]))
            let journal = try files.apply(project:root.path,operations:[["path":"AGENTS.md","baseHash":"absent","content":"generated"]])
            try Data("user edit".utf8).write(to:root.appendingPathComponent("AGENTS.md"))
            XCTAssertThrowsError(try files.undo(journalID:string(journal,"id")))
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("AGENTS.md")),"user edit")
        }
    }

    func testInterruptedJournalRecoversOnlyMatchingWrites() throws {
        try fixture { root,store,_ in
            try Data("new".utf8).write(to:root.appendingPathComponent("AGENTS.md"))
            let stageName = ".vela-stage-" + UUID().uuidString.lowercased()
            try Data("new".utf8).write(to:root.appendingPathComponent(stageName))
            let journal = try store.put("apply_journal",["project":root.path,"state":"committing","operations":[["path":"AGENTS.md","before":"old","beforeHash":stableHash("old"),"content":"new","afterHash":stableHash("new"),"stageName":stageName]]])
            try SafeApplyService(store:store).recoverInterrupted()
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("AGENTS.md")),"old")
            XCTAssertEqual(try store.get("apply_journal",string(journal,"id"))?["state"] as? String,"recovered")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(stageName).path))
        }
    }

    func testHumanEditedWorkflowIsVersionedAndInvalidFrontmatterFailsClosed() throws {
        try fixture { root,store,service in
            let saved = try workflow(service,root:root,steps:[["title":"Write","tool":"file.write","arguments":["path":"manual.txt","content":"original"]]])
            let path = URL(fileURLWithPath:try requireString(saved,"assetPath"))
            var markdown = try String(contentsOf:path)
            markdown = markdown.replacingOccurrences(of:"\"content\":\"original\"",with:"\"content\":\"edited\"")
            try Data(markdown.utf8).write(to:path)
            let run = try call(service,"workflows.run",["id":saved["id"]!,"dryRun":false])
            XCTAssertEqual(run["workflowVersion"] as? Int,2)
            _ = try approve(service,store:store)
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("manual.txt")),"edited")
            try Data("invalid frontmatter".utf8).write(to:path)
            XCTAssertThrowsError(try call(service,"workflows.run",["id":saved["id"]!,"dryRun":false]))
        }
    }

    func testImprovePromotionUsesDistinctRealEvidenceAndIsIdempotent() throws {
        try fixture { root,store,service in
            for index in 1...2 {
                let messages: [JSON] = (1...2).map { ["id":"m\(index)-\($0)","role":"user","content":"You forgot to run tests again","timestamp":"2026-09-\(10+index)T12:00:00Z"] }
                _ = try store.put("session",["id":"session-\(index)","title":"Real fixture","project":root.path,"messages":messages])
            }
            let analysis = try call(service,"improve.analyze",["project":root.path])
            let suggestions = try XCTUnwrap(analysis["suggestions"] as? [JSON])
            XCTAssertEqual(suggestions.count,1)
            XCTAssertEqual(suggestions[0]["signalCount"] as? Int,4)
            XCTAssertEqual(suggestions[0]["distinctSessions"] as? Int,2)
            _ = try call(service,"improve.analyze",["project":root.path])
            XCTAssertEqual(try store.list("signal").count,4)
            XCTAssertEqual(try store.list("suggestion").count,1)
            XCTAssertEqual(analysis["modelCalled"] as? Bool,false)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".vela").path))
        }
    }

    func testImproveDoesNotPromoteSingleSessionOrCleanConversation() throws {
        try fixture { root,store,service in
            _ = try store.put("session",["id":"single","title":"One","project":root.path,"messages":[["id":"a","role":"user","content":"You forgot tests again"],["id":"b","role":"user","content":"You forgot tests again"],["id":"c","role":"user","content":"You forgot tests again"],["id":"d","role":"user","content":"Everything works. Thank you."]]])
            let result = try call(service,"improve.analyze",["project":root.path])
            XCTAssertEqual((result["suggestions"] as? [JSON])?.count,0)
            XCTAssertEqual(try store.list("signal").count,3)
        }
    }

    func testLabRunsApprovedRealPairedCommandsAndCleansWorktrees() throws {
        try fixture { root,store,service in
            try gitRepository(root)
            let evaluation = try call(service,"lab.run",["project":root.path,"title":"Paired content check","kind":"context","baseline":["files":[]],"candidate":["files":[["path":"value.txt","content":"candidate\n"]]],"command":["/usr/bin/grep","candidate","value.txt"],"timeoutSeconds":10,"repetitions":1])
            XCTAssertEqual(string(evaluation,"state"),"pending_approval")
            XCTAssertEqual((evaluation["results"] as? [JSON])?.count,0)
            _ = try approve(service,store:store)
            let completed = try call(service,"lab.compare",["id":evaluation["id"]!])
            XCTAssertEqual(string(completed,"state"),"completed")
            let results = try XCTUnwrap(completed["results"] as? [JSON])
            XCTAssertEqual(results.count,2)
            XCTAssertEqual(results.first {string($0,"variant") == "baseline"}?["exitCode"] as? Int,1)
            XCTAssertEqual(results.first {string($0,"variant") == "candidate"}?["exitCode"] as? Int,0)
            XCTAssertEqual(completed["originalWorktreeUnchanged"] as? Bool,true)
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("value.txt")),"baseline\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath:store.root.appendingPathComponent("lab-worktrees/" + string(evaluation,"id")).path))
            let worktrees = try AutomationProcess.git(["worktree","list","--porcelain"],cwd:root.path)
            XCTAssertEqual(worktrees.output.components(separatedBy:"worktree ").count-1,1)
        }
    }

    func testProcessTimeoutAndOutputLimitAreEnforced() throws {
        try fixture { root,_,_ in
            let timed = try AutomationProcess.run(["/bin/sh","-c","sleep 30 & wait"],cwd:root.path,timeout:1)
            XCTAssertEqual(timed.exitCode,124)
            XCTAssertTrue(timed.timedOut)
            XCTAssertTrue(timed.durationMs < 4000)
            let output = try AutomationProcess.run(["/bin/sh","-c","i=0; while [ $i -lt 100 ]; do echo 0123456789; i=$((i+1)); done"],cwd:root.path,maxOutput:100)
            XCTAssertEqual(output.output.utf8.count,100)
            XCTAssertTrue(output.truncated)
        }
    }

    func testSchedulerClaimsAnEventOnceAndQuotaResetIsUnavailable() throws {
        try fixture { root,store,service in
            let saved = try call(service,"workflows.save",["title":"At startup","project":root.path,"trigger":"app_start","enabled":true,"steps":[["title":"Write","tool":"file.write","arguments":["path":"scheduled.txt","content":"yes"]]]])
            try service.tick(); try service.tick()
            XCTAssertEqual(try store.list("run").filter {string($0,"workflowId") == string(saved,"id")}.count,1)
            XCTAssertEqual(try store.list("approval").count,1)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("scheduled.txt").path))
            let unavailable = try call(service,"workflows.save",["title":"Quota reset","project":root.path,"trigger":"usage_reset","enabled":true,"steps":[["title":"Read","tool":"git.status","arguments":[:]]]])
            try service.tick()
            XCTAssertEqual(try store.get("schedule",string(unavailable,"id"))?["state"] as? String,"unavailable")
            XCTAssertThrowsError(try VelaCron.validate("* *"))
            XCTAssertThrowsError(try VelaCron.validate("*/0 * * * *"))
            XCTAssertTrue(try VelaCron.matches("* * * * *",date:Date()))
        }
    }

    func testHealthDoesNotInventRatesWithoutRealRuns() throws {
        try fixture { _,_,service in
            let health = try call(service,"workflows.health",[:])
            XCTAssertTrue(health["successRate"] is NSNull)
            XCTAssertTrue(health["tokens"] is NSNull)
            XCTAssertEqual(health["tokensAvailable"] as? Bool,false)
        }
    }

    func testTwoDatabaseConnectionsCannotExecuteOneApprovalTwice() throws {
        try fixture { root,store,service in
            let saved = try workflow(service,root:root,steps:[["title":"Append once","tool":"shell.test","arguments":["executable":"/bin/sh","args":["-c","printf x >> count.txt"]]]])
            _ = try call(service,"workflows.run",["id":saved["id"]!,"dryRun":false])
            let approval = try XCTUnwrap(store.list("approval").first)
            let secondStore = try VelaStore(root:store.root)
            let services = [service,AutomationService(store:secondStore)]
            let decisions = AutomationRaceResults()
            DispatchQueue.concurrentPerform(iterations:2) { index in
                do {
                    _ = try services[index].handle("approvals.decide",["id":approval["id"]!,"decision":"approve","snapshotHash":approval["snapshotHash"]!])
                    decisions.record(true)
                } catch { decisions.record(false) }
            }
            XCTAssertEqual(decisions.successes,1)
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("count.txt")),"x")
        }
    }

    func testTwoSchedulersClaimOneCronEvent() throws {
        try fixture { root,store,service in
            _ = try call(service,"workflows.save",["title":"Cron","project":root.path,"trigger":"cron","cron":"* * * * *","enabled":true,"steps":[["title":"Write","tool":"file.write","arguments":["path":"once.txt","content":"value"]]]])
            let secondStore = try VelaStore(root:store.root)
            let services = [service,AutomationService(store:secondStore)]
            DispatchQueue.concurrentPerform(iterations:2) { index in try? services[index].tick() }
            XCTAssertEqual(try store.list("run").count,1)
            XCTAssertEqual(try store.list("schedule_event").count,1)
        }
    }

    func testBackgroundAnalysisRequiresOptInAndSkipsUnchangedSessions() throws {
        try fixture { root,store,service in
            _ = try store.put("session",["id":"background-session","title":"Fixture","project":root.path,"messages":[["id":"m1","role":"user","content":"You forgot to run tests again"]]])
            try service.tick()
            XCTAssertEqual(try store.list("signal").count,0)
            XCTAssertNil(try store.get("analysis_state","background"))
            _ = try store.put("settings",["id":"preferences","analysisEnabled":true])
            try service.tick()
            XCTAssertEqual(try store.list("signal").count,1)
            let priorSignals = try jsonString(store.list("signal"))
            let priorState = try jsonString(XCTUnwrap(store.get("analysis_state","background")))
            // Detect an accidental rewrite even when test execution remains in the same second.
            var signal = try XCTUnwrap(store.list("signal").first)
            signal["verifiedNoRewrite"] = true; _ = try store.put("signal",signal)
            try service.tick()
            XCTAssertEqual(try store.list("signal").first?["verifiedNoRewrite"] as? Bool,true)
            XCTAssertEqual(try jsonString(XCTUnwrap(store.get("analysis_state","background"))),priorState)
            XCTAssertFalse(priorSignals.isEmpty)
            XCTAssertEqual(try store.list("run").count,0)
            XCTAssertEqual(try store.list("approval").count,0)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".vela").path))
        }
    }

    func testBackgroundAnalysisProcessesUpdatesAndOffOnBacklog() throws {
        try fixture { root,store,service in
            _ = try store.put("settings",["id":"preferences","analysisEnabled":true])
            var session: JSON = ["id":"changed-session","title":"Fixture","project":root.path,"messages":[["id":"m1","role":"user","content":"You forgot to run tests again"]]]
            _ = try store.put("session",session); try service.tick()
            XCTAssertEqual(try store.list("signal").count,1)
            session["messages"] = [["id":"m1","role":"user","content":"You forgot to run tests again"],["id":"m2","role":"user","content":"You forgot the diff again"]]
            _ = try store.put("session",session); try service.tick()
            XCTAssertEqual(try store.list("signal").count,2)
            _ = try store.put("settings",["id":"preferences","analysisEnabled":false])
            _ = try store.put("session",["id":"backlog-session","title":"While disabled","project":root.path,"messages":[["id":"m3","role":"user","content":"You forgot to run tests again"]]])
            let before = try jsonString(XCTUnwrap(store.get("analysis_state","background")))
            try service.tick()
            XCTAssertEqual(try store.list("signal").count,2)
            XCTAssertEqual(try jsonString(XCTUnwrap(store.get("analysis_state","background"))),before)
            _ = try store.put("settings",["id":"preferences","analysisEnabled":true])
            try service.tick()
            XCTAssertEqual(try store.list("signal").count,3)
            XCTAssertEqual(try store.list("suggestion").count,0)
        }
    }

    func testBackgroundAnalysisRetriesAfterRealPersistenceFailure() throws {
        try fixture { root,store,service in
            _ = try store.put("settings",["id":"preferences","analysisEnabled":true])
            for index in 1...2 {
                _ = try store.put("session",["id":"retry-\(index)","title":"Retry fixture","project":root.path,"messages":[["id":"a\(index)","role":"user","content":"You forgot tests again"],["id":"b\(index)","role":"user","content":"You forgot tests again"]]])
            }
            let database = store.root.appendingPathComponent("vela.sqlite3").path
            let injected = try AutomationProcess.run(["/usr/bin/sqlite3",database,"CREATE TRIGGER fixture_reject_suggestion BEFORE INSERT ON objects WHEN NEW.kind='suggestion' BEGIN SELECT RAISE(ABORT,'fixture storage failure'); END;"],cwd:root.path)
            XCTAssertEqual(injected.exitCode,0)
            XCTAssertThrowsError(try service.tick())
            XCTAssertNil(try store.get("analysis_state","background"))
            let restored = try AutomationProcess.run(["/usr/bin/sqlite3",database,"DROP TRIGGER fixture_reject_suggestion;"],cwd:root.path)
            XCTAssertEqual(restored.exitCode,0)
            try service.tick()
            XCTAssertEqual(try store.list("signal").count,4)
            XCTAssertEqual(try store.list("suggestion").count,1)
            XCTAssertEqual(try store.get("analysis_state","background")?["state"] as? String,"completed")
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".vela").path))
        }
    }
}

private final class AutomationRaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record(_ success: Bool) { lock.lock(); defer {lock.unlock()}; if success { count += 1 } }
    var successes: Int { lock.lock(); defer {lock.unlock()}; return count }
}
