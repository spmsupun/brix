import SwiftUI
import AppKit

/// Centre "Editor" mode: file tabs plus a read-only preview (split-able).
struct EditorArea: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            if let file = ws.state.activeFile {
                HStack(spacing: 0) {
                    EditorPane(ws: ws, path: file, isSplit: false)
                    if let split = ws.state.splitFile {
                        Rectangle().fill(Theme.divider).frame(width: 1)
                        EditorPane(ws: ws, path: split, isSplit: true)
                    }
                }
            } else {
                EmptyState(symbol: "doc.text.magnifyingglass", message: "Open a file from the Explorer, or press ⌘P to go to a file.", actionTitle: "Go to File") {
                    store.paletteScopeToProject = true
                    store.paletteOpen = true
                }
            }
        }
        .modifier(TileOrIsland(fill: Theme.editor))
    }

    private var tabBar: some View {
        let hue = ws.project?.hue.color ?? Theme.violet
        return HStack(alignment: .bottom, spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(ws.state.openFiles, id: \.self) { f in
                        EditorTab(ws: ws, path: f, selected: f == ws.state.activeFile, hue: hue)
                    }
                }
                .tabStrip()
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                IconButton(symbol: "rectangle.split.2x1", label: "Split editor", shortcut: "⌘D", size: 26, iconSize: 12.5, active: ws.state.splitFile != nil) {
                    ws.state.splitFile = ws.state.splitFile == nil ? ws.state.activeFile : nil
                }
                if let f = ws.state.activeFile {
                    Button { store.askAgent(about: f, in: ws.projectID) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkle").font(.system(size: 9.5, weight: .bold))
                            Text("Ask Agent").font(Typo.ui(11, .medium))
                        }
                        .foregroundStyle(Theme.agentText)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.violet.opacity(0.10)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.violet.opacity(0.22)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ask an agent about this file")
                }
            }
            .frame(height: 37)
        }
        .padding(.horizontal, 6)
        .frame(height: Metrics.tabBar)
        .background(Theme.island)
        .hairlineBottom()
    }
}

struct EditorTab: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    let path: String
    let selected: Bool
    let hue: Color
    @State private var hovering = false

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let st = store.git[ws.projectID]?.changes.first { $0.path == path }?.status
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(FileKinds.iconColor(for: name)).frame(width: 6, height: 6)
            Text(name).font(Typo.ui(12.5, selected ? .medium : .regular)).lineLimit(1)
            GitStatusLetter(status: st)
            if ws.isDirty(path) { Circle().fill(Theme.text2).frame(width: 6, height: 6).accessibilityLabel("Unsaved changes") }
            Button { ws.close(path) } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(selected || hovering ? Theme.text3 : .clear)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(name)")
        }
        .foregroundStyle(selected ? Theme.text : Theme.text3)
        .padding(.leading, 11).padding(.trailing, 8)
        .frame(height: selected ? 33 : 32)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                .fill(selected ? Theme.editor : (hovering ? Theme.hover : .clear))
        )
        .overlay(alignment: .top) {
            if selected { UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2).fill(hue).frame(height: 2).padding(.horizontal, 10) }
        }
        .overlay {
            if selected {
                HStack { Rectangle().fill(Theme.divider).frame(width: 1); Spacer(); Rectangle().fill(Theme.divider).frame(width: 1) }
            }
        }
        .offset(y: selected ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { ws.state.activeFile = path; ws.load(path); store.inspector = .file(ws.projectID, path) }
        .onHover { hovering = $0 }
        .onMiddleClick { ws.close(path) }
        .reorderableTab(path, order: ws.state.openFiles) { from, to in
            guard let a = ws.state.openFiles.firstIndex(of: from), let b = ws.state.openFiles.firstIndex(of: to) else { return }
            ws.state.openFiles.reorder(from: a, onto: b)
        }
        .contextMenu {
            Button("Close") { ws.close(path) }
            Button("Close Others") { ws.state.openFiles.filter { $0 != path }.forEach(ws.close) }
            Button("Open to the Side") { ws.open(path, split: true) }
            Divider()
            Button("Copy Relative Path") { store.copyToPasteboard(path, label: "relative path") }
            Button("Ask Agent About This File") { store.askAgent(about: path, in: ws.projectID) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// One editor pane: breadcrumb plus the file view.
struct EditorPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.inTile) private var inTile
    let ws: WorkspaceStore
    let path: String
    let isSplit: Bool

    var body: some View {
        let change = store.git[ws.projectID]?.changes.first { $0.path == path }
        VStack(spacing: 0) {
            breadcrumb(change)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: path) {
            ws.load(path)
            await ws.loadDiff(for: path)
        }
    }

    private func breadcrumb(_ change: GitFileChange?) -> some View {
        let comps = path.split(separator: "/").map(String.init)
        return HStack(spacing: 6) {
            ForEach(Array(comps.enumerated()), id: \.offset) { i, c in
                Text(c).foregroundStyle(i == comps.count - 1 ? Theme.body : Theme.text3)
                if i < comps.count - 1 { Text("/").foregroundStyle(Theme.lineNumber) }
            }
            if let sym = ws.currentSymbol(in: path) {
                Text("/").foregroundStyle(Theme.lineNumber)
                Text("ƒ \(sym)").font(Typo.mono(11)).foregroundStyle(Theme.text2)
            }
            Spacer(minLength: 0)
            if isSplit {
                IconButton(symbol: "xmark", label: "Close split", size: 20, iconSize: 9) { ws.state.splitFile = nil }
            }
            if let c = change { AddDel(add: c.add, del: c.del, size: 11) }
        }
        .font(Typo.ui(11.5))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .hairlineBottom(Color.white(0.04))
    }

    @ViewBuilder private var content: some View {
        switch ws.contents[path] {
        case nil:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            EmptyState(symbol: "questionmark.folder", message: "This file no longer exists.", actionTitle: "Close") { ws.close(path) }
        case .binary(let size):
            EmptyState(symbol: "doc.zipper", message: "Binary file · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)). Brix shows text and images only.")
        case .image(let img, let size):
            VStack(spacing: 10) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(size.width, 640), maxHeight: min(size.height, 480))
                    .background(CheckerBoard().opacity(0.3))
                Text("\(Int(size.width)) × \(Int(size.height)) px").font(Typo.mono(11)).foregroundStyle(Theme.text3)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text):
            let lang = SyntaxLanguage.detect(path: path)
            if lang == .markdown && ws.state.markdownRendered {
                MarkdownView(text: text)
                    .overlay(alignment: .topTrailing) { mdToggle }
            } else {
                CodeView(text: ws.drafts[path] ?? text, language: lang, editable: ws.project?.isSample == false,
                         onChange: { new in ws.drafts[path] = new == text ? nil : new },
                         marks: ws.gutter[path] ?? [], highlight: claudeEditing ? ws.claudeBlock(in: path) : nil,
                         highlightColor: ws.project?.hue.color ?? Theme.violet, background: inTile ? Theme.pane : Theme.editor,
                         onCursor: { l, c in ws.cursor = (l, c); ws.cursorPath = path })
                    .overlay(alignment: .topTrailing) {
                        if lang == .markdown { mdToggle }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if claudeEditing { claudeChip.padding(18) }
                    }
            }
        }
    }

    private var claudeEditing: Bool {
        store.sessions.contains { $0.projectID == ws.projectID && $0.kind == .agent && $0.state == .running && $0.touched.contains { $0.path == path } }
    }

    private var mdToggle: some View {
        SegmentedControl(options: [(true, "Rendered"), (false, "Source")], selection: Binding(get: { ws.state.markdownRendered }, set: { ws.state.markdownRendered = $0 }), height: 22, fontSize: 11)
            .padding(10)
    }

    private var claudeChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.agentText)
                .frame(width: 18, height: 18).background(RoundedRectangle(cornerRadius: 5).fill(Theme.violet.opacity(0.16)))
            Text("An agent is editing this block").foregroundStyle(Theme.body)
            Text("·").foregroundStyle(Theme.meta)
            Button("View diff") {
                if let c = store.git[ws.projectID]?.changes.first(where: { $0.path == path }) { ws.state.reviewFile = c.id }
                ws.layout.centre = .review
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.agentText)
        }
        .font(Typo.ui(11.5))
        .padding(.leading, 7).padding(.trailing, 8).padding(.vertical, 5)
        .popoverSurface(Theme.popover, radius: 8)
    }
}

struct CheckerBoard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for x in stride(from: 0, to: size.width, by: s) {
                for y in stride(from: 0, to: size.height, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.white.opacity(0.08)))
                }
            }
        }
    }
}

/// Minimal block-level Markdown renderer: headings, lists, quotes, code, tables.
struct MarkdownView: View {
    let text: String

    private enum Block: Hashable {
        case heading(Int, String), paragraph(String), bullet(String), code(String), table([[String]]), quote(String), rule
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var lines = text.components(separatedBy: "\n")[...]
        var para: [String] = []
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        while let line = lines.popFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                flush()
                var code: [String] = []
                while let l = lines.popFirst(), !l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(l) }
                out.append(.code(code.joined(separator: "\n")))
            } else if let level = t.prefix(while: { $0 == "#" }).count as Int?, level > 0, level <= 6, t.dropFirst(level).hasPrefix(" ") {
                flush(); out.append(.heading(level, String(t.dropFirst(level + 1))))
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                flush(); out.append(.bullet(String(t.dropFirst(2))))
            } else if t.hasPrefix(">") {
                flush(); out.append(.quote(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if t == "---" || t == "***" {
                flush(); out.append(.rule)
            } else if t.hasPrefix("|") {
                flush()
                var rows = [t]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(next.trimmingCharacters(in: .whitespaces)); lines.removeFirst() }
                let cells = rows.filter { !$0.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "-: ")).isEmpty }
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
                out.append(.table(cells))
            } else if t.isEmpty {
                flush()
            } else {
                para.append(t)
            }
        }
        flush()
        return out
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private func block(_ b: Block) -> some View {
        switch b {
        case .heading(let l, let s):
            Text(inline(s)).font(Typo.ui(l == 1 ? 20 : (l == 2 ? 16 : 14), .semibold)).foregroundStyle(Theme.text).padding(.top, l == 1 ? 0 : 6)
        case .paragraph(let s):
            Text(inline(s)).font(Typo.ui(13)).foregroundStyle(Theme.body).lineSpacing(3)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Theme.text3)
                Text(inline(s)).font(Typo.ui(13)).foregroundStyle(Theme.body)
            }
        case .quote(let s):
            Text(inline(s)).font(Typo.ui(13)).foregroundStyle(Theme.text2).padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
        case .code(let s):
            Text(s).font(Typo.mono(12)).foregroundStyle(Theme.body).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    GridRow {
                        ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                            Text(inline(c)).font(Typo.ui(12.5, i == 0 ? .semibold : .regular)).foregroundStyle(i == 0 ? Theme.text : Theme.body)
                        }
                    }
                    if i == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        case .rule:
            Divider()
        }
    }
}

// MARK: - Editor helpers on WorkspaceStore

extension WorkspaceStore {
    /// Loads the working-tree diff for a changed file and converts it into gutter marks.
    func loadDiff(for path: String) async {
        guard let p = project, let changes = app.git[projectID]?.changes.filter({ $0.path == path }), !changes.isEmpty else {
            gutter[path] = []
            return
        }
        var marks: [GutterMark] = []
        for c in changes {
            guard let d = try? await app.svc(p).git.diff(p, change: c) else { continue }
            diffs[c.id] = d
            marks += Self.marks(from: d, status: c.status)
        }
        gutter[path] = marks
    }

    nonisolated static func marks(from d: FileDiff, status: GitStatus) -> [GutterMark] {
        if status == .U || status == .A, let last = d.lines.compactMap(\.new).max() {
            return [GutterMark(lines: 1...max(1, last), status: .A)]
        }
        var out: [GutterMark] = []
        var start: Int?, end = 0, sawDelete = false
        func close() {
            if let s = start { out.append(GutterMark(lines: s...max(s, end), status: sawDelete ? .M : .A)) }
            start = nil; sawDelete = false
        }
        for l in d.lines {
            switch l.kind {
            case .add:
                if start == nil { start = l.new }
                end = l.new ?? end
            case .del:
                sawDelete = true
            default:
                close()
            }
        }
        close()
        return out
    }

    /// Nearest enclosing function or type name above the cursor.
    func currentSymbol(in path: String) -> String? {
        guard case .text(let t)? = contents[path] else { return nil }
        let line = cursorPath == path ? cursor.0 : 1
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false).prefix(max(1, line))
        let re = try? NSRegularExpression(pattern: #"(?:function|func|def|class|struct|interface|enum|type)\s+([A-Za-z_][\w]*)|const\s+([A-Za-z_][\w]*)\s*=\s*(?:async\s*)?\("#)
        for l in lines.reversed() {
            let s = String(l)
            if let m = re?.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
                for g in 1...2 where m.range(at: g).location != NSNotFound { return (s as NSString).substring(with: m.range(at: g)) }
            }
        }
        return lines.count > 1 ? nil : nil
    }

    /// Block an agent is editing: the first changed hunk in the file.
    func claudeBlock(in path: String) -> ClosedRange<Int>? {
        gutter[path]?.last?.lines
    }
}
