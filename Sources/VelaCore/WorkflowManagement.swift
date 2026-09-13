import Foundation
import CoreFoundation

extension AutomationService {
    /// Review a definition without importing hand edits or executing inputs.
    func inspectWorkflow(_ params: JSON) throws -> JSON {
        let root = try project(requireString(params,"project")), id = try requireString(params,"id")
        guard let stored = try store.workflowRecord(id), string(stored,"project") == root else { throw VelaError("Workflow was not found in this project") }
        let path = "assets/workflow/" + id + ".md"
        guard string(stored,"assetPath") == store.root.appendingPathComponent(path).path,
              let markdown = try FoundationFile.readUTF8(root:store.root,path:path) else { throw VelaError("Workflow asset is missing or unsafe") }
        let hash = stableHash(try jsonString(stored) + "\n" + markdown)
        var result: JSON = ["id":id,"project":root,"snapshotHash":hash,"assetHash":stableHash(markdown),"markdown":markdown,"state":string(stored,"state"),"definition":stored,"valid":false,"diagnostics":[] as [JSON]]
        guard string(stored,"state") != "archived" else { result["diagnostics"] = [["code":"archived","message":"Restore this definition before it can run"]]; return result }
        do {
            result["definition"] = try loadCurrentWorkflow(id,synchronize:false)
            result["valid"] = true
        } catch { result["diagnostics"] = [["code":"invalid_definition","message":error.localizedDescription]] }
        return result
    }

    func validateWorkflows(_ params: JSON) throws -> JSON {
        let root = try project(requireString(params,"project"))
        let after = string(params,"cursor")
        guard after.utf8.count <= 150, params["limit"] == nil || (params["limit"] as? NSNumber) != nil else { throw VelaError("Invalid validation page") }
        let limit = params["limit"] == nil ? 100 : intValue(params,"limit")
        guard (1...1000).contains(limit) else { throw VelaError("Validation page limit must be 1–1000") }
        let identities = try store.workflowIdentities(project:root,after:after,limit:limit + 1)
        var results: [JSON] = []
        for identity in identities.prefix(limit) {
            do {
                let inspected = try inspectWorkflow(["id":identity["id"]!,"project":root])
                results.append(inspected.filter { ["id","project","state","valid","diagnostics","snapshotHash","assetHash"].contains($0.key) })
            } catch { results.append(["id":string(identity,"id"),"project":root,"valid":false,"diagnostics":[["code":"unreadable_asset","message":error.localizedDescription]]]) }
        }
        return ["results":results,"cursor":identities.count > limit ? string(results.last ?? [:],"id") as Any : NSNull(),"readOnly":true,"checked":results.count]
    }

    private func reviewedWorkflow(_ params: JSON, allowArchived: Bool = false) throws -> (JSON,JSON) {
        let inspected = try inspectWorkflow(params)
        guard string(inspected,"snapshotHash") == (try requireString(params,"snapshotHash")) else { throw VelaError("Workflow changed since review; inspect the latest definition") }
        guard (inspected["valid"] as? Bool == true) || (allowArchived && string(inspected,"state") == "archived") else { throw VelaError("Repair the workflow definition before changing it") }
        if allowArchived, string(inspected,"state") == "archived", let stored = try store.workflowRecord(requireString(params,"id")) { return (inspected,stored) }
        return (inspected,try object("workflow",requireString(params,"id")))
    }

    func cloneWorkflow(_ params: JSON) throws -> JSON {
        let (inspected,_) = try reviewedWorkflow(params)
        var source = inspected["definition"] as? JSON ?? [:]
        let sourceID = string(source,"id"), sourceVersion = intValue(source,"version")
        for key in ["id","version","kind","createdAt","updatedAt","assetPath","humanEdited","clonedFrom"] { source.removeValue(forKey:key) }
        source["title"] = string(params,"title",string(source,"title") + " copy")
        source["enabled"] = false
        var clone = try saveWorkflow(source,persist:false)
        clone["clonedFrom"] = ["workflowId":sourceID,"version":sourceVersion,"snapshotHash":string(inspected,"snapshotHash"),"clonedAt":isoNow()]
        var version = clone; version["id"] = string(clone,"id") + ".v1"
        return try store.putBatch([("workflow_version",version),("workflow",clone)],expectingAbsent:[("workflow",string(clone,"id")),("workflow_version",string(version,"id"))],createOnly:true)[1]
    }

    func setWorkflowEnabled(_ params: JSON) throws -> JSON {
        guard let flag = params["enabled"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw VelaError("enabled must be a boolean") }
        let (inspected,_) = try reviewedWorkflow(params)
        var definition = inspected["definition"] as? JSON ?? [:]
        definition["enabled"] = flag.boolValue
        return try saveWorkflow(definition)
    }

    func archiveWorkflow(_ params: JSON) throws -> JSON {
        let (inspected,original) = try reviewedWorkflow(params)
        let id = string(original,"id"), root = string(original,"project")
        guard try store.activeWorkflowRun(workflowId:id,project:root) == nil else { throw VelaError("An active or uncertain run still uses this workflow; inspect it before archiving") }
        var cursor = ""
        while true {
            let page = try store.workflowIdentities(project:root,after:cursor,limit:100)
            if page.isEmpty { break }
            for item in page where string(item,"id") != id && string(item,"state") != "archived" {
                let other = try loadCurrentWorkflow(string(item,"id"),validatingDependencies:false,synchronize:false)
                let stageReferences = (other["pipeline"] as? [JSON] ?? []).map { string($0,"workflowId") }
                let inputReferences = ((other["context"] as? JSON)?["inputs"] as? [JSON] ?? []).compactMap { ($0["workflow"] as? JSON)?["id"] as? String }
                guard !(stageReferences + inputReferences).contains(id) else { throw VelaError("Workflow is referenced by " + string(other,"title") + "; remove that dependency first") }
            }
            cursor = string(page.last!,"id")
        }
        var archived = inspected["definition"] as? JSON ?? original
        archived["state"] = "archived"; archived["enabled"] = false; archived["archivedAt"] = isoNow(); archived["version"] = intValue(original,"version") + 1
        archived["content"] = try workflowMarkdown(archived)
        var version = archived; version["id"] = id + ".v" + String(intValue(archived,"version"))
        return try store.putBatch([("workflow_version",version),("workflow",archived)],expecting:[("workflow",id,stableHash(try jsonString(original)))],expectingAbsent:[("workflow_version",string(version,"id"))])[1]
    }

    func restoreWorkflow(_ params: JSON) throws -> JSON {
        let (inspected,original) = try reviewedWorkflow(params,allowArchived:true)
        guard string(original,"state") == "archived" else { throw VelaError("Workflow is not archived") }
        guard string(inspected,"markdown").hasSuffix("\n\n# " + string(original,"title") + "\n\n" + string(original,"content") + "\n") else { throw VelaError("Archived asset was edited; repair its original Markdown before restoring") }
        // Archived content remains on disk for recovery. Require it to match
        // the stored asset before restoring; hand edits must be reviewed later.
        var definition = original
        definition["state"] = "active"; definition["enabled"] = false
        return try saveWorkflow(definition,allowArchived:true)
    }
}
