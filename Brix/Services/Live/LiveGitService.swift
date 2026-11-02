import Foundation

/// Git through the `git` CLI using porcelain v2 output.
final class LiveGitService: GitService {
    private func git(_ p: Project, _ args: [String], timeout: TimeInterval = 30) async throws -> String {
        // No optional locks: a background `git status` rewriting the index would
        // wake the folder watcher (another refresh) and race the user's own git.
        try await ProcessRunner.check("git", ["-C", p.expandedPath] + args, env: ["GIT_OPTIONAL_LOCKS": "0"], timeout: timeout)
    }

    func status(_ project: Project) async throws -> GitRepoState {
        // Throws when git itself is missing or hangs; a plain folder returns .empty.
        let inside = try await ProcessRunner.run("git", ["-C", project.expandedPath, "rev-parse", "--show-prefix"], timeout: 10)
        guard inside.ok else { return .empty }
        // A project can be a folder inside a bigger repository. Git runs in the
        // project folder, so pathspecs are relative to it; status paths are
        // relative to the repository root and are cut down to the project's own.
        let prefix = inside.stdout.trimmingCharacters(in: .newlines)

        async let statusOut = git(project, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--", "."])
        async let unstagedNum = git(project, ["diff", "--numstat", "-z", "--relative"])
        async let stagedNum = git(project, ["diff", "--cached", "--numstat", "-z", "--relative"])
        async let logOut = git(project, ["log", "-n", "60", "--format=%H%x1f%an%x1f%at%x1f%s%x1e"])
        async let branchOut = git(project, ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)%1f%(HEAD)%1f%(committerdate:relative)", "refs/heads"])

        let status = try await statusOut
        let parsed = Self.parseStatus(status, prefix: prefix)
        // Any read failing throws, so the caller keeps the last good state rather than empty lists.
        let unstagedStats = Self.parseNumstat(try await unstagedNum)
        let stagedStats = Self.parseNumstat(try await stagedNum)
        // Untracked files have no numstat; counting their lines reads each one,
        // so only a moderate number of small ones are counted.
        let countUntracked = parsed.entries.filter { $0.worktree == .U }.count < 200
        var changes: [GitFileChange] = []
        for e in parsed.entries {
            if let st = e.staged {
                let s = stagedStats[e.path] ?? (0, 0)
                changes.append(GitFileChange(path: e.path, status: st, add: s.0, del: s.1, staged: true, origPath: e.origPath))
            }
            if let wt = e.worktree {
                var s = unstagedStats[e.path] ?? (0, 0)
                if wt == .U, s == (0, 0), countUntracked { s = (Self.lineCount(project.url.appendingPathComponent(e.path)), 0) }
                changes.append(GitFileChange(path: e.path, status: wt, add: s.0, del: s.1, staged: false, conflict: e.conflict))
            }
        }
        // Without an upstream ahead is 0; commits on no remote branch are the unpushed ones.
        var ahead = parsed.ahead
        var unpushed: Set<String>?
        if parsed.upstream == nil, let out = try? await git(project, ["rev-list", "--max-count=1000", "HEAD", "--not", "--remotes"]) {
            let hashes = out.split(separator: "\n").map(String.init)
            ahead = hashes.count
            unpushed = Set(hashes)
        }
        // A repository without commits yet has no log.
        let log: String
        do { log = try await logOut } catch let e where e.localizedDescription.contains("does not have any commits") { log = "" }
        let commits = Self.parseLog(log).enumerated().map { i, c -> GitCommit in
            var c = c
            c.isPushed = unpushed.map { !$0.contains(c.hash) } ?? (i >= ahead)
            return c
        }
        let branches = try await branchOut.split(separator: "\n").map { line -> GitBranch in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            return GitBranch(name: f[0], isCurrent: f.count > 1 && f[1] == "*", lastCommit: f.count > 2 ? f[2] : "")
        }
        return GitRepoState(branch: parsed.branch, ahead: ahead, behind: parsed.behind, changes: changes,
                            commits: commits, branches: branches, remote: parsed.upstream ?? "origin", isRepo: true)
    }

    struct StatusEntry { var path: String; var staged: GitStatus?; var worktree: GitStatus?; var origPath: String? = nil; var conflict = false }
    struct ParsedStatus { var branch = ""; var upstream: String?; var ahead = 0; var behind = 0; var entries: [StatusEntry] = [] }

    static func map(_ c: Character) -> GitStatus? {
        switch c {
        case "M", "T", "R", "C": .M
        case "A": .A
        case "D": .D
        default: nil
        }
    }

    /// Parses `git status --porcelain=v2 --branch -z`. Paths come back relative
    /// to the project folder `prefix` ("sub/" or ""); entries outside it are
    /// dropped, and a rename source outside it becomes a top-level pathspec.
    static func parseStatus(_ s: String, prefix: String = "") -> ParsedStatus {
        func rel(_ p: String) -> String? { p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : nil }
        var out = ParsedStatus()
        let records = s.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < records.count {
            let r = records[i]
            if r.hasPrefix("# branch.head ") {
                out.branch = String(r.dropFirst("# branch.head ".count))
            } else if r.hasPrefix("# branch.upstream ") {
                out.upstream = String(r.dropFirst("# branch.upstream ".count))
            } else if r.hasPrefix("# branch.ab ") {
                let parts = r.split(separator: " ")
                if parts.count >= 4 {
                    out.ahead = Int(parts[2].dropFirst()) ?? 0
                    out.behind = Int(parts[3].dropFirst()) ?? 0
                }
            } else if r.hasPrefix("1 ") || r.hasPrefix("2 ") {
                // 1 XY sub mH mI mW hH hI path   |  2 XY sub mH mI mW hH hI Xscore path\0origPath
                let fields = r.split(separator: " ", maxSplits: r.hasPrefix("1 ") ? 8 : 9, omittingEmptySubsequences: false)
                let xy = Array(fields[1])
                // A rename's original path is the next record.
                let orig = r.hasPrefix("2 ") && i + 1 < records.count ? records[i + 1] : nil
                if let path = rel(String(fields.last ?? "")) {
                    out.entries.append(StatusEntry(path: path, staged: map(xy[0]), worktree: map(xy[1]), origPath: orig.map { rel($0) ?? ":/" + $0 }))
                }
                if orig != nil { i += 1 }
            } else if r.hasPrefix("u ") {
                // Unmerged (UU, AA, DD, AU...): a merge conflict.
                let fields = r.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if let path = rel(String(fields.last ?? "")) { out.entries.append(StatusEntry(path: path, staged: nil, worktree: .M, conflict: true)) }
            } else if r.hasPrefix("? ") {
                if let path = rel(String(r.dropFirst(2))) { out.entries.append(StatusEntry(path: path, staged: nil, worktree: .U)) }
            }
            i += 1
        }
        if out.branch == "(detached)" { out.branch = "HEAD (detached)" }
        return out
    }

    /// Parses `git diff --numstat -z`. Binary files report 0/0.
    static func parseNumstat(_ s: String) -> [String: (Int, Int)] {
        var out: [String: (Int, Int)] = [:]
        let recs = s.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < recs.count {
            let r = recs[i]
            let f = r.split(separator: "\t", omittingEmptySubsequences: false)
            if f.count >= 3 {
                let add = Int(f[0]) ?? 0, del = Int(f[1]) ?? 0
                if f[2].isEmpty, i + 2 < recs.count {
                    // rename: "add\tdel\t\0old\0new"
                    out[recs[i + 2]] = (add, del)
                    i += 2
                } else {
                    out[String(f[2])] = (add, del)
                }
            }
            i += 1
        }
        return out
    }

    static func parseLog(_ s: String) -> [GitCommit] {
        s.split(separator: "\u{1e}").compactMap { rec in
            let f = rec.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { return nil }
            return GitCommit(hash: f[0], message: f[3], author: f[1], date: Date(timeIntervalSince1970: TimeInterval(f[2]) ?? 0))
        }
    }

    static func lineCount(_ url: URL) -> Int {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count < 1_000_000 else { return 0 }
        return d.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
    }

    func stage(_ project: Project, paths: [String]) async throws -> GitRepoState {
        _ = try await git(project, ["add", "--"] + paths)
        return try await status(project)
    }

    func unstage(_ project: Project, paths: [String]) async throws -> GitRepoState {
        let hasHead = (try? await git(project, ["rev-parse", "--verify", "HEAD"])) != nil
        if hasHead {
            _ = try await git(project, ["restore", "--staged", "--"] + paths)
        } else {
            _ = try await git(project, ["rm", "--cached", "-r", "--"] + paths)
        }
        return try await status(project)
    }

    func discard(_ project: Project, paths: [String]) async throws -> GitRepoState {
        let current = try await status(project)
        // A folder covers the changes inside it, and can hold both kinds.
        func under(_ c: GitFileChange, _ p: String) -> Bool { c.path == p || c.path.hasPrefix(p.hasSuffix("/") ? p : p + "/") }
        let tracked = paths.filter { p in current.unstaged.contains { $0.status != .U && under($0, p) } }
        let newFiles = paths.filter { p in current.unstaged.contains { $0.status == .U && under($0, p) } }
        if !tracked.isEmpty { _ = try await git(project, ["restore", "--worktree", "--"] + tracked) }
        if !newFiles.isEmpty { _ = try await git(project, ["clean", "-f", "-d", "--"] + newFiles) }
        let after = try await status(project)
        let left = paths.filter { p in after.unstaged.contains { under($0, p) } }
        if !left.isEmpty { throw ServiceError("Couldn't discard \(left.joined(separator: ", "))") }
        return after
    }

    func commit(_ project: Project, message: String) async throws -> GitRepoState {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { throw ServiceError("Write a commit message first") }
        // Hooks (lint, tests) can take minutes; a timeout would kill git mid-hook.
        _ = try await ProcessRunner.check("git", ["-C", project.expandedPath, "commit", "-F", "-"], input: msg, timeout: 600)
        return try await status(project)
    }

    func fetch(_ project: Project) async throws -> GitRepoState {
        _ = try await git(project, ["fetch", "--prune"], timeout: 120)
        return try await status(project)
    }

    func pull(_ project: Project) async throws -> GitRepoState {
        _ = try await git(project, ["pull", "--ff-only"], timeout: 120)
        return try await status(project)
    }

    func push(_ project: Project) async throws -> GitRepoState {
        let s = try await status(project)
        if s.remote == "origin", !s.branch.isEmpty, (try? await git(project, ["rev-parse", "--abbrev-ref", "@{u}"])) == nil {
            _ = try await git(project, ["push", "--set-upstream", "origin", s.branch], timeout: 600)
        } else {
            _ = try await git(project, ["push"], timeout: 600)
        }
        return try await status(project)
    }

    func diff(_ project: Project, change: GitFileChange) async throws -> FileDiff {
        let text: String
        if change.status == .U {
            text = try await ProcessRunner.run("git", ["-C", project.expandedPath, "diff", "--no-index", "--", "/dev/null", change.path]).stdout
        } else {
            // A staged rename diffs against its source rather than as a whole new file.
            text = try await git(project, ["diff", "-M"] + (change.staged ? ["--cached"] : []) + ["--", change.path] + (change.origPath.map { [$0] } ?? []))
        }
        return Self.parseDiff(text, path: change.path)
    }

    /// Parses unified diff output into rows with old/new line numbers.
    static func parseDiff(_ text: String, path: String) -> FileDiff {
        var lines: [DiffLine] = []
        var old = 0, new = 0, add = 0, del = 0
        var inHunk = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(raw)
            if l.hasPrefix("@@") {
                inHunk = true
                // @@ -a,b +c,d @@ ctx
                let scanner = l.split(separator: " ")
                if scanner.count >= 3 {
                    old = Int(scanner[1].dropFirst().split(separator: ",")[0]) ?? 0
                    new = Int(scanner[2].dropFirst().split(separator: ",")[0]) ?? 0
                }
                lines.append(DiffLine(kind: .hunk, old: nil, new: nil, text: l))
            } else if !inHunk {
                if l.hasPrefix("Binary files") { lines.append(DiffLine(kind: .hunk, old: nil, new: nil, text: l)) }
                continue
            } else if l.hasPrefix("+") {
                lines.append(DiffLine(kind: .add, old: nil, new: new, text: String(l.dropFirst())))
                new += 1; add += 1
            } else if l.hasPrefix("-") {
                lines.append(DiffLine(kind: .del, old: old, new: nil, text: String(l.dropFirst())))
                old += 1; del += 1
            } else if l.hasPrefix("\\") {
                continue
            } else if l.hasPrefix(" ") || l.isEmpty {
                if l.isEmpty && raw.endIndex == text.endIndex { continue }
                lines.append(DiffLine(kind: .context, old: old, new: new, text: String(l.dropFirst())))
                old += 1; new += 1
            }
        }
        return FileDiff(path: path, add: add, del: del, lines: lines)
    }

    func commitDetail(_ project: Project, hash: String) async throws -> GitCommit {
        // -z leaves unicode paths unquoted; a merge lists its changes against the first parent.
        let out = try await git(project, ["show", "-z", "--raw", "--numstat", "-M", "-m", "--first-parent", "--format=%H%x1f%an%x1f%at%x1f%B%x1e", hash])
        let parts = out.components(separatedBy: "\u{1e}")
        let head = parts[0].split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        guard head.count >= 4 else { throw ServiceError("Could not read commit \(hash.prefix(7))") }
        return GitCommit(hash: head[0], message: head[3].trimmingCharacters(in: .whitespacesAndNewlines), author: head[1],
                         date: Date(timeIntervalSince1970: TimeInterval(head[2]) ?? 0), files: Self.parseShowFiles(parts.count > 1 ? parts[1] : ""))
    }

    /// Parses `--raw --numstat -z`: ":modes hashes S\0path" (two paths for a
    /// rename or copy), then "add\tdel\tpath" ("add\tdel\t\0old\0new" for a rename).
    static func parseShowFiles(_ s: String) -> [GitFileChange] {
        let t = s.split(separator: "\0", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .newlines) }
        var files: [GitFileChange] = []
        var i = 0
        while i < t.count {
            if t[i].hasPrefix(":") {
                let code = t[i].split(separator: " ").last?.first ?? "M"
                let two = code == "R" || code == "C"
                if i + (two ? 2 : 1) < t.count {
                    files.append(GitFileChange(path: t[i + (two ? 2 : 1)], status: map(code) ?? .M, add: 0, del: 0, staged: false, origPath: two ? t[i + 1] : nil))
                }
                i += two ? 3 : 2
            } else if t[i].contains("\t") {
                let f = t[i].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                var path = f.count > 2 ? f[2] : ""
                if path.isEmpty, i + 2 < t.count { path = t[i + 2]; i += 2 }
                if let k = files.firstIndex(where: { $0.path == path }) {
                    files[k].add = Int(f[0]) ?? 0
                    files[k].del = f.count > 1 ? Int(f[1]) ?? 0 : 0
                }
                i += 1
            } else {
                i += 1
            }
        }
        return files
    }

    func switchBranch(_ project: Project, to name: String) async throws -> GitRepoState {
        _ = try await git(project, ["switch", name])
        return try await status(project)
    }

    func createBranch(_ project: Project, name: String) async throws -> GitRepoState {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.contains(" ") else { throw ServiceError("Branch names can't contain spaces") }
        _ = try await git(project, ["switch", "-c", clean])
        return try await status(project)
    }

    func deleteBranch(_ project: Project, name: String) async throws -> GitRepoState {
        _ = try await git(project, ["branch", "-d", name])
        return try await status(project)
    }

    func suggestMessage(_ project: Project, staged: [GitFileChange]) async -> String {
        CommitMessageWriter.suggest(for: staged)
    }
}
