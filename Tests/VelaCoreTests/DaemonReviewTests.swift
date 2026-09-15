import XCTest
import Darwin
@testable import VelaCore

final class DaemonReviewTests: XCTestCase {
    private func fixture(_ body: (VelaDaemonService,URL) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-daemon-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let home = temporary.appendingPathComponent("user")
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        let store = try VelaStore(root:temporary.appendingPathComponent("store"))
        let service = try VelaDaemonService(store:store,executable:"/usr/bin/true",userHome:home)
        try body(service,temporary)
    }

    func testExistingFIFOIsRejectedWithoutBlockingOrModifyingIt() throws {
        try fixture { service,_ in
            _ = try service.install()
            let path = try requireString(service.plan(),"path")
            try FileManager.default.removeItem(atPath:path)
            XCTAssertEqual(mkfifo(path,0o600),0)
            let started = Date()
            XCTAssertThrowsError(try service.install())
            XCTAssertThrowsError(try service.stop())
            XCTAssertLessThan(Date().timeIntervalSince(started),1)
            var info = stat(); XCTAssertEqual(lstat(path,&info),0)
            XCTAssertEqual(info.st_mode & S_IFMT,S_IFIFO)
        }
    }

    func testLoadedJobMustMatchBothDiskPathAndEveryArgument() throws {
        try fixture { service,_ in
            let plan = try service.plan()
            let path = try requireString(plan,"path")
            let args = service.configuration()["ProgramArguments"] as? [String] ?? []
            let valid = "gui/501/fixture = {\n path = \(path)\n program = \(args[0])\n arguments = {\n\(args.joined(separator:"\n"))\n}\n}\n"
            XCTAssertTrue(service.loadedJobMatches(valid))
            XCTAssertFalse(service.loadedJobMatches(valid.replacingOccurrences(of:"--home",with:"--other")))
            XCTAssertFalse(service.loadedJobMatches(valid.replacingOccurrences(of:"path = " + path,with:"path = /another/user.plist")))
            XCTAssertFalse(service.loadedJobMatches(valid + "\npath = " + path))
            XCTAssertFalse(service.loadedJobMatches("unrecognized launchctl output"))
        }
    }

    func testHardLinkedOrSymlinkedAgentIsPreservedAndNotStopped() throws {
        try fixture { service,temporary in
            _ = try service.install()
            let path = try requireString(service.plan(),"path")
            let second = temporary.appendingPathComponent("retained.plist")
            try FileManager.default.linkItem(atPath:path,toPath:second.path)
            let original = try Data(contentsOf:second)
            XCTAssertThrowsError(try service.install())
            XCTAssertThrowsError(try service.stop())
            XCTAssertEqual(try Data(contentsOf:second),original)
            try FileManager.default.removeItem(atPath:path)
            try FileManager.default.createSymbolicLink(atPath:path,withDestinationPath:second.path)
            XCTAssertThrowsError(try service.install())
            XCTAssertThrowsError(try service.uninstall())
            XCTAssertEqual(try Data(contentsOf:second),original)
        }
    }
}
