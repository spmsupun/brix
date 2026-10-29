import Foundation

/// A past or running agent conversation found on disk, in Brix or not.
struct AgentHistoryEntry: Identifiable, Hashable {
    var id: String
    /// "claude" or "codex".
    var agent: String
    var title: String?
    var firstPrompt: String?
    var cwd: String
    var branch: String?
    var started: Date?
    var lastActivity: Date
    var bytes: Int
    var file: URL

    var displayTitle: String { title ?? firstPrompt ?? "Untitled session" }
}

/// Reads Claude Code and Codex transcripts. Read-only, and reads only the head
/// and tail of each file so multi-megabyte transcripts stay cheap.
enum AgentTranscripts {
    static let window = 256 * 1024

    /// Parsed transcripts by path, size and modification date: an unchanged
    /// file is never read twice.
    final class Cache<T>: @unchecked Sendable {
        private var items: [String: (stamp: String, value: T?)] = [:]
        private let lock = NSLock()
        func value(_ url: URL, _ make: () -> T?) -> T? {
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let stamp = "\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            lock.lock()
            if let hit = items[url.path], hit.stamp == stamp { lock.unlock(); return hit.value }
            lock.unlock()
            let made = make()
            lock.lock(); items[url.path] = (stamp, made); lock.unlock()
            return made
        }
    }
    static let entries = Cache<AgentHistoryEntry>()
    static let statsCache = Cache<TranscriptStats>()

    // MARK: Claude Code

    /// ~/.claude/projects/<path with every non-alphanumeric as "-">/<session>.jsonl
    static func claudeFolderName(_ path: String) -> String {
        String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    static func claudeSessions(projectPath: String, home: String = NSHomeDirectory()) -> [AgentHistoryEntry] {
        let root = URL(fileURLWithPath: home + "/.claude/projects")
        let base = claudeFolderName(projectPath)
        let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0 == base || $0.hasPrefix(base + "-") }
        var out: [AgentHistoryEntry] = []
        for d in dirs {
            let dir = root.appendingPathComponent(d)
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            where f.pathExtension == "jsonl" {
                guard let e = entries.value(f, { claudeEntry(f) }), e.cwd == projectPath || e.cwd.hasPrefix(projectPath + "/") else { continue }
                out.append(e)
            }
        }
        return out.sorted { $0.lastActivity > $1.lastActivity }
    }

    static func claudeEntry(_ url: URL) -> AgentHistoryEntry? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let (head, tail) = headTail(url)
        var cwd: String?, branch: String?, started: Date?, prompt: String?, title: String?, custom: String?
        for line in head {
            guard let o = json(line) else { continue }
            let type = o["type"] as? String
            // Scripted `claude -p` and Agent SDK runs ("sdk-cli", "sdk-ts", ...)
            // aren't conversations; Claude Code's /resume hides them too.
            if type == "user", (o["entrypoint"] as? String)?.hasPrefix("sdk") == true { return nil }
            if type == "user", cwd == nil || prompt == nil {
                cwd = cwd ?? o["cwd"] as? String
                branch = branch ?? o["gitBranch"] as? String
                started = started ?? (o["timestamp"] as? String).flatMap(parseDate)
                if prompt == nil, o["isMeta"] as? Bool != true, let text = userText(o["message"]) { prompt = text }
            }
        }
        for line in head + tail {
            guard line.contains("-title\"") || line.contains("Title\""), let o = json(line) else { continue }
            if let t = o["customTitle"] as? String { custom = t }
            if let t = o["aiTitle"] as? String { title = t }
        }
        guard let cwd else { return nil }
        return AgentHistoryEntry(id: url.deletingPathExtension().lastPathComponent, agent: "claude", title: custom ?? title, firstPrompt: prompt,
                                 cwd: cwd, branch: branch, started: started, lastActivity: values?.contentModificationDate ?? .distantPast,
                                 bytes: values?.fileSize ?? 0, file: url)
    }

    static func claudeTranscriptExists(sessionID: String, home: String = NSHomeDirectory()) -> Bool {
        let root = home + "/.claude/projects"
        return ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).contains {
            FileManager.default.fileExists(atPath: "\(root)/\($0)/\(sessionID).jsonl")
        }
    }

    /// Title for a running Claude Code conversation (custom name first, then its own).
    static func claudeTitle(sessionID: String, home: String = NSHomeDirectory()) -> String? {
        let root = home + "/.claude/projects"
        for d in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let f = URL(fileURLWithPath: "\(root)/\(d)/\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: f.path) { return claudeEntry(f)?.title }
        }
        return nil
    }

    // MARK: Plan

    /// The task list Claude keeps for a conversation (TaskCreate / TaskUpdate,
    /// or the older TodoWrite), read from its transcript. Transcripts can run to
    /// hundreds of MB, so each file is read once and then only its new bytes.
    static func claudePlan(sessionID: String, home: String = NSHomeDirectory()) -> [PlanItem]? {
        guard let url = transcriptURL(sessionID: sessionID, home: home) else { return nil }
        return planReader.read(url)
    }

    private static var urlByID: [String: URL] = [:]
    private static let urlLock = NSLock()

    static func transcriptURL(sessionID: String, home: String) -> URL? {
        urlLock.lock(); defer { urlLock.unlock() }
        if let u = urlByID[sessionID], FileManager.default.fileExists(atPath: u.path) { return u }
        let root = home + "/.claude/projects"
        for d in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let f = URL(fileURLWithPath: "\(root)/\(d)/\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: f.path) { urlByID[sessionID] = f; return f }
        }
        return nil
    }

    static let planReader = PlanReader()

    final class PlanReader: @unchecked Sendable {
        private struct State { var offset: UInt64 = 0; var tail = Data(); var tasks: [(id: String, title: String, status: String)] = [] }
        private var files: [String: State] = [:]
        private let lock = NSLock()

        func read(_ url: URL) -> [PlanItem]? {
            lock.lock(); defer { lock.unlock() }
            var st = files[url.path] ?? State()
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            if size < st.offset { st = State() }  // rewritten: start over
            try? h.seek(toOffset: st.offset)
            // In 8 MB pieces, so a 400 MB transcript never sits in memory whole.
            while true {
                let piece = autoreleasepool { (try? h.read(upToCount: 8 << 20)) ?? Data() }
                if piece.isEmpty { break }
                let chunk = st.tail + piece
                // Keep an unfinished last line for the next piece (or the next read).
                if let lastNL = chunk.lastIndex(of: 0x0A) {
                    Self.apply(chunk[..<lastNL], to: &st.tasks)
                    st.tail = Data(chunk[chunk.index(after: lastNL)...])
                } else {
                    st.tail = chunk
                }
            }
            st.offset = size
            files[url.path] = st
            return st.tasks.isEmpty ? nil : st.tasks.map { PlanItem(title: $0.title, done: $0.status == "completed", active: $0.status == "in_progress") }
        }

        /// The lines that call a task tool or report a created task, found with a
        /// byte search that jumps from match to match: almost every line is chat.
        static func matchingLines(_ data: Data.SubSequence) -> [Data.SubSequence] {
            var out: [Data.SubSequence] = []
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                guard let base = buf.baseAddress else { return }
                let n = buf.count
                // The tool calls and the creation result; each needle's next hit is
                // remembered so the buffer is scanned once per needle, not per line.
                let needles = [#""name":"Task"#, #""name":"TodoWrite"#, "created successfully: "].map { Array($0.utf8) }
                func next(_ k: Int, from: Int) -> Int {
                    guard from < n else { return n }
                    return needles[k].withUnsafeBytes { nd in
                        memmem(base + from, n - from, nd.baseAddress, nd.count).map { base.distance(to: UnsafeRawPointer($0)) } ?? n
                    }
                }
                var hits = needles.indices.map { next($0, from: 0) }
                var lineStart = 0, at = 0
                while at < n {
                    for k in hits.indices where hits[k] < at { hits[k] = next(k, from: at) }
                    let pos = hits.min() ?? n
                    if pos >= n { break }
                    // Widen to the whole line around the match.
                    var s = pos
                    while s > lineStart, buf[s - 1] != 0x0A { s -= 1 }
                    var e = pos
                    while e < n, buf[e] != 0x0A { e += 1 }
                    out.append(data[data.startIndex + s ..< data.startIndex + e])
                    lineStart = min(e + 1, n)
                    at = lineStart
                }
            }
            return out
        }

        static func apply(_ data: Data.SubSequence, to tasks: inout [(id: String, title: String, status: String)]) {
            for line in matchingLines(data) {
                guard let text = String(data: Data(line), encoding: .utf8),
                      let o = json(text), let m = o["message"] as? [String: Any], let parts = m["content"] as? [[String: Any]] else { continue }
                for c in parts {
                    if c["type"] as? String == "tool_use", let input = c["input"] as? [String: Any] {
                        switch c["name"] as? String {
                        case "TodoWrite":
                            let todos = input["todos"] as? [[String: Any]] ?? []
                            tasks = todos.enumerated().map { i, t in ("\(i + 1)", t["content"] as? String ?? "", t["status"] as? String ?? "pending") }
                        case "TaskUpdate":
                            guard let id = input["taskId"] as? String, let i = tasks.firstIndex(where: { $0.id == id }) else { continue }
                            if let st = input["status"] as? String {
                                if st == "deleted" { tasks.remove(at: i); continue }
                                tasks[i].status = st
                            }
                            if let t = input["subject"] as? String { tasks[i].title = t }
                        default: break
                        }
                    }
                    // A task's number comes back in its result: "Task #3 created successfully: Subject".
                    if c["type"] as? String == "tool_result" {
                        let body = (c["content"] as? String) ?? ((c["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()) ?? ""
                        guard let r = body.range(of: #"Task #(\d+) created successfully: "#, options: .regularExpression) else { continue }
                        let id = body[r].filter(\.isNumber)
                        let title = String(body[r.upperBound...]).components(separatedBy: "\n").first ?? ""
                        if !tasks.contains(where: { $0.id == id }) { tasks.append((String(id), title, "pending")) }
                    }
                }
            }
        }
    }

    /// The conversation a running Claude Code process is on now. Claude keeps
    /// ~/.claude/sessions/<pid>.json current, so this follows a /resume inside it.
    static func claudeLiveSessionID(pid: pid_t, home: String = NSHomeDirectory()) -> String? {
        guard pid > 0, let data = FileManager.default.contents(atPath: "\(home)/.claude/sessions/\(pid).json"),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["pid"] as? NSNumber)?.int32Value == pid, let id = o["sessionId"] as? String, AgentConfig.isSafeID(id) else { return nil }
        return id
    }

    private static func userText(_ message: Any?) -> String? {
        let m = message as? [String: Any]
        var text: String?
        if let s = m?["content"] as? String { text = s }
        if let parts = m?["content"] as? [[String: Any]] { text = parts.first { $0["type"] as? String == "text" }?["text"] as? String }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") else { return nil }
        return String(t.prefix(200))
    }

    // MARK: Codex

    static func codexSessions(projectPath: String, home: String = NSHomeDirectory()) -> [AgentHistoryEntry] {
        let root = URL(fileURLWithPath: home + "/.codex/sessions")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }
        let names = codexNames(home: home)
        var out: [AgentHistoryEntry] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard var e = entries.value(url, { codexEntry(url) }), e.cwd == projectPath || e.cwd.hasPrefix(projectPath + "/") else { continue }
            e.title = names[e.id]
            out.append(e)
        }
        return out.sorted { $0.lastActivity > $1.lastActivity }
    }

    static func codexEntry(_ url: URL) -> AgentHistoryEntry? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 64 * 1024)) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard let first = lines.first.flatMap(json), first["type"] as? String == "session_meta",
              let meta = first["payload"] as? [String: Any], let id = meta["id"] as? String, let cwd = meta["cwd"] as? String else { return nil }
        var prompt: String?
        for line in lines.dropFirst() where line.contains("\"role\":\"user\"") {
            guard let o = json(line), let p = o["payload"] as? [String: Any],
                  let text = (p["content"] as? [[String: Any]])?.first?["text"] as? String else { continue }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("#") { prompt = String(t.prefix(200)); break }
        }
        return AgentHistoryEntry(id: id, agent: "codex", title: nil, firstPrompt: prompt, cwd: cwd, branch: (meta["git"] as? [String: Any])?["branch"] as? String,
                                 started: (meta["timestamp"] as? String).flatMap(parseDate), lastActivity: values?.contentModificationDate ?? .distantPast,
                                 bytes: values?.fileSize ?? 0, file: url)
    }

    /// Thread names from ~/.codex/session_index.jsonl (last entry per id wins).
    static func codexNames(home: String) -> [String: String] {
        guard let s = try? String(contentsOfFile: home + "/.codex/session_index.jsonl", encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in s.split(separator: "\n") {
            if let o = json(String(line)), let id = o["id"] as? String, let n = o["thread_name"] as? String, !n.isEmpty { out[id] = n }
        }
        return out
    }

    // MARK: Helpers

    static func headTail(_ url: URL) -> (head: [String], tail: [String]) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return ([], []) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: 0)
        let head = (try? h.read(upToCount: window)) ?? Data()
        var tail = Data()
        if size > UInt64(window) {
            try? h.seek(toOffset: max(UInt64(window), size - UInt64(window)))
            tail = (try? h.readToEnd()) ?? Data()
        }
        func lines(_ d: Data) -> [String] { String(decoding: d, as: UTF8.self).split(separator: "\n").map(String.init) }
        return (lines(head), lines(tail))
    }

    static func json(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
