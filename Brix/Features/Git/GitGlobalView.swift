import SwiftUI
import AppKit

/// Centre "Review" mode: diff with line numbers, stage/unstage, commit bar.
struct ReviewView: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    @State private var diff: FileDiff?
    @State private var loading = false

    private var git: GitRepoState? { store.git[ws.projectID] }

    private var change: GitFileChange? {
        guard let g = git else { return nil }
        let want = ws.state.reviewFile ?? ""
        let path = String(want.dropFirst(2))
        return g.changes.first { $0.id == want } ?? g.changes.first { $0.path == path } ?? g.changes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let g = git, let c = change {
                header(c)
                diffBody
                CommitBox(ws: ws, git: g, compact: false)
            } else if let g = git, g.isRepo {
                EmptyState(symbol: "checkmark.circle", message: "Nothing to commit. Working tree clean.", actionTitle: g.ahead > 0 ? "Push ↑\(g.ahead)" : nil) { store.push(ws.projectID) }
            } else if git == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(symbol: "arrow.triangle.branch", message: "This folder is not a Git repository.")
            }
        }
        .island(Theme.editor)
        .task(id: "\(change?.id ?? "")-\(change?.add ?? 0)-\(change?.del ?? 0)") { await load() }
    }

    private func load() async {
        guard let p = ws.project, let c = change else { diff = nil; return }
        if let cached = ws.diffs[c.id], cached.add == c.add, cached.del == c.del { diff = cached; return }
        loading = true
        do {
            let d = try await store.svc(p).git.diff(p, change: c)
            ws.diffs[c.id] = d
            diff = d
        } catch {
            diff = nil
            store.toast(.error, "Couldn't load the diff", detail: error.localizedDescription)
        }
        loading = false
    }

    private func header(_ c: GitFileChange) -> some View {
        HStack(spacing: 10) {
            GitStatusLetter(status: c.status)
            Text(c.name).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
            Text(c.dir).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
            Text(c.staged ? "Staged" : "Unstaged")
                .font(Typo.ui(10.5, .semibold))
                .foregroundStyle(c.staged ? Theme.green : Theme.amber)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill((c.staged ? Theme.green : Theme.amber).opacity(0.10)))
            fileSwitcher
            Spacer(minLength: 0)
            AddDel(add: c.add, del: c.del, size: 11)
            SegmentedControl(options: [(DiffMode.unified, "Unified"), (DiffMode.split, "Split")],
                             selection: Binding(get: { ws.state.diffMode }, set: { ws.state.diffMode = $0 }), fill: Theme.input)
            SubtleButton(title: c.staged ? "Unstage" : "Stage", height: 28) {
                if c.staged { store.unstage(ws.projectID, [c.path]) } else { store.stage(ws.projectID, [c.path]) }
                ws.state.reviewFile = (c.staged ? "w:" : "s:") + c.path
            }
            if !c.staged {
                IconButton(symbol: "arrow.uturn.backward", label: "Discard changes", size: 28, iconSize: 12) { store.requestDiscard(ws.projectID, [c.path]) }
            }
        }
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(height: 44)
        .background(Theme.island)
        .hairlineBottom()
    }

    private var fileSwitcher: some View {
        MenuButton(items: {
            (git?.changes ?? []).map { c in
                MenuSpec(title: "\(c.status.rawValue)  \(c.path)\(c.staged ? "  (staged)" : "")", checked: c.id == change?.id) { ws.state.reviewFile = c.id }
            }
        }) {
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .accessibilityLabel("Choose changed file")
    }

    @ViewBuilder private var diffBody: some View {
        if let d = diff {
            if d.lines.isEmpty {
                EmptyState(symbol: "doc", message: "No textual changes (binary file or mode change).")
            } else if ws.state.diffMode == .unified {
                UnifiedDiffView(diff: d)
            } else {
                SplitDiffView(diff: d)
            }
        } else if loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }
}

struct DiffRowStyle {
    static func bg(_ k: DiffLineKind) -> Color {
        switch k {
        case .add: Theme.green.opacity(0.08)
        case .del: Theme.red.opacity(0.08)
        case .hunk: Color.white(0.03)
        case .context: .clear
        }
    }
    static func fg(_ k: DiffLineKind) -> Color {
        switch k {
        case .add: Theme.diffAddText
        case .del: Theme.diffDelText
        case .hunk: Theme.text3
        case .context: Theme.body
        }
    }
    static func bar(_ k: DiffLineKind) -> Color {
        switch k {
        case .add: Theme.green
        case .del: Theme.red
        default: .clear
        }
    }
}

/// The unified diff: one native text view (only what's on screen is laid out,
/// so long diffs scroll smoothly), full-width tints per line, and a gutter with
/// old and new line numbers. Text selects and copies like any editor.
struct UnifiedDiffView: NSViewRepresentable {
    let diff: FileDiff

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var path = ""
        var shown: [String] = []
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = DiffInk.background
        let tv = DiffTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = true
        tv.backgroundColor = DiffInk.background
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        tv.layoutManager?.allowsNonContiguousLayout = true
        scroll.documentView = tv
        let ruler = DiffRuler(textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Compared by content: a re-read of the same diff (new line ids) keeps the
        // scroll position and selection; only a different file goes back to the top.
        let content = diff.lines.map { "\($0.kind)|\($0.old ?? -1)|\($0.new ?? -1)|\($0.text)" }
        guard content != context.coordinator.shown, let tv = scroll.documentView as? DiffTextView else { return }
        let newFile = diff.path != context.coordinator.path
        context.coordinator.shown = content
        context.coordinator.path = diff.path
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = 20
        para.maximumLineHeight = 20
        let font = NSFont.code(ofSize: 12)
        let out = NSMutableAttributedString()
        var starts: [Int] = []
        for (i, l) in diff.lines.enumerated() {
            starts.append(out.length)
            let color: NSColor = switch l.kind {
            case .add: DiffInk.addText
            case .del: DiffInk.delText
            case .hunk: DiffInk.meta
            case .context: DiffInk.body
            }
            out.append(NSAttributedString(string: l.text + (i + 1 < diff.lines.count ? "\n" : ""),
                                          attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]))
        }
        tv.lines = diff.lines.map { ($0.kind, $0.old, $0.new) }
        tv.lineStarts = starts
        tv.textStorage?.setAttributedString(out)
        if newFile { tv.scroll(.zero) }
        scroll.verticalRulerView?.needsDisplay = true
    }
}

/// Paints each diff line's tint across the full width, behind the text.
final class DiffTextView: NSTextView {
    var lines: [(kind: DiffLineKind, old: Int?, new: Int?)] = []
    var lineStarts: [Int] = []

    /// The diff line a character belongs to.
    func line(at char: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= char { lo = mid } else { hi = mid - 1 }
        }
        return max(0, lo)
    }

    /// Visible line fragments with the diff line each starts.
    func visibleLines(in rect: NSRect, _ body: (Int, NSRect) -> Void) {
        guard let lm = layoutManager, let tc = textContainer, !lines.isEmpty else { return }
        let glyphs = lm.glyphRange(forBoundingRect: rect, in: tc)
        var found: [(Int, NSRect)] = []
        lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, range, _ in
            let char = lm.characterIndexForGlyph(at: range.location)
            let i = self.line(at: char)
            guard i < self.lineStarts.count, self.lineStarts[i] == char || i == 0 else { return }
            found.append((i, frag.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)))
        }
        for (i, r) in found { body(i, r) }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        visibleLines(in: rect) { i, frag in
            let k = lines[i].kind
            guard k != .context else { return }
            let row = NSRect(x: 0, y: frag.minY, width: max(bounds.width, rect.maxX), height: frag.height)
            (k == .add ? DiffInk.addBg : k == .del ? DiffInk.delBg : DiffInk.hunkBg).setFill()
            row.fill()
            if k == .add || k == .del {
                (k == .add ? DiffInk.add : DiffInk.del).setFill()
                NSRect(x: 0, y: row.minY, width: 2, height: row.height).fill()
            }
        }
    }
}

/// Old and new line numbers and the +/− mark, beside the diff.
final class DiffRuler: NSRulerView {
    weak var diffView: DiffTextView?

    init(textView: DiffTextView) {
        diffView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        ruleThickness = 106
        clipsToBounds = true
        // Only this diff's scrolling (the document view is set before the ruler is made).
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func redraw(_ n: Notification) {
        if (n.object as? NSView) === scrollView?.contentView { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        DiffInk.background.setFill()
        bounds.fill()
        guard let tv = diffView else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: DiffInk.number]
        let shift = convert(NSPoint.zero, from: tv).y
        tv.visibleLines(in: tv.visibleRect) { i, frag in
            let l = tv.lines[i]
            let y = frag.minY + shift
            if l.kind != .context && l.kind != .hunk {
                (l.kind == .add ? DiffInk.addBg : DiffInk.delBg).setFill()
                NSRect(x: 0, y: y, width: ruleThickness, height: frag.height).fill()
            }
            func put(_ s: String, right: CGFloat, color: NSColor? = nil) {
                var a = attrs
                if let color { a[.foregroundColor] = color }
                let size = (s as NSString).size(withAttributes: a)
                (s as NSString).draw(at: NSPoint(x: right - size.width, y: y + (frag.height - size.height) / 2), withAttributes: a)
            }
            if let o = l.old { put("\(o)", right: 40) }
            if let n = l.new { put("\(n)", right: 82) }
            if l.kind == .add { put("+", right: 100, color: DiffInk.add) }
            if l.kind == .del { put("−", right: 100, color: DiffInk.del) }
        }
    }
}

/// Diff colours made in AppKit (see GridInk).
enum DiffInk {
    private static func dyn(_ dark: UInt32, _ light: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { ap in NSColor(hex: ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light).withAlphaComponent(alpha) }
    }
    static let background = dyn(0x0E0E10, 0xFFFFFF)
    static let body = dyn(0xD4D4D8, 0x27272A)
    static let meta = dyn(0x8A8A93, 0x6B6B74)
    static let number = dyn(0x52525B, 0xA1A1AA)
    static let addText = dyn(0xD9F99D, 0x166534)
    static let delText = dyn(0xFECACA, 0x991B1B)
    static let add = dyn(0x4ADE80, 0x16A34A)
    static let del = dyn(0xF87171, 0xDC2626)
    static let addBg = dyn(0x4ADE80, 0x16A34A, 0.08)
    static let delBg = dyn(0xF87171, 0xDC2626, 0.08)
    static let hunkBg = dyn(0xFFFFFF, 0x000000, 0.03)
}

struct SplitDiffView: View {
    let diff: FileDiff

    private struct Pair: Identifiable {
        let id: Int
        var left: DiffLine?
        var right: DiffLine?
    }

    /// Pairs runs of deletions with following additions.
    private var pairs: [Pair] {
        var out: [Pair] = []
        var dels: [DiffLine] = [], adds: [DiffLine] = []
        func flush() {
            for i in 0..<max(dels.count, adds.count) {
                out.append(Pair(id: out.count, left: i < dels.count ? dels[i] : nil, right: i < adds.count ? adds[i] : nil))
            }
            dels = []; adds = []
        }
        for l in diff.lines {
            switch l.kind {
            case .del: if !adds.isEmpty { flush() }; dels.append(l)
            case .add: adds.append(l)
            default: flush(); out.append(Pair(id: out.count, left: l, right: l))
            }
        }
        flush()
        return out
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(pairs) { p in
                    HStack(spacing: 0) {
                        side(p.left, number: p.left?.old)
                        Rectangle().fill(Theme.divider).frame(width: 1)
                        side(p.right, number: p.right?.new)
                    }
                    .frame(height: 20)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func side(_ l: DiffLine?, number: Int?) -> some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "").frame(width: 40, alignment: .trailing).padding(.trailing, 10).foregroundStyle(Theme.disabled)
            Text(l?.text ?? "").foregroundStyle(DiffRowStyle.fg(l?.kind ?? .context)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(Typo.mono(12))
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .background(l.map { DiffRowStyle.bg($0.kind) } ?? Color.white(0.015))
        .overlay(alignment: .leading) { Rectangle().fill(DiffRowStyle.bar(l?.kind ?? .context)).frame(width: 2) }
    }
}

// MARK: - History and branches

struct HistoryTimeline: View {
    @Environment(AppStore.self) private var store
    let projectID: ProjectID
    @Binding var selected: String?

    var body: some View {
        let commits = store.git[projectID]?.commits ?? []
        let hue = store.project(projectID)?.hue.color ?? Theme.violet
        if commits.isEmpty {
            EmptyState(symbol: "clock", message: "No commits yet.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(commits.enumerated()), id: \.element.id) { i, c in
                        Button {
                            selected = c.hash
                            store.inspector = .commit(projectID, c.hash)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(spacing: 0) {
                                    Circle()
                                        .fill(i == 0 ? hue : .clear)
                                        .overlay(Circle().strokeBorder(i == 0 ? hue : Theme.disabled, lineWidth: 1.5))
                                        .frame(width: 9, height: 9)
                                        .padding(.top, 4)
                                    if i < commits.count - 1 { Rectangle().fill(Color.white(0.08)).frame(width: 1.5).padding(.top, 3) }
                                }
                                .frame(width: 12)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.message).font(Typo.ui(12.5)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                                    HStack(spacing: 6) {
                                        Text(c.short).font(Typo.mono(11)).foregroundStyle(hue)
                                        Text("\(c.author) · \(RelativeTime.long(c.date))").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                                        if !c.isPushed { Text("↑").font(Typo.ui(11, .bold)).foregroundStyle(Theme.amber).accessibilityLabel("Not pushed") }
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.bottom, 12).padding(.top, 2)
                            .background(RoundedRectangle(cornerRadius: 7).fill(selected == c.hash ? Theme.selected : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hand)
                        .contextMenu { Button("Copy Hash") { store.copyToPasteboard(c.hash, label: "hash") } }
                    }
                }
                .padding(8)
            }
        }
    }
}

struct BranchesList: View {
    @Environment(AppStore.self) private var store
    let projectID: ProjectID

    var body: some View {
        let branches = store.git[projectID]?.branches ?? []
        let hue = store.project(projectID)?.hue.color ?? Theme.violet
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(branches) { b in
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5)).foregroundStyle(b.isCurrent ? hue : Theme.text3)
                            Text(b.name).font(Typo.mono(11.5)).foregroundStyle(b.isCurrent ? Theme.text : Theme.body).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(b.isCurrent ? "current" : b.lastCommit).font(Typo.ui(11)).foregroundStyle(Theme.meta)
                        }
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(b.isCurrent ? hue.opacity(0.10) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if !b.isCurrent { store.switchBranch(projectID, to: b.name) } }
                        .contextMenu {
                            Button("Switch to \(b.name)") { store.switchBranch(projectID, to: b.name) }.disabled(b.isCurrent)
                            Button("Delete…", role: .destructive) { store.requestDeleteBranch(projectID, name: b.name) }.disabled(b.isCurrent)
                        }
                        .accessibilityLabel("\(b.name)\(b.isCurrent ? ", current" : "")")
                    }
                }
                .padding(8)
            }
            HStack {
                SubtleButton(title: "New Branch", symbol: "plus", height: 26) { store.sheet = .newBranch(projectID) }
                Spacer()
                Text("Double-click to switch").font(Typo.ui(10.5)).foregroundStyle(Theme.meta)
            }
            .padding(10).hairlineTop()
        }
    }
}

// MARK: - Global Git screen

struct GitGlobalView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    @State var projectID: ProjectID?
    @State private var tab = 0
    @State var selectedCommit: String?
    /// Panel widths, dragged from the gaps between them; kept across launches.
    @AppStorage("git.listWidth") private var listWidth: Double = 286
    @AppStorage("git.repoWidth") private var repoWidth: Double = 300

    var current: ProjectID? {
        projectID ?? store.sortedProjects.first { store.changeCount($0.id) > 0 }?.id ?? store.sortedProjects.first?.id
    }

    var body: some View {
        if store.library.projects.isEmpty {
            EmptyState(symbol: "arrow.triangle.branch", message: "Add a project to see its changes here.", actionTitle: "Add Project") { store.sheet = .addProject }
                .island()
        } else {
            HStack(spacing: 0) {
                summary.frame(width: listWidth)
                ResizeHandle(axis: .horizontal, thickness: gap) { listWidth = min(max(listWidth + $0, 220), 520) }
                if let id = current {
                    let ws = store.workspace(for: id)
                    VStack(spacing: gap) {
                        ReviewView(ws: ws)
                    }
                    .frame(maxWidth: .infinity)
                    ResizeHandle(axis: .horizontal, thickness: gap) { repoWidth = min(max(repoWidth - $0, 240), 560) }
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Text("Repository").font(Typo.panelTitle).tracking(0.4).foregroundStyle(Theme.text2)
                            Spacer()
                            SegmentedControl(options: [(0, "Changes"), (1, "History"), (2, "Branches")], selection: $tab, height: 22, fontSize: 11)
                        }
                        .padding(.horizontal, 10).frame(height: Metrics.panelHeader).hairlineBottom()
                        switch tab {
                        case 0: changes(ws)
                        case 1: HistoryTimeline(projectID: id, selected: $selectedCommit)
                        default: BranchesList(projectID: id)
                        }
                    }
                    .frame(width: repoWidth)
                    .island()
                }
            }
            .onAppear { store.library.projects.forEach { store.refreshGit($0.id) } }
        }
    }

    private func changes(_ ws: WorkspaceStore) -> some View {
        let g = store.git[ws.projectID]
        return VStack(spacing: 0) {
            if let g, g.isRepo {
                BranchSyncRow(projectID: ws.projectID, git: g).padding(10).hairlineBottom()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(g.changes) { c in ChangeRow(ws: ws, change: c, showCheckbox: true) }
                    }
                    .padding(6)
                }
                if g.isClean { EmptyState(symbol: "checkmark.circle", message: "Nothing to commit.") }
            } else {
                EmptyState(symbol: "arrow.triangle.branch", message: "Not a Git repository.")
            }
        }
        .onAppear { if ws.layout.centre != .review { ws.state.reviewFile = ws.state.reviewFile ?? g?.changes.first?.id } }
    }

    private var summary: some View {
        VStack(spacing: 0) {
            IslandHeader(title: "All projects") {
                Text("\(store.totalUncommitted) changed · ↑\(store.totalUnpushed)").font(Typo.ui(11)).foregroundStyle(Theme.text3)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    // Top-level projects, each followed by its repositories on a
                    // guide line, so a repo is always read under its parent.
                    ForEach(store.sortedProjects.filter { $0.parentID == nil }) { p in
                        let repos = store.children(of: p.id)
                        projectRow(p, repos: repos)
                        ForEach(repos) { r in repoRow(r, parent: p, last: r.id == repos.last?.id) }
                    }
                }
                .padding(6)
            }
        }
        .island()
    }
}

extension GitGlobalView {
    /// A parent folder of several repositories is not a repo itself: it shows
    /// the totals of its repos instead of "Not a repository".
    fileprivate func projectRow(_ p: Project, repos: [Project]) -> some View {
        let g = store.git[p.id]
        let isGroup = !repos.isEmpty && g?.isRepo != true
        let n = isGroup ? repos.reduce(0) { $0 + (store.git[$1.id]?.changedFileCount ?? 0) } : (g?.changedFileCount ?? 0)
        let ahead = isGroup ? repos.reduce(0) { $0 + (store.git[$1.id]?.ahead ?? 0) } : (g?.ahead ?? 0)
        let sub = isGroup ? "\(repos.count) repositor\(repos.count == 1 ? "y" : "ies")" : (g?.isRepo == false ? "Not a repository" : "⎇ \(g?.branch ?? "…")")
        return Button { projectID = isGroup ? (repos.first?.id ?? p.id) : p.id; selectedCommit = nil } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProjectMark(project: p, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                        Text(sub).font(isGroup ? Typo.ui(10.5) : Typo.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(n == 0 ? "Clean" : "\(n) changed").font(Typo.ui(11, .medium)).foregroundStyle(n == 0 ? Theme.green : Theme.amber)
                        if ahead > 0 { Text("↑\(ahead) to push").font(Typo.ui(10.5)).foregroundStyle(Theme.text3) }
                    }
                }
                if !isGroup, let g, !g.isClean { ChangeBar(changes: g.changes, hue: p.hue.color) }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .rowBackground(selected: p.id == current, radius: 8)
        }
        .buttonStyle(.hand)
        .contextMenu { ProjectContextMenu(project: p) }
        .padding(.top, 4)
    }

    /// A repository under its project: indented on the parent's guide line.
    fileprivate func repoRow(_ r: Project, parent p: Project, last: Bool) -> some View {
        let g = store.git[r.id]
        let n = g?.changedFileCount ?? 0
        return Button { projectID = r.id; selectedCommit = nil } label: {
            HStack(spacing: 0) {
                // ├ or └ in the parent's colour.
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(p.hue.color.opacity(0.35)).frame(width: 1.5).frame(maxHeight: last ? 22 : .infinity, alignment: .top)
                    Rectangle().fill(p.hue.color.opacity(0.35)).frame(width: 10, height: 1.5).offset(y: 21)
                }
                .frame(width: 14, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        ProjectMark(project: r, size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).font(Typo.ui(12, .medium)).foregroundStyle(Theme.text)
                            Text(g?.isRepo == false ? "Not a repository" : "⎇ \(g?.branch ?? "…")").font(Typo.mono(10)).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(n == 0 ? "Clean" : "\(n) changed").font(Typo.ui(10.5, .medium)).foregroundStyle(n == 0 ? Theme.green : Theme.amber)
                            if let a = g?.ahead, a > 0 { Text("↑\(a) to push").font(Typo.ui(10)).foregroundStyle(Theme.text3) }
                        }
                    }
                    if let g, !g.isClean { ChangeBar(changes: g.changes, hue: r.hue.color) }
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .rowBackground(selected: r.id == current, radius: 8)
            }
            .padding(.leading, 20)
        }
        .buttonStyle(.hand)
        .contextMenu { ProjectContextMenu(project: r) }
    }
}

/// Green/red proportion bar of added and deleted lines.
struct ChangeBar: View {
    let changes: [GitFileChange]
    var hue: Color = Theme.violet

    var body: some View {
        let add = Double(changes.reduce(0) { $0 + $1.add })
        let del = Double(changes.reduce(0) { $0 + $1.del })
        let total = max(add + del, 1)
        // Bar fills up to 76% of the width, scaled by size (capped at 300 lines).
        let scale = min(1, total / 300) * 0.76
        GeometryReader { geo in
            HStack(spacing: 2) {
                Rectangle().fill(Theme.green).frame(width: max(2, geo.size.width * scale * add / total))
                Rectangle().fill(Theme.red).frame(width: max(del > 0 ? 2 : 0, geo.size.width * scale * del / total))
                Rectangle().fill(Color.white(0.06))
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .accessibilityLabel("\(Int(add)) lines added, \(Int(del)) removed")
    }
}
