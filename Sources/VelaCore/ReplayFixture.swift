import Foundation
import CoreFoundation

/// Historical context only. This module never resolves workflow inputs.
enum ReplayFixture {
    static let version = "vela-historical-template-replay-v1"
    static func hash(_ value: JSON) throws -> String { stableHash(try jsonString(value)) }
    static func keys(_ value: JSON, _ allowed: [String]) throws {
        guard Set(value.keys).isSubset(of:Set(allowed)) else { throw VelaError("Unsupported replay parameter") }
    }
    static func active(_ fixture: JSON) -> Bool {
        string(fixture,"state") == "active" && (ISO8601DateFormatter().date(from:string(fixture,"expiresAt")) ?? .distantPast) > Date()
    }
    static func shape(_ workflow: JSON) throws -> JSON {
        guard workflow["pipeline"] == nil, workflow["output"] == nil,
              let steps = workflow["steps"] as? [JSON], steps.count == 1,
              string(steps[0],"tool") == "agent.run", let arguments = steps[0]["arguments"] as? JSON,
              string(arguments,"promptMode") == "workflow_context", let context = workflow["context"] as? JSON,
              (context["inputs"] as? [JSON] ?? []).allSatisfy({ $0["workflow"] == nil }) else { throw VelaError("Replay supports one contextual agent.run without composition or delivery") }
        _ = try WorkflowContext.validate(context,steps:steps)
        return context
    }
    static func prompt(template: String, snapshot: JSON) throws -> String {
        var values = try WorkflowPlanning.requireObject(snapshot,"inputs")
        let guidelines = (snapshot["guidelinesUsed"] as? [JSON] ?? []).map { string($0,"content") }.joined(separator:"\n\n")
        let memory = (snapshot["memoryUsed"] as? [JSON] ?? []).map { string($0,"title") + "\n" + string($0,"content") }.joined(separator:"\n\n")
        values["guidelines"] = guidelines; values["memory"] = memory
        let rendered = try WorkflowContext.render(template,values:values)
        let body = try rendered as? String ?? WorkflowContext.jsonText(rendered)
        let refs = WorkflowContext.expression.matches(in:template,range:NSRange(template.startIndex...,in:template)).map { (template as NSString).substring(with:$0.range(at:1)) }
        var prefix: [String] = []
        if !memory.isEmpty && !refs.contains("memory") { prefix.append(memory) }
        if !guidelines.isEmpty && !refs.contains("guidelines") { prefix.append(guidelines) }
        let text = (prefix + [body]).joined(separator:"\n\n")
        guard text.utf8.count <= 48000, !text.contains("\0"), ModelImprovement.redact(text) == text else { throw VelaError("Historical prompt is oversized or contains credential-like data") }
        return text
    }
    static func sources(_ snapshot: JSON) throws -> [JSON] {
        guard let guidelines = snapshot["guidelinesUsed"] as? [JSON], let memories = snapshot["memoryUsed"] as? [JSON],
              let inputs = snapshot["inputsUsed"] as? [JSON] else { throw VelaError("Missing historical source receipts") }
        var rows = guidelines + memories
        guard guidelines.allSatisfy({string($0,"kind") == "guideline"}), memories.allSatisfy({string($0,"kind") == "memory"}) else { throw VelaError("Invalid historical source kind") }
        for receipt in inputs where string(receipt,"source") == "library" {
            guard let items = receipt["value"] as? [JSON], items.allSatisfy({string($0,"kind") == "library"}) else { throw VelaError("Invalid historical Library receipt") }
            rows += items
        }
        guard rows.count <= 128 else { throw VelaError("Historical source count exceeds 128") }
        for row in rows {
            guard !string(row,"id").isEmpty, row["content"] is String,
                  stableHash(string(row,"content")) == string(row,"contentHash"),
                  try hash(row.filter {$0.key != "sourceHash"}) == string(row,"sourceHash") else { throw VelaError("Historical source hash is missing or inconsistent") }
        }
        return rows
    }
    static func validate(run: JSON) throws -> JSON {
        guard ["completed","failed","rejected"].contains(string(run,"state")), run["compositionDefinitions"] == nil,
              let workflow = run["workflowSnapshot"] as? JSON, let snapshot = run["contextSnapshot"] as? JSON,
              string(workflow,"project") == string(run,"project"), string(workflow,"id") == string(run,"workflowId"),
              intValue(workflow,"version") == intValue(run,"workflowVersion") else { throw VelaError("Run lacks a supported terminal historical context") }
        let context = try shape(workflow)
        guard try WorkflowContext.integer(snapshot["version"],default:-1,range:1...1,name:"historical context version") == 1,
              let degraded = snapshot["degraded"] as? NSNumber, CFGetTypeID(degraded) == CFBooleanGetTypeID(), !degraded.boolValue,
              string(snapshot,"template") == string(context,"template"), string(snapshot,"templateHash") == stableHash(string(snapshot,"template")),
              string(snapshot,"promptHash") == stableHash(string(snapshot,"renderedPrompt")),
              let inputs = snapshot["inputs"] as? JSON, let receipts = snapshot["inputsUsed"] as? [JSON] else { throw VelaError("Historical context is incomplete or degraded") }
        for key in ["inputs","inputsUsed","guidelinesUsed","memoryUsed"] {
            guard run[key] != nil, try WorkflowContext.jsonText(run[key]!) == WorkflowContext.jsonText(snapshot[key] ?? NSNull()) else { throw VelaError("Historical run and context disagree") }
        }
        let definitions = context["inputs"] as? [JSON] ?? []
        guard definitions.count == receipts.count, Set(inputs.keys) == Set(["input"] + definitions.map{string($0,"id")}) else { throw VelaError("Historical input receipts are incomplete") }
        for (definition,receipt) in zip(definitions,receipts) {
            let id = string(definition,"id")
            guard string(receipt,"id") == id, string(receipt,"state") == "resolved", ["tool","library","stdin","value"].contains(string(receipt,"source")),
                  try hash(definition) == hash(receipt["definition"] as? JSON ?? [:]), let value = receipt["value"], let actual = inputs[id],
                  string(receipt,"valueHash") == stableHash(try jsonString(["value":value])),
                  try WorkflowContext.jsonText(value) == WorkflowContext.jsonText(actual) else { throw VelaError("Historical input hash or definition is inconsistent") }
            let expectedSource = definition["tool"] != nil ? "tool" : definition["retrieve"] != nil ? "library" : definition["source"] != nil ? "stdin" : "value"
            guard string(receipt,"source") == expectedSource else { throw VelaError("Historical input source kind changed") }
        }
        _ = try sources(snapshot)
        guard try prompt(template:string(context,"template"),snapshot:snapshot) == string(snapshot,"renderedPrompt"),
              try jsonString(snapshot).utf8.count <= 256000, ModelImprovement.redact(try jsonString(snapshot)) == (try jsonString(snapshot)) else { throw VelaError("Historical rendered context cannot be reproduced safely") }
        let frozen: JSON = ["workflow":workflow,"snapshot":snapshot,"sourceRunId":string(run,"id"),"sourceRunHash":try hash(run)]
        let serialized = try jsonString(frozen)
        guard serialized.utf8.count <= 384000, ModelImprovement.redact(serialized) == serialized else { throw VelaError("Historical workflow contains credential-like or oversized data") }
        return frozen
    }
}

extension AutomationService {
    func replayObject(_ kind: String, id: String, project root: String) throws -> JSON {
        let value = try object(kind,id)
        guard string(value,"project") == root else { throw VelaError("Replay belongs to another project") }
        return value
    }
    func verifyReplaySources(_ payload: JSON, project root: String) throws -> [(String,String,String)] {
        let run = try replayObject("run",id:requireString(payload,"sourceRunId"),project:root)
        guard ModelImprovement.falseOrAbsent(run["private"]), ModelImprovement.falseOrAbsent(run["sourceLabeledPrivate"]), string(run,"scope") != "private", string(run,"state") != "archived" else { throw VelaError("Historical run is no longer visible") }
        var expected = [("run",string(run,"id"),try ReplayFixture.hash(run))]
        for row in try ReplayFixture.sources(WorkflowPlanning.requireObject(payload,"snapshot")) {
            let kind = try requireString(row,"kind"), id = try requireString(row,"id")
            let current = kind == "library" ? try LibrarySource.fresh(store:store,id:id) : try object(kind,id)
            guard ModelImprovement.falseOrAbsent(current["private"]), ModelImprovement.falseOrAbsent(current["sourceLabeledPrivate"]),
                  string(current,"state","active") == "active", string(current,"scope") == string(row,"scope"),
                  string(current,"scope") != "private", string(current,"project") == string(row,"project"),
                  (string(current,"project") == root || (string(current,"project").isEmpty && string(current,"scope") == "global")) else { throw VelaError("Historical source was revoked or changed scope") }
            if kind == "library" { guard LibraryIndex.isPublic(current,project:root) else { throw VelaError("Historical Library is no longer public") } }
            else {
                guard ["memory","guideline"].contains(kind), ["project","repository","global",""].contains(string(current,"scope")),
                      string(current,"assetPath") == store.root.appendingPathComponent("assets/\(kind)/\(id).md").path,
                      try FoundationFile.readUTF8(root:store.root,path:"assets/\(kind)/\(id).md") != nil else { throw VelaError("Historical source asset is unavailable") }
            }
            for key in ["sourcePath","sourceFile","assetPath"] where privateLibraryPath(string(current,key)) { throw VelaError("Historical source path is private") }
            expected.append((kind,id,try ReplayFixture.hash(current)))
        }
        return expected
    }
    func replayFixtureState(id: String, project root: String) throws -> (JSON,JSON) {
        let metadata = try replayObject("replay_fixture",id:id,project:root)
        guard ReplayFixture.active(metadata), let payload = try store.get("replay_fixture_payload",id),
              string(payload,"project") == root, let frozen = payload["frozen"] as? JSON,
              try ReplayFixture.hash(frozen) == string(metadata,"fixtureHash") else { throw VelaError("Replay fixture expired, was forgotten or is inconsistent") }
        _ = try verifyReplaySources(frozen,project:root)
        return (metadata,payload)
    }
    func inspectReplayFixture(_ params: JSON) throws -> JSON {
        let root = try project(requireString(params,"project")), run = try replayObject("run",id:requireString(params,"runId"),project:root)
        let frozen = try ReplayFixture.validate(run:run)
        _ = try verifyReplaySources(frozen,project:root)
        let snapshot = frozen["snapshot"] as! JSON
        return ["eligible":true,"runId":string(run,"id"),"runHash":try ReplayFixture.hash(run),"contextHash":try ReplayFixture.hash(snapshot),"promptHash":string(snapshot,"promptHash"),"sourceCount":try ReplayFixture.sources(snapshot).count,"inputCount":(snapshot["inputsUsed"] as? [JSON] ?? []).count,"inputHash":try ReplayFixture.hash(snapshot.filter{["inputs","inputsUsed","guidelinesUsed","memoryUsed"].contains($0.key)}),"workflowId":string(run,"workflowId"),"workflowVersion":intValue(run,"workflowVersion"),"shape":"single_contextual_agent_template","providerCalls":0]
    }
    func captureReplayFixture(_ params: JSON) throws -> JSON {
        try ReplayFixture.keys(params,["project","runId","runHash","consent","retentionDays"])
        guard let consent = params["consent"] as? NSNumber, CFGetTypeID(consent) == CFBooleanGetTypeID(), consent.boolValue else { throw VelaError("Explicit historical retention consent is required") }
        let days = try WorkflowContext.integer(params["retentionDays"],default:7,range:1...30,name:"replay retention days")
        let inspection = try inspectReplayFixture(params)
        guard string(inspection,"runHash") == (try requireString(params,"runHash")) else { throw VelaError("Historical run changed") }
        let root = try project(requireString(params,"project")), run = try replayObject("run",id:requireString(params,"runId"),project:root)
        guard try ReplayFixture.hash(run) == string(inspection,"runHash") else { throw VelaError("Historical run changed during capture") }
        let frozen = try ReplayFixture.validate(run:run), id = UUID().uuidString.lowercased()
        var meta = inspection.filter{!["eligible","runId","runHash","providerCalls"].contains($0.key)}
        meta.merge(["id":id,"project":root,"sourceRunId":string(run,"id"),"sourceRunHash":string(inspection,"runHash"),"protocol":ReplayFixture.version,"fixtureHash":try ReplayFixture.hash(frozen),"revision":1,"state":"active","retentionDays":days,"expiresAt":ISO8601DateFormatter().string(from:Date().addingTimeInterval(Double(days)*86400)),"consentCapturedAt":isoNow()]) { _,new in new }
        _ = try store.putBatch([("replay_fixture",meta),("replay_fixture_payload",["id":id,"project":root,"frozen":frozen])],expecting:verifyReplaySources(frozen,project:root) + [("run",string(run,"id"),try ReplayFixture.hash(run))],createOnly:true)
        return try object("replay_fixture",id)
    }
    func forgetReplayFixture(_ params: JSON, expired: Bool = false) throws -> JSON {
        let root = try project(requireString(params,"project")), id = try requireString(params,"id")
        var meta = try replayObject("replay_fixture",id:id,project:root)
        guard try expired || string(meta,"fixtureHash") == requireString(params,"fixtureHash") else { throw VelaError("Fixture hash changed") }
        if string(meta,"state") == "active" {
            let before = try ReplayFixture.hash(meta)
            meta["state"] = expired ? "expired" : "forgotten"; meta["revision"] = intValue(meta,"revision") + 1; meta["revokedAt"] = isoNow()
            _ = try store.putBatch([("replay_fixture",meta)],expecting:[("replay_fixture",id,before)])
        }
        try store.remove("replay_fixture_payload",id)
        let pending = try store.replayPayloadIDs(fixtureId:id,project:root)
        for replayID in pending.prefix(128) { try store.remove("replay_payload",replayID) }
        let remaining = try store.replayPayloadIDs(fixtureId:id,project:root,limit:1)
        meta = try object("replay_fixture",id)
        meta["payloadRemoved"] = remaining.isEmpty; meta["cleanupPending"] = !remaining.isEmpty
        meta["payloadsRemovedThisCall"] = min(128,pending.count)
        return meta
    }
}
