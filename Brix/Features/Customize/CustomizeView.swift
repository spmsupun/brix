import SwiftUI

/// Layout and appearance settings. Changes apply instantly and persist.
struct CustomizeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    var inSettingsWindow: Bool

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SegmentedControl(options: [("layout", "Layout"), ("agents", "Agents"), ("accounts", "Accounts")], selection: Bindable(store).customizeTab, height: 26, fontSize: 12.5)
                    Spacer()
                }
                .padding(.horizontal, 12).frame(height: 44).hairlineBottom()
                switch store.customizeTab {
                case "agents": AgentSettingsView()
                case "accounts": AccountsSettings()
                default: LayoutSettings()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipped()
            .island()
            AppearanceSettings().frame(minWidth: 300, idealWidth: 380, maxWidth: 380)
        }
        .padding(inSettingsWindow ? 6 : 0)
        .background(inSettingsWindow ? Theme.base : .clear)
    }
}

private let editablePanels: [PanelKind] = [.explorer, .sourceControl, .terminal, .plan, .agentFiles, .inspector, .connections]

private struct LayoutSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    @State private var renaming: String?
    @State private var newName = ""

    private var layout: DockLayout { store.library.defaultLayout }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Default for new projects. Pick a preset, or set each panel below to make your own.").font(Typo.ui(12)).foregroundStyle(Theme.text3).lineLimit(1)
                Spacer()
                SubtleButton(title: "Save as Custom Layout…", height: 26) { store.sheet = .savePreset(nil) }
                    .disabled(isSavedPreset)
                SubtleButton(title: "Apply to open projects", height: 26) {
                    for id in store.library.openProjects { store.workspace(for: id).state.layout.apply(layout) }
                    store.toast(.success, "Applied to \(store.library.openProjects.count) open project\(store.library.openProjects.count == 1 ? "" : "s")")
                }
                .disabled(appliedEverywhere)
                SubtleButton(title: "Reset", height: 26) {
                    store.library.defaultLayout = .preset(.code)
                    var s = AppSettings()
                    s.agents = store.settings.agents
                    s.defaultAgent = store.settings.defaultAgent
                    store.settings = s
                    store.toast(.info, "Layout and appearance reset")
                }
                .disabled(isDefault)
            }
            .padding(.horizontal, 16).frame(height: 44).hairlineBottom()
            ScrollView {
                VStack(spacing: 16) {
                    presetCards
                    LayoutPreview(layout: layout)
                    panelTable
                    if !store.library.customPresets.isEmpty { customPresets }
                }
                .padding(16)
            }
        }
    }

    /// Every open project already has this arrangement, so applying would do nothing.
    private var appliedEverywhere: Bool {
        store.library.openProjects.allSatisfy { store.workspace(for: $0).state.layout.sameArrangement(as: layout) }
    }

    private var isSavedPreset: Bool {
        guard let n = layout.presetName else { return false }
        return BuiltinPreset(rawValue: n) != nil || store.library.customPresets.contains { $0.id == n }
    }

    private var isDefault: Bool {
        var s = AppSettings()
        s.agents = store.settings.agents
        s.defaultAgent = store.settings.defaultAgent
        s.expandedProjects = store.settings.expandedProjects
        s.collapsedSections = store.settings.collapsedSections
        return layout.sameArrangement(as: .preset(.code)) && layout.presetName == BuiltinPreset.code.rawValue && store.settings == s
    }

    private var presetCards: some View {
        let subs: [BuiltinPreset: String] = [.code: "Files left, changes right, terminal below", .agent: "Agents, plan, files and terminals in one grid",
                                             .review: "Diff centre, changes and files left", .focus: "Only the editor, everything else hidden"]
        let customOn = layout.presetName == nil
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
            ForEach(BuiltinPreset.shown) { p in
                card(p.label, p.shortcut, subs[p] ?? "", on: layout.presetName == p.rawValue) { store.library.defaultLayout = .preset(p) }
            }
            ForEach(store.library.customPresets) { p in
                card(p.name, "", "\(p.layout.allPanels.count) panels · \(p.layout.centre.label) centre", on: layout.presetName == p.id) {
                    var l = p.layout
                    l.presetName = p.id
                    store.library.defaultLayout = l
                }
            }
            if customOn {
                card("Custom", "", "Unsaved changes. Save them to reuse this layout.", on: true) { store.sheet = .savePreset(nil) }
            }
        }
    }

    private func card(_ title: String, _ shortcut: String, _ sub: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().strokeBorder(on ? accent : Theme.disabled, lineWidth: on ? 3.5 : 1.5).frame(width: 12, height: 12)
                    Text(title).font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Text(shortcut).font(Typo.ui(10.5)).foregroundStyle(Theme.meta)
                }
                Text(sub).font(Typo.ui(11)).foregroundStyle(Theme.text3).multilineTextAlignment(.leading).lineLimit(2, reservesSpace: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Color.white(0.06) : Theme.editor))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? accent : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var panelTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Panel")
                Spacer()
                Text("Dock position").frame(width: 260, alignment: .leading)
            }
            .font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3)
            .padding(.horizontal, 12).frame(height: 32)
            .background(Color.white(0.02))
            .hairlineBottom()
            ForEach(editablePanels) { k in
                let current = layout.allPanels.first { $0.kind == k }.flatMap { layout.side(of: $0.id) }
                HStack(spacing: 9) {
                    Image(systemName: k.symbol).font(.system(size: 11)).foregroundStyle(Theme.text2)
                        .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 6).fill(Color.white(0.05)))
                    Text(k.title).font(Typo.row).foregroundStyle(Theme.text)
                    Text(k.toggleShortcut ?? "").font(Typo.ui(10.5)).foregroundStyle(Theme.meta)
                    Spacer()
                    SegmentedControl(options: [("left", "Left"), ("right", "Right"), ("bottom", "Bottom"), ("hidden", "Hidden")],
                                     selection: Binding(get: { current?.rawValue ?? "hidden" }, set: { v in setSide(k, v) }),
                                     fill: Theme.input)
                        .frame(width: 260, alignment: .leading)
                }
                .padding(.horizontal, 12).frame(height: 40)
                .hairlineBottom(Color.white(0.05))
            }
            HStack(spacing: 10) {
                Text("Centre").font(Typo.row).foregroundStyle(Theme.text)
                Spacer()
                SegmentedControl(options: CentreMode.allCases.map { ($0, $0.label) }, selection: Binding(get: { layout.centre }, set: { store.library.defaultLayout.centre = $0; store.library.defaultLayout.presetName = nil }), fill: Theme.input)
            }
            .padding(.horizontal, 12).frame(height: 40)
        }
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func setSide(_ k: PanelKind, _ v: String) {
        var l = store.library.defaultLayout
        if let side = DockSide(rawValue: v) {
            if let p = l.allPanels.first(where: { $0.kind == k }) { l.move(p.id, to: side) } else { l.add(k, to: side) }
        } else if let p = l.allPanels.first(where: { $0.kind == k }) {
            l.hide(p.id)
        }
        store.library.defaultLayout = l
    }

    private var customPresets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your layouts").font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3)
            ForEach(store.library.customPresets) { p in
                HStack(spacing: 8) {
                    if renaming == p.id {
                        TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 220)
                            .onSubmit { rename(p.id) }
                        SubtleButton(title: "Save", height: 24) { rename(p.id) }
                    } else {
                        Image(systemName: "rectangle.3.group").font(.system(size: 11)).foregroundStyle(Theme.text2)
                        Text(p.name).font(Typo.row).foregroundStyle(Theme.text)
                        Text("\(p.layout.allPanels.count) panels · \(p.layout.centre.label)").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    SubtleButton(title: "Use as default", height: 24) { var l = p.layout; l.presetName = p.id; store.library.defaultLayout = l }
                        .disabled(layout.presetName == p.id)
                    IconButton(symbol: "pencil", label: "Rename \(p.name)", iconSize: 11) { renaming = p.id; newName = p.name }
                    IconButton(symbol: "trash", label: "Delete \(p.name)", iconSize: 11) {
                        store.confirm("Delete preset “\(p.name)”?", "Projects using it keep their current layout.", confirm: "Delete") {
                            store.library.customPresets.removeAll { $0.id == p.id }
                        }
                    }
                }
                .padding(.horizontal, 10).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.editor))
            }
        }
    }

    private func rename(_ id: String) {
        let n = newName.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, let i = store.library.customPresets.firstIndex(where: { $0.id == id }) { store.library.customPresets[i].name = n }
        renaming = nil
    }
}

/// Miniature dock preview.
struct LayoutPreview: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let layout: DockLayout

    var body: some View {
        let s = store.settings
        let g = s.spacing.gap
        let r: CGFloat = s.spacing == .seamless ? 2 : 6
        HStack(spacing: g) {
            if s.sidebarPosition == .left { sidebar(s, r) }
            HStack(spacing: g) {
                if !layout.left.isEmpty { dock(layout.left, vertical: true, r: r).frame(width: 118) }
                VStack(spacing: g) {
                    VStack(spacing: 2) {
                        Text(layout.centre.label).font(Typo.ui(11, .semibold)).foregroundStyle(Theme.body)
                        Text("Centre").font(Typo.ui(10)).foregroundStyle(Theme.text3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: r).fill(Theme.editor))
                    .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(accent.opacity(0.33)))
                    if !layout.bottom.isEmpty { dock(layout.bottom, vertical: false, r: r).frame(height: 74) }
                }
                if !layout.right.isEmpty { dock(layout.right, vertical: true, r: r).frame(width: 118) }
            }
            if s.sidebarPosition == .right { sidebar(s, r) }
        }
        .padding(g)
        .frame(height: 300)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.controlStroke))
        .animation(.easeOut(duration: 0.2), value: layout)
        .animation(.easeOut(duration: 0.2), value: s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Layout preview: \(layout.left.map(\.displayTitle).joined(separator: ", ")) left, \(layout.right.map(\.displayTitle).joined(separator: ", ")) right, \(layout.bottom.map(\.displayTitle).joined(separator: ", ")) bottom")
    }

    private func sidebar(_ s: AppSettings, _ r: CGFloat) -> some View {
        Text(s.sidebarStyle == .rail ? "Rail" : "Sidebar")
            .font(Typo.ui(9.5, .semibold)).foregroundStyle(Theme.text3)
            .rotationEffect(s.sidebarStyle == .rail ? .degrees(-90) : .zero)
            .fixedSize()
            .frame(width: s.sidebarStyle == .rail ? 22 : 70)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: r).fill(Theme.island))
            .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(Theme.controlStroke))
    }

    private func dock(_ panels: [PanelInstance], vertical: Bool, r: CGFloat) -> some View {
        let g = store.settings.spacing.gap
        let layout = vertical ? AnyLayout(VStackLayout(spacing: g)) : AnyLayout(HStackLayout(spacing: g))
        return layout {
            ForEach(panels) { p in
                Text(p.displayTitle).font(Typo.ui(10.5, .semibold)).foregroundStyle(Theme.body).multilineTextAlignment(.center).padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: r).fill(Theme.island))
                    .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(Theme.controlStroke))
            }
        }
    }
}

private struct AppearanceSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack {
                Text("Appearance").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 44).hairlineBottom()
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Accent").font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text)
                        HStack(spacing: 10) {
                            ForEach(AccentChoice.allCases) { a in
                                Button { store.settings.accent = a } label: {
                                    Circle().fill(a.color).frame(width: 26, height: 26)
                                        .overlay(Circle().strokeBorder(a.color, lineWidth: 2).padding(-4).opacity(store.settings.accent == a ? 1 : 0))
                                        .padding(4)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(a.label)
                                .accessibilityAddTraits(store.settings.accent == a ? .isSelected : [])
                            }
                        }
                        Text("Used for primary actions, focus and live indicators only.").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).hairlineBottom()
                    segment("Theme", "Dark, light, or follow macOS", AppearanceMode.allCases.map { ($0, $0.label) }, $store.settings.appearance)
                    codeFontRow
                    segment("Panel spacing", "How far apart the islands float", IslandSpacing.allCases.map { ($0, $0.label) }, $store.settings.spacing)
                    segment("Density", "Row height and text size", Density.allCases.map { ($0, $0.label) }, $store.settings.density)
                    segment("Sidebar position", "Put navigation on either edge", SidebarPosition.allCases.map { ($0, $0.label) }, $store.settings.sidebarPosition)
                    segment("Sidebar style", "Full labels or a slim icon rail", SidebarStyle.allCases.map { ($0, $0.label) }, $store.settings.sidebarStyle)
                    Toggle(isOn: $store.settings.showToolStrips) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tool window bars").font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text)
                            Text("Icon strips on the workspace edges to show or hide panels").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                        }
                    }
                    .toggleStyle(.bx).padding(.horizontal, 16).padding(.vertical, 14).hairlineBottom()
                    terminalFont
                    notifications
                }
            }
            HStack {
                Text("Changes apply instantly and are saved on this Mac").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                Spacer()
                KeyCap(text: "⌘,")
            }
            .padding(.horizontal, 16).frame(height: 36).hairlineTop()
        }
        .island()
    }

    /// Label and control side by side, or stacked when a wide font doesn't fit.
    private func segment<T: Hashable>(_ title: String, _ sub: String, _ options: [(T, String)], _ binding: Binding<T>) -> some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text)
            Text(sub).font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
        }
        let control = SegmentedControl(options: options, selection: binding, fill: Theme.input).fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                label.fixedSize()
                Spacer(minLength: 8)
                control
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                control
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .hairlineBottom()
    }

    @ViewBuilder private var codeFontRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Code font").font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text)
                Text("Editor, terminals and SQL").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
            }
            Spacer()
            Picker("Code font", selection: Bindable(store).settings.codeFont) {
                Text("SF Mono").tag("")
                ForEach(NSFont.monospacedFamilies.filter { $0 != "SF Mono" }, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 170)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .hairlineBottom()
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Interface font").font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text)
                Text("Text across the app").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
            }
            Spacer()
            Picker("Interface font", selection: Bindable(store).settings.uiFont) {
                ForEach(UIFontChoice.available) { Text($0.label).font(.custom($0.family ?? "", size: 13)).tag($0) }
            }
            .labelsHidden().frame(width: 170)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .hairlineBottom()
    }

    private var terminalFont: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Terminal font").font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text)
                    Text("\(store.settings.codeFont.ifEmpty("SF Mono")) · size").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                }
                Spacer()
                HStack(spacing: 0) {
                    IconButton(symbol: "minus", label: "Smaller", size: 26, iconSize: 10) { store.settings.terminalFontSize = max(10, store.settings.terminalFontSize - 1) }
                    Text("\(Int(store.settings.terminalFontSize)) pt").font(Typo.ui(12)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 44)
                    IconButton(symbol: "plus", label: "Larger", size: 26, iconSize: 10) { store.settings.terminalFontSize = min(16, store.settings.terminalFontSize + 1) }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.divider))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(MockData.promptLine(project: "atlas-web", branch: "feat/checkout-v2").appending(MockData.span("claude", Theme.text)).attributed)
                Text(TermLine([MockData.span("✻ ", Theme.violet), MockData.span("Claude Code", Theme.text, bold: true), MockData.span(" ready", Theme.text3)]).attributed)
            }
            .font(.system(size: store.settings.terminalFontSize, design: .monospaced))
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.terminal))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
        .padding(16).hairlineBottom()
    }

    private var notifications: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 12) {
            Text("Notifications").font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text)
            Toggle("When an agent session finishes", isOn: $store.settings.notifyFinished).toggleStyle(.bx)
            Toggle("When a session needs input", isOn: $store.settings.notifyNeedsInput).toggleStyle(.bx)
            Toggle("Badge the Dock icon with sessions waiting", isOn: $store.settings.badgeDock).toggleStyle(.bx)
            Toggle("Play a sound", isOn: $store.settings.notifySound).toggleStyle(.bx)
            Text("Agents").font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text).padding(.top, 6)
            Toggle("Show a message box under agent sessions", isOn: $store.settings.agentComposer).toggleStyle(.bx)
        }
        .font(Typo.ui(12.5)).foregroundStyle(Theme.body)
        .padding(16)
    }
}

/// Services Brix reads through the user's own sign-ins. Today: GitHub, via the gh CLI.
struct AccountsSettings: View {
    @Environment(AppStore.self) private var store
    @State private var login: String?
    @State private var others: [String] = []
    @State private var state = "checking"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text).frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white(0.06)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GitHub").font(Typo.ui(14, .semibold)).foregroundStyle(Theme.text)
                        Text(status).font(Typo.ui(12)).foregroundStyle(state == "signed-in" ? Theme.green : Theme.text3)
                    }
                    Spacer()
                    switch state {
                    case "missing": AccentButton(title: "Install GitHub CLI") { terminal("brew install gh && gh auth login") }
                    case "signed-out": AccentButton(title: "Sign In…") { terminal("gh auth login") }
                    case "error":
                        SubtleButton(title: "Check Again") { Task { await check() } }
                    case "signed-in":
                        SubtleButton(title: "Add Account…") { terminal("gh auth login") }
                        SubtleButton(title: "Check Again") { Task { await check() } }
                        SubtleButton(title: "Sign Out…") { terminal("gh auth logout") }
                    default: ProgressView().controlSize(.small)
                    }
                }
                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Also signed in").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                        ForEach(others, id: \.self) { a in
                            HStack(spacing: 8) {
                                Circle().fill(Theme.green).frame(width: 6, height: 6)
                                Text(a).font(Typo.mono(12)).foregroundStyle(Theme.text)
                                let used = store.library.projects.filter { ($0.githubAccount ?? $0.githubAccountSeen) == a }.map(\.name)
                                if !used.isEmpty { Text("used by " + used.prefix(3).joined(separator: ", ")).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1) }
                            }
                        }
                    }
                }
                Text("With several accounts, each project uses the one that can see its repo: Brix tries them in turn and remembers the match, or you pick one in Project Settings → General.")
                    .font(Typo.ui(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                Text("Brix shows each project's pull requests and pipelines on its overview. It uses the GitHub CLI (gh) and your sign-in there, only reads, and stores no token of its own. Each project's repository comes from its git remote, or set one in Project Settings → General.")
                    .font(Typo.ui(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .padding(16)
        }
        .task { await check() }
    }

    private var status: String {
        switch state {
        case "missing": "GitHub CLI (gh) isn't installed"
        case "signed-out": "Not signed in"
        case "signed-in": login.map { "Signed in as \($0) (active)" } ?? "Signed in"
        case "error": "Couldn't check: gh didn't answer"
        default: "Checking…"
        }
    }

    private func check() async {
        guard GitHub.installed else { state = "missing"; return }
        state = "checking"
        do {
            let all = try await GitHub.accounts()
            guard let active = all.first else { state = "signed-out"; return }
            login = active
            others = Array(all.dropFirst())
            state = "signed-in"
        } catch {
            state = "error"
        }
    }

    private func terminal(_ cmd: String) {
        let s = store.newTerminal(project: nil, title: "GitHub", command: cmd + "; exec \"$SHELL\" -l", attach: false)
        store.route = .terminals
        store.focusedSessionID = s.id
    }
}
