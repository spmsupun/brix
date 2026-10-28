import XCTest
@testable import Brix

final class PaneTreeTests: XCTestCase {
    func testAddRemoveAndPrune() {
        var t = PaneTree()
        t.add("a"); t.add("b")
        XCTAssertEqual(t.groups.count, 1)
        XCTAssertEqual(t.groups[0].tabs, ["a", "b"])
        XCTAssertEqual(t.groups[0].active, "b")
        t.remove("b")
        XCTAssertEqual(t.groups[0].active, "a")
        t.remove("a")
        XCTAssertNil(t.root)
    }

    func testSplitAndCollapseBack() {
        var t = PaneTree()
        t.add("a"); t.add("b"); t.add("c")
        let g = t.groups[0].id
        t.split("c", beside: g, edge: .right)
        XCTAssertEqual(t.groups.map(\.tabs), [["a", "b"], ["c"]])
        // Splitting again the same way joins the same row instead of nesting.
        t.split("b", beside: t.group(of: "c")!.id, edge: .right)
        guard case .split(_, let vertical, let children, let weights) = t.root else { return XCTFail("expected a split") }
        XCTAssertFalse(vertical)
        XCTAssertEqual(children.count, 3)
        XCTAssertEqual(weights.count, 3)
        // Moving the last tab out of a group removes the group.
        t.move("c", to: t.group(of: "a")!.id, at: 0)
        XCTAssertEqual(t.groups.map(\.tabs), [["c", "a"], ["b"]])
        t.move("b", to: t.group(of: "a")!.id)
        XCTAssertEqual(t.groups.count, 1)
        if case .split = t.root { XCTFail("single group should not stay wrapped in a split") }
    }

    func testStackedSplitAndReorder() {
        var t = PaneTree()
        t.add("a"); t.add("b")
        t.split("b", beside: t.groups[0].id, edge: .top)
        guard case .split(_, true, let children, _) = t.root else { return XCTFail("expected a vertical split") }
        XCTAssertEqual(children.first?.groups.first?.tabs, ["b"])
        t.add("c", to: t.group(of: "a")!.id)
        t.move("c", to: t.group(of: "a")!.id, at: 0)
        XCTAssertEqual(t.group(of: "a")?.tabs, ["c", "a"])
    }

    func testCannotSplitAGroupByItsOnlyTab() {
        var t = PaneTree()
        t.add("a")
        t.split("a", beside: t.groups[0].id, edge: .right)
        XCTAssertEqual(t.groups.count, 1)
    }

    func testRetainDropsClosedSessions() {
        var t = PaneTree()
        t.add("a"); t.add("b")
        t.split("b", beside: t.groups[0].id, edge: .right)
        t.retain(["a"])
        XCTAssertEqual(t.allTabs, ["a"])
        XCTAssertEqual(t.groups.count, 1)
    }

    func testLegacyConversionKeepsActiveSplit() {
        let a = PaneTab(title: "x", panes: ["1", "2"], vertical: true)
        let b = PaneTab(title: "y", panes: ["3"])
        let t = PaneTree(legacy: [a, b], active: a.id)
        XCTAssertEqual(Set(t.allTabs), ["1", "2", "3"])
        XCTAssertEqual(t.groups.count, 2)
        XCTAssertEqual(t.group(of: "1")?.active, "1")
    }

    func testCodableRoundTrip() throws {
        var t = PaneTree()
        t.add("a"); t.add("b")
        t.split("b", beside: t.groups[0].id, edge: .bottom)
        let back = try JSONDecoder().decode(PaneTree.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
    }

    // MARK: Tiled centre

    func testSplitCloseAndNormalise() {
        var t = PaneTree()
        t.add("a")
        let a = t.groups[0].id
        t.splitNew("b", beside: a, edge: .right)
        t.splitNew("c", beside: t.group(of: "b")!.id, edge: .bottom)
        t.splitNew("d", beside: a, edge: .bottom)
        t.splitNew("e", beside: t.group(of: "c")!.id, edge: .right)
        XCTAssertEqual(t.groups.count, 5)
        for id in ["e", "d", "c", "b"] { t.closeGroup(t.group(of: id)!.id) }
        XCTAssertEqual(t.groups.count, 1)
        guard case .group(let g)? = t.root else { return XCTFail("one pane left must not be wrapped in a split") }
        XCTAssertEqual(g.tabs, ["a"])
        XCTAssertFalse(Self.hasDegenerate(t.root!), "no empty panes or one-child splits")
    }

    static func hasDegenerate(_ n: PaneNode) -> Bool {
        switch n {
        case .group(let g): return g.tabs.isEmpty
        case .split(_, _, let c, let w): return c.count < 2 || w.count != c.count || c.contains(where: hasDegenerate)
        }
    }

    func testIndependentRatiosAndRoundTrip() throws {
        var t = PaneTree()
        t.add("claude"); t.add("zsh")
        let p1 = t.groups[0].id
        t.splitNew("build", beside: p1, edge: .right)
        let topRow = t.root!
        guard case .split(let topID, _, _, _) = topRow else { return XCTFail() }
        // Bottom row as its own split under the top row.
        t.splitNew("panel:explorer", beside: p1, edge: .bottom)
        t.add("file:src/app.ts", to: t.group(of: "panel:explorer")!.id)
        t.split("file:src/app.ts", beside: t.group(of: "panel:explorer")!.id, edge: .right)
        t.setWeights(split: topID, [1, 1])
        let f = t.frames
        let explorer = f[t.group(of: "panel:explorer")!.id]!, editor = f[t.group(of: "file:src/app.ts")!.id]!
        XCTAssertEqual(explorer.minY, editor.minY, accuracy: 0.0001)
        let back = try JSONDecoder().decode(PaneTree.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
        XCTAssertEqual(back.frames, f)
    }

    func testDropOnEveryZone() {
        func fresh() -> (PaneTree, String, String) {
            var t = PaneTree()
            t.add("a"); t.add("x")
            let g = t.groups[0].id
            t.splitNew("b", beside: g, edge: .right)
            return (t, g, t.group(of: "b")!.id)
        }
        for edge in PaneEdge.allCases {
            var (t, _, target) = fresh()
            t.drop("x", on: .edge(group: target, edge))
            XCTAssertEqual(t.groups.count, 3, "\(edge) splits")
            let f = t.frames, nf = f[t.group(of: "x")!.id]!, bf = f[t.group(of: "b")!.id]!
            switch edge {
            case .left: XCTAssertLessThan(nf.minX, bf.minX)
            case .right: XCTAssertGreaterThan(nf.minX, bf.minX)
            case .top: XCTAssertLessThan(nf.minY, bf.minY)
            case .bottom: XCTAssertGreaterThan(nf.minY, bf.minY)
            }
        }
        var (t, source, target) = fresh()
        t.drop("x", on: .center(group: target))
        XCTAssertEqual(t.group(of: "x")?.id, target)
        XCTAssertEqual(t.group(target)?.active, "x")
        XCTAssertEqual(t.group(source)?.tabs, ["a"])
        // Dropping a pane's only tab on its own centre does nothing.
        t.drop("b", on: .center(group: target))
        XCTAssertEqual(t.group(of: "b")?.id, target)
        // Moving the last tab out removes its pane.
        t.drop("a", on: .strip(group: target, index: 0))
        XCTAssertEqual(t.groups.count, 1)
        XCTAssertEqual(t.groups[0].tabs, ["a", "b", "x"])
    }

    func testNeighboursSwapEqualizeMaximize() {
        var t = PaneTree()
        t.add("a")
        let a = t.groups[0].id
        t.split2x2(a, with: ["b", "c", "d"])
        let ga = t.group(of: "a")!.id, gb = t.group(of: "b")!.id, gc = t.group(of: "c")!.id
        XCTAssertEqual(t.neighbour(of: ga, .right), gb)
        XCTAssertEqual(t.neighbour(of: ga, .bottom), gc)
        XCTAssertNil(t.neighbour(of: ga, .left))
        t.swap(ga, gb)
        XCTAssertEqual(t.group(ga)?.tabs, ["b"])
        XCTAssertEqual(t.group(gb)?.tabs, ["a"])
        if case .split(let id, _, _, _) = t.root { t.setWeights(split: id, [3, 1]) }
        t.equalize()
        if case .split(_, _, _, let w) = t.root { XCTAssertEqual(w, [1, 1]) }
        t.toggleMaximized(gc)
        XCTAssertEqual(t.maximized, gc)
        t.closeGroup(gc)
        XCTAssertNil(t.maximized, "closing the maximised pane clears it")
    }

    func testMinimumSizeOfNestedSplits() {
        var t = PaneTree()
        t.add("a")
        t.split2x2(t.groups[0].id, with: ["b", "c", "d"])
        XCTAssertEqual(PaneTree.minimum(t.root!, vertical: false, pane: 160, gap: 6), 326)
        XCTAssertEqual(PaneTree.minimum(t.root!, vertical: true, pane: 120, gap: 6), 246)
    }
}
