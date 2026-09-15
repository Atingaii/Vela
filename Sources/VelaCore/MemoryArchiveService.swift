import Foundation
import CoreFoundation

/// A bounded, untrusted interchange format, not an authenticated backup or a model prompt.
final class MemoryArchiveService {
    static let maximumEntries = 100
    static let maximumBytes = 1024 * 1024
    private let store: VelaStore
    private let scopes: Set<String> = ["project", "repository", "branch", "worktree", "task", "session", "namespace"]
    private let types: Set<String> = ["decision", "constraint", "preference", "failure", "fact", "workflow knowledge", "observation", "hypothesis", "checkpoint"]
    private let states: Set<String> = ["candidate", "active", "superseded", "archived"]
    private let metadataKeys: Set<String> = ["branch", "worktree", "task", "namespace", "sourceSession", "sourceMessage", "sourceFile", "sourceCommit"]

    init(store: VelaStore) { self.store = store }

    func handle(_ method: String, _ params: JSON) throws -> JSON {
        switch method {
        case "memory.archive.fromWalrusRecords":
            return try fromWalrusRecords(params)
        case "memory.archive.export":
            try keys(params, allowed:["project", "ids"], required:["project"])
            let project = try registeredProject(params)
            var items: [JSON]
            if let rawIDs = params["ids"] {
                guard let ids = rawIDs as? [String], !ids.isEmpty, ids.count <= Self.maximumEntries, Set(ids).count == ids.count else { throw VelaError("Archive ids must be a unique list of 1–100 memory identifiers") }
                items = try ids.map { id in
                    try identifier(id)
                    guard let item = try store.get("memory",id), string(item,"project") == project, eligible(item) else { throw VelaError("An archive selection is missing, private, or outside the selected project") }
                    return item
                }
            } else {
                // Never silently export only the first page of a project.
                let all = try store.list("memory",project:project,limit:10000)
                guard all.count < 10000 else { throw VelaError("Select explicit memory ids for a large project archive") }
                items = all.filter(eligible)
                guard items.count <= Self.maximumEntries else { throw VelaError("Archive exceeds 100 memories; select explicit ids") }
            }
            let entries = try items.sorted { string($0,"id") < string($1,"id") }.map { item -> JSON in
                var metadata: JSON = [:]
                for key in metadataKeys { if let value = item[key] as? String, !value.isEmpty { metadata[key] = value } }
                let record: JSON = ["sourceId":string(item,"id"), "title":string(item,"title"), "content":string(item,"content"), "type":string(item,"type","fact"), "scope":string(item,"scope","project"), "state":string(item,"state","candidate"), "private":false, "metadata":metadata]
                return ["record":record, "sha256":stableHash(try jsonString(record))]
            }
            var archive: JSON = ["format":"vela.memory-archive", "version":1, "source":["project":project, "namespace":"project:" + stableHash(project)] as JSON, "entries":entries]
            archive["sha256"] = stableHash(try jsonString(archive))
            _ = try validate(archive)
            return ["archive":archive, "count":entries.count, "bytes":try jsonString(archive).utf8.count, "includesPrivate":false, "includesGlobal":false, "encrypted":false]
        case "memory.archive.validate", "memory.archive.import":
            let importing = method == "memory.archive.import"
            try keys(params, allowed:importing ? ["project", "archive"] : ["archive"], required:importing ? ["project", "archive"] : ["archive"])
            guard let archive = params["archive"] as? JSON else { throw VelaError("Archive must be a JSON object") }
            let entries = try validate(archive)
            if !importing { return ["valid":true, "count":entries.count, "sha256":string(archive,"sha256"), "bytes":try jsonString(archive).utf8.count, "authenticated":false] }
            let project = try registeredProject(params)
            let source = archive["source"] as! JSON
            var writes: [(String,JSON)] = []; var skipped: [String] = []
            for entry in entries {
                let record = entry["record"] as! JSON
                let identity: JSON = ["targetProject":project, "source":source, "sourceId":string(record,"sourceId"), "recordSHA256":string(entry,"sha256")]
                let id = "archive-" + stableHash(try jsonString(identity))
                if let existing = try store.get("memory",id) {
                    guard string(existing,"project") == project,
                          let provenance = existing["provenance"] as? JSON,
                          string(provenance,"origin") == "memory-archive",
                          let savedIdentity = provenance["archiveIdentity"] as? JSON,
                          try jsonString(savedIdentity) == jsonString(identity) else { throw VelaError("Archive import conflicts with an existing memory; no entries were imported") }
                    // User edits and lifecycle decisions made after import are never reverted.
                    skipped.append(id); continue
                }
                let provenance: JSON = ["origin":"memory-archive", "archiveIdentity":identity, "archiveSHA256":string(archive,"sha256"), "sourceScope":string(record,"scope"), "sourceState":string(record,"state"), "sourceMetadata":record["metadata"] as! JSON, "authenticated":false]
                let item: JSON = ["id":id, "project":project, "title":string(record,"title"), "content":string(record,"content"), "type":string(record,"type"), "scope":"project", "state":"candidate", "private":false, "tokens":tokenEstimate(string(record,"content")), "provenance":provenance]
                writes.append(("memory",item))
            }
            // createOnly is checked under the same SQLite write transaction as every insert.
            // A concurrent import may report a conflict; uncertain writes are never retried.
            let imported = try store.putBatch(writes,createOnly:true)
            return ["imported":imported.count, "skipped":skipped.count, "ids":imported.map { string($0,"id") }, "skippedIds":skipped, "project":project, "state":"candidate", "sha256":string(archive,"sha256")]
        default: throw VelaError("Unknown memory archive method")
        }
    }

    private func registeredProject(_ params: JSON) throws -> String {
        let project = try checkedProject(params,required:true)!
        guard let item = try store.get("project",stableHash(project)), string(item,"path") == project else { throw VelaError("Archive operations require an explicitly registered project") }
        return project
    }

    /// Converts explicitly selected remote UTF-8 records using Core's canonical checksum rules.
    /// The virtual source path is provenance only and is never resolved or read.
    private func fromWalrusRecords(_ params: JSON) throws -> JSON {
        try keys(params,allowed:["source", "records", "intendedUse"],required:["source", "records", "intendedUse"])
        guard string(params,"intendedUse") == "candidate-review", JSONSerialization.isValidJSONObject(params), try jsonString(params).utf8.count <= Self.maximumBytes,
              let source = params["source"] as? JSON, let records = params["records"] as? [JSON], !records.isEmpty, records.count <= Self.maximumEntries else { throw VelaError("Remote records require explicit candidate review and a bounded record list") }
        try keys(source,allowed:["network", "packageID", "accountID", "owner", "namespace"],required:["network", "packageID", "accountID", "owner", "namespace"])
        guard ["mainnet", "testnet"].contains(string(source,"network")) else { throw VelaError("Invalid remote network") }
        for key in ["packageID", "accountID", "owner"] {
            guard string(source,key).range(of:"^0x[0-9a-f]{64}$",options:.regularExpression) != nil else { throw VelaError("Invalid remote identity") }
        }
        let namespace = try requireString(source,"namespace")
        guard namespace.utf8.count <= 256, !namespace.contains("\0") else { throw VelaError("Invalid remote namespace") }
        let sourceJSON = try jsonString(source), virtualProject = "/external/walrus/" + stableHash(try jsonString(source))
        var seen: Set<String> = []
        let entries = try records.map { record -> JSON in
            try keys(record,allowed:["blobID", "title", "content", "sha256", "private", "receipt"],required:["blobID", "title", "content", "sha256", "private"])
            let blob = try requireString(record,"blobID"), content = try requireString(record,"content"), title = try requireString(record,"title")
            let base64 = blob.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/") + "="
            guard blob.range(of:"^[A-Za-z0-9_-]{43}$",options:.regularExpression) != nil,
                  let decoded = Data(base64Encoded:base64), decoded.count == 32,
                  decoded.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") == blob,
                  seen.insert(blob).inserted, title.count <= 300, content.utf8.count <= 512 * 1024, !content.contains("\0"),
                  stableHash(content) == string(record,"sha256"),
                  let privacy = record["private"] as? NSNumber, CFGetTypeID(privacy) == CFBooleanGetTypeID(), !privacy.boolValue else { throw VelaError("Invalid, repeated, private, or checksum-mismatched remote record") }
            var verification: JSON = ["plaintextSHA256VerifiedByCore":true, "remoteAuthenticationVerifiedByCore":false, "source":"caller-reported"]
            if let rawReceipt = record["receipt"] {
                guard let receipt = rawReceipt as? JSON else { throw VelaError("Invalid recovery receipt") }
                try keys(receipt,allowed:["sealAuthenticated", "expectedChecksumVerified", "actualSHA256", "plaintextBytes", "manifestSHA256", "manifestAuthenticated"],required:["sealAuthenticated", "expectedChecksumVerified", "actualSHA256", "plaintextBytes", "manifestSHA256", "manifestAuthenticated"])
                for key in ["sealAuthenticated", "expectedChecksumVerified", "manifestAuthenticated"] { guard let value = receipt[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw VelaError("Invalid recovery receipt boolean") } }
                guard string(receipt,"actualSHA256") == string(record,"sha256"), string(receipt,"manifestSHA256").range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
                      let bytes = receipt["plaintextBytes"] as? NSNumber, CFGetTypeID(bytes) != CFBooleanGetTypeID(), bytes.doubleValue == Double(content.utf8.count) else { throw VelaError("Recovery receipt does not match the supplied plaintext") }
                verification["reportedReceipt"] = receipt
            }
            let converted: JSON = ["sourceId":"blob-" + blob, "title":title, "content":content, "type":"fact", "scope":"project", "state":"candidate", "private":false,
                                  "metadata":["sourceSession":sourceJSON, "sourceCommit":blob, "sourceMessage":try jsonString(verification)] as JSON]
            return ["record":converted, "sha256":stableHash(try jsonString(converted))]
        }
        var archive: JSON = ["format":"vela.memory-archive", "version":1, "source":["project":virtualProject, "namespace":"project:" + stableHash(virtualProject)] as JSON, "entries":entries]
        archive["sha256"] = stableHash(try jsonString(archive)); _ = try validate(archive)
        return ["archive":archive, "count":entries.count, "bytes":try jsonString(archive).utf8.count, "encrypted":false, "writesPerformed":false, "authenticated":false, "sourcePathIsVirtual":true, "requiresCandidateReview":true]
    }

    private func eligible(_ item: JSON) -> Bool {
        if let privacy = item["private"] {
            guard let number = privacy as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID(), !number.boolValue else { return false }
        }
        return scopes.contains(string(item,"scope","project")) && !privateLibraryPath(string(item,"sourceFile"))
    }

    private func keys(_ object: JSON, allowed: Set<String>, required: Set<String>) throws {
        guard Set(object.keys).isSubset(of:allowed), required.isSubset(of:Set(object.keys)) else { throw VelaError("Archive contains missing or unsupported fields") }
    }

    private func identifier(_ value: String) throws {
        guard !value.isEmpty, value.count <= 150, value != ".", value != "..", value.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil else { throw VelaError("Archive contains an invalid memory identifier") }
    }

    private func validate(_ archive: JSON) throws -> [JSON] {
        guard JSONSerialization.isValidJSONObject(archive), try jsonString(archive).utf8.count <= Self.maximumBytes else { throw VelaError("Archive exceeds the 1 MiB limit or is not valid JSON") }
        try keys(archive,allowed:["format", "version", "source", "entries", "sha256"],required:["format", "version", "source", "entries", "sha256"])
        guard string(archive,"format") == "vela.memory-archive", let version = archive["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1 else { throw VelaError("Unsupported memory archive format or version") }
        guard let source = archive["source"] as? JSON else { throw VelaError("Archive source must be an object") }
        try keys(source,allowed:["project", "namespace"],required:["project", "namespace"])
        // Foreign source identifiers are data only: validation never resolves or reads these paths.
        let sourceProject = try requireString(source,"project")
        guard sourceProject.hasPrefix("/"), sourceProject.utf8.count <= 4096,
              string(source,"namespace") == "project:" + stableHash(sourceProject) else { throw VelaError("Invalid archive source namespace") }
        guard let entries = archive["entries"] as? [JSON], entries.count <= Self.maximumEntries else { throw VelaError("Archive must contain no more than 100 entries") }
        var sourceIDs: Set<String> = []
        for entry in entries {
            try keys(entry,allowed:["record", "sha256"],required:["record", "sha256"])
            guard let record = entry["record"] as? JSON else { throw VelaError("Archive record must be an object") }
            try keys(record,allowed:["sourceId", "title", "content", "type", "scope", "state", "private", "metadata"],required:["sourceId", "title", "content", "type", "scope", "state", "private", "metadata"])
            let id = try requireString(record,"sourceId"); try identifier(id)
            guard sourceIDs.insert(id).inserted else { throw VelaError("Archive repeats a source identifier") }
            let title = try requireString(record,"title"), content = try requireString(record,"content")
            guard title.count <= 300, content.utf8.count <= 512 * 1024,
                  types.contains(string(record,"type")), scopes.contains(string(record,"scope")), states.contains(string(record,"state")),
                  let privacy = record["private"] as? NSNumber, CFGetTypeID(privacy) == CFBooleanGetTypeID(), !privacy.boolValue,
                  let metadata = record["metadata"] as? JSON else { throw VelaError("Invalid or private archive memory") }
            try keys(metadata,allowed:metadataKeys,required:[])
            for value in metadata.values { guard let value = value as? String, value.utf8.count <= 4096 else { throw VelaError("Invalid archive source metadata") } }
            guard !privateLibraryPath(string(metadata,"sourceFile")) else { throw VelaError("Private source material cannot be imported from this archive format") }
            guard string(entry,"sha256") == stableHash(try jsonString(record)) else { throw VelaError("Archive memory checksum mismatch") }
        }
        var payload = archive; payload.removeValue(forKey:"sha256")
        guard string(archive,"sha256") == stableHash(try jsonString(payload)) else { throw VelaError("Archive checksum mismatch") }
        return entries
    }
}
