import SwiftUI
import AppKit

/// Actions for the Databases screen. Queries run off the main thread on each
/// connection's shared session; PROD connections never write from here.
extension AppStore {
    static let tablePageSize = 50

    /// The project the explorer is scoped to: the one in focus, else the most recent with databases.
    var dataProject: Project? {
        let withDBs = { (p: Project) in !self.dataConnections(for: p.id).isEmpty }
        if let p = currentProject, withDBs(p) { return p }
        return sortedProjects.filter { $0.parentID == nil }.sorted { $0.lastOpened > $1.lastOpened }.first(where: withDBs)
    }

    /// Connections linked to a project, its repositories and its parent folder.
    func dataConnections(for id: ProjectID) -> [DatabaseConnection] {
        let ids = [id] + children(of: id).map(\.id) + (project(id)?.parentID.map { [$0] } ?? [])
        var seen = Set<ResourceID>()
        return ids.flatMap(linkedDatabases).filter { seen.insert($0.id).inserted }
    }

    /// Every connection in the explorer: the project's, or all of them when it has none.
    var explorerConnections: [DatabaseConnection] {
        dataProject.map { dataConnections(for: $0.id) } ?? library.databases
    }

    /// Production connections are locked here: no writes, no DDL, whatever the statement.
    func dataLocked(_ d: DatabaseConnection) -> Bool { d.tag.isProduction }

    // MARK: Explorer

    /// From a project: the connection's tables in a left panel of that project,
    /// tables as its tabs, so they sit beside its agents. One database panel per
    /// project; it follows the connection last clicked.
    func explore(_ d: DatabaseConnection, in project: ProjectID) {
        openProject(project)
        let ws = workspace(for: project)
        let mine = ws.layout.allPanels.first { $0.kind == .database && $0.resourceID == d.id }
        for p in ws.layout.allPanels where p.kind == .database && p.id != mine?.id { ws.layout.hide(p.id) }
        if let mine {
            if ws.layout.side(of: mine.id) != .left { ws.layout.move(mine.id, to: .left) }
            ws.layout.collapsed.remove(.left)
        } else {
            ws.layout.add(.database, to: .left, resource: d.id, title: d.name)
        }
        loadTree(d)
    }

    /// Opens a connection on the Databases screen: its databases and tables in
    /// the list, each table as a tab beside it.
    func explore(_ d: DatabaseConnection) {
        dataWorkspace.explorer = d.id
        loadTree(d)
        go(.databases)
    }

    func loadTree(_ d: DatabaseConnection, force: Bool = false) {
        let ws = dataWorkspace
        guard force || schemaCache[d.id] == nil, !ws.loadingTrees.contains(d.id) else { return }
        ws.loadingTrees.insert(d.id)
        Task {
            do {
                let t = try await svc(d).db.schema(d, password: dbPassword(d))
                schemaCache[d.id] = t
                ws.treeErrors[d.id] = nil
                dbStatus[d.id] = .connected
            } catch {
                let msg = (error as? ServiceError)?.message ?? error.localizedDescription
                noteDBError(d, msg)
                ws.treeErrors[d.id] = msg
                dbStatus[d.id] = .error(msg.lowercased().contains("timeout") ? "timeout" : "failed")
            }
            ws.loadingTrees.remove(d.id)
        }
    }

    // MARK: Tabs

    /// Opens (or brings forward) a table. With a project it opens as a tab in that
    /// project's workspace; without, on the Databases screen.
    func openTable(_ d: DatabaseConnection, _ o: DBObject, where w: String = "", project: ProjectID? = nil) {
        let ws = dataWorkspace
        if w.isEmpty, let t = ws.tabs.first(where: { $0.connectionID == d.id && $0.object == o && $0.projectID == project }) {
            show(t)
            return
        }
        let t = DWTab(kind: .table(o), connectionID: d.id, title: o.name, projectID: project)
        t.whereText = w
        t.appliedWhere = w
        ws.tabs.append(t)
        show(t)
        loadTable(t.id)
    }

    @discardableResult
    func newConsole(_ d: DatabaseConnection? = nil, sql: String = "", project: ProjectID? = nil) -> UUID? {
        let ws = dataWorkspace
        let pool = project.map(dataConnections) ?? explorerConnections
        guard let d = d ?? ws.current.flatMap({ database($0.connectionID) }) ?? pool.first else {
            sheet = .editDatabase(nil)
            return nil
        }
        ws.consoleCount += 1
        let t = DWTab(kind: .console, connectionID: d.id, title: "console \(ws.consoleCount)", projectID: project)
        t.sql = sql
        t.schema = d.kind == .postgres ? "public" : d.database
        // PROD consoles start read-only and stay that way.
        t.readOnlySession = dataLocked(d)
        ws.tabs.append(t)
        show(t)
        return t.id
    }

    /// Brings a data tab to the front: in its project's tiles, or on the Databases screen.
    func show(_ t: DWTab) {
        let ws = dataWorkspace
        ws.active = t.id
        if let p = t.projectID {
            ws.lastInProject[p] = t.id
            if route != .workspace(p) { openProject(p) }
            workspace(for: p).placeTab(t.tileKey, in: nil)
        } else {
            if ws.screenTree.group(of: t.tileKey) == nil { ws.screenTree.add(t.tileKey) }
            ws.screenTree.activate(t.tileKey)
            if route != .databases { route = .databases }
        }
    }

    /// The data tab behind a project tile, recreated after a relaunch (tables
    /// reopen; a console comes back empty on its connection).
    func dataTab(forTile key: String, project: ProjectID) -> DWTab? {
        let ws = dataWorkspace
        guard let ref = GridItemID.dataTabRef(key) else { return nil }
        if let t = ws.tab(ref.id) { return t }
        guard let d = database(ref.connection) else { return nil }
        let t: DWTab
        if let o = ref.object {
            t = DWTab(id: ref.id, kind: .table(o), connectionID: d.id, title: o.name, projectID: project, tileKey: key)
        } else {
            ws.consoleCount += 1
            t = DWTab(id: ref.id, kind: .console, connectionID: d.id, title: "console \(ws.consoleCount)", projectID: project, tileKey: key)
            t.schema = d.kind == .postgres ? "public" : d.database
            t.readOnlySession = dataLocked(d)
        }
        ws.tabs.append(t)
        if t.object != nil { loadTable(t.id) }
        return t
    }

    func closeDataTab(_ id: UUID) {
        confirmDiscard(id) { [weak self] in self?.removeDataTab(id) }
    }

    /// Runs `then` at once, or after "Discard N pending changes?" when the tab has unsubmitted edits.
    func confirmDiscard(_ id: UUID, then: @escaping () -> Void) {
        guard let t = dataWorkspace.tab(id), t.pendingCount > 0 else { then(); return }
        confirm("Discard \(t.pendingCount) pending changes?", "\(t.title) has edits that were never submitted.", confirm: "Discard", action: then)
    }

    /// Drops a data tab and stops anything it's running.
    func removeDataTab(_ id: UUID) {
        let ws = dataWorkspace
        guard let i = ws.index(id) else { return }
        if ws.running[id] != nil, let d = database(ws.tabs[i].connectionID) {
            let owner = ws.owners[id] ?? id.uuidString
            Task { await svc(d).db.cancel(d, owner: owner, password: dbPassword(d)) }
        }
        ws.running[id]?.cancel()
        ws.running[id] = nil
        ws.owners[id] = nil
        let t = ws.tabs[i]
        if let p = t.projectID {
            if ws.lastInProject[p] == id { ws.lastInProject[p] = nil }
            workspace(for: p).state.panes.remove(t.tileKey)
        } else {
            ws.screenTree.remove(t.tileKey)
        }
        ws.tabs.remove(at: i)
        if ws.active == id { ws.active = ws.screenTree.focusedGroup.flatMap { ws.screenTree.group($0)?.active }.flatMap(GridItemID.dataTabID) }
    }

    /// A database refused the saved password: forget the remembered copy so the
    /// next try reads the Keychain again (it may have been changed elsewhere).
    func noteDBError(_ d: DatabaseConnection, _ message: String) {
        let m = message.lowercased()
        if ["password", "authentication", "access denied", "auth failed"].contains(where: m.contains) {
            keychain.forget(Keychain.dbAccount(d.id))
        }
    }

    // MARK: Table tabs

    func loadTable(_ id: UUID) {
        let ws = dataWorkspace
        guard let t = ws.tabs.first(where: { $0.id == id }), let o = t.object, let d = database(t.connectionID) else { return }
        if let old = ws.running[id] {
            // A newer load replaces it: stop the old query on the server too, so it
            // doesn't hold the connection while this one waits. Each load has its own
            // owner tag, so this can only hit the old one.
            old.cancel()
            if let oldOwner = ws.owners[id] { Task { await svc(d).db.cancel(d, owner: oldOwner, password: dbPassword(d)) } }
        }
        let owner = "\(id.uuidString)#\(UUID().uuidString.prefix(8))"
        ws.owners[id] = owner
        ws.update(id) { $0.loading = true; $0.error = nil }
        ws.running[id] = Task { await LiveDatabaseService.$owner.withValue(owner) {
            let pw = dbPassword(d)
            do {
                let svc = svc(d).db
                // Columns (types, keys) are read once per tab, not on every page or sort.
                let det: Result<TableDetail, Error>
                if let cached = t.detail { det = .success(cached) } else {
                    do { det = .success(try await svc.tableDetail(d, object: o, password: pw)) } catch { det = .failure(error) }
                }
                let r = try await svc.page(d, object: o, where: t.appliedWhere, orderBy: t.appliedOrder, page: t.page, pageSize: Self.tablePageSize,
                                           columns: (try? det.get())?.columns, password: pw)
                guard !Task.isCancelled else { return }
                if t.detail != nil, let cols = try? det.get().columns, Set(cols.map(\.name)) != Set(r.columns.map(\.name)) {
                    // The table changed since its columns were read: read them again.
                    ws.update(id) { $0.detail = nil; $0.ddl = nil }
                    ws.running[id] = nil
                    loadTable(id)
                    return
                }
                ws.update(id) {
                    $0.result = r; $0.loading = false; $0.error = nil
                    switch det {
                    case .success(let v): $0.detail = v; $0.detailError = nil
                    case .failure(let e): $0.detail = nil; $0.detailError = (e as? ServiceError)?.message ?? e.localizedDescription
                    }
                }
                dbStatus[d.id] = .connected
            } catch {
                guard !Task.isCancelled else { return }
                let msg = (error as? ServiceError)?.message ?? error.localizedDescription
                noteDBError(d, msg)
                // Refetch the columns next time, in case they're why it failed.
                ws.update(id) { $0.loading = false; $0.error = msg; $0.detail = nil }
            }
            ws.running[id] = nil
        } }
    }

    func applyTableFilter(_ id: UUID) {
        dataWorkspace.update(id) {
            $0.appliedWhere = $0.whereText.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.appliedOrder = $0.orderText.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.page = 0
        }
        loadTable(id)
    }

    /// Header click: ascending, then descending, then off.
    func sortTable(_ id: UUID, by column: String, kind: DBKind) {
        let q = LiveDatabaseService.quote(column, kind)
        dataWorkspace.update(id) {
            let cur = $0.appliedOrder.lowercased()
            $0.orderText = cur == "\(q) asc".lowercased() ? "\(q) DESC" : cur == "\(q) desc".lowercased() ? "" : "\(q) ASC"
        }
        applyTableFilter(id)
    }

    func loadStructure(_ id: UUID) {
        let ws = dataWorkspace
        guard let t = ws.tabs.first(where: { $0.id == id }), let o = t.object, let d = database(t.connectionID), t.ddl == nil, t.view == .ddl else { return }
        ws.update(id) { $0.ddlError = nil }
        Task {
            do {
                let ddl: String
                switch d.kind {
                case .mysql:
                    // Column 2 holds the statement for tables ("Create Table") and views ("Create View").
                    let r = try await svc(d).db.execute(d, sql: "show create \(o.kind == .view ? "view" : "table") \(DataEdits.table(o, .mysql))", password: dbPassword(d))
                    guard let text = r.rows.first?[safe: 1] ?? nil else { throw ServiceError("The server returned no definition.") }
                    ddl = text
                case .sqlite:
                    let r = try await svc(d).db.execute(d, sql: "select sql from sqlite_master where name = \(LiveDatabaseService.literal(o.name, .sqlite))", password: dbPassword(d))
                    guard let text = r.rows.first?.first ?? nil else { throw ServiceError("No definition found for \(o.name).") }
                    ddl = text
                case .postgres:
                    // PostgreSQL has no SHOW CREATE TABLE: built from the columns.
                    let det = try await svc(d).db.tableDetail(d, object: o, password: dbPassword(d))
                    let cols = det.columns.map { c in
                        "  \(LiveDatabaseService.quote(c.name, d.kind)) \(c.type)\(c.nullable ? "" : " NOT NULL")\(c.defaultValue.map { " DEFAULT \($0)" } ?? "")"
                    }
                    let pk = det.columns.filter(\.isPK).map { LiveDatabaseService.quote($0.name, d.kind) }
                    ddl = "-- Rebuilt from the columns; indexes and constraints are on the Indexes tab.\nCREATE TABLE \(DataEdits.table(o, d.kind)) (\n"
                        + (cols + (pk.isEmpty ? [] : ["  PRIMARY KEY (\(pk.joined(separator: ", ")))"])).joined(separator: ",\n") + "\n);"
                }
                ws.update(id) { $0.ddl = ddl }
            } catch {
                // Not cached: switching back to DDL tries again.
                ws.update(id) { $0.ddlError = (error as? ServiceError)?.message ?? error.localizedDescription }
            }
        }
    }

    /// The cell's current value: a staged edit if there is one.
    func cellValue(_ t: DWTab, row: Int, col: Int) -> String? {
        guard let r = t.result, col < r.columns.count else { return nil }
        if row >= r.rows.count {
            let i = row - r.rows.count
            return t.inserted.indices.contains(i) ? t.inserted[i][r.columns[col].name] : nil
        }
        let base = r.rows[row]
        if !t.edits.isEmpty, let k = DataEdits.rowKey(base, columns: r.columns), let e = t.edits[k.id], let v = e.changes[r.columns[col].name] { return v }
        return col < base.count ? base[col] : nil
    }

    /// Stages a change; nothing is written until Submit.
    func stageCell(_ id: UUID, row: Int, col: Int, value: String?) {
        dataWorkspace.update(id) { t in
            guard let r = t.result, col < r.columns.count else { return }
            let name = r.columns[col].name
            if row >= r.rows.count {
                let i = row - r.rows.count
                guard t.inserted.indices.contains(i) else { return }
                if let value { t.inserted[i][name] = value } else { t.inserted[i][name] = nil }
                return
            }
            let base = r.rows[row]
            guard let k = DataEdits.rowKey(base, columns: r.columns) else { return }
            var e = t.edits[k.id] ?? DWRowEdit(key: k.key, original: Dictionary(uniqueKeysWithValues: r.columns.enumerated().map { ($1.name, $0 < base.count ? base[$0] : nil) }))
            if (e.original[name] ?? nil) == value { e.changes[name] = nil } else { e.changes[name] = .some(value) }
            t.edits[k.id] = e.changes.isEmpty ? nil : e
        }
    }

    func addRow(_ id: UUID, copying row: Int? = nil) {
        dataWorkspace.update(id) { t in
            guard let r = t.result else { return }
            var new: [String: String] = [:]
            if let row, row < r.rows.count {
                // Duplicate: every value but the primary key (the database assigns it).
                for (i, c) in r.columns.enumerated() where !c.isPK && i < r.rows[row].count { new[c.name] = r.rows[row][i] }
            }
            t.inserted.append(new)
            t.selection = DWCell(row: r.rows.count + t.inserted.count - 1, col: 0)
        }
    }

    func toggleDelete(_ id: UUID, row: Int) {
        dataWorkspace.update(id) { t in
            guard let r = t.result else { return }
            if row >= r.rows.count {
                let i = row - r.rows.count
                if t.inserted.indices.contains(i) { t.inserted.remove(at: i) }
                return
            }
            guard let k = DataEdits.rowKey(r.rows[row], columns: r.columns) else { return }
            if t.deleted[k.id] != nil { t.deleted[k.id] = nil } else { t.deleted[k.id] = k.key }
        }
    }

    /// Drops the staged changes a Submit just wrote, keeping any made since.
    func clearSubmitted(_ id: UUID, _ edits: [String: DWRowEdit], _ inserted: [[String: String]], _ deleted: [String: [String: String?]]) {
        dataWorkspace.update(id) { t in
            for (k, e) in edits where t.edits[k] == e { t.edits[k] = nil }
            for row in inserted { if let i = t.inserted.firstIndex(of: row) { t.inserted.remove(at: i) } }
            for k in deleted.keys { t.deleted[k] = nil }
        }
    }

    /// Whether rows here can be edited, and if not, why.
    func editBlocker(_ t: DWTab, _ d: DatabaseConnection) -> String? {
        if dataLocked(d) { return "Production: read-only here" }
        if t.object?.kind != .table { return "Views can't be edited" }
        guard let cols = t.result?.columns ?? t.detail?.columns else { return "Loading" }
        let pk = cols.filter(\.isPK)
        if pk.isEmpty { return "No primary key: rows can't be matched, so they can't be edited" }
        if let c = pk.first(where: { !DataEdits.plainKey($0) }) { return "Primary key \(c.name) is \(c.type): its shown value can't be matched exactly, so rows can't be edited" }
        return nil
    }

    func revertTable(_ id: UUID) {
        dataWorkspace.update(id) { $0.edits = [:]; $0.inserted = []; $0.deleted = [:] }
    }

    func pendingSQL(_ t: DWTab) -> [String] {
        guard let o = t.object, let d = database(t.connectionID) else { return [] }
        return DataEdits.sql(object: o, kind: d.kind, edits: t.edits, inserted: t.inserted, deleted: t.deleted)
    }

    /// Runs the staged changes in one transaction. PROD never writes from here.
    func submitTable(_ id: UUID) {
        guard let t = dataWorkspace.tabs.first(where: { $0.id == id }), let d = database(t.connectionID) else { return }
        let sqls = pendingSQL(t)
        guard !sqls.isEmpty else { return }
        guard let o = t.object else { return }
        let plan = DataEdits.plan(object: o, kind: d.kind, edits: t.edits, inserted: t.inserted, deleted: t.deleted)
        // What this Submit covers; edits made while it runs stay staged.
        let snapshot = (edits: t.edits, inserted: t.inserted, deleted: t.deleted)
        if dataLocked(d) {
            toast(.error, "\(d.name) is Production", detail: "Production tables are read-only here. Nothing was written.")
            return
        }
        let run = { (conn: DatabaseConnection) in
            Task {
                do {
                    let r = try await LiveDatabaseService.$owner.withValue(id.uuidString) {
                        try await self.svc(conn).db.executeBatch(conn, sqls: plan.map(\.sql), expect: plan.map(\.expect), password: self.dbPassword(conn))
                    }
                    self.library.queryHistory.insert(QueryHistoryEntry(sql: sqls.joined(separator: "\n"), connectionID: conn.id, ranAt: Date(), rows: sqls.count, ms: r.elapsedMs), at: 0)
                    self.clearSubmitted(id, snapshot.edits, snapshot.inserted, snapshot.deleted)
                    self.toast(.success, "Saved \(sqls.count) change\(sqls.count == 1 ? "" : "s") to \(t.title)", detail: r.message)
                    self.loadTable(id)
                } catch {
                    self.toast(.error, "Nothing was saved", detail: (error as? ServiceError)?.message ?? error.localizedDescription)
                }
            }
        }
        if d.effectiveReadOnly {
            confirm("Write to \(d.name)?", "\(d.name) is read-only. Submit \(sqls.count) change\(sqls.count == 1 ? "" : "s") anyway?", confirm: "Submit") {
                var u = d
                u.writeUnlocked = true
                run(u)
            }
        } else {
            run(d)
        }
    }

    /// The row a foreign-key cell points at ("countries.code" = value).
    func fkTarget(_ d: DatabaseConnection, fk: String, value: String) -> (object: DBObject, column: String)? {
        let parts = fk.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        let table = parts[parts.count - 2], column = parts[parts.count - 1]
        let schema = parts.count >= 3 ? parts[0] : nil
        let objs = schemaCache[d.id]?.schemas.values.flatMap { $0 } ?? []
        // Without a schema in the reference, the connection's own database wins
        // over a same-named table in another database on the server.
        let o = objs.first { $0.name == table && $0.schema == (schema ?? d.database) }
            ?? objs.first { $0.name == table && (schema == nil || $0.schema == schema) }
            ?? DBObject(schema: schema ?? (d.kind == .postgres ? "public" : d.kind == .sqlite ? "main" : d.database), name: table, kind: .table, rowEstimate: nil)
        return (o, column)
    }

    func fetchReferenced(_ d: DatabaseConnection, fk: String, value: String) async -> Result<QueryResult, ServiceError> {
        guard let (o, col) = fkTarget(d, fk: fk, value: value) else { return .failure(ServiceError("Can't read the reference \(fk).")) }
        let w = "\(LiveDatabaseService.quote(col, d.kind)) = \(LiveDatabaseService.literal(value, d.kind))"
        do {
            return .success(try await svc(d).db.page(d, object: o, where: w, orderBy: "", page: 0, pageSize: 1, columns: nil, password: dbPassword(d)))
        } catch {
            return .failure(ServiceError((error as? ServiceError)?.message ?? error.localizedDescription))
        }
    }

    func openReferenced(_ d: DatabaseConnection, fk: String, value: String, project: ProjectID? = nil) {
        guard let (o, col) = fkTarget(d, fk: fk, value: value) else { return }
        openTable(d, o, where: "\(LiveDatabaseService.quote(col, d.kind)) = \(LiveDatabaseService.literal(value, d.kind))", project: project)
    }

    // MARK: Consoles

    enum ConsoleRun { case caret, all, explain }

    func runConsole(_ id: UUID, _ mode: ConsoleRun) {
        let ws = dataWorkspace
        guard let t = ws.tabs.first(where: { $0.id == id }), let d0 = database(t.connectionID), ws.running[id] == nil else { return }
        let ranges = SQLText.statements(t.sql)
        let pick: [NSRange] = switch mode {
        case .all: ranges
        default: SQLText.statement(at: t.caret, in: t.sql).map { [$0] } ?? []
        }
        let stmts = pick.map { SQLText.strip((t.sql as NSString).substring(with: $0)) }.filter { !$0.isEmpty }
        guard !stmts.isEmpty else { return }
        // PROD: only statements that read, on a read-only session. Checked here, not just in the UI.
        var d = d0
        if dataLocked(d0) || t.readOnlySession {
            if let w = stmts.first(where: { !AgentDBPolicy.readOnlyStatement($0) }) {
                let why = dataLocked(d0) ? "\(d0.name) is Production: INSERT, UPDATE, DELETE and DDL are blocked." : "This console is read-only."
                ws.update(id) { $0.results.insert(DWConsoleResult(kind: .output, label: "Output", sql: w, error: why), at: 0); $0.activeResult = $0.results.first?.id }
                return
            }
            d.readOnly = true
            d.writeUnlocked = false
        }
        // The session is shared by every tab on the connection, so a transaction
        // left open here would swallow their work. Submit groups table edits instead.
        if let tx = stmts.first(where: { $0.lowercased().range(of: #"^(begin|start\s+transaction|commit|rollback|end|abort|savepoint|release|xa\s|lock\s+tables?|unlock\s+tables|set\s+(session\s+|local\s+|@@session\.)?autocommit|set\s+(session\s+|local\s+)?(default_)?transaction|set\s+session\s+characteristics)\b"#, options: .regularExpression) != nil }) {
            ws.update(id) { $0.results.insert(DWConsoleResult(kind: .output, label: "Output", sql: tx, error: "Transactions aren't available in a console: it shares one session with every tab on \(d0.name). Each statement commits on its own."), at: 0); $0.activeResult = $0.results.first?.id }
            return
        }
        let needsUnlock = !dataLocked(d0) && !t.readOnlySession && d0.effectiveReadOnly && stmts.contains(where: Self.isWrite)
        let go = { (conn: DatabaseConnection) in
            ws.update(id) { $0.loading = true; $0.error = nil }
            ws.owners[id] = id.uuidString
            ws.running[id] = Task { await LiveDatabaseService.$owner.withValue(id.uuidString) {
                var out: [DWConsoleResult] = []
                var n = 0
                // The session is shared by every tab on this connection, so each run sets its own schema.
                if !t.schema.isEmpty, conn.kind != .sqlite {
                    let use = conn.kind == .postgres ? "SET search_path TO \(LiveDatabaseService.quote(t.schema, .postgres)), public" : "USE \(LiveDatabaseService.quote(t.schema, .mysql))"
                    do {
                        _ = try await self.svc(conn).db.execute(conn, sql: use, password: self.dbPassword(conn))
                    } catch {
                        // Running in the wrong schema would be worse than not running.
                        out.append(DWConsoleResult(kind: .output, label: "Output", sql: use, error: "Couldn't switch to schema \(t.schema): \((error as? ServiceError)?.message ?? error.localizedDescription)"))
                        ws.update(id) { $0.results = out; $0.activeResult = out.first?.id; $0.loading = false }
                        ws.running[id] = nil
                        return
                    }
                }
                for s in stmts {
                    if Task.isCancelled { break }
                    let sql = mode == .explain ? (conn.kind == .sqlite ? "EXPLAIN QUERY PLAN " : "EXPLAIN ") + s : SQLText.limited(s, limit: t.limit)
                    do {
                        let r = try await self.svc(conn).db.execute(conn, sql: sql, password: self.dbPassword(conn))
                        if mode == .explain {
                            out.append(DWConsoleResult(kind: .plan, label: "Plan", sql: sql, result: r))
                        } else if r.columns.isEmpty {
                            out.append(DWConsoleResult(kind: .output, label: "Output", sql: s, result: r))
                        } else {
                            n += 1
                            out.append(DWConsoleResult(kind: .result, label: "Result \(n)", sql: s, result: r))
                        }
                        self.library.queryHistory.insert(QueryHistoryEntry(sql: s, connectionID: conn.id, ranAt: Date(), rows: r.totalRows, ms: r.elapsedMs), at: 0)
                    } catch {
                        let msg = Task.isCancelled ? "Stopped." : ((error as? ServiceError)?.message ?? error.localizedDescription)
                        out.append(DWConsoleResult(kind: .output, label: "Output", sql: s, error: msg))
                        self.library.queryHistory.insert(QueryHistoryEntry(sql: s, connectionID: conn.id, ranAt: Date(), rows: 0, ms: 0, error: msg.components(separatedBy: "\n").first), at: 0)
                        break
                    }
                }
                if self.library.queryHistory.count > 500 { self.library.queryHistory.removeLast(self.library.queryHistory.count - 500) }
                ws.update(id) { tab in
                    tab.results = out
                    tab.activeResult = (out.first { $0.kind == .result } ?? out.first)?.id
                    tab.loading = false
                    tab.selection = nil
                }
                ws.running[id] = nil
            } }
        }
        if needsUnlock {
            confirm("Write to \(d0.name)?", "\(d0.name) is read-only. This changes data. Run it anyway?", confirm: "Run write") {
                var u = d0
                u.writeUnlocked = true
                go(u)
            }
        } else {
            go(d)
        }
    }

    /// Stop: cancels the task and asks the server to cancel the running query.
    func stopConsole(_ id: UUID) {
        let ws = dataWorkspace
        guard let t = ws.tabs.first(where: { $0.id == id }), let d = database(t.connectionID) else { return }
        ws.running[id]?.cancel()
        let owner = ws.owners[id] ?? id.uuidString
        Task { await svc(d).db.cancel(d, owner: owner, password: dbPassword(d)) }
    }

    // MARK: Agents

    /// Schema text for an agent, within the connection's agent access.
    func agentSchema(_ d: DatabaseConnection, tables: [DBObject]) async -> String {
        var out: [String] = []
        for o in tables.prefix(40) {
            let det: TableDetail
            do { det = try await svc(d).db.tableDetail(d, object: o, password: dbPassword(d)) } catch {
                out.append("\(o.schema).\(o.name) (columns unavailable: \((error as? ServiceError)?.message ?? error.localizedDescription))")
                continue
            }
            out.append("\(o.schema).\(o.name)(" + det.columns.map { "\($0.name) \($0.type)\($0.isPK ? " pk" : "")\($0.fk.map { " → \($0)" } ?? "")" }.joined(separator: ", ") + ")")
        }
        return out.joined(separator: "\n")
    }

    /// ⌘I in a console: the agent gets the schema and this console's SQL, and
    /// sends its suggestion back with `brix-db suggest`, shown as ghost lines.
    func askAgentConsole(_ id: UUID) {
        guard let t = dataWorkspace.tabs.first(where: { $0.id == id }), let d = database(t.connectionID) else { return }
        guard d.agentAccess != .none else {
            toast(.info, "Agents can't see \(d.name)", detail: "Change “What agents can do” in the connection to share its schema.")
            return
        }
        guard let project = dataProject ?? sortedProjects.first else { return }
        Task {
            let tables = d.agentSchemas(schemaCache[d.id]?.schemas ?? [:]).values.flatMap { $0 }.filter { $0.kind != .function }
            let schema = await agentSchema(d, tables: tables)
            let prompt = """
            Help with this SQL for the \(DBProduct.flavor(d).label) database “\(d.name)” (\(d.tag.name)). Schema:
            \(schema)

            Current SQL in Brix console \(t.title):
            \(t.sql.isEmpty ? "(empty)" : t.sql)

            Improve or complete it. Send your SQL back into the console with:  brix-db suggest \(id.uuidString) "<sql>"
            """
            askAgent(prompt: prompt, in: project.id)
        }
    }

    /// "Ask agent about this row": schema plus this row only, within the agent access.
    func askAgentRow(_ id: UUID) {
        guard let t = dataWorkspace.tabs.first(where: { $0.id == id }), let d = database(t.connectionID),
              let sel = t.selection else { return }
        let cols = (t.isConsole ? t.shownResult?.result?.columns : t.result?.columns) ?? []
        guard d.agentAccess != .none else {
            toast(.info, "Agents can't see \(d.name)", detail: "Change “What agents can do” in the connection to share it.")
            return
        }
        guard let project = dataProject ?? sortedProjects.first else { return }
        let values: [String?] = cols.indices.map { c in
            t.isConsole ? t.shownResult?.result?.rows[safe: sel.row]?[safe: c] ?? nil : cellValue(t, row: sel.row, col: c)
        }
        let canRead = d.agentAccess == .read || d.agentAccess == .write
        let fields = zip(cols, values).map { c, v -> String in
            let shown = !canRead ? "(hidden: schema only)" : AgentDBPolicy.sensitive(c.name) ? "•••" : (v ?? "NULL")
            return "  \(c.name) \(c.type)\(c.isPK ? " pk" : "")\(c.fk.map { " → \($0)" } ?? ""): \(shown)"
        }
        let prompt = """
        A row from \(t.title) in the \(DBProduct.flavor(d).label) database “\(d.name)” (\(d.tag.name)):
        \(fields.joined(separator: "\n"))

        What stands out about this row? Point out anything that looks wrong or inconsistent.
        """
        askAgent(prompt: prompt, in: project.id)
    }

    /// From the gateway: an agent's SQL for a console, shown as ghost lines.
    func suggest(console: String, sql: String) -> Bool {
        guard let id = UUID(uuidString: console), dataWorkspace.index(id) != nil else { return false }
        dataWorkspace.update(id) { $0.ghost = sql.trimmingCharacters(in: .whitespacesAndNewlines) }
        return true
    }

    func acceptGhost(_ id: UUID) -> Bool {
        guard let t = dataWorkspace.tabs.first(where: { $0.id == id }), let g = t.ghost else { return false }
        dataWorkspace.update(id) { tab in
            let ns = tab.sql as NSString
            let at = SQLText.statement(at: tab.caret, in: tab.sql).map { NSMaxRange($0) } ?? ns.length
            tab.sql = ns.replacingCharacters(in: NSRange(location: at, length: 0), with: (at > 0 ? "\n" : "") + g)
            tab.ghost = nil
        }
        return true
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
