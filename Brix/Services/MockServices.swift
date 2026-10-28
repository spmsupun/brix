import Foundation
import SwiftUI

/// Small async delay so simulated work is visible.
func simulatedDelay(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// MARK: - Git

final class MockGitService: GitService {
    var states: [ProjectID: GitRepoState]
    var delay: Double

    init(states: [ProjectID: GitRepoState] = MockData.git, delay: Double = 0.35) {
        self.states = states
        self.delay = delay
    }

    private func state(_ p: Project) throws -> GitRepoState {
        guard let s = states[p.id] else { throw ServiceError("\(p.name) is not a Git repository") }
        return s
    }

    func status(_ project: Project) async throws -> GitRepoState { try state(project) }

    func stage(_ project: Project, paths: [String]) async throws -> GitRepoState {
        var s = try state(project)
        let set = Set(paths)
        // Merge any staged copy of the same path into one staged entry.
        var merged: [GitFileChange] = []
        for c in s.changes {
            if set.contains(c.path) {
                if let i = merged.firstIndex(where: { $0.path == c.path && $0.staged }) {
                    merged[i].add += c.add; merged[i].del += c.del
                } else {
                    var n = c; n.staged = true
                    if n.status == .U { n.status = .A }
                    merged.append(n)
                }
            } else {
                merged.append(c)
            }
        }
        s.changes = merged
        states[project.id] = s
        return s
    }

    func unstage(_ project: Project, paths: [String]) async throws -> GitRepoState {
        var s = try state(project)
        let set = Set(paths)
        s.changes = s.changes.map { c in
            guard set.contains(c.path), c.staged else { return c }
            var n = c; n.staged = false
            return n
        }
        states[project.id] = s
        return s
    }

    func discard(_ project: Project, paths: [String]) async throws -> GitRepoState {
        var s = try state(project)
        let set = Set(paths)
        s.changes.removeAll { set.contains($0.path) && !$0.staged }
        states[project.id] = s
        return s
    }

    func commit(_ project: Project, message: String) async throws -> GitRepoState {
        await simulatedDelay(delay)
        var s = try state(project)
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { throw ServiceError("Write a commit message first") }
        let staged = s.staged
        guard !staged.isEmpty else { throw ServiceError("Nothing staged to commit") }
        let hash = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        s.commits.insert(GitCommit(hash: hash, message: msg, author: NSFullUserName().components(separatedBy: " ").first ?? "You", date: Date(), files: staged, isPushed: false), at: 0)
        s.changes.removeAll(where: \.staged)
        s.ahead += 1
        states[project.id] = s
        return s
    }

    func fetch(_ project: Project) async throws -> GitRepoState {
        await simulatedDelay(delay * 2)
        return try state(project)
    }

    func pull(_ project: Project) async throws -> GitRepoState {
        await simulatedDelay(delay * 2)
        var s = try state(project)
        if s.behind > 0 {
            s.commits.insert(GitCommit(hash: "d3adb33f0001", message: "Merge remote-tracking branch 'origin/\(s.branch)'", author: "Maya Chen", date: Date()), at: 0)
        }
        s.behind = 0
        states[project.id] = s
        return s
    }

    func push(_ project: Project) async throws -> GitRepoState {
        await simulatedDelay(delay * 2)
        var s = try state(project)
        guard s.ahead > 0 else { throw ServiceError("Everything up-to-date") }
        s.ahead = 0
        s.commits = s.commits.map { var c = $0; c.isPushed = true; return c }
        states[project.id] = s
        return s
    }

    func diff(_ project: Project, change: GitFileChange) async throws -> FileDiff {
        MockData.syntheticDiff(for: change)
    }

    func commitDetail(_ project: Project, hash: String) async throws -> GitCommit {
        let s = try state(project)
        guard let c = s.commits.first(where: { $0.hash == hash }) else { throw ServiceError("Unknown commit \(hash.prefix(7))") }
        return c
    }

    func switchBranch(_ project: Project, to name: String) async throws -> GitRepoState {
        await simulatedDelay(delay)
        var s = try state(project)
        guard s.branches.contains(where: { $0.name == name }) else { throw ServiceError("Branch \(name) not found") }
        s.branches = s.branches.map { var b = $0; b.isCurrent = b.name == name; return b }
        s.branch = name
        s.ahead = 0
        s.behind = 0
        states[project.id] = s
        return s
    }

    func createBranch(_ project: Project, name: String) async throws -> GitRepoState {
        var s = try state(project)
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.contains(" ") else { throw ServiceError("Branch names can't contain spaces") }
        guard !s.branches.contains(where: { $0.name == clean }) else { throw ServiceError("Branch \(clean) already exists") }
        s.branches = s.branches.map { var b = $0; b.isCurrent = false; return b }
        s.branches.insert(GitBranch(name: clean, isCurrent: true, lastCommit: "now"), at: 0)
        s.branch = clean
        s.ahead = 0
        states[project.id] = s
        return s
    }

    func deleteBranch(_ project: Project, name: String) async throws -> GitRepoState {
        var s = try state(project)
        guard name != s.branch else { throw ServiceError("Can't delete the current branch") }
        s.branches.removeAll { $0.name == name }
        states[project.id] = s
        return s
    }

    func suggestMessage(_ project: Project, staged: [GitFileChange]) async -> String {
        await simulatedDelay(0.6)
        return CommitMessageWriter.suggest(for: staged)
    }
}

/// Local heuristic commit message writer (no network, no AI call).
enum CommitMessageWriter {
    static func suggest(for changes: [GitFileChange]) -> String {
        guard !changes.isEmpty else { return "" }
        if changes.contains(where: { $0.path.contains("PaymentForm") }) {
            return "Add Apple Pay wallet buttons to checkout"
        }
        let added = changes.filter { $0.status == .A || $0.status == .U }
        let deleted = changes.filter { $0.status == .D }
        let names = changes.map { ($0.name as NSString).deletingPathExtension }
        let verb = added.count == changes.count ? "Add" : (deleted.count == changes.count ? "Remove" : "Update")
        let subject = names.count <= 2 ? names.joined(separator: " and ") : "\(names[0]) and \(names.count - 1) more files"
        return "\(verb) \(subject)"
    }
}

// MARK: - Files

final class MockFileService: FileService {
    var created: [ProjectID: [String]] = [:]
    var renamed: [ProjectID: [String: String]] = [:]

    func tree(_ project: Project) async throws -> [FileNode] {
        var tree = MockData.tree(for: project.id)
        if let extra = created[project.id], !extra.isEmpty {
            var paths = flatten(tree).filter { !$0.isDirectory }.map(\.path)
            paths += extra
            let status = Dictionary(MockData.git[project.id]?.changes.map { ($0.path, $0.status) } ?? [], uniquingKeysWith: { a, _ in a })
            tree = MockData.buildTree(paths: paths, status: status)
        }
        if let map = renamed[project.id], !map.isEmpty {
            let paths = flatten(tree).filter { !$0.isDirectory }.map { map[$0.path] ?? $0.path }
            tree = MockData.buildTree(paths: paths, status: [:])
        }
        return tree
    }

    private func flatten(_ nodes: [FileNode]) -> [FileNode] {
        nodes.flatMap { [$0] + flatten($0.children ?? []) }
    }

    func read(_ project: Project, path: String) async -> FileContent {
        MockData.content(project: project.id, path: path)
    }

    func info(_ project: Project, path: String) async -> FileInfo {
        switch MockData.content(project: project.id, path: path) {
        case .text(let s):
            return FileInfo(kind: FileKinds.kind(for: path), size: s.utf8.count, lines: s.split(separator: "\n", omittingEmptySubsequences: false).count, encoding: "UTF-8", modified: Date().addingTimeInterval(-600))
        case .image(_, let size):
            return FileInfo(kind: "PNG image · \(Int(size.width))×\(Int(size.height))", size: 18_204, lines: 0, encoding: "binary", modified: Date().addingTimeInterval(-86400))
        case .binary(let size):
            return FileInfo(kind: "Binary", size: size, lines: 0, encoding: "binary", modified: Date().addingTimeInterval(-86400 * 2))
        case .missing:
            return FileInfo(kind: "Missing", size: 0, lines: 0, encoding: "", modified: nil)
        }
    }

    func create(_ project: Project, path: String, isDirectory: Bool) async throws {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !clean.isEmpty else { throw ServiceError("Enter a name") }
        created[project.id, default: []].append(isDirectory ? clean + "/.keep" : clean)
    }

    func rename(_ project: Project, from: String, to: String) async throws {
        guard !to.isEmpty else { throw ServiceError("Enter a name") }
        renamed[project.id, default: [:]][from] = to
    }

    func watch(_ project: Project, onChange: @escaping (_ files: Bool) -> Void) -> AnyObject? { nil }
}

enum FileKinds {
    static func language(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "ts": "TypeScript"
        case "tsx": "TypeScript JSX"
        case "js", "mjs", "cjs": "JavaScript"
        case "jsx": "JavaScript JSX"
        case "swift": "Swift"
        case "go": "Go"
        case "py": "Python"
        case "php": "PHP"
        case "sql": "SQL"
        case "json": "JSON"
        case "yml", "yaml": "YAML"
        case "md", "markdown": "Markdown"
        case "sh", "zsh", "bash": "Shell"
        case "toml": "TOML"
        case "png", "jpg", "jpeg", "gif", "webp", "ico", "heic": "Image"
        default:
            (path as NSString).lastPathComponent.hasPrefix(".") ? "Config" : "Plain Text"
        }
    }

    static func kind(for path: String) -> String {
        let lang = language(for: path)
        return lang == "Plain Text" ? "Text file" : "\(lang) source"
    }

    static func iconColor(for name: String) -> Color {
        switch (name as NSString).pathExtension.lowercased() {
        case "ts", "tsx", "js", "jsx", "go", "py", "swift", "php", "sql": Theme.blue
        case "json", "yml", "yaml", "toml": Theme.amber
        case "md": Theme.violet
        case "png", "jpg", "jpeg", "gif", "ico", "webp": Theme.pink
        default: Theme.text3
        }
    }

    static func isImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "ico", "heic", "tiff", "bmp"].contains((path as NSString).pathExtension.lowercased())
    }
}

// MARK: - Terminal

final class MockTerminalService: TerminalService {
    func respond(to command: String, session: TerminalSession, project: Project?, host: SSHHost?, git: GitRepoState?) async -> [TermLine] {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        let parts = cmd.split(separator: " ").map(String.init)
        guard let head = parts.first else { return [] }
        func span(_ t: String, _ c: Color = Theme.body, bold: Bool = false) -> TermSpan { MockData.span(t, c, bold: bold) }
        let projectName = project?.name ?? "project"
        switch head {
        case "help":
            return ["Brix sample shell. Try:", "  ls  pwd  git status  git log  pnpm dev  pnpm test", "  go test ./...  docker ps  htop  claude  clear"].map { TermLine($0, Theme.text3) }
        case "pwd":
            return [TermLine((session.cwd as NSString).expandingTildeInPath.replacingOccurrences(of: NSHomeDirectory(), with: host == nil ? NSHomeDirectory() : "/home/\(host!.user)"))]
        case "ls":
            if host != nil {
                return [TermLine([span("docker-compose.yml  ", Theme.body), span("logs/  ", Theme.blue, bold: true), span("releases/  ", Theme.blue, bold: true), span(".env", Theme.text3)])]
            }
            let names = MockData.tree(for: project?.id ?? "atlas-web").map { $0.isDirectory ? $0.name + "/" : $0.name }
            return stride(from: 0, to: names.count, by: 4).map { i in
                TermLine(names[i..<min(i + 4, names.count)].map { n in span(n.padding(toLength: 22, withPad: " ", startingAt: 0), n.hasSuffix("/") ? Theme.blue : Theme.body, bold: n.hasSuffix("/")) })
            }
        case "git":
            let sub = parts.dropFirst().first ?? ""
            guard let git, git.isRepo else { return [TermLine("fatal: not a git repository (or any of the parent directories): .git", Theme.red)] }
            if sub == "status" {
                var out = [TermLine("On branch \(git.branch)")]
                if git.ahead > 0 { out.append(TermLine("Your branch is ahead of 'origin/\(git.branch)' by \(git.ahead) commit\(git.ahead == 1 ? "" : "s").")) }
                if git.isClean { out.append(TermLine("nothing to commit, working tree clean")); return out }
                if !git.staged.isEmpty {
                    out.append(TermLine("Changes to be committed:"))
                    out += git.staged.map { TermLine("\t\(label($0.status)):   \($0.path)", Theme.green) }
                }
                let unstaged = git.unstaged.filter { $0.status != .U }
                if !unstaged.isEmpty {
                    out.append(TermLine("Changes not staged for commit:"))
                    out += unstaged.map { TermLine("\t\(label($0.status)):   \($0.path)", Theme.red) }
                }
                let untracked = git.unstaged.filter { $0.status == .U }
                if !untracked.isEmpty {
                    out.append(TermLine("Untracked files:"))
                    out += untracked.map { TermLine("\t\($0.path)", Theme.red) }
                }
                return out
            }
            if sub == "log" {
                return git.commits.prefix(8).map { TermLine([span($0.short + " ", Theme.amber), span($0.message)]) }
            }
            if sub == "branch" {
                return git.branches.map { TermLine(($0.isCurrent ? "* " : "  ") + $0.name, $0.isCurrent ? Theme.green : Theme.body) }
            }
            return [TermLine("git: '\(sub)' is simulated in the sample workspace", Theme.text3)]
        case "pnpm", "npm":
            let sub = parts.dropFirst().first ?? ""
            if sub == "dev" {
                return [TermLine([span("  ▲ Next.js 15.1.2", Theme.text, bold: true), span(" (Turbopack)", Theme.text3)]), TermLine("  - Local:        http://localhost:3000"), TermLine([span(" ✓ ", Theme.green), span("Ready in 1182ms")])]
            }
            if sub == "test" {
                return [TermLine([span(" RUN ", Theme.blue, bold: true), span(" v2.1.8 ~/Developer/\(projectName)", Theme.text3)]),
                        TermLine([span(" ✓ ", Theme.green), span("src/lib/stripe/intent.test.ts "), span("(3 tests) 22ms", Theme.text3)]),
                        TermLine([span(" ✓ ", Theme.green), span("src/lib/useCartTotals.test.ts "), span("(5 tests) 14ms", Theme.text3)]),
                        TermLine(""), TermLine([span(" Test Files  ", Theme.text3), span("2 passed", Theme.green)]), TermLine([span("      Tests  ", Theme.text3), span("8 passed", Theme.green)])]
            }
            return [TermLine("\(head) \(sub): done", Theme.text3)]
        case "go":
            return [TermLine("ok  \t\(projectName)/internal/payments\t0.412s", Theme.green), TermLine("ok  \t\(projectName)/internal/bookings\t0.207s", Theme.green), TermLine("?   \t\(projectName)/cmd/api\t[no test files]", Theme.text3)]
        case "docker":
            return [TermLine("CONTAINER ID   IMAGE              STATUS        PORTS     NAMES", Theme.text3)]
                + MockData.docker.filter { host == nil ? $0.hostID == nil : $0.hostID == host?.id }.map {
                    TermLine("\(String($0.id.hash.magnitude, radix: 16).prefix(12).padding(toLength: 15, withPad: " ", startingAt: 0))\($0.image.padding(toLength: 19, withPad: " ", startingAt: 0))\(($0.state == .running ? "Up 2 hours" : "Exited (0)").padding(toLength: 14, withPad: " ", startingAt: 0))\($0.ports.padding(toLength: 10, withPad: " ", startingAt: 0))\($0.name)")
                }
        case "htop", "top":
            return MockData.htopTranscript
        case "claude":
            return [TermLine([span("✻ ", Theme.violet), span("Claude Code", Theme.text, bold: true), span("  \(session.cwd)", Theme.meta)]), TermLine("  Open a Claude Code session with ⌥⌘T to work with the agent.", Theme.text3)]
        case "echo":
            return [TermLine(parts.dropFirst().joined(separator: " "))]
        case "whoami":
            return [TermLine(host?.user ?? NSUserName())]
        case "cd":
            return []
        default:
            return [TermLine("zsh: command not found: \(head)", Theme.red)]
        }
    }

    private func label(_ s: GitStatus) -> String {
        switch s {
        case .M: "modified"
        case .A: "new file"
        case .D: "deleted"
        case .U: "untracked"
        }
    }
}

// MARK: - Agent

final class MockAgentService: AgentService {
    var delay: Double = 1.2

    func reply(to prompt: String, session: TerminalSession, project: Project?) async -> AgentReply {
        await simulatedDelay(delay)
        func span(_ t: String, _ c: Color = Theme.body, bold: Bool = false) -> TermSpan { MockData.span(t, c, bold: bold) }
        var plan = session.plan
        if let i = plan.firstIndex(where: { !$0.done }) { plan[i].done = true }
        let done = plan.filter(\.done).count
        let progress = plan.isEmpty ? 1 : Double(done) / Double(plan.count)
        let target = session.touched.first?.path ?? "src/app/page.tsx"
        let lines = [
            TermLine(""),
            TermLine([span("> ", Theme.violet), span(prompt, Theme.text)]),
            TermLine([span("⏺ ", Theme.green), span("Read", Theme.text, bold: true), span("(\(target))", Theme.text3)]),
            TermLine([span("  ⎿ Read 48 lines", Theme.text3)]),
            TermLine([span("⏺ ", Theme.amber), span("Update", Theme.text, bold: true), span("(\(target))", Theme.text3), span("  +6", Theme.green), span(" −2", Theme.red)]),
            TermLine([span("⏺ ", Theme.text), span(done == plan.count ? "All tasks done. Anything else?" : "Done with that step. Should I continue with “\(plan.first(where: { !$0.done })?.title ?? "the next task")”?")]),
            TermLine([span("▍", Theme.amber)])
        ]
        var touched = session.touched
        if let i = touched.firstIndex(where: { $0.path == target }) {
            touched[i].add += 6; touched[i].del += 2
        } else {
            touched.append(FileTouch(path: target, add: 6, del: 2))
        }
        return AgentReply(lines: lines, plan: plan, touched: touched, state: .needsInput,
                          lastOutput: "Done with that step.\nWaiting for your reply", progress: progress)
    }
}

// MARK: - SSH and metrics

final class MockSSHService: SSHService {
    var delay: Double = 1.0

    func test(_ host: SSHHost, password: String?) async throws -> String {
        await simulatedDelay(delay)
        if host.id == "bastion" || host.host.contains("bastion") {
            throw ServiceError("Connection timed out after 10 s (\(host.host):\(host.port))")
        }
        if host.host.isEmpty { throw ServiceError("Enter a host") }
        return "OpenSSH_9.6 · \(Int.random(in: 18...64)) ms"
    }

    func connect(_ host: SSHHost) async throws {
        _ = try await test(host, password: nil)
    }
}

final class MockMetricsService: MetricsService {
    func metrics(_ host: SSHHost) async throws -> HostMetrics {
        await simulatedDelay(0.2)
        var m = MockData.metrics[host.id] ?? HostMetrics(cpu: 0.2, memory: 0.4, disk: 0.5, load: "0.30 0.28 0.25", uptime: "3 days", os: host.os)
        func jitter(_ v: Double) -> Double { min(0.98, max(0.01, v + Double.random(in: -0.06...0.06))) }
        m.cpu = jitter(m.cpu)
        m.memory = jitter(m.memory)
        return m
    }
}

// MARK: - Database

final class MockDatabaseService: DatabaseService {
    var delay: Double = 0.4

    private func check(_ c: DatabaseConnection) async throws {
        await simulatedDelay(delay)
        if c.id == "atlas_prod_replica" || c.host.contains("replica") {
            throw ServiceError("timeout: could not connect to \(c.host):\(c.port) after 10 s")
        }
    }

    func test(_ c: DatabaseConnection, password: String?) async throws -> DBTestResult {
        try await check(c)
        let v: String = switch c.kind {
        case .postgres: "PostgreSQL 16.4"
        case .mysql: "MySQL 8.4.2"
        case .sqlite: "SQLite 3.45.1"
        }
        return DBTestResult(version: v, latencyMs: Double.random(in: 3...24).rounded())
    }

    static func tables(for c: DatabaseConnection) -> [String: [DBObject]] {
        switch c.kind {
        case .postgres:
            let pub: [DBObject] = [("users", 12_500), ("organizations", 1_200), ("projects", 3_400), ("bookings", 96_000), ("payments", 88_402), ("sessions", 5_900), ("audit_log", 771_000)]
                .map { DBObject(schema: "public", name: $0.0, kind: .table, rowEstimate: $0.1) }
                + [DBObject(schema: "public", name: "active_users", kind: .view, rowEstimate: nil), DBObject(schema: "public", name: "monthly_revenue", kind: .view, rowEstimate: nil),
                   DBObject(schema: "public", name: "touch_updated_at", kind: .function, rowEstimate: nil)]
            let auth = [DBObject(schema: "auth", name: "identities", kind: .table, rowEstimate: 13_100), DBObject(schema: "auth", name: "refresh_tokens", kind: .table, rowEstimate: 40_220)]
            return ["public": pub, "auth": auth]
        case .mysql:
            return [c.database.isEmpty ? "billing" : c.database: [("customers", 4_210), ("invoices", 38_900), ("line_items", 211_000)].map { DBObject(schema: c.database.isEmpty ? "billing" : c.database, name: $0.0, kind: .table, rowEstimate: $0.1) }]
        case .sqlite:
            return ["main": [("events", 1_480_000), ("daily_rollup", 730)].map { DBObject(schema: "main", name: $0.0, kind: .table, rowEstimate: $0.1) }]
        }
    }

    func schema(_ c: DatabaseConnection, password: String?) async throws -> DBSchemaTree {
        try await check(c)
        return DBSchemaTree(database: c.kind == .sqlite ? c.name : (c.database.isEmpty ? c.name : c.database), schemas: Self.tables(for: c))
    }

    static func columns(for table: String) -> [DBColumn] {
        switch table {
        case "users":
            return [DBColumn(name: "id", type: "uuid", nullable: false, defaultValue: "gen_random_uuid()", isPK: true),
                    DBColumn(name: "email", type: "varchar(255)", nullable: false),
                    DBColumn(name: "full_name", type: "text"),
                    DBColumn(name: "role", type: "user_role", nullable: false, defaultValue: "'member'"),
                    DBColumn(name: "plan", type: "text", nullable: false, defaultValue: "'free'"),
                    DBColumn(name: "org_id", type: "uuid", fk: "organizations.id"),
                    DBColumn(name: "created_at", type: "timestamptz", nullable: false, defaultValue: "now()"),
                    DBColumn(name: "last_login_at", type: "timestamptz")]
        case "payments":
            return [DBColumn(name: "id", type: "bigint", nullable: false, isPK: true),
                    DBColumn(name: "booking_id", type: "bigint", nullable: false, fk: "bookings.id"),
                    DBColumn(name: "provider", type: "text", nullable: false),
                    DBColumn(name: "status", type: "text", nullable: false, defaultValue: "'pending'"),
                    DBColumn(name: "amount_cents", type: "integer", nullable: false),
                    DBColumn(name: "created_at", type: "timestamptz", nullable: false, defaultValue: "now()")]
        case "bookings":
            return [DBColumn(name: "id", type: "bigint", nullable: false, isPK: true),
                    DBColumn(name: "user_id", type: "uuid", nullable: false, fk: "users.id"),
                    DBColumn(name: "status", type: "text", nullable: false),
                    DBColumn(name: "total_cents", type: "integer", nullable: false),
                    DBColumn(name: "created_at", type: "timestamptz", nullable: false, defaultValue: "now()")]
        default:
            return [DBColumn(name: "id", type: "bigint", nullable: false, isPK: true),
                    DBColumn(name: "name", type: "text"),
                    DBColumn(name: "created_at", type: "timestamptz", nullable: false, defaultValue: "now()")]
        }
    }

    func tableDetail(_ c: DatabaseConnection, object: DBObject, password: String?) async throws -> TableDetail {
        try await check(c)
        let cols = Self.columns(for: object.name)
        var idx = [DBIndex(name: "\(object.name)_pkey", columns: ["id"], unique: true, method: "btree", size: "296 kB")]
        if object.name == "users" {
            idx += [DBIndex(name: "users_email_key", columns: ["email"], unique: true, method: "btree", size: "512 kB"),
                    DBIndex(name: "users_org_id_idx", columns: ["org_id"], unique: false, method: "btree", size: "248 kB")]
        }
        if object.name == "payments" {
            idx += [DBIndex(name: "payments_booking_id_idx", columns: ["booking_id"], unique: false, method: "btree", size: "1.9 MB"),
                    DBIndex(name: "payments_status_created_idx", columns: ["status", "created_at"], unique: false, method: "btree", size: "2.6 MB")]
        }
        let rows = object.rowEstimate ?? 0
        return TableDetail(columns: cols, indexes: idx, rowEstimate: rows, size: ByteCountFormatter.string(fromByteCount: Int64(rows * 180), countStyle: .file))
    }

    // Deterministic synthetic rows, generated per page so huge tables stay cheap.
    static let first = ["Maya", "Liam", "Aisha", "Noah", "Sofia", "Kenji", "Elena", "Omar", "Priya", "Lucas", "Hannah", "Mateo", "Zara", "Felix", "Ines", "Tom"]
    static let last = ["Chen", "Okafor", "Patel", "Muller", "Rossi", "Tanaka", "Garcia", "Haddad", "Novak", "Silva", "Kim", "Andersen", "Moreau", "Fischer", "Costa", "Reid"]
    static let domains = ["acme.io", "northwind.dev", "globex.com", "initech.co", "hooli.xyz"]
    static let roles = ["owner", "admin", "member", "member", "viewer"]

    static func row(table: String, index i: Int) -> [String?] {
        switch table {
        case "users":
            let f = first[(i * 7 + 3) % 16], l = last[(i * 11 + 5) % 16]
            let id = String(format: "%08x", UInt32(truncatingIfNeeded: 2654435761 &* (i + 1))) + "-4c1e-9a2b-\(String(format: "%012x", i * 7919))"
            let org: String? = i % 4 == 0 ? nil : String(format: "%08x", UInt32(truncatingIfNeeded: 40503 &* (i + 3))) + "-0b7d-4e8a-\(String(format: "%012x", i * 31))"
            let created = String(format: "2025-%02d-%02d 09:%02d", 1 + (i * 7) % 12, 1 + (i * 5) % 28, (i * 13) % 60)
            let login = String(format: "2026-10-%02d %02d:%02d", max(1, 27 - i / 2 % 27), 8 + i % 10, (i * 7) % 60)
            return [id, "\(f.lowercased()).\(l.lowercased())@\(domains[i % 5])", i == 6 ? nil : "\(f) \(l)", roles[i % 5], ["enterprise", "team", "pro", "free"][i % 4 == 3 ? 3 : (i % 3)], org, created, login]
        case "payments":
            let statuses = ["succeeded", "succeeded", "requires_action", "processing", "succeeded"]
            return ["\(90429 - i)", "\(41000 + i * 3)", i % 5 == 0 || i % 5 == 4 ? "apple_pay" : "stripe", statuses[i % 5], "\([12400, 8900, 4900, 31200, 6600][i % 5] + (i / 5) * 100)", String(format: "2026-10-%02d 1%d:%02d", max(1, 27 - i / 40 % 27), i % 10, (i * 17) % 60)]
        case "bookings":
            return ["\(96000 - i)", String(format: "%08x-4c1e", UInt32(truncatingIfNeeded: 2654435761 &* (i + 1))), ["confirmed", "pending", "cancelled", "confirmed"][i % 4], "\(4900 + (i * 137) % 30000)", String(format: "2026-10-%02d 08:%02d", max(1, 27 - i / 30 % 27), (i * 11) % 60)]
        default:
            return ["\(i + 1)", "\(table)_\(i + 1)", String(format: "2026-09-%02d 12:%02d", 1 + i % 28, i % 60)]
        }
    }

    func rows(_ c: DatabaseConnection, object: DBObject, filter: String, sort: (column: String, ascending: Bool)?, page: Int, pageSize: Int, password: String?) async throws -> QueryResult {
        let start = Date()
        try await check(c)
        let cols = Self.columns(for: object.name)
        let total = object.rowEstimate ?? 100
        var rows: [[String?]]
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !f.isEmpty {
            // Simple "column = 'value'" or substring filter over the first 2,000 rows.
            let all = (0..<min(total, 2000)).map { Self.row(table: object.name, index: $0) }
            let needle = f.components(separatedBy: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) ?? f
            rows = all.filter { r in r.contains { ($0 ?? "null").lowercased().contains(needle) } }
            let matched = rows.count
            if let sort, let ci = cols.firstIndex(where: { $0.name == sort.column }) {
                rows.sort { a, b in sort.ascending ? (a[ci] ?? "") < (b[ci] ?? "") : (a[ci] ?? "") > (b[ci] ?? "") }
            }
            rows = Array(rows.dropFirst(page * pageSize).prefix(pageSize))
            return QueryResult(columns: cols, rows: rows, totalRows: matched, elapsedMs: Date().timeIntervalSince(start) * 1000)
        }
        let lo = page * pageSize
        let hi = min(lo + pageSize, total)
        rows = lo < hi ? (lo..<hi).map { Self.row(table: object.name, index: $0) } : []
        if let sort, let ci = cols.firstIndex(where: { $0.name == sort.column }) {
            rows.sort { a, b in sort.ascending ? (a[ci] ?? "") < (b[ci] ?? "") : (a[ci] ?? "") > (b[ci] ?? "") }
        }
        return QueryResult(columns: cols, rows: rows, totalRows: total, elapsedMs: Date().timeIntervalSince(start) * 1000)
    }

    func executeBatch(_ c: DatabaseConnection, sqls: [String], expect: [Int?], password: String?) async throws -> QueryResult {
        try await check(c)
        return QueryResult(columns: [], rows: [], totalRows: 0, elapsedMs: 12, message: "\(sqls.count) statement\(sqls.count == 1 ? "" : "s") committed")
    }

    func cancel(_ c: DatabaseConnection, owner: String?, password: String?) async {}

    func page(_ c: DatabaseConnection, object: DBObject, where w: String, orderBy: String, page: Int, pageSize: Int, columns: [DBColumn]?, password: String?) async throws -> QueryResult {
        let parts = orderBy.split(separator: ",").first?.split(separator: " ").map(String.init) ?? []
        let sort = parts.first.map { (column: $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"`")), ascending: parts.count < 2 || parts[1].lowercased() != "desc") }
        return try await rows(c, object: object, filter: w, sort: sort, page: page, pageSize: pageSize, password: password)
    }

    func execute(_ c: DatabaseConnection, sql: String, password: String?) async throws -> QueryResult {
        try await check(c)
        let s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        guard !s.isEmpty else { throw ServiceError("Empty query") }
        if lower.hasPrefix("set ") || lower.hasPrefix("use ") { return QueryResult(columns: [], rows: [], totalRows: 0, elapsedMs: 0, message: "OK") }
        let ms = Double.random(in: 6...48).rounded()
        if lower.contains("bookigns") { throw ServiceError("ERROR: relation \"bookigns\" does not exist\nLINE 1: select * from bookigns limit 10;\n                      ^") }
        if lower.hasPrefix("explain") {
            let plan = ["Seq Scan on audit_log  (cost=0.00..18334.00 rows=2140 width=96) (actual time=0.021..231.8 rows=2088 loops=1)",
                        "  Filter: (created_at > (now() - '1 day'::interval))",
                        "  Rows Removed by Filter: 768912",
                        "Planning Time: 0.118 ms", "Execution Time: 233.204 ms"]
            return QueryResult(columns: [DBColumn(name: "QUERY PLAN", type: "text")], rows: plan.map { [$0] }, totalRows: plan.count, elapsedMs: 233)
        }
        if lower.hasPrefix("update") || lower.hasPrefix("insert") || lower.hasPrefix("delete") {
            return QueryResult(columns: [], rows: [], totalRows: 0, elapsedMs: 6, message: "1 row affected")
        }
        if lower.contains("group by u.plan") || lower.contains("as buyers") {
            let cols = [DBColumn(name: "plan", type: "text"), DBColumn(name: "buyers", type: "bigint"), DBColumn(name: "revenue", type: "numeric")]
            let rows: [[String?]] = [["enterprise", "212", "48210.00"], ["team", "640", "31877.50"], ["pro", "1408", "22940.25"], ["free", "96", "1104.00"]]
            return QueryResult(columns: cols, rows: rows, totalRows: 4, elapsedMs: 38)
        }
        if lower.contains("group by status") {
            return QueryResult(columns: [DBColumn(name: "status", type: "text"), DBColumn(name: "count", type: "bigint")],
                               rows: [["confirmed", "71204"], ["pending", "12988"], ["cancelled", "9410"], ["refunded", "2398"]], totalRows: 4, elapsedMs: 42)
        }
        if lower.hasPrefix("select") || lower.hasPrefix("with") {
            let tables = Self.tables(for: c).values.flatMap { $0 }
            let table = tables.first { lower.contains("from \($0.name)") || lower.contains("from public.\($0.name)") }
            guard let table else {
                if lower.contains(" from ") { throw ServiceError("ERROR: relation does not exist") }
                return QueryResult(columns: [DBColumn(name: "?column?", type: "integer")], rows: [["1"]], totalRows: 1, elapsedMs: 1)
            }
            var limit = 50
            if let r = lower.range(of: #"limit\s+(\d+)"#, options: .regularExpression) {
                limit = Int(lower[r].split(separator: " ").last ?? "50") ?? 50
            }
            let cols = Self.columns(for: table.name)
            let n = min(limit, table.rowEstimate ?? 50, 10_000)
            return QueryResult(columns: cols, rows: (0..<n).map { Self.row(table: table.name, index: $0) }, totalRows: n, elapsedMs: ms)
        }
        throw ServiceError("ERROR: syntax error at or near \"\(s.split(separator: " ").first ?? "")\"")
    }
}

// MARK: - Docker

final class MockDockerService: DockerService {
    var containers: [DockerTarget] = MockData.docker

    func list(hosts: [SSHHost]) async throws -> [DockerTarget] {
        await simulatedDelay(0.2)
        return containers
    }

    func inventory(host: SSHHost?) async throws -> DockerInventory {
        await simulatedDelay(0.2)
        let mine = containers.filter { $0.hostID == host?.id }
        let projects = Array(Set(mine.map(\.composeProject).filter { !$0.isEmpty })).sorted()
        return DockerInventory(
            stacks: projects.map { p in
                let running = mine.filter { $0.composeProject == p && $0.state == .running }.count
                return ComposeStack(id: ComposeStack.makeID(p, hostID: host?.id), name: p, hostID: host?.id,
                                    status: running > 0 ? "running(\(running))" : "exited", configFiles: ["~/Developer/\(p)/compose.yaml"], isSample: true)
            },
            networks: [DockerNetwork(id: "bridge", name: "bridge", driver: "bridge", scope: "local", composeProject: "", hostID: host?.id)]
                + projects.map { DockerNetwork(id: "\($0)_default", name: "\($0)_default", driver: "bridge", scope: "local", composeProject: $0, hostID: host?.id) },
            volumes: projects.map { DockerVolume(name: "\($0)_pgdata", driver: "local", composeProject: $0, hostID: host?.id) },
            images: mine.map { DockerImage(id: $0.image, repository: $0.image.components(separatedBy: ":").first ?? $0.image,
                                           tag: $0.image.components(separatedBy: ":").dropFirst().first ?? "latest", size: "–", created: "", hostID: host?.id) })
    }

    func compose(_ action: ComposeAction, _ stack: ComposeStack, host: SSHHost?) async throws {
        await simulatedDelay(0.8)
        for i in containers.indices where containers[i].composeProject == stack.name && containers[i].hostID == stack.hostID {
            containers[i].state = action == .up || action == .restart ? .running : (action == .pull ? containers[i].state : .exited)
        }
    }

    func composeLogsCommand(_ stack: ComposeStack, host: SSHHost?) -> String { "docker compose -p \(stack.name) logs -f" }

    /// Canned output so the sample workspace's detail views have something to show.
    func run(_ args: [String], host: SSHHost?, timeout: TimeInterval) async throws -> String {
        await simulatedDelay(0.2)
        if args.first == "stats" {
            return #"{"CPUPerc":"1.20%","MemUsage":"84MiB / 7.6GiB","MemPerc":"1.08%","NetIO":"1.2MB / 800kB","BlockIO":"0B / 4.1MB","PIDs":"12"}"#
        }
        if args.contains("inspect"), let name = args.last {
            let c = containers.first { $0.name == name }
            return """
            [{"Id":"3f9a1c0d2b7e","Name":"/\(name)","Created":"2026-10-27T09:12:00Z","State":{"Status":"\(c?.state.rawValue ?? "running")","StartedAt":"2026-10-27T09:12:03Z","RestartCount":0},
              "Config":{"Image":"\(c?.image ?? "postgres:16")","Cmd":["docker-entrypoint.sh","postgres"],"WorkingDir":"/","Env":["POSTGRES_USER=atlas","POSTGRES_PASSWORD=secret","PGDATA=/var/lib/postgresql/data"],
                        "Labels":{"com.docker.compose.project":"\(c?.composeProject ?? "")","com.docker.compose.service":"\(c?.composeService ?? name)"}},
              "NetworkSettings":{"Ports":{"5432/tcp":[{"HostIp":"0.0.0.0","HostPort":"5432"}]},"Networks":{"atlas-web_default":{"IPAddress":"172.18.0.2"}}},
              "Mounts":[{"Type":"volume","Name":"atlas-web_pgdata","Source":"/var/lib/docker/volumes/atlas-web_pgdata/_data","Destination":"/var/lib/postgresql/data","RW":true}],
              "Driver":"bridge","Scope":"local","Mountpoint":"/var/lib/docker/volumes/\(name)/_data","IPAM":{"Config":[{"Subnet":"172.18.0.0/16","Gateway":"172.18.0.1"}]},
              "Containers":{"a1":{"Name":"db","IPv4Address":"172.18.0.2/16"}},"RepoTags":["\(name)"],"Size":412000000,"Architecture":"arm64","Os":"linux"}]
            """
        }
        if args.first == "ps" { return containers.prefix(2).map(\.name).joined(separator: "\n") }
        return ""
    }

    func perform(_ action: DockerAction, on c: DockerTarget, host: SSHHost?) async throws -> DockerTarget {
        await simulatedDelay(0.8)
        guard let i = containers.firstIndex(where: { $0.id == c.id }) else { throw ServiceError("No such container: \(c.name)") }
        switch action {
        case .start, .restart:
            containers[i].state = .running
            containers[i].startedAt = Date()
        case .stop:
            containers[i].state = .exited
            containers[i].startedAt = nil
            containers[i].exitCode = 0
        }
        return containers[i]
    }

    func logs(_ c: DockerTarget, host: SSHHost?) async throws -> [String] {
        await simulatedDelay(0.2)
        switch c.name {
        case "db": return ["2026-10-27 06:01:12.401 UTC [1] LOG:  database system is ready to accept connections", "2026-10-27 08:40:55.118 UTC [88] LOG:  checkpoint complete: wrote 412 buffers (2.5%)"]
        case "redis": return ["1:M 27 Oct 2026 06:01:12.210 * Ready to accept connections tcp", "1:M 27 Oct 2026 08:31:02.004 * 100 changes in 300 seconds. Saving..."]
        case "queue-worker": return ["[worker] processed 1,204 jobs", "[worker] shutting down (SIGTERM)", "exited with code 0"]
        default: return ["{\"level\":\"info\",\"msg\":\"listening\",\"addr\":\":8080\"}", "{\"level\":\"info\",\"msg\":\"request\",\"path\":\"/v1/bookings\",\"status\":200,\"ms\":18}"]
        }
    }

    func shellCommand(_ c: DockerTarget, host: SSHHost?) -> String { LiveDockerService.shell(c, host: host) }
    func followLogsCommand(_ c: DockerTarget, host: SSHHost?) -> String { LiveDockerService.follow(c, host: host) }
}
