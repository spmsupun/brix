import SwiftUI

/// Live state of one tab drag. Nothing in the tree changes until the drop, so
/// tabs never fight the layout mid-drag.
@Observable final class PaneDrag {
    static let space = "panes"
    var tab: String?
    var source: String?
    var location: CGPoint = .zero
    /// Pointer position inside the dragged tab.
    var grab: CGSize = .zero
    var size: CGSize = .zero
    var target: PaneDropTarget?
    var tabFrames: [String: CGRect] = [:]
    var stripFrames: [String: CGRect] = [:]
    var bodyFrames: [String: CGRect] = [:]
}

/// What the tiled centre needs from its host (a project workspace or the
/// Terminals screen).
struct TiledHost {
    /// Opens the Add Panel menu for a pane; nil uses `addMenu` instead.
    var addPopover: ((String) -> Void)?
    var addMenu: (String) -> [MenuSpec] = { _ in [] }
    /// A fresh terminal for split right/down and 2 × 2.
    var newTerminal: () -> String?
    /// Closes tabs of any kind (asks when a process is running).
    var close: ([String]) -> Void
    /// The tab body.
    var content: (String) -> AnyView
}

enum TileMetrics {
    static let strip: CGFloat = 36
    static let tab: CGFloat = 30
    static let activeTab: CGFloat = 31
    static let tabWidth: CGFloat = 180
    static let tabMinWidth: CGFloat = 72
    static let tabRadius: CGFloat = 7
    static let flare: CGFloat = 6
    static let paneRadius: CGFloat = 10
    static let minPane = CGSize(width: 160, height: 120)
}

/// Tab bodies: terminals and agents are dark, everything else is the pane colour.
enum TileColors {
    static func body(_ tab: String?) -> Color {
        guard let tab, !GridItemID.isPanel(tab), !GridItemID.isFile(tab) else { return Theme.pane }
        return Theme.terminal
    }

    /// The strip always contrasts with the active tab: lighter above a dark
    /// terminal body, darker above a pane-coloured one, so tabs stay readable.
    static func strip(_ activeTab: String?) -> Color {
        body(activeTab) == Theme.terminal ? Theme.tileStripLight : Theme.tileStrip
    }
}

private struct InTileKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Content is a tab body in the tiled centre: it draws no island or header of its own.
    var inTile: Bool {
        get { self[InTileKey.self] }
        set { self[InTileKey.self] = newValue }
    }
}

/// Tiled centre: split any pane any way, any size, with Chrome-style tabs in every pane.
struct SessionPaneTree: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    @Binding var tree: PaneTree
    let host: TiledHost
    @State private var drag = PaneDrag()

    var body: some View {
        Group {
            if let m = tree.maximized, let g = tree.group(m) {
                PaneGroupView(group: g, tree: $tree, host: host, commit: commit)
            } else if let root = tree.root {
                node(root)
            }
        }
        .coordinateSpace(name: PaneDrag.space)
        .environment(drag)
        .overlay(alignment: .topLeading) { ghost }
        .onChange(of: store.focusedSessionID) { _, id in
            if let id, let g = tree.group(of: id), tree.focusedGroup != g.id { tree.focusedGroup = g.id }
        }
        .onChange(of: store.tileDragPreview?.target) { _, _ in
            guard let p = store.tileDragPreview else { drag.tab = nil; drag.target = nil; return }
            drag.tab = p.tab
            drag.source = tree.group(of: p.tab)?.id
            drag.size = CGSize(width: 170, height: TileMetrics.activeTab)
            drag.grab = CGSize(width: 60, height: 14)
            drag.location = p.at
            drag.target = p.target
        }
    }

    private var paneGap: CGFloat { max(gap, 6) }

    private func node(_ n: PaneNode) -> AnyView {
        switch n {
        case .group(let g):
            return AnyView(PaneGroupView(group: g, tree: $tree, host: host, commit: commit))
        case .split(let id, let vertical, let children, let weights):
            let mins = children.map {
                PaneTree.minimum($0, vertical: vertical, pane: vertical ? TileMetrics.minPane.height : TileMetrics.minPane.width, gap: paneGap)
            }
            return AnyView(SplitView(vertical: vertical, weights: weights, minimums: mins, gap: paneGap,
                                     onResize: { tree.setWeights(split: id, $0) },
                                     onEqualize: { withAnimation(.easeOut(duration: 0.18)) { tree.equalize(split: id) } }) { i in
                node(children[i])
            })
        }
    }

    /// Rotated tab ghost following the pointer once it leaves its own strip.
    @ViewBuilder private var ghost: some View {
        if let id = drag.tab, !draggingInOwnStrip {
            PaneTabLabel(tabID: id, selected: true, hovering: false)
                .frame(width: drag.size.width, height: TileMetrics.activeTab)
                .background(ChromeTabShape().fill(TileColors.body(id)).padding(.horizontal, -TileMetrics.flare))
                .rotationEffect(.degrees(-1.5))
                .shadow(color: .black(0.45), radius: 14, y: 8)
                .offset(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
                .allowsHitTesting(false)
        }
    }

    private var draggingInOwnStrip: Bool {
        if case .strip(let g, _)? = drag.target { return g == drag.source }
        return drag.target == nil
    }

    private func commit(_ target: PaneDropTarget?) {
        guard let tab = drag.tab else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            if let target { tree.drop(tab, on: target) }
            drag.tab = nil
            drag.source = nil
            drag.target = nil
        }
    }
}

/// Children laid out by weight, divided by draggable gaps.
private struct SplitView<Child: View>: View {
    let vertical: Bool
    let weights: [CGFloat]
    let minimums: [CGFloat]
    let gap: CGFloat
    let onResize: ([CGFloat]) -> Void
    let onEqualize: () -> Void
    @ViewBuilder let child: (Int) -> Child

    var body: some View {
        GeometryReader { geo in
            let n = minimums.count
            let total = (vertical ? geo.size.height : geo.size.width) - gap * CGFloat(max(n - 1, 0))
            let w = weights.count == n ? weights : Array(repeating: 1, count: n)
            let sum = max(w.reduce(0, +), 0.001)
            let layout = vertical ? AnyLayout(VStackLayout(spacing: gap)) : AnyLayout(HStackLayout(spacing: gap))
            layout {
                ForEach(0..<n, id: \.self) { i in
                    let size = max(total * w[i] / sum, 0)
                    child(i)
                        .frame(width: vertical ? nil : size, height: vertical ? size : nil)
                        .overlay(alignment: vertical ? .bottom : .trailing) {
                            if i < n - 1 {
                                ResizeHandle(axis: vertical ? .vertical : .horizontal, thickness: gap, style: .grip,
                                             onDrag: { d in resize(i, by: d, total: total, weights: w, sum: sum) },
                                             onDoubleClick: onEqualize)
                                    .offset(x: vertical ? 0 : gap, y: vertical ? gap : 0)
                                    .zIndex(2)
                            }
                        }
                }
            }
        }
    }

    /// Moves the divider after child `i`, keeping both neighbours at or above their minimum.
    private func resize(_ i: Int, by d: CGFloat, total: CGFloat, weights w: [CGFloat], sum: CGFloat) {
        guard total > 0 else { return }
        let a = total * w[i] / sum, b = total * w[i + 1] / sum
        let na = a + d, nb = b - d
        guard na >= minimums[i], nb >= minimums[i + 1] else { return }
        var nw = w
        nw[i] = na / total * sum
        nw[i + 1] = nb / total * sum
        onResize(nw)
    }
}

/// One pane: an island whose tab strip and active tab read as one surface with its body.
private struct PaneGroupView: View {
    @Environment(AppStore.self) private var store
    @Environment(PaneDrag.self) private var drag
    @Environment(\.accent) private var accent
    let group: TabGroup
    @Binding var tree: PaneTree
    let host: TiledHost
    let commit: (PaneDropTarget?) -> Void
    @State private var hovered: String?

    private var active: String? { group.active ?? group.tabs.first }
    private var focused: Bool { tree.focusedGroup == group.id }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TileMetrics.paneRadius, style: .continuous)
        VStack(spacing: 0) {
            strip
            ZStack {
                TileColors.body(active)
                if let active {
                    host.content(active).id(active)
                        .environment(\.inTile, true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PaneDrag.space)) } action: { drag.bodyFrames[group.id] = $0 }
            .overlay { dropZones }
            // A click in the body focuses the pane but leaves the keyboard where the
            // click put it (the terminal, or a text field such as the agent's message box).
            .simultaneousGesture(TapGesture().onEnded { focus(keyboard: false) })
        }
        .background(Theme.pane)
        .clipShape(shape)
        // The focused pane's border is the usual one, a touch brighter.
        .overlay(shape.strokeBorder(focused ? Color.white(0.16) : Theme.border, lineWidth: 1))
    }

    private func focus(keyboard: Bool = true) {
        tree.focusedGroup = group.id
        if let a = active, !GridItemID.isPanel(a), !GridItemID.isFile(a) {
            store.focusedSessionID = a
            if keyboard { TerminalRegistry.shared.focus(a) }
        }
    }

    // MARK: Strip

    private var strip: some View {
        HStack(alignment: .bottom, spacing: 0) {
            GeometryReader { geo in
                let avail = geo.size.width - 40
                let n = CGFloat(max(group.tabs.count, 1))
                let w = min(max(avail / n, TileMetrics.tabMinWidth), TileMetrics.tabWidth)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(Array(group.tabs.enumerated()), id: \.element) { i, id in
                            tab(id, index: i, width: w)
                        }
                        addButton.padding(.leading, 6).padding(.bottom, 3)
                    }
                    .padding(.leading, 8)
                    .frame(height: TileMetrics.strip, alignment: .bottom)
                }
                .scrollClipDisabled()
                // Clip sideways only, so overflowing tabs never draw over the pane buttons.
                .mask(Rectangle().padding(.vertical, -20))
            }
            .frame(height: TileMetrics.strip)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PaneDrag.space)) } action: { drag.stripFrames[group.id] = $0 }
            HStack(spacing: 0) {
                IconButton(symbol: "rectangle.split.2x1", label: "Split Right", shortcut: "⌘D", size: 26, iconSize: 12) { splitNew(.right) }
                IconButton(symbol: "rectangle.split.1x2", label: "Split Down", shortcut: "⇧⌘D", size: 26, iconSize: 12) { splitNew(.bottom) }
                MenuButton(items: { paneMenu }) {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.text3)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .accessibilityLabel("Pane actions")
            }
            .padding(.trailing, 6)
            .frame(height: TileMetrics.strip)
        }
        .frame(height: TileMetrics.strip)
        .background(TileColors.strip(active))
        .zIndex(1)
    }

    @ViewBuilder private var addButton: some View {
        if let popover = host.addPopover {
            IconButton(symbol: "plus", label: "Add a tab to this pane", size: 24, iconSize: 11) { focus(); popover(group.id) }
        } else {
            MenuButton(items: { host.addMenu(group.id) }) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .accessibilityLabel("Add a tab to this pane")
        }
    }

    private func splitNew(_ edge: PaneEdge) {
        guard let t = host.newTerminal() else { return }
        withAnimation(.easeOut(duration: 0.18)) { tree.splitNew(t, beside: group.id, edge: edge) }
    }

    private var paneMenu: [MenuSpec] {
        let others = tree.groups.filter { $0.id != group.id }
        let title = PaneTabLabel.title(store)
        return [
            MenuSpec(title: "Split Right", key: "⌘D") { splitNew(.right) },
            MenuSpec(title: "Split Down", key: "⇧⌘D") { splitNew(.bottom) },
            MenuSpec(title: "Split into 2 × 2") {
                let new = (0..<3).compactMap { _ in host.newTerminal() }
                if new.count == 3 { withAnimation(.easeOut(duration: 0.2)) { tree.split2x2(group.id, with: new) } }
            },
            .separator,
            MenuSpec(title: "Move Tab to New Pane", key: "⌃⌥⌘→", enabled: group.tabs.count > 1) {
                if let a = active { withAnimation(.easeOut(duration: 0.18)) { tree.split(a, beside: group.id, edge: .right) } }
            },
            MenuSpec(title: "Equalize Sizes", key: "⌃⌘=") { withAnimation(.easeOut(duration: 0.18)) { tree.equalize() } },
            MenuSpec(title: tree.maximized == group.id ? "Restore Panes" : "Maximize Pane", key: "⇧⌘↩",
                     enabled: tree.groups.count > 1 || tree.maximized != nil) {
                withAnimation(.easeOut(duration: 0.18)) { tree.toggleMaximized(group.id) }
            },
            MenuSpec(title: "Swap with Pane", enabled: !others.isEmpty, children: others.map { g in
                MenuSpec(title: (g.active ?? g.tabs.first).map(title) ?? "Pane") {
                    withAnimation(.easeOut(duration: 0.18)) { tree.swap(group.id, g.id) }
                }
            }),
            .separator,
            MenuSpec(title: "Close Pane", key: "⌥⌘W", destructive: true) { host.close(group.tabs) }
        ]
    }

    // MARK: Tabs

    private func tab(_ id: String, index i: Int, width: CGFloat) -> some View {
        let selected = id == active
        let isDragged = drag.tab == id
        let frame = drag.tabFrames[id] ?? .zero
        // Separators only between two inactive tabs, Chrome style.
        let next = i + 1 < group.tabs.count ? group.tabs[i + 1] : nil
        let separator = !selected && next != nil && next != active && hovered != id && hovered != next && drag.tab == nil
        return PaneTabLabel(tabID: id, selected: selected || isDragged, hovering: hovered == id, onClose: { host.close([id]) })
            .frame(width: width, height: selected ? TileMetrics.activeTab : TileMetrics.tab)
            .background { ChromeTabBackground(selected: selected || isDragged, hovering: hovered == id, fill: TileColors.body(id)) }
            .overlay(alignment: .trailing) {
                if separator { Rectangle().fill(Color.white(0.14)).frame(width: 1).padding(.vertical, 9) }
            }
            .offset(x: isDragged ? draggedOffset(frame) : shift(index: i))
            .opacity(isDragged && !draggingInOwnStrip ? 0 : 1)
            // Measured after the offset, so this is the tab's resting place. Measured
            // before it, the drag fed back into itself and the tab flickered.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PaneDrag.space)) } action: { drag.tabFrames[id] = $0 }
            .animation(isDragged ? nil : .spring(response: 0.26, dampingFraction: 0.86), value: drag.target)
            .zIndex(selected || isDragged ? 5 : 0)
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
            .onTapGesture { tree.activate(id); focus() }
            .onMiddleClick { host.close([id]) }
            .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named(PaneDrag.space))
                .onChanged { v in changed(id, v) }
                .onEnded { _ in commit(drag.target) })
            .contextMenu {
                if !GridItemID.isPanel(id), !GridItemID.isFile(id) {
                    Button("Rename…") { store.sheet = .renameSession(id) }
                    Button("Interrupt (⌃C)") { store.interruptSession(id) }
                    Divider()
                }
                if group.tabs.count > 1 {
                    Button("Move to New Pane on the Right") { tree.split(id, beside: group.id, edge: .right) }
                    Button("Move to New Pane Below") { tree.split(id, beside: group.id, edge: .bottom) }
                    Divider()
                }
                Button("Close Others") { host.close(group.tabs.filter { $0 != id }) }.disabled(group.tabs.count < 2)
                Button("Close", role: .destructive) { host.close([id]) }
            }
    }

    // MARK: Drag

    private var draggingInOwnStrip: Bool {
        if case .strip(let g, _)? = drag.target { return g == drag.source }
        return drag.target == nil
    }

    private func draggedOffset(_ frame: CGRect) -> CGFloat {
        guard draggingInOwnStrip, let strip = drag.stripFrames[group.id] else { return 0 }
        let x = drag.location.x - drag.grab.width
        return min(max(x, strip.minX + 8), strip.maxX - frame.width) - frame.minX
    }

    /// Tabs slide aside to open a gap where the dragged tab would land.
    private func shift(index i: Int) -> CGFloat {
        guard let dragged = drag.tab, group.tabs[i] != dragged else { return 0 }
        let w = drag.size.width
        let d = drag.source == group.id ? group.tabs.firstIndex(of: dragged) : nil
        let without = (d != nil && i > d!) ? i - 1 : i
        var out: CGFloat = 0
        if case .strip(let g, let k)? = drag.target, g == group.id, without >= k { out += w }
        if let d, i > d { out -= w }
        return out
    }

    private func changed(_ id: String, _ v: DragGesture.Value) {
        if drag.tab != id {
            let f = drag.tabFrames[id] ?? .zero
            drag.tab = id
            drag.source = group.id
            drag.grab = CGSize(width: v.startLocation.x - f.minX, height: v.startLocation.y - f.minY)
            drag.size = f.size
            tree.activate(id)
        }
        drag.location = v.location
        let t = Self.target(at: v.location, dragged: id, source: drag.source, tree: tree, drag: drag)
        if t != drag.target { drag.target = t }
    }

    static func target(at p: CGPoint, dragged: String, source: String?, tree: PaneTree, drag: PaneDrag) -> PaneDropTarget? {
        for g in tree.groups {
            guard let r = drag.stripFrames[g.id], r.insetBy(dx: 0, dy: -6).contains(p) else { continue }
            let center = p.x - drag.grab.width + drag.size.width / 2
            let others = g.tabs.filter { $0 != dragged }
            let k = others.filter { (drag.tabFrames[$0]?.midX ?? .infinity) < center }.count
            return .strip(group: g.id, index: k)
        }
        for g in tree.groups {
            guard let r = drag.bodyFrames[g.id], r.contains(p) else { continue }
            let alone = g.id == source && g.tabs.count == 1
            if alone { return nil }
            if let cell = TargetPicker.cell(at: p, in: r) {
                if let edge = cell { return .edge(group: g.id, edge) }
                return g.id == source ? nil : .center(group: g.id)
            }
            // Outside the picker: the nearest edge.
            let d: [(CGFloat, PaneEdge)] = [((p.x - r.minX) / r.width, .left), ((r.maxX - p.x) / r.width, .right),
                                            ((p.y - r.minY) / r.height, .top), ((r.maxY - p.y) / r.height, .bottom)]
            return .edge(group: g.id, d.min { $0.0 < $1.0 }!.1)
        }
        return nil
    }

    @ViewBuilder private var dropZones: some View {
        if drag.tab != nil, !isStripTarget, let r = drag.bodyFrames[group.id], r.contains(drag.location) || drag.target?.group == group.id {
            GeometryReader { geo in
                let s = geo.size
                ZStack(alignment: .topLeading) {
                    if let t = drag.target, t.group == group.id, let zone = Self.zone(t, s) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accent.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                            .overlay {
                                // The centre zone's label sits above the picker instead of under it.
                                Text(zone.label).font(Typo.ui(12, .semibold)).foregroundStyle(accent)
                                    .padding(.horizontal, 10).frame(height: 24)
                                    .background(Capsule().fill(Theme.popover))
                                    .offset(y: t == .center(group: group.id) ? -(TargetPicker.side / 2 + 22) : 0)
                            }
                            .frame(width: zone.rect.width - 8, height: zone.rect.height - 8)
                            .offset(x: zone.rect.minX + 4, y: zone.rect.minY + 4)
                    }
                    TargetPicker(highlight: drag.target?.group == group.id ? drag.target : nil, accent: accent)
                        .position(x: s.width / 2, y: s.height / 2)
                }
                .animation(.easeOut(duration: 0.12), value: drag.target)
            }
            .allowsHitTesting(false)
        }
    }

    /// Reordering inside a strip shows no picker.
    private var isStripTarget: Bool {
        if case .strip? = drag.target { return true }
        return false
    }

    static func zone(_ t: PaneDropTarget, _ s: CGSize) -> (rect: CGRect, label: String)? {
        switch t {
        case .edge(_, .left): (CGRect(x: 0, y: 0, width: s.width / 2, height: s.height), PaneEdge.left.label)
        case .edge(_, .right): (CGRect(x: s.width / 2, y: 0, width: s.width / 2, height: s.height), PaneEdge.right.label)
        case .edge(_, .top): (CGRect(x: 0, y: 0, width: s.width, height: s.height / 2), PaneEdge.top.label)
        case .edge(_, .bottom): (CGRect(x: 0, y: s.height / 2, width: s.width, height: s.height / 2), PaneEdge.bottom.label)
        case .center: (CGRect(origin: .zero, size: s), "Add to this pane")
        case .strip: nil
        }
    }
}

/// The tab look every strip shares: the active tab is a Chrome-style shape in
/// its body's colour, open at the bottom; the others get a faint hover fill.
struct ChromeTabBackground: View {
    let selected: Bool
    let hovering: Bool
    let fill: Color

    var body: some View {
        if selected {
            ChromeTabShape().fill(fill).padding(.horizontal, -TileMetrics.flare)
                // A hairline on the top and sides only; the bottom stays open into the body.
                .overlay(ChromeTabOutline().stroke(Color.white(0.08), lineWidth: 1).padding(.horizontal, -TileMetrics.flare))
        } else if hovering {
            UnevenRoundedRectangle(topLeadingRadius: TileMetrics.tabRadius, topTrailingRadius: TileMetrics.tabRadius)
                .fill(Color.white(0.04)).padding(.bottom, 3)
        }
    }
}

/// The centred 3 × 3 picker shown over a pane while dragging a tab.
struct TargetPicker: View {
    let highlight: PaneDropTarget?
    let accent: Color
    static let cell: CGFloat = 26
    static let spacing: CGFloat = 4
    static let inset: CGFloat = 6
    static var side: CGFloat { cell * 3 + spacing * 2 + inset * 2 }

    /// The picker cell under `p`: `.some(nil)` is the centre, `.some(edge)` a side, nil elsewhere.
    static func cell(at p: CGPoint, in r: CGRect) -> PaneEdge?? {
        let x = p.x - (r.midX - side / 2) - inset, y = p.y - (r.midY - side / 2) - inset
        let inner = side - inset * 2
        guard x >= 0, y >= 0, x < inner, y < inner else { return nil }
        return slot(Int(x / (cell + spacing)), Int(y / (cell + spacing)))
    }

    static func slot(_ col: Int, _ row: Int) -> PaneEdge?? {
        switch (col, row) {
        case (1, 1): .some(nil)
        case (0, 1): .some(.left)
        case (2, 1): .some(.right)
        case (1, 0): .some(.top)
        case (1, 2): .some(.bottom)
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: Self.spacing) {
                    ForEach(0..<3, id: \.self) { col in cellView(col, row) }
                }
            }
        }
        .padding(Self.inset)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.popover.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.popoverBorder))
        .shadow(color: .black(0.4), radius: 12, y: 6)
    }

    @ViewBuilder private func cellView(_ col: Int, _ row: Int) -> some View {
        if let target = Self.slot(col, row) {
            let on: Bool = {
                switch (highlight, target) {
                case (.center?, nil): true
                case (.edge(_, let e)?, let t?): e == t
                default: false
                }
            }()
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(on ? accent.opacity(0.25) : Color.white(0.05))
                RoundedRectangle(cornerRadius: 5).strokeBorder(on ? accent : Color.white(0.12))
                HalfShape(edge: target).fill(on ? accent : Color.white(0.35)).padding(5)
            }
            .frame(width: Self.cell, height: Self.cell)
        } else {
            Color.clear.frame(width: Self.cell, height: Self.cell)
        }
    }
}

/// The half of a picker cell the new pane would take (all of it for the centre).
private struct HalfShape: Shape {
    let edge: PaneEdge?
    func path(in r: CGRect) -> Path {
        let rect: CGRect = switch edge {
        case .left?: CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
        case .right?: CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
        case .top?: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
        case .bottom?: CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
        case nil: r
        }
        return Path(roundedRect: rect, cornerRadius: 1.5)
    }
}

/// Chrome tab outline: rounded top corners and concave flares at the bottom.
/// Drawn `flare` wider than the tab on each side.
struct ChromeTabShape: Shape {
    var radius: CGFloat = TileMetrics.tabRadius
    var flare: CGFloat = TileMetrics.flare

    func path(in r: CGRect) -> Path {
        var p = Path()
        let f = flare, rad = radius
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + f, y: r.maxY - f), control: CGPoint(x: r.minX + f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + f, y: r.minY + rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + f + rad, y: r.minY), control: CGPoint(x: r.minX + f, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - f - rad, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - f, y: r.minY + rad), control: CGPoint(x: r.maxX - f, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.maxY - f))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.maxX - f, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The visible edge of a Chrome tab: flares, sides and top, but not the bottom.
struct ChromeTabOutline: Shape {
    var radius: CGFloat = TileMetrics.tabRadius
    var flare: CGFloat = TileMetrics.flare

    func path(in r: CGRect) -> Path {
        var p = Path()
        let f = flare, rad = radius
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + f, y: r.maxY - f), control: CGPoint(x: r.minX + f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + f, y: r.minY + rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + f + rad, y: r.minY), control: CGPoint(x: r.minX + f, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - f - rad, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - f, y: r.minY + rad), control: CGPoint(x: r.maxX - f, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.maxY - f))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.maxX - f, y: r.maxY))
        return p
    }
}

/// Glyph, title, status dot and close button for one tab of any kind.
struct PaneTabLabel: View {
    @Environment(AppStore.self) private var store
    let tabID: String
    let selected: Bool
    var hovering = false
    var onClose: (() -> Void)? = nil

    static func title(_ store: AppStore) -> (String) -> String {
        { id in
            if let path = GridItemID.filePath(id) {
                let dirty = store.currentWorkspace?.isDirty(path) == true
                return (path as NSString).lastPathComponent + (dirty ? " •" : "")
            }
            if id == GridItemID.editor { return "Editor" }
            if let k = GridItemID.kind(id) {
                if k == .database, let d = GridItemID.panelInstance(id)?.resourceID.flatMap(store.database) { return d.name }
                if k == .dataTab, let ref = GridItemID.panelInstance(id)?.resourceID.flatMap(GridItemID.dataTabRef) {
                    let t = store.dataWorkspace.tab(ref.id)
                    return (t?.title ?? ref.object?.name ?? "console") + ((t?.pendingCount ?? 0) > 0 ? " •" : "")
                }
                if k == .remoteFiles, let h = GridItemID.panelInstance(id)?.resourceID.flatMap(store.host) { return "\(h.name) files" }
                return k.title
            }
            return store.session(id).map(store.displayTitle) ?? "Closed"
        }
    }

    var body: some View {
        let s = store.session(tabID)
        let title = Self.title(store)(tabID)
        HStack(spacing: 7) {
            glyph(s)
            Text(title).font(Typo.ui(12, selected ? .medium : .regular))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let s, s.state == .running || s.state == .needsInput {
                Circle().fill(s.state == .needsInput ? Theme.amber : Theme.green).frame(width: 6, height: 6)
                    .accessibilityLabel(s.state.label)
            }
            SidebarCloseButton(label: "Close \(title)") { onClose?() }
                .opacity(selected || hovering ? 1 : 0)
                .allowsHitTesting(selected || hovering)
        }
        .foregroundStyle(selected ? Theme.text : Theme.text3)
        .padding(.leading, 11).padding(.trailing, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func glyph(_ s: TerminalSession?) -> some View {
        if let path = GridItemID.filePath(tabID) {
            RoundedRectangle(cornerRadius: 2).fill(FileKinds.iconColor(for: (path as NSString).lastPathComponent)).frame(width: 7, height: 7)
                .frame(width: 13, height: 13)
        } else if GridItemID.kind(tabID) == .dataTab, let ref = GridItemID.panelInstance(tabID)?.resourceID.flatMap(GridItemID.dataTabRef) {
            // Tinted by the connection's environment, like the Databases screen's tabs.
            Image(systemName: ref.object == nil ? "chevron.right.square" : "tablecells").font(.system(size: 11, weight: .medium))
                .foregroundStyle(store.database(ref.connection).map { DWLook.env($0.tag) } ?? Theme.text2).frame(width: 13, height: 13)
        } else if let k = GridItemID.kind(tabID) {
            Image(systemName: k.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text2).frame(width: 13, height: 13)
        } else if tabID == GridItemID.editor {
            Image(systemName: "doc.text").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text2).frame(width: 13, height: 13)
        } else {
            SessionIcon(session: s, size: 13)
        }
    }
}
