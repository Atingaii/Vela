import XCTest
@testable import VelaCore

final class SetupInventoryTests: XCTestCase {
    private func fixture(_ body: (URL,URL,VelaStore,FoundationService) throws -> Void) throws {
        let directory = URL(fileURLWithPath:canonicalProject(FileManager.default.temporaryDirectory.path)).appendingPathComponent("vela-setup-inventory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let project = directory.appendingPathComponent("project"), home = directory.appendingPathComponent("home")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
        let store = try VelaStore(root:directory.appendingPathComponent("store"))
        _ = try store.put("project",["path":project.path,"project":project.path])
        try body(project,home,store,FoundationService(store:store,sourceRoots:[:],globalHome:home))
    }
    private func write(_ url: URL,_ content: String) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(content.utf8).write(to:url)
    }
    private func call(_ service: FoundationService,_ method: String,_ params: JSON = [:]) throws -> JSON { try XCTUnwrap(service.handle(method,params) as? JSON) }
    private func scan(_ service: FoundationService,_ project: URL) throws -> JSON { try call(service,"setup.scan",["project":project.path]) }
    private func item(_ store: VelaStore,_ path: URL) throws -> JSON { try XCTUnwrap(store.get("artifact",stableHash("setup:" + path.path))) }

    func testCatalogDiscoversFiveProvidersAndKeepsLoadedStateUnknown() throws {
        try fixture { project,home,store,service in
            for path in ["CLAUDE.md","AGENTS.override.md",".claude/rules/style.md",".cursor/rules/types.mdc",".agents/skills/shared/SKILL.md",".pi/prompts/review.md",".omp/AGENTS.md"] {
                try write(project.appendingPathComponent(path),"---\nname: fixture\n---\nSynthetic instructions")
            }
            try write(project.appendingPathComponent(".codex/config.toml"),"model = \"synthetic\"\n[mcp_servers.fixture.env]\nCUSTOM = \"must-not-persist\"")
            try write(project.appendingPathComponent(".omp/config.yml"),"modelRoles:\n  default: synthetic\npassword: |\n  multiline-secret")
            try write(home.appendingPathComponent(".pi/agent/settings.json"),"{\"defaultThinkingLevel\":\"low\"}")
            try write(home.appendingPathComponent(".omp/agent/mcp.json"),"{\"mcpServers\":{\"fixture\":{\"command\":\"never-executed\"}}}")
            let result = try scan(service,project)
            XCTAssertEqual(result["scanComplete"] as? Bool,true)
            let artifacts = try XCTUnwrap(result["artifacts"] as? [JSON])
            for provider in ["claude","codex","cursor","pi","omp"] { XCTAssertTrue(artifacts.contains { string($0,"provider") == provider }) }
            XCTAssertTrue(artifacts.allSatisfy { string($0,"runtimeLoadedState") == "unavailable" && !$0.keys.contains("effective") })
            XCTAssertFalse(try jsonString(result).contains("must-not-persist")); XCTAssertFalse(try jsonString(result).contains("multiline-secret"))
            XCTAssertEqual(string(try item(store,project.appendingPathComponent(".omp/config.yml")),"contentStatus"),"withheld_unparsed_configuration")
            XCTAssertEqual((try call(service,"setup.catalog"))["catalogVersion"] as? String,SetupCatalog.version)
            XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent("never-executed").path))
        }
    }

    func testSanitizedRevisionHistoryDeduplicatesAndShowsChangesDeletionAndReappearance() throws {
        try fixture { project,_,store,service in
            let path = project.appendingPathComponent("AGENTS.md")
            try write(path,"Line one\nOld requirement\nLine three\n"); _ = try scan(service,project)
            let id = string(try item(store,path),"id")
            _ = try scan(service,project); XCTAssertEqual(intValue(try item(store,path),"revision"),1)
            try write(path,"Line one\nNew requirement\nLine three\n"); _ = try scan(service,project)
            let diff = try call(service,"setup.diff",["id":id,"project":project.path,"from":1,"to":2])
            XCTAssertEqual(diff["diffAvailable"] as? Bool,true)
            XCTAssertEqual(diff["removed"] as? [String],["Old requirement"])
            XCTAssertEqual(diff["added"] as? [String],["New requirement"])
            XCTAssertEqual(diff["startLine"] as? Int,2)
            try FileManager.default.removeItem(at:path); _ = try scan(service,project)
            XCTAssertEqual(string(try item(store,path),"state"),"deleted")
            XCTAssertEqual(intValue(try item(store,path),"revision"),3)
            try write(path,"Restored requirement"); _ = try scan(service,project)
            XCTAssertEqual(intValue(try item(store,path),"revision"),4)
            let history = try call(service,"setup.history",["id":id,"project":project.path,"limit":2])
            let revisions = try XCTUnwrap(history["revisions"] as? [JSON])
            XCTAssertEqual(revisions.map { intValue($0,"revision") },[4,3])
            XCTAssertTrue(revisions.allSatisfy { $0["content"] == nil })
            let older = try call(service,"setup.history",["id":id,"project":project.path,"before":history["nextBefore"]!])
            XCTAssertEqual((older["revisions"] as? [JSON])?.map { intValue($0,"revision") },[2,1])
            XCTAssertEqual(try store.list("setup_revision").count,4)
        }
    }

    func testSecretRotationRemainsARealSourceChangeWithoutPersistingSecretDiffs() throws {
        try fixture { project,_,store,service in
            let path = project.appendingPathComponent(".mcp.json")
            for secret in ["fixture-secret-one","fixture-secret-two"] {
                try write(path,try jsonString(["mcpServers":["fixture":["command":"do-not-run","env":["CUSTOM":secret],"headers":["Authorization":"Bearer " + secret],"apiKey":secret,"url":"https://user:password-value@example.invalid/?token=" + secret]]]))
                _ = try scan(service,project)
            }
            let current = try item(store,path)
            XCTAssertEqual(intValue(current,"revision"),2)
            let diff = try call(service,"setup.diff",["id":current["id"]!,"project":project.path])
            XCTAssertEqual(diff["sourceChanged"] as? Bool,true)
            XCTAssertEqual(diff["sanitizedTextChanged"] as? Bool,false)
            XCTAssertEqual(diff["redacted"] as? Bool,true)
            for kind in ["artifact","setup_revision"] {
                let persisted = try jsonString(store.list(kind))
                for secret in ["fixture-secret-one","fixture-secret-two","password-value"] { XCTAssertFalse(persisted.contains(secret)) }
            }
            XCTAssertEqual((current["details"] as? JSON)?["mcpServerNames"] as? [String],["fixture"])
            XCTAssertTrue(try String(contentsOf:path).contains("fixture-secret-two"))
        }
    }

    func testMixedAuthStoreIsMetadataOnlyAndGlobalHistoryNeedsExplicitScope() throws {
        try fixture { project,home,store,service in
            let mixed = home.appendingPathComponent(".claude.json")
            try write(mixed,"not even valid json: PRIVATE_SIGN_IN_SESSION")
            _ = try scan(service,project)
            let metadata = try item(store,mixed)
            XCTAssertEqual(string(metadata,"contentStatus"),"metadata_only_mixed_auth_store")
            XCTAssertTrue(metadata["hash"] is NSNull)
            XCTAssertFalse(try jsonString(store.list("artifact")).contains("PRIVATE_SIGN_IN_SESSION"))
            XCTAssertFalse(try jsonString(store.list("setup_revision")).contains("PRIVATE_SIGN_IN_SESSION"))
            XCTAssertThrowsError(try call(service,"setup.history",["id":metadata["id"]!,"project":project.path]))
            let history = try call(service,"setup.history",["id":metadata["id"]!,"scope":"global"])
            XCTAssertEqual((history["revisions"] as? [JSON])?.count,1)
            XCTAssertEqual((try call(service,"setup.diff",["id":metadata["id"]!,"scope":"global"]))["diffAvailable"] as? Bool,false)
        }
    }

    func testSymlinkAncestorsHardLinksPrivateAndRegisteredNestedProjectsAreNotRead() throws {
        try fixture { project,home,store,service in
            let outside = project.deletingLastPathComponent().appendingPathComponent("outside")
            try write(outside.appendingPathComponent("settings.json"),"{\"private\":\"outside-private-content\"}")
            try FileManager.default.createSymbolicLink(at:project.appendingPathComponent(".claude"),withDestinationURL:outside)
            try FileManager.default.createSymbolicLink(at:home.appendingPathComponent(".claude"),withDestinationURL:outside)
            try FileManager.default.linkItem(at:outside.appendingPathComponent("settings.json"),to:project.appendingPathComponent(".mcp.json"))
            for path in ["Library/private/AGENTS.md",".git/AGENTS.md","node_modules/dependency/AGENTS.md"] { try write(project.appendingPathComponent(path),"must-never-index") }
            let nested = project.appendingPathComponent("registered-child")
            try write(nested.appendingPathComponent("AGENTS.md"),"private-other-project")
            _ = try store.put("project",["path":nested.path,"project":nested.path])
            let result = try scan(service,project), encoded = try jsonString(result)
            for secret in ["outside-private-content","must-never-index","private-other-project"] { XCTAssertFalse(encoded.contains(secret)) }
            XCTAssertTrue((result["diagnostics"] as? [JSON] ?? []).contains { string($0,"code") == "unreadable-source" })
            XCTAssertEqual(try String(contentsOf:outside.appendingPathComponent("settings.json")),"{\"private\":\"outside-private-content\"}")
            XCTAssertNil(try store.get("artifact",stableHash("setup:" + nested.appendingPathComponent("AGENTS.md").path)))
        }
    }

    func testInvalidJSONAndUnreadableSourceDoNotLeakFallbackText() throws {
        try fixture { project,_,store,service in
            let path = project.appendingPathComponent(".mcp.json")
            try write(path,"{ \"env\": {\"PRIVATE_VALUE\": \"do-not-leak-broken-json\"")
            let result = try scan(service,project)
            XCTAssertFalse(try jsonString(result).contains("do-not-leak-broken-json"))
            XCTAssertTrue((result["diagnostics"] as? [JSON] ?? []).contains { string($0,"code") == "invalid-json" })
            XCTAssertEqual(string(try item(store,path),"contentStatus"),"withheld_invalid_json")
            try write(project.appendingPathComponent("AGENTS.md"),String(repeating:"x",count:1_048_577))
            _ = try scan(service,project)
            XCTAssertEqual(string(try item(store,project.appendingPathComponent("AGENTS.md")),"state"),"unavailable")
            XCTAssertTrue(string(try item(store,project.appendingPathComponent("AGENTS.md")),"content").isEmpty)
        }
    }

    func testTruncatedDiscoveryNeverMarksUnseenPreviousArtifactsDeleted() throws {
        try fixture { project,_,store,service in
            let prior: JSON = ["id":"prior-unseen","project":project.path,"origin":"setup","path":project.appendingPathComponent("formerly-seen/AGENTS.md").path,"state":"active","content":"retained history"]
            _ = try store.put("artifact",prior)
            for index in 0...SetupInventoryService.maxFiles { try write(project.appendingPathComponent(".claude/rules/\(index).md"),"rule \(index)") }
            let result = try scan(service,project)
            XCTAssertEqual(result["scanComplete"] as? Bool,false)
            XCTAssertEqual(try store.get("artifact","prior-unseen")?["state"] as? String,"active")
            XCTAssertLessThanOrEqual((result["artifacts"] as? [JSON] ?? []).count,SetupInventoryService.maxFiles)
        }
    }

    func testDiffAndRelationsCannotCrossProjectAndDoNotClaimProviderAdoption() throws {
        try fixture { project,_,store,service in
            try write(project.appendingPathComponent("AGENTS.md"),"baseline")
            try write(project.appendingPathComponent("AGENTS.override.md"),"override")
            for name in ["a","b"] { try write(project.appendingPathComponent(".agents/skills/\(name)/SKILL.md"),"---\nname: same-skill\n---\nSame") }
            _ = try scan(service,project)
            let override = try item(store,project.appendingPathComponent("AGENTS.override.md"))
            let links = try call(service,"setup.relations",["id":override["id"]!,"project":project.path])
            XCTAssertTrue((links["relations"] as? [JSON] ?? []).contains { string($0,"relation") == "documented_same_directory_override" })
            let skill = try item(store,project.appendingPathComponent(".agents/skills/a/SKILL.md"))
            let names = try call(service,"setup.relations",["id":skill["id"]!,"project":project.path])
            XCTAssertTrue((names["relations"] as? [JSON] ?? []).contains { string($0,"relation") == "same_declared_skill_name" })
            for method in ["setup.get","setup.history","setup.diff","setup.relations"] { XCTAssertThrowsError(try call(service,method,["id":override["id"]!,"project":project.deletingLastPathComponent().path])) }
            XCTAssertThrowsError(try call(service,"setup.history",["id":override["id"]!,"project":project.path,"limit":true]))
        }
    }

    func testConcurrentScansNeverOverwriteImmutableRevisionIdentity() throws {
        try fixture { project,home,store,service in
            let path = project.appendingPathComponent("AGENTS.md")
            try write(path,"version one"); _ = try scan(service,project)
            try write(path,"version two")
            let services = try (0..<2).map { _ in FoundationService(store:try VelaStore(root:store.root),sourceRoots:[:],globalHome:home) }
            let resultLock = NSLock(); var errors: [String] = []
            DispatchQueue.concurrentPerform(iterations:2) { index in
                do { _ = try scan(services[index],project) }
                catch {
                    if !error.localizedDescription.contains("Batch source changed") && !error.localizedDescription.contains("batch identity already exists") {
                        resultLock.lock(); errors.append(error.localizedDescription); resultLock.unlock()
                    }
                }
            }
            XCTAssertTrue(errors.isEmpty)
            XCTAssertEqual(intValue(try item(store,path),"revision"),2)
            XCTAssertEqual(try store.list("setup_revision").count,2)
        }
    }

    func testMissingScopeRootPreservesPriorObservationAndGlobalScanStaysGlobal() throws {
        try fixture { project,home,store,service in
            let path = project.appendingPathComponent("AGENTS.md")
            try write(path,"preserve until a complete scope observation")
            try write(home.appendingPathComponent(".claude/CLAUDE.md"),"global fixture")
            _ = try scan(service,project)
            let id = string(try item(store,path),"id")
            let moved = project.deletingLastPathComponent().appendingPathComponent("temporarily-unavailable-project")
            try FileManager.default.moveItem(at:project,to:moved)
            let unavailable = try scan(service,project)
            XCTAssertEqual(unavailable["scanComplete"] as? Bool,false)
            XCTAssertEqual(string(try XCTUnwrap(store.get("artifact",id)),"state"),"active")
            XCTAssertEqual((try call(service,"setup.scan",["scope":"global"]))["scannedProjects"] as? [String],[])
            let globals = try XCTUnwrap(service.handle("setup.list",["scope":"global"]) as? [JSON])
            XCTAssertTrue(globals.allSatisfy { string($0,"scope") == "global" })
            XCTAssertThrowsError(try service.handle("setup.list",["includeInactive":1.5]))
            XCTAssertThrowsError(try service.handle("setup.scan",["provider":"unknown"]))
        }
    }

    func testWrongShapeSecretContainersAndPrivateKeyBlocksAreNotPersisted() throws {
        try fixture { project,_,store,service in
            try write(project.appendingPathComponent(".mcp.json"),"{\"env\":\"wrong-shape-secret\",\"headers\":[\"secret-header-list\"]}")
            try write(project.appendingPathComponent("CLAUDE.md"),"Before\n-----BEGIN RSA PRIVATE KEY-----\nprivate-key-body\n-----END RSA PRIVATE KEY-----\nAfter")
            _ = try scan(service,project)
            for kind in ["artifact","setup_revision"] {
                let content = try jsonString(store.list(kind))
                for secret in ["wrong-shape-secret","secret-header-list","private-key-body"] { XCTAssertFalse(content.contains(secret)) }
            }
        }
    }
}
