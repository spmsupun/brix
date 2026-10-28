import SwiftUI

/// Renders a session: a real PTY for live sessions, the lazy mock renderer
/// for sample sessions. Swap point for SwiftTerm is LiveTerminalSurface.
struct TerminalSurface: View {
    @Environment(AppStore.self) private var store
    let sessionID: String
    var showInput = true

    var body: some View {
        if let s = store.session(sessionID) {
            if s.isLive {
                LiveTerminalSurface(sessionID: sessionID)
                    .background(Theme.terminal)
                    .accessibilityLabel("Terminal \(s.title)")
            } else {
                MockTerminalView(session: s, showInput: showInput && s.kind != .agent)
            }
        } else {
            EmptyState(symbol: "terminal", message: "This terminal was closed.")
        }
    }
}

extension TermLine {
    var attributed: AttributedString {
        var out = AttributedString()
        for s in spans {
            var a = AttributedString(s.text)
            a.foregroundColor = s.color
            if s.bold { a.font = .system(size: 12, weight: .semibold, design: .monospaced) }
            out += a
        }
        return out
    }
}

struct MockTerminalView: View {
    @Environment(AppStore.self) private var store
    let session: TerminalSession
    var showInput = true
    @State private var input = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @FocusState private var focused: Bool

    private var fontSize: CGFloat { store.settings.terminalFontSize }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.lines.enumerated()), id: \.element.id) { i, line in
                        if showInput, i == session.lines.count - 1, session.state != .running || session.kind == .shell {
                            promptRow(line)
                        } else {
                            Text(line.attributed)
                                .font(.system(size: fontSize, design: .monospaced))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(height: fontSize * 1.55, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    Color.clear.frame(height: 2).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .background(Theme.terminal)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .onChange(of: session.lines.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .accessibilityLabel("Terminal \(session.title)")
    }

    private func promptRow(_ line: TermLine) -> some View {
        HStack(spacing: 0) {
            Text(line.attributed)
                .font(.system(size: fontSize, design: .monospaced))
                .fixedSize()
            TextField("", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onSubmit(submit)
                .onKeyPress(.upArrow) { recall(-1); return .handled }
                .onKeyPress(.downArrow) { recall(1); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "c"), phases: .down) { press in
                    guard press.modifiers.contains(.control) else { return .ignored }
                    store.interruptSession(session.id)
                    input = ""
                    return .handled
                }
                .accessibilityLabel("Command input")
        }
        .frame(height: fontSize * 1.55)
        .onAppear { if store.focusedSessionID == session.id { focused = true } }
    }

    private func submit() {
        let cmd = input
        input = ""
        if !cmd.isEmpty { history.append(cmd) }
        historyIndex = nil
        store.sendInput(session.id, cmd)
        focused = true
    }

    private func recall(_ delta: Int) {
        guard !history.isEmpty else { return }
        let i = max(0, min(history.count - 1, (historyIndex ?? history.count) + delta))
        historyIndex = i
        input = history[i]
    }
}
