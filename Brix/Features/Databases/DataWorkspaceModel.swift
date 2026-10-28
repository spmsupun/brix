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
    var showInspector = true
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

    /// A SELECT gets the console's row limit unless it has one.
    static func limited(_ sql: String, limit: Int) -> String {
        let s = strip(sql)
        let lower = s.lowercased()
        guard lower.hasPrefix("select") || lower.hasPrefix("with"), lower.range(of: #"\blimit\s+\d+"#, options: .regularExpression) == nil,
              lower.range(of: #"\bfetch\s+first\b"#, options: .regularExpression) == nil else { return s }
        return s + "\nLIMIT \(limit)"
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
            out.append("UPDATE \(t) SET \(set) WHERE \(whereKey(e.key, kind));")
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
            let key = sql.hasPrefix("UPDATE") ? edits.values.first { sql.hasSuffix("WHERE \(whereKey($0.key, kind));") }?.key
                                              : deleted.values.first { sql.hasSuffix("WHERE \(whereKey($0, kind));") }
            return key.map { checked(sql, $0) } ?? [(sql, nil)]
        }
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
