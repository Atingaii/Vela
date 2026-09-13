import Foundation

/// Versioned public discovery conventions. A discovered file does not prove
/// the provider loaded it: trust, CLI overlays and runtime settings also apply.
enum SetupCatalog {
    static let version = "public-config-locations-2026-09-13-v1"
    struct Location {
        let path: String, provider: String, type: String, source: String
        var tree = false
        var metadataOnly = false
        var format: String { URL(fileURLWithPath:path).pathExtension.lowercased() }
    }
    static let claude = "https://code.claude.com/docs/en/settings"
    static let claudeMemory = "https://code.claude.com/docs/en/memory"
    static let claudeSkills = "https://code.claude.com/docs/en/skills"
    static let codex = "https://learn.chatgpt.com/docs/agent-configuration/agents-md"
    static let codexSkills = "https://learn.chatgpt.com/docs/build-skills"
    static let cursor = "https://cursor.com/docs/rules"
    static let pi = "https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md"
    static let omp = "https://github.com/can1357/oh-my-pi/blob/main/docs/settings.md"
    static let ompContext = "https://github.com/can1357/oh-my-pi/blob/main/docs/context-files.md"
    static let ompMCP = "https://github.com/can1357/oh-my-pi/blob/main/docs/mcp-config.md"

    static var project: [Location] {
        var result: [Location] = [
            .init(path:"AGENTS.md",provider:"shared",type:"instruction",source:codex),
            .init(path:"AGENTS.override.md",provider:"shared",type:"instruction",source:codex),
            .init(path:"CLAUDE.md",provider:"claude",type:"instruction",source:claudeMemory),
            .init(path:"CLAUDE.local.md",provider:"claude",type:"instruction",source:claudeMemory),
            .init(path:".claude/CLAUDE.md",provider:"claude",type:"instruction",source:claudeMemory),
            .init(path:".claude/settings.json",provider:"claude",type:"configuration",source:claude),
            .init(path:".claude/settings.local.json",provider:"claude",type:"configuration",source:claude),
            .init(path:".mcp.json",provider:"claude",type:"mcp",source:"https://code.claude.com/docs/en/mcp"),
            .init(path:".codex/config.toml",provider:"codex",type:"configuration",source:"https://developers.openai.com/codex/config-basic"),
            .init(path:".codex/hooks.json",provider:"codex",type:"hook",source:"https://developers.openai.com/codex/hooks"),
            .init(path:".cursorrules",provider:"cursor",type:"rule",source:cursor),
            .init(path:".cursor/mcp.json",provider:"cursor",type:"mcp",source:"https://cursor.com/docs/mcp"),
            .init(path:".cursor/hooks.json",provider:"cursor",type:"hook",source:"https://cursor.com/docs/hooks"),
            .init(path:".pi/settings.json",provider:"pi",type:"configuration",source:pi),
            .init(path:".omp/config.yml",provider:"omp",type:"configuration",source:omp),
            .init(path:".omp/settings.json",provider:"omp",type:"configuration",source:omp),
            .init(path:".omp/AGENTS.md",provider:"omp",type:"instruction",source:ompContext),
            .init(path:".omp/RULES.md",provider:"omp",type:"rule",source:ompContext),
            .init(path:".omp/mcp.json",provider:"omp",type:"mcp",source:ompMCP),
            .init(path:".omp/.mcp.json",provider:"omp",type:"mcp",source:ompMCP)
        ]
        for file in ["SYSTEM.md","APPEND_SYSTEM.md"] { result.append(.init(path:".pi/"+file,provider:"pi",type:"instruction",source:pi)) }
        for (path,provider,type,source) in [
            (".claude/rules","claude","rule",claudeMemory), (".claude/skills","claude","skill",claudeSkills),
            (".claude/commands","claude","command",claudeSkills), (".claude/agents","claude","agent","https://code.claude.com/docs/en/sub-agents"),
            (".agents/skills","shared","skill",codexSkills), (".cursor/rules","cursor","rule",cursor),
            (".cursor/skills","cursor","skill","https://cursor.com/docs/skills"), (".cursor/commands","cursor","command","https://cursor.com/docs/agent/chat/commands"),
            (".pi/skills","pi","skill",pi), (".pi/prompts","pi","prompt",pi),
            (".omp/skills","omp","skill","https://github.com/can1357/oh-my-pi/blob/main/docs/skills.md"),
            (".omp/rules","omp","rule","https://github.com/can1357/oh-my-pi/blob/main/docs/skills.md")
        ] { result.append(.init(path:path,provider:provider,type:type,source:source,tree:true)) }
        return result
    }

    static var global: [Location] {
        var result = project.filter { $0.path.hasPrefix(".claude/") || $0.path.hasPrefix(".cursor/") || $0.path.hasPrefix(".agents/") || $0.path == ".codex/config.toml" || $0.path == ".codex/hooks.json" }
            .filter { ![".claude/settings.local.json",".cursor/rules"].contains($0.path) }
        result += [
            .init(path:".claude.json",provider:"claude",type:"configuration",source:claude,metadataOnly:true),
            .init(path:".codex/AGENTS.md",provider:"codex",type:"instruction",source:codex),
            .init(path:".codex/AGENTS.override.md",provider:"codex",type:"instruction",source:codex)
        ]
        for provider in ["pi","omp"] {
            let source = provider == "pi" ? pi : ompContext
            for file in provider == "pi" ? ["AGENTS.md","SYSTEM.md","APPEND_SYSTEM.md"] : ["AGENTS.md","RULES.md"] {
                result.append(.init(path:".\(provider)/agent/"+file,provider:provider,type:file == "RULES.md" ? "rule" : "instruction",source:source))
            }
            for directory in provider == "pi" ? ["skills","prompts"] : ["skills","rules","managed-skills"] {
                result.append(.init(path:".\(provider)/agent/"+directory,provider:provider,type:directory.contains("skills") ? "skill" : directory == "rules" ? "rule" : "prompt",source:source,tree:true))
            }
        }
        result.append(.init(path:".pi/agent/settings.json",provider:"pi",type:"configuration",source:pi))
        for file in ["config.yml","config.yaml","settings.json"] { result.append(.init(path:".omp/agent/"+file,provider:"omp",type:"configuration",source:omp)) }
        for file in ["mcp.json",".mcp.json"] { result.append(.init(path:".omp/agent/"+file,provider:"omp",type:"mcp",source:ompMCP)) }
        return result
    }

    static let excludedDirectories: Set<String> = [".git",".hg",".svn","node_modules",".build",".next",".venv","venv","vendor","Pods","DerivedData","target","dist","build",".vela","private","Library"]
    static func match(_ relative: String, global: Bool) -> Location? {
        let list = global ? self.global : project
        for location in list {
            if relative == location.path { return location.tree ? nil : location }
            if !global && relative.hasSuffix("/" + location.path) { return location.tree ? nil : location }
            if location.tree {
                let needle = location.path + "/"
                guard relative.hasPrefix(needle) || (!global && relative.contains("/" + needle)) else { continue }
                let filename = URL(fileURLWithPath:relative).lastPathComponent
                if location.type == "skill" ? filename == "SKILL.md" : ["md","mdc"].contains(URL(fileURLWithPath:relative).pathExtension.lowercased()) { return location }
            }
        }
        return nil
    }
    static var description: JSON {
        ["catalogVersion":version,"providers":["claude","codex","cursor","pi","omp"],"projectLocations":project.map { dto($0) },"globalLocations":global.map { dto($0) },
         "runtimeLoadedState":"unavailable","readOnly":true,"limitations":["Catalog inventories documented files; provider trust, active profiles, custom paths, managed/remote policy, CLI/environment overlays and actual loaded configuration require separate provider evidence.","Credential stores, private libraries and linked files are never read. Mixed authentication/config files are metadata-only.","Custom imports and plugin packages are not followed or executed."]]
    }
    private static func dto(_ item: Location) -> JSON { ["path":item.path,"provider":item.provider,"type":item.type,"recursive":item.tree,"metadataOnly":item.metadataOnly,"sourceURL":item.source] }
}
