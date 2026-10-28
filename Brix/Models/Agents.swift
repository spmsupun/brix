import Foundation

/// A coding agent CLI Brix can start in a project terminal.
struct AgentConfig: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    /// Launch command, run through a login shell in the project folder.
    var command: String
    /// Shell command that installs the CLI. Shown before it runs.
    var installCommand: String = ""
    var enabled = true
    var showUsage = false
    /// Image file for the agent's logo (PNG, PDF, SVG or ICNS); empty uses the built-in mark.
    var iconPath: String = ""

    var isBuiltin: Bool { Self.builtins.contains { $0.id == id } }
    /// The executable to look for on PATH.
    var binary: String { command.split(separator: " ").first.map(String.init) ?? command }
    /// Only Claude Code accepts the linked-resources note as a system prompt.
    var acceptsSystemPrompt: Bool { binary == "claude" }

    static let builtins: [AgentConfig] = [
        AgentConfig(id: "claude", name: "Claude Code", command: "claude",
                    installCommand: "curl -fsSL https://claude.ai/install.sh | bash", enabled: true, showUsage: true),
        AgentConfig(id: "codex", name: "Codex", command: "codex",
                    installCommand: "npm install -g @openai/codex", enabled: true, showUsage: true),
        AgentConfig(id: "gemini", name: "Gemini CLI", command: "gemini",
                    installCommand: "npm install -g @google/gemini-cli", enabled: false),
        AgentConfig(id: "opencode", name: "OpenCode", command: "opencode",
                    installCommand: "npm install -g opencode-ai", enabled: false)
    ]

    /// Keeps the user's list and order, adding builtins introduced later.
    static func mergingBuiltins(_ saved: [AgentConfig]) -> [AgentConfig] {
        saved + builtins.filter { b in !saved.contains { $0.id == b.id } }
    }

    /// The command for a new session. Agents get resource names only, never secrets.
    /// `sessionID` names a new Claude Code conversation, or with `resume` continues one.
    func launchCommand(resourceNames: [String], sessionID: String? = nil, resume: Bool = false, databases: Bool = false) -> String {
        let base = command.trimmingCharacters(in: .whitespaces).isEmpty ? binary : command
        if resume, let id = sessionID, Self.isSafeID(id) {
            switch binary {
            case "claude": return base + " --resume " + id
            case "codex": return base + " resume " + id
            default: break
            }
        }
        var out = base
        if binary == "claude", let id = sessionID, Self.isSafeID(id) { out += " --session-id " + id }
        guard acceptsSystemPrompt, !resourceNames.isEmpty else { return out }
        var note = "This project is managed in Brix. Linked resources (names only, no credentials): " + resourceNames.joined(separator: ", ") + "."
        if databases {
            note += " To use its databases run `brix-db list`, `brix-db schema <name>` and `brix-db query <name> \"<sql>\"`; Brix applies each database's access rules and never gives you its password."
        }
        return out + " --append-system-prompt " + ProcessRunner.shellQuote(note)
    }

    /// Session ids go into a shell command line, so only UUID-like ids are used.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}

/// One rate-limit window, e.g. "5h 12%".
struct UsageWindow: Hashable {
    var label: String
    var percent: Double
    var resetsAt: Date?
}

/// Reads plan usage the agent CLIs already write to disk. Nothing is sent anywhere.
enum AgentUsageReader {
    static func read(_ agent: AgentConfig, home: String = NSHomeDirectory()) -> [UsageWindow] {
        switch agent.binary {
        case "claude": claude(home: home)
        case "codex": codex(home: home)
        default: []
        }
    }

    /// Claude Code passes rate limits to its status line; a status line script can
    /// cache them in ~/.claude/state/rate-limits.json, which is what this reads.
    static func claude(home: String) -> [UsageWindow] {
        let url = URL(fileURLWithPath: home + "/.claude/state/rate-limits.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return [("five_hour", "5h"), ("seven_day", "7d")].compactMap { key, label in
            guard let w = obj[key] as? [String: Any], let pct = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return window(label, pct, w["resets_at"])
        }
    }

    /// Codex logs `rate_limits` in its session files; the newest one wins.
    static func codex(home: String) -> [UsageWindow] {
        let root = URL(fileURLWithPath: home + "/.codex/sessions")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let cutoff = Date().addingTimeInterval(-8 * 86_400)
        var files: [(URL, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if d > cutoff { files.append((url, d)) }
        }
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(10) {
            if let w = codexLimits(in: url), !w.isEmpty { return w }
        }
        return []
    }

    static func codexLimits(in url: URL) -> [UsageWindow]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        guard let data = try? h.readToEnd() else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").reversed()
        for line in lines where line.contains("\"rate_limits\":{") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let limits = (obj["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { continue }
            return parseCodex(limits)
        }
        return nil
    }

    static func parseCodex(_ limits: [String: Any]) -> [UsageWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let w = limits[key] as? [String: Any], let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
            let label = minutes >= 1440 ? "\(minutes / 1440)d" : "\(max(minutes / 60, 1))h"
            return window(label, pct, w["resets_at"])
        }
    }

    private static func window(_ label: String, _ pct: Double, _ resets: Any?) -> UsageWindow {
        let date = (resets as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        // A window that has already reset starts again from zero.
        let used = date.map { $0 < Date() } == true ? 0 : pct
        return UsageWindow(label: label, percent: used, resetsAt: date)
    }
}
