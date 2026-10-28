import SwiftUI
import AppKit

struct ExplorerPanel: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    private struct Row: Identifiable {
        var id: String { node.path }
        let node: FileNode
        let depth: Int
    }

    /// Visible rows: expanded folders only, or every match when filtering.
    private var rows: [Row] {
        var out: [Row] = []
        let f = filter.lowercased()
        func walk(_ nodes: [FileNode], _ depth: Int) {
            for n in nodes {
                if f.isEmpty {
                    out.append(Row(node: n, depth: depth))
                    if n.isDirectory, ws.state.expanded.contains(n.path) { walk(n.children ?? [], depth + 1) }
                } else if !n.isDirectory, n.path.lowercased().contains(f) {
                    out.append(Row(node: n, depth: 0))
                } else if n.isDirectory {
                    walk(n.children ?? [], depth)
                }
            }
        }
        walk(ws.tree, 0)
        return out
    }

    private var agentFiles: Set<String> {
        Set(store.sessions.filter { $0.projectID == ws.projectID && $0.kind == .agent }.flatMap { $0.touched.map(\.path) })
    }

    var body: some View {
        let hue = ws.project?.hue.color ?? Theme.violet
        PanelChrome(title: "Explorer") {
            Spacer(minLength: 0)
            IconButton(symbol: "doc.badge.plus", label: "New file", iconSize: 12) { store.sheet = .newFile(ws.projectID, isDirectory: false, parent: parentForNew) }
            IconButton(symbol: "folder.badge.plus", label: "New folder", iconSize: 12) { store.sheet = .newFile(ws.projectID, isDirectory: true, parent: parentForNew) }
        } content: {
            VStack(spacing: 0) {
                SearchField(placeholder: "Go to file", text: $filter, shortcut: "⌘P", focus: $filterFocused)
                    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 6)
                    .onSubmit { if let first = rows.first(where: { !$0.node.isDirectory }) { ws.open(first.node.path); filter = "" } }
                if let err = ws.treeError {
                    EmptyState(symbol: "exclamationmark.triangle", message: err, actionTitle: "Retry") { ws.loadTree() }
                } else if ws.tree.isEmpty {
                    EmptyState(symbol: "folder", message: "This folder is empty.")
                } else if rows.isEmpty {
                    EmptyState(symbol: "magnifyingglass", message: "No files match “\(filter)”.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { r in row(r, hue: hue) }
                        }
                        .padding(.horizontal, 6).padding(.bottom, 8).padding(.top, 2)
                    }
                }
            }
        }
    }

    private var parentForNew: String {
        guard let sel = ws.state.selection else { return "" }
        if ws.state.expanded.contains(sel) { return sel }
        return (sel as NSString).deletingLastPathComponent
    }

    private func row(_ r: Row, hue: Color) -> some View {
        let n = r.node
        let selected = ws.state.selection == n.path
        let open = ws.state.expanded.contains(n.path)
        return HStack(spacing: 5) {
            // Indent guides
            HStack(spacing: 0) {
                ForEach(0..<r.depth, id: \.self) { _ in
                    Rectangle().fill(Color.white(0.06)).frame(width: 1).padding(.leading, 5).frame(width: 12, alignment: .leading)
                }
            }
            Image(systemName: n.isDirectory ? (open ? "chevron.down" : "chevron.right") : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.meta)
                .frame(width: 10)
                .opacity(n.isDirectory ? 1 : 0)
            Image(systemName: n.isDirectory ? "folder.fill" : (FileKinds.isImage(n.name) ? "photo" : "doc"))
                .font(.system(size: 11.5))
                .foregroundStyle(n.isDirectory ? Theme.text3.opacity(0.6) : FileKinds.iconColor(for: n.name))
                .frame(width: 14)
            Text(n.name)
                .font(Typo.row)
                .foregroundStyle(n.name.hasPrefix(".env") ? Theme.meta : (selected ? Theme.text : Theme.body))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if agentFiles.contains(n.path) {
                Text("✦").font(.system(size: 10)).foregroundStyle(Theme.violet).accessibilityLabel("Touched by an agent")
            }
            GitStatusLetter(status: n.gitStatus)
        }
        .padding(.leading, 4).padding(.trailing, 6)
        .frame(height: 24)
        .rowBackground(selected: selected, tint: hue, radius: 6)
        .onTapGesture { activate(n) }
        .contextMenu { menu(n) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(n.name)\(n.gitStatus.map { ", \($0.name)" } ?? "")")
        .accessibilityAddTraits(.isButton)
    }

    private func activate(_ n: FileNode) {
        ws.state.selection = n.path
        if n.isDirectory {
            if ws.state.expanded.contains(n.path) { ws.state.expanded.remove(n.path) } else { ws.state.expanded.insert(n.path) }
        } else {
            ws.open(n.path)
        }
    }

    @ViewBuilder private func menu(_ n: FileNode) -> some View {
        let abs = (ws.project?.expandedPath ?? "") + "/" + n.path
        if !n.isDirectory {
            Button("Open") { ws.open(n.path) }
            Button("Open to the Side") { ws.open(n.path, split: true) }
        }
        Button("New File…") { store.sheet = .newFile(ws.projectID, isDirectory: false, parent: n.isDirectory ? n.path : (n.path as NSString).deletingLastPathComponent) }
        Button("New Folder…") { store.sheet = .newFile(ws.projectID, isDirectory: true, parent: n.isDirectory ? n.path : (n.path as NSString).deletingLastPathComponent) }
        Button("Rename…") { store.sheet = .renameFile(ws.projectID, path: n.path) }
        Divider()
        Button("Copy Path") { store.copyToPasteboard(abs, label: "path") }
        Button("Copy Relative Path") { store.copyToPasteboard(n.path, label: "relative path") }
        Button("Reveal in Finder") { NSWorkspace.shared.selectFile(abs, inFileViewerRootedAtPath: "") }
            .disabled(ws.project?.isSample ?? true)
        Button("Open in Terminal Here") {
            let dir = n.isDirectory ? n.path : (n.path as NSString).deletingLastPathComponent
            let base = ws.project?.path ?? "~"
            store.newTerminal(project: ws.projectID, cwd: dir.isEmpty ? base : base + "/" + dir)
        }
        Divider()
        Button("Ask Agent About This File") { store.askAgent(about: n.path, in: ws.projectID) }
        Button("Show in Inspector") { store.inspector = .file(ws.projectID, n.path) }
    }
}

extension AppStore {
    /// Starts (or reuses) an agent session and sends a question about a file.
    func askAgent(about path: String, in projectID: ProjectID) {
        askAgent(prompt: "Explain @\(path) and point out anything risky.", in: projectID)
    }

    /// Starts (or reuses) an agent session in the project and sends it a prompt.
    func askAgent(prompt: String, in projectID: ProjectID) {
        let ask = { [weak self] (s: TerminalSession, fresh: Bool) in
            guard let self else { return }
            let ws = workspace(for: projectID)
            if fresh { ws.attach(session: s, preferAgentGrid: true) }
            ws.focus(session: s.id)
            if s.isLive {
                // Give the CLI a moment to start before typing into it.
                Task {
                    try? await Task.sleep(nanoseconds: fresh ? 2_500_000_000 : 0)
                    self.sendInput(s.id, prompt)
                }
            } else {
                sendInput(s.id, prompt)
            }
        }
        if let existing = sessions.first(where: { $0.projectID == projectID && $0.kind == .agent && $0.state != .finished && $0.state != .failed }) {
            ask(existing, false)
        } else {
            startAgent(project: projectID) { ask($0, true) }
        }
    }
}
