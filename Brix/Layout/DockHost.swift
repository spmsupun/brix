import SwiftUI
import UniformTypeIdentifiers

/// Project workspace frame: centre plus left, right and bottom docks.
struct WorkspaceView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    let ws: WorkspaceStore

    var body: some View {
        HStack(spacing: gap) {
            docks
            if store.settings.showToolStrips { ToolStrip(ws: ws) }
        }
        .onAppear { ws.activate() }
    }

    private var docks: some View {
        GeometryReader { geo in
            HStack(spacing: gap) {
                if ws.layout.isVisible(.left) {
                    DockStack(ws: ws, side: .left)
                        .frame(width: ws.layout.leftWidth)
                        .overlay(alignment: .trailing) {
                            ResizeHandle(axis: .horizontal) { d in
                                ws.layout.resize(.left, to: ws.layout.leftWidth + d, available: geo.size)
                            }
                            .offset(x: 4 + gap / 2)
                        }
                        .zIndex(1)
                }
                VStack(spacing: gap) {
                    CentreView(ws: ws)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if ws.layout.isVisible(.bottom) {
                        DockStack(ws: ws, side: .bottom)
                            .frame(height: ws.layout.bottomHeight)
                            .overlay(alignment: .top) {
                                ResizeHandle(axis: .vertical) { d in
                                    ws.layout.resize(.bottom, to: ws.layout.bottomHeight - d, available: geo.size)
                                }
                                .offset(y: -4 - gap / 2)
                            }
                    }
                }
                if ws.layout.isVisible(.right) {
                    DockStack(ws: ws, side: .right)
                        .frame(width: ws.layout.rightWidth)
                        .overlay(alignment: .leading) {
                            ResizeHandle(axis: .horizontal) { d in
                                ws.layout.resize(.right, to: ws.layout.rightWidth - d, available: geo.size)
                            }
                            .offset(x: -4 - gap / 2)
                        }
                        .zIndex(1)
                }
            }
            .overlay { if store.draggingPanel != nil { EdgeDropZones(ws: ws) } }
            .overlay(alignment: .topLeading) { FloatingPanels(ws: ws, size: geo.size) }
            .onAppear { ws.layout.fit(available: geo.size) }
            .onChange(of: geo.size) { _, s in ws.layout.fit(available: s) }
        }
    }
}

// MARK: - Dock stacks

/// Panels in one dock: stacked vertically on the sides, side by side at the bottom.
struct DockStack: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    let ws: WorkspaceStore
    let side: DockSide

    private var vertical: Bool { side != .bottom }
    static let collapsedHeight: CGFloat = 40

    var body: some View {
        let panels = ws.layout.panels(side)
        GeometryReader { geo in
            let total = vertical ? geo.size.height : geo.size.width
            let collapsed = panels.filter { vertical && ws.layout.collapsedPanels.contains($0.id) }
            let open = panels.filter { !(vertical && ws.layout.collapsedPanels.contains($0.id)) }
            let free = max(0, total - gap * CGFloat(max(panels.count - 1, 0)) - CGFloat(collapsed.count) * Self.collapsedHeight)
            let weightSum = open.reduce(0) { $0 + ws.layout.weight($1.id) }
            let unit = weightSum > 0 ? free / weightSum : 0
            let stack = ForEach(Array(panels.enumerated()), id: \.element.id) { i, p in
                let isCollapsed = vertical && ws.layout.collapsedPanels.contains(p.id)
                let size = isCollapsed ? Self.collapsedHeight : unit * ws.layout.weight(p.id)
                PanelView(ws: ws, panel: p, side: side)
                    .frame(width: vertical ? nil : size, height: vertical ? size : nil)
                    .overlay {
                        if store.draggingPanel != nil, store.draggingPanel != p.id {
                            InsertZones(ws: ws, side: side, index: i, vertical: vertical)
                        }
                    }
                    .overlay(alignment: vertical ? .bottom : .trailing) {
                        if i < panels.count - 1, !isCollapsed {
                            let next = panels[i + 1]
                            ResizeHandle(axis: vertical ? .vertical : .horizontal) { d in
                                guard unit > 0, !ws.layout.collapsedPanels.contains(next.id) else { return }
                                let dw = d / unit
                                let a = ws.layout.weight(p.id), b = ws.layout.weight(next.id)
                                guard a + dw > 0.25, b - dw > 0.25 else { return }
                                ws.layout.setWeight(p.id, a + dw)
                                ws.layout.setWeight(next.id, b - dw)
                            }
                            .offset(x: vertical ? 0 : 4 + gap / 2, y: vertical ? 4 + gap / 2 : 0)
                            .zIndex(2)
                        }
                    }
            }
            if vertical {
                VStack(spacing: gap) { stack }
            } else {
                HStack(spacing: gap) { stack }
            }
        }
    }
}

/// Above/below (or before/after) drop targets on a docked panel while dragging.
struct InsertZones: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    let side: DockSide
    let index: Int
    let vertical: Bool

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            DropZone(edge: vertical ? .top : .leading) { drop(at: index) }
            DropZone(edge: vertical ? .bottom : .trailing) { drop(at: index + 1) }
        }
    }

    private func drop(at i: Int) {
        guard let id = store.draggingPanel else { return }
        ws.layout.move(id, to: side, at: i)
        store.draggingPanel = nil
    }
}

struct DropZone: View {
    let edge: Edge?
    let action: () -> Void
    @State private var targeted = false
    @Environment(\.accent) private var accent

    var body: some View {
        Rectangle()
            .fill(targeted && edge == nil ? accent.opacity(0.10) : Color.white.opacity(0.001))
            .overlay(alignment: alignment) {
                if targeted {
                    if let edge {
                        Rectangle().fill(accent)
                            .frame(width: edge == .leading || edge == .trailing ? 3 : nil, height: edge == .top || edge == .bottom ? 3 : nil)
                    } else {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                }
            }
            .onDrop(of: [UTType.text], isTargeted: $targeted) { _ in
                action()
                return true
            }
    }

    private var alignment: Alignment {
        switch edge {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        case nil: .center
        }
    }
}

/// Drop strips at the window edges, so a panel can go to an empty dock.
struct EdgeDropZones: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let ws: WorkspaceStore

    var body: some View {
        ZStack {
            zone(.left).frame(width: 90).frame(maxWidth: .infinity, alignment: .leading)
            zone(.right).frame(width: 90).frame(maxWidth: .infinity, alignment: .trailing)
            zone(.bottom).frame(height: 90).frame(maxHeight: .infinity, alignment: .bottom).padding(.horizontal, 96)
        }
    }

    @ViewBuilder private func zone(_ side: DockSide) -> some View {
        if ws.layout.panels(side).isEmpty || ws.layout.collapsed.contains(side) {
            DropZone(edge: nil) {
                guard let id = store.draggingPanel else { return }
                ws.layout.move(id, to: side)
                store.draggingPanel = nil
            }
            .overlay {
                Text("Dock \(side.label.lowercased())")
                    .font(Typo.ui(11, .semibold)).foregroundStyle(accent.opacity(0.9))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.popover))
                    .allowsHitTesting(false)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.05)).allowsHitTesting(false))
        }
    }
}

// MARK: - Floating panels

struct FloatingPanels: View {
    let ws: WorkspaceStore
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(ws.layout.floating, id: \.panel.id) { f in
                PanelView(ws: ws, panel: f.panel, side: nil)
                    .frame(width: f.width, height: f.height)
                    .shadow(color: .black(0.6), radius: 24, y: 14)
                    .offset(x: min(f.x, max(0, size.width - f.width)), y: min(f.y, max(0, size.height - f.height)))
            }
        }
    }
}

// MARK: - Panel chrome

/// An island holding one docked panel.
struct PanelView: View {
    let ws: WorkspaceStore
    let panel: PanelInstance
    /// nil when floating.
    let side: DockSide?

    var body: some View {
        PanelContent(ws: ws, panel: panel)
            .environment(\.panelContext, PanelContext(ws: ws, panel: panel, side: side))
    }
}

struct PanelContext {
    weak var ws: WorkspaceStore?
    var panel: PanelInstance?
    var side: DockSide?
}

private struct PanelContextKey: EnvironmentKey { static let defaultValue = PanelContext() }
private struct PanelInGridKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var panelContext: PanelContext {
        get { self[PanelContextKey.self] }
        set { self[PanelContextKey.self] = newValue }
    }
    /// The panel is a tab in the centre grid; its tab already shows the title.
    var panelInGrid: Bool {
        get { self[PanelInGridKey.self] }
        set { self[PanelInGridKey.self] = newValue }
    }
}

/// Island with a 36pt panel header: grip, title, count, actions, dock button.
struct PanelChrome<Actions: View, Content: View>: View {
    @Environment(AppStore.self) private var store
    @Environment(\.panelContext) private var ctx
    @Environment(\.inTile) private var inTile
    var title: String
    var count: String? = nil
    var countColor: Color = Theme.text2
    var dark = false
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    private var collapsed: Bool {
        guard let id = ctx.panel?.id, let ws = ctx.ws, ctx.side != .bottom else { return false }
        return ws.layout.collapsedPanels.contains(id)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: title, count: count, countColor: countColor, dark: dark, actions: actions)
            if !collapsed {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(TileOrIsland(fill: inTile ? (dark ? Theme.terminal : Theme.pane) : (dark ? Theme.terminal : Theme.island)))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { if let id = ctx.panel?.id { ctx.ws?.select(panel: id) } })
    }
}

extension PanelChrome where Actions == EmptyView {
    init(title: String, count: String? = nil, countColor: Color = Theme.text2, dark: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, count: count, countColor: countColor, dark: dark, actions: { EmptyView() }, content: content)
    }
}

struct PanelHeader<Actions: View>: View {
    @Environment(AppStore.self) private var store
    @Environment(\.panelContext) private var ctx
    @Environment(\.panelInGrid) private var inGrid
    var title: String
    var count: String?
    var countColor: Color = Theme.text2
    var dark = false
    @ViewBuilder var actions: () -> Actions
    @State private var dragStart: CGPoint?

    var body: some View {
        HStack(spacing: 8) {
            if !inGrid {
                Grip()
                Text(title)
                    .font(Typo.panelTitle).tracking(0.4)
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
            }
            if let count {
                CountPill(text: count, color: countColor, tint: countColor == Theme.text2 ? Color.white(0.06) : countColor.opacity(0.10))
            }
            actions()
            if ctx.panel != nil, !inGrid { DockButton() }
        }
        .padding(.leading, 10).padding(.trailing, 8)
        .frame(height: Metrics.panelHeader)
        // In a tile the header shares the body colour, so the tab above flows into it.
        // Dark (terminal) headers hold Chrome tabs that open into the body: no rule under them.
        .background(dark && !inGrid ? Theme.tileStripLight : Color.clear)
        .hairlineBottom(dark ? .clear : Theme.divider)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let id = ctx.panel?.id, ctx.side != .bottom, ctx.side != nil { ctx.ws?.layout.togglePanelCollapsed(id) }
        }
        .modifier(HeaderDrag(ctx: ctx))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) panel")
    }
}

/// Docked panels drag to re-dock; floating panels drag to move.
private struct HeaderDrag: ViewModifier {
    @Environment(AppStore.self) private var store
    let ctx: PanelContext
    @State private var origin: CGPoint?

    func body(content: Content) -> some View {
        if let panel = ctx.panel, let ws = ctx.ws {
            if ctx.side == nil {
                content.gesture(DragGesture(minimumDistance: 2).onChanged { v in
                    guard let f = ws.layout.floating.first(where: { $0.panel.id == panel.id }) else { return }
                    if origin == nil { origin = CGPoint(x: f.x, y: f.y) }
                    ws.layout.moveFloating(panel.id, to: CGPoint(x: origin!.x + v.translation.width, y: origin!.y + v.translation.height))
                }.onEnded { _ in origin = nil })
            } else {
                content.onDrag {
                    store.beginPanelDrag(panel.id)
                    return NSItemProvider(object: panel.id as NSString)
                } preview: {
                    Text(panel.displayTitle)
                        .font(Typo.ui(12, .semibold)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.popover))
                }
            }
        } else {
            content
        }
    }
}

extension AppStore {
    /// Tracks a panel drag; clears itself when the mouse is released anywhere.
    func beginPanelDrag(_ id: String) {
        draggingPanel = id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            while NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            if self?.draggingPanel == id { self?.draggingPanel = nil }
        }
    }
}

/// Window icon with the docked side filled; opens the dock menu.
struct DockButton: View {
    @Environment(AppStore.self) private var store
    @Environment(\.panelContext) private var ctx

    static func symbol(_ side: DockSide?) -> String {
        switch side {
        case .left: "rectangle.lefthalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case nil: "rectangle.center.inset.filled"
        }
    }

    var body: some View {
        MenuButton(items: items) {
            Image(systemName: Self.symbol(ctx.side))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.text3)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(ctx.panel?.displayTitle ?? "Panel") docked \(ctx.side?.label.lowercased() ?? "floating"), change position")
        .tip("Dock panel")
    }

    private func items() -> [MenuSpec] {
        guard let ws = ctx.ws, let p = ctx.panel else { return [] }
        var items: [MenuSpec] = [.header("Dock panel")]
        for side in DockSide.allCases {
            items.append(MenuSpec(title: side.label, symbol: Self.symbol(side), key: side.shortcut, checked: ctx.side == side) {
                ws.layout.move(p.id, to: side)
            })
        }
        items.append(MenuSpec(title: "Float", symbol: Self.symbol(nil), key: "⌃⌥F", checked: ctx.side == nil) { ws.layout.float(p.id) })
        if ctx.side == .left || ctx.side == .right {
            items.append(MenuSpec(title: ws.layout.collapsedPanels.contains(p.id) ? "Expand" : "Collapse") { ws.layout.togglePanelCollapsed(p.id) })
        }
        if p.kind.allowsMultiple {
            items.append(MenuSpec(title: "Rename…") { store.sheet = .renamePanel(ws.projectID, p.id) })
        }
        items.append(.separator)
        items.append(MenuSpec(title: "Hide panel", symbol: "eye.slash", key: p.kind.toggleShortcut) { ws.layout.hide(p.id) })
        return items
    }
}

// MARK: - Centre

struct CentreView: View {
    let ws: WorkspaceStore
    var body: some View {
        switch ws.layout.centre {
        case .editor, .agents: AgentsGrid(ws: ws)
        case .review: ReviewView(ws: ws)
        }
    }
}
