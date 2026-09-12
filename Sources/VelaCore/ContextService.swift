import Foundation

/// Human-owned guidelines and transparent local workflow drafting. No external model is called.
public final class ContextService {
    private let store: VelaStore
    public init(store: VelaStore) { self.store = store }

    public func handle(_ method: String, _ params: JSON) throws -> Any? {
        switch method {
        case "guidelines.list": return try store.list("guideline", project: checkedProject(params))
        case "guidelines.save":
            let title = try requireString(params,"title"), content = try requireString(params,"content")
            guard title.count <= 240, content.utf8.count <= 128 * 1024 else { throw VelaError("Guideline exceeds size limit") }
            let scope = string(params,"scope","project").lowercased()
            guard ["project","global"].contains(scope) else { throw VelaError("Guidelines support project or global scope") }
            var item: JSON = ["title":title,"content":content,"scope":scope,"state":"active","tokens":tokenEstimate(content)]
            if scope == "project" { item["project"] = try checkedProject(params,required:true) }
            if let id = params["id"] as? String {
                guard let old = try store.get("guideline",id), string(old,"project") == string(item,"project") else { throw VelaError("Existing guideline must have the same scope") }
                item["id"] = id; item["version"] = intValue(old,"version") + 1
            } else { item["version"] = 1 }
            let result = try store.put("guideline",item)
            var version = result; version["id"] = string(result,"id") + ".v" + String(intValue(result,"version"))
            _ = try store.put("guideline_version",version)
            return result
        case "workflows.build": return try draftWorkflow(params)
        case "regression.list": return try regressions(params)
        case "signals.record":
            var signal = params
            signal.removeValue(forKey:"id")
            signal["title"] = try requireString(params,"title")
            signal["content"] = try requireString(params,"content")
            signal["project"] = try checkedProject(params,required:true)
            signal["state"] = "candidate"; signal["origin"] = "contribution"
            signal["sourceSession"] = try requireString(params,"sourceSession")
            guard let session = try store.get("session",string(signal,"sourceSession")), string(session,"project") == string(signal,"project") else { throw VelaError("Signal requires an existing source session in this project") }
            return try store.put("signal",signal)
        case "suggestions.draft":
            let project = try checkedProject(params,required:true)!
            return try store.put("suggestion",["title":try requireString(params,"title"),"content":try requireString(params,"content"),"project":project,"state":"draft","carrier":"reference","operations":[] as [JSON],"evidence":[],"origin":"contribution","contextTokens":0])
        default: return nil
        }
    }

    private func draftWorkflow(_ params: JSON) throws -> JSON {
        let request = try requireString(params,"description")
        guard request.count <= 8000 else { throw VelaError("Workflow description is too long") }
        let project = try checkedProject(params,required:true)!
        guard try store.list("project").contains(where:{canonicalProject(string($0,"path")) == project}) else { throw VelaError("Register the project before drafting a workflow") }
        let lower = request.lowercased()
        let root = URL(fileURLWithPath:project)
        var package: JSON = [:]
        let packagePath = root.appendingPathComponent("package.json")
        if let meta = try? packagePath.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]), meta.isSymbolicLink != true, (meta.fileSize ?? Int.max) <= 256_000,
           let data = try? Data(contentsOf:packagePath), let parsed = (try? JSONSerialization.jsonObject(with:data)) as? JSON { package = parsed }
        let scripts = package["scripts"] as? [String:String] ?? [:]
        let manager: String
        if let declared = package["packageManager"] as? String, ["pnpm","npm","yarn","bun"].contains(String(declared.split(separator:"@").first ?? "")) { manager = String(declared.split(separator:"@")[0]) }
        else if FileManager.default.fileExists(atPath:root.appendingPathComponent("pnpm-lock.yaml").path) { manager = "pnpm" }
        else if FileManager.default.fileExists(atPath:root.appendingPathComponent("yarn.lock").path) { manager = "yarn" }
        else { manager = "npm" }
        var steps: [JSON] = [], unresolved: [String] = []
        func step(_ title: String, _ tool: String, _ arguments: JSON = [:]) -> JSON { ["title":title,"tool":tool,"arguments":arguments] }
        if lower.contains("diff") || lower.contains("变更") || lower.contains("审查") || lower.contains("review") { steps.append(step("查看 Git 变更","git.diff")) }
        if lower.contains("status") || lower.contains("状态") { steps.append(step("查看工作区状态","git.status")) }
        if lower.contains("test") || lower.contains("测试") {
            if scripts["test"] != nil { steps.append(step("运行项目测试","shell.test",["executable":manager,"args":["run","test"]])) }
            else if FileManager.default.fileExists(atPath:root.appendingPathComponent("Package.swift").path) { steps.append(step("运行 Swift 测试","shell.test",["executable":"swift","args":["test"]])) }
            else { unresolved.append("未发现确定的测试入口，请指定 executable 和 args。") }
        }
        if lower.contains("typecheck") || lower.contains("类型检查") {
            if let script = ["typecheck","type-check","check-types"].first(where:{scripts[$0] != nil}) { steps.append(step("运行类型检查","shell.typecheck",["executable":manager,"args":["run",script]])) }
            else { unresolved.append("未发现类型检查脚本，请指定命令。") }
        }
        if lower.contains("log") || lower.contains("提交记录") { steps.append(step("读取最近提交","git.log")) }
        if steps.isEmpty { unresolved.append("本地解析器目前识别 Git 状态/变更/日志、测试和类型检查。请在步骤编辑器补充其他操作。") }
        if ["push","release","deploy","slack","发送","发布","部署","删除"].contains(where:lower.contains) { unresolved.append("外部发布/消息/删除操作不自动配置；请使用受支持工具并逐项审批。") }
        let trigger = lower.contains("完成后") || lower.contains("finished") || lower.contains("completed") ? "session_completed" : "manual"
        let workflow: JSON = ["title":String(request.prefix(70)),"project":project,"description":request,"trigger":trigger,"enabled":false,"steps":steps,"guidelines":[]]
        return ["workflow":workflow,"unresolvedInputs":unresolved,"mode":"deterministic-local-builder","saved":false,"approvalRequired":steps.contains { string($0,"tool").hasPrefix("shell.") },"message":"依据请求关键词和项目脚本生成草稿。请核对步骤后保存；未调用模型、未执行命令。"]
    }

    private func regressions(_ params: JSON) throws -> JSON {
        let evals = try store.list("eval",project:checkedProject(params),limit:1000)
        let runs = try store.list("run",project:checkedProject(params),limit:10000)
        let grouped = Dictionary(grouping:runs) { string($0,"workflowId") }
        var comparisons: [JSON] = []
        for (id, values) in grouped {
            let versions = Dictionary(grouping:values) { intValue($0,"workflowVersion") }
            let order = versions.keys.sorted()
            guard order.count > 1 else { continue }
            let old = versions[order[order.count-2]]!, new = versions[order.last!]!
            func metrics(_ items: [JSON]) -> JSON {
                let eligible = items.filter { ["completed","failed"].contains(string($0,"state")) && $0["dryRun"] as? Bool != true }
                let passed = eligible.filter { string($0,"state") == "completed" }.count
                return ["runs":eligible.count,"successes":passed,"successRate":eligible.isEmpty ? NSNull() : Double(passed)/Double(eligible.count),"meanRuntimeMs":eligible.isEmpty ? NSNull() : Double(eligible.reduce(0){$0+intValue($1,"durationMs")})/Double(eligible.count)]
            }
            comparisons.append(["workflowId":id,"baselineVersion":order[order.count-2],"candidateVersion":order.last!,"baseline":metrics(old),"candidate":metrics(new),"causality":"observational; inputs and environments may differ"])
        }
        return ["workflowComparisons":comparisons,"evaluations":evals,"message":"版本趋势仅为观测结果；归因需要同条件隔离评测。"]
    }
}
