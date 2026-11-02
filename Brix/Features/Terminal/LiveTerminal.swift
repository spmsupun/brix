import AppKit
import SwiftUI
import SwiftTerm
import os

/// A SwiftTerm view running a real process in a PTY. Session cards read the
/// last lines from its screen.
final class BrixTerminalView: LocalProcessTerminalView {
    let sessionID: String
    weak var store: AppStore?
    private(set) var lastData = Date.distantPast
    private var idle = true
    private var idleTimer: Timer?
    private lazy var relay = DelegateRelay(owner: self)
    /// Set on SwiftTerm's parse thread when output arrives; cleared on main.
    private let outputPending = OSAllocatedUnfairLock(initialState: false)

    init(sessionID: String, store: AppStore, fontSize: CGFloat) {
        self.sessionID = sessionID
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360), font: nil, options: TerminalOptions(scrollback: 10_000))
        wantsLayer = true
        processDelegate = relay
        applyTheme(fontSize: fontSize, accent: store.settings.accent)
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        // SwiftTerm hands output straight to its parser and never calls
        // dataReceived(slice:), so this is the only sign of output. It runs on the
        // parse thread for every batch: at most one hop to main per 0.2 s.
        let pending = outputPending
        setProcessOutputHandler { [weak self] in
            guard pending.withLock({ p in defer { p = true }; return !p }) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { self?.outputArrived() }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { idleTimer?.invalidate() }

    // MARK: Context menu

    /// Right-click always opens Brix's menu, even while a program (an agent, vim)
    /// reads the mouse; SwiftTerm would otherwise hand the click to it.
    override func rightMouseDown(with event: NSEvent) {
        guard let m = menu(for: event) else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        // Copy and Paste go to SwiftTerm, which greys Copy out with nothing selected.
        m.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        m.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
        m.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        m.addItem(.separator())
        m.addItem(item("Clear", #selector(menuClear)))
        m.addItem(item("Interrupt (⌃C)", #selector(menuInterrupt)))
        m.addItem(.separator())
        if let st = store, let s = st.session(sessionID), s.kind == .agent, s.externalID != nil, st.agent(for: s)?.binary == "claude" {
            m.addItem(item("Open as Chat", #selector(menuOpenAsChat)))
        }
        m.addItem(item("Rename…", #selector(menuRename)))
        m.addItem(item("Close", #selector(menuClose)))
        return m
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func menuClear() { store?.clearSession(sessionID) }
    @objc private func menuInterrupt() { store?.interruptSession(sessionID) }
    @objc private func menuRename() { store?.sheet = .renameSession(sessionID) }
    @objc private func menuOpenAsChat() { store?.reopen(sessionID, asChat: true) }
    @objc private func menuClose() { store?.closeSession(sessionID) }

    private var accent: AccentChoice = .lime

    /// SwiftTerm stores concrete colours, so dynamic theme colours are resolved
    /// here and again whenever the appearance changes.
    func applyTheme(fontSize: CGFloat, accent: AccentChoice) {
        self.accent = accent
        let f = NSFont.code(ofSize: fontSize, weight: .regular)
        if font.pointSize != fontSize || font.familyName != f.familyName { font = f }
        let ap = effectiveAppearance
        nativeBackgroundColor = NSColor(Theme.terminal).resolved(for: ap)
        nativeForegroundColor = NSColor(Theme.body).resolved(for: ap)
        caretColor = NSColor(accent.color).resolved(for: ap)
        selectedTextBackgroundColor = NSColor(accent.color).resolved(for: ap).withAlphaComponent(0.3)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme(fontSize: font.pointSize, accent: accent)
    }

    /// Back on screen after another screen was shown (Git, Settings): SwiftTerm
    /// only redraws rows that changed, so an idle session stayed black until new
    /// output arrived. Draw the whole view once.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsDisplay = true }
    }

    /// A click (or a move between panes) gave this terminal the keyboard: its
    /// pane becomes the focused one. The pane's tap gesture never sees clicks
    /// that the terminal handles itself. (SwiftTerm's becomeFirstResponder can't be
    /// overridden; it sets this.)
    override var hasFocus: Bool {
        didSet { if hasFocus { store?.terminalFocused(sessionID) } }
    }

    /// Closing: SIGHUP to the shell's process group and its foreground job, as
    /// closing a terminal window does (interactive zsh ignores SIGTERM and left
    /// its jobs running), then SIGKILL to both if the shell is still there.
    func hangUp() {
        idleTimer?.invalidate()
        let shell = process.shellPid
        guard shell > 0, process.running else { return }
        let fg = process.childfd >= 0 ? tcgetpgrp(process.childfd) : -1
        let groups = Set([shell, fg].filter { $0 > 0 })
        groups.forEach { killpg($0, SIGHUP) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [process] in
            if process?.running == true { groups.forEach { killpg($0, SIGKILL) } }
        }
    }

    /// Moved to a screen with another scale (an external display): draw again.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let grew = newSize != frame.size
        super.setFrameSize(newSize)
        if grew { needsDisplay = true }
    }

    private func outputArrived() {
        outputPending.withLock { $0 = false }
        lastData = Date()
        // An agent's state is read from its screen: now, rather than on the next tick.
        if isAgent { checkIdle(); return }
        // Local shells are tracked by their foreground process in checkIdle.
        if idle, foregroundCommand() == nil {
            idle = false
            store?.liveIdle(sessionID, idle: false)
        }
    }

    /// The last 60 non-blank lines of the screen and the scrollback above it.
    var recentLines: [String] {
        let rows = terminalContentSnapshot(region: .history(maximumScrollbackRows: 60))?.rows.map(\.text) ?? []
        return Array(rows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(60))
    }

    private func checkIdle() {
        // Agent TUIs redraw (clocks, status lines) even when waiting, so output
        // alone doesn't mean work. Read the visible screen instead: a running
        // turn shows "esc to interrupt" or a spinner word ("Cogitating…"), and a
        // question shows a choice list ("Do you want to…", "❯ 1. Yes").
        if isAgent {
            let screen = visibleScreen()
            if Self.screenShowsWork(screen) { lastWorkHint = Date() }
            let working = Date().timeIntervalSince(lastWorkHint) < 2.5
            let state: SessionState = working ? .running : Self.screenAsksInput(screen) ? .needsInput : .idle
            if state != agentState {
                agentState = state
                store?.liveActivity(sessionID, lastLines: recentLines, exited: nil)
                store?.liveAgentState(sessionID, state)
            }
            return
        }
        // A local shell is busy while a command runs in front of it, not while it
        // prints: prompts with clocks or Git status redraw by themselves.
        if let fg = foregroundCommand() {
            var busy = fg != ""
            // An agent typed into a shell (claude, codex) stays in front while it
            // waits for you: read its screen like an agent session's instead.
            if busy, Self.agentCommands.contains(fg) {
                let screen = visibleScreen()
                if Self.screenShowsWork(screen) { lastWorkHint = Date() }
                busy = Date().timeIntervalSince(lastWorkHint) < 2.5
            }
            if busy != !idle || fg != lastForeground {
                idle = !busy
                lastForeground = fg
                store?.liveActivity(sessionID, lastLines: recentLines, exited: nil)
                store?.liveForeground(sessionID, command: fg.isEmpty ? nil : fg, busy: busy)
            }
            return
        }
        guard !idle, Date().timeIntervalSince(lastData) > 2.5 else { return }
        idle = true
        store?.liveActivity(sessionID, lastLines: recentLines, exited: nil)
        store?.liveIdle(sessionID, idle: true)
    }

    private var lastForeground: String?
    /// Process names of agent CLIs (Homebrew's Claude runs as claude.exe).
    static let agentCommands: Set<String> = ["claude", "claude.exe", "codex", "gemini"]

    /// For a local shell: "" when the shell itself is in front (waiting at its
    /// prompt), else the name of the command running in it. nil when that can't
    /// be told (an ssh session, or the terminal has no process yet).
    func foregroundCommand() -> String? {
        guard let s = store?.session(sessionID), s.kind == .shell, s.hostID == nil else { return nil }
        let shell = process.shellPid, fd = process.childfd
        guard shell > 0, fd >= 0 else { return nil }
        let fg = tcgetpgrp(fd)
        guard fg > 0 else { return nil }
        if fg == shell { return "" }
        var name = [CChar](repeating: 0, count: 256)
        let n = proc_name(fg, &name, UInt32(name.count))
        return n > 0 ? String(cString: name) : "command"
    }

    private var isAgent: Bool { store?.session(sessionID)?.kind == .agent }
    private var agentState: SessionState?
    private var lastWorkHint = Date.distantPast

    /// A prompt was just sent: count as working until the agent's own hint shows.
    func markWorking() { lastWorkHint = Date() }

    /// The bottom of the screen, where an agent's spinner, prompt box and
    /// questions live. Chat text further up never counts. Room for the task
    /// list Claude draws under its spinner, which pushed the spinner out of a
    /// 10-line window.
    private func visibleScreen() -> String {
        let rows = terminalContentSnapshot(region: .history(maximumScrollbackRows: -1))?.rows.map(\.text) ?? []
        return Self.bottom(rows)
    }

    static func bottom(_ rows: [String], lines: Int = 24) -> String {
        rows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(lines).joined(separator: "\n")
    }

    static func screenShowsWork(_ screen: String) -> Bool {
        let s = screen.lowercased()
        if s.contains("esc to interrupt") || s.contains("ctrl+c to interrupt") { return true }
        // Claude waiting on its own background agents or shells ("✱ Waiting for 1 background agent
        // to finish") is still busy, though nothing spins.
        if s.range(of: #"waiting for \d+ background (agent|task|shell)"#, options: .regularExpression) != nil { return true }
        // Its agent list under the prompt while background agents run: "● main" then a
        // "○ general-purpose  Running the tests" row for each of them.
        if screen.range(of: #"(?m)^\s*●\s+main\s*$"#, options: .regularExpression) != nil,
           screen.range(of: #"(?m)^\s*○\s+\S+\s{2,}\S"#, options: .regularExpression) != nil { return true }
        // Claude Code's spinner row: one of its star glyphs, then a capitalised word and an ellipsis
        // ("✶ Cogitating…", "✳ Sautéing…", "✢ Dilly-dallying…", "· Beboppin'…"). Claude no longer
        // prints "esc to interrupt" there, so this row is the only sign.
        return screen.range(of: #"(?m)^\s*[·✢✳✶✻✽*]\s+\p{Lu}[\p{L}'-]*…"#, options: .regularExpression) != nil
    }

    /// The agent is asking something: a numbered choice list or a y/n prompt.
    /// A question in the chat text alone doesn't count.
    static func screenAsksInput(_ screen: String) -> Bool {
        let s = screen.lowercased()
        if s.contains("(y/n)") || s.contains("[y/n]") { return true }
        return screen.range(of: #"(?m)^\s*[❯›>]\s*1\.\s"#, options: .regularExpression) != nil
    }

    // MARK: Process events (via DelegateRelay)

    func directoryChanged(_ directory: String?) {
        guard let directory, let store, let i = store.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let path = URL(string: directory)?.path ?? directory
        let home = NSHomeDirectory()
        store.sessions[i].cwd = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    func terminated(_ exitCode: Int32?) {
        idleTimer?.invalidate()
        store?.liveActivity(sessionID, lastLines: recentLines, exited: exitCode ?? -1)
        feed(text: "\r\n\u{1B}[2m[process exited\(exitCode.map { " with code \($0)" } ?? "")]\u{1B}[0m\r\n")
    }

    func failedToStart(_ error: LocalProcessError) {
        store?.toast(.error, "Couldn't start the terminal", detail: String(describing: error))
        store?.liveActivity(sessionID, lastLines: [], exited: -1)
    }
}

/// SwiftTerm's view already implements some delegate names itself, so the
/// process delegate is a separate small object.
final class DelegateRelay: LocalProcessTerminalViewDelegate {
    weak var owner: BrixTerminalView?
    init(owner: BrixTerminalView) { self.owner = owner }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { owner?.directoryChanged(directory) }
    func processTerminated(source: TerminalView, exitCode: Int32?) { owner?.terminated(exitCode) }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) { owner?.failedToStart(error) }
}

/// Owns live terminal views so they survive re-docking and SwiftUI re-renders.
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()
    private var views: [String: BrixTerminalView] = [:]

    func start(sessionID: String, argv: [String], cwd: String, env: [String: String], fontSize: CGFloat, store: AppStore) {
        let view = BrixTerminalView(sessionID: sessionID, store: store, fontSize: fontSize)
        views[sessionID] = view
        var environment = ProcessRunner.environment(extra: env)
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Brix"
        environment.removeValue(forKey: "GIT_TERMINAL_PROMPT")
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        // forkpty passes every open descriptor on; see ProcessRunner.spawnLock.
        ProcessRunner.spawnLock.withLock {
            ProcessRunner.markAllCloseOnExec()
            view.startProcess(executable: argv[0], args: Array(argv.dropFirst()),
                              environment: environment.map { "\($0.key)=\($0.value)" }, execName: nil, currentDirectory: dir)
        }
    }

    func view(_ id: String) -> BrixTerminalView? { views[id] }
    /// The process the terminal started (the shell, or the agent run directly).
    func pid(_ id: String) -> pid_t? { views[id].map { $0.process.shellPid }.flatMap { $0 > 0 ? $0 : nil } }

    func markWorking(_ id: String) { views[id]?.markWorking() }

    /// Keyboard focus to a session's terminal (moving between panes).
    func focus(_ id: String) {
        guard let v = views[id] else { return }
        v.window?.makeFirstResponder(v)
    }

    func send(_ id: String, text: String) {
        views[id]?.send(txt: text)
    }

    func clear(_ id: String) {
        // Clear screen + scrollback, then redraw the prompt with ⌃L.
        views[id]?.feed(text: "\u{1B}[2J\u{1B}[3J\u{1B}[H")
        views[id]?.send(txt: "\u{0C}")
    }

    /// Every place a session is shown, weakly held.
    private var places: [String: NSHashTable<TerminalContainer>] = [:]

    func register(_ c: TerminalContainer, for id: String) {
        let table = places[id] ?? NSHashTable<TerminalContainer>.weakObjects()
        table.add(c)
        places[id] = table
    }

    func containers(for id: String) -> [TerminalContainer] { places[id]?.allObjects ?? [] }

    private var pendingPlace: Set<String> = []

    /// Puts a session's terminal in the biggest place that is really on screen.
    /// A session can be shown in several places at once (a pane, a card, a
    /// second window); the newest place used to take it, and when that place was
    /// hidden or off screen the visible one stayed black. Runs on the next turn,
    /// since it's called from layout.
    func placeSoon(_ id: String) {
        guard pendingPlace.insert(id).inserted else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingPlace.remove(id)
            self.place(id)
        }
    }

    private func place(_ id: String) {
        guard let term = views[id] else { return }
        // A container reused for another tab stays in this table: skip it.
        let shown = containers(for: id).filter { $0.sessionID == id && $0.isShowing }
        guard let best = shown.max(by: { $0.shownArea < $1.shownArea }) else { return }
        if let current = term.superview as? TerminalContainer, current.isShowing, current.shownArea >= best.shownArea { return }
        let from = (term.superview as? TerminalContainer).map { $0.isShowing ? "a smaller place" : "a hidden place" } ?? "nowhere"
        LiveTerminalSurface.attach(id, to: best, focus: false)
        PerfMonitor.shared.note("terminal \(id) moved on screen from \(from)")
    }

    func stop(_ id: String) {
        places[id] = nil
        if let v = views.removeValue(forKey: id) {
            v.hangUp()
            v.removeFromSuperview()
        }
    }

    /// A local shell is busy while a command runs in front of it (npm run dev,
    /// vim); anything else (ssh, logs) while it printed in the last 3 s.
    func hasChildProcess(_ id: String) -> Bool {
        guard let v = views[id] else { return false }
        if let fg = v.foregroundCommand() { return !fg.isEmpty }
        return Date().timeIntervalSince(v.lastData) < 3
    }

    func applyTheme(fontSize: CGFloat, accent: AccentChoice) {
        views.values.forEach { $0.applyTheme(fontSize: fontSize, accent: accent) }
    }

    func stopAll() {
        views.keys.forEach(stop)
    }
}

/// Hosts the shared live terminal view. Re-parents it when the panel moves.
struct LiveTerminalSurface: NSViewRepresentable {
    let sessionID: String

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainer()
        container.wantsLayer = true
        // The newest place a session appears takes the terminal.
        Self.attach(sessionID, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let container = container as? TerminalContainer else { return }
        // Re-renders don't steal the terminal back from another visible place;
        // they only pick it up when it has no window (its last place went away).
        if container.sessionID != sessionID { Self.attach(sessionID, to: container) }
        TerminalRegistry.shared.placeSoon(sessionID)
    }

    /// When the place showing a terminal goes away (a layout or tab switch), the
    /// terminal moves to another place still on screen instead of vanishing.
    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        guard let container = container as? TerminalContainer, let id = container.sessionID,
              let term = TerminalRegistry.shared.view(id), term.superview === container else { return }
        term.removeFromSuperview()
        container.sessionID = nil
        TerminalRegistry.shared.placeSoon(id)
    }

    /// `focus`: give the terminal the keyboard. Off for re-placement, which must
    /// not pull typing away from a search box or another pane.
    static func attach(_ sessionID: String, to container: TerminalContainer, focus: Bool = true) {
        // The container is reused when SwiftUI shows another session in the same
        // place (switching tabs), so drop whatever terminal it held before.
        for v in container.subviews where v !== TerminalRegistry.shared.view(sessionID) { v.removeFromSuperview() }
        container.sessionID = sessionID
        TerminalRegistry.shared.register(container, for: sessionID)
        guard let term = TerminalRegistry.shared.view(sessionID) else { return }
        if term.superview !== container {
            term.removeFromSuperview()
            term.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(term)
            NSLayoutConstraint.activate([
                term.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                term.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
                term.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                term.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
            ])
            let had = (term.window?.firstResponder as? NSView).map { $0 === term || $0.isDescendant(of: term) } ?? false
            if focus || had {
                DispatchQueue.main.async {
                    // Only the focused session takes the keyboard, and never from a
                    // text field or editor being typed in (a restore or a new tab
                    // elsewhere used to pull typing into the newest terminal).
                    guard had || (term.store?.focusedSessionID == sessionID && !(term.window?.firstResponder is NSTextView)) else { return }
                    term.window?.makeFirstResponder(term)
                }
            }
        }
    }
}

/// Layer-backed host whose background follows the theme.
final class TerminalContainer: NSView {
    var sessionID: String?

    /// In a visible window, not hidden, and big enough to read.
    var isShowing: Bool {
        guard let w = window, w.isVisible, w.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else { return false }
        let r = shownRect
        return r.width >= 60 && r.height >= 40
    }
    var shownArea: CGFloat { shownRect.width * shownRect.height }

    /// The part inside the window: views don't clip their children on macOS 14,
    /// so visibleRect alone counts parts outside the window.
    private var shownRect: CGRect {
        guard let content = window?.contentView else { return .zero }
        let mine = visibleRect.intersection(bounds)
        guard !mine.isNull else { return .zero }
        let r = convert(mine, to: nil).intersection(content.convert(content.bounds, to: nil))
        return r.isNull ? .zero : r
    }

    private func replace() { if let id = sessionID { TerminalRegistry.shared.placeSoon(id) } }
    private var occlusion: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusion { NotificationCenter.default.removeObserver(o); occlusion = nil }
        if let w = window {
            // Back from another Space, minimised or covered: place again.
            occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.replace() }
            }
        }
        replace()
    }
    deinit { if let o = occlusion { NotificationCenter.default.removeObserver(o) } }
    override func viewDidUnhide() { super.viewDidUnhide(); replace() }
    override func viewDidHide() { super.viewDidHide(); replace() }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { replace() }
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor(Theme.terminal).resolved(for: effectiveAppearance).cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}
