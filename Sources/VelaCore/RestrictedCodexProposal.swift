import Foundation

/// Shared transport for proposals. Domain modules retain their own schemas,
/// evidence checks, approvals and acceptance rules; this is not another agent.
enum RestrictedCodexProposal {
    static let schemaPlaceholder = "<vela-private-scratch>/output-schema.json"
    static let disabledCodeModeDiagnostic = "Code Mode is unavailable because code-mode host is disabled. Code mode will fail closed; enable `features.code_mode_host` and install `codex-code-mode-host`."

    static func command(agent: JSON, prompt: String, schemaPath: String) throws -> [String] {
        guard !prompt.contains("\0"), prompt.utf8.count <= 64_000 else { throw VelaError("Proposal prompt exceeds its bounded argument limit") }
        var command = [try requireString(agent,"executable"),"exec","--ignore-user-config","--ignore-rules","--json","--ephemeral","--skip-git-repo-check","--model",try requireString(agent,"model"),"--sandbox","read-only","--output-schema",schemaPath,"--color","never","-c","approval_policy=\"never\"","-c","web_search=\"disabled\"","-c","mcp_servers={}","-c","model_reasoning_effort=" + (try WorkflowContext.jsonText(string(agent,"reasoningEffort")))]
        // Keep flags stable: pending approvals freeze this complete command.
        // Older CLIs fail explicitly; restrictions are never silently removed.
        for feature in ["hooks","plugins","apps","shell_tool","unified_exec","browser_use","browser_use_external","computer_use","multi_agent","code_mode","code_mode_host","image_generation","memories"] {
            command += ["--disable",feature]
        }
        return command + ["--",prompt]
    }

    static func decode(output: String, truncated: Bool, maxAnswerBytes: Int = 32_000) throws -> (JSON, JSON) {
        guard (1...64_000).contains(maxAnswerBytes) else { throw VelaError("Invalid proposal answer limit") }
        var warnings: [JSON] = []
        for line in output.split(separator:"\n") {
            guard let event = try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? JSON else { continue }
            if string(event,"type").hasPrefix("item."), let item = event["item"] as? JSON,
               !["agent_message","reasoning"].contains(string(item,"type")) {
                // Codex 0.154.0 reports this exact fail-closed diagnostic as an
                // error item when the intentionally disabled code host starts.
                // It does not weaken restrictions or make failed turns succeed.
                if string(event,"type") == "item.completed", string(item,"type") == "error",
                   Set(item.keys) == Set(["id","type","message"]), !string(item,"id").isEmpty,
                   string(item,"message") == disabledCodeModeDiagnostic {
                    warnings.append(["code":"code_mode_host_disabled","message":disabledCodeModeDiagnostic]); continue
                }
                throw VelaError("Proposal emitted an unexpected tool or item type")
            }
        }
        var metrics = AgentEvaluation.metrics(output,truncated:truncated,verificationCommand:[])
        guard metrics["protocolComplete"] as? Bool == true, intValue(metrics,"toolCalls") == 0,
              let messages = metrics["agentMessages"] as? [JSON], messages.count == 1,
              let data = string(messages[0],"text").data(using:.utf8), data.count <= maxAnswerBytes,
              let result = try JSONSerialization.jsonObject(with:data) as? JSON else { throw VelaError("Proposal requires one complete JSON answer and no tool calls") }
        metrics["warnings"] = warnings
        return (result,metrics)
    }

    static func run(frozenCommand: [String], schema: JSON, timeoutSeconds: Int, scratchPrefix: String) throws -> AutomationProcessResult {
        guard (1...300).contains(timeoutSeconds), scratchPrefix.range(of:"^vela-[a-z-]{1,64}-$",options:.regularExpression) != nil,
              frozenCommand.filter({ $0 == schemaPlaceholder }).count == 1 else { throw VelaError("Invalid proposal execution boundary") }
        let schemaData = Data(try jsonString(schema).utf8)
        guard schemaData.count <= 64_000 else { throw VelaError("Proposal schema exceeds its limit") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(scratchPrefix + UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:temporary) }
        let schemaURL = temporary.appendingPathComponent("output-schema.json")
        try schemaData.write(to:schemaURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:schemaURL.path)
        let command = frozenCommand.map { $0 == schemaPlaceholder ? schemaURL.path : $0 }
        return try AutomationProcess.run(command,cwd:temporary.path,timeout:Double(timeoutSeconds),maxOutput:262_144)
    }
}
