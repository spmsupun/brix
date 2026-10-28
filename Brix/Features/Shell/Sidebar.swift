import SwiftUI

/// App sidebar from the Sidebar artboard: full (232pt) and rail (56pt).
struct SidebarView: View {
    @Environment(AppStore.self) private var store
    let rail: Bool

    var body: some View {
        Group {
            if rail { RailSidebar() } else { FullSidebar() }
        }
        .frame(maxHeight: .infinity)
        .island()
        .shadow(color: .black(0.4), radius: 1, y: 1)
    }
}

private struct NavItem: Identifiable {
    var id: String { "\(route)" }
    let route: Route
    var label: String
    var badge: String? = nil
    var badgeColor: Color = Theme.text3
}

private extension AppStore {
    var runningTerminals: Int { sessions.filter { $0.state == .running }.count }
    var connectedHosts: Int { hostStatus.values.filter { $0 == .connected }.count }
}

/// Full sidebar from the Project tree artboard: a short nav, the project tree
/// (sessions on a spine, then linked servers, Docker and databases), the
/// library and the footer.
private struct FullSidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    @State private var rowDrag = RowDragState()
    @State private var filtering = false
    @State private var filter = ""
    @State private var hoveredProject: ProjectID?
    @State private var hoveredSession: String?
    @State private var menuFor: ProjectID?
    @State private var hoveredRepo: ProjectID?
    @State private var projectScroll = ScrollMetrics()
    @AppStorage("sidebar.dbTree") private var dbTreeOpen = false
    /// The repo the quick Agent / Terminal buttons start in, per project.
    @State private var lastRepo: [ProjectID: ProjectID] = [:]
    @AppStorage("sidebar.repoSort") private var repoSort = RepoSort.activity
    /// Keyboard cursor in the project tree (↑↓←→↩).
    @State private var cursor: String?
    @FocusState private var treeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                navRow(NavItem(route: .overview, label: "Overview"))
                navRow(NavItem(route: .terminals, label: "All Terminals", badge: store.runningTerminals > 0 ? "\(store.runningTerminals)" : nil, badgeColor: Theme.green))
                navRow(NavItem(route: .git, label: "Git", badge: store.totalUncommitted > 0 ? "\(store.totalUncommitted)" : nil, badgeColor: Theme.amber))
                navRow(NavItem(route: .recentFiles, label: "Recent Files"))
            }
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 6)
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
            projectsHeader
            // A thin bar shows when the list is longer than the sidebar.
            ScrollView(.vertical, showsIndicators: false) {
                // Lazy: rows off screen (a big project's tables) aren't built until scrolled to.
                LazyVStack(alignment: .leading, spacing: 2) {
                    if store.library.projects.isEmpty {
                        Text("No projects yet").font(Typo.ui(12)).foregroundStyle(Theme.meta).padding(.horizontal, 8).rowHeight(26)
                    }
                    let projects = visibleProjects
                    let order = projects.map(\.id)
                    ForEach(projects) { p in
                        VStack(alignment: .leading, spacing: 0) { projectNode(p) }
                            .reorderableRow(p.id, list: "projects", order: order, state: rowDrag) { from, to in
                                guard let a = store.sortedProjects.firstIndex(where: { $0.id == order[from] }),
                                      let b = store.sortedProjects.firstIndex(where: { $0.id == order[to] }) else { return }
                                store.moveProject(from: a, to: b)
                            }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 8)
                .coordinateSpace(name: "sidebar")
                .reportsScrollPosition(projectScroll)
            }
            .thinScrollBar(projectScroll)
            .focusable()
            .focusEffectDisabled()
            .focused($treeFocused)
            .onKeyPress(.downArrow) { moveCursor(1); return .handled }
            .onKeyPress(.upArrow) { moveCursor(-1); return .handled }
            .onKeyPress(.rightArrow) { expandCursor(true); return .handled }
            .onKeyPress(.leftArrow) { expandCursor(false); return .handled }
            .onKeyPress(.return) { activateCursor(); return .handled }
            library
            footer
        }
    }

    /// Top-level projects; repositories inside one show nested under it.
    /// Filtering matches nested ones too and shows their parent.
    private var visibleProjects: [Project] {
        let top = store.sortedProjects.filter { $0.parentID == nil }
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard filtering, !q.isEmpty else { return top }
        return top.filter { p in p.name.localizedCaseInsensitiveContains(q) || store.children(of: p.id).contains { $0.name.localizedCaseInsensitiveContains(q) } }
    }

    private var projectsHeader: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text("PROJECTS").font(Typo.ui(10.5, .semibold)).tracking(0.6).foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
                IconButton(symbol: "magnifyingglass", label: "Filter projects", size: 22, iconSize: 11, active: filtering) {
                    filtering.toggle()
                    if !filtering { filter = "" }
                }
                IconButton(symbol: "plus", label: "Add project", size: 22, iconSize: 11) { store.sheet = .addProject }
            }
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(height: 26)
            if filtering {
                SidebarSearch(placeholder: "Filter projects", text: $filter) { filtering = false }
                    .padding(.horizontal, 2)
            }
        }
    }

    private func isActive(_ r: Route) -> Bool { store.route == r }

    private func navRow(_ item: NavItem) -> some View {
        let on = isActive(item.route)
        return Button { store.go(item.route) } label: {
            HStack(spacing: 8) {
                Image(systemName: item.route.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(on ? accent : Theme.text2)
                    .frame(width: 16)
                Text(item.label)
                    .font(Typo.ui(13, on ? .medium : .regular))
                    .foregroundStyle(on ? Theme.text : Theme.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let b = item.badge {
                    Text(b).font(Typo.ui(11, .semibold)).monospacedDigit().foregroundStyle(item.badgeColor)
                }
            }
            .padding(.horizontal, 8)
            .rowHeight(28)
            .rowBackground(selected: on)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Project node

    private func isExpanded(_ id: ProjectID) -> Bool { store.settings.expandedProjects.contains(id) }

    private func toggleExpanded(_ id: ProjectID) {
        withAnimation(.easeOut(duration: 0.15)) {
            if isExpanded(id) { store.settings.expandedProjects.remove(id) } else { store.settings.expandedProjects.insert(id) }
        }
    }

    @ViewBuilder private func projectNode(_ p: Project) -> some View {
        let open = isExpanded(p.id)
        let repos = store.children(of: p.id)
        projectHead(p, open: open, repos: repos)
        if open, !repos.isEmpty {
            multiRepoBody(p, repos: repos)
        } else if open {
            VStack(alignment: .leading, spacing: 0) {
                let sessions = store.sessions.filter { $0.projectID == p.id }
                ForEach(sessions) { s in sessionRow(s, hue: p.hue.color) }
                HStack(spacing: 4) {
                    dashedButton("Agent", icon: AnyView(AgentMark(agent: store.agent(p.agentID) ?? store.agent(store.settings.defaultAgent) ?? store.enabledAgents.first, size: 10))) {
                        store.startAgent(project: p.id)
                    }
                    dashedButton("Terminal", icon: AnyView(Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)))) {
                        store.openProject(p.id)
                        store.newTerminal(project: p.id)
                    }
                }
                .padding(.leading, Tree.child).padding(.top, 3).padding(.bottom, 6)
                linkedGroups(p)
            }
            .padding(.top, 2).padding(.bottom, 6)
            .coordinateSpace(name: "spine")
            // The spine: the project's colour, from the top down to the last branch.
            .backgroundPreferenceValue(SpineEnd.self) { end in
                Rectangle().fill(p.hue.color.opacity(0.35)).frame(width: 1, height: max(0, end))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(x: Tree.spine)
            }
        }
    }

    private func projectHead(_ p: Project, open: Bool, repos: [Project]) -> some View {
        // The project row is selected only when none of its rows below is.
        let on = store.route.projectID == p.id && !(open && childSelected(p))
        let changes = ([p] + repos).reduce(0) { $0 + lineChanges($1.id) }
        let sub = subLine(p, repos: repos)
        let agents = store.sessions.filter { s in s.kind == .agent && (s.projectID == p.id || repos.contains { $0.id == s.projectID }) }
        let showAdd = open || hoveredProject == p.id || menuFor == p.id
        return HStack(spacing: 8) {
            Button { toggleExpanded(p.id) } label: {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.meta)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Collapse \(p.name)" : "Expand \(p.name)")
            ProjectMark(project: p, size: Tree.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if let sub { sub.lineLimit(1).truncationMode(.tail) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if !open, !agents.isEmpty {
                    Text("✳\(agents.count)").font(Typo.ui(10.5, .semibold))
                        .foregroundStyle(agents.contains { $0.state == .needsInput } ? Theme.amber : Self.agentOrange)
                        .accessibilityLabel("\(agents.count) agent sessions")
                }
                let ci = store.runningPipelines(p.id)
                if ci > 0 { PipelineBadge(count: ci) }
                if changes > 0 {
                    Text("±\(Compact.number(changes))").font(Typo.mono(10.5, .semibold)).foregroundStyle(Theme.amber)
                        .accessibilityLabel("\(changes) lines changed")
                }
                if showAdd {
                    IconButton(symbol: "plus", label: "New in \(p.name)", size: 22, iconSize: 10.5, active: menuFor == p.id) { menuFor = p.id }
                        .popover(isPresented: Binding(get: { menuFor == p.id }, set: { if !$0 { menuFor = nil } }), arrowEdge: .trailing) {
                            NewInProjectMenu(project: p) { menuFor = nil }
                        }
                }
            }
        }
        .padding(.leading, 6).padding(.trailing, 4)
        .frame(height: sub == nil ? 36 : (open ? 46 : 44))
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? p.hue.color.opacity(0.08) : (hoveredProject == p.id ? Theme.hover : .clear)))
        .overlay(cursorRing("p:" + p.id))
        .contentShape(Rectangle())
        .onHover { hoveredProject = $0 ? p.id : (hoveredProject == p.id ? nil : hoveredProject) }
        // One gesture, read the click count: a single click responds at once
        // (two tap gestures would hold it back to wait for a second click).
        .onTapGesture {
            cursor = "p:" + p.id
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                store.openProject(p.id)
            } else {
                store.route = .projectHome(p.id)
                if !isExpanded(p.id) { toggleExpanded(p.id) }
            }
        }
        .help("Click for the overview, double-click to open the workspace")
        .contextMenu { ProjectContextMenu(project: p) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(p.name)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }

    static let agentOrange = Color(hex: 0xE07B53)

    /// "7 repos · ⎇ dev · 2 off-branch", or "1 repo · ⎇ master · agent editing".
    private func subLine(_ p: Project, repos: [Project]) -> Text? {
        var parts: [Text] = []
        if repos.isEmpty {
            if let b = store.git[p.id]?.branch, !b.isEmpty {
                parts = [Text("1 repo"), Text("⎇ \(b)").font(Typo.mono(10.5))]
            }
            if let a = activityLine(p) { parts.append(Text(a.text).foregroundColor(a.color)) }
        } else {
            let (dominant, off) = branches(repos)
            parts.append(Text("\(repos.count) repos"))
            if let dominant { parts.append(Text("⎇ \(dominant)").font(Typo.mono(10.5))) }
            if off > 0 { parts.append(Text("\(off) off-branch")) }
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text(" · ") + $1 }
            .font(Typo.ui(10.5)).foregroundColor(Theme.text3)
    }

    /// The branch most repos are on, and how many repos are on another one.
    private func branches(_ repos: [Project]) -> (String?, Int) {
        let names = repos.compactMap { store.git[$0.id]?.branch }.filter { !$0.isEmpty }
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        guard let top = names.max(by: { counts[$0]! < counts[$1]! }) else { return (nil, 0) }
        return (top, names.filter { $0 != top }.count)
    }

    /// Added plus deleted lines not yet committed.
    private func lineChanges(_ id: ProjectID) -> Int {
        store.git[id]?.changes.reduce(0) { $0 + $1.add + $1.del } ?? 0
    }

    /// What's happening in a collapsed project: an agent waiting, or one working.
    private func activityLine(_ p: Project) -> (text: String, color: Color)? {
        let sessions = store.sessions.filter { $0.projectID == p.id && $0.kind == .agent }
        if let w = sessions.first(where: { $0.state == .needsInput }) {
            return ("\(store.agent(for: w)?.name ?? "agent") needs input", Theme.amber)
        }
        if let r = sessions.first(where: { $0.state == .running }) {
            return ("agent editing", Theme.text3)
        }
        return nil
    }

    private func dashedButton(_ title: String, icon: AnyView, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon.frame(width: 10, height: 10)
                Text(title).font(Typo.ui(11.5))
            }
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .fixedSize()
            .background(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New \(title.lowercased())")
    }

    /// A branch off the spine; it also tells the spine to reach down to it.
    private func elbow(_ hue: Color, x: CGFloat = Tree.spine, joinsSpine: Bool = true) -> some View {
        Rectangle().fill(hue.opacity(0.35)).frame(width: 8, height: 1).offset(x: x)
            .background {
                if joinsSpine {
                    GeometryReader { g in Color.clear.preference(key: SpineEnd.self, value: g.frame(in: .named("spine")).midY) }
                }
            }
    }

    // MARK: Sessions

    /// A session row is selected only while its workspace is showing it.
    private func sessionSelected(_ s: TerminalSession) -> Bool {
        guard let p = s.projectID, store.route == .workspace(p) else { return false }
        return (activeTab(p) ?? store.focusedSessionID) == s.id
    }

    /// The tab in front in a project's focused pane, while its workspace shows.
    private func activeTab(_ p: ProjectID) -> String? {
        guard store.route == .workspace(p), let ws = store.workspaces[p],
              let g = ws.state.panes.focusedGroup.flatMap({ ws.state.panes.group($0) }) ?? ws.state.panes.groups.first else { return nil }
        return g.active ?? g.tabs.first
    }

    private func hostSelected(_ h: SSHHost, in p: ProjectID) -> Bool {
        store.route == .remoteFiles(h.id) || activeTab(p) == GridItemID.remoteFiles(h.id)
    }

    /// A container's shell session is in front.
    private func containerSelected(_ c: DockerTarget, in p: ProjectID) -> Bool {
        guard let id = activeTab(p), let s = store.session(id) else { return false }
        return s.title == "\(c.name) shell" || s.title == "\(c.name) logs"
    }

    private func childSelected(_ p: Project) -> Bool {
        store.children(of: p.id).contains { store.route.projectID == $0.id || childSelected($0) }
            || store.sessions.contains { $0.projectID == p.id && sessionSelected($0) }
            || store.linkedHosts(p.id).contains { hostSelected($0, in: p.id) }
            || store.linkedDatabases(p.id).contains { activeTab(p.id) == GridItemID.database($0.id) }
    }

    private func sessionRow(_ s: TerminalSession, hue: Color, repo: Project? = nil) -> some View {
        let on = sessionSelected(s)
        let hovering = hoveredSession == s.id
        return Button { store.reveal(session: s.id) } label: {
            HStack(spacing: 8) {
                SessionIcon(session: s, size: 12)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(s.kind == .agent ? Color(hex: 0xE07B53).opacity(0.12) : Color.white(0.05)))
                    .foregroundStyle(s.isRemote ? Theme.blue : Theme.text2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.displayTitle(s)).font(Typo.ui(12.5, on ? .semibold : .medium)).foregroundStyle(on ? Theme.text : Theme.body).lineLimit(1)
                    ((repo.map { Text($0.name).foregroundColor($0.hue.color) + Text(" · ") } ?? Text("")) + Text(sessionSub(s)))
                        .font(Typo.ui(10.5)).foregroundColor(Theme.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
                if hovering {
                    SidebarCloseButton(label: "Close \(s.title)") { store.closeSession(s.id) }
                } else if s.state == .needsInput {
                    Text("Input").font(Typo.ui(10, .semibold)).foregroundStyle(Color(hex: 0x09090B))
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.amber))
                } else {
                    StatusDot(color: s.state.color, size: 6, ring: s.state == .running, pulse: s.state == .running)
                }
            }
            .padding(.leading, Tree.child).padding(.trailing, 8)
            .frame(height: 38)
            .background(alignment: .leading) { elbow(hue) }
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.selected : (hovering ? Theme.hover : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Color.white(0.06) : .clear))
            .overlay(cursorRing("s:" + s.id))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredSession = $0 ? s.id : (hoveredSession == s.id ? nil : hoveredSession) }
        .onMiddleClick { store.closeSession(s.id) }
        .contextMenu {
            Button("Rename…") { store.sheet = .renameSession(s.id) }
            Button("Show in Inspector") { store.inspector = .session(s.id) }
            Divider()
            Button("Close", role: .destructive) { store.closeSession(s.id) }
        }
        .accessibilityLabel("\(store.displayTitle(s)), \(s.state.label)")
    }

    /// Second line of a session row: who it's waiting on, where it runs, or what it last said.
    private func sessionSub(_ s: TerminalSession) -> String {
        if s.state == .needsInput { return "Waiting for your answer" }
        if let h = s.hostID.flatMap(store.host) {
            return "\(h.user)@\(h.host)" + (s.process.isEmpty ? "" : " · \(s.process)")
        }
        let age = Self.age(since: s.startedAt)
        if s.kind == .agent, let line = s.lastOutput.split(separator: "\n").last.map(String.init), !line.isEmpty {
            return "\(line.trimmingCharacters(in: .whitespaces)) · \(age)"
        }
        return (s.cwd as NSString).abbreviatingWithTildeInPath
    }

    static func age(since d: Date) -> String {
        let m = max(0, Int(Date().timeIntervalSince(d) / 60))
        return m < 60 ? "\(m)m" : m < 1440 ? "\(m / 60)h" : "\(m / 1440)d"
    }

    // MARK: Multi-repo projects

    /// A folder of repositories: every session in any repo, quick-create,
    /// then the repos (busiest first) and one line of linked resources.
    private func multiRepoBody(_ p: Project, repos: [Project]) -> some View {
        let hue = p.hue.color
        let ids = Set(repos.map(\.id))
        let sessions = store.sessions.filter { $0.projectID == p.id || $0.projectID.map(ids.contains) == true }
        let target = repos.first { $0.id == lastRepo[p.id] ?? UserDefaults.standard.string(forKey: "sidebar.lastRepo.\(p.id)") }
        let changed = repos.filter { lineChanges($0.id) > 0 || store.changeCount($0.id) > 0 }.count
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(sessions) { s in sessionRow(s, hue: hue, repo: repos.first { $0.id == s.projectID }) }
            HStack(spacing: 4) {
                dashedButton("Agent", icon: AnyView(Text("✳").font(.system(size: 11)).foregroundStyle(Self.agentOrange))) {
                    store.startAgent(project: (target ?? p).id)
                }
                dashedButton("Terminal", icon: AnyView(Text("❯").font(.system(size: 10)))) {
                    let id = (target ?? p).id
                    store.openProject(id)
                    store.newTerminal(project: id)
                }
                MenuButton(items: {
                    [MenuSpec.header("Start new sessions in"), MenuSpec(title: "\(p.name) (top folder)", checked: target == nil) { pickRepo(nil, in: p) }]
                        + repos.map { r in MenuSpec(title: r.name, checked: target?.id == r.id) { pickRepo(r.id, in: p) } }
                }) {
                    Text("in \(target?.name ?? "any repo") ▾").font(Typo.ui(10.5)).foregroundStyle(Theme.meta).lineLimit(1)
                }
                .padding(.leading, 2)
                .accessibilityLabel("Repository for new sessions: \(target?.name ?? p.name)")
            }
            .padding(.leading, Tree.child).padding(.top, 3).padding(.bottom, 8)
            let reposOpen = groupOpen(p.id, "repos")
            HStack(spacing: 6) {
                // The header folds the repo list; the click is remembered.
                Button { toggleGroup(p.id, "repos") } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.meta)
                            .rotationEffect(.degrees(reposOpen ? 90 : 0))
                        Text("Repositories").font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text2).fixedSize()
                        Text("\(changed) changed · \(repos.count - changed) clean").font(Typo.ui(10.5)).foregroundStyle(Theme.meta).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Repositories, \(changed) changed")
                .accessibilityValue(reposOpen ? "Expanded" : "Collapsed")
                MenuButton(items: { RepoSort.allCases.map { o in MenuSpec(title: "By \(o.rawValue)", checked: o == repoSort) { repoSort = o } } }) {
                    Text("by \(repoSort.rawValue) ▾").font(Typo.ui(10.5)).foregroundStyle(Theme.meta).fixedSize()
                }
                .accessibilityLabel("Sort repositories, by \(repoSort.rawValue)")
            }
            .padding(.leading, Tree.child).padding(.trailing, 6)
            .frame(height: 26)
            .background(alignment: .leading) { elbow(hue) }
            if reposOpen { ForEach(sortedRepos(repos)) { repoRow($0, in: p) } }
            resourcesLine(p)
        }
        .padding(.top, 4).padding(.bottom, 6)
        .coordinateSpace(name: "spine")
        .backgroundPreferenceValue(SpineEnd.self) { end in
            Rectangle().fill(hue.opacity(0.28)).frame(width: 1, height: max(0, end))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: Tree.spine)
        }
    }

    private func pickRepo(_ id: ProjectID?, in p: Project) {
        lastRepo[p.id] = id ?? ""
        UserDefaults.standard.set(id ?? "", forKey: "sidebar.lastRepo.\(p.id)")
    }

    enum RepoSort: String, CaseIterable { case activity, name, changes }

    private func agentWorking(_ id: ProjectID) -> Bool {
        store.sessions.contains { $0.projectID == id && $0.kind == .agent && $0.state == .running }
    }

    /// Activity: agents working first, then most changes, then clean.
    private func sortedRepos(_ repos: [Project]) -> [Project] {
        switch repoSort {
        case .name:
            return repos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .changes:
            return repos.sorted { lineChanges($0.id) > lineChanges($1.id) }
        case .activity:
            return repos.sorted { a, b in
                let (wa, wb) = (agentWorking(a.id), agentWorking(b.id))
                if wa != wb { return wa }
                let (ca, cb) = (lineChanges(a.id) + store.changeCount(a.id), lineChanges(b.id) + store.changeCount(b.id))
                if ca != cb { return ca > cb }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    private func repoRow(_ r: Project, in p: Project) -> some View {
        let g = store.git[r.id]
        let (dominant, _) = branches(store.children(of: p.id))
        let off = g.map { !$0.branch.isEmpty && $0.branch != dominant } ?? false
        let lines = lineChanges(r.id), files = store.changeCount(r.id)
        let working = agentWorking(r.id)
        let hovering = hoveredRepo == r.id
        let on = store.route.projectID == r.id
        return HStack(spacing: 7) {
            BranchGlyph().stroke(r.hue.color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 13)
            Text(r.name).font(Typo.ui(12.5, .medium)).foregroundStyle(files == 0 ? Theme.text2 : Theme.text).lineLimit(1).layoutPriority(1)
            if off, let b = g?.branch {
                Text("⎇ \(b)").font(Typo.mono(10)).foregroundStyle(Color(hex: 0xC4B5FD)).lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.violet.opacity(0.12)))
                    .frame(maxWidth: 96, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .help(b)
            }
            Spacer(minLength: 4)
            if hovering {
                HStack(spacing: 1) {
                    repoAction("❯", Theme.body, "Terminal in \(r.name)") { pickRepo(r.id, in: p); store.openProject(r.id); store.newTerminal(project: r.id) }
                    repoAction("✳", Self.agentOrange, "Agent in \(r.name)") { pickRepo(r.id, in: p); store.startAgent(project: r.id) }
                    MenuButton(items: { repoMenu(r) }) {
                        Text("•••").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.body).frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .accessibilityLabel("More for \(r.name)")
                }
            } else {
                HStack(spacing: 6) {
                    if working { LiveDot(color: Theme.green, size: 6, ring: 5) }
                    if let g, g.ahead > 0 { Text("↑\(g.ahead)").font(Typo.mono(10)).foregroundStyle(Theme.text2) }
                    if let g, g.behind > 0 { Text("↓\(g.behind)").font(Typo.mono(10)).foregroundStyle(Theme.amber) }
                    Group {
                        if lines > 0 { Text("±\(Compact.number(lines))").foregroundStyle(lines >= 500 ? Theme.amber : Theme.body) }
                        else if files > 0 { Text("\(files) new").foregroundStyle(Theme.body) }
                        else { Text("✓").foregroundStyle(Theme.disabled) }
                    }
                    .font(Typo.mono(10.5, .semibold)).frame(minWidth: 30, alignment: .trailing)
                }
            }
        }
        .padding(.leading, Tree.child + 2).padding(.trailing, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.selected : (hovering ? Theme.hover : .clear)))
        .overlay(cursorRing("r:" + r.id))
        .contentShape(Rectangle())
        .onHover { hoveredRepo = $0 ? r.id : (hoveredRepo == r.id ? nil : hoveredRepo) }
        .onTapGesture {
            cursor = "r:" + r.id
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { store.openProject(r.id) } else { store.route = .projectHome(r.id) }
        }
        .contextMenu { ProjectContextMenu(project: r) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(repoLabel(r, branch: g?.branch, lines: lines, files: files, working: working))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open Terminal") { store.openProject(r.id); store.newTerminal(project: r.id) }
        .accessibilityAction(named: "Start Agent") { store.startAgent(project: r.id) }
    }

    private func repoLabel(_ r: Project, branch: String?, lines: Int, files: Int, working: Bool) -> String {
        var parts = [r.name]
        if let branch, !branch.isEmpty { parts.append("on \(branch)") }
        if let g = store.git[r.id] {
            if g.ahead > 0 { parts.append("\(g.ahead) ahead") }
            if g.behind > 0 { parts.append("\(g.behind) behind") }
        }
        parts.append(lines > 0 ? "\(lines) lines changed" : files > 0 ? "\(files) new files" : "clean")
        if working { parts.append("agent working") }
        return parts.joined(separator: ", ")
    }

    private func repoAction(_ glyph: String, _ color: Color, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(.system(size: 11)).foregroundStyle(color).frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white(0.001)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func repoMenu(_ r: Project) -> [MenuSpec] {
        let path = (r.path as NSString).expandingTildeInPath
        return [
            MenuSpec(title: "Open in Workspace", symbol: "rectangle.split.2x1") { store.openProject(r.id) },
            .separator,
            MenuSpec(title: "Pull", symbol: "arrow.down") { store.pull(r.id) },
            MenuSpec(title: "Push", symbol: "arrow.up") { store.push(r.id) },
            .separator,
            MenuSpec(title: "Reveal in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
            MenuSpec(title: "Copy Path", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        ]
    }

    /// "Servers 2 · Docker 4 · DB 1" with a health dot each; a click opens the groups.
    @ViewBuilder private func resourcesLine(_ p: Project) -> some View {
        let hosts = store.linkedHosts(p.id), dbs = store.linkedDatabases(p.id)
        let stacks = store.dockerVisible ? store.linkedStacks(p.id) : [], containers = store.dockerVisible ? store.linkedDocker(p.id) : []
        let dockerN = stacks.count + containers.count
        let dockerUp = stacks.filter(\.isRunning).count + containers.filter { $0.state == .running }.count
        let items: [(String, String, Int, Color)] = [
            ("server.rack", "Servers", hosts.count, hosts.contains { store.hostStatus[$0.id] == .connected } ? Theme.green : Theme.disabled),
            ("shippingbox", "Docker", dockerN, dockerUp == 0 ? Theme.disabled : dockerUp == dockerN ? Theme.green : Theme.amber),
            ("cylinder", "DB", dbs.count, dbs.contains { store.dbStatus[$0.id] == .connected } ? Theme.green : Theme.disabled)
        ].filter { $0.2 > 0 }
        if !items.isEmpty {
            let open = !groupOpen(p.id, "res")
            Button { toggleGroup(p.id, "res") } label: {
                HStack(spacing: 10) {
                    ForEach(items, id: \.1) { i in
                        HStack(spacing: 5) {
                            Image(systemName: i.0).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.text3)
                            Text("\(i.1) \(i.2)").font(Typo.ui(11)).foregroundStyle(Theme.text2)
                            Circle().fill(i.3).frame(width: 5, height: 5)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.meta)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.leading, Tree.child).padding(.trailing, 8)
                .frame(height: 28)
                .background(alignment: .leading) { elbow(p.hue.color) }
                .rowBackground(selected: false)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .accessibilityLabel(items.map { "\($0.1) \($0.2)" }.joined(separator: ", "))
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open { linkedGroups(p, headers: false) }
        }
    }

    // MARK: Keyboard

    /// Rows the arrow keys walk, top to bottom, as "p:" / "s:" / "r:" ids.
    private var cursorRows: [String] {
        visibleProjects.flatMap { p -> [String] in
            var rows = ["p:" + p.id]
            guard isExpanded(p.id) else { return rows }
            let repos = store.children(of: p.id)
            let ids = Set(repos.map(\.id) + [p.id])
            rows += store.sessions.filter { $0.projectID.map(ids.contains) == true }.map { "s:" + $0.id }
            if groupOpen(p.id, "repos") { rows += sortedRepos(repos).map { "r:" + $0.id } }
            return rows
        }
    }

    private func moveCursor(_ by: Int) {
        let rows = cursorRows
        guard !rows.isEmpty else { return }
        let i = cursor.flatMap(rows.firstIndex(of:)) ?? (by > 0 ? -1 : rows.count)
        cursor = rows[min(max(i + by, 0), rows.count - 1)]
    }

    private func expandCursor(_ open: Bool) {
        guard let c = cursor else { return moveCursor(1) }
        let id = String(c.dropFirst(2))
        if c.hasPrefix("p:") {
            if isExpanded(id) != open { toggleExpanded(id) }
        } else if !open {
            // ← on a row inside a project goes up to the project.
            let owner = c.hasPrefix("r:") ? store.project(id)?.parentID : store.session(id)?.projectID.map { store.project($0)?.parentID ?? $0 }
            if let owner { cursor = "p:" + owner }
        }
    }

    private func activateCursor() {
        guard let c = cursor else { return }
        let id = String(c.dropFirst(2))
        switch c.prefix(2) {
        case "p:": store.route = .projectHome(id); if !isExpanded(id) { toggleExpanded(id) }
        case "r:": store.route = .projectHome(id)
        default: store.reveal(session: id)
        }
    }

    private func cursorRing(_ id: String) -> some View {
        RoundedRectangle(cornerRadius: 7).strokeBorder(accent.opacity(treeFocused && cursor == id ? 0.7 : 0), lineWidth: 1.5)
            .allowsHitTesting(false)
    }

    // MARK: Linked groups

    /// Open by default; a click collapses it and that's remembered.
    /// Servers, Docker and Databases start closed, so opening a project shows just
    /// its top level; they're stored as "~open" once opened. The rest start open.
    private static let closedByDefault: Set<String> = ["ssh", "docker", "db"]

    private func groupKey(_ p: ProjectID, _ key: String) -> String {
        Self.closedByDefault.contains(key) ? "\(p)#\(key)~open" : "\(p)#\(key)"
    }

    private func groupOpen(_ p: ProjectID, _ key: String) -> Bool {
        let stored = store.settings.collapsedSections.contains(groupKey(p, key))
        return Self.closedByDefault.contains(key) ? stored : !stored
    }

    private func toggleGroup(_ p: ProjectID, _ key: String) {
        let k = groupKey(p, key)
        withAnimation(.easeOut(duration: 0.15)) {
            if store.settings.collapsedSections.contains(k) { store.settings.collapsedSections.remove(k) } else { store.settings.collapsedSections.insert(k) }
        }
    }

    /// `headers: false` lists the items without their group rows (under the one-line summary).
    @ViewBuilder private func linkedGroups(_ p: Project, headers: Bool = true) -> some View {
        let hosts = store.linkedHosts(p.id), dbs = store.linkedDatabases(p.id)
        let stacks = store.linkedStacks(p.id), containers = store.linkedDocker(p.id)
        let online = hosts.filter { store.hostStatus[$0.id] == .connected }.count
        let hue = p.hue.color
        group(p, "ssh", "Servers", "server.rack", online > 0 ? "\(online) online" : "\(hosts.count) linked",
              empty: hosts.isEmpty, hue: hue, header: headers) {
            let order = hosts.map(\.id)
            ForEach(hosts) { h in
                itemRow(icon: AnyView(ServerOSIcon(host: h, size: 18)), name: h.name, meta: "", tag: h.tag,
                        dot: (store.hostStatus[h.id] ?? .disconnected) == .connected ? Theme.green : Theme.disabled,
                        selected: hostSelected(h, in: p.id), hue: hue) { openFiles(h, in: p) }
                    .contextMenu {
                        Button("Browse Files") { openFiles(h, in: p) }
                        Button("Open Terminal") { store.openProject(p.id); store.connect(h.id, project: p.id) }
                        Divider()
                        HostContextMenu(host: h)
                        Divider()
                        Button("Detach from \(p.name)") { store.library.links.unlink(p.id, h.id) }
                    }
                    .reorderableRow(h.id, list: "hosts-\(p.id)", order: order, state: rowDrag) { from, to in
                        guard let a = store.library.hosts.firstIndex(where: { $0.id == order[from] }),
                              let b = store.library.hosts.firstIndex(where: { $0.id == order[to] }) else { return }
                        store.library.hosts.reorder(from: a, onto: b)
                    }
            }
        }
        if store.dockerVisible {
            let running = stacks.filter(\.isRunning).count + containers.filter { $0.state == .running }.count
            group(p, "docker", "Docker", "shippingbox", "\(running) running",
                  empty: stacks.isEmpty && containers.isEmpty, hue: hue, header: headers) {
                ForEach(stacks) { st in
                    itemRow(icon: AnyView(LogoBadge(logo: "Logos/docker", color: Theme.blue, size: 18)), name: st.name, meta: "",
                            tag: nil, dot: st.isRunning ? Theme.green : Theme.disabled,
                            selected: store.route == .docker && store.dockerSelection == .stack(st.id), hue: hue) {
                        store.dockerTab = "stacks"
                        store.dockerSelection = .stack(st.id)
                        store.go(.docker)
                    }
                    .contextMenu { Button("Detach from \(p.name)") { store.setStackLink(p.id, st, linked: false) } }
                }
                ForEach(containers) { c in
                    itemRow(icon: AnyView(LogoBadge(logo: "Logos/docker", color: Theme.blue, size: 18)), name: c.name,
                            meta: c.ports.split(separator: ",").first.map { ":" + ($0.split(separator: ":").last.map(String.init) ?? "") } ?? "",
                            tag: nil, dot: c.state == .running ? Theme.green : Theme.disabled, selected: containerSelected(c, in: p.id), hue: hue) {
                        store.openProject(p.id)
                        store.openDockerShell(c.id, project: p.id)
                    }
                    .contextMenu {
                        Button("Open Shell") { store.openProject(p.id); store.openDockerShell(c.id, project: p.id) }
                        Button("Follow Logs") { store.openProject(p.id); store.openDockerLogs(c.id, project: p.id) }
                        Divider()
                        Button("Detach from \(p.name)") { store.library.links.unlink(p.id, c.id) }
                    }
                }
            }
        }
        group(p, "db", "Databases", "cylinder", "\(dbs.count) linked", empty: dbs.isEmpty, hue: hue, header: headers) {
            let order = dbs.map(\.id)
            ForEach(dbs) { d in
                let key = "\(p.id)|c:\(d.id)"
                let open = store.dataWorkspace.expanded.contains(key)
                itemRow(icon: AnyView(DatabaseIcon(db: d, size: 18)), name: d.name, meta: d.port > 0 ? ":\(d.port)" : "", tag: d.tag,
                        dot: store.dbStatus[d.id] == .connected ? Theme.green : Theme.disabled, selected: activeTab(p.id) == GridItemID.database(d.id), hue: hue,
                        expanded: open) {
                    // Opens its tree of tables; a table opens as a tab in this project.
                    if open { store.dataWorkspace.expanded.remove(key) } else { store.dataWorkspace.expanded.insert(key); store.loadTree(d) }
                }
                .contextMenu {
                    Button("Add as a Tab") { store.openProject(p.id); store.workspace(for: p.id).placeTab(GridItemID.database(d.id), in: nil) }
                    Divider()
                    DatabaseContextMenu(db: d)
                    Divider()
                    Button("Detach from \(p.name)") { store.library.links.unlink(p.id, d.id) }
                }
                .reorderableRow(d.id, list: "dbs-\(p.id)", order: order, state: rowDrag) { from, to in
                    guard let a = store.library.databases.firstIndex(where: { $0.id == order[from] }),
                          let b = store.library.databases.firstIndex(where: { $0.id == order[to] }) else { return }
                    store.library.databases.reorder(from: a, onto: b)
                }
                if open { DBTreeRows(connection: d, scope: p.id, indent: Tree.item + 16, project: p.id) }
            }
        }
    }

    /// A linked group; hidden when nothing is linked (the project's + menu links things).
    @ViewBuilder private func group<Items: View>(_ p: Project, _ key: String, _ title: String, _ symbol: String, _ summary: String,
                                                 empty: Bool, hue: Color, header: Bool = true, @ViewBuilder items: () -> Items) -> some View {
        if !empty, !header {
            VStack(alignment: .leading, spacing: 0) { items() }
                .backgroundPreferenceValue(BranchEnd.self) { end in
                    Rectangle().fill(hue.opacity(0.35)).frame(width: 1, height: max(0, end + 7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .offset(x: Tree.branch, y: -7)
                }
                .coordinateSpace(name: "branch")
        } else if !empty {
            let open = groupOpen(p.id, key)
            Button { toggleGroup(p.id, key) } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.text3).frame(width: 12)
                    Text(title).font(Typo.ui(11.5, .semibold)).foregroundStyle(Theme.text2)
                    Text(summary).font(Typo.ui(10.5)).foregroundStyle(Theme.meta)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.meta)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.leading, Tree.child).padding(.trailing, 8)
                .frame(height: 26)
                .background(alignment: .leading) { elbow(hue) }
                .rowBackground(selected: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(summary)")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                // Items hang off a short branch under the group's icon.
                VStack(alignment: .leading, spacing: 0) { items() }
                    .backgroundPreferenceValue(BranchEnd.self) { end in
                        Rectangle().fill(hue.opacity(0.35)).frame(width: 1, height: max(0, end + 7))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .offset(x: Tree.branch, y: -7)
                    }
                    .coordinateSpace(name: "branch")
            }
        }
    }

    /// `expanded`: nil for rows that don't open, else whether a chevron points down.
    private func itemRow(icon: AnyView, name: String, meta: String, tag: EnvTag?, dot: Color, selected: Bool, hue: Color,
                         expanded: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon
                Text(name).font(Typo.ui(12.5)).foregroundStyle(selected ? Theme.text : Theme.body).lineLimit(1)
                Spacer(minLength: 0)
                if !meta.isEmpty { Text(meta).font(Typo.mono(10)).foregroundStyle(Theme.meta) }
                if let tag { TagPill(tag: tag, size: 8.5, filled: false) }
                Circle().fill(dot).frame(width: 6, height: 6)
                if let expanded {
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.meta)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 8)
                }
            }
            .padding(.leading, Tree.item).padding(.trailing, 8)
            .frame(height: 28)
            .background(alignment: .leading) {
                Rectangle().fill(hue.opacity(0.35)).frame(width: 8, height: 1).offset(x: Tree.branch)
                    .background(GeometryReader { g in Color.clear.preference(key: BranchEnd.self, value: g.frame(in: .named("branch")).midY) })
            }
            .rowBackground(selected: selected)
        }
        .buttonStyle(.plain)
    }

    /// SSH files open as a tab in the project's tiled centre.
    private func openFiles(_ h: SSHHost, in p: Project) {
        store.guardProduction(h.tag, name: h.name, verb: "Browse files on") {
            store.openProject(p.id)
            store.workspace(for: p.id).placeTab(GridItemID.remoteFiles(h.id), in: nil)
        }
    }

    // MARK: Library and footer

    private var library: some View {
        let running = store.allDocker.filter { $0.state == .running }.count
        return VStack(spacing: 0) {
            // A click opens the connection tree (and the overview); another closes it.
            Button {
                withAnimation(.easeOut(duration: 0.15)) { dbTreeOpen.toggle() }
                if dbTreeOpen { store.go(.dbConnections) }
            } label: {
                libraryLabel("Databases", symbol: "cylinder", meta: "\(store.library.databases.count) saved",
                             on: isActive(.dbConnections) || isActive(.databases))
            }
            .buttonStyle(.plain)
            .accessibilityValue(dbTreeOpen ? "Expanded" : "Collapsed")
            if dbTreeOpen { DBLibraryTree() }
            libraryRow("Servers", symbol: "server.rack", meta: "\(store.library.hosts.count) saved", route: .ssh)
            if store.dockerVisible { libraryRow("Docker", symbol: "shippingbox", meta: "\(running) running", route: .docker) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .hairlineTop()
    }

    private func libraryRow(_ title: String, symbol: String, meta: String, route: Route) -> some View {
        Button { store.go(route) } label: { libraryLabel(title, symbol: symbol, meta: meta, on: isActive(route)) }
            .buttonStyle(.plain)
    }

    private func libraryLabel(_ title: String, symbol: String, meta: String, on: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .medium)).foregroundStyle(on ? accent : Theme.text3).frame(width: 16)
            Text(title).font(Typo.ui(12.5)).foregroundStyle(on ? Theme.text : Theme.body)
            Spacer(minLength: 0)
            Text(meta).font(Typo.ui(11)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 8)
        .rowHeight(28)
        .rowBackground(selected: on)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            MenuButton(items: {
                [MenuSpec(title: "Project Folder…", symbol: "folder.badge.plus", key: "⌘O") { store.sheet = .addProject },
                 MenuSpec(title: "SSH Host…", symbol: "globe") { store.sheet = .editHost(nil) },
                 MenuSpec(title: "Database…", symbol: "cylinder.split.1x2") { store.sheet = .editDatabase(nil) },
                 MenuSpec(title: "Docker Target…", symbol: "shippingbox") { store.sheet = .addDocker },
                 .separator,
                 MenuSpec(title: "Import from JetBrains / VS Code…", symbol: "square.and.arrow.down") { store.sheet = .importConnections }]
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 10.5, weight: .heavy))
                    Text("Add").font(Typo.ui(12, .semibold))
                }
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(accent))
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Add project, host, database or Docker target")
            Spacer()
            IconButton(symbol: "slider.horizontal.3", label: "Customize layout and appearance", shortcut: "⌘,", size: 26, iconSize: 13, color: Theme.text2,
                       active: store.route == .customize) { store.go(.customize) }
            IconButton(symbol: store.settings.sidebarPosition == .left ? "chevron.left.2" : "chevron.right.2", label: "Collapse sidebar", size: 26, iconSize: 11, color: Theme.text2) {
                withAnimation(.easeOut(duration: 0.18)) {
                    if store.sidebarForcedFull { store.sidebarForcedFull = false } else { store.settings.sidebarStyle = .rail }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .hairlineTop()
    }
}

/// "New in <project>" menu from the project's + button.
private struct NewInProjectMenu: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let dismiss: () -> Void

    private struct Item: Identifiable {
        let id: String
        var icon: AnyView
        var tint: Color
        var label: String
        var sub: String
        var key = ""
        var action: () -> Void
    }

    private var items: [Item] {
        let p = project
        let path = (p.expandedPath as NSString).abbreviatingWithTildeInPath
        var out: [Item] = store.enabledAgents.enumerated().map { i, a in
            let ready = store.isInstalled(a) || p.isSample
            return Item(id: "agent-\(a.id)", icon: AnyView(AgentMark(agent: a, size: 11)), tint: Color(hex: 0xE07B53).opacity(0.12),
                        label: "\(a.name) session", sub: ready ? "In \(path)" : "Not installed: click to install", key: i == 0 ? "⌥⌘T" : "") {
                if ready { store.launchAgent(a, project: p.id, then: nil) } else { store.installAgent(a) }
            }
        }
        let shell = ((ProcessInfo.processInfo.environment["SHELL"] ?? "zsh") as NSString).lastPathComponent
        out.append(Item(id: "terminal", icon: AnyView(Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.body)),
                        tint: Color.white(0.06), label: "Terminal", sub: "\(shell) in project folder", key: "⌘T") {
            store.openProject(p.id)
            store.newTerminal(project: p.id)
        })
        for h in store.linkedHosts(p.id) {
            out.append(Item(id: "host-\(h.id)", icon: AnyView(Image(systemName: "globe").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.blue)),
                            tint: Theme.blue.opacity(0.12), label: "Shell on \(h.name)", sub: "Linked server") {
                store.openProject(p.id)
                store.connect(h.id, project: p.id)
            })
        }
        for c in store.linkedDocker(p.id) {
            out.append(Item(id: "docker-\(c.id)", icon: AnyView(Image(systemName: "shippingbox").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text2)),
                            tint: Color.white(0.06), label: "Shell in \(c.name)", sub: "Linked container") {
                store.openProject(p.id)
                store.openDockerShell(c.id, project: p.id)
            })
        }
        out.append(Item(id: "link", icon: AnyView(Image(systemName: "link").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text2)),
                        tint: Color.white(0.06), label: "Link server, container or DB…", sub: "Opens Project Resources") {
            store.route = .projectSettings(p.id)
        })
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New in \(project.name)").font(Typo.ui(10.5, .semibold)).foregroundStyle(Theme.text3)
                .padding(.horizontal, 8).padding(.top, 5).padding(.bottom, 4)
            ForEach(items) { item in
                MenuRow(item: item) { dismiss(); item.action() }
            }
        }
        .padding(5)
        .frame(width: 252)
        .background(Theme.popover)
    }

    private struct MenuRow: View {
        let item: Item
        let action: () -> Void
        @State private var hovering = false
        var body: some View {
            Button(action: action) {
                HStack(spacing: 9) {
                    item.icon
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(item.tint))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label).font(Typo.ui(12.5)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(item.sub).font(Typo.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !item.key.isEmpty { Text(item.key).font(Typo.ui(10.5)).foregroundStyle(Theme.meta) }
                }
                .padding(.horizontal, 8)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.selected : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

private struct RailSidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    private let nav: [Route] = [.overview, .projects, .terminals, .git, .docker, .ssh, .dbConnections]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(nav.filter { $0 != .docker || store.dockerVisible }, id: \.self) { r in
                let on = store.route == r
                Button { store.go(r) } label: {
                    Image(systemName: r.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(on ? accent : Theme.text2)
                        .frame(width: 36, height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.white(0.08) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(r.title)
                .tip(r.title)
            }
            Rectangle().fill(Color.white(0.08)).frame(width: 26, height: 1).padding(.vertical, 8)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    // Top-level projects only (repositories live inside theirs), with their own mark.
                    ForEach(store.sortedProjects.filter { $0.parentID == nil }) { p in
                        let kids = Set(store.children(of: p.id).map(\.id))
                        let on = store.route.projectID.map { $0 == p.id || kids.contains($0) } ?? false
                        Button { store.route = .projectHome(p.id) } label: {
                            ProjectMark(project: p, size: 26)
                                .frame(width: 36, height: 34)
                                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.white(0.08) : .clear))
                                .overlay(alignment: .topTrailing) {
                                    if store.waitingSessions.contains(where: { $0.projectID == p.id || $0.projectID.map(kids.contains) == true }) {
                                        Circle().fill(Theme.amber).frame(width: 6, height: 6).offset(x: -5, y: 5)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(p.name)
                        .tip(p.name)
                        .contextMenu { ProjectContextMenu(project: p) }
                    }
                }
            }
            Spacer(minLength: 0)
            IconButton(symbol: "slider.horizontal.3", label: "Customize", shortcut: "⌘,", size: 36, iconSize: 14, color: Theme.text2) { store.go(.customize) }
            IconButton(symbol: store.settings.sidebarPosition == .left ? "chevron.right.2" : "chevron.left.2", label: "Expand sidebar", size: 36, iconSize: 12, color: Theme.text2) {
                withAnimation(.easeOut(duration: 0.18)) {
                    store.settings.sidebarStyle = .full
                    if store.windowNarrow { store.sidebarForcedFull = true }
                }
            }
        }
        .padding(.vertical, 10)
        .frame(width: Metrics.sidebarRail)
    }
}

// MARK: - Shared context menus

struct ProjectContextMenu: View {
    @Environment(AppStore.self) private var store
    let project: Project
    var body: some View {
        Button("Open Workspace") { store.openProject(project.id) }
        Button("Overview") { store.route = .projectHome(project.id) }
        Button("Open in Terminal") { store.newTerminal(project: project.id, attach: false); store.route = .terminals }
        Button("Start Agent Here…") { store.startAgent(project: project.id) }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.expandedPath) }
            .disabled(project.isSample)
        Button("Copy Path") { store.copyToPasteboard(project.expandedPath, label: "path") }
        Button(project.isPinned ? "Unpin" : "Pin") { store.togglePin(project.id) }
        Button("Rename and Change Icon…") { store.projectSettingsSection = "General"; store.route = .projectSettings(project.id) }
        Button("Project Settings…") { store.route = .projectSettings(project.id) }
        Divider()
        Button("Remove…", role: .destructive) { store.requestRemoveProject(project.id) }
    }
}

struct HostContextMenu: View {
    @Environment(AppStore.self) private var store
    let host: SSHHost
    var body: some View {
        Button("Connect / Open Terminal") { store.connect(host.id) }
        Button("Browse Files") { store.guardProduction(host.tag, name: host.name, verb: "Browse files on") { store.go(.remoteFiles(host.id)) } }
        Button("Edit…") { store.sheet = .editHost(host) }
        Button("Duplicate") { store.duplicateHost(host.id) }
        Button("Copy SSH Command") { store.copyToPasteboard(host.sshCommand, label: "SSH command") }
        AttachToProjectMenu(resource: host.id, kind: .host)
        Divider()
        Button("Remove…", role: .destructive) { store.requestRemoveHost(host.id) }
    }
}

struct DatabaseContextMenu: View {
    @Environment(AppStore.self) private var store
    let db: DatabaseConnection
    var body: some View {
        Button("Open in Browser") { store.selectedDatabase = db.id; store.go(.databases) }
        Button("New Query") { store.pendingQuery = (db.id, ""); store.selectedDatabase = db.id; store.go(.databases) }
        Button("Edit…") { store.sheet = .editDatabase(db) }
        Button("Duplicate") { store.duplicateDatabase(db.id) }
        Button("Copy Connection URL") { store.copyToPasteboard(store.connectionURL(db), label: "connection URL (no password)") }
        Divider()
        Button("Dump…") { store.dumpDatabase(db) }
        Button("Restore…") { store.restoreDatabase(db) }.disabled(db.readOnly)
        Button("Open CLI") { store.openDatabaseCLI(db) }
        Toggle("Read-only", isOn: Binding(get: { db.readOnly || db.tag.isProduction }, set: { v in
            var d = db; d.readOnly = v; store.saveDatabase(d, password: nil)
        }))
        .disabled(db.tag.isProduction)
        AttachToProjectMenu(resource: db.id, kind: .database)
        Divider()
        Button("Delete…", role: .destructive) { store.requestRemoveDatabase(db.id) }
    }
}

/// Small × that appears on a sidebar row; also how terminal tabs close.
struct SidebarCloseButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                .foregroundStyle(hovering ? Theme.text : Theme.meta)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Context-menu submenu: tick projects a host, database or container belongs to.
struct AttachToProjectMenu: View {
    @Environment(AppStore.self) private var store
    let resource: ResourceID
    let kind: ResourceKind

    var body: some View {
        Menu("Attach to Project") {
            ForEach(store.sortedProjects) { p in
                let on = store.library.links.isLinked(p.id, resource)
                Button { store.setLink(p.id, resource, kind: kind, linked: !on) } label: { Text(on ? "✓ \(p.name)" : p.name) }
            }
            if store.sortedProjects.isEmpty { Text("No projects yet") }
        }
    }
}

/// How far down a project's spine reaches: the middle of its last branch.
private struct SpineEnd: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The same for a group's own short branch.
private struct BranchEnd: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Where the project tree's lines sit. The spine runs down from the middle of
/// the project icon (row inset 6 + chevron 12 + gap 8 + half the icon).
enum Tree {
    static let icon: CGFloat = 30
    static let spine: CGFloat = 6 + 12 + 8 + icon / 2
    /// Rows hanging off the spine start after its 8pt elbow.
    static let child: CGFloat = spine + 12
    /// A group's own short line, under the group's icon.
    static let branch: CGFloat = child + 6
    static let item: CGFloat = branch + 14
}

/// The git branch mark: a trunk and a branch curving off it.
struct BranchGlyph: Shape {
    func path(in r: CGRect) -> Path {
        let u = r.width / 24
        var p = Path()
        p.move(to: CGPoint(x: 6 * u, y: 3 * u)); p.addLine(to: CGPoint(x: 6 * u, y: 15 * u))
        p.addEllipse(in: CGRect(x: 15 * u, y: 3 * u, width: 6 * u, height: 6 * u))
        p.addEllipse(in: CGRect(x: 3 * u, y: 15 * u, width: 6 * u, height: 6 * u))
        p.move(to: CGPoint(x: 18 * u, y: 9 * u))
        p.addQuadCurve(to: CGPoint(x: 9 * u, y: 18 * u), control: CGPoint(x: 18 * u, y: 18 * u))
        return p
    }
}
