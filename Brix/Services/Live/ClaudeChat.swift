import AppKit
import Observation
import UniformTypeIdentifiers

/// A Claude Code session driven through its stream-json mode instead of its
/// terminal screen: Brix sends messages and answers permission prompts as JSON
/// lines on stdin, and reads every event (text as it streams, tool calls, tool
/// results, prompts) from stdout. The conversation is saved by Claude as usual,
/// so plans, titles and resume keep working.
@MainActor
@Observable
final class ClaudeChat {
    struct Diff: Equatable, Sendable { var old: String; var new: String }

    /// An image going to Claude with a message.
    struct Attachment: Identifiable, Sendable {
        let id = UUID()
        var data: Data
        var mediaType: String
        /// The N of the "[Image #N]" tag the composer put in the text; 0 when untagged.
        var number = 0
    }

    /// A message's content blocks: each image right after its "[Image #N]" label, so
    /// Claude can match the tags in the text to the pictures, then the text.
    nonisolated static func content(_ text: String, images: [Attachment]) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        for a in images {
            if a.number > 0 { parts.append(["type": "text", "text": "[Image #\(a.number)]"]) }
            parts.append(["type": "image", "source": ["type": "base64", "media_type": a.mediaType, "data": a.data.base64EncodedString()]])
        }
        if !text.isEmpty { parts.append(["type": "text", "text": text]) }
        return parts
    }

    /// The label block `content` puts before an image; history leaves it out of the shown text.
    nonisolated static func isImageLabel(_ s: String) -> Bool {
        s.wholeMatch(of: /\[Image #\d+\]/) != nil
    }

    /// Images brought back into the composer, numbered on from `next`, with their
    /// tags in `text` changed to match; an untagged one gets a tag in front.
    nonisolated static func renumbered(_ text: String, _ images: [Attachment], from next: Int) -> (text: String, images: [Attachment]) {
        var map: [Int: Int] = [:], out = images, front = ""
        for i in out.indices {
            let n = next + i
            if out[i].number > 0 { map[out[i].number] = n } else { front += "[Image #\(n)] " }
            out[i].number = n
        }
        let t = text.replacing(/\[Image #(\d+)\]/) { m in map[Int(m.1) ?? 0].map { "[Image #\($0)]" } ?? String(m.0) }
        return (front + t, out)
    }

    struct Item: Identifiable, Sendable {
        enum Kind { case user, text, thinking, tool, error, notice, output }
        let id: String
        var kind: Kind
        /// The message, or for a tool the one-line summary ("npm test", "src/app.ts").
        var text: String
        var tool = ""
        /// A tool's body: the command, the file content, the plan.
        var detail = ""
        var diff: Diff?
        var result: String?
        var failed = false
        /// Images you sent with a message (kept with their tags, for Edit and Resend).
        var images: [Attachment] = []
        /// Your message's id in Claude's transcript (for rewind), and the id of
        /// Claude's last message before it (where a rewind or fork cuts).
        var uuid: String? = nil
        var before: String? = nil
        /// False when Brix can't tell where Claude's context before it starts
        /// (sent before a resumed history loaded, or the oldest one loaded).
        var cutKnown = true
        /// A subagent's own steps (Task/Agent tool), and images a tool returned.
        var children: [Item] = []
        var resultImages: [Data] = []

        func renamed(_ newID: String) -> Item {
            Item(id: newID, kind: kind, text: text, tool: tool, detail: detail, diff: diff, result: result, failed: failed, images: images, uuid: uuid, before: before, cutKnown: cutKnown,
                 children: children, resultImages: resultImages)
        }
    }

    struct Command: Identifiable, Sendable {
        var id: String { name }
        var name: String
        var description: String
        var hint: String
    }

    struct Question: Identifiable {
        var id: String { question }
        var question: String
        var header: String
        var options: [(label: String, description: String)]
        var multi: Bool
    }

    /// A tool waiting for your answer: allow it, deny it, or answer its questions.
    struct Ask: Identifiable {
        let id: String
        var tool: String
        var summary: String
        var detail: String
        var diff: Diff?
        var questions: [Question] = []
        var input: [String: Any]
        var suggestions: [Suggestion] = []
        /// Claude's own words for the prompt, and why it's asking.
        var title = ""
        var reason = ""
        var blockedPath = ""
    }

    /// One "Yes, and …" choice Claude offers with a permission prompt. Each is
    /// sent back on its own: some only last this session, others are saved.
    struct Suggestion: Identifiable {
        let id = UUID()
        var label: String
        var raw: [String: Any]
        var saved: Bool
    }

    struct Model: Identifiable, Sendable {
        var id: String { value }
        var value: String
        var name: String
        var detail: String
        var resolved: String
        var efforts: [String]
    }

    struct Queued: Identifiable, Sendable {
        let id: String
        var text: String
        var images: [Attachment]
    }

    struct Context: Sendable {
        var percent: Int
        var used: Int
        var max: Int
        var compactAt: Int
        var autoCompact: Bool
        var categories: [(name: String, tokens: Int)]
    }

    /// Work Claude runs in the background: a subagent or a backgrounded command.
    struct BackgroundTask: Identifiable, Sendable {
        let id: String
        var toolUseID: String
        var description: String
        var status: String
        var summary: String
        var outputFile: String
        var running: Bool { status == "running" || status == "pending" || status.isEmpty }
    }

    struct MCPServer: Identifiable, Sendable {
        var id: String { name }
        var name: String
        var status: String
        var error: String
        var tools: Int
    }

    struct Limit: Identifiable, Sendable {
        var id: String { label }
        var label: String
        var used: Double
        var resets: Date?
    }

    /// The modes Claude Code cycles through with ⇧⇥, in its order.
    nonisolated static let modes: [(id: String, name: String, detail: String)] = [
        ("default", "Ask before edits", "Asks before changing files or running commands"),
        ("acceptEdits", "Accept edits", "Edits files without asking; still asks for commands"),
        ("plan", "Plan", "Researches and proposes a plan without changing anything"),
        ("auto", "Auto", "No routine prompts; a reviewer model screens actions"),
    ]

    let sessionID: String
    private(set) var items: [Item] = []
    private(set) var asks: [Ask] = []
    /// Text and thinking of the reply as it streams, before the finished block arrives.
    private(set) var liveText = ""
    private(set) var liveThinking = ""
    private(set) var working = false
    private(set) var model = ""
    private(set) var permissionMode = ""
    private(set) var exited: Int32?
    /// Slash commands Claude reported (its own, skills, custom ones).
    private(set) var commands: [Command] = []
    private(set) var loadingHistory = false
    private(set) var models: [Model] = []
    /// The effort Claude uses: what you picked here, else your Claude settings.
    private(set) var effort = ""
    /// Messages sent while Claude works; each runs as its own turn, in order.
    private(set) var queued: [Queued] = []
    private(set) var context: Context?
    /// Claude's list-price figure for this session (not what a subscription is charged).
    private(set) var sessionCost = 0.0
    private(set) var limits: [Limit] = []
    private(set) var compacting = false
    /// Files Claude suggests for an `@` mention.
    private(set) var fileMatches: [String] = []
    private(set) var tasks: [BackgroundTask] = []
    private(set) var mcpServers: [MCPServer] = []
    /// `!` command output waiting to go to Claude with the next message, as the terminal's bash mode does.
    private(set) var bashContext = ""
    /// `!` commands still running; their output must reach Claude before the next message goes.
    private(set) var bashRunning = 0
    /// Why the MCP list couldn't be read, if it couldn't.
    private(set) var mcpError = ""
    /// `!` commands running, by their card's id, with the command.
    private var bashTasks: [String: (cmd: String, task: Task<Void, Never>)] = [:]
    /// Streamed text not yet shown: it reaches the view at most every 60 ms.
    @ObservationIgnored private var streamed = (text: "", thinking: "")
    @ObservationIgnored private var flushQueued = false
    /// Turn lines seen (stream, assistant, user): none after a result means the queue isn't draining.
    @ObservationIgnored private var turnEvents = 0
    /// Bumped when the conversation is swapped, so a history still loading is dropped.
    @ObservationIgnored private var historyGeneration = 0
    /// Edits waiting for their result: counted for Agent Files only once they succeed.
    private var pendingEdits: [String: (path: String, added: Int, removed: Int)] = [:]
    private var replies: [String: CheckedContinuation<[String: Any]?, Never>] = [:]
    private var fileQuery = 0
    let cwd: String

    weak var store: AppStore?
    private var process: Process?
    private var input: FileHandle?
    private var pending = Data()
    private var stderrTail = ""
    private var interrupting = false
    private var contextGeneration = 0
    /// The command this chat started with, its environment, and Claude's id for the conversation now.
    private var launch = ""
    private var launchEnv: [String: String] = [:]
    private(set) var conversationID = ""
    /// Claude's latest message in the main conversation, where a rewind to the next message cuts.
    private var lastAssistant: String?
    /// Put into the composer by Edit (a rewound message to change and send again, with its images).
    var prefill: (text: String, images: [Attachment])?
    /// Writes go out off the main thread: a long message into a full pipe would block the window.
    private let writer = DispatchQueue(label: "brix.claude-chat.write")

    init(sessionID: String, cwd: String, store: AppStore) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.store = store
    }

    static let flags = " --print --input-format stream-json --output-format stream-json --verbose --include-partial-messages --permission-prompt-tool stdio --replay-user-messages"

    /// `command` is the usual launch line (session id, resume, system prompt); it
    /// runs through a login shell like a terminal session, so PATH matches.
    /// `replacing`: a rewind or clear swapping the process; a failure then leaves the old one running.
    @discardableResult
    func start(command: String, env: [String: String], history: Bool = true, replacing: Bool = false) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "exec " + command + Self.flags]
        p.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory())
        var extra = env
        // Marks the transcript as a Brix chat (listed and titled like a terminal
        // conversation, unlike scripted runs), and keeps file checkpoints for rewind.
        extra["CLAUDE_CODE_ENTRYPOINT"] = "brix"
        extra["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1"
        p.environment = ProcessRunner.environment(extra: extra)
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        // Output from a process a rewind replaced is dropped.
        out.fileHandleForReading.readabilityHandler = { [weak self, weak p] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { if let self, self.process === p { self.consume(d) } } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self, weak p] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.process === p else { return }
                self.stderrTail = String(self.stderrTail.appending(String(decoding: d, as: UTF8.self)).suffix(2000))
            } }
        }
        p.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            // Its last stderr lines (the reason) arrive on their own handler: let them land first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated {
                // A process replaced by a rewind or clear ending isn't the chat ending.
                guard self?.process === p else { return }
                self?.ended(code)
            } }
        }
        do {
            try ProcessRunner.spawnLock.withLock {
                ProcessRunner.markAllCloseOnExec()
                try p.run()
            }
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            items.append(Item(id: "err-start-\(UUID().uuidString)", kind: .error, text: "Couldn't start Claude Code: \(error.localizedDescription)"))
            if !replacing {
                exited = -1
                store?.liveActivity(sessionID, lastLines: [], exited: -1)
            }
            return false
        }
        launch = command
        launchEnv = env
        conversationID = Self.flag("--session-id", in: command) ?? Self.flag("--resume", in: command) ?? conversationID
        pending = Data()
        stderrTail = ""
        process = p
        input = inp.fileHandleForWriting
        effort = Self.settingsEffort()
        // Subagent steps come back tagged with their Task, so their cards can show them.
        write(["type": "control_request", "request_id": "init", "request": ["subtype": "initialize", "forwardSubagentText": true]])
        if history, let id = Self.flag("--resume", in: command) {
            loadHistory(id, until: Self.flag("--resume-session-at", in: command))
        }
        return true
    }

    var pid: pid_t? { process.map(\.processIdentifier).flatMap { $0 > 0 ? $0 : nil } }
    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: Sending

    func send(_ text: String, images: [Attachment] = []) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !images.isEmpty, exited == nil else { return }
        let shown = t
        if !bashContext.isEmpty, !t.hasPrefix("/") {
            t = bashContext + "\n\n" + t
            bashContext = ""
        }
        let uuid = UUID().uuidString.lowercased()
        // While a turn runs, Claude queues it; it shows as queued until its turn starts.
        if working {
            queued.append(Queued(id: uuid, text: shown, images: images))
        } else {
            items.append(Item(id: "u-\(uuid)", kind: .user, text: shown, images: images, uuid: uuid, before: lastAssistant, cutKnown: !loadingHistory))
        }
        if images.isEmpty {
            write(["type": "user", "uuid": uuid, "message": ["role": "user", "content": t]])
        } else {
            write(["type": "user", "uuid": uuid, "message": ["role": "user", "content": Self.content(t, images: images)]])
        }
        interrupting = false
        setWorking(true)
    }

    func interrupt() {
        guard working else { return }
        interrupting = true
        // Whatever it was asking is moot once the turn stops, and so are messages queued behind it.
        asks = []
        for q in queued { control(["subtype": "cancel_async_message", "message_uuid": q.id]) }
        dropQueued()
        report()
        write(["type": "control_request", "request_id": "int-\(UUID().uuidString)", "request": ["subtype": "interrupt"]])
    }

    /// `also`: one "Yes, and …" choice to apply with it (a rule, a folder, a mode).
    func allow(_ ask: Ask, also: Suggestion? = nil) {
        var r: [String: Any] = ["behavior": "allow", "updatedInput": ask.input]
        if let also { r["updatedPermissions"] = [also.raw] }
        reply(ask, r)
        if let mode = also?.raw["mode"] as? String { permissionMode = mode }
    }

    func deny(_ ask: Ask, message: String = "") {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        reply(ask, ["behavior": "deny", "message": m.isEmpty ? "The user denied this. Ask them what to do instead." : m])
    }

    /// Approves a plan and sets how the edits that follow are handled.
    func approvePlan(_ ask: Ask, mode: String) {
        reply(ask, ["behavior": "allow", "updatedInput": ask.input])
        setMode(mode)
    }

    // MARK: Session controls

    /// Shown at once; put back if Claude refuses it (auto mode isn't on every account).
    func setMode(_ mode: String) {
        let before = permissionMode
        permissionMode = mode
        Task {
            if await request(["subtype": "set_permission_mode", "mode": mode]) == nil, permissionMode == mode {
                permissionMode = before
                items.append(Item(id: "e-mode-\(UUID().uuidString)", kind: .error, text: "Couldn't switch to \(Self.modes.first { $0.id == mode }?.name ?? mode)."))
            }
        }
    }

    func setModel(_ value: String) {
        control(["subtype": "set_model", "model": value])
    }

    func setEffort(_ level: String) {
        effort = level
        control(["subtype": "apply_flag_settings", "settings": ["effortLevel": level]])
    }

    /// Removed only if Claude hadn't started it yet.
    func cancelQueued(_ id: String) {
        Task {
            let r = await request(["subtype": "cancel_async_message", "message_uuid": id])
            if r?["cancelled"] as? Bool == true {
                queued.removeAll { $0.id == id }
            }
        }
    }

    func compact() { send("/compact") }

    // MARK: Background work, MCP, bash mode

    /// Sends a running command or subagent to the background (⌃B in the terminal); nil: all of them.
    func background(_ toolUseID: String? = nil) {
        var r: [String: Any] = ["subtype": "background_tasks"]
        if let toolUseID { r["tool_use_id"] = toolUseID }
        control(r)
    }

    func stopTask(_ id: String) { control(["subtype": "stop_task", "task_id": id]) }

    func refreshMCP() async {
        guard let r = await request(["subtype": "mcp_status"]) else { mcpError = "Couldn't reach Claude Code."; return }
        mcpError = ""
        mcpServers = (r["mcpServers"] as? [[String: Any]] ?? []).compactMap { s in
            guard let n = s["name"] as? String else { return nil }
            return MCPServer(name: n, status: s["status"] as? String ?? "", error: s["error"] as? String ?? "", tools: (s["tools"] as? [Any])?.count ?? 0)
        }
    }

    func reconnectMCP(_ name: String) {
        Task {
            if await request(["subtype": "mcp_reconnect", "serverName": name]) == nil { mcpError = "Couldn't reconnect \(name)." }
            await refreshMCP()
        }
    }

    func toggleMCP(_ name: String, on: Bool) {
        Task {
            if await request(["subtype": "mcp_toggle", "serverName": name, "enabled": on]) == nil { mcpError = "Couldn't turn \(name) \(on ? "on" : "off")." }
            await refreshMCP()
        }
    }

    /// `!command`: runs in the project folder; Claude gets the command and its output with your next message.
    func runBash(_ command: String) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        let id = "b-\(UUID().uuidString)"
        items.append(Item(id: id, kind: .tool, text: cmd, tool: "Bash", detail: cmd))
        let dir = URL(fileURLWithPath: cwd.isEmpty ? NSHomeDirectory() : cwd)
        bashRunning += 1
        let task = Task {
            let out: ProcessOutput
            do { out = try await ProcessRunner.run("/bin/zsh", ["-lc", cmd], cwd: dir, timeout: 120) }
            catch { out = ProcessOutput(stdout: "", stderr: Task.isCancelled ? "Stopped." : "Couldn't run it: " + error.localizedDescription, status: -1) }
            bashDone(id, cmd, out)
        }
        bashTasks[id] = (cmd, task)
    }

    func isRunningBash(_ id: String) -> Bool { bashTasks[id] != nil }

    /// Stops a `!` command. Claude still gets the command, and its output if the
    /// runner hands back what it printed before the grace period ends.
    func stopBash(_ id: String) {
        guard let b = bashTasks[id] else { return }
        b.task.cancel()
        Task {
            try? await Task.sleep(for: .seconds(2))
            bashDone(id, b.cmd, ProcessOutput(stdout: "", stderr: "Stopped before it finished.", status: -1))
        }
    }

    /// Once per command: whichever of its result and a stop comes second is dropped.
    private func bashDone(_ id: String, _ cmd: String, _ out: ProcessOutput) {
        guard bashTasks.removeValue(forKey: id) != nil else { return }
        bashRunning -= 1
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].result = String((out.stdout + (out.stderr.isEmpty ? "" : "\n" + out.stderr)).trimmingCharacters(in: .whitespacesAndNewlines).suffix(20_000))
            items[i].failed = !out.ok
        }
        // Output can't close the tags early and pass itself off as your words.
        func safe(_ s: String, _ n: Int) -> String { String(s.suffix(n)).replacingOccurrences(of: "</bash-", with: "<\\/bash-") }
        bashContext += (bashContext.isEmpty ? "" : "\n") + "<bash-input>\(safe(cmd, 4_000))</bash-input>\n<bash-stdout>\(safe(out.stdout, 20_000))</bash-stdout><bash-stderr>\(safe(out.stderr, 5_000))</bash-stderr>"
    }

    /// `#note`: added to the project's CLAUDE.md, which Claude reads at the start of each conversation.
    func addMemory(_ note: String) -> String? {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard !cwd.isEmpty else { return "This session has no folder." }
        // Appended in place: a linked CLAUDE.md stays linked, its permissions stay, and
        // a file that isn't UTF-8 text is left alone rather than rewritten.
        let url = URL(fileURLWithPath: cwd).appendingPathComponent("CLAUDE.md").resolvingSymlinksInPath()
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                guard String(data: data, encoding: .utf8) != nil else { return "CLAUDE.md isn't UTF-8 text, so it was left as it is." }
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: Data(((data.last == nil || data.last == 0x0A) ? "" : "\n").utf8) + Data(("- " + text + "\n").utf8))
            } else {
                try Data(("- " + text + "\n").utf8).write(to: url)
            }
            items.append(Item(id: "n-mem-\(UUID().uuidString)", kind: .notice, text: "Added to CLAUDE.md: " + text))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Rewind, fork, clear, export

    /// What rewinding the code to before `item` would undo; nil when it can't.
    struct RewindPreview { var files: [String]; var added: Int; var removed: Int }

    /// What rewinding the code to before `item` would undo, or why it can't.
    func previewRewind(_ item: Item) async -> Result<RewindPreview, RewindError> {
        guard let u = item.uuid else { return .failure(RewindError("This message has no checkpoint.")) }
        guard let r = await request(["subtype": "rewind_files", "user_message_id": u, "dry_run": true]) else {
            return .failure(RewindError("Claude Code didn't answer."))
        }
        guard r["canRewind"] as? Bool == true else { return .failure(RewindError(r["error"] as? String ?? "There's no file checkpoint from before this message.")) }
        return .success(RewindPreview(files: (r["filesChanged"] as? [String] ?? []).map { ($0 as NSString).abbreviatingWithTildeInPath },
                                      added: (r["insertions"] as? NSNumber)?.intValue ?? 0, removed: (r["deletions"] as? NSNumber)?.intValue ?? 0))
    }

    struct RewindError: Error { var message: String; init(_ m: String) { message = m } }

    /// Puts the files back as they were before `item`. Returns why it couldn't, or nil.
    func rewindFiles(_ item: Item) async -> String? {
        guard let u = item.uuid else { return "This message has no checkpoint." }
        guard let r = await request(["subtype": "rewind_files", "user_message_id": u]) else { return "Claude Code didn't answer." }
        return r["canRewind"] as? Bool == true ? nil : (r["error"] as? String ?? "Couldn't rewind the files.")
    }

    /// Goes back to before `item`: the conversation continues from Claude's
    /// message before it (a fork of the transcript, so nothing is lost on disk).
    /// `edit`: put the message back in the composer to change and send again.
    /// Whether a rewind or fork can cut at `item` (Claude isn't mid-turn and the cut point is known).
    func canCut(_ item: Item) -> Bool {
        !working && exited == nil && item.cutKnown && (item.before == nil || !conversationID.isEmpty)
    }

    func rewindConversation(to item: Item, edit: Bool) {
        guard canCut(item), let i = items.firstIndex(where: { $0.id == item.id }), let command = forkCommand(at: item) else { return }
        // The new process starts before anything is thrown away: if it can't, nothing changes.
        guard restart(command.command) else { return }
        items = Array(items[..<i]) + [Item(id: "n-rewound-\(UUID().uuidString)", kind: .notice, text: "Rewound to here")]
        lastAssistant = item.before
        conversationID = command.id
        store?.chatConversation(sessionID, command.id)
        if edit { prefill = (item.text, item.images) }
    }

    /// A fresh conversation in the same place; the old one stays resumable.
    func clear() {
        let id = UUID().uuidString.lowercased()
        guard restart(Self.base(launch) + " --session-id \(id)") else { return }
        items = [Item(id: "n-cleared-\(UUID().uuidString)", kind: .notice, text: "New conversation")]
        lastAssistant = nil
        tasks = []
        conversationID = id
        store?.chatConversation(sessionID, id)
    }

    /// The launch line for a copy of this conversation up to before `item` (or a new
    /// empty one when nothing came before it), and the id the copy will have.
    func forkCommand(at item: Item) -> (command: String, id: String)? {
        guard item.cutKnown else { return nil }
        let id = UUID().uuidString.lowercased()
        guard let cut = item.before else { return (Self.base(launch) + " --session-id \(id)", id) }
        guard !conversationID.isEmpty else { return nil }
        return (Self.base(launch) + " --resume \(conversationID) --resume-session-at \(cut) --fork-session --session-id \(id)", id)
    }

    /// The conversation as plain text, and the file name Claude suggests.
    func export() async -> (text: String, name: String)? {
        guard let r = await request(["subtype": "export_conversation"]), let t = r["text"] as? String else { return nil }
        return (t, r["default_filename"] as? String ?? "conversation.txt")
    }

    var lastReply: String? { items.last { $0.kind == .text }?.text }

    /// Replaces the process with one running `command`, keeping this chat.
    /// False (and the old process left running) when the new one can't start.
    @discardableResult
    private func restart(_ command: String) -> Bool {
        let old = process
        let ended = exited != nil
        guard start(command: command, env: launchEnv, history: false, replacing: true) else { return false }
        for c in replies.values { c.resume(returning: nil) }
        replies = [:]
        asks = []
        queued = []
        clearLive()
        working = false
        interrupting = false
        exited = nil
        context = nil
        // The old process's background work and unfinished edits went with it.
        for i in tasks.indices where tasks[i].running { tasks[i].status = "stopped" }
        pendingEdits = [:]
        // A history still being read belongs to the conversation left behind.
        historyGeneration += 1
        loadingHistory = false
        old?.terminate()
        // An ended chat started again is live again: state, notifications and badges resume.
        if ended { store?.setSessionState(sessionID, .idle) }
        report()
        return true
    }

    /// The launch line without the flags that pick a conversation.
    nonisolated static func base(_ command: String) -> String {
        command.replacingOccurrences(of: #" --(session-id|resume|resume-session-at) [0-9a-fA-F-]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " --fork-session", with: "")
    }

    /// The value after `flag` in a launch line.
    nonisolated static func flag(_ flag: String, in command: String) -> String? {
        guard let r = command.range(of: " \(flag) ") else { return nil }
        let v = command[r.upperBound...].prefix { !$0.isWhitespace }
        return v.isEmpty ? nil : String(v)
    }

    /// How full the context window is, asked after each turn.
    func refreshContext() async {
        contextGeneration += 1
        let gen = contextGeneration
        guard let r = await request(["subtype": "get_context_usage"]), gen == contextGeneration else { return }
        func int(_ k: String) -> Int { (r[k] as? NSNumber)?.intValue ?? 0 }
        let cats = (r["categories"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String != "deferred" && $0["isDeferred"] as? Bool != true }
        context = Context(percent: Int(((r["percentage"] as? NSNumber)?.doubleValue ?? 0).rounded()), used: int("totalTokens"), max: int("maxTokens"),
                          compactAt: int("autoCompactThreshold"), autoCompact: r["isAutoCompactEnabled"] as? Bool ?? false,
                          categories: cats.compactMap { c in (c["name"] as? String).map { ($0, (c["tokens"] as? NSNumber)?.intValue ?? 0) } }.filter { $0.1 > 0 })
    }

    /// Files matching an `@` mention, newest query wins.
    func findFiles(_ query: String) {
        fileQuery += 1
        let n = fileQuery
        Task {
            let r = await request(["subtype": "file_suggestions", "query": query])
            guard n == fileQuery else { return }
            fileMatches = (r?["suggestions"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }.prefix(8).map { $0 }
        }
    }

    func clearFileMatches() { fileQuery += 1; fileMatches = [] }

    private func control(_ request: [String: Any]) {
        write(["type": "control_request", "request_id": "c-\(UUID().uuidString)", "request": request])
    }

    /// A control request whose answer is wanted; nil on an error or if Claude has gone.
    private func request(_ body: [String: Any]) async -> [String: Any]? {
        guard exited == nil, input != nil else { return nil }
        let id = "q-\(UUID().uuidString)"
        // An answer that never comes gives up after 15 s instead of waiting forever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.replies.removeValue(forKey: id)?.resume(returning: nil)
        }
        return await withCheckedContinuation { c in
            replies[id] = c
            write(["type": "control_request", "request_id": id, "request": body])
        }
    }

    /// Answers AskUserQuestion: each question's text mapped to the chosen labels.
    func answer(_ ask: Ask, _ answers: [String: String]) {
        var input = ask.input
        input["answers"] = answers
        reply(ask, ["behavior": "allow", "updatedInput": input])
    }

    private func reply(_ ask: Ask, _ response: [String: Any]) {
        asks.removeAll { $0.id == ask.id }
        write(["type": "control_response", "response": ["subtype": "success", "request_id": ask.id, "response": response]])
        report()
    }

    func stop() {
        input = nil
        if let p = process, p.isRunning { p.terminate() }
    }

    private func write(_ object: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        writer.async { [weak self] in
            do { try input.write(contentsOf: data) } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self?.items.append(Item(id: "err-\(UUID().uuidString)", kind: .error, text: "Couldn't reach Claude Code: \(error.localizedDescription)"))
                    self?.setWorking(false)
                } }
            }
        }
    }

    // MARK: Reading

    private func consume(_ data: Data) {
        pending.append(data)
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            // A login shell's own output (a .zshrc echo) isn't JSON: skipped.
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(o)
        }
    }

    private func handle(_ o: [String: Any]) {
        if ["stream_event", "assistant", "user"].contains(o["type"] as? String) || o["subtype"] as? String == "status" { turnEvents += 1 }
        switch o["type"] as? String {
        case "system":
            if o["subtype"] as? String == "init" {
                if let id = o["session_id"] as? String, id != conversationID {
                    // /clear and forks start a new conversation: keep Brix's record (resume, title) on it.
                    conversationID = id
                    store?.chatConversation(sessionID, id)
                }
                model = o["model"] as? String ?? model
                permissionMode = o["permissionMode"] as? String ?? permissionMode
            } else if o["subtype"] as? String == "status" {
                if let m = o["permissionMode"] as? String { permissionMode = m }
                compacting = o["status"] as? String == "compacting"
                if o["status"] as? String == "requesting", !working {
                    // A turn Claude started itself (a background task finished).
                    setWorking(true)
                }
            } else if (o["subtype"] as? String)?.hasPrefix("task_") == true {
                updateTask(o)
            } else if o["subtype"] as? String == "hook_response", let code = (o["exit_code"] as? NSNumber)?.intValue, code != 0 {
                // A hook that failed or blocked something says why; successful ones stay quiet.
                let why = ((o["stderr"] as? String) ?? (o["output"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                items.append(Item(id: "hk-\(o["uuid"] as? String ?? UUID().uuidString)", kind: .notice,
                                  text: "Hook \(o["hook_name"] as? String ?? "") " + (code == 2 ? "blocked this" : "failed") + (why.isEmpty ? "" : ": " + String(why.prefix(300)))))
            } else if let n = Self.notice(o) {
                items.append(Item(id: "s-\(o["uuid"] as? String ?? UUID().uuidString)", kind: n.output ? .output : .notice, text: n.text))
            }
        case "rate_limit_event":
            if let w = (o["rate_limit_info"] as? [String: Any])?["unifiedWindows"] as? [String: Any] {
                limits = [("five_hour", "5h"), ("seven_day", "7d")].compactMap { key, label in
                    guard let v = w[key] as? [String: Any], let u = v["utilization"] as? Double else { return nil }
                    return Limit(label: label, used: u, resets: (v["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
                }
            }
        case "stream_event":
            guard o["parent_tool_use_id"] is NSNull || o["parent_tool_use_id"] == nil,
                  let e = o["event"] as? [String: Any] else { return }
            if e["type"] as? String == "content_block_delta", let d = e["delta"] as? [String: Any] {
                if let t = d["text"] as? String { streamed.text += t }
                if let t = d["thinking"] as? String { streamed.thinking += t }
                flushSoon()
            }
        case "assistant":
            // A subagent's own steps go inside its Task card.
            if let parent = o["parent_tool_use_id"] as? String {
                guard let parts = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
                var steps: [Item] = []
                for c in parts {
                    if c["type"] as? String == "tool_use" {
                        let name = c["name"] as? String ?? "Tool"
                        let input = c["input"] as? [String: Any] ?? [:]
                        let s = Self.describe(name, input, cwd: cwd)
                        let diff = name == "Write" ? (Self.writeDiff(input) ?? s.diff) : s.diff
                        let tid = c["id"] as? String ?? UUID().uuidString
                        steps.append(Item(id: tid, kind: .tool, text: s.summary, tool: name, detail: s.detail, diff: diff))
                        noteEdit(tid, name, input, diff)
                    } else if c["type"] as? String == "text", let t = c["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        steps.append(Item(id: UUID().uuidString, kind: .text, text: t))
                    }
                }
                if !steps.isEmpty, !updateStep(parent, { $0.children += steps }) {
                    PerfMonitor.shared.note("chat \(sessionID): \(steps.count) subagent steps for an unknown task \(parent)")
                }
                return
            }
            clearLive()
            guard let m = o["message"] as? [String: Any], let parts = m["content"] as? [[String: Any]] else { return }
            let isError = o["is_api_error_message"] as? Bool == true
            if let u = o["uuid"] as? String { lastAssistant = u }
            for (k, c) in parts.enumerated() {
                let id = "\(m["id"] as? String ?? UUID().uuidString)-\(k)-\(items.count)"
                switch c["type"] as? String {
                case "text":
                    let t = (c["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { items.append(Item(id: id, kind: isError ? .error : .text, text: t)) }
                case "thinking":
                    let t = (c["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { items.append(Item(id: id, kind: .thinking, text: t)) }
                case "tool_use":
                    let name = c["name"] as? String ?? "Tool"
                    let input = c["input"] as? [String: Any] ?? [:]
                    let s = Self.describe(name, input, cwd: cwd)
                    let diff = name == "Write" ? (Self.writeDiff(input) ?? s.diff) : s.diff
                    let tid = c["id"] as? String ?? id
                    items.append(Item(id: tid, kind: .tool, text: s.summary, tool: name, detail: s.detail, diff: diff))
                    noteEdit(tid, name, input, diff)
                default: break
                }
            }
            report()
        case "user":
            // A queued message is echoed back when its turn starts: it moves into the chat then.
            if o["isReplay"] as? Bool == true, let u = o["uuid"] as? String, let i = queued.firstIndex(where: { $0.id == u }) {
                let q = queued.remove(at: i)
                items.append(Item(id: "u-\(q.id)", kind: .user, text: q.text, images: q.images, uuid: q.id, before: lastAssistant, cutKnown: !loadingHistory))
                setWorking(true)
                return
            }
            // A slash command's own output (/model, /usage) comes back as a replayed user line.
            if let m = o["message"] as? [String: Any], let t = m["content"] as? String {
                if let out = Self.commandOutput(t), !(items.last?.kind == .output && items.last?.text == out) {
                    items.append(Item(id: "o-\(o["uuid"] as? String ?? UUID().uuidString)", kind: .output, text: out))
                }
                return
            }
            // Echoes of messages already shown.
            if o["isReplay"] as? Bool == true { return }
            guard let m = o["message"] as? [String: Any], let parts = m["content"] as? [[String: Any]] else { return }
            if o["parent_tool_use_id"] is String {
                for c in parts where c["type"] as? String == "tool_result" {
                    guard let id = c["tool_use_id"] as? String else { continue }
                    let failed = c["is_error"] as? Bool == true
                    _ = updateStep(id) { $0.result = Self.capped(Self.text(of: c["content"])); $0.failed = failed }
                    editDone(id, failed: failed)
                }
                return
            }
            for c in parts {
                if c["type"] as? String == "tool_result", let id = c["tool_use_id"] as? String,
                   let i = items.lastIndex(where: { $0.id == id }) {
                    items[i].result = Self.capped(Self.text(of: c["content"]))
                    items[i].failed = c["is_error"] as? Bool == true
                    items[i].resultImages = Self.images(of: c["content"])
                    if !items[i].resultImages.isEmpty { trimResultImages() }
                    editDone(id, failed: items[i].failed)
                } else if c["type"] as? String == "text", let t = c["text"] as? String, t.hasPrefix("[Request interrupted") {
                    items.append(Item(id: "n-\(UUID().uuidString)", kind: .notice, text: "Interrupted"))
                }
            }
        case "result":
            clearLive()
            if interrupting {
                // Stopped on purpose: not an error.
                if items.last?.kind != .notice { items.append(Item(id: "n-\(UUID().uuidString)", kind: .notice, text: "Interrupted")) }
            } else if o["subtype"] as? String != "success" {
                let why = (o["errors"] as? [String])?.joined(separator: "\n") ?? (o["result"] as? String) ?? (o["subtype"] as? String ?? "")
                items.append(Item(id: "r-\(UUID().uuidString)", kind: .error, text: why.isEmpty ? "The turn ended with an error." : why))
            }
            interrupting = false
            if let c = o["total_cost_usd"] as? Double { sessionCost = c }
            // Queued messages still waiting start the next turn (Claude may run several as one).
            setWorking(!queued.isEmpty)
            if !queued.isEmpty { settleQueue() }
            Task { await refreshContext() }
        case "control_request":
            guard let id = o["request_id"] as? String, let r = o["request"] as? [String: Any] else { return }
            if r["subtype"] as? String == "can_use_tool" {
                let name = r["tool_name"] as? String ?? "Tool"
                let input = r["input"] as? [String: Any] ?? [:]
                let s = Self.describe(name, input, cwd: cwd)
                let questions = (input["questions"] as? [[String: Any]] ?? []).map { q in
                    Question(question: q["question"] as? String ?? "", header: q["header"] as? String ?? "",
                             options: (q["options"] as? [[String: Any]] ?? []).map { ($0["label"] as? String ?? "", $0["description"] as? String ?? "") },
                             multi: q["multiSelect"] as? Bool ?? false)
                }
                asks.append(Ask(id: id, tool: name, summary: s.summary, detail: s.detail, diff: s.diff, questions: name == "AskUserQuestion" ? questions : [],
                                input: input, suggestions: (r["permission_suggestions"] as? [[String: Any]] ?? []).compactMap { Self.suggestion($0, cwd: cwd) },
                                title: r["title"] as? String ?? "", reason: r["decision_reason"] as? String ?? "",
                                blockedPath: r["blocked_path"] as? String ?? ""))
                report()
            } else {
                // Hooks and SDK MCP servers aren't registered here; say so rather than leave it waiting.
                write(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Not supported by Brix"]])
            }
        case "control_response":
            guard let r = o["response"] as? [String: Any], let rid = r["request_id"] as? String else { return }
            let body = r["subtype"] as? String == "success" ? (r["response"] as? [String: Any] ?? [:]) : nil
            if let c = replies.removeValue(forKey: rid) { c.resume(returning: body); return }
            if rid == "init", let body {
                // The answer to `initialize`: commands, models and the mode this session starts in.
                commands = (body["commands"] as? [[String: Any]] ?? []).compactMap { c in
                    guard let n = c["name"] as? String else { return nil }
                    return Command(name: n, description: c["description"] as? String ?? "", hint: c["argumentHint"] as? String ?? "")
                }
                models = (body["models"] as? [[String: Any]] ?? []).compactMap { m in
                    guard let v = m["value"] as? String else { return nil }
                    return Model(value: v, name: m["displayName"] as? String ?? v, detail: m["description"] as? String ?? "",
                                 resolved: m["resolvedModel"] as? String ?? v, efforts: m["supportedEffortLevels"] as? [String] ?? [])
                }
                if let m = body["current_permission_mode"] as? String, permissionMode.isEmpty { permissionMode = m }
            } else if r["subtype"] as? String == "error" {
                items.append(Item(id: "e-\(rid)", kind: .error, text: "Claude Code: " + (r["error"] as? String ?? "that didn't work.")))
            }
        case "control_cancel_request":
            if let id = o["request_id"] as? String { asks.removeAll { $0.id == id }; report() }
        default: break
        }
    }

    private func ended(_ code: Int32) {
        guard exited == nil else { return }
        exited = code
        working = false
        interrupting = false
        asks = []
        for i in tasks.indices where tasks[i].running { tasks[i].status = "stopped" }
        dropQueued()
        for c in replies.values { c.resume(returning: nil) }
        replies = [:]
        if code != 0 {
            items.append(Item(id: "x-\(UUID().uuidString)", kind: .error, text: Self.exitMessage(code, stderr: stderrTail, command: launch)))
        }
        store?.liveActivity(sessionID, lastLines: lastLines, exited: code)
    }

    /// Queued messages that won't run: listed in the chat, so nothing typed vanishes.
    private func dropQueued() {
        guard !queued.isEmpty else { return }
        items.append(Item(id: "n-unsent-\(UUID().uuidString)", kind: .notice, text: "\(queued.count) queued message\(queued.count == 1 ? " wasn't" : "s weren't") sent: " + queued.map(\.text).joined(separator: " · ")))
        queued = []
    }

    /// Queued messages normally start their own turn right after a result, and their
    /// echo moves them into the chat. Claude can also take them into the turn that
    /// just ended, with no echo: after 10 s with no turn starting they're shown as
    /// sent and Claude as idle, rather than "working" forever.
    private func settleQueue() {
        let mark = turnEvents
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.turnEvents == mark, self.exited == nil, !self.queued.isEmpty else { return }
            for q in self.queued {
                self.items.append(Item(id: "u-\(q.id)", kind: .user, text: q.text, images: q.images, uuid: q.id, cutKnown: false))
            }
            self.queued = []
            self.setWorking(false)
        }
    }

    /// Streamed text reaches the view at most every 60 ms: each change re-renders the reply.
    private func flushSoon() {
        guard !flushQueued else { return }
        flushQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in MainActor.assumeIsolated {
            guard let self else { return }
            self.flushQueued = false
            if !self.streamed.text.isEmpty { self.liveText += self.streamed.text }
            if !self.streamed.thinking.isEmpty { self.liveThinking += self.streamed.thinking }
            self.streamed = ("", "")
        } }
    }

    private func clearLive() {
        liveText = ""
        liveThinking = ""
        streamed = ("", "")
    }

    /// Only the last 20 images tools returned stay in memory; older cards drop theirs.
    private func trimResultImages(keep: Int = 20) {
        var kept = 0
        for i in items.indices.reversed() where !items[i].resultImages.isEmpty {
            if kept >= keep { items[i].resultImages = [] } else { kept += items[i].resultImages.count }
        }
    }

    private func setWorking(_ on: Bool) {
        guard working != on else { return }
        working = on
        report()
    }

    /// Tells the session list: working, waiting on a prompt, or idle at the input.
    private func report() {
        guard exited == nil else { return }
        store?.liveActivity(sessionID, lastLines: lastLines, exited: nil)
        store?.liveAgentState(sessionID, !asks.isEmpty ? .needsInput : (working ? .running : .idle))
    }

    /// The last reply's lines, for notifications and session cards.
    private var lastLines: [String] {
        guard let t = items.last(where: { $0.kind == .text }) else { return [] }
        return t.text.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(3)
    }

    private func updateTask(_ o: [String: Any]) {
        guard let id = o["task_id"] as? String,
              tasks.contains(where: { $0.id == id }) || o["subtype"] as? String == "task_started" else { return }
        var t = tasks.first { $0.id == id } ?? BackgroundTask(id: id, toolUseID: o["tool_use_id"] as? String ?? "", description: "", status: "running", summary: "", outputFile: "")
        if let d = o["description"] as? String, o["subtype"] as? String == "task_started" { t.description = d }
        if let d = o["description"] as? String, o["subtype"] as? String == "task_progress" { t.summary = d }
        if let s = o["summary"] as? String, !s.isEmpty { t.summary = s }
        if let s = o["status"] as? String { t.status = s }
        if let s = (o["patch"] as? [String: Any])?["status"] as? String { t.status = s }
        if let f = o["output_file"] as? String { t.outputFile = f }
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i] = t } else { tasks.append(t) }
        // Finished ones beyond the last 20 drop off.
        while tasks.count > 20, let i = tasks.firstIndex(where: { !$0.running }) { tasks.remove(at: i) }
    }

    /// A step anywhere under a Task card (subagents can start their own), by tool id.
    @discardableResult
    private func updateStep(_ id: String, _ change: (inout Item) -> Void) -> Bool {
        for i in items.indices.reversed() {
            if items[i].id == id { change(&items[i]); return true }
            for k in items[i].children.indices where items[i].children[k].id == id { change(&items[i].children[k]); return true }
            for k in items[i].children.indices {
                for j in items[i].children[k].children.indices where items[i].children[k].children[j].id == id {
                    change(&items[i].children[k].children[j]); return true
                }
            }
        }
        return false
    }

    private func noteEdit(_ toolID: String, _ name: String, _ input: [String: Any], _ diff: Diff?) {
        guard ["Edit", "MultiEdit", "Write"].contains(name), let path = input["file_path"] as? String, let diff, pendingEdits[toolID] == nil else { return }
        let n = DiffCount.count(diff)
        pendingEdits[toolID] = (path, n.added, n.removed)
    }

    /// An edit's result: a successful one counts in Agent Files; a denied or failed one doesn't.
    private func editDone(_ toolID: String, failed: Bool) {
        guard let e = pendingEdits.removeValue(forKey: toolID), !failed else { return }
        store?.chatEdited(sessionID, path: e.path, added: e.added, removed: e.removed)
    }

    // MARK: Parsing helpers

    /// A tool's output as kept for its card: a whole file read can run to megabytes.
    nonisolated static func capped(_ s: String, _ limit: Int = 20_000) -> String {
        s.utf8.count <= limit ? s : String(s.prefix(limit)) + "\n… cut at \(limit / 1000)k characters"
    }

    /// Why the process ended, in words: a missing CLI names it and says how to get it.
    nonisolated static func exitMessage(_ code: Int32, stderr: String, command: String) -> String {
        let why = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = command.split(separator: " ").first.map(String.init) ?? "claude"
        if code == 127 || why.contains("command not found: \(name)") {
            let install = AgentConfig.builtins.first { $0.id == "claude" }?.installCommand ?? ""
            return "Couldn't find \(name). Install Claude Code with `\(install)`, or set its full path in Customize → Agents."
        }
        return "Claude Code exited with code \(code)" + (why.isEmpty ? "." : ":\n" + String(why.suffix(600)))
    }

    /// Wrappers Claude Code puts around command echoes, hook output and notes it adds itself.
    nonisolated static let systemTags = ["<command-name>", "<command-message>", "<command-args>", "<local-command-stdout>", "<local-command-stderr>",
                                         "<local-command-caveat>", "<system-reminder>", "<bash-input>", "<bash-stdout>", "<bash-stderr>",
                                         "<user-prompt-submit-hook>", "<task-notification>", "<user-memory-input>"]

    /// A user message from a transcript as shown in the chat; nil for Claude's own
    /// tagged echoes. Your own text can start with "<" (`<div>` is broken) and still shows.
    nonisolated static func shownUserText(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // `!` output Brix sent ahead of your words: your words are the message.
        if t.hasPrefix("<bash-input>"), let r = t.range(of: "</bash-stderr>", options: .backwards) {
            t = t[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !t.isEmpty, !systemTags.contains(where: { t.hasPrefix($0) }) else { return nil }
        return t
    }

    /// A Write over a file that exists: the change against what's there now (read
    /// before Claude writes it), so it isn't counted as all new lines. nil for a new file.
    nonisolated static func writeDiff(_ input: [String: Any]) -> Diff? {
        guard let path = input["file_path"] as? String, let new = input["content"] as? String,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber, size.intValue < 2 << 20,
              let old = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Diff(old: old, new: new)
    }

    /// The text between `<local-command-stdout>` tags, if this is a command's output.
    nonisolated static func commandOutput(_ text: String) -> String? {
        guard let a = text.range(of: "<local-command-stdout>"), let b = text.range(of: "</local-command-stdout>", range: a.upperBound..<text.endIndex) else { return nil }
        let out = text[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// System messages worth a line in the chat. `output`: shown as formatted text.
    nonisolated static func notice(_ o: [String: Any]) -> (text: String, output: Bool)? {
        switch o["subtype"] as? String {
        case "local_command_output":
            let t = (o["content"] as? String) ?? (o["output"] as? String) ?? ""
            return t.isEmpty ? nil : (commandOutput(t) ?? t, true)
        case "compact_boundary":
            let pre = (o["compact_metadata"] as? [String: Any])?["pre_tokens"] as? Int ?? o["pre_tokens"] as? Int
            return ("Conversation compacted" + (pre.map { ", \($0 / 1000)k tokens before" } ?? ""), false)
        case "api_retry":
            let a = o["attempt"] as? Int, m = o["max_retries"] as? Int
            return ("API error, retrying" + (a.flatMap { a in m.map { " (\(a) of \($0))" } } ?? ""), false)
        case "model_fallback", "model_refusal_fallback":
            return ("Switched model" + ((o["to"] as? String ?? o["fallback_model"] as? String).map { " to \($0)" } ?? ""), false)
        case "informational", "notification":
            let t = (o["message"] as? String) ?? (o["text"] as? String) ?? ""
            return t.isEmpty ? nil : (t, false)
        case "permission_denied":
            return ("Not allowed" + ((o["tool_name"] as? String).map { ": \($0)" } ?? ""), false)
        default: return nil
        }
    }

    /// A "Yes, and …" choice in the words the terminal uses, and whether it's saved to a settings file.
    nonisolated static func suggestion(_ s: [String: Any], cwd: String) -> Suggestion? {
        let dest = s["destination"] as? String ?? "session"
        let saved = dest != "session" && dest != "cliArg"
        let whereSaved: String = switch dest {
        case "localSettings": " (saved in .claude/settings.local.json)"
        case "projectSettings": " (saved in .claude/settings.json, shared)"
        case "userSettings": " (saved for all projects)"
        default: " for this session"
        }
        switch s["type"] as? String {
        case "addRules":
            let rules = (s["rules"] as? [[String: Any]] ?? []).map { r in
                let tool = r["toolName"] as? String ?? ""
                return (r["ruleContent"] as? String).map { "\(tool)(\($0))" } ?? tool
            }
            guard s["behavior"] as? String ?? "allow" == "allow", !rules.isEmpty else { return nil }
            return Suggestion(label: "Yes, and don't ask again for " + rules.joined(separator: ", ") + whereSaved, raw: s, saved: saved)
        case "addDirectories":
            let dirs = (s["directories"] as? [String] ?? []).map { ($0 as NSString).abbreviatingWithTildeInPath }
            return dirs.isEmpty ? nil : Suggestion(label: "Yes, and allow access to " + dirs.joined(separator: ", ") + whereSaved, raw: s, saved: saved)
        case "setMode":
            let mode = s["mode"] as? String ?? ""
            let name = modes.first { $0.id == mode }?.name.lowercased() ?? mode
            return Suggestion(label: "Yes, and switch to \(name)" + whereSaved, raw: s, saved: saved)
        default: return nil
        }
    }

    /// `effortLevel` from your Claude settings (~/.claude/settings.json).
    nonisolated static func settingsEffort(home: String = NSHomeDirectory()) -> String {
        let f = home + "/.claude/settings.json"
        guard let d = FileManager.default.contents(atPath: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
        return o["effortLevel"] as? String ?? ""
    }

    // MARK: History

    /// A resumed conversation: its earlier messages, read from Claude's transcript.
    /// `until`: a fork's cut point; nothing after it is shown.
    private func loadHistory(_ id: String, until: String? = nil) {
        loadingHistory = true
        historyGeneration += 1
        let gen = historyGeneration
        let cwd = cwd
        Task {
            let earlier = await Task.detached(priority: .userInitiated) { () -> [Item]? in
                guard let url = AgentTranscripts.transcriptURL(sessionID: id, home: NSHomeDirectory()) else { return nil }
                return Self.history(url, cwd: cwd, until: until)
            }.value
            // A new conversation or a rewind came first: this history isn't this chat's any more.
            guard gen == historyGeneration else { return }
            lastAssistant = lastAssistant ?? earlier?.last(where: { $0.kind != .user && $0.uuid != nil })?.uuid
            loadingHistory = false
            guard let earlier, !earlier.isEmpty else {
                items.insert(Item(id: "n-nohistory", kind: .notice, text: earlier == nil
                    ? "Continued an earlier conversation; its history couldn't be read."
                    : "Continued an earlier conversation; nothing in its history could be shown."), at: 0)
                return
            }
            items.insert(contentsOf: earlier + [Item(id: "n-resumed", kind: .notice, text: "Continued here")], at: 0)
        }
    }

    /// The last `limit` items of a transcript. Only its tail is read: transcripts
    /// run to hundreds of MB, and the start of a long one isn't what you came back for.
    /// nil when the file can't be read.
    nonisolated static func history(_ url: URL, cwd: String, limit: Int = 400, tailBytes: UInt64 = 12 << 20, until: String? = nil) -> [Item]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let start = size > tailBytes ? size - tailBytes : 0
        guard (try? h.seek(toOffset: start)) != nil, var data = try? h.readToEnd() else { return nil }
        // Started mid-line: drop the partial first line.
        if start > 0, let nl = data.firstIndex(of: 0x0A) { data = data[data.index(after: nl)...] }
        var out: [Item] = []
        var lastAssistant: String?
        // Read from the middle: what came before the first message shown isn't known.
        let known = start == 0
        var matched = until == nil
        for line in data.split(separator: 0x0A) {
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let until, lastAssistant == until, o["uuid"] as? String != until { break }
            if o["uuid"] as? String == until { matched = true }
            guard o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true, o["isCompactSummary"] as? Bool != true,
                  let m = o["message"] as? [String: Any] else { continue }
            let uuid = o["uuid"] as? String ?? UUID().uuidString
            switch o["type"] as? String {
            case "user":
                if let t = m["content"] as? String {
                    if let text = Self.shownUserText(t) { out.append(Item(id: "h-\(uuid)", kind: .user, text: text, uuid: uuid, before: lastAssistant, cutKnown: known || lastAssistant != nil)) }
                    continue
                }
                guard let parts = m["content"] as? [[String: Any]] else { continue }
                var text = "", images: [Attachment] = [], label = 0
                for c in parts {
                    switch c["type"] as? String {
                    case "tool_result":
                        if let id = c["tool_use_id"] as? String, let i = out.lastIndex(where: { $0.id == id }) {
                            out[i].result = Self.capped(Self.text(of: c["content"]))
                            out[i].failed = c["is_error"] as? Bool == true
                        }
                    case "text":
                        let t = c["text"] as? String ?? ""
                        if t.hasPrefix("[Request interrupted") { out.append(Item(id: "h-\(uuid)-i", kind: .notice, text: "Interrupted")) }
                        else if Self.isImageLabel(t) { label = Int(t.filter(\.isNumber)) ?? 0 }
                        else if let t = Self.shownUserText(t) { text += (text.isEmpty ? "" : "\n") + t }
                    case "image":
                        if let src = c["source"] as? [String: Any], let b = src["data"] as? String, let d = Data(base64Encoded: b) {
                            images.append(Attachment(data: d, mediaType: src["media_type"] as? String ?? "image/png", number: label))
                        }
                        label = 0
                    default: break
                    }
                }
                if !text.isEmpty || !images.isEmpty { out.append(Item(id: "h-\(uuid)", kind: .user, text: text, images: images, uuid: uuid, before: lastAssistant, cutKnown: known || lastAssistant != nil)) }
            case "assistant":
                lastAssistant = uuid
                guard let parts = m["content"] as? [[String: Any]] else { continue }
                for (k, c) in parts.enumerated() {
                    switch c["type"] as? String {
                    case "text":
                        let t = (c["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { out.append(Item(id: "h-\(uuid)-\(k)", kind: o["isApiErrorMessage"] as? Bool == true ? .error : .text, text: t, uuid: uuid)) }
                    case "tool_use":
                        let name = c["name"] as? String ?? "Tool"
                        let s = describe(name, c["input"] as? [String: Any] ?? [:], cwd: cwd)
                        out.append(Item(id: c["id"] as? String ?? "h-\(uuid)-\(k)", kind: .tool, text: s.summary, tool: name, detail: s.detail, diff: s.diff, result: "", uuid: uuid))
                    default: break
                    }
                }
            default: break
            }
        }
        if !matched { out.append(Item(id: "n-nocut", kind: .notice, text: "The point this copy was made at wasn't found; showing the most recent messages.")) }
        // A resumed or forked transcript can repeat an id; rows need unique ones.
        var seen = Set<String>()
        for i in out.indices where !seen.insert(out[i].id).inserted { out[i] = out[i].renamed("\(out[i].id)-\(i)") }
        return Array(out.suffix(limit))
    }

    // MARK: Images

    /// An image ready to send: scaled to at most 1568 px on its long side (larger
    /// is scaled down by Claude anyway), PNG, or JPEG when the PNG is big.
    nonisolated static func attachment(_ image: NSImage) -> Attachment? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let longest = max(cg.width, cg.height), limit = 1568
        var rep = NSBitmapImageRep(cgImage: cg)
        if longest > limit {
            let scale = Double(limit) / Double(longest)
            let w = Int(Double(cg.width) * scale), h = Int(Double(cg.height) * scale)
            guard let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
            NSGraphicsContext.current?.imageInterpolation = .high
            NSImage(cgImage: cg, size: .zero).draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            rep = small
        }
        if let png = rep.representation(using: .png, properties: [:]), png.count < 3_500_000 {
            return Attachment(data: png, mediaType: "image/png")
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]).map { Attachment(data: $0, mediaType: "image/jpeg") }
    }

    /// Images on the pasteboard: copied image files first, else image data when
    /// there's no text (text copied from a web page can carry an image too).
    nonisolated static func images(on pb: NSPasteboard) -> [NSImage] {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !urls.isEmpty { return urls.compactMap(NSImage.init(contentsOf:)) }
        if pb.string(forType: .string) != nil { return [] }
        return (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? []
    }

    // MARK: Describing tools

    nonisolated static func describe(_ name: String, _ input: [String: Any], cwd: String) -> (summary: String, detail: String, diff: Diff?) {
        func str(_ k: String) -> String { input[k] as? String ?? "" }
        func rel(_ path: String) -> String {
            let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : (path as NSString).abbreviatingWithTildeInPath
        }
        switch name {
        case "Bash": return (str("description").isEmpty ? str("command") : str("description"), str("command"), nil)
        case "Read": return (rel(str("file_path")), "", nil)
        case "Write": return (rel(str("file_path")), "", Diff(old: "", new: str("content")))
        case "Edit": return (rel(str("file_path")), "", Diff(old: str("old_string"), new: str("new_string")))
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return (rel(str("file_path")), "", Diff(old: edits.map { $0["old_string"] as? String ?? "" }.joined(separator: "\n…\n"),
                                                    new: edits.map { $0["new_string"] as? String ?? "" }.joined(separator: "\n…\n")))
        case "Grep", "Glob": return (str("pattern") + (str("path").isEmpty ? "" : " in " + rel(str("path"))), "", nil)
        case "WebFetch": return (str("url"), str("prompt"), nil)
        case "WebSearch": return (str("query"), "", nil)
        case "Task", "Agent": return (str("description"), str("prompt"), nil)
        case "ExitPlanMode": return ("Plan ready", str("plan"), nil)
        case "AskUserQuestion": return ("Question", "", nil)
        case "TodoWrite": return ("Task list", (input["todos"] as? [[String: Any]] ?? []).map { "• " + ($0["content"] as? String ?? "") }.joined(separator: "\n"), nil)
        case "TaskCreate": return (str("subject"), str("description"), nil)
        case "TaskUpdate": return ("Task \(str("taskId")) " + str("status"), "", nil)
        default:
            let body = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return (name.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " · "), body, nil)
        }
    }

    nonisolated static func images(of content: Any?) -> [Data] {
        ((content as? [[String: Any]]) ?? []).compactMap { p in
            guard p["type"] as? String == "image", let b = (p["source"] as? [String: Any])?["data"] as? String else { return nil }
            return Data(base64Encoded: b)
        }
    }

    nonisolated static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return ""
    }
}

/// Owns the chat sessions, like TerminalRegistry owns terminal views.
@MainActor
final class ClaudeChatRegistry {
    static let shared = ClaudeChatRegistry()
    private var chats: [String: ClaudeChat] = [:]

    func start(sessionID: String, command: String, cwd: String, env: [String: String], store: AppStore) {
        let c = ClaudeChat(sessionID: sessionID, cwd: cwd, store: store)
        chats[sessionID] = c
        c.start(command: command, env: env)
    }

    func chat(_ id: String) -> ClaudeChat? { chats[id] }

    func stop(_ id: String) { chats.removeValue(forKey: id)?.stop() }
    func stopAll() { chats.keys.forEach(stop) }
}

/// Lines an edit adds and removes, for Agent Files.
enum DiffCount {
    static func count(_ d: ClaudeChat.Diff) -> (added: Int, removed: Int) {
        let lines = DiffBlock.lines(d)
        return (lines.filter { $0.0 == "+" }.count, lines.filter { $0.0 == "-" }.count)
    }
}
