import SwiftUI

extension AppStore {
    /// One read per project at a time: a request while one runs makes it run
    /// once more, so an older result never lands after a newer one. Returns the
    /// read it started, if it started one.
    @discardableResult
    func refreshGit(_ id: ProjectID) -> Task<Void, Never>? {
        guard let p = project(id) else { return nil }
        guard gitRefreshing.insert(id).inserted else { gitRefreshAgain.insert(id); return nil }
        return Task {
            let result: Result<GitRepoState, Error>
            do { result = .success(try await svc(p).git.status(p)) } catch { result = .failure(error) }
            gitRefreshing.remove(id)
            // Asked again meanwhile (files changed, a git action finished): this may be stale.
            if gitRefreshAgain.remove(id) != nil { refreshGit(id); return }
            switch result {
            case .success(let new):
                let old = git[id]
                git[id] = new
                gitErrors[id] = nil
                gitChanged(id, from: old, to: new)
            case .failure(let error):
                // Keep the last good status (a hiccup isn't "not a repository").
                if git[id] == nil { git[id] = .empty }
                gitErrors[id] = error.localizedDescription
            }
        }
    }

    /// A git action's own result; a read already running is then out of date.
    private func setGit(_ id: ProjectID, _ s: GitRepoState) {
        git[id] = s
        if gitRefreshing.contains(id) { gitRefreshAgain.insert(id) }
    }

    /// Runs a git operation with busy state and an error toast.
    private func gitOp(_ id: ProjectID, _ label: String, success: String? = nil, progress: Bool = false,
                       _ op: @escaping (GitService, Project) async throws -> GitRepoState) {
        guard let p = project(id) else { return }
        gitBusy.insert("\(id):\(label)")
        let t = progress ? toast(.progress, "\(label)…") : nil
        Task {
            do {
                setGit(id, try await op(svc(p).git, p))
                if let t { finish(t, .success, success ?? label) } else if let success { toast(.success, success) }
            } catch {
                if let t { dismissToast(t) }
                toast(.error, "\(label) failed", detail: error.localizedDescription)
            }
            gitBusy.remove("\(id):\(label)")
        }
    }

    func isGitBusy(_ id: ProjectID, _ label: String) -> Bool { gitBusy.contains("\(id):\(label)") }

    /// Staging a file with merge conflicts marks it resolved, so that asks first.
    func stage(_ id: ProjectID, _ paths: [String]) {
        let run: () -> Void = { [weak self] in self?.gitOp(id, "Stage") { try await $0.stage($1, paths: paths) } }
        let conflicted = git[id]?.unstaged.filter { c in c.conflict && paths.contains { $0 == "." || $0 == c.path } }.map(\.name) ?? []
        if conflicted.isEmpty { run(); return }
        let what = conflicted.count == 1 ? conflicted[0] : "\(conflicted.count) files"
        confirm("Mark \(what) as resolved?", "Staging tells Git the merge conflicts are fixed. Make sure no conflict markers are left.", confirm: "Stage", destructive: false, action: run)
    }

    /// A staged rename unstages with its source path, or the deletion stays staged.
    func unstage(_ id: ProjectID, _ paths: [String]) {
        let sources = git[id]?.staged.filter { paths.contains($0.path) }.compactMap(\.origPath) ?? []
        gitOp(id, "Unstage") { try await $0.unstage($1, paths: paths + sources) }
    }

    func stageAll(_ id: ProjectID) {
        let paths = git[id]?.unstaged.map(\.path) ?? []
        guard !paths.isEmpty else { return }
        // One pathspec for the whole project folder rather than every path on the command line.
        stage(id, project(id)?.isSample == true ? paths : ["."])
    }

    func unstageAll(_ id: ProjectID) {
        let paths = git[id]?.staged.map(\.path) ?? []
        guard !paths.isEmpty else { return }
        unstage(id, paths)
    }

    func requestDiscard(_ id: ProjectID, _ paths: [String]) {
        guard !paths.isEmpty else { return }
        let what = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) files"
        confirm("Discard changes to \(what)?", "This can't be undone. Untracked files are deleted.", confirm: "Discard") { [weak self] in
            self?.gitOp(id, "Discard", success: "Discarded \(what)") { try await $0.discard($1, paths: paths) }
        }
    }

    func commit(_ id: ProjectID, message: String, then: @escaping (Bool) -> Void = { _ in }) {
        guard let p = project(id) else { return }
        let count = git[id]?.staged.count ?? 0
        gitBusy.insert("\(id):Commit")
        Task {
            do {
                setGit(id, try await svc(p).git.commit(p, message: message))
                toast(.success, "Committed \(count) file\(count == 1 ? "" : "s")", detail: message.components(separatedBy: "\n").first)
                then(true)
            } catch {
                toast(.error, "Commit failed", detail: error.localizedDescription)
                then(false)
            }
            gitBusy.remove("\(id):Commit")
        }
    }

    func fetch(_ id: ProjectID) { gitOp(id, "Fetch", success: "Fetched", progress: true) { try await $0.fetch($1) } }
    func pull(_ id: ProjectID) { gitOp(id, "Pull", success: "Pulled", progress: true) { try await $0.pull($1) } }

    func push(_ id: ProjectID) {
        let n = git[id]?.ahead ?? 0
        gitOp(id, "Push", success: "Pushed \(n) commit\(n == 1 ? "" : "s")", progress: true) { try await $0.push($1) }
    }

    func switchBranch(_ id: ProjectID, to name: String) {
        let doSwitch: () -> Void = { [weak self] in
            self?.gitOp(id, "Switch branch", success: "Switched to \(name)") { try await $0.switchBranch($1, to: name) }
        }
        if let s = git[id], !s.isClean {
            confirm("Switch to \(name) with uncommitted changes?", "\(s.changedFileCount) changed file\(s.changedFileCount == 1 ? "" : "s") will be carried over, or Git will refuse if they conflict.", confirm: "Switch", destructive: false, action: doSwitch)
        } else {
            doSwitch()
        }
    }

    func createBranch(_ id: ProjectID, name: String) {
        gitOp(id, "Create branch", success: "Created \(name)") { try await $0.createBranch($1, name: name) }
    }

    func requestDeleteBranch(_ id: ProjectID, name: String) {
        confirm("Delete branch \(name)?", "Unmerged work on this branch may be lost.", confirm: "Delete") { [weak self] in
            self?.gitOp(id, "Delete branch", success: "Deleted \(name)") { try await $0.deleteBranch($1, name: name) }
        }
    }

    var totalUncommitted: Int { library.projects.reduce(0) { $0 + changeCount($1.id) } }
    var totalUnpushed: Int { library.projects.reduce(0) { $0 + (git[$1.id]?.ahead ?? 0) } }
}
