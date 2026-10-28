import SwiftUI

/// Source Control panel: branch, sync, commit, staged/changes groups, recent commits.
struct SourceControlPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        let g = store.git[ws.projectID]
        PanelChrome(title: "Source Control", count: g.map { $0.changedFileCount > 0 ? "\($0.changedFileCount)" : nil } ?? nil) {
            Spacer(minLength: 0)
            IconButton(symbol: "arrow.clockwise", label: "Refresh", iconSize: 11.5) { store.refreshGit(ws.projectID) }
        } content: {
            if let g, g.isRepo {
                content(g)
            } else if g == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(symbol: "arrow.triangle.branch", message: store.gitErrors[ws.projectID] ?? "This folder is not a Git repository.",
                           actionTitle: store.gitErrors[ws.projectID] == nil ? "Initialise Repository" : "Retry") {
                    if store.gitErrors[ws.projectID] != nil { store.refreshGit(ws.projectID); return }
                    initRepo()
                }
            }
        }
    }

    private func initRepo() {
        guard let p = ws.project, !p.isSample else { return }
        Task {
            do {
                _ = try await ProcessRunner.check("git", ["-C", p.expandedPath, "init"])
                store.refreshGit(p.id)
                store.toast(.success, "Initialised a Git repository")
            } catch {
                store.toast(.error, "git init failed", detail: error.localizedDescription)
            }
        }
    }

    private func content(_ g: GitRepoState) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                BranchSyncRow(projectID: ws.projectID, git: g)
                CommitBox(ws: ws, git: g, compact: true)
            }
            .padding(10)
            .hairlineBottom()
            if g.isClean {
                EmptyState(symbol: "checkmark.circle", message: "Nothing to commit. Working tree clean.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        group("Staged", g.staged, action: "Unstage all") { store.unstageAll(ws.projectID) }
                        group("Changes", g.unstaged, action: "Stage all") { store.stageAll(ws.projectID) }
                    }
                    .padding(6)
                }
            }
            RecentCommits(ws: ws, commits: Array(g.commits.prefix(3)))
        }
    }

    @ViewBuilder private func group(_ title: String, _ items: [GitFileChange], action: String, perform: @escaping () -> Void) -> some View {
        if !items.isEmpty {
            HStack(spacing: 6) {
                Button { toggle(title) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(collapsedGroups.contains(title) ? -90 : 0))
                        Text("\(title) · \(items.count)")
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button(action, action: perform).buttonStyle(.plain).foregroundStyle(Theme.meta).font(Typo.ui(11, .medium))
            }
            .font(Typo.ui(11, .semibold))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 6)
            .frame(height: 28)
            .padding(.top, 4)
            if !collapsedGroups.contains(title) {
                ForEach(items) { c in ChangeRow(ws: ws, change: c) }
            }
        }
    }

    private func toggle(_ t: String) {
        if collapsedGroups.contains(t) { collapsedGroups.remove(t) } else { collapsedGroups.insert(t) }
    }
}

struct BranchSyncRow: View {
    @Environment(AppStore.self) private var store
    let projectID: ProjectID
    let git: GitRepoState

    var body: some View {
        VStack(spacing: 6) {
            MenuButton(items: branchMenu) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                    Text(git.branch).font(Typo.mono(11.5)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("↑\(git.ahead) ↓\(git.behind)").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlStroke))
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Branch \(git.branch), switch branch")
            HStack(spacing: 4) {
                syncButton("Fetch", busy: store.isGitBusy(projectID, "Fetch")) { store.fetch(projectID) }
                syncButton(git.behind > 0 ? "Pull ↓\(git.behind)" : "Pull", busy: store.isGitBusy(projectID, "Pull")) { store.pull(projectID) }
                syncButton(git.ahead > 0 ? "Push ↑\(git.ahead)" : "Push", busy: store.isGitBusy(projectID, "Push"), strong: git.ahead > 0) { store.push(projectID) }
            }
        }
    }

    private func branchMenu() -> [MenuSpec] {
        var items: [MenuSpec] = [.header("Switch branch")]
        items += git.branches.filter { !$0.isRemote }.map { b in
            MenuSpec(title: b.name, checked: b.isCurrent) { if !b.isCurrent { store.switchBranch(projectID, to: b.name) } }
        }
        items += [.separator, MenuSpec(title: "New Branch…", symbol: "plus") { store.sheet = .newBranch(projectID) }]
        let others = git.branches.filter { !$0.isCurrent && !$0.isRemote }
        if !others.isEmpty {
            items.append(MenuSpec(title: "Delete Branch", children: others.map { b in MenuSpec(title: b.name) { store.requestDeleteBranch(projectID, name: b.name) } }))
        }
        return items
    }

    private func syncButton(_ title: String, busy: Bool, strong: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().controlSize(.mini) } else { Text(title) }
            }
            .font(Typo.ui(11.5, strong ? .semibold : .regular))
            .foregroundStyle(strong ? Theme.text : Theme.body)
            .frame(maxWidth: .infinity).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.control))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// Commit message and Commit (⌘↩). `compact` is the panel version.
struct CommitBox: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let ws: WorkspaceStore
    let git: GitRepoState
    var compact: Bool
    @State private var writing = false

    var body: some View {
        let staged = git.staged.count
        let busy = store.isGitBusy(ws.projectID, "Commit")
        let message = Binding(get: { ws.commitMessage }, set: { ws.commitMessage = $0 })
        if compact {
            VStack(spacing: 8) {
                TextField("Commit message", text: message, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .font(Typo.ui(12.5))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlStroke))
                    .accessibilityLabel("Commit message")
                HStack(spacing: 6) {
                    AccentButton(title: staged > 0 ? "Commit \(staged) file\(staged == 1 ? "" : "s")" : "Commit", shortcut: "⌘↩", fullWidth: true, isLoading: busy) { commit() }
                        .disabled(staged == 0 || ws.commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                    writeIt
                }
            }
        } else {
            HStack(spacing: 10) {
                TextField("Commit message", text: message)
                    .textFieldStyle(.plain)
                    .font(Typo.ui(13))
                    .onSubmit(commit)
                    .accessibilityLabel("Commit message")
                writeIt
                AccentButton(title: staged > 0 ? "Commit \(staged) file\(staged == 1 ? "" : "s")" : "Commit", shortcut: "⌘↩", isLoading: busy) { commit() }
                    .disabled(staged == 0 || ws.commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.island))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.controlStroke))
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
    }

    private var writeIt: some View {
        Button {
            guard let p = ws.project else { return }
            writing = true
            Task {
                let m = await store.svc(p).git.suggestMessage(p, staged: git.staged)
                if m.isEmpty { store.toast(.info, "Stage some files first") } else { ws.commitMessage = m }
                writing = false
            }
        } label: {
            HStack(spacing: 5) {
                if writing { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkle").font(.system(size: 9.5, weight: .bold)) }
                Text("Write it").font(Typo.ui(11.5, .medium))
            }
            .foregroundStyle(Theme.agentText)
            .padding(.horizontal, 9).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.violet.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.violet.opacity(0.22)))
        }
        .buttonStyle(.plain)
        .disabled(writing || git.staged.isEmpty)
        .accessibilityLabel("Generate commit message")
        .tip("Suggest a commit message from the staged changes")
    }

    private func commit() {
        let msg = ws.commitMessage
        guard !msg.trimmingCharacters(in: .whitespaces).isEmpty, !git.staged.isEmpty else { return }
        store.commit(ws.projectID, message: msg) { ok in if ok { ws.commitMessage = "" } }
    }
}

struct ChangeRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let ws: WorkspaceStore
    let change: GitFileChange
    var showCheckbox = false
    @State private var hovering = false

    var body: some View {
        let selected = ws.state.reviewFile == change.id && ws.layout.centre == .review
        HStack(spacing: 7) {
            if showCheckbox {
                Button { toggleStage() } label: {
                    ZStack {
                        if change.staged {
                            RoundedRectangle(cornerRadius: 4).fill(accent)
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.onAccent)
                        } else {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.lineNumber, lineWidth: 1.5)
                        }
                    }
                    .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(change.staged ? "Unstage \(change.name)" : "Stage \(change.name)")
            }
            GitStatusLetter(status: change.status).frame(width: 16)
            Text(change.name).font(Typo.row).foregroundStyle(Theme.text).lineLimit(1).layoutPriority(1)
            Text(change.dir).font(Typo.ui(11)).foregroundStyle(Theme.meta).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
            if hovering && !showCheckbox {
                IconButton(symbol: "arrow.uturn.backward", label: "Discard changes", size: 20, iconSize: 10) { store.requestDiscard(ws.projectID, [change.path]) }
                    .opacity(change.staged ? 0 : 1)
                IconButton(symbol: change.staged ? "minus" : "plus", label: change.staged ? "Unstage" : "Stage", size: 20, iconSize: 10) { toggleStage() }
            } else if !showCheckbox {
                AddDel(add: change.add, del: change.del)
            }
        }
        .padding(.leading, 4).padding(.trailing, 8)
        .frame(height: showCheckbox ? 28 : 26)
        .rowBackground(selected: selected || (ws.state.selection == change.path && !showCheckbox), radius: 6)
        .onHover { hovering = $0 }
        .onTapGesture {
            ws.state.reviewFile = change.id
            ws.state.selection = change.path
            store.inspector = .file(ws.projectID, change.path)
            if ws.layout.centre != .review && !showCheckbox {
                if change.status == .D { ws.layout.centre = .review } else { ws.open(change.path) }
            }
        }
        .contextMenu {
            Button(change.staged ? "Unstage" : "Stage") { toggleStage() }
            Button("Open Diff") { ws.state.reviewFile = change.id; ws.layout.centre = .review }
            if change.status != .D { Button("Open File") { ws.open(change.path) } }
            Divider()
            Button("Discard Changes…", role: .destructive) { store.requestDiscard(ws.projectID, [change.path]) }.disabled(change.staged)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(change.name), \(change.status.name)\(change.staged ? ", staged" : "")")
    }

    private func toggleStage() {
        if change.staged { store.unstage(ws.projectID, [change.path]) } else { store.stage(ws.projectID, [change.path]) }
    }
}

struct RecentCommits: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    let commits: [GitCommit]

    var body: some View {
        if !commits.isEmpty {
            let hue = ws.project?.hue.color ?? Theme.violet
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent commits").font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3)
                ForEach(commits) { c in
                    Button { selectCommit(c) } label: {
                        HStack(spacing: 8) {
                            Circle().strokeBorder(hue, lineWidth: 1.5).frame(width: 7, height: 7)
                            Text(c.message).font(Typo.ui(12)).foregroundStyle(Theme.body).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(RelativeTime.short(c.date)).font(Typo.ui(11)).foregroundStyle(Theme.meta)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairlineTop()
        }
    }

    private func selectCommit(_ c: GitCommit) {
        ws.selectedCommit = c.hash
        store.inspector = .commit(ws.projectID, c.hash)
    }
}

enum RelativeTime {
    /// "now", "5m", "2h", "1d", "3w".
    static func short(_ d: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        if s < 86400 * 7 { return "\(s / 86400)d" }
        return "\(s / (86400 * 7))w"
    }

    /// "just now", "5m ago", "2h ago".
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = short(d, now: now)
        return s == "now" ? "just now" : s + " ago"
    }

    /// "5 min", "1 h", "Yesterday", "2 days", "1 week".
    static func long(_ d: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h" }
        let days = s / 86400
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days) days" }
        let w = days / 7
        return w == 1 ? "1 week" : "\(w) weeks"
    }
}
