import SwiftUI

extension Array {
    /// Moves the element at `from` to the position of `to` (after it when moving right, before it when moving left).
    mutating func reorder(from: Int, onto to: Int) {
        guard from != to, indices.contains(from), indices.contains(to) else { return }
        insert(remove(at: from), at: to)
    }
}

/// Live drag state for one tab strip. The order only changes on drop, so a tab
/// can't get stuck mid-drag the way live reordering could.
@Observable final class TabDragState {
    static let space = "tabstrip"
    var id: String?
    var translation: CGFloat = 0
    var target: Int?
    var frames: [String: CGRect] = [:]
    var strip: CGRect = .zero
}

extension View {
    /// Hosts reorderable tabs: gives them a shared drag state and coordinate space.
    func tabStrip() -> some View { modifier(TabStripHost()) }

    /// Chrome-style reordering: the tab follows the pointer within its strip and
    /// neighbours slide aside; the new order is applied on release.
    func reorderableTab(_ id: String, order: [String], move: @escaping (_ from: String, _ onto: String) -> Void) -> some View {
        modifier(ReorderableTab(id: id, order: order, move: move))
    }
}

private struct TabStripHost: ViewModifier {
    @State private var state = TabDragState()
    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: TabDragState.space)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TabDragState.space)) } action: { state.strip = $0 }
            .environment(state)
    }
}

private struct ReorderableTab: ViewModifier {
    @Environment(TabDragState.self) private var state: TabDragState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: String
    let order: [String]
    let move: (String, String) -> Void

    private var dragging: Bool { state?.id == id }
    private var slide: Animation? { reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86) }

    func body(content: Content) -> some View {
        content
            // Solid while dragged, so it never looks see-through over its neighbours.
            .background { if dragging { UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7).fill(Theme.popover) } }
            .offset(x: dragging ? clamped : shift)
            // After the offset: the resting frame, not the moving one.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TabDragState.space)) } action: { state?.frames[id] = $0 }
            .zIndex(dragging ? 10 : 0)
            .shadow(color: dragging ? .black(0.35) : .clear, radius: 8, y: 2)
            .animation(dragging ? nil : slide, value: state?.target)
            .simultaneousGesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(TabDragState.space))
                    .onChanged(changed)
                    .onEnded { _ in end() }
            )
    }

    /// Dragged tab: follows the pointer but stays inside the strip.
    private var clamped: CGFloat {
        guard let state, let f = state.frames[id] else { return 0 }
        let lo = state.strip.minX - f.minX, hi = state.strip.maxX - f.maxX
        return min(max(state.translation, lo), max(lo, hi))
    }

    /// Other tabs slide by the dragged tab's width to open the landing gap.
    private var shift: CGFloat {
        guard let state, let dragged = state.id, let k = state.target,
              let d = order.firstIndex(of: dragged), let i = order.firstIndex(of: id),
              let w = state.frames[dragged]?.width else { return 0 }
        if d < i && i <= k { return -w }
        if k <= i && i < d { return w }
        return 0
    }

    private func changed(_ v: DragGesture.Value) {
        guard let state else { return }
        if state.id != id { state.id = id; state.target = order.firstIndex(of: id) }
        state.translation = v.translation.width
        guard let f = state.frames[id] else { return }
        let center = f.midX + clamped
        let others = order.filter { $0 != id }
        let k = others.filter { (state.frames[$0]?.midX ?? .infinity) < center }.count
        if k != state.target { state.target = k }
    }

    private func end() {
        guard let state else { return }
        let from = order.firstIndex(of: id), k = state.target
        withAnimation(slide) {
            if let from, let k, k != from {
                // `move` lands the tab at the target's position.
                move(id, order[k])
            }
            state.id = nil
            state.translation = 0
            state.target = nil
        }
    }
}

extension AppStore {
    /// Reorders sessions, which is the order of the terminal panel's tabs.
    func moveSession(_ from: String, onto to: String) {
        guard let a = sessions.firstIndex(where: { $0.id == from }), let b = sessions.firstIndex(where: { $0.id == to }) else { return }
        sessions.reorder(from: a, onto: b)
    }
}

// MARK: - Vertical lists (sidebar)

/// Drag state for one vertical list, keyed by the list's name.
@Observable final class RowDragState {
    var list: String?
    var id: String?
    var translation: CGFloat = 0
    var target: Int?
    var frames: [String: CGRect] = [:]
}

extension View {
    /// Drag a row up or down to reorder; rows slide aside and the order is
    /// applied on release. `list` keeps separate lists from mixing.
    func reorderableRow(_ id: String, list: String, order: [String], state: RowDragState, move: @escaping (_ from: Int, _ to: Int) -> Void) -> some View {
        modifier(ReorderableRow(id: id, list: list, order: order, state: state, move: move))
    }
}

private struct ReorderableRow: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: String
    let list: String
    let order: [String]
    let state: RowDragState
    let move: (Int, Int) -> Void

    private var key: String { "\(list)|\(id)" }
    private var dragging: Bool { state.id == key }
    private var slide: Animation? { reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86) }

    func body(content: Content) -> some View {
        content
            .background { if dragging { RoundedRectangle(cornerRadius: 7).fill(Theme.popover) } }
            .offset(y: dragging ? clamped : shift)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("sidebar")) } action: { state.frames[key] = $0 }
            .zIndex(dragging ? 10 : 0)
            .shadow(color: dragging ? .black(0.35) : .clear, radius: 8, y: 2)
            .animation(dragging ? nil : slide, value: state.target)
            .simultaneousGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named("sidebar"))
                    .onChanged(changed)
                    .onEnded { _ in end() }
            )
    }

    private func frame(_ i: String) -> CGRect? { state.frames["\(list)|\(i)"] }

    private var clamped: CGFloat {
        guard let f = frame(id), let first = order.first.flatMap(frame), let last = order.last.flatMap(frame) else { return state.translation }
        return min(max(state.translation, first.minY - f.minY), last.maxY - f.maxY)
    }

    private var shift: CGFloat {
        guard state.list == list, let dragged = state.id, let k = state.target,
              let d = order.firstIndex(where: { "\(list)|\($0)" == dragged }), let i = order.firstIndex(of: id),
              let h = state.frames[dragged]?.height else { return 0 }
        if d < i && i <= k { return -h }
        if k <= i && i < d { return h }
        return 0
    }

    private func changed(_ v: DragGesture.Value) {
        if state.id != key { state.list = list; state.id = key; state.target = order.firstIndex(of: id) }
        state.translation = v.translation.height
        guard let f = frame(id) else { return }
        let center = f.midY + clamped
        let k = order.filter { $0 != id }.filter { (frame($0)?.midY ?? .infinity) < center }.count
        if k != state.target { state.target = k }
    }

    private func end() {
        let from = order.firstIndex(of: id), k = state.target
        withAnimation(slide) {
            if let from, let k, k != from { move(from, k) }
            state.id = nil
            state.list = nil
            state.translation = 0
            state.target = nil
        }
    }
}
