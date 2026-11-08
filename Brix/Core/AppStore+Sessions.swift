import SwiftUI
import AppKit

extension AppStore {
    // MARK: Creating sessions

    /// Creates a terminal. Sample projects and hosts get a mock session;
    /// everything else runs a real PTY.
    @discardableResult
    func newTerminal(project: ProjectID?, host hostID: ResourceID? = nil, title: String? = nil, kind: SessionKind = .shell,
                     command: String? = nil, cwd: String? = nil, env extraEnv: [String: String] = [:], attach: Bool = true, chat: Bool = false) -> TerminalSession {
        let p = project.flatMap(self.project)
        let h = hostID.flatMap(self.host)
        let sample = (p?.isSample ?? false) || (h?.isSample ?? false)
        let dir = cwd ?? (h != nil ? "~" : (p?.path ?? "~"))
        var s = TerminalSession(id: "s-\(UUID().uuidString.prefix(8))", projectID: project, hostID: hostID,
                                title: title ?? (h.map { "\($0.user)@\($0.name.components(separatedBy: " ").first?.lowercased() ?? $0.host)" } ?? "Terminal"),
                                kind: kind, cwd: dir, state: .idle, process: command ?? (h != nil ? "ssh" : Self.loginShellName), startedAt: Date())
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
                // Commands Brix builds use zsh syntax, so they keep zsh.
                argv = ["/bin/zsh", "-lic", command]
            } else {
                argv = [Self.loginShell, "-l"]
            }
            var env: [String: String] = extraEnv
            if let h, h.auth == .password, let pw = hostPassword(h), let ask = try? SSHCommand.askpassEnv(password: pw) {
                env.merge(ask) { _, new in new }
            }
            let workdir = h == nil ? (dir as NSString).expandingTildeInPath : NSHomeDirectory()
            if chat, h == nil, let command {
                s.isChat = true
                s.state = .idle
                ClaudeChatRegistry.shared.start(sessionID: s.id, command: command, cwd: workdir, env: env, store: self)
            } else {
            TerminalRegistry.shared.start(sessionID: s.id, argv: argv, cwd: workdir, env: env, fontSize: settings.terminalFontSize, store: self)
            }
        }
        sessions.append(s)
        if attach, let project { workspace(for: project).attach(session: s) }
        focusedSessionID = s.id
        return s
    }

    /// The user's login shell (bash, fish), for plain terminals.
    static let loginShell: String = {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let path = String(cString: sh)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }()
    static var loginShellName: String { (loginShell as NSString).lastPathComponent }

    func remotePrompt(_ h: SSHHost, cwd: String) -> TermLine {
        TermLine([MockData.span("\(h.user)@\(h.host.components(separatedBy: ".").first ?? h.host)", Theme.green), MockData.span(":", Theme.text3),
                  MockData.span(cwd, Theme.cyan), MockData.span(" ❯ ", settings.accent.color)])
    }

    /// Starts `agent` in the project. Callers that don't know which agent the
    /// user wants should call `startAgent(project:)`, which asks.
    @discardableResult
    /// `chat`: show it as a chat or a terminal; nil follows the setting.
    func newAgentSession(project id: ProjectID, agent a: AgentConfig, resume: String? = nil, attach: Bool = true, chat: Bool? = nil) -> TerminalSession? {
        guard let p = project(id) else {
            toast(.info, "Open a project first", detail: "Agent sessions run inside a project folder.")
            return nil
        }
        // Agents receive resource names only, never secrets.
        let names = linkedHosts(id).map(\.name) + dataConnections(for: id).map(\.name) + linkedDocker(id).map(\.name)
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
                            env: AgentDBGateway.shared.environment(project: id, session: pending), attach: false,
                            chat: a.binary == "claude" && (chat ?? settings.claudeNativeView))
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
        guard c.state == .running else { toast(.info, "\(c.name) isn't running", detail: "Start it to open a shell."); return }
        let host = c.hostID.flatMap(self.host)
        // A shell in a container on a Production server is a shell on that server.
        guardProduction(host?.tag ?? .dev, name: host.map { "\(c.name) on \($0.name)" } ?? c.name, verb: "Open Shell in") { [weak self] in
            guard let self else { return }
            let cmd = (c.isSample ? services.mock.docker : services.live.docker).shellCommand(c, host: host)
            let s = newTerminal(project: project ?? currentProjectID, title: "\(c.name) shell", kind: .shell, command: cmd, attach: (project ?? currentProjectID) != nil)
            if project ?? currentProjectID == nil { route = .terminals; focusedSessionID = s.id }
        }
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
            ClaudeChatRegistry.shared.stop(id)
            if s.state == .running { trackAgentTime(s, from: .running, to: .finished) }
            runningTasks[id] = nil
            AgentDBGateway.shared.revoke(session: id)
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
        if sessions[i].isChat {
            // Clear on a chat starts a new conversation: asked, since it can't be undone in place.
            guard let chat = ClaudeChatRegistry.shared.chat(id) else { return }
            confirm("Start a new conversation here?", "The current one stays in this project's past conversations, where you can resume it." + (chat.working ? " Claude is working; this stops it." : ""),
                    confirm: "New Conversation", destructive: false) { chat.clear() }
        } else if sessions[i].isLive {
            TerminalRegistry.shared.clear(id)
        } else {
            sessions[i].lines = []
        }
    }

    func interruptSession(_ id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if let chat = ClaudeChatRegistry.shared.chat(id) {
            chat.interrupt()
        } else if sessions[i].isLive {
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

    /// Input from a mock terminal's prompt line or Brix sending a prompt.
    func sendInput(_ id: String, _ text: String, images: [ClaudeChat.Attachment] = []) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions[i]
        if let chat = ClaudeChatRegistry.shared.chat(id) {
            if sessions[i].task.isEmpty, !text.isEmpty { sessions[i].task = String(text.prefix(120)) }
            chat.send(text, images: images)
            return
        }
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
        if resuming.contains(id) {
            // Reloading after a restart: it settles back where it was, nothing new to see.
            if state != .running { resuming.remove(id) }
            updateDockBadge()
            return
        }
        if state == .running, !sessions[i].markedUnread {
            sessions[i].unseen = false
        } else if (old == .running || state == .needsInput || state == .finished), !isWatching(id) {
            sessions[i].unseen = true
        }
        let s = sessions[i]
        // The first turn started: its prompt is in the transcript now, so name the tab without waiting for the 15 s refresh.
        if state == .running, s.task.isEmpty, s.sessionName == nil { Task { [weak self] in await self?.refreshSessionNames() } }
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

    /// You looked at it: no longer flagged as finished-unseen.
    /// `opened`: the user picked it from a list, which also clears a hand-set unread.
    /// Otherwise (it's merely on screen) a hand-set unread stays.
    func markSeen(_ id: String, opened: Bool = false) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if opened {
            sessions[i].markedUnread = false
            markNoticesRead(session: id)
        }
        guard sessions[i].unseen, !sessions[i].markedUnread else { return }
        sessions[i].unseen = false
        updateDockBadge()
    }

    /// Flags a session to come back to: the Unread chip shows until you open it again.
    func setUnread(_ id: String, _ unread: Bool) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].unseen = unread
        sessions[i].markedUnread = unread
        if !unread { markNoticesRead(session: id) }
        updateDockBadge()
    }

    /// Brix came to the front: sessions already on screen count as seen.
    func markWatchedSeen() {
        for s in sessions where s.unseen && (isWatching(s.id) || onScreen[s.id, default: 0] > 0) { markSeen(s.id) }
    }

    func updateDockBadge() {
        let n = sessions.filter { ($0.kind == .agent && $0.state == .needsInput) || $0.unseen }.count
        NSApp?.dockTile.badgeLabel = settings.badgeDock && n > 0 ? "\(n)" : nil
    }

    // MARK: Notification list

    var unreadNotices: Int { library.notices.filter { !$0.read }.count }

    func recordNotice(title: String, body: String, session: String) {
        library.notices.insert(AgentNotice(title: title, body: body, sessionID: session), at: 0)
        if library.notices.count > 200 { library.notices.removeLast(library.notices.count - 200) }
    }

    func markNoticesRead(session: String? = nil) {
        for i in library.notices.indices where !library.notices[i].read && (session == nil || library.notices[i].sessionID == session) {
            library.notices[i].read = true
        }
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
        markSeen(id, opened: true)
    }

    /// A path shown in a local terminal, as it exists on disk: relative ones are
    /// read from the session's folder, and ":42:7" line numbers are dropped.
    func resolvePath(_ raw: String, from id: String) -> (path: String, isDirectory: Bool)? {
        guard let s = session(id), s.hostID == nil else { return nil }
        let folder = s.cwd.isEmpty ? (s.projectID.flatMap(project)?.path ?? "~") : s.cwd
        return Self.resolvePath(raw, base: (folder as NSString).expandingTildeInPath)
    }

    nonisolated static func resolvePath(_ raw: String, base: String) -> (path: String, isDirectory: Bool)? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("file://") { t = URL(string: t)?.path ?? String(t.dropFirst(7)) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]<>,;"))
        if let r = t.range(of: #"(:\d+)+$"#, options: .regularExpression) { t.removeSubrange(r) }
        guard !t.isEmpty else { return nil }
        let e = (t as NSString).expandingTildeInPath
        let full = URL(fileURLWithPath: e.hasPrefix("/") ? e : base + "/" + e).standardizedFileURL.resolvingSymlinksInPath().path
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &dir) else { return nil }
        return (full, dir.boolValue)
    }

    /// Opens a path from a terminal (⌘-click, or Open on a selection): a file in a
    /// project opens in a tab, a folder shows opened in the Explorer, and anything
    /// outside your projects shows in Finder. False when nothing on disk matches.
    @discardableResult
    func openPath(_ raw: String, from id: String) -> Bool {
        guard let (full, isDir) = resolvePath(raw, from: id) else { return false }
        let root = { (p: Project) in URL(fileURLWithPath: p.expandedPath).resolvingSymlinksInPath().path }
        let inside = { (p: Project) in !p.isSample && (full == root(p) || full.hasPrefix(root(p) + "/")) }
        let own = session(id)?.projectID.flatMap(project)
        guard let p = own.flatMap({ inside($0) ? $0 : nil }) ?? library.projects.first(where: inside) else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
            return true
        }
        if p.id != own?.id { openProject(p.id) }
        let ws = workspace(for: p.id)
        let rel = String(full.dropFirst(root(p).count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !isDir {
            ws.open(rel)
            return true
        }
        if !rel.isEmpty {
            ws.expandParents(of: rel)
            ws.state.expanded.insert(rel)
            ws.state.selection = rel
        }
        if !ws.state.layout.allPanels.contains(where: { $0.kind == .explorer }), !ws.state.panes.allTabs.contains(GridItemID.panel(.explorer)) {
            _ = ws.state.layout.add(.explorer)
        }
        return true
    }

    /// Called by the live terminal when output arrives or the process exits.
    /// `asked`: the question on screen while the agent waits on a choice list.
    func liveActivity(_ id: String, lastLines: [String], exited: Int32?, asked: String? = nil) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        // A process Brix stopped (closing, switching views) didn't finish by itself.
        if exited != nil, sessions[i].isLive, TerminalRegistry.shared.view(id) == nil, ClaudeChatRegistry.shared.chat(id) == nil { return }
        if sessions[i].kind == .agent {
            // No reply on screen: an empty text makes the notice say "Waiting for your next message", not the prompt line.
            sessions[i].lastOutput = asked ?? BrixTerminalView.lastReply(lastLines) ?? ""
        } else if !lastLines.isEmpty {
            sessions[i].lastOutput = lastLines.suffix(3).joined(separator: "\n")
        }
        // A chat's lines are Claude's prose, not its screen: its edits arrive through chatEdited.
        if sessions[i].kind == .agent, !sessions[i].isChat {
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

    /// A chat moved to another Claude conversation (/clear, a rewind or a fork):
    /// resume and titles follow it.
    func chatConversation(_ id: String, _ conversation: String) {
        guard AgentConfig.isSafeID(conversation), let i = sessions.firstIndex(where: { $0.id == id }),
              sessions[i].externalID != conversation else { return }
        sessions[i].externalID = conversation
        sessions[i].sessionName = nil
    }

    /// A chat's edit, as the terminal parser records them: Agent Files, activity, "editing".
    func chatEdited(_ id: String, path: String, added: Int, removed: Int) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        // Relative to the session folder when inside it (symlinks such as /tmp → /private/tmp resolved).
        let base = URL(fileURLWithPath: (sessions[i].cwd as NSString).expandingTildeInPath).resolvingSymlinksInPath().path + "/"
        let full = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let rel = full.hasPrefix(base) ? String(full.dropFirst(base.count)) : full
        if let k = sessions[i].touched.firstIndex(where: { $0.path == rel }) {
            sessions[i].touched[k].add += added
            sessions[i].touched[k].del += removed
        } else {
            sessions[i].touched.append(FileTouch(path: rel, add: added, del: removed))
            let s = sessions[i]
            record(ActivityEvent(date: Date(), kind: .edit, projectID: s.projectID, actor: displayTitle(s),
                                 text: "edited \((rel as NSString).lastPathComponent)", sessionID: s.id))
        }
    }

    /// A new chat with the conversation up to before one of its messages.
    func forkChat(_ id: String, at item: ClaudeChat.Item) {
        guard let s = session(id), let chat = ClaudeChatRegistry.shared.chat(id) else { return }
        let title = "Fork of " + displayTitle(s)
        guard chat.canCut(item), let fork = chat.forkCommand(at: item) else { return }
        let token = "s-fork-\(UUID().uuidString.prefix(6))"
        let env = s.projectID.map { AgentDBGateway.shared.environment(project: $0, session: token) } ?? [:]
        let f = newTerminal(project: s.projectID, title: title, kind: .agent, command: fork.command, cwd: s.cwd, env: env, attach: false, chat: true)
        gatewaySessions[token] = f.id
        if let i = sessions.firstIndex(where: { $0.id == f.id }) {
            sessions[i].agentID = s.agentID
            sessions[i].process = "claude"
            sessions[i].externalID = fork.id
        }
        if let p = s.projectID { workspace(for: p).attach(session: session(f.id) ?? f, preferAgentGrid: true) }
        reveal(session: f.id)
    }

    /// Reopens a Claude session in the other view (chat or terminal), same conversation.
    func reopen(_ id: String, asChat: Bool) {
        guard let s = session(id), s.kind == .agent, let a = agent(for: s), a.binary == "claude", let ext = s.externalID else { return }
        let go = { [weak self] in
            guard let self else { return }
            // Where it sits now, so the other view takes the same tab slot.
            let ws = s.projectID.map { self.workspace(for: $0) }
            let tree = ws?.state.panes ?? self.terminalTree
            let group = tree.group(of: id)
            let index = group?.tabs.firstIndex(of: id)
            // Stop this one first: one conversation never runs in two processes.
            let old = TerminalRegistry.shared.pid(id) ?? ClaudeChatRegistry.shared.chat(id)?.pid
            TerminalRegistry.shared.stop(id)
            ClaudeChatRegistry.shared.stop(id)
            if let i = self.sessions.firstIndex(where: { $0.id == id }) { self.sessions[i].externalID = nil }
            Task {
                // Wait (up to 3 s) for it to exit: Claude can't resume a conversation
                // another process still has open.
                let deadline = Date().addingTimeInterval(3)
                while let old, old > 0, kill(old, 0) == 0, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
                // Closed meanwhile: nothing to switch.
                guard self.session(id) != nil else { return }
                let n = s.projectID.flatMap { self.newAgentSession(project: $0, agent: a, resume: ext, attach: false, chat: asChat) }
                    ?? self.startLocalAgent(a, resume: ext, chat: asChat, focus: false)
                if let ws { ws.state.panes.add(n.id, to: group?.id, at: index) } else { self.terminalTree.add(n.id, to: group?.id, at: index) }
                self.closeSession(id, confirmRunning: false)
                self.renameSession(n.id, to: s.title)
                if let i = self.sessions.firstIndex(where: { $0.id == n.id }) {
                    self.sessions[i].sessionName = s.sessionName
                    self.sessions[i].task = s.task
                }
                self.reveal(session: n.id)
            }
        }
        let queued = ClaudeChatRegistry.shared.chat(id)?.queued.count ?? 0
        if s.state == .running || queued > 0 {
            confirm("Stop Claude to switch views?", "Switching restarts it on the same conversation, which stops the current turn" + (queued > 0 ? " and drops \(queued) queued message\(queued == 1 ? "" : "s")." : "."), confirm: "Switch", action: go)
        } else {
            go()
        }
    }

    /// An agent's state read from its screen: working, asking, or waiting at its prompt.
    func liveAgentState(_ id: String, _ state: SessionState) {
        guard let s = session(id), s.isLive, s.state != .finished, s.state != .failed else { return }
        setSessionState(id, state)
    }

    /// What a local shell is running: a command's name, or nil at its prompt.
    /// `busy`: the command is working (an agent CLI waiting for you isn't).
    func liveForeground(_ id: String, command: String?, busy: Bool) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].isLive,
              sessions[i].state != .finished, sessions[i].state != .failed else { return }
        sessions[i].state = busy ? .running : .idle
        sessions[i].process = command ?? Self.loginShellName
    }

    /// A terminal took the keyboard: it's the focused session, in the focused pane.
    func terminalFocused(_ id: String) {
        if focusedSessionID != id { focusedSessionID = id }
        if let ws = session(id)?.projectID.flatMap({ workspaces[$0] }), let g = ws.state.panes.group(of: id)?.id {
            if ws.state.panes.focusedGroup != g { ws.state.panes.focusedGroup = g }
        } else if let g = terminalTree.group(of: id)?.id, terminalTree.focusedGroup != g {
            terminalTree.focusedGroup = g
        }
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
    /// A session restored at launch: quiet while its agent reloads, and unread only
    /// if it was when Brix quit.
    func restored(_ id: String, from d: SessionDescriptor) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if d.unread == true { sessions[i].unseen = true }
        guard d.kind == .agent else { return }
        resuming.insert(id)
        // A reload that never settles (no idle screen) stops being quiet after a minute.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            self?.resuming.remove(id)
        }
    }

    func restoreSessionsAtLaunch() {
        guard !globalRestored, !restoreDisabled else { return }
        // Restarting doesn't move the focus to whichever session came back last.
        let focused = focusedSessionID
        defer { focusedSessionID = focused }
        for id in library.openProjects where project(id)?.isSample == false {
            workspace(for: id).restoreLiveSessions()
        }
        var remap: [String: String] = [:]
        // Production SSH shells are not reopened without the user asking; they stay saved.
        heldGlobalSessions = library.globalSessions.filter { $0.restorable && ($0.hostID.flatMap(host)?.tag.isProduction ?? false) }
        if !heldGlobalSessions.isEmpty {
            let n = heldGlobalSessions.count
            toast(.info, "\(n) production session\(n == 1 ? " was" : "s were") not reopened on the Terminals screen",
                  detail: "Brix doesn't reconnect to Production servers unasked. Open \(n == 1 ? "it" : "them") again from the server when you need \(n == 1 ? "it" : "them").")
        }
        for d in library.globalSessions where d.restorable && !(d.hostID.flatMap(host)?.tag.isProduction ?? false) {
            // An agent on This Mac resumes its conversation (it came back as a bare shell before).
            // An agent whose CLI was removed from Brix comes back as a shell rather than under another agent.
            let s: TerminalSession
            if d.kind == .agent, d.hostID == nil, let a = agent(d.agentID) {
                s = startLocalAgent(a, resume: d.externalID, chat: d.isChat, focus: false)
            } else {
                s = newTerminal(project: nil, host: d.hostID, title: d.title, kind: d.kind == .agent ? .shell : d.kind,
                                command: d.kind == .agent ? nil : d.command, cwd: d.cwd, attach: false)
            }
            remap[d.id] = s.id
            restored(s.id, from: d)
            if d.kind == .agent { renameSession(s.id, to: d.title) }
        }
        terminalTree = WorkspaceStore.remapped(library.globalTree, remap) { _ in false }
        globalRestored = true
    }

    /// Reads the task list of each working Claude agent from its transcript.
    func refreshPlans() async {
        let targets = sessions.compactMap { s -> (String, String)? in
            guard s.kind == .agent, s.isLive, let ext = s.externalID, agent(for: s)?.binary == "claude" else { return nil }
            return (s.id, ext)
        }
        guard !targets.isEmpty else { return }
        let plans = await Task.detached(priority: .utility) {
            // No transcript, or nothing in it yet (a /clear or /resume moved on): empty,
            // so the last conversation's plan doesn't linger.
            targets.map { id, ext in (id, AgentTranscripts.claudePlan(sessionID: ext) ?? AgentPlan(items: [], doc: "")) }
        }.value
        for (id, plan) in plans {
            guard let i = sessions.firstIndex(where: { $0.id == id }) else { continue }
            if sessions[i].plan != plan.items { sessions[i].plan = plan.items }
            if sessions[i].planDoc != plan.doc { sessions[i].planDoc = plan.doc }
        }
    }

    /// Reads the title Claude Code gave each live conversation from its transcript.
    /// A /resume inside Claude switches it to another conversation: the id is
    /// updated too, so the title follows and a relaunch resumes the right one.
    func refreshSessionNames() async {
        let targets = sessions.compactMap { s -> (String, String, pid_t?)? in
            guard s.kind == .agent, s.isLive, let ext = s.externalID, agent(for: s)?.binary == "claude" else { return nil }
            return (s.id, ext, TerminalRegistry.shared.pid(s.id) ?? ClaudeChatRegistry.shared.chat(s.id)?.pid)
        }
        guard !targets.isEmpty else { return }
        let found = await Task.detached(priority: .utility) {
            targets.map { id, ext, pid in
                let now = pid.flatMap { AgentTranscripts.claudeLiveSessionID(pid: $0) } ?? ext
                return (id, now, AgentTranscripts.claudeEntry(sessionID: now))
            }
        }.value
        for (id, ext, entry) in found {
            guard let i = sessions.firstIndex(where: { $0.id == id }),
                  let was = targets.first(where: { $0.0 == id })?.1, sessions[i].externalID == was else { continue }
            // (A rewind or clear may have moved it while this ran; that newer id wins.)
            if sessions[i].externalID != ext {
                PerfMonitor.shared.note("session \(id) switched conversation to \(ext)")
                sessions[i].externalID = ext
            }
            if let name = entry?.title, sessions[i].sessionName != name { sessions[i].sessionName = name }
            // Typed straight into the terminal, the first prompt never passed through
            // Brix: until Claude names the chat, the tab shows that prompt.
            if sessions[i].task.isEmpty, let p = entry?.firstPrompt { sessions[i].task = String(p.prefix(120)) }
        }
    }
}
