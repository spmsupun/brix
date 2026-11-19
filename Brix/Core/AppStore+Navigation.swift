import AppKit

/// Somewhere Back and Forward can return to: a screen, and in a project the tab
/// that had focus, or the server, database or container open on its page.
struct NavPlace: Hashable {
    var route: Route
    var tab: String? = nil
    var item: String? = nil
}

/// Browser-style history for this run. Visiting somewhere new drops the forward steps.
struct NavHistory {
    static let limit = 50
    private(set) var back: [NavPlace] = []
    private(set) var forward: [NavPlace] = []
    private(set) var current: NavPlace?

    mutating func visit(_ p: NavPlace) {
        guard p != current else { return }
        if let c = current {
            back.append(c)
            if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        }
        forward.removeAll()
        current = p
    }

    /// Steps back, dropping places `valid` rejects (a closed tab, a removed project).
    mutating func goBack(_ valid: (NavPlace) -> Bool) -> NavPlace? { step(back: true, valid) }
    mutating func goForward(_ valid: (NavPlace) -> Bool) -> NavPlace? { step(back: false, valid) }

    /// Where a step actually landed, when it couldn't be restored exactly.
    mutating func land(_ p: NavPlace) { current = p }

    private mutating func step(back isBack: Bool, _ valid: (NavPlace) -> Bool) -> NavPlace? {
        var from = isBack ? back : forward, to = isBack ? forward : back
        defer { if isBack { back = from; forward = to } else { forward = from; back = to } }
        while let p = from.popLast() {
            guard p != current, valid(p) else { continue }
            if let c = current { to.append(c) }
            current = p
            return p
        }
        return nil
    }
}

extension AppStore {
    var currentPlace: NavPlace {
        if route == .terminals { return NavPlace(route: route, tab: Self.focusedTab(terminalTree)) }
        if route == .ssh { return NavPlace(route: route, item: selectedHost) }
        if route == .dbConnections { return NavPlace(route: route, item: selectedDatabase) }
        if route == .docker, case .container(let id)? = dockerSelection { return NavPlace(route: route, item: id) }
        guard case .workspace(let id) = route, let ws = workspaces[id], ws.layout.centre == .agents else { return NavPlace(route: route) }
        return NavPlace(route: route, tab: Self.focusedTab(ws.state.panes))
    }

    private static func focusedTab(_ t: PaneTree) -> String? { t.focusedGroup.flatMap { t.group($0)?.active } }

    /// Called on every route or layout change; records once per run-loop turn so a
    /// change made in several steps is one place, not several. A change nobody just
    /// clicked or typed for (an agent opening a tab, a tab closing) replaces the
    /// current place instead, like a redirect, so it doesn't wipe Forward.
    func noteNavigation() {
        // Just after Back or Forward, the views settling (a terminal taking the keyboard back) isn't a new step.
        if let e = NSApp?.currentEvent, ProcessInfo.processInfo.systemUptime - e.timestamp < 1, Date() > navQuietUntil,
           [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseUp, .keyDown].contains(e.type) { navByUser = true }
        guard !navPending else { return }
        navPending = true
        Task { @MainActor [weak self] in self?.recordNavigation() }
    }

    private func recordNavigation() {
        guard navPending else { return }
        navPending = false
        if navByUser { nav.visit(currentPlace) } else { nav.land(currentPlace) }
        navByUser = false
    }

    @discardableResult func goBack() -> Bool {
        recordNavigation()
        guard let p = nav.goBack(canVisit) else { return false }
        show(p)
        return true
    }

    @discardableResult func goForward() -> Bool {
        recordNavigation()
        guard let p = nav.goForward(canVisit) else { return false }
        show(p)
        return true
    }

    /// Removed projects and hosts, closed projects and closed tabs are skipped.
    private func canVisit(_ p: NavPlace) -> Bool {
        switch p.route {
        case .workspace(let id), .projectSettings(let id), .projectHome(let id):
            guard project(id) != nil, library.openProjects.contains(id) else { return false }
        case .remoteFiles(let h):
            guard host(h) != nil else { return false }
        default: break
        }
        if let item = p.item {
            switch p.route {
            case .ssh: return host(item) != nil
            case .dbConnections: return database(item) != nil
            case .docker: return dockerTarget(item) != nil
            default: break
            }
        }
        guard let tab = p.tab else { return true }
        if p.route == .terminals { return terminalTree.group(of: tab) != nil }
        guard let id = p.route.projectID else { return true }
        return workspace(for: id).state.panes.group(of: tab) != nil
    }

    private func show(_ p: NavPlace) {
        navQuietUntil = Date().addingTimeInterval(0.6)
        if let item = p.item {
            switch p.route {
            case .ssh: selectedHost = item; inspector = .host(item)
            case .dbConnections: selectedDatabase = item
            case .docker: dockerTab = "containers"; dockerSelection = .container(item)
            default: break
            }
        }
        go(p.route)
        if let tab = p.tab {
            if p.route == .terminals {
                terminalTree.activate(tab)
            } else if let ws = currentWorkspace {
                ws.state.panes.activate(tab)
                ws.layout.centre = .agents
            }
            // The keyboard follows, or the terminal that had it pulls the focus back.
            if session(tab) != nil {
                focusedSessionID = tab
                DispatchQueue.main.async { TerminalRegistry.shared.focus(tab) }
            }
        }
        nav.land(currentPlace)
    }

    /// The mouse's back and forward buttons, and a trackpad swipe set to "Swipe between pages".
    func installNavigationMonitor() {
        guard navMonitor == nil else { return }
        noteNavigation()  // the screen Brix opens on
        navMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp, .swipe]) { [weak self] e in
            // Only the main window, with no sheet over it; Settings and dialogs keep the event.
            guard let self, let w = e.window, w === WindowChrome.main, w.attachedSheet == nil else { return e }
            let back: Bool
            if e.type == .swipe {
                guard e.deltaX != 0 else { return e }
                back = e.deltaX > 0  // fingers moving right, like Safari
            } else {
                guard e.buttonNumber == 3 || e.buttonNumber == 4 else { return e }
                back = e.buttonNumber == 3
            }
            // Nowhere to go: the event carries on to whatever is under the pointer.
            return (back ? goBack() : goForward()) ? nil : e
        }
    }
}
