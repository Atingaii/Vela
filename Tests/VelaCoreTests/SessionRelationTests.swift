import XCTest
@testable import VelaCore

final class SessionRelationTests: XCTestCase {
    private final class Fixture {
        let temporary: URL, logs: URL
        let project: String, other: String
        let store: VelaStore
        let service: FoundationService
        let parent = "00000000-0000-4000-8000-000000000001"
        let child = "00000000-0000-4000-8000-000000000002"
        let third = "00000000-0000-4000-8000-000000000003"
        init() throws {
            temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-relations-test-" + UUID().uuidString)
            logs = temporary.appendingPathComponent("sources")
            for path in [logs,temporary.appendingPathComponent("project"),temporary.appendingPathComponent("other")] { try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true) }
            project = canonicalProject(temporary.appendingPathComponent("project").path); other = canonicalProject(temporary.appendingPathComponent("other").path)
            store = try VelaStore(root:temporary.appendingPathComponent("store"))
            service = FoundationService(store:store,sourceRoots:["codex":[logs]],globalHome:temporary)
            for path in [project,other] { _ = try store.put("project",["id":stableHash(path),"path":path,"project":path,"title":"Synthetic relation project"]) }
        }
        deinit { try? FileManager.default.removeItem(at:temporary) }
        func header(_ id: String, parent: String? = nil, extra: JSON = [:]) -> JSON {
            var payload: JSON = ["id":id,"session_id":self.parent,"timestamp":"2026-09-13T00:00:00Z","cwd":project,"originator":"codex_cli_rs","cli_version":"0.154.0","source":"cli"]
            if let parent { payload["parent_thread_id"] = parent; payload["source"] = ["subagent":["thread_spawn":["parent_thread_id":parent,"depth":1] as JSON] as JSON] as JSON }
            payload.merge(extra){_,new in new}; return ["type":"session_meta","timestamp":"2026-09-13T00:00:00Z","payload":payload]
        }
        func status(_ type: String) -> JSON { ["type":"event_msg","timestamp":"2026-09-13T00:00:01Z","payload":["type":type]] }
        func spawn(_ id: String = "spawn-a", namespace: Any = "multi_agent_v1") throws -> JSON {
            ["type":"response_item","payload":["type":"function_call","namespace":namespace,"name":"spawn_agent","call_id":id,"arguments":try jsonString(["message":"SYNTHETIC_PROMPT_MUST_NOT_RETURN"])] as JSON]
        }
        func acknowledged(_ child: String, call: String = "spawn-a") throws -> JSON { ["type":"response_item","payload":["type":"function_call_output","call_id":call,"output":try jsonString(["agent_id":child,"nickname":NSNull()])] as JSON] }
        @discardableResult func write(_ name: String, _ rows: [JSON]) throws -> String {
            let path = logs.appendingPathComponent(name + ".jsonl")
            try (rows.map{try jsonString($0)}.joined(separator:"\n") + "\n").write(to:path,atomically:true,encoding:.utf8)
            return stableHash("codex:" + canonicalProject(path.path))
        }
        func append(_ name: String, _ rows: [JSON]) throws {
            let path = logs.appendingPathComponent(name + ".jsonl"), handle = try FileHandle(forWritingTo:path); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf:Data((rows.map{try jsonString($0)}.joined(separator:"\n")+"\n").utf8))
        }
        func refresh() throws { _ = try service.handle("sessions.refresh",[:]) }
        func call(_ name: String, _ values: JSON = [:]) throws -> JSON {
            var params = values; if name != "describe", params["project"] == nil { params["project"] = project }
            let response = try service.handle("sessions.relations." + name,params)
            return try XCTUnwrap(response as? JSON)
        }
        func detail(_ id: String) throws -> JSON { try call("get",["id":id]) }
        func facts(_ id: String) throws -> JSON { let value = try detail(id); return try XCTUnwrap(value["relation"] as? JSON) }
        func changeSession(_ id: String, _ change: JSON) throws {
            let response = try store.get("session",id); var source = try XCTUnwrap(response)
            source.merge(change){_,new in new}; _ = try store.put("session",source)
        }
    }
    func testMetadataParentForkAndRootSessionAreDistinctFacts() throws {
        let f = try Fixture(); let parent = try f.write("parent",[f.header(f.parent),f.status("task_complete")])
        let child = try f.write("child",[f.header(f.child,parent:f.parent,extra:["forked_from_id":f.third]),f.status("error")]); try f.refresh()
        let result = try f.detail(child), relation = try XCTUnwrap(result["relation"] as? JSON), resolved = try XCTUnwrap(result["parent"] as? JSON)
        XCTAssertEqual(string(relation,"parentThreadId"),f.parent); XCTAssertEqual(string(relation,"forkedFromThreadId"),f.third)
        XCTAssertEqual(string(relation,"relationshipKind"),"thread_spawn"); XCTAssertEqual(resolved["resolved"] as? Bool,true)
        XCTAssertEqual(string(resolved["source"] as? JSON ?? [:],"id"),parent)
        XCTAssertEqual(string(resolved["source"] as? JSON ?? [:],"observedState"),"Completed")
        XCTAssertEqual(string(result["source"] as? JSON ?? [:],"observedState"),"Error")
        XCTAssertEqual(string(result,"liveness"),"unknown")
        let page = try f.call("children",["id":parent]); XCTAssertEqual(intValue(page,"childErrorsOnPage"),1); XCTAssertEqual(string(page,"parentState"),"Completed")
    }
    func testOrdinaryForkAndRootSessionIDDoNotBecomeParent() throws {
        let f = try Fixture(); _ = try f.write("parent",[f.header(f.parent)])
        let fork = try f.write("fork",[f.header(f.child,extra:["forked_from_id":f.parent])]); try f.refresh()
        let result = try f.detail(fork); XCTAssertEqual(string(result["parent"] as? JSON ?? [:],"status"),"none_declared")
        XCTAssertEqual(string(result["relation"] as? JSON ?? [:],"relationshipKind"),"fork_only")
        XCTAssertTrue((try f.call("children",["id":stableHash("codex:"+canonicalProject(f.logs.appendingPathComponent("parent.jsonl").path))])["items"] as? [JSON] ?? []).isEmpty)
    }
    func testMatchingSpawnAcknowledgementIsSeparateFromChildMetadata() throws {
        let f = try Fixture(); let parent = try f.write("parent",[f.header(f.parent),try f.spawn()]); try f.refresh()
        let proposed = try f.call("events",["id":parent]); XCTAssertEqual((proposed["items"] as? [JSON] ?? []).map{string($0,"status")},["proposed"])
        try f.append("parent",[try f.acknowledged(f.child),f.status("task_complete")]); try f.refresh()
        let reported = try f.call("events",["id":parent]); let event = try XCTUnwrap((reported["items"] as? [JSON])?.last)
        XCTAssertEqual(string(event,"status"),"reported_spawned"); XCTAssertEqual(string(event["childResolution"] as? JSON ?? [:],"status"),"unavailable")
        _ = try f.write("child",[f.header(f.child,parent:f.parent),f.status("error")]); try f.refresh()
        let corroborated = try f.call("events",["id":parent]); let last = try XCTUnwrap((corroborated["items"] as? [JSON])?.last)
        XCTAssertEqual(string(last["childResolution"] as? JSON ?? [:],"parentEvidence"),"corroborated")
        XCTAssertFalse(try jsonString(corroborated).contains("SYNTHETIC_PROMPT_MUST_NOT_RETURN"))
    }
    func testTypedUnknownNamespaceAndUnpairedToolResultsCannotClaimChildren() throws {
        let f = try Fixture()
        let unknown: JSON = ["type":"response_item","payload":["type":"function_call_output","call_id":"missing","output":try jsonString(["agent_id":f.child])] as JSON]
        let parent = try f.write("parent",[f.header(f.parent),unknown,try f.spawn("foreign",namespace:"external.tool"),try f.acknowledged(f.child,call:"foreign"),try f.spawn("fail"),["type":"response_item","payload":["type":"function_call_output","call_id":"fail","output":"Provider rejected the request"]] as JSON]); try f.refresh()
        let statuses = (try f.call("events",["id":parent])["items"] as? [JSON] ?? []).map{string($0,"status")}
        XCTAssertFalse(statuses.contains("reported_spawned")); XCTAssertTrue(statuses.contains("unsupported_namespace")); XCTAssertTrue(statuses.contains("unknown_result"))
    }
    func testConflictingMetadataAndInvalidDepthCannotSelectAParent() throws {
        let f = try Fixture(); _ = try f.write("parent",[f.header(f.parent)])
        let conflict = try f.write("conflict",[f.header(f.child,parent:f.parent,extra:["source":["subagent":["thread_spawn":["parent_thread_id":f.third,"depth":1] as JSON] as JSON] as JSON])])
        let invalid = try f.write("invalid",[f.header(f.third,parent:f.parent,extra:["source":["subagent":["thread_spawn":["parent_thread_id":f.parent,"depth":true] as JSON] as JSON] as JSON])]); try f.refresh()
        XCTAssertEqual(string(try f.facts(conflict),"headerState"),"conflict")
        XCTAssertEqual(string(try f.facts(invalid),"headerState"),"invalid")
        XCTAssertEqual((try f.detail(conflict)["parent"] as? JSON)?["resolved"] as? Bool,false)
    }
    func testDuplicateSourceUUIDIsAmbiguousAndCannotSilentlyChooseAFile() throws {
        let f = try Fixture(); _ = try f.write("parent-a",[f.header(f.parent)]); _ = try f.write("parent-b",[f.header(f.parent)])
        let child = try f.write("child",[f.header(f.child,parent:f.parent)]); try f.refresh()
        XCTAssertEqual(string(try f.detail(child)["parent"] as? JSON ?? [:],"status"),"ambiguous")
        XCTAssertEqual(string(try f.call("resolve",["threadId":f.parent]),"status"),"ambiguous")
    }
    func testLaterConflictingHeaderCannotCorroborateOldSpawnAndInternalHeaderWithholdsSource() throws {
        let f = try Fixture()
        let parent = try f.write("parent",[f.header(f.parent),try f.spawn(),try f.acknowledged(f.child)])
        _ = try f.write("child",[f.header(f.child,parent:f.parent)])
        try f.refresh()
        try f.append("parent",[f.header(f.parent,extra:["forked_from_id":f.third])]); try f.refresh()
        let events = try f.call("events",["id":parent])["items"] as? [JSON] ?? []
        let report = try XCTUnwrap(events.first{string($0,"status") == "reported_spawned"})
        XCTAssertEqual(string(report["childResolution"] as? JSON ?? [:],"status"),"source_metadata_conflict")
        XCTAssertNil((report["childResolution"] as? JSON)?["source"])
        try f.append("parent",[f.header(f.parent,extra:["source":["internal":"guardian"] as JSON])]); try f.refresh()
        XCTAssertThrowsError(try f.detail(parent))
        XCTAssertEqual(string(try f.call("resolve",["threadId":f.parent]),"status"),"unavailable")
    }
    func testSameAcknowledgementBodyWithChangedNamespaceOrTypeInvalidatesUniqueReport() throws {
        for change: JSON in [["namespace":"foreign"],["name":"other_tool"],["output":["agent_id":"00000000-0000-4000-8000-000000000002"] as JSON]] {
            let f = try Fixture()
            let parent = try f.write("parent",[f.header(f.parent),try f.spawn(),try f.acknowledged(f.child)]); try f.refresh()
            var row = try f.acknowledged(f.child), payload = row["payload"] as? JSON ?? [:]
            payload.merge(change){_,new in new}; row["payload"] = payload
            try f.append("parent",[row]); try f.refresh()
            let events = try f.call("events",["id":parent])["items"] as? [JSON] ?? []
            XCTAssertFalse(events.contains{string($0,"status") == "reported_spawned"})
            XCTAssertTrue(events.contains{string($0,"status") == "conflict"})
        }
    }
    func testBoundedPrefixRequiresWholeHeaderLineAndPreservesLeadingNewlineOffset() throws {
        let f = try Fixture(); _ = try f.write("parent",[f.header(f.parent)])
        let row = try jsonString(f.header(f.child,parent:f.parent))
        let tail = String(repeating:try jsonString(f.status("task_complete")) + "\n",count:4000)
        let path = f.logs.appendingPathComponent("child.jsonl")
        // The 32 KiB prefix is valid JSON plus whitespace, but the actual full
        // record has trailing invalid bytes outside that prefix.
        let falseHeader = row + String(repeating:" ",count:40000) + "INVALID_RECORD_SUFFIX\n" + tail
        try falseHeader.write(to:path,atomically:true,encoding:.utf8); try f.refresh()
        XCTAssertNotEqual(string(try f.call("resolve",["threadId":f.child]),"status"),"resolved")
        let trueHeader = "\n" + row + "\n" + tail
        try trueHeader.write(to:path,atomically:true,encoding:.utf8); try f.refresh()
        let id = stableHash("codex:" + canonicalProject(path.path)), detail = try f.detail(id)
        let evidence = try XCTUnwrap(detail["headerEvidence"] as? JSON)
        XCTAssertEqual(intValue(evidence,"byteOffset"),1)
        XCTAssertEqual(intValue(evidence,"byteLength"),row.utf8.count)
        XCTAssertEqual(string(evidence,"sha256"),stableHash(row))
        XCTAssertEqual((detail["parent"] as? JSON)?["resolved"] as? Bool,true)
        XCTAssertEqual((detail["relation"] as? JSON)?["coverageLimited"] as? Bool,true)
    }
    func testCrossProjectPrivateAndInternalSourcesRemainUnavailable() throws {
        let f = try Fixture(); let parent = try f.write("parent",[f.header(f.parent,extra:["cwd":f.other])]); let child = try f.write("child",[f.header(f.child,parent:f.parent)]); try f.refresh()
        XCTAssertEqual(string(try f.detail(child)["parent"] as? JSON ?? [:],"status"),"unavailable")
        XCTAssertThrowsError(try f.detail(parent))
        _ = try f.write("parent",[f.header(f.parent)]); try f.refresh()
        for flags: JSON in [["private":true],["private":false,"internalRun":true],["internalRun":false,"sourceLabeledPrivate":"false"],["sourceLabeledPrivate":false,"scope":"private"]] {
            try f.changeSession(parent,flags)
            XCTAssertEqual(string(try f.detail(child)["parent"] as? JSON ?? [:],"status"),"unavailable")
            XCTAssertThrowsError(try f.detail(parent))
        }
    }
    func testExplicitProviderInternalSourceIsExcludedWithoutInventingLegacySubtype() throws {
        let f = try Fixture(); let parent = try f.write("parent",[f.header(f.parent)])
        let hidden = try f.write("internal",[f.header(f.child,parent:f.parent,extra:["source":["internal":"guardian"] as JSON])])
        let legacy = try f.write("legacy",[f.header(f.third,parent:f.parent,extra:["source":["subagent":"memory_consolidation"] as JSON])]); try f.refresh()
        XCTAssertThrowsError(try f.detail(hidden))
        XCTAssertEqual(string(try f.call("resolve",["threadId":f.child]),"status"),"unavailable")
        XCTAssertEqual(string(try f.facts(legacy),"relationshipKind"),"provider_parent_metadata")
        let rows = try f.call("children",["id":parent])["items"] as? [JSON] ?? []
        XCTAssertEqual(rows.count,1); XCTAssertEqual(string(rows[0]["source"] as? JSON ?? [:],"id"),legacy)
    }
    func testChildPaginationAdvancesPastWithheldRowsWithoutLoadingBodies() throws {
        let f = try Fixture(); let parent = try f.write("parent",[f.header(f.parent)])
        var children: [String] = []
        for number in 2...4 { let uuid = String(format:"00000000-0000-4000-8000-%012d",number); children.append(try f.write("child-\(number)",[f.header(uuid,parent:f.parent)])) }
        try f.refresh(); children.sort(); try f.changeSession(children[0],["private":true,"content":String(repeating:"hidden",count:100000)])
        let first = try f.call("children",["id":parent,"limit":1]); XCTAssertTrue((first["items"] as? [JSON] ?? []).isEmpty); XCTAssertEqual(intValue(first,"scanned"),1)
        let next = try XCTUnwrap(first["nextCursor"] as? String)
        let second = try f.call("children",["id":parent,"limit":1,"after":next]); let source = try XCTUnwrap((second["items"] as? [JSON])?.first?["source"] as? JSON)
        XCTAssertEqual(string(source,"id"),children[1]); XCTAssertNil(source["content"]); XCTAssertNil(source["messages"])
        XCTAssertFalse(try jsonString(second).contains("hidden"))
    }
    func testRewriteChangesEpochAndClearsOldParentAndRejectsOldCursor() throws {
        let f = try Fixture(); let parent = try f.write("parent",[f.header(f.parent),try f.spawn(),try f.acknowledged(f.child)])
        let child = try f.write("child",[f.header(f.child,parent:f.parent)]); _ = try f.write("child-2",[f.header(f.third,parent:f.parent)]); try f.refresh()
        let page = try f.call("children",["id":parent,"limit":1]), oldEpoch = string(try f.facts(parent),"relationEpoch")
        let cursor = try XCTUnwrap(page["nextCursor"] as? String)
        _ = try f.write("parent",[f.header(f.parent)]); _ = try f.write("child",[f.header(f.child)]); try f.refresh()
        XCTAssertNotEqual(string(try f.facts(parent),"relationEpoch"),oldEpoch)
        XCTAssertEqual(string(try f.facts(child),"relationshipKind"),"none_observed")
        XCTAssertThrowsError(try f.call("children",["id":parent,"after":cursor]))
        XCTAssertThrowsError(try f.call("events",["id":parent,"afterSequence":1,"epoch":oldEpoch]))
    }
    func testRestartAndIncrementalAcknowledgementKeepEpochAndEvidenceOffsets() throws {
        let f = try Fixture(); let parent = try f.write("parent",[f.header(f.parent),try f.spawn()]); try f.refresh()
        let epoch = string(try f.facts(parent),"relationEpoch")
        try f.append("parent",[try f.acknowledged(f.child)])
        let restarted = FoundationService(store:f.store,sourceRoots:["codex":[f.logs]],globalHome:f.temporary); _ = try restarted.handle("sessions.refresh",[:])
        XCTAssertEqual(string(try f.facts(parent),"relationEpoch"),epoch)
        let events = try f.call("events",["id":parent]), last = try XCTUnwrap((events["items"] as? [JSON])?.last)
        XCTAssertEqual(string(last,"status"),"reported_spawned")
        let reference = try XCTUnwrap(last["reference"] as? JSON); XCTAssertGreaterThan(intValue(reference,"byteOffset"),0)
        XCTAssertEqual(string(reference,"sha256").count,64); XCTAssertNotNil(reference["proposalReference"])
    }
    func testConflictingAcknowledgementInvalidatesEarlierReportedChild() throws {
        let f = try Fixture(); let parent = try f.write("parent",[f.header(f.parent),try f.spawn(),try f.acknowledged(f.child),try f.acknowledged(f.third)]); try f.refresh()
        let events = try f.call("events",["id":parent])["items"] as? [JSON] ?? []
        XCTAssertFalse(events.contains{string($0,"status") == "reported_spawned"}); XCTAssertTrue(events.contains{string($0,"status") == "conflict"})
    }
    func testCyclesAreReportedWithoutPropagatingStates() throws {
        let f = try Fixture(); let parent = try f.write("parent",[f.header(f.parent,parent:f.child),f.status("task_complete")])
        let child = try f.write("child",[f.header(f.child,parent:f.parent),f.status("error")]); try f.refresh()
        XCTAssertEqual(string(try f.detail(child)["parent"] as? JSON ?? [:],"status"),"cycle")
        XCTAssertEqual(string(try f.detail(parent)["source"] as? JSON ?? [:],"observedState"),"Completed")
    }
    func testSameInodeGrowingHeaderRewriteStartsNewRelationEpoch() throws {
        let f = try Fixture(); _ = try f.write("parent",[f.header(f.parent)]); _ = try f.write("other-parent",[f.header(f.third)])
        let child = try f.write("child",[f.header(f.child,parent:f.parent)]); try f.refresh()
        let previous = string(try f.facts(child),"relationEpoch"), path = f.logs.appendingPathComponent("child.jsonl")
        let inode = try FileManager.default.attributesOfItem(atPath:path.path)[.systemFileNumber] as? NSNumber
        let rows = [f.header(f.child,parent:f.third)] + Array(repeating:f.status("task_complete"),count:20)
        let data = Data(try rows.map{try jsonString($0)}.joined(separator:"\n").appending("\n").utf8)
        let handle = try FileHandle(forWritingTo:path); try handle.seek(toOffset:0); try handle.write(contentsOf:data); try handle.truncate(atOffset:UInt64(data.count)); try handle.close()
        let nextInode = try FileManager.default.attributesOfItem(atPath:path.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(inode,nextInode)
        try f.refresh()
        XCTAssertNotEqual(string(try f.facts(child),"relationEpoch"),previous)
        XCTAssertEqual(string(try f.facts(child),"parentThreadId"),f.third)
        XCTAssertEqual(string(try f.detail(child)["parent"] as? JSON ?? [:],"declaredThreadId"),f.third)
    }
    func testPaginationTypesAndProjectArgumentsAreStrict() throws {
        let f = try Fixture(); let parent = try f.write("parent",[f.header(f.parent)]); try f.refresh()
        for raw: Any in [true,1.5,-1,101,"2"] { XCTAssertThrowsError(try f.call("children",["id":parent,"limit":raw])) }
        XCTAssertThrowsError(try f.call("get",["id":parent,"includePrivate":true]))
        XCTAssertThrowsError(try f.call("get",["id":parent,"project":f.temporary.path]))
        XCTAssertThrowsError(try f.call("resolve",["threadId":"not-a-uuid"]))
        XCTAssertThrowsError(try f.call("events",["id":parent,"afterSequence":1]))
        XCTAssertEqual(string(try f.call("describe"),"referenceCommit"),SessionRelationProjection.sourceCommit)
    }
}
