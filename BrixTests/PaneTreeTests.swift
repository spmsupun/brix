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

@MainActor
final class SavedTabRestoreTests: XCTestCase {
    /// A relaunch keeps file, panel and data tabs in the tiled centre; only
    /// sessions that weren't restarted (and data tabs whose connection is gone) drop out.
    func testRemappedKeepsFileAndPanelTabs() {
        func dataTab(_ conn: String) -> String {
            let raw = Data([UUID().uuidString, conn].joined(separator: "\u{1F}").utf8).base64EncodedString()
            return "panel:dataTab:" + raw.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let kept = dataTab("db-1"), gone = dataTab("db-deleted")
        var t = PaneTree()
        for id in ["s-old", "s-closed", "file:src/a.swift", GridItemID.panel(.plan), GridItemID.panel(.agentFiles), GridItemID.database("db-1"), kept, gone] { t.add(id) }
        let out = WorkspaceStore.remapped(t, ["s-old": "s-new"]) { id in
            WorkspaceStore.keepsSavedTab(id, session: { $0 == "s-new" }, connection: { $0 == "db-1" })
        }
        XCTAssertEqual(out.allTabs, ["s-new", "file:src/a.swift", "panel:plan", "panel:agentFiles", "panel:database:db-1", kept])
    }

    func testGroupingAndLayouts() {
        let rank = ["a1": 0, "a2": 0, "b1": 1, "b2": 1, "c1": 2]
        var t = PaneTree()
        for id in ["b1", "a1", "c1", "b2"] { t.add(id) }
        t.sortTabs { rank[$0]! }
        XCTAssertEqual(t.allTabs, ["a1", "b1", "b2", "c1"])
        // A new tab lands after its kin, even in another pane.
        t.split("c1", beside: t.groups[0].id, edge: .right)
        t.add("a2", to: t.group(of: "c1")!.id)
        XCTAssertTrue(t.placeWithKin("a2") { rank[$0]! })
        XCTAssertEqual(t.groups.map(\.tabs), [["a1", "a2", "b1", "b2"], ["c1"]])
        XCTAssertFalse(t.placeWithKin("c1") { rank[$0]! })
        XCTAssertFalse(t.placeWithKin("c1") { _ in Int.max })

        // Placing a background tab keeps what each pane shows and where focus is.
        var u = PaneTree()
        u.add("a1"); u.add("b1")
        u.split("b1", beside: u.groups[0].id, edge: .right)
        u.add("a2", to: u.group(of: "b1")!.id)
        u.activate("b1")
        XCTAssertTrue(u.placeWithKin("a2") { rank[$0]! })
        XCTAssertEqual(u.group(of: "a2")?.tabs, ["a1", "a2"])
        XCTAssertEqual(u.group(of: "a1")?.active, "a1")
        XCTAssertEqual(u.focusedGroup, u.group(of: "b1")?.id)
        // Only the named panes are sorted.
        var v = PaneTree()
        v.add("b1"); v.add("a1"); v.add("c1")
        v.split("c1", beside: v.groups[0].id, edge: .right)
        v.add("b2", to: v.group(of: "c1")!.id)
        v.sortTabs(by: { rank[$0]! }, only: [v.group(of: "c1")!.id])
        XCTAssertEqual(v.groups.map(\.tabs), [["b1", "a1"], ["b2", "c1"]])

        XCTAssertEqual(PaneTree.chunked(["1", "2", "3", "4", "5"], into: 2), [["1", "2", "3"], ["4", "5"]])
        XCTAssertEqual(PaneTree.chunked(["1", "2", "3", "4", "5"], into: 4), [["1", "2"], ["3"], ["4"], ["5"]])
        XCTAssertEqual(PaneTree.chunked(["1", "2", "3", "4", "5", "6", "7", "8", "9"], into: 4).map(\.count), [3, 2, 2, 2])
        XCTAssertEqual(PaneTree.chunked(["1"], into: 4), [["1"]])
        XCTAssertEqual(PaneTree.chunked([], into: 2), [])
        let grid = PaneTree.tiled([["1"], ["2"], ["3"]], perRow: 2)
        XCTAssertEqual(grid.groups.map(\.tabs), [["1"], ["2"], ["3"]])
        guard case .split(_, true, let rows, _) = grid.root else { return XCTFail("expected stacked rows") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(PaneTree.tiled([["1", "2"]], perRow: 2).groups.count, 1)
    }
}
