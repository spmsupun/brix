import SwiftUI
import UniformTypeIdentifiers

/// Asks which agent to start when no default is set.
struct ChooseAgentSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    let projectID: ProjectID
    @State private var remember = false

    var body: some View {
        let sample = store.project(projectID)?.isSample == true
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start an agent").font(Typo.pageTitle).foregroundStyle(Theme.text)
                Text("In \(store.project(projectID)?.name ?? "this project"). Linked resources are shared by name only.")
                    .font(Typo.ui(12)).foregroundStyle(Theme.text3)
            }
            if store.enabledAgents.isEmpty {
                EmptyState(symbol: "sparkle", message: "No agents are turned on.", actionTitle: "Manage agents…") {
                    dismiss(); store.showAgentSettings()
                }
                .frame(height: 160)
            }
            VStack(spacing: 6) {
                ForEach(Array(store.enabledAgents.enumerated()), id: \.element.id) { i, a in
                    let ready = store.isInstalled(a) || sample
                    Button { pick(a, ready: ready) } label: {
                        HStack(spacing: 11) {
                            AgentMark(agent: a, size: 18)
                                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(Color.white(0.05)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                                Text(ready ? a.command : "Not installed. Choose to install with: \(a.installCommand)")
                                    .font(Typo.mono(11)).foregroundStyle(ready ? Theme.text3 : Theme.amber).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            if i < 9 { KeyCap(text: "⌘\(i + 1)") }
                        }
                        .padding(.horizontal, 10).rowHeight(46)
                        .rowBackground(selected: false, radius: 9)
                    }
                    .buttonStyle(.hand)
                    .keyboardShortcut(i < 9 ? KeyEquivalent(Character("\(i + 1)")) : KeyEquivalent(" "), modifiers: i < 9 ? .command : [])
                }
            }
            Toggle("Always start the agent I pick", isOn: $remember).toggleStyle(.bx)
                .font(Typo.ui(12.5)).foregroundStyle(Theme.body)
            HStack {
                LinkButton(title: "Manage agents…") { dismiss(); store.showAgentSettings() }
                Spacer()
                SubtleButton(title: "Cancel") { store.agentCompletion = nil; dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.sheet)
    }

    private func pick(_ a: AgentConfig, ready: Bool) {
        let then = store.agentCompletion
        store.agentCompletion = nil
        dismiss()
        guard ready else { store.installAgent(a); return }
        if remember { store.settings.defaultAgent = a.id }
        store.launchAgent(a, project: projectID, then: then)
    }
}

/// Add or edit an agent: name, launch command, install command.
struct AgentEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let existing: AgentConfig?
    @State private var name = ""
    @State private var command = ""
    @State private var install = ""
    @State private var icon = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add Agent" : "Edit \(existing!.name)").font(Typo.pageTitle).foregroundStyle(Theme.text)
            Text("Any command-line agent works. It starts in a terminal in the project folder.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
            BXTextField(label: "Name", text: $name, placeholder: "Aider")
            BXTextField(label: "Launch command", text: $command, placeholder: "aider --model sonnet", mono: true, error: error)
            BXTextField(label: "Install command (optional)", text: $install, placeholder: "brew install aider", mono: true)
            HStack(spacing: 10) {
                AgentMark(agent: preview, size: 22)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 8).fill(Color.white(0.05)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logo").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                    Text(icon.isEmpty ? "Built in" : (icon as NSString).lastPathComponent).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer()
                SubtleButton(title: "Choose Image…", height: 26) { chooseIcon() }
                if !icon.isEmpty { SubtleButton(title: "Use Built-in", height: 26) { icon = "" } }
            }
            HStack {
                Spacer()
                SubtleButton(title: "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                AccentButton(title: existing == nil ? "Add" : "Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.sheet)
        .onAppear {
            name = existing?.name ?? ""
            command = existing?.command ?? ""
            install = existing?.installCommand ?? ""
            icon = existing?.iconPath ?? ""
        }
    }

    private var preview: AgentConfig {
        var a = existing ?? AgentConfig(id: "preview", name: name, command: command)
        a.command = command.isEmpty ? a.command : command
        a.iconPath = icon
        return a
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .pdf, .svg, .icns, .tiff]
        panel.message = "Choose a logo image for this agent"
        if panel.runModal() == .OK, let url = panel.url { icon = url.path }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let c = command.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { error = "Enter the command that starts the agent"; return }
        var a = existing ?? AgentConfig(id: "custom-\(UUID().uuidString.prefix(6))", name: "", command: "")
        a.name = n.isEmpty ? (c.split(separator: " ").first.map(String.init) ?? c) : n
        a.command = c
        a.installCommand = install.trimmingCharacters(in: .whitespaces)
        a.iconPath = icon
        store.saveAgent(a)
        dismiss()
    }
}

/// Customize → Agents: which agents exist, install state, default, usage in the toolbar.
struct AgentSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var selected: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("When starting an agent").font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text)
                        Text("Projects can override this in Project Settings → Agents.").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Picker("Default agent", selection: Binding(get: { store.settings.defaultAgent ?? "" }, set: { store.settings.defaultAgent = $0.isEmpty ? nil : $0 })) {
                        Text("Ask every time").tag("")
                        ForEach(store.enabledAgents) { a in Text("Start \(a.name)").tag(a.id) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                VStack(spacing: 0) {
                    HStack {
                        Text("Agent")
                        Spacer()
                        Text("Usage in status bar").frame(width: 150, alignment: .leading)
                        Text("On").frame(width: 50, alignment: .leading)
                        Color.clear.frame(width: 60)
                    }
                    .font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Color.white(0.02))
                    .hairlineBottom()
                    ForEach(store.settings.agents) { a in row(a) }
                }
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    SubtleButton(title: "Add Agent…", symbol: "plus", height: 26) { store.sheet = .editAgent(nil) }
                    SubtleButton(title: "Check Again", symbol: "arrow.clockwise", height: 26) {
                        store.refreshAgentPaths()
                        Task { await store.refreshAgentUsage() }
                    }
                    Spacer()
                }
                if let id = selected ?? store.settings.agents.first(where: { store.isInstalled($0) })?.id, let a = store.agent(id) {
                    AgentOverviewView(agent: a).id(a.id)
                }
                Text("Usage comes from files the CLIs write on this Mac: Codex session logs, and for Claude Code a status line cache at ~/.claude/state/rate-limits.json. Nothing is sent anywhere.")
                    .font(Typo.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .onAppear { store.refreshAgentPaths() }
    }

    private func row(_ a: AgentConfig) -> some View {
        let path = store.agentPaths[a.id]
        let usage = store.agentUsage[a.id] ?? []
        return HStack(spacing: 10) {
            AgentMark(agent: a, size: 15).opacity(a.enabled ? 1 : 0.4)
                .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(Color.white(0.05)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.name).font(Typo.row).foregroundStyle(Theme.text)
                    if store.settings.defaultAgent == a.id {
                        Text("DEFAULT").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(Theme.text3)
                    }
                }
                Text(path ?? "Not installed").font(Typo.mono(10.5)).foregroundStyle(path == nil ? Theme.amber : Theme.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if path == nil, !a.installCommand.isEmpty {
                SubtleButton(title: "Install", height: 24) { store.installAgent(a) }
            }
            HStack(spacing: 6) {
                Toggle("", isOn: Binding(get: { a.showUsage }, set: { v in
                    var c = a; c.showUsage = v; store.saveAgent(c)
                    Task { await store.refreshAgentUsage() }
                })).toggleStyle(.bx).labelsHidden().fixedSize()
                Text(usage.isEmpty ? "–" : usage.map { "\($0.label) \(Int($0.percent))%" }.joined(separator: " "))
                    .font(Typo.ui(10.5)).monospacedDigit().foregroundStyle(Theme.text3).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            .help(usage.isEmpty ? "No usage data found for \(a.name)" : "Plan usage read from \(a.name)'s local files")
            Toggle("", isOn: Binding(get: { a.enabled }, set: { store.setAgentEnabled(a.id, $0) }))
                .toggleStyle(.bx).labelsHidden().fixedSize().frame(width: 50, alignment: .leading)
                .accessibilityLabel("\(a.name) on")
            HStack(spacing: 0) {
                IconButton(symbol: "pencil", label: "Edit \(a.name)", iconSize: 11) { store.sheet = .editAgent(a) }
                if !a.isBuiltin {
                    IconButton(symbol: "trash", label: "Remove \(a.name)", iconSize: 11) {
                        store.confirm("Remove \(a.name)?", "This only removes it from Brix. The CLI stays installed.", confirm: "Remove") { store.removeAgent(a.id) }
                    }
                }
            }
            .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12).rowHeight(52)
        .background(selected == a.id ? Theme.selected : .clear)
        .contentShape(Rectangle())
        .clickable().onTapGesture { selected = a.id }
        .hairlineBottom(Color.white(0.05))
    }
}

/// Status bar plan usage for agents the user chose to show.
struct AgentUsageChips: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let shown = store.settings.agents.filter { $0.enabled && $0.showUsage && !(store.agentUsage[$0.id] ?? []).isEmpty }
        if !shown.isEmpty {
            HStack(spacing: 12) {
                ForEach(shown) { a in chip(a, store.agentUsage[a.id] ?? []) }
            }
        }
    }

    private func chip(_ a: AgentConfig, _ windows: [UsageWindow]) -> some View {
        Button { store.showAgentSettings() } label: {
            HStack(spacing: 5) {
                AgentMark(agent: a, size: 12)
                Text(a.name.components(separatedBy: " ").first ?? a.name).font(Typo.ui(11, .medium)).foregroundStyle(Theme.text2)
                ForEach(windows, id: \.label) { w in
                    HStack(spacing: 3) {
                        Text(w.label).foregroundStyle(Theme.text3)
                        Text("\(Int(w.percent))%").foregroundStyle(color(w.percent))
                    }
                    .font(Typo.ui(11)).monospacedDigit()
                }
            }
            .lineLimit(1).fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.hand)
        .help(Self.tip(a, windows))
        .accessibilityLabel(Self.spoken(a, windows))
    }

    static func tip(_ a: AgentConfig, _ windows: [UsageWindow]) -> String {
        windows.map { w -> String in
            let reset: String = w.resetsAt.map { ", resets " + $0.formatted(.relative(presentation: .named)) } ?? ""
            return "\(a.name) \(w.label): \(Int(w.percent))% used" + reset
        }.joined(separator: "\n")
    }

    static func spoken(_ a: AgentConfig, _ windows: [UsageWindow]) -> String {
        "\(a.name) usage " + windows.map { "\($0.label) \(Int($0.percent)) percent" }.joined(separator: ", ")
    }

    private func color(_ p: Double) -> Color { p >= 90 ? Theme.red : (p >= 70 ? Theme.amber : Theme.text) }
}

/// Details for one agent on this Mac, shown under the agent list.
struct AgentOverviewView: View {
    @Environment(AppStore.self) private var store
    let agent: AgentConfig
    @State private var o: AgentOverview?
    @State private var tab = "instructions"
    @State private var newName = ""
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AgentMark(agent: agent, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(Typo.ui(14, .semibold)).foregroundStyle(Theme.text)
                    Text(o?.version ?? (store.isInstalled(agent) ? "Reading…" : "Not installed")).font(Typo.mono(11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                IconButton(symbol: "arrow.clockwise", label: "Reload", size: 26, iconSize: 11.5) { Task { await reload() } }
                if let c = o?.configFile {
                    SubtleButton(title: "Settings File", symbol: "doc", height: 26) { store.sheet = .editFile(.local(c.path)) }
                }
            }
            .padding(14).hairlineBottom()
            if let o {
                ScrollView(.horizontal, showsIndicators: false) {
                    SegmentedControl(options: tabs(o), selection: $tab, height: 26, fontSize: 12)
                }
                .padding(.horizontal, 14).padding(.top, 12)
                content(o).padding(14)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(30)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .task(id: agent.id) { await reload() }
        // Edits happen in the file editor sheet; read again when it closes.
        .onChange(of: store.sheet == nil) { _, closed in if closed { Task { await reload() } } }
    }

    private func reload() async {
        let path = store.agentPaths[agent.id]
        let a = agent
        o = await AgentOverview.load(a, path: path)
    }

    private func tabs(_ o: AgentOverview) -> [(String, String)] {
        var t = [("instructions", "Instructions")]
        if o.skillsDir != nil || !o.skills.isEmpty { t.append(("skills", "Skills \(o.skills.count)")) }
        if o.subagentsDir != nil { t.append(("subagents", "Subagents \(o.subagents.count)")) }
        if o.commandsDir != nil { t.append(("commands", "Commands \(o.commands.count)")) }
        t.append(("mcp", "MCP \(o.mcpServers.count)"))
        if agent.binary == "claude" { t.append(("hooks", "Hooks \(o.hookEvents.count)")) }
        return t
    }

    @ViewBuilder private func content(_ o: AgentOverview) -> some View {
        switch tab {
        case "skills": files(o.skills, dir: o.skillsDir, kind: "skill")
        case "subagents": files(o.subagents, dir: o.subagentsDir, kind: "subagent")
        case "commands": files(o.commands, dir: o.commandsDir, kind: "command")
        case "mcp": mcp(o)
        case "hooks": hooks(o)
        default: instructions(o)
        }
    }

    private func instructions(_ o: AgentOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(o.instructions.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "No global instructions file")
                    .font(Typo.mono(11.5)).foregroundStyle(Theme.text2)
                Spacer()
                if let i = o.instructions {
                    LinkButton(title: "Edit") { store.sheet = .editFile(.local(i.path)) }
                }
            }
            ScrollView {
                Text(o.instructionsText ?? "This agent reads no global instructions file, or it hasn't been created yet.")
                    .font(Typo.mono(11.5)).foregroundStyle(o.instructionsText == nil ? Theme.text3 : Theme.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 260)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.editor))
        }
    }

    /// Skills, subagents or commands: each opens in Brix's editor; new ones start from a template.
    private func files(_ items: [AgentOverview.Item], dir: String?, kind: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let dir {
                HStack(spacing: 8) {
                    TextField("New \(kind) name", text: $newName)
                        .textFieldStyle(.plain).font(Typo.ui(12.5))
                        .padding(.horizontal, 8).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.input))
                        .onSubmit { create(kind, in: dir) }
                    SubtleButton(title: "New \(kind.capitalized)", symbol: "plus", height: 26) { create(kind, in: dir) }
                        .disabled(slug.isEmpty)
                    Spacer(minLength: 0)
                    LinkButton(title: "Show Folder") {
                        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                    }
                }
            }
            if items.isEmpty {
                Text("None yet.").font(Typo.ui(12)).foregroundStyle(Theme.meta).padding(.vertical, 6)
            }
            LazyVStack(spacing: 1) {
                ForEach(items) { i in
                    row(i, actions: [
                        MenuSpec(title: "Edit", symbol: "pencil") { store.sheet = .editFile(.local(i.editPath)) },
                        MenuSpec(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: i.path)]) },
                        .separator,
                        MenuSpec(title: "Move to Trash…", symbol: "trash", destructive: true) { trash(i, kind: kind) }
                    ]) { store.sheet = .editFile(.local(i.editPath)) }
                }
            }
        }
    }

    private func mcp(_ o: AgentOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Servers this agent can call. Settings like tokens stay in the config file and are never shown here.")
                    .font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
                if store.agentPaths[agent.id] != nil {
                    SubtleButton(title: "Add…", symbol: "plus", height: 26) { addMCP() }
                }
            }
            if o.mcpServers.isEmpty {
                Text("No MCP servers.").font(Typo.ui(12)).foregroundStyle(Theme.meta).padding(.vertical, 6)
            }
            LazyVStack(spacing: 1) {
                ForEach(o.mcpServers) { i in
                    // Claude Code rewrites ~/.claude.json while it runs, so Brix never saves over it;
                    // its servers change through the CLI only.
                    let editable = !i.path.hasSuffix("/.claude.json")
                    row(i, actions: (editable ? [MenuSpec(title: "Edit Config File", symbol: "pencil") { store.sheet = .editFile(.local(i.path)) }, .separator] : []) + [
                        MenuSpec(title: "Remove…", symbol: "trash", enabled: store.agentPaths[agent.id] != nil, destructive: true) { removeMCP(i.name) }
                    ]) { if editable { store.sheet = .editFile(.local(i.path)) } }
                }
            }
        }
    }

    private func hooks(_ o: AgentOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Commands Claude Code runs on events, from ~/.claude/settings.json.").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
                if let c = o.configFile { SubtleButton(title: "Edit Hooks", symbol: "pencil", height: 26) { store.sheet = .editFile(.local(c.path)) } }
            }
            if o.hookEvents.isEmpty { Text("No hooks.").font(Typo.ui(12)).foregroundStyle(Theme.meta) }
            ForEach(o.hookEvents, id: \.self) { e in
                Text(e).font(Typo.mono(12)).foregroundStyle(Theme.body).padding(.horizontal, 8).frame(height: 26)
            }
        }
    }

    private func row(_ i: AgentOverview.Item, actions: [MenuSpec], open: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(i.name).font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                if !i.detail.isEmpty {
                    Text(i.detail).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            MenuButton(items: { actions }) {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text3)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .opacity(hovered == i.id ? 1 : 0.4)
            .accessibilityLabel("Actions for \(i.name)")
        }
        .padding(.horizontal, 8).frame(minHeight: 36)
        .rowBackground(selected: false)
        .onHover { hovered = $0 ? i.id : (hovered == i.id ? nil : hovered) }
        .onTapGesture(count: 2, perform: open)
        .help("Double-click to edit")
    }

    /// Letters, digits and dashes, as agents expect for skill and command names.
    private var slug: String {
        newName.lowercased().replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func create(_ kind: String, in dir: String) {
        let name = slug
        guard !name.isEmpty else { return }
        let fm = FileManager.default
        let file = kind == "skill" ? "\(dir)/\(name)/SKILL.md" : "\(dir)/\(name).md"
        guard !fm.fileExists(atPath: file) else {
            store.toast(.error, "“\(name)” already exists")
            return
        }
        do {
            try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try AgentOverview.template(kind: kind, name: name).write(toFile: file, atomically: true, encoding: .utf8)
            newName = ""
            store.sheet = .editFile(.local(file))
        } catch {
            store.toast(.error, "Couldn't create \(name)", detail: error.localizedDescription)
        }
    }

    private func trash(_ i: AgentOverview.Item, kind: String) {
        store.confirm("Move “\(i.name)” to the Trash?", "The \(kind) stops being available to \(agent.name). You can put it back from the Trash.", confirm: "Move to Trash") {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: i.path), resultingItemURL: nil)
                Task { await reload() }
            } catch {
                store.toast(.error, "Couldn't move \(i.name) to the Trash", detail: error.localizedDescription)
            }
        }
    }

    private func removeMCP(_ name: String) {
        guard let path = store.agentPaths[agent.id] else { return }
        let args = agent.binary == "claude" ? ["mcp", "remove", name, "-s", "user"] : ["mcp", "remove", name]
        store.confirm("Remove the “\(name)” MCP server?", "\(agent.name) stops using it. Runs \(agent.binary) \(args.joined(separator: " ")).", confirm: "Remove") {
            Task {
                do {
                    let r = try await ProcessRunner.run(path, args, timeout: 20)
                    if r.ok {
                        store.toast(.success, "Removed \(name)")
                    } else {
                        store.toast(.error, "Couldn't remove \(name)", detail: r.stderr.isEmpty ? r.stdout : r.stderr)
                    }
                } catch {
                    store.toast(.error, "Couldn't remove \(name)", detail: error.localizedDescription)
                }
                await reload()
            }
        }
    }

    /// Adding needs the server's command and secrets, so it happens in a terminal with the CLI's own help.
    private func addMCP() {
        let cmd = "\(agent.binary) mcp add --help; echo; echo 'Type the \(agent.binary) mcp add command above, then reload in Brix.'; exec \"$SHELL\" -l"
        let s = store.newTerminal(project: nil, title: "Add MCP server", command: cmd, attach: false)
        store.route = .terminals
        store.focusedSessionID = s.id
    }
}

