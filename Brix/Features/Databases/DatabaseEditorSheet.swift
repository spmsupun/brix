import SwiftUI
import AppKit

/// New / Edit database connection: Quick start on the left (paste anything,
/// databases found nearby), the form on the right, live-tested as you type.
struct DatabaseEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    let existing: DatabaseConnection?

    // Form
    @State private var name = ""
    @State private var nameEdited = false
    @State private var flavor: DBFlavor = .postgres
    @State private var route: DBRoute = .direct
    @State private var host = "localhost"
    @State private var port = "5432"
    @State private var database = ""
    @State private var user = ""
    @State private var password = ""
    @State private var filePath = ""
    @State private var ssl: SSLMode = .prefer
    @State private var tunnel: ResourceID?
    @State private var container: String?
    @State private var tag: EnvTag = .dev
    @State private var access: AgentDBAccess = .read
    @State private var projects: Set<ProjectID> = []
    @State private var fromEnv: Set<ProjectID> = []
    @State private var advanced = false
    @State private var timeout = ""
    @State private var queryTimeout = ""
    @State private var colour: ProjectHue?
    @State private var startupSQL = ""
    @State private var notes = ""
    @State private var errors: [String: String] = [:]
    @State private var loaded = false
    /// One id for the whole sheet, so live tests reuse one pooled session.
    @State private var draftID = UUID().uuidString

    // Quick start
    @State private var pasted = ""
    @State private var detected: [String] = []
    @State private var pasteNote: String?
    @State private var found: [DBCandidate] = []
    @State private var scanning = false
    @State private var scannedAt: Date?
    @State private var using: String?
    /// Saved servers are only checked when asked: it means connecting to each one.
    @State private var serverScanDone = false

    // Live test
    enum Live: Equatable { case idle, testing, ok(String), failed(String) }
    @State private var live: Live = .idle
    @State private var databases: [String] = []
    @State private var showDetails = false
    /// The saved password, read from the Keychain once.
    @State private var storedPassword: String?

    private var kind: DBKind { flavor.kind }
    private var pastedOK: Bool { !pasted.isEmpty && !detected.isEmpty && using == nil }
    private var hasStoredPassword: Bool { existing.map { store.keychain.has(Keychain.dbAccount($0.id)) } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                quickStart.frame(width: 330)
                Rectangle().fill(Color.white(0.07)).frame(width: 1)
                ScrollView { form.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18) }
            }
            footer
        }
        .frame(width: 1010, height: min(836, (NSScreen.main?.visibleFrame.height ?? 900) - 60))
        .background(Color.dyn(0x161618, 0xFAFAFB))
        .onAppear(perform: load)
        .task { await scan() }
        // Auto-test 600 ms after the last edit.
        .task(id: testKey) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await test()
        }
        .onChange(of: flavor) { old, new in
            if port == "\(old.defaultPort)" || port.isEmpty { port = "\(new.defaultPort)" }
            if ssl == old.defaultSSL { ssl = new.defaultSSL }
            if new == .sqlite, tag == .dev { tag = .local }
            suggestName()
        }
        .onChange(of: tag) { _, t in
            if t.isProduction, access == .write { access = .read }
        }
        .onChange(of: database) { _, _ in suggestName() }
        .onChange(of: host) { _, _ in suggestName() }
    }

    // MARK: Quick start

    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quick start").font(Typo.ui(15, .bold)).foregroundStyle(Theme.text)
                Text("Paste anything, or pick something Brix found. We’ll fill the form for you.")
                    .font(Typo.ui(12)).foregroundStyle(Theme.text3).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("PASTE ANYTHING")
                ZStack(alignment: .topLeading) {
                    TextEditor(text: Binding(get: { pasted }, set: { onPaste($0) }))
                        .font(Typo.mono(11.5)).foregroundStyle(Theme.text)
                        .scrollContentBackground(.hidden)
                        .frame(height: 74)
                        .accessibilityLabel("Paste a connection")
                    if pasted.isEmpty {
                        Text("DATABASE_URL=postgres://…").font(Typo.mono(11.5)).foregroundStyle(Theme.meta)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.input))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(pastedOK ? accent : Color.white(0.09)))
                .background(RoundedRectangle(cornerRadius: 13).fill(pastedOK ? accent.opacity(0.15) : .clear).padding(-3))
                Text(pasteNote ?? "URL, .env line, psql / mysql command or docker-compose service")
                    .font(Typo.ui(11)).foregroundStyle(pasteNote == nil ? Theme.text3 : Theme.amber)
                FlowLayout(spacing: 5) {
                    ForEach(detected, id: \.self) { d in
                        Text("✓ \(d)").font(Typo.ui(11)).foregroundStyle(Color(hex: 0x86EFAC))
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.green.opacity(0.10)))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SectionLabel("FOUND NEARBY")
                    Spacer()
                    Button { Task { await scan() } } label: {
                        Text(scanning ? "scanning…" : scannedAt.map { "scanned \(RelativeTime.short($0)) ↻" } ?? "scan ↻")
                            .font(Typo.ui(11)).foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(.plain).disabled(scanning)
                    .accessibilityLabel("Scan again")
                }
                ScrollView {
                    VStack(spacing: 6) {
                        if found.isEmpty && !scanning {
                            Text("Nothing found in your projects, Docker or on this Mac.").font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }
                        ForEach(found) { candidateRow($0) }
                        serverScanRow
                    }
                }
                .scrollIndicators(.never)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 18).padding(.vertical, 22)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.dyn(0x111113, 0xF1F1F3))
    }

    private func candidateRow(_ c: DBCandidate) -> some View {
        let on = using == c.id
        return Button { Task { await use(c) } } label: {
            HStack(spacing: 10) {
                LetterBadge(text: badge(for: c), color: color(for: c), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name).font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(c.sub).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(on ? "Using" : "Use").font(Typo.ui(11.5, .semibold)).foregroundStyle(on ? Theme.onAccent : Theme.text)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? accent : Color.white(0.07)))
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? accent.opacity(0.08) : Color.white(0.025)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? accent.opacity(0.35) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(c.sub)
        .accessibilityLabel("\(c.name), \(c.sub)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var serverScanRow: some View {
        let hosts = store.library.hosts.filter { !$0.isSample && !$0.tag.isProduction }
        if !hosts.isEmpty && !serverScanDone {
            Button {
                store.confirm("Check your saved servers?", "Brix connects to each of your \(hosts.count) non-production servers over SSH and lists the database ports they listen on (5432, 3306). Nothing is changed.", confirm: "Check", destructive: false) {
                    Task { await scanServers(hosts) }
                }
            } label: {
                HStack(spacing: 10) {
                    LetterBadge(text: "SSH", color: Theme.blue, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Databases on your servers").font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                        Text("Check \(hosts.count) saved servers for 5432 / 3306").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Check").font(Typo.ui(11.5, .semibold)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 9).frame(height: 24).background(RoundedRectangle(cornerRadius: 7).fill(Color.white(0.07)))
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                // The title keeps its width; a long status shortens instead of squeezing it.
                VStack(alignment: .leading, spacing: 4) {
                    Text(existing == nil ? "New database connection" : "Edit connection").font(Typo.ui(17, .bold)).foregroundStyle(Theme.text)
                        .fixedSize()
                    Text("Passwords go to your Keychain. Brix never shows them to agents.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minWidth: 260, alignment: .leading)
                .layoutPriority(1)
                Spacer(minLength: 8)
                statusPill
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("ENGINE")
                FlowLayout(spacing: 6) {
                    ForEach(Self.primary, id: \.self) { engineChip($0) }
                    moreEngines
                }
            }
            if kind != .sqlite {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("HOW TO REACH IT")
                    HStack(spacing: 10) {
                        SegmentedControl(options: DBRoute.allCases.map { ($0, $0.label) }, selection: $route, height: 28, fill: Theme.input, fontSize: 12)
                            .fixedSize()
                        routePicker
                        Text(routeHint).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                }
            }
            fields
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("ENVIRONMENT")
                HStack(spacing: 6) {
                    ForEach(EnvTag.allCases) { envChip($0) }
                }
                Text(envNote).font(Typo.ui(11.5)).foregroundStyle(tag.isProduction ? Color(hex: 0xFCA5A5) : Theme.text3)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SectionLabel("WHAT AGENTS CAN DO")
                    Text("NEW").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(hex: 0xC4B5FD))
                        .padding(.horizontal, 6).padding(.vertical, 1).background(RoundedRectangle(cornerRadius: 4).fill(Theme.violet.opacity(0.14)))
                }
                HStack(alignment: .top, spacing: 6) {
                    ForEach(AgentDBAccess.allCases) { accessCard($0) }
                }
            }
            if !store.sortedProjects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("USE IN PROJECTS")
                    FlowLayout(spacing: 6) {
                        ForEach(store.sortedProjects) { projectChip($0) }
                    }
                }
            }
            advancedSection
        }
    }

    private static let primary: [DBFlavor] = [.postgres, .mysql, .mariadb, .sqlite, .supabase, .neon]

    static func letters(_ f: DBFlavor) -> String {
        switch f {
        case .postgres: "PG"
        case .mysql: "MY"
        case .mariadb: "MA"
        case .sqlite: "SQ"
        case .supabase: "SB"
        case .neon: "NE"
        case .cockroach: "CR"
        case .timescale: "TS"
        case .redshift: "RS"
        case .tidb: "TI"
        case .planetscale: "PS"
        }
    }

    static func color(_ f: DBFlavor) -> Color {
        switch f {
        case .postgres: Color(hex: 0x93B4FF)
        case .mysql: Color(hex: 0xFB923C)
        case .mariadb: Color(hex: 0xFBBF24)
        case .sqlite: Color(hex: 0x22D3EE)
        case .supabase: Color(hex: 0x4ADE80)
        case .neon: Color(hex: 0x34D399)
        default: f.color
        }
    }

    private func engineChip(_ f: DBFlavor) -> some View {
        let on = f == flavor
        let c = Self.color(f)
        return Button { flavor = f } label: {
            HStack(spacing: 8) {
                LetterBadge(text: Self.letters(f), color: c, size: 22)
                Text(f.label).font(Typo.ui(12.5, on ? .semibold : .medium)).foregroundStyle(on ? Theme.text : Theme.body)
            }
            .padding(.leading, 7).padding(.trailing, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? c.opacity(0.10) : Color.white(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? c.opacity(0.55) : Color.white(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var moreEngines: some View {
        let more = DBFlavor.allCases.filter { !Self.primary.contains($0) }
        let picked = more.contains(flavor)
        return MenuButton(items: { more.map { f in MenuSpec(title: f.label, checked: f == flavor) { flavor = f } } }) {
            HStack(spacing: 8) {
                if picked {
                    LetterBadge(text: Self.letters(flavor), color: Self.color(flavor), size: 22)
                    Text(flavor.label).font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                }
                Text(picked ? "▾" : "More · \(more.count) ▾").font(Typo.ui(12.5)).foregroundStyle(Theme.text2)
            }
            .padding(.leading, picked ? 7 : 12).padding(.trailing, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(picked ? Self.color(flavor).opacity(0.10) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(picked ? Self.color(flavor).opacity(0.55) : Color.white(0.14),
                                                                    style: StrokeStyle(lineWidth: 1, dash: picked ? [] : [3, 3])))
            .contentShape(Rectangle())
        }
        .accessibilityLabel("More engines")
    }

    @ViewBuilder private var routePicker: some View {
        switch route {
        case .ssh:
            Picker("", selection: $tunnel) {
                Text("Choose a server").tag(ResourceID?.none)
                ForEach(store.library.hosts) { h in Text(h.name).tag(ResourceID?.some(h.id)) }
            }
            .labelsHidden().frame(width: 170).accessibilityLabel("SSH server")
        case .docker:
            Picker("", selection: Binding(get: { container }, set: { pickContainer($0) })) {
                Text(dockerChoices.isEmpty ? "No database containers" : "Choose a container").tag(String?.none)
                ForEach(dockerChoices) { c in Text(c.dockerContainer ?? c.name).tag(c.dockerContainer) }
            }
            .labelsHidden().frame(width: 170).accessibilityLabel("Docker container")
        case .direct:
            EmptyView()
        }
    }

    private var dockerChoices: [DBCandidate] { found.filter { $0.source == .docker } }

    private var routeHint: String {
        switch route {
        case .direct:
            return "Connects straight to \(host.isEmpty ? "the host" : host):\(port)"
        case .ssh:
            return tunnel.flatMap(store.host).map { "Through \($0.name); Brix picks a local port" } ?? "Pick a saved server to tunnel through"
        case .docker:
            guard let c = dockerChoices.first(where: { $0.dockerContainer == container }) else { return "Pick a running container" }
            return c.port.map { "Published on localhost:\($0)" } ?? "No published port; publish \(flavor.defaultPort) to connect"
        }
    }

    private func pickContainer(_ name: String?) {
        container = name
        guard let c = dockerChoices.first(where: { $0.dockerContainer == name }) else { return }
        Task { await use(c) }
    }

    private var fields: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
            if kind == .sqlite {
                GridRow {
                    BXTextField(label: "Name", text: nameBinding, placeholder: "analytics", error: errors["name"]).gridCellColumns(6)
                }
                GridRow {
                    HStack(alignment: .bottom, spacing: 8) {
                        BXTextField(label: "Database file", text: $filePath, placeholder: "~/data/app.sqlite", mono: true, error: errors["file"])
                        SubtleButton(title: "Choose…", height: 32) { chooseFile() }
                    }
                    .gridCellColumns(6)
                }
            } else {
                GridRow {
                    BXTextField(label: "Name", text: nameBinding, placeholder: "atlas_dev", error: errors["name"]).gridCellColumns(3)
                    databaseField.gridCellColumns(3)
                }
                GridRow {
                    BXTextField(label: "Host", text: $host, placeholder: flavor.hostHint, mono: true, error: errors["host"]).gridCellColumns(3)
                    BXTextField(label: "Port", text: $port, mono: true, error: errors["port"]).gridCellColumns(1)
                    BXTextField(label: "User", text: $user, mono: true, error: errors["user"]).gridCellColumns(2)
                }
                GridRow {
                    passwordField.gridCellColumns(6)
                }
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(get: { name }, set: { name = $0; nameEdited = true })
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
            HStack(spacing: 8) {
                SecureField(hasStoredPassword ? "Stored in Keychain · type to replace" : "Optional", text: $password)
                    .textFieldStyle(.plain).font(Typo.ui(12.5)).foregroundStyle(Theme.text)
                if hasStoredPassword || !password.isEmpty {
                    Label(password.isEmpty ? "Saved to Keychain" : "Goes to Keychain", systemImage: "lock.fill")
                        .font(Typo.ui(11)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 11).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white(0.09)))
        }
    }

    /// The database, with a menu of the ones found after connecting.
    private var databaseField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind == .mysql ? "Database" : "Database (optional)").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
            HStack(spacing: 6) {
                TextField("", text: $database).textFieldStyle(.plain).font(Typo.mono(12)).foregroundStyle(Theme.text)
                    .accessibilityLabel("Database")
                if !databases.isEmpty {
                    MenuButton(items: { databases.map { d in MenuSpec(title: d, checked: d == database) { database = d } } }) {
                        Text("\(databases.count) found ▾").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                    }
                }
            }
            .padding(.horizontal, 11).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(errors["database"] == nil ? Color.white(0.09) : Theme.red))
            if let e = errors["database"] { Text(e).font(Typo.ui(11)).foregroundStyle(Theme.red) }
        }
    }

    private func envChip(_ t: EnvTag) -> some View {
        let on = t == tag
        let c = Self.envColor(t)
        return Button { tag = t } label: {
            HStack(spacing: 7) {
                Circle().fill(c).frame(width: 7, height: 7)
                Text(t.name).font(Typo.ui(12.5, .semibold)).foregroundStyle(on ? Theme.text : Theme.text2)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? c.opacity(0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? c.opacity(0.5) : Color.white(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    static func envColor(_ t: EnvTag) -> Color {
        switch t {
        case .prod: Color(hex: 0xF87171)
        case .stage: Color(hex: 0xFBBF24)
        case .dev: Color(hex: 0x60A5FA)
        case .personal: Color(hex: 0xA78BFA)
        case .local: Color(hex: 0x22D3EE)
        }
    }

    private var envNote: String {
        switch tag {
        case .prod: "Production is read-only. The Databases screen never writes to it; the quick query panel needs the database name typed."
        case .stage: "Staging: writes allowed. Turn on read-only in the connection to have them confirmed."
        case .dev: "Development: writes allowed."
        case .personal: "Personal: yours alone; writes allowed."
        case .local: "Local: on this Mac; writes allowed."
        }
    }

    private func accessCard(_ a: AgentDBAccess) -> some View {
        let disabled = tag.isProduction && a == .write
        let on = access == a
        return Button { access = a } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(a.label).font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                Text(disabled ? "Not allowed on Production" : a.detail).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineSpacing(1.5)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 11).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.violet.opacity(0.10) : Color.white(0.025)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Theme.violet.opacity(0.5) : Color.white(0.08)))
            .opacity(disabled ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func projectChip(_ p: Project) -> some View {
        let on = projects.contains(p.id)
        return Button { if on { projects.remove(p.id) } else { projects.insert(p.id) } } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2).fill(p.hue.color).frame(width: 7, height: 7)
                Text(p.name).font(Typo.ui(12.5, .medium)).foregroundStyle(on ? Theme.text : Theme.text2)
                if fromEnv.contains(p.id) { Text("from .env").font(Typo.ui(10.5)).foregroundStyle(Color(hex: 0x86EFAC)) }
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(on ? Color.white(0.09) : .clear))
            .overlay(Capsule().strokeBorder(on ? Color.white(0.18) : Color.white(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.easeOut(duration: 0.15)) { advanced.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(advanced ? "▾ Advanced" : "▸ Advanced").font(Typo.ui(12, .semibold)).foregroundStyle(Theme.text2)
                    Text("SSL · timeouts · colour · startup SQL").font(Typo.ui(12)).foregroundStyle(Theme.meta)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if advanced {
                VStack(alignment: .leading, spacing: 12) {
                    if kind != .sqlite {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SSL").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                            SegmentedControl(options: SSLMode.allCases.map { ($0, $0.rawValue.capitalized) }, selection: $ssl, height: 24, fill: Theme.input).fixedSize()
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        BXTextField(label: kind == .sqlite ? "Wait when locked (s)" : "Connect timeout (s)", text: $timeout, placeholder: kind == .sqlite ? "5" : "10", mono: true, error: errors["timeout"])
                        if kind != .sqlite {
                            BXTextField(label: "Query timeout (s)", text: $queryTimeout, placeholder: "none", mono: true, error: errors["queryTimeout"])
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Colour").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                        HStack(spacing: 10) {
                            HuePicker(selection: Binding(get: { colour ?? .blue }, set: { colour = $0 }))
                            if colour != nil {
                                Button("Use environment colour") { colour = nil }.buttonStyle(.plain).font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                            }
                        }
                    }
                    if kind != .sqlite {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Startup SQL").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                            TextEditor(text: $startupSQL).font(Typo.mono(12)).scrollContentBackground(.hidden).frame(height: 54)
                                .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white(0.09)))
                                .accessibilityLabel("Startup SQL")
                            Text(kind == .postgres ? "Runs after connecting, e.g. SET search_path TO app, public;" : "Runs after connecting, e.g. SET time_zone = '+00:00';")
                                .font(Typo.ui(11)).foregroundStyle(Theme.text3)
                        }
                    }
                    BXTextField(label: "Notes", text: $notes, placeholder: "What this database is for")
                }
            }
        }
    }

    // MARK: Live status

    private var testKey: String {
        [flavor.rawValue, route.rawValue, host, port, database, user, password, filePath, ssl.rawValue, tunnel ?? "", timeout].joined(separator: "|")
    }

    @ViewBuilder private var statusPill: some View {
        switch live {
        case .idle:
            EmptyView()
        case .testing:
            pill(color: Theme.amber, text: "Testing…", live: false)
        case .ok(let text):
            pill(color: Theme.green, text: text, live: true)
        case .failed(let why):
            Button { showDetails.toggle() } label: { pill(color: Theme.red, text: "Can’t connect · Details", live: false) }
                .buttonStyle(.plain)
                .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                    Text(why).font(Typo.mono(11.5)).foregroundStyle(Theme.text).textSelection(.enabled)
                        .frame(maxWidth: 360, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(12)
                }
        }
    }

    private func pill(color: Color, text: String, live: Bool) -> some View {
        HStack(spacing: 7) {
            if live { LiveDot(color: color, size: 7, ring: 5) } else { Circle().fill(color).frame(width: 7, height: 7) }
            Text(text).font(Typo.ui(11.5, .medium)).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
        }
        .help(text)
        .padding(.horizontal, 11).frame(height: 28)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().strokeBorder(color.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }

    private func test() async {
        // The auto-test never runs unsaved startup SQL against the server.
        guard var d = build(validate: false) else { live = .idle; return }
        d.startupSQL = ""
        if d.kind == .sqlite ? d.filePath.isEmpty : (d.host.isEmpty || d.user.isEmpty) { live = .idle; return }
        if route == .ssh, d.tunnelHostID == nil { live = .idle; return }
        live = .testing
        let pw = password.isEmpty ? storedPassword : password
        let result = await store.testDatabase(d, password: pw)
        guard !Task.isCancelled else { live = .idle; return }
        switch result {
        case .success(let t):
            async let tables = store.tableCount(d, password: pw)
            async let dbs = store.listDatabases(d, password: pw)
            let (n, list) = await (tables, dbs)
            guard !Task.isCancelled else { return }
            databases = list
            live = .ok(["Connected", Self.shortVersion(t.version), "\(Int(t.latencyMs)) ms", n.map { "\($0) tables" }].compactMap { $0 }.joined(separator: " · "))
        case .failure(let e):
            live = .failed(e.message)
        }
    }

    /// "PostgreSQL 17.6 (Debian 17.6-1.pgdg…) on x86_64…" to "PostgreSQL 17.6";
    /// "MySQL 10.11.7-MariaDB-1:10.11.7+maria~ubu2204" to "MariaDB 10.11.7".
    static func shortVersion(_ v: String) -> String {
        let cut = v.components(separatedBy: CharacterSet(charactersIn: "(,")).first ?? v
        let words = cut.split(separator: " ").prefix(2).map(String.init)
        guard words.count == 2 else { return words.joined(separator: " ") }
        let number = words[1].split(separator: "-").first.map(String.init) ?? words[1]
        return (v.contains("MariaDB") ? "MariaDB" : words[0]) + " " + number
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(maskedURL).font(Typo.mono(11.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel") { dismiss() }.buttonStyle(.plain).font(Typo.ui(13)).foregroundStyle(Theme.text2).padding(.horizontal, 12)
                .keyboardShortcut(.cancelAction)
            Button { save(open: false) } label: {
                Text("Save").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text).padding(.horizontal, 14).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white(0.10)))
            }
            .buttonStyle(.plain)
            Button { save(open: true) } label: {
                Text("Save & open tables ↩").font(Typo.ui(13, .bold)).foregroundStyle(Theme.onAccent).padding(.horizontal, 16).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(accent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20).frame(height: 60)
        .background(Color.white(0.02)).hairlineTop()
    }

    private var maskedURL: String {
        if kind == .sqlite { return filePath.isEmpty ? "" : "sqlite:" + filePath }
        let scheme = kind == .mysql ? (flavor == .mariadb ? "mariadb" : "mysql") : "postgres"
        let auth = user.isEmpty ? "" : user + ((password.isEmpty && !hasStoredPassword) ? "" : ":••••") + "@"
        return "\(scheme)://\(auth)\(host):\(port)/\(database)"
    }

    // MARK: Quick start actions

    /// A pasted password never stays on screen: it moves to the password
    /// field (and the Keychain on save) and the paste box shows it masked.
    private func onPaste(_ text: String) {
        guard let c = DBPaste.parse(text) else {
            pasted = text
            detected = []
            pasteNote = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "Couldn't read a connection from that"
            return
        }
        pasteNote = nil
        using = nil
        apply(c)
        pasted = DBPaste.masked(text, password: c.password)
        detected = c.detected
    }

    private func use(_ found: DBCandidate) async {
        using = found.id
        let c = found.source == .docker ? await DBDiscovery.dockerCredentials(found) : found
        guard using == found.id else { return }
        apply(c)
        using = c.id
        detected = c.detected
        switch c.source {
        case .docker: route = .docker; container = c.dockerContainer
        case .ssh: route = .ssh; tunnel = c.sshHostID
        default: route = .direct
        }
        fromEnv = Set(c.projects)
        projects.formUnion(c.projects)
    }

    private func apply(_ c: DBCandidate) {
        flavor = c.flavor
        if c.flavor == .sqlite {
            filePath = (c.filePath as NSString).abbreviatingWithTildeInPath
        } else {
            host = c.host.isEmpty ? "localhost" : c.host
            port = "\(c.port ?? c.flavor.defaultPort)"
            if !c.database.isEmpty { database = c.database }
            if !c.user.isEmpty { user = c.user }
            if !c.password.isEmpty { password = c.password }
            if let s = c.ssl { ssl = s }
        }
        if existing == nil, !nameEdited || name.isEmpty { nameEdited = false; suggestName() }
    }

    private func suggestName() {
        guard !nameEdited, existing == nil else { return }
        if kind == .sqlite {
            name = ((filePath as NSString).lastPathComponent as NSString).deletingPathExtension
        } else {
            let short = host.components(separatedBy: ".").first ?? host
            let local = host == "localhost" || host == "127.0.0.1"
            name = database.isEmpty ? short : database + (local ? "" : "@" + short)
        }
    }

    private func scan() async {
        scanning = true
        found = await DBDiscovery.scan(projects: store.library.projects)
        scannedAt = Date()
        scanning = false
        if let pick = DebugSnapshot.directory.flatMap({ _ in ProcessInfo.processInfo.environment["BRIX_SNAPSHOT_USE"] }),
           let c = found.first(where: { $0.dockerContainer == pick }) { await use(c) }
    }

    private func scanServers(_ hosts: [SSHHost]) async {
        scanning = true
        for h in hosts {
            for p in await DBDiscovery.serverPorts(h, password: store.hostPassword(h)) {
                let f: DBFlavor = p == 3306 ? .mysql : .postgres
                found.append(DBCandidate(id: "ssh-\(h.id)-\(p)", source: .ssh, name: "\(f.label) on \(h.name)", sub: "port \(p) open · via SSH tunnel",
                                         flavor: f, host: "127.0.0.1", port: p, user: f == .postgres ? "postgres" : "root", sshHostID: h.id))
            }
        }
        serverScanDone = true
        scanning = false
    }

    private func badge(for c: DBCandidate) -> String {
        switch c.source {
        case .env: "ENV"
        case .ssh: "SSH"
        default: Self.letters(c.flavor)
        }
    }

    private func color(for c: DBCandidate) -> Color {
        switch c.source {
        case .env: accent
        case .ssh: Theme.blue
        default: Self.color(c.flavor)
        }
    }

    // MARK: Load and save

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let d = existing else { return }
        name = d.name; nameEdited = true; flavor = DBProduct.flavor(d); host = d.host; port = "\(d.port)"; database = d.database; user = d.user
        filePath = d.filePath; ssl = d.sslMode; tunnel = d.tunnelHostID; tag = d.tag; access = d.agentAccess
        route = d.route == .direct && d.tunnelHostID != nil ? .ssh : d.route
        container = d.dockerContainer
        timeout = d.connectTimeout.map(String.init) ?? ""; queryTimeout = d.queryTimeout.map(String.init) ?? ""
        colour = d.colour; startupSQL = d.startupSQL; notes = d.notes
        advanced = d.connectTimeout != nil || d.queryTimeout != nil || !d.startupSQL.isEmpty || d.colour != nil || !d.notes.isEmpty
        projects = Set(store.library.links.projects(for: d.id))
        storedPassword = store.dbPassword(d)
    }

    private func chooseFile() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.message = "Choose a SQLite database file"
        if p.runModal() == .OK, let u = p.url {
            filePath = (u.path as NSString).abbreviatingWithTildeInPath
            suggestName()
        }
    }

    /// The connection the form describes. `validate: false` is the live test:
    /// it shows no errors and accepts a missing name.
    private func build(validate: Bool = true) -> DatabaseConnection? {
        var e: [String: String] = [:]
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { e["name"] = "Enter a name" }
        var p = 0
        if kind == .sqlite {
            if filePath.isEmpty { e["file"] = "Choose a file" }
            else if !(existing?.isSample ?? false), !FileManager.default.fileExists(atPath: (filePath as NSString).expandingTildeInPath) { e["file"] = "No file at that path" }
        } else {
            if host.trimmingCharacters(in: .whitespaces).isEmpty { e["host"] = "Enter a host" }
            if let v = Int(port), (1...65535).contains(v) { p = v } else { e["port"] = "1 to 65535" }
            if user.trimmingCharacters(in: .whitespaces).isEmpty { e["user"] = "Enter a user" }
            if kind == .mysql, database.trimmingCharacters(in: .whitespaces).isEmpty { e["database"] = "Enter a database" }
            if route == .ssh, tunnel == nil { e["host"] = "Pick a server for the SSH tunnel" }
        }
        let t = timeout.trimmingCharacters(in: .whitespaces), q = queryTimeout.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, Int(t).map({ !(1...600).contains($0) }) ?? true { e["timeout"] = "1 to 600 seconds" }
        if !q.isEmpty, Int(q).map({ !(1...86_400).contains($0) }) ?? true { e["queryTimeout"] = "1 to 86400 seconds" }
        if validate {
            errors = e
            if !e.isEmpty, !advanced, e["timeout"] != nil || e["queryTimeout"] != nil { advanced = true }
            guard e.isEmpty else { return nil }
        } else if e.keys.contains(where: { $0 != "name" }) {
            return nil
        }
        var d = existing ?? DatabaseConnection(id: draftID, name: n, kind: kind, tag: tag)
        d.name = n.isEmpty ? "test" : n; d.kind = kind; d.host = host.trimmingCharacters(in: .whitespaces); d.port = p
        d.database = database.trimmingCharacters(in: .whitespaces); d.user = user.trimmingCharacters(in: .whitespaces)
        d.filePath = filePath; d.sslMode = ssl
        d.route = kind == .sqlite ? .direct : route
        d.tunnelHostID = kind == .sqlite || route != .ssh ? nil : tunnel
        d.dockerContainer = kind != .sqlite && route == .docker ? container : nil
        d.tag = tag; d.readOnly = d.readOnly || tag.isProduction
        d.flavor = flavor
        // Production never lets agents write, whatever the form says.
        d.agentAccess = tag.isProduction && access == .write ? .read : access
        d.connectTimeout = Int(t); d.queryTimeout = kind == .sqlite ? nil : Int(q)
        d.colour = colour; d.startupSQL = kind == .sqlite ? "" : startupSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        d.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return d
    }

    private func save(open: Bool) {
        guard let d = build() else { return }
        store.saveDatabase(d, password: password.isEmpty ? nil : password)
        let before = Set(store.library.links.projects(for: d.id))
        for p in projects.subtracting(before) { store.setLink(p, d.id, kind: .database, linked: true) }
        for p in before.subtracting(projects) { store.setLink(p, d.id, kind: .database, linked: false) }
        store.selectedDatabase = d.id
        dismiss()
        if open { store.go(.databases) }
    }
}

/// Small caps section label from the design.
private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Typo.ui(10.5, .bold)).tracking(0.74).foregroundStyle(Theme.text3)
    }
}

/// Engine and source badges: letters on a tinted square.
struct LetterBadge: View {
    let text: String
    let color: Color
    var size: CGFloat = 22
    var body: some View {
        Text(text).font(.system(size: max(8.5, (size * 0.36).rounded()), weight: .heavy)).foregroundStyle(color)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: max(4, (size * 0.24).rounded())).fill(color.opacity(0.14)))
            .accessibilityHidden(true)
    }
}
