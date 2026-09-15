import Foundation
import CoreFoundation

/// A bounded, evidence-only suggestion to adjust one already configured process
/// timeout. It never starts work, retries a run, or grants a new tool/path.
extension AutomationService {
    private static let healthProposalScanCap = 10_000
    private static let healthProposalTools: Set<String> = ["shell.test","shell.typecheck","agent.run"]

    func workflowHealthProposal(_ method: String, _ params: JSON) throws -> JSON {
        switch method {
        case "workflows.health.proposeTimeout": return try createHealthTimeoutProposal(params)
        case "workflows.health.proposal.get": return try healthProposalView(params)
        case "workflows.health.proposal.list": return try listHealthProposals(params)
        case "workflows.health.proposal.decide": return try decideHealthProposal(params)
        default: throw VelaError("Unknown workflow health proposal method")
        }
    }

    private func createHealthTimeoutProposal(_ params: JSON) throws -> JSON {
        let allowed: Set<String> = ["project","workflowId","workflowVersion","snapshotHash","runId","stepId","findingId","newTimeoutSeconds"]
        guard Set(params.keys) == allowed else { throw VelaError("Workflow health timeout proposal requires its complete frozen evidence") }
        let root = try project(requireString(params,"project")), workflowID = try requireString(params,"workflowId"), runID = try requireString(params,"runId"), stepID = try requireString(params,"stepId"), findingID = try requireString(params,"findingId")
        guard boundedPositiveInteger(params["workflowVersion"]), workflowID.utf8.count <= 200, runID.utf8.count <= 200, stepID.utf8.count <= 200, findingID.utf8.count <= 200 else { throw VelaError("Invalid workflow health proposal identity") }
        let version = intValue(params,"workflowVersion"), snapshotHash = try requireString(params,"snapshotHash")
        guard snapshotHash.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else { throw VelaError("Invalid workflow health proposal snapshot") }
        try completeHealthEvidence(project:root)
        let inspected = try inspectWorkflow(["project":root,"id":workflowID])
        guard inspected["valid"] as? Bool == true, string(inspected,"state") == "active", string(inspected,"snapshotHash") == snapshotHash else { throw VelaError("Workflow changed or is not a valid active reviewed definition") }
        let workflow = inspected["definition"] as? JSON ?? [:]
        guard intValue(workflow,"version") == version else { throw VelaError("Workflow version changed since the health finding") }
        let run = try object("run",runID)
        guard string(run,"project") == root, string(run,"workflowId") == workflowID, intValue(run,"workflowVersion") == version,
              ["failed","needs_review"].contains(string(run,"state")), run["dryRun"] as? Bool != true,
              ModelImprovement.falseOrAbsent(run["private"]), ModelImprovement.falseOrAbsent(run["sourceLabeledPrivate"]),
              !privateLibraryPath(string(run,"sourcePath")), !privateLibraryPath(string(run,"sourceFile")), !privateLibraryPath(string(run,"assetPath")) else { throw VelaError("Run is not complete public timeout evidence for this workflow") }
        let steps = run["steps"] as? [JSON] ?? []
        guard let observed = steps.first(where:{ string($0,"id") == stepID }), observed["timedOut"] as? Bool == true,
              observed["truncated"] as? Bool != true, ["failed","needs_review"].contains(string(observed,"state")),
              string(observed,"tool").isEmpty == false,
              findingID == timeoutFindingID(runID:runID,stepID:stepID) else { throw VelaError("Timeout finding is unavailable or incomplete") }
        guard let definitionIndex = (workflow["steps"] as? [JSON] ?? []).firstIndex(where:{ string($0,"id") == stepID }) else { throw VelaError("Current workflow no longer contains the timed-out step") }
        let definitionStep = (workflow["steps"] as? [JSON] ?? [])[definitionIndex], tool = string(definitionStep,"tool"), arguments = definitionStep["arguments"] as? JSON ?? [:]
        guard tool == string(observed,"tool"), Self.healthProposalTools.contains(tool), let current = currentTimeout(arguments) else { throw VelaError("Only an explicitly configured 1–300 second process timeout can be proposed") }
        let proposed = try requiredTimeout(params["newTimeoutSeconds"],name:"newTimeoutSeconds")
        guard proposed > current, proposed <= min(300,current * 2) else { throw VelaError("Timeout candidate must be greater than the frozen value, no more than twice it, and at most 300 seconds") }
        let uncertain = string(run,"state") == "needs_review" || observed["outcomeUnknown"] as? Bool == true || string(observed,"state") == "needs_review"
        let identity: JSON = ["project":root,"workflowId":workflowID,"workflowVersion":version,"snapshotHash":snapshotHash,"runId":runID,"runHash":stableHash(try jsonString(run)),"stepId":stepID,"findingId":findingID,"fromTimeoutSeconds":current,"timeoutDefaulted":(arguments["timeoutSeconds"] == nil),"toTimeoutSeconds":proposed,"sourceOutcomeUnknown":uncertain,"stepWithoutTimeoutHash":try stableStepHash(definitionStep)]
        let proposalID = "health-timeout-" + String(stableHash(try jsonString(identity)).prefix(32))
        if let existing = try store.get("workflow_health_proposal",proposalID) { return try safeHealthProposal(existing,project:root) }
        let proposal: JSON = ["id":proposalID,"project":root,"kind":"timeout_adjustment_disabled_candidate","state":"pending_review","workflowId":workflowID,"workflowVersion":version,"snapshotHash":snapshotHash,"runId":runID,"runHash":stableHash(try jsonString(run)),"stepId":stepID,"findingId":findingID,"tool":tool,"fromTimeoutSeconds":current,"timeoutDefaulted":(arguments["timeoutSeconds"] == nil),"toTimeoutSeconds":proposed,"sourceOutcomeUnknown":uncertain,"stepWithoutTimeoutHash":try stableStepHash(definitionStep),"proposalHash":stableHash(try jsonString(identity)),"createdAt":isoNow(),"evidence":["runState":string(run,"state"),"timedOut":true,"dryRun":false,"scanCoverage":"complete","neverAutoExecutes":true]]
        _ = try store.putBatch([("workflow_health_proposal",proposal)],expectingAbsent:[("workflow_health_proposal",proposalID)],createOnly:true)
        return try safeHealthProposal(proposal,project:root)
    }

    private func healthProposalView(_ params: JSON) throws -> JSON {
        guard Set(params.keys) == ["project","id"] else { throw VelaError("Unsupported workflow health proposal parameter") }
        let root = try project(requireString(params,"project")), proposal = try object("workflow_health_proposal",try requireString(params,"id"))
        return try safeHealthProposal(proposal,project:root)
    }

    private func listHealthProposals(_ params: JSON) throws -> JSON {
        let allowed: Set<String> = ["project","limit"]
        guard Set(params.keys).isSubset(of:allowed) else { throw VelaError("Unsupported workflow health proposal list parameter") }
        let root = try project(requireString(params,"project")), limit = try WorkflowContext.integer(params["limit"],default:50,range:1...100,name:"workflow health proposal limit")
        let items = try store.list("workflow_health_proposal",project:root,limit:limit).map { try safeHealthProposal($0,project:root) }
        return ["items":items,"limit":limit,"complete":items.count < limit]
    }

    private func decideHealthProposal(_ params: JSON) throws -> JSON {
        guard Set(params.keys).isSubset(of:["project","id","proposalHash","decision","acknowledgeUncertainSource"]), Set(params.keys).isSuperset(of:["project","id","proposalHash","decision"]) else { throw VelaError("Workflow health proposal decision requires project, id, proposalHash, and decision") }
        let root = try project(requireString(params,"project")), id = try requireString(params,"id"), supplied = try requireString(params,"proposalHash"), decision = try requireString(params,"decision")
        guard ["accept","reject","recover"].contains(decision) else { throw VelaError("Workflow health proposal decision must be accept, reject or recover") }
        var proposal = try object("workflow_health_proposal",id)
        guard string(proposal,"project") == root, string(proposal,"proposalHash") == supplied else { throw VelaError("Workflow health proposal changed or was already decided") }
        let originalHash = stableHash(try jsonString(proposal))
        if decision == "recover" {
            guard string(proposal,"state") == "accepting" else { throw VelaError("Only an interrupted accepting proposal can be recovered") }
            proposal["state"] = "pending_review"; proposal["decision"] = "recovered"; proposal["recoveredAt"] = isoNow(); proposal["error"] = "Acceptance was interrupted before candidate creation; review and explicitly accept again"
            return try safeHealthProposal(try store.putBatch([("workflow_health_proposal",proposal)],expecting:[("workflow_health_proposal",id,originalHash)])[0],project:root)
        }
        guard string(proposal,"state") == "pending_review" else { throw VelaError("Workflow health proposal changed or was already decided") }
        if decision == "reject" {
            proposal["state"] = "rejected"; proposal["decidedAt"] = isoNow(); proposal["decision"] = "reject"
            return try safeHealthProposal(try store.putBatch([("workflow_health_proposal",proposal)],expecting:[("workflow_health_proposal",id,originalHash)])[0],project:root)
        }
        let uncertain = proposal["sourceOutcomeUnknown"] as? Bool == true
        guard let acknowledged = params["acknowledgeUncertainSource"] as? NSNumber, CFGetTypeID(acknowledged) == CFBooleanGetTypeID(), !uncertain || acknowledged.boolValue else { throw VelaError("Accepting an uncertain timeout observation requires acknowledgeUncertainSource=true") }
        // Claim before cloning so another service cannot create a second candidate.
        proposal["state"] = "accepting"; proposal["decision"] = "accept"
        proposal = try store.putBatch([("workflow_health_proposal",proposal)],expecting:[("workflow_health_proposal",id,originalHash)])[0]
        let acceptingHash = stableHash(try jsonString(proposal))
        do {
            try completeHealthEvidence(project:root)
            let workflowID = string(proposal,"workflowId"), inspected = try inspectWorkflow(["project":root,"id":workflowID])
            guard inspected["valid"] as? Bool == true, string(inspected,"state") == "active", string(inspected,"snapshotHash") == string(proposal,"snapshotHash"), intValue((inspected["definition"] as? JSON ?? [:]),"version") == intValue(proposal,"workflowVersion") else { throw VelaError("Workflow changed since timeout proposal review") }
            let run = try object("run",string(proposal,"runId")), stepID = string(proposal,"stepId")
            let inspectedWorkflowRecord = try object("workflow",workflowID)
            let inspectedWorkflowHash = stableHash(try jsonString(inspectedWorkflowRecord))
            let inspectedRunHash = stableHash(try jsonString(run))
            guard inspectedRunHash == string(proposal,"runHash"), string(run,"project") == root, ["failed","needs_review"].contains(string(run,"state")), run["dryRun"] as? Bool != true,
                  let observed = (run["steps"] as? [JSON] ?? []).first(where:{string($0,"id") == stepID}), observed["timedOut"] as? Bool == true, observed["truncated"] as? Bool != true,
                  string(proposal,"findingId") == timeoutFindingID(runID:string(run,"id"),stepID:stepID) else { throw VelaError("Timeout evidence changed or became incomplete") }
            var definition = inspected["definition"] as? JSON ?? [:], steps = definition["steps"] as? [JSON] ?? []
            guard let index = steps.firstIndex(where:{string($0,"id") == stepID}), string(steps[index],"tool") == string(proposal,"tool"), let current = currentTimeout(steps[index]["arguments"] as? JSON ?? [:]), current == intValue(proposal,"fromTimeoutSeconds"), try stableStepHash(steps[index]) == string(proposal,"stepWithoutTimeoutHash"), let proposed = boundedTimeout(proposal["toTimeoutSeconds"]), proposed > current, proposed <= min(300,current * 2) else { throw VelaError("Timeout proposal no longer matches the reviewed step") }
            var arguments = steps[index]["arguments"] as? JSON ?? [:]; arguments["timeoutSeconds"] = proposed; steps[index]["arguments"] = arguments; definition["steps"] = steps
            // New identity + disabled state makes this a reviewable candidate, not a mutation of the active definition.
            definition.removeValue(forKey:"id"); definition.removeValue(forKey:"version"); definition.removeValue(forKey:"assetPath"); definition.removeValue(forKey:"content"); definition.removeValue(forKey:"createdAt"); definition.removeValue(forKey:"updatedAt")
            definition["title"] = String((string(definition,"title") + " timeout candidate").prefix(240)); definition["enabled"] = false
            let candidate = try saveWorkflow(definition,persist:false)
            let candidateID = string(candidate,"id"), candidateVersion = intValue(candidate,"version")
            var snapshot = candidate; snapshot["id"] = candidateID + ".v" + String(candidateVersion)
            // Re-inspect immediately before the store transaction. Asset-backed workflow
            // content has no Store CAS; a changed inspection is refused before candidate write.
            let finalInspected = try inspectWorkflow(["project":root,"id":workflowID])
            guard finalInspected["valid"] as? Bool == true, string(finalInspected,"state") == "active", string(finalInspected,"snapshotHash") == string(proposal,"snapshotHash") else { throw VelaError("Workflow source changed before candidate creation") }
            proposal["state"] = "accepted"; proposal["decidedAt"] = isoNow(); proposal["acceptedWorkflowId"] = candidateID; proposal["acceptedWorkflowVersion"] = candidateVersion; proposal["acceptedWorkflowEnabled"] = false
            proposal = try store.putBatch([("workflow_version",snapshot),("workflow",candidate),("workflow_health_proposal",proposal)],expecting:[("workflow_health_proposal",id,acceptingHash),("run",string(proposal,"runId"),inspectedRunHash),("workflow",workflowID,inspectedWorkflowHash)],expectingAbsent:[("workflow",candidateID),("workflow_version",string(snapshot,"id"))])[2]
            return try safeHealthProposal(proposal,project:root)
        } catch {
            proposal["state"] = "invalidated"; proposal["error"] = "Frozen workflow or timeout evidence changed before candidate creation"; proposal["decidedAt"] = isoNow()
            if let current = try? store.get("workflow_health_proposal",id), stableHash(try jsonString(current)) == acceptingHash {
                _ = try? store.putBatch([("workflow_health_proposal",proposal)],expecting:[("workflow_health_proposal",id,acceptingHash)])
            }
            throw error
        }
    }

    private func completeHealthEvidence(project: String) throws {
        let runs = try store.list("run",project:project,limit:Self.healthProposalScanCap), approvals = try store.list("approval",project:project,limit:Self.healthProposalScanCap)
        guard runs.count < Self.healthProposalScanCap, approvals.count < Self.healthProposalScanCap else { throw VelaError("Workflow health evidence scan is incomplete at its 10,000 record cap") }
    }

    private func boundedPositiveInteger(_ value: Any?) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return false }
        return n.intValue >= 1 && Double(n.intValue) == n.doubleValue
    }

    private func requiredTimeout(_ value: Any?, name: String) throws -> Int {
        guard let timeout = boundedTimeout(value) else { throw VelaError("\(name) must be an integer from 1 to 300") }; return timeout
    }
    private func currentTimeout(_ arguments: JSON) -> Int? {
        arguments["timeoutSeconds"] == nil ? 120 : boundedTimeout(arguments["timeoutSeconds"])
    }
    private func boundedTimeout(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue, (1...300).contains(n.intValue) else { return nil }; return n.intValue
    }
    private func stableStepHash(_ step: JSON) throws -> String {
        var stable: JSON = ["id":string(step,"id"),"title":string(step,"title"),"tool":string(step,"tool"),"arguments":step["arguments"] ?? [:]]
        var arguments = stable["arguments"] as? JSON ?? [:]; arguments.removeValue(forKey:"timeoutSeconds"); stable["arguments"] = arguments
        if let retry = step["retry"] { stable["retry"] = retry }
        return stableHash(try jsonString(stable))
    }

    private func timeoutFindingID(runID: String, stepID: String) -> String { "timeout_observed:" + String(stableHash(runID + ":" + stepID).prefix(32)) }

    private func safeHealthProposal(_ proposal: JSON, project: String) throws -> JSON {
        guard string(proposal,"project") == project else { throw VelaError("Workflow health proposal is unavailable in this project") }
        return proposal.filter { ["id","project","kind","state","workflowId","workflowVersion","snapshotHash","runId","runHash","stepId","findingId","tool","fromTimeoutSeconds","timeoutDefaulted","toTimeoutSeconds","sourceOutcomeUnknown","stepWithoutTimeoutHash","proposalHash","createdAt","decidedAt","decision","acceptedWorkflowId","acceptedWorkflowVersion","acceptedWorkflowEnabled","evidence","error"].contains($0.key) }
    }
}
