import XCTest
import CoreServices
@testable import VelaCore

final class WorkflowFileWatchTests: XCTestCase {
    private let base = Date(timeIntervalSince1970:1_789_257_600)
    private func fixture(_ body: (URL,VelaStore,AutomationService) throws -> Void) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vela-file-watch-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let raw = temp.appendingPathComponent("project"); try FileManager.default.createDirectory(at:raw,withIntermediateDirectories:true)
        let root = URL(fileURLWithPath:canonicalProject(raw.path)), store = try VelaStore(root:temp.appendingPathComponent("store"))
        _ = try store.put("project",["project":root.path,"path":root.path]); _ = try AutomationProcess.git(["init","-q"],cwd:root.path)
        let service = AutomationService(store:store)
        defer { service.fileWatchEvents.stop() }
        try body(root,store,service)
    }
    private func policy(_ paths: [String] = ["."], recursive: Bool = true, ignore: [String] = []) throws -> JSON {
        try WorkflowWatch.validate(["source":"files","paths":paths,"recursive":recursive,"ignore":ignore,"debounceSeconds":0])
    }
    private func save(_ service: AutomationService, _ root: URL, _ policy: JSON) throws -> JSON {
        try XCTUnwrap(service.handle("workflows.save",["title":"File watch fixture","project":root.path,"trigger":"watch","enabled":true,"watch":policy,"steps":[["tool":"git.status","arguments":JSON()]]]) as? JSON)
    }
    private func entries(_ root: URL, _ policy: JSON) throws -> JSON {
        let valueToUnwrap = try WorkflowFileWatch.scan(project:root.path,policy:policy)["entries"] as? JSON
        return try XCTUnwrap(valueToUnwrap)
    }
    private func waitForEvent(_ service: AutomationService, id: String, after: Int) throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if intValue(try service.fileWatchEvents.signal(id),"serial") > after { return }
            Thread.sleep(forTimeInterval:0.02)
        }
        XCTFail("Real FSEvents did not observe the synthetic change")
    }
    func testByteHashesDetectSameSizeSameMtimeAndAtomicReplacementWithoutFalseSameContentChange() throws {
        try fixture { root,_,_ in
            let policy = try policy(), path = root.appendingPathComponent("binary.dat")
            try Data([0,1,2,3]).write(to:path)
            let before = try entries(root,policy), date = try FileManager.default.attributesOfItem(atPath:path.path)[.modificationDate]!
            try Data([3,2,1,0]).write(to:path)
            try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:path.path)
            let changed = try entries(root,policy)
            XCTAssertEqual(try WorkflowWatch.merge(previous:before,current:changed,pending:[:]).count,1)
            try Data([3,2,1,0]).write(to:path,options:.atomic)
            let replacement = try entries(root,policy)
            XCTAssertEqual(try WorkflowWatch.merge(previous:changed,current:replacement,pending:[:]).count,0)
            try Data([9,8,7,6]).write(to:path,options:.atomic)
            XCTAssertEqual(try WorkflowWatch.merge(previous:replacement,current:entries(root,policy),pending:[:]).count,1)
        }
    }
    func testRenameDeleteAndEmptyDirectoryChangesHaveActualIdentityEvidence() throws {
        try fixture { root,_,_ in
            let policy = try policy(), first = root.appendingPathComponent("a.txt"), moved = root.appendingPathComponent("z.txt")
            try Data("rename".utf8).write(to:first); let before = try entries(root,policy)
            try FileManager.default.moveItem(at:first,to:moved)
            let after = try entries(root,policy), changes = WorkflowFileWatch.changes(try WorkflowWatch.merge(previous:before,current:after,pending:[:]))
            XCTAssertEqual(changes.count,1); XCTAssertEqual(string(changes[0],"type"),"renamed")
            XCTAssertTrue(try jsonString(changes[0]["before"]!).contains("a.txt")); XCTAssertTrue(try jsonString(changes[0]["after"]!).contains("z.txt"))
            try FileManager.default.removeItem(at:moved)
            let deletion = WorkflowFileWatch.changes(try WorkflowWatch.merge(previous:after,current:entries(root,policy),pending:[:]))
            XCTAssertEqual(deletion.count,1); XCTAssertEqual(string(deletion[0],"type"),"removed")
            let empty = try entries(root,policy)
            try FileManager.default.createDirectory(at:root.appendingPathComponent("empty"),withIntermediateDirectories:true)
            XCTAssertEqual(try WorkflowWatch.merge(previous:empty,current:entries(root,policy),pending:[:]).count,1)
        }
    }
    func testRecursiveScopeIgnoreAndPrivateRootsRemainExcluded() throws {
        try fixture { root,_,_ in
            for directory in ["src/nested","private","src/cache"] { try FileManager.default.createDirectory(at:root.appendingPathComponent(directory),withIntermediateDirectories:true) }
            for file in ["src/main.swift","src/nested/child.swift","private/secret.txt","src/cache/transient.txt"] { try Data("data".utf8).write(to:root.appendingPathComponent(file)) }
            let full = try entries(root,policy(["src"],ignore:["**/cache/**"]))
            XCTAssertTrue(try jsonString(full).contains("child.swift")); XCTAssertFalse(try jsonString(full).contains("transient"))
            let flat = try entries(root,policy(["src"],recursive:false))
            XCTAssertTrue(try jsonString(flat).contains("main.swift")); XCTAssertFalse(try jsonString(flat).contains("child.swift"))
            XCTAssertFalse(try jsonString(entries(root,policy())).contains("secret.txt"))
            XCTAssertThrowsError(try policy(["private"]))
            XCTAssertThrowsError(try policy(["../escape"]))
            XCTAssertThrowsError(try policy([".","src"]))
            XCTAssertTrue(WorkflowFileWatch.glob("src/cache","**/cache/**"))
            XCTAssertTrue(WorkflowFileWatch.glob("src/cache/item.tmp","**/cache/**"))
            XCTAssertTrue(WorkflowFileWatch.glob("src/file.tmp","*.tmp"))
            XCTAssertFalse(WorkflowFileWatch.glob("src/cache/item","cache/**"))
            XCTAssertFalse(WorkflowFileWatch.glob("src/deep/file.tmp","src/*.tmp"))
        }
    }
    func testSymlinkHardlinkFIFOAndOversizedFilesFailWithoutFollowingOrBlocking() throws {
        try fixture { root,_,_ in
            let target = root.appendingPathComponent("safe.txt"); try Data("safe".utf8).write(to:target)
            let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:target.path)
            XCTAssertThrowsError(try entries(root,policy(["link"])))
            let hard = root.appendingPathComponent("hard"); try FileManager.default.linkItem(at:target,to:hard)
            XCTAssertThrowsError(try entries(root,policy(["hard"])))
            let fifo = root.appendingPathComponent("fifo"); XCTAssertEqual(mkfifo(fifo.path,0o600),0)
            let began = Date(); XCTAssertThrowsError(try entries(root,policy(["fifo"]))); XCTAssertLessThan(Date().timeIntervalSince(began),1)
            let large = root.appendingPathComponent("large"); try Data(repeating:0,count:2_097_153).write(to:large)
            XCTAssertThrowsError(try entries(root,policy(["large"])))
        }
    }
    func testActualFSEventsTriggersOnceWhileIdleTicksDoNotReadFileContentsAgain() throws {
        try fixture { root,store,service in
            let workflow = try save(service,root,policy(["watched.txt"]))
            try service.tick(at:base)
            let id = string(workflow,"id"), serial = intValue(try service.fileWatchEvents.signal(id),"serial")
            try Data("observed".utf8).write(to:root.appendingPathComponent("watched.txt")); try waitForEvent(service,id:id,after:serial)
            try service.tick(at:base.addingTimeInterval(30))
            XCTAssertEqual(try store.list("run").count,1)
            // Drain coalesced kernel delivery before measuring a stable idle interval.
            Thread.sleep(forTimeInterval:0.4); try service.tick(at:base.addingTimeInterval(60))
            let count = intValue(try XCTUnwrap(store.get("watch_state",id)),"pollCount")
            for minute in 3...10 { try service.tick(at:base.addingTimeInterval(Double(minute * 30))) }
            XCTAssertEqual(intValue(try XCTUnwrap(store.get("watch_state",id)),"pollCount"),count)
            XCTAssertEqual(try store.list("run").count,1)
            XCTAssertNotEqual(string(try XCTUnwrap(store.get("watch_state",id)),"fileEventID"),"unavailable")
        }
    }
    func testRestartReconcilesByteChangesWithoutInventingIntermediateEventsOrRepeatingOldDispatch() throws {
        try fixture { root,store,service in
            let workflow = try save(service,root,policy(["offline.txt"]))
            try Data("before".utf8).write(to:root.appendingPathComponent("offline.txt")); try service.tick(at:base)
            service.fileWatchEvents.stop()
            try Data("middle".utf8).write(to:root.appendingPathComponent("offline.txt")); try Data("after".utf8).write(to:root.appendingPathComponent("offline.txt"))
            let reopened = AutomationService(store:try VelaStore(root:store.root)); defer { reopened.fileWatchEvents.stop() }
            try reopened.tick(at:base.addingTimeInterval(30))
            XCTAssertEqual(try store.list("run").count,1)
            let event = try XCTUnwrap(store.list("schedule_event").first), input = try XCTUnwrap(event["watchInput"] as? JSON)
            XCTAssertEqual((input["changes"] as? [JSON])?.count,1)
            XCTAssertFalse(try jsonString(input).contains("middle"))
            let second = AutomationService(store:try VelaStore(root:store.root)); defer { second.fileWatchEvents.stop() }
            try second.tick(at:base.addingTimeInterval(60))
            XCTAssertEqual(try store.list("run").count,1)
            XCTAssertEqual(string(try XCTUnwrap(store.get("watch_state",string(workflow,"id"))),"state"),"watching")
        }
    }
    func testDroppedEventRescansAndPreviewNeverStartsOrUpdatesTheObserver() throws {
        try fixture { root,store,service in
            let workflow = try save(service,root,policy(["dropped.txt"]))
            let preview = try XCTUnwrap(service.handle("watches.preview",["id":workflow["id"]!,"project":root.path]) as? JSON)
            XCTAssertEqual(preview["mutated"] as? Bool,false); XCTAssertThrowsError(try service.fileWatchEvents.signal(string(workflow,"id")))
            XCTAssertEqual(try store.list("watch_state").count,0)
            try service.tick(at:base)
            let prior = intValue(try XCTUnwrap(store.get("watch_state",string(workflow,"id"))),"pollCount")
            service.fileWatchEvents.receive(path:root.path,flags:FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped),eventID:123)
            try service.tick(at:base.addingTimeInterval(30))
            let state = try XCTUnwrap(store.get("watch_state",string(workflow,"id")))
            XCTAssertEqual(intValue(state,"pollCount"),prior + 1); XCTAssertEqual(state["historyIncomplete"] as? Bool,true)
            XCTAssertEqual(try store.list("run").count,0)
        }
    }
    func testSameObserverRestartReconcilesItsUnobservedGap() throws {
        try fixture { root,store,service in
            let workflow = try save(service,root,policy(["gap.txt"]))
            try service.tick(at:base)
            service.fileWatchEvents.stop()
            try Data("changed while stopped".utf8).write(to:root.appendingPathComponent("gap.txt"))
            try service.tick(at:base.addingTimeInterval(30))
            XCTAssertEqual(try store.list("run").count,1)
            XCTAssertEqual(try store.get("watch_state",string(workflow,"id"))?["historyIncomplete"] as? Bool,true)
        }
    }
}
