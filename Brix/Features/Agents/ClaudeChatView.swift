import SwiftUI

/// A Claude Code session drawn as a chat: your messages, Claude's replies as
/// formatted text, each tool call as a card, and permission prompts and
/// questions as buttons. The terminal view is a setting away (Customize → Agents).
struct ClaudeChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let chat: ClaudeChat
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chat.items.isEmpty, !chat.working {
                            Text("Ask Claude to do something in \((chat.cwd as NSString).lastPathComponent).")
                                .font(Typo.ui(13)).foregroundStyle(Theme.text3).padding(.top, 24)
                        }
                        ForEach(chat.items) { item in row(item) }
                        if !chat.liveThinking.isEmpty, chat.liveText.isEmpty {
                            thinking(chat.liveThinking, live: true)
                        }
                        if !chat.liveText.isEmpty {
                            MarkdownView(text: chat.liveText, scrolls: false)
                        }
                        if chat.working, chat.asks.isEmpty, chat.liveText.isEmpty {
                            HStack(spacing: 8) {
                                WorkingSpinner(color: accent, size: 12)
                                Text("Working…").font(Typo.ui(12)).foregroundStyle(Theme.text3)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: chat.items.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.liveText.count / 200) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.asks.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if let ask = chat.asks.first {
                AskCard(chat: chat, ask: ask).id(ask.id).padding(.horizontal, 16).padding(.bottom, 8)
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
            composer
        }
        .background(Theme.terminal)
        .onAppear { focused = true }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ item: ClaudeChat.Item) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(item.text).font(Typo.ui(13)).foregroundStyle(Theme.text).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white(0.07)))
            }
        case .text:
            MarkdownView(text: item.text, scrolls: false)
        case .thinking:
            thinking(item.text, live: false)
        case .tool:
            ToolCard(item: item, running: item.result == nil && chat.working)
        case .error:
            Text(item.text).font(Typo.ui(12.5)).foregroundStyle(Theme.red).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.red.opacity(0.08)))
        case .notice:
            Text(item.text).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).frame(maxWidth: .infinity)
        }
    }

    private func thinking(_ text: String, live: Bool) -> some View {
        DisclosureGroup {
            Text(text).font(Typo.ui(12)).italic().foregroundStyle(Theme.text3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
        } label: {
            Text(live ? "Thinking…" : "Thought").font(Typo.ui(12)).foregroundStyle(Theme.text3)
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(chat.exited != nil ? "This session has ended." : "Reply to Claude…  (⏎ to send, ⇧⏎ for a new line)")
                            .font(Typo.ui(13)).foregroundStyle(Theme.text3).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .font(Typo.ui(13)).foregroundStyle(Theme.text)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .frame(minHeight: 20, maxHeight: 160)
                        .fixedSize(horizontal: false, vertical: true)
                        .disabled(chat.exited != nil)
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                            send()
                            return .handled
                        }
                }
                Button {
                    if chat.working, draft.isEmpty { chat.interrupt() } else { send() }
                } label: {
                    Image(systemName: chat.working && draft.isEmpty ? "stop.fill" : "arrow.up")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAccent)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(chat.exited == nil ? accent : Theme.disabled))
                }
                .buttonStyle(.hand)
                .disabled(chat.exited != nil)
                .help(chat.working && draft.isEmpty ? "Stop (interrupt)" : "Send")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? accent.opacity(0.45) : Theme.border))
            HStack(spacing: 10) {
                if !chat.model.isEmpty { Text(chat.model) }
                if !chat.permissionMode.isEmpty, chat.permissionMode != "default" { Text(chat.permissionMode) }
                Spacer()
            }
            .font(Typo.ui(10.5)).foregroundStyle(Theme.text3).padding(.horizontal, 4)
        }
        .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 4)
        .frame(maxWidth: 820).frame(maxWidth: .infinity)
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.sendInput(chat.sessionID, t)
        draft = ""
    }
}

/// One tool call: its name and target on a line, the details and result folded away.
private struct ToolCard: View {
    let item: ClaudeChat.Item
    let running: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.symbol(item.tool)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text3).frame(width: 14)
                    Text(Self.label(item.tool)).font(Typo.ui(12, .semibold)).foregroundStyle(Theme.body)
                    Text(item.text).font(Typo.mono(11.5)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if running {
                        ProgressView().controlSize(.mini)
                    } else if item.failed {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.red)
                    } else if item.result != nil {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.green)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.meta)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.hand)
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if let d = item.diff { DiffBlock(diff: d) }
                    if !item.detail.isEmpty { mono(item.detail, limit: 60) }
                    if let r = item.result, !r.isEmpty { mono(r, limit: 80, color: item.failed ? Theme.red : Theme.text3) }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            } else if let d = item.diff {
                // Edits show their change without opening.
                DiffBlock(diff: d, maxLines: 8).padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(item.failed ? Theme.red.opacity(0.35) : Theme.border))
    }

    private func mono(_ s: String, limit: Int, color: Color = Theme.body) -> some View {
        let lines = s.components(separatedBy: "\n")
        let shown = lines.prefix(limit).joined(separator: "\n") + (lines.count > limit ? "\n… \(lines.count - limit) more lines" : "")
        return Text(shown).font(Typo.mono(11)).foregroundStyle(color).textSelection(.enabled)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well))
    }

    static func label(_ tool: String) -> String {
        switch tool {
        case "Bash": "Run"
        case "Read": "Read"
        case "Write": "Write"
        case "Edit", "MultiEdit": "Edit"
        case "Grep", "Glob": "Search"
        case "WebFetch": "Fetch"
        case "WebSearch": "Web search"
        case "Task", "Agent": "Agent"
        case "TodoWrite", "TaskCreate", "TaskUpdate": "Tasks"
        case "ExitPlanMode": "Plan"
        default: tool.hasPrefix("mcp__") ? "MCP" : tool
        }
    }

    static func symbol(_ tool: String) -> String {
        switch tool {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Write": "doc.badge.plus"
        case "Edit", "MultiEdit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite", "TaskCreate", "TaskUpdate": "checklist"
        case "ExitPlanMode": "list.bullet.clipboard"
        default: "wrench.and.screwdriver"
        }
    }
}

/// Removed lines in red, added in green.
struct DiffBlock: View {
    let diff: ClaudeChat.Diff
    var maxLines = 400

    var body: some View {
        let all = Self.lines(diff)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(all.prefix(maxLines).enumerated()), id: \.offset) { _, l in
                Text(l.0 + " " + l.1).font(Typo.mono(11)).foregroundStyle(l.0 == "-" ? Theme.red : (l.0 == "+" ? Theme.green : Theme.text3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(l.0 == " " ? Color.clear : (l.0 == "-" ? Theme.red : Theme.green).opacity(0.07))
            }
            if all.count > maxLines {
                Text("… \(all.count - maxLines) more lines").font(Typo.mono(11)).foregroundStyle(Theme.text3)
            }
        }
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Lines the edit kept at either end show as plain context; only the middle is coloured.
    static func lines(_ d: ClaudeChat.Diff) -> [(String, String)] {
        let old = d.old.isEmpty ? [] : d.old.components(separatedBy: "\n")
        let new = d.new.isEmpty ? [] : d.new.components(separatedBy: "\n")
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head, old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        return old[..<head].map { (" ", $0) }
            + old[head..<(old.count - tail)].map { ("-", $0) }
            + new[head..<(new.count - tail)].map { ("+", $0) }
            + old[(old.count - tail)...].map { (" ", $0) }
    }
}

/// What Claude is waiting on: a tool to allow, questions to answer, or a plan to approve.
private struct AskCard: View {
    @Environment(\.accent) private var accent
    let chat: ClaudeChat
    let ask: ClaudeChat.Ask
    @State private var picks: [String: Set<String>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !ask.questions.isEmpty {
                questions
            } else if ask.tool == "ExitPlanMode" {
                Text("Claude has a plan").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                ScrollView { MarkdownView(text: ask.detail, scrolls: false).padding(.trailing, 6) }.frame(maxHeight: 280)
                HStack {
                    Spacer()
                    SubtleButton(title: "Keep Planning", height: 28) { chat.deny(ask, message: "The user wants to keep planning. Ask what to change.") }
                    AccentButton(title: "Approve Plan", height: 28) { chat.allow(ask) }.keyboardShortcut(.defaultAction)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: ToolCard.symbol(ask.tool)).font(.system(size: 11)).foregroundStyle(Theme.amber)
                    Text("Allow \(ToolCard.label(ask.tool).lowercased())?").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                    Text(ask.summary).font(Typo.mono(11.5)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                }
                // Sized to what it shows (a capped ScrollView would take its full height).
                if let d = ask.diff { DiffBlock(diff: d, maxLines: 14) }
                if !ask.detail.isEmpty {
                    let lines = ask.detail.components(separatedBy: "\n")
                    Text(lines.prefix(10).joined(separator: "\n") + (lines.count > 10 ? "\n… \(lines.count - 10) more lines" : ""))
                        .font(Typo.mono(11)).foregroundStyle(Theme.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well))
                }
                HStack {
                    Spacer()
                    SubtleButton(title: "Deny", height: 28) { chat.deny(ask) }.keyboardShortcut(.cancelAction)
                    if !ask.suggestions.isEmpty {
                        SubtleButton(title: "Allow for This Session", height: 28) { chat.allow(ask, always: true) }
                    }
                    AccentButton(title: "Allow", height: 28) { chat.allow(ask) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sheet))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.amber.opacity(0.45)))
    }

    @ViewBuilder private var questions: some View {
        ForEach(ask.questions) { q in
            VStack(alignment: .leading, spacing: 6) {
                if !q.header.isEmpty { Text(q.header.uppercased()).font(Typo.ui(10, .heavy)).foregroundStyle(Theme.text3) }
                Text(q.question).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                ForEach(q.options, id: \.label) { o in
                    let on = picks[q.question, default: []].contains(o.label)
                    Button {
                        var set = q.multi ? picks[q.question, default: []] : []
                        if on { set.remove(o.label) } else { set.insert(o.label) }
                        picks[q.question] = set
                        // One single-choice question: the click is the answer.
                        if !q.multi, ask.questions.count == 1 { submit() }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: on ? (q.multi ? "checkmark.square.fill" : "largecircle.fill.circle") : (q.multi ? "square" : "circle"))
                                .font(.system(size: 11)).foregroundStyle(on ? accent : Theme.text3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(o.label).font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text)
                                if !o.description.isEmpty { Text(o.description).font(Typo.ui(11.5)).foregroundStyle(Theme.text3) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8).contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? accent.opacity(0.08) : Color.white(0.03)))
                    }
                    .buttonStyle(.hand)
                }
            }
        }
        if ask.questions.count > 1 || ask.questions.contains(where: \.multi) {
            HStack {
                Spacer()
                SubtleButton(title: "Skip", height: 28) { chat.deny(ask, message: "The user skipped the question.") }
                AccentButton(title: "Answer", height: 28) { submit() }
                    .disabled(ask.questions.contains { picks[$0.question, default: []].isEmpty })
            }
        }
    }

    private func submit() {
        var answers: [String: String] = [:]
        for q in ask.questions { answers[q.question] = q.options.map(\.label).filter { picks[q.question, default: []].contains($0) }.joined(separator: ", ") }
        chat.answer(ask, answers)
    }
}
