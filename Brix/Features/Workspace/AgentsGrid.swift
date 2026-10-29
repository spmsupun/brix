import SwiftUI

/// Centre "Agents & Terminals" mode: the tiled centre, any tab kind in any pane.
struct AgentsGrid: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore

    var body: some View {
        if ws.state.panes.isEmpty {
            EmptyState(symbol: "sparkle", message: "Nothing open yet. Open a file from the Explorer (⌘P), or start an agent or a terminal.", actionTitle: "New Agent Session") {
                store.startAgent(project: ws.projectID)
            }
            .island()
            .overlay(alignment: .topTrailing) {
                IconButton(symbol: "plus", label: "Add a tab", size: 30, iconSize: 12) { ws.showAddTab(group: nil) }
                    .padding(6)
            }
        } else {
            SessionPaneTree(tree: Binding(get: { ws.state.panes }, set: { ws.state.panes = $0 }), host: ws.tiledHost)
                .onChange(of: store.sessions.map(\.id)) { _, ids in
                    let keep = Set(ids)
                    let stale = ws.state.panes.allTabs.filter { !GridItemID.isPanel($0) && !GridItemID.isFile($0) && !keep.contains($0) }
                    if !stale.isEmpty { ws.state.panes.retain(Set(ws.state.panes.allTabs).subtracting(stale)) }
                }
        }
    }
}

extension WorkspaceStore {
    var tiledHost: TiledHost {
        TiledHost(addPopover: { [weak self] g in self?.showAddTab(group: g) },
                  newTerminal: { [weak self] in
                      guard let self else { return nil }
                      return app.newTerminal(project: projectID, attach: false).id
                  },
                  close: { [weak self] ids in self?.closeTabs(ids) },
                  content: { [weak self] id in
                      guard let self else { return AnyView(EmptyView()) }
                      return AnyView(GridTab(ws: self, id: id))
                  })
    }

    /// The existing Add Panel menu, adding its pick into `group`.
    func showAddTab(group: String?) {
        app.popover = PopoverRequest(kind: .addTab(group ?? state.panes.focusedGroup ?? ""), anchor: .zero, projectID: projectID, centred: true)
    }

    /// Adds a tab to a pane (or the focused one) and shows the tiled centre.
    func placeTab(_ id: String, in group: String?) {
        state.panes.add(id, to: group.flatMap { state.panes.group($0)?.id })
        state.layout.centre = .agents
    }
}

/// The body of one grid tab: a session, a file, or a panel.
struct GridTab: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    let id: String

    var body: some View {
        if let path = GridItemID.filePath(id) {
            EditorPane(ws: ws, path: path, isSplit: false)
        } else if id == GridItemID.editor {
            EditorArea(ws: ws)
        } else if let p = GridItemID.panelInstance(id) {
            PanelContent(ws: ws, panel: p)
                .environment(\.panelInGrid, true)
        } else if store.session(id)?.kind == .agent {
            AgentPane(ws: ws, sessionID: id, compact: false)
        } else {
            TerminalPane(ws: ws, sessionID: id, showHealth: true)
        }
    }
}

/// Grid tab ids: session ids as they are, panels as "panel:<kind>[:resource]".
enum GridItemID {
    static let panelKinds: [PanelKind] = [.explorer, .sourceControl, .plan, .agentFiles, .inspector, .connections, .docker, .notes]
    static let editor = "panel:editor"

    static func panel(_ k: PanelKind) -> String { "panel:\(k.rawValue)" }
    static func database(_ id: ResourceID) -> String { "panel:database:\(id)" }
    static func remoteFiles(_ host: ResourceID) -> String { "panel:remoteFiles:\(host)" }
    /// A table or SQL console as a project tab. The id carries what's needed to
    /// reopen it after a relaunch: tab id, connection, and the table if any.
    @MainActor static func dataTab(_ t: DWTab) -> String {
        var parts = [t.id.uuidString, t.connectionID]
        if let o = t.object { parts += [o.schema, o.name, o.kind == .view ? "v" : "t"] }
        let raw = Data(parts.joined(separator: "\u{1F}").utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "panel:dataTab:" + raw
    }
    /// The data tab id in a tile key.
    static func dataTabID(_ key: String) -> UUID? { panelInstance(key)?.resourceID.flatMap(dataTabRef)?.id }

    static func dataTabRef(_ key: String) -> (id: UUID, connection: ResourceID, object: DBObject?)? {
        var b = key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b) else { return nil }
        let p = String(decoding: data, as: UTF8.self).components(separatedBy: "\u{1F}")
        guard p.count >= 2, let id = UUID(uuidString: p[0]) else { return nil }
        let o = p.count >= 5 ? DBObject(schema: p[2], name: p[3], kind: p[4] == "v" ? .view : .table, rowEstimate: nil) : nil
        return (id, p[1], o)
    }
    static func isPanel(_ id: String) -> Bool { id.hasPrefix("panel:") }
    /// An open file in the tiled centre.
    static func file(_ path: String) -> String { "file:\(path)" }
    static func isFile(_ id: String) -> Bool { id.hasPrefix("file:") }
    static func filePath(_ id: String) -> String? { isFile(id) ? String(id.dropFirst(5)) : nil }

    static func kind(_ id: String) -> PanelKind? {
        guard isPanel(id) else { return nil }
        return PanelKind(rawValue: String(id.dropFirst(6).split(separator: ":").first ?? ""))
    }

    static func panelInstance(_ id: String) -> PanelInstance? {
        guard let k = kind(id) else { return nil }
        let parts = id.split(separator: ":")
        return PanelInstance(id: id, kind: k, resourceID: parts.count > 2 ? String(parts[2]) : nil)
    }
}

/// Shell or server terminal pane with its own header.
struct TerminalPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.inTile) private var inTile
    let ws: WorkspaceStore?
    let sessionID: String
    var showHealth = false

    var body: some View {
        if let s = store.session(sessionID) {
            let host = s.hostID.flatMap(store.host)
            VStack(spacing: 0) {
                // In the tiled centre the tab already names the session.
                if !inTile { HStack(spacing: 8) {
                    Image(systemName: host != nil ? "globe" : "terminal").font(.system(size: 11)).foregroundStyle(host?.tag.color ?? Theme.text3)
                    Text(store.displayTitle(s)).font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(s.cwd).font(Typo.mono(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.head)
                    if let host { TagPill(tag: host.tag, size: 8.5) }
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        StatusDot(color: s.state.color, size: 6, ring: s.state == .running)
                        Text(s.state.label).font(Typo.ui(11)).foregroundStyle(Theme.text2)
                    }
                    SessionActions(sessionID: s.id)
                }
                .padding(.horizontal, 12)
                .frame(height: Metrics.panelHeader)
                .background(Theme.terminalHeader)
                .hairlineBottom() }
                if showHealth, let host, let m = store.hostMetrics[host.id] {
                    HealthStrip(metrics: m)
                }
                TerminalSurface(sessionID: s.id)
            }
            .modifier(TileOrIsland(fill: Theme.terminal, stroke: host.map { $0.tag.color.opacity(0.35) } ?? Theme.border))
            .onTapGesture { store.inspector = .session(s.id); store.focusedSessionID = s.id }
        } else {
            EmptyState(symbol: "terminal", message: "This session was closed.").island(Theme.terminal)
        }
    }
}

/// Rename, clear, interrupt and close for a session.
struct SessionActions: View {
    @Environment(AppStore.self) private var store
    let sessionID: String

    var body: some View {
        MenuButton(items: {
            [MenuSpec(title: "Rename…") { store.sheet = .renameSession(sessionID) },
             MenuSpec(title: "Clear") { store.clearSession(sessionID) },
             MenuSpec(title: "Interrupt", key: "⌃C") { store.interruptSession(sessionID) },
             MenuSpec(title: "Copy Directory") { store.copyToPasteboard(store.session(sessionID)?.cwd ?? "", label: "directory") },
             MenuSpec(title: "Show in Inspector") { store.inspector = .session(sessionID) },
             .separator,
             MenuSpec(title: "Close") { store.closeSession(sessionID) }]
        }) {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text3)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .accessibilityLabel("Session actions")
    }
}

/// A Claude Code session. Input goes straight to its terminal, so pasting
/// images and every agent shortcut work as in a normal terminal.
struct AgentPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    @Environment(\.inTile) private var inTile
    let ws: WorkspaceStore
    let sessionID: String
    var compact: Bool

    var body: some View {
        if let s = store.session(sessionID) {
            let p = s.projectID.flatMap(store.project)
            let hue = p?.hue.color ?? Theme.violet
            let active = s.state == .running || s.state == .needsInput
            if inTile {
                // The tab carries the name, logo and state; the body is just the session.
                TerminalSurface(sessionID: s.id, showInput: false)
                    .background(Theme.terminal)
                .clickable().onTapGesture { store.inspector = .session(s.id) }
            } else {
                VStack(spacing: 0) {
                    header(s, project: p, hue: hue)
                    TerminalSurface(sessionID: s.id, showInput: false)
                }
                .background(Theme.terminal)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.islandRadius))
                .overlay(RoundedRectangle(cornerRadius: Metrics.islandRadius).strokeBorder(active && !compact ? hue.opacity(0.35) : Theme.border))
                .background(RoundedRectangle(cornerRadius: Metrics.islandRadius + 3).fill(active && !compact ? hue.opacity(0.07) : .clear).padding(-3))
                .clickable().onTapGesture { store.inspector = .session(s.id) }
            }
        } else {
            EmptyState(symbol: "sparkle", message: "This session was closed.").island(Theme.terminal)
        }
    }

    private func header(_ s: TerminalSession, project p: Project?, hue: Color) -> some View {
        HStack(spacing: 8) {
            AgentMark(agent: store.agent(for: s), size: 15, working: s.state == .running)
            Text(store.displayTitle(s)).font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                .help(store.displayTitle(s))
            if !compact {
                Text(s.cwd).font(Typo.mono(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.head).layoutPriority(-1)
            }
            Spacer(minLength: 0)
            if let a = store.agent(for: s), let w = store.agentUsage[a.id]?.first {
                Text("\(w.label) \(Int(w.percent))%").font(Typo.ui(10.5, .medium)).monospacedDigit()
                    .foregroundStyle(w.percent >= 90 ? Theme.red : (w.percent >= 70 ? Theme.amber : Theme.text3))
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white(0.05)))
                    .help(AgentUsageChips.tip(a, store.agentUsage[a.id] ?? []))
            }
            if s.state == .needsInput {
                Text("Needs input").font(Typo.ui(10.5, .semibold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Theme.amber))
            } else {
                HStack(spacing: 6) {
                    StatusDot(color: s.state.color, size: 6, ring: s.state == .running, pulse: s.state == .running)
                    Text(s.state == .running ? "Working · \(Self.duration(since: s.startedAt))" : s.state.label).font(Typo.ui(11)).foregroundStyle(Theme.text2)
                }
            }
            if s.state == .running {
                IconButton(symbol: "stop.circle", label: "Interrupt", shortcut: "⌃C", size: 22, iconSize: 11) { store.interruptSession(s.id) }
            }
            SessionActions(sessionID: s.id)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.panelHeader)
        .background(Theme.terminalHeader)
        .hairlineBottom()
    }

    static func duration(since d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        return m < 60 ? "\(max(m, 1)) min" : "\(m / 60) h"
    }
}

/// Dock panel: the plan of the project's current agent session.
struct PlanPanel: View {
    let ws: WorkspaceStore
    var body: some View {
        let s = ws.currentAgentSession
        PanelChrome(title: "Plan") {
            Spacer(minLength: 0)
            if let s { Text("\(s.plan.filter(\.done).count) of \(s.plan.count)").font(Typo.ui(11)).foregroundStyle(Theme.text3) }
        } content: {
            if let s {
                ScrollView { PlanList(session: s) }
            } else {
                EmptyState(symbol: "checklist", message: "Start an agent to see its plan here.")
            }
        }
    }
}

struct PlanList: View {
    let session: TerminalSession

    var body: some View {
        // The task the agent marked in progress, else the first one not done.
        let current = session.plan.firstIndex(where: \.active) ?? session.plan.firstIndex { !$0.done }
        VStack(spacing: 0) {
            if session.plan.isEmpty {
                Text(session.task.isEmpty ? "The plan appears once the agent starts a task." : session.task)
                    .font(Typo.ui(12)).foregroundStyle(Theme.text3).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.plan.enumerated()), id: \.offset) { i, item in
                        HStack(spacing: 9) {
                            box(done: item.done, now: i == current && session.state == .running)
                            Text(item.title)
                                .font(Typo.ui(12.5, i == current ? .medium : .regular))
                                .foregroundStyle(item.done ? Theme.text3 : (i == current ? Theme.text : Theme.text2))
                                .strikethrough(item.done, color: Color.white(0.25))
                                .lineLimit(1)
                        }
                        .frame(height: 26)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(item.done ? "Done" : (i == current ? "In progress" : "To do"))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func box(done: Bool, now: Bool) -> some View {
        ZStack {
            if done {
                RoundedRectangle(cornerRadius: 5).fill(Theme.green.opacity(0.16))
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.green)
            } else {
                RoundedRectangle(cornerRadius: 5).strokeBorder(now ? Theme.violet : Theme.lineNumber, lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 7).stroke(now ? Theme.violet.opacity(0.15) : .clear, lineWidth: 3).padding(-1.5))
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// Dock panel: files the project's current agent session touched.
struct AgentFilesPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore

    var body: some View {
        PanelChrome(title: "Agent Files") {
            Spacer(minLength: 0)
            LinkButton(title: "Review all →") { ws.layout.centre = .review }
        } content: {
            if let session = ws.currentAgentSession {
                ScrollView { list(session) }
            } else {
                EmptyState(symbol: "doc.on.doc", message: "Files an agent changes show up here.")
            }
        }
    }

    @ViewBuilder private func list(_ session: TerminalSession) -> some View {
        VStack(spacing: 0) {
            if session.touched.isEmpty {
                Text("No files changed yet.").font(Typo.ui(12)).foregroundStyle(Theme.text3).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(session.touched) { t in
                        let st = store.git[ws.projectID]?.changes.first { $0.path == t.path }?.status ?? .M
                        Button { ws.open(t.path) } label: {
                            HStack(spacing: 8) {
                                GitStatusLetter(status: st).frame(width: 14)
                                Text((t.path as NSString).lastPathComponent).font(Typo.row).foregroundStyle(Theme.text)
                                Text((t.path as NSString).deletingLastPathComponent).font(Typo.ui(11)).foregroundStyle(Theme.meta).lineLimit(1).truncationMode(.head)
                                Spacer(minLength: 0)
                                AddDel(add: t.add, del: t.del)
                            }
                            .padding(.horizontal, 8).frame(height: 28)
                            .rowBackground(selected: false, radius: 6)
                        }
                        .buttonStyle(.hand)
                    }
                }
                .padding(6)
            }
        }
    }
}

/// CPU, memory and disk meters for a remote pane.
struct HealthStrip: View {
    let metrics: HostMetrics
    var body: some View {
        HStack(spacing: 14) {
            meter("CPU", metrics.cpu, Theme.green)
            meter("MEM", metrics.memory, Theme.amber)
            meter("DISK", metrics.disk, Theme.blue)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.terminal)
        .hairlineBottom(Color.white(0.04))
        .animation(.easeOut(duration: 0.4), value: metrics)
    }

    private func meter(_ label: String, _ v: Double, _ c: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Typo.ui(10.5)).foregroundStyle(Theme.text2).frame(width: 30, alignment: .leading)
            MeterBar(label: label, value: v, color: c, showLabel: false)
            Text("\(Int((v * 100).rounded()))%").font(Typo.ui(11)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 34, alignment: .trailing)
        }
    }
}

/// An island normally; in the tiled centre the pane is the island, so just the fill.
struct TileOrIsland: ViewModifier {
    @Environment(\.inTile) private var inTile
    var fill: Color = Theme.island
    var stroke: Color = Theme.border
    func body(content: Content) -> some View {
        if inTile { content.background(fill) } else { content.island(fill, stroke: stroke) }
    }
}
