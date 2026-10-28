import SwiftUI

/// The Brix buddy's mood on the build site: waiting beats shipped beats working beats idle.
enum BuddyMood: String, CaseIterable { case working, waiting, shipped, idle }

extension AppStore {
    // MARK: Recording

    func record(_ e: ActivityEvent) {
        // The same thing again within a minute (a quick restart, a repeated edit) is one event.
        if let last = library.activity.first, last.kind == e.kind, last.projectID == e.projectID, last.text == e.text,
           e.date.timeIntervalSince(last.date) < 60 { return }
        library.activity.insert(e, at: 0)
        if library.activity.count > 400 { library.activity.removeLast(library.activity.count - 400) }
    }

    /// Every event for one project (or all), newest first: Brix's own log, sample
    /// history and git commits, merged.
    func events(project id: ProjectID? = nil, limit: Int = 60) -> [ActivityEvent] {
        let projects = id.flatMap(project).map { [$0] } ?? library.projects
        let ids = Set(projects.map(\.id))
        // "resumed a session" rows from older builds are noise; leave them out.
        var out = library.activity.filter { ($0.kind != .start || $0.text != "resumed a session") && (id == nil || $0.projectID.map(ids.contains) == true) }
        for p in projects {
            out += svc(p).activity.events(p)
            for c in (git[p.id]?.commits ?? []).prefix(12) where c.date > Date().addingTimeInterval(-3 * 86_400) {
                out.append(ActivityEvent(date: c.date, kind: .commit, projectID: p.id, actor: c.author.isEmpty ? "You" : c.author,
                                         text: "committed", target: "“\(c.message)”", meta: c.short, ref: c.hash))
            }
        }
        return Array(out.sorted { $0.date > $1.date }.prefix(limit))
    }

    // MARK: Agent time

    /// Seconds agents spent working, per project and day.
    func addAgentTime(_ project: ProjectID?, _ seconds: TimeInterval) {
        guard let project, seconds > 0 else { return }
        library.daily[Self.dayKey("agent", project, Date()), default: 0] += min(seconds, 8 * 3600)
    }

    /// Called whenever an agent's state changes, to count working time.
    func trackAgentTime(_ s: TerminalSession, from old: SessionState, to new: SessionState) {
        if new == .running, old != .running { runningSince[s.id] = Date() }
        if old == .running, new != .running {
            addAgentTime(s.projectID, Date().timeIntervalSince(runningSince.removeValue(forKey: s.id) ?? s.startedAt))
        }
    }

    /// Agent sessions started today: counted when they start, so the capped
    /// activity log trimming old events never lowers it.
    func sessionsToday(_ project: ProjectID? = nil) -> Int {
        let ids = project.map { [$0] } ?? library.projects.map(\.id)
        let counted = ids.reduce(0.0) { $0 + (library.daily[Self.dayKey("sessions", $1, Date())] ?? 0) }
        // Sample sessions are not started through Brix today, so they count as they stand.
        let sample = sessions.filter { $0.kind == .agent && $0.isSampleSession && (project == nil || $0.projectID == project) }.count
        return Int(counted) + sample
    }

    func agentSecondsToday(_ project: ProjectID? = nil) -> TimeInterval {
        let ids = project.map { [$0] } ?? library.projects.map(\.id)
        let stored = ids.reduce(0.0) { $0 + (library.daily[Self.dayKey("agent", $1, Date())] ?? 0) }
        let live = sessions.filter { $0.kind == .agent && $0.state == .running && $0.isLive && (project == nil || $0.projectID == project) }
            .reduce(0.0) { $0 + Date().timeIntervalSince(runningSince[$1.id] ?? $1.startedAt) }
        return stored + live
    }

    static func dayKey(_ metric: String, _ id: String, _ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%@|%@|%04d-%02d-%02d", metric, id, c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Seven daily values, oldest first.
    func week(_ metric: String, _ id: String) -> [Double] {
        if let p = project(id), let s = svc(p).activity.series(metric, p) { return s }
        return (0..<7).reversed().map { back in
            let d = Calendar.current.date(byAdding: .day, value: -back, to: Date()) ?? Date()
            var v = library.daily[Self.dayKey(metric, id, d)] ?? 0
            if metric == "agent", back == 0 { v = agentSecondsToday(id) }
            return v
        }
    }

    func recordDailyMax(_ metric: String, _ id: String, _ value: Double) {
        let k = Self.dayKey(metric, id, Date())
        if value > library.daily[k] ?? -1 { library.daily[k] = value }
    }

    /// Commits per day this week, oldest first.
    func commitWeek(_ id: ProjectID) -> [Double] {
        let cal = Calendar.current
        let commits = git[id]?.commits ?? []
        return (0..<7).reversed().map { back in
            let d = cal.date(byAdding: .day, value: -back, to: Date()) ?? Date()
            return Double(commits.filter { cal.isDate($0.date, inSameDayAs: d) }.count)
        }
    }

    // MARK: Builds and run tasks

    func builds(_ id: ProjectID? = nil) -> [BuildRecord] {
        var all = library.builds.filter { id == nil || $0.projectID == id }
        for p in library.projects where id == nil || p.id == id { all += svc(p).activity.builds(p) }
        return all.sorted { $0.date > $1.date }
    }

    func lastBuild(_ id: ProjectID? = nil) -> BuildRecord? {
        builds(id).first { $0.kind == .build || $0.kind == .test }
    }

    /// Runs a detected task in a terminal in the project; its exit code becomes a build record.
    func run(_ task: RunTask, in id: ProjectID) {
        guard let p = project(id) else { return }
        openProject(id)
        let s = newTerminal(project: id, title: task.name, command: task.command)
        if p.isSample {
            // Sample projects pretend the task passed.
            finishTask(task, project: id, ok: true, duration: 14.2)
        } else {
            runningTasks[s.id] = (task, id, Date())
        }
    }

    /// The run task in this session ended.
    func taskExited(_ sessionID: String, code: Int32) {
        guard let t = runningTasks.removeValue(forKey: sessionID) else { return }
        finishTask(t.task, project: t.project, ok: code == 0, duration: Date().timeIntervalSince(t.started))
        refreshGit(t.project)
    }

    private func finishTask(_ task: RunTask, project id: ProjectID, ok: Bool, duration: TimeInterval) {
        guard task.kind != .run else { return }
        library.builds.insert(BuildRecord(projectID: id, task: task.name, kind: task.kind, ok: ok, duration: duration, date: Date()), at: 0)
        if library.builds.count > 200 { library.builds.removeLast() }
        let kind: ActivityEvent.Kind = task.kind == .test ? .test : task.kind == .deploy ? .deploy : .build
        let verb = task.kind == .deploy ? (ok ? "deployed with" : "failed to deploy with") : (ok ? (task.kind == .test ? "passed" : "succeeded for") : "failed for")
        record(ActivityEvent(date: Date(), kind: kind, projectID: id, actor: task.kind == .test ? "Tests" : task.kind == .deploy ? "You" : "Build",
                             text: verb, target: task.command, meta: Self.duration(duration), tone: ok ? .good : .bad, failed: !ok))
        if ok, task.kind != .test { lastShipped = Date() }
    }

    static func duration(_ t: TimeInterval) -> String {
        t < 60 ? String(format: "%.1fs", t) : t < 3600 ? "\(Int(t) / 60)m \(Int(t) % 60)s" : "\(Int(t) / 3600)h \(Int(t) % 3600 / 60)m"
    }

    // MARK: Git

    /// Called after every git refresh: a push since the last one ships, and
    /// today's commit totals refresh.
    func gitChanged(_ id: ProjectID, from old: GitRepoState?, to new: GitRepoState) {
        recordDailyMax("tree", id, Double(new.changedFileCount))
        if let old, old.isRepo, old.branch == new.branch, old.ahead > 0, new.ahead == 0, old.commits.first?.hash == new.commits.first?.hash {
            lastShipped = Date()
            record(ActivityEvent(date: Date(), kind: .commit, projectID: id, actor: "You", text: "pushed \(old.ahead) commit\(old.ahead == 1 ? "" : "s") to",
                                 target: new.remote, tone: .good))
        }
        guard let p = project(id), old?.commits.first?.hash != new.commits.first?.hash || dayStats[id] == nil else { return }
        let service = svc(p).activity
        Task { dayStats[id] = await service.dayStats(p) }
    }

    /// The session is on screen in front of the user: Brix is the active app and
    /// the session is the visible tab of a pane in the screen being shown.
    func isWatching(_ id: String) -> Bool {
        guard NSApp?.isActive == true, windowVisible, let s = session(id) else { return false }
        let tree: PaneTree?
        switch route {
        case .workspace(let p) where p == s.projectID: tree = workspaces[p]?.state.panes
        case .terminals: tree = terminalTree
        default: tree = nil
        }
        guard let tree else { return false }
        return tree.groups.contains { ($0.active ?? $0.tabs.first) == id }
    }

    // MARK: Mood

    var buddyMood: BuddyMood {
        if !waitingSessions.isEmpty { return .waiting }
        if let t = lastShipped, Date().timeIntervalSince(t) < 60 { return .shipped }
        if sessions.contains(where: { $0.kind == .agent && $0.state == .running }) { return .working }
        return .idle
    }
}
