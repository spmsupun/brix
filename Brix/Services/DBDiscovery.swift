import Foundation
import Network

/// A connection worked out from pasted text or found on this Mac.
struct DBCandidate: Identifiable, Equatable {
    enum Source: String { case env, docker, local, sqlite, ssh, paste }
    var id: String
    var source: Source
    var name: String
    var sub: String
    var flavor: DBFlavor
    var host = "localhost"
    var port: Int?
    var database = ""
    var user = ""
    /// Kept only until the form takes it; then it goes to the Keychain.
    var password = ""
    var filePath = ""
    var ssl: SSLMode?
    var dockerContainer: String?
    var sshHostID: ResourceID?
    /// Projects whose .env named this database.
    var projects: [ProjectID] = []

    /// The fields this candidate fills, for the ✓ chips.
    var detected: [String] {
        var d = [flavor.label]
        if flavor == .sqlite {
            if !filePath.isEmpty { d.append((filePath as NSString).lastPathComponent) }
        } else {
            if !host.isEmpty { d.append("\(host):\(port ?? flavor.defaultPort)") }
            if !database.isEmpty { d.append(database) }
            if !user.isEmpty { d.append("user \(user)") }
            if !password.isEmpty { d.append("password → Keychain") }
        }
        return d
    }
}

/// Reads a connection out of whatever the user pastes.
enum DBPaste {
    static func parse(_ raw: String) -> DBCandidate? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let c = compose(text) { return c }
        if let c = command(text) { return c }
        if let c = env(text) { return c }
        if let c = url(text) { return c }
        return nil
    }

    /// `postgres://`, `mysql://`, `mariadb://`, `sqlite:`/`file:`, `libsql://`.
    static func url(_ text: String, source: DBCandidate.Source = .paste) -> DBCandidate? {
        let t = text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'\n"))
        if t.hasPrefix("libsql://") || t.hasPrefix("sqlite:") || t.hasPrefix("file:") {
            var path = t.replacingOccurrences(of: #"^(libsql|sqlite|file):(//)?"#, with: "", options: .regularExpression)
            if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
            guard !path.isEmpty, !t.hasPrefix("libsql://") else { return nil }
            return DBCandidate(id: "paste", source: source, name: (path as NSString).lastPathComponent, sub: path, flavor: .sqlite, filePath: path)
        }
        guard let p = DatabaseConnection.parse(url: t), let f = p.flavor else { return nil }
        return DBCandidate(id: "paste", source: source, name: p.database.isEmpty ? p.host : p.database, sub: "\(p.host):\(p.port ?? f.defaultPort)",
                           flavor: f, host: p.host, port: p.port, database: p.database, user: p.user, password: p.password, ssl: p.ssl)
    }

    /// `.env` text: a URL variable, or DB_HOST / DB_PORT / DB_DATABASE… (also
    /// POSTGRES_* and MYSQL_*), with `export`, quotes and comments allowed.
    static func env(_ text: String, source: DBCandidate.Source = .paste) -> DBCandidate? {
        var vars: [String: String] = [:]
        for line in text.split(separator: "\n") {
            var l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
            if l.hasPrefix("export ") { l = String(l.dropFirst(7)) }
            let key = l[..<l.firstIndex(of: "=")!].trimmingCharacters(in: .whitespaces).uppercased()
            var value = String(l[l.index(after: l.firstIndex(of: "=")!)...]).trimmingCharacters(in: .whitespaces)
            if !value.hasPrefix("\""), !value.hasPrefix("'"), let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            value = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            _ = eq
            vars[key] = value
        }
        guard !vars.isEmpty else { return nil }
        for key in ["DATABASE_URL", "DB_URL", "POSTGRES_URL", "MYSQL_URL", "PRISMA_DATABASE_URL", "DIRECT_URL"] {
            if let v = vars[key], var c = url(v, source: source) { c.sub = key + " · " + c.flavor.label.lowercased() + (c.database.isEmpty ? "" : " · " + c.database); return c }
        }
        func first(_ keys: [String]) -> String? { keys.lazy.compactMap { vars[$0] }.first { !$0.isEmpty } }
        let conn = first(["DB_CONNECTION", "DB_DRIVER", "DB_TYPE"])?.lowercased() ?? ""
        let host = first(["DB_HOST", "DATABASE_HOST", "POSTGRES_HOST", "PGHOST", "MYSQL_HOST"])
        let db = first(["DB_DATABASE", "DB_NAME", "DATABASE_NAME", "POSTGRES_DB", "PGDATABASE", "MYSQL_DATABASE"])
        guard host != nil || db != nil else { return nil }
        let isMy = conn.contains("mysql") || conn.contains("maria") || vars.keys.contains { $0.hasPrefix("MYSQL_") }
        let isLite = conn.contains("sqlite")
        let flavor: DBFlavor = isLite ? .sqlite : conn.contains("maria") ? .mariadb : isMy ? .mysql : .postgres
        if isLite {
            let path = db ?? ""
            return DBCandidate(id: "paste", source: source, name: (path as NSString).lastPathComponent, sub: "DB_DATABASE · sqlite", flavor: .sqlite, filePath: path)
        }
        return DBCandidate(id: "paste", source: source, name: db ?? host ?? "", sub: "DB_HOST · \(flavor.label.lowercased())\(db.map { " · " + $0 } ?? "")",
                           flavor: flavor, host: host ?? "localhost",
                           port: first(["DB_PORT", "DATABASE_PORT", "POSTGRES_PORT", "PGPORT", "MYSQL_PORT"]).flatMap(Int.init),
                           database: db ?? "",
                           user: first(["DB_USERNAME", "DB_USER", "DATABASE_USER", "POSTGRES_USER", "PGUSER", "MYSQL_USER"]) ?? "",
                           password: first(["DB_PASSWORD", "DATABASE_PASSWORD", "POSTGRES_PASSWORD", "PGPASSWORD", "MYSQL_PASSWORD"]) ?? "")
    }

    /// `psql -h … -p … -U … -d …` (or a URL argument) and `mysql -h … -P … -u … -p… db`.
    static func command(_ text: String) -> DBCandidate? {
        let words = shellWords(text)
        guard let tool = words.first.map({ ($0 as NSString).lastPathComponent }), ["psql", "mysql", "mariadb", "pgcli", "mycli"].contains(tool) else { return nil }
        let isPG = tool == "psql" || tool == "pgcli"
        var c = DBCandidate(id: "paste", source: .paste, name: "", sub: tool, flavor: isPG ? .postgres : (tool == "mariadb" ? .mariadb : .mysql))
        var i = 1
        func next() -> String? { i += 1; return i < words.count ? words[i] : nil }
        var positional: [String] = []
        while i < words.count {
            let w = words[i]
            switch w {
            case "-h", "--host": c.host = next() ?? c.host
            case "-p" where isPG, "--port": c.port = next().flatMap(Int.init)
            case "-P": c.port = next().flatMap(Int.init)
            case "-U", "-u", "--user", "--username": c.user = next() ?? ""
            case "-d", "--dbname", "-D", "--database": c.database = next() ?? ""
            default:
                if w.hasPrefix("--host=") { c.host = String(w.dropFirst(7)) }
                else if w.hasPrefix("--port=") { c.port = Int(w.dropFirst(7)) }
                else if w.hasPrefix("--user=") || w.hasPrefix("--username=") { c.user = String(w.split(separator: "=", maxSplits: 1)[1]) }
                else if w.hasPrefix("--password=") { c.password = String(w.dropFirst(11)) }
                else if w.hasPrefix("--dbname=") || w.hasPrefix("--database=") { c.database = String(w.split(separator: "=", maxSplits: 1)[1]) }
                else if !isPG, w.hasPrefix("-p"), w.count > 2 { c.password = String(w.dropFirst(2)) }
                else if !isPG, w.hasPrefix("-u"), w.count > 2 { c.user = String(w.dropFirst(2)) }
                else if !isPG, w.hasPrefix("-h"), w.count > 2 { c.host = String(w.dropFirst(2)) }
                else if !w.hasPrefix("-") { positional.append(w) }
            }
            i += 1
        }
        if let first = positional.first {
            if let u = url(first) { var u = u; u.sub = tool; return u }
            if c.database.isEmpty { c.database = first }
        }
        if isPG, positional.count > 1, c.user.isEmpty { c.user = positional[1] }
        c.name = c.database.isEmpty ? c.host : c.database
        return c
    }

    /// A docker-compose service: image postgres/mysql/mariadb, a published
    /// port, and POSTGRES_* / MYSQL_* environment.
    static func compose(_ text: String) -> DBCandidate? {
        let lower = text.lowercased()
        guard lower.contains("image:"), let imageLine = text.split(separator: "\n").first(where: { $0.lowercased().contains("image:") }) else { return nil }
        let image = imageLine.split(separator: ":", maxSplits: 1).dropFirst().first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) } ?? ""
        guard let flavor = flavor(image: image) else { return nil }
        var c = DBCandidate(id: "paste", source: .paste, name: "", sub: "compose · \(image)", flavor: flavor)
        // The service name: the last unindented-ish "name:" line before image.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let idx = lines.firstIndex(where: { $0.lowercased().contains("image:") }) {
            let imageIndent = lines[idx].prefix { $0 == " " }.count
            if let svc = lines[..<idx].reversed().first(where: { l in
                let ind = l.prefix { $0 == " " }.count
                return ind < imageIndent && l.trimmingCharacters(in: .whitespaces).hasSuffix(":") && !l.contains("services")
            }) { c.dockerContainer = svc.trimmingCharacters(in: .whitespaces).dropLast().description }
        }
        let inner = flavor.kind == .mysql ? 3306 : 5432
        if let r = text.range(of: #"["']?(\d+):"# + "\(inner)" + #"["']?"#, options: .regularExpression),
           let host = Int(text[r].filter(\.isNumber).dropLast("\(inner)".count)) {
            c.port = host
        } else {
            c.port = inner
        }
        var envText = ""
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "- \"'"))
            if let colon = t.range(of: ": "), !t.contains("=") {
                envText += t[..<colon.lowerBound] + "=" + t[colon.upperBound...] + "\n"
            } else if t.contains("=") {
                envText += t + "\n"
            }
        }
        if let e = env(envText) {
            c.user = e.user; c.password = e.password; c.database = e.database
        }
        if c.user.isEmpty { c.user = flavor.kind == .mysql ? "root" : "postgres" }
        if flavor.kind == .mysql, c.password.isEmpty, let rootPW = envText.split(separator: "\n").first(where: { $0.hasPrefix("MYSQL_ROOT_PASSWORD=") }) {
            c.password = String(rootPW.dropFirst("MYSQL_ROOT_PASSWORD=".count))
        }
        c.name = c.dockerContainer ?? (c.database.isEmpty ? image : c.database)
        return c
    }

    static func flavor(image: String) -> DBFlavor? {
        let i = image.lowercased()
        if i.contains("timescale") { return .timescale }
        if i.contains("postgis") || i.contains("postgres") || i.contains("supabase/postgres") { return .postgres }
        if i.contains("mariadb") { return .mariadb }
        if i.contains("mysql") { return .mysql }
        if i.contains("cockroach") { return .cockroach }
        return nil
    }

    /// Splits like a shell: quotes and backslashes.
    static func shellWords(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, escaped = false, any = false
        for ch in s {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" && quote != "'" { escaped = true; continue }
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) }; continue }
            if ch == "\"" || ch == "'" { quote = ch; any = true; continue }
            if ch.isWhitespace { if !cur.isEmpty || any { out.append(cur) }; cur = ""; any = false; continue }
            cur.append(ch)
        }
        if !cur.isEmpty || any { out.append(cur) }
        return out
    }

    /// The pasted text with the password hidden, to show back.
    static func masked(_ text: String, password: String) -> String {
        guard !password.isEmpty else { return text }
        return text.replacingOccurrences(of: password, with: "••••••")
    }
}

/// Finds databases on this Mac and in the user's projects.
enum DBDiscovery {
    /// Runs every scan; slow ones in parallel. SSH servers aren't scanned here.
    static func scan(projects: [Project]) async -> [DBCandidate] {
        async let env = Task.detached(priority: .utility) { envFiles(projects) }.value
        async let lite = Task.detached(priority: .utility) { sqliteFiles(projects) }.value
        async let docker = dockerContainers()
        async let local = localServices()
        var out: [DBCandidate] = []
        out += await env
        out += await docker
        out += await local
        out += await lite
        return out
    }

    static func envFiles(_ projects: [Project]) -> [DBCandidate] {
        var found: [String: DBCandidate] = [:]
        for p in projects where !p.isSample {
            for name in [".env", ".env.local", ".env.development", ".env.dev"] {
                let url = p.url.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8), var c = DBPaste.env(text, source: .env) else { continue }
                if c.flavor == .sqlite, !c.filePath.hasPrefix("/") { c.filePath = p.url.appendingPathComponent(c.filePath).path }
                let key = "\(c.flavor.kind)|\(c.host)|\(c.port ?? 0)|\(c.database)|\(c.filePath)"
                if var existing = found[key] {
                    existing.projects.append(p.id)
                    found[key] = existing
                    continue
                }
                c.id = "env-\(p.id)-\(name)"
                c.name = "\(p.name) / \(name)"
                c.projects = [p.id]
                found[key] = c
            }
        }
        return Array(found.values).sorted { $0.name < $1.name }
    }

    static func sqliteFiles(_ projects: [Project]) -> [DBCandidate] {
        var out: [DBCandidate] = []
        let exts: Set<String> = ["sqlite", "sqlite3", "db"]
        for p in projects where !p.isSample {
            guard let walker = FileManager.default.enumerator(at: p.url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in walker {
                if walker.level > 3 { walker.skipDescendants(); continue }
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if v?.isDirectory == true {
                    if ProjectScan.skip.contains(u.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                guard exts.contains(u.pathExtension.lowercased()), isSQLite(u) else { continue }
                let rel = (u.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                let size = ByteCountFormatter.string(fromByteCount: Int64(v?.fileSize ?? 0), countStyle: .file)
                out.append(DBCandidate(id: "sq-\(u.path)", source: .sqlite, name: u.lastPathComponent, sub: "\(rel) · \(size)", flavor: .sqlite,
                                       filePath: u.path, projects: [p.id]))
                if out.count > 12 { return out }
            }
        }
        return out
    }

    /// The "SQLite format 3" header, so a random `.db` isn't offered.
    static func isSQLite(_ u: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: u) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 16)).map { String(decoding: $0, as: UTF8.self).hasPrefix("SQLite format 3") } ?? false
    }

    static func dockerContainers() async -> [DBCandidate] {
        guard ProcessRunner.which("docker") != nil,
              let r = try? await ProcessRunner.run("docker", ["ps", "--format", "{{.Names}}\t{{.Image}}\t{{.Ports}}"], timeout: 8), r.ok else { return [] }
        return parseDockerPS(r.stdout)
    }

    /// `docker ps` lines into database containers with their published port.
    static func parseDockerPS(_ out: String) -> [DBCandidate] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, let flavor = DBPaste.flavor(image: f[1]) else { return nil }
            let inner = flavor.kind == .mysql ? 3306 : 5432
            // "0.0.0.0:5433->5432/tcp, :::5433->5432/tcp"
            let published = f[2].split(separator: ",").compactMap { part -> Int? in
                let s = part.trimmingCharacters(in: .whitespaces)
                guard s.hasSuffix("->\(inner)/tcp"), let colon = s.lastIndex(of: ":") else { return nil }
                return Int(s[s.index(after: colon)...].prefix { $0.isNumber })
            }.first
            let image = f[1].split(separator: "/").last.map(String.init) ?? f[1]
            return DBCandidate(id: "docker-\(f[0])", source: .docker, name: "\(flavor.label) in Docker",
                               sub: "\(f[0]) · \(image)\(published.map { " · :\($0)" } ?? " · port not published")",
                               flavor: flavor, host: "localhost", port: published, user: flavor.kind == .mysql ? "root" : "postgres", dockerContainer: f[0])
        }
    }

    /// Fills user, password and database from the container's environment
    /// (POSTGRES_*, MYSQL_*, MARIADB_*). Read only when the user picks the
    /// container, so passwords are not pulled out of every container on a scan.
    static func dockerCredentials(_ c: DBCandidate) async -> DBCandidate {
        guard let name = c.dockerContainer,
              let r = try? await ProcessRunner.run("docker", ["inspect", "--format", "{{range .Config.Env}}{{println .}}{{end}}", name], timeout: 8), r.ok else { return c }
        return applyContainerEnv(r.stdout, to: c)
    }

    static func applyContainerEnv(_ out: String, to c: DBCandidate) -> DBCandidate {
        var env: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        func first(_ keys: [String]) -> String? { keys.lazy.compactMap { env[$0] }.first { !$0.isEmpty } }
        var c = c
        if c.flavor.kind == .postgres {
            c.user = first(["POSTGRES_USER"]) ?? "postgres"
            c.password = first(["POSTGRES_PASSWORD"]) ?? c.password
            c.database = first(["POSTGRES_DB"]) ?? c.user
        } else {
            // A named app user is the safer default; root only when it's all there is.
            if let u = first(["MYSQL_USER", "MARIADB_USER"]), let pw = first(["MYSQL_PASSWORD", "MARIADB_PASSWORD"]) {
                c.user = u; c.password = pw
            } else {
                c.user = "root"
                c.password = first(["MYSQL_ROOT_PASSWORD", "MARIADB_ROOT_PASSWORD"]) ?? c.password
            }
            c.database = first(["MYSQL_DATABASE", "MARIADB_DATABASE"]) ?? c.database
        }
        return c
    }

    /// Something listening on 5432 / 3306 here (Homebrew, Postgres.app, a native install).
    static func localServices() async -> [DBCandidate] {
        var out: [DBCandidate] = []
        for (port, flavor) in [(5432, DBFlavor.postgres), (3306, DBFlavor.mysql)] where await isOpen(port) {
            let app = FileManager.default.fileExists(atPath: "/Applications/Postgres.app")
            let brew = FileManager.default.fileExists(atPath: "/opt/homebrew/var/\(flavor == .postgres ? "postgresql" : "mysql")")
                || ((try? FileManager.default.contentsOfDirectory(atPath: "/opt/homebrew/var")) ?? []).contains { $0.hasPrefix(flavor == .postgres ? "postgres" : "mysql") }
            let via = flavor == .postgres && app ? "Postgres.app" : brew ? "Homebrew" : "this Mac"
            out.append(DBCandidate(id: "local-\(port)", source: .local, name: "\(flavor.label) (\(via))", sub: "localhost:\(port)", flavor: flavor,
                                   host: "localhost", port: port, user: flavor == .postgres ? NSUserName() : "root"))
        }
        return out
    }

    /// A TCP connect to 127.0.0.1 that gives up after half a second.
    static func isOpen(_ port: Int) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .tcp)
            let once = OnceFlag()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { conn.cancel(); cont.resume(returning: true) }
                case .failed, .cancelled, .waiting: if once.claim() { conn.cancel(); cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { if once.claim() { conn.cancel(); cont.resume(returning: false) } }
        }
    }

    /// For the SSH servers the user chooses to check: listening database ports
    /// on that server (`ss` or `netstat`), read-only. Run only on request.
    static func serverPorts(_ h: SSHHost, password: String?) async -> [Int] {
        guard let r = try? await SSHCommand.run(h, password: password, remote: "(ss -ltn 2>/dev/null || netstat -an 2>/dev/null) | grep -Eo ':(5432|3306)\\b' | sort -u", timeout: 15),
              r.ok else { return [] }
        return r.stdout.split(separator: "\n").compactMap { Int($0.dropFirst()) }
    }
}
