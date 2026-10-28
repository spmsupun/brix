import Foundation

/// What's inside a project folder: top-level layout, nested projects and git
/// repositories, and instruction files for AI agents.
struct ProjectScan {
    struct Entry: Identifiable, Hashable {
        var id: String { path }
        var path: String
        var isDirectory: Bool
    }
    struct SubProject: Identifiable, Hashable {
        var id: String { path }
        /// Relative to the project root.
        var path: String
        var kinds: [String]
        var isGitRepo: Bool
    }
    struct AIFile: Identifiable, Hashable {
        var id: String { path }
        var path: String
        var label: String
        /// Skills, agents or commands folders: how many entries they hold.
        var count: Int?
    }

    var top: [Entry] = []
    var subProjects: [SubProject] = []
    var aiFiles: [AIFile] = []
    var isGitRepo = false

    static let skip: Set<String> = ["node_modules", ".git", "vendor", "build", "dist", ".build", ".venv", "venv", "Pods", "DerivedData",
                                    "target", ".next", ".nuxt", "__pycache__", ".idea", ".vscode", "coverage", ".gradle", ".turbo"]
    static let markers: [String: String] = ["package.json": "Node", "go.mod": "Go", "Cargo.toml": "Rust", "pyproject.toml": "Python",
                                            "requirements.txt": "Python", "composer.json": "PHP", "Gemfile": "Ruby", "pom.xml": "Java",
                                            "build.gradle": "Gradle", "build.gradle.kts": "Gradle", "Package.swift": "Swift", "project.yml": "XcodeGen",
                                            "pubspec.yaml": "Flutter", "mix.exs": "Elixir", "compose.yaml": "Compose", "docker-compose.yml": "Compose",
                                            "compose.yml": "Compose", "docker-compose.yaml": "Compose", "Dockerfile": "Docker"]
    /// Instruction files agents read, relative to the root.
    static let aiPaths: [(String, String)] = [
        ("CLAUDE.md", "Claude Code"), ("CLAUDE.local.md", "Claude Code (local)"), (".claude/CLAUDE.md", "Claude Code"),
        ("AGENTS.md", "Codex and others"), ("GEMINI.md", "Gemini CLI"), (".cursorrules", "Cursor"), (".windsurfrules", "Windsurf"),
        (".github/copilot-instructions.md", "GitHub Copilot"), (".mcp.json", "MCP servers"), (".claude/settings.json", "Claude settings"),
        (".claude/settings.local.json", "Claude settings (local)")
    ]
    static let aiFolders: [(String, String)] = [(".claude/skills", "Claude skills"), (".claude/agents", "Claude subagents"),
                                                (".claude/commands", "Claude commands"), (".cursor/rules", "Cursor rules"),
                                                (".codex/skills", "Codex skills"), (".agents/skills", "Agent skills")]

    /// ponytail: walks 3 levels deep with a 4,000-entry cap; deep monorepos may show partial results.
    static func scan(_ root: URL) -> ProjectScan {
        let fm = FileManager.default
        var out = ProjectScan()
        out.isGitRepo = fm.fileExists(atPath: root.appendingPathComponent(".git").path)
        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        out.top = names.filter { $0 != ".DS_Store" }.map { n in
            var dir: ObjCBool = false
            fm.fileExists(atPath: root.appendingPathComponent(n).path, isDirectory: &dir)
            return Entry(path: n, isDirectory: dir.boolValue)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.path.lowercased()) < ($1.isDirectory ? 0 : 1, $1.path.lowercased()) }

        var visited = 0
        func walk(_ dir: URL, rel: String, depth: Int) {
            guard depth <= 3, visited < 4000 else { return }
            let children = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            visited += children.count
            if !rel.isEmpty {
                let kinds = Array(Set(children.compactMap { markers[$0] })).sorted()
                let git = children.contains(".git")
                if !kinds.isEmpty || git { out.subProjects.append(SubProject(path: rel, kinds: kinds, isGitRepo: git)) }
            }
            for c in children where !skip.contains(c) && !c.hasPrefix(".") {
                var isDir: ObjCBool = false
                let u = dir.appendingPathComponent(c)
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                    walk(u, rel: rel.isEmpty ? c : "\(rel)/\(c)", depth: depth + 1)
                }
            }
        }
        walk(root, rel: "", depth: 0)

        for (p, label) in aiPaths where fm.fileExists(atPath: root.appendingPathComponent(p).path) {
            out.aiFiles.append(AIFile(path: p, label: label))
        }
        for (p, label) in aiFolders {
            if let items = try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(p).path) {
                out.aiFiles.append(AIFile(path: p, label: label, count: items.filter { !$0.hasPrefix(".") }.count))
            }
        }
        // Instruction files inside sub-projects too.
        for sp in out.subProjects {
            for name in ["CLAUDE.md", "AGENTS.md", "GEMINI.md"] where fm.fileExists(atPath: root.appendingPathComponent("\(sp.path)/\(name)").path) {
                out.aiFiles.append(AIFile(path: "\(sp.path)/\(name)", label: "In \(sp.path)"))
            }
        }
        return out
    }
}
