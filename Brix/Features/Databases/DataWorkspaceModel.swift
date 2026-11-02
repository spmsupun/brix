import SwiftUI

/// The Databases screen's state: open tabs (tables and SQL consoles from any
/// connection), each keeping its own selection, filter, results and staged edits.
@Observable @MainActor
final class DataWorkspace {
    /// Every open data tab: the Databases screen's (no project) and those shown as
    /// tabs inside a project's workspace.
    var tabs: [DWTab] = []
    var active: UUID?
    /// Sidebar tree rows that are open ("c:<conn>", "s:<conn>.<schema>", …).
    var expanded: Set<String> = []
    /// The Record panel beside a table or console; hidden or shown, it stays that way after a relaunch.
    var showInspector = UserDefaults.standard.object(forKey: "brix.showRecordPanel") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "brix.showRecordPanel") }
    }
    /// The connection whose databases and tables the Databases screen lists.
    var explorer: ResourceID?
    var treeErrors: [ResourceID: String] = [:]
    var loadingTrees: Set<ResourceID> = []
    var consoleCount = 0
    /// ⌘O: the go-to-table-or-console picker.
    var goTo = false
    /// The data tab last in front in each project, for its Record panel.
    var lastInProject: [ProjectID: UUID] = [:]
    @ObservationIgnored var running: [UUID: Task<Void, Never>] = [:]
    /// The owner tag of each tab's current query, for Stop.
    @ObservationIgnored var owners: [UUID: String] = [:]

    /// The Databases screen's tabs, laid out like a project's (split panes, drag between them).
    var screenTree = PaneTree()

    /// The Databases screen's own tabs.
    var screenTabs: [DWTab] { tabs.filter { $0.projectID == nil } }
    var current: DWTab? { tabs.first { $0.id == active } }

    func tab(_ id: UUID) -> DWTab? { tabs.first { $0.id == id } }
    func index(_ id: UUID) -> Int? { tabs.firstIndex { $0.id == id } }

    /// Tabs are objects: a change to one redraws only the views reading what changed.
    func update(_ id: UUID, _ change: (DWTab) -> Void) {
        guard let t = tab(id) else { return }
        change(t)
    }
}

enum DWTableView: String, CaseIterable { case data = "Data", structure = "Structure", indexes = "Indexes", ddl = "DDL" }
enum DWResultView: String, CaseIterable { case grid = "Grid", chart = "Chart", text = "Text" }

struct DWCell: Hashable {
    var row: Int
    var col: Int
}

/// A staged change to one existing row, keyed by its primary key.
struct DWRowEdit: Equatable {
    var key: [String: String?]
    var original: [String: String?]
    var changes: [String: String?] = [:]
    /// Columns whose loaded value SQL can match exactly (not rounded, not a stand-in):
    /// an UPDATE also checks those it changes still hold it, so a concurrent edit isn't overwritten.
    var matchable: Set<String> = []
}

struct DWConsoleResult: Identifiable, Equatable {
    enum Kind: Equatable { case result, output, plan }
    let id = UUID()
    var kind: Kind
    var label: String
    var sql: String
    var result: QueryResult?
    var error: String?
    var ranAt = Date()
}

@Observable @MainActor
final class DWTab: Identifiable {
    enum Kind: Equatable { case table(DBObject), console }

    let id: UUID
    var kind: Kind
    var connectionID: ResourceID
    var title: String
    /// Set when the tab lives in a project's workspace instead of the Databases screen.
    let projectID: ProjectID?

    /// Its key as a tile, fixed when it's made (a console can later switch connection).
    @ObservationIgnored private(set) var tileKey = ""

    init(id: UUID = UUID(), kind: Kind, connectionID: ResourceID, title: String, projectID: ProjectID? = nil, tileKey: String? = nil) {
        self.id = id; self.kind = kind; self.connectionID = connectionID; self.title = title; self.projectID = projectID
        self.tileKey = tileKey ?? GridItemID.dataTab(self)
    }
    var selection: DWCell?
    var loading = false
    var error: String?

    // Table
    var view: DWTableView = .data
    var whereText = ""
    var appliedWhere = ""
    var orderText = ""
    var appliedOrder = ""
    var page = 0
    var result: QueryResult?
    var detail: TableDetail?
    var detailError: String?
    var ddl: String?
    var ddlError: String?
    var edits: [String: DWRowEdit] = [:]
    var deleted: [String: [String: String?]] = [:]
    var inserted: [[String: String]] = []
    var fkPopover: DWCell?

    // Console
    var sql = ""
    var caret = 0
    var schema = ""
    var limit = 500
    var readOnlySession = false
    var results: [DWConsoleResult] = []
    var activeResult: UUID?
    var resultView: DWResultView = .grid
    var editorHeight: CGFloat = 300
    var ghost: String?
    var chartColumn: Int?

    var object: DBObject? { if case .table(let o) = kind { o } else { nil } }
    var isConsole: Bool { kind == .console }
    var pendingCount: Int { edits.values.filter { !$0.changes.isEmpty }.count + deleted.count + inserted.count }
    var shownResult: DWConsoleResult? { results.first { $0.id == activeResult } ?? results.first }
}

// MARK: - SQL text

enum SQLText {
    /// Statements in a script as UTF-16 ranges, split on `;` outside quotes and comments.
    static func statements(_ sql: String) -> [NSRange] {
        let s = Array(sql.utf16)
        var out: [NSRange] = []
        var start = 0, i = 0
        var quote: UInt16? = nil
        func flush(_ end: Int) {
            let r = NSRange(location: start, length: end - start)
            let text = (sql as NSString).substring(with: r)
            if !strip(text).isEmpty { out.append(r) }
        }
        while i < s.count {
            let c = s[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == 39 || c == 34 || c == 96 { // ' " `
                quote = c
            } else if c == 45, i + 1 < s.count, s[i + 1] == 45 { // -- comment to end of line
                while i < s.count, s[i] != 10 { i += 1 }
                continue
            } else if c == 59 { // ;
                flush(i + 1)
                start = i + 1
            }
            i += 1
        }
        flush(s.count)
        return out
    }

    /// The statement the caret is in (or just after), else the first one.
    static func statement(at caret: Int, in sql: String) -> NSRange? {
        let all = statements(sql)
        return all.first { caret >= $0.location && caret <= NSMaxRange($0) } ?? all.last { NSMaxRange($0) <= caret } ?? all.first
    }

    /// The SQL without comments and surrounding blanks or `;`.
    static func strip(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let r = line.range(of: "--") else { return line }
                return line[..<r.lowerBound]
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 1-based line of a UTF-16 offset.
    static func line(of offset: Int, in sql: String) -> Int {
        let ns = sql as NSString
        let prefix = ns.substring(to: min(offset, ns.length))
        return prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// First line that holds SQL (not a comment or blank) in a range.
    static func firstCodeLine(_ r: NSRange, in sql: String) -> Int {
        let ns = sql as NSString
        var loc = r.location
        while loc < NSMaxRange(r) {
            let lr = ns.lineRange(for: NSRange(location: loc, length: 0))
            // Only the part of the line inside the statement (it may start after a `;`).
            let from = max(lr.location, r.location), to = min(NSMaxRange(lr), NSMaxRange(r))
            let text = ns.substring(with: NSRange(location: from, length: max(0, to - from))).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !text.hasPrefix("--") { return line(of: from, in: sql) }
            loc = NSMaxRange(lr)
        }
        return line(of: r.location, in: sql)
    }

    /// A SELECT gets the console's row limit unless it has one of its own (a LIMIT
    /// in a subquery doesn't count).
    static func limited(_ sql: String, limit: Int) -> String {
        let s = strip(sql)
        var depth = 0
        let top = String(code(s, mysql: false).filter { c in
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
            return depth == 0 && c != ")"
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        guard top.hasPrefix("select") || top.hasPrefix("with"), top.range(of: #"\blimit\s+(\d+|all)\b"#, options: .regularExpression) == nil,
              top.range(of: #"\bfetch\s+(first|next)\b"#, options: .regularExpression) == nil else { return s }
        return s + "\nLIMIT \(limit)"
    }

    /// The SQL as keyword checks read it: lowercased, comments dropped, string literals
    /// emptied to `''` (or with `keepLiterals`, their text kept), quotes around names
    /// dropped. `mysql` picks MySQL's lexer (backslash escapes, `#` and `-- ` comments,
    /// "…" strings, code inside `/*! … */`); else Postgres's (E'…' escapes, $tag$
    /// quotes, nested comments), which also fits SQLite.
    static func code(_ sql: String, mysql: Bool, keepLiterals: Bool = false) -> String {
        let s = Array(sql.lowercased().unicodeScalars)
        var out = String.UnicodeScalarView()
        func at(_ k: Int) -> Unicode.Scalar? { k >= 0 && k < s.count ? s[k] : nil }
        func word(_ c: Unicode.Scalar?) -> Bool { c.map { $0 == "_" || $0 == "$" || $0.properties.isAlphabetic || ("0"..."9").contains($0) } ?? false }
        func blank(_ c: Unicode.Scalar?) -> Bool { c.map { $0.properties.isWhitespace || $0.value < 32 } ?? true }
        var i = 0, inCode = false  // inside MySQL's /*! … */
        while i < s.count {
            let c = s[i]
            if (c == "-" && at(i + 1) == "-" && (!mysql || blank(at(i + 2)))) || (mysql && c == "#") {
                while i < s.count, s[i] != "\n" { i += 1 }
                out.append(" ")
            } else if inCode, c == "*", at(i + 1) == "/" {
                inCode = false; i += 2; out.append(" ")
            } else if c == "/", at(i + 1) == "*" {
                if mysql, at(i + 2) == "!" {
                    // MySQL runs what's inside: kept, without the marker and version.
                    i += 3; while let d = at(i), ("0"..."9").contains(d) { i += 1 }
                    inCode = true
                } else {
                    var depth = 0
                    while i < s.count {
                        if s[i] == "/", at(i + 1) == "*", !mysql || depth == 0 { depth += 1; i += 2 }
                        else if s[i] == "*", at(i + 1) == "/" { depth -= 1; i += 2; if depth == 0 { break } }
                        else { i += 1 }
                    }
                }
                out.append(" ")
            } else if c == "'" || (mysql && c == "\"") {
                let escapes = mysql || (at(i - 1) == "e" && !word(at(i - 2)))
                var text = String.UnicodeScalarView()
                i += 1
                while i < s.count {
                    if escapes, s[i] == "\\" { text.append(contentsOf: s[i..<min(i + 2, s.count)]); i += 2; continue }
                    if s[i] == c { if at(i + 1) == c { text.append(c); i += 2; continue }; break }
                    text.append(s[i]); i += 1
                }
                i += 1
                out.append(contentsOf: keepLiterals ? " \(String(text)) ".unicodeScalars : "''".unicodeScalars)
            } else if !mysql, c == "$", !word(at(i - 1)), let tagEnd = (i + 1..<s.count).first(where: { !word(s[$0]) || s[$0] == "$" }), s[tagEnd] == "$",
                      !(at(i + 1).map { ("0"..."9").contains($0) } ?? false) {
                // $tag$ … $tag$
                let tag = Array(s[i...tagEnd])
                var j = tagEnd + 1
                while j < s.count, !(s[j] == "$" && Array(s[j..<min(j + tag.count, s.count)]) == tag) { j += 1 }
                if keepLiterals { out.append(" "); out.append(contentsOf: s[min(tagEnd + 1, s.count)..<j]); out.append(" ") } else { out.append(contentsOf: "''".unicodeScalars) }
                i = min(j + tag.count, s.count)
            } else if c == "`" || (!mysql && c == "\"") {
                // A quoted name: its text, without the quotes.
                i += 1
                while i < s.count {
                    if s[i] == c { if at(i + 1) == c { out.append(c); i += 2; continue }; break }
                    out.append(s[i]); i += 1
                }
                i += 1
            } else {
                out.append(c); i += 1
            }
        }
        return String(out)
    }

    /// The SQL as each engine that could run it reads it: checks pass only if they pass for all.
    static func variants(_ sql: String, _ kind: DBKind?) -> [String] {
        switch kind {
        case .mysql: [code(sql, mysql: true)]
        case .postgres: [code(sql, mysql: false)]
        default: [code(sql, mysql: false), code(sql, mysql: true)]
        }
    }

    /// Every name-like word in the SQL, quoted text included (lowercased).
    static func identifiers(_ sql: String) -> [String] {
        [false, true].flatMap { code(sql, mysql: $0, keepLiterals: true).matches(of: #/[a-z_][a-z0-9_$]*/#).map { String($0.output) } }
    }

    /// The SQL for query history: string literals after PASSWORD or IDENTIFIED BY
    /// (ALTER USER, CREATE ROLE, SET PASSWORD) replaced, so no secret is saved.
    static func redacted(_ sql: String) -> String {
        guard let r = sql.range(of: #"(?i)\b(password|identified\b)"#, options: .regularExpression) else { return sql }
        return String(sql[..<r.lowerBound]) + sql[r.lowerBound...].replacingOccurrences(of: #"'(?:[^'\\]|''|\\.)*'"#, with: "'•••'", options: .regularExpression)
    }
}

// MARK: - Staged edits

enum DataEdits {
    static func table(_ o: DBObject, _ kind: DBKind) -> String {
        kind == .sqlite ? LiveDatabaseService.quote(o.name, .sqlite) : LiveDatabaseService.quote(o.schema, kind) + "." + LiveDatabaseService.quote(o.name, kind)
    }

    static func value(_ v: String?, _ kind: DBKind) -> String { v.map { LiveDatabaseService.literal($0, kind) } ?? "NULL" }

    static func whereKey(_ key: [String: String?], _ kind: DBKind) -> String {
        key.keys.sorted().map { k in
            let q = LiveDatabaseService.quote(k, kind)
            return key[k].flatMap { $0 }.map { "\(q) = \(LiveDatabaseService.literal($0, kind))" } ?? "\(q) IS NULL"
        }.joined(separator: " AND ")
    }

    /// The statements Submit runs, in order: updates, inserts, deletes.
    static func sql(object o: DBObject, kind: DBKind, edits: [String: DWRowEdit], inserted: [[String: String]], deleted: [String: [String: String?]]) -> [String] {
        let t = table(o, kind)
        var out: [String] = []
        for k in edits.keys.sorted() {
            guard let e = edits[k], !e.changes.isEmpty, deleted[k] == nil else { continue }
            let set = e.changes.keys.sorted().map { "\(LiveDatabaseService.quote($0, kind)) = \(value(e.changes[$0] ?? nil, kind))" }.joined(separator: ", ")
            out.append("UPDATE \(t) SET \(set) WHERE \(whereKey(match(e), kind));")
        }
        for row in inserted where !row.isEmpty {
            let cols = row.keys.sorted()
            out.append("INSERT INTO \(t) (\(cols.map { LiveDatabaseService.quote($0, kind) }.joined(separator: ", "))) VALUES (\(cols.map { LiveDatabaseService.literal(row[$0] ?? "", kind) }.joined(separator: ", ")));")
        }
        for k in deleted.keys.sorted() {
            guard let key = deleted[k] else { continue }
            out.append("DELETE FROM \(t) WHERE \(whereKey(key, kind));")
        }
        return out
    }

    /// What Submit runs: each UPDATE and DELETE must match exactly one row, or
    /// the whole batch rolls back. PostgreSQL and SQLite count RETURNING rows.
    /// MySQL first counts (and locks) the matching row, since its ROW_COUNT()
    /// reports rows changed, which is 0 when a value is set to what it already was.
    static func plan(object o: DBObject, kind: DBKind, edits: [String: DWRowEdit], inserted: [[String: String]], deleted: [String: [String: String?]]) -> [(sql: String, expect: Int?)] {
        let t = table(o, kind)
        let checked = { (sql: String, key: [String: String?]) -> [(String, Int?)] in
            if kind == .mysql {
                return [("SELECT COUNT(*) AS brix_affected FROM \(t) WHERE \(whereKey(key, kind)) FOR UPDATE", 1), (sql, nil)]
            }
            return [(String(sql.dropLast()) + " RETURNING 1;", 1)]
        }
        return self.sql(object: o, kind: kind, edits: edits, inserted: inserted, deleted: deleted).flatMap { sql -> [(String, Int?)] in
            if sql.hasPrefix("INSERT") { return [(sql, nil)] }
            // The key is the WHERE of the statement; find it from the staged data, not by parsing.
            let key = sql.hasPrefix("UPDATE") ? edits.values.first { sql.hasSuffix("WHERE \(whereKey(match($0), kind));") }.map(match)
                                              : deleted.values.first { sql.hasSuffix("WHERE \(whereKey($0, kind));") }
            return key.map { checked(sql, $0) } ?? [(sql, nil)]
        }
    }

    /// What an UPDATE matches: the key, and each changed column's loaded value where it can be matched.
    static func match(_ e: DWRowEdit) -> [String: String?] {
        var m = e.key
        for c in e.changes.keys where e.matchable.contains(c) { m[c] = e.original[c] ?? nil }
        return m
    }

    /// Whether a loaded value can be matched back exactly in a WHERE (no rounding, no
    /// stand-in, a type with `=`), so a write can check the row is still as loaded.
    static func matchable(_ v: String?, _ c: DBColumn) -> Bool {
        plainKey(c) && !placeholder(v, c) && !["xml", "geometry", "point", "bit"].contains(where: c.type.lowercased().contains)
    }

    /// A row's identity for a DELETE: its key, plus every value that can be matched,
    /// so a row someone changed since it was loaded isn't deleted unseen.
    static func deleteKey(_ row: [String?], columns: [DBColumn], key: [String: String?]) -> [String: String?] {
        var m = key
        for (i, c) in columns.enumerated() where i < row.count && matchable(row[i], c) { m[c.name] = row[i] }
        return m
    }

    /// A cell shown as a stand-in for its value ("<12 bytes>", "<interval value>"): never written back or matched.
    static func placeholder(_ v: String?, _ c: DBColumn) -> Bool {
        let t = c.type.lowercased()
        if ["bytea", "blob", "binary"].contains(where: t.contains) { return true }
        return v?.range(of: #"^<(\d+ bytes|[^<>]+ value)>$"#, options: .regularExpression) != nil && !["char", "text", "json", "xml"].contains(where: t.contains)
    }

    /// Key types whose text form can't be matched back exactly (rounding, time zones, bytes).
    static func plainKey(_ c: DBColumn) -> Bool {
        let t = c.type.lowercased()
        return !["time", "date", "float", "double", "real", "bytea", "blob", "binary", "json", "numeric", "decimal"].contains { t.contains($0) }
    }

    /// A row's identity: its primary-key values, in column order.
    static func rowKey(_ row: [String?], columns: [DBColumn]) -> (id: String, key: [String: String?])? {
        let pk = columns.enumerated().filter { $0.element.isPK }
        guard !pk.isEmpty else { return nil }
        var key: [String: String?] = [:]
        for (i, c) in pk where i < row.count { key[c.name] = row[i] }
        return (pk.map { i, _ in i < row.count ? (row[i] ?? "\u{0}NULL") : "" }.joined(separator: "\u{1F}"), key)
    }
}

/// Small clause-per-line SQL formatter. Leaves strings and comments alone.
enum SQLFormatter {
    static let clauses = ["select", "from", "where", "group by", "order by", "having", "limit", "offset", "left join", "right join", "inner join", "full join", "join", "union all", "union", "values", "set", "returning"]

    static func format(_ sql: String) -> String {
        var out = ""
        var i = sql.startIndex
        var inString = false
        var buffer = ""
        func flushBuffer() {
            var s = buffer.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            for c in clauses {
                s = s.replacingOccurrences(of: #"(?i)\s+\b"# + c.replacingOccurrences(of: " ", with: #"\s+"#) + #"\b"#, with: "\n" + c, options: .regularExpression)
            }
            s = s.replacingOccurrences(of: #"(?i)\s+\band\b"#, with: "\n  and", options: .regularExpression)
            s = s.replacingOccurrences(of: #",\s*"#, with: ",\n       ", options: .regularExpression)
            out += s
            buffer = ""
        }
        while i < sql.endIndex {
            let ch = sql[i]
            if !inString, sql[i...].hasPrefix("--") {
                flushBuffer()
                let end = sql[i...].firstIndex(of: "\n") ?? sql.endIndex
                out += String(sql[i..<end]) + "\n"
                i = end < sql.endIndex ? sql.index(after: end) : end
                continue
            }
            if ch == "'" {
                if !inString { flushBuffer() }
                inString.toggle()
                out.append(ch)
            } else if inString {
                out.append(ch)
            } else {
                buffer.append(ch)
            }
            i = sql.index(after: i)
        }
        flushBuffer()
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String($0).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Compact {
    /// 1455 to "1.5k", 12482 to "12k".
    static func number(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(n / 1000)k" }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}
