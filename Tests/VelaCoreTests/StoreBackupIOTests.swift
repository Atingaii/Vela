import Foundation
import Darwin
import CryptoKit
import XCTest
@testable import VelaCore

final class StoreBackupIOTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".task-tmp/backup-io-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        try body(root)
    }
    func testStreamingCopyHashesEmptyAndContentWithoutWholeFileAssumption() throws {
        try fixture { root in
            let source=root.appendingPathComponent("source"), target=root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true); try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            for (name,data) in [("empty",Data()),("content",Data("chunked backup bytes".utf8))] {
                try data.write(to:source.appendingPathComponent(name))
                let copied=try StoreBackupFiles.copy(root:source,path:name,destination:target,limit:1024,deadline:Date().addingTimeInterval(5))
                let digest=try StoreBackupFiles.digest(root:target,path:name,limit:1024,deadline:Date().addingTimeInterval(5))
                XCTAssertEqual(copied.sha256,digest.sha256); XCTAssertEqual(copied.bytes,data.count)
                XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(name)),data)
                XCTAssertEqual(copied.sha256,SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined())
            }
        }
    }
    func testRejectsOverLimitSparseRegularFileWithoutCopy() throws {
        try fixture { root in
            let source=root.appendingPathComponent("source"), target=root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true); try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            let file=source.appendingPathComponent("large"); FileManager.default.createFile(atPath:file.path,contents:nil)
            let fd=Darwin.open(file.path,O_WRONLY); XCTAssertTrue(fd >= 0); XCTAssertEqual(ftruncate(fd,Int64(StoreBackupFiles.maximumFileBytes)+1),0); Darwin.close(fd)
            XCTAssertThrowsError(try StoreBackupFiles.copy(root:source,path:"large",destination:target,limit:StoreBackupFiles.maximumFileBytes,deadline:Date().addingTimeInterval(5)))
            XCTAssertFalse(FileManager.default.fileExists(atPath:target.appendingPathComponent("large").path))
        }
    }
    func testRejectsSymlinkHardlinkAndFIFO() throws {
        try fixture { root in
            let source=root.appendingPathComponent("source"); try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
            let regular=source.appendingPathComponent("regular"); try Data("x".utf8).write(to:regular)
            try FileManager.default.createSymbolicLink(at:source.appendingPathComponent("link"),withDestinationURL:regular)
            XCTAssertEqual(link(regular.path,source.appendingPathComponent("hard").path),0)
            XCTAssertEqual(mkfifo(source.appendingPathComponent("pipe").path,0o600),0)
            for name in ["link","hard","pipe"] { XCTAssertThrowsError(try StoreBackupFiles.digest(root:source,path:name,limit:1024,deadline:Date().addingTimeInterval(2))) }
        }
    }
    func testNonAssetRemovalInsideIngestionTransactionRollsBack() throws {
        try fixture { root in
            let store=try VelaStore(root:root.appendingPathComponent("store")); _ = try store.put("session",["id":"derived","project":root.path,"title":"derived","content":"x"])
            XCTAssertThrowsError(try store.withIngestionPolicyTransaction { try store.remove("session","derived"); throw VelaError("fixture rollback") })
            XCTAssertNotNil(try store.get("session","derived"))
        }
    }
}
