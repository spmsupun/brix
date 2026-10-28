import Foundation
import Network

/// What an agent's database request may do, given the connection's access.
enum AgentDBPolicy {
    enum Decision: Equatable {
        case allow
        /// A write: the user confirms each one in Brix.
        case ask
        case deny(String)
    }

    static func check(_ access: AgentDBAccess, sql: String, production: Bool) -> Decision {
        let write = AppStore.isWrite(sql)
        switch access {
        case .none: return .deny("Agents have no access to this database.")
        case .schema: return .deny("Schema only: agents can list tables and columns but not read rows. Use `brix-db schema`.")
        case .read:
            if write { return .deny("Read data only: this statement changes data.") }
            return readOnlyStatement(sql) ? .allow : .deny("Read data only: run a single SELECT, WITH, SHOW or EXPLAIN.")
        case .write:
            if write { return production ? .deny("Production databases are read-only for agents.") : .ask }
            return .allow
        }
    }

    /// One statement that only reads.
    static func readOnlyStatement(_ sql: String) -> Bool {
        let s = sql.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";")).lowercased()
        guard !s.contains(";") else { return false }
        // MySQL writes files from a SELECT; a read-only transaction doesn't stop it.
        if s.range(of: #"\binto\s+(out|dump)file\b"#, options: .regularExpression) != nil { return false }
        return ["select", "with", "show", "explain", "describe", "desc ", "values", "table "].contains { s.hasPrefix($0) }
    }

    /// Column names whose values agents never see.
    static func sensitive(_ column: String) -> Bool {
        column.lowercased().range(of: #"pass(word|wd)?|secret|token|api_?key|private_?key|ssn|social_security|card_?(number|no)|cvv|cvc|iban|salt|hash|otp|pin_code"#,
                                  options: .regularExpression) != nil
    }

    /// The result as text for an agent: sensitive columns masked, at most `limit` rows.
    static func render(_ r: QueryResult, limit: Int = 200) -> String {
        let cols = r.columns.map(\.name)
        let masked = cols.map(sensitive)
        var lines = [cols.joined(separator: "\t")]
        for row in r.rows.prefix(limit) {
            lines.append(row.enumerated().map { i, v in i < masked.count && masked[i] ? "•••" : (v ?? "NULL") }
                .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t"))
        }
        if r.rows.count > limit { lines.append("… \(r.rows.count - limit) more rows not shown") }
        if masked.contains(true) { lines.append("(masked: " + cols.enumerated().filter { masked[$0.offset] }.map(\.element).joined(separator: ", ") + ")") }
        if let m = r.message, cols.isEmpty { lines = [m] }
        return lines.joined(separator: "\n")
    }
}

/// A local endpoint agents reach through the `brix-db` command. It lists the
/// databases linked to the agent's project, shows schemas, and runs queries
/// under each connection's agent access. It never returns credentials.
@MainActor
final class AgentDBGateway {
    static let shared = AgentDBGateway()
    private var listener: NWListener?
    private(set) var port: UInt16?
    let token = UUID().uuidString + UUID().uuidString
    weak var store: AppStore?

    /// Environment for an agent session in `project`.
    func environment(project: ProjectID?, session: String) -> [String: String] {
        guard let port, let project else { return [:] }
        return ["BRIX_DB_URL": "http://127.0.0.1:\(port)", "BRIX_DB_TOKEN": token, "BRIX_DB_PROJECT": project, "BRIX_SESSION": session,
                "PATH": Self.binDir.path + ":" + ProcessRunner.searchPath]
    }

    static var binDir: URL { Persistence.standard.directory.appendingPathComponent("bin") }

    func start(store: AppStore) {
        self.store = store
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.serve(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .ready = state { self?.port = l.port?.rawValue }
                    if case .failed(let e) = state { store.toast(.error, "Agent database access is off", detail: e.localizedDescription) }
                }
            }
            l.start(queue: .main)
            listener = l
            try Self.installCLI()
        } catch {
            store.toast(.error, "Agent database access is off", detail: error.localizedDescription)
        }
    }

    /// `brix-db`: a small shell script agents run; it calls this endpoint with curl.
    static func installCLI() throws {
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/sh
        # brix-db: databases linked to this Brix project, under the access Brix allows.
        #   brix-db list                 databases you can use
        #   brix-db schema <name>        tables and columns
        #   brix-db query <name> "<sql>" run SQL (writes ask the user in Brix)
        #   brix-db suggest <console> "<sql>"  show SQL in a Brix console (the user accepts it)
        [ -n "$BRIX_DB_URL" ] || { echo "brix-db: run this from a Brix agent session" >&2; exit 2; }
        cmd="$1"; db="$2"; sql="$3"
        case "$cmd" in list|schema|query|suggest) ;; *) /usr/bin/sed -n '3,6p' "$0" | /usr/bin/sed 's/^#  //'; exit 2;; esac
        dbname=$(printf '%s' "$db" | /usr/bin/od -An -tx1 | /usr/bin/tr -d ' \n')
        printf '%s' "$sql" | /usr/bin/curl -sS --max-time 300 -X POST "$BRIX_DB_URL/$cmd" \
          -H "Authorization: Bearer $BRIX_DB_TOKEN" -H "X-Brix-Project: $BRIX_DB_PROJECT" -H "X-Brix-Session: $BRIX_SESSION" \
          -H "X-Brix-DB: $dbname" --data-binary @- -w '\n%{http_code}' | {
            out=$(/bin/cat); code=$(printf '%s' "$out" | /usr/bin/tail -n1); printf '%s\n' "$(printf '%s' "$out" | /usr/bin/sed '$d')"
            [ "$code" = "200" ]
          }
        """#
        let url = binDir.appendingPathComponent("brix-db")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: HTTP

    private func serve(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                var buf = buffer
                if let data { buf.append(data) }
                if let req = Self.parse(buf) {
                    let (code, text) = await self.handle(req)
                    Self.respond(conn, code: code, text: text)
                } else if done || error != nil || buf.count > 1 << 20 {
                    Self.respond(conn, code: 400, text: "Bad request")
                } else {
                    self.receive(conn, buffer: buf)
                }
            }
        }
    }

    struct Request {
        var path: String
        var headers: [String: String]
        var body: Data
    }

    /// A whole HTTP/1.1 request, or nil while more is coming.
    nonisolated static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).split(separator: "\r\n").map(String.init)
        guard let first = head.first?.split(separator: " "), first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for h in head.dropFirst() {
            guard let c = h.firstIndex(of: ":") else { continue }
            headers[h[..<c].lowercased()] = h[h.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }

    nonisolated static func unhex(_ s: String) -> String {
        var bytes: [UInt8] = []
        var i = s.startIndex
        while let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex), i < s.endIndex, let b = UInt8(s[i..<j], radix: 16) { bytes.append(b); i = j }
        return String(decoding: bytes, as: UTF8.self)
    }

    nonisolated private static func respond(_ conn: NWConnection, code: Int, text: String) {
        let body = Data(text.utf8)
        let head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func handle(_ req: Request) async -> (Int, String) {
        guard req.headers["authorization"] == "Bearer \(token)" else { return (401, "Not a Brix agent session.") }
        guard let store, let projectID = req.headers["x-brix-project"], let project = store.project(projectID) else { return (403, "Unknown project.") }
        let session = req.headers["x-brix-session"].flatMap { store.gatewaySessions[$0] ?? $0 }.flatMap(store.session)
        // The name comes hex-encoded in a header (any characters survive); the body is the SQL.
        let name = Self.unhex(req.headers["x-brix-db"] ?? "").trimmingCharacters(in: .whitespaces)
        let sql = String(decoding: req.body, as: UTF8.self)
        // Only databases linked to the agent's project (or its parent folder).
        let ids = [project.id] + (project.parentID.map { [$0] } ?? [])
        let dbs = ids.flatMap(store.linkedDatabases).filter { $0.agentAccess != .none }
        switch req.path {
        case "/list":
            if dbs.isEmpty { return (200, "No databases are shared with agents in \(project.name).") }
            return (200, dbs.map { "\($0.name)\t\(DBProduct.flavor($0).label)\t\($0.agentAccess.label)\t\($0.tag.name)" }.joined(separator: "\n"))
        case "/schema", "/query":
            guard let d = dbs.first(where: { $0.name == name }) else {
                return (404, "No database “\(name)” here. Run `brix-db list`.")
            }
            if req.path == "/schema" { return await schema(d, store: store) }
            switch AgentDBPolicy.check(d.agentAccess, sql: sql, production: d.tag.isProduction) {
            case .deny(let why): return (403, why)
            case .allow: return await run(sql, on: d, unlock: false, store: store)
            case .ask:
                let who = session.map(store.displayTitle) ?? "An agent"
                let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    store.confirm("\(who) wants to write to \(d.name)", sql.count > 400 ? String(sql.prefix(400)) + "…" : sql, confirm: "Allow Once",
                                  onCancel: { cont.resume(returning: false) }) { cont.resume(returning: true) }
                }
                return ok ? await run(sql, on: d, unlock: true, store: store) : (403, "The user declined this write.")
            }
        case "/suggest":
            // `name` is the console id from the prompt Brix sent; only consoles on a
            // database this agent's project shares with agents.
            guard let console = UUID(uuidString: name), let tab = store.dataWorkspace.tabs.first(where: { $0.id == console && $0.isConsole }),
                  dbs.contains(where: { $0.id == tab.connectionID }) else { return (404, "No such console for this project.") }
            return store.suggest(console: name, sql: sql) ? (200, "Shown in the Brix console. The user presses Tab to accept it.") : (404, "That console is closed.")
        default:
            return (404, "Unknown command.")
        }
    }

    private func schema(_ d: DatabaseConnection, store: AppStore) async -> (Int, String) {
        do {
            let svc = store.svc(d).db
            let tree = try await svc.schema(d, password: store.dbPassword(d))
            var out: [String] = []
            for (schema, objects) in tree.schemas.sorted(by: { $0.key < $1.key }) {
                for o in objects.sorted(by: { $0.name < $1.name }) where o.kind == .table || o.kind == .view {
                    let cols: [DBColumn]
                    do { cols = try await svc.tableDetail(d, object: o, password: store.dbPassword(d)).columns } catch {
                        out.append("\(schema).\(o.name) (columns unavailable: \((error as? ServiceError)?.message ?? error.localizedDescription))")
                        continue
                    }
                    out.append("\(schema).\(o.name)" + (o.kind == .view ? " (view)" : ""))
                    out += cols.map { "  \($0.name) \($0.type)\($0.isPK ? " primary key" : "")\($0.nullable ? "" : " not null")" }
                }
            }
            return (200, out.isEmpty ? "No tables." : out.joined(separator: "\n"))
        } catch {
            return (500, (error as? ServiceError)?.message ?? error.localizedDescription)
        }
    }

    private func run(_ sql: String, on d: DatabaseConnection, unlock: Bool, store: AppStore) async -> (Int, String) {
        var conn = d
        // Reads run in a read-only transaction whatever the connection allows.
        conn.readOnly = !unlock
        conn.writeUnlocked = unlock
        do {
            let r = try await store.svc(conn).db.execute(conn, sql: sql, password: store.dbPassword(conn))
            return (200, AgentDBPolicy.render(r))
        } catch {
            return (500, (error as? ServiceError)?.message ?? error.localizedDescription)
        }
    }
}
