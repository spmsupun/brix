import SwiftUI

/// Draws the custom Add panel menu above everything when requested.
struct PopoverHost: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let req = store.popover, let pid = req.projectID, let target = Self.target(req.kind) {
            ZStack {
                Color.black.opacity(0.001)
                    .onTapGesture { store.popover = nil }
                AddPanelMenu(ws: store.workspace(for: pid), side: target.side, pane: target.pane) { store.popover = nil }
                    .shadow(color: .black(0.7), radius: 30, y: 24)
            }
            .onExitCommand { store.popover = nil }
        }
    }
}

extension PopoverHost {
    static func target(_ k: PopoverRequest.Kind) -> (side: DockSide, pane: String?)? {
        switch k {
        case .addPanel(let side): (side, nil)
        case .addTab(let g): (.right, g)
        case .dock: nil
        }
    }
}

/// Searchable "+ Add panel" menu grouped into Shells, Project and Linked resources.
/// With `pane` set it adds the pick as a tab in that pane of the tiled centre.
struct AddPanelMenu: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    @State var side: DockSide
    var pane: String? = nil
    var dismiss: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        var group: String
        var title: String
        var sub: String
        var badge: String
        var color: Color
        var tint: Color
        var key: String = ""
        var children: [Item] = []
        var action: () -> Void = {}
    }

    private var items: [Item] {
        let p = ws.project
        let hosts = store.linkedHosts(ws.projectID)
        let dbs = store.linkedDatabases(ws.projectID)
        let docker = store.linkedDocker(ws.projectID)
        func has(_ k: PanelKind) -> Bool { ws.layout.contains(k) }
        func whereIs(_ k: PanelKind) -> String {
            guard let panel = ws.layout.allPanels.first(where: { $0.kind == k }) else { return "" }
            if let s = ws.layout.side(of: panel.id) { return "Already in \(s.label.lowercased()) dock" }
            return "Floating"
        }
        var out: [Item] = [
            Item(id: "terminal", group: "Shells", title: "Terminal", sub: "zsh in \(p?.path ?? "~")", badge: "❯", color: Theme.text, tint: Color.white(0.07), key: "⌘T") {
                let s = store.newTerminal(project: ws.projectID, attach: false)
                if let pane { ws.placeTab(s.id, in: pane); return }
                let panel = ws.layout.add(.terminal, to: side)
                ws.state.panelSession[panel.id] = s.id
            },
            Item(id: "agent", group: "Shells", title: "Agent session", sub: store.enabledAgents.map(\.name).joined(separator: " · ").ifEmpty("Turn on an agent in Customize"),
                 badge: "✦", color: Theme.agentText, tint: Theme.violet.opacity(0.16), key: "▸",
                 children: store.enabledAgents.map { a in
                     Item(id: "agent-\(a.id)", group: "Shells", title: a.name, sub: store.isInstalled(a) ? a.command : "Not installed: choose to install", badge: "✦",
                          color: Theme.agentText, tint: Theme.violet.opacity(0.16)) {
                         guard store.isInstalled(a) || p?.isSample == true else { store.installAgent(a); return }
                         store.launchAgent(a, project: ws.projectID) { s in
                             if let pane { ws.placeTab(s.id, in: pane); return }
                             let panel = ws.layout.add(.agent, to: side)
                             ws.state.panelSession[panel.id] = s.id
                         }
                     }
                 }) {},
            Item(id: "server", group: "Shells", title: "Server shell", sub: hosts.isEmpty ? "Link a server first" : hosts.map { $0.name.components(separatedBy: " ").first ?? $0.name }.joined(separator: " · "),
                 badge: "SSH", color: Color(hex: 0x93C5FD), tint: Theme.blue.opacity(0.14), key: hosts.isEmpty ? "" : "▸",
                 children: hosts.map { h in Item(id: "server-\(h.id)", group: "Shells", title: h.name, sub: h.address, badge: "SSH", color: h.tag.color, tint: h.tag.color.opacity(0.12)) {
                     if let pane {
                         store.guardProduction(h.tag, name: h.name, verb: "Connect to") {
                             let s = store.newTerminal(project: ws.projectID, host: h.id, kind: .server, attach: false)
                             store.hostStatus[h.id] = .connected
                             ws.placeTab(s.id, in: pane)
                         }
                         return
                     }
                     ws.layout.add(.serverShell, to: side, resource: h.id)
                 } }) {
                if hosts.isEmpty { store.route = .projectSettings(ws.projectID) }
            }
        ]
        let project: [(PanelKind, String, String)] = [
            (.explorer, "EX", "Files and folders"), (.sourceControl, "SC", "Changes, commit, history"), (.inspector, "IN", "Details for the selection"),
            (.connections, "CN", "Linked hosts and databases"), (.record, "RC", "The selected row of a table or query"),
            (.notes, "NT", "Scratchpad saved with the project"), (.logs, "LG", "Tail a file here or on a linked host")
        ] + (pane == nil ? [] : [(.plan, "PL", "The current agent's plan"), (.agentFiles, "AF", "Files the current agent changed")])
        if let pane {
            out.insert(Item(id: "editor", group: "Project", title: "Editor", sub: ws.state.activeFile ?? "Open a file", badge: "ED", color: Theme.text2, tint: Color.white(0.06)) {
                if let f = ws.state.activeFile ?? ws.state.openFiles.first { ws.placeTab(GridItemID.file(f), in: pane) } else { store.paletteScopeToProject = true; store.paletteOpen = true }
            }, at: 3)
        }
        for (k, badge, sub) in project {
            out.append(Item(id: k.rawValue, group: "Project", title: k.title, sub: pane == nil && has(k) && !k.allowsMultiple ? whereIs(k) : sub, badge: badge, color: Theme.text2, tint: Color.white(0.06), key: k.toggleShortcut ?? "") {
                if let pane {
                    if let p = ws.layout.allPanels.first(where: { $0.kind == k }), !k.allowsMultiple { ws.layout.hide(p.id) }
                    ws.placeTab(GridItemID.panel(k), in: pane)
                    return
                }
                ws.layout.add(k, to: side)
            })
        }
        out.append(Item(id: "database", group: "Linked resources", title: "Database", sub: dbs.isEmpty ? "Link a database first" : dbs.map(\.name).joined(separator: " · "),
                        badge: dbs.first?.kind.badge ?? "DB", color: Theme.pgBlue, tint: Color(hex: 0x7DA7FF).opacity(0.14), key: dbs.isEmpty ? "" : "▸",
                        children: dbs.map { d in Item(id: "db-\(d.id)", group: "Linked resources", title: d.name, sub: d.endpoint, badge: d.kind.badge, color: d.kind.color, tint: Color.white(0.06)) {
                            if let pane { ws.placeTab(GridItemID.database(d.id), in: pane) } else { ws.layout.add(.database, to: side, resource: d.id) }
                        } }) {
            if dbs.isEmpty { store.route = .projectSettings(ws.projectID) }
        })
        out.append(Item(id: "docker", group: "Linked resources", title: "Docker", sub: docker.isEmpty ? "Link containers first" : "\(docker.count) linked container\(docker.count == 1 ? "" : "s")",
                        badge: "DK", color: Theme.text2, tint: Color.white(0.06)) {
            if docker.isEmpty { store.route = .projectSettings(ws.projectID) } else if let pane { ws.placeTab(GridItemID.panel(.docker), in: pane) } else { ws.layout.add(.docker, to: side) }
        })
        out.append(Item(id: "browser", group: "Linked resources", title: "Browser preview", sub: "localhost:3000", badge: "WEB", color: Theme.text2, tint: Color.white(0.06)) {
            if let pane { ws.placeTab(GridItemID.panel(.browser), in: pane) } else { ws.layout.add(.browser, to: side) }
        })
        return out
    }

    private var filtered: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        var out: [Item] = []
        for i in items {
            if FuzzyMatcher.score(q, i.title + " " + i.sub) != nil { out.append(i) }
            out += i.children.filter { FuzzyMatcher.score(q, $0.title + " " + $0.sub) != nil }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
                TextField(pane == nil ? "Add a panel to this dock…" : "Add a tab to this pane…", text: $query)
                    .textFieldStyle(.plain).font(Typo.ui(12.5)).foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { run(highlighted) }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(filtered.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .accessibilityLabel("Search panels")
                if pane == nil {
                    SegmentedControl(options: DockSide.allCases.map { ($0, $0.label) }, selection: $side, height: 20, fontSize: 10.5)
                }
            }
            .padding(.horizontal, 9).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let list = filtered
                    if list.isEmpty {
                        Text("No panels match “\(query)”.").font(Typo.ui(12)).foregroundStyle(Theme.text3).padding(10)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                        if i == 0 || list[i - 1].group != item.group {
                            Text(item.group).font(Typo.ui(10.5, .semibold)).foregroundStyle(Theme.text3).padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 3)
                        }
                        row(item, index: i)
                    }
                }
            }
            .frame(maxHeight: 420)
        }
        .padding(6)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .popoverSurface(Theme.popover)
        .onAppear { focused = true }
        .onExitCommand(perform: dismiss)
    }

    @ViewBuilder private func row(_ item: Item, index: Int) -> some View {
        let content = HStack(spacing: 10) {
            Text(item.badge).font(.system(size: 9, weight: .heavy)).foregroundStyle(item.color)
                .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 7).fill(item.tint))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Typo.row).foregroundStyle(Theme.text)
                Text(item.sub).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(item.key).font(Typo.ui(11)).foregroundStyle(Theme.meta)
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 8).fill(index == highlighted ? Theme.selected : .clear))
        .contentShape(Rectangle())
        .onHover { if $0 { highlighted = index } }
        if item.children.isEmpty {
            Button { run(index) } label: { content }.buttonStyle(.hand)
        } else {
            MenuButton(items: { item.children.map { c in MenuSpec(title: c.title) { c.action(); dismiss() } } }) { content }
        }
    }

    private func run(_ i: Int) {
        let list = filtered
        guard list.indices.contains(i) else { return }
        let item = list[i]
        if let first = item.children.first, item.children.count == 1 {
            first.action()
        } else if !item.children.isEmpty, query.isEmpty {
            item.children.first?.action()
        } else {
            item.action()
        }
        dismiss()
    }
}
