import SwiftUI
import UniformTypeIdentifiers

/// A Claude Code session drawn as a chat: your messages, Claude's replies as
/// formatted text, each tool call as a card, and permission prompts and
/// questions as buttons. The terminal view is a setting away (Customize → Agents).
struct ClaudeChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let chat: ClaudeChat
    @State private var draft = ""
    @State private var attachments: [ClaudeChat.Attachment] = []
    /// The next "[Image #N]"; numbers never repeat within a message, so removing one doesn't shift the others.
    @State private var nextImage = 1
    @State private var pasteMonitor: Any?
    /// Why the last images couldn't be attached; shown above the composer.
    @State private var attachError: String?
    private static let maxImages = 5
    @State private var dropping = false
    @State private var showContext = false
    @State private var showTodos = false
    @State private var showTasks = false
    @State private var showMCP = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chat.loadingHistory {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading the conversation…") }
                                .font(Typo.ui(12)).foregroundStyle(Theme.text3).padding(.top, 24)
                        } else if chat.items.isEmpty, !chat.working {
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
                .contextMenu {
                    Button("Copy Last Reply") { if let r = chat.lastReply { copy(r) } }.disabled(chat.lastReply == nil)
                    Button("Interrupt") { chat.interrupt() }.disabled(!chat.working)
                    Button("Rename…") { store.sheet = .renameSession(chat.sessionID) }
                    Button("Open as Terminal") { store.reopen(chat.sessionID, asChat: false) }
                    Divider()
                    Button("Close", role: .destructive) { store.closeSession(chat.sessionID) }
                }
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
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10).strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(6)
                    .overlay(Text("Drop images to attach").font(Typo.ui(13, .semibold)).foregroundStyle(accent))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            for p in providers {
                if p.canLoadObject(ofClass: URL.self) {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                        let img = isImage ? NSImage(contentsOf: url) : nil
                        DispatchQueue.main.async { attach(img.map { [$0] } ?? [], failed: img == nil ? [url.lastPathComponent] : []) }
                    }
                } else if p.canLoadObject(ofClass: NSImage.self) {
                    _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                        let img = img as? NSImage
                        DispatchQueue.main.async { attach(img.map { [$0] } ?? [], failed: img == nil ? ["the dropped image"] : []) }
                    }
                }
            }
            return true
        }
        .onChange(of: chat.prefill) { _, t in
            guard let t else { return }
            // Whatever was being typed stays, under the message brought back.
            draft = draft.isEmpty ? t : t + "\n\n" + draft
            chat.prefill = nil
            focused = true
        }
        .onAppear {
            focused = true
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            // ⌘V with an image on the clipboard attaches it; text pastes as usual.
            // Only in the key window, where this chat's editor has focus.
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard focused, e.window != nil, e.window === NSApp.keyWindow,
                      e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      e.charactersIgnoringModifiers == "v" else { return e }
                let found = ClaudeChat.images(on: .general)
                guard !found.isEmpty else { return e }
                attach(found)
                return nil
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
    }

    /// The `@word` being typed at the end of the draft, if any.
    private var mention: String? {
        let last = draft.components(separatedBy: .whitespacesAndNewlines).last ?? ""
        return last.hasPrefix("@") ? String(last.dropFirst()) : nil
    }

    private func pickFile(_ path: String) {
        guard let m = mention else { return }
        draft = String(draft.dropLast(m.count + 1)) + "@" + path + " "
        chat.clearFileMatches()
    }

    /// Slash commands matching what you've typed so far ("/com" → /compact).
    private var suggestions: [ClaudeChat.Command] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        let q = draft.dropFirst().lowercased()
        let starts = chat.commands.filter { $0.name.lowercased().hasPrefix(q) }
        let inside = q.isEmpty ? [] : chat.commands.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        return Array((starts + inside).prefix(8))
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        let loaded = panel.urls.map { ($0.lastPathComponent, NSImage(contentsOf: $0)) }
        attach(loaded.compactMap(\.1), failed: loaded.filter { $0.1 == nil }.map(\.0))
    }

    /// Scales and encodes off the main thread (a big photo takes a moment), then
    /// adds what fits under the limit and says what didn't make it.
    private func attach(_ images: [NSImage], failed: [String] = []) {
        let boxed = images.map { UncheckedImage(image: $0) }
        Task {
            let made = await Task.detached(priority: .userInitiated) { boxed.map { ClaudeChat.attachment($0.image) } }.value
            var problems = failed.map { "Couldn't read \($0)." }
            let ok = made.compactMap { $0 }
            if ok.count < made.count { problems.append("Couldn't convert \(made.count - ok.count) image\(made.count - ok.count == 1 ? "" : "s").") }
            let room = max(0, Self.maxImages - attachments.count)
            var added = Array(ok.prefix(room))
            for i in added.indices { added[i].number = nextImage; nextImage += 1 }
            attachments += added
            if !added.isEmpty { insertTags(added.map { "[Image #\($0.number)] " }.joined()) }
            if ok.count > room { problems.append("Up to \(Self.maxImages) images per message.") }
            attachError = problems.isEmpty ? nil : problems.joined(separator: " ")
        }
    }

    /// Puts the image tags at the cursor, as the terminal does; at the end when the editor isn't focused (a drop).
    private func insertTags(_ tags: String) {
        if focused, let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable {
            tv.insertText(tags, replacementRange: tv.selectedRange())
        } else {
            draft += (draft.isEmpty || draft.last?.isWhitespace == true ? "" : " ") + tags
        }
    }

    private func removeAttachment(_ a: ClaudeChat.Attachment) {
        attachments.removeAll { $0.id == a.id }
        draft = draft.replacingOccurrences(of: "[Image #\(a.number)] ", with: "").replacingOccurrences(of: "[Image #\(a.number)]", with: "")
        if attachments.isEmpty { nextImage = 1 }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ item: ClaudeChat.Item) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 6) {
                    if !item.images.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(item.images.enumerated()), id: \.offset) { _, d in
                                if let img = NSImage(data: d) {
                                    Image(nsImage: img).resizable().scaledToFit()
                                        .frame(maxWidth: min(220, img.size.width), maxHeight: min(160, img.size.height))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                    if !item.text.isEmpty {
                        Text(item.text).font(Typo.ui(13)).foregroundStyle(Theme.text).textSelection(.enabled)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white(0.07)))
                    }
                }
            }
            .contextMenu { userMenu(item) }
        case .text:
            MarkdownView(text: item.text, scrolls: false)
                .contextMenu { Button("Copy") { copy(item.text) } }
        case .thinking:
            thinking(item.text, live: false)
        case .tool:
            ToolCard(item: item, running: item.result == nil && chat.working,
                     onBackground: ["Bash", "Task", "Agent"].contains(item.tool) && item.result == nil && chat.working ? { chat.background(item.id) } : nil)
        case .error:
            Text(item.text).font(Typo.ui(12.5)).foregroundStyle(Theme.red).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.red.opacity(0.08)))
        case .notice:
            Text(item.text).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).frame(maxWidth: .infinity)
        case .output:
            // A slash command's own output (/usage, /model, /context).
            MarkdownView(text: item.text, scrolls: false)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
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
            if !chat.queued.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(chat.queued) { q in
                        HStack(spacing: 8) {
                            Text("QUEUED").font(Typo.ui(9, .heavy)).foregroundStyle(Theme.text3)
                            Text(q.text.isEmpty ? "\(q.images.count) image\(q.images.count == 1 ? "" : "s")" : q.text)
                                .font(Typo.ui(12)).foregroundStyle(Theme.body).lineLimit(1)
                            Spacer(minLength: 0)
                            Button { chat.cancelQueued(q.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3).frame(width: 16, height: 16)
                            }
                            .buttonStyle(.hand).help("Don't send this one")
                        }
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white(0.03)))
                    }
                }
            }
            if mention != nil, !chat.fileMatches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(chat.fileMatches, id: \.self) { f in
                        Button { pickFile(f) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(Theme.text3)
                                Text(f).font(Typo.mono(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.head)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).frame(height: 26).contentShape(Rectangle())
                        }
                        .buttonStyle(.hand)
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sheet))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { c in
                        Button { draft = "/" + c.name + " " } label: {
                            HStack(spacing: 10) {
                                Text("/" + c.name).font(Typo.mono(12, .semibold)).foregroundStyle(Theme.text)
                                if !c.hint.isEmpty { Text(c.hint).font(Typo.mono(11)).foregroundStyle(Theme.text3) }
                                Text(c.description).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.hand)
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sheet))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            }
            if let attachError {
                HStack(spacing: 6) {
                    Text(attachError).font(Typo.ui(11.5)).foregroundStyle(Theme.amber)
                    Button { self.attachError = nil } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3) }
                        .buttonStyle(.hand)
                }
            }
            if !attachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(attachments) { a in
                        if let img = NSImage(data: a.data) {
                            Image(nsImage: img).resizable().scaledToFill().frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .bottomLeading) {
                                    Text("#\(a.number)").font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                                        .padding(.horizontal, 4).frame(height: 14).background(Capsule().fill(.black.opacity(0.7))).padding(3)
                                        .help("[Image #\(a.number)] in your message")
                                }
                                .overlay(alignment: .topTrailing) {
                                    Button { removeAttachment(a) } label: {
                                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                            .frame(width: 16, height: 16).background(Circle().fill(.black.opacity(0.7)))
                                    }
                                    .buttonStyle(.hand).padding(3)
                                    .help("Remove image")
                                }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(chat.exited != nil ? "This session has ended." : "Reply to Claude…")
                            .font(Typo.ui(13)).foregroundStyle(Theme.text3).padding(.leading, 5).allowsHitTesting(false)
                    }
                    TextEditor(text: $draft)
                        .noWritingTools()
                        // With a mouse attached macOS shows an always-on scroll bar track in
                        // the box; long drafts still scroll.
                        .scrollIndicators(.never)
                        .font(Typo.ui(13)).foregroundStyle(Theme.text)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .frame(minHeight: 20, maxHeight: 160)
                        .fixedSize(horizontal: false, vertical: true)
                        .disabled(chat.exited != nil)
                        .onChange(of: mention) { _, m in
                            if let m { chat.findFiles(m) } else { chat.clearFileMatches() }
                        }
                        .onKeyPress(.tab, phases: .down) { press in
                            // ⇧⇥ cycles the mode, as in the terminal.
                            if press.modifiers.contains(.shift) { cycleMode(); return .handled }
                            if mention != nil, let f = chat.fileMatches.first { pickFile(f); return .handled }
                            guard let first = suggestions.first else { return .ignored }
                            draft = "/" + first.name + " "
                            return .handled
                        }
                        .onKeyPress(.escape, phases: .down) { _ in
                            if mention != nil, !chat.fileMatches.isEmpty { chat.clearFileMatches(); return .handled }
                            // A prompt on screen takes Esc as "No"; it doesn't stop the turn.
                            guard chat.working, chat.asks.isEmpty else { return .ignored }
                            chat.interrupt()
                            return .handled
                        }
                        .onKeyPress(characters: ["c", "b"], phases: .down) { press in
                            guard press.modifiers == .control, chat.working else { return .ignored }
                            if press.characters == "b" { chat.background() } else { chat.interrupt() }
                            return .handled
                        }
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                            if mention != nil, let f = chat.fileMatches.first { pickFile(f); return .handled }
                            // A half-typed command ("/com") completes instead of going to Claude as text.
                            if let first = suggestions.first, !chat.commands.contains(where: { "/" + $0.name == draft }) {
                                draft = "/" + first.name + " "
                                return .handled
                            }
                            send()
                            return .handled
                        }
                }
                HStack(spacing: 6) {
                    Button { pickImages() } label: {
                        Image(systemName: "paperclip").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.hand)
                    .disabled(chat.exited != nil)
                    .help("Attach images (or paste or drop them here)")
                    MenuButton(items: modeMenu) { chip(footLabel(ClaudeChat.modes.first { $0.id == chat.permissionMode }?.name ?? chat.permissionMode,
                                                                 symbol: chat.permissionMode == "plan" ? "list.bullet.clipboard" : "hand.raised",
                                                                 tint: chat.permissionMode == "default" ? Theme.text2 : accent)) }
                        .help("Permission mode (⇧⇥ to cycle)")
                    MenuButton(items: modelMenu) { chip(footLabel(modelName, symbol: "cpu", tint: Theme.text2)) }
                        .help("Model")
                    if !effortLevels.isEmpty {
                        MenuButton(items: effortMenu) { chip(footLabel(chat.effort.isEmpty ? "Effort" : "Effort: \(chat.effort)", symbol: "gauge.with.dots.needle.33percent", tint: Theme.text2)) }
                            .help("How hard Claude thinks")
                    }
                    Spacer(minLength: 8)
                    // Dropped when the pane is too narrow, rather than squeezing the chips.
                    ViewThatFits(in: .horizontal) {
                        Text("⏎ send · ⇧⏎ new line").font(Typo.ui(10.5)).foregroundStyle(Theme.text3).fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                    Button {
                        if chat.working, draft.isEmpty, attachments.isEmpty { chat.interrupt() } else { send() }
                    } label: {
                        Image(systemName: chat.working && draft.isEmpty && attachments.isEmpty ? "stop.fill" : "arrow.up")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAccent)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(chat.exited == nil ? accent : Theme.disabled))
                    }
                    .buttonStyle(.hand)
                    .disabled(chat.exited != nil)
                    .help(chat.working && draft.isEmpty && attachments.isEmpty ? "Stop (interrupt)" : "Send")
                }
            }
            .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? accent.opacity(0.45) : Theme.border))
            footer
        }
        .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 4)
        .frame(maxWidth: 820).frame(maxWidth: .infinity)
    }

    // MARK: Message actions

    @ViewBuilder private func userMenu(_ item: ClaudeChat.Item) -> some View {
        Button("Copy") { copy(item.text) }
        if item.uuid != nil, chat.exited == nil {
            Divider()
            // Not while Claude works (it would cut a turn mid-way), nor where the cut point is unknown.
            let can = chat.canCut(item)
            Button("Edit and Resend…") { chat.rewindConversation(to: item, edit: true) }.disabled(!can)
            Button("Rewind Conversation to Here") { chat.rewindConversation(to: item, edit: false) }.disabled(!can)
            Button("Rewind Code to Here…") { rewindCode(item) }.disabled(chat.working)
            Button("Fork from Here") { store.forkChat(chat.sessionID, at: item) }.disabled(!can)
            if chat.working { Text("Available when Claude finishes this turn") }
        }
    }

    /// Shows what would be undone, then puts the files back.
    private func rewindCode(_ item: ClaudeChat.Item) {
        Task {
            let p: ClaudeChat.RewindPreview
            switch await chat.previewRewind(item) {
            case .success(let r): p = r
            case .failure(let e): store.toast(.info, "Can't rewind the code", detail: e.message); return
            }
            guard !p.files.isEmpty else { store.toast(.info, "Nothing to rewind", detail: "No files changed after this message."); return }
            let list = p.files.prefix(8).joined(separator: "\n") + (p.files.count > 8 ? "\n…and \(p.files.count - 8) more" : "")
            store.confirm("Rewind \(p.files.count) file\(p.files.count == 1 ? "" : "s") to before this message?",
                          "+\(p.added) −\(p.removed) lines will be undone:\n\(list)\n\nThe conversation stays as it is.", confirm: "Rewind Code") {
                Task {
                    if let why = await chat.rewindFiles(item) { store.toast(.error, "Couldn't rewind", detail: why) }
                    else { store.toast(.success, "Files rewound", detail: "\(p.files.count) file\(p.files.count == 1 ? "" : "s") back to before that message") }
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func moreMenu() -> [MenuSpec] {
        [MenuSpec(title: "Compact Conversation", symbol: "rectangle.compress.vertical", enabled: !chat.working) { chat.compact() },
         MenuSpec(title: "New Conversation Here", symbol: "plus.bubble", enabled: chat.exited == nil) { store.clearSession(chat.sessionID) },
         .separator,
         MenuSpec(title: "Copy Last Reply", symbol: "doc.on.doc", enabled: chat.lastReply != nil) { if let r = chat.lastReply { copy(r) } },
         MenuSpec(title: "Export Conversation…", symbol: "square.and.arrow.up") { export() },
         .separator,
         MenuSpec(title: "Open as Terminal", symbol: "terminal") { store.reopen(chat.sessionID, asChat: false) }]
    }

    private func export() {
        Task {
            guard let e = await chat.export() else { store.toast(.error, "Couldn't export the conversation"); return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = e.name
            panel.allowedContentTypes = [.plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try e.text.write(to: url, atomically: true, encoding: .utf8) }
            catch { store.toast(.error, "Couldn't save", detail: error.localizedDescription) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if chat.exited == nil { Text("/ commands   @ files   ! shell   # memory").lineLimit(1).layoutPriority(-1) }
            Spacer(minLength: 0)
            if let s = store.session(chat.sessionID), !s.plan.isEmpty {
                Button { showTodos.toggle() } label: {
                    Label("\(s.plan.filter(\.done).count)/\(s.plan.count)", systemImage: "checklist")
                }
                .buttonStyle(.hand).help("Claude's task list")
                .popover(isPresented: $showTodos, arrowEdge: .bottom) { ScrollView { PlanList(session: s) }.frame(width: 320).frame(maxHeight: 360) }
            }
            if !chat.tasks.isEmpty {
                let running = chat.tasks.filter(\.running).count
                Button { showTasks.toggle() } label: {
                    Label(running > 0 ? "\(running) running" : "\(chat.tasks.count) done", systemImage: "square.stack.3d.up")
                        .foregroundStyle(running > 0 ? accent : Theme.text3)
                }
                .buttonStyle(.hand).help("Background work")
                .popover(isPresented: $showTasks, arrowEdge: .bottom) { tasksDetail }
            }
            Button { showMCP.toggle(); Task { await chat.refreshMCP() } } label: {
                Label("MCP", systemImage: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(chat.mcpServers.contains { $0.status == "failed" } ? Theme.amber : Theme.text3)
            }
            .buttonStyle(.hand).help("MCP servers")
            .popover(isPresented: $showMCP, arrowEdge: .bottom) { mcpDetail }
            MenuButton(items: moreMenu) {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text3).frame(width: 18, height: 14).contentShape(Rectangle())
            }
            .help("More: compact, new conversation, export, open as terminal")
            ForEach(chat.limits) { l in
                Text("\(l.label) \(Int(l.used * 100))%").monospacedDigit()
                    .foregroundStyle(l.used >= 0.9 ? Theme.red : (l.used >= 0.7 ? Theme.amber : Theme.text3))
                    .help("Plan usage, \(l.label) window" + (l.resets.map { ", resets " + $0.formatted(.relative(presentation: .named)) } ?? ""))
            }
            if let c = chat.context {
                Button { showContext.toggle() } label: {
                    HStack(spacing: 4) {
                        ZStack {
                            Circle().stroke(Theme.border, lineWidth: 2)
                            Circle().trim(from: 0, to: CGFloat(c.percent) / 100).stroke(contextColor(c), style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                        }
                        .frame(width: 11, height: 11)
                        Text("\(c.percent)%").monospacedDigit()
                    }
                }
                .buttonStyle(.hand)
                .help("Context used")
                .popover(isPresented: $showContext, arrowEdge: .bottom) { contextDetail(c) }
            }
        }
        .font(Typo.ui(10.5)).foregroundStyle(Theme.text3).padding(.horizontal, 4)
    }

    private var tasksDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background work").font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text)
            ForEach(chat.tasks) { t in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Circle().fill(t.running ? accent : (t.status == "failed" ? Theme.red : Theme.text3)).frame(width: 6, height: 6)
                        Text(t.description.isEmpty ? t.id : t.description).font(Typo.ui(12, .medium)).foregroundStyle(Theme.body).lineLimit(1)
                        Spacer()
                        Text(t.status.isEmpty ? "running" : t.status).font(Typo.ui(10.5)).foregroundStyle(Theme.text3)
                    }
                    if !t.summary.isEmpty { Text(t.summary).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(2) }
                    HStack(spacing: 8) {
                        if t.running { SubtleButton(title: "Stop", height: 22) { chat.stopTask(t.id) } }
                        if !t.outputFile.isEmpty {
                            SubtleButton(title: "Show Output", height: 22) { showOutput(t.outputFile) }
                        }
                    }
                }
            }
        }
        .padding(14).frame(width: 340)
    }

    /// A task's output file opens only if it's a text file in a temporary folder; anything else is shown in Finder.
    private func showOutput(_ path: String) {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { store.toast(.info, "That output file is gone"); return }
        let temp = [URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path, "/private/tmp/", "/private/var/folders/"]
        if temp.contains(where: { url.path.hasPrefix($0) }), ["output", "txt", "log", "md", "json"].contains(url.pathExtension.lowercased()) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private var mcpDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MCP servers").font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text)
            if !chat.mcpError.isEmpty { Text(chat.mcpError).font(Typo.ui(11.5)).foregroundStyle(Theme.amber) }
            else if chat.mcpServers.isEmpty { Text("Loading…").font(Typo.ui(11.5)).foregroundStyle(Theme.text3) }
            ForEach(chat.mcpServers) { m in
                HStack(spacing: 8) {
                    Circle().fill(m.status == "connected" ? Theme.green : (m.status == "failed" ? Theme.red : (m.status == "needs-auth" ? Theme.amber : Theme.text3)))
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.name).font(Typo.ui(12)).foregroundStyle(Theme.body).lineLimit(1)
                        Text(m.status == "needs-auth" ? "needs sign-in (run /mcp in the terminal view)" : m.status + (m.tools > 0 ? " · \(m.tools) tools" : "") + (m.error.isEmpty ? "" : " · " + m.error))
                            .font(Typo.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    Spacer()
                    if m.status == "failed" || m.status == "pending" { SubtleButton(title: "Reconnect", height: 22) { chat.reconnectMCP(m.name) } }
                    Toggle("", isOn: Binding(get: { m.status != "disabled" }, set: { chat.toggleMCP(m.name, on: $0) }))
                        .toggleStyle(.bx).labelsHidden().fixedSize()
                }
            }
        }
        .padding(14).frame(width: 380)
    }

    /// A menu label inside the composer, outlined like a small button.
    private func chip(_ label: some View) -> some View {
        label.font(Typo.ui(11)).padding(.horizontal, 8).frame(height: 24)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.controlStroke))
    }

    private func footLabel(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .medium))
            Text(text)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
        }
        .foregroundStyle(tint).contentShape(Rectangle())
    }

    private var modelName: String {
        if let m = chat.models.first(where: { $0.value != "default" && ($0.resolved == chat.model || $0.value == chat.model) }) { return m.name }
        // Claude names its model with the first reply; until then, the default one.
        if chat.model.isEmpty, let d = chat.models.first(where: { $0.value == "default" }) {
            return chat.models.first { $0.value != "default" && $0.resolved == d.resolved }?.name ?? d.name
        }
        return chat.model.isEmpty ? "Model" : chat.model
    }

    private var effortLevels: [String] {
        chat.models.first { $0.resolved == chat.model || $0.value == chat.model }?.efforts ?? chat.models.first?.efforts ?? []
    }

    private func modeMenu() -> [MenuSpec] {
        ClaudeChat.modes.map { m in MenuSpec(title: m.name + "  ·  " + m.detail, checked: m.id == chat.permissionMode) { chat.setMode(m.id) } }
    }

    private func modelMenu() -> [MenuSpec] {
        chat.models.map { m in
            MenuSpec(title: m.detail.isEmpty ? m.name : "\(m.name)  ·  \(m.detail)", checked: m.value != "default" && (m.resolved == chat.model || m.value == chat.model)) { chat.setModel(m.value) }
        }
    }

    private func effortMenu() -> [MenuSpec] {
        effortLevels.map { e in MenuSpec(title: e.capitalized, checked: e == chat.effort) { chat.setEffort(e) } }
    }

    private func cycleMode() {
        let ids = ClaudeChat.modes.map(\.id)
        let i = ids.firstIndex(of: chat.permissionMode) ?? -1
        chat.setMode(ids[(i + 1) % ids.count])
    }

    private func contextColor(_ c: ClaudeChat.Context) -> Color {
        c.compactAt > 0 && c.used >= c.compactAt * 9 / 10 ? Theme.amber : accent
    }

    private func contextDetail(_ c: ClaudeChat.Context) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context: \(c.used / 1000)k of \(c.max / 1000)k tokens (\(c.percent)%)").font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text)
            ForEach(Array(c.categories.enumerated()), id: \.offset) { _, cat in
                HStack {
                    Text(cat.name).foregroundStyle(Theme.body)
                    Spacer()
                    Text(cat.tokens >= 1000 ? "\(cat.tokens / 1000)k" : "\(cat.tokens)").monospacedDigit().foregroundStyle(Theme.text3)
                }
                .font(Typo.ui(11.5))
            }
            if c.autoCompact, c.compactAt > 0 {
                Text("Compacts automatically at \(c.compactAt / 1000)k").font(Typo.ui(11)).foregroundStyle(Theme.text3)
            }
            if chat.sessionCost > 0 {
                Text(String(format: "API-equivalent cost this session: $%.2f (not what a subscription is charged)", chat.sessionCost))
                    .font(Typo.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                SubtleButton(title: "Compact Now", height: 26) { showContext = false; chat.compact() }.disabled(chat.working)
            }
        }
        .padding(14).frame(width: 300)
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !attachments.isEmpty else { return }
        // As in the terminal: !command runs it here, #note goes into CLAUDE.md.
        // Only a one-line "!cmd" or "# note": pasted text that happens to start with ! or # is a message.
        let oneLine = !t.contains("\n") && attachments.isEmpty
        if oneLine, t.count > 1, t.hasPrefix("!"), let c = t.dropFirst().first, !c.isWhitespace, c != "!" {
            chat.runBash(String(t.dropFirst()))
            draft = ""
            return
        }
        if oneLine, t.hasPrefix("# "), t.count > 2 {
            let note = String(t.dropFirst(2))
            // The draft stays until you say yes, so Cancel keeps it.
            store.confirm("Add this to CLAUDE.md?", "\"\(note.trimmingCharacters(in: .whitespaces))\" is added to \(((chat.cwd as NSString).abbreviatingWithTildeInPath))/CLAUDE.md, which Claude reads in every conversation here. To send it to Claude instead, cancel and remove the #.",
                          confirm: "Add", destructive: false, onCancel: nil) {
                if let why = chat.addMemory(note) { store.toast(.error, "Couldn't update CLAUDE.md", detail: why) } else { draft = "" }
            }
            return
        }
        if chat.bashRunning > 0 {
            attachError = "Waiting for the ! command to finish, so its output goes with this message."
            return
        }
        store.sendInput(chat.sessionID, t, images: attachments)
        draft = ""
        attachments = []
        nextImage = 1
        attachError = nil
    }
}

/// One tool call: its name and target on a line, the details and result folded away.
private struct ToolCard: View {
    let item: ClaudeChat.Item
    let running: Bool
    /// Sends this running command or subagent to the background (⌃B).
    var onBackground: (() -> Void)? = nil
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.symbol(item.tool)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text3).frame(width: 14)
                    Text(Self.label(item.tool)).font(Typo.ui(12, .semibold)).foregroundStyle(Theme.body)
                    Text(item.text).font(Typo.mono(11.5)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if !item.children.isEmpty {
                        Text("\(item.children.filter { $0.kind == .tool }.count) steps").font(Typo.ui(10.5)).foregroundStyle(Theme.text3)
                    }
                    if let onBackground {
                        Button(action: onBackground) {
                            Text("Background").font(Typo.ui(10.5, .medium)).foregroundStyle(Theme.text2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white(0.06)))
                        }
                        .buttonStyle(.hand).help("Keep it running in the background and carry on (⌃B)")
                    }
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
            if running, !open, let last = item.children.last {
                // A working subagent: its latest step.
                Text(last.kind == .tool ? "\(Self.label(last.tool)) \(last.text)" : last.text)
                    .font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if !item.children.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(item.children) { c in
                                if c.kind == .tool { ToolCard(item: c, running: c.result == nil && running) }
                                else { MarkdownView(text: c.text, scrolls: false).padding(.leading, 4) }
                            }
                        }
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
                    }
                    if let d = item.diff { DiffBlock(diff: d) }
                    if !item.detail.isEmpty { mono(item.detail, limit: 60) }
                    if let r = item.result, !r.isEmpty { mono(r, limit: 80, color: item.failed ? Theme.red : Theme.text3) }
                    ForEach(Array(item.resultImages.enumerated()), id: \.offset) { _, d in
                        if let img = NSImage(data: d) {
                            Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: min(480, img.size.width), maxHeight: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
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
/// The choices match the terminal's.
private struct AskCard: View {
    @Environment(\.accent) private var accent
    let chat: ClaudeChat
    let ask: ClaudeChat.Ask
    @State private var picks: [String: Set<String>] = [:]
    /// Typed "Other" answers, per question.
    @State private var other: [String: String] = [:]
    /// What to tell Claude instead (deny) or what to change (keep planning).
    @State private var note = ""
    @State private var noting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !ask.questions.isEmpty {
                questions
            } else if ask.tool == "ExitPlanMode" {
                plan
            } else {
                permission
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sheet))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.amber.opacity(0.45)))
    }

    // MARK: Plan

    @ViewBuilder private var plan: some View {
        HStack {
            Text("Claude has a plan and is ready to start").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
            Spacer()
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ask.detail, forType: .string) } label: {
                Label("Copy Plan", systemImage: "doc.on.doc").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
            }
            .buttonStyle(.hand)
        }
        ScrollView { MarkdownView(text: ask.detail, scrolls: false).padding(.trailing, 6) }.frame(maxHeight: 280)
        option("Yes, and auto-accept edits", key: "1", primary: true) { chat.approvePlan(ask, mode: "acceptEdits") }
            .keyboardShortcut(noting ? nil : .defaultAction)
        option("Yes, and approve each edit", key: "2") { chat.approvePlan(ask, mode: "default") }
        noteOption("No, keep planning", key: "3", placeholder: "What should change in the plan?") {
            chat.deny(ask, message: note.isEmpty ? "The user wants to keep planning. Ask what to change." : "Keep planning. The user says: " + note)
        }
    }

    // MARK: Permission

    @ViewBuilder private var permission: some View {
        HStack(spacing: 6) {
            Image(systemName: ToolCard.symbol(ask.tool)).font(.system(size: 11)).foregroundStyle(Theme.amber)
            Text(ask.title.isEmpty ? "Allow \(ToolCard.label(ask.tool).lowercased())?" : ask.title)
                .font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(2)
            if ask.title.isEmpty {
                Text(ask.summary).font(Typo.mono(11.5)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
            }
        }
        if !ask.reason.isEmpty { Text(ask.reason).font(Typo.ui(11.5)).foregroundStyle(Theme.text3) }
        // Sized to what it shows (a capped ScrollView would take its full height).
        if let d = ask.diff { DiffBlock(diff: d, maxLines: 14) }
        if !ask.detail.isEmpty {
            let lines = ask.detail.components(separatedBy: "\n")
            Text(lines.prefix(10).joined(separator: "\n") + (lines.count > 10 ? "\n… \(lines.count - 10) more lines" : ""))
                .font(Typo.mono(11)).foregroundStyle(Theme.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well))
        }
        if !ask.blockedPath.isEmpty {
            Text("Outside the working folder: " + (ask.blockedPath as NSString).abbreviatingWithTildeInPath)
                .font(Typo.ui(11)).foregroundStyle(Theme.amber)
        }
        option("Yes", key: "1", primary: true) { chat.allow(ask) }.keyboardShortcut(noting ? nil : .defaultAction)
        ForEach(Array(ask.suggestions.enumerated()), id: \.element.id) { i, sug in
            option(sug.label, key: "\(i + 2)", warn: sug.saved) { chat.allow(ask, also: sug) }
        }
        noteOption("No, and tell Claude what to do instead", key: "\(ask.suggestions.count + 2)", placeholder: "Optional: what Claude should do instead") {
            chat.deny(ask, message: note)
        }
    }

    // MARK: Options

    private func option(_ title: String, key: String, primary: Bool = false, warn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(key).font(Typo.mono(11, .semibold)).foregroundStyle(Theme.text3).frame(width: 14)
                Text(title).font(Typo.ui(12.5, primary ? .semibold : .regular)).foregroundStyle(primary ? Theme.text : Theme.body)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if warn { Image(systemName: "square.and.arrow.down").font(.system(size: 10)).foregroundStyle(Theme.text3).help("Saved to a settings file") }
            }
            .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(primary ? accent.opacity(0.10) : Color.white(0.03)))
        }
        .buttonStyle(.hand)
    }

    /// The "No" choice: a click opens a note field; ⏎ in it sends the note.
    @ViewBuilder private func noteOption(_ title: String, key: String, placeholder: String, send: @escaping () -> Void) -> some View {
        if noting {
            HStack(spacing: 8) {
                TextField(placeholder, text: $note).textFieldStyle(.plain).font(Typo.ui(12.5)).onSubmit(send)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white(0.05)))
                SubtleButton(title: "Send", height: 28, action: send)
            }
        } else {
            option(title, key: key) { noting = true }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Questions

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
                        if !q.multi { other[q.question] = nil }
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
                // Claude is told the app adds a free-text "Other" answer.
                TextField(q.multi ? "Type something" : "Other: type your own answer", text: Binding(
                    get: { other[q.question] ?? "" },
                    set: { other[q.question] = $0; if !q.multi, !$0.isEmpty { picks[q.question] = [] } }))
                    .textFieldStyle(.plain).font(Typo.ui(12.5))
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.white(0.03)))
                    .onSubmit { if ask.questions.count == 1, !(other[q.question] ?? "").isEmpty { submit() } }
            }
        }
        HStack {
            Spacer()
            SubtleButton(title: "Skip", height: 28) { chat.deny(ask, message: "The user skipped the question.") }
            AccentButton(title: "Answer", height: 28) { submit() }
                .disabled(ask.questions.contains { answer(for: $0).isEmpty })
        }
    }

    private func answer(for q: ClaudeChat.Question) -> String {
        let chosen = q.options.map(\.label).filter { picks[q.question, default: []].contains($0) }
        let typed = (other[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (chosen + (typed.isEmpty ? [] : [typed])).joined(separator: ", ")
    }

    private func submit() {
        var answers: [String: String] = [:]
        for q in ask.questions { answers[q.question] = answer(for: q) }
        chat.answer(ask, answers)
    }
}

/// NSImage isn't Sendable; each one here is only read, on one thread at a time.
private struct UncheckedImage: @unchecked Sendable { let image: NSImage }

/// Chat · Terminal for a Claude agent: the same conversation shown either way.
/// Hidden for anything else (other agents, shells, a conversation Brix can't resume).
struct AgentViewSwitch: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let sessionID: String

    var body: some View {
        if let s = store.session(sessionID), s.kind == .agent, s.isLive, s.externalID != nil, store.agent(for: s)?.binary == "claude" {
            HStack(spacing: 2) {
                segment("Chat", symbol: "bubble.left", on: s.isChat) { store.reopen(sessionID, asChat: true) }
                segment("Terminal", symbol: "terminal", on: !s.isChat) { store.reopen(sessionID, asChat: false) }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("View")
        }
    }

    private func segment(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { if !on { action() } } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
                Text(title).font(Typo.ui(11, on ? .semibold : .medium))
            }
            .foregroundStyle(on ? Theme.onAccent : Theme.text2)
            .padding(.horizontal, 8).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hand)
        .help(on ? "Showing as \(title.lowercased())" : "Show this conversation as \(title == "Chat" ? "a chat" : "a terminal")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
