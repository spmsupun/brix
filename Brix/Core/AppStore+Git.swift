import SwiftUI

extension AppStore {
    func refreshGit(_ id: ProjectID) {
        guard let p = project(id) else { return }
        Task {
            do {
                let old = git[id]
                let new = try await svc(p).git.status(p)
                git[id] = new
                gitErrors[id] = nil
                gitChanged(id, from: old, to: new)
            } catch {
                git[id] = .empty
                gitErrors[id] = error.localizedDescription
            }
        }
    }

    /// Runs a git operation with busy state and an error toast.
    private func gitOp(_ id: ProjectID, _ label: String, success: String? = nil, progress: Bool = false,
                       _ op: @escaping (GitService, Project) async throws -> GitRepoState) {
        guard let p = project(id) else { return }
        gitBusy.insert("\(id):\(label)")
        let t = progress ? toast(.progress, "\(label)…") : nil
        Task {
            do {
                git[id] = try await op(svc(p).git, p)
                if let t { finish(t, .success, success ?? label) } else if let success { toast(.success, success) }
            } catch {
                if let t { dismissToast(t) }
                toast(.error, "\(label) failed", detail: error.localizedDescription)
            }
            gitBusy.remove("\(id):\(label)")
        }
    }

    func isGitBusy(_ id: ProjectID, _ label: String) -> Bool { gitBusy.contains("\(id):\(label)") }

    func stage(_ id: ProjectID, _ paths: [String]) { gitOp(id, "Stage") { try await $0.stage($1, paths: paths) } }
    func unstage(_ id: ProjectID, _ paths: [String]) { gitOp(id, "Unstage") { try await $0.unstage($1, paths: paths) } }

    func stageAll(_ id: ProjectID) {
        let paths = git[id]?.unstaged.map(\.path) ?? []
        guard !paths.isEmpty else { return }
        stage(id, paths)
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
                git[id] = try await svc(p).git.commit(p, message: message)
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
