import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Logging
import PostgresNIO
import MySQLNIO
import GRDB

/// PostgreSQL (PostgresNIO), MySQL (MySQLNIO) and SQLite (GRDB).
///
/// ponytail: one connection per call (plus an SSH tunnel when configured). Simple
/// and leak-free; add a per-connection pool if query latency starts to matter.
final class LiveDatabaseService: DatabaseService {
    static let logger = Logger(label: "brix.db")
    var tunnelHostLookup: (@MainActor (ResourceID) -> SSHHost?)?
    var hostPasswordLookup: ((SSHHost) -> String?)?

    // MARK: Generic plumbing

    /// Raw text rows: column names, column type names, values (nil = NULL).
    struct RawResult {
        var columns: [String] = []
        var types: [String] = []
        var rows: [[String?]] = []
        var affected: Int? = nil
    }

    let pool = DBSessionPool()

    /// Who a call belongs to (a tab id), so Stop only cancels that tab's query.
    @TaskLocal static var owner: String?
    /// The schema a console runs in: switched to before each call, in the same hold of the session.
    @TaskLocal static var schema: String?
    /// An agent's call (through the gateway): at most 30 s and `AgentDBPolicy.rowCap` rows,
    /// and a read runs in a read-only transaction that's rolled back.
    @TaskLocal static var agent = false

    private func run(_ c: DatabaseConnection, password: String?, _ sqls: [String], atomic: Bool = false, expect: [Int?] = []) async throws -> [RawResult] {
        switch c.kind {
        case .sqlite: return try await sqlite(c, sqls, expect: expect)
        case .postgres, .mysql: return try await pooled(c, password: password, sqls, atomic: atomic, expect: expect)
        }
    }

    /// Rows a statement touched: its RETURNING rows, a `brix_affected` count, or the driver's count.
    static func touched(_ r: RawResult) -> Int {
        if let a = r.affected { return a }
        if r.columns == ["brix_affected"] { return Int(r.rows.first?.first.flatMap { $0 } ?? "") ?? 0 }
        return r.rows.count
    }

    /// Throws when a statement touched a different number of rows than expected
    /// (inside the transaction, so nothing is kept).
    static func verify(_ r: RawResult, _ sql: String, expected: Int?) throws {
        guard let expected else { return }
        let n = touched(r)
        guard n == expected else {
            let what = sql.hasPrefix("SELECT ROW_COUNT") ? "The previous statement" : String(sql.prefix(90))
            throw ServiceError("\(what) changed \(n) row\(n == 1 ? "" : "s"), expected \(expected). The row may have changed since it was loaded. Nothing was saved.")
        }
    }

    /// Runs on the connection's shared session (opened on first use, reopened when
    /// its settings change or it drops). One call at a time per connection.
    private func pooled(_ c: DatabaseConnection, password: String?, _ sqls: [String], atomic: Bool, expect: [Int?]) async throws -> [RawResult] {
        try await pool.acquire(c.id, owner: Self.owner ?? "")
        do {
            let out = try await pooledLocked(c, password: password, sqls, atomic: atomic, expect: expect)
            await pool.release(c.id)
            return out
        } catch {
            await pool.release(c.id)
            throw error
        }
    }

    private func pooledLocked(_ c: DatabaseConnection, password: String?, _ sqls: [String], atomic: Bool, expect: [Int?]) async throws -> [RawResult] {
        let key = sessionKey(c, password: password)
        var session = await pool.session(c.id)
        if let s = session, s.key != key || s.isClosed {
            await pool.remove(c.id)?.close()
            session = nil
        }
        if session == nil {
            let s = try await open(c, password: password, key: key)
            await pool.put(c.id, s)
            session = s
        }
        guard let session else { throw ServiceError("No session") }
        session.lastUse = Date()
        let agentRead = Self.agent && readOnly(c) && !atomic
        do {
            try await session.setReadOnly(readOnly(c))
            if Self.agent {
                // Agents get a session of their own (see AgentDBGateway), so this stays there.
                let t = min(c.queryTimeout ?? 30, 30)
                if c.kind == .postgres { _ = try await session.query("SET statement_timeout = \(t * 1000)") } else {
                    // MySQL's applies to SELECTs; MariaDB names it differently (seconds, every statement).
                    let mysql = "SET SESSION max_execution_time = \(t * 1000)", maria = "SET SESSION max_statement_time = \(t)"
                    do { _ = try await session.query(c.flavor == .mariadb ? maria : mysql) } catch { _ = try await session.query(c.flavor == .mariadb ? mysql : maria) }
                }
            }
            if let schema = Self.schema {
                let use = c.kind == .postgres ? "SET search_path TO \(Self.quote(schema, .postgres)), public" : "USE \(Self.quote(schema, .mysql))"
                // Running in the wrong schema would be worse than not running.
                do { _ = try await session.query(use) } catch { throw ServiceError("Couldn't switch to schema \(schema): \(Self.describe(error))") }
            }
            var out: [RawResult] = []
            if atomic { _ = try await session.query("BEGIN") }
            if agentRead { _ = try await session.query(c.kind == .postgres ? "BEGIN READ ONLY" : "START TRANSACTION READ ONLY") }
            for (i, sql) in sqls.enumerated() {
                let r = try await session.query(sql, cap: Self.agent ? AgentDBPolicy.rowCap : .max, describe: !atomic)
                try Self.verify(r, sql, expected: expect.indices.contains(i) ? expect[i] : nil)
                out.append(r)
            }
            if atomic { _ = try await session.query("COMMIT") }
            if agentRead { _ = try await session.query("ROLLBACK") }
            return out
        } catch {
            if atomic || agentRead {
                do { _ = try await session.query("ROLLBACK") } catch {
                    // A session we can't roll back can't be trusted for the next call.
                    await pool.remove(c.id)?.close()
                }
            }
            if session.isClosed { await pool.remove(c.id)?.close() }
            throw ServiceError(Self.describe(error))
        }
    }

    /// Everything that needs a fresh session when it changes. The password is hashed.
    private func sessionKey(_ c: DatabaseConnection, password: String?) -> String {
        var h = Hasher()
        h.combine(password)
        return [c.host, "\(c.port)", c.user, c.database, c.sslMode.rawValue, c.tunnelHostID ?? "", c.startupSQL,
                "\(c.queryTimeout ?? 0)", c.flavor?.rawValue ?? "", "\(h.finalize())"].joined(separator: "|")
    }

    private func open(_ c: DatabaseConnection, password: String?, key: String) async throws -> DBSession {
        var tunnel: SSHTunnel?
        var host = c.host, port = c.port
        if let tunnelID = c.tunnelHostID {
            let lookup = tunnelHostLookup
            guard let h = await MainActor.run(body: { lookup?(tunnelID) }) else { throw ServiceError("Tunnel host not found") }
            let t = try await SSHTunnel.open(via: h, password: hostPasswordLookup?(h), to: c.host, port: c.port)
            tunnel = t
            host = "127.0.0.1"; port = t.localPort
        }
        do {
            let s: DBSession = c.kind == .postgres
                ? .init(key: key, pg: try await connectPostgres(c, host: host, port: port, password: password), tunnel: tunnel)
                : .init(key: key, my: try await connectMySQL(c, host: host, port: port, password: password), tunnel: tunnel)
            do {
                // Startup SQL first, so it can't undo the read-only guard set per call.
                for sql in Self.statements(c.startupSQL) { _ = try await s.query(sql) }
                // literal() doubles backslashes for MySQL, which is only right while
                // backslash escapes are on.
                if c.kind == .mysql { _ = try await s.query("SET SESSION sql_mode = REPLACE(@@SESSION.sql_mode, 'NO_BACKSLASH_ESCAPES', '')") }
                if let t = c.queryTimeout {
                    switch c.kind {
                    case .postgres: _ = try await s.query("SET statement_timeout = \(t * 1000)")
                    // MariaDB names it differently (seconds, every statement); MySQL's applies to SELECTs.
                    default: _ = try await s.query(c.flavor == .mariadb ? "SET SESSION max_statement_time = \(t)" : "SET SESSION max_execution_time = \(t * 1000)")
                    }
                }
                s.serverID = try await s.query(c.kind == .postgres ? "select pg_backend_pid()" : "select connection_id()").rows.first?.first ?? nil
            } catch {
                s.close()
                throw error
            }
            return s
        } catch {
            tunnel?.close()
            throw ServiceError(Self.describe(error))
        }
    }

    /// Stops the query running on the connection's session: the server is asked
    /// to cancel it from a second, short-lived connection. SQLite is interrupted.
    func cancel(_ c: DatabaseConnection, owner: String?, password: String?) async {
        if c.kind == .sqlite { sqliteQueue(c.id)?.interrupt(); return }
        // Only when this tab's call holds the session; another tab's query is left alone.
        guard let holder = await pool.holder(c.id), owner == nil || holder == owner,
              let id = await pool.session(c.id)?.serverID, let n = Int(id) else { return }
        var probe = c
        probe.startupSQL = ""
        let sql = c.kind == .postgres ? "select pg_cancel_backend(\(n))" : "KILL QUERY \(n)"
        do {
            let s = try await open(probe, password: password, key: "cancel")
            defer { s.close() }
            _ = try await s.query(sql)
        } catch {
            Self.logger.warning("cancel failed: \(Self.describe(error))")
        }
    }

    /// Waits at most `seconds` for a future (its driver has no connect timeout of
    /// its own). A result that arrives after giving up is handed to `late`, so a
    /// connection that opens too late still gets closed.
    static func timeout<T: Sendable>(_ seconds: Int, _ future: EventLoopFuture<T>, late: @escaping @Sendable (T) -> Void) async throws -> T {
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { cont in
            let timer = DispatchWorkItem {
                if once.claim() { cont.resume(throwing: ServiceError("No answer from the server after \(seconds)s")) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds), execute: timer)
            future.whenComplete { result in
                timer.cancel()
                if once.claim() { cont.resume(with: result) } else if case .success(let v) = result { late(v) }
            }
        }
    }

    /// The connection's startup SQL, one statement per `;`.
    static func statements(_ sql: String) -> [String] {
        sql.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func readOnly(_ c: DatabaseConnection) -> Bool { c.effectiveReadOnly && !c.writeUnlocked }

    private func connectPostgres(_ c: DatabaseConnection, host: String, port: Int, password: String?) async throws -> PostgresConnection {
        let tls: PostgresConnection.Configuration.TLS
        switch c.sslMode {
        case .disable: tls = .disable
        case .prefer: tls = .prefer(try NIOSSLContext(configuration: .clientDefault))
        case .require: tls = .require(try NIOSSLContext(configuration: .clientDefault))
        }
        var config = PostgresConnection.Configuration(host: host, port: port, username: c.user, password: password,
                                                      database: c.database.isEmpty ? nil : c.database, tls: tls)
        config.options.connectTimeout = .seconds(Int64(c.connectTimeout ?? 10))
        return try await PostgresConnection.connect(configuration: config, id: 1, logger: Self.logger)
    }

    private func connectMySQL(_ c: DatabaseConnection, host: String, port: Int, password: String?) async throws -> MySQLConnection {
        let group = MultiThreadedEventLoopGroup.singleton
        let address = try SocketAddress.makeAddressResolvingHost(host, port: port)
        var tls: TLSConfiguration? = nil
        if c.sslMode != .disable {
            tls = .makeClientConfiguration()
            if c.sslMode == .prefer { tls?.certificateVerification = .none }
        }
        return try await Self.timeout(c.connectTimeout ?? 10,
                                      MySQLConnection.connect(to: address, username: c.user, database: c.database, password: password,
                                                              tlsConfiguration: tls, serverHostname: host, on: group.any())) { late in _ = late.close() }
    }

    /// SQLite databases with a statement running, for Stop.
    private let sqliteLock = NSLock()
    private var sqliteQueues: [ResourceID: DatabaseQueue] = [:]
    private func sqliteRunning(_ id: ResourceID, _ q: DatabaseQueue?) { sqliteLock.lock(); sqliteQueues[id] = q; sqliteLock.unlock() }
    private func sqliteQueue(_ id: ResourceID) -> DatabaseQueue? { sqliteLock.lock(); defer { sqliteLock.unlock() }; return sqliteQueues[id] }

    /// Open SQLite files, reused across calls (keyed by path, read-only and lock wait).
    private var sqliteOpen: [String: DatabaseQueue] = [:]
    private func openSQLite(_ path: String, _ config: Configuration, timeout: Int) throws -> DatabaseQueue {
        // The inode too: a file deleted and made again (or swapped) gets a fresh handle.
        let inode = (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int) ?? 0
        let key = "\(path)|\(inode)|\(config.readonly)|\(timeout)"
        sqliteLock.lock(); defer { sqliteLock.unlock() }
        if let q = sqliteOpen[key] { return q }
        let q = try DatabaseQueue(path: path, configuration: config)
        sqliteOpen[key] = q
        return q
    }

    private func sqlite(_ c: DatabaseConnection, _ sqls: [String], expect: [Int?] = []) async throws -> [RawResult] {
        let path = (c.filePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { throw ServiceError("SQLite file not found: \(c.filePath)") }
        var config = Configuration()
        config.readonly = readOnly(c)
        config.busyMode = .timeout(TimeInterval(c.connectTimeout ?? 5))
        do {
            let queue = try openSQLite(path, config, timeout: c.connectTimeout ?? 5)
            sqliteRunning(c.id, queue)
            // An agent's call stops after 30 s, like on the servers.
            // ponytail: interrupts whatever the file's queue runs at that moment; a per-call progress handler if that bites.
            let deadline = Self.agent ? DispatchWorkItem { queue.interrupt() } : nil
            if let deadline { DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline) }
            defer { sqliteRunning(c.id, nil); deadline?.cancel() }
            let cap = Self.agent ? AgentDBPolicy.rowCap : .max
            // A PRAGMA such as foreign_keys does nothing inside a transaction, so those run outside one.
            let pragma = sqls.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("pragma") }
            let body: @Sendable (Database) throws -> [RawResult] = { db in
                try sqls.enumerated().map { i, sql in
                    let stmt = try db.makeStatement(sql: sql)
                    var r = RawResult()
                    r.columns = stmt.columnNames
                    let want = expect.indices.contains(i) ? expect[i] : nil
                    if stmt.columnCount == 0 {
                        try stmt.execute()
                        r.affected = db.changesCount
                        try Self.verify(r, sql, expected: want)
                        return r
                    }
                    var rows: [Row] = []
                    let cursor = try Row.fetchCursor(stmt)
                    while rows.count < cap, let row = try cursor.next() { rows.append(row.copy()) }
                    r.rows = rows.map { row in
                        (0..<row.count).map { i -> String? in
                            switch row[i] as DatabaseValue? {
                            case .none: return nil
                            case .some(let v):
                                switch v.storage {
                                case .null: return nil
                                case .int64(let x): return String(x)
                                case .double(let x): return String(x)
                                case .string(let s): return s
                                case .blob(let d): return "<\(d.count) bytes>"
                                }
                            }
                        }
                    }
                    r.types = (0..<stmt.columnCount).map { i in
                        rows.first.map { row -> String in
                            switch (row[i] as DatabaseValue?)?.storage {
                            case .int64: "integer"
                            case .double: "real"
                            case .blob: "blob"
                            default: "text"
                            }
                        } ?? "text"
                    }
                    return r
                }
            }
            return pragma ? try await queue.writeWithoutTransaction(body) : try await queue.write(body)
        } catch let e as DatabaseError {
            // A broken handle shouldn't be reused: open the file fresh next time.
            if [ResultCode.SQLITE_CANTOPEN, .SQLITE_CORRUPT, .SQLITE_NOTADB, .SQLITE_IOERR].contains(e.resultCode.primaryResultCode) {
                sqliteLock.withLock { sqliteOpen = sqliteOpen.filter { !$0.key.hasPrefix(path + "|") } }
            }
            throw ServiceError(e.message ?? e.description)
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? ServiceError { return e.message }
        if let p = error as? PSQLError {
            if let msg = p.serverInfo?[.message] { return "ERROR: \(msg)" }
            return String(reflecting: p.code)
        }
        return String(describing: error)
    }

    static func isTrue(_ s: String?) -> Bool { s == "true" || s == "t" }

    /// A file only this user can read, alone in a new private folder: for a password a
    /// tool reads, instead of its environment. `removeSecret` deletes it.
    static func secretFile(_ text: String, name: String = "secret") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            try? FileManager.default.removeItem(at: dir)
            throw ServiceError("Couldn't write a temporary file for the password")
        }
        return file
    }

    static func removeSecret(_ file: URL) {
        do { try FileManager.default.removeItem(at: file.deletingLastPathComponent()) } catch {
            logger.warning("couldn't remove \(file.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
    }

    static func quote(_ ident: String, _ kind: DBKind) -> String {
        kind == .mysql ? "`" + ident.replacingOccurrences(of: "`", with: "``") + "`" : "\"" + ident.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A quoted string literal. MySQL also treats `\` as an escape, so it is doubled there.
    static func literal(_ s: String, _ kind: DBKind) -> String {
        let t = kind == .mysql ? s.replacingOccurrences(of: "\\", with: "\\\\") : s
        return "'" + t.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // MARK: DatabaseService

    func test(_ c: DatabaseConnection, password: String?) async throws -> DBTestResult {
        let start = Date()
        let sql = switch c.kind {
        case .postgres: "select version()"
        case .mysql: "select concat('MySQL ', version())"
        case .sqlite: "select 'SQLite ' || sqlite_version()"
        }
        let r = try await run(c, password: password, [sql])
        let raw = r.first?.rows.first?.first.flatMap { $0 } ?? c.kind.label
        let version = raw.components(separatedBy: " on ").first?.components(separatedBy: ",").first ?? raw
        return DBTestResult(version: version, latencyMs: (Date().timeIntervalSince(start) * 1000).rounded())
    }

    func schema(_ c: DatabaseConnection, password: String?) async throws -> DBSchemaTree {
        let sqls: [String]
        switch c.kind {
        case .postgres:
            sqls = ["""
            select n.nspname, c.relname, c.relkind, greatest(c.reltuples, 0)::bigint
            from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where c.relkind in ('r','v','m','p') and n.nspname not in ('pg_catalog','information_schema') and n.nspname not like 'pg_toast%'
            order by 1, 2
            """, """
            select n.nspname, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname not in ('pg_catalog','information_schema') order by 1, 2 limit 500
            """]
        case .mysql:
            // Every database on the server. ponytail: capped at 20,000 tables; page
            // the list per database if a server has more.
            sqls = ["select table_schema, table_name, if(table_type = 'VIEW', 'v', 'r'), coalesce(table_rows, 0) from information_schema.tables where table_schema not in ('information_schema','mysql','performance_schema','sys') order by 1, 2 limit 20000",
                    "select routine_schema, routine_name from information_schema.routines where routine_schema not in ('information_schema','mysql','performance_schema','sys') order by 1, 2"]
        case .sqlite:
            sqls = ["select 'main', name, case type when 'view' then 'v' else 'r' end, 0 from sqlite_master where type in ('table','view') and name not like 'sqlite_%' order by name"]
        }
        let res = try await run(c, password: password, sqls)
        var schemas: [String: [DBObject]] = [:]
        for row in res[0].rows {
            guard let s = row[0], let name = row[1] else { continue }
            let kind: DBObjectKind = (row[2] == "v" || row[2] == "m") ? .view : .table
            schemas[s, default: []].append(DBObject(schema: s, name: name, kind: kind, rowEstimate: kind == .table ? Int(row[3] ?? "") : nil))
        }
        if res.count > 1 {
            for row in res[1].rows {
                guard let s = row[0], let name = row[1] else { continue }
                schemas[s, default: []].append(DBObject(schema: s, name: name, kind: .function, rowEstimate: nil))
            }
        }
        return DBSchemaTree(database: c.kind == .sqlite ? c.name : c.database, schemas: schemas)
    }

    func tableDetail(_ c: DatabaseConnection, object: DBObject, password: String?) async throws -> TableDetail {
        let s = Self.literal(object.schema, c.kind), t = Self.literal(object.name, c.kind)
        switch c.kind {
        case .postgres:
            let res = try await run(c, password: password, [
                """
                select a.attname, format_type(a.atttypid, a.atttypmod), not a.attnotnull, pg_get_expr(d.adbin, d.adrelid),
                  exists(select 1 from pg_constraint k where k.conrelid = a.attrelid and k.contype = 'p' and a.attnum = any(k.conkey)),
                  (select confrelid::regclass || '.' || (select attname from pg_attribute where attrelid = k.confrelid and attnum = k.confkey[1])
                     from pg_constraint k where k.conrelid = a.attrelid and k.contype = 'f' and a.attnum = any(k.conkey) limit 1)
                from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                where a.attrelid = (quote_ident(\(s)) || '.' || quote_ident(\(t)))::regclass and a.attnum > 0 and not a.attisdropped
                order by a.attnum
                """,
                """
                select i.relname, array_to_string(array(select pg_get_indexdef(ix.indexrelid, k + 1, true) from generate_subscripts(ix.indkey, 1) k), ', '),
                  ix.indisunique, am.amname, pg_size_pretty(pg_relation_size(ix.indexrelid))
                from pg_index ix join pg_class i on i.oid = ix.indexrelid join pg_am am on am.oid = i.relam
                where ix.indrelid = (quote_ident(\(s)) || '.' || quote_ident(\(t)))::regclass
                """,
                "select greatest(reltuples, 0)::bigint, pg_size_pretty(pg_total_relation_size(oid)) from pg_class where oid = (quote_ident(\(s)) || '.' || quote_ident(\(t)))::regclass"
            ])
            let cols = res[0].rows.map { r in
                // Booleans come back as "true"/"false" (older servers' text form is "t"/"f").
                DBColumn(name: r[0] ?? "", type: r[1] ?? "", nullable: Self.isTrue(r[2]), defaultValue: r[3], isPK: Self.isTrue(r[4]), fk: r[5])
            }
            let idx = res[1].rows.map { r in
                DBIndex(name: r[0] ?? "", columns: (r[1] ?? "").components(separatedBy: ", "), unique: Self.isTrue(r[2]), method: r[3] ?? "", size: r[4] ?? "")
            }
            return TableDetail(columns: cols, indexes: idx, rowEstimate: Int(res[2].rows.first?[0] ?? "") ?? 0, size: res[2].rows.first?[1] ?? "")
        case .mysql:
            let res = try await run(c, password: password, [
                """
                select c.column_name, c.column_type, c.is_nullable = 'YES', c.column_default, c.column_key = 'PRI',
                  (select concat(k.referenced_table_schema, '.', k.referenced_table_name, '.', k.referenced_column_name) from information_schema.key_column_usage k
                     where k.table_schema = c.table_schema and k.table_name = c.table_name and k.column_name = c.column_name and k.referenced_table_name is not null limit 1)
                from information_schema.columns c where c.table_schema = \(s) and c.table_name = \(t) order by c.ordinal_position
                """,
                "select index_name, group_concat(column_name order by seq_in_index separator ', '), max(non_unique) = 0, max(index_type) from information_schema.statistics where table_schema = \(s) and table_name = \(t) group by index_name",
                "select coalesce(table_rows, 0), concat(round((data_length + index_length) / 1024), ' kB') from information_schema.tables where table_schema = \(s) and table_name = \(t)"
            ])
            let cols = res[0].rows.map { r in DBColumn(name: r[0] ?? "", type: r[1] ?? "", nullable: r[2] == "1", defaultValue: r[3], isPK: r[4] == "1", fk: r[5]) }
            let idx = res[1].rows.map { r in DBIndex(name: r[0] ?? "", columns: (r[1] ?? "").components(separatedBy: ", "), unique: r[2] == "1", method: (r[3] ?? "").lowercased(), size: "") }
            return TableDetail(columns: cols, indexes: idx, rowEstimate: Int(res[2].rows.first?[0] ?? "") ?? 0, size: res[2].rows.first?[1] ?? "")
        case .sqlite:
            let q = Self.quote(object.name, .sqlite)
            let res = try await run(c, password: password, ["pragma table_info(\(q))", "pragma foreign_key_list(\(q))", "pragma index_list(\(q))", "select count(*) from \(q)"])
            let fks = Dictionary(res[1].rows.compactMap { r -> (String, String)? in
                guard r.count > 4, let from = r[3], let table = r[2] else { return nil }
                return (from, "\(table).\(r[4] ?? "")")
            }, uniquingKeysWith: { a, _ in a })
            let cols = res[0].rows.map { r in
                DBColumn(name: r[1] ?? "", type: r[2] ?? "", nullable: r[3] == "0", defaultValue: r[4], isPK: (Int(r[5] ?? "0") ?? 0) > 0, fk: fks[r[1] ?? ""])
            }
            let idx = res[2].rows.map { r in DBIndex(name: r[1] ?? "", columns: [], unique: r[2] == "1", method: "btree", size: "") }
            return TableDetail(columns: cols, indexes: idx, rowEstimate: Int(res[3].rows.first?[0] ?? "") ?? 0, size: "")
        }
    }

    func rows(_ c: DatabaseConnection, object: DBObject, filter: String, sort: (column: String, ascending: Bool)?, page: Int, pageSize: Int, password: String?) async throws -> QueryResult {
        let start = Date()
        let table = c.kind == .sqlite ? Self.quote(object.name, .sqlite) : Self.quote(object.schema, c.kind) + "." + Self.quote(object.name, c.kind)
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let whereClause = f.isEmpty ? "" : " where \(f)"
        let detail = try? await tableDetail(c, object: object, password: password)
        // Unsorted pages go in key order, so none repeat or go missing.
        let pk = (detail?.columns ?? []).filter(\.isPK).map { Self.quote($0.name, c.kind) }.joined(separator: ", ")
        let order = sort.map { " order by \(Self.quote($0.column, c.kind)) \($0.ascending ? "asc" : "desc")" } ?? (pk.isEmpty ? "" : " order by \(pk)")
        let select = "select * from \(table)\(whereClause)\(order) limit \(pageSize) offset \(page * pageSize)"
        let count = f.isEmpty && object.rowEstimate != nil && (object.rowEstimate ?? 0) > 50_000
            ? "select \(object.rowEstimate ?? 0)"
            : "select count(*) from \(table)\(whereClause)"
        let res = try await run(c, password: password, [select, count])
        let types = Dictionary(detail?.columns.map { ($0.name, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        let cols = res[0].columns.enumerated().map { i, n in
            types[n] ?? DBColumn(name: n, type: i < res[0].types.count ? res[0].types[i] : "")
        }
        let total = Int(res[1].rows.first?.first.flatMap { $0 } ?? "") ?? res[0].rows.count
        return QueryResult(columns: cols, rows: res[0].rows, totalRows: total, elapsedMs: (Date().timeIntervalSince(start) * 1000).rounded())
    }

    func page(_ c: DatabaseConnection, object: DBObject, where w: String, orderBy: String, page: Int, pageSize: Int, columns known: [DBColumn]?, password: String?) async throws -> QueryResult {
        let start = Date()
        let table = c.kind == .sqlite ? Self.quote(object.name, .sqlite) : Self.quote(object.schema, c.kind) + "." + Self.quote(object.name, c.kind)
        let f = w.trimmingCharacters(in: .whitespacesAndNewlines), o = orderBy.trimmingCharacters(in: .whitespacesAndNewlines)
        let whereClause = f.isEmpty ? "" : " where \(f)"
        let columns: [DBColumn]
        if let known { columns = known } else { columns = try await tableDetail(c, object: object, password: password).columns }
        // Pages need a fixed order, or rows repeat or go missing between them: the key's, unless sorted.
        let pk = columns.filter(\.isPK).map { Self.quote($0.name, c.kind) }.joined(separator: ", ")
        let order = o.isEmpty ? (pk.isEmpty ? "" : " order by \(pk)") : " order by \(o)"
        let select = "select * from \(table)\(whereClause)\(order) limit \(pageSize) offset \(page * pageSize)"
        let count = f.isEmpty && (object.rowEstimate ?? 0) > 50_000 ? "select \(object.rowEstimate ?? 0)" : "select count(*) from \(table)\(whereClause)"
        let res = try await run(c, password: password, [select, count])
        let types = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        // An empty page may not name its columns; the table's are the same.
        let names = res[0].columns.isEmpty ? columns.map(\.name) : res[0].columns
        let cols = names.enumerated().map { i, n in types[n] ?? DBColumn(name: n, type: i < res[0].types.count ? res[0].types[i] : "") }
        let total = Int(res[1].rows.first?.first.flatMap { $0 } ?? "") ?? res[0].rows.count
        return QueryResult(columns: cols, rows: res[0].rows, totalRows: total, elapsedMs: (Date().timeIntervalSince(start) * 1000).rounded())
    }

    /// Several statements in one transaction: all of them or none.
    func executeBatch(_ c: DatabaseConnection, sqls: [String], expect: [Int?], password: String?) async throws -> QueryResult {
        let start = Date()
        // GRDB's write already wraps SQLite in a transaction.
        let res = try await run(c, password: password, sqls, atomic: c.kind != .sqlite, expect: expect)
        let affected = res.compactMap(\.affected).reduce(0, +)
        return QueryResult(columns: [], rows: [], totalRows: 0, elapsedMs: (Date().timeIntervalSince(start) * 1000).rounded(),
                           message: c.kind == .sqlite ? "\(affected) row\(affected == 1 ? "" : "s") changed" : "\(sqls.count) statement\(sqls.count == 1 ? "" : "s") committed")
    }

    func execute(_ c: DatabaseConnection, sql: String, password: String?) async throws -> QueryResult {
        let start = Date()
        let res = try await run(c, password: password, [sql])
        let r = res.last ?? RawResult()
        let cols = r.columns.enumerated().map { i, n in DBColumn(name: n, type: i < r.types.count ? r.types[i] : "") }
        let msg: String? = r.columns.isEmpty ? (r.affected.map { "\($0) row\($0 == 1 ? "" : "s") affected" } ?? "Query OK") : nil
        return QueryResult(columns: cols, rows: r.rows, totalRows: r.rows.count, elapsedMs: (Date().timeIntervalSince(start) * 1000).rounded(), message: msg)
    }
}

/// `ssh -N -L` port forward through a saved host, closed when the call ends.
final class SSHTunnel {
    let localPort: Int
    private let process: Process

    private init(localPort: Int, process: Process) {
        self.localPort = localPort
        self.process = process
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func portOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    static func open(via host: SSHHost, password: String?, to target: String, port: Int) async throws -> SSHTunnel {
        let local = freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = SSHCommand.args(host, batch: host.auth != .password,
                                      extra: ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveCountMax=3", "-L", "127.0.0.1:\(local):\(target):\(port)"])
        var env = ProcessRunner.environment()
        // The password goes in a file only this user can read, gone once ssh has signed in
        // (or given up), rather than in the environment of a process that lives for hours.
        var secret: URL?
        defer { if let secret { LiveDatabaseService.removeSecret(secret) } }
        if host.auth == .password {
            guard let password, !password.isEmpty else { throw ServiceError("No password saved for \(host.name), so the SSH tunnel can't sign in") }
            let file = try LiveDatabaseService.secretFile(password + "\n")
            secret = file
            let askpass = file.deletingLastPathComponent().appendingPathComponent("askpass")
            try "#!/bin/sh\nexec /bin/cat \"${0%/*}/\(file.lastPathComponent)\"\n".write(to: askpass, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
            env["SSH_ASKPASS"] = askpass.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":0"
        }
        p.environment = env
        let err = ProcessRunner.pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { throw ServiceError("Could not start ssh: \(error.localizedDescription)") }
        let tunnel = SSHTunnel(localPort: local, process: p)
        for _ in 0..<80 {
            if !p.isRunning {
                let msg = String(decoding: err.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ServiceError("SSH tunnel via \(host.name) failed: \(msg.isEmpty ? "exit \(p.terminationStatus)" : msg)")
            }
            if portOpen(local) {
                // Keep reading what ssh says from here on, so a full pipe never stalls it.
                err.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { h.readabilityHandler = nil; return }
                    LiveDatabaseService.logger.warning("ssh tunnel via \(host.name): \(String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                return tunnel
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        tunnel.close()
        throw ServiceError("SSH tunnel via \(host.name) timed out")
    }

    func close() {
        if process.isRunning { process.terminate() }
    }

    deinit { close() }
}

/// True for the first caller only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// One open driver session (and its SSH tunnel) for a saved connection.
final class DBSession: @unchecked Sendable {
    let key: String
    let pg: PostgresConnection?
    let my: MySQLConnection?
    let tunnel: SSHTunnel?
    var serverID: String?
    var lastUse = Date()

    init(key: String, pg: PostgresConnection? = nil, my: MySQLConnection? = nil, tunnel: SSHTunnel?) {
        self.key = key; self.pg = pg; self.my = my; self.tunnel = tunnel
    }

    var isClosed: Bool { pg?.isClosed ?? my?.isClosed ?? true }

    func setReadOnly(_ on: Bool) async throws {
        // Set on every call, never cached: a statement on the shared session could have changed it.
        if pg != nil {
            _ = try await query("SET default_transaction_read_only = \(on ? "on" : "off")")
        } else {
            _ = try await query(on ? "SET SESSION TRANSACTION READ ONLY" : "SET SESSION TRANSACTION READ WRITE")
        }
    }

    /// Runs one statement: its columns (even with no rows), at most `cap` rows, and the
    /// rows an INSERT, UPDATE or DELETE changed. `describe`: a Postgres query that
    /// returns no rows is described by a second, empty query (not inside a transaction).
    func query(_ sql: String, cap: Int = .max, describe: Bool = false) async throws -> LiveDatabaseService.RawResult {
        var r = LiveDatabaseService.RawResult()
        if let pg {
            let got = PGRows(cap: cap)
            try await pg.query(sql, [], onMetadata: { got.tag = $0 }, onRow: { got.add($0) }).get()
            var head = got.rows.first
            if head == nil, describe, got.tag?.command == "SELECT", let probe = Self.describeSQL(sql) {
                // Best effort: without it the empty result just has no column names.
                do { head = try await pg.simpleQuery(probe).get().first } catch {
                    LiveDatabaseService.logger.debug("couldn't describe an empty result: \(LiveDatabaseService.describe(error))")
                }
            }
            if let head {
                let ra = head.makeRandomAccess()
                r.columns = ra.map(\.columnName)
                r.types = ra.map { String(describing: $0.dataType).lowercased() }
            }
            r.rows = got.rows.map { row in row.makeRandomAccess().map(Self.text) }
            if let tag = got.tag, tag.command != "SELECT" { r.affected = tag.rows }
        } else if let my {
            let q = MySQLTextQuery(sql, cap: cap)
            try await my.send(q, logger: LiveDatabaseService.logger).get()
            r.columns = q.columns.map(\.name)
            r.types = q.columns.map { "\($0.columnType)".lowercased() }
            r.rows = q.rows.map { values in
                zip(q.columns, values).map { def, value in
                    MySQLData(type: def.columnType, format: .text, buffer: value, isUnsigned: def.flags.contains(.COLUMN_UNSIGNED)).string
                }
            }
            r.affected = q.affected.map(Int.init)
        }
        return r
    }

    /// A query that returns one row of NULLs with the columns `sql` would return, without
    /// running it (the join is on false). Only for what can be a subquery.
    static func describeSQL(_ sql: String) -> String? {
        let s = sql.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
        let head = SQLText.code(s, mysql: false).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["select", "with", "values", "table "].contains(where: head.hasPrefix) else { return nil }
        return "select brix_q.* from (select 1) brix_one left join (\n\(s)\n) brix_q on false"
    }

    /// A Postgres value as text. Results arrive in binary, so each type is decoded
    /// by its own layout; one Brix can't read shows as "<type value>".
    static func text(_ cell: PostgresCell) -> String? {
        guard var b = cell.bytes else { return nil }
        if cell.format == .text { return b.readString(length: b.readableBytes) }
        let other = "<\(cell.dataType) value>"
        switch cell.dataType {
        case .text, .varchar, .bpchar, .name, .char, .json, .jsonb, .xml, .unknown: return (try? cell.decode(String.self)) ?? other
        case .bool: return (try? cell.decode(Bool.self)).map { $0 ? "true" : "false" }
        case .int2, .int4, .int8: return (try? cell.decode(Int64.self)).map(String.init)
        case .oid, .regclass, .regproc, .regtype, .regnamespace, .regrole, .xid, .cid: return b.readInteger(as: UInt32.self).map(String.init) ?? other
        case .float4, .float8: return (try? cell.decode(Double.self)).map { String($0) }
        case .numeric: return numeric(&b) ?? other
        case .uuid: return (try? cell.decode(UUID.self)).map { $0.uuidString.lowercased() }
        case .timestamptz: return b.readInteger(as: Int64.self).map { stamp($0, utc: true) } ?? other
        case .timestamp: return b.readInteger(as: Int64.self).map { stamp($0, utc: false) } ?? other
        case .date: return (try? cell.decode(Date.self)).map { day.string(from: $0) }
        case .time: return b.readInteger(as: Int64.self).map { clock($0) } ?? other
        case .timetz:
            guard let t = b.readInteger(as: Int64.self), let west = b.readInteger(as: Int32.self) else { return other }
            let east = -Int(west), h = abs(east) / 3600, m = abs(east) % 3600 / 60
            return clock(t) + (east < 0 ? "-" : "+") + String(format: "%02d", h) + (m == 0 ? "" : String(format: ":%02d", m))
        case .interval:
            guard let t = b.readInteger(as: Int64.self), let days = b.readInteger(as: Int32.self), let months = b.readInteger(as: Int32.self) else { return other }
            let unit = { (n: Int32, one: String, many: String) in n == 0 ? nil : "\(n) \(abs(n) == 1 ? one : many)" }
            let parts = [unit(months / 12, "year", "years"), unit(months % 12, "mon", "mons"), unit(days, "day", "days")].compactMap { $0 }
            return (parts + (t != 0 || parts.isEmpty ? [(t < 0 ? "-" : "") + clock(abs(t))] : [])).joined(separator: " ")
        case .bytea: return "<\(b.readableBytes) bytes>"
        case .int2Array, .int4Array, .int8Array: return (try? cell.decode([Int64].self)).map { "{" + $0.map(String.init).joined(separator: ",") + "}" } ?? other
        case .textArray, .varcharArray, .bpcharArray, .nameArray:
            return (try? cell.decode([String].self)).map { "{" + $0.map(arrayItem).joined(separator: ",") + "}" } ?? other
        default:
            // Enums, citext and other types of the database's own arrive as their text.
            if cell.dataType.isUserDefined, let s = b.readString(length: b.readableBytes), s.unicodeScalars.allSatisfy({ $0.value >= 9 }) { return s }
            return other
        }
    }

    /// Postgres's binary numeric: base-10000 digits, so any size and scale survive, and NaN and Infinity too.
    static func numeric(_ b: inout ByteBuffer) -> String? {
        guard let n = b.readInteger(as: Int16.self), let weight = b.readInteger(as: Int16.self),
              let sign = b.readInteger(as: UInt16.self), let scale = b.readInteger(as: Int16.self) else { return nil }
        switch sign {
        case 0xC000: return "NaN"
        case 0xD000: return "Infinity"
        case 0xF000: return "-Infinity"
        default: break
        }
        var digits: [Int] = []
        for _ in 0..<max(0, Int(n)) { guard let d = b.readInteger(as: Int16.self) else { return nil }; digits.append(Int(d)) }
        let digit = { (i: Int) in digits.indices.contains(i) ? digits[i] : 0 }
        var int = weight < 0 ? "0" : String(digit(0))
        if weight > 0 { for i in 1...Int(weight) { int += String(format: "%04d", digit(i)) } }
        var frac = "", i = Int(weight) + 1
        while frac.count < Int(scale) { frac += String(format: "%04d", digit(i)); i += 1 }
        let s = int + (scale > 0 ? "." + frac.prefix(Int(scale)) : "")
        return sign == 0x4000 ? "-" + s : s
    }

    /// Microseconds from 2000-01-01 as Postgres prints them, the fraction only when there is one.
    /// `utc`: a timestamptz, shown in UTC with its offset.
    static func stamp(_ micros: Int64, utc: Bool) -> String {
        if micros == .max { return "infinity" }
        if micros == .min { return "-infinity" }
        var (secs, frac) = micros.quotientAndRemainder(dividingBy: 1_000_000)
        if frac < 0 { secs -= 1; frac += 1_000_000 }
        return naive.string(from: Date(timeIntervalSince1970: 946_684_800 + TimeInterval(secs))) + fraction(frac) + (utc ? "+00" : "")
    }

    /// A time of day (or an interval's time) from microseconds: 25:00:00 past a day.
    static func clock(_ micros: Int64) -> String {
        let (secs, frac) = micros.quotientAndRemainder(dividingBy: 1_000_000)
        return String(format: "%02lld:%02lld:%02lld", secs / 3600, secs % 3600 / 60, secs % 60) + fraction(frac)
    }

    private static func fraction(_ micros: Int64) -> String {
        micros == 0 ? "" : "." + String(String(format: "%06lld", micros).reversed().drop { $0 == "0" }.reversed())
    }

    /// An array element as Postgres writes it: quoted when it has to be.
    private static func arrayItem(_ s: String) -> String {
        guard s.isEmpty || s.lowercased() == "null" || s.contains(where: { "{},\"\\".contains($0) || $0.isWhitespace }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func formatter(_ f: String, utc: Bool) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.dateFormat = f
        if utc { d.timeZone = TimeZone(identifier: "UTC") }
        return d
    }
    private static let naive = formatter("yyyy-MM-dd HH:mm:ss", utc: true)
    private static let day = formatter("yyyy-MM-dd", utc: true)

    func close() {
        if let pg { Task { try? await pg.close() } }
        // The close future keeps the connection alive until it has really closed
        // (MySQLNIO asserts if one is freed while still open).
        if let my { my.close().whenComplete { _ in _ = my } }
        tunnel?.close()
    }
}

/// Rows of a Postgres query as they arrive (on the event loop), up to a cap, and its command tag.
private final class PGRows: @unchecked Sendable {
    private let lock = NSLock()
    private let cap: Int
    private var kept: [PostgresRow] = []
    private var meta: PostgresQueryMetadata?
    init(cap: Int) { self.cap = cap }
    func add(_ row: PostgresRow) { lock.withLock { if kept.count < cap { kept.append(row) } } }
    var rows: [PostgresRow] { lock.withLock { kept } }
    var tag: PostgresQueryMetadata? {
        get { lock.withLock { meta } }
        set { lock.withLock { meta = newValue } }
    }
}

/// MySQL's text query, like MySQLNIO's simpleQuery, but it keeps the columns of an
/// empty result and the OK packet's row count, and stops keeping rows after `cap`.
private final class MySQLTextQuery: MySQLCommand, @unchecked Sendable {
    let sql: String
    let cap: Int
    var columns: [MySQLProtocol.ColumnDefinition41] = []
    var rows: [[ByteBuffer?]] = []
    var affected: UInt64?
    private var expected: Int?

    init(_ sql: String, cap: Int) { self.sql = sql; self.cap = cap }

    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        MySQLCommandState(response: [try .encode(MySQLProtocol.COM_QUERY(query: sql), capabilities: capabilities)])
    }

    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if packet.isError { throw MySQLError.server(try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities)) }
        guard let expected else {
            if packet.isOK {
                affected = try packet.decode(MySQLProtocol.OK_Packet.self, capabilities: capabilities).affectedRows
                return MySQLCommandState(done: true)
            }
            self.expected = Int(try packet.decode(MySQLProtocol.COM_QUERY_Response.self, capabilities: capabilities).columnCount)
            return MySQLCommandState()
        }
        if columns.count < expected {
            columns.append(try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities))
            return MySQLCommandState()
        }
        if packet.isEOF { return MySQLCommandState(done: true) }
        let row = try MySQLProtocol.TextResultSetRow.decode(from: &packet, columnCount: columns.count)
        if rows.count < cap { rows.append(row.values) }
        return MySQLCommandState()
    }
}

/// Open sessions by connection, plus a per-connection queue so one call's
/// settings (read-only on or off) can't mix with another's. Idle sessions
/// close after five minutes.
actor DBSessionPool {
    private var sessions: [ResourceID: DBSession] = [:]
    /// The tab (owner tag) whose call holds each connection's session.
    private var holders: [ResourceID: String] = [:]
    private var waiters: [ResourceID: [(ticket: UUID, cont: CheckedContinuation<Bool, Never>)]] = [:]
    private var sweeper: Task<Void, Never>?

    deinit {
        sweeper?.cancel()
        for s in sessions.values { s.close() }
    }

    /// Waits for the connection's session; gives up (throws) when the caller is cancelled.
    func acquire(_ id: ResourceID, owner: String) async throws {
        while holders[id] != nil {
            let ticket = UUID()
            let granted = await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    waiters[id, default: []].append((ticket, cont))
                }
            } onCancel: {
                Task { await self.drop(id, ticket) }
            }
            if Task.isCancelled {
                // Woken but no longer wanted: pass the turn on so nobody waits forever.
                if granted, holders[id] == nil { wakeNext(id) }
                throw CancellationError()
            }
            if !granted { throw CancellationError() }
        }
        holders[id] = owner
    }

    private func drop(_ id: ResourceID, _ ticket: UUID) {
        guard let i = waiters[id]?.firstIndex(where: { $0.ticket == ticket }) else { return }
        waiters[id]?.remove(at: i).cont.resume(returning: false)
    }

    func release(_ id: ResourceID) {
        holders[id] = nil
        wakeNext(id)
    }

    private func wakeNext(_ id: ResourceID) {
        guard let next = waiters[id]?.first else { return }
        waiters[id]?.removeFirst()
        next.cont.resume(returning: true)
    }

    func holder(_ id: ResourceID) -> String? { holders[id] }

    func session(_ id: ResourceID) -> DBSession? { sessions[id] }

    func put(_ id: ResourceID, _ s: DBSession) {
        sessions[id] = s
        if sweeper == nil {
            sweeper = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    await self?.sweep()
                }
            }
        }
    }

    @discardableResult func remove(_ id: ResourceID) -> DBSession? { sessions.removeValue(forKey: id) }

    private func sweep() {
        for (id, s) in sessions where holders[id] == nil && Date().timeIntervalSince(s.lastUse) > 300 {
            sessions[id] = nil
            s.close()
        }
    }
}
