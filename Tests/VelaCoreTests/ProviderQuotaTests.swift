import XCTest
import Darwin
@testable import VelaCore

final class ProviderQuotaTests: XCTestCase {
    var root: URL!
    var store: VelaStore!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: canonicalProject(FileManager.default.temporaryDirectory.path)).appendingPathComponent("vela-quota-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try VelaStore(root: root.appendingPathComponent("store"))
    }
    override func tearDownWithError() throws { store = nil; if let root { try FileManager.default.removeItem(at: root) } }
    func limits(_ value: Any = 25, reset: Int = 2_000_000_000) -> JSON {
        ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": value, "windowDurationMins": 300, "resetsAt": reset], "secondary": NSNull()]]
    }
    func windows(_ value: JSON) -> [JSON] { (value["buckets"] as? [JSON] ?? []).flatMap { $0["windows"] as? [JSON] ?? [] } }
    func fixture(_ mode: String) throws -> String {
        let path = root.appendingPathComponent("codex")
        let modeJSON = try jsonString(["mode": mode])
        let source = """
        #!/usr/bin/python3
        import json, os, sys, time
        mode = \(modeJSON)["mode"]
        assert sys.argv[1:] == ['app-server', '--stdio']
        assert 'FAKE_API_TOKEN' not in os.environ
        assert 'DYLD_INSERT_LIBRARIES' not in os.environ
        def send(value):
            data = (json.dumps(value, ensure_ascii=False) + '\\n').encode('utf-8')
            if mode == 'fragmented':
                for start in range(0, len(data), 4093):
                    sys.stdout.buffer.write(data[start:start + 4093]); sys.stdout.buffer.flush()
            else:
                sys.stdout.buffer.write(data); sys.stdout.buffer.flush()
        first = json.loads(sys.stdin.readline())
        assert first['method'] == 'initialize' and first['params']['clientInfo']['name'] == 'vela'
        if mode == 'premature':
            send({'id': 2, 'result': {}}); time.sleep(2)
        if mode == 'early_exit':
            sys.exit(0)
        if mode == 'flood':
            sys.stdout.write('x' * (1024 * 1024 + 1)); sys.stdout.flush(); time.sleep(2)
        if mode == 'stderr_flood':
            sys.stderr.write('x' * (5 * 1024 * 1024)); sys.stderr.flush(); time.sleep(2)
        if mode == 'timeout_child':
            child = os.fork()
            if child == 0:
                time.sleep(0.7)
                open('orphan-survived', 'w').write('bad')
                os._exit(0)
            open('child-pid', 'w').write(str(child))
            time.sleep(3)
        if mode == 'stderr':
            sys.stderr.write('DO-NOT-RETURN-AUTH-SECRET' * 4000); sys.stderr.flush()
        if mode == 'fragmented':
            # Fragment UTF-8 and carry a complete frame plus the next partial
            # frame through the same buffer; retained Data indices may be nonzero.
            send({'method': 'notification/test', 'params': {'text': '合成' * 16000}})
        if mode == 'long_notification':
            send({'method': 'notification/test', 'params': {'text': 'x' * (1024 * 1024 - 100)}})
        send({'method': 'notification/test', 'params': {'privateData': 'DO-NOT-RETURN-AUTH-SECRET'}})
        send({'id': 1, 'result': {'userAgent': 'fixture'}})
        notification = json.loads(sys.stdin.readline())
        assert notification == {'method': 'initialized'}
        request = json.loads(sys.stdin.readline())
        assert request == {'method': 'account/rateLimits/read', 'id': 2}
        if mode == 'server_request':
            send({'method': 'account/chatgptAuthTokens/refresh', 'id': 8, 'params': {'DO-NOT-RETURN-AUTH-SECRET': True}})
        elif mode == 'auth_error':
            send({'id': 2, 'error': {'code': -32000, 'message': 'Not logged in DO-NOT-RETURN-AUTH-SECRET'}})
        elif mode == 'boolean_error_code':
            send({'id': 2, 'error': {'code': True, 'message': 'DO-NOT-RETURN-AUTH-SECRET'}})
        elif mode == 'invalid_json':
            sys.stdout.write('invalid-json\\n'); sys.stdout.flush()
        else:
            send({'id': 2, 'result': {'rateLimitsByLimitId': {'codex': {'limitId': 'codex', 'primary': {'usedPercent': 0, 'windowDurationMins': 300, 'resetsAt': 2000000000}, 'secondary': None}}, 'account': {'email': 'DO-NOT-RETURN-AUTH-SECRET'}, 'access_token': 'DO-NOT-RETURN-AUTH-SECRET'}})
        time.sleep(2)
        """
        try Data(source.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path.path
    }
    func service(timeout: Double = 2) -> ProviderQuotaService {
        ProviderQuotaService(store: store, environment: ["HOME": root.path, "CODEX_HOME": root.appendingPathComponent("empty-codex-home").path, "PATH": "/usr/bin:/bin", "FAKE_API_TOKEN": "secret", "DYLD_INSERT_LIBRARIES": "untrusted"], timeout: timeout)
    }
    func read(_ service: ProviderQuotaService, _ executable: String) throws -> JSON { try XCTUnwrap(service.handle("usage.quota.read", ["provider": "codex", "executable": executable]) as? JSON) }
    func status(_ service: ProviderQuotaService) throws -> JSON { try XCTUnwrap(service.handle("usage.quota.status", ["provider": "codex"]) as? JSON) }

    func testMultiBucketQuotaPreservesMissingValuesAndRealZeroWithoutAccountIdentity() throws {
        let response: JSON = ["rateLimitsByLimitId": ["codex": ["limitId": "codex", "primary": ["usedPercent": 0, "windowDurationMins": 300, "resetsAt": 2_000_000_000]], "other_bucket": ["limitId": "other_meter", "limitName": "Other service", "primary": ["usedPercent": 25.5, "resetsAt": 2_000_000_000], "secondary": NSNull()]], "account": ["email": "never-persist@example.test"], "accessToken": "secret"]
        let normalized = try ProviderQuotaService.normalize(response)
        let values = windows(normalized)
        XCTAssertEqual(values.count, 2); XCTAssertEqual(values[0]["usedPercent"] as? Double, 0)
        XCTAssertEqual(values[0]["remainingPercent"] as? Double, 100); XCTAssertEqual(values[1]["remainingPercent"] as? Double, 74.5)
        XCTAssertTrue(values[1]["windowDurationMins"] is NSNull)
        let buckets = normalized["buckets"] as? [JSON] ?? []
        XCTAssertEqual(string(buckets[1], "limitId"), "other_meter"); XCTAssertEqual(string(buckets[1], "key"), "other_bucket")
        XCTAssertFalse(try jsonString(normalized).contains("never-persist")); XCTAssertFalse(try jsonString(normalized).contains("secret"))
    }

    func testLegacyFallbackAndExplicitEmptyMapDoNotInventBuckets() throws {
        var legacy = limits(); var bucket = legacy["rateLimits"] as? JSON ?? [:]; bucket.removeValue(forKey: "limitId"); legacy["rateLimits"] = bucket
        let normalized = try ProviderQuotaService.normalize(legacy)
        XCTAssertTrue((normalized["buckets"] as? [JSON])?.first?["limitId"] is NSNull)
        legacy["rateLimitsByLimitId"] = [:] as JSON
        XCTAssertTrue(windows(try ProviderQuotaService.normalize(legacy)).isEmpty)
        XCTAssertThrowsError(try ProviderQuotaService.normalize(["rateLimitsByLimitId": "bad"]))
        XCTAssertThrowsError(try ProviderQuotaService.normalize(["rateLimits": ["primary": "bad"]]))
        XCTAssertThrowsError(try ProviderQuotaService.normalize(["rateLimitsByLimitId": NSNull(), "rateLimits": "bad"]))
        XCTAssertTrue(windows(try ProviderQuotaService.normalize(["rateLimitsByLimitId": NSNull(), "rateLimits": NSNull()])).isEmpty)
    }

    func testInvalidPercentAndExpiredWindowsRemainUnavailable() throws {
        for invalid in [true, NSNull(), -1, "25"] as [Any] {
            let value = try ProviderQuotaService.normalize(limits(invalid))
            XCTAssertTrue(windows(value)[0]["usedPercent"] is NSNull); XCTAssertTrue(windows(value)[0]["remainingPercent"] is NSNull)
            XCTAssertEqual(value["quotaAvailable"] as? Bool, false)
        }
        let overage = try ProviderQuotaService.normalize(limits(120))
        XCTAssertEqual(windows(overage)[0]["usedPercent"] as? Double, 120); XCTAssertEqual(windows(overage)[0]["remainingPercent"] as? Double, 0)
        let old = try ProviderQuotaService.normalize(limits(25, reset: 1000))
        XCTAssertEqual(old["quotaAvailable"] as? Bool, false); XCTAssertEqual(windows(old)[0]["expired"] as? Bool, true)
    }

    func testRealSubprocessHandshakeDrainAndPersistedStatusDoNotExposeSecrets() throws {
        let reader = service(); let first = try status(reader)
        XCTAssertEqual(string(first, "status"), "never_read"); XCTAssertTrue(first["snapshot"] is NSNull)
        let observed = try read(reader, fixture("stderr"))
        XCTAssertEqual(string(observed, "status"), "fresh"); XCTAssertEqual(observed["quotaAvailable"] as? Bool, true)
        XCTAssertFalse(try jsonString(observed).contains("DO-NOT-RETURN-AUTH-SECRET"))
        let snapshot = try XCTUnwrap(observed["snapshot"] as? JSON)
        XCTAssertEqual(windows(snapshot)[0]["usedPercent"] as? Double, 0)
        let reopened = ProviderQuotaService(store: try VelaStore(root: store.root))
        XCTAssertEqual(try jsonString(try status(reopened)["snapshot"] as? JSON ?? [:]), try jsonString(snapshot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("empty-codex-home").path))
    }

    func testFailurePreservesLastSuccessfulCaptureAndOnlyStoresSanitizedError() throws {
        let reader = service(); let success = try read(reader, fixture("success"))
        let oldSnapshot = try jsonString(try XCTUnwrap(success["snapshot"] as? JSON))
        let failed = try read(reader, fixture("auth_error"))
        XCTAssertEqual(string(failed, "status"), "error"); XCTAssertEqual(failed["quotaAvailable"] as? Bool, false)
        XCTAssertEqual(try jsonString(try XCTUnwrap(failed["snapshot"] as? JSON)), oldSnapshot)
        let attempt = try XCTUnwrap(failed["lastAttempt"] as? JSON); let error = try XCTUnwrap(attempt["error"] as? JSON)
        XCTAssertEqual(string(error, "kind"), "login_required"); XCTAssertEqual(error["code"] as? Int, -32000)
        XCTAssertFalse(try jsonString(failed).contains("DO-NOT-RETURN-AUTH-SECRET"))
        XCTAssertEqual(failed["stale"] as? Bool, true)
        let malformedCode = try read(reader, fixture("boolean_error_code"))
        let malformedAttempt = try XCTUnwrap(malformedCode["lastAttempt"] as? JSON)
        XCTAssertTrue((malformedAttempt["error"] as? JSON)?["code"] is NSNull)
    }

    func testMalformedFramesPrematureResponsesAndCredentialRequestsAreRejected() throws {
        for mode in ["invalid_json", "premature", "server_request", "early_exit"] {
            let reader = service(); let value = try read(reader, fixture(mode))
            XCTAssertEqual(string(value, "status"), "error"); XCTAssertFalse(value["quotaAvailable"] as? Bool == true)
            XCTAssertFalse(try jsonString(value).contains("DO-NOT-RETURN-AUTH-SECRET"))
        }
    }

    func testOutputBoundsAndTimeoutTerminateProcessGroups() throws {
        for mode in ["flood", "stderr_flood"] {
            let value = try read(service(), fixture(mode))
            let attempt = try XCTUnwrap(value["lastAttempt"] as? JSON); let error = try XCTUnwrap(attempt["error"] as? JSON)
            let actualKind = string(error, "kind")
            XCTAssertTrue(["frame_limit", "output_limit"].contains(actualKind), "Flood mode \(mode) returned \(actualKind)")
        }
        let value = try read(service(timeout: 0.2), fixture("timeout_child"))
        let attempt = try XCTUnwrap(value["lastAttempt"] as? JSON); let error = try XCTUnwrap(attempt["error"] as? JSON)
        XCTAssertEqual(string(error, "kind"), "timeout")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("orphan-survived").path))
    }

    func testFragmentedUTF8AndNearLimitNotificationKeepFollowingResponses() throws {
        for mode in ["fragmented", "long_notification"] {
            let value = try read(service(), fixture(mode))
            XCTAssertEqual(string(value, "status"), "fresh", "Mode \(mode): \(String(describing:value["lastAttempt"]))")
            let snapshot = try XCTUnwrap(value["snapshot"] as? JSON)
            XCTAssertEqual(windows(snapshot)[0]["remainingPercent"] as? Double, 100)
            XCTAssertFalse(try jsonString(value).contains("合成"))
        }
    }

    func testStatusIsReadOnlyAndDoesNotTreatOldSnapshotsAsFresh() throws {
        let old = try ProviderQuotaService.normalize(limits(), now: Date().addingTimeInterval(-600))
        _ = try store.put("quota_snapshot", old)
        let snapshot = try jsonString(try XCTUnwrap(store.get("quota_snapshot", "codex")))
        let value = try status(service())
        XCTAssertEqual(string(value, "status"), "stale"); XCTAssertEqual(value["quotaAvailable"] as? Bool, false)
        XCTAssertEqual(try jsonString(try XCTUnwrap(store.get("quota_snapshot", "codex"))), snapshot)
        XCTAssertTrue(value["lastAttempt"] is NSNull)
    }

    func testQuotaInterfaceRejectsExtraCommandsProvidersAndRelativeExecutables() throws {
        let reader = service()
        XCTAssertThrowsError(try reader.handle("usage.quota.read", ["provider": "claude", "executable": "/bin/echo"]))
        XCTAssertThrowsError(try reader.handle("usage.quota.read", ["provider": "codex", "executable": "codex"]))
        XCTAssertThrowsError(try reader.handle("usage.quota.read", ["provider": "codex", "executable": "/bin/echo", "args": ["secret"]]))
        XCTAssertThrowsError(try reader.handle("usage.quota.status", ["provider": "codex", "executable": "/bin/echo"]))
        XCTAssertNil(try reader.handle("usage.quota.reset", ["provider": "codex"]))
        XCTAssertNil(try reader.handle("account/sendAddCreditsNudgeEmail", [:]))
        XCTAssertTrue(try status(reader)["lastAttempt"] is NSNull)
    }
}
