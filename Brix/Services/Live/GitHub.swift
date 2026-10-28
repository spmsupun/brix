import Foundation

/// A pull request from `gh pr list`.
struct GitHubPR: Identifiable, Hashable, Decodable {
    var id: Int { number }
    var number: Int
    var title: String
    var url: String
    var headRefName: String
    var isDraft: Bool
    var reviewDecision: String?
    var updatedAt: Date
    var author: Author?
    var statusCheckRollup: [Check]?

    struct Author: Hashable, Decodable { var login: String }
    struct Check: Hashable, Decodable {
        var conclusion: String? = nil
        var status: String? = nil
        var state: String? = nil
    }

    enum Checks { case none, passing, pending, failing }

    /// Every check's result folded into one.
    var checks: Checks { GitHubPR.fold(statusCheckRollup ?? []) }

    static func fold(_ checks: [Check]) -> Checks {
        guard !checks.isEmpty else { return .none }
        let states = checks.map { ($0.conclusion ?? $0.state ?? $0.status ?? "").uppercased() }
        if states.contains(where: { ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains($0) }) { return .failing }
        if states.contains(where: { ["", "PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED", "EXPECTED"].contains($0) }) { return .pending }
        return .passing
    }
}

/// A workflow run from `gh run list`.
struct GitHubRun: Identifiable, Hashable, Decodable {
    var id: Int { databaseId }
    var databaseId: Int
    var displayTitle: String
    var workflowName: String
    var status: String
    var conclusion: String?
    var headBranch: String
    var event: String
    var createdAt: Date
    var updatedAt: Date
    var url: String

    enum Result { case running, passed, failed, other }
    var result: Result {
        if status != "completed" { return .running }
        switch conclusion {
        case "success": return .passed
        case "failure", "timed_out", "startup_failure": return .failed
        default: return .other
        }
    }
}

/// What the GitHub card shows for one project.
enum GitHubState: Equatable {
    case notInstalled
    case signedOut
    case noRepo
    case loading
    case failed(String)
    case ready(repo: String, prs: [GitHubPR], runs: [GitHubRun])
}

/// GitHub through the user's own `gh` CLI and its sign-in. Read-only.
enum GitHub {
    /// "owner/repo" from a GitHub remote URL: https, ssh, and ssh host aliases
    /// such as `git@github.com-work:owner/repo.git`.
    static func repo(fromRemote url: String) -> String? {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [#"^https?://(?:[^@/]+@)?github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$"#,
                        #"^(?:ssh://)?git@github\.com[^:/]*[:/]([^/]+)/([^/]+?)(?:\.git)?/?$"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: u, range: NSRange(u.startIndex..., in: u)),
                  let o = Range(m.range(at: 1), in: u), let r = Range(m.range(at: 2), in: u) else { continue }
            return "\(u[o])/\(u[r])"
        }
        return nil
    }

    /// The project's GitHub repo: its own setting, else origin (or any GitHub remote).
    static func detectRepo(_ p: Project) async -> String? {
        if let r = p.githubRepo?.trimmingCharacters(in: .whitespaces), !r.isEmpty { return r }
        guard let out = try? await ProcessRunner.run("git", ["-C", p.expandedPath, "remote", "-v"], timeout: 8), out.ok else { return nil }
        let urls = out.stdout.split(separator: "\n").compactMap { line -> (String, String)? in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return f.count >= 2 ? (String(f[0]), String(f[1])) : nil
        }
        return (urls.first { $0.0 == "origin" }.flatMap { repo(fromRemote: $0.1) }) ?? urls.lazy.compactMap { repo(fromRemote: $0.1) }.first
    }

    static var installed: Bool { ProcessRunner.which("gh") != nil }

    /// The github.com accounts gh is signed in to, the active one first.
    static func accounts() async throws -> [String] {
        let out = try await ProcessRunner.run("gh", ["auth", "status", "--hostname", "github.com"], timeout: 15)
        return parseAccounts(out.stdout + "\n" + out.stderr)
    }

    /// Account logins from `gh auth status`, the active one first.
    static func parseAccounts(_ text: String) -> [String] {
        var all: [String] = []
        var active: String?
        var current: String?
        for line in text.split(separator: "\n") {
            if let r = line.range(of: #"account (\S+)"#, options: .regularExpression), line.contains("Logged in") {
                current = String(line[r].dropFirst("account ".count))
                if let c = current, !all.contains(c) { all.append(c) }
            } else if line.contains("Active account: true"), let c = current {
                active = c
            }
        }
        if let a = active, let i = all.firstIndex(of: a) { all.remove(at: i); all.insert(a, at: 0) }
        return all
    }

    /// One account's token, for this gh call only (gh keeps it in the Keychain;
    /// Brix never stores it).
    /// Throws rather than fall back to the active account, so results are never
    /// credited to an account that didn't read them.
    static func env(for account: String) async throws -> [String: String] {
        let t = try await ProcessRunner.run("gh", ["auth", "token", "--hostname", "github.com", "--user", account], timeout: 10)
        let token = t.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.ok, !token.isEmpty else { throw ServiceError("Couldn't get \(account)'s GitHub sign-in from gh") }
        return ["GH_TOKEN": token]
    }

    /// The repo isn't visible to this account (private to someone else).
    static func notVisible(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("could not resolve to a repository") || s.contains("http 404") || s.contains("http 403") || s.contains("not found")
    }

    /// Pull requests and runs for the project, read with the account that can
    /// see the repo: the one chosen for the project, else each signed-in account
    /// in turn. `account` is the one that worked.
    static func load(_ p: Project, prefer: String? = nil) async -> (GitHubState, account: String?) {
        guard installed else { return (.notInstalled, nil) }
        guard let repo = await detectRepo(p) else { return (.noRepo, nil) }
        let all: [String]
        do {
            all = try await accounts()
        } catch {
            // A failed call (offline, timeout) is an error; only no accounts means signed out.
            return (.failed(error.localizedDescription), nil)
        }
        guard !all.isEmpty else { return (.signedOut, nil) }
        var order = all
        // The account that worked last time goes first.
        if let prefer, let i = order.firstIndex(of: prefer) { order.remove(at: i); order.insert(prefer, at: 0) }
        if let chosen = p.githubAccount {
            guard all.contains(chosen) else { return (.failed("\(chosen) isn't signed in to gh. Sign it in under Settings → Accounts, or pick another account."), nil) }
            order = [chosen]
        }
        var lastError = ""
        for account in order {
            let env: [String: String]
            do {
                env = try await self.env(for: account)
            } catch {
                // A chosen account must work; when trying in turn, move on but say why.
                if p.githubAccount != nil { return (.failed(error.localizedDescription), nil) }
                lastError = error.localizedDescription
                continue
            }
            async let prs = ProcessRunner.run("gh", ["pr", "list", "-R", repo, "--state", "open", "--limit", "20", "--json",
                                                     "number,title,url,headRefName,isDraft,reviewDecision,updatedAt,author,statusCheckRollup"], env: env, timeout: 30)
            async let runs = ProcessRunner.run("gh", ["run", "list", "-R", repo, "--limit", "15", "--json",
                                                      "databaseId,displayTitle,workflowName,status,conclusion,headBranch,event,createdAt,updatedAt,url"], env: env, timeout: 30)
            do {
                let (pr, r) = try await (prs, runs)
                guard pr.ok else {
                    lastError = Self.message(pr.stderr)
                    // Another account may see it; anything else is a real error.
                    if notVisible(pr.stderr) { continue }
                    return (.failed(lastError), nil)
                }
                // A repo without Actions answers the run list with an error; that alone means no runs.
                let noActions = r.stderr.lowercased().contains("actions") && (r.stderr.contains("disabled") || r.stderr.contains("not found") || r.stderr.contains("404"))
                guard r.ok || noActions else { return (.failed("Pipelines: " + Self.message(r.stderr)), account) }
                return (.ready(repo: repo, prs: try decode([GitHubPR].self, pr.stdout), runs: r.ok ? try decode([GitHubRun].self, r.stdout) : []), account)
            } catch {
                return (.failed(error.localizedDescription), nil)
            }
        }
        let tried = order.joined(separator: ", ")
        return (.failed("None of your GitHub accounts (\(tried)) can see \(repo). \(lastError)"), nil)
    }

    static func decode<T: Decodable>(_ t: T.Type, _ s: String) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(t, from: Data(s.utf8))
    }

    private static func message(_ stderr: String) -> String {
        stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? "gh failed"
    }

    /// Sample data for the sample workspace.
    static func sample(_ p: Project) -> GitHubState {
        let now = Date()
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        let prs = [
            GitHubPR(number: 212, title: "Apple Pay wallet buttons on checkout", url: "https://github.com/atlas/atlas-web/pull/212", headRefName: "feat/checkout-v2",
                     isDraft: false, reviewDecision: "REVIEW_REQUIRED", updatedAt: ago(1200), author: .init(login: "supun"),
                     statusCheckRollup: [.init(conclusion: nil, status: "IN_PROGRESS", state: nil), .init(conclusion: "SUCCESS", status: "COMPLETED", state: nil)]),
            GitHubPR(number: 208, title: "Fix tax rounding on invoices", url: "https://github.com/atlas/atlas-web/pull/208", headRefName: "fix/tax-rounding",
                     isDraft: false, reviewDecision: "APPROVED", updatedAt: ago(5 * 3600), author: .init(login: "maya"),
                     statusCheckRollup: [.init(conclusion: "SUCCESS", status: "COMPLETED", state: nil)]),
            GitHubPR(number: 205, title: "Spike: edge caching for product pages", url: "https://github.com/atlas/atlas-web/pull/205", headRefName: "spike/edge-cache",
                     isDraft: true, reviewDecision: nil, updatedAt: ago(2 * 86400), author: .init(login: "supun"),
                     statusCheckRollup: [.init(conclusion: "FAILURE", status: "COMPLETED", state: nil)])
        ]
        let runs = [
            GitHubRun(databaseId: 3, displayTitle: "Apple Pay wallet buttons on checkout", workflowName: "CI", status: "in_progress", conclusion: nil,
                      headBranch: "feat/checkout-v2", event: "pull_request", createdAt: ago(300), updatedAt: ago(60), url: "https://github.com/atlas/atlas-web/actions"),
            GitHubRun(databaseId: 2, displayTitle: "Merge pull request #204", workflowName: "Deploy", status: "completed", conclusion: "success",
                      headBranch: "main", event: "push", createdAt: ago(3 * 3600), updatedAt: ago(3 * 3600 - 240), url: "https://github.com/atlas/atlas-web/actions"),
            GitHubRun(databaseId: 1, displayTitle: "Spike: edge caching for product pages", workflowName: "CI", status: "completed", conclusion: "failure",
                      headBranch: "spike/edge-cache", event: "pull_request", createdAt: ago(2 * 86400), updatedAt: ago(2 * 86400 - 300), url: "https://github.com/atlas/atlas-web/actions")
        ]
        return p.id == "atlas-web" ? .ready(repo: "atlas/atlas-web", prs: prs, runs: runs) : .noRepo
    }
}
