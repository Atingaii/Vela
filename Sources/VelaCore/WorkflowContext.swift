import Foundation
import CoreFoundation

/// An explicit, versioned prompt contract. Values substituted into a template are
/// data: they are never parsed again as templates, executable names, or shell code.
enum WorkflowContext {
    static let promptMarker = "{{vela.prompt}}"
    static let maximumBytes = 48_000
    static let expression = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\}\}"#)

    static func integer(_ value: Any?, default fallback: Int, range: ClosedRange<Int>, name: String) throws -> Int {
        guard let value else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue), range.contains(number.intValue) else { throw VelaError("Invalid \(name)") }
        return number.intValue
    }

    static func validate(_ raw: Any?, steps: [JSON]) throws -> JSON? {
        let contextual = steps.filter { string($0["arguments"] as? JSON ?? [:],"promptMode") == "workflow_context" }
        guard let raw else {
            guard contextual.isEmpty else { throw VelaError("workflow_context requires an explicit workflow context") }; return nil
        }
        guard let context = raw as? JSON, Set(context.keys).isSubset(of:["version","template","inputs","memory"]),
              try integer(context["version"],default:0,range:1...1,name:"context version") == 1,
              let template = context["template"] as? String, !template.isEmpty, template.utf8.count <= 32_000,
              !template.contains("\0"), !contextual.isEmpty else { throw VelaError("Context v1 requires a bounded template and an explicit contextual agent step") }
        guard context["inputs"] == nil || context["inputs"] is [JSON] else { throw VelaError("Context inputs must be an array") }
        let definitions = context["inputs"] as? [JSON] ?? []
        guard definitions.count <= 16 else { throw VelaError("Context supports at most 16 inputs") }
        var identifiers = Set<String>()
        for definition in definitions {
            let id = try requireString(definition,"id")
            guard id.range(of:#"^[A-Za-z_][A-Za-z0-9_]{0,63}$"#,options:.regularExpression) != nil,
                  !["input","guidelines","memory","config","vela"].contains(id), identifiers.insert(id).inserted,
                  Set(definition.keys).isSubset(of:["id","tool","arguments","retrieve","source","value","optional","workflow"]) else { throw VelaError("Invalid or duplicate context input identifier") }
            guard ["tool","retrieve","source","value","workflow"].filter({ definition[$0] != nil }).count == 1 else { throw VelaError("Each context input requires exactly one source") }
            if let optional = definition["optional"] {
                guard let number = optional as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw VelaError("Input optional must be boolean") }
            }
            if let tool = definition["tool"] as? String {
                guard ["git.status","git.diff","git.log"].contains(tool), definition["arguments"] == nil || definition["arguments"] is JSON else { throw VelaError("Context tool input must be a registered read-only Git tool") }
            } else if definition["tool"] != nil { throw VelaError("Invalid context tool") }
            if let retrieval = definition["retrieve"] as? JSON {
                guard Set(retrieval.keys).isSubset(of:["query","k"]), retrieval["query"] is String else { throw VelaError("Invalid retrieval input") }
                _ = try integer(retrieval["k"],default:5,range:1...20,name:"retrieval limit")
            } else if definition["retrieve"] != nil { throw VelaError("Invalid retrieval input") }
            if definition["source"] != nil && string(definition,"source") != "stdin" { throw VelaError("Only explicit stdin sources are supported") }
            if let child = definition["workflow"] as? JSON {
                guard Set(child.keys).isSubset(of:["id","inputs","stdin"]), child["id"] is String,
                      child["inputs"] == nil || child["inputs"] is JSON,
                      child["stdin"] == nil || child["stdin"] is String else { throw VelaError("Invalid sub-workflow input") }
                _ = try requireString(child,"id")
            } else if definition["workflow"] != nil { throw VelaError("Invalid sub-workflow input") }
            guard try jsonString(definition).utf8.count <= 16_000 else { throw VelaError("Context input is too large") }
        }
        guard context["memory"] == nil || context["memory"] is JSON else { throw VelaError("Invalid context memory policy") }
        let memory = context["memory"] as? JSON ?? [:]
        guard Set(memory.keys).isSubset(of:["enabled","budgetTokens"]) else { throw VelaError("Unknown context memory policy") }
        if let enabled = memory["enabled"] {
            guard let number = enabled as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw VelaError("Memory enabled must be boolean") }
        }
        _ = try integer(memory["budgetTokens"],default:2000,range:0...4000,name:"memory budget")
        return context
    }

    static func validateCommand(_ tool: String, _ arguments: JSON) throws {
        guard arguments["contextPromptHash"] == nil else { throw VelaError("Context hashes are assigned by the runner") }
        guard arguments["promptMode"] != nil else { return }
        if tool == "agent.loop" {
            guard string(arguments,"promptMode") == "workflow_context", string(arguments,"prompt") == promptMarker else { throw VelaError("Loop context mode requires exactly {{vela.prompt}} as its prompt") }; return
        }
        guard tool == "agent.run", string(arguments,"promptMode") == "workflow_context",
              let args = arguments["args"] as? [String], args.filter({ $0 == promptMarker }).count == 1,
              args.filter({ $0.contains(promptMarker) }).count == 1 else { throw VelaError("Context mode requires agent.run and exactly one whole {{vela.prompt}} argv entry") }
        // Internal fields may only be produced by the core at run creation.
    }

    static func bounded(_ value: Any) throws {
        guard try jsonString(["value":value]).utf8.count <= maximumBytes else { throw VelaError("Resolved context exceeds 48 KB") }
    }

    static func jsonText(_ value: Any) throws -> String {
        String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.sortedKeys,.withoutEscapingSlashes]),as:UTF8.self)
    }

    static func render(_ value: Any, values: JSON) throws -> Any {
        if let object = value as? JSON { return try object.mapValues { try render($0,values:values) } }
        if let array = value as? [Any] { return try array.map { try render($0,values:values) } }
        guard let text = value as? String else { return value }
        let matches = expression.matches(in:text,range:NSRange(text.startIndex...,in:text))
        func lookup(_ match: NSTextCheckingResult) throws -> Any {
            let key = (text as NSString).substring(with:match.range(at:1))
            var cursor: Any = values
            for part in key.split(separator:".") {
                guard let object = cursor as? JSON, let next = object[String(part)] else { throw VelaError("Unresolved context placeholder: \(key)") }
                cursor = next
            }
            return cursor
        }
        if matches.count == 1, matches[0].range == NSRange(text.startIndex...,in:text) { return try lookup(matches[0]) }
        var rendered = text
        for match in matches.reversed() {
            let replacement = try lookup(match)
            let stringValue = try replacement as? String ?? jsonText(replacement)
            guard let range = Range(match.range,in:rendered) else { throw VelaError("Invalid context template range") }
            rendered.replaceSubrange(range,with:stringValue)
        }
        return rendered
    }

    static func source(_ object: JSON) -> JSON {
        var record: JSON = ["id":string(object,"id"),"kind":string(object,"kind"),"title":string(object,"title"),"content":string(object,"content"),"contentHash":stableHash(string(object,"content")),"sourceUpdatedAt":string(object,"updatedAt"),"scope":string(object,"scope"),"project":string(object,"project")]
        if let version = object["version"] { record["version"] = version }
        record["sourceHash"] = stableHash((try? jsonString(record)) ?? "")
        return record
    }

    // Preserve the existing lexical lookup contract while sharing the same
    // authoritative asset and privacy boundary as the indexed Library search.
    static func publicLibrary(store: VelaStore, query: String, project: String, count: Int) throws -> [JSON] {
        var results: [JSON] = []
        for candidate in try store.search(query,project:project,includePrivate:false,limit:50) {
            guard string(candidate,"kind") == "library", let current = try? LibrarySource.fresh(store:store,id:string(candidate,"id")), LibraryIndex.isPublic(current,project:project) else { continue }
            results.append(current)
            if results.count >= count { break }
        }
        return results
    }
}

extension AutomationService {
    func freezeWorkflowContext(_ workflow: JSON, supplied: JSON, stdin: String?) throws -> JSON? {
        guard let context = workflow["context"] as? JSON else { return nil }
        try WorkflowContext.bounded(supplied)
        if let stdin { try WorkflowContext.bounded(stdin) }
        let root = string(workflow,"project")
        var values: JSON = ["input":supplied]
        var receipts: [JSON] = []
        var degraded = false
        for definition in context["inputs"] as? [JSON] ?? [] {
            let receipt = try resolveOrdinaryContextInput(definition,values:values,project:root,stdin:stdin)
            values[string(definition,"id")] = receipt["value"]
            receipts.append(receipt); degraded = degraded || string(receipt,"state") == "degraded"
            try WorkflowContext.bounded(values)
        }
        return try finishWorkflowContext(workflow,values:values,receipts:receipts,degraded:degraded)
    }

    func resolveOrdinaryContextInput(_ definition: JSON, values: JSON, project root: String, stdin: String?) throws -> JSON {
        let id = string(definition,"id")
            var receipt: JSON = ["id":id,"definition":definition,"state":"resolved"]
            do {
                let value: Any
                if let tool = definition["tool"] as? String {
                    let args = try WorkflowContext.render(definition["arguments"] ?? JSON(),values:values) as? JSON ?? [:]
                    let result = try executeTool(tool,arguments:args,project:root)
                    guard intValue(result,"exitCode") == 0, result["truncated"] as? Bool != true else { throw VelaError("Read input \(id) failed or exceeded its capture limit") }
                    value = result; receipt["arguments"] = args; receipt["source"] = "tool"
                } else if let retrieval = definition["retrieve"] as? JSON {
                    let query = try WorkflowContext.render(retrieval["query"] ?? "",values:values)
                    guard let text = query as? String, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw VelaError("Retrieval query must resolve to nonempty text") }
                    let count = try WorkflowContext.integer(retrieval["k"],default:5,range:1...20,name:"retrieval limit")
                    // Only this registered project's public Library can become a workflow input.
                    let sources = try WorkflowContext.publicLibrary(store:store,query:text,project:root,count:count).map(WorkflowContext.source)
                    value = sources; receipt["source"] = "library"; receipt["query"] = text
                } else if string(definition,"source") == "stdin" {
                    guard let stdin else { throw VelaError("Missing explicit stdin for input \(id)") }
                    value = stdin; receipt["source"] = "stdin"
                } else if definition["workflow"] != nil {
                    throw VelaError("Sub-workflow input must be resolved by the composition runner")
                } else {
                    value = try WorkflowContext.render(definition["value"] ?? NSNull(),values:values); receipt["source"] = "value"
                }
                try WorkflowContext.bounded(value)
                receipt["value"] = value
                receipt["valueHash"] = stableHash(try jsonString(["value":value]))
            } catch {
                guard definition["optional"] as? Bool == true else { throw VelaError("Input \(id): \(error.localizedDescription)") }
                receipt["value"] = ""; receipt["state"] = "degraded"; receipt["error"] = error.localizedDescription
            }
        return receipt
    }

    func finishWorkflowContext(_ workflow: JSON, values source: JSON, receipts: [JSON], degraded: Bool) throws -> JSON {
        let context = workflow["context"] as? JSON ?? [:]
        let root = string(workflow,"project")
        var values = source
        var guidelines: [JSON] = []
        for id in workflow["guidelines"] as? [String] ?? [] {
            guard let item = try store.get("guideline",id), item["private"] as? Bool != true,
                  string(item,"scope") != "private", string(item,"state","active") == "active",
                  string(item,"project") == root || (string(item,"scope") == "global" && string(item,"project").isEmpty) else { throw VelaError("Guideline is missing, private, inactive, or outside this project: \(id)") }
            guidelines.append(WorkflowContext.source(item))
        }
        let memoryPolicy = context["memory"] as? JSON ?? [:]
        let budget = try WorkflowContext.integer(memoryPolicy["budgetTokens"],default:2000,range:0...4000,name:"memory budget")
        var memories: [JSON] = []
        var usedTokens = 0
        if memoryPolicy["enabled"] as? Bool ?? true {
            let recalled = try MemoryService(store:store).recall(["project":root,"query":string(context,"template"),"budget":budget])
            memories = (recalled["items"] as? [JSON] ?? []).map(WorkflowContext.source)
            usedTokens = intValue(recalled,"usedTokens")
        }
        let guidelineText = guidelines.map { string($0,"content") }.joined(separator:"\n\n")
        let memoryText = memories.map { string($0,"title") + "\n" + string($0,"content") }.joined(separator:"\n\n")
        values["guidelines"] = guidelineText; values["memory"] = memoryText
        let template = string(context,"template")
        let rendered = try WorkflowContext.render(template,values:values)
        let body = try rendered as? String ?? WorkflowContext.jsonText(rendered)
        let refs = WorkflowContext.expression.matches(in:template,range:NSRange(template.startIndex...,in:template)).map { (template as NSString).substring(with:$0.range(at:1)) }
        var prefix: [String] = []
        if !memoryText.isEmpty && !refs.contains("memory") { prefix.append(memoryText) }
        if !guidelineText.isEmpty && !refs.contains("guidelines") { prefix.append(guidelineText) }
        let prompt = (prefix + [body]).joined(separator:"\n\n")
        guard !prompt.contains("\0"), prompt.utf8.count <= WorkflowContext.maximumBytes else { throw VelaError("Rendered context prompt exceeds 48 KB or contains NUL") }
        return ["version":1,"template":template,"templateHash":stableHash(template),"renderedPrompt":prompt,"promptHash":stableHash(prompt),"inputs":values.filter { !["guidelines","memory"].contains($0.key) },"inputsUsed":receipts,"guidelinesUsed":guidelines,"memoryUsed":memories,"memoryBudgetTokens":budget,"memoryUsedTokens":usedTokens,"memoryAccounting":"conservative character upper bound","degraded":degraded,"capturedAt":isoNow()]
    }

    func contextArguments(_ args: JSON, snapshot: JSON?) throws -> JSON {
        guard string(args,"promptMode") == "workflow_context" else { return args }
        guard let snapshot, let prompt = snapshot["renderedPrompt"] as? String,
              stableHash(prompt) == string(snapshot,"promptHash") else { throw VelaError("Missing or inconsistent frozen workflow context") }
        var frozen = args
        if args["args"] == nil && string(args,"prompt") == WorkflowContext.promptMarker { frozen["prompt"] = prompt }
        else {
            guard let argv = args["args"] as? [String], argv.filter({ $0 == WorkflowContext.promptMarker }).count == 1 else { throw VelaError("Missing contextual argv marker") }
            frozen["args"] = argv.map { $0 == WorkflowContext.promptMarker ? prompt : $0 }
        }
        frozen["contextPromptHash"] = stableHash(prompt)
        return frozen
    }
}
