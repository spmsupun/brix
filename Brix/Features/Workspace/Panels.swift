import SwiftUI
import AppKit

/// Routes a panel instance to its view.
struct PanelContent: View {
    let ws: WorkspaceStore
    let panel: PanelInstance

    var body: some View {
        switch panel.kind {
        case .explorer: ExplorerPanel(ws: ws)
        case .sourceControl: SourceControlPanel(ws: ws)
        case .terminal: TerminalPanel(ws: ws, panel: panel)
        case .agent: AgentPanel(ws: ws, panel: panel)
        case .inspector: InspectorPanel(ws: ws)
        case .connections: ConnectionsPanel(ws: ws)
        case .docker: DockerPanel(ws: ws)
        case .database: DatabasePanelView(ws: ws, panel: panel)
        case .serverShell: ServerShellPanel(ws: ws, panel: panel)
        case .logs: LogsPanel(ws: ws, panel: panel)
        case .notes: NotesPanel(ws: ws)
        case .browser: BrowserPanel(ws: ws, panel: panel)
        case .plan: PlanPanel(ws: ws)
        case .agentFiles: AgentFilesPanel(ws: ws)
        case .remoteFiles:
            if let h = panel.resourceID { RemoteFilesView(hostID: h) } else { EmptyState(symbol: "externaldrive", message: "No host chosen.") }
        case .dataTab: DataTabTile(ws: ws, key: panel.resourceID ?? "")
        case .record: RecordPanel(ws: ws)
        }
    }
}

// MARK: - Terminal

struct TerminalPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    let panel: PanelInstance
    @State private var hoveredTab: String?

    private var sessions: [TerminalSession] {
        ws.projectSessions.filter { $0.hostID == nil || ws.state.panelSession.values.contains($0.id) }
    }
    private var selected: String? {
        let id = ws.state.panelSession[panel.id]
        return id.flatMap { store.session($0) != nil ? $0 : nil } ?? sessions.first?.id
    }
    private var splitID: String? {
        ws.state.panelSession[panel.id + ":split"].flatMap { store.session($0) != nil ? $0 : nil }
    }

    var body: some View {
        PanelChrome(title: panel.title ?? "Terminal", dark: true) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 4) {
                    HStack(alignment: .bottom, spacing: 0) { ForEach(sessions) { s in sessionTab(s) } }.tabStrip()
                    IconButton(symbol: "plus", label: "New terminal", shortcut: "⌘T", iconSize: 11) {
                        let s = store.newTerminal(project: ws.projectID, attach: false)
                        ws.state.panelSession[panel.id] = s.id
                    }
                    .padding(.bottom, 3)
                }
                .padding(.leading, 8)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .scrollClipDisabled()
            .frame(maxHeight: .infinity)
            Spacer(minLength: 0)
            IconButton(symbol: "rectangle.split.2x1", label: "Split terminal", shortcut: "⌘D", iconSize: 12.5, active: splitID != nil) { toggleSplit() }
            IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Maximize terminal", iconSize: 11.5) {
                if let s = selected { ws.focus(session: s); ws.layout.centre = .agents; moveToGrid(s) }
            }
        } content: {
            if let sel = selected {
                HStack(spacing: 0) {
                    TerminalSurface(sessionID: sel)
                    if let split = splitID, split != sel {
                        Rectangle().fill(Theme.divider).frame(width: 1)
                        TerminalSurface(sessionID: split)
                            .frame(width: nil)
                            .frame(maxWidth: .infinity)
                    }
                }
                .contextMenu { sessionMenu(sel) }
            } else {
                EmptyState(symbol: "terminal", message: "No terminals in this project.", actionTitle: "New Terminal") {
                    let s = store.newTerminal(project: ws.projectID, attach: false)
                    ws.state.panelSession[panel.id] = s.id
                }
                .background(Theme.terminal)
            }
        }
    }

    /// Same Chrome-style tabs as the tiled centre.
    private func sessionTab(_ s: TerminalSession) -> some View {
        let on = s.id == selected
        return PaneTabLabel(tabID: s.id, selected: on, hovering: hoveredTab == s.id, onClose: { store.closeSession(s.id) })
            .frame(width: 170, height: on ? TileMetrics.activeTab : TileMetrics.tab)
            .background { ChromeTabBackground(selected: on, hovering: hoveredTab == s.id, fill: Theme.terminal) }
            .zIndex(on ? 1 : 0)
            .contentShape(Rectangle())
            .onHover { hoveredTab = $0 ? s.id : (hoveredTab == s.id ? nil : hoveredTab) }
            .onTapGesture { ws.state.panelSession[panel.id] = s.id }
        .reorderableTab(s.id, order: sessions.map(\.id)) { store.moveSession($0, onto: $1) }
        .onMiddleClick { store.closeSession(s.id) }
        .contextMenu { sessionMenu(s.id) }
        .accessibilityLabel("\(s.title), \(s.state.label)")
    }

    @ViewBuilder private func sessionMenu(_ id: String) -> some View {
        Button("Rename…") { store.sheet = .renameSession(id) }
        Button("Clear") { store.clearSession(id) }
        Button("Interrupt (⌃C)") { store.interruptSession(id) }
        Button("Show in Inspector") { store.inspector = .session(id) }
        Button("Copy Directory") { store.copyToPasteboard(store.session(id)?.cwd ?? "", label: "directory") }
        Divider()
        Button("Close", role: .destructive) { store.closeSession(id) }
    }

    private func toggleSplit() {
        if splitID != nil {
            ws.state.panelSession[panel.id + ":split"] = nil
        } else {
            let other = sessions.first { $0.id != selected }?.id ?? store.newTerminal(project: ws.projectID, attach: false).id
            ws.state.panelSession[panel.id + ":split"] = other
        }
    }

    private func moveToGrid(_ id: String) {
        ws.state.panes.add(id)
    }
}

/// A docked agent session.
struct AgentPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    let panel: PanelInstance

    private var sessionID: String? {
        if let id = ws.state.panelSession[panel.id], store.session(id) != nil { return id }
        return nil
    }

    var body: some View {
        PanelChrome(title: panel.title ?? sessionID.flatMap(store.session)?.title ?? "Agent", dark: true) {
            Spacer(minLength: 0)
        } content: {
            if let id = sessionID {
                AgentPane(ws: ws, sessionID: id, compact: true)
            } else {
                EmptyState(symbol: "sparkle", message: "Start an agent session in this project.", actionTitle: "New Session") {
                    store.startAgent(project: ws.projectID) { s in ws.state.panelSession[panel.id] = s.id }
                }
                .background(Theme.terminal)
            }
        }
    }
}

// MARK: - Server shell

struct ServerShellPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    let panel: PanelInstance

    private var host: SSHHost? { panel.resourceID.flatMap(store.host) }
    private var sessionID: String? {
        if let id = ws.state.panelSession[panel.id], store.session(id) != nil { return id }
        return nil
    }

    var body: some View {
        PanelChrome(title: "Server Shell", dark: true) {
            if let h = host {
                HStack(spacing: 5) {
                    Image(systemName: "globe").font(.system(size: 9.5))
                    Text("\(h.user)@\(h.name)").font(Typo.ui(11.5)).lineLimit(1)
                    TagPill(tag: h.tag, size: 8.5)
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white(0.08)))
            }
            Spacer(minLength: 0)
            hostPicker
        } content: {
            if let id = sessionID {
                TerminalSurface(sessionID: id)
                    .overlay(RoundedRectangle(cornerRadius: 0).strokeBorder(host?.tag.color.opacity(0.0) ?? .clear))
            } else if let h = host {
                VStack(spacing: 10) {
                    EmptyState(symbol: "globe", message: "\(h.name) · \(h.address)", actionTitle: store.hostStatus[h.id] == .connecting ? "Connecting…" : "Connect") {
                        connect(h)
                    }
                }
                .background(Theme.terminal)
            } else {
                EmptyState(symbol: "globe", message: store.linkedHosts(ws.projectID).isEmpty ? "No servers linked to this project." : "Pick a linked server.",
                           actionTitle: store.linkedHosts(ws.projectID).isEmpty ? "Link a server" : nil) {
                    store.route = .projectSettings(ws.projectID)
                }
                .background(Theme.terminal)
            }
        }
    }

    private var hostPicker: some View {
        MenuButton(items: {
            store.linkedHosts(ws.projectID).map { h in
                MenuSpec(title: h.name, checked: h.id == panel.resourceID) {
                    ws.layout.bind(panel.id, resource: h.id)
                    ws.state.panelSession[panel.id] = nil
                }
            } + [.separator, MenuSpec(title: "Link a server…") { store.route = .projectSettings(ws.projectID) }]
        }) {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3).frame(width: 22, height: 22)
        }
        .accessibilityLabel("Choose server")
    }

    private func connect(_ h: SSHHost) {
        store.guardProduction(h.tag, name: h.name, verb: "Connect to") {
            let s = store.newTerminal(project: ws.projectID, host: h.id, kind: .server, attach: false)
            ws.state.panelSession[panel.id] = s.id
            store.hostStatus[h.id] = .connected
        }
    }
}

// MARK: - Connections

struct ConnectionsPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore

    var body: some View {
        let dbs = store.linkedDatabases(ws.projectID)
        let hosts = store.linkedHosts(ws.projectID)
        PanelChrome(title: "Connections", count: "\(dbs.count + hosts.count)") {
            Spacer(minLength: 0)
            IconButton(symbol: "plus", label: "Link a resource", iconSize: 11) { store.route = .projectSettings(ws.projectID) }
        } content: {
            if dbs.isEmpty && hosts.isEmpty {
                EmptyState(symbol: "link", message: "No servers or databases linked yet.", actionTitle: "Link a server") { store.route = .projectSettings(ws.projectID) }
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(dbs) { d in
                            let status = store.dbStatus[d.id] ?? .disconnected
                            row(icon: AnyView(DatabaseIcon(db: d, size: 22)), name: d.name, tag: d.tag, dot: status.color, label: status.label) {
                                let p = ws.layout.add(.database, to: .bottom, resource: d.id)
                                ws.select(panel: p.id)
                            }
                            .contextMenu { DatabaseContextMenu(db: d) }
                        }
                        ForEach(hosts) { h in
                            let status = store.hostStatus[h.id] ?? .disconnected
                            row(icon: AnyView(ServerOSIcon(host: h, size: 22)), name: h.name, tag: h.tag, dot: status.color, label: status.label) {
                                store.connect(h.id, project: ws.projectID)
                            }
                            .contextMenu { HostContextMenu(host: h) }
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    private func row(icon: AnyView, name: String, tag: EnvTag, dot: Color, label: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 9) {
                icon
                Text(name).font(Typo.row).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                TagPill(tag: tag, size: 9, filled: false)
                StatusDot(color: dot, size: 7)
            }
            .padding(.horizontal, 6)
            .frame(height: 31)
            .rowBackground(selected: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(tag.name), \(label)")
        .tip("Open \(name)")
    }
}

// MARK: - Docker

struct DockerPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore

    var body: some View {
        let items = store.linkedDocker(ws.projectID)
        let up = items.filter { $0.state == .running }.count
        PanelChrome(title: "Docker", count: "\(up) up", countColor: Theme.green) {
            Spacer(minLength: 0)
            IconButton(symbol: "arrow.clockwise", label: "Refresh", iconSize: 11) { Task { await store.refreshDocker() } }
        } content: {
            if items.isEmpty {
                EmptyState(symbol: "shippingbox", message: "No containers linked to this project.", actionTitle: "Link a container") { store.route = .projectSettings(ws.projectID) }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { c in DockerRow(container: c, projectID: ws.projectID) }
                    }
                    .padding(6)
                }
            }
        }
    }
}

struct DockerRow: View {
    @Environment(AppStore.self) private var store
    let container: DockerTarget
    var projectID: ProjectID?

    var body: some View {
        let c = container
        let busy = store.dockerBusy.contains(c.id)
        let hostName = c.hostID.flatMap(store.host)?.name ?? "local"
        HStack(spacing: 10) {
            StatusDot(color: c.state.color, size: 7, ring: c.state == .running)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text)
                Text(c.state == .running ? "\(c.image) · \(c.ports.isEmpty ? "no ports" : c.ports) · \(hostName)" : "\(hostName) · \(c.uptimeText.lowercased())")
                    .font(Typo.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.small).frame(width: 24, height: 24)
            } else {
                smallAction(c.state == .running ? "stop.fill" : "play.fill", c.state == .running ? "Stop \(c.name)" : "Start \(c.name)") {
                    store.dockerAction(c.state == .running ? .stop : .start, c.id)
                }
                smallAction("text.alignleft", "Logs for \(c.name)") { store.openDockerLogs(c.id, project: projectID) }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .rowBackground(selected: false, radius: 8)
        .contextMenu {
            Button("Start") { store.dockerAction(.start, c.id) }.disabled(c.state == .running)
            Button("Stop") { store.dockerAction(.stop, c.id) }.disabled(c.state != .running)
            Button("Restart") { store.dockerAction(.restart, c.id) }
            Divider()
            Button("Logs") { store.openDockerLogs(c.id, project: projectID) }
            Button("Shell") { store.openDockerShell(c.id, project: projectID) }.disabled(c.state != .running)
        }
    }

    private func smallAction(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.body)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white(0.05)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .tip(label)
    }
}

// MARK: - Notes

struct NotesPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore

    var body: some View {
        PanelChrome(title: "Notes") {
            Spacer(minLength: 0)
            Text("Saved with the project").font(Typo.ui(10.5)).foregroundStyle(Theme.meta)
        } content: {
            TextEditor(text: Binding(
                get: { ws.project?.notes ?? "" },
                set: { v in if var p = ws.project { p.notes = v; store.updateProject(p) } }))
                .font(Typo.ui(12.5))
                .scrollContentBackground(.hidden)
                .padding(8)
                .accessibilityLabel("Project notes")
        }
    }
}

// MARK: - Logs

struct LogsPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    let panel: PanelInstance
    @State private var path = "/var/log/system.log"
    @State private var hostID: ResourceID? = nil

    private var sessionID: String? {
        if let id = ws.state.panelSession[panel.id], store.session(id) != nil { return id }
        return nil
    }

    var body: some View {
        PanelChrome(title: panel.title ?? "Logs", dark: true) {
            Spacer(minLength: 0)
            if let id = sessionID {
                IconButton(symbol: "trash", label: "Clear", iconSize: 11) { store.clearSession(id) }
                IconButton(symbol: "stop.fill", label: "Stop tailing", iconSize: 10) {
                    store.closeSession(id, confirmRunning: false)
                    ws.state.panelSession[panel.id] = nil
                }
            }
        } content: {
            if let id = sessionID {
                TerminalSurface(sessionID: id, showInput: false)
            } else {
                setup.background(Theme.terminal)
            }
        }
        .onAppear(perform: autoStart)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tail a log file").font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text)
            HStack(spacing: 6) {
                Picker("", selection: $hostID) {
                    Text("This Mac").tag(ResourceID?.none)
                    ForEach(store.linkedHosts(ws.projectID)) { h in Text(h.name).tag(ResourceID?.some(h.id)) }
                }
                .labelsHidden()
                .frame(width: 160)
                .accessibilityLabel("Where")
                BXTextField(label: "", text: $path, placeholder: "/var/log/app.log", mono: true)
            }
            AccentButton(title: "Start tailing", height: 28) { start(path: path, host: hostID) }
                .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func autoStart() {
        guard sessionID == nil, let res = panel.resourceID else { return }
        if res.hasPrefix("docker:") {
            let id = String(res.dropFirst("docker:".count))
            guard let c = store.dockerTarget(id) else { return }
            let host = c.hostID.flatMap(store.host)
            let cmd = (c.isSample ? store.services.mock.docker : store.services.live.docker).followLogsCommand(c, host: host)
            let s = store.newTerminal(project: c.isSample ? ws.projectID : nil, title: "\(c.name) logs", kind: .logs, command: cmd, attach: false)
            ws.state.panelSession[panel.id] = s.id
            if c.isSample {
                Task {
                    let lines = (try? await store.services.mock.docker.logs(c, host: host)) ?? []
                    if let i = store.sessions.firstIndex(where: { $0.id == s.id }) {
                        store.sessions[i].lines += lines.map { TermLine($0, Theme.body) }
                    }
                }
            }
        }
    }

    private func start(path: String, host: ResourceID?) {
        let cmd = "tail -n 200 -F \(ProcessRunner.shellQuote(path))"
        let h = host.flatMap(store.host)
        let go = {
            let s = store.newTerminal(project: ws.projectID, host: host, title: (path as NSString).lastPathComponent, kind: .logs, command: cmd, attach: false)
            ws.state.panelSession[panel.id] = s.id
            ws.layout.rename(panel.id, to: (path as NSString).lastPathComponent)
            if s.isSampleSession, let i = store.sessions.firstIndex(where: { $0.id == s.id }) {
                store.sessions[i].lines += MockData.apiLogTranscript.dropFirst()
            }
        }
        if let h { store.guardProduction(h.tag, name: h.name, verb: "Connect to", action: go) } else { go() }
    }
}

// MARK: - Browser preview (phase 2)

struct BrowserPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    let panel: PanelInstance
    @State private var url = "http://localhost:3000"

    var body: some View {
        PanelChrome(title: "Browser Preview") {
            Spacer(minLength: 0)
        } content: {
            VStack(spacing: 10) {
                Image(systemName: "safari").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.text3)
                Text("An embedded preview is planned. For now, open the dev server in your browser.")
                    .font(Typo.ui(12)).foregroundStyle(Theme.text3).multilineTextAlignment(.center).frame(maxWidth: 260)
                BXTextField(label: "", text: $url, mono: true).frame(maxWidth: 260)
                SubtleButton(title: "Open in Browser", symbol: "arrow.up.forward.square", height: 26) {
                    if let u = URL(string: url), u.scheme?.hasPrefix("http") == true {
                        NSWorkspace.shared.open(u)
                    } else {
                        store.toast(.error, "Enter an http or https URL")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
