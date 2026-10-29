import SwiftUI

/// Saved database connections with a detail pane and Test Connection.
struct DBConnectionsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    @State private var query = ""

    private var current: DatabaseConnection? { store.selectedDatabase.flatMap(store.database) ?? store.library.databases.first }

    var body: some View {
        if store.library.databases.isEmpty {
            EmptyState(symbol: "link", message: "No saved connections yet.", actionTitle: "Add Database") { store.sheet = .editDatabase(nil) }
                .island()
        } else {
            HStack(spacing: gap) {
                list
                if let d = current { ConnectionDetail(db: d).id(d.id).frame(width: 440) }
            }
        }
    }

    private var list: some View {
        let items = store.library.databases.filter { query.isEmpty || FuzzyMatcher.score(query, $0.name + " " + $0.endpoint) != nil }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                SearchField(placeholder: "Filter connections", text: $query, height: 30).frame(width: 260)
                Spacer()
                SubtleButton(title: "Import…", symbol: "square.and.arrow.down") { store.sheet = .importConnections }
                AccentButton(title: "Add Database", symbol: "plus") { store.sheet = .editDatabase(nil) }
            }
            .padding(.leading, 16).padding(.trailing, 12).frame(height: 52).hairlineBottom()
            HStack(spacing: 10) {
                Color.clear.frame(width: 26)
                Text("Name").frame(width: 170, alignment: .leading)
                Text("Endpoint").frame(maxWidth: .infinity, alignment: .leading)
                Text("Env").frame(width: 70, alignment: .leading)
                Text("Status").frame(width: 110, alignment: .leading)
                Text("Last used").frame(width: 80, alignment: .leading)
                Text("Projects").frame(width: 90, alignment: .leading)
            }
            .font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3)
            .padding(.horizontal, 16).frame(height: 30).hairlineBottom()
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(items) { d in row(d) }
                }
                .padding(6)
            }
        }
        .island()
    }

    private func row(_ d: DatabaseConnection) -> some View {
        let status = store.dbStatus[d.id] ?? .disconnected
        let projects = store.library.links.projects(for: d.id).compactMap(store.project)
        let on = d.id == current?.id
        return HStack(spacing: 10) {
            DatabaseIcon(db: d, size: 26)
            HStack(spacing: 5) {
                Text(d.name).font(Typo.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                if d.effectiveReadOnly { Image(systemName: "lock.fill").font(.system(size: 8.5)).foregroundStyle(Theme.text3) }
            }
            .frame(width: 170, alignment: .leading)
            Text(d.endpoint).font(Typo.mono(11)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            TagPill(tag: d.tag, size: 8.5).frame(width: 70, alignment: .leading)
            HStack(spacing: 6) {
                if status == .connecting { ProgressView().controlSize(.mini) } else { StatusDot(color: status.color, size: 6) }
                Text(status.label).font(Typo.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)
            Text(d.lastUsed.map { RelativeTime.long($0) } ?? "Never").font(Typo.ui(11.5)).foregroundStyle(Theme.text3).frame(width: 80, alignment: .leading)
            HStack(spacing: -5) {
                ForEach(projects.prefix(3)) { p in ProjectMark(project: p, size: 20).background(RoundedRectangle(cornerRadius: 6).fill(Theme.island).padding(-2)) }
                if projects.isEmpty { Text("–").font(Typo.ui(11)).foregroundStyle(Theme.meta) }
            }
            .frame(width: 90, alignment: .leading)
        }
        .padding(.horizontal, 10).frame(height: 48)
        .rowBackground(selected: on, radius: 8)
        .clickable().onTapGesture { store.selectedDatabase = d.id }
        .onTapGesture(count: 2) { store.selectedDatabase = d.id; store.route = .databases }
        .contextMenu { DatabaseContextMenu(db: d) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(d.name), \(d.kind.label), \(d.tag.name), \(status.label)")
    }
}

private struct ConnectionDetail: View {
    @Environment(AppStore.self) private var store
    let db: DatabaseConnection
    @State private var test: TestOutcome?
    @State private var testing = false

    enum TestOutcome { case ok(DBTestResult), failed(String) }

    var body: some View {
        let d = db
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                DatabaseIcon(db: d, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(d.name).font(Typo.ui(15, .semibold)).foregroundStyle(Theme.text)
                        TagPill(tag: d.tag)
                    }
                    Text(d.kind.label + (d.effectiveReadOnly ? " · read-only" : "")).font(Typo.ui(12)).foregroundStyle(Theme.text2)
                }
                Spacer()
            }
            .padding(18).hairlineBottom()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    AccentButton(title: testing ? "Testing…" : "Test Connection", isLoading: testing) { runTest() }.disabled(testing)
                    SubtleButton(title: "Open in Browser") { store.selectedDatabase = d.id; store.route = .databases }
                    SubtleButton(title: "Edit") { store.sheet = .editDatabase(d) }
                }
                HStack(spacing: 6) {
                    SubtleButton(title: "Dump…", symbol: "square.and.arrow.up", height: 26, isLoading: store.dbBusy.contains(d.id)) { store.dumpDatabase(d) }
                        .disabled(store.dbBusy.contains(d.id))
                    SubtleButton(title: "Restore…", symbol: "square.and.arrow.down", height: 26) { store.restoreDatabase(d) }
                        .disabled(store.dbBusy.contains(d.id) || d.readOnly)
                        .help(d.readOnly ? "Read-only: turn it off to restore" : "Run a .sql or pg_dump file against this database")
                    SubtleButton(title: "Open CLI", symbol: "terminal", height: 26) { store.openDatabaseCLI(d) }
                    MenuButton(items: {
                        [MenuSpec(title: "New Query") { store.pendingQuery = (d.id, ""); store.selectedDatabase = d.id; store.route = .databases },
                         MenuSpec(title: "Copy Connection URL") { store.copyToPasteboard(store.connectionURL(d), label: "connection URL (no password)") },
                         MenuSpec(title: "Duplicate") { store.duplicateDatabase(d.id) },
                         .separator,
                         MenuSpec(title: "Delete…") { store.requestRemoveDatabase(d.id) }]
                    }) {
                        Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text2)
                            .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 8).fill(Theme.control)).contentShape(Rectangle())
                    }
                    .accessibilityLabel("More database actions")
                }
                Toggle(isOn: Binding(get: { d.readOnly || d.tag.isProduction }, set: { store.setReadOnly(d, $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Read-only").font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text)
                        Text(d.tag.isProduction ? "Always on for Production; writes ask first" : "Block writes from the SQL editor, restore and CLI")
                            .font(Typo.ui(11)).foregroundStyle(Theme.text3)
                    }
                }
                .toggleStyle(.bx).frame(maxWidth: 360)
                .disabled(d.tag.isProduction)
                switch test {
                case .ok(let r)?:
                    Label("Connected · \(r.version) · \(Int(r.latencyMs)) ms", systemImage: "checkmark.circle.fill").font(Typo.ui(12)).foregroundStyle(Theme.green)
                case .failed(let m)?:
                    Label(m, systemImage: "xmark.octagon.fill").font(Typo.ui(12)).foregroundStyle(Theme.red).textSelection(.enabled)
                case nil:
                    EmptyView()
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).hairlineBottom()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    InspectorSection(title: "Connection") {
                        if d.kind == .sqlite {
                            FactRow(key: "File", value: d.filePath)
                        } else {
                            FactRow(key: "Host", value: d.host)
                            FactRow(key: "Port", value: "\(d.port)")
                            FactRow(key: "Database", value: d.database.ifEmpty("–"))
                            FactRow(key: "User", value: d.user.ifEmpty("–"))
                            FactRow(key: "Password", value: store.keychain.has(Keychain.dbAccount(d.id)) ? "Stored in Keychain" : "Not saved", mono: false)
                            FactRow(key: "SSL", value: d.sslMode.rawValue)
                            FactRow(key: "SSH tunnel", value: d.tunnelHostID.flatMap(store.host)?.name ?? "None", mono: false)
                        }
                        FactRow(key: "Read-only", value: d.readOnly ? "Yes" : (d.tag.isProduction ? "Yes (Production)" : "No"), mono: false)
                        FactRow(key: "Last used", value: d.lastUsed.map { RelativeTime.long($0) + " ago" } ?? "Never", mono: false)
                    }
                    InspectorSection(title: "Linked projects") {
                        let ps = store.library.links.projects(for: d.id).compactMap(store.project)
                        if ps.isEmpty { Text("Not linked to any project.").font(Typo.ui(12)).foregroundStyle(Theme.text3) }
                        ForEach(ps) { p in
                            HStack(spacing: 8) {
                                ProjectMark(project: p, size: 18)
                                Text(p.name).font(Typo.row).foregroundStyle(Theme.text)
                            }
                            .frame(height: 26)
                        }
                    }
                }
            }
        }
        .island()
    }

    private func runTest() {
        testing = true
        test = nil
        Task {
            switch await store.testDatabase(db) {
            case .success(let r): test = .ok(r)
            case .failure(let e): test = .failed(e.message)
            }
            testing = false
        }
    }
}
