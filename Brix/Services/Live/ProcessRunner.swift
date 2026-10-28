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
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                let inPipe = Pipe()
                p.standardInput = inPipe

                // Read pipes concurrently so a full buffer never blocks the child.
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

                do {
                    try p.run()
                } catch {
                    cont.resume(throwing: ServiceError("Could not start \(tool): \(error.localizedDescription)"))
                    return
                }
                if let input, let d = input.data(using: .utf8) {
                    inPipe.fileHandleForWriting.write(d)
                }
                try? inPipe.fileHandleForWriting.close()

                var timedOut = false
                let timer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                p.waitUntilExit()
                timer.cancel()
                group.wait()
                if timedOut {
                    cont.resume(throwing: ServiceError("\(tool) timed out after \(Int(timeout)) s"))
                    return
                }
                cont.resume(returning: ProcessOutput(stdout: String(decoding: outData, as: UTF8.self),
                                                     stderr: String(decoding: errData, as: UTF8.self),
                                                     status: p.terminationStatus))
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
