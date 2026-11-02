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

    /// scp arguments for a host (scp spells the port flag -P). Ends with "--",
    /// so the paths that follow are never read as options.
    static func scpArgs(_ h: SSHHost, recursive: Bool) -> [String] {
        var a = ["-o", "ConnectTimeout=8", "-q"] + SSHCommand.muxArgs()
        if recursive { a.append("-r") }
        if h.auth != .password { a += ["-o", "BatchMode=yes"] }
        if h.port != 22 { a += ["-P", "\(h.port)"] }
        if h.auth == .key, !h.keyPath.isEmpty { a += ["-i", (h.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        if h.auth == .password { a += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"] }
        return a + ["--"]
    }

    static func remoteSpec(_ h: SSHHost, _ path: String) -> String { "\(h.destination):\(path)" }

    // MARK: Operations

    static func list(_ h: SSHHost, password: String?, path: String) async throws -> (path: String, entries: [RemoteEntry]) {
        let r = try await SSHCommand.run(h, password: password, remote: listCommand(path), timeout: 20)
        if r.status == 3 { throw ServiceError("No such folder: \(path)") }
        guard r.ok else { throw failure(r) }
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

    /// Size and modification time ("123 1700000000"), GNU/busybox stat or BSD stat.
    static func stampCommand(_ path: String) -> String {
        "stat -c '%s %Y' -- \(q(path)) 2>/dev/null || stat -f '%z %m' -- \(q(path))"
    }

    /// Reads a text file, refusing anything over `limit` bytes, with NUL bytes
    /// or not UTF-8 (saving it back would rewrite the bytes it couldn't read).
    /// `stamp` is the file's size and time, for `writeText` to check against.
    static func readText(_ h: SSHHost, password: String?, _ path: String, limit: Int = 2_000_000) async throws -> (text: String, stamp: String) {
        let r = try await SSHCommand.run(h, password: password,
                                         remote: "s=$(wc -c < \(q(path))) || exit 2; [ \"$s\" -le \(limit) ] || { echo \"TOO_BIG $s\" >&2; exit 4; }; st=$(\(stampCommand(path))) || exit 2; printf '%s\\n' \"$st\"; cat -- \(q(path))", timeout: 30)
        if r.status == 4 { throw ServiceError("This file is too large to edit in Brix (over \(limit / 1_000_000) MB). Download it instead.") }
        guard r.ok, let nl = r.stdout.firstIndex(of: "\n") else { throw failure(r) }
        let text = String(r.stdout[r.stdout.index(after: nl)...])
        if text.contains("\u{0}") { throw ServiceError("This looks like a binary file. Download it instead.") }
        if text.contains("\u{FFFD}") { throw ServiceError("This file isn't UTF-8 text, so Brix can't edit it safely. Download it instead.") }
        return (text, String(r.stdout[..<nl]))
    }

    static func download(_ h: SSHHost, password: String?, remote: String, to local: URL, recursive: Bool) async throws {
        try await scp(h, password: password, scpArgs(h, recursive: recursive) + [remoteSpec(h, remote), local.path])
    }

    static func upload(_ h: SSHHost, password: String?, local: URL, toDirectory dir: String) async throws {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir)
        try await scp(h, password: password, scpArgs(h, recursive: isDir.boolValue) + [local.path, remoteSpec(h, join(dir, ""))])
    }

    /// Puts `upload` in place of `path` if `path` still has `stamp` (else exit 5),
    /// then prints the new stamp. A symlink or someone else's file is written
    /// through (mv would replace the link, or the owner); otherwise the upload
    /// takes the file's mode and is moved over it.
    static func replaceCommand(_ path: String, with upload: String, stamp: String) -> String {
        """
        st=$(\(stampCommand(path))); [ "$st" = \(q(stamp)) ] || { rm -f -- \(q(upload)); exit 5; }; \
        { if [ -L \(q(path)) ] || [ ! -O \(q(path)) ]; then cat -- \(q(upload)) > \(q(path)) && rm -f -- \(q(upload)); \
        else chmod -- "$(stat -c %a -- \(q(path)) 2>/dev/null || stat -f %Lp -- \(q(path)))" \(q(upload)) && mv -f -- \(q(upload)) \(q(path)); fi; } \
        || { rm -f -- \(q(upload)); exit 1; }; \(stampCommand(path))
        """
    }

    /// Writes text back to a remote file: uploads it beside the file, then
    /// moves it into place, so a dropped connection never leaves half a file.
    /// Refuses when the file changed since it was read (`stamp` from readText).
    /// Returns the new stamp, for the next save.
    static func writeText(_ h: SSHHost, password: String?, _ path: String, text: String, stamp: String) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("brix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let name = (path as NSString).lastPathComponent
        let file = tmp.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let upload = join(parent(path), ".\(name).brix-\(UUID().uuidString.prefix(8))")
        try await scp(h, password: password, scpArgs(h, recursive: false) + [file.path, remoteSpec(h, upload)])
        let r = try await SSHCommand.run(h, password: password, remote: replaceCommand(path, with: upload, stamp: stamp), timeout: 60)
        if r.status == 5 { throw ServiceError("\(name) changed on the server since you opened it. Not saved; reopen it to see the new version.") }
        guard r.ok else { throw failure(r) }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func failure(_ r: ProcessOutput) -> ServiceError { ServiceError(SSHCommand.message(r)) }
}
