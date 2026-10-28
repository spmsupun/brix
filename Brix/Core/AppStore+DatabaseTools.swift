import AppKit
import UniformTypeIdentifiers

/// Dump, restore and the database's own command-line client. These run the
/// standard tools (pg_dump, psql, pg_restore, mysqldump, mysql, sqlite3) so the
/// files work anywhere; passwords reach them through their environment variable.
extension AppStore {
    struct DBEndpoint {
        var host: String
        var port: Int
        var tunnel: SSHTunnel?
        var env: [String: String]
    }

    static func clientTool(_ kind: DBKind, dump: Bool, custom: Bool = false) -> String {
        switch kind {
        case .postgres: dump ? "pg_dump" : (custom ? "pg_restore" : "psql")
        case .mysql: dump ? "mysqldump" : "mysql"
        case .sqlite: "sqlite3"
        }
    }

    static func installHint(_ kind: DBKind) -> String {
        switch kind {
        case .postgres: "Install the client tools with: brew install libpq"
        case .mysql: "Install the client tools with: brew install mysql-client"
        case .sqlite: "sqlite3 ships with macOS."
        }
    }

    /// Opens an SSH tunnel when the connection uses one; the caller closes it.
    func endpoint(_ d: DatabaseConnection) async throws -> DBEndpoint {
        var env: [String: String] = [:]
        if let pw = dbPassword(d), !pw.isEmpty {
            env[d.kind == .postgres ? "PGPASSWORD" : "MYSQL_PWD"] = pw
        }
        if d.kind == .postgres { env["PGSSLMODE"] = d.sslMode.rawValue }
        if let hid = d.tunnelHostID, let h = host(hid) {
            let t = try await SSHTunnel.open(via: h, password: hostPassword(h), to: d.host, port: d.port)
            return DBEndpoint(host: "127.0.0.1", port: t.localPort, tunnel: t, env: env)
        }
        return DBEndpoint(host: d.host, port: d.port, tunnel: nil, env: env)
    }

    static func dumpArgs(_ d: DatabaseConnection, _ e: DBEndpoint, to file: String, custom: Bool) -> [String] {
        switch d.kind {
        case .postgres:
            ["-h", e.host, "-p", "\(e.port)", "-U", d.user, "-d", d.database, "--no-password", "-f", file] + (custom ? ["-Fc"] : ["--clean", "--if-exists"])
        case .mysql:
            ["-h", e.host, "-P", "\(e.port)", "-u", d.user, "--single-transaction", "--routines", "--triggers", "--result-file=\(file)", d.database]
        case .sqlite:
            [(d.filePath as NSString).expandingTildeInPath, ".output \(file)", ".dump"]
        }
    }

    static func restoreArgs(_ d: DatabaseConnection, _ e: DBEndpoint, from file: String, custom: Bool) -> [String] {
        switch d.kind {
        case .postgres where custom:
            ["-h", e.host, "-p", "\(e.port)", "-U", d.user, "-d", d.database, "--no-password", "--clean", "--if-exists", "--no-owner", file]
        case .postgres:
            ["-h", e.host, "-p", "\(e.port)", "-U", d.user, "-d", d.database, "--no-password", "-v", "ON_ERROR_STOP=1", "-f", file]
        case .mysql:
            ["-h", e.host, "-P", "\(e.port)", "-u", d.user, d.database, "-e", "source \(file)"]
        case .sqlite:
            [(d.filePath as NSString).expandingTildeInPath, ".read \(file)"]
        }
    }

    func dumpDatabase(_ d: DatabaseConnection) {
        guard !d.isSample else { toast(.info, "Sample databases can't be dumped"); return }
        let panel = NSSavePanel()
        let custom = d.kind == .postgres
        panel.nameFieldStringValue = "\(d.database.ifEmpty(d.name))-\(Date().formatted(.iso8601.year().month().day()))\(custom ? ".dump" : ".sql")"
        panel.message = custom ? "PostgreSQL custom format (restore with pg_restore). Name it .sql for plain SQL." : "Plain SQL dump"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let asCustom = custom && url.pathExtension != "sql"
        let tool = Self.clientTool(d.kind, dump: true)
        guard let path = ProcessRunner.which(tool) else {
            toast(.error, "\(tool) not found", detail: Self.installHint(d.kind))
            return
        }
        dbBusy.insert(d.id)
        toast(.progress, "Dumping \(d.name)…", detail: url.lastPathComponent)
        Task {
            defer { dbBusy.remove(d.id) }
            do {
                let e = try await endpoint(d)
                defer { e.tunnel?.close() }
                let r = try await ProcessRunner.run(path, Self.dumpArgs(d, e, to: url.path, custom: asCustom), env: e.env, timeout: 3600)
                guard r.ok else { throw ServiceError(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("\(tool) exited with \(r.status)")) }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).map { ByteCountFormatter.string(fromByteCount: Int64($0 ?? 0), countStyle: .file) } ?? ""
                toast(.success, "Dumped \(d.name)", detail: "\(url.lastPathComponent) · \(size)")
            } catch {
                toast(.error, "Dump of \(d.name) failed", detail: error.localizedDescription)
            }
        }
    }

    func restoreDatabase(_ d: DatabaseConnection) {
        guard !d.isSample else { toast(.info, "Sample databases can't be restored"); return }
        if d.readOnly {
            toast(.info, "\(d.name) is read-only", detail: "Turn off read-only in its settings to restore into it.")
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .sql file or a PostgreSQL custom-format dump to restore into \(d.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let custom = d.kind == .postgres && url.pathExtension != "sql"
        let tool = Self.clientTool(d.kind, dump: false, custom: custom)
        guard let path = ProcessRunner.which(tool) else {
            toast(.error, "\(tool) not found", detail: Self.installHint(d.kind))
            return
        }
        let what = "Restore \(url.lastPathComponent) into \(d.name)?"
        let detail = "This runs the dump against \(d.endpoint)\(d.tunnelHostID.flatMap(host).map { " through \($0.name)" } ?? ""). Existing tables in the dump are replaced. This can't be undone."
        let run = { [weak self] in
            guard let self else { return }
            dbBusy.insert(d.id)
            toast(.progress, "Restoring \(d.name)…", detail: url.lastPathComponent)
            Task {
                defer { self.dbBusy.remove(d.id) }
                do {
                    let e = try await self.endpoint(d)
                    defer { e.tunnel?.close() }
                    let r = try await ProcessRunner.run(path, Self.restoreArgs(d, e, from: url.path, custom: custom), env: e.env, timeout: 3600)
                    guard r.ok else { throw ServiceError(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("\(tool) exited with \(r.status)")) }
                    self.schemaCache[d.id] = nil
                    self.toast(.success, "Restored \(d.name)", detail: url.lastPathComponent)
                } catch {
                    self.toast(.error, "Restore into \(d.name) failed", detail: error.localizedDescription)
                }
            }
        }
        if d.tag.isProduction {
            // Two steps for production: the usual confirmation, then a second one naming it.
            confirm(what, detail, confirm: "Continue") { [weak self] in
                DispatchQueue.main.async {
                    self?.confirm("\(d.name) is PRODUCTION", "Really overwrite production data from \(url.lastPathComponent)?", confirm: "Restore into Production", action: run)
                }
            }
        } else {
            confirm(what, detail, confirm: "Restore", action: run)
        }
    }

    /// psql / mysql / sqlite3 in a terminal, connected and with the password set.
    func openDatabaseCLI(_ d: DatabaseConnection) {
        guard !d.isSample else { toast(.info, "Sample databases have no CLI"); return }
        let tool = Self.clientTool(d.kind, dump: false)
        guard ProcessRunner.which(tool) != nil else { toast(.error, "\(tool) not found", detail: Self.installHint(d.kind)); return }
        let q = ProcessRunner.shellQuote
        guard d.tunnelHostID == nil else {
            toast(.info, "Use the SQL editor for tunnelled databases", detail: "The CLI needs a direct connection.")
            return
        }
        let cmd: String = switch d.kind {
        case .postgres: "psql -h \(q(d.host)) -p \(d.port) -U \(q(d.user)) -d \(q(d.database))"
        case .mysql: "mysql -h \(q(d.host)) -P \(d.port) -u \(q(d.user)) \(q(d.database))"
        case .sqlite: "sqlite3 \(d.effectiveReadOnly ? "-readonly " : "")\(q((d.filePath as NSString).expandingTildeInPath))"
        }
        var env: [String: String] = [:]
        if let pw = dbPassword(d), !pw.isEmpty { env[d.kind == .postgres ? "PGPASSWORD" : "MYSQL_PWD"] = pw }
        if d.kind == .postgres {
            env["PGSSLMODE"] = d.sslMode.rawValue
            // psql reads PGOPTIONS at connect, so read-only applies to the whole session.
            if d.effectiveReadOnly { env["PGOPTIONS"] = "-c default_transaction_read_only=on" }
        }
        let project = library.links.projects(for: d.id).first
        let s = newTerminal(project: project, title: "\(d.name) \(tool)", command: cmd, env: env, attach: false)
        route = .terminals
        focusedSessionID = s.id
    }

    /// Connection URL without the password, for pasting into other tools.
    func connectionURL(_ d: DatabaseConnection) -> String {
        switch d.kind {
        case .sqlite: "sqlite://\((d.filePath as NSString).expandingTildeInPath)"
        case .postgres: "postgresql://\(d.user.isEmpty ? "" : d.user + "@")\(d.host):\(d.port)/\(d.database)?sslmode=\(d.sslMode.rawValue)"
        case .mysql: "mysql://\(d.user.isEmpty ? "" : d.user + "@")\(d.host):\(d.port)/\(d.database)"
        }
    }

    func setReadOnly(_ d: DatabaseConnection, _ on: Bool) {
        var c = d
        c.readOnly = on
        saveDatabase(c, password: nil)
    }
}
