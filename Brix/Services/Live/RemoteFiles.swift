import Foundation

/// One entry in a remote directory.
struct RemoteEntry: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var isDirectory: Bool
    var isLink: Bool
    var size: Int64
    var modified: Date?
    /// Octal permissions, e.g. "644".
    var mode: String
}

/// File operations on an SSH host through the system `ssh` and `scp`, so
/// ~/.ssh/config, keys and the agent apply exactly as in Terminal.
enum RemoteFiles {
    /// Quotes for the remote POSIX shell.
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// `cd` target: "~" and "~/x" stay relative to the remote home.
    static func cdTarget(_ path: String) -> String {
        if path == "~" || path.isEmpty { return "cd" }
        if path.hasPrefix("~/") { return "cd ~/" + q(String(path.dropFirst(2))) }
        return "cd -- " + q(path)
    }

    /// Lists with GNU find when it's there, else a plain shell loop (busybox, BSD).
    /// First line of output is the absolute directory.
    static func listCommand(_ path: String) -> String {
        """
        \(cdTarget(path)) || exit 3; pwd; \
        find . -mindepth 1 -maxdepth 1 -printf '%y\\t%s\\t%T@\\t%m\\t%f\\n' 2>/dev/null || \
        for f in .* *; do [ "$f" = . ] || [ "$f" = .. ] || [ ! -e "$f" ] && continue; \
        if [ -L "$f" ]; then t=l; elif [ -d "$f" ]; then t=d; else t=f; fi; printf '%s\\t0\\t0\\t0\\t%s\\n' "$t" "$f"; done
        """
    }

    /// Parses `listCommand` output into the directory path and its entries,
    /// folders first, then by name.
    static func parseList(_ out: String) -> (path: String, entries: [RemoteEntry]) {
        var lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let path = lines.isEmpty ? "" : lines.removeFirst().trimmingCharacters(in: .whitespaces)
        let entries = lines.compactMap { line -> RemoteEntry? in
            let p = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard p.count == 5, !p[4].isEmpty else { return nil }
            let t = Double(p[2]) ?? 0
            return RemoteEntry(name: p[4], isDirectory: p[0] == "d", isLink: p[0] == "l", size: Int64(p[1]) ?? 0,
                               modified: t > 0 ? Date(timeIntervalSince1970: t) : nil, mode: p[3])
        }
        return (path, entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        })
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    static func parent(_ path: String) -> String {
        guard path != "/" else { return "/" }
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    /// scp arguments for a host (scp spells the port flag -P).
    static func scpArgs(_ h: SSHHost, recursive: Bool) -> [String] {
        var a = ["-o", "ConnectTimeout=8", "-q"]
        if recursive { a.append("-r") }
        if h.auth != .password { a += ["-o", "BatchMode=yes"] }
        if h.port != 22 { a += ["-P", "\(h.port)"] }
        if h.auth == .key, !h.keyPath.isEmpty { a += ["-i", (h.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        if h.auth == .password { a += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"] }
        return a
    }

    static func remoteSpec(_ h: SSHHost, _ path: String) -> String { "\(h.user)@\(h.host):\(path)" }

    // MARK: Operations

    static func list(_ h: SSHHost, password: String?, path: String) async throws -> (path: String, entries: [RemoteEntry]) {
        let r = try await SSHCommand.run(h, password: password, remote: listCommand(path), timeout: 20)
        if r.status == 3 { throw ServiceError("No such folder: \(path)") }
        guard r.ok || !r.stdout.isEmpty else { throw failure(r) }
        return parseList(r.stdout)
    }

    static func run(_ h: SSHHost, password: String?, _ command: String, timeout: TimeInterval = 60) async throws {
        let r = try await SSHCommand.run(h, password: password, remote: command, timeout: timeout)
        guard r.ok else { throw failure(r) }
    }

    static func mkdir(_ h: SSHHost, password: String?, _ path: String) async throws {
        try await run(h, password: password, "mkdir -p -- \(q(path))")
    }

    static func rename(_ h: SSHHost, password: String?, from: String, to: String) async throws {
        try await run(h, password: password, "[ ! -e \(q(to)) ] || { echo 'A file with that name already exists' >&2; exit 1; }; mv -- \(q(from)) \(q(to))")
    }

    static func copy(_ h: SSHHost, password: String?, from: String, to: String) async throws {
        try await run(h, password: password, "cp -R -- \(q(from)) \(q(to))", timeout: 600)
    }

    static func delete(_ h: SSHHost, password: String?, _ path: String) async throws {
        // Never on "/", the home folder or an empty path.
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, p != "/", p != "~", p != "." , p != ".." else { throw ServiceError("Refusing to delete \(path)") }
        try await run(h, password: password, "rm -rf -- \(q(p))", timeout: 600)
    }

    /// Reads a text file, refusing anything over `limit` bytes or with NUL bytes.
    static func readText(_ h: SSHHost, password: String?, _ path: String, limit: Int = 2_000_000) async throws -> String {
        let r = try await SSHCommand.run(h, password: password,
                                         remote: "s=$(wc -c < \(q(path))) || exit 2; [ \"$s\" -le \(limit) ] || { echo \"TOO_BIG $s\" >&2; exit 4; }; cat -- \(q(path))", timeout: 30)
        if r.status == 4 { throw ServiceError("This file is too large to edit in Brix (over \(limit / 1_000_000) MB). Download it instead.") }
        guard r.ok else { throw failure(r) }
        if r.stdout.contains("\u{0}") { throw ServiceError("This looks like a binary file. Download it instead.") }
        return r.stdout
    }

    static func download(_ h: SSHHost, password: String?, remote: String, to local: URL, recursive: Bool) async throws {
        try await scp(h, password: password, scpArgs(h, recursive: recursive) + [remoteSpec(h, remote), local.path])
    }

    static func upload(_ h: SSHHost, password: String?, local: URL, toDirectory dir: String) async throws {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir)
        try await scp(h, password: password, scpArgs(h, recursive: isDir.boolValue) + [local.path, remoteSpec(h, join(dir, ""))])
    }

    /// Writes text back to a remote file by uploading a temporary copy.
    static func writeText(_ h: SSHHost, password: String?, _ path: String, text: String) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("brix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent((path as NSString).lastPathComponent)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try await scp(h, password: password, scpArgs(h, recursive: false) + [file.path, remoteSpec(h, path)])
    }

    private static func scp(_ h: SSHHost, password: String?, _ args: [String]) async throws {
        var env: [String: String] = [:]
        if h.auth == .password {
            guard let password, !password.isEmpty else { throw ServiceError("No password stored in the Keychain for \(h.name)") }
            env = try SSHCommand.askpassEnv(password: password)
        }
        let r = try await ProcessRunner.run("/usr/bin/scp", args, env: env, timeout: 3600)
        guard r.ok else { throw failure(r) }
    }

    private static func failure(_ r: ProcessOutput) -> ServiceError {
        let msg = r.stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("debug1") }.last
        return ServiceError(msg ?? "exit status \(r.status)")
    }
}
