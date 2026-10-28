import SwiftUI

// MARK: - Models

/// One thing an agent, a build or the user did, for the live wire and project activity.
struct ActivityEvent: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case edit, ask, test, build, commit, deploy, start
        var label: String { rawValue.uppercased() }
    }
    enum Tone: String, Codable { case plain, good, warn, bad }

    var id = UUID()
    var date: Date
    var kind: Kind
    var projectID: ProjectID?
    /// Session name, "You", "Build"…
    var actor: String
    /// The rest of the sentence: "edited TabStrip.swift".
    var text: String
    var target: String = ""
    var meta: String = ""
    var tone: Tone = .plain
    var sessionID: String?
    /// Commit hash, for commit rows.
    var ref: String?
    /// A failed build or test.
    var failed = false
}

/// The result of a Run task (build, test or deploy) started from Brix.
struct BuildRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var projectID: ProjectID
    var task: String
    var kind: RunTask.Kind
    var ok: Bool
    var duration: TimeInterval
    var date: Date
}

/// A task detected in the project: build, test, run or deploy.
struct RunTask: Identifiable, Hashable {
    enum Kind: String, Codable { case build, test, run, deploy }
    var id: String { name }
    var name: String
    var command: String
    var kind: Kind
}

/// Commits, files and lines changed today in one project.
struct DayStats: Hashable {
    var commits = 0
    var files: Set<String> = []
    var add = 0
    var del = 0
}

/// Languages, files and lines in a project.
struct CodebaseStats: Hashable {
    struct Lang: Hashable { var name: String; var share: Double; var color: Color }
    var files = 0
    var lines = 0
    var langs: [Lang] = []
}

/// Tool calls and edits read from an agent transcript.
struct TranscriptStats: Hashable {
    enum Tool: Hashable { case read, edit, check, shell, error }
    var tools: [Tool] = []
    var files: Set<String> = []
    var add = 0
    var del = 0
}

// MARK: - Service

/// Build, deploy and codebase data. Sample projects get fixed sample data; real
/// projects read the folder and git, and everything else comes from what Brix records.
protocol ActivityService: Sendable {
    /// Events that exist outside Brix's own log (sample history).
    func events(_ p: Project) -> [ActivityEvent]
    func builds(_ p: Project) -> [BuildRecord]
    func runTasks(_ p: Project) -> [RunTask]
    func dayStats(_ p: Project) async -> DayStats
    func codebase(_ p: Project) async -> CodebaseStats
    /// Seven daily values (oldest first) for a sample metric; nil uses what Brix recorded.
    func series(_ metric: String, _ p: Project) -> [Double]?
}

struct LiveActivityService: ActivityService {
    func events(_ p: Project) -> [ActivityEvent] { [] }
    func builds(_ p: Project) -> [BuildRecord] { [] }
    func runTasks(_ p: Project) -> [RunTask] { RunTaskDetector.detect(p.url) }
    func series(_ metric: String, _ p: Project) -> [Double]? { nil }

    func dayStats(_ p: Project) async -> DayStats {
        guard let r = try? await ProcessRunner.run("git", ["-C", p.expandedPath, "log", "--since=midnight", "--numstat", "--format=%x1e%H"], timeout: 10),
              r.ok else { return DayStats() }
        return Self.parseDayLog(r.stdout)
    }

    /// `git log --numstat --format=%x1e%H` into totals.
    static func parseDayLog(_ out: String) -> DayStats {
        var s = DayStats()
        for record in out.split(separator: "\u{1e}") {
            let lines = record.split(separator: "\n")
            guard !lines.isEmpty else { continue }
            s.commits += 1
            for l in lines.dropFirst() {
                let f = l.split(separator: "\t", maxSplits: 2).map(String.init)
                guard f.count == 3 else { continue }
                s.add += Int(f[0]) ?? 0
                s.del += Int(f[1]) ?? 0
                s.files.insert(f[2])
            }
        }
        return s
    }

    func codebase(_ p: Project) async -> CodebaseStats {
        let url = p.url
        return await Task.detached(priority: .utility) { CodebaseScanner.scan(url) }.value
    }
}

struct MockActivityService: ActivityService {
    private static func ago(_ s: TimeInterval) -> Date { Date().addingTimeInterval(-s) }

    func events(_ p: Project) -> [ActivityEvent] {
        guard p.id == "atlas-web" || p.id == "atlas-api" else { return [] }
        if p.id == "atlas-api" {
            return [ActivityEvent(date: Self.ago(2 * 3600), kind: .deploy, projectID: p.id, actor: "You", text: "deployed atlas-api to", target: "Staging Server", meta: "docker compose up"),
                    ActivityEvent(date: Self.ago(3 * 3600), kind: .test, projectID: p.id, actor: "Tests", text: "passed", target: "go test ./...", meta: "128 passed", tone: .good)]
        }
        return [
            ActivityEvent(date: Self.ago(2 * 60), kind: .build, projectID: p.id, actor: "Build", text: "succeeded for", target: "next build", meta: "14.2s", tone: .good),
            ActivityEvent(date: Self.ago(40 * 60), kind: .test, projectID: p.id, actor: "Tests", text: "passed", target: "pnpm test", meta: "42 passed", tone: .good),
            ActivityEvent(date: Self.ago(2 * 3600), kind: .deploy, projectID: p.id, actor: "You", text: "deployed atlas-web to", target: "Development Server", meta: "docker compose up"),
            ActivityEvent(date: Self.ago(5 * 3600), kind: .start, projectID: p.id, actor: "add Apple Pay", text: "started from your prompt")
        ]
    }

    func builds(_ p: Project) -> [BuildRecord] {
        guard p.id == "atlas-web" else { return [] }
        let durations: [TimeInterval] = [16.1, 15.4, 17.0, 14.8, 15.9, 15.2, 14.2]
        return durations.enumerated().map { i, d in
            BuildRecord(projectID: p.id, task: "Build", kind: .build, ok: true, duration: d, date: Self.ago(Double(durations.count - i) * 3600 - 3480))
        }
    }

    func runTasks(_ p: Project) -> [RunTask] {
        [RunTask(name: "Dev server", command: "pnpm dev", kind: .run),
         RunTask(name: "Build", command: "pnpm build", kind: .build),
         RunTask(name: "Tests", command: "pnpm test", kind: .test)]
    }

    func dayStats(_ p: Project) async -> DayStats {
        p.id == "atlas-web" ? DayStats(commits: 3, files: ["a", "b", "c", "d", "e", "f", "g"], add: 412, del: 88) : DayStats()
    }

    func codebase(_ p: Project) async -> CodebaseStats {
        CodebaseStats(files: 148, lines: 18_200, langs: [.init(name: "TypeScript", share: 0.74, color: Color(hex: 0x60A5FA)),
                                                         .init(name: "CSS", share: 0.12, color: Color(hex: 0xA78BFA)),
                                                         .init(name: "JSON", share: 0.09, color: Color(hex: 0xFBBF24)),
                                                         .init(name: "Markdown", share: 0.05, color: Color(hex: 0x22D3EE))])
    }

    func series(_ metric: String, _ p: Project) -> [Double]? {
        guard p.id == "atlas-web" else { return nil }
        switch metric {
        case "agent": return [1200, 3000, 1800, 4800, 2400, 3600, 5400]
        case "tree": return [1, 4, 8, 3, 2, 6, 7]
        default: return nil
        }
    }
}

// MARK: - Run task detection

enum RunTaskDetector {
    /// Build, test, run and deploy tasks from the files at the root of a project.
    static func detect(_ root: URL) -> [RunTask] {
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(f).path) }
        func text(_ f: String) -> String { (try? String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)) ?? "" }
        var out: [RunTask] = []
        if has("build.sh") {
            out.append(RunTask(name: "Build", command: "./build.sh", kind: .build))
            if text("build.sh").contains("test") { out.append(RunTask(name: "Tests", command: "./build.sh test", kind: .test)) }
        } else if let proj = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).first(where: { $0.hasSuffix(".xcodeproj") }) {
            let scheme = (proj as NSString).deletingPathExtension
            out.append(RunTask(name: "Build", command: "xcodebuild -scheme \(ProcessRunner.shellQuote(scheme)) build", kind: .build))
            out.append(RunTask(name: "Tests", command: "xcodebuild -scheme \(ProcessRunner.shellQuote(scheme)) test", kind: .test))
        }
        if has("package.json"), let data = fm.contents(atPath: root.appendingPathComponent("package.json").path),
           let scripts = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["scripts"] as? [String: Any] {
            let pm = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : has("bun.lockb") ? "bun run" : "npm run"
            let order: [(String, RunTask.Kind)] = [("dev", .run), ("start", .run), ("build", .build), ("test", .test), ("lint", .test)]
            for (s, kind) in order where scripts[s] != nil {
                out.append(RunTask(name: s.capitalized, command: "\(pm) \(s)", kind: kind))
            }
        }
        if has("Cargo.toml") {
            out += [RunTask(name: "cargo build", command: "cargo build", kind: .build), RunTask(name: "cargo test", command: "cargo test", kind: .test)]
        }
        if has("go.mod") {
            out += [RunTask(name: "go build", command: "go build ./...", kind: .build), RunTask(name: "go test", command: "go test ./...", kind: .test)]
        }
        if has("Package.swift"), !out.contains(where: { $0.kind == .build }) {
            out += [RunTask(name: "swift build", command: "swift build", kind: .build), RunTask(name: "swift test", command: "swift test", kind: .test)]
        }
        if has("Makefile") {
            let targets = text("Makefile").split(separator: "\n").compactMap { line -> String? in
                guard let r = line.range(of: #"^[A-Za-z0-9_-]+(?=:)"#, options: .regularExpression), !line.contains(":=") else { return nil }
                return String(line[r])
            }
            for t in targets.prefix(3) where !out.contains(where: { $0.command == "make \(t)" }) {
                out.append(RunTask(name: "make \(t)", command: "make \(t)", kind: t.contains("test") ? .test : .build))
            }
        }
        if let compose = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"].first(where: has) {
            out.append(RunTask(name: "Compose up", command: "docker compose -f \(compose) up -d", kind: .deploy))
        }
        return Array(out.prefix(6))
    }
}

// MARK: - Codebase

enum CodebaseScanner {
    static let languages: [String: (String, UInt32)] = [
        "swift": ("Swift", 0xFB923C), "ts": ("TypeScript", 0x60A5FA), "tsx": ("TypeScript", 0x60A5FA), "js": ("JavaScript", 0xFBBF24),
        "jsx": ("JavaScript", 0xFBBF24), "py": ("Python", 0x60A5FA), "go": ("Go", 0x22D3EE), "rs": ("Rust", 0xFB923C),
        "php": ("PHP", 0xA78BFA), "rb": ("Ruby", 0xF87171), "java": ("Java", 0xFB923C), "kt": ("Kotlin", 0xA78BFA),
        "c": ("C", 0xA1A1AA), "h": ("C", 0xA1A1AA), "m": ("Objective-C", 0x60A5FA), "cpp": ("C++", 0xF472B6), "cs": ("C#", 0x4ADE80),
        "css": ("CSS", 0xA78BFA), "scss": ("CSS", 0xA78BFA), "html": ("HTML", 0xFB923C), "vue": ("Vue", 0x4ADE80), "svelte": ("Svelte", 0xFB923C),
        "md": ("Markdown", 0x22D3EE), "yml": ("YAML", 0xA78BFA), "yaml": ("YAML", 0xA78BFA), "json": ("JSON", 0xFBBF24),
        "sh": ("Shell", 0x4ADE80), "zsh": ("Shell", 0x4ADE80), "sql": ("SQL", 0xFBBF24), "dart": ("Dart", 0x22D3EE), "ex": ("Elixir", 0xA78BFA)
    ]

    /// ponytail: walks up to 20,000 files and reads those under 1 MB; huge monorepos show a partial count.
    static func scan(_ root: URL) -> CodebaseStats {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return CodebaseStats() }
        var stats = CodebaseStats()
        var byLang: [String: Int] = [:]
        var colors: [String: UInt32] = [:]
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if v?.isDirectory == true {
                if ProjectScan.skip.contains(url.lastPathComponent) || url.pathExtension == "xcodeproj" { walker.skipDescendants() }
                continue
            }
            stats.files += 1
            if stats.files > 20_000 { break }
            guard let lang = languages[url.pathExtension.lowercased()], (v?.fileSize ?? 0) < 1_000_000,
                  let data = try? Data(contentsOf: url) else { continue }
            let n = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            stats.lines += n
            byLang[lang.0, default: 0] += n
            colors[lang.0] = lang.1
        }
        let total = max(byLang.values.reduce(0, +), 1)
        stats.langs = byLang.sorted { $0.value > $1.value }.prefix(5).map {
            .init(name: $0.key, share: Double($0.value) / Double(total), color: Color(hex: colors[$0.key] ?? 0xA1A1AA))
        }
        return stats
    }
}

// MARK: - Transcript tool calls

extension AgentTranscripts {
    /// Tool calls, files edited and lines changed in a transcript (head and tail only).
    static func stats(_ e: AgentHistoryEntry) -> TranscriptStats {
        statsCache.value(e.file) { readStats(e) } ?? TranscriptStats()
    }

    private static func readStats(_ e: AgentHistoryEntry) -> TranscriptStats {
        let (head, tail) = headTail(e.file)
        var s = TranscriptStats()
        func lines(_ text: String) -> Int { text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count }
        func shell(_ cmd: String) -> TranscriptStats.Tool {
            let c = cmd.lowercased()
            if c.contains("test") || c.contains("build") || c.contains("xcodebuild") || c.contains("lint") { return .check }
            if c.hasPrefix("cat ") || c.hasPrefix("rg ") || c.hasPrefix("grep ") || c.hasPrefix("ls") || c.hasPrefix("sed -n") || c.hasPrefix("find ") { return .read }
            return .shell
        }
        for line in head + tail {
            guard line.contains("tool_use") || line.contains("tool_result") || line.contains("function_call") || line.contains("custom_tool_call"),
                  let o = json(line) else { continue }
            if e.agent == "codex" {
                guard let p = o["payload"] as? [String: Any], let type = p["type"] as? String else { continue }
                if type == "function_call", let args = (p["arguments"] as? String).flatMap(json) {
                    let cmd = (args["command"] as? [String])?.joined(separator: " ") ?? (args["command"] as? String) ?? (args["cmd"] as? String) ?? ""
                    if cmd.contains("apply_patch") { s.tools.append(.edit); patch(cmd, into: &s) } else { s.tools.append(shell(cmd)) }
                } else if type == "custom_tool_call", let input = p["input"] as? String {
                    s.tools.append(.edit)
                    patch(input, into: &s)
                } else if type == "function_call_output", (p["output"] as? String)?.contains("\"exit_code\":1") == true {
                    s.tools.append(.error)
                }
                continue
            }
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for c in content {
                if c["type"] as? String == "tool_result", c["is_error"] as? Bool == true { s.tools.append(.error); continue }
                guard c["type"] as? String == "tool_use", let name = c["name"] as? String else { continue }
                let input = c["input"] as? [String: Any] ?? [:]
                switch name {
                case "Edit", "MultiEdit", "Write", "NotebookEdit":
                    s.tools.append(.edit)
                    if let f = input["file_path"] as? String { s.files.insert(f) }
                    if let n = input["new_string"] as? String { s.add += lines(n) }
                    if let o = input["old_string"] as? String { s.del += lines(o) }
                    if let w = input["content"] as? String { s.add += lines(w) }
                    for edit in input["edits"] as? [[String: Any]] ?? [] {
                        s.add += lines(edit["new_string"] as? String ?? "")
                        s.del += lines(edit["old_string"] as? String ?? "")
                    }
                case "Bash": s.tools.append(shell(input["command"] as? String ?? ""))
                default: s.tools.append(.read)
                }
            }
        }
        if s.tools.count > 28 { s.tools = Array(s.tools.suffix(28)) }
        return s
    }

    private static func patch(_ text: String, into s: inout TranscriptStats) {
        for l in text.split(separator: "\n") {
            if l.hasPrefix("*** Update File: ") || l.hasPrefix("*** Add File: ") { s.files.insert(String(l.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces)) }
            else if l.hasPrefix("+"), !l.hasPrefix("+++") { s.add += 1 }
            else if l.hasPrefix("-"), !l.hasPrefix("---") { s.del += 1 }
        }
    }
}
