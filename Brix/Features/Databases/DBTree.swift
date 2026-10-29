import SwiftUI
import AppKit

/// A connection's schemas, Tables / Views / Routines and objects, as sidebar
/// rows (DataGrip style). A table opens as a tab: in the project's workspace
/// when `project` is set, else on the Databases screen.
struct DBTreeRows: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let connection: DatabaseConnection
    /// Separates open/closed state per place the tree shows ("lib", a project id).
    let scope: String
    let indent: CGFloat
    var project: ProjectID? = nil

    var initialQuery = ""
    /// Off when the place showing the tree has its own search box.
    var showSearch = true
    /// Databases (schemas) start open: the key then records a closed one.
    var schemasOpen = false
    @State private var query = ""
    /// How many objects a folder shows before "Show more": long lists stay cheap.
    @State private var limit: [String: Int] = [:]
    private static let page = 50

    private var ws: DataWorkspace { store.dataWorkspace }

    var body: some View {
        let d = connection
        if let err = ws.treeErrors[d.id], store.schemaCache[d.id] == nil {
            HStack(spacing: 6) {
                Text(err).font(Typo.ui(11)).foregroundStyle(Theme.red).lineLimit(2).help(err)
                Button("Retry") { store.loadTree(d, force: true) }.buttonStyle(.hand).font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text2)
            }
            .padding(.leading, indent).padding(.trailing, 8).padding(.vertical, 4)
        } else if let tree = store.schemaCache[d.id] {
            let schemas = tree.schemas.keys.sorted()
            if showSearch, tree.schemas.values.reduce(0, { $0 + $1.count }) > 12 { search }
            Color.clear.frame(height: 0).onChange(of: initialQuery, initial: true) { _, q in query = q }
            if schemas.isEmpty {
                Text("No tables").font(Typo.ui(11)).foregroundStyle(Theme.meta).padding(.leading, indent).frame(height: 22)
            }
            let q = query.trimmingCharacters(in: .whitespaces)
            // A search matches database names too: a matching database shows all its
            // tables, and databases with nothing matching drop out.
            let shown = schemas.filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) || tree.schemas[$0]?.contains { $0.name.localizedCaseInsensitiveContains(q) } == true }
            if !q.isEmpty, shown.isEmpty {
                Text("Nothing matches").font(Typo.ui(11)).foregroundStyle(Theme.meta).padding(.leading, indent).frame(height: 22)
            }
            ForEach(shown, id: \.self) { schema in
                let objs = (tree.schemas[schema] ?? []).filter { q.isEmpty || schema.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q) }
                if schemas.count == 1 {
                    // A lone schema adds nothing: its folders sit right under the connection.
                    folders(schema, objs, indent: indent)
                } else {
                    let key = "\(scope)|s:\(d.id).\(schema)"
                    let open = !q.isEmpty || schemasOpen != ws.expanded.contains(key)
                    row(indent: indent, icon: "cylinder", iconColor: Theme.text2, name: schema, meta: "\(objs.filter { $0.kind != .function }.count)",
                        open: open) { toggle(key) }
                    if open { folders(schema, objs, indent: indent + 14) }
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading…").font(Typo.ui(11)).foregroundStyle(Theme.meta)
            }
            .padding(.leading, indent).frame(height: 22)
            .onAppear { store.loadTree(d) }
        }
    }

    @ViewBuilder private func folders(_ schema: String, _ objs: [DBObject], indent: CGFloat) -> some View {
        folder(schema, "Tables", "tablecells", objs.filter { $0.kind == .table }, indent: indent, openByDefault: true)
        folder(schema, "Views", "eye", objs.filter { $0.kind == .view }, indent: indent, openByDefault: false)
        folder(schema, "Routines", "function", objs.filter { $0.kind == .function }, indent: indent, openByDefault: false)
    }

    @ViewBuilder private func folder(_ schema: String, _ title: String, _ icon: String, _ objs: [DBObject], indent: CGFloat, openByDefault: Bool) -> some View {
        if !objs.isEmpty {
            // Tables start open: the key records the opposite of the default.
            let key = "\(scope)|f:\(connection.id).\(schema).\(title)"
            // A search opens every folder with a match.
            let open = !query.isEmpty || openByDefault != ws.expanded.contains(key)
            row(indent: indent, icon: "folder", iconColor: Theme.meta, name: title, meta: "\(objs.count)", open: open) { toggle(key) }
            if open {
                let sorted = objs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                let shown = limit[key] ?? Self.page
                ForEach(sorted.prefix(shown)) { o in object(o, indent: indent + 14, icon: icon) }
                if sorted.count > shown {
                    Button { limit[key] = shown + Self.page * 4 } label: {
                        Text("Show \(min(Self.page * 4, sorted.count - shown)) more of \(sorted.count - shown)")
                            .font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                            .padding(.leading, indent + 29).frame(height: 24).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hand)
                }
            }
        }
    }

    private func object(_ o: DBObject, indent: CGFloat, icon: String) -> some View {
        let d = connection
        let tab = ws.tabs.first { $0.connectionID == d.id && $0.object == o && $0.projectID == project }
        let current = tab != nil && tab?.id == ws.active
        return row(indent: indent, icon: icon, iconColor: current ? accent : Theme.text3, name: o.name,
                   meta: o.rowEstimate.map(Compact.number) ?? "", open: nil, openDot: tab == nil ? nil : (current ? accent : Theme.disabled), current: current) {
            if o.kind == .function {
                store.newConsole(d, sql: "-- \(o.schema).\(o.name)\n", project: project)
            } else {
                store.openTable(d, o, project: project)
            }
        }
        .contextMenu {
            if o.kind != .function { Button("Open") { store.openTable(d, o, project: project) } }
            Button("Select in New Console") { store.newConsole(d, sql: "SELECT * FROM \(DataEdits.table(o, d.kind)) LIMIT 100;", project: project) }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(o.name, forType: .string)
            }
        }
    }

    /// Filters this connection's objects by name.
    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.text3)
            TextField("Filter databases and tables", text: $query).textFieldStyle(.plain).font(Typo.ui(11.5))
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.text3) }
                    .buttonStyle(.hand).accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 7).frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.input))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white(0.06)))
        .padding(.leading, indent).padding(.trailing, 8).padding(.vertical, 3)
    }

    private func toggle(_ key: String) {
        if ws.expanded.contains(key) { ws.expanded.remove(key) } else { ws.expanded.insert(key) }
    }

    /// `open`: nil for a leaf, else whether its chevron points down.
    private func row(indent: CGFloat, icon: String, iconColor: Color, name: String, meta: String, open: Bool?,
                     openDot: Color? = nil, current: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.meta)
                    .rotationEffect(.degrees(open == true ? 90 : 0)).frame(width: 9).opacity(open == nil ? 0 : 1)
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(iconColor).frame(width: 13)
                Text(name).font(Typo.ui(12, current ? .semibold : .regular)).foregroundStyle(current ? Theme.text : Theme.body).lineLimit(1)
                if let openDot { Circle().fill(openDot).frame(width: 5, height: 5) }
                Spacer(minLength: 0)
                Text(meta).font(Typo.mono(10.5)).foregroundStyle(Theme.meta)
            }
            .padding(.leading, indent).padding(.trailing, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(current ? accent.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hand)
        .accessibilityLabel(name)
        .accessibilityValue(open.map { $0 ? "Expanded" : "Collapsed" } ?? "")
    }
}

/// Every saved connection under the sidebar's Databases row. A click opens it
/// on the Databases screen, where its databases and tables are listed.
struct DBLibraryTree: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    @State private var query = ""
    @State private var scroll = ScrollMetrics()

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let conns = store.library.databases.filter { d in
            q.isEmpty || d.name.localizedCaseInsensitiveContains(q) || d.host.localizedCaseInsensitiveContains(q) || d.database.localizedCaseInsensitiveContains(q)
        }
        VStack(alignment: .leading, spacing: 1) {
            if store.library.databases.count > 6 { SidebarSearch(placeholder: "Search connections", text: $query) }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if conns.isEmpty {
                        Text(store.library.databases.isEmpty ? "No connections yet" : "No matches").font(Typo.ui(11.5)).foregroundStyle(Theme.meta)
                            .padding(.leading, 10).frame(height: 24)
                    }
                    ForEach(conns) { d in
                        let on = store.route == .databases && store.dataWorkspace.explorer == d.id
                        Button { store.explore(d) } label: {
                            HStack(spacing: 7) {
                                DatabaseIcon(db: d, size: 16)
                                Text(d.name).font(Typo.ui(12.5, on ? .semibold : .regular)).foregroundStyle(on ? Theme.text : Theme.body).lineLimit(1)
                                Spacer(minLength: 0)
                                DWLook.tag(d.tag)
                                Circle().fill(store.dbStatus[d.id] == .connected ? Theme.green : Theme.disabled).frame(width: 6, height: 6)
                            }
                            .padding(.leading, 12).padding(.trailing, 8)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.selected : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hand)
                        .contextMenu {
                            Button("New Console") { store.newConsole(d) }
                            Button("Refresh") { store.loadTree(d, force: true) }
                            Divider()
                            Button("Edit Connection…") { store.sheet = .editDatabase(d) }
                        }
                    }
                }
                .reportsScrollPosition(scroll)
            }
            .thinScrollBar(scroll)
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Databases screen's list beside the tabs: one connection's databases
/// (schemas), their Tables, Views and Routines. A table opens as a tab.
struct DBExplorer: View {
    @Environment(AppStore.self) private var store
    let connection: DatabaseConnection
    /// Set inside a project: tables open as the project's tabs, beside its agents.
    var project: ProjectID? = nil
    /// Inside a dock panel, which draws its own island.
    var bare = false
    @State private var query = ""
    @State private var scroll = ScrollMetrics()

    var body: some View {
        let d = connection
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
                    TextField("Search databases and tables", text: $query).textFieldStyle(.plain).font(Typo.ui(12.5))
                        .onExitCommand { query = "" }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.text3) }
                            .buttonStyle(.hand).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 9).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.divider))
                IconButton(symbol: "plus.rectangle", label: "New console", size: 28, iconSize: 12) { store.newConsole(d, project: project) }
                IconButton(symbol: "arrow.clockwise", label: "Refresh", size: 28, iconSize: 12) { store.loadTree(d, force: true) }
            }
            .padding(10)
            Button { store.sheet = .editDatabase(d) } label: {
                HStack(spacing: 10) {
                    DatabaseIcon(db: d, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(d.name).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            DWLook.tag(d.tag)
                        }
                        Text(d.kind == .sqlite ? (d.filePath as NSString).lastPathComponent : "\(d.host)\(d.port > 0 ? ":\(d.port)" : "")")
                            .font(Typo.mono(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Circle().fill(store.dbStatus[d.id] == .connected ? Theme.green : Theme.disabled).frame(width: 7, height: 7)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white(0.04)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.hand)
            .help("Edit connection")
            .padding(.horizontal, 10).padding(.bottom, 8)
            .hairlineBottom()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    DBTreeRows(connection: d, scope: project ?? "exp", indent: 6, project: project, initialQuery: query, showSearch: false,
                               schemasOpen: (store.schemaCache[d.id]?.schemas.count ?? 0) <= 3)
                }
                .padding(6)
                .reportsScrollPosition(scroll)
            }
            .thinScrollBar(scroll)
        }
        .modifier(IslandUnless(bare: bare))
        .onAppear { store.loadTree(d) }
    }
}

private struct IslandUnless: ViewModifier {
    let bare: Bool
    func body(content: Content) -> some View {
        if bare { content } else { content.island() }
    }
}

/// A project's Database panel: one linked connection's databases and tables;
/// a table opens as a tab in the project, so it can sit beside an agent.
struct ProjectDBPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    let panel: PanelInstance

    var body: some View {
        let dbs = store.linkedDatabases(ws.projectID)
        // Never stand in another connection for one that was removed or unlinked:
        // its tables would open against a database nobody picked.
        let d = panel.resourceID.map { id in dbs.first { $0.id == id } } ?? dbs.first
        PanelChrome(title: d?.name ?? "Database") {
            Spacer(minLength: 0)
        } content: {
            if let d {
                DBExplorer(connection: d, project: ws.projectID, bare: true).id(d.id)
            } else {
                EmptyState(symbol: "cylinder.split.1x2",
                           message: panel.resourceID == nil ? "No database linked to this project." : "This connection was removed or unlinked from the project.",
                           actionTitle: "Link one") {
                    store.route = .projectSettings(ws.projectID)
                }
            }
        }
    }
}

/// The sidebar's search box: the same look and spacing wherever one opens.
struct SidebarSearch: View {
    let placeholder: String
    @Binding var text: String
    var onExit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(Typo.ui(12)).focused($focused)
                .onExitCommand { text = ""; onExit() }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10.5)).foregroundStyle(Theme.text3) }
                    .buttonStyle(.hand).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.input))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.border.opacity(2) : Theme.divider))
        // Room above and below, so it never touches the row it opened from.
        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 6)
    }
}
