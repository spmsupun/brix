import Foundation
import CoreGraphics

/// A group of tabs (terminal or agent session ids) with one showing.
struct TabGroup: Codable, Hashable, Identifiable {
    var id: String
    var tabs: [String]
    var active: String?

    static func make(_ tabs: [String] = []) -> TabGroup {
        TabGroup(id: "g-\(UUID().uuidString.prefix(6))", tabs: tabs, active: tabs.first)
    }
}

/// JetBrains-style split layout: groups of tabs, split side by side or stacked,
/// nested to any depth. A pure value type so every operation is unit tested.
indirect enum PaneNode: Codable, Hashable {
    case group(TabGroup)
    case split(id: String, vertical: Bool, children: [PaneNode], weights: [CGFloat])

    var groups: [TabGroup] {
        switch self {
        case .group(let g): [g]
        case .split(_, _, let children, _): children.flatMap(\.groups)
        }
    }
}

enum PaneEdge: String, Codable, CaseIterable { case left, right, top, bottom
    var label: String {
        switch self {
        case .left: "Split left"
        case .right: "Split right"
        case .top: "Split up"
        case .bottom: "Split down"
        }
    }
}

/// Where a dragged tab would land.
enum PaneDropTarget: Hashable {
    case strip(group: String, index: Int)
    case edge(group: String, PaneEdge)
    case center(group: String)

    var group: String {
        switch self {
        case .strip(let g, _), .edge(let g, _), .center(let g): g
        }
    }
}

struct PaneTree: Codable, Hashable {
    var root: PaneNode?
    /// Where new tabs go.
    var focusedGroup: String?
    /// A pane shown alone in the whole centre (⇧⌘↩); the tree is untouched.
    var maximized: String?

    var groups: [TabGroup] { root?.groups ?? [] }
    var allTabs: [String] { groups.flatMap(\.tabs) }
    var isEmpty: Bool { allTabs.isEmpty }

    func group(of tab: String) -> TabGroup? { groups.first { $0.tabs.contains(tab) } }
    func group(_ id: String) -> TabGroup? { groups.first { $0.id == id } }
    /// Ids of the tabs currently showing, one per group.
    var visibleTabs: [String] { groups.compactMap { $0.active ?? $0.tabs.first } }

    // MARK: Editing

    /// Adds a tab to `groupID`, the focused group, or a new group.
    mutating func add(_ tab: String, to groupID: String? = nil, at index: Int? = nil) {
        guard !allTabs.contains(tab) else { activate(tab); return }
        let target = groupID ?? focusedGroup ?? groups.first?.id
        if let target, update(target, { g in
            let i = min(max(index ?? g.tabs.count, 0), g.tabs.count)
            g.tabs.insert(tab, at: i)
            g.active = tab
        }) {
            focusedGroup = target
            return
        }
        let g = TabGroup.make([tab])
        if let root {
            self.root = Self.append(.group(g), to: root, vertical: false)
        } else {
            root = .group(g)
        }
        focusedGroup = g.id
    }

    mutating func activate(_ tab: String) {
        guard let g = group(of: tab) else { return }
        _ = update(g.id) { $0.active = tab }
        focusedGroup = g.id
    }

    mutating func remove(_ tab: String) {
        guard let g = group(of: tab) else { return }
        _ = update(g.id) { g in
            let i = g.tabs.firstIndex(of: tab) ?? 0
            g.tabs.removeAll { $0 == tab }
            if g.active == tab { g.active = g.tabs.isEmpty ? nil : g.tabs[min(i, g.tabs.count - 1)] }
        }
        prune()
    }

    /// Reorders within a group: lands at `index` of the list without the tab.
    mutating func move(_ tab: String, to groupID: String, at index: Int? = nil) {
        guard group(of: tab) != nil, group(groupID) != nil else { return }
        let source = group(of: tab)!.id
        _ = update(source) { g in
            g.tabs.removeAll { $0 == tab }
            if g.active == tab { g.active = g.tabs.first }
        }
        _ = update(groupID) { g in
            let i = min(max(index ?? g.tabs.count, 0), g.tabs.count)
            g.tabs.insert(tab, at: i)
            g.active = tab
        }
        focusedGroup = groupID
        prune()
    }

    /// Moves `tab` into a new group on `edge` of `groupID`.
    mutating func split(_ tab: String, beside groupID: String, edge: PaneEdge) {
        guard let target = group(groupID), let source = group(of: tab) else { return }
        // Splitting a group by its only tab would leave nothing behind.
        if source.id == target.id && target.tabs.count == 1 { return }
        _ = update(source.id) { g in
            g.tabs.removeAll { $0 == tab }
            if g.active == tab { g.active = g.tabs.first }
        }
        let fresh = TabGroup.make([tab])
        root = root.map { Self.insert(.group(fresh), beside: groupID, edge: edge, in: $0) }
        focusedGroup = fresh.id
        prune()
    }

    mutating func setWeights(split id: String, _ weights: [CGFloat]) {
        root = root.map { Self.mapSplit(id, in: $0) { _, children, _ in (children, weights) } }
    }

    /// Removes a whole pane and returns the tabs it held (the caller closes them).
    @discardableResult
    mutating func closeGroup(_ id: String) -> [String] {
        guard let g = group(id) else { return [] }
        _ = update(id) { $0.tabs = []; $0.active = nil }
        prune()
        return g.tabs
    }

    /// Adds `tab` to `groupID` and puts it in a new pane on `edge` (split right/down).
    mutating func splitNew(_ tab: String, beside groupID: String, edge: PaneEdge) {
        guard group(groupID) != nil else { add(tab); return }
        add(tab, to: groupID)
        split(tab, beside: groupID, edge: edge)
    }

    /// Turns a pane into a 2 × 2 grid: it keeps the top-left, `tabs` fill the rest.
    mutating func split2x2(_ groupID: String, with tabs: [String]) {
        guard tabs.count == 3, case .group(let g)? = root.flatMap({ Self.find(groupID, in: $0) }) else { return }
        let n = tabs.map { TabGroup.make([$0]) }
        let sid = { "s-\(UUID().uuidString.prefix(6))" }
        let grid = PaneNode.split(id: sid(), vertical: true, children: [
            .split(id: sid(), vertical: false, children: [.group(g), .group(n[0])], weights: [1, 1]),
            .split(id: sid(), vertical: false, children: [.group(n[1]), .group(n[2])], weights: [1, 1])
        ], weights: [1, 1])
        root = root.map { Self.replace(groupID, with: grid, in: $0) }
        focusedGroup = groupID
    }

    /// Exchanges the tabs of two panes, keeping the layout.
    mutating func swap(_ a: String, _ b: String) {
        guard let ga = group(a), let gb = group(b), a != b else { return }
        _ = update(a) { $0.tabs = gb.tabs; $0.active = gb.active }
        _ = update(b) { $0.tabs = ga.tabs; $0.active = ga.active }
        focusedGroup = b
    }

    /// Equal sizes for the children of one split, or every split when nil.
    mutating func equalize(split id: String? = nil) {
        func eq(_ n: PaneNode) -> PaneNode {
            guard case .split(let sid, let v, let c, let w) = n else { return n }
            let mine = id == nil || sid == id
            return .split(id: sid, vertical: v, children: c.map(eq), weights: mine ? Array(repeating: 1, count: c.count) : w)
        }
        root = root.map(eq)
    }

    mutating func toggleMaximized(_ id: String) {
        maximized = maximized == id ? nil : (group(id) == nil ? nil : id)
    }

    /// Applies a tab drop: reorder or move into a strip, split on an edge, or join a pane.
    mutating func drop(_ tab: String, on target: PaneDropTarget) {
        guard let source = group(of: tab)?.id else { return }
        switch target {
        case .strip(let g, let i): move(tab, to: g, at: i)
        case .edge(let g, let e): split(tab, beside: g, edge: e)
        case .center(let g) where g != source: move(tab, to: g)
        case .center: break
        }
    }

    // MARK: Geometry

    /// Each pane's frame in a unit square, from the split weights.
    var frames: [String: CGRect] {
        var out: [String: CGRect] = [:]
        func walk(_ n: PaneNode, _ r: CGRect) {
            switch n {
            case .group(let g): out[g.id] = r
            case .split(_, let v, let c, let w):
                let weights = w.count == c.count ? w : Array(repeating: 1, count: c.count)
                let sum = max(weights.reduce(0, +), 0.0001)
                var offset: CGFloat = 0
                for (i, child) in c.enumerated() {
                    let f = weights[i] / sum
                    let cr = v ? CGRect(x: r.minX, y: r.minY + offset * r.height, width: r.width, height: f * r.height)
                               : CGRect(x: r.minX + offset * r.width, y: r.minY, width: f * r.width, height: r.height)
                    walk(child, cr)
                    offset += f
                }
            }
        }
        if let root { walk(root, CGRect(x: 0, y: 0, width: 1, height: 1)) }
        return out
    }

    /// The pane next to `id` in a direction: touching that side, most overlap wins.
    func neighbour(of id: String, _ edge: PaneEdge) -> String? {
        let f = frames
        guard let me = f[id] else { return nil }
        let eps: CGFloat = 0.0001
        var best: (String, CGFloat)?
        for (gid, r) in f where gid != id {
            let touching: Bool, overlap: CGFloat
            switch edge {
            case .left: touching = abs(r.maxX - me.minX) < eps; overlap = min(r.maxY, me.maxY) - max(r.minY, me.minY)
            case .right: touching = abs(r.minX - me.maxX) < eps; overlap = min(r.maxY, me.maxY) - max(r.minY, me.minY)
            case .top: touching = abs(r.maxY - me.minY) < eps; overlap = min(r.maxX, me.maxX) - max(r.minX, me.minX)
            case .bottom: touching = abs(r.minY - me.maxY) < eps; overlap = min(r.maxX, me.maxX) - max(r.minX, me.minX)
            }
            if touching, overlap > eps, overlap > (best?.1 ?? 0) { best = (gid, overlap) }
        }
        return best?.0
    }

    /// Smallest size a node can take along an axis, given each pane's minimum.
    static func minimum(_ n: PaneNode, vertical: Bool, pane: CGFloat, gap: CGFloat) -> CGFloat {
        switch n {
        case .group: return pane
        case .split(_, let v, let c, _):
            let mins = c.map { minimum($0, vertical: vertical, pane: pane, gap: gap) }
            return v == vertical ? mins.reduce(0, +) + gap * CGFloat(max(c.count - 1, 0)) : (mins.max() ?? pane)
        }
    }

    /// Drops tabs that no longer exist and empty groups.
    mutating func retain(_ valid: Set<String>) {
        for g in groups {
            _ = update(g.id) { g in
                g.tabs.removeAll { !valid.contains($0) }
                if let a = g.active, !g.tabs.contains(a) { g.active = g.tabs.first }
            }
        }
        prune()
    }

    // MARK: Internals

    @discardableResult
    private mutating func update(_ groupID: String, _ change: (inout TabGroup) -> Void) -> Bool {
        guard let root, groups.contains(where: { $0.id == groupID }) else { return false }
        self.root = Self.mapGroup(groupID, in: root, change)
        return true
    }

    private static func mapGroup(_ id: String, in node: PaneNode, _ change: (inout TabGroup) -> Void) -> PaneNode {
        switch node {
        case .group(var g):
            if g.id == id { change(&g) }
            return .group(g)
        case .split(let sid, let v, let children, let w):
            return .split(id: sid, vertical: v, children: children.map { mapGroup(id, in: $0, change) }, weights: w)
        }
    }

    private static func find(_ id: String, in n: PaneNode) -> PaneNode? {
        switch n {
        case .group(let g): return g.id == id ? n : nil
        case .split(_, _, let c, _): return c.lazy.compactMap { find(id, in: $0) }.first
        }
    }

    private static func replace(_ id: String, with new: PaneNode, in n: PaneNode) -> PaneNode {
        switch n {
        case .group(let g): return g.id == id ? new : n
        case .split(let sid, let v, let c, let w): return .split(id: sid, vertical: v, children: c.map { replace(id, with: new, in: $0) }, weights: w)
        }
    }

    private static func mapSplit(_ id: String, in node: PaneNode, _ change: (Bool, [PaneNode], [CGFloat]) -> ([PaneNode], [CGFloat])) -> PaneNode {
        guard case .split(let sid, let v, let children, let w) = node else { return node }
        if sid == id {
            let (c, nw) = change(v, children, w)
            return .split(id: sid, vertical: v, children: c, weights: nw.count == c.count ? nw : Array(repeating: 1, count: c.count))
        }
        return .split(id: sid, vertical: v, children: children.map { mapSplit(id, in: $0, change) }, weights: w)
    }

    private static func append(_ new: PaneNode, to root: PaneNode, vertical: Bool) -> PaneNode {
        if case .split(let id, let v, let children, let w) = root, v == vertical {
            return .split(id: id, vertical: v, children: children + [new], weights: w + [1])
        }
        return .split(id: "s-\(UUID().uuidString.prefix(6))", vertical: vertical, children: [root, new], weights: [1, 1])
    }

    /// Puts `new` beside the group `id`. Joins the parent split when it already
    /// runs the same way, so repeated splits make even columns, not a staircase.
    private static func insert(_ new: PaneNode, beside id: String, edge: PaneEdge, in node: PaneNode) -> PaneNode {
        let vertical = edge == .top || edge == .bottom
        let before = edge == .left || edge == .top
        switch node {
        case .group(let g):
            guard g.id == id else { return node }
            return .split(id: "s-\(UUID().uuidString.prefix(6))", vertical: vertical, children: before ? [new, node] : [node, new], weights: [1, 1])
        case .split(let sid, let v, var children, var w):
            if v == vertical, let i = children.firstIndex(where: { if case .group(let g) = $0 { return g.id == id }; return false }) {
                children.insert(new, at: before ? i : i + 1)
                w.insert(w[i], at: before ? i : i + 1)
                return .split(id: sid, vertical: v, children: children, weights: w)
            }
            return .split(id: sid, vertical: v, children: children.map { insert(new, beside: id, edge: edge, in: $0) }, weights: w)
        }
    }

    /// Removes empty groups and splits left with a single child.
    private mutating func prune() {
        root = root.flatMap(Self.pruned)
        if let f = focusedGroup, !groups.contains(where: { $0.id == f }) { focusedGroup = groups.first?.id }
        if let m = maximized, !groups.contains(where: { $0.id == m }) { maximized = nil }
    }

    private static func pruned(_ node: PaneNode) -> PaneNode? {
        switch node {
        case .group(let g): return g.tabs.isEmpty ? nil : node
        case .split(let id, let v, let children, let w):
            var kept: [PaneNode] = [], weights: [CGFloat] = []
            for (i, c) in children.enumerated() {
                if let p = pruned(c) { kept.append(p); weights.append(i < w.count ? w[i] : 1) }
            }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0] }
            return .split(id: id, vertical: v, children: kept, weights: weights)
        }
    }
}

extension PaneTree {
    /// Converts the old "tabs of up to four panes" layout: every pane becomes a
    /// tab, and the active multi-pane tab keeps its split.
    init(legacy tabs: [PaneTab], active: String?) {
        self.init()
        let current = tabs.first { $0.id == active } ?? tabs.first
        for t in tabs { t.panes.forEach { add($0) } }
        guard let current, current.panes.count > 1, let home = group(of: current.panes[0])?.id else { return }
        for p in current.panes.dropFirst() { split(p, beside: home, edge: current.vertical ? .bottom : .right) }
        activate(current.panes[0])
    }
}
