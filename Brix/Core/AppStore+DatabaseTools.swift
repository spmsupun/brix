import AppKit
import UniformTypeIdentifiers

/// Dump, restore and the database's own command-line client. These run the
/// standard tools (pg_dump, psql, pg_restore, mysqldump, mysql, sqlite3) so the
/// files work anywhere; passwords reach them in a file only this user can read
/// (PGPASSFILE, mysql's --defaults-extra-file), not the environment, which
/// outlives the moment it's needed.
extension AppStore {
    struct DBEndpoint {
        var host: String
        var port: Int
        var tunnel: SSHTunnel?
        var env: [String: String]
        /// The password file the tool reads, removed by `close`.
        var secret: URL? = nil

        func close() {
            tunnel?.close()
            if let secret { LiveDatabaseService.removeSecret(secret) }
        }
    }

    /// The password where the client reads it: a .pgpass line for Postgres, an option file for MySQL.
    static func passwordFile(_ kind: DBKind, _ password: String) throws -> URL {
        let esc = { (s: String, chars: [String]) in chars.reduce(s.replacingOccurrences(of: "\\", with: "\\\\")) { $0.replacingOccurrences(of: $1, with: "\\" + $1) } }
        if kind == .postgres { return try LiveDatabaseService.secretFile("*:*:*:*:\(esc(password, [":"]))\n", name: "pgpass") }
        return try LiveDatabaseService.secretFile("[client]\npassword=\"\(esc(password, ["\""]).replacingOccurrences(of: "\n", with: "\\n"))\"\n", name: "my.cnf")
    }

    /// mysql and mysqldump take the option file only as their first argument.
    static func optionFile(_ d: DatabaseConnection, _ e: DBEndpoint) -> [String] {
        d.kind == .mysql ? e.secret.map { ["--defaults-extra-file=\($0.path)"] } ?? [] : []
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
        var e = DBEndpoint(host: d.host, port: d.port, tunnel: nil, env: [:])
        if let pw = dbPassword(d), !pw.isEmpty, d.kind != .sqlite {
            let file = try Self.passwordFile(d.kind, pw)
            e.secret = file
            if d.kind == .postgres { e.env["PGPASSFILE"] = file.path }
        }
        if d.kind == .postgres { e.env["PGSSLMODE"] = d.sslMode.rawValue }
        if let hid = d.tunnelHostID, let h = host(hid) {
            do { e.tunnel = try await SSHTunnel.open(via: h, password: hostPassword(h), to: d.host, port: d.port) } catch {
                e.close()
                throw error
            }
            e.host = "127.0.0.1"
            e.port = e.tunnel?.localPort ?? d.port
        }
        return e
    }

    static func dumpArgs(_ d: DatabaseConnection, _ e: DBEndpoint, to file: String, custom: Bool) -> [String] {
        switch d.kind {
        case .postgres:
            ["-h", e.host, "-p", "\(e.port)", "-U", d.user, "-d", d.database, "--no-password", "-f", file] + (custom ? ["-Fc"] : ["--clean", "--if-exists"])
        case .mysql:
            optionFile(d, e) + ["-h", e.host, "-P", "\(e.port)", "-u", d.user, "--single-transaction", "--routines", "--triggers", "--result-file=\(file)", d.database]
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
            optionFile(d, e) + ["-h", e.host, "-P", "\(e.port)", "-u", d.user, d.database, "-e", "source \(file)"]
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
                defer { e.close() }
                let r = try await ProcessRunner.run(path, Self.dumpArgs(d, e, to: url.path, custom: asCustom), env: e.env, timeout: 3600)
                guard r.ok else { throw ServiceError(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("\(tool) exited with \(r.status)")) }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
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
                    defer { e.close() }
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
        var env: [String: String] = [:]
        var options = ""
        var secret: URL?
        if let pw = dbPassword(d), !pw.isEmpty, d.kind != .sqlite {
            do {
                let file = try Self.passwordFile(d.kind, pw)
                secret = file
                if d.kind == .postgres { env["PGPASSFILE"] = file.path } else { options = "--defaults-extra-file=\(q(file.path)) " }
            } catch {
                toast(.error, "Couldn't hand the password to \(tool)", detail: error.localizedDescription)
            }
        }
        let cmd: String = switch d.kind {
        case .postgres: "psql -h \(q(d.host)) -p \(d.port) -U \(q(d.user)) -d \(q(d.database))"
        case .mysql: "mysql \(options)-h \(q(d.host)) -P \(d.port) -u \(q(d.user)) \(q(d.database))"
        case .sqlite: "sqlite3 \(d.effectiveReadOnly ? "-readonly " : "")\(q((d.filePath as NSString).expandingTildeInPath))"
        }
        if d.kind == .postgres {
            env["PGSSLMODE"] = d.sslMode.rawValue
            // psql reads PGOPTIONS at connect, so read-only applies to the whole session.
            if d.effectiveReadOnly { env["PGOPTIONS"] = "-c default_transaction_read_only=on" }
        }
        let project = library.links.projects(for: d.id).first
        let s = newTerminal(project: project, title: "\(d.name) \(tool)", command: cmd, env: env, attach: false)
        route = .terminals
        focusedSessionID = s.id
        if let secret { removeOnceConnected(secret, session: s.id) }
    }

    /// The client reads its password file as it connects: remove the file once its
    /// prompt (or a password question, or an error) is on screen, or the session
    /// ends, and after 30 s whatever happens.
    private func removeOnceConnected(_ file: URL, session: String) {
        Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let s = self.session(session), s.isLive else { break }
                let screen = TerminalRegistry.shared.view(session)?.recentLines.suffix(3).joined(separator: "\n") ?? ""
                if Self.clientConnected(screen) { break }
            }
            LiveDatabaseService.removeSecret(file)
        }
    }

    /// psql's or mysql's prompt, a password question, or a connection error.
    nonisolated static func clientConnected(_ screen: String) -> Bool {
        screen.range(of: #"(?m)(^\S*[=\-(][>#]\s*$|^(mysql|mariadb|MariaDB \[.*\])>\s*$|password|error|failed|could not)"#,
                     options: [.regularExpression, .caseInsensitive]) != nil
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
