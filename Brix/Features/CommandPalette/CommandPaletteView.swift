import SwiftUI

struct CommandItem: Identifiable {
    let id: String
    var group: String
    var title: String
    var sub: String
    var glyph: String
    var color: Color = Theme.body
    var tint: Color = Color.white(0.06)
    var key: String = ""
    /// Extra text used for matching only.
    var keywords: String = ""
    var action: () -> Void
    var splitAction: (() -> Void)? = nil
    /// Higher shows first when the query is empty.
    var boost: Int = 0
}

/// Builds every palette entry from the store.
@MainActor
enum CommandCatalog {
    static func items(_ store: AppStore, scopeProject: ProjectID?) -> [CommandItem] {
        var out: [CommandItem] = []
        let pid = scopeProject ?? store.currentProjectID
        let p = pid.flatMap(store.project)

        // Files in the current project
        if let p, let ws = store.workspaces[p.id] {
            let changed = Dictionary(store.git[p.id]?.changes.map { ($0.path, $0.status) } ?? [], uniquingKeysWith: { a, _ in a })
            let recent = Set(store.library.recentFiles.filter { $0.project == p.id }.prefix(6).map(\.path))
            for f in ws.allFiles {
                let ext = (f.name as NSString).pathExtension.uppercased()
                let dir = (f.path as NSString).deletingLastPathComponent
                let st = changed[f.path]
                out.append(CommandItem(id: "file:\(f.path)", group: "FILES IN \(p.name.uppercased())", title: f.name,
                                       sub: [dir.isEmpty ? "/" : dir, st.map { $0.name.lowercased() } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                                       glyph: ext.isEmpty ? "•" : String(ext.prefix(3)), color: FileKinds.iconColor(for: f.name), tint: FileKinds.iconColor(for: f.name).opacity(0.12),
                                       key: "", keywords: f.path,
                                       action: { store.openProject(p.id); ws.open(f.path) },
                                       splitAction: { store.openProject(p.id); ws.open(f.path, split: true) },
                                       boost: recent.contains(f.path) ? 3 : (st != nil ? 2 : 0)))
            }
        }

        // Actions
        func action(_ id: String, _ title: String, _ sub: String, _ glyph: String, key: String = "", color: Color = Theme.body, tint: Color = Color.white(0.06), boost: Int = 0, _ run: @escaping () -> Void) {
            out.append(CommandItem(id: "action:\(id)", group: "ACTIONS", title: title, sub: sub, glyph: glyph, color: color, tint: tint, key: key, action: run, boost: boost))
        }
        if let p {
            for a in store.enabledAgents {
                action("agent-\(a.id)", "New \(a.name) session in \(p.name)", store.isInstalled(a) ? "Agent session with linked resources as context" : "Not installed: choose to install",
                       "✦", color: Theme.agentText, tint: Theme.violet.opacity(0.16), boost: 2) {
                    if store.isInstalled(a) || p.isSample { store.launchAgent(a, project: p.id, then: nil) } else { store.installAgent(a) }
                }
            }
            action("terminal", "New terminal in \(p.name)", p.path, "❯", key: "⌘T", boost: 1) { store.openProject(p.id); store.newTerminal(project: p.id) }
            for d in store.linkedDatabases(p.id) {
                action("panel-db-\(d.id)", "Add panel: Database · \(d.name)", "Dock a query panel for \(d.name)", d.kind.badge, color: Theme.pgBlue, tint: Color(hex: 0x7DA7FF).opacity(0.14)) {
                    store.openProject(p.id); store.workspace(for: p.id).layout.add(.database, to: .bottom, resource: d.id)
                }
            }
            for k in [PanelKind.explorer, .sourceControl, .terminal, .inspector, .connections, .notes, .docker, .logs] {
                let has = store.workspaces[p.id]?.layout.contains(k) ?? false
                action("toggle-\(k.rawValue)", "\(has ? "Hide" : "Show") \(k.title)", "Panel", "▤", key: k.toggleShortcut ?? "") {
                    store.openProject(p.id); store.workspace(for: p.id).layout.toggle(k)
                }
            }
            for preset in BuiltinPreset.shown {
                let subs: [BuiltinPreset: String] = [.code: "Explorer left, changes right, terminal below", .agent: "Agents centre, files right", .review: "Diff centre, changes left, inspector right", .focus: "Everything hidden"]
                action("preset-\(preset.rawValue)", "Layout: \(preset.label)", subs[preset] ?? "", "▦", key: preset.shortcut) {
                    store.openProject(p.id); store.workspace(for: p.id).apply(preset)
                }
            }
            for c in store.library.customPresets {
                action("custom-\(c.id)", "Layout: \(c.name)", "Your preset", "▦") { store.openProject(p.id); store.workspace(for: p.id).apply(custom: c) }
            }
            action("save-preset", "Save layout as preset…", "Stores the current arrangement", "▦") { store.sheet = .savePreset(p.id) }
            action("project-settings", "Project settings: \(p.name)", "General, resources, layout, environment, agents", "⚙") { store.route = .projectSettings(p.id) }
        }
        action("add-project", "Open project folder…", "Add a project to Brix", "+", key: "⌘O") { store.sheet = .addProject }
        action("add-host", "Add SSH host…", "Uses ~/.ssh config and agent", "+") { store.sheet = .editHost(nil) }
        action("add-db", "Add database…", "PostgreSQL, MySQL or SQLite", "+") { store.sheet = .editDatabase(nil) }
        action("sidebar-side", "Move sidebar to the \(store.settings.sidebarPosition == .left ? "right" : "left")", "Appearance", "◧") {
            store.settings.sidebarPosition = store.settings.sidebarPosition == .left ? .right : .left
        }
        action("sidebar-style", "Sidebar style: \(store.settings.sidebarStyle == .full ? "rail" : "full")", "Appearance", "◧") {
            store.settings.sidebarStyle = store.settings.sidebarStyle == .full ? .rail : .full
        }
        action("import", "Import connections", "SSH hosts and databases from JetBrains, VS Code and ~/.ssh/config", "⇣") { store.sheet = .importConnections }
        action("settings", "Open settings", "Layout and appearance", "⚙", key: "⌘,") { store.go(.customize) }
        for (i, r) in Route.numbered.enumerated() {
            action("go-\(i)", "Go to \(r.title)", "Section", "→", key: "⌘\(i + 1)") { store.go(r) }
        }
        for r in [Route.recentFiles, .servers, .dbConnections] {
            action("go-\(r.title)", "Go to \(r.title)", "Section", "→") { store.go(r) }
        }
        if !store.library.projects.contains(where: \.isSample) {
            action("sample", "Load sample workspace", "Fill Brix with demo projects, hosts and databases", "◎") { store.loadSampleWorkspace() }
        }

        // Projects
        for proj in store.sortedProjects where scopeProject == nil {
            out.append(CommandItem(id: "project:\(proj.id)", group: "PROJECTS", title: proj.name, sub: "\(proj.framework) · \(proj.path)",
                                   glyph: proj.initials, color: proj.hue.color, tint: proj.hue.color.opacity(0.16), action: { store.openProject(proj.id) }, boost: proj.isPinned ? 1 : 0))
        }

        // Data: tables in linked (or all) databases
        let dbs = pid.map { store.linkedDatabases($0) } ?? store.library.databases
        for d in dbs {
            let schemas = store.schemaCache[d.id]?.schemas ?? (d.isSample && d.id != "atlas_prod_replica" ? MockDatabaseService.tables(for: d) : [:])
            for o in schemas.values.flatMap({ $0 }) where o.kind != .function {
                out.append(CommandItem(id: "table:\(d.id).\(o.id)", group: "DATA", title: o.name,
                                       sub: "\(d.name) · \(o.schema)\(o.rowEstimate.map { " · \($0.formatted()) rows" } ?? "")",
                                       glyph: o.kind == .view ? "VW" : "TB", action: {
                                           store.selectedDatabase = d.id
                                           store.inspector = .table(d.id, o)
                                           store.route = .databases
                                       }, splitAction: {
                                           store.pendingQuery = (d.id, "select * from \(o.schema == "main" ? "" : o.schema + ".")\(o.name) limit 100;")
                                           store.selectedDatabase = d.id
                                           store.route = .databases
                                       }))
            }
        }

        // Servers
        let hosts = pid.map { store.linkedHosts($0) } ?? store.library.hosts
        for h in hosts {
            out.append(CommandItem(id: "host:\(h.id)", group: "SERVERS", title: "Open shell on \(h.name)", sub: h.address + (pid != nil ? " · linked to \(p?.name ?? "")" : ""),
                                   glyph: "SSH", color: Color(hex: 0x93C5FD), tint: Theme.blue.opacity(0.12), keywords: h.tag.name,
                                   action: { store.connect(h.id, project: pid) }))
            out.append(CommandItem(id: "logs:\(h.id)", group: "SERVERS", title: "Tail logs on \(h.name)", sub: h.address,
                                   glyph: "SSH", color: Color(hex: 0x93C5FD), tint: Theme.blue.opacity(0.12), action: { store.tailSystemLog(h.id) }))
        }
        if scopeProject == nil {
            for d in store.library.databases {
                out.append(CommandItem(id: "db:\(d.id)", group: "DATABASES", title: d.name, sub: "\(d.kind.label) · \(d.endpoint)", glyph: d.kind.badge, color: d.kind.color, tint: d.kind.color.opacity(0.14),
                                       action: { store.selectedDatabase = d.id; store.route = .databases }))
            }
        }

        // Docker
        let docker = pid.map { store.linkedDocker($0) } ?? store.allDocker
        for c in docker {
            out.append(CommandItem(id: "docker:\(c.id)", group: "DOCKER", title: c.name, sub: "\(c.image) · \(c.uptimeText.lowercased())", glyph: "DK",
                                   action: { store.dockerAction(c.state == .running ? .restart : .start, c.id) },
                                   splitAction: { store.openDockerLogs(c.id, project: pid) }))
        }

        // Sessions
        for s in store.sessions where scopeProject == nil || s.projectID == scopeProject {
            out.append(CommandItem(id: "session:\(s.id)", group: "SESSIONS", title: s.kind == .agent ? "\(s.title) · \(s.projectID.flatMap(store.project)?.name ?? "")" : s.title,
                                   sub: "\(s.state.label) · \(s.cwd)", glyph: s.kind == .agent ? "✦" : "❯",
                                   color: s.kind == .agent ? Theme.agentText : Theme.body, tint: s.kind == .agent ? Theme.violet.opacity(0.16) : Color.white(0.06),
                                   action: { store.reveal(session: s.id) }, boost: s.state == .needsInput ? 3 : 0))
        }
        return out
    }

    static let groupOrder = ["FILES", "ACTIONS", "SESSIONS", "PROJECTS", "DATA", "SERVERS", "DATABASES", "DOCKER"]

    static func rank(_ items: [CommandItem], query: String) -> [CommandItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        func gi(_ g: String) -> Int { groupOrder.firstIndex { g.hasPrefix($0) } ?? 99 }
        if q.isEmpty {
            var perGroup: [String: Int] = [:]
            return items.sorted { a, b in gi(a.group) != gi(b.group) ? gi(a.group) < gi(b.group) : a.boost > b.boost }
                .filter { i in
                    let n = perGroup[i.group, default: 0]
                    perGroup[i.group] = n + 1
                    return n < (i.group.hasPrefix("FILES") ? 4 : 3)
                }
        }
        let scored = items.compactMap { i -> (CommandItem, Int)? in
            let best = [FuzzyMatcher.score(q, i.title).map { $0 + 4 }, FuzzyMatcher.score(q, i.sub), i.keywords.isEmpty ? nil : FuzzyMatcher.score(q, i.keywords)].compactMap { $0 }.max()
            return best.map { (i, $0 + i.boost) }
        }
        // Groups ordered by their best hit; items by score within a group, at most 6 per group.
        var bestPerGroup: [String: Int] = [:]
        for (i, s) in scored { bestPerGroup[i.group] = max(bestPerGroup[i.group] ?? .min, s) }
        var perGroup: [String: Int] = [:]
        return scored.sorted { a, b in
            let ga = bestPerGroup[a.0.group]!, gb = bestPerGroup[b.0.group]!
            if a.0.group != b.0.group { return ga != gb ? ga > gb : gi(a.0.group) < gi(b.0.group) }
            return a.1 > b.1
        }
        .map(\.0)
        .filter { i in
            let n = perGroup[i.group, default: 0]
            perGroup[i.group] = n + 1
            return n < 6
        }
    }
}

struct CommandPaletteView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var highlighted = 0
    @State private var scoped = false
    @State private var all: [CommandItem] = []
    @FocusState private var focused: Bool

    private var results: [CommandItem] { CommandCatalog.rank(all, query: query) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { close() }
            palette
                .padding(.top, 96)
        }
        .onAppear {
            scoped = store.paletteScopeToProject && store.currentProjectID != nil
            reload()
            focused = true
        }
    }

    private func reload() {
        all = CommandCatalog.items(store, scopeProject: scoped ? store.currentProjectID : nil)
        highlighted = 0
    }

    private var palette: some View {
        let list = results
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text3)
                TextField(scoped ? "Go to file, action or resource in \(store.currentProject?.name ?? "")" : "Search everything", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typo.ui(15))
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onChange(of: query) { _, _ in highlighted = 0 }
                    .onSubmit { run(list, split: false) }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.tab) { toggleScope(); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        run(list, split: true)
                        return .handled
                    }
                    .accessibilityLabel("Search")
                if let p = store.currentProject {
                    Button { toggleScope() } label: {
                        HStack(spacing: 6) {
                            ProjectMark(project: p, size: 16)
                            Text(p.name).font(Typo.ui(11.5, .medium))
                        }
                        .foregroundStyle(scoped ? Theme.text : Theme.text3)
                        .padding(.leading, 4).padding(.trailing, 8).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(scoped ? p.hue.color.opacity(0.14) : Color.white(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(scoped ? p.hue.color.opacity(0.35) : Theme.border))
                    }
                    .buttonStyle(.plain)
                    .tip(scoped ? "Search everything" : "Scope to \(p.name)", "⇥")
                }
                KeyCap(text: "esc")
            }
            .padding(.horizontal, 16).frame(height: 56).hairlineBottom()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if list.isEmpty {
                            EmptyState(symbol: "magnifyingglass", message: "No results for “\(query)”.").frame(height: 180)
                        }
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                            if i == 0 || list[i - 1].group != item.group {
                                Text(item.group).font(Typo.ui(10.5, .semibold)).tracking(0.6).foregroundStyle(Theme.text3)
                                    .padding(.horizontal, 12).padding(.top, i == 0 ? 6 : 12).padding(.bottom, 4)
                            }
                            row(item, on: i == highlighted)
                                .id(item.id)
                                .onTapGesture { highlighted = i; run(list, split: false) }
                                .onHover { if $0 { highlighted = i } }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 460)
                .onChange(of: highlighted) { _, h in if list.indices.contains(h) { proxy.scrollTo(list[h].id) } }
            }
            HStack(spacing: 14) {
                hint("↑↓", "navigate"); hint("↩", "open"); hint("⌘↩", "open in split"); hint("⇥", "scope to project")
                Spacer()
                Text("\(list.count) result\(list.count == 1 ? "" : "s")").font(Typo.ui(11)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 16).frame(height: 36)
            .background(Color.white(0.02)).hairlineTop()
        }
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.sheet)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.sheetRadius))
        .overlay(RoundedRectangle(cornerRadius: Metrics.sheetRadius).strokeBorder(Theme.popoverBorder))
        .shadow(color: .black(0.7), radius: 40, y: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private func row(_ item: CommandItem, on: Bool) -> some View {
        HStack(spacing: 12) {
            Text(item.glyph).font(.system(size: 10, weight: .heavy)).foregroundStyle(item.color).lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 8).fill(item.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Typo.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(item.sub).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            if on { KeyCap(text: "↩") } else if !item.key.isEmpty { KeyCap(text: item.key) }
        }
        .padding(.horizontal, 10).frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 9).fill(on ? Theme.selected : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? Theme.border : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }

    private func hint(_ k: String, _ label: String) -> some View {
        HStack(spacing: 5) { KeyCap(text: k); Text(label).font(Typo.ui(11)).foregroundStyle(Theme.text3) }
    }

    private func toggleScope() {
        guard store.currentProjectID != nil else { return }
        scoped.toggle()
        reload()
    }

    private func run(_ list: [CommandItem], split: Bool) {
        guard list.indices.contains(highlighted) else { return }
        let item = list[highlighted]
        close()
        DispatchQueue.main.async { (split ? (item.splitAction ?? item.action) : item.action)() }
    }

    private func close() {
        store.paletteOpen = false
        store.paletteScopeToProject = false
    }
}
