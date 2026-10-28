import Foundation

/// What one agent CLI has set up on this Mac: version, global instructions,
/// skills, subagents, commands, hooks and MCP servers.
struct AgentOverview {
    struct Item: Identifiable, Hashable {
        var id: String { path + "#" + name }
        var name: String
        var path: String
        /// One line: a skill's description, an MCP server's command or URL.
        var detail: String = ""
        /// The file to open for editing (a skill folder's SKILL.md).
        var editPath: String { isDirectory ? path + "/SKILL.md" : path }
        var isDirectory: Bool {
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
        }
    }
    var version: String?
    var instructions: Item?
    var instructionsText: String?
    var configFile: Item?
    var skills: [Item] = []
    var subagents: [Item] = []
    var commands: [Item] = []
    var hookEvents: [String] = []
    var mcpServers: [Item] = []
    /// Where new skills, subagents and commands go; nil when the agent has none.
    var skillsDir: String?
    var subagentsDir: String?
    var commandsDir: String?

    static func load(_ a: AgentConfig, path: String?, home: String = NSHomeDirectory()) async -> AgentOverview {
        var o = AgentOverview()
        if let path, let r = try? await ProcessRunner.run(path, ["--version"], timeout: 8), r.ok {
            o.version = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first
        }
        let fm = FileManager.default
        func item(_ p: String) -> Item? { fm.fileExists(atPath: p) ? Item(name: (p as NSString).lastPathComponent, path: p) : nil }
        func list(_ dir: String) -> [Item] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted().map {
                var i = Item(name: ($0 as NSString).deletingPathExtension, path: "\(dir)/\($0)")
                i.detail = description(of: i.editPath)
                return i
            }
        }
        // Server names and their command or URL; env and headers can hold tokens and are never read out.
        func servers(_ json: [String: Any]?, file: String) -> [Item] {
            (json ?? [:]).keys.sorted().map { name in
                let cfg = json?[name] as? [String: Any] ?? [:]
                let cmd = ([cfg["command"] as? String] + ((cfg["args"] as? [String]) ?? []).map(Optional.some)).compactMap { $0 }.joined(separator: " ")
                return Item(name: name, path: file, detail: (cfg["url"] as? String) ?? cmd)
            }
        }
        switch a.binary {
        case "claude":
            o.instructions = item(home + "/.claude/CLAUDE.md")
            o.configFile = item(home + "/.claude/settings.json")
            o.skillsDir = home + "/.claude/skills"
            o.subagentsDir = home + "/.claude/agents"
            o.commandsDir = home + "/.claude/commands"
            o.skills = list(o.skillsDir!)
            o.subagents = list(o.subagentsDir!)
            o.commands = list(o.commandsDir!)
            if let data = fm.contents(atPath: home + "/.claude/settings.json"),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let hooks = obj["hooks"] as? [String: Any] {
                o.hookEvents = hooks.keys.sorted()
            }
            if let data = fm.contents(atPath: home + "/.claude.json"),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                o.mcpServers = servers(obj["mcpServers"] as? [String: Any], file: home + "/.claude.json")
            }
        case "codex":
            o.instructions = item(home + "/.codex/AGENTS.md") ?? item(home + "/.codex/instructions.md")
            o.configFile = item(home + "/.codex/config.toml")
            o.skillsDir = home + "/.codex/skills"
            o.skills = list(o.skillsDir!)
            if let toml = try? String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8) {
                o.mcpServers = mcpNames(toml: toml).map { Item(name: $0, path: home + "/.codex/config.toml") }
            }
        case "gemini":
            o.instructions = item(home + "/.gemini/GEMINI.md")
            o.configFile = item(home + "/.gemini/settings.json")
            if let data = fm.contents(atPath: home + "/.gemini/settings.json"),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                o.mcpServers = servers(obj["mcpServers"] as? [String: Any], file: home + "/.gemini/settings.json")
            }
        case "opencode":
            o.instructions = item(home + "/.config/opencode/AGENTS.md")
            o.configFile = item(home + "/.config/opencode/opencode.json")
        default:
            break
        }
        if let p = o.instructions?.path, let text = try? String(contentsOfFile: p, encoding: .utf8) {
            o.instructionsText = String(text.prefix(20_000))
        }
        return o
    }

    /// The `description:` line of a Markdown file's front matter.
    static func description(of path: String) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return "" }
        for l in lines.dropFirst() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t == "---" { break }
            if t.hasPrefix("description:") {
                return t.dropFirst("description:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
        }
        return ""
    }

    /// Starter file for a new skill, subagent or command.
    static func template(kind: String, name: String) -> String {
        switch kind {
        case "skill": "---\nname: \(name)\ndescription: When to use this skill, in one sentence.\n---\n\n# \(name)\n\nInstructions for the agent.\n"
        case "subagent": "---\nname: \(name)\ndescription: When the main agent should hand work to this subagent.\ntools: Read, Grep, Glob\n---\n\nYou are \(name). Describe its job here.\n"
        default: "---\ndescription: What /\(name) does.\n---\n\nPrompt for /\(name). Use $ARGUMENTS for what the user types after it.\n"
        }
    }

    /// `[mcp_servers.name]` table names from a Codex config.toml.
    static func mcpNames(toml: String) -> [String] {
        var out: [String] = []
        for line in toml.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("[mcp_servers."), t.hasSuffix("]") else { continue }
            let name = t.dropFirst("[mcp_servers.".count).dropLast().split(separator: ".").first.map(String.init) ?? ""
            let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !clean.isEmpty, !out.contains(clean) { out.append(clean) }
        }
        return out
    }
}
