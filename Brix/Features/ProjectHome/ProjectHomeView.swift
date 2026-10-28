import SwiftUI

/// What the project overview loaded last time, and when.
struct ProjectHomeData {
    var scan: ProjectScan?
    var scanned = Date.distantPast
    var history: [AgentHistoryEntry]?
    var stats: [String: TranscriptStats] = [:]
    var tasks: [RunTask] = []
    var codebase: CodebaseStats?
    var counted = Date.distantPast
}

/// Project overview (project selected, workspace not open): header and ask box,
/// stats, agent sessions and activity, and Run, Connections, AI instructions and Codebase.
struct ProjectHomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    let projectID: ProjectID
    @State private var scan: ProjectScan?
    @State private var history: [AgentHistoryEntry]?
    @State private var stats: [String: TranscriptStats] = [:]
    @State private var tasks: [RunTask] = []
    @State private var codebase: CodebaseStats?
    @State private var lastFetch: Date?

    private var project: Project? { store.project(projectID) }
    private var space: CGFloat { max(gap, 6) }

    var body: some View {
        if let p = project {
            VStack(spacing: space) {
                ProjectHeader(project: p, stack: stack(p), lastFetch: lastFetch)
                StatsRow(project: p)
                HStack(alignment: .top, spacing: space) {
                    // Sessions and activity share the column 1.25 : 1.
                    GeometryReader { geo in
                        let h = geo.size.height - space
                        VStack(spacing: space) {
                            SessionsCard(project: p, history: history, stats: stats, reload: { Task { await loadHistory(p) } })
                                .frame(height: h * 1.25 / 2.25)
                            CommitsCard(project: p)
                                .frame(height: h / 2.25)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        VStack(spacing: space) {
                            if !store.children(of: p.id).isEmpty { RepositoriesCard(project: p) }
                            RunCard(project: p, tasks: tasks)
                            if showsGitHub(p) { GitHubCard(project: p) }
                            ConnectionsCard(project: p)
                            InstructionsCard(project: p, scan: scan, reload: { Task { await load(p, force: true) } })
                            CodebaseCard(project: p, stats: codebase)
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(width: 360)
                }
                .frame(maxHeight: .infinity)
            }
            .task(id: projectID) {
                await load(p)
                // Sessions run elsewhere too; check again while this screen is up.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    await loadHistory(p)
                }
            }
        }
    }

    /// Shows what was loaded last time at once, then refreshes only what's stale:
    /// the folder scan after a minute, line counts after ten.
    private func load(_ p: Project, force: Bool = false) async {
        var cache = store.homeCache[p.id] ?? ProjectHomeData()
        scan = cache.scan; history = cache.history; stats = cache.stats; codebase = cache.codebase
        tasks = cache.tasks.isEmpty ? store.svc(p).activity.runTasks(p) : cache.tasks
        let fetch = p.url.appendingPathComponent(".git/FETCH_HEAD").path
        lastFetch = (try? FileManager.default.attributesOfItem(atPath: fetch))?[.modificationDate] as? Date
        await loadHistory(p)
        if force || Date().timeIntervalSince(cache.scanned) > 60 {
            let url = p.url
            scan = await Task.detached(priority: .userInitiated) { p.isSample ? ProjectScan() : ProjectScan.scan(url) }.value
            tasks = store.svc(p).activity.runTasks(p)
            cache.scanned = Date()
        }
        if force || codebase == nil || Date().timeIntervalSince(cache.counted) > 600 {
            codebase = await store.svc(p).activity.codebase(p)
            cache.counted = Date()
        }
        guard !Task.isCancelled else { return }
        cache.scan = scan; cache.tasks = tasks; cache.codebase = codebase
        cache.history = history; cache.stats = stats
        store.homeCache[p.id] = cache
    }

    private func loadHistory(_ p: Project) async {
        guard !p.isSample else { history = []; return }
        let path = p.expandedPath
        let entries = await Task.detached(priority: .utility) {
            (AgentTranscripts.claudeSessions(projectPath: path) + AgentTranscripts.codexSessions(projectPath: path)).sorted { $0.lastActivity > $1.lastActivity }
        }.value
        history = entries
        let recent = Array(entries.prefix(20))
        let computed = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: recent.map { ($0.id, AgentTranscripts.stats($0)) })
        }.value
        stats.merge(computed) { _, new in new }
        store.homeCache[p.id, default: ProjectHomeData()].history = history
        store.homeCache[p.id, default: ProjectHomeData()].stats = stats
    }

    /// The GitHub card only where there's a GitHub repo to show: a repo with a
    /// GitHub remote, or a folder whose repositories have one.
    private func showsGitHub(_ p: Project) -> Bool {
        let ids = [p.id] + store.children(of: p.id).map(\.id)
        return ids.contains { id in
            switch store.github[id] ?? .loading {
            case .noRepo: false
            case .loading: store.git[id]?.isRepo == true || store.project(id)?.isSample == true
            default: true
            }
        }
    }

    /// Language, framework and tools found at the root.
    private func stack(_ p: Project) -> [(String, Color)] {
        var out: [(String, Color)] = []
        func add(_ s: String) {
            guard !s.isEmpty, s != "Unknown", s != "Folder", !out.contains(where: { $0.0 == s }) else { return }
            let c = CodebaseScanner.languages.values.first { $0.0 == s }.map { Color(hex: $0.1) } ?? Theme.text2
            out.append((s, c))
        }
        add(p.language)
        add(p.framework)
        if !p.isSample {
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: p.expandedPath)) ?? [])
            for (file, label) in ProjectScan.markers.sorted(by: { $0.key < $1.key }) where names.contains(file) { add(label) }
        }
        return Array(out.prefix(5))
    }
}

// MARK: - Header and ask box

private struct ProjectHeader: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let project: Project
    let stack: [(String, Color)]
    let lastFetch: Date?
    @State private var prompt = ""
    @State private var refs: [String] = []
    @State private var agentID: String?

    var body: some View {
        let p = project
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { store.projectSettingsSection = "General"; store.route = .projectSettings(p.id) } label: {
                    ProjectMark(project: p, size: 56)
                }
                .buttonStyle(.plain)
                .help("Change the name and icon")
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Text(p.name).font(Typo.ui(20, .semibold)).tracking(-0.2).foregroundStyle(Theme.text).lineLimit(1)
                        if let g = store.git[p.id], g.isRepo {
                            Text("⎇ \(g.branch)").font(Typo.mono(11)).foregroundStyle(p.hue.color)
                                .padding(.horizontal, 8).frame(height: 22).background(RoundedRectangle(cornerRadius: 6).fill(p.hue.color.opacity(0.10)))
                            let n = g.changedFileCount
                            Text(n == 0 ? "Clean" : "\(n) change\(n == 1 ? "" : "s")").font(Typo.ui(11, .semibold)).foregroundStyle(n == 0 ? Theme.green : Theme.amber)
                                .padding(.horizontal, 8).frame(height: 22).background(RoundedRectangle(cornerRadius: 6).fill((n == 0 ? Theme.green : Theme.amber).opacity(0.12)))
                            Text("↑\(g.ahead) ↓\(g.behind)" + (lastFetch.map { " · synced \(RelativeTime.ago($0))" } ?? "")).font(Typo.ui(11)).foregroundStyle(Theme.text3)
                        }
                        if store.runningPipelines(p.id) > 0 {
                            pipelinePill(p)
                        }
                    }
                    HStack(spacing: 6) {
                        Text((p.expandedPath as NSString).abbreviatingWithTildeInPath).font(Typo.mono(11.5)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                            .padding(.trailing, 6)
                        ForEach(stack, id: \.0) { s in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2).fill(s.1).frame(width: 6, height: 6)
                                Text(s.0)
                            }
                            .font(Typo.ui(11)).foregroundStyle(Theme.body)
                            .padding(.horizontal, 7).frame(height: 20).background(RoundedRectangle(cornerRadius: 5).fill(Color.white(0.05)))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SubtleButton(title: "Terminal", symbol: "chevron.right", height: 28) { store.openProject(p.id); store.newTerminal(project: p.id) }
                IconButton(symbol: "slider.horizontal.3", label: "Project Settings", size: 28, iconSize: 12.5, color: Theme.text) { store.route = .projectSettings(p.id) }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlStroke))
                Button { store.openProject(p.id) } label: {
                    HStack(spacing: 8) {
                        Text("Open Workspace").font(Typo.ui(12.5, .semibold))
                        Text("↩").font(Typo.ui(10.5)).opacity(0.55)
                    }
                    .foregroundStyle(Theme.onAccent).padding(.horizontal, 14).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 9).fill(accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            askBox(p)
        }
        .island()
    }

    /// Running pipelines, named; click shows them on GitHub.
    private func pipelinePill(_ p: Project) -> some View {
        let runs = ([p.id] + store.children(of: p.id).map(\.id)).flatMap { id -> [GitHubRun] in
            guard case .ready(_, _, let r) = store.github[id] ?? .loading else { return [] }
            return r.filter { $0.result == .running }
        }
        return Button { if let u = runs.first.flatMap({ URL(string: $0.url) }), u.scheme == "https" { NSWorkspace.shared.open(u) } } label: {
            HStack(spacing: 6) {
                PipelineBadge(count: runs.count, label: false)
                Text(runs.count == 1 ? "\(runs[0].workflowName) running" : "\(runs.count) pipelines running").font(Typo.ui(11, .semibold))
            }
            .foregroundStyle(Theme.amber)
            .padding(.horizontal, 8).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.amber.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(runs.map { "\($0.workflowName) · \($0.headBranch) · \($0.displayTitle)" }.joined(separator: "\n"))
    }

    // MARK: Ask box

    private var agents: [AgentConfig] { store.enabledAgents }
    private var agent: AgentConfig? {
        agents.first { $0.id == agentID } ?? store.agent(project.agentID) ?? store.agent(store.settings.defaultAgent) ?? agents.first
    }

    private func askBox(_ p: Project) -> some View {
        HStack(spacing: 10) {
            AgentMark(agent: agent, size: 15)
            TextField("What should an agent do in \(p.name)?  e.g. “add tests for the checkout form”", text: $prompt)
                .textFieldStyle(.plain).font(Typo.ui(13)).foregroundStyle(Theme.text)
                .onSubmit(start)
                .accessibilityLabel("Ask an agent to work on \(p.name)")
            ForEach(refs, id: \.self) { r in
                let linked = !r.contains(".") && !r.contains("/")
                Button { refs.removeAll { $0 == r } } label: {
                    Text("@ \(r)").font(Typo.ui(11)).foregroundStyle(linked ? Theme.blue : Theme.text2)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(linked ? Theme.blue.opacity(0.10) : Color.white(0.05)))
                }
                .buttonStyle(.plain)
                .help("Remove @\(r)")
            }
            MenuButton(items: { attachMenu(p) }) {
                Text("@").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text3).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .accessibilityLabel("Attach a file, server, container or database")
            if agents.count > 1 {
                SegmentedControl(options: agents.map { ($0.id, $0.name) }, selection: Binding(get: { agent?.id ?? "" }, set: { agentID = $0 }), height: 24, fontSize: 11.5)
                    .fixedSize()
            }
            Button(action: start) {
                HStack(spacing: 6) {
                    Text("Start").font(Typo.ui(12, .semibold))
                    Text("⌘↩").font(Typo.ui(10.5)).opacity(0.5)
                }
                .foregroundStyle(Color(hex: 0x09090B)).padding(.horizontal, 12).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0xF4F4F5)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(agent == nil)
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.input))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.white(0.09)))
        .padding(.horizontal, 16).padding(.bottom, 14)
    }

    private func attachMenu(_ p: Project) -> [MenuSpec] {
        var items: [MenuSpec] = []
        let ws = store.workspace(for: p.id)
        let files = Array(Set(ws.state.openFiles + store.library.recentFiles.filter { $0.project == p.id }.map(\.path))).sorted().prefix(12)
        if !files.isEmpty {
            items.append(.header("Files"))
            items += files.map { f in MenuSpec(title: f) { add(f) } }
        }
        let linked = store.linkedHosts(p.id).map(\.name) + store.linkedDocker(p.id).map(\.name) + store.linkedStacks(p.id).map(\.name) + store.linkedDatabases(p.id).map(\.name)
        if !linked.isEmpty {
            items += [.separator, .header("Linked")]
            items += linked.map { n in MenuSpec(title: n) { add(n) } }
        }
        if items.isEmpty { items.append(MenuSpec(title: "Open a file or link a server first", enabled: false) {}) }
        return items
    }

    private func add(_ r: String) { if !refs.contains(r) { refs.append(r) } }

    /// Starts the chosen agent with the prompt and opens the workspace on it.
    private func start() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let a = agent, !text.isEmpty else { return }
        guard store.isInstalled(a) || project.isSample else { store.installAgent(a); return }
        let full = (refs.map { "@\($0)" } + [text]).joined(separator: " ")
        store.openProject(project.id)
        guard let s = store.newAgentSession(project: project.id, agent: a) else { return }
        store.workspace(for: project.id).focus(session: s.id)
        prompt = ""
        refs = []
        Task {
            // Give the CLI a moment to start before typing into it.
            if s.isLive { try? await Task.sleep(nanoseconds: 2_500_000_000) }
            store.sendInput(s.id, full)
        }
    }
}

// MARK: - Stats

private struct StatsRow: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        let p = project
        HStack(spacing: 6) {
            agentTime(p)
            usage(p)
            commits(p)
            build(p)
            tree(p)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func agentTime(_ p: Project) -> some View {
        let secs = Int(store.agentSecondsToday(p.id))
        let n = store.sessionsToday(p.id)
        return StatTile(label: "Agent time today", value: secs >= 3600 ? "\(secs / 3600)h \(secs % 3600 / 60)m" : "\(secs / 60)m",
                        sub: "\(n) session\(n == 1 ? "" : "s")", bars: store.week("agent", p.id), color: Theme.orange)
    }

    @ViewBuilder private func usage(_ p: Project) -> some View {
        let shown = store.settings.agents.filter { $0.enabled && !(store.agentUsage[$0.id] ?? []).isEmpty }
        if let a = shown.first, let windows = store.agentUsage[a.id], let top = windows.max(by: { $0.percent < $1.percent }) {
            let others = windows.filter { $0.label != top.label }.map { "\($0.label) \(Int($0.percent))%" }
            StatTile(label: "\(a.name.components(separatedBy: " ").first ?? a.name) usage", value: "\(Int(top.percent))%",
                     sub: (["of \(top.label) limit"] + others).joined(separator: " · "), bars: store.week("usage", a.id),
                     color: top.percent >= 90 ? Theme.red : top.percent >= 70 ? Theme.amber : Theme.orange,
                     valueColor: top.percent >= 90 ? Theme.red : top.percent >= 70 ? Theme.amber : Theme.text)
                .help(shown.map { AgentUsageChips.tip($0, store.agentUsage[$0.id] ?? []) }.joined(separator: "\n"))
        } else {
            StatTile(label: "Usage", value: "—", sub: "Turn on usage in Agents", bars: [], color: Theme.orange)
        }
    }

    private func commits(_ p: Project) -> some View {
        let week = store.commitWeek(p.id)
        let d = store.dayStats[p.id]
        return StatTile(label: "Commits this week", value: "\(Int(week.reduce(0, +)))",
                        sub: d.map { $0.add + $0.del > 0 ? "+\($0.add) −\($0.del) today" : "none today" } ?? "",
                        bars: week, color: Theme.violet)
    }

    @ViewBuilder private func build(_ p: Project) -> some View {
        let builds = store.builds(p.id).filter { $0.kind == .build || $0.kind == .test }
        if let b = builds.first {
            StatTile(label: "Last \(b.kind == .test ? "test run" : "build")", value: AppStore.duration(b.duration),
                     sub: "\(b.ok ? "Succeeded" : "Failed") · \(RelativeTime.ago(b.date))",
                     bars: builds.prefix(7).reversed().map(\.duration), color: b.ok ? Theme.green : Theme.red, valueColor: b.ok ? Theme.green : Theme.red)
        } else {
            StatTile(label: "Last build", value: "—", sub: "Run one from Run", bars: [], color: Theme.green)
        }
    }

    private func tree(_ p: Project) -> some View {
        let changes = store.git[p.id]?.changes ?? []
        let n = Set(changes.map(\.path)).count
        return StatTile(label: "Working tree", value: "\(n)", sub: changes.first?.name ?? "Clean",
                        bars: store.week("tree", p.id), color: Theme.amber, valueColor: n > 0 ? Theme.amber : Theme.text)
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let sub: String
    let bars: [Double]
    let color: Color
    var valueColor: Color = Theme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
            HStack(alignment: .bottom, spacing: 8) {
                Text(value).font(Typo.ui(18, .semibold)).monospacedDigit().foregroundStyle(valueColor).lineLimit(1).fixedSize()
                Text(sub).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).padding(.bottom, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Sparkline(values: bars, color: color)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .island()
        .accessibilityElement(children: .combine)
    }
}

/// Seven bars, the newest in colour.
private struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        let v = Array((Array(repeating: 0.0, count: max(0, 7 - values.count)) + values).suffix(7))
        let top = max(v.max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<7, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5).fill(i == 6 ? color : Color.white(0.14))
                    .frame(width: 4, height: max(3, (v[i] / top * 22).rounded()))
            }
        }
        .frame(height: 22, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

// MARK: - Agent sessions

private struct SessionsCard: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let history: [AgentHistoryEntry]?
    let stats: [String: TranscriptStats]
    let reload: () -> Void
    @State private var filter = "all"
    @State private var query = ""

    enum RowState { case working, input, done, paused }

    struct Row: Identifiable {
        var id: String
        var agent: AgentConfig?
        var binary: String
        var title: String
        var prompt: String
        var date: Date
        var branch: String
        var stats: TranscriptStats
        var state: RowState
        var live: TerminalSession?
        var entry: AgentHistoryEntry?
    }

    /// Transcripts on disk, with live Brix sessions laid over them (and any not on disk yet).
    private var rows: [Row] {
        let branch = store.git[project.id]?.branch ?? ""
        var out: [Row] = []
        var used = Set<String>()
        for e in history ?? [] {
            let live = store.sessions.first { $0.externalID == e.id && $0.isLive && $0.state != .finished && $0.state != .failed }
            if let live { used.insert(live.id) }
            let s = stats[e.id] ?? TranscriptStats()
            out.append(Row(id: e.id, agent: store.settings.agents.first { $0.binary == e.agent }, binary: e.agent,
                           title: live.map(store.displayTitle) ?? e.displayTitle, prompt: e.firstPrompt ?? "", date: e.lastActivity,
                           branch: e.branch ?? branch, stats: s, state: state(live, edits: !s.files.isEmpty), live: live, entry: e))
        }
        for s in store.sessions where s.projectID == project.id && s.kind == .agent && !used.contains(s.id) {
            var t = TranscriptStats()
            t.files = Set(s.touched.map(\.path))
            t.tools = s.touched.map { _ in .edit }
            t.add = s.touched.reduce(0) { $0 + $1.add }
            t.del = s.touched.reduce(0) { $0 + $1.del }
            let a = store.agent(for: s)
            out.insert(Row(id: s.id, agent: a, binary: a?.binary ?? "", title: store.displayTitle(s), prompt: s.task, date: s.startedAt,
                           branch: branch, stats: t, state: state(s, edits: !t.files.isEmpty), live: s, entry: nil), at: 0)
        }
        return out
    }

    private func state(_ live: TerminalSession?, edits: Bool) -> RowState {
        switch live?.state {
        case .running?: .working
        case .needsInput?: .input
        default: edits ? .done : .paused
        }
    }

    var body: some View {
        let all = rows
        let binaries = Array(Set(all.map(\.binary))).sorted()
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = all.filter { r in
            (filter == "all" || r.binary == filter)
                && (q.isEmpty || r.title.localizedCaseInsensitiveContains(q) || r.prompt.localizedCaseInsensitiveContains(q) || r.branch.localizedCaseInsensitiveContains(q))
        }
        VStack(spacing: 0) {
            CardHeader(title: "Agent sessions", count: history == nil ? nil : (q.isEmpty ? "\(all.count)" : "\(shown.count) of \(all.count)")) {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3)
                    TextField("Search sessions", text: $query).textFieldStyle(.plain).font(Typo.ui(11.5))
                        .onExitCommand { query = "" }
                    if !q.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.text3) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 8).frame(width: 190, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.input))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white(0.06)))
                if binaries.count > 1 {
                    SegmentedControl(options: [("all", "All")] + binaries.map { b in (b, store.settings.agents.first { $0.binary == b }?.name ?? b) },
                                     selection: $filter, height: 22, fontSize: 11)
                }
                IconButton(symbol: "arrow.clockwise", label: "Reload sessions", size: 22, iconSize: 10.5, action: reload)
            }
            if history == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty, !q.isEmpty {
                EmptyState(symbol: "magnifyingglass", message: "No sessions match “\(q)”.")
            } else if shown.isEmpty {
                EmptyState(symbol: "sparkle", message: "No agent sessions in this folder yet. Ask one above.", actionTitle: "Start Agent") {
                    store.startAgent(project: project.id)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        Paged(items: shown) { r in SessionRow(row: r, project: project) }
                    }
                    .padding(6)
                }
                .id(q + filter)
            }
        }
        .frame(maxHeight: .infinity)
        .island()
    }
}

private struct SessionRow: View {
    @Environment(AppStore.self) private var store
    let row: SessionsCard.Row
    let project: Project
    @State private var hovering = false

    var body: some View {
        let r = row
        HStack(spacing: 12) {
            AgentMark(agent: r.agent, size: 13, working: r.state == .working)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(r.binary == "claude" ? Color(hex: 0xE07B53).opacity(0.12) : Color.white(0.07)))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(r.title).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    pill(r.state)
                    Spacer(minLength: 4)
                    Text(when(r)).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                if !r.prompt.isEmpty {
                    Text("“\(r.prompt)”").font(Typo.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
                }
                HStack(spacing: 10) {
                    if !r.branch.isEmpty { Text("⎇ \(r.branch)").font(Typo.mono(11)) }
                    Text(r.stats.files.isEmpty ? "no edits" : "\(r.stats.files.count) file\(r.stats.files.count == 1 ? "" : "s")")
                    if r.stats.add > 0 { Text("+\(r.stats.add.formatted())").font(Typo.mono(11)).foregroundStyle(Theme.green) }
                    if r.stats.del > 0 { Text("−\(r.stats.del.formatted())").font(Typo.mono(11)).foregroundStyle(Theme.red) }
                    Ribbon(tools: r.stats.tools)
                }
                .font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            HStack(spacing: 4) {
                primary(r)
                if r.binary == "claude", r.entry != nil {
                    Button("Fork") { fork(r) }.buttonStyle(GhostButtonStyle()).help("Start a new conversation from this one")
                }
                MenuButton(items: { menu(r) }) {
                    Text("•••").font(Typo.ui(11.5)).foregroundStyle(Theme.text2).padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
                }
                .accessibilityLabel("More actions")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering || r.state == .working ? Color.white(0.05) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(r.state == .working ? Color.white(0.06) : .clear))
        .onHover { hovering = $0 }
    }

    private func pill(_ s: SessionsCard.RowState) -> some View {
        let (text, fg, bg): (String, Color, Color) = switch s {
        case .working: ("Working", Theme.green, Theme.green.opacity(0.12))
        case .input: ("Needs input", Color(hex: 0x09090B), Theme.amber)
        case .done: ("Done", Theme.text2, Color.white(0.06))
        case .paused: ("Paused", Theme.text2, Color.white(0.06))
        }
        return Text(text).font(Typo.ui(10, .semibold)).foregroundStyle(fg).padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(bg))
    }

    private func when(_ r: SessionsCard.Row) -> String {
        if let s = r.live, r.state == .working { return "now · \(RelativeTime.short(s.startedAt))" }
        return "\(RelativeTime.ago(r.date))"
    }

    @ViewBuilder private func primary(_ r: SessionsCard.Row) -> some View {
        if let live = r.live {
            Button("Open") { store.reveal(session: live.id) }
                .buttonStyle(PrimaryRowButtonStyle(waiting: r.state == .input))
        } else {
            Button("Resume") { resume(r) }
                .buttonStyle(PrimaryRowButtonStyle(waiting: false))
                .disabled(r.agent.map { !store.isInstalled($0) } ?? true)
        }
    }

    private func menu(_ r: SessionsCard.Row) -> [MenuSpec] {
        guard let e = r.entry else {
            return [MenuSpec(title: "Open") { if let s = r.live { store.reveal(session: s.id) } },
                    MenuSpec(title: "Close", destructive: true) { if let s = r.live { store.closeSession(s.id) } }]
        }
        return [MenuSpec(title: "Resume in Brix", enabled: r.live == nil) { resume(r) },
                MenuSpec(title: "Copy Session ID") { store.copyToPasteboard(e.id, label: "session id") },
                MenuSpec(title: "Copy Resume Command") { store.copyToPasteboard(e.agent == "codex" ? "codex resume \(e.id)" : "claude --resume \(e.id)", label: "command") },
                MenuSpec(title: "Reveal Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([e.file]) },
                .separator,
                MenuSpec(title: r.live != nil ? "Close it in Brix first to delete" : "Move to Trash…", enabled: r.live == nil, destructive: true) { trash(e) }]
    }

    private func resume(_ r: SessionsCard.Row) {
        guard let a = r.agent, let e = r.entry else { return }
        store.openProject(project.id)
        guard let s = store.newAgentSession(project: project.id, agent: a, resume: e.id) else { return }
        if let i = store.sessions.firstIndex(where: { $0.id == s.id }) {
            store.sessions[i].sessionName = e.title
            store.sessions[i].task = e.firstPrompt ?? ""
        }
    }

    /// A new conversation that starts from this one's history (Claude Code's --fork-session).
    private func fork(_ r: SessionsCard.Row) {
        guard let a = r.agent, let e = r.entry, AgentConfig.isSafeID(e.id) else { return }
        store.openProject(project.id)
        let base = a.command.trimmingCharacters(in: .whitespaces).isEmpty ? a.binary : a.command
        let s = store.newTerminal(project: project.id, title: "\(e.displayTitle) (fork)", kind: .agent, command: "\(base) --resume \(e.id) --fork-session")
        if let i = store.sessions.firstIndex(where: { $0.id == s.id }) { store.sessions[i].agentID = a.id }
    }

    private func trash(_ e: AgentHistoryEntry) {
        store.confirm("Move “\(e.displayTitle)” to the Trash?", "The transcript file goes to the Trash, so it can be restored from there. The agent won't list it any more.", confirm: "Move to Trash") {
            do {
                try FileManager.default.trashItem(at: e.file, resultingItemURL: nil)
                store.toast(.success, "Moved to the Trash")
            } catch {
                store.toast(.error, "Couldn't move the transcript to the Trash", detail: error.localizedDescription)
            }
        }
    }
}

/// One bar per tool call: blue read, amber edit, green test or build, violet shell, red error.
private struct Ribbon: View {
    let tools: [TranscriptStats.Tool]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(tools.enumerated()), id: \.offset) { _, t in
                RoundedRectangle(cornerRadius: 1.5).fill(color(t)).frame(width: 5, height: 10)
            }
        }
        .accessibilityLabel("Tool activity: \(tools.count) calls")
    }
    private func color(_ t: TranscriptStats.Tool) -> Color {
        switch t {
        case .read: Theme.blue
        case .edit: Theme.amber
        case .check: Theme.green
        case .shell: Theme.violet
        case .error: Theme.red
        }
    }
}

private struct PrimaryRowButtonStyle: ButtonStyle {
    let waiting: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.ui(11.5, .semibold))
            .foregroundStyle(waiting ? Color(hex: 0x09090B) : Theme.text)
            .padding(.horizontal, 11).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(waiting ? Theme.amber : Color.white(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(waiting ? .clear : Color.white(0.09)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct GhostButtonStyle: ButtonStyle {
    var filled = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.ui(11.5)).foregroundStyle(Theme.text2)
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(filled || configuration.isPressed ? Color.white(0.05) : .clear))
    }
}

/// Small search box for card headers.
private struct HeaderSearch: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(Typo.ui(11.5))
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.text3) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).frame(width: 190, height: 24)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.input))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white(0.06)))
    }
}

/// The first 10 rows, then 10 more each time the end scrolls into view.
private struct Paged<Item, Row: View>: View {
    let items: [Item]
    var page = 10
    /// Asked for more when the shown rows run out (older commits from git).
    var loadMore: (() -> Void)? = nil
    @ViewBuilder let row: (Item) -> Row
    @State private var shown = 10

    var body: some View {
        ForEach(Array(items.prefix(shown).enumerated()), id: \.offset) { _, item in row(item) }
        if shown < items.count || loadMore != nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 28)
                .onAppear {
                    if shown < items.count { shown += page } else { loadMore?() }
                }
        }
    }
}

// MARK: - Commits

/// Recent commits: who, what, when, lines changed; click opens it in Review.
private struct CommitsCard: View {
    @Environment(AppStore.self) private var store
    let project: Project
    @State private var query = ""
    /// Older history and search results from git, beyond the recent commits git status loads.
    @State private var older: [ProjectID: [GitCommit]] = [:]
    @State private var found: [(GitCommit, Project)]?
    @State private var exhausted: Set<ProjectID> = []
    @State private var loading = false
    @State private var gitError: String?

    private var repos: [Project] { (store.git[project.id]?.isRepo == true ? [project] : []) + store.children(of: project.id) }

    var body: some View {
        let g = store.git[project.id]
        // A folder of repositories shows all their commits together, each tagged with its repo.
        let kids = store.children(of: project.id)
        var seen = Set<String>()
        let merged: [(GitCommit, Project)] = repos.flatMap { r in ((store.git[r.id]?.commits ?? []) + (older[r.id] ?? [])).map { ($0, r) } }
            .filter { seen.insert($0.0.hash).inserted }
            .sorted { $0.0.date > $1.0.date }
        let q = query.trimmingCharacters(in: .whitespaces)
        let commits = q.isEmpty ? merged : (found ?? merged.filter { $0.0.message.localizedCaseInsensitiveContains(q) || $0.0.author.localizedCaseInsensitiveContains(q) || $0.0.hash.hasPrefix(q) })
        VStack(spacing: 0) {
            CardHeader(title: "Commits") {
                if let g, g.isRepo {
                    Text("\(g.branch)\(g.ahead > 0 ? " · \(g.ahead) to push" : "")\(g.behind > 0 ? " · \(g.behind) to pull" : "")")
                        .font(Typo.mono(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
                HeaderSearch(placeholder: "Search commits", text: $query)
                if let g, g.isRepo {
                    let staged = g.staged.count
                    Button { store.openProject(project.id); store.workspace(for: project.id).layout.centre = .review } label: {
                        Text(g.changes.isEmpty ? "Review" : "Commit \(staged > 0 ? "\(staged) staged" : "\(g.changedFileCount) changes")…")
                            .font(Typo.ui(11.5, .semibold)).foregroundStyle(g.changes.isEmpty ? Theme.text2 : Theme.onAccent)
                            .padding(.horizontal, 9).frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(g.changes.isEmpty ? Color.white(0.06) : Theme.amber))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let gitError {
                Text(gitError).font(Typo.ui(11)).foregroundStyle(Theme.amber).lineLimit(2)
                    .padding(.horizontal, 14).padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            if g?.isRepo != true && kids.isEmpty {
                EmptyState(symbol: "arrow.triangle.branch", message: "Not a git repository.")
            } else if commits.isEmpty {
                EmptyState(symbol: q.isEmpty ? "circle.circle" : "magnifyingglass", message: q.isEmpty ? "No commits yet." : (loading ? "Searching…" : "No commits match “\(q)”."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Paged(items: commits, loadMore: q.isEmpty && !repos.allSatisfy({ exhausted.contains($0.id) }) ? { Task { await loadOlder() } } : nil) { item in
                            row(item.0, repo: item.1)
                        }
                    }
                    .padding(6)
                }
                .id(q)
            }
        }
        .frame(maxHeight: .infinity)
        .island()
        .task(id: query) { await search(query.trimmingCharacters(in: .whitespaces)) }
    }

    /// The next 50 commits of each repository's history.
    private func loadOlder() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        for r in repos where !exhausted.contains(r.id) && !r.isSample {
            let have = (store.git[r.id]?.commits.count ?? 0) + (older[r.id]?.count ?? 0)
            let out: ProcessOutput
            do {
                out = try await ProcessRunner.run("git", ["-C", r.expandedPath, "log", "--skip", "\(have)", "-n", "50", "--format=%H%x1f%an%x1f%at%x1f%s%x1e"], timeout: 15)
            } catch {
                gitError = "Couldn't load older commits in \(r.name): \(error.localizedDescription)"
                exhausted.insert(r.id)
                continue
            }
            // An empty repository answers with an error and no output; that's simply the end.
            guard out.ok else {
                if !out.stdout.isEmpty || !out.stderr.lowercased().contains("does not have any commits") {
                    gitError = "Couldn't load older commits in \(r.name): \(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
                exhausted.insert(r.id)
                continue
            }
            let page = LiveGitService.parseLog(out.stdout)
            older[r.id, default: []] += page
            if page.count < 50 { exhausted.insert(r.id) }
        }
        if repos.allSatisfy({ $0.isSample }) { repos.forEach { exhausted.insert($0.id) } }
    }

    /// Searches the whole history: message, author and hash.
    private func search(_ q: String) async {
        // The previous query's results never show under the new one.
        found = nil
        gitError = nil
        guard !q.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        var hits: [(GitCommit, Project)] = []
        for r in repos where !r.isSample {
            let fmt = "--format=%H%x1f%an%x1f%at%x1f%s%x1e"
            async let byMessage = ProcessRunner.run("git", ["-C", r.expandedPath, "log", "-i", "--fixed-strings", "--grep", q, "-n", "100", fmt], timeout: 15)
            async let byAuthor = ProcessRunner.run("git", ["-C", r.expandedPath, "log", "-i", "--fixed-strings", "--author", q, "-n", "100", fmt], timeout: 15)
            do {
                for out in [try await byMessage, try await byAuthor] {
                    guard out.ok else { gitError = "Search failed in \(r.name): \(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"; continue }
                    hits += LiveGitService.parseLog(out.stdout).map { ($0, r) }
                }
            } catch {
                gitError = "Search failed in \(r.name): \(error.localizedDescription)"
            }
        }
        guard !Task.isCancelled, query.trimmingCharacters(in: .whitespaces) == q else { return }
        var seen = Set<String>()
        let local = repos.flatMap { r in (store.git[r.id]?.commits ?? []).map { ($0, r) } }
            .filter { $0.0.message.localizedCaseInsensitiveContains(q) || $0.0.author.localizedCaseInsensitiveContains(q) || $0.0.hash.hasPrefix(q) }
        found = (hits + local).filter { seen.insert($0.0.hash).inserted }.sorted { $0.0.date > $1.0.date }
    }

    private func row(_ c: GitCommit, repo: Project) -> some View {
        Button {
            store.openProject(repo.id)
            let ws = store.workspace(for: repo.id)
            ws.selectedCommit = c.hash
            ws.layout.centre = .review
        } label: {
            HStack(spacing: 10) {
                Circle().strokeBorder(c.isPushed ? Theme.violet : Theme.amber, lineWidth: 1.5).frame(width: 9, height: 9)
                    .help(c.isPushed ? "Pushed" : "Not pushed yet")
                if repo.id != project.id {
                    Text(repo.name).font(Typo.ui(10.5, .semibold)).foregroundStyle(repo.hue.color)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(repo.hue.color.opacity(0.12)))
                }
                Text(c.message).font(Typo.ui(12.5)).foregroundStyle(Theme.text).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(c.author).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                Text(c.short).font(Typo.mono(10.5)).foregroundStyle(Theme.text3)
                Text(RelativeTime.short(c.date)).font(Typo.ui(11)).foregroundStyle(Theme.meta).frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, 8).frame(height: 30)
            .rowBackground(selected: false, radius: 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Right column

private struct RunCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let project: Project
    let tasks: [RunTask]

    var body: some View {
        VStack(spacing: 0) {
            CardHeader(title: "Run") {
                Text(tasks.isEmpty ? "nothing detected" : "detected in the project folder").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
            }
            VStack(spacing: 2) {
                if tasks.isEmpty {
                    Text("No build, test or run scripts found (build.sh, package.json, Makefile, Cargo, Go, Swift, Xcode, Compose).")
                        .font(Typo.ui(12)).foregroundStyle(Theme.text3).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(tasks.enumerated()), id: \.element.id) { i, t in row(t, first: i == 0) }
            }
            .padding(6)
        }
        .island()
    }

    private func row(_ t: RunTask, first: Bool) -> some View {
        let last = store.builds(project.id).first { $0.task == t.name }
        let running = store.runningTasks.values.contains { $0.project == project.id && $0.task == t }
        return HStack(spacing: 9) {
            Button { store.run(t, in: project.id) } label: {
                Image(systemName: "play.fill").font(.system(size: 8.5)).foregroundStyle(first ? Theme.onAccent : Theme.text)
                    .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 6).fill(first ? accent : Color.white(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Run \(t.name)")
            Text(t.name).font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Text(t.command).font(Typo.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if running { Text("running…").foregroundStyle(Theme.green) }
                else if let last { Text(last.ok ? "\(AppStore.duration(last.duration)) ✓" : "failed").foregroundStyle(last.ok ? Theme.green : Theme.red) }
                else { Text(t.kind == .run ? "" : "never run").foregroundStyle(Theme.meta) }
            }
            .font(Typo.ui(11))
        }
        .padding(.leading, 8).padding(.trailing, 6).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7).fill(first ? Color.white(0.04) : .clear))
        .help(t.command)
    }
}

/// Open pull requests and recent pipeline runs from GitHub, through the user's own `gh`.
/// A folder of repositories shows all of theirs together.
private struct GitHubCard: View {
    @Environment(AppStore.self) private var store
    let project: Project
    @State private var tab = "prs"

    private var kids: [Project] { store.children(of: project.id) }

    /// This project's GitHub, or its nested repositories' merged (each row tagged).
    private var state: GitHubState {
        if kids.isEmpty { return store.github[project.id] ?? .loading }
        var prs: [GitHubPR] = [], runs: [GitHubRun] = []
        var repos: [String] = []
        var failure: GitHubState?
        for c in kids {
            let st = store.github[c.id] ?? .loading
            if case .failed = st { failure = failure ?? st }
            guard case .ready(let repo, let p, let r) = st else { continue }
            repos.append(repo); prs += p; runs += r
        }
        if repos.isEmpty {
            if let failure { return failure }
            return kids.contains { if case .loading = store.github[$0.id] ?? .loading { true } else { false } } ? .loading : .noRepo
        }
        return .ready(repo: repos.count == 1 ? repos[0] : "\(repos.count) repositories", prs: prs.sorted { $0.updatedAt > $1.updatedAt }, runs: runs.sorted { $0.createdAt > $1.createdAt })
    }

    var body: some View {
        let state = state
        VStack(spacing: 0) {
            CardHeader(title: "GitHub", count: count(state)) {
                if case .ready(let repo, _, _) = state {
                    Text(repo).font(Typo.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                        .help(project.githubAccountSeen.map { "Read as \($0)" } ?? repo)
                }
                Spacer(minLength: 0)
                if case .ready(let repo, let prs, let runs) = state {
                    SegmentedControl(options: [("prs", "PRs \(prs.count)"), ("runs", "Pipelines \(runs.count)")], selection: $tab, height: 22, fontSize: 11)
                        .fixedSize()
                    if kids.isEmpty {
                        IconButton(symbol: "arrow.up.right.square", label: "Open on GitHub", size: 22, iconSize: 10.5) { open("https://github.com/\(repo)\(tab == "runs" ? "/actions" : "/pulls")") }
                    }
                }
                IconButton(symbol: "arrow.clockwise", label: "Refresh", size: 22, iconSize: 10.5) { Task { await load() } }
            }
            if let warning = warning {
                Text(warning).font(Typo.ui(11)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            content(state).padding(6)
        }
        .island()
        .task(id: project.id) { await load() }
    }

    /// Stale or missing data, said out loud: this project's last refresh, or any
    /// nested repository whose refresh failed.
    private var warning: String? {
        let ids = [project.id] + kids.map(\.id)
        let bad = ids.compactMap { id -> (String, String)? in
            let why: String?
            if case .failed(let w) = store.githubErrors[id] ?? .loading { why = w }
            else if !kids.isEmpty, case .failed(let w) = store.github[id] ?? .loading { why = w }
            else { why = nil }
            return why.map { (store.project(id)?.name ?? id, $0) }
        }
        guard let first = bad.first else { return nil }
        if kids.isEmpty { return "Last refresh failed: \(first.1). Showing what was loaded before." }
        return bad.count == 1 ? "\(first.0) couldn't be read: \(first.1)" : "\(bad.count) repositories couldn't be read (\(bad.map(\.0).joined(separator: ", "))). \(first.1)"
    }

    private func count(_ state: GitHubState) -> String? {
        if case .ready(_, let prs, _) = state { return "\(prs.count)" }
        return nil
    }

    private func load() async {
        for id in [project.id] + kids.map(\.id) { await store.refreshGitHub(id) }
    }

    @ViewBuilder private func content(_ state: GitHubState) -> some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 44)
        case .notInstalled:
            message("Install the GitHub CLI to see pull requests and pipelines.", action: "Install gh") { terminal("brew install gh && gh auth login") }
        case .signedOut:
            message("Sign in to GitHub with the GitHub CLI. Brix uses that sign-in and only reads.", action: "Sign In") { store.customizeTab = "accounts"; store.go(.customize) }
        case .noRepo:
            message("No GitHub remote in this repo. Set one in Project Settings.", action: "Set Repository") {
                store.projectSettingsSection = "General"; store.route = .projectSettings(project.id)
            }
        case .failed(let why):
            message("Couldn't read GitHub: \(why)", action: "Retry") { Task { await load() } }
        case .ready(_, let prs, let runs):
            VStack(spacing: 1) {
                if tab == "runs" {
                    if runs.isEmpty { empty("No workflow runs.") }
                    ForEach(runs.prefix(8)) { run($0) }
                } else {
                    if prs.isEmpty { empty("No open pull requests.") }
                    ForEach(prs.prefix(8)) { pr($0) }
                }
            }
        }
    }

    private func message(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(Typo.ui(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            SubtleButton(title: action, height: 26, action: perform)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Typo.ui(12)).foregroundStyle(Theme.text3).padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pr(_ p: GitHubPR) -> some View {
        let (icon, color): (String, Color) = switch p.checks {
        case .passing: ("checkmark.circle.fill", Theme.green)
        case .failing: ("xmark.circle.fill", Theme.red)
        case .pending: ("circle.dotted", Theme.amber)
        case .none: ("circle", Theme.text3)
        }
        return Button { open(p.url) } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color).frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("#\(p.number)").font(Typo.mono(11)).foregroundStyle(Theme.text3)
                        Text(p.title).font(Typo.ui(12.5, .medium)).foregroundStyle(p.isDraft ? Theme.text2 : Theme.text).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(p.headRefName).font(Typo.mono(10.5))
                        if p.isDraft { Text("Draft") }
                        if let r = review(p.reviewDecision) { Text(r.0).foregroundStyle(r.1) }
                        if let a = p.author?.login { Text(a) }
                        Text(RelativeTime.ago(p.updatedAt))
                    }
                    .font(Typo.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8).frame(height: 40)
            .rowBackground(selected: false, radius: 7)
        }
        .buttonStyle(.plain)
        .help("Open #\(p.number) on GitHub")
    }

    private func review(_ d: String?) -> (String, Color)? {
        switch d {
        case "APPROVED": ("Approved", Theme.green)
        case "CHANGES_REQUESTED": ("Changes requested", Theme.red)
        case "REVIEW_REQUIRED": ("Review required", Theme.amber)
        default: nil
        }
    }

    private func run(_ r: GitHubRun) -> some View {
        let (icon, color): (String, Color) = switch r.result {
        case .running: ("circle.dotted", Theme.amber)
        case .passed: ("checkmark.circle.fill", Theme.green)
        case .failed: ("xmark.circle.fill", Theme.red)
        case .other: ("minus.circle", Theme.text3)
        }
        let took = r.updatedAt.timeIntervalSince(r.createdAt)
        return Button { open(r.url) } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color).frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(r.workflowName).font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(r.displayTitle).font(Typo.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(r.headBranch).font(Typo.mono(10.5))
                        Text(r.event.replacingOccurrences(of: "_", with: " "))
                        Text(r.result == .running ? "running" : AppStore.duration(took))
                        Text(RelativeTime.ago(r.createdAt))
                    }
                    .font(Typo.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8).frame(height: 40)
            .rowBackground(selected: false, radius: 7)
        }
        .buttonStyle(.plain)
        .help("Open this run on GitHub")
    }

    private func open(_ url: String) {
        if let u = URL(string: url), u.scheme == "https" { NSWorkspace.shared.open(u) }
    }

    private func terminal(_ cmd: String) {
        let s = store.newTerminal(project: nil, title: "GitHub sign-in", command: cmd + "; exec \"$SHELL\" -l", attach: false)
        store.route = .terminals
        store.focusedSessionID = s.id
    }
}

/// The repositories inside a multi-repo project, each one click from its own overview.
private struct RepositoriesCard: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        let kids = store.children(of: project.id)
        VStack(spacing: 0) {
            CardHeader(title: "Repositories", count: "\(kids.count)") {
                Spacer(minLength: 0)
                Button("Find Again") { Task { await store.discoverSubProjects(project.id) } }.buttonStyle(GhostButtonStyle())
            }
            VStack(spacing: 2) {
                ForEach(kids) { c in
                    let g = store.git[c.id]
                    let agents = store.sessions.filter { $0.projectID == c.id && $0.kind == .agent && ($0.state == .running || $0.state == .needsInput) }.count
                    Button { store.route = .projectHome(c.id) } label: {
                        HStack(spacing: 10) {
                            ProjectMark(project: c, size: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                Text([g?.branch.isEmpty == false ? "⎇ \(g!.branch)" : nil, c.framework.isEmpty ? c.language : c.framework].compactMap { $0 }.joined(separator: " · "))
                                    .font(Typo.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if agents > 0 { Text("\(agents) agent\(agents == 1 ? "" : "s")").font(Typo.ui(10.5, .semibold)).foregroundStyle(Theme.green) }
                            let n = g?.changedFileCount ?? 0
                            if n > 0 { Text("±\(n)").font(Typo.mono(10.5, .semibold)).foregroundStyle(Theme.amber) }
                            if let g, g.ahead > 0 { Text("↑\(g.ahead)").font(Typo.mono(10.5)).foregroundStyle(Theme.text3) }
                        }
                        .padding(.horizontal, 8).frame(height: 40)
                        .rowBackground(selected: false, radius: 7)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .island()
    }
}

private struct ConnectionsCard: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        let p = project
        let hosts = store.linkedHosts(p.id), dbs = store.linkedDatabases(p.id), containers = store.linkedDocker(p.id), stacks = store.linkedStacks(p.id)
        let total = hosts.count + dbs.count + containers.count + stacks.count
        VStack(spacing: 0) {
            CardHeader(title: "Connections", count: "\(total)") {
                Spacer(minLength: 0)
                Button("+ Attach") { store.route = .projectSettings(p.id) }.buttonStyle(GhostButtonStyle())
            }
            VStack(spacing: 2) {
                if total == 0 {
                    Text("Nothing attached. Attach servers, containers and databases so agents and panels know about them.")
                        .font(Typo.ui(12)).foregroundStyle(Theme.text3).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(hosts) { h in
                    let st = store.hostStatus[h.id] ?? .disconnected
                    row(AnyView(ServerOSIcon(host: h, size: 28)), h.name, "\(h.address)\(store.hostMetrics[h.id].map { " · up \($0.uptime)" } ?? "")", st.color, h.tag, "Shell") {
                        store.guardProduction(h.tag, name: h.name, verb: "Open a shell on") { store.openProject(p.id); store.connect(h.id, project: p.id) }
                    }
                }
                ForEach(stacks) { s in
                    row(AnyView(LogoBadge(logo: "Logos/docker", color: Theme.blue, size: 28)), s.name, "docker compose · \(s.hostID.flatMap(store.host)?.name ?? "local")",
                        s.isRunning ? Theme.green : Theme.disabled, nil, "Logs") { store.openComposeLogs(s) }
                }
                ForEach(containers) { c in
                    row(AnyView(LogoBadge(logo: "Logos/docker", color: Theme.blue, size: 28)), c.name, "\(c.image)\(c.ports.isEmpty ? "" : " · \(c.ports)")",
                        c.state == .running ? Theme.green : Theme.disabled, nil, "Logs") { store.openProject(p.id); store.openDockerLogs(c.id, project: p.id) }
                }
                ForEach(dbs) { d in
                    row(AnyView(DatabaseIcon(db: d, size: 28)), d.name, d.endpoint, (store.dbStatus[d.id] ?? .disconnected).color, d.tag, "Open") {
                        store.selectedDatabase = d.id; store.go(.databases)
                    }
                }
            }
            .padding(6)
        }
        .island()
    }

    private func row(_ icon: AnyView, _ name: String, _ sub: String, _ dot: Color, _ tag: EnvTag?, _ action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(name).font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Circle().fill(dot).frame(width: 6, height: 6)
                    if let tag { TagPill(tag: tag, size: 9, filled: false) }
                }
                Text(sub).font(Typo.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action, action: perform).buttonStyle(GhostButtonStyle(filled: true))
        }
        .padding(.leading, 8).padding(.trailing, 6).frame(height: 44)
    }
}

private struct InstructionsCard: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let scan: ProjectScan?
    let reload: () -> Void

    var body: some View {
        let files = scan?.aiFiles ?? []
        VStack(spacing: 0) {
            CardHeader(title: "AI instructions", count: scan == nil ? nil : "\(files.count)") { Spacer(minLength: 0) }
            if scan == nil {
                ProgressView().frame(height: 60)
            } else if files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No CLAUDE.md or AGENTS.md yet. A short rules file saves tokens on every agent session.")
                        .font(Typo.ui(12)).foregroundStyle(Theme.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    if !project.isSample {
                        HStack(spacing: 6) {
                            Button { generate() } label: {
                                Text("✳ Generate from repo").font(Typo.ui(12, .semibold)).foregroundStyle(Color(hex: 0xF0A07E))
                                    .padding(.horizontal, 11).frame(height: 28)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xE07B53).opacity(0.12)))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0xE07B53).opacity(0.3)))
                            }
                            .buttonStyle(.plain)
                            SubtleButton(title: "Blank CLAUDE.md", height: 28) { blank() }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 1) {
                    ForEach(files) { f in
                        Button { open(f.path) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: f.count == nil ? "doc.text" : "folder").font(.system(size: 11)).foregroundStyle(Theme.violet).frame(width: 16)
                                Text(f.path).font(Typo.mono(11.5)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(f.count.map { "\($0) · \(f.label)" } ?? f.label).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                            }
                            .padding(.horizontal, 8).frame(height: 28)
                            .rowBackground(selected: false, radius: 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
        }
        .island()
    }

    /// An agent reads the repo and writes the rules file itself.
    private func generate() {
        let prompt = "Read this repository and write a concise CLAUDE.md at the root: how to build, test and run it, the layout, and the conventions an agent must follow. Keep it under 80 lines."
        store.openProject(project.id)
        store.startAgent(project: project.id) { s in
            let ws = store.workspace(for: project.id)
            ws.attach(session: s, preferAgentGrid: true)
            ws.focus(session: s.id)
            Task {
                if s.isLive { try? await Task.sleep(nanoseconds: 2_500_000_000) }
                store.sendInput(s.id, prompt)
            }
        }
    }

    private func blank() {
        let url = project.url.appendingPathComponent("CLAUDE.md")
        do {
            try "# \(project.name)\n\nNotes for coding agents working in this project.\n".write(to: url, atomically: true, encoding: .utf8)
            reload()
            open("CLAUDE.md")
        } catch {
            store.toast(.error, "Couldn't create CLAUDE.md", detail: error.localizedDescription)
        }
    }

    private func open(_ path: String) {
        var isDir: ObjCBool = false
        let full = project.url.appendingPathComponent(path)
        FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir)
        if isDir.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([full])
        } else {
            store.openProject(project.id)
            store.workspace(for: project.id).open(path)
        }
    }
}

private struct CodebaseCard: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let stats: CodebaseStats?

    var body: some View {
        VStack(spacing: 0) {
            CardHeader(title: "Codebase") {
                Spacer(minLength: 0)
                if let s = stats { Text("\(s.files.formatted()) files · \(TowerCaption.short(s.lines)) lines").font(Typo.ui(11)).foregroundStyle(Theme.text3) }
            }
            if let s = stats {
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(s.langs, id: \.name) { l in
                                Rectangle().fill(l.color).frame(width: max(2, (geo.size.width - CGFloat(s.langs.count - 1) * 2) * l.share))
                            }
                        }
                    }
                    .frame(height: 6).clipShape(Capsule())
                    HStack(spacing: 12) {
                        ForEach(s.langs, id: \.name) { l in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2).fill(l.color).frame(width: 6, height: 6)
                                Text("\(l.name) \(Int((l.share * 100).rounded()))%")
                            }
                            .font(Typo.ui(11)).foregroundStyle(Theme.text2)
                        }
                    }
                    .lineLimit(1)
                    if s.langs.isEmpty { Text("No source files recognised.").font(Typo.ui(12)).foregroundStyle(Theme.text3) }
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            } else {
                ProgressView().frame(height: 50)
            }
            recent
        }
        .island()
    }

    @ViewBuilder private var recent: some View {
        let changes = Array((store.git[project.id]?.changes ?? []).prefix(5))
        if !changes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Recently changed").font(Typo.ui(10.5, .semibold)).foregroundStyle(Theme.text3).padding(.horizontal, 8).padding(.vertical, 4)
                ForEach(changes) { c in
                    let agent = store.sessions.first { s in s.projectID == project.id && s.kind == .agent && s.touched.contains { $0.path.hasSuffix(c.path) || c.path.hasSuffix($0.path) } }
                    HStack(spacing: 8) {
                        Text(c.status.rawValue).font(Typo.mono(10, .bold)).foregroundStyle(c.status.color).frame(width: 12)
                        Text(c.name).font(Typo.ui(12.5)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(c.dir).font(Typo.ui(11)).foregroundStyle(Theme.meta).lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
                        Text(agent.map { store.displayTitle($0) } ?? "You").font(Typo.ui(10.5)).foregroundStyle(agent == nil ? Theme.text3 : Theme.orange).lineLimit(1)
                    }
                    .padding(.horizontal, 8).frame(height: 26)
                    .contentShape(Rectangle())
                    .onTapGesture { store.openProject(project.id); store.workspace(for: project.id).open(c.path) }
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 6).padding(.top, 2)
        }
    }
}

private enum TowerCaption {
    static func short(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
}

/// Island header from the design: 36pt, small caps title, optional count.
private struct CardHeader<Trailing: View>: View {
    let title: String
    var count: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Typo.ui(11, .semibold)).tracking(0.44).foregroundStyle(Theme.text2)
            if let count {
                Text(count).font(Typo.ui(10, .semibold)).foregroundStyle(Theme.text2).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white(0.06)))
            }
            trailing()
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .frame(height: 36)
        .hairlineBottom()
    }
}

extension CardHeader where Trailing == Spacer {
    init(title: String, count: String? = nil) {
        self.init(title: title, count: count) { Spacer(minLength: 0) }
    }
}
