import SwiftUI

/// Global terminals: sessions grouped by project and by server, in split groups of tabs.
struct TerminalsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    /// Keeps tabs grouped as sessions come and go: "none", "project" or "machine".
    @AppStorage("terminals.groupTabs") private var groupTabs = "none"

    var body: some View {
        HStack(spacing: gap) {
            SessionList(open: open)
                .frame(width: 248)
            if store.terminalTree.isEmpty {
                EmptyState(symbol: "terminal", message: "No terminals open.", actionTitle: "New Terminal") { newTerminal(in: nil) }
                    .island(Theme.terminal)
            } else {
                SessionPaneTree(tree: Bindable(store).terminalTree, host: TiledHost(
                    addPopover: nil, addMenu: newItems,
                    newTerminal: { store.newTerminal(project: nil, attach: false).id },
                    close: { store.closeSessions($0) },
                    content: { AnyView(pane($0)) },
                    arrangeMenu: arrangeMenu))
            }
        }
        .onAppear { sync() }
        .onChange(of: store.sessions.map(\.id)) { old, new in sync(new: Set(new).subtracting(old)) }
        .onChange(of: store.focusedSessionID) { _, id in if let id { open(id) } }
        // Reordering projects or adding a server moves the groups too.
        .onChange(of: store.sortedProjects.map(\.id) + store.library.hosts.map(\.id)) { _, _ in
            if let rank { store.terminalTree.sortTabs(by: rank) }
        }
    }

    /// Keeps the tree in step with sessions: drops closed ones, adds new ones.
    /// With tab grouping on, `new` sessions join their project's (or machine's)
    /// tabs. Only panes that gained a tab are re-sorted, so a drag elsewhere stays put.
    private func sync(new: Set<String> = []) {
        let ids = Set(store.sessions.map(\.id))
        if !Set(store.terminalTree.allTabs).isSubset(of: ids) { store.terminalTree.retain(ids) }
        let placed = Set(store.terminalTree.allTabs)
        for s in store.sessions where !placed.contains(s.id) { store.terminalTree.add(s.id) }
        if let rank {
            for id in new { store.terminalTree.placeWithKin(id, rank: rank) }
            let touched = Set(new.compactMap { store.terminalTree.group(of: $0)?.id })
            if !touched.isEmpty { store.terminalTree.sortTabs(by: rank, only: touched) }
        }
        if let f = store.focusedSessionID { store.terminalTree.activate(f) }
    }

    /// Where a tab sorts when grouped, in the Sessions list's order: projects,
    /// then This Mac, then each server. Nil when grouping is off.
    private var rank: ((String) -> Int)? { rank(groupTabs) }

    private func rank(_ mode: String) -> ((String) -> Int)? {
        let projects = store.sortedProjects.map(\.id), hosts = store.library.hosts.map(\.id)
        func host(_ s: TerminalSession) -> Int { 1 + (s.hostID.flatMap { hosts.firstIndex(of: $0) } ?? hosts.count) }
        switch mode {
        case "project":
            return { id in
                guard let s = store.session(id) else { return Int.max }
                if s.hostID != nil { return projects.count + host(s) }
                return s.projectID.flatMap { projects.firstIndex(of: $0) } ?? projects.count
            }
        case "machine":
            return { id in store.session(id).map { $0.hostID == nil ? 0 : host($0) } ?? Int.max }
        default: return nil
        }
    }

    private func arrangeMenu() -> [MenuSpec] {
        let modes = [("none", "Off"), ("project", "By Project"), ("machine", "By Machine")]
        return [
            MenuSpec(title: "Group Tabs", children: modes.map { m in
                MenuSpec(title: m.1, checked: groupTabs == m.0) {
                    groupTabs = m.0
                    if let rank { withAnimation(.easeOut(duration: 0.18)) { store.terminalTree.sortTabs(by: rank) } }
                }
            }),
            MenuSpec(title: "Layout", children: [
                MenuSpec(title: "One Pane") { layout([ordered], perRow: 1) },
                MenuSpec(title: "Two Side by Side") { layout(PaneTree.chunked(ordered, into: 2), perRow: 2) },
                MenuSpec(title: "Two Stacked") { layout(PaneTree.chunked(ordered, into: 2), perRow: 1) },
                MenuSpec(title: "2 × 2 Grid") { layout(PaneTree.chunked(ordered, into: 4), perRow: 2) },
                MenuSpec(title: groupTabs == "machine" ? "A Pane per Machine" : "A Pane per Project") {
                    guard let r = rank ?? rank("project") else { return }
                    let buckets = Dictionary(grouping: ordered, by: r).sorted { $0.key < $1.key }.map(\.value)
                    layout(buckets, perRow: Int(Double(buckets.count).squareRoot().rounded(.up)))
                }
            ])
        ]
    }

    /// Every open tab, grouped when grouping is on.
    private var ordered: [String] {
        let all = store.terminalTree.allTabs
        guard let rank else { return all }
        return all.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// Replaces the panes. Each tab that was showing still shows where it can, and
    /// the one you were on keeps focus.
    private func layout(_ buckets: [[String]], perRow: Int) {
        let tree = store.terminalTree
        let current = tree.focusedGroup.flatMap { tree.group($0)?.active }
        withAnimation(.easeOut(duration: 0.2)) {
            var t = PaneTree.tiled(buckets, perRow: perRow)
            for id in tree.visibleTabs where id != current { t.activate(id) }
            if let current { t.activate(current) } else { t.focusedGroup = t.groups.first?.id }
            store.terminalTree = t
        }
    }

    private func open(_ id: String) {
        if store.terminalTree.group(of: id) == nil, store.session(id) != nil { store.terminalTree.add(id) }
        store.terminalTree.activate(id)
        store.inspector = .session(id)
    }

    /// Not tied to a project: a terminal or agent here runs on This Mac, in your home folder.
    private func newTerminal(in group: String?) {
        let s = store.newTerminal(project: nil, attach: false)
        store.terminalTree.add(s.id, to: group)
    }

    private func newItems(_ group: String) -> [MenuSpec] {
        var items: [MenuSpec] = [MenuSpec(title: "Terminal", symbol: "terminal", key: "⌘T") { newTerminal(in: group) }]
        let agents = store.enabledAgents.filter(store.isInstalled)
        if !agents.isEmpty {
            items += [.separator, .header("Agent on This Mac")]
            items += agents.map { a in MenuSpec(title: a.name, symbol: "sparkle") {
                let s = store.startLocalAgent(a)
                store.terminalTree.add(s.id, to: group)
            } }
        }
        if !store.library.hosts.isEmpty {
            items += [.separator, .header("SSH")]
            items += store.library.hosts.map { h in MenuSpec(title: h.name, symbol: "globe") {
                store.guardProduction(h.tag, name: h.name, verb: "Connect to") {
                    let s = store.newTerminal(project: nil, host: h.id, kind: .server, attach: false)
                    store.terminalTree.add(s.id, to: group)
                    store.hostStatus[h.id] = .connected
                }
            } }
        }
        return items
    }

    @ViewBuilder private func pane(_ id: String) -> some View {
        if let s = store.session(id), s.kind == .agent, let p = s.projectID {
            AgentPane(ws: store.workspace(for: p), sessionID: id, compact: false)
        } else {
            TerminalPane(ws: nil, sessionID: id, showHealth: true)
        }
    }
}

/// Left list: sessions grouped by project, then by server.
private struct SessionList: View {
    @Environment(AppStore.self) private var store
    let open: (String) -> Void

    private struct Group: Identifiable {
        var id: String
        var name: String
        var mark: AnyView
        var tag: EnvTag?
        var sessions: [TerminalSession]
    }

    private var groups: [Group] {
        var out: [Group] = []
        for p in store.sortedProjects {
            let ss = store.sessions.filter { $0.projectID == p.id && $0.hostID == nil }
            if !ss.isEmpty { out.append(Group(id: p.id, name: p.name, mark: AnyView(ProjectMark(project: p, size: 18)), tag: nil, sessions: ss)) }
        }
        let local = store.sessions.filter { $0.projectID == nil && $0.hostID == nil }
        if !local.isEmpty { out.append(Group(id: "local", name: "This Mac", mark: AnyView(Image(systemName: "laptopcomputer").font(.system(size: 10)).foregroundStyle(Theme.text2).frame(width: 18, height: 18)), tag: .local, sessions: local)) }
        for h in store.library.hosts {
            let ss = store.sessions.filter { $0.hostID == h.id }
            if !ss.isEmpty {
                out.append(Group(id: h.id, name: h.name, mark: AnyView(Circle().fill(h.tag.color.opacity(0.18)).overlay(Image(systemName: "globe").font(.system(size: 9)).foregroundStyle(h.tag.color)).frame(width: 18, height: 18)), tag: h.tag, sessions: ss))
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Sessions").font(Typo.panelTitle).tracking(0.4).foregroundStyle(Theme.text2)
                CountPill(text: "\(store.sessions.count)")
                Spacer()
                MenuButton(items: newMenu) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .accessibilityLabel("New session")
            }
            .padding(.leading, 12).padding(.trailing, 8)
            .frame(height: Metrics.panelHeader).hairlineBottom()
            if groups.isEmpty {
                EmptyState(symbol: "terminal", message: "No sessions yet.", actionTitle: "New Terminal") {
                    let s = store.newTerminal(project: nil, attach: false)
                    open(s.id)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { g in
                            HStack(spacing: 8) {
                                g.mark
                                Text(g.name).font(Typo.ui(12, .semibold)).foregroundStyle(Theme.body).lineLimit(1)
                                Spacer(minLength: 0)
                                if let t = g.tag { TagPill(tag: t, size: 9, filled: false) }
                            }
                            .padding(.horizontal, 8).frame(height: 30).padding(.top, 4)
                            ForEach(g.sessions) { s in row(s) }
                        }
                    }
                    .padding(6)
                }
            }
        }
        .island()
    }

    /// Two lines under the group, joined to it by a guide line: the session's
    /// name, then where it runs and what it's doing.
    private func row(_ s: TerminalSession) -> some View {
        let on = store.inspector == .session(s.id)
        let place = s.cwd.split(separator: "/").last.map(String.init) ?? s.cwd
        return Button { open(s.id) } label: {
            HStack(spacing: 8) {
                Rectangle().fill(Theme.border).frame(width: 1).padding(.vertical, -2)
                SessionIcon(session: s, size: 13).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.displayTitle(s)).font(Typo.ui(12.5, .medium)).foregroundStyle(on ? Theme.text : Theme.body)
                        .lineLimit(1).truncationMode(.middle)
                    Text([place, meta(s)].filter { !$0.isEmpty }.joined(separator: " · ")).font(Typo.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                .help(store.displayTitle(s))
                Spacer(minLength: 4)
                state(s)
            }
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(height: 40)
            .rowBackground(selected: on, radius: 6)
        }
        .buttonStyle(.hand)
        .contextMenu {
            Button("Rename…") { store.sheet = .renameSession(s.id) }
            Button(s.unseen ? "Mark as Read" : "Mark as Unread") { store.setUnread(s.id, !s.unseen) }
            Button("Clear") { store.clearSession(s.id) }
            Button("Interrupt") { store.interruptSession(s.id) }
            if s.projectID != nil { Button("Open in Workspace") { store.reveal(session: s.id) } }
            Divider()
            Button("Close", role: .destructive) { store.closeSession(s.id) }
        }
        .accessibilityLabel("\(s.title), \(s.state.label)")
    }

    @ViewBuilder private func state(_ s: TerminalSession) -> some View {
        if s.state == .needsInput {
            Text("Input").font(Typo.ui(10, .semibold)).foregroundStyle(Color(hex: 0x09090B))
                .padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(Theme.amber))
        } else if s.unseen {
            Text(s.markedUnread || s.state == .running ? "Unread" : "Done").font(Typo.ui(10, .semibold)).foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(Theme.green))
        } else if s.state == .running {
            WorkingSpinner(size: 10)
        } else {
            Circle().fill(s.state.color).frame(width: 6, height: 6)
        }
    }

    private func meta(_ s: TerminalSession) -> String {
        switch s.state {
        case .needsInput: "waiting for you"
        case .idle: s.unseen ? "done, not opened" : "idle"
        case .running: s.kind == .agent ? AgentPane.duration(since: store.runningSince[s.id] ?? s.startedAt).replacingOccurrences(of: " min", with: "m") : (s.kind == .logs ? "tail" : (["", "zsh", "bash", "login"].contains(s.process) ? "" : s.process))
        default: s.state.label.lowercased()
        }
    }

    private func newMenu() -> [MenuSpec] {
        var items: [MenuSpec] = [.header("Local shell")]
        items += store.sortedProjects.prefix(8).map { p in MenuSpec(title: p.name, symbol: "terminal") { open(store.newTerminal(project: p.id, attach: false).id) } }
        items.append(MenuSpec(title: "Home folder", symbol: "house") { open(store.newTerminal(project: nil, attach: false).id) })
        let agents = store.enabledAgents.filter(store.isInstalled)
        if !agents.isEmpty {
            items += [.separator, .header("Agent on This Mac")]
            items += agents.map { a in MenuSpec(title: a.name, symbol: "sparkle") { open(store.startLocalAgent(a).id) } }
        }
        if !store.library.hosts.isEmpty {
            items += [.separator, .header("Server shell")]
            items += store.library.hosts.map { h in MenuSpec(title: h.name, symbol: "globe") {
                store.guardProduction(h.tag, name: h.name, verb: "Connect to") {
                    let s = store.newTerminal(project: nil, host: h.id, kind: .server, attach: false)
                    store.hostStatus[h.id] = .connected
                    open(s.id)
                }
            } }
        }
        return items
    }
}
