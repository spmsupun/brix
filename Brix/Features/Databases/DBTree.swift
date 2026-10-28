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
                Button("Retry") { store.loadTree(d, force: true) }.buttonStyle(.plain).font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text2)
            }
            .padding(.leading, indent).padding(.trailing, 8).padding(.vertical, 4)
        } else if let tree = store.schemaCache[d.id] {
            let schemas = tree.schemas.keys.sorted()
            if tree.schemas.values.reduce(0, { $0 + $1.count }) > 12 { search }
            Color.clear.frame(height: 0).onChange(of: initialQuery, initial: true) { _, q in query = q }
            if schemas.isEmpty {
                Text("No tables").font(Typo.ui(11)).foregroundStyle(Theme.meta).padding(.leading, indent).frame(height: 22)
            }
            ForEach(schemas, id: \.self) { schema in
                let q = query.trimmingCharacters(in: .whitespaces)
                let objs = (tree.schemas[schema] ?? []).filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
                if schemas.count == 1 {
                    // A lone schema adds nothing: its folders sit right under the connection.
                    folders(schema, objs, indent: indent)
                } else {
                    let key = "\(scope)|s:\(d.id).\(schema)"
                    row(indent: indent, icon: "cylinder", iconColor: Theme.text2, name: schema, meta: "\(objs.filter { $0.kind != .function }.count)",
                        open: ws.expanded.contains(key)) { toggle(key) }
                    if ws.expanded.contains(key) { folders(schema, objs, indent: indent + 14) }
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
                    .buttonStyle(.plain)
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
            TextField("Filter tables", text: $query).textFieldStyle(.plain).font(Typo.ui(11.5))
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.text3) }
                    .buttonStyle(.plain).accessibilityLabel("Clear filter")
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
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(open.map { $0 ? "Expanded" : "Collapsed" } ?? "")
    }
}

/// Every saved connection under the sidebar's Databases row, each opening into its tree.
struct DBLibraryTree: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var scroll = ScrollMetrics()

    var body: some View {
        let ws = store.dataWorkspace
        let q = query.trimmingCharacters(in: .whitespaces)
        let conns = store.library.databases.filter { d in
            q.isEmpty || d.name.localizedCaseInsensitiveContains(q) || d.host.localizedCaseInsensitiveContains(q)
                || (store.schemaCache[d.id]?.schemas.values.contains { $0.contains { $0.name.localizedCaseInsensitiveContains(q) } } ?? false)
        }
        VStack(alignment: .leading, spacing: 1) {
            SidebarSearch(placeholder: "Search connections and tables", text: $query)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if conns.isEmpty {
                        Text(store.library.databases.isEmpty ? "No connections yet" : "No matches").font(Typo.ui(11.5)).foregroundStyle(Theme.meta)
                            .padding(.leading, 10).frame(height: 24)
                    }
                    ForEach(conns) { d in
                        let key = "lib|c:" + d.id
                        // A table match opens its connection.
                        let open = ws.expanded.contains(key) || (!q.isEmpty && !d.name.localizedCaseInsensitiveContains(q))
                        Button {
                            if ws.expanded.contains(key) { ws.expanded.remove(key) } else { ws.expanded.insert(key); store.loadTree(d) }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.meta)
                                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 9)
                                DatabaseIcon(db: d, size: 16)
                                Text(d.name).font(Typo.ui(12.5)).foregroundStyle(Theme.body).lineLimit(1)
                                Spacer(minLength: 0)
                                DWLook.tag(d.tag)
                                Circle().fill(store.dbStatus[d.id] == .connected ? Theme.green : Theme.disabled).frame(width: 6, height: 6)
                            }
                            .padding(.leading, 10).padding(.trailing, 8)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("New Console") { store.newConsole(d) }
                            Button("Refresh") { store.loadTree(d, force: true) }
                            Divider()
                            Button("Edit Connection…") { store.sheet = .editDatabase(d) }
                        }
                        .accessibilityValue(open ? "Expanded" : "Collapsed")
                        if open { DBTreeRows(connection: d, scope: "lib", indent: 26, initialQuery: d.name.localizedCaseInsensitiveContains(q) ? "" : q) }
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
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.input))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.border.opacity(2) : Theme.divider))
        // Room above and below, so it never touches the row it opened from.
        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 6)
    }
}
