import SwiftUI

typealias ProjectID = String
typealias ResourceID = String

// MARK: - Project

struct Project: Codable, Identifiable, Hashable {
    var id: ProjectID
    var name: String
    var path: String
    var language: String
    var framework: String
    var hue: ProjectHue
    var isPinned: Bool
    var lastOpened: Date
    var defaultPreset: String = BuiltinPreset.code.rawValue
    var notes: String = ""
    var envVarNames: [String] = []
    /// Agent started by default in this project; nil uses the app default.
    var agentID: String? = nil
    /// nil means on: keep `brix.json` in the project folder up to date.
    var syncsSettingsFile: Bool? = nil
    var keepsSettingsFile: Bool { syncsSettingsFile ?? true }
    /// Sample projects are backed by mock services; real ones by live services.
    var isSample: Bool = false
    /// Optional fixed initials for the project mark.
    var mark: String? = nil
    /// An SF Symbol drawn instead of the initials.
    var iconSymbol: String? = nil
    /// An image file (relative to the project folder, or absolute) drawn instead of the initials.
    var iconPath: String? = nil
    /// "owner/repo" on GitHub; nil uses the git remote.
    var githubRepo: String? = nil
    /// The gh account that reads this repo; nil tries each signed-in account
    /// (and remembers the one that worked in `githubAccountSeen`).
    var githubAccount: String? = nil
    var githubAccountSeen: String? = nil
    /// A repository inside another project's folder (frontend, backend…): shown
    /// nested under that project.
    var parentID: ProjectID? = nil

    var initials: String {
        if let mark, !mark.isEmpty { return mark }
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " || $0 == "." })
        let letters = parts.prefix(2).compactMap(\.first)
        let s = letters.count >= 2 ? String(letters) : String(name.prefix(2))
        return s.uppercased()
    }

    var expandedPath: String { (path as NSString).expandingTildeInPath }
    var url: URL { URL(fileURLWithPath: expandedPath, isDirectory: true) }
}

// MARK: - SSH

enum SSHAuth: String, Codable, CaseIterable, Identifiable {
    case key, agent, password
    var id: String { rawValue }
    var label: String {
        switch self {
        case .key: "SSH Key"
        case .agent: "SSH Agent"
        case .password: "Password"
        }
    }
}

struct SSHHost: Codable, Identifiable, Hashable {
    var id: ResourceID
    var name: String
    var host: String
    var user: String
    var port: Int = 22
    var auth: SSHAuth = .key
    /// Path reference only. The key itself never leaves ~/.ssh.
    var keyPath: String = "~/.ssh/id_ed25519"
    var tag: EnvTag
    var notes: String = ""
    var os: String = ""
    var lastConnected: Date? = nil
    var isSample: Bool = false

    var address: String { "\(user)@\(host)\(port == 22 ? "" : ":\(port)")" }
    var sshCommand: String {
        var parts = ["ssh"]
        if port != 22 { parts += ["-p", "\(port)"] }
        if auth == .key, !keyPath.isEmpty { parts += ["-i", keyPath] }
        parts.append("\(user)@\(host)")
        return parts.joined(separator: " ")
    }
}

// MARK: - Database

enum DBKind: String, Codable, CaseIterable, Identifiable {
    case postgres, mysql, sqlite
    var id: String { rawValue }
    var label: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .sqlite: "SQLite"
        }
    }
    var badge: String {
        switch self {
        case .postgres: "PG"
        case .mysql: "MY"
        case .sqlite: "SQ"
        }
    }
    var defaultPort: Int {
        switch self {
        case .postgres: 5432
        case .mysql: 3306
        case .sqlite: 0
        }
    }
    var color: Color {
        switch self {
        case .postgres: Theme.pgBlue
        case .mysql: Theme.orange
        case .sqlite: Theme.cyan
        }
    }
}

/// A database product. Each speaks one of the three protocols Brix connects
/// with (PostgreSQL, MySQL, SQLite) and brings its own defaults and logo.
enum DBFlavor: String, Codable, CaseIterable, Identifiable {
    case postgres, mysql, mariadb, sqlite, cockroach, timescale, supabase, neon, redshift, tidb, planetscale
    var id: String { rawValue }

    var label: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .sqlite: "SQLite"
        case .cockroach: "CockroachDB"
        case .timescale: "TimescaleDB"
        case .supabase: "Supabase"
        case .neon: "Neon"
        case .redshift: "Redshift"
        case .tidb: "TiDB"
        case .planetscale: "PlanetScale"
        }
    }

    var kind: DBKind {
        switch self {
        case .mysql, .mariadb, .tidb, .planetscale: .mysql
        case .sqlite: .sqlite
        default: .postgres
        }
    }

    var defaultPort: Int {
        switch self {
        case .cockroach: 26257
        case .redshift: 5439
        case .tidb: 4000
        case .supabase: 6543
        default: kind.defaultPort
        }
    }

    /// Hosted services insist on TLS.
    var defaultSSL: SSLMode {
        switch self {
        case .supabase, .neon, .redshift, .planetscale, .cockroach: .require
        default: .prefer
        }
    }

    var hostHint: String {
        switch self {
        case .supabase: "aws-0-eu-west-2.pooler.supabase.com"
        case .neon: "ep-cool-name-123456.eu-west-2.aws.neon.tech"
        case .redshift: "cluster.abc123.eu-west-2.redshift.amazonaws.com"
        case .planetscale: "aws.connect.psdb.cloud"
        case .tidb: "gateway01.eu-central-1.prod.aws.tidbcloud.com"
        default: "localhost"
        }
    }

    var logo: String? {
        switch self {
        case .redshift: nil
        default: "Logos/\(rawValue)"
        }
    }

    var color: Color {
        switch self {
        case .postgres: Color(hex: 0x4F8BD1)
        case .mysql: Color(hex: 0xF29111)
        case .mariadb: Color(hex: 0xC0765A)
        case .sqlite: Color(hex: 0x44A8E0)
        case .cockroach: Color(hex: 0x6933FF)
        case .timescale: Color(hex: 0xFDB515)
        case .supabase: Color(hex: 0x3FCF8E)
        case .neon: Color(hex: 0x00E599)
        case .redshift: Color(hex: 0x8C4FFF)
        case .tidb: Color(hex: 0xE30C34)
        case .planetscale: Theme.text
        }
    }
}

/// What agents may do with a database, enforced by Brix's agent gateway.
enum AgentDBAccess: String, Codable, CaseIterable, Identifiable, Comparable {
    static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    case none, schema, read, write
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "No access"
        case .schema: "Schema only"
        case .read: "Read data"
        case .write: "Read & write"
        }
    }
    var detail: String {
        switch self {
        case .none: "Agents can’t see this database"
        case .schema: "Tables and columns, no rows"
        case .read: "SELECT queries, sensitive columns masked"
        case .write: "Writes always ask you first"
        }
    }
}

/// How Brix reaches a database server.
enum DBRoute: String, Codable, CaseIterable, Identifiable {
    case direct, ssh, docker
    var id: String { rawValue }
    var label: String {
        switch self {
        case .direct: "Direct"
        case .ssh: "SSH tunnel"
        case .docker: "Docker"
        }
    }
}

enum SSLMode: String, Codable, CaseIterable, Identifiable {
    case disable, prefer, require
    var id: String { rawValue }
}

struct DatabaseConnection: Codable, Identifiable, Hashable {
    var id: ResourceID
    var name: String
    var kind: DBKind
    var host: String = "localhost"
    var port: Int = 5432
    var database: String = ""
    var user: String = ""
    var filePath: String = ""
    var sslMode: SSLMode = .prefer
    var tunnelHostID: ResourceID? = nil
    var tag: EnvTag
    var readOnly: Bool = false
    var lastUsed: Date? = nil
    var isSample: Bool = false
    /// Set only on a transient copy after the user confirmed a write to a
    /// read-only or production database. Never persisted as true.
    var writeUnlocked: Bool = false
    /// Server version from the first successful connection ("PostgreSQL 16.2", "MariaDB 10.11").
    var serverVersion: String = ""
    /// The product chosen when the connection was made; nil reads it from `kind`.
    var flavor: DBFlavor? = nil
    /// Seconds to wait for the server before giving up.
    var connectTimeout: Int? = nil
    /// A note for people (and agents) on what this database is.
    var notes: String = ""
    /// What agents may do through `brix-db`.
    /// Schema only unless the user chooses more in the connection form.
    var agentAccess: AgentDBAccess = .schema
    /// How Brix reaches the server.
    var route: DBRoute = .direct
    /// For `.docker`: the container whose published port is used.
    var dockerContainer: String? = nil
    /// Seconds a query may run; nil leaves the server's own limit.
    var queryTimeout: Int? = nil
    /// SQL run right after connecting (search_path, time zone…).
    var startupSQL: String = ""
    /// A colour for the connection in lists; nil uses the product's.
    var colour: ProjectHue? = nil

    var endpoint: String {
        kind == .sqlite ? filePath : "\(host):\(port)/\(database)"
    }
    /// Fields from a connection URL such as `postgres://user:pass@host:5432/db?sslmode=require`.
    struct URLParts: Equatable {
        var flavor: DBFlavor?
        var host = ""
        var port: Int?
        var database = ""
        var user = ""
        var password = ""
        var ssl: SSLMode?
    }

    static func parse(url raw: String) -> URLParts? {
        guard let c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = c.scheme?.lowercased() else { return nil }
        var p = URLParts()
        switch scheme {
        case "postgres", "postgresql": p.flavor = .postgres
        case "mysql", "mysql2": p.flavor = .mysql
        case "mariadb": p.flavor = .mariadb
        case "cockroachdb": p.flavor = .cockroach
        case "redshift": p.flavor = .redshift
        case "sqlite", "file": p.flavor = .sqlite
        default: return nil
        }
        let host = c.host ?? ""
        if host.hasSuffix(".supabase.com") || host.hasSuffix(".supabase.co") { p.flavor = .supabase }
        if host.hasSuffix(".neon.tech") { p.flavor = .neon }
        if host.hasSuffix(".psdb.cloud") { p.flavor = .planetscale }
        if host.contains("tidbcloud.com") { p.flavor = .tidb }
        if host.contains(".redshift.amazonaws.com") { p.flavor = .redshift }
        p.host = host
        p.port = c.port
        // URLComponents already decodes these; decoding again would mangle a literal "%41".
        p.user = c.user ?? ""
        p.password = c.password ?? ""
        p.database = String(c.path.drop { $0 == "/" })
        let q = Dictionary((c.queryItems ?? []).map { ($0.name.lowercased(), ($0.value ?? "").lowercased()) }, uniquingKeysWith: { a, _ in a })
        switch q["sslmode"] ?? q["ssl-mode"] ?? q["ssl"] {
        case "disable", "false", "0": p.ssl = .disable
        case "require", "verify-ca", "verify-full", "true", "1", "required": p.ssl = .require
        case "prefer", "allow", "preferred": p.ssl = .prefer
        default: break
        }
        return p
    }

    /// Production databases are read-only unless the user explicitly confirms.
    var effectiveReadOnly: Bool { readOnly || tag.isProduction }
}

extension Project {
    /// Fields added over time load with defaults when an older file lacks them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ProjectID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        language = (try? c.decodeIfPresent(String.self, forKey: .language)) ?? ""
        framework = (try? c.decodeIfPresent(String.self, forKey: .framework)) ?? ""
        hue = (try? c.decodeIfPresent(ProjectHue.self, forKey: .hue)) ?? .violet
        isPinned = (try? c.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? false
        lastOpened = (try? c.decodeIfPresent(Date.self, forKey: .lastOpened)) ?? .distantPast
        defaultPreset = (try? c.decodeIfPresent(String.self, forKey: .defaultPreset)) ?? BuiltinPreset.code.rawValue
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        envVarNames = (try? c.decodeIfPresent([String].self, forKey: .envVarNames)) ?? []
        agentID = try? c.decodeIfPresent(String.self, forKey: .agentID)
        syncsSettingsFile = try? c.decodeIfPresent(Bool.self, forKey: .syncsSettingsFile)
        isSample = (try? c.decodeIfPresent(Bool.self, forKey: .isSample)) ?? false
        mark = try? c.decodeIfPresent(String.self, forKey: .mark)
        iconSymbol = try? c.decodeIfPresent(String.self, forKey: .iconSymbol)
        iconPath = try? c.decodeIfPresent(String.self, forKey: .iconPath)
        githubRepo = try? c.decodeIfPresent(String.self, forKey: .githubRepo)
        githubAccount = try? c.decodeIfPresent(String.self, forKey: .githubAccount)
        githubAccountSeen = try? c.decodeIfPresent(String.self, forKey: .githubAccountSeen)
        parentID = try? c.decodeIfPresent(ProjectID.self, forKey: .parentID)
    }
}

extension SSHHost {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ResourceID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        user = (try? c.decodeIfPresent(String.self, forKey: .user)) ?? ""
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? 22
        auth = (try? c.decodeIfPresent(SSHAuth.self, forKey: .auth)) ?? .key
        keyPath = (try? c.decodeIfPresent(String.self, forKey: .keyPath)) ?? "~/.ssh/id_ed25519"
        tag = (try? c.decodeIfPresent(EnvTag.self, forKey: .tag)) ?? .dev
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        os = (try? c.decodeIfPresent(String.self, forKey: .os)) ?? ""
        lastConnected = try? c.decodeIfPresent(Date.self, forKey: .lastConnected)
        isSample = (try? c.decodeIfPresent(Bool.self, forKey: .isSample)) ?? false
    }
}

extension DatabaseConnection {
    /// Every field but the identity is optional on disk: a connection saved by
    /// an older (or newer) Brix still loads, with defaults for what it lacks.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ResourceID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(DBKind.self, forKey: .kind)
        tag = (try? c.decodeIfPresent(EnvTag.self, forKey: .tag)) ?? .dev
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? "localhost"
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? kind.defaultPort
        database = (try? c.decodeIfPresent(String.self, forKey: .database)) ?? ""
        user = (try? c.decodeIfPresent(String.self, forKey: .user)) ?? ""
        filePath = (try? c.decodeIfPresent(String.self, forKey: .filePath)) ?? ""
        sslMode = (try? c.decodeIfPresent(SSLMode.self, forKey: .sslMode)) ?? .prefer
        tunnelHostID = try? c.decodeIfPresent(ResourceID.self, forKey: .tunnelHostID)
        readOnly = (try? c.decodeIfPresent(Bool.self, forKey: .readOnly)) ?? false
        lastUsed = try? c.decodeIfPresent(Date.self, forKey: .lastUsed)
        isSample = (try? c.decodeIfPresent(Bool.self, forKey: .isSample)) ?? false
        writeUnlocked = false
        serverVersion = (try? c.decodeIfPresent(String.self, forKey: .serverVersion)) ?? ""
        flavor = try? c.decodeIfPresent(DBFlavor.self, forKey: .flavor)
        connectTimeout = try? c.decodeIfPresent(Int.self, forKey: .connectTimeout)
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        agentAccess = (try? c.decodeIfPresent(AgentDBAccess.self, forKey: .agentAccess)) ?? .schema
        route = (try? c.decodeIfPresent(DBRoute.self, forKey: .route)) ?? .direct
        dockerContainer = try? c.decodeIfPresent(String.self, forKey: .dockerContainer)
        queryTimeout = try? c.decodeIfPresent(Int.self, forKey: .queryTimeout)
        startupSQL = (try? c.decodeIfPresent(String.self, forKey: .startupSQL)) ?? ""
        colour = try? c.decodeIfPresent(ProjectHue.self, forKey: .colour)
    }
}

// MARK: - Docker

enum ContainerState: String, Codable {
    case running, exited, restarting, paused
    var color: Color {
        switch self {
        case .running: Theme.green
        case .restarting: Theme.amber
        case .paused: Theme.amber
        case .exited: Theme.disabled
        }
    }
}

struct DockerTarget: Codable, Identifiable, Hashable {
    var id: ResourceID
    var name: String
    var image: String
    var ports: String
    /// nil = local Docker; otherwise the SSH host that runs it.
    var hostID: ResourceID?
    var composeProject: String = ""
    var state: ContainerState
    var startedAt: Date?
    var exitCode: Int = 0
    var isSample: Bool = false
    /// Docker's own status line ("Up 2 hours") for live containers.
    var statusText: String = ""
    var composeService: String = ""

    var uptimeText: String {
        if !statusText.isEmpty { return statusText }
        switch state {
        case .running:
            guard let s = startedAt else { return "Up" }
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            return "Up " + f.localizedString(for: s, relativeTo: Date()).replacingOccurrences(of: " ago", with: "")
        case .exited: return "Exited (\(exitCode))"
        case .restarting: return "Restarting"
        case .paused: return "Paused"
        }
    }
}

// MARK: - Links (many-to-many)

enum ResourceKind: String, Codable, CaseIterable {
    case host, database, docker, stack
}

struct LinkPair: Codable, Hashable {
    var project: ProjectID
    var resource: ResourceID
    var kind: ResourceKind
}

struct ProjectLinks: Codable, Equatable {
    var pairs: Set<LinkPair> = []

    func isLinked(_ project: ProjectID, _ resource: ResourceID) -> Bool {
        pairs.contains { $0.project == project && $0.resource == resource }
    }

    mutating func link(_ project: ProjectID, _ resource: ResourceID, kind: ResourceKind) {
        pairs.insert(LinkPair(project: project, resource: resource, kind: kind))
    }

    mutating func unlink(_ project: ProjectID, _ resource: ResourceID) {
        pairs = pairs.filter { !($0.project == project && $0.resource == resource) }
    }

    mutating func set(_ project: ProjectID, _ resource: ResourceID, kind: ResourceKind, linked: Bool) {
        if linked { link(project, resource, kind: kind) } else { unlink(project, resource) }
    }

    func resources(of kind: ResourceKind, for project: ProjectID) -> [ResourceID] {
        pairs.filter { $0.project == project && $0.kind == kind }.map(\.resource).sorted()
    }

    func projects(for resource: ResourceID) -> [ProjectID] {
        pairs.filter { $0.resource == resource }.map(\.project).sorted()
    }

    func count(of kind: ResourceKind, for project: ProjectID) -> Int {
        pairs.filter { $0.project == project && $0.kind == kind }.count
    }

    mutating func removeResource(_ resource: ResourceID) {
        pairs = pairs.filter { $0.resource != resource }
    }

    mutating func removeProject(_ project: ProjectID) {
        pairs = pairs.filter { $0.project != project }
    }
}

// MARK: - Connection status

enum ConnectionStatus: Equatable {
    case connected, idle, disconnected, connecting
    case error(String)

    var color: Color {
        switch self {
        case .connected: Theme.green
        case .idle: Theme.amber
        case .disconnected: Theme.offline
        case .connecting: Theme.blue
        case .error: Theme.red
        }
    }
    var label: String {
        switch self {
        case .connected: "Connected"
        case .idle: "Idle"
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .error(let m): "Error: \(m)"
        }
    }
    var isLive: Bool { self == .connected || self == .idle }
}

struct HostMetrics: Equatable {
    var cpu: Double
    var memory: Double
    var disk: Double
    var load: String
    var uptime: String
    var os: String
}

// MARK: - Files

enum GitStatus: String, Codable {
    case M, A, D, U
    var color: Color {
        switch self {
        case .M: Theme.amber
        case .A: Theme.green
        case .D: Theme.red
        case .U: Theme.cyan
        }
    }
    var name: String {
        switch self {
        case .M: "Modified"
        case .A: "Added"
        case .D: "Deleted"
        case .U: "Untracked"
        }
    }
}

struct FileNode: Identifiable, Hashable {
    var id: String { path }
    var name: String
    /// Path relative to the project root, "/"-separated.
    var path: String
    var isDirectory: Bool
    var children: [FileNode]? = nil
    var gitStatus: GitStatus? = nil

    var ext: String { (name as NSString).pathExtension.lowercased() }
}

enum FileContent: Equatable {
    case text(String)
    case image(NSImage, size: CGSize)
    case binary(size: Int)
    case missing

    static func == (a: FileContent, b: FileContent) -> Bool {
        switch (a, b) {
        case (.text(let x), .text(let y)): x == y
        case (.binary(let x), .binary(let y)): x == y
        case (.missing, .missing): true
        case (.image(_, let x), .image(_, let y)): x == y
        default: false
        }
    }
}

struct FileInfo: Equatable {
    var kind: String
    var size: Int
    var lines: Int
    var encoding: String
    var modified: Date?
}

struct RecentFile: Codable, Hashable, Identifiable {
    var id: String { project + ":" + path }
    var project: ProjectID
    var path: String
    var openedAt: Date
}

// MARK: - Git

struct GitFileChange: Codable, Identifiable, Hashable {
    var id: String { (staged ? "s:" : "w:") + path }
    var path: String
    var status: GitStatus
    var add: Int
    var del: Int
    var staged: Bool

    var name: String { (path as NSString).lastPathComponent }
    var dir: String {
        let d = (path as NSString).deletingLastPathComponent
        return d
    }
}

struct GitCommit: Codable, Identifiable, Hashable {
    var id: String { hash }
    var hash: String
    var message: String
    var author: String
    var date: Date
    var files: [GitFileChange] = []
    var isPushed: Bool = true

    var short: String { String(hash.prefix(7)) }
}

struct GitBranch: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var isCurrent: Bool
    var isRemote: Bool = false
    var lastCommit: String = ""
}

struct GitRepoState: Codable, Equatable {
    var branch: String
    var ahead: Int
    var behind: Int
    var changes: [GitFileChange]
    var commits: [GitCommit]
    var branches: [GitBranch]
    var remote: String = "origin"
    var isRepo: Bool = true

    var staged: [GitFileChange] { changes.filter(\.staged) }
    var unstaged: [GitFileChange] { changes.filter { !$0.staged } }
    var changedFileCount: Int { Set(changes.map(\.path)).count }
    var isClean: Bool { changes.isEmpty }

    static let empty = GitRepoState(branch: "", ahead: 0, behind: 0, changes: [], commits: [], branches: [], isRepo: false)
}

enum DiffLineKind: String, Codable { case context, add, del, hunk }

struct DiffLine: Identifiable, Hashable {
    let id = UUID()
    var kind: DiffLineKind
    var old: Int?
    var new: Int?
    var text: String
}

struct FileDiff: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var add: Int
    var del: Int
    var lines: [DiffLine]
}

// MARK: - Terminals and agents

enum SessionKind: String, Codable {
    case shell, agent, server, logs
}

enum SessionState: String, Codable {
    case running, idle, needsInput, finished, failed
    var color: Color {
        switch self {
        case .running: Theme.green
        case .idle: Theme.disabled
        case .needsInput: Theme.amber
        case .finished: Theme.text3
        case .failed: Theme.red
        }
    }
    var label: String {
        switch self {
        case .running: "Running"
        case .idle: "Idle"
        case .needsInput: "Needs input"
        case .finished: "Finished"
        case .failed: "Failed"
        }
    }
}

/// A coloured run of text in a terminal line.
struct TermSpan: Hashable {
    var text: String
    var color: Color = Theme.body
    var bold = false

    func hash(into h: inout Hasher) { h.combine(text); h.combine(bold) }
    static func == (a: TermSpan, b: TermSpan) -> Bool { a.text == b.text && a.bold == b.bold && a.color == b.color }
}

struct TermLine: Identifiable, Hashable {
    let id = UUID()
    var spans: [TermSpan]
    var plain: String { spans.map(\.text).joined() }

    init(_ spans: [TermSpan]) { self.spans = spans }
    init(_ text: String, _ color: Color = Theme.body, bold: Bool = false) {
        self.spans = [TermSpan(text: text, color: color, bold: bold)]
    }
}

struct PlanItem: Hashable, Identifiable {
    var id: String { title }
    var title: String
    var done: Bool
}

struct FileTouch: Hashable, Identifiable {
    var id: String { path }
    var path: String
    var add: Int
    var del: Int
}

struct TerminalSession: Identifiable, Hashable {
    var id: String
    var projectID: ProjectID?
    var hostID: ResourceID?
    var title: String
    var kind: SessionKind
    var cwd: String
    var state: SessionState
    var process: String
    var startedAt: Date
    var lines: [TermLine] = []
    // Agent extras
    var plan: [PlanItem] = []
    var touched: [FileTouch] = []
    var lastOutput: String = ""
    var progress: Double = 0
    var task: String = ""
    /// Which AgentConfig started this session (agent sessions only).
    var agentID: String?
    /// The agent's own id for this conversation (Claude Code `--session-id`), for resume.
    var externalID: String?
    /// Title the agent gave the conversation, read from its transcript.
    var sessionName: String?
    var isLive: Bool = false
    /// Finished or waiting while you weren't looking at it; cleared when you do.
    var unseen = false
    /// Mock sessions loaded from the sample workspace.
    var isSampleSession: Bool = false

    var isRemote: Bool { hostID != nil }

    static func == (a: TerminalSession, b: TerminalSession) -> Bool {
        a.id == b.id && a.state == b.state && a.lines.count == b.lines.count && a.title == b.title
            && a.plan == b.plan && a.lastOutput == b.lastOutput && a.progress == b.progress
    }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Database results

struct DBColumn: Hashable, Identifiable {
    var id: String { name }
    var name: String
    var type: String
    var nullable: Bool = true
    var defaultValue: String? = nil
    var isPK = false
    var fk: String? = nil
}

struct DBIndex: Hashable, Identifiable {
    var id: String { name }
    var name: String
    var columns: [String]
    var unique: Bool
    var method: String
    var size: String
}

enum DBObjectKind: String { case table, view, function }

struct DBObject: Hashable, Identifiable {
    var id: String { schema + "." + name }
    var schema: String
    var name: String
    var kind: DBObjectKind
    var rowEstimate: Int?
}

struct DBSchemaTree: Hashable {
    var database: String
    var schemas: [String: [DBObject]]
}

/// Grid cells are strings; nil means SQL NULL.
struct QueryResult: Equatable {
    var columns: [DBColumn]
    var rows: [[String?]]
    var totalRows: Int
    var elapsedMs: Double
    var message: String? = nil
}

struct TableDetail: Equatable {
    var columns: [DBColumn]
    var indexes: [DBIndex]
    var rowEstimate: Int
    var size: String
}

struct QueryHistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var sql: String
    var connectionID: ResourceID
    var ranAt: Date
    var rows: Int
    var ms: Double
    var error: String? = nil
}

extension DatabaseConnection {
    /// What agents see of a connection: a MySQL server lists every database, but
    /// a connection set to one database shares only that one.
    func agentSchemas(_ all: [String: [DBObject]]) -> [String: [DBObject]] {
        guard kind == .mysql, !database.isEmpty else { return all }
        return all.filter { $0.key == database }
    }
}
