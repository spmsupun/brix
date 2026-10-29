import XCTest
@testable import Brix

final class DockModelTests: XCTestCase {
    func testCodePresetPlacesPanels() {
        let l = DockLayout.preset(.code)
        XCTAssertEqual(l.left.map(\.kind), [.explorer])
        XCTAssertEqual(l.right.map(\.kind), [.sourceControl])
        XCTAssertEqual(l.bottom.map(\.kind), [.terminal])
        XCTAssertEqual(l.centre, .agents)
        XCTAssertEqual(l.presetName, "code")
    }

    func testFocusPresetHidesEverything() {
        XCTAssertTrue(DockLayout.preset(.focus).allPanels.isEmpty)
    }

    func testMoveToAnotherDock() {
        var l = DockLayout.preset(.code)
        let sc = l.right[0].id
        l.move(sc, to: .left)
        XCTAssertEqual(l.left.map(\.kind), [.explorer, .sourceControl])
        XCTAssertTrue(l.right.isEmpty)
        XCTAssertNil(l.presetName, "Changing a preset makes it custom")
        XCTAssertEqual(l.lastSide[.sourceControl], .left)
    }

    func testStackAboveAnotherPanel() {
        var l = DockLayout.preset(.code)
        let sc = l.right[0].id
        l.move(sc, to: .left, at: 0)
        XCTAssertEqual(l.left.map(\.kind), [.sourceControl, .explorer])
    }

    func testReorderWithinSameDock() {
        var l = DockLayout()
        let a = l.add(.explorer, to: .left), b = l.add(.notes, to: .left), c = l.add(.connections, to: .left)
        l.move(a.id, to: .left, at: 3)
        XCTAssertEqual(l.left.map(\.id), [b.id, c.id, a.id])
        l.move(c.id, to: .left, at: 0)
        XCTAssertEqual(l.left.map(\.id), [c.id, b.id, a.id])
    }

    func testHideAndToggleRestoresLastSide() {
        var l = DockLayout.preset(.code)
        l.move(l.left[0].id, to: .right)
        l.toggle(.explorer)
        XCTAssertFalse(l.contains(.explorer))
        l.toggle(.explorer)
        XCTAssertEqual(l.right.last?.kind, .explorer, "Re-adding uses the last side")
    }

    func testHiddenPanelKeepsItsIdWhenShownAgain() {
        var l = DockLayout.preset(.code)
        let id = l.bottom[0].id
        l.toggle(.terminal)
        l.toggle(.terminal)
        XCTAssertEqual(l.bottom.first?.id, id)
    }

    func testFloatAndRedock() {
        var l = DockLayout.preset(.code)
        let id = l.bottom[0].id
        l.float(id)
        XCTAssertTrue(l.isFloating(id))
        XCTAssertTrue(l.bottom.isEmpty)
        l.move(id, to: .bottom)
        XCTAssertFalse(l.isFloating(id))
        XCTAssertEqual(l.bottom.map(\.id), [id])
    }

    func testMultipleInstancesAllowedForTerminalsAndDatabases() {
        var l = DockLayout()
        l.add(.terminal, to: .bottom)
        l.add(.terminal, to: .bottom)
        l.add(.database, to: .bottom, resource: "atlas_dev")
        l.add(.database, to: .right, resource: "billing")
        XCTAssertEqual(l.bottom.filter { $0.kind == .terminal }.count, 2)
        XCTAssertEqual(Set(l.allPanels.filter { $0.kind == .database }.compactMap(\.resourceID)), ["atlas_dev", "billing"])
        XCTAssertEqual(Set(l.allPanels.map(\.id)).count, 4, "Instances have unique ids")
    }

    func testSingleInstanceKindMovesInsteadOfDuplicating() {
        var l = DockLayout.preset(.code)
        l.add(.explorer, to: .right)
        XCTAssertEqual(l.allPanels.filter { $0.kind == .explorer }.count, 1)
        XCTAssertEqual(l.right.last?.kind, .explorer)
    }

    func testResizeClampsKeepCentreVisible() {
        var l = DockLayout.preset(.code)
        let size = CGSize(width: 1100, height: 700)
        l.resize(.left, to: 5, available: size)
        XCTAssertEqual(l.leftWidth, DockLayout.minSide)
        l.resize(.left, to: 2000, available: size)
        XCTAssertLessThanOrEqual(l.leftWidth + l.rightWidth, size.width - DockLayout.minCentreWidth)
        l.resize(.bottom, to: 5000, available: size)
        XCTAssertEqual(l.bottomHeight, size.height - DockLayout.minCentreHeight)
        l.resize(.bottom, to: 1, available: size)
        XCTAssertEqual(l.bottomHeight, DockLayout.minBottom)
    }

    func testApplyPresetKeepsExistingInstances() {
        var l = DockLayout.preset(.code)
        let terminal = l.bottom[0]
        l.apply(.preset(.agent))
        l.apply(.preset(.code))
        XCTAssertEqual(l.bottom.first?.id, terminal.id, "Terminal keeps its id so its session survives")
    }

    func testCustomPresetRoundTrip() throws {
        var l = DockLayout.preset(.code)
        l.move(l.right[0].id, to: .bottom)
        l.add(.notes, to: .right)
        let preset = CustomPreset(id: "p1", name: "Mine", layout: l)
        let data = try JSONEncoder().encode(preset)
        let back = try JSONDecoder().decode(CustomPreset.self, from: data)
        XCTAssertEqual(back.layout, l)
    }

    func testDecodingToleratesMissingFields() throws {
        let json = #"{"left":[{"id":"explorer","kind":"explorer"}],"centre":"agents"}"#
        let l = try JSONDecoder().decode(DockLayout.self, from: Data(json.utf8))
        XCTAssertEqual(l.left.map(\.kind), [.explorer])
        XCTAssertEqual(l.centre, .agents)
        XCTAssertEqual(l.rightWidth, DockLayout().rightWidth)
    }

    func testCollapsePanel() {
        var l = DockLayout.preset(.review)
        XCTAssertTrue(l.collapsedPanels.contains("explorer"))
        l.togglePanelCollapsed("explorer")
        XCTAssertFalse(l.collapsedPanels.contains("explorer"))
    }
}

@MainActor
final class WorkspacePersistenceTests: XCTestCase {
    func testEachProjectRestoresItsOwnLayout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brix-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = Persistence(directory: dir)
        let kc = Keychain(service: "com.brix.tests.\(UUID().uuidString)")

        let store = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: persistence, keychain: kc, loadFromDisk: false)
        store.loadSampleWorkspace()
        let web = store.workspace(for: "atlas-web")
        let api = store.workspace(for: "atlas-api")
        web.apply(.review)
        api.apply(.agent)
        api.layout.add(.notes, to: .left)
        web.state.openFiles = ["CLAUDE.md"]
        store.saveNow()

        let reopened = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: persistence, keychain: kc, loadFromDisk: true)
        XCTAssertEqual(reopened.workspace(for: "atlas-web").layout.centre, .review)
        XCTAssertEqual(reopened.workspace(for: "atlas-web").state.openFiles, ["CLAUDE.md"])
        XCTAssertEqual(reopened.workspace(for: "atlas-api").layout.centre, .agents)
        XCTAssertEqual(reopened.workspace(for: "atlas-api").layout.left.map(\.kind), [.notes])
        XCTAssertEqual(reopened.library.projects.count, 6)
    }
}

final class RenameTests: XCTestCase {
    @MainActor
    func testRenameMovesTabsDraftsAndFilesInsideAFolder() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brix-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: dir),
                             keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"), loadFromDisk: false)
        store.loadSampleWorkspace()
        let ws = store.workspace(for: "atlas-web")
        ws.open("src/lib/stripe/intent.ts")
        ws.open("src/lib/stripe/client.ts")
        ws.open("README.md")
        ws.drafts["src/lib/stripe/intent.ts"] = "edited"

        ws.renamed(from: "src/lib/stripe", to: "src/lib/payments")

        XCTAssertTrue(ws.state.openFiles.contains("src/lib/payments/intent.ts"))
        XCTAssertFalse(ws.state.openFiles.contains { $0.hasPrefix("src/lib/stripe/") })
        let tabs = ws.state.panes.allTabs
        XCTAssertTrue(tabs.contains(GridItemID.file("src/lib/payments/client.ts")))
        XCTAssertFalse(tabs.contains(GridItemID.file("src/lib/stripe/client.ts")))
        XCTAssertEqual(tabs.filter { $0 == GridItemID.file("src/lib/payments/intent.ts") }.count, 1)
        XCTAssertEqual(ws.drafts["src/lib/payments/intent.ts"], "edited")
        XCTAssertNil(ws.drafts["src/lib/stripe/intent.ts"])
        XCTAssertEqual(ws.state.activeFile, "README.md")
        // A sibling whose name only starts the same way is untouched.
        ws.open("src/lib/stripe-old.ts")
        ws.renamed(from: "src/lib/payments", to: "src/lib/pay")
        XCTAssertTrue(ws.state.openFiles.contains("src/lib/stripe-old.ts"))

        // Reapplying a layout doesn't bring back a second tab for the file.
        ws.apply(.code)
        XCTAssertEqual(ws.state.panes.allTabs.filter { $0 == GridItemID.file("src/lib/pay/intent.ts") }.count, 1)
    }
}

@MainActor
final class UnseenSessionTests: XCTestCase {
    func testFinishedAgentStaysFlaggedUntilOpened() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brix-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: dir),
                             keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"), loadFromDisk: false)
        store.loadSampleWorkspace()
        let s = store.newTerminal(project: "atlas-web", kind: .agent, attach: false)
        store.setSessionState(s.id, .running)
        XCTAssertFalse(store.session(s.id)!.unseen)
        store.setSessionState(s.id, .idle)
        XCTAssertTrue(store.session(s.id)!.unseen, "done while not on screen")
        store.reveal(session: s.id)
        XCTAssertFalse(store.session(s.id)!.unseen, "opening it clears the flag")
    }
}

@MainActor
final class LoopBoxTests: XCTestCase {
    /// AppKit drops layer animations when a view leaves its window; the box
    /// must ask for the loop again when it's back.
    func testRestartsWhenShownInAWindowAgain() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
        let box = LoopBox()
        var restarts = 0
        box.restart = { restarts += 1 }
        win.contentView?.addSubview(box)
        box.removeFromSuperview()
        win.contentView?.addSubview(box)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(restarts, 2)
    }
}

@MainActor
final class TerminalPlacementTests: XCTestCase {
    /// The black-terminal bug: the session's terminal sat in a place that was
    /// hidden or tiny while the place on screen stayed empty.
    func testTerminalMovesToThePlaceOnScreen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brix-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: dir),
                             keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"), loadFromDisk: false)
        let id = "t-\(UUID().uuidString.prefix(6))"
        TerminalRegistry.shared.start(sessionID: id, argv: ["/bin/cat"], cwd: "/tmp", env: [:], fontSize: 12, store: store)
        defer { TerminalRegistry.shared.stop(id) }
        let term = try XCTUnwrap(TerminalRegistry.shared.view(id))

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        win.orderFrontRegardless()
        defer { win.orderOut(nil) }
        // Occlusion is reported a moment after the window appears.
        for _ in 0..<20 where !win.occlusionState.contains(.visible) { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        try XCTSkipUnless(win.occlusionState.contains(.visible), "the test window isn't on screen (headless run)")
        // A hidden place and one scrolled out of the window, both newer than the one on screen.
        let shown = TerminalContainer(frame: NSRect(x: 0, y: 0, width: 600, height: 280))
        let hidden = TerminalContainer(frame: NSRect(x: 0, y: 300, width: 400, height: 280))
        let offscreen = TerminalContainer(frame: NSRect(x: 2000, y: 2000, width: 400, height: 280))
        for c in [shown, hidden, offscreen] { win.contentView?.addSubview(c) }
        hidden.isHidden = true
        XCTAssertTrue(shown.isShowing)
        XCTAssertFalse(hidden.isShowing)
        XCTAssertFalse(offscreen.isShowing)

        LiveTerminalSurface.attach(id, to: shown)
        LiveTerminalSurface.attach(id, to: hidden)
        TerminalRegistry.shared.placeSoon(id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(term.superview === shown, "out of a hidden place")

        LiveTerminalSurface.attach(id, to: offscreen)
        TerminalRegistry.shared.placeSoon(id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(term.superview === shown, "the terminal belongs where it can be seen")
    }
}
