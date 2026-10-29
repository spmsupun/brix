import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Table tab

struct DWTablePane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let tabID: UUID
    @State private var preview = false
    @FocusState private var whereFocused: Bool

    private var ws: DataWorkspace { store.dataWorkspace }

    var body: some View {
        if let t = ws.tabs.first(where: { $0.id == tabID }), let d = store.database(t.connectionID) {
            VStack(spacing: 0) {
                toolbar(t, d)
                if t.view == .data { filters(t, d) }
                content(t, d)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .hairlineTop()
                if t.pendingCount > 0 { pendingBar(t, d) }
            }
        }
    }

    private func editable(_ t: DWTab, _ d: DatabaseConnection) -> Bool { store.editBlocker(t, d) == nil }

    private func toolbar(_ t: DWTab, _ d: DatabaseConnection) -> some View {
        let canEdit = editable(t, d)
        let sel = t.selection?.row
        return DWToolbar {
            DWSegment(options: DWTableView.allCases.map { ($0, $0.rawValue) }, selection: t.view) { v in
                ws.update(tabID) { $0.view = v }
                if v == .ddl { store.loadStructure(tabID) }
            }
            DWVSep()
            IconButton(symbol: "arrow.triangle.2.circlepath", label: "Reload", size: 26, iconSize: 11) {
                // A reload re-reads the columns too, in case the table changed.
                ws.update(tabID) { $0.detail = nil; $0.ddl = nil; $0.ddlError = nil }
                store.loadTable(tabID)
            }
            IconButton(symbol: "plus", label: "Add row", size: 26, iconSize: 11) { store.addRow(tabID) }.disabled(!canEdit)
            IconButton(symbol: "minus", label: "Delete row", size: 26, iconSize: 11) { if let sel { store.toggleDelete(tabID, row: sel) } }.disabled(!canEdit || sel == nil)
            IconButton(symbol: "plus.square.on.square", label: "Duplicate row", size: 26, iconSize: 11) { store.addRow(tabID, copying: sel) }
                .disabled(!canEdit || sel == nil || sel! >= (t.result?.rows.count ?? 0))
            DWVSep()
            DWPill {
                Text("Tx").foregroundStyle(Theme.text3)
                Text(DWTx.label(t, d, store: store))
            }
            .fixedSize()
            .help(store.editBlocker(t, d) ?? "Edits are staged; nothing is written until Submit")
            if let why = store.editBlocker(t, d), why != "Loading", !store.dataLocked(d) {
                Label("Read-only", systemImage: "lock").font(Typo.ui(11)).foregroundStyle(Theme.text3).fixedSize().help(why)
                    .accessibilityLabel("Read-only: \(why)")
            }
            Spacer(minLength: 0)
            if let r = t.result {
                let start = r.rows.isEmpty ? 0 : t.page * AppStore.tablePageSize + 1
                HStack(spacing: 4) {
                    Text("\(start)–\(t.page * AppStore.tablePageSize + r.rows.count)").font(Typo.mono(11.5)).foregroundStyle(Theme.text2)
                    Text("of \(r.totalRows.formatted())").font(Typo.ui(11.5)).foregroundStyle(Theme.meta)
                }
                .fixedSize()
                IconButton(symbol: "chevron.left", label: "Previous page", size: 26, iconSize: 10) {
                    ws.update(tabID) { $0.page -= 1 }
                    store.loadTable(tabID)
                }
                .disabled(t.page == 0)
                IconButton(symbol: "chevron.right", label: "Next page", size: 26, iconSize: 10) {
                    ws.update(tabID) { $0.page += 1 }
                    store.loadTable(tabID)
                }
                .disabled((t.page + 1) * AppStore.tablePageSize >= r.totalRows)
            }
            DWVSep()
            Button { export(t) } label: {
                DWPill { Image(systemName: "arrow.down.to.line").font(.system(size: 10.5)); Text("CSV") }.fixedSize()
            }
            .buttonStyle(.hand).disabled(t.result == nil)
        }
    }

    private func filters(_ t: DWTab, _ d: DatabaseConnection) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("WHERE").font(Typo.mono(10.5, .bold)).foregroundStyle(Theme.violet)
                ZStack(alignment: .leading) {
                    TextField("", text: Binding(get: { t.whereText }, set: { v in ws.update(tabID) { $0.whereText = v } }))
                        .textFieldStyle(.plain).font(Typo.mono(12)).focused($whereFocused)
                        .opacity(whereFocused ? 1 : 0)
                        .onSubmit { store.applyTableFilter(tabID) }
                    if !whereFocused {
                        SQLHighlight.text(t.whereText.isEmpty ? "" : t.whereText).font(Typo.mono(12)).lineLimit(1)
                            .allowsHitTesting(false)
                        if t.whereText.isEmpty { Text("id > 100").font(Typo.mono(12)).foregroundStyle(Theme.meta).allowsHitTesting(false) }
                    }
                }
                Text("⌥⏎ apply").font(Typo.ui(10)).foregroundStyle(Theme.meta)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(whereFocused ? accent.opacity(0.5) : Color.white(0.07)))
            .layoutPriority(1.6)
            .onTapGesture { whereFocused = true }
            HStack(spacing: 8) {
                Text("ORDER BY").font(Typo.mono(10.5, .bold)).foregroundStyle(Theme.violet)
                TextField("", text: Binding(get: { t.orderText }, set: { v in ws.update(tabID) { $0.orderText = v } }), prompt: Text("id ASC").foregroundColor(Theme.meta))
                    .textFieldStyle(.plain).font(Typo.mono(12))
                    .onSubmit { store.applyTableFilter(tabID) }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white(0.07)))
            .frame(minWidth: 170)
            .layoutPriority(1)
            .background { Button("") { store.applyTableFilter(tabID) }.keyboardShortcut(.return, modifiers: .option).opacity(0) }
        }
        .padding(.horizontal, 10).padding(.bottom, 6).frame(height: 34)
    }

    @ViewBuilder private func content(_ t: DWTab, _ d: DatabaseConnection) -> some View {
        switch t.view {
        case .data:
            if let e = t.error, t.result == nil {
                DWError(message: e)
            } else if let r = t.result {
                let base = r.rows.count
                let sortParts = t.appliedOrder.split(separator: " ")
                let sortCol = sortParts.first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"`")) }
                DWGrid(columns: r.columns, rowCount: base + t.inserted.count,
                       value: { row, col in store.cellValue(t, row: row, col: col) },
                       rowState: { row in
                           if row >= base { return .inserted }
                           if t.deleted.isEmpty { return .normal }
                           return DataEdits.rowKey(r.rows[row], columns: r.columns).map { t.deleted[$0.id] != nil } == true ? .deleted : .normal
                       },
                       edited: { row in
                           guard row < base, !t.edits.isEmpty, let k = DataEdits.rowKey(r.rows[row], columns: r.columns), let e = t.edits[k.id] else { return [] }
                           return Set(r.columns.indices.filter { e.changes[r.columns[$0].name] != nil })
                       },
                       rowOffset: t.page * AppStore.tablePageSize,
                       selection: t.selection,
                       sort: sortCol.map { ($0, !(sortParts.last?.lowercased() == "desc")) },
                       editable: editable(t, d),
                       onSelect: { cell in
                           ws.update(tabID) {
                               $0.selection = cell
                               $0.fkPopover = r.columns[safe: cell.col]?.fk != nil && store.cellValue(t, row: cell.row, col: cell.col) != nil ? cell : nil
                           }
                       },
                       onEdit: { cell, v in store.stageCell(tabID, row: cell.row, col: cell.col, value: v) },
                       onSort: { store.sortTable(tabID, by: $0, kind: d.kind) },
                       fkCell: t.fkPopover,
                       fkContent: { cell in
                           AnyView(DWForeignKey(tabID: tabID, connection: d, column: r.columns[cell.col], value: store.cellValue(t, row: cell.row, col: cell.col) ?? ""))
                       },
                       onFKDismiss: { ws.update(tabID) { $0.fkPopover = nil } })
                .overlay { if t.loading { Color.black.opacity(0.12).overlay(ProgressView().controlSize(.small)) } }
                .overlay(alignment: .bottom) { if let e = t.error { DWError(message: e).frame(maxHeight: 90).background(Theme.island) } }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .structure:
            if let e = t.detailError, t.detail == nil {
                DWError(message: e)
            } else if let det = t.detail {
                DataGrid(columns: ["column", "type", "nullable", "default", "references"].map { DBColumn(name: $0, type: "") },
                         rows: det.columns.map { c in [c.name + (c.isPK ? "  PK" : ""), c.type, c.nullable ? "yes" : "no", c.defaultValue, c.fk] })
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .indexes:
            if let e = t.detailError, t.detail == nil {
                DWError(message: e)
            } else if let det = t.detail {
                DataGrid(columns: ["name", "columns", "unique", "method", "size"].map { DBColumn(name: $0, type: "") },
                         rows: det.indexes.map { [$0.name, $0.columns.joined(separator: ", "), $0.unique ? "yes" : "no", $0.method, $0.size.ifEmpty("–")] })
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .ddl:
            if let ddl = t.ddl {
                CodeView(text: ddl, language: .sql)
            } else if let e = t.ddlError {
                VStack(spacing: 10) {
                    DWError(message: e).frame(maxHeight: 120)
                    SubtleButton(title: "Try Again", height: 26) { store.loadStructure(tabID) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity).onAppear { store.loadStructure(tabID) }
            }
        }
    }

    private func pendingBar(_ t: DWTab, _ d: DatabaseConnection) -> some View {
        let updates = t.edits.values.filter { !$0.changes.isEmpty }.count
        return HStack(spacing: 10) {
            Text("\(t.pendingCount)").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.onAccent)
                .frame(width: 18, height: 18).background(RoundedRectangle(cornerRadius: 5).fill(Theme.amber))
            Text("Pending changes").font(Typo.ui(12, .semibold)).foregroundStyle(Color(hex: 0xFDE68A)).lineLimit(1)
            HStack(spacing: 6) {
                if updates > 0 { countChip("\(updates) update\(updates == 1 ? "" : "s")", Theme.amber) }
                if !t.inserted.isEmpty { countChip("\(t.inserted.count) insert\(t.inserted.count == 1 ? "" : "s")", Theme.green) }
                if !t.deleted.isEmpty { countChip("\(t.deleted.count) delete\(t.deleted.count == 1 ? "" : "s")", Theme.red) }
            }
            Spacer(minLength: 0)
            Button { preview = true } label: { DWPill { Text("Preview SQL") }.fixedSize() }.buttonStyle(.hand)
                .popover(isPresented: $preview, arrowEdge: .top) {
                    CodeView(text: store.pendingSQL(t).joined(separator: "\n"), language: .sql).frame(width: 560, height: 220)
                }
            Button { store.revertTable(tabID) } label: { DWPill { Text("Revert") }.fixedSize() }.buttonStyle(.hand)
            Button { store.submitTable(tabID) } label: {
                HStack(spacing: 7) {
                    Text("Submit").font(Typo.ui(11.5, .bold))
                    Text("⌘⏎").font(Typo.ui(11.5, .semibold)).opacity(0.6)
                }
                .foregroundStyle(Theme.onAccent).padding(.horizontal, 11).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(accent))
                .fixedSize()
            }
            .buttonStyle(.hand)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(store.dataLocked(d))
        }
        .padding(.leading, 14).padding(.trailing, 10).frame(height: 40)
        .background(LinearGradient(colors: [Theme.amber.opacity(0.10), Theme.amber.opacity(0.02)], startPoint: .leading, endPoint: .trailing))
        .overlay(alignment: .top) { Rectangle().fill(Theme.amber.opacity(0.18)).frame(height: 1) }
    }

    private func countChip(_ text: String, _ c: Color) -> some View {
        Text(text).font(Typo.ui(11)).foregroundStyle(c).padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(c.opacity(0.12)))
            .fixedSize()
    }

    private func export(_ t: DWTab) {
        guard let r = t.result else { return }
        DWExport.csv(columns: r.columns, rows: r.rows, name: t.title)
    }
}

/// The referenced row behind a foreign-key cell.
private struct DWForeignKey: View {
    @Environment(AppStore.self) private var store
    let tabID: UUID
    let connection: DatabaseConnection
    let column: DBColumn
    let value: String
    @State private var row: QueryResult?
    @State private var failure: String?
    @State private var loaded = false

    var body: some View {
        let target = column.fk ?? ""
        let parts = target.split(separator: ".")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "link").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.blue)
                Text(parts.dropLast().joined(separator: ".")).font(Typo.mono(11.5)).foregroundStyle(Theme.text2)
                Text("where").font(Typo.ui(11.5)).foregroundStyle(Theme.meta)
                Text("\(parts.last.map(String.init) ?? "") = '\(value)'").font(Typo.mono(11.5)).foregroundStyle(Color(hex: 0xE4E4E7)).lineLimit(1)
            }
            if let r = row, let first = r.rows.first {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(Array(r.columns.prefix(4).enumerated()), id: \.offset) { i, c in
                        GridRow {
                            Text(c.name).font(Typo.ui(11.5)).foregroundStyle(Theme.meta)
                            Text(first[safe: i].flatMap { $0 } ?? "NULL").font(Typo.ui(11.5, i == 1 ? .semibold : .regular)).foregroundStyle(Theme.text).lineLimit(1)
                        }
                    }
                }
            } else if let failure {
                Text(failure).font(Typo.ui(11.5)).foregroundStyle(Theme.red).lineLimit(4).textSelection(.enabled)
            } else if loaded {
                Text("No matching row.").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 6) {
                Button { store.openReferenced(connection, fk: target, value: value) } label: {
                    Text("Open in tab ⌘B").font(Typo.ui(11, .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 5).fill(Theme.blue))
                }
                .buttonStyle(.hand)
                Button {
                    store.dataWorkspace.update(tabID) {
                        $0.whereText = "\(LiveDatabaseService.quote(column.name, connection.kind)) = \(LiveDatabaseService.literal(value, connection.kind))"
                        $0.fkPopover = nil
                    }
                    store.applyTableFilter(tabID)
                } label: {
                    Text("Filter by this").font(Typo.ui(11)).foregroundStyle(Theme.text2)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 5).fill(Color.white(0.06)))
                }
                .buttonStyle(.hand)
            }
        }
        .padding(12).frame(width: 260, alignment: .leading)
        .task {
            switch await store.fetchReferenced(connection, fk: target, value: value) {
            case .success(let r): row = r
            case .failure(let e): failure = e.message
            }
            loaded = true
        }
    }
}

struct DWError: View {
    let message: String
    var body: some View {
        ScrollView {
            Text(message).font(Typo.mono(12)).foregroundStyle(Theme.red).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
    }
}

enum DWExport {
    @MainActor static func csv(columns: [DBColumn], rows: [[String?]], name: String) {
        let esc = { (s: String) in s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        let text = ([columns.map { esc($0.name) }.joined(separator: ",")] + rows.map { $0.map { esc($0 ?? "") }.joined(separator: ",") }).joined(separator: "\n")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSSound.beep() }
        }
    }
}

/// SQL keyword colouring for one-line fields.
enum SQLHighlight {
    static let keywords: Set<String> = ["select", "from", "where", "join", "left", "on", "as", "and", "or", "group", "by", "order", "desc", "asc", "limit",
                                        "is", "null", "not", "distinct", "interval", "filter", "in", "like", "ilike", "between", "true", "false"]

    static func text(_ s: String) -> Text {
        var out = Text("")
        let pattern = #"('[^']*'?|\b\d+(?:\.\d+)?\b|[A-Za-z_][A-Za-z0-9_]*|\s+|.)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return Text(s) }
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let tok = ns.substring(with: m.range)
            let c: Color
            if tok.hasPrefix("'") { c = Theme.green }
            else if tok.first?.isNumber == true { c = Color(hex: 0xFB923C) }
            else if keywords.contains(tok.lowercased()) { c = Theme.violet }
            else if tok.first?.isLetter == true || tok.first == "_" { c = Color(hex: 0xE4E4E7) }
            else { c = Theme.text3 }
            out = out + Text(tok).foregroundColor(c).fontWeight(keywords.contains(tok.lowercased()) ? .semibold : .regular)
        }
        return out
    }
}

// MARK: - Console tab

struct DWConsolePane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let tabID: UUID
    @State private var dragStart: CGFloat?

    private var ws: DataWorkspace { store.dataWorkspace }

    var body: some View {
        if let t = ws.tabs.first(where: { $0.id == tabID }), let d = store.database(t.connectionID) {
            GeometryReader { g in
                VStack(spacing: 0) {
                    if store.dataLocked(d) { prodBanner(d) }
                    toolbar(t, d)
                    editor(t)
                        .frame(height: min(max(120, t.editorHeight), max(120, g.size.height - 160)))
                    splitter(t)
                    resultsBar(t)
                    results(t)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .hairlineTop()
                }
            }
        }
    }

    private func prodBanner(_ d: DatabaseConnection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.red)
            (Text("PROD").fontWeight(.bold).foregroundColor(Theme.red) + Text(" read-only session · INSERT, UPDATE, DELETE and DDL are blocked · agents get \(d.agentAccess == .none ? "nothing" : "schema only")"))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let q = d.queryTimeout { Text("Statement timeout \(q) s").foregroundStyle(Theme.text3) }
        }
        .font(Typo.ui(11.5)).foregroundStyle(Color(hex: 0xFCA5A5))
        .padding(.horizontal, 14).frame(height: 30)
        .background(LinearGradient(colors: [Theme.red.opacity(0.14), Theme.red.opacity(0.03)], startPoint: .leading, endPoint: .trailing))
    }

    private func toolbar(_ t: DWTab, _ d: DatabaseConnection) -> some View {
        let running = ws.running[tabID] != nil
        let (letters, color) = DWLook.engine(d)
        return DWToolbar {
            Button { store.runConsole(tabID, .caret) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "play.fill").font(.system(size: 9))
                    Text("Run").font(Typo.ui(11.5, .bold))
                    Text("⌘⏎").font(Typo.ui(11.5, .semibold)).opacity(0.55)
                }
                .foregroundStyle(Theme.onAccent).padding(.leading, 9).padding(.trailing, 11).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(accent))
                .fixedSize()
            }
            .buttonStyle(.hand).disabled(running)
            .help("Run the statement under the caret")
            IconButton(symbol: "forward.fill", label: "Run all", size: 26, iconSize: 10) { store.runConsole(tabID, .all) }.disabled(running)
            IconButton(symbol: "list.bullet.indent", label: "Explain plan", size: 26, iconSize: 11) { store.runConsole(tabID, .explain) }.disabled(running)
            IconButton(symbol: "stop.fill", label: "Stop", size: 26, iconSize: 10) { store.stopConsole(tabID) }.disabled(!running).opacity(running ? 1 : 0.4)
            IconButton(symbol: "text.alignleft", label: "Format", size: 26, iconSize: 11) { ws.update(tabID) { $0.sql = SQLFormatter.format($0.sql) } }
            DWVSep()
            MenuButton(items: {
                store.dataLocked(d) ? [MenuSpec(title: "Read-only (Production)", checked: true, enabled: false)] :
                [MenuSpec(title: "Auto-commit", checked: !t.readOnlySession) { ws.update(tabID) { $0.readOnlySession = false } },
                 MenuSpec(title: "Read-only", checked: t.readOnlySession) { ws.update(tabID) { $0.readOnlySession = true } }]
            }) {
                DWPill { Text("Tx").foregroundStyle(Theme.text3); Text(DWTx.label(t, d, store: store)); Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Theme.text3) }
                    .fixedSize()
            }
            MenuButton(items: { [100, 500, 1000, 5000].map { n in MenuSpec(title: "\(n) rows", checked: t.limit == n) { ws.update(tabID) { $0.limit = n } } } }) {
                DWPill { Text("Limit").foregroundStyle(Theme.text3); Text("\(t.limit)").font(Typo.mono(11.5)) }
                    .fixedSize()
            }
            Spacer(minLength: 4)
            MenuButton(items: { switcher(t, d) }) {
                HStack(spacing: 6) {
                    LetterBadge(text: letters, color: color, size: 18)
                    Text(d.name).font(Typo.ui(11.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if !t.schema.isEmpty {
                        Text("›").foregroundStyle(Theme.meta)
                        Text(t.schema).font(Typo.mono(11.5)).foregroundStyle(Theme.body).lineLimit(1)
                    }
                    DWLook.tag(d.tag).fixedSize()
                    Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Theme.text3)
                }
                .padding(.leading, 5).padding(.trailing, 9).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.input))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white(0.08)))
            }
            .accessibilityLabel("Connection and schema for this console: \(d.name) \(t.schema)")
            Button { store.askAgentConsole(tabID) } label: {
                ViewThatFits {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle").font(.system(size: 10.5)).foregroundStyle(Theme.violet)
                        Text("Ask agent").foregroundStyle(Color(hex: 0xDDD6FE))
                        Text("⌘I").foregroundStyle(Theme.text3)
                    }
                    .fixedSize()
                    Image(systemName: "sparkle").font(.system(size: 10.5)).foregroundStyle(Theme.violet)
                }
                .font(Typo.ui(11.5)).padding(.horizontal, 9).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.violet.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.violet.opacity(0.3)))
            }
            .buttonStyle(.hand)
            .disabled(d.agentAccess == .none)
            .help(d.agentAccess == .none ? "Agents can't see \(d.name)" : "The agent gets the schema and this SQL; its answer shows here")
        }
    }

    /// Any explorer connection, then this connection's schemas.
    private func switcher(_ t: DWTab, _ d: DatabaseConnection) -> [MenuSpec] {
        var items: [MenuSpec] = [.header("Connection")]
        items += store.explorerConnections.map { c in
            MenuSpec(title: "\(c.name) · \(DWLook.envLabel(c.tag))", checked: c.id == d.id) {
                store.loadTree(c)
                ws.update(tabID) {
                    $0.connectionID = c.id
                    $0.schema = c.kind == .postgres ? "public" : c.database
                    $0.readOnlySession = store.dataLocked(c) || ($0.readOnlySession && !store.dataLocked(d))
                    $0.results = []
                }
            }
        }
        let schemas = store.schemaCache[d.id]?.schemas.keys.sorted() ?? []
        if d.kind != .sqlite, !schemas.isEmpty {
            items += [.separator, .header("Schema")]
            items += schemas.map { s in MenuSpec(title: s, checked: s == t.schema) { ws.update(tabID) { $0.schema = s } } }
        }
        return items
    }

    private func editor(_ t: DWTab) -> some View {
        let stmts = SQLText.statements(t.sql)
        let runLines = Set(stmts.map { SQLText.firstCodeLine($0, in: t.sql) })
        let current = SQLText.statement(at: t.caret, in: t.sql).map { r -> ClosedRange<Int> in
            let a = SQLText.firstCodeLine(r, in: t.sql)
            let b = SQLText.line(of: max(r.location, NSMaxRange(r) - 1), in: t.sql)
            return a...max(a, b)
        }
        return CodeView(text: t.sql, language: .sql, editable: true,
                        onChange: { v in ws.update(tabID) { $0.sql = v } },
                        highlight: current, highlightColor: accent, background: Theme.editor,
                        onRun: { store.runConsole(tabID, .caret) },
                        onCaret: { c in if c != t.caret { ws.update(tabID) { $0.caret = c } } },
                        runLines: runLines,
                        onRunLine: { line in
                            if let r = stmts.first(where: { SQLText.firstCodeLine($0, in: t.sql) == line }) {
                                ws.update(tabID) { $0.caret = r.location + 1 }
                                store.runConsole(tabID, .caret)
                            }
                        },
                        onTab: { store.acceptGhost(tabID) })
            .overlay(alignment: .bottomLeading) { if let g = t.ghost { ghost(g) } }
    }

    /// An agent's suggestion: dimmed lines and a "Tab to accept" chip.
    private func ghost(_ sql: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("✦ Tab to accept · agent suggestion").font(Typo.ui(10.5)).foregroundStyle(Color(hex: 0xDDD6FE))
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.violet.opacity(0.16)))
                Button("Dismiss") { ws.update(tabID) { $0.ghost = nil } }.buttonStyle(.hand).font(Typo.ui(10.5)).foregroundStyle(Theme.text3)
            }
            Text(sql).font(Typo.mono(12.5)).italic().foregroundStyle(Theme.text.opacity(0.5)).lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 62).padding(.trailing, 12).padding(.vertical, 8)
        .background(Theme.violet.opacity(0.06))
        .background(Theme.editor.opacity(0.92))
    }

    private func splitter(_ t: DWTab) -> some View {
        Rectangle().fill(Theme.input)
            .frame(height: 7)
            .overlay(Capsule().fill(Color.white(0.16)).frame(width: 28, height: 2))
            .overlay(alignment: .top) { Rectangle().fill(Color.white(0.05)).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white(0.05)).frame(height: 1) }
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let start = dragStart ?? t.editorHeight
                    if dragStart == nil { dragStart = start }
                    ws.update(tabID) { $0.editorHeight = min(900, max(120, start + v.translation.height)) }
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityLabel("Resize editor")
    }

    private func resultsBar(_ t: DWTab) -> some View {
        HStack(spacing: 4) {
            if ws.running[tabID] != nil {
                ProgressView().controlSize(.mini)
                Text("Running…").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
            }
            ForEach(t.results) { r in
                let on = r.id == t.shownResult?.id
                Button { ws.update(tabID) { $0.activeResult = r.id; $0.selection = nil } } label: {
                    HStack(spacing: 6) {
                        if on { Circle().fill(r.error == nil ? Theme.green : Theme.red).frame(width: 6, height: 6) }
                        Text(r.label).font(Typo.ui(11.5, on ? .semibold : .medium)).foregroundStyle(on ? Theme.text : Theme.text3)
                        if let res = r.result, r.kind == .result {
                            Text(" · \(res.totalRows.formatted()) row\(res.totalRows == 1 ? "" : "s")").font(Typo.ui(11.5)).foregroundStyle(Theme.meta)
                        }
                    }
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.white(0.07) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hand)
            }
            Spacer(minLength: 0)
            DWSegment(options: DWResultView.allCases.map { ($0, $0.rawValue) }, selection: t.resultView) { v in ws.update(tabID) { $0.resultView = v } }
            IconButton(symbol: "square.and.arrow.down", label: "Export CSV", size: 26, iconSize: 11) {
                if let r = t.shownResult?.result { DWExport.csv(columns: r.columns, rows: r.rows, name: t.title) }
            }
            .disabled(t.shownResult?.result?.columns.isEmpty ?? true)
        }
        .padding(.horizontal, 10).frame(height: 36)
    }

    @ViewBuilder private func results(_ t: DWTab) -> some View {
        if let shown = t.shownResult {
            if let e = shown.error {
                DWError(message: e)
            } else if let r = shown.result {
                if r.columns.isEmpty {
                    Text(r.message ?? "Done.").font(Typo.mono(12)).foregroundStyle(Theme.body)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(14)
                } else {
                    switch t.resultView {
                    case .grid:
                        DWGrid(columns: r.columns, rowCount: r.rows.count, value: { row, col in r.rows[safe: row]?[safe: col] ?? nil },
                               selection: t.selection, barColumn: shown.kind == .result ? barColumn(r, t) : nil,
                               onSelect: { c in ws.update(tabID) { $0.selection = c } })
                    case .chart:
                        DWChart(result: r, column: barColumn(r, t), selected: t.selection?.row) { c in ws.update(tabID) { $0.chartColumn = c } }
                    case .text:
                        ScrollView([.vertical, .horizontal]) {
                            Text(DWText.table(r)).font(Typo.mono(12)).foregroundStyle(Theme.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        }
                    }
                }
            }
        } else {
            Text(ws.running[tabID] == nil ? "Run a statement with ⌘⏎, or click a ▶ in the gutter." : "")
                .font(Typo.ui(12)).foregroundStyle(Theme.meta).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The numeric column that gets data bars and the chart: the chosen one, or the widest-ranging.
    private func barColumn(_ r: QueryResult, _ t: DWTab) -> Int? {
        let numeric = r.columns.indices.filter { i in
            !r.columns[i].isPK && !r.columns[i].name.lowercased().hasSuffix("id") &&
            r.rows.prefix(50).contains { $0[safe: i].flatMap { $0 }.flatMap(DWGrid.number) != nil } &&
            r.rows.prefix(50).allSatisfy { row in row[safe: i].flatMap { $0 }.map { DWGrid.number($0) != nil } ?? true }
        }
        if let c = t.chartColumn, numeric.contains(c) { return c }
        return numeric.max { a, b in
            let sa = r.rows.prefix(200).compactMap { $0[safe: a].flatMap { $0 }.flatMap(DWGrid.number) }.reduce(0, +)
            let sb = r.rows.prefix(200).compactMap { $0[safe: b].flatMap { $0 }.flatMap(DWGrid.number) }.reduce(0, +)
            return sa < sb
        }
    }
}

/// A bar chart of the first label column against a numeric one.
private struct DWChart: View {
    let result: QueryResult
    let column: Int?
    let selected: Int?
    let pick: (Int) -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        let label = result.columns.indices.first { $0 != column } ?? 0
        let rows = Array(result.rows.prefix(60))
        let values = rows.map { row in column.flatMap { c in row[safe: c].flatMap { $0 }.flatMap(DWGrid.number) } ?? 0 }
        let top = values.max() ?? 1
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DWPill { Text("Bar") }
                Text("x").foregroundStyle(Theme.meta)
                Text(result.columns[safe: label]?.name ?? "").font(Typo.mono(11.5)).foregroundStyle(Theme.text)
                Text("y").foregroundStyle(Theme.meta)
                MenuButton(items: {
                    result.columns.indices.filter { i in rows.contains { $0[safe: i].flatMap { $0 }.flatMap(DWGrid.number) != nil } }
                        .map { i in MenuSpec(title: result.columns[i].name, checked: i == column) { pick(i) } }
                }) {
                    Text((column.flatMap { result.columns[safe: $0]?.name } ?? "choose") + " ▾").font(Typo.mono(11.5)).foregroundStyle(Theme.text)
                }
                Spacer()
                if result.rows.count > rows.count { Text("first \(rows.count) of \(result.rows.count) rows").foregroundStyle(Theme.meta) }
            }
            .font(Typo.ui(11.5))
            if column == nil {
                Text("No numeric column to chart.").font(Typo.ui(12)).foregroundStyle(Theme.meta).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { g in
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            VStack(spacing: 5) {
                                Text(Self.short(values[i])).font(Typo.mono(10)).foregroundStyle(Theme.text2).lineLimit(1)
                                RoundedRectangle(cornerRadius: 4).fill(i == selected ? accent : accent.opacity(0.35))
                                    .frame(maxWidth: 46).frame(height: max(2, (g.size.height - 40) * 0.92 * (top > 0 ? values[i] / top : 0)))
                                Text(row[safe: label].flatMap { $0 } ?? "").font(Typo.mono(10)).foregroundStyle(Theme.meta).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .padding(.top, 18)
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
    }

    static func short(_ v: Double) -> String {
        abs(v) >= 1000 ? String(format: "%.1fk", v / 1000) : (v.rounded() == v ? String(Int(v)) : String(format: "%.2f", v))
    }
}

enum DWText {
    /// A plain-text table, columns padded.
    static func table(_ r: QueryResult) -> String {
        let rows = r.rows.prefix(1000).map { $0.map { $0 ?? "NULL" } }
        let widths = r.columns.indices.map { i in min(60, max(r.columns[i].name.count, rows.map { $0[safe: i]?.count ?? 0 }.max() ?? 0)) }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { i, c in String(c.prefix(60)).padding(toLength: widths[safe: i] ?? 0, withPad: " ", startingAt: 0) }.joined(separator: "  ")
        }
        return ([line(r.columns.map(\.name)), widths.map { String(repeating: "─", count: $0) }.joined(separator: "  ")] + rows.map(line)).joined(separator: "\n")
    }
}

// MARK: - Record inspector

struct DWInspector: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let tabID: UUID
    /// Off inside a project panel, which has its own title bar.
    var showHeader = true

    private var ws: DataWorkspace { store.dataWorkspace }

    var body: some View {
        if let t = ws.tab(tabID), let d = store.database(t.connectionID) {
            let cols = (t.isConsole ? t.shownResult?.result?.columns : t.result?.columns) ?? []
            let count = t.isConsole ? (t.shownResult?.result?.rows.count ?? 0) : (t.result?.rows.count ?? 0) + t.inserted.count
            let sel = t.selection ?? (count > 0 ? DWCell(row: 0, col: 0) : nil)
            VStack(spacing: 0) {
                DWHeader(title: showHeader ? "RECORD" : "") {
                    Text(sel.map { "\(t.isConsole ? (t.shownResult?.label ?? "") : t.title) · row \($0.row + 1)" } ?? "").font(Typo.ui(11)).foregroundStyle(Theme.meta).lineLimit(1)
                    Spacer(minLength: 0)
                    IconButton(symbol: "chevron.up", label: "Previous row", size: 26, iconSize: 10) { move(-1, count: count, sel: sel) }.disabled((sel?.row ?? 0) <= 0)
                    IconButton(symbol: "chevron.down", label: "Next row", size: 26, iconSize: 10) { move(1, count: count, sel: sel) }.disabled((sel?.row ?? 0) + 1 >= count)
                }
                if let sel, !cols.isEmpty {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(cols.enumerated()), id: \.offset) { i, c in field(t, d, c, row: sel.row, col: i, selected: sel.col == i) }
                        }
                        .padding(6)
                    }
                    valueBox(t, d, cols, sel)
                } else {
                    Text("Select a row to see it here.").font(Typo.ui(12)).foregroundStyle(Theme.meta).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func value(_ t: DWTab, row: Int, col: Int) -> String? {
        t.isConsole ? t.shownResult?.result?.rows[safe: row]?[safe: col] ?? nil : store.cellValue(t, row: row, col: col)
    }

    private func original(_ t: DWTab, row: Int, col: Int) -> (edited: Bool, was: String?) {
        guard !t.isConsole, let r = t.result, row < r.rows.count, let k = DataEdits.rowKey(r.rows[row], columns: r.columns),
              let e = t.edits[k.id], e.changes[r.columns[col].name] != nil else { return (false, nil) }
        return (true, e.original[r.columns[col].name] ?? nil)
    }

    private func move(_ by: Int, count: Int, sel: DWCell?) {
        let s = sel ?? DWCell(row: 0, col: 0)
        ws.update(tabID) { $0.selection = DWCell(row: min(max(0, s.row + by), max(0, count - 1)), col: s.col) }
    }

    private func field(_ t: DWTab, _ d: DatabaseConnection, _ c: DBColumn, row: Int, col: Int, selected: Bool) -> some View {
        let v = value(t, row: row, col: col)
        let (edited, was) = original(t, row: row, col: col)
        let style = DWGrid.style(v, c, inserted: !t.isConsole && row >= (t.result?.rows.count ?? 0))
        let fkHint: String? = c.fk.flatMap { fk in v.map { _ in "→ \(fk)  ⌘B" } }
        return Button { ws.update(t.id) { $0.selection = DWCell(row: row, col: col) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if c.isPK { KeyGlyph(color: Theme.amber) } else if c.fk != nil { Image(systemName: "link").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.blue) }
                    Text(c.name).font(Typo.ui(10.5, .medium)).foregroundStyle(Theme.text2)
                    Text(c.type).font(Typo.mono(10.5)).foregroundStyle(Color(hex: 0x5E5E68)).lineLimit(1)
                    Spacer(minLength: 0)
                    if edited {
                        Text("EDITED").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.amber)
                            .padding(.horizontal, 5).background(RoundedRectangle(cornerRadius: 4).fill(Theme.amber.opacity(0.12)))
                    }
                }
                Text(style.text).font(Typo.mono(12)).italic(style.italic).foregroundStyle(edited ? Color(hex: 0xFDE68A) : style.color == Theme.body ? Theme.text : style.color)
                    .lineLimit(1).truncationMode(.tail)
                if edited {
                    Text("was “\(was ?? "NULL")”").font(Typo.ui(10.5)).foregroundStyle(Theme.text2).lineLimit(1)
                } else if let fkHint {
                    Text(fkHint).font(Typo.ui(10.5)).foregroundStyle(Theme.meta).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? accent.opacity(0.08) : .clear))
            .overlay(alignment: .leading) { if selected { Rectangle().fill(accent).frame(width: 2).padding(.vertical, 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hand)
        .accessibilityLabel("\(c.name), \(v ?? "NULL")\(edited ? ", edited" : "")")
    }

    private func valueBox(_ t: DWTab, _ d: DatabaseConnection, _ cols: [DBColumn], _ sel: DWCell) -> some View {
        let c = cols[safe: sel.col]
        let v = value(t, row: sel.row, col: sel.col)
        let canEdit = !t.isConsole && !store.dataLocked(d) && (t.result?.columns.contains(where: \.isPK) ?? false)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("VALUE").font(Typo.ui(11, .semibold)).tracking(0.44).foregroundStyle(Theme.text2)
                Text("\(c?.name ?? "") · \(c?.type ?? "")").font(Typo.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(Self.pretty(v)).font(Typo.mono(12)).foregroundStyle(v == nil ? Theme.meta : Theme.text).textSelection(.enabled)
                .lineLimit(10).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white(0.08)))
            HStack(spacing: 6) {
                MenuButton(items: {
                    [MenuSpec(title: "Value") { copy(v ?? "NULL") },
                     MenuSpec(title: "Row as JSON") { copy(Self.json(cols, row: cols.indices.map { value(t, row: sel.row, col: $0) })) },
                     MenuSpec(title: "WHERE clause") { copy("\(LiveDatabaseService.quote(c?.name ?? "", d.kind)) = \(DataEdits.value(v, d.kind))") }]
                }) {
                    DWPill { Text("Copy as"); Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Theme.text3) }
                        .frame(maxWidth: .infinity)
                }
                Button { store.stageCell(t.id, row: sel.row, col: sel.col, value: nil) } label: { DWPill { Text("Set NULL") }.frame(maxWidth: .infinity) }
                    .buttonStyle(.hand)
                    .disabled(!canEdit || c?.isPK == true || c?.nullable == false)
            }
            Button { store.askAgentRow(t.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").font(.system(size: 10.5)).foregroundStyle(Theme.violet)
                    Text("Ask agent about this row")
                }
                .font(Typo.ui(11.5)).foregroundStyle(Color(hex: 0xDDD6FE))
                .frame(maxWidth: .infinity).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.violet.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.violet.opacity(0.3)))
            }
            .buttonStyle(.hand)
            .disabled(d.agentAccess == .none)
            .help(d.agentAccess == .none ? "Agents can't see \(d.name)" : d.agentAccess == .schema ? "Agents get the columns only (schema only)" : "Sends this row's columns and values; sensitive columns are masked")
        }
        .padding(10)
        .hairlineTop()
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func pretty(_ v: String?) -> String {
        guard let v else { return "NULL" }
        let trimmed = v.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return v }
        return String(decoding: out, as: UTF8.self)
    }

    static func json(_ cols: [DBColumn], row: [String?]) -> String {
        let dict = Dictionary(zip(cols.map(\.name), row.map { $0 as Any? ?? NSNull() }), uniquingKeysWith: { a, _ in a })
        guard let data = try? JSONSerialization.data(withJSONObject: dict.mapValues { $0 ?? NSNull() }, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A 40pt toolbar row; when the pane is too narrow it scrolls sideways instead of clipping.
struct DWToolbar<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { content() }
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 4) { content() } }
        }
        .padding(.horizontal, 10).frame(height: 40)
    }
}
