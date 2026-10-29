import SwiftUI
import AppKit

/// Right-hand inspector panel. Details follow the current selection; in the
/// Review layout it defaults to History, as in the Git artboard.
struct InspectorPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    @State private var tab: Int?

    private var effectiveTab: Int { tab ?? (ws.layout.centre == .review ? 1 : 0) }

    var body: some View {
        PanelChrome(title: "Inspector") {
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                tabButton("Details", 0)
                tabButton("History", 1)
                tabButton("Branches", 2)
            }
        } content: {
            switch effectiveTab {
            case 1:
                VStack(spacing: 0) {
                    HistoryTimeline(projectID: ws.projectID, selected: Binding(get: { ws.selectedCommit }, set: { ws.selectedCommit = $0 }))
                    if let h = ws.selectedCommit {
                        CommitDetail(projectID: ws.projectID, hash: h)
                            .frame(maxHeight: 280)
                            .hairlineTop()
                    }
                }
            case 2:
                BranchesList(projectID: ws.projectID)
            default:
                InspectorDetails(selection: store.inspector == .none ? .project(ws.projectID) : store.inspector)
            }
        }
    }

    private func tabButton(_ t: String, _ i: Int) -> some View {
        let on = effectiveTab == i
        return Button { tab = i } label: {
            Text(t).font(Typo.ui(11, .medium)).foregroundStyle(on ? Theme.text : Theme.text3)
                .padding(.horizontal, 7).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.white(0.08) : .clear))
                .contentShape(Rectangle())
                .fixedSize()
        }
        .buttonStyle(.hand)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Selection-driven details, also used by the Projects, SSH and Recent Files screens.
struct InspectorDetails: View {
    @Environment(AppStore.self) private var store
    let selection: InspectorSelection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch selection {
                case .none:
                    EmptyState(symbol: "sidebar.right", message: "Select a file, project, session, host, table or commit to see its details.")
                        .frame(height: 300)
                case .file(let p, let path): FileInspector(projectID: p, path: path)
                case .project(let p): ProjectInspector(projectID: p)
                case .session(let id): SessionInspector(sessionID: id)
                case .host(let id): HostInspector(hostID: id)
                case .table(let db, let obj): TableInspector(dbID: db, object: obj)
                case .commit(let p, let h): CommitDetail(projectID: p, hash: h)
                }
            }
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3).padding(.bottom, 6)
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairlineBottom()
    }
}

struct InspectorActions: View {
    let actions: [(String, () -> Void)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                SubtleButton(title: a.0, height: 26, fullWidth: true, action: a.1)
            }
        }
        .padding(14)
    }
}

// MARK: - File

struct FileInspector: View {
    @Environment(AppStore.self) private var store
    let projectID: ProjectID
    let path: String
    @State private var info: FileInfo?

    var body: some View {
        let p = store.project(projectID)
        let change = store.git[projectID]?.changes.first { $0.path == path }
        let last = store.git[projectID]?.commits.first { c in c.files.contains { $0.path == path } } ?? store.git[projectID]?.commits.first
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: FileKinds.isImage(path) ? "photo" : "doc.text").font(.system(size: 16)).foregroundStyle(FileKinds.iconColor(for: path))
                    .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 8).fill(Color.white(0.05)))
                VStack(alignment: .leading, spacing: 2) {
                    Text((path as NSString).lastPathComponent).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                    Text(p?.name ?? "").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                }
            }
            .padding(14).hairlineBottom()
            InspectorSection(title: "File") {
                FactRow(key: "Kind", value: info?.kind ?? "…", mono: false)
                FactRow(key: "Size", value: info.map { ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file) } ?? "…")
                FactRow(key: "Lines", value: info.map { $0.lines > 0 ? "\($0.lines)" : "–" } ?? "…")
                FactRow(key: "Encoding", value: info?.encoding ?? "…")
                FactRow(key: "Modified", value: info?.modified.map { RelativeTime.long($0) + " ago" } ?? "–", mono: false)
                FactRow(key: "Path", value: ((p?.path ?? "") as NSString).appendingPathComponent(path))
            }
            InspectorSection(title: "Git") {
                FactRow(key: "Status", value: change.map { "\($0.status.name)\($0.staged ? ", staged" : "")" } ?? "Unchanged", mono: false,
                        valueColor: change?.status.color ?? Theme.text)
                if let c = change { HStack { Text("Changes").font(Typo.row).foregroundStyle(Theme.text3).frame(width: 96, alignment: .leading); AddDel(add: c.add, del: c.del, size: 11.5) }.frame(height: 28) }
                if let l = last { FactRow(key: "Last commit", value: "\(l.short) \(l.message)") }
            }
            InspectorActions(actions: [
                ("Copy Path", { store.copyToPasteboard((p?.expandedPath ?? "") + "/" + path, label: "path") }),
                ("Copy Relative", { store.copyToPasteboard(path, label: "relative path") }),
                ("Reveal in Finder", { if let p, !p.isSample { NSWorkspace.shared.selectFile(p.expandedPath + "/" + path, inFileViewerRootedAtPath: "") } else { store.toast(.info, "Sample files aren't on disk") } }),
                ("Open in Workspace", { store.openProject(projectID); store.workspace(for: projectID).open(path) }),
                ("Ask Agent", { store.openProject(projectID); store.askAgent(about: path, in: projectID) })
            ])
        }
        .task(id: path) {
            guard let p else { return }
            info = await store.svc(p).files.info(p, path: path)
        }
    }
}

// MARK: - Project

struct ProjectInspector: View {
    @Environment(AppStore.self) private var store
    let projectID: ProjectID

    var body: some View {
        if let p = store.project(projectID) {
            let g = store.git[p.id]
            let sessions = store.sessions.filter { $0.projectID == p.id }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ProjectMark(project: p, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(Typo.ui(15, .semibold)).foregroundStyle(Theme.text)
                            Text(p.framework).font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                        }
                    }
                    HStack(spacing: 6) {
                        AccentButton(title: "Open", fullWidth: true) { store.openProject(p.id) }
                        SubtleButton(title: "Terminal", fullWidth: true) { store.newTerminal(project: p.id, attach: false); store.route = .terminals }
                        SubtleButton(title: "Finder", fullWidth: true) {
                            if p.isSample { store.toast(.info, "Sample projects aren't on disk") } else { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.expandedPath) }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14).hairlineBottom()
                VStack(alignment: .leading, spacing: 2) {
                    FactRow(key: "Location", value: p.path)
                    if let g, g.isRepo {
                        FactRow(key: "Branch", value: g.branch)
                        FactRow(key: "Remote", value: "\(g.remote) ↑\(g.ahead) ↓\(g.behind)")
                        FactRow(key: "Changes", value: g.isClean ? "Clean" : "\(g.staged.count) staged · \(g.unstaged.count) unstaged")
                    } else {
                        FactRow(key: "Git", value: "Not a repository", mono: false)
                    }
                    FactRow(key: "Sessions", value: sessions.isEmpty ? "None" : sessions.map { $0.title }.joined(separator: " · "), mono: false)
                }
                .padding(.horizontal, 16).padding(.vertical, 14).hairlineBottom()
                LinkedResourcesList(projectID: p.id)
            }
        } else {
            EmptyState(symbol: "questionmark.folder", message: "Project not found.")
        }
    }
}

struct LinkedResourcesList: View {
    @Environment(AppStore.self) private var store
    let projectID: ProjectID

    var body: some View {
        let hosts = store.linkedHosts(projectID)
        let dbs = store.linkedDatabases(projectID)
        let docker = store.linkedDocker(projectID)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Linked resources").font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3)
                Spacer()
                LinkButton(title: "Manage →") { store.route = .projectSettings(projectID) }
            }
            if hosts.isEmpty && dbs.isEmpty && docker.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nothing linked yet.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
                    SubtleButton(title: "Link a server", symbol: "link", height: 26) { store.route = .projectSettings(projectID) }
                }
            }
            ForEach(hosts) { h in row(AnyView(ServerOSIcon(host: h, size: 22)), h.name, tag: h.tag) { store.selectedHost = h.id; store.route = .ssh } }
            ForEach(dbs) { d in row(AnyView(DatabaseIcon(db: d, size: 22)), d.name, tag: d.tag) { store.selectedDatabase = d.id; store.route = .databases } }
            if !docker.isEmpty {
                Button { store.route = .docker } label: {
                    HStack(spacing: 9) {
                        LogoBadge(logo: "Logos/docker", color: Theme.blue, size: 22)
                        Text(docker.map(\.name).joined(separator: " · ")).font(Typo.row).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("DOCKER").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text2)
                    }
                    .frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.hand)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func row(_ icon: AnyView, _ name: String, tag: EnvTag, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 9) {
                icon
                Text(name).font(Typo.row).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                TagPill(tag: tag, size: 9, filled: false)
            }
            .frame(height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.hand)
    }
}

// MARK: - Session

struct SessionInspector: View {
    @Environment(AppStore.self) private var store
    let sessionID: String

    var body: some View {
        if let s = store.session(sessionID) {
            let host = s.hostID.flatMap(store.host)
            VStack(alignment: .leading, spacing: 0) {
                InspectorSection(title: s.kind == .agent ? "\(s.title) session" : "Terminal session") {
                    FactRow(key: "Name", value: s.title, mono: false)
                    HStack(spacing: 0) {
                        Text("Status").font(Typo.row).foregroundStyle(Theme.text3).frame(width: 96, alignment: .leading)
                        StatusDot(color: s.state.color, size: 6)
                        Text(" " + s.state.label).font(Typo.row).foregroundStyle(Theme.text)
                    }
                    .frame(height: 28)
                    FactRow(key: "Process", value: s.process)
                    FactRow(key: "Directory", value: s.cwd)
                    FactRow(key: "Where", value: host == nil ? "Local" : "Remote", mono: false)
                    if let host {
                        HStack(spacing: 6) {
                            Text("Host").font(Typo.row).foregroundStyle(Theme.text3).frame(width: 96, alignment: .leading)
                            Text(host.name).font(Typo.row).foregroundStyle(Theme.text)
                            TagPill(tag: host.tag, size: 8.5)
                        }
                        .frame(height: 28)
                    }
                    FactRow(key: "Started", value: s.startedAt.formatted(date: .omitted, time: .shortened) + " · " + RelativeTime.long(s.startedAt) + " ago", mono: false)
                    FactRow(key: "Activity", value: s.lastOutput.components(separatedBy: "\n").last ?? "–")
                }
                InspectorActions(actions: [
                    ("Rename", { store.sheet = .renameSession(s.id) }),
                    ("Clear", { store.clearSession(s.id) }),
                    ("Copy Directory", { store.copyToPasteboard(s.cwd, label: "directory") }),
                    ("Close", { store.closeSession(s.id) })
                ])
            }
        } else {
            EmptyState(symbol: "terminal", message: "This session was closed.")
        }
    }
}

// MARK: - Host

struct HostInspector: View {
    @Environment(AppStore.self) private var store
    let hostID: ResourceID

    var body: some View {
        if let h = store.host(hostID) {
            let status = store.hostStatus[h.id] ?? .disconnected
            let sessions = store.sessions.filter { $0.hostID == h.id }
            VStack(alignment: .leading, spacing: 0) {
                InspectorSection(title: "SSH host") {
                    HStack(spacing: 8) {
                        Text(h.name).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                        TagPill(tag: h.tag)
                    }
                    .padding(.bottom, 4)
                    HStack(spacing: 0) {
                        Text("Status").font(Typo.row).foregroundStyle(Theme.text3).frame(width: 96, alignment: .leading)
                        StatusDot(color: status.color, size: 6)
                        Text(" " + status.label).font(Typo.row).foregroundStyle(Theme.text)
                    }
                    .frame(height: 28)
                    FactRow(key: "Host", value: h.host)
                    FactRow(key: "User", value: h.user)
                    FactRow(key: "Port", value: "\(h.port)")
                    FactRow(key: "Auth", value: HostAuthText.describe(h, keychainHas: store.keychain.has(Keychain.hostAccount(h.id))))
                    FactRow(key: "Last seen", value: h.lastConnected.map { RelativeTime.long($0) + " ago" } ?? "Never", mono: false)
                    FactRow(key: "Sessions", value: sessions.isEmpty ? "None" : sessions.map(\.title).joined(separator: ", "), mono: false)
                    FactRow(key: "Projects", value: store.library.links.projects(for: h.id).compactMap { store.project($0)?.name }.joined(separator: ", ").ifEmpty("None"), mono: false)
                }
                InspectorActions(actions: [
                    ("Connect", { store.connect(h.id) }),
                    ("Edit", { store.sheet = .editHost(h) }),
                    ("Copy SSH Command", { store.copyToPasteboard(h.sshCommand, label: "SSH command") }),
                    ("Show in SSH", { store.selectedHost = h.id; store.route = .ssh })
                ])
            }
        } else {
            EmptyState(symbol: "globe", message: "Host not found.")
        }
    }
}

enum HostAuthText {
    /// Never includes a secret.
    static func describe(_ h: SSHHost, keychainHas: Bool) -> String {
        switch h.auth {
        case .key: "SSH key · \(h.keyPath.isEmpty ? "default" : h.keyPath)"
        case .agent: "SSH agent"
        case .password: keychainHas ? "Password · Stored in Keychain" : "Password · not saved"
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - Table

struct TableInspector: View {
    @Environment(AppStore.self) private var store
    let dbID: ResourceID
    let object: DBObject
    @State private var detail: TableDetail?
    @State private var error: String?

    var body: some View {
        let db = store.database(dbID)
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection(title: object.kind == .view ? "View" : (object.kind == .function ? "Function" : "Table")) {
                Text("\(object.schema).\(object.name)").font(Typo.mono(12.5, .medium)).foregroundStyle(Theme.text).padding(.bottom, 4)
                FactRow(key: "Type", value: object.kind.rawValue.capitalized, mono: false)
                FactRow(key: "Est. rows", value: detail.map { $0.rowEstimate.formatted() } ?? (object.rowEstimate?.formatted() ?? "–"))
                FactRow(key: "Size", value: detail?.size.ifEmpty("–") ?? "…")
                FactRow(key: "Connection", value: db?.name ?? "–")
            }
            if let error {
                Text(error).font(Typo.ui(11.5)).foregroundStyle(Theme.red).padding(14)
            }
            if let d = detail {
                InspectorSection(title: "Columns · \(d.columns.count)") {
                    ForEach(d.columns) { c in
                        HStack(spacing: 6) {
                            Text(c.name).font(Typo.mono(11.5)).foregroundStyle(Theme.text)
                            if c.isPK { KeyBadge(text: "PK", color: Theme.amber) }
                            if c.fk != nil { KeyBadge(text: "FK", color: Theme.blue) }
                            Spacer(minLength: 0)
                            Text(c.type).font(Typo.mono(10.5)).foregroundStyle(Theme.text3)
                        }
                        .frame(height: 24)
                    }
                }
                InspectorSection(title: "Indexes · \(d.indexes.count)") {
                    ForEach(d.indexes) { i in
                        HStack {
                            Text(i.name).font(Typo.mono(11)).foregroundStyle(Theme.body).lineLimit(1)
                            Spacer()
                            if i.unique { Text("unique").font(Typo.ui(10.5)).foregroundStyle(Theme.text3) }
                        }
                        .frame(height: 22)
                    }
                }
            }
        }
        .task(id: object.id) {
            guard let db else { return }
            do {
                detail = try await store.svc(db).db.tableDetail(db, object: object, password: store.dbPassword(db))
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct KeyBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 8.5, weight: .heavy)).foregroundStyle(color)
            .padding(.horizontal, 3)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.35)))
    }
}

// MARK: - Commit

struct CommitDetail: View {
    @Environment(AppStore.self) private var store
    let projectID: ProjectID
    let hash: String
    @State private var commit: GitCommit?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let c = commit {
                    InspectorSection(title: "Commit") {
                        Text(c.message).font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text).padding(.bottom, 6).textSelection(.enabled)
                        FactRow(key: "Hash", value: c.short)
                        FactRow(key: "Author", value: c.author, mono: false)
                        FactRow(key: "Date", value: c.date.formatted(date: .abbreviated, time: .shortened), mono: false)
                        FactRow(key: "Pushed", value: c.isPushed ? "Yes" : "Not yet", mono: false)
                    }
                    InspectorSection(title: "Files changed · \(c.files.count)") {
                        if c.files.isEmpty { Text("No file stats").font(Typo.ui(12)).foregroundStyle(Theme.text3) }
                        ForEach(c.files) { f in
                            HStack {
                                Text(f.path).font(Typo.mono(11)).foregroundStyle(Theme.body).lineLimit(1).truncationMode(.head)
                                Spacer(minLength: 6)
                                AddDel(add: f.add, del: f.del)
                            }
                            .frame(height: 24)
                        }
                        let a = c.files.reduce(0) { $0 + $1.add }, d = c.files.reduce(0) { $0 + $1.del }
                        Text("\(c.files.count) files · +\(a) −\(d)").font(Typo.ui(11)).foregroundStyle(Theme.text3).padding(.top, 4)
                    }
                    InspectorActions(actions: [("Copy Hash", { store.copyToPasteboard(c.hash, label: "hash") })])
                } else if let error {
                    Text(error).font(Typo.ui(12)).foregroundStyle(Theme.red).padding(14)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
                }
            }
        }
        .task(id: hash) {
            guard let p = store.project(projectID) else { return }
            do {
                commit = try await store.svc(p).git.commitDetail(p, hash: hash)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
