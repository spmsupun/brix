import SwiftUI

extension View {
    /// Applies the user's appearance settings as environment values.
    func themed(_ s: AppSettings) -> some View {
        self
            .environment(\.accent, s.accent.color)
            .environment(\.islandGap, s.spacing.gap)
            .environment(\.rowExtra, s.density.extra)
            .tint(s.accent.color)
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            BrixToolbar()
            HStack(spacing: store.settings.spacing.gap) {
                if store.settings.sidebarPosition == .left { sidebar }
                // minWidth 0 + clip: a screen that can't shrink further is cut at its
                // own edge instead of pushing the sidebar out of the window.
                content
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .layoutPriority(-1)
                if store.settings.sidebarPosition == .right { sidebar }
            }
            .padding(.horizontal, 6)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                let narrow = w < Metrics.autoRailWidth
                if narrow != store.windowNarrow {
                    store.windowNarrow = narrow
                    if !narrow { store.sidebarForcedFull = false }
                }
            }
            StatusBar()
        }
        .background(Theme.base)
        .ignoresSafeArea(.container, edges: .top)
        .coordinateSpace(name: "root")
        .overlay(alignment: .bottomTrailing) { ToastStack().padding(.trailing, 18).padding(.bottom, 38) }
        .overlay { PopoverHost() }
        .overlay {
            if store.paletteOpen {
                CommandPaletteView()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: store.paletteOpen)
        .sheet(item: $store.sheet) { sheet in
            SheetRouter(sheet: sheet)
                .environment(store)
                .themed(store.settings)
        }
        .alert(store.confirmation?.title ?? "", isPresented: Binding(get: { store.confirmation != nil && store.confirmation?.typeToConfirm == nil },
                                                                      set: { if !$0, store.confirmation?.typeToConfirm == nil { store.confirmation = nil } }),
               presenting: store.confirmation) { c in
            Button(c.confirmTitle, role: c.destructive ? .destructive : nil) { c.action() }
            Button("Cancel", role: .cancel) { c.onCancel?() }
        } message: { c in
            Text(c.message)
        }
        .sheet(item: Binding(get: { store.confirmation?.typeToConfirm == nil ? nil : store.confirmation }, set: { if $0 == nil { store.confirmation = nil } })) { c in
            TypeToConfirmSheet(confirmation: c) { store.confirmation = nil }
        }
        .background(WindowChrome())
        .focusEffectDisabled()
        .themed(store.settings)
        .onChange(of: store.settings.terminalFontSize) { _, v in TerminalRegistry.shared.applyTheme(fontSize: v, accent: store.settings.accent) }
        .onChange(of: store.settings.accent) { _, a in TerminalRegistry.shared.applyTheme(fontSize: store.settings.terminalFontSize, accent: a) }
        .onChange(of: store.settings.badgeDock) { _, _ in store.updateDockBadge() }
    }

    /// Rail when chosen, or automatically on narrow windows unless expanded by hand.
    private var useRail: Bool { store.settings.sidebarStyle == .rail || (store.windowNarrow && !store.sidebarForcedFull) }

    @ViewBuilder private var sidebar: some View {
        if !store.settings.sidebarHidden {
            if useRail {
                SidebarView(rail: true).frame(width: Metrics.sidebarRail)
            } else {
                SidebarView(rail: false)
                    .frame(width: store.settings.sidebarWidth)
                    .overlay(alignment: store.settings.sidebarPosition == .left ? .trailing : .leading) {
                        ResizeHandle(axis: .horizontal) { delta in
                            let d = store.settings.sidebarPosition == .left ? delta : -delta
                            store.settings.sidebarWidth = min(max(store.settings.sidebarWidth + d, Metrics.sidebarRange.lowerBound), Metrics.sidebarRange.upperBound)
                        }
                        .offset(x: store.settings.sidebarPosition == .left ? 4 : -4)
                    }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.route {
        case .overview: OverviewView()
        case .projects: ProjectsView()
        case .recentFiles: RecentFilesView()
        case .terminals: TerminalsView()
        case .git: GitGlobalView()
        case .databases: DataWorkspaceView()
        case .docker: DockerView()
        case .ssh: SSHView()
        case .servers: ServersView()
        case .dbConnections: DBConnectionsView()
        case .customize: CustomizeView(inSettingsWindow: false)
        case .workspace(let id):
            if store.project(id) != nil {
                WorkspaceView(ws: store.workspace(for: id)).id(id)
            } else {
                EmptyState(symbol: "questionmark.folder", message: "This project was removed.", actionTitle: "All projects") { store.go(.projects) }
                    .island()
            }
        case .remoteFiles(let h): RemoteFilesView(hostID: h).id(h)
        case .projectHome(let id):
            if store.project(id) != nil {
                ProjectHomeView(projectID: id).id(id)
            } else {
                EmptyState(symbol: "questionmark.folder", message: "This project was removed.", actionTitle: "All projects") { store.go(.projects) }
                    .island()
            }
        case .projectSettings(let id):
            if store.project(id) != nil {
                ProjectSettingsView(projectID: id).id(id)
            } else {
                EmptyState(symbol: "questionmark.folder", message: "This project was removed.", actionTitle: "All projects") { store.go(.projects) }
                    .island()
            }
        }
    }
}

struct SheetRouter: View {
    let sheet: ActiveSheet
    var body: some View {
        switch sheet {
        case .addProject: AddProjectSheet()
        case .editHost(let h): HostEditorSheet(existing: h)
        case .editDatabase(let d): DatabaseEditorSheet(existing: d)
        case .addDocker: AddDockerSheet()
        case .savePreset(let p): SavePresetSheet(projectID: p)
        case .newFile(let p, let dir, let parent): NewFileSheet(projectID: p, isDirectory: dir, parent: parent)
        case .renameFile(let p, let path): RenameFileSheet(projectID: p, path: path)
        case .newBranch(let p): NewBranchSheet(projectID: p)
        case .renameSession(let s): RenameSessionSheet(sessionID: s)
        case .renamePanel(let p, let id): RenamePanelSheet(projectID: p, panelID: id)
        case .chooseAgent(let p): ChooseAgentSheet(projectID: p)
        case .importConnections: ImportSheet()
        case .editFile(let f): FileEditorSheet(file: f)
        case .editAgent(let a): AgentEditorSheet(existing: a)
        }
    }
}

// MARK: - Status bar

/// Agents on the left; last build, branch, plan usage, servers and containers on the right.
struct StatusBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 4) {
            agents
            Spacer(minLength: 8)
            right
        }
        .font(Typo.ui(11))
        .foregroundStyle(Theme.text2)
        .padding(.horizontal, 8)
        .frame(height: Metrics.statusBar)
        .lineLimit(1)
    }

    // MARK: Agents

    /// Working first, then waiting, then finished ones ready to review.
    private var chips: [TerminalSession] {
        let a = store.sessions.filter { $0.kind == .agent && ($0.state == .running || $0.state == .needsInput || ($0.state == .idle && !$0.task.isEmpty) || $0.state == .finished) }
        let rank: (TerminalSession) -> Int = { $0.state == .needsInput ? 0 : $0.unseen ? 1 : $0.state == .running ? 2 : 3 }
        return a.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    @ViewBuilder private var agents: some View {
        let c = chips
        if c.isEmpty {
            HStack(spacing: 6) {
                Circle().fill(Theme.disabled).frame(width: 6, height: 6)
                Text("No agents running")
            }
            .padding(.horizontal, 8).frame(height: 20)
        } else {
            ForEach(c.prefix(4)) { s in AgentChip(session: s) }
            if c.count > 4 {
                Button { store.route = .terminals } label: { Text("+\(c.count - 4)").padding(.horizontal, 8).frame(height: 20).background(RoundedRectangle(cornerRadius: 6).fill(Color.white(0.05))) }
                    .buttonStyle(.plain)
                    .help(c.dropFirst(4).map { store.displayTitle($0) }.joined(separator: "\n"))
            }
        }
    }

    // MARK: Right side

    @ViewBuilder private var right: some View {
        let p = store.currentProject
        if let b = store.lastBuild(p?.id) {
            segment(help: "\(b.task) \(b.ok ? "passed" : "failed") \(RelativeTime.ago(b.date)), took \(AppStore.duration(b.duration))", action: { store.route = .projectHome(b.projectID) }) {
                Image(systemName: b.ok ? "checkmark" : "xmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(b.ok ? Theme.green : Theme.red)
                Text("\(b.kind == .test ? "Tests" : "Build") \(AppStore.duration(b.duration))").foregroundStyle(Theme.body)
            }
        }
        if let p, let g = store.git[p.id], g.isRepo {
            segment(help: "\(g.branch): \(g.ahead) to push, \(g.behind) to pull, \(g.changedFileCount) changed", action: { store.route = .git }) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.violet)
                Text(g.branch).font(Typo.mono(11)).foregroundStyle(Theme.body)
                Text("↑\(g.ahead) ±\(g.changedFileCount)").foregroundStyle(Theme.text3)
            }
        }
        let providers = store.settings.agents.filter { $0.enabled && $0.showUsage && !(store.agentUsage[$0.id] ?? []).isEmpty }
        if !providers.isEmpty {
            divider
            ForEach(providers) { a in UsageSegment(agent: a, windows: store.agentUsage[a.id] ?? []) }
        }
        divider
        let online = store.library.hosts.filter { store.hostStatus[$0.id]?.isLive == true }.count
        segment(help: "\(online) of \(store.library.hosts.count) servers connected", action: { store.go(.ssh) }) {
            Image(systemName: "server.rack").font(.system(size: 9.5))
            Text("\(online)/\(store.library.hosts.count)").foregroundStyle(Theme.body)
        }
        if store.dockerVisible {
            let running = store.allDocker.filter { $0.state == .running }.count
            segment(help: "\(running) containers running", action: { store.go(.docker) }) {
                Image(systemName: "shippingbox").font(.system(size: 9.5))
                Text("\(running)").foregroundStyle(Theme.body)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white(0.08)).frame(width: 1, height: 14).padding(.horizontal, 4)
    }

    private func segment<C: View>(help: String, action: @escaping () -> Void, @ViewBuilder _ content: () -> C) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { content() }
                .padding(.horizontal, 8).frame(height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(StatusSegmentStyle())
        .help(help)
    }
}

private struct StatusSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StatusSegmentBody(configuration: configuration)
    }
    private struct StatusSegmentBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering || configuration.isPressed ? Theme.hover : .clear))
                .onHover { hovering = $0 }
        }
    }
}

/// One agent session: working (pulsing dot), waiting (amber chip) or done.
private struct AgentChip: View {
    @Environment(AppStore.self) private var store
    let session: TerminalSession

    var body: some View {
        let s = session
        let waiting = s.state == .needsInput, working = s.state == .running, fresh = s.unseen && !waiting && !working
        Button { store.reveal(session: s.id) } label: {
            HStack(spacing: 6) {
                if waiting {
                    Text("!").font(.system(size: 9, weight: .black)).foregroundStyle(Theme.amber)
                        .frame(width: 13, height: 13).background(Circle().fill(Color(hex: 0x09090B)))
                } else if working {
                    WorkingSpinner(size: 10)
                } else if fresh {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .black)).foregroundStyle(Theme.onAccent)
                        .frame(width: 13, height: 13).background(Circle().fill(Theme.green))
                } else {
                    Circle().fill(Theme.disabled).frame(width: 6, height: 6)
                }
                Text(Self.clip(store.displayTitle(s), 22)).fontWeight(.semibold).foregroundStyle(waiting ? Color(hex: 0x09090B) : Theme.text)
                Text(Self.clip(sub, 26)).foregroundStyle(waiting ? Color(hex: 0x09090B).opacity(0.7) : Theme.text3)
            }
            .fixedSize()
            .padding(.horizontal, 8).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(waiting ? Theme.amber : fresh ? Theme.green.opacity(0.18) : Color.white(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(fresh ? Theme.green.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(store.displayTitle(s)) in \(s.projectID.flatMap(store.project)?.name ?? "Terminals"): \(sub)")
        .accessibilityLabel("\(store.displayTitle(s)), \(sub)")
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    private var sub: String {
        switch session.state {
        case .needsInput: "Waiting for you"
        case .running: session.touched.last.map { "Editing \(($0.path as NSString).lastPathComponent)" } ?? "Working"
        default: session.unseen ? "Done · not opened yet" : "Done · ready to review"
        }
    }
}

/// One provider's plan usage: a mini bar per window, the percentage and the next reset.
private struct UsageSegment: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let agent: AgentConfig
    let windows: [UsageWindow]

    var body: some View {
        Button { store.showAgentSettings() } label: {
            HStack(spacing: 8) {
                AgentMark(agent: agent, size: 11)
                Text(agent.name.components(separatedBy: " ").first ?? agent.name).fontWeight(.semibold).foregroundStyle(Theme.text)
                ForEach(windows, id: \.label) { w in
                    HStack(spacing: 5) {
                        Text(w.label).foregroundStyle(Theme.text3)
                        Capsule().fill(Color.white(0.08)).frame(width: 34, height: 4)
                            .overlay(alignment: .leading) { Capsule().fill(color(w.percent)).frame(width: 34 * min(max(w.percent, 0), 100) / 100, height: 4) }
                        Text("\(Int(w.percent))%").font(Typo.mono(10.5)).foregroundStyle(Theme.body)
                    }
                }
                if let reset = windows.compactMap(\.resetsAt).filter({ $0 > Date() }).min() {
                    Text("resets \(Self.countdown(to: reset))").foregroundStyle(Theme.meta)
                }
            }
            .fixedSize()
            .padding(.horizontal, 8).frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(AgentUsageChips.tip(agent, windows))
        .accessibilityLabel(AgentUsageChips.spoken(agent, windows))
    }

    /// The provider's own colour while there's room; amber from 70%, red from 90%.
    private func color(_ p: Double) -> Color {
        p >= 90 ? Theme.red : p >= 70 ? Theme.amber : (agent.binary == "claude" ? Color(hex: 0xE07B53) : accent)
    }

    static func countdown(to d: Date) -> String {
        let m = max(0, Int(d.timeIntervalSinceNow / 60))
        return m >= 1440 ? "\(m / 1440)d \(m % 1440 / 60)h" : m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

// MARK: - Toasts

struct ToastStack: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(store.toasts) { t in
                HStack(alignment: .top, spacing: 10) {
                    icon(t.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                        if let d = t.detail {
                            Text(d).font(Typo.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(3)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { store.dismissToast(t.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.meta)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: 320, alignment: .leading)
                .popoverSurface(Theme.popover, radius: 10)
                .contentShape(Rectangle())
                .onTapGesture { if let s = t.sessionID { store.dismissToast(t.id); store.reveal(session: s) } }
                .modifier(OptionalHandCursor(on: t.sessionID != nil))
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.toasts)
    }

    @ViewBuilder private func icon(_ k: Toast.Kind) -> some View {
        switch k {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
        case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(Theme.blue)
        case .progress: ProgressView().controlSize(.small)
        }
    }
}

/// A confirmation that needs a name typed exactly (writes to Production).
struct TypeToConfirmSheet: View {
    let confirmation: Confirmation
    let close: () -> Void
    @State private var typed = ""

    var body: some View {
        let target = confirmation.typeToConfirm ?? ""
        VStack(alignment: .leading, spacing: 12) {
            Text(confirmation.title).font(Typo.ui(15, .semibold)).foregroundStyle(Theme.text)
            Text(confirmation.message).font(Typo.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            Text("Type \(target) to confirm").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
            TextField(target, text: $typed).textFieldStyle(.roundedBorder).font(Typo.mono(13))
                .onSubmit { if typed == target { close(); confirmation.action() } }
            HStack {
                Spacer()
                Button("Cancel") { close(); confirmation.onCancel?() }.keyboardShortcut(.cancelAction)
                Button(confirmation.confirmTitle, role: .destructive) { close(); confirmation.action() }
                    .disabled(typed != target)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct OptionalHandCursor: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.handCursor() } else { content }
    }
}
