import Foundation
import Observation

/// A Claude Code session driven through its stream-json mode instead of its
/// terminal screen: Brix sends messages and answers permission prompts as JSON
/// lines on stdin, and reads every event (text as it streams, tool calls, tool
/// results, prompts) from stdout. The conversation is saved by Claude as usual,
/// so plans, titles and resume keep working.
@MainActor
@Observable
final class ClaudeChat {
    struct Diff: Equatable { var old: String; var new: String }

    struct Item: Identifiable {
        enum Kind { case user, text, thinking, tool, error, notice }
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
        var suggestions: [Any] = []
    }

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
    let cwd: String

    weak var store: AppStore?
    private var process: Process?
    private var input: FileHandle?
    private var pending = Data()
    private var stderrTail = ""
    private var interrupting = false
    /// Messages sent whose turn hasn't ended; each one gets its own result.
    private var turns = 0
    /// Writes go out off the main thread: a long message into a full pipe would block the window.
    private let writer = DispatchQueue(label: "brix.claude-chat.write")

    init(sessionID: String, cwd: String, store: AppStore) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.store = store
    }

    static let flags = " --print --input-format stream-json --output-format stream-json --verbose --include-partial-messages --permission-prompt-tool stdio"

    /// `command` is the usual launch line (session id, resume, system prompt); it
    /// runs through a login shell like a terminal session, so PATH matches.
    func start(command: String, env: [String: String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "exec " + command + Self.flags]
        p.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory())
        p.environment = ProcessRunner.environment(extra: env)
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(d) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.stderrTail = String((self?.stderrTail ?? "") .appending(String(decoding: d, as: UTF8.self)).suffix(2000)) } }
        }
        p.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            // Its last stderr lines (the reason) arrive on their own handler: let them land first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { self?.ended(code) } }
        }
        do {
            try ProcessRunner.spawnLock.withLock {
                ProcessRunner.markAllCloseOnExec()
                try p.run()
            }
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            items.append(Item(id: "err-start", kind: .error, text: "Couldn't start Claude Code: \(error.localizedDescription)"))
            exited = -1
            store?.liveActivity(sessionID, lastLines: [], exited: -1)
            return
        }
        process = p
        input = inp.fileHandleForWriting
        write(["type": "control_request", "request_id": "init", "request": ["subtype": "initialize"]])
        if command.contains(" --resume ") {
            items.append(Item(id: "n-resumed", kind: .notice, text: "Continued an earlier conversation. Its history isn't shown here yet; turn the chat view off to see it in the terminal."))
        }
    }

    var pid: pid_t? { process.map(\.processIdentifier).flatMap { $0 > 0 ? $0 : nil } }
    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: Sending

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, exited == nil else { return }
        items.append(Item(id: "u-\(UUID().uuidString)", kind: .user, text: t))
        write(["type": "user", "message": ["role": "user", "content": t]])
        interrupting = false
        turns += 1
        setWorking(true)
    }

    func interrupt() {
        guard working else { return }
        interrupting = true
        // Whatever it was asking is moot once the turn stops.
        asks = []
        report()
        write(["type": "control_request", "request_id": "int-\(UUID().uuidString)", "request": ["subtype": "interrupt"]])
    }

    func allow(_ ask: Ask, always: Bool = false) {
        var r: [String: Any] = ["behavior": "allow", "updatedInput": ask.input]
        if always, !ask.suggestions.isEmpty { r["updatedPermissions"] = ask.suggestions }
        reply(ask, r)
    }

    func deny(_ ask: Ask, message: String = "The user denied this. Ask them what to do instead.") {
        reply(ask, ["behavior": "deny", "message": message])
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
        switch o["type"] as? String {
        case "system":
            if o["subtype"] as? String == "init" {
                model = o["model"] as? String ?? model
                permissionMode = o["permissionMode"] as? String ?? permissionMode
            } else if o["subtype"] as? String == "status", o["status"] as? String == "requesting", !working {
                // A turn Claude started itself (a background task finished).
                turns = max(turns, 1)
                setWorking(true)
            }
        case "stream_event":
            guard o["parent_tool_use_id"] is NSNull || o["parent_tool_use_id"] == nil,
                  let e = o["event"] as? [String: Any] else { return }
            if e["type"] as? String == "content_block_delta", let d = e["delta"] as? [String: Any] {
                if let t = d["text"] as? String { liveText += t }
                if let t = d["thinking"] as? String { liveThinking += t }
            }
        case "assistant":
            liveText = ""
            liveThinking = ""
            // A subagent's own steps stay inside its Task card.
            guard o["parent_tool_use_id"] is NSNull || o["parent_tool_use_id"] == nil,
                  let m = o["message"] as? [String: Any], let parts = m["content"] as? [[String: Any]] else { return }
            let isError = o["is_api_error_message"] as? Bool == true
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
                    items.append(Item(id: c["id"] as? String ?? id, kind: .tool, text: s.summary, tool: name, detail: s.detail, diff: s.diff))
                default: break
                }
            }
            report()
        case "user":
            guard o["parent_tool_use_id"] is NSNull || o["parent_tool_use_id"] == nil,
                  let m = o["message"] as? [String: Any], let parts = m["content"] as? [[String: Any]] else { return }
            for c in parts {
                if c["type"] as? String == "tool_result", let id = c["tool_use_id"] as? String,
                   let i = items.lastIndex(where: { $0.id == id }) {
                    items[i].result = Self.text(of: c["content"])
                    items[i].failed = c["is_error"] as? Bool == true
                } else if c["type"] as? String == "text", let t = c["text"] as? String, t.hasPrefix("[Request interrupted") {
                    items.append(Item(id: "n-\(UUID().uuidString)", kind: .notice, text: "Interrupted"))
                }
            }
        case "result":
            liveText = ""
            liveThinking = ""
            if interrupting {
                // Stopped on purpose: not an error.
                if items.last?.kind != .notice { items.append(Item(id: "n-\(UUID().uuidString)", kind: .notice, text: "Interrupted")) }
            } else if o["subtype"] as? String != "success" {
                let why = (o["errors"] as? [String])?.joined(separator: "\n") ?? (o["result"] as? String) ?? (o["subtype"] as? String ?? "")
                items.append(Item(id: "r-\(UUID().uuidString)", kind: .error, text: why.isEmpty ? "The turn ended with an error." : why))
            }
            interrupting = false
            turns = max(0, turns - 1)
            if turns == 0 { setWorking(false) }
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
                                input: input, suggestions: r["permission_suggestions"] as? [Any] ?? []))
                report()
            } else {
                // Hooks and SDK MCP servers aren't registered here; say so rather than leave it waiting.
                write(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Not supported by Brix"]])
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
        turns = 0
        interrupting = false
        asks = []
        if code != 0 {
            let why = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(Item(id: "x-\(UUID().uuidString)", kind: .error,
                              text: "Claude Code exited with code \(code)" + (why.isEmpty ? "." : ":\n" + String(why.suffix(600)))))
        }
        store?.liveActivity(sessionID, lastLines: lastLines, exited: code)
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

    // MARK: Describing tools

    static func describe(_ name: String, _ input: [String: Any], cwd: String) -> (summary: String, detail: String, diff: Diff?) {
        func str(_ k: String) -> String { input[k] as? String ?? "" }
        func rel(_ path: String) -> String {
            let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : (path as NSString).abbreviatingWithTildeInPath
        }
        switch name {
        case "Bash": return (str("description").isEmpty ? str("command") : str("description"), str("command"), nil)
        case "Read": return (rel(str("file_path")), "", nil)
        case "Write": return (rel(str("file_path")), str("content"), nil)
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

    static func text(of content: Any?) -> String {
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
