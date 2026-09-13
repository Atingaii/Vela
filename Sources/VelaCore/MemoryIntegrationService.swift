import Foundation
import CoreFoundation

/// Local process API: namespace selection is not authentication of an external host.
final class MemoryIntegrationService {
    private let integrations = ["openclaw", "ai-sdk-v4", "openai-responses"]
    private let store: VelaStore
    init(store: VelaStore) { self.store = store }
    private func boundary(_ params: JSON, allowed: Set<String>) throws -> (String,String) {
        guard Set(params.keys).isSubset(of:allowed) else { throw VelaError("Unsupported integration memory fields") }
        let project = try checkedProject(params,required:true)!, namespace = try requireString(params,"namespace")
        guard let registered = try store.get("project",stableHash(project)), string(registered,"path") == project,
              namespace.utf8.count <= 256, !namespace.contains("\0"), namespace.rangeOfCharacter(from:.controlCharacters) == nil else { throw VelaError("Integration memory requires a registered project and explicit namespace") }
        return (project,namespace)
    }
    func handle(_ method: String, _ params: JSON) throws -> JSON {
        switch method {
        case "memory.integration.capture":
            let (project,namespace) = try boundary(params,allowed:["project","namespace","integration","sourceID","records"])
            let integration = string(params,"integration")
            guard integrations.contains(integration), JSONSerialization.isValidJSONObject(params), try jsonString(params).utf8.count <= 64 * 1024,
                  let records = params["records"] as? [JSON], !records.isEmpty, records.count <= 20 else { throw VelaError("Integration capture requires 1–20 selected original messages") }
            let sourceID = try requireString(params,"sourceID")
            guard sourceID.utf8.count <= 300, !sourceID.contains("\0") else { throw VelaError("Invalid integration source identity") }
            var writes: [(String,JSON)] = [], skipped: [String] = [], seen: Set<String> = []
            for record in records {
                guard Set(record.keys).isSubset(of:["id","role","content","title"]), ["user","assistant"].contains(string(record,"role")) else { throw VelaError("Only selected conversation messages can be captured") }
                let content = try requireString(record,"content"), sourceMessage = try requireString(record,"id"), title = string(record,"title",String(content.prefix(120)))
                guard content.utf8.count <= 16 * 1024, !content.contains("\0"), ModelImprovement.redact(content) == content,
                      sourceMessage.utf8.count <= 300, !sourceMessage.contains("\0"), title.count <= 300, !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw VelaError("Integration message contains unsupported or credential-like content") }
                let identity: JSON = ["project":project,"namespace":namespace,"integration":integration,"sourceID":sourceID,"sourceMessage":sourceMessage,"contentSHA256":stableHash(content),"role":string(record,"role")]
                let id = "integration-" + stableHash(try jsonString(identity))
                guard seen.insert(id).inserted else { throw VelaError("Integration capture repeats a source message") }
                if let existing = try store.get("memory",id) {
                    guard string(existing,"project") == project, string(existing,"namespace") == namespace,
                          let provenance = existing["provenance"] as? JSON, let saved = provenance["integrationIdentity"] as? JSON,
                          try jsonString(saved) == jsonString(identity) else { throw VelaError("Integration capture conflicts with an existing record") }
                    skipped.append(id); continue
                }
                let item: JSON = ["id":id,"project":project,"namespace":namespace,"scope":"namespace","state":"candidate","private":false,"type":"observation","title":title,"content":content,"tokens":tokenEstimate(content),
                                  "sourceSession":sourceID,"sourceMessage":sourceMessage,
                                  "provenance":["origin":"integration-capture","integrationIdentity":identity,"hostAuthenticatedByCore":false,"method":"verbatim-selected-message","requiresReview":true] as JSON]
                writes.append(("memory",item))
            }
            let written = try store.putBatch(writes,createOnly:true)
            return ["created":written.count,"skipped":skipped.count,"ids":written.map { string($0,"id") },"skippedIds":skipped,"state":"candidate","namespace":namespace,"modelCalled":false,"method":"verbatim-selected-messages","hostAuthenticatedByCore":false]
        case "memory.integration.recall":
            _ = try boundary(params,allowed:["project","namespace","query","budget","retrievalMode","language","limit","minSimilarity"])
            _ = try requireString(params,"query")
            var limit = 5
            if let raw = params["limit"] {
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      number.doubleValue.rounded(.down) == number.doubleValue, (1...50).contains(number.intValue) else { throw VelaError("Invalid integration recall limit") }
                limit = number.intValue
            }
            var result = try MemoryService(store:store).recall(params)
            let items = result["items"] as? [JSON] ?? []
            if items.count > limit {
                let selected = Array(items.prefix(limit)); result["items"] = selected; result["truncated"] = true
                result["usedTokens"] = selected.reduce(0) { $0 + intValue($1,"recallTokens") }
            }
            return result
        case "memory.integration.stats":
            let (project,namespace) = try boundary(params,allowed:["project","namespace"])
            let page = try store.list("memory",project:project,limit:10000)
            let rows = page.filter { string($0,"scope") == "namespace" && string($0,"namespace") == namespace && ModelImprovement.falseOrAbsent($0["private"]) && !privateLibraryPath(string($0,"sourceFile")) }
            return ["project":project,"namespace":namespace,"observedRecords":rows.count,"states":Dictionary(grouping:rows,by:{string($0,"state")}).mapValues(\.count),"complete":page.count < 10000,"limit":10000,"namespaceIsRemoteACL":false,"supportedIntegrations":integrations]
        default: throw VelaError("Unknown integration memory operation")
        }
    }
}
