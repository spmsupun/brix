import SwiftUI

/// Menu bar commands. Every shortcut in the app is listed here.
struct BrixCommands: Commands {
    let store: AppStore

    private var ws: WorkspaceStore? { store.currentWorkspace }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Terminal") { newTerminal() }.keyboardShortcut("t", modifiers: .command)
            Button("New Agent Session…") { newAgent() }.keyboardShortcut("t", modifiers: [.command, .option])
            Button("Reopen Closed Tab") { ws?.reopenClosedTab() }.keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(ws?.closedTabs.isEmpty ?? true)
            // On the Databases screen ⌘O goes to a table or console instead.
            Button("Open Project…") { if store.route == .databases { store.dataWorkspace.goTo = true } else { store.sheet = .addProject } }
                .keyboardShortcut("o", modifiers: .command)
            Button("Connect to Server…") { store.route = .ssh }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Add SSH Host…") { store.sheet = .editHost(nil) }
            Button("Add Database…") { store.sheet = .editDatabase(nil) }
            Button("Add Docker Target…") { store.sheet = .addDocker }
            Divider()
            Button("Save") { if let ws, let f = ws.activeEditedFile { ws.save(f) } }.keyboardShortcut("s", modifiers: .command)
                .disabled(!(ws.flatMap { w in w.activeEditedFile.map(w.isDirty) } ?? false))
            Button("Save All") { ws?.saveAll() }.keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            Button("Close Tab") { closeTab() }.keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button("Command Palette") { store.paletteOpen.toggle() }.keyboardShortcut("k", modifiers: .command)
            Button("Go to File…") { goToFile() }.keyboardShortcut("p", modifiers: .command)
            Divider()
            Button("Toggle Sidebar") { store.settings.sidebarHidden.toggle() }.keyboardShortcut("s", modifiers: [.control, .command])
            Button("Toggle Inspector") { toggle(.inspector) }.keyboardShortcut("0", modifiers: [.option, .command])
            Divider()
            Button("Explorer") { toggle(.explorer) }.keyboardShortcut("e", modifiers: [.option, .command])
            Button("Source Control") { toggle(.sourceControl) }.keyboardShortcut("g", modifiers: [.option, .command])
            Button("Terminal") { toggle(.terminal) }.keyboardShortcut("j", modifiers: [.option, .command])
            Button("Inspector Panel") { toggle(.inspector) }.keyboardShortcut("i", modifiers: [.option, .command])
            Button("Connections") { toggle(.connections) }.keyboardShortcut("l", modifiers: [.option, .command])
            Divider()
            Button("Split Right") { split(vertical: false) }.keyboardShortcut("d", modifiers: .command)
            Button("Split Down") { split(vertical: true) }.keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandMenu("Panes") {
            Button("Split into 2 × 2") { split2x2() }
            Button("Move Tab to New Pane") { tiled { $0.moveActiveTabToNewPane() } }.keyboardShortcut(.rightArrow, modifiers: [.control, .option, .command])
            Button("Equalize Sizes") { tiled { $0.state.panes.equalize() } }.keyboardShortcut("=", modifiers: [.control, .command])
            Button("Maximize Pane") { tiled { $0.toggleMaximizePane() } }.keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Close Pane") { tiled { $0.closeFocusedPane() } }.keyboardShortcut("w", modifiers: [.option, .command])
            Divider()
            Button("Focus Pane Left") { tiled { $0.focusPane(.left) } }.keyboardShortcut(.leftArrow, modifiers: [.option, .command])
            Button("Focus Pane Right") { tiled { $0.focusPane(.right) } }.keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            Button("Focus Pane Above") { tiled { $0.focusPane(.top) } }.keyboardShortcut(.upArrow, modifiers: [.option, .command])
            Button("Focus Pane Below") { tiled { $0.focusPane(.bottom) } }.keyboardShortcut(.downArrow, modifiers: [.option, .command])
            Divider()
            Button("Move Tab Left") { tiled { $0.moveTabToNeighbour(.left) } }.keyboardShortcut(.leftArrow, modifiers: [.control, .shift])
            Button("Move Tab Right") { tiled { $0.moveTabToNeighbour(.right) } }.keyboardShortcut(.rightArrow, modifiers: [.control, .shift])
            Button("Move Tab Up") { tiled { $0.moveTabToNeighbour(.top) } }.keyboardShortcut(.upArrow, modifiers: [.control, .shift])
            Button("Move Tab Down") { tiled { $0.moveTabToNeighbour(.bottom) } }.keyboardShortcut(.downArrow, modifiers: [.control, .shift])
            Button("Next Tab") { ws?.cycleTab(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { ws?.cycleTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
        }

        CommandMenu("Layout") {
            ForEach(Array(BuiltinPreset.shown.enumerated()), id: \.element) { i, p in
                Button("\(p.label) Layout") { ws?.apply(p) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.control, .command])
            }
            Divider()
            Button("Save Layout as Preset…") { if let id = store.currentProjectID { store.sheet = .savePreset(id) } }
            Divider()
            Button("Move Panel Left") { movePanel(.left) }.keyboardShortcut(.leftArrow, modifiers: [.control, .option])
            Button("Move Panel Right") { movePanel(.right) }.keyboardShortcut(.rightArrow, modifiers: [.control, .option])
            Button("Move Panel to Bottom") { movePanel(.bottom) }.keyboardShortcut(.downArrow, modifiers: [.control, .option])
            Button("Float Panel") { floatPanel() }.keyboardShortcut("f", modifiers: [.control, .option])
            Divider()
            Button("Move Sidebar to \(store.settings.sidebarPosition == .left ? "Right" : "Left")") {
                store.settings.sidebarPosition = store.settings.sidebarPosition == .left ? .right : .left
            }
            Button("Sidebar Style: \(store.settings.sidebarStyle == .full ? "Rail" : "Full")") {
                store.settings.sidebarStyle = store.settings.sidebarStyle == .full ? .rail : .full
            }
        }

        CommandMenu("Go") {
            ForEach(Array(Route.numbered.enumerated()), id: \.offset) { i, r in
                Button(r.title) { store.go(r) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Divider()
            Button("Recent Files") { store.go(.recentFiles) }
            Button("Servers") { store.go(.servers) }
            Button("Database Connections") { store.go(.dbConnections) }
            Divider()
            Button("Previous Project") { store.switchProject(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Project") { store.switchProject(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Button("Performance Log") {
                try? FileManager.default.createDirectory(at: PerfMonitor.directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(PerfMonitor.directory)
            }
            Divider()
            Button("Load Sample Workspace") { store.loadSampleWorkspace() }
            Button("Remove Sample Workspace") { store.removeSampleWorkspace() }
                .disabled(!store.library.projects.contains(where: \.isSample))
        }
    }

    private func newTerminal() {
        if let id = store.currentProjectID {
            store.newTerminal(project: id)
        } else {
            let p = store.sortedProjects.first
            store.newTerminal(project: p?.id, attach: false)
            store.route = .terminals
        }
    }

    private func newAgent() {
        store.startAgent(project: nil)
    }

    private func closeTab() {
        if store.route == .databases, let id = store.dataWorkspace.active {
            store.closeDataTab(id)
            return
        }
        guard let ws else { return }
        if ws.state.layout.centre == .agents { ws.closeActiveTab() }
    }

    private func goToFile() {
        store.paletteScopeToProject = true
        store.paletteOpen = true
    }

    private func toggle(_ kind: PanelKind) {
        guard let ws else {
            if kind == .inspector { store.toast(.info, "Open a project to use the inspector") }
            return
        }
        ws.layout.toggle(kind)
    }

    private func split(vertical: Bool) {
        guard let ws else { return }
        ws.splitActivePane(vertical: vertical)
    }

    /// Runs a pane action when a project's tiled centre is showing.
    private func tiled(_ action: (WorkspaceStore) -> Void) {
        guard let ws, ws.layout.centre == .agents, !ws.state.panes.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.18)) { action(ws) }
    }

    private func split2x2() {
        tiled { ws in
            guard let g = ws.state.panes.focusedGroup ?? ws.state.panes.groups.first?.id else { return }
            let new = (0..<3).map { _ in store.newTerminal(project: ws.projectID, attach: false).id }
            ws.state.panes.split2x2(g, with: new)
        }
    }

    private func movePanel(_ side: DockSide) {
        guard let ws, let id = ws.panelSelection ?? ws.layout.allPanels.first?.id else { return }
        ws.layout.move(id, to: side)
    }

    private func floatPanel() {
        guard let ws, let id = ws.panelSelection ?? ws.layout.allPanels.first?.id else { return }
        ws.layout.float(id)
    }
}
