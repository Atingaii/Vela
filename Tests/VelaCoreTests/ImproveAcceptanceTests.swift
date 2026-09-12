import XCTest
@testable import VelaCore

final class ImproveAcceptanceTests: XCTestCase {
    private func fixture(_ work: (URL,URL,VelaStore,AutomationService) throws -> Void) throws {
        let base = URL(fileURLWithPath:canonicalProject(FileManager.default.temporaryDirectory.path)).appendingPathComponent("vela-improve-acceptance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:base.appendingPathComponent("store"))
        _ = try store.put("project",["title":"Isolated verification project","path":project.path,"project":project.path])
        try work(base,project,store,AutomationService(store:store))
    }

    private func analyze(_ service: AutomationService, project: URL) throws -> JSON {
        // Expected service errors must reach XCTAssertThrowsError directly;
        // XCTUnwrap records an extra failure if its expression itself throws.
        let response = try service.handle("improve.analyze",["project":project.path])
        return try XCTUnwrap(response as? JSON)
    }

    private func session(_ store: VelaStore, project: URL, id: String, texts: [String], internalRun: Bool = false) throws {
        let messages: [JSON] = texts.enumerated().map { ["id":"\(id)-m\($0.offset)","role":"user","content":$0.element,"timestamp":"2026-09-12T09:00:00Z"] }
        _ = try store.put("session",["id":id,"project":project.path,"messages":messages,"internalRun":internalRun])
    }

    func testFiveDistinctVerificationCorrectionsProduceOneReviewableWorkflow() throws {
        try fixture { _,project,store,service in
            for i in 1...5 { try session(store,project:project,id:"s\(i)",texts:["You forgot to run the relevant tests again before handing over the task."]) }
            let result = try analyze(service,project:project)
            let suggestions = try XCTUnwrap(result["suggestions"] as? [JSON])
            XCTAssertEqual(suggestions.count,1)
            XCTAssertEqual(intValue(suggestions[0],"distinctSessions"),5)
            XCTAssertEqual(string(suggestions[0],"carrier"),"Workflow")
            XCTAssertEqual((suggestions[0]["evidence"] as? [JSON])?.count,5)
            XCTAssertEqual((result["candidateMemories"] as? [JSON])?.count,0)
            XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent(".vela").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent("AGENTS.md").path))
            _ = try analyze(service,project:project)
            XCTAssertEqual(try store.list("signal").count,5)
            XCTAssertEqual(try store.list("suggestion").count,1)
            XCTAssertEqual(result["modelCalled"] as? Bool,false)
            XCTAssertNil(suggestions[0]["confidence"])
        }
    }

    func testExplicitHandoffConstraintCreatesCandidateWithExactProvenanceAndPreservesAdoption() throws {
        try fixture { _,project,store,service in
            let text = "以后完成任务之前一定先跑测试"
            try session(store,project:project,id:"source",texts:[text])
            try session(store,project:project,id:"english",texts:["From now on, always run the relevant tests before handing over the task.","You forgot tests again"])
            let result = try analyze(service,project:project)
            let memories = try XCTUnwrap(result["candidateMemories"] as? [JSON])
            XCTAssertEqual(memories.count,2)
            let memory = try XCTUnwrap(memories.first {string($0,"sourceSession") == "source"})
            XCTAssertEqual(string(memory,"state"),"candidate")
            XCTAssertEqual(string(memory,"type"),"constraint")
            XCTAssertEqual(string(memory,"content"),text)
            XCTAssertEqual(string(memory,"sourceMessage"),"source-m0")
            XCTAssertEqual(string(memory,"project"),project.path)
            XCTAssertEqual(string(memory["provenance"] as? JSON ?? [:],"origin"),"session_explicit_constraint")
            let suggestion = try XCTUnwrap((result["suggestions"] as? [JSON])?.first)
            XCTAssertEqual(suggestion["verificationCandidateMemoryIds"] as? [String],memories.map {string($0,"id")}.sorted())
            let memoriesService = MemoryService(store:store)
            let before = try XCTUnwrap(try memoriesService.handle("recall",["project":project.path,"query":"测试"]) as? JSON)
            XCTAssertTrue((before["items"] as? [JSON] ?? []).isEmpty)
            _ = try memoriesService.handle("memory.transition",["id":memory["id"]!,"state":"active"])
            _ = try memoriesService.handle("memory.save",["id":memory["id"]!,"title":"Reviewed constraint","content":"Reviewed: run relevant project tests."])
            _ = try analyze(service,project:project)
            let persisted = try XCTUnwrap(store.get("memory",string(memory,"id")))
            XCTAssertEqual(string(persisted,"state"),"active")
            XCTAssertEqual(string(persisted,"content"),"Reviewed: run relevant project tests.")
            XCTAssertEqual(try store.list("memory").count,2)
        }
    }

    func testFeatureSpecificationsQuotedExamplesAndAgainDoNotCreateSignals() throws {
        try fixture { _,project,store,service in
            let nearMisses = [
                "Run the tests again.", "The test button should run again after every click.",
                "Every time the user completes the form, run validation tests again.",
                "Add a test for the new feature again.", "这里不好", "每次点击按钮后运行测试。",
                "Example: You forgot to run tests again.", "> You forgot tests again",
                "The expected message is \"You forgot tests again\".",
                "From now on always run tests before handing over this fixture example.",
                "From now on never run tests before handing over the task.",
                "以后完成任务之前不要跑测试", "假设用户说忘记跑测试，如何显示错误？"
            ]
            for i in 1...5 { try session(store,project:project,id:"negative-\(i)",texts:nearMisses) }
            let result = try analyze(service,project:project)
            XCTAssertTrue((result["signals"] as? [JSON] ?? []).isEmpty)
            XCTAssertTrue((result["suggestions"] as? [JSON] ?? []).isEmpty)
            XCTAssertTrue((result["candidateMemories"] as? [JSON] ?? []).isEmpty)
        }
    }

    func testOldSignalsMissingMessagesAndCrossProjectEvidenceCannotPromote() throws {
        try fixture { base,project,store,service in
            let other = base.appendingPathComponent("other")
            try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
            _ = try store.put("project",["title":"Other","path":other.path,"project":other.path])
            for i in 1...2 {
                try session(store,project:project,id:"a\(i)",texts:["You forgot tests again"])
                try session(store,project:other,id:"b\(i)",texts:["You forgot tests again"])
                _ = try store.put("signal",["id":"forged\(i)","project":project.path,"sourceSession":"a\(i)","sourceMessage":"absent","clusterKey":"verification","detector":"explicit-language-v1"])
            }
            try session(store,project:project,id:"internal",texts:["You forgot tests again"],internalRun:true)
            _ = try store.put("session",["id":"missing-id","project":project.path,"messages":[["role":"user","content":"You forgot tests again"]]])
            let result = try analyze(service,project:project)
            XCTAssertEqual((result["signals"] as? [JSON])?.count,2)
            XCTAssertTrue((result["suggestions"] as? [JSON] ?? []).isEmpty)
            XCTAssertTrue((try analyze(service,project:other)["suggestions"] as? [JSON] ?? []).isEmpty)
        }
    }

    private func ingestSequence(_ engine: FoundationService, directory: URL, project: URL, id: String, commands: [String], summary: Bool = true, cwd: String? = nil) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var events: [JSON] = [["type":"session_meta","timestamp":"2026-09-12T10:00:00Z","payload":["id":id,"cwd":project.path]]]
        for (index,command) in commands.enumerated() {
            let args: JSON = ["cmd":command,"workdir":cwd ?? project.path]
            events.append(["type":"response_item","timestamp":"2026-09-12T10:00:01Z","payload":["type":"function_call","id":"\(id)-tool-\(index)","name":"exec_command","arguments":try jsonString(args)]])
        }
        if summary { events.append(["type":"response_item","timestamp":"2026-09-12T10:00:02Z","payload":["type":"message","id":"\(id)-summary","role":"assistant","content":[["type":"output_text","text":"Summary\nReviewed changes and the test invocation."]]]]) }
        let data = try events.map { try jsonString($0) }.joined(separator:"\n") + "\n"
        try Data(data.utf8).write(to:directory.appendingPathComponent(id + ".jsonl"))
        _ = try engine.handle("sessions.refresh",[:])
    }

    func testThreeParsedCodexToolSequencesCreateDisabledWorkflowDraftWithoutExecution() throws {
        try fixture { base,project,store,service in
            let directory = base.appendingPathComponent("codex")
            let engine = FoundationService(store:store,sourceRoots:["codex":[directory]],globalHome:base.appendingPathComponent("home"))
            defer { engine.stopWatching() }
            for i in 1...2 { try ingestSequence(engine,directory:directory,project:project,id:"seq\(i)",commands:["git diff --stat","pnpm run test"]) }
            XCTAssertTrue((try analyze(service,project:project)["suggestions"] as? [JSON] ?? []).isEmpty)
            try ingestSequence(engine,directory:directory,project:project,id:"seq3",commands:["git diff --stat","pnpm run test"])
            let result = try analyze(service,project:project)
            let suggestion = try XCTUnwrap((result["suggestions"] as? [JSON])?.first)
            XCTAssertEqual(string(suggestion,"discoveryKind"),"tool-sequence")
            XCTAssertEqual(intValue(suggestion,"distinctSessions"),3)
            XCTAssertEqual((suggestion["evidence"] as? [JSON])?.count,9)
            let draft = try XCTUnwrap(suggestion["workflowDraft"] as? JSON)
            XCTAssertEqual(draft["enabled"] as? Bool,false)
            let steps = try XCTUnwrap(draft["steps"] as? [JSON])
            XCTAssertEqual(steps.map {string($0,"tool")},["git.diff","shell.test"])
            XCTAssertEqual((steps[1]["arguments"] as? JSON)?["args"] as? [String],["run","test"])
            XCTAssertTrue(try store.list("workflow").isEmpty)
            XCTAssertTrue(try store.list("run").isEmpty)
            XCTAssertTrue(try store.list("approval").isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent("AGENTS.md").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent(".vela").path))
            _ = try analyze(service,project:project)
            XCTAssertEqual(try store.list("signal").count,3)
            XCTAssertEqual(try store.list("suggestion").count,1)
        }
    }

    func testProcedureRejectsTextMimicsWrongOrderUnrelatedDirectoriesAndChainedShell() throws {
        try fixture { base,project,store,service in
            let directory = base.appendingPathComponent("codex")
            let engine = FoundationService(store:store,sourceRoots:["codex":[directory]],globalHome:base.appendingPathComponent("home"))
            defer { engine.stopWatching() }
            for i in 1...3 {
                try ingestSequence(engine,directory:directory,project:project,id:"order\(i)",commands:["pnpm run test","git diff"])
                try ingestSequence(engine,directory:directory,project:project,id:"chained\(i)",commands:["git diff","pnpm test; touch should-not-run"])
                try ingestSequence(engine,directory:directory,project:project,id:"wrong-cwd\(i)",commands:["git diff","pnpm test"],cwd:base.path)
                try ingestSequence(engine,directory:directory,project:project,id:"no-summary\(i)",commands:["git diff","pnpm test"],summary:false)
                try ingestSequence(engine,directory:directory,project:project,id:"interleaved\(i)",commands:["git diff","pnpm test","git checkout other-feature"])
                try session(store,project:project,id:"text-only\(i)",texts:["[Tool: exec_command]\n{\"cmd\":\"git diff\"}","pnpm test","Summary"])
            }
            let result = try analyze(service,project:project)
            XCTAssertTrue((result["suggestions"] as? [JSON] ?? []).isEmpty)
            XCTAssertTrue((result["signals"] as? [JSON] ?? []).isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent("should-not-run").path))
        }
    }

    func testChangedSourceAndDuplicateMessageIDsDoNotAccumulatePromotionEvidence() throws {
        try fixture { _,project,store,service in
            let same: JSON = ["id":"duplicate","role":"user","content":"You forgot tests again"]
            _ = try store.put("session",["id":"duplicate-source","project":project.path,"messages":[same,same,same]])
            try session(store,project:project,id:"second",texts:["You forgot tests again"])
            XCTAssertTrue((try analyze(service,project:project)["suggestions"] as? [JSON] ?? []).isEmpty)
            try session(store,project:project,id:"duplicate-source",texts:["The feature works. Please add a test button."])
            let result = try analyze(service,project:project)
            XCTAssertEqual((result["signals"] as? [JSON])?.count,1)
            XCTAssertTrue((result["suggestions"] as? [JSON] ?? []).isEmpty)
        }
    }

    func testCopiedProviderLogsDoNotMultiplySessionsOrCandidateMemories() throws {
        try fixture { base,project,store,service in
            let directory = base.appendingPathComponent("codex")
            let engine = FoundationService(store:store,sourceRoots:["codex":[directory]],globalHome:base.appendingPathComponent("home"))
            defer { engine.stopWatching() }
            try ingestSequence(engine,directory:directory,project:project,id:"one-provider-session",commands:["git diff","pnpm test"])
            let source = directory.appendingPathComponent("one-provider-session.jsonl")
            let record: JSON = ["type":"response_item","timestamp":"2026-09-12T10:00:03Z","payload":["type":"message","id":"lasting-constraint","role":"user","content":[["type":"input_text","text":"以后完成任务之前一定先跑测试"]]]]
            let handle = try FileHandle(forWritingTo:source)
            try handle.seekToEnd(); try handle.write(contentsOf:Data((try jsonString(record) + "\n").utf8)); try handle.close()
            for index in 1...2 {
                try FileManager.default.copyItem(at:source,to:directory.appendingPathComponent("copy-\(index).jsonl"))
            }
            _ = try engine.handle("sessions.refresh",[:])
            XCTAssertEqual(try store.list("session").count,3)
            let result = try analyze(service,project:project)
            XCTAssertEqual((result["signals"] as? [JSON])?.count,2)
            XCTAssertEqual((result["candidateMemories"] as? [JSON])?.count,1)
            XCTAssertEqual(try store.list("memory").count,1)
            XCTAssertTrue((result["suggestions"] as? [JSON] ?? []).isEmpty)
            XCTAssertTrue((result["clusters"] as? [JSON] ?? []).allSatisfy { intValue($0,"distinctSessions") == 1 })
        }
    }

    func testProposalSnapshotsRejectAncestorSymlinksAndOversizedFilesWithoutMutation() throws {
        try fixture { base,project,store,service in
            let safe = SafeApplyService(store:store)
            let absent = try safe.readSnapshot(project:project.path,path:"missing/AGENTS.md")
            XCTAssertEqual(absent["exists"] as? Bool,false)
            XCTAssertEqual(string(absent,"hash"),"absent")
            XCTAssertTrue(absent["content"] is NSNull)
            XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent("missing").path))

            let outside = base.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at:outside.appendingPathComponent("workflows"),withIntermediateDirectories:true)
            let sentinel = outside.appendingPathComponent("workflows/review-before-handoff.md")
            try Data("outside sentinel must not be read or changed".utf8).write(to:sentinel)
            try FileManager.default.createSymbolicLink(at:project.appendingPathComponent(".vela"),withDestinationURL:outside)
            XCTAssertThrowsError(try safe.readSnapshot(project:project.path,path:".vela/workflows/review-before-handoff.md")) { error in
                XCTAssertTrue(error.localizedDescription.contains("parent"))
            }
            for i in 1...3 { try session(store,project:project,id:"unsafe\(i)",texts:["You forgot tests again"]) }
            XCTAssertThrowsError(try analyze(service,project:project))
            XCTAssertTrue(try store.list("suggestion").isEmpty)
            XCTAssertEqual(try String(contentsOf:sentinel),"outside sentinel must not be read or changed")

            try FileManager.default.removeItem(at:project.appendingPathComponent(".vela"))
            let directory = project.appendingPathComponent(".vela/workflows")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let oversized = directory.appendingPathComponent("review-before-handoff.md")
            try Data(repeating:65,count:2_097_153).write(to:oversized)
            XCTAssertThrowsError(try safe.readSnapshot(project:project.path,path:oversized.path)) { error in
                XCTAssertTrue(error.localizedDescription.contains("bounded"))
            }
            XCTAssertThrowsError(try analyze(service,project:project))
            XCTAssertTrue(try store.list("suggestion").isEmpty)
            XCTAssertEqual((try oversized.resourceValues(forKeys:[.fileSizeKey])).fileSize,2_097_153)

            try Data("reviewable existing text".utf8).write(to:oversized)
            let snapshot = try safe.readSnapshot(project:project.path,path:oversized.path)
            XCTAssertEqual(snapshot["exists"] as? Bool,true)
            XCTAssertEqual(string(snapshot,"content"),"reviewable existing text")
            XCTAssertEqual(string(snapshot,"hash"),stableHash("reviewable existing text"))
            XCTAssertEqual((try analyze(service,project:project)["suggestions"] as? [JSON])?.count,1)
        }
    }
}
