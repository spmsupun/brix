import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Project settings: General, Resources, Layout, Environment, Agents, Danger zone.
struct ProjectSettingsView: View {
    @Environment(AppStore.self) private var store
    let projectID: ProjectID
    @State private var section = "Resources"

    private let sections = ["General", "Resources", "Layout", "Environment", "Agents", "Danger zone"]

    var body: some View {
        if let p = store.project(projectID) {
            HStack(spacing: 0) {
                nav(p).frame(width: 196)
                Rectangle().fill(Theme.divider).frame(width: 1)
                Group {
                    switch section {
                    case "General": GeneralSettings(project: p)
                    case "Layout": LayoutProjectSettings(project: p)
                    case "Environment": EnvironmentSettings(project: p)
                    case "Agents": AgentSettings(project: p)
                    case "Danger zone": DangerZone(project: p)
                    default: ResourcesSettings(project: p)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .island()
            .onAppear { if let s = store.projectSettingsSection { section = s; store.projectSettingsSection = nil } }
            .onChange(of: store.projectSettingsSection) { _, s in if let s { section = s; store.projectSettingsSection = nil } }
        }
    }

    private func nav(_ p: Project) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                ProjectMark(project: p, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text("Project settings").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 14)
            ForEach(sections, id: \.self) { s in
                let on = s == section
                Button { section = s } label: {
                    HStack {
                        Text(s).font(Typo.ui(12.5, on ? .medium : .regular))
                            .foregroundStyle(s == "Danger zone" ? Theme.red : (on ? Theme.text : Theme.text2))
                        Spacer()
                        if s == "Resources" {
                            Text("\(store.library.links.pairs.filter { $0.project == p.id }.count)").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                        }
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Theme.selected : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
            SubtleButton(title: "Open workspace", height: 26, fullWidth: true) { store.openProject(p.id) }
        }
        .padding(.horizontal, 10).padding(.vertical, 16)
    }
}

private struct SettingsHeader: View {
    let title: String
    let sub: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Typo.pageTitle).foregroundStyle(Theme.text)
                Text(sub).font(Typo.ui(12.5)).foregroundStyle(Theme.text3)
            }
            Spacer()
            if let trailing { Text(trailing).font(Typo.ui(12)).foregroundStyle(Theme.text2) }
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
        .hairlineBottom()
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppStore.self) private var store
    let project: Project
    @State private var name = ""
    @State private var path = ""
    @State private var hue: ProjectHue = .violet
    @State private var mark = ""
    @State private var symbol: String?
    @State private var iconPath: String?
    @State private var github = ""
    @State private var detected: String?
    @State private var account: String?
    @State private var accounts: [String] = []
    @State private var pathError: String?

    static let symbols = ["folder.fill", "shippingbox.fill", "globe", "cart.fill", "creditcard.fill", "server.rack", "cpu", "iphone",
                          "desktopcomputer", "gamecontroller.fill", "brain", "bolt.fill", "leaf.fill", "flame.fill", "star.fill", "hammer.fill",
                          "paintbrush.fill", "book.fill", "chart.bar.fill", "lock.fill", "cloud.fill", "airplane", "car.fill", "heart.fill"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "General", sub: "Display name, icon, location and colour.")
            VStack(alignment: .leading, spacing: 16) {
                BXTextField(label: "Display name", text: $name)
                iconPicker
                HStack(alignment: .bottom, spacing: 8) {
                    BXTextField(label: "Folder", text: $path, mono: true, error: pathError)
                    SubtleButton(title: "Choose…", height: 32) { choose() }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Colour").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                    HuePicker(selection: $hue)
                }
                if store.git[project.id]?.isRepo == true {
                VStack(alignment: .leading, spacing: 4) {
                    BXTextField(label: "GitHub repository", text: $github, placeholder: detected ?? "owner/repo", mono: true)
                    Text(detected.map { "Found \($0) from the git remote. Leave empty to use it." } ?? "Pull requests and pipelines show on the project overview, through your GitHub CLI (gh) sign-in.")
                        .font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                }
                if accounts.count > 1 || account != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("GitHub account").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                        Picker("", selection: $account) {
                            Text("Automatic\(project.githubAccountSeen.map { " (\($0))" } ?? "")").tag(String?.none)
                            ForEach(accounts, id: \.self) { Text($0).tag(String?.some($0)) }
                            if let a = account, !accounts.contains(a) { Text("\(a) (not signed in)").tag(String?.some(a)) }
                        }
                        .labelsHidden().frame(width: 260)
                        Text("Automatic tries each account signed in to gh and remembers the one that can see this repo.")
                            .font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                    }
                }
                } else if !store.children(of: project.id).isEmpty {
                    Text("GitHub is set per repository: open one of \(project.name)'s repositories to change its repository or account.")
                        .font(Typo.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Pinned to the top of lists", isOn: Binding(get: { project.isPinned }, set: { _ in store.togglePin(project.id) })).toggleStyle(.bx)
                    .font(Typo.ui(12.5)).foregroundStyle(Theme.text).frame(width: 340)
                if !project.isSample {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Keep settings in brix.json", isOn: Binding(get: { project.keepsSettingsFile }, set: { v in
                            var p = project
                            p.syncsSettingsFile = v
                            store.updateProject(p)
                        }))
                        .toggleStyle(.bx).font(Typo.ui(12.5)).foregroundStyle(Theme.text).frame(width: 340)
                        Text("Layout, agent, linked hosts, databases and Docker targets, saved in the project folder so they travel with the repo. Never passwords.")
                            .font(Typo.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                        if let err = store.projectFileErrors[project.id] {
                            Text(err).font(Typo.ui(11.5)).foregroundStyle(Theme.red)
                        }
                    }
                }
                HStack {
                    AccentButton(title: "Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !project.isSample {
                        SubtleButton(title: "Reload from brix.json") { store.loadProjectFile(project.id) }
                        SubtleButton(title: "Reveal File") {
                            NSWorkspace.shared.activateFileViewerSelecting([ProjectFile.url(for: project)])
                        }
                        .disabled(!FileManager.default.fileExists(atPath: ProjectFile.url(for: project).path))
                    }
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(22)
        }
        .onAppear {
            name = project.name; path = project.path; hue = project.hue
            mark = project.mark ?? ""; symbol = project.iconSymbol; iconPath = project.iconPath
            github = project.githubRepo ?? ""
            account = project.githubAccount
        }
        .task(id: project.id) {
            var p = project
            p.githubRepo = nil
            detected = await GitHub.detectRepo(p)
            if GitHub.installed { accounts = (try? await GitHub.accounts()) ?? [] }
        }
    }

    /// Initials, a symbol, or an image file; previewed live in the project's colour.
    private var iconPicker: some View {
        var preview = project
        preview.name = name.isEmpty ? project.name : name
        preview.hue = hue
        preview.mark = mark.isEmpty ? nil : mark
        preview.iconSymbol = symbol
        preview.iconPath = iconPath
        return VStack(alignment: .leading, spacing: 8) {
            Text("Icon").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
            HStack(alignment: .top, spacing: 14) {
                ProjectMark(project: preview, size: 76)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        BXTextField(label: "", text: Binding(get: { mark }, set: { mark = String($0.prefix(3)) }), placeholder: "Initials, e.g. \(project.initials)")
                            .frame(width: 160)
                        SubtleButton(title: "Image…", symbol: "photo", height: 30) { chooseImage() }
                        if symbol != nil || iconPath != nil {
                            SubtleButton(title: "Use Initials", height: 30) { symbol = nil; iconPath = nil }
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 5), count: 12), alignment: .leading, spacing: 5) {
                        ForEach(Self.symbols, id: \.self) { s in
                            Button { symbol = s; iconPath = nil } label: {
                                Image(systemName: s).font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(symbol == s ? hue.color : Theme.text2)
                                    .frame(width: 34, height: 34)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(symbol == s ? hue.color.opacity(0.16) : Color.white(0.04)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(s)
                        }
                    }
                }
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .icns, .svg, .tiff, .heic]
        panel.directoryURL = project.url
        guard panel.runModal() == .OK, let u = panel.url else { return }
        // Inside the project the path stays relative, so brix.json travels with the repo.
        let root = project.url.standardizedFileURL.path + "/"
        iconPath = u.path.hasPrefix(root) ? String(u.path.dropFirst(root.count)) : u.path
        symbol = nil
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        if p.runModal() == .OK, let u = p.url {
            let home = NSHomeDirectory()
            path = u.path.hasPrefix(home) ? "~" + u.path.dropFirst(home.count) : u.path
        }
    }

    private func save() {
        var p = project
        let full = (path as NSString).expandingTildeInPath
        if !p.isSample, path != p.path {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { pathError = "That folder doesn't exist"; return }
        }
        pathError = nil
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.path = path
        p.hue = hue
        p.mark = mark.trimmingCharacters(in: .whitespaces).isEmpty ? nil : mark.trimmingCharacters(in: .whitespaces)
        p.iconSymbol = symbol
        p.iconPath = iconPath
        let repo = github.trimmingCharacters(in: .whitespaces)
        p.githubRepo = repo.isEmpty ? nil : repo
        p.githubAccount = account
        ProjectIcons.forget(p)
        store.updateProject(p)
        store.refreshGit(p.id)
        store.toast(.success, "Saved \(p.name)")
    }
}

// MARK: - Resources

private struct ResourcesSettings: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        let total = store.library.links.pairs.filter { $0.project == project.id }.count
        VStack(spacing: 0) {
            SettingsHeader(title: "Resources", sub: "Servers, databases and containers this project uses. One resource can belong to many projects.",
                           trailing: "\(total) resources linked")
            GeometryReader { geo in
                let w = (geo.size.width - 1) / 2
                let h = (geo.size.height - 1) / 2
                VStack(spacing: 1) {
                    HStack(spacing: 1) {
                        group("SSH servers", add: "Server", kind: .host, items: store.library.hosts.map { h in
                            Item(id: h.id, name: h.name, sub: h.address, tag: h.tag.label, tagColor: h.tag.color, badge: "SSH", dot: (store.hostStatus[h.id] ?? .disconnected).color)
                        }) { store.sheet = .editHost(nil) }
                        .frame(width: w, height: h)
                        group("Databases", add: "Database", kind: .database, items: store.library.databases.map { d in
                            Item(id: d.id, name: d.name, sub: d.endpoint + (d.effectiveReadOnly ? " · read-only" : ""), tag: d.tag.label, tagColor: d.tag.color, badge: d.kind.badge, dot: (store.dbStatus[d.id] ?? .disconnected).color)
                        }) { store.sheet = .editDatabase(nil) }
                        .frame(width: w, height: h)
                    }
                    HStack(spacing: 1) {
                        group("Docker", add: "Container", kind: .docker, items: store.allDocker.map { c in
                            Item(id: c.id, name: "\(c.name) · \(c.image)", sub: "\(c.hostID.flatMap(store.host)?.name ?? "local") · \(c.uptimeText.lowercased())\(c.ports.isEmpty ? "" : " · \(c.ports)")",
                                 tag: c.hostID == nil ? "COMPOSE" : "REMOTE", tagColor: c.hostID == nil ? Theme.text2 : Theme.blue, badge: "DK", dot: c.state.color)
                        }) { store.sheet = .addDocker }
                        .frame(width: w, height: h)
                        usage.frame(width: w, height: h)
                    }
                }
                .background(Color.white(0.05))
            }
        }
    }

    struct Item: Identifiable {
        var id: String
        var name: String
        var sub: String
        var tag: String
        var tagColor: Color
        var badge: String
        var dot: Color
    }

    private func group(_ title: String, add: String, kind: ResourceKind, items: [Item], onAdd: @escaping () -> Void) -> some View {
        let linked = items.filter { store.library.links.isLinked(project.id, $0.id) }.count
        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text(title).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                Text("\(linked) of \(items.count) linked").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                Spacer()
                SubtleButton(title: "+ \(add)", height: 26, action: onAdd)
            }
            .padding(.horizontal, 16).frame(height: 44)
            if items.isEmpty {
                EmptyState(symbol: "plus.circle", message: "Nothing saved yet.", actionTitle: "Add \(add)", action: onAdd)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { i in row(i, kind: kind) }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
        }
        .background(Theme.island)
    }

    private func row(_ i: Item, kind: ResourceKind) -> some View {
        let on = store.library.links.isLinked(project.id, i.id)
        let others = store.library.links.projects(for: i.id).filter { $0 != project.id }.compactMap(store.project)
        return HStack(spacing: 11) {
            Toggle("", isOn: Binding(get: { on }, set: { store.setLink(project.id, i.id, kind: kind, linked: $0) }))
                .toggleStyle(.bx).labelsHidden().frame(width: 34)
                .accessibilityLabel("Link \(i.name)")
            Text(i.badge).font(.system(size: 8.5, weight: .heavy)).foregroundStyle(Theme.text2)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(i.name).font(Typo.ui(12.5, .medium)).foregroundStyle(on ? Theme.text : Theme.text2).lineLimit(1)
                    Text(i.tag).font(.system(size: 8.5, weight: .bold)).foregroundStyle(i.tagColor)
                }
                Text(i.sub).font(Typo.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: -6) {
                ForEach(others.prefix(3)) { p in
                    ProjectMark(project: p, size: 20)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.island).padding(-2))
                        .help(p.name)
                }
            }
            .accessibilityLabel(others.isEmpty ? "" : "Also used by \(others.map(\.name).joined(separator: ", "))")
            Circle().fill(i.dot).frame(width: 6, height: 6)
        }
        .padding(.horizontal, 10).frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.white(0.035) : .clear))
    }

    private var usage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How \(project.name) shows them").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
            use("terminal", "Terminals", "New terminal → pick a linked server to open an SSH shell inside this workspace.")
            use("cylinder.split.1x2", "Database panel", "Linked databases appear in the panel picker and in ⌘K.")
            use("shippingbox", "Docker panel", "Start, stop and tail logs for linked containers, local or remote.")
            use("sparkle", "Agent context", "Agents get connection names (never secrets) so they can reason about your stack.")
            Spacer(minLength: 0)
            AccentButton(title: "Open workspace →") { store.openProject(project.id) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.island)
    }

    private func use(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.text2)
                .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 6).fill(Color.white(0.05)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text)
                Text(body).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineSpacing(2)
            }
        }
    }
}

// MARK: - Layout

private struct LayoutProjectSettings: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        let ws = store.workspace(for: project.id)
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "Layout", sub: "The preset new windows of this project start with, and its saved arrangement.")
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default preset").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                    SegmentedControl(options: BuiltinPreset.shown.map { ($0.rawValue, $0.label) },
                                     selection: Binding(get: { project.defaultPreset }, set: { v in var p = project; p.defaultPreset = v; store.updateProject(p) }), fill: Theme.input)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current arrangement · \(ws.activePresetName)").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                    LayoutPreview(layout: ws.layout).frame(maxWidth: 640)
                }
                HStack {
                    SubtleButton(title: "Reset to default preset") {
                        ws.apply(BuiltinPreset(rawValue: project.defaultPreset) ?? .code)
                        store.toast(.success, "Layout reset")
                    }
                    SubtleButton(title: "Save as preset…") { store.sheet = .savePreset(project.id) }
                    SubtleButton(title: "Use as default for new projects") {
                        store.library.defaultLayout = ws.layout
                        store.toast(.success, "Saved as the default layout")
                    }
                }
            }
            .padding(22)
        }
    }
}

// MARK: - Environment

private struct EnvironmentSettings: View {
    @Environment(AppStore.self) private var store
    let project: Project
    @State private var newVar = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "Environment", sub: "Variable names this project expects. Values are never shown here.")
            VStack(alignment: .leading, spacing: 8) {
                if project.envVarNames.isEmpty {
                    Text("No variables listed.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
                }
                ForEach(project.envVarNames, id: \.self) { v in
                    HStack(spacing: 10) {
                        Text(v).font(Typo.mono(12)).foregroundStyle(Theme.text)
                        Spacer()
                        Text("•••••••").font(Typo.mono(12)).foregroundStyle(Theme.text3).accessibilityLabel("Value hidden")
                        IconButton(symbol: "minus.circle", label: "Remove \(v)", iconSize: 12) {
                            var p = project; p.envVarNames.removeAll { $0 == v }; store.updateProject(p)
                        }
                    }
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.editor))
                }
                HStack(spacing: 8) {
                    BXTextField(label: "", text: $newVar, placeholder: "NEW_VARIABLE_NAME", mono: true)
                        .onSubmit(add)
                    SubtleButton(title: "Add", height: 32) { add() }
                }
                Text("Brix reads names only, for agents and checks. Keep values in your .env files or the Keychain.").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(22)
        }
    }

    private func add() {
        let n = newVar.trimmingCharacters(in: .whitespaces).uppercased()
        guard n.range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) != nil else {
            store.toast(.error, "Use letters, digits and underscores")
            return
        }
        guard !project.envVarNames.contains(n) else { return }
        var p = project
        p.envVarNames.append(n)
        store.updateProject(p)
        newVar = ""
    }
}

// MARK: - Agents

private struct AgentSettings: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        let names = store.linkedHosts(project.id).map(\.name) + store.linkedDatabases(project.id).map(\.name) + store.linkedDocker(project.id).map(\.name)
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "Agents", sub: "Which coding agent starts in this project.")
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("Default agent").font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text)
                    Spacer()
                    Picker("Default agent", selection: Binding(get: { project.agentID ?? "" }, set: { v in
                        var p = project
                        p.agentID = v.isEmpty ? nil : v
                        store.updateProject(p)
                    })) {
                        Text(store.agent(store.settings.defaultAgent).map { "App default (\($0.name))" } ?? "Ask every time").tag("")
                        ForEach(store.enabledAgents) { a in Text(a.name).tag(a.id) }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
                Text("Runs in a terminal at \(project.path). Commands and installs are managed in Customize → Agents.").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Context passed to new sessions").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                    Text(names.isEmpty ? "No linked resources." : "Linked resources by name only: " + names.joined(separator: ", "))
                        .font(Typo.ui(12)).foregroundStyle(Theme.body)
                    Text("Secrets are never passed to agents. Only Claude Code takes this as a system prompt.").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                }
                HStack {
                    AccentButton(title: "Start a session now") { store.startAgent(project: project.id) }
                    SubtleButton(title: "Manage agents…") { store.showAgentSettings() }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(22)
        }
    }
}

// MARK: - Danger zone

private struct DangerZone: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader(title: "Danger zone", sub: "Actions that can't be undone.")
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Remove \(project.name) from Brix").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                        Text("Forgets the project, its layout, sessions and links. Files on disk are not touched.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    SubtleButton(title: "Remove Project…", destructive: true) { store.requestRemoveProject(project.id) }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.red.opacity(0.35)))
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reset workspace layout").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                        Text("Closes open files and restores the default preset.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    SubtleButton(title: "Reset…", destructive: true) {
                        store.confirm("Reset the layout of \(project.name)?", "Open files and panel positions are cleared.", confirm: "Reset") {
                            let ws = store.workspace(for: project.id)
                            ws.state = WorkspaceState(layout: .preset(BuiltinPreset(rawValue: project.defaultPreset) ?? .code))
                            store.toast(.success, "Layout reset")
                        }
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(22)
        }
    }
}
