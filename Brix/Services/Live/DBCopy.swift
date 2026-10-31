import Foundation

/// Copies tables between two saved connections, any engine to any engine.
///
/// Values travel as text, but read with engine-native expressions so nothing
/// is lost on the way: binary as hex, Postgres values through `::text` (full
/// timestamp precision, arrays, json), MySQL through `CAST(… AS CHAR)`. They're
/// written back as the target engine's literals.
enum DBCopy {
    enum Mode: String, CaseIterable, Identifiable {
        case all, structure, data
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "Structure and data"
            case .structure: "Structure only"
            case .data: "Data only"
            }
        }
        var structure: Bool { self != .data }
        var data: Bool { self != .structure }
    }

    /// What happens to a table that's already in the target.
    enum Clash: String, CaseIterable, Identifiable {
        case skip, append, replace
        var id: String { rawValue }
        var label: String {
            switch self {
            case .skip: "Skip"
            case .append: "Add rows"
            case .replace: "Drop and recreate"
            }
        }
    }

    struct Column: Hashable {
        var name: String
        var sourceType: String
        var targetType: String
        var kind: DBTypeMap.Kind
        var nullable: Bool
        var isPK: Bool
        var auto: Bool
        var defaultSQL: String?
        var fk: (table: String, column: String)?
        static func == (a: Column, b: Column) -> Bool { a.name == b.name && a.targetType == b.targetType }
        func hash(into h: inout Hasher) { h.combine(name) }
    }

    struct Table: Identifiable {
        var id: String { source.id }
        var source: DBObject
        var columns: [Column]
        var indexes: [DBIndex]
        var rowEstimate: Int
        /// Already in the target, and what to do about it.
        var exists: Bool
        var clash: Clash = .skip
        var warnings: [String] = []
        var pk: [String] { columns.filter(\.isPK).map(\.name) }
    }

    struct Plan {
        var source: DatabaseConnection
        var target: DatabaseConnection
        var targetSchema: String
        var mode: Mode
        var tables: [Table]
        /// The target schema (Postgres) or database (MySQL) has to be created first.
        var createSchema: Bool
    }

    struct Outcome: Identifiable {
        var id: String { table }
        var table: String
        var rows: Int
        var state: String
        var error: String?
    }

    // MARK: Planning

    /// Reads the source tables and the target schema; writes nothing.
    static func plan(source: DatabaseConnection, sourcePassword: String?, objects: [DBObject],
                     target: DatabaseConnection, targetPassword: String?, targetSchema: String, mode: Mode,
                     service: DatabaseService) async throws -> Plan {
        let src = session(source), dst = session(target)
        let tree = try await service.schema(dst, password: targetPassword)
        let schemaName = target.kind == .sqlite ? "main" : targetSchema
        let existing = Set((tree.schemas[schemaName] ?? []).filter { $0.kind == .table }.map { $0.name.lowercased() })
        let schemaExists = target.kind == .sqlite || tree.schemas[schemaName] != nil
        var tables: [Table] = []
        for o in objects where o.kind == .table {
            try Task.checkCancellation()
            let d = try await service.tableDetail(src, object: o, password: sourcePassword)
            let auto = try await autoColumns(src, o, service: service, password: sourcePassword)
            var warnings: [String] = []
            let cols = d.columns.map { c -> Column in
                let m = DBTypeMap.map(c.type, from: source.kind, to: target.kind)
                if let note = m.note { warnings.append("\(c.name): \(note)") }
                let isAuto = auto.contains(c.name)
                let def = isAuto ? nil : DBTypeMap.defaultSQL(c.defaultValue, kind: m.kind, from: source.kind, to: target.kind)
                if c.defaultValue != nil, def == nil, !isAuto { warnings.append("\(c.name): default \(c.defaultValue ?? "") isn't copied") }
                return Column(name: c.name, sourceType: c.type, targetType: m.type, kind: m.kind, nullable: c.nullable, isPK: c.isPK,
                              auto: isAuto, defaultSQL: def, fk: c.fk.flatMap(splitFK))
            }
            var indexes = d.indexes.filter { i in
                let pkNames = Set(cols.filter(\.isPK).map(\.name))
                return !(i.name == "PRIMARY" || i.name.hasSuffix("_pkey") || (i.unique && Set(i.columns) == pkNames))
            }
            if source.kind == .sqlite { indexes = try await sqliteIndexColumns(src, indexes, service: service, password: sourcePassword) }
            // MySQL can't key or index unbounded text or binary: those columns get a length.
            let keyed = Set(indexes.flatMap(\.columns).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"`")) })
            let sized = cols.map { c -> Column in
                guard target.kind == .mysql, source.kind != .mysql, c.isPK || keyed.contains(c.name) else { return c }
                var x = c
                x.targetType = DBTypeMap.keyable(c.targetType, kind: .mysql)
                if x.targetType != c.targetType { warnings.append("\(c.name): \(x.targetType) in MySQL, since it's a key or indexed") }
                return x
            }
            tables.append(Table(source: o, columns: sized, indexes: indexes, rowEstimate: d.rowEstimate,
                                exists: existing.contains(o.name.lowercased()), warnings: warnings))
        }
        return Plan(source: source, target: target, targetSchema: schemaName, mode: mode, tables: tables, createSchema: !schemaExists)
    }

    /// Columns the source numbers by itself (serial, identity, AUTO_INCREMENT, SQLite's INTEGER PRIMARY KEY).
    private static func autoColumns(_ c: DatabaseConnection, _ o: DBObject, service: DatabaseService, password: String?) async throws -> Set<String> {
        let s = LiveDatabaseService.literal(o.schema, c.kind), t = LiveDatabaseService.literal(o.name, c.kind)
        switch c.kind {
        case .postgres:
            let r = try await service.execute(c, sql: "select column_name from information_schema.columns where table_schema = \(s) and table_name = \(t) and (column_default like 'nextval(%' or is_identity = 'YES')", password: password)
            return Set(r.rows.compactMap { $0.first ?? nil })
        case .mysql:
            let r = try await service.execute(c, sql: "select column_name from information_schema.columns where table_schema = \(s) and table_name = \(t) and extra like '%auto_increment%'", password: password)
            return Set(r.rows.compactMap { $0.first ?? nil })
        case .sqlite:
            // A lone INTEGER PRIMARY KEY is the rowid: it numbers itself.
            let r = try await service.execute(c, sql: "select name, type, pk from pragma_table_info(\(t))", password: password)
            let pks = r.rows.filter { (Int($0[2] ?? "0") ?? 0) > 0 }
            guard pks.count == 1, (pks[0][1] ?? "").uppercased() == "INTEGER", let n = pks[0][0] else { return [] }
            return [n]
        }
    }

    /// SQLite's index list has no columns; ask each index for them.
    private static func sqliteIndexColumns(_ c: DatabaseConnection, _ indexes: [DBIndex], service: DatabaseService, password: String?) async throws -> [DBIndex] {
        var out: [DBIndex] = []
        for i in indexes {
            let r = try await service.execute(c, sql: "select name from pragma_index_info(\(LiveDatabaseService.literal(i.name, .sqlite))) order by seqno", password: password)
            var x = i
            x.columns = r.rows.compactMap { $0.first ?? nil }
            // A UNIQUE constraint's index has a generated name: give it a readable one.
            if i.name.hasPrefix("sqlite_autoindex"), let t = i.name.components(separatedBy: "_").dropFirst(2).dropLast().joined(separator: "_") as String? {
                x.name = t + "_" + x.columns.joined(separator: "_") + "_key"
            }
            if !x.columns.isEmpty { out.append(x) }
        }
        return out
    }

    /// "public.users.id", "shop.users.id" or "users.id" → (users, id).
    static func splitFK(_ s: String) -> (table: String, column: String)? {
        let parts = s.components(separatedBy: ".").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"`")) }
        guard parts.count >= 2 else { return nil }
        return (parts[parts.count - 2], parts[parts.count - 1])
    }

    // MARK: SQL

    static func name(_ schema: String, _ table: String, _ kind: DBKind) -> String {
        kind == .sqlite ? LiveDatabaseService.quote(table, kind) : LiveDatabaseService.quote(schema, kind) + "." + LiveDatabaseService.quote(table, kind)
    }

    /// CREATE TABLE in the target's dialect. SQLite can't add foreign keys later, so it gets them inline.
    static func createTable(_ t: Table, schema: String, kind: DBKind, copiedTables: Set<String>, as table: String? = nil) -> String {
        let q = { LiveDatabaseService.quote($0, kind) }
        let pk = t.pk
        let lonePKAuto = pk.count == 1 && t.columns.first { $0.name == pk[0] }?.auto == true
        var lines = t.columns.map { c -> String in
            var s = q(c.name) + " "
            if kind == .sqlite, c.auto, lonePKAuto, c.isPK {
                return s + "INTEGER PRIMARY KEY AUTOINCREMENT"
            }
            s += c.targetType
            if c.auto {
                switch kind {
                case .postgres: s += " GENERATED BY DEFAULT AS IDENTITY"
                case .mysql: s += " AUTO_INCREMENT"
                case .sqlite: break
                }
            }
            if !c.nullable || c.isPK { s += " NOT NULL" }
            if let d = c.defaultSQL {
                // MySQL takes a default on TEXT, BLOB and JSON only as an expression.
                let t = c.targetType.lowercased()
                let wrap = kind == .mysql && (t.contains("text") || t.contains("blob") || t == "json") && !d.hasPrefix("(") && d != "NULL"
                s += " DEFAULT " + (wrap ? "(\(d))" : d)
            }
            if kind == .sqlite, let fk = c.fk, copiedTables.contains(fk.table.lowercased()) {
                s += " REFERENCES \(q(fk.table))(\(q(fk.column)))"
            }
            return s
        }
        if !pk.isEmpty, !(kind == .sqlite && lonePKAuto) {
            lines.append("PRIMARY KEY (" + pk.map(q).joined(separator: ", ") + ")")
        }
        // utf8mb4 so every character survives, whatever the server's default.
        return "CREATE TABLE \(name(schema, table ?? t.source.name, kind)) (\n  " + lines.joined(separator: ",\n  ") + "\n)" + (kind == .mysql ? " DEFAULT CHARSET=utf8mb4" : "")
    }

    static func createIndexes(_ t: Table, schema: String, kind: DBKind) -> [String] {
        let q = { LiveDatabaseService.quote($0, kind) }
        let cols = Set(t.columns.map(\.name))
        return t.indexes.compactMap { i in
            // Expression indexes (Postgres) aren't plain column lists: left out.
            let names = i.columns.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"`")) }
            guard !names.isEmpty, names.allSatisfy(cols.contains) else { return nil }
            return "CREATE \(i.unique ? "UNIQUE " : "")INDEX \(q(i.name)) ON \(name(schema, t.source.name, kind)) (" + names.map(q).joined(separator: ", ") + ")"
        }
    }

    static func foreignKeys(_ t: Table, schema: String, kind: DBKind, copiedTables: Set<String>) -> [String] {
        guard kind != .sqlite else { return [] }
        let q = { LiveDatabaseService.quote($0, kind) }
        return t.columns.compactMap { c in
            guard let fk = c.fk, copiedTables.contains(fk.table.lowercased()) else { return nil }
            return "ALTER TABLE \(name(schema, t.source.name, kind)) ADD FOREIGN KEY (\(q(c.name))) REFERENCES \(name(schema, fk.table, kind)) (\(q(fk.column)))"
        }
    }

    /// What to select from the source for each column, so its value arrives exactly.
    static func selectExpr(_ c: Column, source: DBKind, target: DBKind) -> String {
        let q = LiveDatabaseService.quote(c.name, source)
        switch (c.kind, source) {
        case (.binary, .postgres): return "encode(\(q), 'hex')"
        case (.binary, .mysql): return "HEX(\(q))"
        case (.binary, .sqlite): return "CASE WHEN \(q) IS NULL THEN NULL ELSE hex(\(q)) END"
        case (.bool, .postgres): return "CASE WHEN \(q) THEN '1' WHEN NOT \(q) THEN '0' END"
        // Another engine has no time zones in its datetime: the moment is carried in UTC.
        case (.timestamptz, .postgres) where target != .postgres: return "to_char(\(q) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US')"
        case (_, .postgres): return "\(q)::text"
        case (_, .mysql): return "CAST(\(q) AS CHAR)"
        case (_, .sqlite): return q
        }
    }

    /// One value as the target's literal.
    static func literal(_ v: String?, _ c: Column, target: DBKind) -> String {
        guard let v else { return "NULL" }
        switch c.kind {
        case .binary:
            let hex = v.filter(\.isHexDigit)
            return target == .postgres ? "decode('\(hex)', 'hex')" : "X'\(hex)'"
        case .bool:
            // Anything but a clear false is true (MySQL's tinyint(1) can hold 2).
            let on = !["0", "f", "false", "n", "no", "off", ""].contains(v.lowercased())
            return target == .postgres ? (on ? "true" : "false") : (on ? "1" : "0")
        case .int, .bigint, .smallint, .decimal, .float, .double:
            // Plain numbers go unquoted; anything else (NaN, Infinity) as a string the target can refuse.
            return v.range(of: #"^-?\d+(\.\d+)?([eE][-+]?\d+)?$"#, options: .regularExpression) != nil ? v : LiveDatabaseService.literal(v, target)
        case .time, .timestamp, .timestamptz:
            // MySQL's datetime(6) writes ".000000" on whole seconds; the same moment without it.
            return LiveDatabaseService.literal(v.replacingOccurrences(of: #"\.0+(?=$|[+-])"#, with: "", options: .regularExpression), target)
        default:
            return LiveDatabaseService.literal(v, target)
        }
    }

    static func insert(_ t: Table, columns: [Column], rows: [[String?]], schema: String, target: DBKind, into table: String? = nil) -> String {
        let q = { LiveDatabaseService.quote($0, target) }
        let values = rows.map { r in "(" + columns.indices.map { literal(r[$0], columns[$0], target: target) }.joined(separator: ", ") + ")" }
        return "INSERT INTO \(name(schema, table ?? t.source.name, target)) (" + columns.map { q($0.name) }.joined(separator: ", ") + ") VALUES\n" + values.joined(separator: ",\n")
    }

    // MARK: Running

    /// A copy of the connection with its own pooled session, so a long copy
    /// doesn't hold up the tabs using the connection.
    static func session(_ c: DatabaseConnection, write: Bool = false) -> DatabaseConnection {
        var x = c
        x.id = c.id + (write ? "#copy-to" : "#copy-from")
        x.writeUnlocked = write
        return x
    }

    /// Whether two connections reach the same database (same saved one, or the same server and database).
    static func sameDatabase(_ a: DatabaseConnection, _ b: DatabaseConnection) -> Bool {
        if a.id == b.id { return true }
        guard a.kind == b.kind else { return false }
        if a.kind == .sqlite {
            let p = { (s: String) in URL(fileURLWithPath: (s as NSString).expandingTildeInPath).resolvingSymlinksInPath().path }
            return p(a.filePath) == p(b.filePath)
        }
        let local: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]
        let host = { (s: String) in local.contains(s.lowercased()) ? "localhost" : s.lowercased() }
        return host(a.host) == host(b.host) && a.port == b.port && a.tunnelHostID == b.tunnelHostID
            && (a.kind == .mysql || a.database == b.database)
    }

    /// Why this plan can't run, if it can't. Checked again here, whoever calls `run`.
    static func refusal(_ plan: Plan, sourceSchema: String) -> String? {
        if plan.target.readOnly { return "\(plan.target.name) is read-only." }
        if sameDatabase(plan.source, plan.target), plan.target.kind == .sqlite || plan.targetSchema == sourceSchema {
            return "That's the database the tables come from. Pick another connection, or another schema."
        }
        let system = plan.target.kind == .mysql ? ["mysql", "sys", "information_schema", "performance_schema"] : ["pg_catalog", "information_schema", "pg_toast"]
        if plan.target.kind != .sqlite, system.contains(plan.targetSchema.lowercased()) { return "\(plan.targetSchema) is a system schema." }
        return nil
    }

    /// Tables that others reference come first, so their rows are in before the rows pointing at them.
    static func ordered(_ tables: [Table]) -> [Table] {
        var left = tables, out: [Table] = []
        while !left.isEmpty {
            let names = Set(left.map { $0.source.name.lowercased() })
            let ready = left.filter { t in t.columns.allSatisfy { c in c.fk.map { $0.table.lowercased() == t.source.name.lowercased() || !names.contains($0.table.lowercased()) } ?? true } }
            let next = ready.isEmpty ? [left[0]] : ready  // a cycle: take one and go on
            out += next
            left.removeAll { t in next.contains { $0.id == t.id } }
        }
        return out
    }

    /// Runs the plan. `progress(table index, rows copied so far)`. Stops at a chunk
    /// boundary when the task is cancelled; each table's outcome says how far it got.
    static func run(_ plan: Plan, sourcePassword: String?, targetPassword: String?, service: DatabaseService,
                    progress: @escaping @MainActor (Int, Int) -> Void) async -> [Outcome] {
        let src = session(plan.source), dst = session(plan.target, write: true)
        let kind = plan.target.kind, schema = plan.targetSchema
        let sourceSchema = plan.tables.first?.source.schema ?? ""
        if let why = refusal(plan, sourceSchema: sourceSchema) {
            return plan.tables.map { Outcome(table: $0.source.name, rows: 0, state: "Not started", error: why) }
        }
        var out: [Outcome] = []
        let copied = Set(plan.tables.filter { !($0.exists && $0.clash == .skip) }.map { $0.source.name.lowercased() })
        if plan.createSchema, kind != .sqlite {
            let sql = kind == .postgres ? "CREATE SCHEMA IF NOT EXISTS \(LiveDatabaseService.quote(schema, kind))"
                : "CREATE DATABASE IF NOT EXISTS \(LiveDatabaseService.quote(schema, kind)) CHARACTER SET utf8mb4"
            do { _ = try await service.execute(dst, sql: sql, password: targetPassword) }
            catch { return plan.tables.map { Outcome(table: $0.source.name, rows: 0, state: "Not started", error: "Couldn't create \(schema): " + LiveDatabaseService.describe(error)) } }
        }
        var built: [Table] = []
        let order = ordered(plan.tables)
        for t in order {
            let i = plan.tables.firstIndex { $0.id == t.id } ?? 0
            if Task.isCancelled { out.append(Outcome(table: t.source.name, rows: 0, state: "Not started", error: nil)); continue }
            if t.exists, t.clash == .skip { out.append(Outcome(table: t.source.name, rows: 0, state: "Skipped (already there)", error: nil)); continue }
            if t.exists, t.clash == .append, !plan.mode.data { out.append(Outcome(table: t.source.name, rows: 0, state: "Skipped (already there)", error: nil)); continue }
            let real = t.source.name
            // Drop and recreate builds a new table beside the old one and swaps them only once
            // it's complete, so a failed or stopped copy leaves the old table as it was.
            let swap = t.exists && t.clash == .replace
            let into = swap ? real + "__brix_copy" : real
            var rows = 0
            var notes: [String] = []
            do {
                if !t.exists || swap {
                    if swap { _ = try? await service.execute(dst, sql: "DROP TABLE IF EXISTS \(name(schema, into, kind))", password: targetPassword) }
                    _ = try await service.execute(dst, sql: createTable(t, schema: schema, kind: kind, copiedTables: copied, as: into), password: targetPassword)
                }
                if plan.mode.data {
                    let r = try await copyRows(t, plan: plan, into: into, src: src, dst: dst, sourcePassword: sourcePassword, targetPassword: targetPassword, service: service) { n in
                        rows = n
                        await progress(i, n)
                    }
                    rows = r.rows
                    notes += r.notes
                    if Task.isCancelled { throw CancellationError() }
                    // Every row arrived? (Rows written to the source meanwhile can make this differ.)
                    if !(t.exists && t.clash == .append) {
                        let n = try await service.execute(src, sql: "SELECT COUNT(*) FROM \(DataEdits.table(t.source, plan.source.kind))", password: sourcePassword).rows.first?.first ?? nil
                        if let n, let total = Int(n), total != rows { notes.append("The source has \(total) rows; \(rows) were copied.") }
                    }
                }
                if swap {
                    _ = try await service.execute(dst, sql: "DROP TABLE \(name(schema, real, kind))", password: targetPassword)
                    let rename = kind == .mysql ? "RENAME TABLE \(name(schema, into, kind)) TO \(name(schema, real, kind))"
                        : "ALTER TABLE \(name(schema, into, kind)) RENAME TO \(LiveDatabaseService.quote(real, kind))"
                    _ = try await service.execute(dst, sql: rename, password: targetPassword)
                }
                if !t.exists || swap { built.append(t) }
                if kind == .postgres, plan.mode.data {
                    for c in t.columns where c.auto {
                        let tn = name(schema, real, kind), cn = LiveDatabaseService.quote(c.name, kind)
                        do {
                            _ = try await service.execute(dst, sql: "SELECT setval(pg_get_serial_sequence(\(LiveDatabaseService.literal(tn, kind)), \(LiveDatabaseService.literal(c.name, kind))), COALESCE((SELECT MAX(\(cn)) FROM \(tn)), 0) + 1, false)", password: targetPassword)
                        } catch {
                            notes.append("\(c.name)'s numbering wasn't moved past the copied rows; new rows may clash (\(LiveDatabaseService.describe(error))).")
                        }
                    }
                }
                out.append(Outcome(table: real, rows: rows, state: "Done", error: notes.isEmpty ? nil : notes.joined(separator: "\n")))
            } catch {
                if swap { _ = try? await service.execute(dst, sql: "DROP TABLE IF EXISTS \(name(schema, into, kind))", password: targetPassword) }
                let stopped = error is CancellationError || Task.isCancelled
                let what = stopped ? "Stopped" : "Failed"
                let kept = swap ? " The table that was there is unchanged." : (rows > 0 ? " \(rows) rows were copied before that." : "")
                out.append(Outcome(table: real, rows: swap ? 0 : rows, state: what, error: (stopped ? "Stopped." : LiveDatabaseService.describe(error)) + kept))
            }
        }
        // Indexes and keys after the rows: faster, and rows needn't arrive in key order.
        for t in built where !Task.isCancelled {
            for sql in createIndexes(t, schema: schema, kind: kind) + foreignKeys(t, schema: schema, kind: kind, copiedTables: copied) {
                do { _ = try await service.execute(dst, sql: sql, password: targetPassword) }
                catch {
                    if let k = out.firstIndex(where: { $0.table == t.source.name }) {
                        out[k].error = (out[k].error.map { $0 + "\n" } ?? "") + "Not added: \(sql.prefix(120)) (\(LiveDatabaseService.describe(error)))"
                    }
                }
            }
        }
        // In the order the tables were listed.
        return plan.tables.compactMap { t in out.first { $0.table == t.source.name } }
    }

    /// Rows in chunks: by primary key when there's a single integer one (keyset), else by
    /// offset in a fixed order (the key's columns, or every column).
    private static func copyRows(_ t: Table, plan: Plan, into: String, src: DatabaseConnection, dst: DatabaseConnection, sourcePassword: String?, targetPassword: String?,
                                 service: DatabaseService, progress: (Int) async -> Void) async throws -> (rows: Int, notes: [String]) {
        let sk = plan.source.kind, tk = plan.target.kind
        var notes: [String] = []
        var cols = t.columns
        if t.exists, t.clash == .append {
            // Adding to an existing table: only the columns it has, under its spelling.
            let have = try await service.tableDetail(dst, object: DBObject(schema: plan.targetSchema, name: t.source.name, kind: .table), password: targetPassword).columns
            let byName = Dictionary(have.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
            let missing = cols.filter { byName[$0.name.lowercased()] == nil }.map(\.name)
            cols = cols.compactMap { c in byName[c.name.lowercased()].map { var x = c; x.name = $0; return x } }
            guard !cols.isEmpty else { throw ServiceError("None of its columns are in the target table.") }
            if !missing.isEmpty { notes.append("Not in the target table, so not copied: " + missing.joined(separator: ", ")) }
        }
        // Read by the source's spelling of each column.
        let readCols = cols.map { c -> Column in var x = c; x.name = t.columns.first { $0.name.lowercased() == c.name.lowercased() }?.name ?? c.name; return x }
        let from = DataEdits.table(t.source, sk)
        let list = readCols.map { selectExpr($0, source: sk, target: tk) }.joined(separator: ", ")
        let keyset = t.pk.count == 1 && [.int, .bigint, .smallint].contains(t.columns.first { $0.name == t.pk[0] }?.kind ?? .text)
        let pkq = keyset ? LiveDatabaseService.quote(t.pk[0], sk) : ""
        // Without a fixed order, pages can overlap or miss rows.
        let order = t.pk.isEmpty ? (1...readCols.count).map(String.init).joined(separator: ", ") : t.pk.map { LiveDatabaseService.quote($0, sk) }.joined(separator: ", ")
        if t.pk.isEmpty { notes.append("No primary key: rows were read in column order.") }
        let readSize = 1000, writeSize = 500
        var last: String?, offset = 0, total = 0
        while !Task.isCancelled {
            let sql: String
            if keyset {
                // The key column's own value, unconverted and named apart, is selected last for the next page.
                let more = last.map { " WHERE \(pkq) > \($0)" } ?? ""
                sql = "SELECT \(list), \(pkq) AS brix_copy_key FROM \(from)\(more) ORDER BY brix_copy_key LIMIT \(readSize)"
            } else {
                sql = "SELECT \(list) FROM \(from) ORDER BY \(order) LIMIT \(readSize) OFFSET \(offset)"
            }
            let page = try await service.execute(src, sql: sql, password: sourcePassword)
            if page.rows.isEmpty { break }
            let rows = keyset ? page.rows.map { Array($0.dropLast()) } : page.rows
            for start in stride(from: 0, to: rows.count, by: writeSize) {
                let chunk = Array(rows[start..<min(start + writeSize, rows.count)])
                _ = try await service.executeBatch(dst, sqls: [insert(t, columns: cols, rows: chunk, schema: plan.targetSchema, target: tk, into: into)], expect: [nil], password: targetPassword)
                total += chunk.count
                await progress(total)
            }
            if page.rows.count < readSize { break }
            if keyset {
                guard let k = page.rows.last?.last ?? nil, k.range(of: #"^-?\d+$"#, options: .regularExpression) != nil else {
                    throw ServiceError("A key value isn't a whole number, so the rest can't be read in order. \(total) rows were copied.")
                }
                last = k
            } else {
                offset += page.rows.count
            }
        }
        return (total, notes)
    }
}

/// Column types across Postgres, MySQL and SQLite.
enum DBTypeMap {
    enum Kind: String { case smallint, int, bigint, decimal, float, double, bool, char, varchar, text, date, time, timestamp, timestamptz, json, uuid, binary, other }

    /// The target type for a source column, and a note when it isn't an exact match.
    static func map(_ type: String, from: DBKind, to: DBKind) -> (type: String, kind: Kind, note: String?) {
        let k = kind(type, from)
        // Same engine: the type as it is (enums, unsigned, arrays all survive); MySQL's
        // tinyint(1) and SQLite's booleans stay numbers, since they can hold more than 0 and 1.
        if from == to { return (type, k.kind == .bool && from != .postgres ? .smallint : k.kind, nil) }
        if k.kind == .bool, from == .mysql, to == .sqlite { return ("INTEGER", .smallint, nil) }
        if to == .postgres, type.lowercased().contains("unsigned") {
            if k.kind == .bigint { return ("numeric(20)", .decimal, nil) }
            if k.kind == .int { return ("bigint", .bigint, nil) }
        }
        let n = k.length, p = k.precision
        switch to {
        case .postgres:
            switch k.kind {
            case .smallint: return ("smallint", k.kind, nil)
            case .int: return ("integer", k.kind, nil)
            case .bigint: return ("bigint", k.kind, nil)
            case .decimal: return (p.map { "numeric(\($0.0),\($0.1))" } ?? "numeric", k.kind, nil)
            case .float: return ("real", k.kind, nil)
            case .double: return ("double precision", k.kind, nil)
            case .bool: return ("boolean", k.kind, nil)
            case .char: return (n.map { "char(\($0))" } ?? "char(1)", k.kind, nil)
            case .varchar: return (n.map { "varchar(\($0))" } ?? "text", k.kind, nil)
            case .text: return ("text", k.kind, nil)
            case .date: return ("date", k.kind, nil)
            case .time: return ("time", k.kind, nil)
            case .timestamp: return ("timestamp", k.kind, nil)
            case .timestamptz: return ("timestamptz", k.kind, nil)
            case .json: return ("jsonb", k.kind, nil)
            case .uuid: return ("uuid", k.kind, nil)
            case .binary: return ("bytea", k.kind, nil)
            case .other: return ("text", .text, "\(type) has no match; copied as text")
            }
        case .mysql:
            switch k.kind {
            case .smallint: return ("smallint", k.kind, nil)
            case .int: return ("int", k.kind, nil)
            case .bigint: return ("bigint", k.kind, nil)
            case .decimal: return (p.map { "decimal(\(min($0.0, 65)),\(min($0.1, 30)))" } ?? "decimal(65,30)", k.kind, p == nil ? "numeric without precision became decimal(65,30)" : nil)
            case .float: return ("float", k.kind, nil)
            case .double: return ("double", k.kind, nil)
            case .bool: return ("tinyint(1)", k.kind, nil)
            case .char: return (n.map { "char(\(min($0, 255)))" } ?? "char(1)", k.kind, nil)
            case .varchar: return (n.map { $0 <= 16_383 ? "varchar(\($0))" : "longtext" } ?? "longtext", n == nil ? .text : k.kind, nil)
            case .text: return ("longtext", k.kind, nil)
            case .date: return ("date", k.kind, nil)
            case .time: return ("time(6)", k.kind, nil)
            case .timestamp: return ("datetime(6)", k.kind, nil)
            case .timestamptz: return ("datetime(6)", k.kind, "time zone dropped; times copied in UTC")
            case .json: return ("json", k.kind, nil)
            case .uuid: return ("char(36)", k.kind, nil)
            case .binary: return ("longblob", k.kind, nil)
            case .other: return ("longtext", .text, "\(type) has no match; copied as text")
            }
        case .sqlite:
            switch k.kind {
            case .smallint, .int, .bigint, .bool: return ("INTEGER", k.kind, nil)
            case .decimal: return ("NUMERIC", k.kind, nil)
            case .float, .double: return ("REAL", k.kind, nil)
            case .binary: return ("BLOB", k.kind, nil)
            case .timestamptz: return ("TEXT", k.kind, "time zone dropped; times copied in UTC")
            case .other: return ("TEXT", .text, "\(type) has no match; copied as text")
            default: return ("TEXT", k.kind, nil)
            }
        }
    }

    /// Text and binary columns can't be keys in MySQL without a length.
    static func keyable(_ type: String, kind: DBKind) -> String {
        guard kind == .mysql else { return type }
        switch type {
        case "longtext": return "varchar(255)"
        case "longblob": return "varbinary(255)"
        default: return type
        }
    }

    static func kind(_ type: String, _ engine: DBKind) -> (kind: Kind, length: Int?, precision: (Int, Int)?) {
        let t = type.lowercased().trimmingCharacters(in: .whitespaces)
        let nums = t.range(of: #"\((\d+)(?:\s*,\s*(\d+))?\)"#, options: .regularExpression).map { r -> [Int] in
            t[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        } ?? []
        let length = nums.first
        let precision = nums.count == 2 ? (nums[0], nums[1]) : (nums.count == 1 ? (nums[0], 0) : nil)
        // The leading word decides; enum and set values ('print', 'binary') mustn't.
        let word = String(t.prefix { $0.isLetter || $0 == " " || $0 == "_" }).trimmingCharacters(in: .whitespaces)
        func has(_ s: String) -> Bool { word.contains(s) }
        if t.hasPrefix("enum(") || t.hasPrefix("set(") { return (.text, nil, nil) }
        if t.hasSuffix("[]") || has("array") { return (.other, nil, nil) }
        if word.hasPrefix("interval") || word.contains("range") || word.hasPrefix("point") || word.hasPrefix("multipoint") { return (.other, nil, nil) }
        if engine == .mysql, t.hasPrefix("tinyint(1)") { return (.bool, nil, nil) }
        if has("bool") { return (.bool, nil, nil) }
        if has("bytea") || has("blob") || has("binary") { return (.binary, nil, nil) }
        if has("timestamp with time zone") || t == "timestamptz" { return (.timestamptz, nil, nil) }
        if has("timestamp") || has("datetime") { return (.timestamp, nil, nil) }
        if t.hasPrefix("date") { return (.date, nil, nil) }
        if t.hasPrefix("time") { return (.time, nil, nil) }
        if t.hasPrefix("year") { return (.smallint, nil, nil) }
        if has("bigint") || t == "int8" || t == "bigserial" { return (.bigint, nil, nil) }
        if has("smallint") || has("tinyint") || t == "int2" || t == "smallserial" { return (.smallint, nil, nil) }
        if has("int") || t == "serial" { return (.int, nil, nil) }  // integer, int4, mediumint
        if has("numeric") || has("decimal") { return (.decimal, nil, precision) }
        if t == "money" { return (.decimal, nil, (19, 4)) }
        if t == "real" { return engine == .postgres ? (.float, nil, nil) : (.double, nil, nil) }
        if has("double") || t == "float8" { return (.double, nil, nil) }
        if has("float") { return (.float, nil, nil) }
        if has("uuid") { return (.uuid, nil, nil) }
        if has("json") { return (.json, nil, nil) }
        if has("varchar") || has("character varying") || has("nvarchar") { return (.varchar, length, nil) }
        if has("char") || has("character") { return (.char, length, nil) }
        if has("text") || has("clob") || t == "citext" || t == "name" { return (.text, nil, nil) }
        if engine == .sqlite, t.isEmpty { return (.text, nil, nil) }
        return (.other, nil, nil)
    }

    /// A source default the target understands: literals, NULL and the current time. Nil: left out.
    static func defaultSQL(_ raw: String?, kind: Kind, from: DBKind, to: DBKind) -> String? {
        guard var d = raw?.trimmingCharacters(in: .whitespaces), !d.isEmpty else { return nil }
        if from == to, !d.lowercased().hasPrefix("nextval(") { return from == .mysql ? mysqlDefault(d, kind: kind) : d }
        // Postgres casts: 'abc'::character varying → 'abc'.
        if from == .postgres, let r = d.range(of: "::", options: .backwards), !d[r.upperBound...].contains("'") { d = String(d[..<r.lowerBound]) }
        let l = d.lowercased()
        if l == "null" { return "NULL" }
        if ["now()", "current_timestamp", "current_timestamp()", "localtimestamp", "transaction_timestamp()"].contains(l) || l.hasPrefix("current_timestamp(") {
            return [.timestamp, .timestamptz].contains(kind) ? "CURRENT_TIMESTAMP" : nil
        }
        if kind == .bool {
            let on = ["1", "true", "'1'", "b'1'", "'t'"].contains(l)
            let off = ["0", "false", "'0'", "b'0'", "'f'"].contains(l)
            guard on || off else { return nil }
            return to == .postgres ? (on ? "true" : "false") : (on ? "1" : "0")
        }
        if d.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil { return d }
        // MySQL gives string defaults unquoted.
        if from == .mysql { return LiveDatabaseService.literal(d, to) }
        if d.hasPrefix("'"), d.hasSuffix("'"), d.count >= 2 {
            let inner = String(d.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            return LiveDatabaseService.literal(inner, to)
        }
        return nil
    }

    /// MySQL's information_schema gives string defaults unquoted.
    private static func mysqlDefault(_ d: String, kind: Kind) -> String? {
        let l = d.lowercased()
        if l == "null" || l.hasPrefix("current_timestamp") || d.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil { return d }
        return LiveDatabaseService.literal(d, .mysql)
    }
}
