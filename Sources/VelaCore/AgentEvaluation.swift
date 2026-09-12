import Foundation
import CoreFoundation

/// A protocol adapter, not an agent: Codex owns reasoning, tools and its sandbox.
enum AgentEvaluation {
    static func specification(_ input: JSON) throws -> JSON {
        guard string(input,"provider") == "codex" else { throw VelaError("Agent Lab currently supports the Codex JSONL protocol only") }
        let model = try requireString(input,"model")
        guard model.range(of:"^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$",options:.regularExpression) != nil else { throw VelaError("An explicit model identifier is required") }
        let effort = string(input,"reasoningEffort","high")
        guard ["low","medium","high","xhigh"].contains(effort) else { throw VelaError("Unsupported reasoning effort") }
        let executable = try AutomationProcess.executable(string(input,"executable","codex"))
        return ["provider":"codex","executable":executable,"model":model,"reasoningEffort":effort,"sandbox":"workspace-write","protocol":"codex-exec-jsonl-v1"]
    }

    static func command(_ spec: JSON, task: String, context: String) throws -> [String] {
        func literal(_ value: String) throws -> String {
            String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.withoutEscapingSlashes]),as:UTF8.self)
        }
        var command = [try requireString(spec,"executable"),"exec","--ignore-user-config","--json","--ephemeral","--model",try requireString(spec,"model"),"--sandbox","workspace-write","-c","approval_policy=\"never\"","-c","model_reasoning_effort=" + (try literal(string(spec,"reasoningEffort"))),"--color","never"]
        // No hook-trust bypass. Existing project hooks must pass Codex's own trust check.
        if !context.isEmpty { command += ["-c","developer_instructions=" + (try literal(context))] }
        command += [task]
        return command
    }

    /// Only complete provider events establish available counts. Stderr and unknown events
    /// remain raw evidence; they are not silently translated into successes or zero usage.
    static func metrics(_ output: String, truncated: Bool, verificationCommand: [String]) -> JSON {
        var session: String?; var completed = false; var usage: JSON?
        var commands: [JSON] = []; var tools = Set<String>(); var messages: [JSON] = []
        var seen = Set<String>(); var protocolErrors: [String] = []
        for line in output.split(separator:"\n") where line.utf8.count <= 1_048_576 {
            guard let row = try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? JSON else { continue }
            switch string(row,"type") {
            case "thread.started": session = row["thread_id"] as? String
            case "turn.completed": completed = true; usage = row["usage"] as? JSON
            case "turn.failed","error": protocolErrors.append(String(string(row,"message",(row["error"] as? JSON).map { string($0,"message") } ?? "Agent protocol error").prefix(2000)))
            case "item.completed":
                guard let item = row["item"] as? JSON, !string(item,"id").isEmpty, seen.insert(string(item,"id")).inserted else { continue }
                let type = string(item,"type")
                if ["command_execution","mcp_tool_call","web_search","file_change"].contains(type) { tools.insert(string(item,"id")) }
                if type == "command_execution" { commands.append(item) }
                if type == "agent_message" { messages.append(["id":string(item,"id"),"text":string(item,"text")]) }
            default: break
            }
        }
        let complete = session != nil && completed && !truncated && protocolErrors.isEmpty
        let tests = commands.compactMap { command -> JSON? in
            guard string(command,"status") == "completed", let exit = usageTokenCount(command["exit_code"]),
                  let match = verificationMatch(string(command,"command"),expected:verificationCommand) else { return nil }
            // A composite script may fail parsing before its first command runs.
            // Only a successful script establishes its unconditional first invocation.
            guard match == "complete_simple_command" || exit == 0 else { return nil }
            var result = command; result["matchKind"] = match
            result["testExitCode"] = match == "complete_simple_command" ? command["exit_code"] ?? NSNull() : NSNull()
            return result
        }
        let allSimple = commands.allSatisfy { simpleProgram(string($0,"command")) != nil && string($0,"status") == "completed" && usageTokenCount($0["exit_code"]) != nil }
        var observed: Any = NSNull()
        if complete {
            if !tests.isEmpty { observed = true }
            else if allSimple { observed = false }
        }
        func count(_ key: String) -> Int? {
            guard complete else { return nil }
            return usageTokenCount(usage?[key])
        }
        let input = count("input_tokens"), output = count("output_tokens")
        let total: Any = input.flatMap { i in output.flatMap { usageTokenSum([i,$0]) } } as Any? ?? NSNull()
        return ["sourceSessionId":session as Any? ?? NSNull(),"protocolComplete":complete,"providerUsage":usage as Any? ?? NSNull(),"tokenInput":input as Any? ?? NSNull(),"tokenOutput":output as Any? ?? NSNull(),"tokens":total,"toolCalls":complete ? tools.count : NSNull(),"testInvocations":complete ? tests.count : NSNull(),"testExecutionObserved":observed,"testCountIsLowerBound":!allSimple,"successfulTestInvocations":complete ? tests.filter { ($0["testExitCode"] as? NSNumber)?.intValue == 0 && string($0,"status") == "completed" }.count : NSNull(),"testCommands":tests,"commands":commands,"agentMessages":messages,"corrections":NSNull(),"correctionMeasurement":"unavailable: single-turn evaluation does not observe user corrections","testMeasurement":"Exact simple argv or unconditional leading invocation; composite test exit status and unclassified absence remain unavailable.","metricVersion":"codex-test-observation-v3","protocolErrors":protocolErrors]
    }

    static func matchesVerification(_ command: String, expected: [String]) -> Bool {
        guard let words = simpleProgram(command) else { return false }
        return matchesWords(words,expected:expected)
    }

    private static func program(_ command: String) -> String? {
        guard let words = shellWords(command) else { return nil }
        if words.count == 3, ["sh","bash","zsh"].contains(URL(fileURLWithPath:words[0]).lastPathComponent), ["-c","-lc"].contains(words[1]) { return words[2] }
        return command
    }
    private static func simpleProgram(_ command: String) -> [String]? {
        guard let program = program(command) else { return nil }
        return shellWords(program)
    }
    static func verificationMatch(_ command: String, expected: [String]) -> String? {
        if matchesVerification(command,expected:expected) { return "complete_simple_command" }
        guard let program = program(command) else { return nil }
        // Only an unconditional first command is evidence of an attempted test. Do not
        // scan later text, heredocs, quoted examples, branches or short-circuited commands.
        let firstLine = String(program.split(separator:"\n",omittingEmptySubsequences:false).first ?? "")
        let prefix = firstLine.components(separatedBy:" && ")[0]
        guard var words = shellWords(prefix), !words.isEmpty else { return nil }
        if words[0] == "PYTHONDONTWRITEBYTECODE=1" { words.removeFirst() }
        guard matchesWords(words,expected:expected) else { return nil }
        return "unconditional_leading_invocation"
    }
    private static func matchesWords(_ words: [String], expected: [String]) -> Bool {
        guard !expected.isEmpty else { return false }
        guard words.count == expected.count, !words.isEmpty else { return false }
        if words[0].hasPrefix("/"), expected[0].hasPrefix("/"), canonicalProject(words[0]) != canonicalProject(expected[0]) { return false }
        return URL(fileURLWithPath:words[0]).lastPathComponent == URL(fileURLWithPath:expected[0]).lastPathComponent && Array(words.dropFirst()) == Array(expected.dropFirst())
    }

    /// Deliberately accepts only a simple argv. Never interprets substitutions or pipelines.
    static func shellWords(_ text: String) -> [String]? {
        var words: [String] = [], current = "", quote: Character?, escaped = false, started = false
        for char in text {
            if escaped { current.append(char); escaped = false; started = true; continue }
            if char == "\\", quote != "'" { escaped = true; started = true; continue }
            if let q = quote {
                if q == "\"", char == "$" || char == "`" { return nil }
                if char == q { quote = nil } else { current.append(char) }; started = true; continue
            }
            if char == "'" || char == "\"" { quote = char; started = true; continue }
            if ";|&<>$`\n".contains(char) { return nil }
            if char.isWhitespace { if started { words.append(current); current = ""; started = false }; continue }
            current.append(char); started = true
        }
        guard quote == nil, !escaped else { return nil }
        if started { words.append(current) }
        return words
    }
}

extension AutomationService {
    func agentEvaluationSummary(_ results: [JSON], expectedRepetitions: Int) -> JSON {
        func aggregate(_ variant: String) -> JSON {
            let rows = results.filter { string($0,"variant") == variant }
            let valid = rows.filter { ($0["agentMetrics"] as? JSON)?["protocolComplete"] as? Bool == true && $0["verificationIntact"] as? Bool == true }
            let successes = valid.filter { ($0["verification"] as? JSON)?["exitCode"] as? Int == 0 && intValue($0,"exitCode") == 0 && $0["timedOut"] as? Bool != true }.count
            let observedTests = valid.compactMap { ($0["agentMetrics"] as? JSON)?["testExecutionObserved"] as? Bool }
            let tests = observedTests.filter { $0 }.count
            let tokens = valid.compactMap { ($0["agentMetrics"] as? JSON)?["tokens"] as? Int }
            return ["runs":rows.count,"validRuns":valid.count,"successes":successes,"testExecutingRuns":observedTests.count == rows.count ? tests : NSNull(),"testObservedRuns":tests,"testObservationCoverage":observedTests.count,"passRate":rows.isEmpty ? NSNull() : Double(successes)/Double(rows.count),"testExecutionRate":rows.isEmpty || observedTests.count != rows.count ? NSNull() : Double(tests)/Double(rows.count),"averageTokens":tokens.count != rows.count || rows.isEmpty ? NSNull() : tokens.reduce(0.0) {$0+Double($1)}/Double(tokens.count),"averageDurationMs":rows.isEmpty ? NSNull() : rows.reduce(0.0) {$0+Double(intValue($1,"durationMs"))}/Double(rows.count)]
        }
        let b = aggregate("baseline"), c = aggregate("candidate")
        var decision = "inconclusive", reasons: [String] = []
        let complete = intValue(b,"validRuns") == expectedRepetitions && intValue(c,"validRuns") == expectedRepetitions && intValue(b,"runs") == expectedRepetitions && intValue(c,"runs") == expectedRepetitions
        if !complete { reasons.append("Every planned run must have complete protocol and unchanged verification evidence.") }
        if expectedRepetitions < 3 { reasons.append("At least 3 repetitions per variant are required for promotion review.") }
        let testsComparable = b["testExecutingRuns"] is Int && c["testExecutingRuns"] is Int
        if !testsComparable { reasons.append("Unclassified test execution is unavailable, not zero.") }
        if complete && (intValue(c,"successes") < intValue(b,"successes") || (testsComparable && intValue(c,"testExecutingRuns") < intValue(b,"testExecutingRuns"))) {
            decision = "reject"; reasons.append("Candidate regressed in task success or observed test execution.")
        } else if let bt = b["averageTokens"] as? Double, let ct = c["averageTokens"] as? Double {
            let budgetOK = ct <= max(bt * 1.2,bt + 100)
            if !budgetOK { decision = "reject"; reasons.append("Candidate token usage exceeds the frozen 20% / 100-token tolerance.") }
            else if complete && expectedRepetitions >= 3 && testsComparable && intValue(c,"successes") == expectedRepetitions && (intValue(c,"successes") > intValue(b,"successes") || intValue(c,"testExecutingRuns") > intValue(b,"testExecutingRuns")) { decision = "ready_for_review" }
            else { reasons.append("No sufficient measured improvement; do not infer a benefit from a tie.") }
        } else { reasons.append("Provider token usage is unavailable.") }
        return ["baseline":b,"candidate":c,"decision":decision,"reasons":reasons,"corrections":NSNull(),"futureEffect":"not_measured","interpretation":"Local task/test-execution comparison, not a claim of longitudinal correction reduction. Promotion always needs human review."]
    }

    func currentEvaluation(_ source: JSON) -> JSON {
        var evaluation = source
        if evaluation["originalGitStatusUnchanged"] == nil, let previous = source["originalWorktreeUnchanged"] as? Bool { evaluation["originalGitStatusUnchanged"] = previous }
        if source["originalWorktreeUnchanged"] != nil { evaluation["originalWorktreeUnchanged"] = NSNull() }
        guard string(source,"evaluator") == "codex_agent", string(source,"state") == "completed" else { return evaluation }
        let command = source["command"] as? [String] ?? []
        let results = (source["results"] as? [JSON] ?? []).map { row -> JSON in
            var result = row
            let metrics = AgentEvaluation.metrics(string(row,"output"),truncated:row["truncated"] as? Bool ?? true,verificationCommand:command)
            result["agentMetrics"] = metrics
            result["tokens"] = metrics["tokens"] ?? NSNull()
            result["tokensAvailable"] = metrics["tokens"] is Int
            return result
        }
        evaluation["results"] = results
        evaluation["tokensAvailable"] = !results.isEmpty && results.allSatisfy { $0["tokensAvailable"] as? Bool == true }
        evaluation["summary"] = agentEvaluationSummary(results,expectedRepetitions:intValue(source,"repetitions"))
        evaluation["analysisVersion"] = "codex-test-observation-v3"
        if string(source,"analysisVersion") != "codex-test-observation-v3" {
            evaluation["previousAnalysisSummary"] = source["summary"]
            evaluation["analysisRevisionReason"] = "Recomputed from retained raw provider events: only successful composite scripts establish a leading test observation; unclassified absence and unsafe token counts remain unavailable. Raw results are unchanged."
        }
        return evaluation
    }
}
