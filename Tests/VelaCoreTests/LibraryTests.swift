import Foundation
import XCTest
import Darwin
@testable import VelaCore

final class LibraryTests: XCTestCase {
    private func fixture(_ body: (URL,VelaStore,LibraryService,String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vela-library-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let project = directory.appendingPathComponent("project"); try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let store = try VelaStore(root:directory.appendingPathComponent("store"))
        try body(directory,store,LibraryService(store:store),canonicalProject(project.path))
    }
    private func call(_ service: LibraryService,_ method: String,_ params: JSON) throws -> JSON {
        let valueToUnwrap = try service.handle(method,params) as? JSON
        return try XCTUnwrap(valueToUnwrap)
    }
    private func review(_ service: LibraryService,_ id: String,_ project: String) throws -> JSON {
        ["id":id,"project":project,"snapshotHash":try call(service,"library.get",["id":id,"project":project])["snapshotHash"]!]
    }
    func testEditArchiveRestoreAndHistoryKeepReviewedVersionsAndExternalSource() throws {
        try fixture { directory,store,service,project in
            let source = directory.appendingPathComponent("notes.md"); try "First original reference".write(to:source,atomically:true,encoding:.utf8)
            let created = try call(service,"library.add",["project":project,"title":"Reference","path":source.path,"private":false])
            let id = string(created,"id"), oldReview = try review(service,id,project)
            var edit = oldReview; edit["content"] = "Reviewed local correction"; edit["folder"] = "engineering/parser"
            let updated = try call(service,"library.update",edit)
            XCTAssertEqual(intValue(updated,"version"),2); XCTAssertEqual(string(updated,"folder"),"engineering/parser")
            XCTAssertEqual(try String(contentsOf:source),"First original reference")
            XCTAssertThrowsError(try call(service,"library.remove",oldReview))
            let archived = try call(service,"library.remove",review(service,id,project))
            XCTAssertEqual(string(archived,"state"),"archived")
            XCTAssertEqual((try service.handle("library.list",["project":project]) as? [JSON])?.count,0)
            XCTAssertEqual((try service.handle("library.list",["project":project,"includeArchived":true]) as? [JSON])?.count,1)
            let restored = try call(service,"library.restore",review(service,id,project))
            XCTAssertEqual(string(restored,"content"),"Reviewed local correction"); XCTAssertEqual(string(restored,"state"),"active")
            XCTAssertEqual((try service.handle("library.history",["project":project,"id":id]) as? [JSON])?.count,4)
            XCTAssertEqual(try store.list("library").count,1)
        }
    }
    func testSourceRefreshIsExplicitRetainsOldVersionOnFailureAndRejectsWrongScope() throws {
        try fixture { directory,_,service,project in
            let source = directory.appendingPathComponent("notes.org"); try "Original source".write(to:source,atomically:true,encoding:.utf8)
            let item = try call(service,"library.add",["project":project,"title":"Org notes","path":source.path])
            XCTAssertEqual(item["private"] as? Bool,true)
            let id = string(item,"id"); try "Updated source".write(to:source,atomically:true,encoding:.utf8)
            XCTAssertEqual(string(try call(service,"library.get",["project":project,"id":id])["item"] as? JSON ?? [:],"content"),"Original source")
            let updated = try call(service,"library.refresh",review(service,id,project))
            XCTAssertEqual(string(updated,"content"),"Updated source")
            XCTAssertEqual(string(updated,"sourceHash"),stableHash("Updated source"))
            try FileManager.default.removeItem(at:source)
            XCTAssertThrowsError(try call(service,"library.refresh",review(service,id,project)))
            let latest = try call(service,"library.get",["project":project,"id":id])["item"] as? JSON ?? [:]
            XCTAssertEqual(intValue(latest,"version"),2); XCTAssertEqual(string(latest,"content"),"Updated source")
            for method in ["library.get","library.history","library.export","library.remove"] { XCTAssertThrowsError(try service.handle(method,["id":id,"project":project + "-foreign","snapshotHash":"ignored"])) }
        }
    }
    func testSourceSelectorMetadataAndPrivacyCannotBeInjected() throws {
        try fixture { _,_,service,project in
            let base: JSON = ["project":project,"title":"Reference","content":"Ordinary content"]
            for patch: JSON in [["private":0],["private":"false"],["state":"active"],["kind":"memory"],["sourcePath":"/private/stolen"],["url":"https://example.invalid"],["folder":"../escape"],["title":String(repeating:"x",count:301)]] {
                var params = base; params.merge(patch) { _,new in new }; XCTAssertThrowsError(try service.handle("library.add",params))
            }
            var params = base; params["id"] = "chosen"
            _ = try call(service,"library.add",params)
            XCTAssertThrowsError(try call(service,"library.add",params))
        }
    }
    func testPrivateLabeledAliasCannotBePublishedAfterImport() throws {
        try fixture { directory,_,service,project in
            let privateDir = directory.appendingPathComponent("private"); try FileManager.default.createDirectory(at:privateDir,withIntermediateDirectories:true)
            let publicSource = directory.appendingPathComponent("source.md"); try "Private labeled evidence".write(to:publicSource,atomically:true,encoding:.utf8)
            let alias = privateDir.appendingPathComponent("alias.md"); try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:publicSource)
            let imported = try call(service,"library.add",["project":project,"title":"Explicit private alias","path":alias.path,"private":false])
            XCTAssertEqual(imported["private"] as? Bool,true); XCTAssertEqual(imported["sourceLabeledPrivate"] as? Bool,true)
            var update = try review(service,string(imported,"id"),project); update["private"] = false
            XCTAssertThrowsError(try call(service,"library.update",update))
        }
    }
    func testUnsafeAndOversizedSourcesAreRejectedWithoutBlocking() throws {
        try fixture { directory,_,service,project in
            let fifo = directory.appendingPathComponent("pipe.md"); XCTAssertEqual(mkfifo(fifo.path,0o600),0)
            let source = directory.appendingPathComponent("source.md"); try "source".write(to:source,atomically:true,encoding:.utf8)
            let link = directory.appendingPathComponent("hard.md"); try FileManager.default.linkItem(at:source,to:link)
            let large = directory.appendingPathComponent("large.md"); try Data(repeating:65,count:2_097_153).write(to:large)
            let started = Date()
            for path in [fifo.path,link.path,large.path] { XCTAssertThrowsError(try call(service,"library.add",["project":project,"title":"Unsafe","path":path])) }
            XCTAssertLessThan(Date().timeIntervalSince(started),2)
        }
    }
    func testExportIsExplicitAndDoesNotChangePrivateContentOrWriteFiles() throws {
        try fixture { _,store,service,project in
            let item = try call(service,"library.add",["project":project,"title":"User <heading>","content":"Do not reinterpret `commands` & 用户原文."])
            let exported = try call(service,"library.export",["project":project,"id":item["id"]!])
            XCTAssertEqual(exported["writesSource"] as? Bool,false); XCTAssertEqual(exported["private"] as? Bool,true)
            XCTAssertEqual(string(exported,"content"),"# User <heading>\n\nDo not reinterpret `commands` & 用户原文.\n")
            XCTAssertEqual(try store.list("library_version").count,1)
        }
    }
    func testActualOfficeAndPlainTextFormatsExtractWithoutChangingSources() throws {
        try fixture { directory,_,service,project in
            let source = directory.appendingPathComponent("reference.txt")
            let original = "A real converted engineering reference. 原始资料。"
            try original.write(to:source,atomically:true,encoding:.utf8)
            for format in ["doc","docx","odt","rtf"] {
                let target = directory.appendingPathComponent("reference." + format)
                let converted = try FoundationCommand.run("/usr/bin/textutil",["-convert",format,"-output",target.path,source.path],timeout:15)
                XCTAssertEqual(converted.code,0)
                let before = try Data(contentsOf:target)
                let imported = try call(service,"library.add",["project":project,"title":format,"path":target.path])
                XCTAssertTrue(string(imported,"content").contains(original),format)
                XCTAssertEqual(try Data(contentsOf:target),before)
            }
            for format in ["md","rst","org","txt"] {
                let target = directory.appendingPathComponent("plain." + format)
                try original.write(to:target,atomically:true,encoding:.utf8)
                let imported = try call(service,"library.add",["project":project,"title":format,"path":target.path])
                XCTAssertEqual(string(imported,"content"),original)
            }
        }
    }
}
