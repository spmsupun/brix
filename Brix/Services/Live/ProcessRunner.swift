import Foundation

struct ProcessOutput {
    var stdout: String
    var stderr: String
    var status: Int32
    var ok: Bool { status == 0 }
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

    static func run(_ tool: String, _ args: [String], cwd: URL? = nil, env: [String: String] = [:], input: String? = nil, timeout: TimeInterval = 30) async throws -> ProcessOutput {
        guard let exe = which(tool) else { throw ServiceError("\(tool) was not found. Install it or add it to your PATH.") }
        return try await withCheckedThrowingContinuation { cont in
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
                let lock = NSLock()
                var outData = Data(), errData = Data(), done = false
                let handles = [out.fileHandleForReading, err.fileHandleForReading]
                // Closed here rather than when the pipes deallocate: the timeout's
                // work item keeps them alive for the full timeout even after a
                // fast exit, which held hundreds of descriptors open.
                func stopReading() { handles.forEach { $0.readabilityHandler = nil; try? $0.close() } }
                // Resumes once: on exit plus end of output, or on the timeout.
                func finish(_ r: Result<ProcessOutput, Error>) {
                    guard lock.withLock({ () -> Bool in defer { done = true }; return !done }) else { return }
                    stopReading()
                    cont.resume(with: r)
                }

                let group = DispatchGroup()
                for (h, isOut) in zip(handles, [true, false]) {
                    group.enter()
                    var ended = false
                    h.readabilityHandler = { h in
                        let d = h.availableData
                        // Readability fires again after EOF until the handler is gone.
                        let leave = lock.withLock { () -> Bool in
                            if d.isEmpty { defer { ended = true }; return !ended }
                            if isOut { outData.append(d) } else { errData.append(d) }
                            return false
                        }
                        if leave { h.readabilityHandler = nil; group.leave() }
                    }
                }
                group.enter()
                p.terminationHandler = { _ in group.leave() }

                // Armed before stdin is written, which can block on a tool that never reads it.
                let timer = DispatchWorkItem {
                    if p.isRunning {
                        p.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
                    }
                    // Also when the tool exited but something it started still holds its output open.
                    finish(.failure(ServiceError("\(tool) timed out after \(Int(timeout)) s")))
                }
                do {
                    try p.run()
                } catch {
                    finish(.failure(ServiceError("Could not start \(tool): \(error.localizedDescription)")))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                if let input, let d = input.data(using: .utf8) {
                    try? inPipe.fileHandleForWriting.write(contentsOf: d)
                }
                try? inPipe.fileHandleForWriting.close()

                group.notify(queue: .global()) {
                    timer.cancel()
                    let (o, e) = lock.withLock { (outData, errData) }
                    finish(.success(ProcessOutput(stdout: String(decoding: o, as: UTF8.self),
                                                  stderr: String(decoding: e, as: UTF8.self),
                                                  status: p.terminationStatus)))
                }
            }
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
