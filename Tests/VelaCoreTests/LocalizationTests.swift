import XCTest
@testable import VelaCore

final class LocalizationTests: XCTestCase {
    var temporary: URL!
    var store: VelaStore!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-localization-tests-" + UUID().uuidString, isDirectory: true)
        store = try VelaStore(root: temporary.appendingPathComponent("store"))
    }

    override func tearDownWithError() throws {
        store = nil
        if let temporary { try FileManager.default.removeItem(at: temporary) }
    }

    func testLocaleDefaultsAndLegacyFallback() throws {
        XCTAssertEqual(try VelaPreferences.read(from: store)["locale"] as? String, "zh-CN")
        _ = try store.put("settings", ["id": "preferences", "analysisEnabled": true, "notifyErrors": false])
        let legacy = try VelaPreferences.read(from: store)
        XCTAssertEqual(legacy["locale"] as? String, "zh-CN")
        XCTAssertEqual(legacy["analysisEnabled"] as? Bool, true)
        XCTAssertEqual(legacy["notifyErrors"] as? Bool, false)

        for invalid in ["fr", "en-US", "", 1, false, NSNull(), ["en"], ["language": "en"]] as [Any] {
            _ = try store.put("settings", ["id": "preferences", "locale": invalid, "notifyErrors": false])
            let repaired = try VelaPreferences.read(from: store)
            XCTAssertEqual(repaired["locale"] as? String, "zh-CN")
            XCTAssertEqual(repaired["notifyErrors"] as? Bool, false)
        }
    }

    func testLocaleOnlyWritePersistsWithoutSavingOtherPreferencesOrContent() throws {
        _ = try VelaPreferences.save(["analysisEnabled": true, "notificationSound": false], in: store)
        let body = "会话 Sessions: <b>原文</b> /tmp/中文路径 --flag \"argument with spaces\""
        let memory = try store.put("memory", ["id": "locale-original", "title": "未翻译的用户标题", "content": body, "state": "candidate"])
        let saved = try VelaPreferences.save(["locale": "en"], in: store)
        XCTAssertEqual(saved["locale"] as? String, "en")
        XCTAssertEqual(saved["analysisEnabled"] as? Bool, true)
        XCTAssertEqual(saved["notificationSound"] as? Bool, false)
        XCTAssertEqual(saved["notifications"] as? Bool, false)
        XCTAssertEqual(saved["telemetry"] as? Bool, false)

        let reopened = try VelaStore(root: store.root)
        XCTAssertEqual(try VelaPreferences.read(from: reopened)["locale"] as? String, "en")
        XCTAssertEqual(try jsonString(XCTUnwrap(reopened.get("memory", "locale-original"))), try jsonString(memory))
        _ = try VelaPreferences.save(["notifyErrors": false], in: reopened)
        XCTAssertEqual(try VelaPreferences.read(from: reopened)["locale"] as? String, "en")
        _ = try VelaPreferences.save(["locale": "zh-CN"], in: reopened)
        XCTAssertEqual(try VelaPreferences.read(from: store)["locale"] as? String, "zh-CN")
    }

    func testInvalidLocaleOrMixedPatchIsRejectedBeforePersistence() throws {
        _ = try VelaPreferences.save(["locale": "en", "analysisEnabled": false], in: store)
        let original = try jsonString(XCTUnwrap(store.get("settings", "preferences")))
        for invalid in ["EN", "en-US", "zh", "zh-TW", " en ", "fr", "", 0, true, NSNull(), ["en"], ["locale": "en"]] as [Any] {
            XCTAssertThrowsError(try VelaPreferences.save(["locale": invalid, "analysisEnabled": true], in: store))
            XCTAssertEqual(try jsonString(XCTUnwrap(store.get("settings", "preferences"))), original)
        }
        let mixed = try JSONSerialization.jsonObject(with: Data(#"{"locale":"zh-CN","notifications":1}"#.utf8)) as! JSON
        XCTAssertThrowsError(try VelaPreferences.save(mixed, in: store))
        XCTAssertThrowsError(try VelaPreferences.save(["locale": "zh-CN", "telemetry": true], in: store))
        XCTAssertEqual(try jsonString(XCTUnwrap(store.get("settings", "preferences"))), original)
    }

    func testGlobalAndProjectDashboardsExposeSameGlobalLocale() throws {
        let project = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let roots = ["claude": [temporary.appendingPathComponent("logs/claude")], "codex": [temporary.appendingPathComponent("logs/codex")], "cursor": [temporary.appendingPathComponent("logs/cursor")]]
        let service = FoundationService(store: store, sourceRoots: roots, globalHome: temporary.appendingPathComponent("home"))
        _ = try service.handle("projects.add", ["path": project.path])
        _ = try VelaPreferences.save(["locale": "en"], in: store)
        let global = try XCTUnwrap(service.handle("dashboard.get", [:]) as? JSON)
        let scoped = try XCTUnwrap(service.handle("dashboard.get", ["project": project.path]) as? JSON)
        XCTAssertEqual((global["settings"] as? JSON)?["locale"] as? String, "en")
        XCTAssertEqual((scoped["settings"] as? JSON)?["locale"] as? String, "en")
        XCTAssertEqual(global["notificationScope"] as? String, "*")
        XCTAssertEqual(scoped["notificationScope"] as? String, canonicalProject(project.path))
    }
}
