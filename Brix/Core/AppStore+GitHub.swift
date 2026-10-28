import SwiftUI

/// GitHub for every project, kept in one place: the project overview shows it,
/// and a running pipeline shows on the sidebar, Home and the overview.
extension AppStore {
    /// Projects whose GitHub state is loaded and refreshed.
    var githubProjects: [Project] {
        library.projects.filter { !$0.isSample || $0.id == "atlas-web" }.filter { git[$0.id]?.isRepo == true || $0.isSample }
    }

    func refreshGitHub(_ id: ProjectID) async {
        guard let p = project(id) else { return }
        if p.isSample { github[id] = GitHub.sample(p); return }
        if github[id] == nil { github[id] = .loading }
        let (result, account) = await GitHub.load(p, prefer: p.githubAccountSeen)
        // A failed refresh keeps the last good data on screen, marked stale
        // (githubErrors) until a refresh succeeds.
        if case .failed = result, case .ready = github[id] ?? .loading {
            githubErrors[id] = result
        } else {
            github[id] = result
            githubErrors[id] = nil
        }
        if let account, account != project(id)?.githubAccountSeen, var q = project(id) {
            q.githubAccountSeen = account
            updateProject(q)
        }
    }

    /// Every minute, or every 15 seconds while any pipeline runs; only while a
    /// Brix window is visible, and only for projects with a GitHub remote.
    func startGitHubPolling() {
        githubTask?.cancel()
        githubTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                if self.windowVisible, GitHub.installed {
                    for p in self.githubProjects {
                        if case .noRepo = self.github[p.id] ?? .loading, self.githubChecked[p.id].map({ Date().timeIntervalSince($0) < 600 }) == true { continue }
                        await self.refreshGitHub(p.id)
                        self.githubChecked[p.id] = Date()
                    }
                }
                let running = self.library.projects.contains { self.runningPipelines($0.id) > 0 }
                try? await Task.sleep(nanoseconds: running ? 15_000_000_000 : 60_000_000_000)
            }
        }
    }

    /// Workflow runs in progress for a project (and its nested repositories).
    func runningPipelines(_ id: ProjectID) -> Int {
        let ids = [id] + children(of: id).map(\.id)
        return ids.reduce(0) { n, i in
            // Stale data can't say a run is still going.
            guard githubErrors[i] == nil, case .ready(_, _, let runs) = github[i] ?? .loading else { return n }
            return n + runs.filter { $0.result == .running }.count
        }
    }

    /// The newest run per workflow that failed and hasn't passed since.
    func failedPipelines(_ id: ProjectID) -> [GitHubRun] {
        guard githubErrors[id] == nil, case .ready(_, _, let runs) = github[id] ?? .loading else { return [] }
        var seen = Set<String>()
        return runs.filter { r in
            guard r.result != .running, seen.insert(r.workflowName + "|" + r.headBranch).inserted else { return false }
            return r.result == .failed
        }
    }
}
