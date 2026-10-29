import Foundation
import CoreGraphics

enum PanelKind: String, Codable, CaseIterable, Identifiable {
    case explorer, sourceControl, terminal, agent, inspector, connections, docker, database, serverShell, logs, notes, browser, plan, agentFiles, remoteFiles
    /// A table or SQL console tab (tiles only), and the record of its selected row.
    case dataTab, record
    var id: String { rawValue }

    var title: String {
        switch self {
        case .explorer: "Explorer"
        case .sourceControl: "Source Control"
        case .terminal: "Terminal"
        case .agent: "Agent"
        case .inspector: "Inspector"
        case .connections: "Connections"
        case .docker: "Docker"
        case .database: "Database"
        case .serverShell: "Server Shell"
        case .logs: "Logs"
        case .notes: "Notes"
        case .browser: "Browser Preview"
        case .plan: "Plan"
        case .agentFiles: "Agent Files"
        case .remoteFiles: "Server Files"
        case .dataTab: "Table"
        case .record: "Record"
        }
    }

    var symbol: String {
        switch self {
        case .explorer: "folder"
        case .sourceControl: "arrow.triangle.branch"
        case .terminal: "terminal"
        case .agent: "sparkle"
        case .inspector: "sidebar.right"
        case .connections: "link"
        case .docker: "shippingbox"
        case .database: "cylinder.split.1x2"
        case .serverShell: "globe"
        case .logs: "text.alignleft"
        case .notes: "note.text"
        case .browser: "safari"
        case .plan: "checklist"
        case .agentFiles: "doc.on.doc"
        case .remoteFiles: "externaldrive.connected.to.line.below"
        case .dataTab: "tablecells"
        case .record: "list.bullet.rectangle"
        }
    }

    /// Several instances allowed (two terminals, two database panels…).
    var allowsMultiple: Bool {
        switch self {
        case .terminal, .agent, .database, .serverShell, .logs, .remoteFiles, .dataTab: true
        default: false
        }
    }

    /// Default side when a panel is added without a target dock.
    var defaultSide: DockSide {
        switch self {
        case .explorer, .database: .left
        case .sourceControl, .inspector, .connections, .notes, .browser, .plan, .agentFiles, .remoteFiles, .record: .right
        case .terminal, .agent, .serverShell, .logs, .docker, .dataTab: .bottom
        }
    }

    var toggleShortcut: String? {
        switch self {
        case .explorer: "⌥⌘E"
        case .sourceControl: "⌥⌘G"
        case .terminal: "⌥⌘J"
        case .inspector: "⌥⌘I"
        case .connections: "⌥⌘L"
        default: nil
        }
    }
}

struct PanelInstance: Codable, Hashable, Identifiable {
    var id: String
    var kind: PanelKind
    /// Bound resource: database id, host id, docker id or log path.
    var resourceID: String? = nil
    var title: String? = nil

    var displayTitle: String { title ?? kind.title }

    static func make(_ kind: PanelKind, resource: String? = nil, title: String? = nil) -> PanelInstance {
        let id = kind.allowsMultiple ? "\(kind.rawValue)-\(UUID().uuidString.prefix(6))" : kind.rawValue
        return PanelInstance(id: id, kind: kind, resourceID: resource, title: title)
    }
}

enum DockSide: String, Codable, CaseIterable, Identifiable {
    case left, right, bottom
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var shortcut: String {
        switch self {
        case .left: "⌃⌥←"
        case .right: "⌃⌥→"
        case .bottom: "⌃⌥↓"
        }
    }
}

enum CentreMode: String, Codable, CaseIterable, Identifiable {
    case editor, agents, review
    var id: String { rawValue }
    var label: String {
        switch self {
        case .editor: "Editor"
        case .agents: "Agents & Terminals"
        case .review: "Review"
        }
    }
}

struct FloatingPanel: Codable, Hashable {
    var panel: PanelInstance
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat = 360
    var height: CGFloat = 300
}

enum BuiltinPreset: String, Codable, CaseIterable, Identifiable {
    case code, agent, review, focus
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var shortcut: String {
        switch self {
        case .code: "⌃⌘1"
        case .agent: "⌃⌘2"
        case .review: "⌃⌘3"
        case .focus: "⌃⌘4"
        }
    }

    /// Presets offered in the UI. Review and Focus stay decodable for old files.
    static let shown: [BuiltinPreset] = [.code, .agent]
}

struct CustomPreset: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var layout: DockLayout
    /// The tiled centre, with sessions stored as "new:terminal" / "new:agent:<id>" placeholders.
    var panes: PaneTree? = nil
}

/// The arrangement of a project workspace. A pure value type so it can be tested
/// without any UI and persisted per project.
struct DockLayout: Codable, Hashable {
    var left: [PanelInstance] = []
    var right: [PanelInstance] = []
    var bottom: [PanelInstance] = []
    var floating: [FloatingPanel] = []
    var leftWidth: CGFloat = 252
    var rightWidth: CGFloat = 290
    var bottomHeight: CGFloat = 262
    /// Relative size of each panel inside its stack (default 1).
    var weights: [String: CGFloat] = [:]
    /// Docks collapsed from the toolbar; their panels are kept.
    var collapsed: Set<DockSide> = []
    var centre: CentreMode = .editor
    /// Last side a panel kind lived on, so toggling restores it.
    var lastSide: [PanelKind: DockSide] = [:]
    /// Which preset the layout came from, nil once the user changes it.
    var presetName: String? = nil
    /// Panels shrunk to their header (still docked).
    var collapsedPanels: Set<String> = []
    /// Hidden panel instances kept so re-showing a panel reuses its id (and
    /// therefore its terminal session or database binding).
    var parked: [PanelInstance] = []

    init() {}

    // Tolerant decoding: fields added later default instead of failing the restore.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DockLayout()
        left = (try? c.decode([PanelInstance].self, forKey: .left)) ?? d.left
        right = (try? c.decode([PanelInstance].self, forKey: .right)) ?? d.right
        bottom = (try? c.decode([PanelInstance].self, forKey: .bottom)) ?? d.bottom
        floating = (try? c.decode([FloatingPanel].self, forKey: .floating)) ?? d.floating
        leftWidth = (try? c.decode(CGFloat.self, forKey: .leftWidth)) ?? d.leftWidth
        rightWidth = (try? c.decode(CGFloat.self, forKey: .rightWidth)) ?? d.rightWidth
        bottomHeight = (try? c.decode(CGFloat.self, forKey: .bottomHeight)) ?? d.bottomHeight
        weights = (try? c.decode([String: CGFloat].self, forKey: .weights)) ?? d.weights
        collapsed = (try? c.decode(Set<DockSide>.self, forKey: .collapsed)) ?? d.collapsed
        centre = (try? c.decode(CentreMode.self, forKey: .centre)) ?? d.centre
        lastSide = (try? c.decode([PanelKind: DockSide].self, forKey: .lastSide)) ?? d.lastSide
        presetName = try? c.decode(String.self, forKey: .presetName)
        collapsedPanels = (try? c.decode(Set<String>.self, forKey: .collapsedPanels)) ?? d.collapsedPanels
        parked = (try? c.decode([PanelInstance].self, forKey: .parked)) ?? d.parked
    }

    // Minimums so the centre never collapses.
    static let minSide: CGFloat = 180
    static let maxSide: CGFloat = 640
    static let minBottom: CGFloat = 120
    static let minCentreWidth: CGFloat = 360
    static let minCentreHeight: CGFloat = 200

    // MARK: Queries

    func panels(_ side: DockSide) -> [PanelInstance] {
        switch side {
        case .left: left
        case .right: right
        case .bottom: bottom
        }
    }

    var allPanels: [PanelInstance] { left + right + bottom + floating.map(\.panel) }

    func side(of id: String) -> DockSide? {
        DockSide.allCases.first { panels($0).contains { $0.id == id } }
    }

    func contains(_ kind: PanelKind) -> Bool { allPanels.contains { $0.kind == kind } }

    func isFloating(_ id: String) -> Bool { floating.contains { $0.panel.id == id } }

    func isVisible(_ side: DockSide) -> Bool { !panels(side).isEmpty && !collapsed.contains(side) }

    func size(_ side: DockSide) -> CGFloat {
        switch side {
        case .left: leftWidth
        case .right: rightWidth
        case .bottom: bottomHeight
        }
    }

    func weight(_ id: String) -> CGFloat { weights[id] ?? 1 }

    // MARK: Mutations

    private mutating func setPanels(_ side: DockSide, _ value: [PanelInstance]) {
        switch side {
        case .left: left = value
        case .right: right = value
        case .bottom: bottom = value
        }
    }

    /// Removes a panel from wherever it is and returns it.
    @discardableResult
    private mutating func detach(_ id: String) -> PanelInstance? {
        for side in DockSide.allCases {
            var list = panels(side)
            if let i = list.firstIndex(where: { $0.id == id }) {
                let p = list.remove(at: i)
                setPanels(side, list)
                return p
            }
        }
        if let i = floating.firstIndex(where: { $0.panel.id == id }) {
            return floating.remove(at: i).panel
        }
        return nil
    }

    /// Moves a panel to a dock. `index` nil appends; otherwise inserts at that
    /// position (used for "above/below another panel" drops).
    mutating func move(_ id: String, to side: DockSide, at index: Int? = nil) {
        let currentSide = self.side(of: id)
        guard currentSide != nil || isFloating(id) else { return }
        var adjusted = index
        if currentSide == side, let idx = index, let from = panels(side).firstIndex(where: { $0.id == id }), from < idx {
            adjusted = idx - 1
        }
        guard let panel = detach(id) else { return }
        var list = panels(side)
        let at = min(max(adjusted ?? list.count, 0), list.count)
        list.insert(panel, at: at)
        setPanels(side, list)
        lastSide[panel.kind] = side
        collapsed.remove(side)
        presetName = nil
    }

    mutating func float(_ id: String, at point: CGPoint = CGPoint(x: 120, y: 80)) {
        guard !isFloating(id), let panel = detach(id) else { return }
        floating.append(FloatingPanel(panel: panel, x: point.x, y: point.y))
        presetName = nil
    }

    mutating func moveFloating(_ id: String, to point: CGPoint) {
        guard let i = floating.firstIndex(where: { $0.panel.id == id }) else { return }
        floating[i].x = max(0, point.x)
        floating[i].y = max(0, point.y)
    }

    mutating func hide(_ id: String) {
        if let side = side(of: id), let p = panels(side).first(where: { $0.id == id }) {
            lastSide[p.kind] = side
        }
        if let p = detach(id) {
            parked.removeAll { $0.id == p.id }
            parked.append(p)
            if parked.count > 12 { parked.removeFirst(parked.count - 12) }
        }
        weights[id] = nil
        presetName = nil
    }

    /// Adds a panel. Single-instance kinds that already exist are moved instead.
    @discardableResult
    mutating func add(_ kind: PanelKind, to side: DockSide? = nil, resource: String? = nil, title: String? = nil) -> PanelInstance {
        let target = side ?? lastSide[kind] ?? kind.defaultSide
        if !kind.allowsMultiple, let existing = allPanels.first(where: { $0.kind == kind }) {
            move(existing.id, to: target)
            return existing
        }
        let p: PanelInstance
        if let i = parked.firstIndex(where: { $0.kind == kind && (resource == nil || $0.resourceID == resource) }) {
            p = parked.remove(at: i)
        } else {
            p = PanelInstance.make(kind, resource: resource, title: title)
        }
        var list = panels(target)
        list.append(p)
        setPanels(target, list)
        lastSide[kind] = target
        collapsed.remove(target)
        presetName = nil
        return p
    }

    /// ⌥⌘E style toggle: hides the kind if present, otherwise restores it.
    mutating func toggle(_ kind: PanelKind) {
        if let p = allPanels.first(where: { $0.kind == kind }) {
            hide(p.id)
        } else {
            add(kind)
        }
    }

    mutating func togglePanelCollapsed(_ id: String) {
        if collapsedPanels.contains(id) { collapsedPanels.remove(id) } else { collapsedPanels.insert(id) }
    }

    mutating func toggleCollapsed(_ side: DockSide) {
        if collapsed.contains(side) { collapsed.remove(side) } else { collapsed.insert(side) }
    }

    mutating func rename(_ id: String, to title: String) {
        for side in DockSide.allCases {
            var list = panels(side)
            if let i = list.firstIndex(where: { $0.id == id }) {
                list[i].title = title.isEmpty ? nil : title
                setPanels(side, list)
            }
        }
    }

    mutating func bind(_ id: String, resource: String?) {
        for side in DockSide.allCases {
            var list = panels(side)
            if let i = list.firstIndex(where: { $0.id == id }) {
                list[i].resourceID = resource
                setPanels(side, list)
            }
        }
    }

    /// Clamps a dock size against the available workspace size so the centre
    /// keeps its minimum.
    mutating func resize(_ side: DockSide, to value: CGFloat, available: CGSize) {
        switch side {
        case .left:
            let other = isVisible(.right) ? rightWidth : 0
            let maxW = min(Self.maxSide, available.width - other - Self.minCentreWidth)
            leftWidth = Self.clamp(value, Self.minSide, maxW)
        case .right:
            let other = isVisible(.left) ? leftWidth : 0
            let maxW = min(Self.maxSide, available.width - other - Self.minCentreWidth)
            rightWidth = Self.clamp(value, Self.minSide, maxW)
        case .bottom:
            let maxH = available.height - Self.minCentreHeight
            bottomHeight = Self.clamp(value, Self.minBottom, maxH)
        }
    }

    static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), max(lo, hi))
    }

    /// Re-applies clamps after a window resize.
    mutating func fit(available: CGSize) {
        resize(.left, to: leftWidth, available: available)
        resize(.right, to: rightWidth, available: available)
        resize(.bottom, to: bottomHeight, available: available)
    }

    mutating func setWeight(_ id: String, _ value: CGFloat) {
        weights[id] = min(max(value, 0.2), 5)
    }

    /// Same panels on the same sides with the same centre, ignoring panel ids
    /// and sizes. Used to tell whether applying a layout would change anything.
    func sameArrangement(as o: DockLayout) -> Bool {
        DockSide.allCases.allSatisfy { panels($0).map(\.kind) == o.panels($0).map(\.kind) }
            && floating.map(\.panel.kind) == o.floating.map(\.panel.kind) && centre == o.centre
    }

    // MARK: Presets

    static func preset(_ p: BuiltinPreset) -> DockLayout {
        var l = DockLayout()
        switch p {
        case .code:
            l.left = [.make(.explorer)]
            l.right = [.make(.sourceControl)]
            l.bottom = [.make(.terminal)]
            l.centre = .agents
        case .agent:
            // Everything lives in the centre grid (WorkspaceStore.arrangeAgentGrid).
            l.centre = .agents
        case .review:
            l.left = [.make(.sourceControl), .make(.explorer)]
            l.right = [.make(.inspector)]
            l.leftWidth = 286
            l.collapsedPanels = [PanelKind.explorer.rawValue]
            l.centre = .review
        case .focus:
            l.centre = .agents
        }
        l.presetName = p.rawValue
        for side in DockSide.allCases {
            for panel in l.panels(side) { l.lastSide[panel.kind] = side }
        }
        return l
    }

    /// Applies a preset but keeps existing panel instances (so terminals keep their
    /// sessions) where the preset needs the same kind.
    mutating func apply(_ preset: DockLayout) {
        var next = preset
        var pool = allPanels + parked
        for side in DockSide.allCases {
            let mapped = next.panels(side).map { p -> PanelInstance in
                guard let i = pool.firstIndex(where: { $0.kind == p.kind }) else { return p }
                return pool.remove(at: i)
            }
            next.setPanels(side, mapped)
        }
        next.parked = Array(pool.suffix(12))
        next.lastSide = lastSide.merging(preset.lastSide) { _, new in new }
        self = next
    }
}
