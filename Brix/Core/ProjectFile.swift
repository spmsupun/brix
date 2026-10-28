import Foundation

/// `<project>/brix.json`: everything Brix knows about one project
/// that isn't a secret, so it travels with the repo. Passwords stay in the
/// Keychain; hosts and databases are matched by address when loaded.
/// Every field is optional so older or hand-edited files still load.
struct ProjectFile: Codable, Equatable {
    var version: Int? = 1
    var name: String?
    var language: String?
    var framework: String?
    var hue: String?
    var mark: String?
    var iconSymbol: String?
    var iconPath: String?
    var github: String?
    var defaultPreset: String?
    var agent: String?
    var notes: String?
    var envVarNames: [String]?
    var layout: DockLayout?
    var hosts: [Host]?
    var databases: [Database]?
    var docker: [Docker]?
    var stacks: [Stack]?
    /// Compose files found in the project root, for reference.
    var composeFiles: [String]?

    struct Host: Codable, Equatable {
        var name: String
        var host: String
        var user: String
        var port: Int?
        var auth: String?
        var keyPath: String?
        var tag: String?
        var notes: String?
    }

    struct Database: Codable, Equatable {
        var name: String
        var kind: String
        var host: String?
        var port: Int?
        var database: String?
        var user: String?
        var filePath: String?
        var sslMode: String?
        /// Name of the SSH host to tunnel through (one of `hosts`).
        var tunnelHost: String?
        var tag: String?
        var readOnly: Bool?
        /// What agents may do: none, schema, read or write.
        var agentAccess: String?
    }

    struct Docker: Codable, Equatable {
        var name: String
        var image: String?
        var composeProject: String?
        var composeService: String?
        /// Name of the SSH host running it; nil for local Docker.
        var host: String?
    }

    struct Stack: Codable, Equatable {
        var name: String
        /// Name of the SSH host running it; nil for local Docker.
        var host: String?
        var configFiles: [String]?
    }

    static let relativePath = "brix.json"
    /// Where earlier builds kept it; read once, then replaced by brix.json.
    static let legacyPath = ".brix/project.json"
    static func url(for project: Project) -> URL { project.url.appendingPathComponent(relativePath) }

    static func read(_ project: Project) throws -> ProjectFile? {
        for rel in [relativePath, legacyPath] {
            let url = project.url.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) { return try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: url)) }
        }
        return nil
    }

    /// Removes the old .brix/project.json once brix.json holds the same data.
    static func removeLegacy(_ project: Project) {
        let old = project.url.appendingPathComponent(legacyPath)
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        try? FileManager.default.removeItem(at: old)
        let dir = old.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? FileManager.default.removeItem(at: dir) }
    }

    static let composeNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
}

extension SSHHost {
    var fileEntry: ProjectFile.Host {
        .init(name: name, host: host, user: user, port: port, auth: auth.rawValue, keyPath: auth == .key ? keyPath : nil, tag: tag.rawValue, notes: notes.isEmpty ? nil : notes)
    }
    init(entry e: ProjectFile.Host) {
        self.init(id: "h-\(UUID().uuidString.prefix(8).lowercased())", name: e.name, host: e.host, user: e.user, port: e.port ?? 22,
                  auth: e.auth.flatMap(SSHAuth.init) ?? .key, keyPath: e.keyPath ?? "~/.ssh/id_ed25519",
                  tag: e.tag.flatMap(EnvTag.init) ?? EnvTag.guess(e.name), notes: e.notes ?? "")
    }
    func matches(_ e: ProjectFile.Host) -> Bool { host == e.host && port == (e.port ?? 22) && user == e.user }
}

extension DatabaseConnection {
    func fileEntry(tunnelName: String?) -> ProjectFile.Database {
        .init(name: name, kind: kind.rawValue, host: kind == .sqlite ? nil : host, port: kind == .sqlite ? nil : port,
              database: kind == .sqlite ? nil : database, user: user.isEmpty ? nil : user, filePath: kind == .sqlite ? filePath : nil,
              sslMode: sslMode.rawValue, tunnelHost: tunnelName, tag: tag.rawValue, readOnly: readOnly ? true : nil,
              agentAccess: agentAccess.rawValue)
    }
    func matches(_ e: ProjectFile.Database) -> Bool {
        guard kind.rawValue == e.kind else { return false }
        if kind == .sqlite { return filePath == (e.filePath ?? "") }
        return host == (e.host ?? "localhost") && port == (e.port ?? kind.defaultPort) && database == (e.database ?? "")
    }
}

extension EnvTag {
    /// Best guess from a name or address: anything that says prod is production.
    static func guess(_ text: String) -> EnvTag {
        let t = text.lowercased()
        if t.contains("prod") || t.contains("live") { return .prod }
        if t.contains("stag") { return .stage }
        if t.contains("localhost") || t.contains("127.0.0.1") || t.contains("local") { return .local }
        return .dev
    }
}
