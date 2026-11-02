import Foundation

struct ProcessOutput {
    var stdout: String
    var stderr: String
    var status: Int32
    var ok: Bool { status == 0 }
}

/// A tool ran past its timeout and was stopped; `partial` holds what it printed until then.
struct ProcessTimeout: LocalizedError, CustomStringConvertible {
    var message: String
    var partial: ProcessOutput
    var errorDescription: String? { message }
    /// Just the message where an error is printed, never the output.
    var description: String { message }
}

/// Runs the cancel action once, whether the task is cancelled before or after it's set.
private final class CancelHook: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (() -> Void)?

    func set(_ a: @escaping () -> Void) {
        let now = lock.withLock { () -> Bool in
            if !cancelled { action = a }
            return cancelled
        }
        if now { a() }
    }

    func fire() {
        let a = lock.withLock { () -> (() -> Void)? in
            cancelled = true
            defer { action = nil }
            return action
        }
        a?()
    }
}

/// Runs a command-line tool off the main thread with a hard timeout.
enum ProcessRunner {
    /// Login-shell PATH so tools from Homebrew, nvm and similar are found even
    /// when Brix is launched from Finder.
    static let searchPath: String = {
        // Keg-only database clients from Homebrew and Postgres.app are included so
        // dump and restore find pg_dump and mysqldump without PATH changes.
        let base = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                    NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.claude/local",
                    "/opt/homebrew/opt/libpq/bin", "/opt/homebrew/opt/mysql-client/bin", "/opt/homebrew/opt/mysql/bin",
                    "/usr/local/opt/libpq/bin", "/usr/local/opt/mysql-client/bin", "/Applications/Postgres.app/Contents/Versions/latest/bin"]
        let env = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (base + env).filter { seen.insert($0).inserted }.joined(separator: ":")
    }()

    /// Terminals start with forkpty, which hands the child every open descriptor.
    /// An agent holding the write end of a tool's output pipe keeps
    /// `readDataToEndOfFile` waiting forever, one worker thread each, until GCD
    /// runs out of threads and Brix stops responding. Pipes are made
    /// close-on-exec as they are created, under the lock a terminal holds while
    /// it marks every other descriptor and forks.
    static let spawnLock = NSLock()

    static func pipe() -> Pipe {
        spawnLock.withLock {
            let p = Pipe()
            for h in [p.fileHandleForReading, p.fileHandleForWriting] { closeOnExec(h.fileDescriptor) }
            return p
        }
    }

    /// ponytail: descriptors opened elsewhere between this sweep and the fork
    /// (a socket, say) can still reach the child; only pipes made by `pipe()`
    /// are covered for certain.
    static func markAllCloseOnExec() {
        for fd in 3..<min(getdtablesize(), 1 << 16) { closeOnExec(fd) }
    }

    private static func closeOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0, flags & FD_CLOEXEC == 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
    }

    static func which(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        for dir in searchPath.split(separator: ":") {
            let p = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Brix started from inside a Claude Code session inherits its session
        // markers; passed on, agents in Brix think they're its children
        // ("Transcript saving is off"). Settings Claude reads itself still apply.
        for k in env.keys where k == "CLAUDECODE" || k == "CLAUDE_PID" || k.hasPrefix("CLAUDE_CODE_") { env[k] = nil }
        env["PATH"] = searchPath
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["GIT_TERMINAL_PROMPT"] = "0"
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Output past this much per stream is read and dropped, so a runaway
    /// command can't grow Brix's memory without bound.
    static let outputCap = 32 << 20

    /// Throws `CancellationError` when the calling task is cancelled, and
    /// `ProcessTimeout` (with what was printed so far) on the timeout. Either way
    /// the tool and everything it started are stopped.
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil, env: [String: String] = [:], input: String? = nil, timeout: TimeInterval = 30) async throws -> ProcessOutput {
        guard let exe = which(tool) else { throw ServiceError("\(tool) was not found. Install it or add it to your PATH.") }
        let cancel = CancelHook()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: exe)
                    p.arguments = args
                    if let cwd { p.currentDirectoryURL = cwd }
                    p.environment = environment(extra: env)
                    let out = pipe(), err = pipe()
                    p.standardOutput = out
                    p.standardError = err
                    let inPipe = pipe()
                    p.standardInput = inPipe

                    // Nothing here blocks a thread. Blocking reads and waitUntilExit held
                    // three GCD workers per tool; with about 20 tools at once (git for
                    // every repository at launch) all 64 workers were waiting for
                    // readers that could never be scheduled, and Brix stalled.
                    // Reads, exit and teardown all run on this one queue, so a pipe is
                    // never closed while a read on it is under way.
                    let q = DispatchQueue(label: "brix.process")
                    var outData = Data(), errData = Data(), done = false, waiting = 3, dropped = false
                    var sources: [DispatchSourceRead] = []
                    var timer: DispatchWorkItem?
                    func output(status: Int32) -> ProcessOutput {
                        let note = dropped ? "\n[\(tool) printed more than \(outputCap >> 20) MB; the rest was dropped]" : ""
                        return ProcessOutput(stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self) + note, status: status)
                    }
                    // Resumes once: on exit plus end of output, the timeout, or cancellation.
                    // Cancelling a source closes its pipe (in its cancel handler) and
                    // drops the work item's hold on the rest, which held hundreds of
                    // descriptors open for the full timeout after a fast exit.
                    func finish(_ r: Result<ProcessOutput, Error>) {
                        guard !done else { return }
                        done = true
                        timer?.cancel()
                        sources.forEach { $0.cancel() }
                        cont.resume(with: r)
                    }
                    func ended() {
                        waiting -= 1
                        if waiting == 0 { finish(.success(output(status: p.terminationStatus))) }
                    }
                    // Process starts the tool in its own process group: stop the whole
                    // group, so a child it started doesn't outlive it.
                    func stop() {
                        let group = p.processIdentifier
                        guard group > 0 else { return }
                        killpg(group, SIGTERM)
                        q.asyncAfter(deadline: .now() + 2) { killpg(group, SIGKILL) }
                    }

                    for (h, isOut) in [(out.fileHandleForReading, true), (err.fileHandleForReading, false)] {
                        let fd = h.fileDescriptor
                        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
                        src.setEventHandler {
                            var buf = [UInt8](repeating: 0, count: 65_536)
                            let n = read(fd, &buf, buf.count)
                            if n > 0 {
                                let room = outputCap - (isOut ? outData.count : errData.count)
                                if room > 0 {
                                    if isOut { outData.append(buf, count: min(n, room)) } else { errData.append(buf, count: min(n, room)) }
                                }
                                if n > room { dropped = true }
                            } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                                src.cancel()
                                ended()
                            }
                        }
                        src.setCancelHandler { try? h.close() }
                        sources.append(src)
                        src.resume()
                    }
                    p.terminationHandler = { _ in q.async { ended() } }

                    // Armed before stdin is written, which can block on a tool that never reads it.
                    // Also fires when the tool exited but something it started still holds its output open.
                    let t = DispatchWorkItem {
                        stop()
                        finish(.failure(ProcessTimeout(message: "\(tool) timed out after \(Int(timeout)) s", partial: output(status: -1))))
                    }
                    q.sync { timer = t }
                    do {
                        try p.run()
                    } catch {
                        q.async { finish(.failure(ServiceError("Could not start \(tool): \(error.localizedDescription)"))) }
                        return
                    }
                    q.asyncAfter(deadline: .now() + timeout, execute: t)
                    cancel.set { q.async { if !done { stop(); finish(.failure(CancellationError())) } } }
                    if let input, let d = input.data(using: .utf8) {
                        try? inPipe.fileHandleForWriting.write(contentsOf: d)
                    }
                    try? inPipe.fileHandleForWriting.close()
                }
            }
        } onCancel: {
            cancel.fire()
        }
    }

    /// Runs and throws with stderr when the exit status is non-zero.
    static func check(_ tool: String, _ args: [String], cwd: URL? = nil, env: [String: String] = [:], input: String? = nil, timeout: TimeInterval = 30) async throws -> String {
        let r = try await run(tool, args, cwd: cwd, env: env, input: input, timeout: timeout)
        guard r.ok else {
            let msg = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServiceError(msg.isEmpty ? "\(tool) exited with status \(r.status)" : msg)
        }
        return r.stdout
    }

    /// Single-quotes a value for /bin/sh.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
