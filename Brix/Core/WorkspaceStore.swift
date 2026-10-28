import SwiftUI
import Observation

/// State of one open project: layout, files, terminals, selection.
@MainActor
@Observable
final class WorkspaceStore {
    let projectID: ProjectID
    unowned let app: AppStore

    var state: WorkspaceState { didSet { app.scheduleSave() } }
    var tree: [FileNode] = []
    var treeError: String?
    var contents: [String: FileContent] = [:]
    var diffs: [String: FileDiff] = [:]
    var selectedCommit: String?
    var commitDetail: GitCommit?
    var commitMessage = ""
    var panelSelection: String?
    var gutter: [String: [GutterMark]] = [:]
    var cursor: (Int, Int) = (1, 1)
    var cursorPath: String?
    private var watcher: AnyObject?
    /// Its folder watcher is running, so Git refreshes when the project changes.
    var watchesFiles: Bool { watcher != nil }
    private var activated = false
    /// Tabs closed in the tiled centre this run, newest last (⇧⌘T reopens).
    var closedTabs: [ClosedTab] = []
    /// Unsaved edits per open file (project-relative path).
    var drafts: [String: String] = [:]
    /// Saved sessions have been recreated; until then saving keeps the saved list.
    private(set) var restored = false

    var layout: DockLayout {
        get { state.layout }
        set { state.layout = newValue }
    }

    var project: Project? { app.project(projectID) }

    init(projectID: ProjectID, app: AppStore) {
        self.projectID = projectID
        self.app = app
        let defaultLayout = app.project(projectID).flatMap { BuiltinPreset(rawValue: $0.defaultPreset) }.map(DockLayout.preset) ?? app.library.defaultLayout
        do {
            if let saved = try app.persistence.load(WorkspaceState.self, from: "workspaces/\(projectID).json") {
                state = saved
            } else {
                state = WorkspaceState(layout: defaultLayout)
                seedDefaults()
            }
        } catch {
            state = WorkspaceState(layout: defaultLayout)
            app.toast(.error, "Couldn't restore the layout for \(projectID)", detail: error.localizedDescription)
        }
        adoptTiledCentre()
    }

    /// Saves with the project's current live sessions, however they were opened,
    /// so every terminal and agent comes back after a relaunch or a crash.
    func save() throws {
        var s = state
        if restored, project?.isSample == false {
            s.sessions = projectSessions.filter(\.isLive).filter { $0.state != .finished && $0.state != .failed }.map(SessionDescriptor.init)
        }
        try app.persistence.save(s, to: "workspaces/\(projectID).json")
    }

    private func seedDefaults() {
        guard let p = project, p.isSample else { return }
        if p.id == "atlas-web" {
            state.openFiles = ["src/components/PaymentForm.tsx", "src/app/checkout/page.tsx", "src/lib/stripe/intent.ts", "CLAUDE.md"]
            state.activeFile = "src/components/PaymentForm.tsx"
            state.selection = "src/components/PaymentForm.tsx"
            state.expanded = ["src", "src/app", "src/app/checkout", "src/components", "src/lib", "src/lib/stripe"]
            var tree = PaneTree()
            ["s-claude-aw", "s-dev-aw", "s-logs-dev"].forEach { tree.add($0) }
            tree.add("s-claude-aa")
            tree.split("s-claude-aa", beside: tree.groups[0].id, edge: .right)
            tree.add("s-htop-dev", to: tree.group(of: "s-claude-aa")?.id)
            tree.activate("s-claude-aw")
            tree.activate("s-claude-aa")
            state.panes = tree
            if let term = state.layout.allPanels.first(where: { $0.kind == .terminal }) {
                state.panelSession[term.id] = "s-claude-aw"
                state.panelSession[term.id + ":split"] = "s-dev-aw"
            }
            state.reviewFile = "s:src/components/PaymentForm.tsx"
            commitMessage = "Add Apple Pay wallet buttons to checkout"
        } else {
            let sessions = app.sessions.filter { $0.projectID == p.id }.map(\.id)
            if !sessions.isEmpty {
                sessions.forEach { state.panes.add($0) }
            }
        }
    }

    /// Called when the workspace becomes visible.
    func activate() {
        if !activated {
            activated = true
            restoreLiveSessions()
            loadTree()
            if let p = project, !p.isSample {
                watcher = app.svc(p).files.watch(p) { [weak self] files in
                    Task { @MainActor in
                        self?.app.refreshGit(p.id)
                        guard files else { return }
                        self?.loadTree()
                        self?.reloadOpenFiles()
                    }
                }
            }
        }
        app.refreshGit(projectID)
        if let f = state.activeFile { load(f) }
        if let f = state.splitFile { load(f) }
    }

    func loadTree() {
        guard let p = project else { return }
        Task {
            do {
                tree = try await app.svc(p).files.tree(p)
                treeError = nil
            } catch {
                tree = []
                treeError = error.localizedDescription
            }
        }
    }

    // MARK: Files

    func open(_ path: String, split: Bool = false) {
        if !state.openFiles.contains(path) { state.openFiles.append(path) }
        // A file is a tab in the tiled centre, next to other files when there are some.
        placeFile(path)
        state.layout.centre = .agents
        if split {
            state.splitFile = path
        } else {
            state.activeFile = path
        }
        state.selection = path
        expandParents(of: path)
        load(path)
        app.library.recentFiles.removeAll { $0.project == projectID && $0.path == path }
        app.library.recentFiles.insert(RecentFile(project: projectID, path: path, openedAt: Date()), at: 0)
        if app.library.recentFiles.count > 100 { app.library.recentFiles.removeLast() }
        app.inspector = .file(projectID, path)
    }

    private func placeFile(_ path: String) {
        let id = GridItemID.file(path)
        if state.panes.group(of: id) != nil {
            state.panes.activate(id)
        } else {
            let home = state.panes.groups.first { $0.tabs.contains(where: GridItemID.isFile) }?.id
            state.panes.add(id, to: home ?? state.panes.focusedGroup)
        }
    }

    /// Files, agents and terminals all share the tiled centre. Older layouts
    /// with a separate editor move their open files into it.
    func adoptTiledCentre() {
        let loose = state.openFiles.filter { state.panes.group(of: GridItemID.file($0)) == nil }
        guard state.layout.centre == .editor || !loose.isEmpty else { return }
        for f in loose { placeFile(f) }
        if let f = state.activeFile, !loose.isEmpty { state.panes.activate(GridItemID.file(f)) }
        if state.layout.centre == .editor { state.layout.centre = .agents }
    }

    func expandParents(of path: String) {
        var comps = path.split(separator: "/").map(String.init)
        comps.removeLast()
        var acc = ""
        for c in comps {
            acc = acc.isEmpty ? c : acc + "/" + c
            state.expanded.insert(acc)
        }
    }

    func load(_ path: String) {
        guard let p = project, contents[path] == nil else { return }
        Task { contents[path] = await app.svc(p).files.read(p, path: path) }
    }

    /// Re-reads open files after a change on disk; keeps the old text until the new one arrives.
    func reloadOpenFiles() {
        guard let p = project else { return }
        let paths = Set([state.activeFile, state.splitFile].compactMap { $0 })
        contents = contents.filter { paths.contains($0.key) }
        diffs = [:]
        for path in paths {
            Task {
                let fresh = await app.svc(p).files.read(p, path: path)
                if contents[path] != fresh { contents[path] = fresh }
                await loadDiff(for: path)
            }
        }
    }

    func close(_ path: String) {
        if drafts[path] != nil {
            app.confirm("Save changes to \((path as NSString).lastPathComponent)?", "Your edits are lost if you close without saving.", confirm: "Discard Changes") { [weak self] in
                self?.drafts[path] = nil
                self?.close(path)
            }
            return
        }
        state.panes.remove(GridItemID.file(path))
        guard let i = state.openFiles.firstIndex(of: path) else { return }
        state.openFiles.remove(at: i)
        if state.splitFile == path { state.splitFile = nil }
        if state.activeFile == path {
            state.activeFile = state.openFiles.isEmpty ? nil : state.openFiles[min(i, state.openFiles.count - 1)]
            if let f = state.activeFile { load(f) }
        }
    }

    func cycleTab(_ offset: Int) {
        guard let a = state.activeFile, let i = state.openFiles.firstIndex(of: a), !state.openFiles.isEmpty else { return }
        let next = state.openFiles[(i + offset + state.openFiles.count) % state.openFiles.count]
        state.activeFile = next
        load(next)
    }

    var allFiles: [FileNode] {
        func flat(_ n: [FileNode]) -> [FileNode] { n.flatMap { $0.isDirectory ? flat($0.children ?? []) : [$0] } }
        return flat(tree)
    }

    // MARK: Panels and sessions

    func select(panel id: String) { panelSelection = id }

    /// Puts a session somewhere visible: the agents grid for agents, otherwise a terminal panel.
    func attach(session s: TerminalSession, preferAgentGrid: Bool = false) {
        if !state.sessions.contains(where: { $0.id == s.id }), s.isLive {
            state.sessions.append(SessionDescriptor(id: s.id, title: s.title, kind: s.kind, hostID: s.hostID, cwd: s.cwd, command: s.kind == .agent ? "agent" : nil, agentID: s.agentID))
        }
        if preferAgentGrid || s.kind == .agent || layout.centre == .agents {
            state.panes.add(s.id)
            if preferAgentGrid { state.layout.centre = .agents }
        } else {
            let terminalPanel = layout.allPanels.first { $0.kind == .terminal || ($0.kind == .serverShell && s.hostID != nil) }
            let panel = terminalPanel ?? layout_add(s.hostID != nil ? .serverShell : .terminal)
            state.panelSession[panel.id] = s.id
            if s.hostID != nil, panel.kind == .serverShell { state.layout.bind(panel.id, resource: s.hostID) }
        }
    }

    private func layout_add(_ kind: PanelKind) -> PanelInstance {
        state.layout.add(kind, to: .bottom)
    }

    func detach(session id: String) {
        state.sessions.removeAll { $0.id == id }
        state.panes.remove(id)
        for (k, v) in state.panelSession where v == id { state.panelSession[k] = nil }
    }

    func focus(session id: String) {
        if state.panes.group(of: id) != nil {
            state.panes.activate(id)
            state.layout.centre = .agents
        } else if let panel = state.panelSession.first(where: { $0.value == id })?.key {
            panelSelection = panel
        } else if let s = app.session(id) {
            attach(session: s, preferAgentGrid: s.kind == .agent)
        }
    }

    /// Sessions for this project, used by terminal panels' tab strips.
    var projectSessions: [TerminalSession] {
        app.sessions.filter { $0.projectID == projectID }
    }

    /// The agent session the Plan and Agent Files panels describe: the focused
    /// one, else the first agent in the active tab, else the newest agent here.
    var currentAgentSession: TerminalSession? {
        if let f = app.focusedSessionID, let s = app.session(f), s.projectID == projectID, s.kind == .agent { return s }
        if let gid = state.panes.focusedGroup, let g = state.panes.group(gid), let s = (g.active ?? g.tabs.first).flatMap(app.session), s.kind == .agent { return s }
        if let s = state.panes.visibleTabs.compactMap(app.session).first(where: { $0.kind == .agent }) { return s }
        return projectSessions.last { $0.kind == .agent }
    }




    /// Processes don't survive a relaunch: shells are started again in their last
    /// folder, and agents resume their conversation where the CLI supports it.
    func restoreLiveSessions() {
        guard !restored else { return }
        restored = true
        guard let p = project, !p.isSample else { return }
        let saved = state.sessions
        state.sessions = []
        var remap: [String: String] = [:]
        for d in saved where app.session(d.id) == nil {
            let s: TerminalSession?
            if d.kind == .agent, let a = app.agent(d.agentID) ?? app.enabledAgents.first {
                s = app.newAgentSession(project: projectID, agent: a, resume: d.externalID, attach: false)
                if let s, let i = app.sessions.firstIndex(where: { $0.id == s.id }) { app.sessions[i].task = d.task ?? "" }
            } else {
                s = app.newTerminal(project: projectID, host: d.hostID, title: d.title, kind: d.kind, cwd: d.cwd, attach: false)
            }
            if let s {
                remap[d.id] = s.id
                app.renameSession(s.id, to: d.title)
            }
        }
        state.panes = Self.remapped(state.panes, remap) { [app] in app.session($0) != nil }
        state.panelSession = state.panelSession.compactMapValues { remap[$0] ?? (app.session($0) != nil ? $0 : nil) }
    }

    /// Swaps restored session ids into a saved tree, dropping ones that are gone.
    /// Follows a rename of a file or folder: open files, their tabs, unsaved
    /// edits and loaded text all move to the new path.
    func renamed(from old: String, to new: String) {
        func moved(_ p: String) -> String? {
            if p == old { return new }
            return p.hasPrefix(old + "/") ? new + p.dropFirst(old.count) : nil
        }
        var tabs: [String: String] = [:]
        for f in state.openFiles { if let n = moved(f) { tabs[GridItemID.file(f)] = GridItemID.file(n) } }
        state.openFiles = state.openFiles.map { moved($0) ?? $0 }
        state.activeFile = state.activeFile.map { moved($0) ?? $0 }
        state.splitFile = state.splitFile.map { moved($0) ?? $0 }
        state.selection = state.selection.map { moved($0) ?? $0 }
        if !tabs.isEmpty { state.panes = Self.remapped(state.panes, tabs) { _ in true } }
        for (k, v) in drafts { if let n = moved(k) { drafts[k] = nil; drafts[n] = v } }
        for k in contents.keys where moved(k) != nil { contents[k] = nil }
        for f in state.openFiles where tabs.values.contains(GridItemID.file(f)) { load(f) }
    }

    static func remapped(_ tree: PaneTree, _ remap: [String: String], exists: (String) -> Bool) -> PaneTree {
        func map(_ n: PaneNode) -> PaneNode {
            switch n {
            case .group(var g):
                g.tabs = g.tabs.compactMap { remap[$0] ?? (exists($0) ? $0 : nil) }
                g.active = g.active.flatMap { remap[$0] ?? $0 }
                return .group(g)
            case .split(let id, let v, let c, let w):
                return .split(id: id, vertical: v, children: c.map(map), weights: w)
            }
        }
        var out = tree
        out.root = tree.root.map(map)
        out.retain(Set(out.allTabs))
        return out
    }

    // MARK: Presets

    func apply(_ preset: BuiltinPreset, fresh: Bool = false) {
        if !fresh { rememberArrangement() }
        if !fresh, let saved = state.presetArrangements[preset.rawValue] {
            restore(saved, name: preset.rawValue)
            return
        }
        state.layout.apply(.preset(preset))
        if preset == .agent { arrangeAgentGrid() }
        adoptTiledCentre()
    }

    func apply(custom: CustomPreset, fresh: Bool = false) {
        if !fresh { rememberArrangement() }
        if !fresh, let saved = state.presetArrangements[custom.id] {
            restore(saved, name: custom.id)
            return
        }
        state.layout.apply(custom.layout)
        state.layout.presetName = custom.id
        if let tree = custom.panes { applyPresetTree(tree) }
        adoptTiledCentre()
    }

    /// Keeps this project's current arrangement under the layout it's on.
    func rememberArrangement() {
        guard let name = state.layout.presetName else { return }
        state.presetArrangements[name] = CustomPreset(id: name, name: name, layout: state.layout, panes: state.panes)
    }

    /// Back to the layout's own default arrangement for this project.
    func resetArrangement() {
        guard let name = state.layout.presetName else { return }
        state.presetArrangements[name] = nil
        if let b = BuiltinPreset(rawValue: name) { apply(b, fresh: true) } else if let c = app.library.customPresets.first(where: { $0.id == name }) { apply(custom: c, fresh: true) }
    }

    /// The project's own saved arrangement: tabs that no longer exist drop out,
    /// and sessions opened since join the first pane.
    private func restore(_ saved: CustomPreset, name: String) {
        state.layout = saved.layout
        state.layout.presetName = name
        var t = Self.remapped(saved.panes ?? PaneTree(), [:]) { id in
            GridItemID.isPanel(id) || (GridItemID.filePath(id).map { state.openFiles.contains($0) } ?? false) || app.session(id) != nil
        }
        for s in projectSessions where t.group(of: s.id) == nil { t.add(s.id, to: t.groups.first?.id) }
        state.panes = t
        adoptTiledCentre()
    }

    /// Rebuilds a saved tiled centre: placeholders become fresh shells or this
    /// project's open agents; open sessions with no place join the first pane.
    private func applyPresetTree(_ preset: PaneTree) {
        var agents = projectSessions.filter { $0.kind == .agent }.map(\.id)
        var map: [String: String] = [:]
        for tab in preset.allTabs where tab.hasPrefix("new:") {
            if tab.hasPrefix("new:terminal") {
                map[tab] = app.newTerminal(project: projectID, attach: false).id
            } else if tab.hasPrefix("new:agent"), !agents.isEmpty {
                map[tab] = agents.removeFirst()
            }
        }
        var t = Self.remapped(preset, map) { id in GridItemID.isPanel(id) || GridItemID.isFile(id) }
        for s in projectSessions where t.group(of: s.id) == nil { t.add(s.id, to: t.groups.first?.id) }
        state.panes = t
    }

    /// The tiled centre with live session ids swapped for placeholders.
    var presetTree: PaneTree {
        var n = 0
        var map: [String: String] = [:]
        for tab in state.panes.allTabs where !GridItemID.isPanel(tab) && !GridItemID.isFile(tab) {
            n += 1
            let kind = app.session(tab)?.kind == .agent ? "agent:\(app.session(tab)?.agentID ?? "")" : "terminal"
            map[tab] = "new:\(kind):\(n)"
        }
        return Self.remapped(state.panes, map) { _ in true }
    }

    func saveAsPreset(name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        var l = state.layout
        l.presetName = nil
        let p = CustomPreset(id: "custom-\(UUID().uuidString.prefix(6))", name: clean, layout: l, panes: state.panes.isEmpty ? nil : presetTree)
        app.library.customPresets.append(p)
        state.layout.presetName = p.id
        app.toast(.success, "Saved preset “\(clean)”")
    }

    var activePresetName: String {
        guard let n = state.layout.presetName else { return "Custom" }
        if let b = BuiltinPreset(rawValue: n) { return b.label }
        return app.library.customPresets.first { $0.id == n }?.name ?? "Custom"
    }
}

extension WorkspaceStore {
    /// Agent layout: sessions on the left, Plan above Agent Files on the right,
    /// shells underneath. Only adds what's missing, so a user's own arrangement stays.
    func arrangeAgentGrid() {
        var t = state.panes
        let plan = GridItemID.panel(.plan), files = GridItemID.panel(.agentFiles)
        for s in projectSessions where s.kind == .agent && t.group(of: s.id) == nil { t.add(s.id) }
        let main = t.groups.first { g in g.tabs.contains { !GridItemID.isPanel($0) } }?.id ?? t.groups.first?.id
        if t.group(of: plan) == nil {
            t.add(plan, to: main)
            if let main, t.group(of: plan)?.tabs.count ?? 0 > 1 { t.split(plan, beside: main, edge: .right) }
        }
        if t.group(of: files) == nil, let pg = t.group(of: plan)?.id {
            t.add(files, to: pg)
            t.split(files, beside: pg, edge: .bottom)
        }
        let shells = projectSessions.filter { $0.kind != .agent && t.group(of: $0.id) == nil }
        if let first = shells.first, let main {
            t.add(first.id, to: main)
            t.split(first.id, beside: main, edge: .bottom)
            for s in shells.dropFirst() { t.add(s.id, to: t.group(of: first.id)?.id) }
        }
        if let s = projectSessions.last(where: { $0.kind == .agent }) { t.activate(s.id) }
        if t.groups.count > 1, case .split(let id, false, let children, _) = t.root, children.count == 2 {
            t.setWeights(split: id, [1.6, 1])
        }
        state.panes = t
    }

    /// Shows a panel as a tab in the centre grid instead of in a dock.
    func movePanelToGrid(_ k: PanelKind, group: String?) {
        if let p = state.layout.allPanels.first(where: { $0.kind == k }) { state.layout.hide(p.id) }
        state.panes.add(GridItemID.panel(k), to: group)
        state.layout.centre = .agents
    }

    /// Takes a panel out of the grid (when it's shown in a dock instead).
    func removePanelFromGrid(_ k: PanelKind) {
        state.panes.remove(GridItemID.panel(k))
    }
}

/// A tab closed in the tiled centre, enough to bring it back.
struct ClosedTab {
    var id: String
    var group: String?
    var index: Int
    var session: SessionDescriptor?
}

extension WorkspaceStore {
    /// Closes tabs of any kind from the tiled centre and remembers them for ⇧⌘T.
    func closeTabs(_ ids: [String]) {
        var sessions: [String] = []
        for id in ids {
            let g = state.panes.group(of: id)
            let index = g?.tabs.firstIndex(of: id) ?? 0
            if let path = GridItemID.filePath(id) {
                closedTabs.append(ClosedTab(id: id, group: g?.id, index: index))
                close(path)
            } else if GridItemID.kind(id) == .dataTab, let ref = GridItemID.panelInstance(id)?.resourceID.flatMap(GridItemID.dataTabRef) {
                // A table or console tab: ask before throwing away unsubmitted edits,
                // and stop what it's running.
                app.confirmDiscard(ref.id) { [weak self] in
                    guard let self else { return }
                    closedTabs.append(ClosedTab(id: id, group: g?.id, index: index))
                    state.panes.remove(id)
                    app.removeDataTab(ref.id)
                }
            } else if GridItemID.isPanel(id) {
                closedTabs.append(ClosedTab(id: id, group: g?.id, index: index))
                state.panes.remove(id)
            } else if let s = app.session(id) {
                closedTabs.append(ClosedTab(id: id, group: g?.id, index: index, session: SessionDescriptor(s)))
                sessions.append(id)
            } else {
                state.panes.remove(id)
            }
        }
        if closedTabs.count > 30 { closedTabs.removeFirst(closedTabs.count - 30) }
        if !sessions.isEmpty { app.closeSessions(sessions) }
    }

    /// ⇧⌘T: reopens the last closed tab where it was. Shells start again in
    /// their folder; agents resume their conversation when they can.
    func reopenClosedTab() {
        guard let c = closedTabs.popLast() else { app.toast(.info, "No closed tabs to reopen"); return }
        var id = c.id
        if c.session != nil, app.session(c.id) != nil {
            // The close was cancelled (a process was running), so the session is still here.
            state.layout.centre = .agents
            state.panes.add(c.id, to: c.group.flatMap { state.panes.group($0)?.id }, at: c.index)
            return
        }
        if let d = c.session {
            if d.kind == .agent, let a = app.agent(d.agentID) ?? app.enabledAgents.first,
               let s = app.newAgentSession(project: projectID, agent: a, resume: d.externalID, attach: false) {
                id = s.id
            } else if d.kind != .agent {
                id = app.newTerminal(project: projectID, host: d.hostID, title: d.title, kind: d.kind, cwd: d.cwd, attach: false).id
            } else {
                return
            }
            app.renameSession(id, to: d.title)
        } else if let path = GridItemID.filePath(id), !state.openFiles.contains(path) {
            state.openFiles.append(path)
        }
        state.layout.centre = .agents
        state.panes.add(id, to: c.group.flatMap { state.panes.group($0)?.id }, at: c.index)
    }
}

// MARK: - Tiled centre keyboard actions

extension WorkspaceStore {
    private var focusedPane: TabGroup? {
        state.panes.focusedGroup.flatMap { state.panes.group($0) } ?? state.panes.groups.first
    }

    /// ⌘D / ⇧⌘D: a new terminal in a new pane beside the focused one.
    func splitActivePane(vertical: Bool) {
        let s = app.newTerminal(project: projectID, attach: false)
        state.layout.centre = .agents
        guard let g = focusedPane?.id else { state.panes.add(s.id); return }
        state.panes.splitNew(s.id, beside: g, edge: vertical ? .bottom : .right)
    }

    /// ⌥⌘ arrows: focus the neighbouring pane.
    func focusPane(_ edge: PaneEdge) {
        guard let g = focusedPane?.id, let n = state.panes.neighbour(of: g, edge), let p = state.panes.group(n) else { return }
        state.panes.focusedGroup = n
        if let a = p.active ?? p.tabs.first, app.session(a) != nil {
            app.focusedSessionID = a
            TerminalRegistry.shared.focus(a)
        }
    }

    /// ⌃⇧ arrows: move the active tab into the neighbouring pane.
    func moveTabToNeighbour(_ edge: PaneEdge) {
        guard let g = focusedPane, let tab = g.active ?? g.tabs.first, let n = state.panes.neighbour(of: g.id, edge) else { return }
        state.panes.move(tab, to: n)
    }

    /// Close Tab (⌘W) in the tiled centre.
    func closeActiveTab() {
        guard let g = focusedPane, let tab = g.active ?? g.tabs.last else { return }
        closeTabs([tab])
    }

    func closeFocusedPane() {
        guard let g = focusedPane else { return }
        closeTabs(g.tabs)
    }

    func moveActiveTabToNewPane() {
        guard let g = focusedPane, g.tabs.count > 1, let tab = g.active else { return }
        state.panes.split(tab, beside: g.id, edge: .right)
    }

    func toggleMaximizePane() {
        guard let g = focusedPane else { return }
        state.panes.toggleMaximized(g.id)
    }
}

// MARK: - Editing project files

extension WorkspaceStore {
    /// The file a ⌘S should save: the focused tile's file tab, else the editor's active file.
    var activeEditedFile: String? {
        if let g = state.panes.focusedGroup.flatMap({ state.panes.group($0) }),
           let path = (g.active ?? g.tabs.first).flatMap(GridItemID.filePath) { return path }
        return state.activeFile
    }

    func isDirty(_ path: String) -> Bool { drafts[path] != nil }

    /// Writes a draft to disk. Sample projects are read-only.
    func save(_ path: String) {
        guard let text = drafts[path] else { return }
        guard let p = project, !p.isSample else { app.toast(.info, "Sample files can't be saved"); return }
        let url = p.url.appendingPathComponent(path)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            drafts[path] = nil
            contents[path] = .text(text)
            app.refreshGit(projectID)
        } catch {
            app.toast(.error, "Couldn't save \((path as NSString).lastPathComponent)", detail: error.localizedDescription)
        }
    }

    func saveAll() { drafts.keys.forEach(save) }
}
