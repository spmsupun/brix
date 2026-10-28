import AppKit
import SwiftUI
import SwiftTerm

/// A SwiftTerm view running a real process in a PTY. Keeps a plain-text tail
/// of the output so session cards can show the last lines.
final class BrixTerminalView: LocalProcessTerminalView {
    let sessionID: String
    weak var store: AppStore?
    private(set) var lastData = Date.distantPast
    private var tail: [String] = [""]
    private var idle = true
    private var idleTimer: Timer?
    private var escape = false
    private var csi = false
    private var osc = false
    private lazy var relay = DelegateRelay(owner: self)

    init(sessionID: String, store: AppStore, fontSize: CGFloat) {
        self.sessionID = sessionID
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        wantsLayer = true
        processDelegate = relay
        applyTheme(fontSize: fontSize, accent: store.settings.accent)
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { idleTimer?.invalidate() }

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

    override func setFrameSize(_ newSize: NSSize) {
        let grew = newSize != frame.size
        super.setFrameSize(newSize)
        if grew { needsDisplay = true }
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        lastData = Date()
        appendTail(slice)
        if isAgent {
            if Self.screenShowsWork(rolling) {
                lastWorkHint = Date()
                rolling = ""
            }
            if agentState != .running { checkIdle() }
            return
        }
        if idle {
            idle = false
            store?.liveIdle(sessionID, idle: false)
        }
    }

    /// Strips escape sequences and keeps the last 60 lines.
    private func appendTail(_ bytes: ArraySlice<UInt8>) {
        var current = tail.removeLast()
        var scalars: [UInt8] = []
        for b in bytes {
            if osc { if b == 0x07 || b == 0x5C { osc = false }; continue }
            if csi { if (0x40...0x7E).contains(b) { csi = false }; continue }
            if escape {
                escape = false
                if b == 0x5B { csi = true } else if b == 0x5D { osc = true }
                continue
            }
            switch b {
            case 0x1B: escape = true
            case 0x0A:
                let line = String(decoding: scalars, as: UTF8.self)
                current += line; rolling += line + " "; scalars = []
                tail.append(current); current = ""
            case 0x0D: break
            case 0x08: if !scalars.isEmpty { scalars.removeLast() }
            case 0..<0x20: break
            default: scalars.append(b)
            }
        }
        current += String(decoding: scalars, as: UTF8.self)
        rolling += String(decoding: scalars, as: UTF8.self)
        if rolling.count > 600 { rolling = String(rolling.suffix(300)) }
        tail.append(current)
        if tail.count > 60 { tail.removeFirst(tail.count - 60) }
    }

    var recentLines: [String] { tail.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }

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
        guard !idle, Date().timeIntervalSince(lastData) > 2.5 else { return }
        idle = true
        store?.liveActivity(sessionID, lastLines: recentLines, exited: nil)
        store?.liveIdle(sessionID, idle: true)
    }

    private var isAgent: Bool { store?.session(sessionID)?.kind == .agent }
    private var agentState: SessionState?
    private var lastWorkHint = Date.distantPast

    /// A prompt was just sent: count as working until the agent's own hint shows.
    func markWorking() { lastWorkHint = Date() }
    /// Printable output with escape codes removed, newest last.
    private var rolling = ""

    /// The bottom of the screen, where an agent's spinner, prompt box and
    /// questions live. Chat text further up never counts.
    private func visibleScreen() -> String {
        let rows = terminalContentSnapshot(region: .history(maximumScrollbackRows: -1))?.rows.map(\.text) ?? []
        return Self.bottom(rows)
    }

    static func bottom(_ rows: [String], lines: Int = 10) -> String {
        rows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(lines).joined(separator: "\n")
    }

    static func screenShowsWork(_ screen: String) -> Bool {
        let s = screen.lowercased()
        if s.contains("esc to interrupt") || s.contains("ctrl+c to interrupt") { return true }
        // Claude Code's spinner row: one of its star glyphs, then a capitalised -ing word and an ellipsis ("✶ Cogitating…").
        return screen.range(of: #"(?m)^\s*[·✢✳✶✻✽*]\s+[A-Z][a-z]+ing…"#, options: .regularExpression) != nil
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

    func stop(_ id: String) {
        places[id] = nil
        if let v = views.removeValue(forKey: id) {
            v.terminate()
            v.removeFromSuperview()
        }
    }

    /// ponytail: "busy" means output in the last 3 s; inspect the PTY's
    /// foreground process group if this needs to be exact.
    func hasChildProcess(_ id: String) -> Bool {
        guard let v = views[id] else { return false }
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
        let term = TerminalRegistry.shared.view(sessionID)
        if container.sessionID != sessionID || term?.window == nil { Self.attach(sessionID, to: container) }
    }

    /// When the place showing a terminal goes away (a layout or tab switch), the
    /// terminal moves to another place still on screen instead of vanishing.
    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        guard let container = container as? TerminalContainer, let id = container.sessionID,
              let term = TerminalRegistry.shared.view(id), term.superview === container else { return }
        term.removeFromSuperview()
        container.sessionID = nil
        if let next = TerminalRegistry.shared.containers(for: id).first(where: { $0 !== container && $0.window != nil }) {
            attach(id, to: next)
        }
    }

    static func attach(_ sessionID: String, to container: TerminalContainer) {
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
            DispatchQueue.main.async { term.window?.makeFirstResponder(term) }
        }
    }
}

/// Layer-backed host whose background follows the theme.
final class TerminalContainer: NSView {
    var sessionID: String?

    /// Arriving on screen while the terminal has no window: pick it up.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let id = sessionID, let term = TerminalRegistry.shared.view(id), term.window == nil else { return }
        LiveTerminalSurface.attach(id, to: self)
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor(Theme.terminal).resolved(for: effectiveAppearance).cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}
