import Foundation

/// A docker compose project ("stack"), local or on an SSH host.
struct ComposeStack: Codable, Identifiable, Hashable {
    var id: ResourceID
    var name: String
    /// nil = local Docker.
    var hostID: ResourceID?
    var status: String = ""
    var configFiles: [String] = []
    var isSample = false

    static func makeID(_ name: String, hostID: ResourceID?) -> ResourceID { "stack:\(hostID ?? "local")/\(name)" }
    var isRunning: Bool { status.hasPrefix("running") }
}

struct DockerNetwork: Identifiable, Hashable {
    var id: String
    var name: String
    var driver: String
    var scope: String
    var composeProject: String
    var hostID: ResourceID?
}

struct DockerVolume: Identifiable, Hashable {
    var id: String { "\(hostID ?? "local")/\(name)" }
    var name: String
    var driver: String
    var composeProject: String
    var hostID: ResourceID?
}

struct DockerImage: Identifiable, Hashable {
    var id: String
    var repository: String
    var tag: String
    var size: String
    var created: String
    var hostID: ResourceID?
}

enum ComposeAction: String {
    case up, down, restart, stop, pull
    var label: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .restart: "Restart"
        case .stop: "Stop"
        case .pull: "Pull"
        }
    }
}

/// Everything Docker reports for one engine (local or a host).
struct DockerInventory {
    var stacks: [ComposeStack] = []
    var networks: [DockerNetwork] = []
    var volumes: [DockerVolume] = []
    var images: [DockerImage] = []
}

enum DockerParse {
    private struct Row: Decodable {
        var Name: String?
        var Status: String?
        var ConfigFiles: String?
        var ID: String?
        var Driver: String?
        var Scope: String?
        var Labels: String?
        var Repository: String?
        var Tag: String?
        var Size: String?
        var CreatedSince: String?
    }

    private static func rows(_ out: String) -> [Row] {
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // `compose ls --format json` prints one array; the others print one object per line.
        if t.hasPrefix("["), let d = t.data(using: .utf8), let a = try? JSONDecoder().decode([Row].self, from: d) { return a }
        return t.split(separator: "\n").compactMap { try? JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
    }

    private static func label(_ labels: String?, _ key: String) -> String {
        labels?.split(separator: ",").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) } ?? ""
    }

    static func stacks(_ out: String, hostID: ResourceID?) -> [ComposeStack] {
        rows(out).compactMap { r in
            guard let n = r.Name, !n.isEmpty else { return nil }
            return ComposeStack(id: ComposeStack.makeID(n, hostID: hostID), name: n, hostID: hostID, status: r.Status ?? "",
                                configFiles: (r.ConfigFiles ?? "").split(separator: ",").map(String.init))
        }
    }

    static func networks(_ out: String, hostID: ResourceID?) -> [DockerNetwork] {
        rows(out).compactMap { r in
            guard let n = r.Name else { return nil }
            return DockerNetwork(id: "\(hostID ?? "local")/\(r.ID ?? n)", name: n, driver: r.Driver ?? "", scope: r.Scope ?? "",
                                 composeProject: label(r.Labels, "com.docker.compose.project"), hostID: hostID)
        }
    }

    static func volumes(_ out: String, hostID: ResourceID?) -> [DockerVolume] {
        rows(out).compactMap { r in
            guard let n = r.Name else { return nil }
            return DockerVolume(name: n, driver: r.Driver ?? "", composeProject: label(r.Labels, "com.docker.compose.project"), hostID: hostID)
        }
    }

    static func images(_ out: String, hostID: ResourceID?) -> [DockerImage] {
        rows(out).compactMap { r in
            guard let repo = r.Repository else { return nil }
            return DockerImage(id: "\(hostID ?? "local")/\(r.ID ?? repo)/\(r.Tag ?? "")", repository: repo, tag: r.Tag ?? "", size: r.Size ?? "",
                               created: r.CreatedSince ?? "", hostID: hostID)
        }
    }
}
