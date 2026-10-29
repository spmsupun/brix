import SwiftUI
import AppKit

/// Databases: table and SQL console tabs from any connection, opened from the
/// database tree in the sidebar, with a record inspector. With no tabs open it
/// shows the connections overview.
struct DataWorkspaceView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    @AppStorage("db.explorerWidth") private var explorerWidth: Double = 300

    var body: some View {
        let ws = store.dataWorkspace
        if store.library.databases.isEmpty {
            EmptyState(symbol: "cylinder.split.1x2", message: "No databases yet. Add PostgreSQL, MySQL or SQLite.", actionTitle: "Add Database") { store.sheet = .editDatabase(nil) }
                .island()
        } else if let d = ws.explorer.flatMap(store.database) {
            HStack(spacing: 0) {
                DBExplorer(connection: d).id(d.id).frame(width: explorerWidth)
                ResizeHandle(axis: .horizontal, thickness: gap) { explorerWidth = min(max(explorerWidth + $0, 220), 520) }
                if ws.screenTabs.isEmpty {
                    EmptyState(symbol: "tablecells", message: "Pick a table to open it here.").island()
                } else {
                    DWEditor()
                    if ws.showInspector, let t = ws.current, t.projectID == nil { DWInspector(tabID: t.id).frame(width: 264).island().padding(.leading, gap) }
                }
            }
            .onAppear(perform: consumeRequests)
            .onChange(of: store.pendingQuery?.sql) { _, _ in consumeRequests() }
            .popover(isPresented: Binding(get: { ws.goTo }, set: { ws.goTo = $0 }), arrowEdge: .top) { DWGoTo() }
            .background(DWShortcuts(tabID: ws.current?.id))
        } else if ws.screenTabs.isEmpty {
            DBConnectionsView()
                .onAppear(perform: consumeRequests)
                .onChange(of: store.pendingQuery?.sql) { _, _ in consumeRequests() }
        } else {
            HStack(spacing: gap) {
                DWEditor()
                if ws.showInspector, let t = ws.current, t.projectID == nil { DWInspector(tabID: t.id).frame(width: 264).island() }
            }
            .onAppear(perform: consumeRequests)
            .onChange(of: store.pendingQuery?.sql) { _, _ in consumeRequests() }
            .popover(isPresented: Binding(get: { ws.goTo }, set: { ws.goTo = $0 }), arrowEdge: .top) { DWGoTo() }
            .background(DWShortcuts(tabID: ws.current?.id))
        }
    }

    /// "Run this SQL" from elsewhere opens a console.
    private func consumeRequests() {
        if let q = store.pendingQuery, let d = store.database(q.connection) {
            store.pendingQuery = nil
            store.newConsole(d, sql: q.sql)
        }
    }
}

/// Keyboard for the data tab in front: ⇧⌘L new console, ⌘B jump to the
/// foreign key, ⌘I ask the agent.
struct DWShortcuts: View {
    @Environment(AppStore.self) private var store
    let tabID: UUID?
    var project: ProjectID? = nil

    var body: some View {
        ZStack {
            Button("") { store.newConsole(project: project) }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("") { jumpFK() }.keyboardShortcut("b", modifiers: .command)
            Button("") {
                guard let t = tabID.flatMap(store.dataWorkspace.tab) else { return }
                if t.isConsole { store.askAgentConsole(t.id) } else { store.askAgentRow(t.id) }
            }
            .keyboardShortcut("i", modifiers: .command)
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }

    private func jumpFK() {
        guard let t = tabID.flatMap(store.dataWorkspace.tab), let sel = t.selection, let d = store.database(t.connectionID),
              let col = t.result?.columns[safe: sel.col], let fk = col.fk, let v = store.cellValue(t, row: sel.row, col: sel.col) else { return }
        store.openReferenced(d, fk: fk, value: v, project: t.projectID)
    }
}

// MARK: - Shared look

enum DWLook {
    static func env(_ t: EnvTag) -> Color { DatabaseEditorSheet.envColor(t) }

    static func envLabel(_ t: EnvTag) -> String {
        switch t {
        case .prod: "PROD"
        case .stage: "STAGE"
        case .dev: "DEV"
        case .personal: "PERS"
        case .local: "LOCAL"
        }
    }

    static func engine(_ d: DatabaseConnection) -> (String, Color) {
        let f = DBProduct.flavor(d)
        return (DatabaseEditorSheet.letters(f), DatabaseEditorSheet.color(f))
    }

    static func tag(_ t: EnvTag) -> some View {
        Text(envLabel(t)).font(.system(size: 9, weight: .heavy)).tracking(0.45).foregroundStyle(env(t))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(env(t).opacity(0.13)))
    }

    static func version(_ d: DatabaseConnection) -> String {
        let v = d.serverVersion.isEmpty ? DBProduct.flavor(d).label : DatabaseEditorSheet.shortVersion(d.serverVersion)
        let at = d.kind == .sqlite ? (d.filePath as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~") : "\(d.host):\(d.port)"
        return "\(v) · \(at)"
    }
}

struct DWHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Typo.ui(11, .semibold)).tracking(0.44).foregroundStyle(Theme.text2)
            trailing()
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 38)
        .hairlineBottom()
    }
}

/// Recent queries, newest first; a click opens one in a new console.
struct DWHistory: View {
    @Environment(AppStore.self) private var store
    let done: () -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if store.library.queryHistory.isEmpty {
                    Text("No queries yet.").font(Typo.ui(12)).foregroundStyle(Theme.text3).padding(10)
                }
                ForEach(store.library.queryHistory.prefix(200)) { h in
                    Button {
                        store.newConsole(store.database(h.connectionID), sql: h.sql)
                        done()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.sql.trimmingCharacters(in: .whitespacesAndNewlines)).font(Typo.mono(11.5)).foregroundStyle(h.error == nil ? Theme.body : Theme.red).lineLimit(2)
                            Text("\(store.database(h.connectionID)?.name ?? "removed") · \(RelativeTime.short(h.ranAt)) · \(h.error ?? "\(h.rows) rows · \(Int(h.ms)) ms")")
                                .font(Typo.ui(10.5)).foregroundStyle(Theme.meta).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        }
        .frame(width: 420, height: 420)
    }
}

/// ⌘O: go to any table in the explorer's connections, or an open console.
private struct DWGoTo: View {
    @Environment(AppStore.self) private var store
    @State private var q = ""
    @FocusState private var focused: Bool

    private var items: [(id: String, title: String, sub: String, run: () -> Void)] {
        var out: [(String, String, String, () -> Void)] = store.dataWorkspace.tabs.filter(\.isConsole).map { t in
            ("t" + t.id.uuidString, t.title, "console · " + (store.database(t.connectionID)?.name ?? ""), { store.dataWorkspace.active = t.id })
        }
        for d in store.explorerConnections {
            for o in (store.schemaCache[d.id]?.schemas.values.flatMap { $0 } ?? []) where o.kind != .function {
                out.append(("o" + d.id + o.id, o.name, "\(d.name) › \(o.schema)", { store.openTable(d, o) }))
            }
        }
        let s = q.trimmingCharacters(in: .whitespaces)
        let hits = s.isEmpty ? out : out.filter { $0.1.localizedCaseInsensitiveContains(s) || $0.2.localizedCaseInsensitiveContains(s) }
        return Array(hits.prefix(60))
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            TextField("Go to table or console…", text: $q)
                .textFieldStyle(.plain).font(Typo.ui(13)).focused($focused)
                .padding(.horizontal, 12).frame(height: 38).hairlineBottom()
                .onSubmit { if let f = list.first { f.run(); store.dataWorkspace.goTo = false } }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list, id: \.id) { i in
                        Button { i.run(); store.dataWorkspace.goTo = false } label: {
                            HStack {
                                Text(i.title).font(Typo.ui(12.5)).foregroundStyle(Theme.text)
                                Spacer()
                                Text(i.sub).font(Typo.ui(11)).foregroundStyle(Theme.meta)
                            }
                            .padding(.horizontal, 12).frame(height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 460, height: 360)
        .onAppear { focused = true }
    }
}

// MARK: - Editor (tabs + body + footer)

/// The screen's tabs in split panes, with the same strip, drag and split as a project.
private struct DWEditor: View {
    @Environment(AppStore.self) private var store
    @State private var history = false

    private var ws: DataWorkspace { store.dataWorkspace }

    private var frontKey: String? {
        let tree = ws.screenTree
        let g = tree.focusedGroup.flatMap { tree.group($0) } ?? tree.groups.first
        return g?.active ?? g?.tabs.first
    }

    var body: some View {
        SessionPaneTree(tree: Binding(get: { ws.screenTree }, set: { ws.screenTree = $0 }), host: TiledHost(
            addPopover: nil,
            addMenu: { _ in
                [MenuSpec(title: "New Console", symbol: "terminal", key: "⇧⌘L") { store.newConsole() },
                 MenuSpec(title: "Go to Table…", symbol: "magnifyingglass", key: "⌘O") { ws.goTo = true },
                 .separator,
                 MenuSpec(title: "Query History…", symbol: "clock") { history = true },
                 MenuSpec(title: ws.showInspector ? "Hide Record" : "Show Record", symbol: "sidebar.right") { ws.showInspector.toggle() }]
            },
            newTerminal: { nil },
            close: { keys in
                for k in keys { if let id = GridItemID.dataTabID(k) { store.closeDataTab(id) } else { ws.screenTree.remove(k) } }
            },
            content: { key in AnyView(DWScreenTile(key: key)) }))
        .popover(isPresented: $history, arrowEdge: .top) { DWHistory { history = false } }
        // The tab in front of the focused pane is the current one (Record, shortcuts).
        .onChange(of: frontKey, initial: true) { _, key in
            if let id = key.flatMap(GridItemID.dataTabID), ws.tab(id) != nil { ws.active = id }
        }
        .onAppear {
            // Keys whose tab is gone (closed elsewhere) don't stay in the strip.
            let live = Set(ws.screenTabs.map(\.tileKey))
            if !Set(ws.screenTree.allTabs).isSubset(of: live) { ws.screenTree.retain(live) }
        }
    }
}

/// One tab's body on the Databases screen; showing it makes it the current tab.
private struct DWScreenTile: View {
    @Environment(AppStore.self) private var store
    let key: String

    var body: some View {
        if let id = GridItemID.dataTabID(key), store.dataWorkspace.tab(id) != nil {
            DWTabBody(tabID: id)
                .background(Theme.island)
                .onAppear { store.dataWorkspace.active = id }
        } else {
            EmptyState(symbol: "tablecells", message: "This tab was closed.")
        }
    }
}

/// Icon, `name · connection`, pending / PROD dot and close button, for any data tab.
struct DWTabLabel: View {
    @Environment(AppStore.self) private var store
    let tab: DWTab
    let connection: DatabaseConnection?
    let selected: Bool
    var hovering = false
    var showConnection = true
    var onClose: () -> Void

    var body: some View {
        let d = connection
        let prod = d.map(store.dataLocked) ?? false
        HStack(spacing: 7) {
            Image(systemName: tab.isConsole ? "chevron.right.square" : "tablecells").font(.system(size: 11, weight: .medium))
                .foregroundStyle(d.map { DWLook.env($0.tag) } ?? Theme.text3)
            (Text(tab.title).foregroundColor(selected ? Theme.text : Theme.text3)
             + Text(showConnection ? " · \(d?.name ?? "")" : "").foregroundColor(Theme.meta).fontWeight(.regular))
                .font(Typo.ui(12, selected ? .medium : .regular)).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if tab.pendingCount > 0 {
                Circle().fill(Theme.amber).frame(width: 6, height: 6).help("\(tab.pendingCount) pending changes")
            } else if prod {
                Circle().fill(Theme.red).frame(width: 6, height: 6).background(Circle().fill(Theme.red.opacity(0.18)).padding(-3)).help("Production")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(selected || hovering ? Theme.text3 : .clear)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.title)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel("\(tab.title), \(d?.name ?? "")\(tab.pendingCount > 0 ? ", \(tab.pendingCount) pending changes" : "")")
    }
}

/// A data tab's body and footer, wherever it shows (Databases screen or a project tab).
struct DWTabBody: View {
    @Environment(AppStore.self) private var store
    let tabID: UUID

    var body: some View {
        if let t = store.dataWorkspace.tab(tabID), let d = store.database(t.connectionID) {
            VStack(spacing: 0) {
                if t.isConsole { DWConsolePane(tabID: t.id) } else { DWTablePane(tabID: t.id) }
                footer(t, d)
            }
        } else {
            EmptyState(symbol: "tablecells", message: "This connection was removed.")
        }
    }

    private func footer(_ t: DWTab, _ d: DatabaseConnection) -> some View {
        let rows: String = {
            if t.isConsole {
                guard let r = t.shownResult?.result else { return "" }
                return r.columns.isEmpty ? (r.message ?? "") : "\(r.totalRows.formatted()) row\(r.totalRows == 1 ? "" : "s")"
            }
            guard let r = t.result else { return "" }
            let start = r.rows.isEmpty ? 0 : t.page * AppStore.tablePageSize + 1
            return "Rows \(start.formatted())–\((t.page * AppStore.tablePageSize + r.rows.count).formatted()) of \(r.totalRows.formatted())"
        }()
        let ms = t.isConsole ? t.shownResult?.result?.elapsedMs : t.result?.elapsedMs
        let when = t.isConsole ? t.shownResult.map { " · " + $0.ranAt.formatted(date: .omitted, time: .standard) } ?? "" : ""
        return HStack(spacing: 12) {
            Circle().fill(DWLook.env(d.tag)).frame(width: 6, height: 6)
            Text("\(d.name) › \(t.object.map { "\($0.schema).\($0.name)" } ?? t.title)").font(Typo.mono(11)).foregroundStyle(Theme.body).lineLimit(1)
            Text(rows).lineLimit(1)
            if let ms { Text("\(Int(ms)) ms\(when)").font(Typo.mono(11)) }
            Spacer(minLength: 0)
            Text(DWTx.label(t, d, store: store))
            Text(d.serverVersion.isEmpty ? DBProduct.flavor(d).label : DatabaseEditorSheet.shortVersion(d.serverVersion)).lineLimit(1)
        }
        .font(Typo.ui(11)).foregroundStyle(Theme.text3)
        .padding(.horizontal, 12).frame(height: 28)
        .hairlineTop()
    }
}

/// The transaction mode a tab runs in.
enum DWTx {
    @MainActor static func label(_ t: DWTab, _ d: DatabaseConnection, store: AppStore) -> String {
        if store.dataLocked(d) || t.readOnlySession { return "Read-only" }
        return t.isConsole ? "Auto-commit" : "Manual"
    }
}

/// Small rounded pill from the design (Tx, Limit, connection switcher).
struct DWPill<Label: View>: View {
    @ViewBuilder var label: () -> Label
    var body: some View {
        HStack(spacing: 6) { label() }
            .font(Typo.ui(11.5)).foregroundStyle(Theme.body)
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white(0.08)))
    }
}

struct DWSegment<T: Hashable>: View {
    let options: [(T, String)]
    let selection: T
    let pick: (T) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { v, l in
                Button { pick(v) } label: {
                    Text(l).font(Typo.ui(11, .medium)).foregroundStyle(v == selection ? Theme.text : Theme.text3)
                        .fixedSize()
                        .padding(.horizontal, 9).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(v == selection ? Color.white(0.09) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(v == selection ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.input))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white(0.06)))
    }
}

struct DWVSep: View {
    var body: some View { Rectangle().fill(Color.white(0.08)).frame(width: 1, height: 16).padding(.horizontal, 4) }
}

// MARK: - Project tiles

/// A table or console opened from a project's database tree, as one of its tabs.
struct DataTabTile: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    let key: String
    @State private var tried = false

    var body: some View {
        let ref = GridItemID.dataTabRef(key)
        Group {
            if let ref, let t = store.dataWorkspace.tab(ref.id) {
                DWTabBody(tabID: t.id)
                    .background(Theme.island)
                    .background(DWShortcuts(tabID: t.id, project: ws.projectID))
                    .onAppear { store.dataWorkspace.lastInProject[ws.projectID] = t.id }
            } else if tried {
                EmptyState(symbol: "tablecells", message: ref.flatMap { store.database($0.connection) } == nil ? "This connection is no longer saved." : "This tab was closed.")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // After a relaunch the tab is recreated here, outside the view's body.
        .task(id: key) {
            _ = store.dataTab(forTile: key, project: ws.projectID)
            tried = true
        }
    }
}

/// The project's Record panel: the selected row of its data tab in front.
struct RecordPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore

    var body: some View {
        PanelChrome(title: "Record") {
            if let id = store.dataWorkspace.lastInProject[ws.projectID], store.dataWorkspace.tab(id) != nil {
                DWInspector(tabID: id, showHeader: false)
            } else {
                EmptyState(symbol: "list.bullet.rectangle", message: "Open a table from the project's database tree to see a row here.")
            }
        }
    }
}
