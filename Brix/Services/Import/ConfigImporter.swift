import Foundation

/// A host or database found in another tool's settings, offered for import.
struct ImportCandidate: Identifiable {
    enum Item {
        case host(SSHHost)
        /// `tunnelRef` is the importer's key of the SSH host to tunnel through.
        case database(DatabaseConnection, password: String?, tunnelRef: String?)
    }
    var id: String
    var item: Item
    var source: String
    /// Key used to resolve tunnels (JetBrains SSH config id); nil otherwise.
    var ref: String?
}

/// Reads SSH hosts and database connections from JetBrains IDEs, VS Code
/// (SQLTools, Remote-SSH) and ~/.ssh/config. Read-only: never connects.
enum ConfigImporter {
    // MARK: ~/.ssh/config

    /// Concrete Host blocks. Wildcards and git-hosting aliases are skipped.
    /// ponytail: `Include` and `Match` are ignored; follow them if people ask.
    static func sshConfig(_ text: String) -> [SSHHost] {
        var out: [SSHHost] = []
        var alias: String?
        var fields: [String: String] = [:]
        func flush() {
            defer { alias = nil; fields = [:] }
            guard let a = alias, !a.contains("*"), !a.contains("?"), !a.hasPrefix("!") else { return }
            let host = fields["hostname"] ?? a
            if ["github.com", "gitlab.com", "bitbucket.org", "ssh.dev.azure.com"].contains(host.lowercased()) { return }
            let key = fields["identityfile"]
            out.append(SSHHost(id: "h-\(UUID().uuidString.prefix(8).lowercased())", name: a, host: host, user: fields["user"] ?? NSUserName(),
                               port: fields["port"].flatMap(Int.init) ?? 22, auth: key == nil ? .agent : .key,
                               keyPath: key ?? "~/.ssh/id_ed25519", tag: EnvTag.guess(a + " " + host)))
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"="))
            if key == "host" || key == "match" {
                flush()
                // A multi-alias line takes the first name.
                if key == "host" { alias = value.split(separator: " ").first.map(String.init) }
            } else if alias != nil, fields[key] == nil {
                fields[key] = value
            }
        }
        flush()
        return out
    }

    // MARK: JetBrains

    /// options/sshConfigs.xml (app level) or .idea/sshConfigs.xml. Returns the
    /// JetBrains config id with each host so data sources can tunnel through it.
    static func jetbrainsSSH(_ data: Data) -> [(ref: String, host: SSHHost)] {
        guard let doc = try? XMLDocument(data: data), let nodes = try? doc.nodes(forXPath: "//sshConfig") else { return [] }
        return nodes.compactMap { n in
            guard let e = n as? XMLElement, let host = e.attribute(forName: "host")?.stringValue, !host.isEmpty else { return nil }
            let attr = { (k: String) in e.attribute(forName: k)?.stringValue }
            let user = attr("username") ?? NSUserName()
            let port = attr("port").flatMap(Int.init) ?? 22
            let key = attr("keyPath")?.replacingOccurrences(of: "$USER_HOME$", with: "~")
            let auth: SSHAuth = attr("authType") == "PASSWORD" ? .password : (key != nil ? .key : .agent)
            let name = attr("customName").flatMap { $0.isEmpty ? nil : $0 } ?? "\(user)@\(host)"
            let h = SSHHost(id: "h-\(UUID().uuidString.prefix(8).lowercased())", name: name, host: host, user: user, port: port,
                            auth: auth, keyPath: key ?? "~/.ssh/id_ed25519", tag: EnvTag.guess(name + " " + host))
            return (attr("id") ?? h.id, h)
        }
    }

    /// .idea/dataSources.xml plus dataSources.local.xml (user name, SSH tunnel).
    /// Passwords live in the IDE's own secure storage and are not read.
    static func jetbrainsDataSources(main: Data, local: Data?) -> [(db: DatabaseConnection, tunnelRef: String?)] {
        guard let doc = try? XMLDocument(data: main), let nodes = try? doc.nodes(forXPath: "//data-source") else { return [] }
        let localDoc = local.flatMap { try? XMLDocument(data: $0) }
        return nodes.compactMap { n in
            guard let e = n as? XMLElement,
                  let url = (try? e.nodes(forXPath: "jdbc-url").first?.stringValue) ?? nil,
                  var db = parseJDBC(url) else { return nil }
            let uuid = e.attribute(forName: "uuid")?.stringValue ?? ""
            db.name = e.attribute(forName: "name")?.stringValue ?? db.name
            db.tag = EnvTag.guess(db.name + " " + db.host)
            var tunnel: String?
            if let l = localDoc, !uuid.isEmpty, let le = (try? l.nodes(forXPath: "//data-source[@uuid='\(uuid)']"))?.first {
                if let u = (try? le.nodes(forXPath: "user-name").first?.stringValue) ?? nil { db.user = u }
                let enabled = (try? le.nodes(forXPath: "ssh-properties/enabled").first?.stringValue) ?? nil
                if enabled == "true" { tunnel = (try? le.nodes(forXPath: "ssh-properties/ssh-config-id").first?.stringValue) ?? nil }
            }
            return (db, tunnel)
        }
    }

    /// jdbc:postgresql://host:5432/db, jdbc:mysql://…, jdbc:mariadb://…, jdbc:sqlite:/path
    static func parseJDBC(_ jdbc: String) -> DatabaseConnection? {
        guard jdbc.hasPrefix("jdbc:") else { return nil }
        let rest = String(jdbc.dropFirst(5))
        let id = "db-\(UUID().uuidString.prefix(8).lowercased())"
        if rest.hasPrefix("sqlite:") {
            let path = String(rest.dropFirst(7))
            var d = DatabaseConnection(id: id, name: (path as NSString).lastPathComponent, kind: .sqlite, tag: .local)
            d.filePath = path
            return d
        }
        guard let c = URLComponents(string: rest), let scheme = c.scheme else { return nil }
        let kind: DBKind
        switch scheme {
        case "postgresql", "postgres": kind = .postgres
        case "mysql", "mariadb": kind = .mysql
        default: return nil
        }
        var d = DatabaseConnection(id: id, name: "", kind: kind, tag: .dev)
        d.host = c.host ?? "localhost"
        d.port = c.port ?? kind.defaultPort
        d.database = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        d.user = c.user ?? c.queryItems?.first { $0.name == "user" }?.value ?? ""
        d.name = d.database.isEmpty ? d.host : "\(d.database)@\(d.host)"
        return d
    }

    // MARK: VS Code

    /// `sqltools.connections` from a settings.json (comments allowed).
    static func vscodeSQLTools(_ jsonc: String) -> [(db: DatabaseConnection, password: String?)] {
        guard let data = stripJSONC(jsonc).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conns = obj["sqltools.connections"] as? [[String: Any]] else { return [] }
        return conns.compactMap { c in
            let driver = (c["driver"] as? String ?? "").lowercased()
            let kind: DBKind
            if driver.contains("postgres") { kind = .postgres }
            else if driver.contains("mysql") || driver.contains("maria") { kind = .mysql }
            else if driver.contains("sqlite") { kind = .sqlite }
            else { return nil }
            let name = c["name"] as? String ?? driver
            var d = DatabaseConnection(id: "db-\(UUID().uuidString.prefix(8).lowercased())", name: name, kind: kind, tag: .dev)
            if kind == .sqlite {
                d.filePath = c["database"] as? String ?? ""
                d.tag = .local
            } else {
                d.host = c["server"] as? String ?? "localhost"
                d.port = (c["port"] as? NSNumber)?.intValue ?? kind.defaultPort
                d.database = c["database"] as? String ?? ""
                d.user = c["username"] as? String ?? ""
                d.tag = EnvTag.guess(name + " " + d.host)
            }
            return (d, (c["password"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// `remote.SSH.configFile`, when VS Code points Remote-SSH at another file.
    static func vscodeSSHConfigPath(_ jsonc: String) -> String? {
        guard let data = stripJSONC(jsonc).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["remote.SSH.configFile"] as? String
    }

    /// Removes // and /* */ comments outside strings, and trailing commas.
    static func stripJSONC(_ s: String) -> String {
        var out = ""
        var chars = Array(s)[...]
        var inString = false
        while let ch = chars.first {
            chars = chars.dropFirst()
            if inString {
                out.append(ch)
                if ch == "\\", let next = chars.first { out.append(next); chars = chars.dropFirst() }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
                out.append(ch)
            } else if ch == "/", chars.first == "/" {
                while let c = chars.first, c != "\n" { chars = chars.dropFirst() }
            } else if ch == "/", chars.first == "*" {
                chars = chars.dropFirst()
                while let c = chars.first, !(c == "*" && chars.dropFirst().first == "/") { chars = chars.dropFirst() }
                chars = chars.dropFirst(2)
            } else {
                out.append(ch)
            }
        }
        return out.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
    }

    /// "PhpStorm2026.2" → "PhpStorm 2026.2".
    static func prettyIDE(_ dir: String) -> String {
        dir.replacingOccurrences(of: #"([A-Za-z])(\d)"#, with: "$1 $2", options: .regularExpression)
    }

    // MARK: Scan

    /// Everything importable on this Mac. `projectFolders` are checked for
    /// .idea and .vscode settings.
    static func scan(home: String = NSHomeDirectory(), projectFolders: [URL]) -> [ImportCandidate] {
        var out: [ImportCandidate] = []
        let fm = FileManager.default
        func read(_ path: String) -> Data? { fm.contents(atPath: path) }

        // JetBrains app-level SSH configs: newest version of each product wins.
        let jb = home + "/Library/Application Support/JetBrains"
        let products = ((try? fm.contentsOfDirectory(atPath: jb)) ?? [])
            .filter { fm.fileExists(atPath: "\(jb)/\($0)/options/sshConfigs.xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        var seenProducts = Set<String>()
        for dir in products {
            let product = dir.replacingOccurrences(of: #"\d+(\.\d+)*$"#, with: "", options: .regularExpression)
            guard seenProducts.insert(product).inserted, let data = read("\(jb)/\(dir)/options/sshConfigs.xml") else { continue }
            for (ref, h) in jetbrainsSSH(data) {
                out.append(ImportCandidate(id: "jb-\(ref)", item: .host(h), source: prettyIDE(dir), ref: ref))
            }
        }

        // ~/.ssh/config (also what VS Code Remote-SSH uses), or the file VS Code points at.
        let codeSettings = ["Code", "Cursor", "VSCodium", "Windsurf"].map { home + "/Library/Application Support/\($0)/User/settings.json" }
        var sshPaths = [home + "/.ssh/config"]
        for path in codeSettings {
            if let s = read(path).flatMap({ String(data: $0, encoding: .utf8) }), let p = vscodeSSHConfigPath(s) {
                sshPaths.append((p as NSString).expandingTildeInPath)
            }
        }
        for path in Set(sshPaths) {
            guard let s = read(path).flatMap({ String(data: $0, encoding: .utf8) }) else { continue }
            let label = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
            for h in sshConfig(s) { out.append(ImportCandidate(id: "ssh-\(path)-\(h.name)", item: .host(h), source: label)) }
        }

        // VS Code family: SQLTools connections in user settings.
        for path in codeSettings {
            guard let s = read(path).flatMap({ String(data: $0, encoding: .utf8) }) else { continue }
            let app = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            for (i, (d, pw)) in vscodeSQLTools(s).enumerated() {
                out.append(ImportCandidate(id: "code-\(app)-\(i)", item: .database(d, password: pw, tunnelRef: nil), source: "\(app == "Code" ? "VS Code" : app) · SQLTools"))
            }
        }

        // Per project: .idea data sources and SSH configs, .vscode SQLTools.
        for folder in projectFolders {
            let idea = folder.appendingPathComponent(".idea")
            let label = folder.lastPathComponent
            if let data = read(idea.appendingPathComponent("sshConfigs.xml").path) {
                for (ref, h) in jetbrainsSSH(data) { out.append(ImportCandidate(id: "jbp-\(label)-\(ref)", item: .host(h), source: "JetBrains · \(label)", ref: ref)) }
            }
            if let main = read(idea.appendingPathComponent("dataSources.xml").path) {
                let local = read(idea.appendingPathComponent("dataSources.local.xml").path)
                for (i, (d, tunnel)) in jetbrainsDataSources(main: main, local: local).enumerated() {
                    out.append(ImportCandidate(id: "jbd-\(label)-\(i)", item: .database(d, password: nil, tunnelRef: tunnel), source: "JetBrains · \(label)"))
                }
            }
            if let s = read(folder.appendingPathComponent(".vscode/settings.json").path).flatMap({ String(data: $0, encoding: .utf8) }) {
                for (i, (d, pw)) in vscodeSQLTools(s).enumerated() {
                    out.append(ImportCandidate(id: "vsp-\(label)-\(i)", item: .database(d, password: pw, tunnelRef: nil), source: "VS Code · \(label)"))
                }
            }
        }
        return dedupe(out)
    }

    /// The same host or database often appears in several places; keep the first.
    static func dedupe(_ items: [ImportCandidate]) -> [ImportCandidate] {
        var seen = Set<String>()
        return items.filter { c in
            switch c.item {
            case .host(let h): seen.insert("h|\(h.host)|\(h.port)|\(h.user)").inserted
            case .database(let d, _, _): seen.insert("d|\(d.kind)|\(d.endpoint)|\(d.user)").inserted
            }
        }
    }
}
