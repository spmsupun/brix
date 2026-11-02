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

    /// Rows read for an agent at most (it's shown 200 of them).
    static let rowCap = 1000

    /// Functions agents never call: they reach files, other servers or other sessions,
    /// or change settings, whatever the access.
    static let blocked = #"\b(dblink\w*|pg_terminate_backend|pg_cancel_backend|lo_\w+|pg_read_file|pg_read_binary_file|pg_ls_\w+|pg_stat_file|pg_reload_conf|set_config|load_file|(query|table|cursor|schema|database)_to_xml\w*)\s*\("#

    static func check(_ access: AgentDBAccess, sql: String, production: Bool, kind: DBKind? = nil) -> Decision {
        switch access {
        case .none: return .deny("Agents have no access to this database.")
        case .schema: return .deny("Schema only: agents can list tables and columns but not read rows. Use `brix-db schema`.")
        case .read, .write: break
        }
        let code = SQLText.variants(sql, kind)
        // Each call stands alone: no transaction or session setting outlives it (or turns read-only off).
        if code.contains(where: { $0.range(of: #"(^|;)\s*(begin|start\s+transaction|commit|rollback|end|abort|savepoint|release|set|reset|xa|lock|unlock)\b"#, options: .regularExpression) != nil }) {
            return .deny("Transactions and session settings (BEGIN, COMMIT, SET, …) aren't available to agents. Each statement runs on its own.")
        }
        // U&"…" spells any name in escapes, past the checks below.
        if sql.range(of: #"(?i)\bu&\s*['"]"#, options: .regularExpression) != nil { return .deny("U&'…' escapes aren't available to agents.") }
        if let f = code.lazy.compactMap({ s in s.range(of: blocked, options: .regularExpression).map { s[$0] } }).first {
            return .deny("\(f.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)) isn't available to agents.")
        }
        // Only what's known to read runs unasked; anything else is a write, whatever its keywords.
        if readOnlyStatement(sql, kind: kind), !AppStore.isWrite(sql, kind: kind) { return .allow }
        if access == .read {
            return .deny(AppStore.isWrite(sql, kind: kind) ? "Read data only: this statement changes data." : "Read data only: run a single SELECT, WITH, SHOW or EXPLAIN.")
        }
        return production ? .deny("Production databases are read-only for agents.") : .ask
    }

    /// One statement that only reads (comments and quoted text aside).
    static func readOnlyStatement(_ sql: String, kind: DBKind? = nil) -> Bool {
        SQLText.variants(sql, kind).allSatisfy { v in
            let s = v.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.contains(";") else { return false }
            // MySQL writes files from a SELECT; a read-only transaction doesn't stop it.
            if s.range(of: #"\binto\s+(out|dump)file\b"#, options: .regularExpression) != nil { return false }
            return ["select", "with", "show", "explain", "describe", "desc ", "values", "table "].contains { s.hasPrefix($0) }
        }
    }

    /// Column names whose values agents never see. Long words count anywhere in the
    /// name; short ones (otp, hash, pin) only as a whole part, so `rootpage` isn't `otp`.
    static func sensitive(_ column: String) -> Bool {
        // passwordHash reads as password_hash.
        let n = column.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1_$2", options: .regularExpression).lowercased()
        return n.range(of: #"pass(word|wd|phrase)|secret|token|credential|api_?key|private_?key|social_security|card_?(number|no)|cookie|session_?(id|key)|authentication_string"#,
                       options: .regularExpression) != nil
            || n.range(of: #"(^|_)(pass|pwd|ssn|cvv|cvc|iban|salt|hash(ed)?|otp|totp|mfa|jwt|pin_?code)(_|$)"#, options: .regularExpression) != nil
    }

    static let keywords: Set<String> = [
        "select", "from", "where", "and", "or", "not", "as", "on", "join", "left", "right", "inner", "outer", "full", "cross", "natural", "using", "group", "by",
        "order", "having", "limit", "offset", "fetch", "first", "next", "rows", "row", "only", "distinct", "all", "union", "intersect", "except", "case", "when",
        "then", "else", "end", "is", "null", "true", "false", "in", "like", "ilike", "similar", "to", "between", "exists", "any", "some", "with", "recursive", "over",
        "partition", "window", "filter", "within", "lateral", "asc", "desc", "nulls", "last", "interval", "cast", "extract", "year", "month", "day", "hour", "minute",
        "second", "epoch", "week", "at", "time", "zone", "timestamp", "date", "current_date", "current_time", "current_timestamp", "localtime", "localtimestamp",
        "current_user", "session_user", "collate", "escape", "show", "explain", "analyze", "verbose", "describe", "values", "table", "tables", "columns", "status",
        "databases", "schemas", "index", "indexes", "keys", "for", "update", "share", "of", "nowait", "skip", "locked", "default", "array", "regexp", "rlike", "div",
        "mod", "xor", "unsigned", "signed", "straight_join", "top", "into"]

    /// For each result column, whether an agent must not see it. A sensitive name always
    /// is. When the query can reach a secret (it names a sensitive column, reads a table
    /// that has one, or reads something not in `known`), only plain columns of the tables
    /// it names get through: an alias, expression or whole row could carry a secret under
    /// any name. `known`: each table or view the SQL names (lowercased) and its lowercased
    /// columns; nil when they couldn't be read, which masks everything.
    ///
    /// ponytail: reads the text, not a parse tree. A WHERE used as an oracle gets past it;
    /// schema-only access is the answer for such databases. Views are checked by their
    /// definition in `sources`.
    static func masks(_ columns: [String], sql: String, known: [String: [String]]?) -> [Bool] {
        let named = columns.map(sensitive)
        guard let known else { return columns.map { _ in true } }
        let source = Set(known.values.joined())
        var strict = source.contains(where: sensitive) || SQLText.identifiers(sql).contains(where: sensitive)
        var aliases = Set<String>()
        let codes = SQLText.variants(sql, nil)
        for code in codes {
            let toks = code.matches(of: #/[a-z_][a-z0-9_$]*|\d+(?:\.\d+)?|::|\S/#).map { String($0.output) }
            for (i, t) in toks.enumerated() where t.first.map({ $0.isLetter || $0 == "_" }) == true {
                let prev = i > 0 ? toks[i - 1] : "", next = i + 1 < toks.count ? toks[i + 1] : ""
                if next == "(" || next == "." || prev == "::" { continue }  // a function, a qualifier, a type
                if next == "as", i + 2 < toks.count, toks[i + 2] == "(" { continue }  // a WITH query's name
                let afterName = prev.first.map { $0.isLetter || $0 == "_" } == true && !keywords.contains(prev)
                if prev == "as" || afterName || prev == ")" || prev == "'" || prev.first?.isNumber == true { aliases.insert(t); continue }
                if !keywords.contains(t), known[t] == nil, !source.contains(t) { strict = true }
            }
        }
        // Rows from a second query come under the first one's column names.
        if strict, codes.contains(where: { $0.range(of: #"\b(union|intersect|except)\b"#, options: .regularExpression) != nil }) { return columns.map { _ in true } }
        return columns.enumerated().map { i, c in
            named[i] || (strict && (!source.contains(c.lowercased()) || aliases.contains(c.lowercased())))
        }
    }

    /// The result as text for an agent: `masked` columns (by default, sensitive names) hidden, at most `limit` rows.
    static func render(_ r: QueryResult, masked: [Bool]? = nil, limit: Int = 200) -> String {
        let cols = r.columns.map(\.name)
        let masked = masked ?? cols.map(sensitive)
        var lines = [cols.joined(separator: "\t")]
        for row in r.rows.prefix(limit) {
            lines.append(row.enumerated().map { i, v in i < masked.count && masked[i] ? "•••" : (v ?? "NULL") }
                .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t"))
        }
        if r.rows.count >= rowCap { lines.append("… more rows not shown (reading stopped at \(rowCap))") }
        else if r.rows.count > limit { lines.append("… \(r.rows.count - limit) more rows not shown") }
        if masked.contains(true) { lines.append("(masked: " + cols.enumerated().filter { masked[$0.offset] }.map(\.element).joined(separator: ", ") + ")") }
        if let m = r.message, cols.isEmpty { lines = [m] }
        return lines.joined(separator: "\n")
    }

    /// The SQL as an approval prompt shows it, all of it: invisible characters made
    /// visible and runs of blank space squeezed, so padding can't push part of it out
    /// of view. Nil when it's still too long to read in a prompt.
    static func reviewable(_ sql: String) -> String? {
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate]
        let shown = String(String.UnicodeScalarView(sql.unicodeScalars.map { u in
            "\n\r\t".unicodeScalars.contains(u) || !hidden.contains(u.properties.generalCategory) ? u : "\u{FFFD}"
        }))
        let s = shown.replacingOccurrences(of: #"[^\S\n]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > 2000 || s.split(separator: "\n").count > 40 ? nil : s
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
    /// Why there's no port, told to agents through brix-db.
    private var failure: String?
    private var restarted = false
    /// Connections whose request hasn't fully arrived yet.
    private var awaitingRequest: Set<ObjectIdentifier> = []
    /// Each agent session's token, and the project and session it was made for. A
    /// request is judged by its token alone, never by what its headers claim.
    /// A closed session's tokens are revoked with it.
    private var grants: [String: (project: ProjectID, session: String)] = [:]
    weak var store: AppStore?

    /// Environment for an agent session in `project`, with a token of its own. brix-db
    /// finds the port in a file when it runs, so a session started before the listener
    /// is up (sessions restored at launch) or after it restarted still reaches it.
    func environment(project: ProjectID?, session: String) -> [String: String] {
        guard let project else { return [:] }
        let token = UUID().uuidString + UUID().uuidString
        grants[token] = (project, session)
        return ["BRIX_DB_PORTFILE": Self.portFile.path, "BRIX_DB_TOKEN": token, "PATH": Self.binDir.path + ":" + ProcessRunner.searchPath]
    }

    /// Holds the listener's port while it answers; gone while it doesn't.
    static var portFile: URL { binDir.appendingPathComponent("gateway.port") }

    private func publish(_ port: UInt16?) {
        self.port = port
        if let port {
            do { try String(port).write(to: Self.portFile, atomically: true, encoding: .utf8) } catch {
                PerfMonitor.shared.note("database gateway: couldn't write its port file: \(error.localizedDescription)")
            }
        } else {
            try? FileManager.default.removeItem(at: Self.portFile)
        }
    }

    /// Drops the tokens handed to a session that has closed, so a process it left
    /// behind can't keep using them. `session` is the store's id; a grant may name
    /// the id the session had before it started (mapped in `gatewaySessions`).
    func revoke(session: String) {
        guard let store else { return }
        grants = grants.filter { (store.gatewaySessions[$0.value.session] ?? $0.value.session) != session }
        store.gatewaySessions = store.gatewaySessions.filter { $0.value != session }
    }

    static var binDir: URL { Persistence.standard.directory.appendingPathComponent("bin") }

    /// A connection's own pooled session for agents, so an agent's call never shares
    /// (or holds up) the session the user's tabs run on.
    nonisolated static func agentConnection(_ d: DatabaseConnection) -> DatabaseConnection {
        var x = d
        x.id = d.id + "#agent"
        return x
    }

    func start(store: AppStore) {
        self.store = store
        guard listener == nil else { return }
        publish(nil)  // a port left by a run that didn't quit cleanly
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.serve(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .ready = state { self?.publish(l.port?.rawValue); self?.failure = nil }
                    if case .failed(let e) = state { self?.failed(l, e.localizedDescription, store: store) }
                }
            }
            l.start(queue: .main)
            listener = l
            try Self.installCLI()
        } catch {
            failure = error.localizedDescription
            store.toast(.error, "Agent database access is off", detail: error.localizedDescription)
        }
    }

    /// The listener stopped: its port no longer answers, so it's cleared, and a new
    /// listener is tried once a moment later.
    private func failed(_ l: NWListener, _ why: String, store: AppStore) {
        guard listener === l else { return }
        l.cancel()
        listener = nil
        publish(nil)
        failure = why
        guard !restarted else {
            store.toast(.error, "Agent database access is off", detail: why)
            return
        }
        restarted = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.start(store: store)
        }
    }

    /// `brix-db`: a small shell script agents run; it calls this endpoint with curl.
    /// The token goes to curl on a file descriptor, not its command line (which `ps` shows).
    static func installCLI() throws {
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/sh
        # brix-db: databases linked to this Brix project, under the access Brix allows.
        #   brix-db list                 databases you can use
        #   brix-db schema <name>        tables and columns
        #   brix-db query <name> "<sql>" run SQL (writes ask the user in Brix)
        #   brix-db suggest <console> "<sql>"  show SQL in a Brix console (the user accepts it)
        [ -n "$BRIX_DB_TOKEN" ] || { echo "brix-db: run this from a Brix agent session" >&2; exit 2; }
        port=$(/bin/cat "$BRIX_DB_PORTFILE" 2>/dev/null)
        [ -n "$port" ] || { echo "brix-db: Brix's database gateway isn't running. Is Brix open?" >&2; exit 2; }
        cmd="$1"; db="$2"; sql="$3"
        case "$cmd" in list|schema|query|suggest) ;; *) /usr/bin/sed -n '3,6p' "$0" | /usr/bin/sed 's/^#  //'; exit 2;; esac
        dbname=$(printf '%s' "$db" | /usr/bin/od -An -tx1 | /usr/bin/tr -d ' \n')
        exec 3<<BRIX_AUTH
        Authorization: Bearer $BRIX_DB_TOKEN
        BRIX_AUTH
        printf '%s' "$sql" | /usr/bin/curl -sS --max-time 300 -X POST "http://127.0.0.1:$port/$cmd" \
          -H @/dev/fd/3 -H "X-Brix-DB: $dbname" --data-binary @- -w '\n%{http_code}' | {
            out=$(/bin/cat); code=$(printf '%s' "$out" | /usr/bin/tail -n1); printf '%s\n' "$(printf '%s' "$out" | /usr/bin/sed '$d')"
            [ "$code" = "200" ]
          }
        """#
        let url = binDir.appendingPathComponent("brix-db")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: HTTP

    /// The largest request body taken (SQL text).
    nonisolated static let maxBody = 1 << 20

    private func serve(_ conn: NWConnection) {
        conn.start(queue: .main)
        // A client that never finishes sending its request doesn't hold the connection open.
        let id = ObjectIdentifier(conn)
        awaitingRequest.insert(id)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if self?.awaitingRequest.remove(id) != nil { conn.cancel() }
        }
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                var buf = buffer
                if let data { buf.append(data) }
                if let req = Self.parse(buf) {
                    self.awaitingRequest.remove(ObjectIdentifier(conn))
                    let (code, text) = req.path.isEmpty ? (400, "Bad request") : await self.handle(req)
                    Self.respond(conn, code: code, text: text)
                } else if done || error != nil || buf.count > Self.maxBody + (64 << 10) {
                    self.awaitingRequest.remove(ObjectIdentifier(conn))
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

    /// A whole HTTP/1.1 request, or nil while more is coming. A request that can
    /// never be valid (a negative or oversized Content-Length) has an empty path.
    nonisolated static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).split(separator: "\r\n").map(String.init)
        guard let first = head.first?.split(separator: " "), first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for h in head.dropFirst() {
            guard let c = h.firstIndex(of: ":") else { continue }
            headers[h[..<c].lowercased()] = h[h.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        guard let length = Int(headers["content-length"] ?? "0"), (0...maxBody).contains(length) else {
            return Request(path: "", headers: [:], body: Data())
        }
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
        let auth = req.headers["authorization"] ?? ""
        guard auth.hasPrefix("Bearer "), let grant = grants[String(auth.dropFirst(7))] else { return (401, "Not a Brix agent session.") }
        guard let store, let project = store.project(grant.project) else { return (403, "Unknown project.") }
        let session = store.session(store.gatewaySessions[grant.session] ?? grant.session)
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
            switch AgentDBPolicy.check(d.agentAccess, sql: sql, production: d.tag.isProduction, kind: d.kind) {
            case .deny(let why): return (403, why)
            case .allow: return await run(sql, on: d, unlock: false, store: store)
            case .ask:
                guard let shown = AgentDBPolicy.reviewable(sql) else {
                    return (403, "Too long to review: the user approves each write by reading it, so keep one under 40 lines and 2,000 characters.")
                }
                let who = session.map(store.displayTitle) ?? "An agent"
                let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    let c = Confirmation(title: "\(who) wants to write to \(d.name)", message: shown, confirmTitle: "Allow Once",
                                         action: { cont.resume(returning: true) }, onCancel: { cont.resume(returning: false) })
                    store.confirmation = c
                    // brix-db gives up after 300 s; withdraw the prompt before then, so a
                    // late "Allow" never runs a write the agent no longer waits for.
                    Task { @MainActor [weak store] in
                        try? await Task.sleep(nanoseconds: 280_000_000_000)
                        store?.answerConfirmation(c.id, confirmed: false)
                    }
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
            let svc = store.svc(d).db, conn = Self.agentConnection(d), pw = store.dbPassword(d)
            let tree = try await svc.schema(conn, password: pw)
            var out: [String] = []
            for (schema, objects) in d.agentSchemas(tree.schemas).sorted(by: { $0.key < $1.key }) {
                for o in objects.sorted(by: { $0.name < $1.name }) where o.kind == .table || o.kind == .view {
                    let cols: [DBColumn]
                    do { cols = try await svc.tableDetail(conn, object: o, password: pw).columns } catch {
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
        var conn = Self.agentConnection(d)
        // Reads run in a read-only transaction whatever the connection allows.
        conn.readOnly = !unlock
        conn.writeUnlocked = unlock
        do {
            let pw = store.dbPassword(d)
            let r = try await LiveDatabaseService.$agent.withValue(true) { try await store.svc(conn).db.execute(conn, sql: sql, password: pw) }
            let known = r.columns.isEmpty ? [:] : await sources(sql, on: d, store: store)
            let text = AgentDBPolicy.render(r, masked: AgentDBPolicy.masks(r.columns.map(\.name), sql: sql, known: known))
            return (200, text + (known == nil ? "\n(every column hidden: the tables this reads couldn't be checked for secrets)" : ""))
        } catch {
            return (500, (error as? ServiceError)?.message ?? error.localizedDescription)
        }
    }

    /// The tables and views the SQL names, with their columns (lowercased), for masking.
    /// Nil when they can't be read: then every column is masked.
    /// The SQL a view is defined by, or nil when it can't be read.
    private func viewDefinition(_ o: DBObject, d: DatabaseConnection) async -> String? {
        guard let store else { return nil }
        let q = { (x: String) in "'" + x.replacingOccurrences(of: "'", with: "''") + "'" }
        let sql: String = switch d.kind {
        case .postgres: "SELECT pg_get_viewdef(format('%I.%I', \(q(o.schema)), \(q(o.name)))::regclass)"
        case .mysql: "SELECT view_definition FROM information_schema.views WHERE table_schema = \(q(o.schema)) AND table_name = \(q(o.name))"
        case .sqlite: "SELECT sql FROM sqlite_master WHERE type = 'view' AND name = \(q(o.name))"
        }
        var conn = Self.agentConnection(d)
        conn.readOnly = true
        let pw = store.dbPassword(d)
        let r = try? await LiveDatabaseService.$agent.withValue(true) { try await store.svc(conn).db.execute(conn, sql: sql, password: pw) }
        return r?.rows.first?.first.flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func sources(_ sql: String, on d: DatabaseConnection, store: AppStore) async -> [String: [String]]? {
        let words = Set(SQLText.identifiers(sql))
        let svc = store.svc(d).db, conn = Self.agentConnection(d), pw = store.dbPassword(d)
        do {
            let tree: DBSchemaTree
            if let cached = store.schemaCache[d.id] { tree = cached } else { tree = try await svc.schema(conn, password: pw) }
            let named = tree.schemas.values.joined().filter { $0.kind != .function && words.contains($0.name.lowercased()) }
            guard named.count <= 30 else { return nil }
            var out: [String: [String]] = [:]
            for o in named {
                var cols = try await svc.tableDetail(conn, object: o, password: pw).columns.map { $0.name.lowercased() }
                // A view can pass a secret on under a harmless name. Trust its columns only
                // when its definition reads no sensitive column; otherwise (or when the
                // definition can't be read) its columns count as secrets.
                if o.kind == .view, await viewDefinition(o, d: d).map({ SQLText.identifiers($0).contains(where: AgentDBPolicy.sensitive) }) ?? true {
                    cols = cols.map { "secret_" + $0 }
                }
                out[o.name.lowercased(), default: []] += cols
            }
            return out
        } catch {
            LiveDatabaseService.logger.warning("agent masking: couldn't read the tables of \(d.name): \(LiveDatabaseService.describe(error))")
            return nil
        }
    }
}
