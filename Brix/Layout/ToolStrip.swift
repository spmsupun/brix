import SwiftUI

/// PhpStorm-style tool window bar on the right edge: one icon per panel.
/// Click shows or hides it; right-click moves it to a dock or the centre grid.
struct ToolStrip: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let ws: WorkspaceStore

    static let kinds: [PanelKind] = [.explorer, .sourceControl, .plan, .agentFiles, .inspector, .connections, .notes]
    static let width: CGFloat = 44

    private func home(_ k: PanelKind) -> DockSide {
        if let p = ws.layout.allPanels.first(where: { $0.kind == k }), let side = ws.layout.side(of: p.id) { return side }
        return ws.layout.lastSide[k] ?? k.defaultSide
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Self.kinds) { button($0) }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .island()
    }

    private func button(_ k: PanelKind) -> some View {
        let panel = ws.layout.allPanels.first { $0.kind == k }
        let side = panel.flatMap { ws.layout.side(of: $0.id) }
        let inGrid = ws.state.panes.allTabs.contains(GridItemID.panel(k)) && ws.layout.centre == .agents
        let visible = inGrid || (panel != nil && (side == nil || !ws.layout.collapsed.contains(side!)))
        return Button { toggle(k, panel: panel, side: side, visible: visible) } label: {
            Image(systemName: k.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(visible ? accent : Theme.text2)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(visible ? Color.white(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.hand)
        .tip(k.title, k.toggleShortcut)
        .accessibilityLabel("\(k.title), \(visible ? "shown" : "hidden")")
        .contextMenu {
            Button("Show in the Centre Grid") { ws.movePanelToGrid(k, group: nil) }
            ForEach(DockSide.allCases) { d in
                Button("Show on the \(d.label)") {
                    ws.removePanelFromGrid(k)
                    if let panel { ws.layout.move(panel.id, to: d) } else { ws.layout.add(k, to: d) }
                }
            }
            if let panel {
                Button("Float") { ws.layout.float(panel.id) }
                Divider()
                Button("Hide") { ws.layout.hide(panel.id) }
            }
        }
    }

    private func toggle(_ k: PanelKind, panel: PanelInstance?, side: DockSide?, visible: Bool) {
        withAnimation(.easeOut(duration: 0.15)) {
            if ws.state.panes.allTabs.contains(GridItemID.panel(k)) {
                if ws.layout.centre == .agents { ws.removePanelFromGrid(k) } else { ws.layout.centre = .agents; ws.state.panes.activate(GridItemID.panel(k)) }
            } else if let panel, let side, ws.layout.collapsed.contains(side) {
                ws.layout.toggleCollapsed(side)
                ws.select(panel: panel.id)
            } else if let panel, visible {
                ws.layout.hide(panel.id)
            } else {
                let p = ws.layout.add(k, to: home(k))
                if k == .terminal, ws.state.panelSession[p.id] == nil, let s = ws.projectSessions.first(where: { $0.kind != .agent }) {
                    ws.state.panelSession[p.id] = s.id
                }
                ws.select(panel: p.id)
            }
        }
    }
}
