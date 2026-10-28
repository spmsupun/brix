import SwiftUI
import AppKit

extension AppStore {
    // MARK: Creating sessions

    /// Creates a terminal. Sample projects and hosts get a mock session;
    /// everything else runs a real PTY.
    @discardableResult
    func newTerminal(project: ProjectID?, host hostID: ResourceID? = nil, title: String? = nil, kind: SessionKind = .shell,
                     command: String? = nil, cwd: String? = nil, env extraEnv: [String: String] = [:], attach: Bool = true) -> TerminalSession {
        let p = project.flatMap(self.project)
        let h = hostID.flatMap(self.host)
        let sample = (p?.isSample ?? false) || (h?.isSample ?? false)
        let dir = cwd ?? (h != nil ? "~" : (p?.path ?? "~"))
        var s = TerminalSession(id: "s-\(UUID().uuidString.prefix(8))", projectID: project, hostID: hostID,
                                title: title ?? (h.map { "\($0.user)@\($0.name.components(separatedBy: " ").first?.lowercased() ?? $0.host)" } ?? "zsh"),
                                kind: kind, cwd: dir, state: .idle, process: command ?? (h != nil ? "ssh" : "zsh"), startedAt: Date())
        if sample {
            s.isSampleSession = true
            if let h {
                s.lines = [TermLine([MockData.span("Connected to \(h.host)", Theme.text3)]), remotePrompt(h, cwd: s.cwd)]
                s.state = .idle
            } else if let p {
                s.lines = [MockData.promptLine(project: p.name, branch: git[p.id]?.branch ?? "main")]
            }
            if let command, kind != .agent {
                s.lines[s.lines.count - 1] = s.lines[s.lines.count - 1].appending(MockData.span(command, Theme.text))
                s.state = .running
            }
        } else {
            s.isLive = true
            s.state = .running
            var argv: [String]
            if let h {
                argv = SSHCommand.interactive(h, remoteCommand: command)
            } else if let command {
                argv = ["/bin/zsh", "-lic", command]
            } else {
                argv = ["/bin/zsh", "-l"]
            }
            var env: [String: String] = extraEnv
            if let h, h.auth == .password, let pw = hostPassword(h), let ask = try? SSHCommand.askpassEnv(password: pw) {
                env.merge(ask) { _, new in new }
            }
            let workdir = h == nil ? (dir as NSString).expandingTildeInPath : NSHomeDirectory()
            TerminalRegistry.shared.start(sessionID: s.id, argv: argv, cwd: workdir, env: env, fontSize: settings.terminalFontSize, store: self)
        }
        sessions.append(s)
        if attach, let project { workspace(for: project).attach(session: s) }
        focusedSessionID = s.id
        return s
    }

    func remotePrompt(_ h: SSHHost, cwd: String) -> TermLine {
        TermLine([MockData.span("\(h.user)@\(h.host.components(separatedBy: ".").first ?? h.host)", Theme.green), MockData.span(":", Theme.text3),
                  MockData.span(cwd, Theme.cyan), MockData.span(" ❯ ", settings.accent.color)])
    }

    /// Starts `agent` in the project. Callers that don't know which agent the
    /// user wants should call `startAgent(project:)`, which asks.
    @discardableResult
    func newAgentSession(project id: ProjectID, agent a: AgentConfig, resume: String? = nil, attach: Bool = true) -> TerminalSession? {
        guard let p = project(id) else {
            toast(.info, "Open a project first", detail: "Agent sessions run inside a project folder.")
            return nil
        }
        // Agents receive resource names only, never secrets.
        let names = linkedHosts(id).map(\.name) + linkedDatabases(id).map(\.name) + linkedDocker(id).map(\.name)
        // Never run two copies of one conversation; the second would fail.
        if let resume, let live = sessions.first(where: { $0.externalID == resume && $0.isLive && $0.state != .finished && $0.state != .failed }) {
            return live
        }
        // Claude Code takes our own session id, so the conversation can be resumed later.
        let external = resume ?? (a.binary == "claude" && !p.isSample ? UUID().uuidString.lowercased() : nil)
        // A Claude conversation that never got a message has no transcript to resume:
        // start it fresh under the same id instead of failing.
        let canResume = resume != nil && (a.binary != "claude" || AgentTranscripts.claudeTranscriptExists(sessionID: resume!))
        let shared = (linkedDatabases(id) + (p.parentID.map(linkedDatabases) ?? [])).contains { $0.agentAccess != .none }
        let cmd = a.launchCommand(resourceNames: names, sessionID: external, resume: canResume, databases: shared)
        // brix-db reaches Brix's gateway with these; the session id is filled in below.
        let pending = "s-pending-\(UUID().uuidString.prefix(6))"
        var s = newTerminal(project: id, title: a.name, kind: .agent, command: cmd,
                            env: AgentDBGateway.shared.environment(project: id, session: pending), attach: false)
        gatewaySessions[pending] = s.id
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            if s.isSampleSession {
                sessions[i].lines = [TermLine([MockData.span("✻ ", Theme.violet), MockData.span(a.name, Theme.text, bold: true), MockData.span("  \(p.path)", Theme.meta)]),
                                     TermLine(""), TermLine("  Type a task below to start.", Theme.text3)]
                sessions[i].state = .idle
                sessions[i].task = ""
                sessions[i].plan = []
            }
            sessions[i].process = a.binary
            sessions[i].agentID = a.id
            sessions[i].externalID = external
            s = sessions[i]
        }
        if attach { workspace(for: id).attach(session: s, preferAgentGrid: true) }
        library.daily[Self.dayKey("sessions", id, Date()), default: 0] += 1
        // Resumes (including every relaunch) aren't news; only new sessions are.
        if resume == nil {
            record(ActivityEvent(date: Date(), kind: .start, projectID: id, actor: a.name, text: "started a session", sessionID: s.id))
        }
        return s
    }

    func openServerShell(_ hostID: ResourceID, project: ProjectID? = nil, cwd: String? = nil) {
        guard let h = host(hostID) else { return }
        let target = project ?? currentProjectID
        // `cd` into the folder, then hand over to the user's login shell.
        let command = cwd.map { "cd \(RemoteFiles.q($0)) 2>/dev/null; exec \"$SHELL\" -l" }
        let s = newTerminal(project: target, host: hostID, kind: .server, command: command, attach: target != nil)
        if target == nil {
            route = .terminals
            focusedSessionID = s.id
        }
        if h.isSample { hostStatus[hostID] = .connected }
    }

    func openDockerShell(_ id: ResourceID, project: ProjectID? = nil) {
        guard let c = dockerTarget(id) else { return }
        let host = c.hostID.flatMap(self.host)
        let cmd = (c.isSample ? services.mock.docker : services.live.docker).shellCommand(c, host: host)
        let s = newTerminal(project: project ?? currentProjectID, title: "\(c.name) shell", kind: .shell, command: cmd, attach: (project ?? currentProjectID) != nil)
        if project ?? currentProjectID == nil { route = .terminals; focusedSessionID = s.id }
    }

    func openDockerLogs(_ id: ResourceID, project: ProjectID? = nil) {
        guard let c = dockerTarget(id) else { return }
        let target = project ?? currentProjectID
        if let target {
            let ws = workspace(for: target)
            let panel = ws.layout.add(.logs, to: .bottom, resource: "docker:\(id)", title: "\(c.name) logs")
            ws.select(panel: panel.id)
            if route != .workspace(target) { openProject(target) }
        } else {
            let host = c.hostID.flatMap(self.host)
            let cmd = (c.isSample ? services.mock.docker : services.live.docker).followLogsCommand(c, host: host)
            var s = newTerminal(project: nil, title: "\(c.name) logs", kind: .logs, command: cmd, attach: false)
            if c.isSample, let i = sessions.firstIndex(where: { $0.id == s.id }) {
                Task {
                    let lines = (try? await services.mock.docker.logs(c, host: host)) ?? []
                    sessions[i].lines += lines.map { TermLine($0, Theme.body) }
                }
                s = sessions[i]
            }
            route = .terminals
            focusedSessionID = s.id
        }
    }

    // MARK: Session actions

    func closeSession(_ id: String, confirmRunning: Bool = true) {
        guard let s = session(id) else { return }
        let close = { [weak self] in
            guard let self else { return }
            TerminalRegistry.shared.stop(id)
            if s.state == .running { trackAgentTime(s, from: .running, to: .finished) }
            runningTasks[id] = nil
            sessions.removeAll { $0.id == id }
            for ws in workspaces.values { ws.detach(session: id) }
            if focusedSessionID == id { focusedSessionID = nil }
            if inspector == .session(id) { inspector = .none }
            updateDockBadge()
        }
        if confirmRunning, s.isLive, s.kind == .agent {
            confirm("Close \(displayTitle(s))?", "The agent stops. You can resume the conversation later from the project overview.", confirm: "Close", action: close)
        } else if confirmRunning, s.isLive, Self.isBusy(s) {
            confirm("Close \(s.title)?", "A process is still running in this terminal and will be stopped.", confirm: "Close", action: close)
        } else {
            close()
        }
    }

    /// Something is running that closing would stop.
    static func isBusy(_ s: TerminalSession) -> Bool {
        s.state == .running && (s.kind != .shell || TerminalRegistry.shared.hasChildProcess(s.id))
    }

    /// Closes several sessions (a tab's panes) behind one confirmation.
    func closeSessions(_ ids: [String]) {
        let busy = ids.compactMap(session).filter { $0.isLive && ($0.kind == .agent || Self.isBusy($0)) }
        let close = { [weak self] in ids.forEach { self?.closeSession($0, confirmRunning: false) } }
        if busy.isEmpty {
            close()
        } else {
            let what = ids.count == 1 ? displayTitle(busy[0]) : "\(ids.count) tabs"
            let why = busy.contains { $0.kind == .agent } ? "Agents stop; you can resume them later from the project overview." : "A process is still running and will be stopped."
            confirm("Close \(what)?", why, confirm: "Close", action: close)
        }
    }

    func renameSession(_ id: String, to title: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        sessions[i].title = title
    }

    func clearSession(_ id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[i].isLive {
            TerminalRegistry.shared.clear(id)
        } else {
            sessions[i].lines = []
        }
    }

    func interruptSession(_ id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[i].isLive {
            TerminalRegistry.shared.send(id, text: "\u{3}")
        } else {
            sessions[i].lines.append(TermLine("^C", Theme.text3))
            if sessions[i].kind == .agent {
                sessions[i].lines.append(TermLine("  ⎿ Interrupted by user", Theme.amber))
                setSessionState(id, .idle)
            } else {
                if let h = sessions[i].hostID.flatMap(host) {
                    sessions[i].lines.append(remotePrompt(h, cwd: sessions[i].cwd))
                } else if let p = sessions[i].projectID.flatMap(project) {
                    sessions[i].lines.append(MockData.promptLine(project: p.name, branch: git[p.id]?.branch ?? "main"))
                }
                sessions[i].state = .idle
                sessions[i].process = sessions[i].hostID == nil ? "zsh" : "bash"
            }
        }
    }

    /// Input from a mock terminal's prompt line or an agent composer.
    func sendInput(_ id: String, _ text: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions[i]
        if s.isLive {
            TerminalRegistry.shared.send(id, text: text + "\r")
            if s.kind == .agent {
                if sessions[i].task.isEmpty { sessions[i].task = String(text.prefix(120)) }
                TerminalRegistry.shared.markWorking(id)
                setSessionState(id, .running)
            }
            return
        }
        if s.kind == .agent {
            sessions[i].state = .running
            if sessions[i].task.isEmpty { sessions[i].task = text }
            if sessions[i].plan.isEmpty {
                sessions[i].plan = [PlanItem(title: "Understand the request", done: false), PlanItem(title: "Make the change", done: false), PlanItem(title: "Run the tests", done: false)]
            }
            sessions[i].lines.append(TermLine([MockData.span("✶ Thinking…", Theme.violet)]))
            let project = s.projectID.flatMap(self.project)
            let svc = services.mock.agent
            Task {
                guard let cur = session(id) else { return }
                let reply = await svc.reply(to: text, session: cur, project: project)
                guard let j = sessions.firstIndex(where: { $0.id == id }) else { return }
                sessions[j].lines.removeAll { $0.plain.hasPrefix("✶ Thinking") }
                sessions[j].lines += reply.lines
                if let plan = reply.plan { sessions[j].plan = plan }
                if let t = reply.touched { sessions[j].touched = t }
                sessions[j].lastOutput = reply.lastOutput
                sessions[j].progress = reply.progress
                setSessionState(id, reply.state)
            }
            return
        }
        // Mock shell
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !sessions[i].lines.isEmpty {
            sessions[i].lines[sessions[i].lines.count - 1] = sessions[i].lines[sessions[i].lines.count - 1].appending(MockData.span(trimmed, Theme.text))
        }
        if trimmed == "clear" {
            sessions[i].lines = [promptFor(sessions[i])]
            return
        }
        if trimmed.hasPrefix("cd ") {
            let target = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            sessions[i].cwd = target.hasPrefix("/") || target.hasPrefix("~") ? target : (sessions[i].cwd as NSString).appendingPathComponent(target)
        }
        let p = s.projectID.flatMap(project)
        let h = s.hostID.flatMap(host)
        let g = s.projectID.flatMap { git[$0] }
        let cmd = trimmed
        Task {
            let out = cmd.isEmpty ? [] : await services.mock.terminal.respond(to: cmd, session: s, project: p, host: h, git: g)
            guard let j = sessions.firstIndex(where: { $0.id == id }) else { return }
            sessions[j].lines += out
            sessions[j].lines.append(promptFor(sessions[j]))
            sessions[j].lastOutput = out.suffix(2).map(\.plain).joined(separator: "\n")
            let longRunning = cmd.hasPrefix("pnpm dev") || cmd.hasPrefix("htop") || cmd.hasPrefix("tail -f")
            sessions[j].state = longRunning ? .running : .idle
            sessions[j].process = longRunning ? cmd : (h == nil ? "zsh" : "bash")
        }
    }

    func promptFor(_ s: TerminalSession) -> TermLine {
        if let h = s.hostID.flatMap(host) { return remotePrompt(h, cwd: s.cwd) }
        let p = s.projectID.flatMap(project)
        return MockData.promptLine(project: p?.name ?? "~", branch: s.projectID.flatMap { git[$0]?.branch } ?? "main")
    }

    // MARK: State changes and notifications

    func setSessionState(_ id: String, _ state: SessionState) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let old = sessions[i].state
        sessions[i].state = state
        guard old != state, sessions[i].kind == .agent else { return }
        let s = sessions[i]
        trackAgentTime(s, from: old, to: state)
        if state == .needsInput {
            record(ActivityEvent(date: Date(), kind: .ask, projectID: s.projectID, actor: displayTitle(s), text: "asked you a question",
                                 meta: "waiting", tone: .warn, sessionID: s.id))
        }
        let pname = s.projectID.flatMap(project)?.name ?? s.title
        if state == .needsInput, settings.notifyNeedsInput {
            AgentNotifier.shared.notify(title: "\(pname) needs your input", body: s.lastOutput.isEmpty ? "\(s.title) is waiting for a reply." : s.lastOutput, sessionID: id, sound: settings.notifySound, store: self)
        } else if state == .idle, old == .running, settings.notifyNeedsInput {
            AgentNotifier.shared.notify(title: "\(pname): \(s.title) is done", body: s.lastOutput.isEmpty ? "Waiting for your next message." : s.lastOutput, sessionID: id, sound: settings.notifySound, store: self)
        } else if state == .finished, settings.notifyFinished {
            AgentNotifier.shared.notify(title: "\(pname): session finished", body: s.task.isEmpty ? "\(s.title) exited." : s.task, sessionID: id, sound: settings.notifySound, store: self)
        }
        updateDockBadge()
    }

    func updateDockBadge() {
        let n = waitingSessions.count
        NSApp?.dockTile.badgeLabel = settings.badgeDock && n > 0 ? "\(n)" : nil
    }

    /// Opens the project workspace with the given session focused.
    func reveal(session id: String) {
        guard let s = session(id) else { return }
        if let p = s.projectID {
            openProject(p)
            workspace(for: p).focus(session: id)
        } else {
            route = .terminals
        }
        focusedSessionID = id
        inspector = .session(id)
    }

    /// Called by the live terminal when output arrives or the process exits.
    func liveActivity(_ id: String, lastLines: [String], exited: Int32?) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let text = lastLines.suffix(3).joined(separator: "\n")
        if !text.isEmpty { sessions[i].lastOutput = text }
        if sessions[i].kind == .agent {
            let before = Set(sessions[i].touched.map(\.path))
            AgentActivityParser.apply(lines: lastLines, to: &sessions[i])
            let s = sessions[i]
            for t in s.touched where !before.contains(t.path) {
                record(ActivityEvent(date: Date(), kind: .edit, projectID: s.projectID, actor: displayTitle(s),
                                     text: "edited \((t.path as NSString).lastPathComponent)", sessionID: s.id))
            }
        }
        if let code = exited {
            taskExited(id, code: code)
            if sessions[i].title.hasPrefix("Install ") { refreshAgentPaths() }
            if sessions[i].kind == .agent {
                setSessionState(id, code == 0 ? .finished : .failed)
            } else {
                sessions[i].state = code == 0 ? .finished : .failed
            }
        }
    }

    /// An agent's state read from its screen: working, asking, or waiting at its prompt.
    func liveAgentState(_ id: String, _ state: SessionState) {
        guard let s = session(id), s.isLive, s.state != .finished, s.state != .failed else { return }
        setSessionState(id, state)
    }

    func liveIdle(_ id: String, idle: Bool) {
        guard let s = session(id), s.isLive, s.state != .finished, s.state != .failed else { return }
        if s.kind == .agent {
            setSessionState(id, idle ? .needsInput : .running)
        } else if let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].state = idle ? .idle : .running
        }
    }
}

/// Pulls plan items and touched files out of Claude Code's terminal output.
enum AgentActivityParser {
    static func apply(lines: [String], to s: inout TerminalSession) {
        var plan: [PlanItem] = []
        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("☒") { plan.append(PlanItem(title: String(l.dropFirst()).trimmingCharacters(in: .whitespaces), done: true)) }
            if l.hasPrefix("☐") { plan.append(PlanItem(title: String(l.dropFirst()).trimmingCharacters(in: .whitespaces), done: false)) }
            if let r = l.range(of: #"(Update|Write|Edit)\(([^)]+)\)"#, options: .regularExpression) {
                let m = String(l[r])
                if let open = m.firstIndex(of: "("), let close = m.lastIndex(of: ")") {
                    let path = String(m[m.index(after: open)..<close])
                    if !s.touched.contains(where: { $0.path == path }) { s.touched.append(FileTouch(path: path, add: 0, del: 0)) }
                }
            }
        }
        if !plan.isEmpty {
            s.plan = plan
            s.progress = Double(plan.filter(\.done).count) / Double(plan.count)
        }
    }
}

extension AppStore {
    /// Restarts last run's terminals and agents for open projects and the
    /// Terminals screen, so a relaunch (or a crash) picks up where it left off.
    /// Runs once, when the window first appears (never from init, which SwiftUI
    /// may call more than once).
    func restoreSessionsAtLaunch() {
        guard !globalRestored, !restoreDisabled else { return }
        for id in library.openProjects where project(id)?.isSample == false {
            workspace(for: id).restoreLiveSessions()
        }
        var remap: [String: String] = [:]
        for d in library.globalSessions where !(d.hostID.flatMap(host)?.tag.isProduction ?? false) {
            // Production SSH shells are not reopened without the user asking.
            let s = newTerminal(project: nil, host: d.hostID, title: d.title, kind: d.kind, cwd: d.cwd, attach: false)
            remap[d.id] = s.id
        }
        terminalTree = WorkspaceStore.remapped(library.globalTree, remap) { _ in false }
        globalRestored = true
    }

    /// Reads the title Claude Code gave each live conversation from its transcript.
    func refreshSessionNames() async {
        let targets = sessions.compactMap { s -> (String, String)? in
            guard s.kind == .agent, s.isLive, let ext = s.externalID, agent(for: s)?.binary == "claude" else { return nil }
            return (s.id, ext)
        }
        guard !targets.isEmpty else { return }
        let names = await Task.detached(priority: .utility) {
            targets.compactMap { id, ext in AgentTranscripts.claudeTitle(sessionID: ext).map { (id, $0) } }
        }.value
        for (id, name) in names {
            if let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].sessionName != name { sessions[i].sessionName = name }
        }
    }
}
