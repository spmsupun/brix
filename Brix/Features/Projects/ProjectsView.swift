import SwiftUI

struct ProjectsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    @State private var filter = ""
    @State private var scope = 0
    @FocusState private var listFocused: Bool

    private var projects: [Project] {
        store.sortedProjects.filter { p in
            (filter.isEmpty || FuzzyMatcher.score(filter, p.name + " " + p.framework + " " + p.path) != nil)
                && (scope != 1 || p.isPinned)
                && (scope != 2 || store.changeCount(p.id) > 0)
        }
    }

    private var selected: ProjectID? { store.selectedProjectInList ?? store.sortedProjects.first?.id }

    var body: some View {
        HStack(spacing: gap) {
            VStack(spacing: 0) {
                header
                GeometryReader { geo in
                    let w = Cols(total: geo.size.width - 32)
                    VStack(spacing: 0) {
                        columns(w)
                        list(w)
                    }
                }
            }
            .island()
            if let id = selected, store.project(id) != nil {
                ProjectInspector(projectID: id)
                    .frame(width: 300)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .island()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SearchField(placeholder: "Filter projects", text: $filter, height: 30).frame(width: 260)
            SegmentedControl(options: [(0, "All"), (1, "Pinned"), (2, "Has changes")], selection: $scope, fill: Theme.input, fontSize: 12)
            Spacer()
            AccentButton(title: "Add Folder", symbol: "plus", shortcut: "⌘O") { store.sheet = .addProject }
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(height: 52)
        .hairlineBottom()
    }

    /// Fixed columns plus three flexible ones split 1.4 : 1.5 : 1.2, as in the design.
    struct Cols {
        var name: CGFloat, location: CGFloat, branch: CGFloat
        init(total: CGFloat) {
            let flex = max(240, total - 36 - 110 - 120 - 80 - 8 * 6)
            name = flex * 1.4 / 4.1; location = flex * 1.5 / 4.1; branch = flex * 1.2 / 4.1
        }
    }

    private func columns(_ w: Cols) -> some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 36)
            Text("Name").frame(width: w.name, alignment: .leading)
            Text("Location").frame(width: w.location, alignment: .leading)
            Text("Branch").frame(width: w.branch, alignment: .leading)
            Text("Working tree").frame(width: 110, alignment: .leading)
            Text("Resources").frame(width: 120, alignment: .leading)
            Text("Opened").frame(width: 80, alignment: .trailing)
        }
        .font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .hairlineBottom()
    }

    @ViewBuilder private func list(_ w: Cols) -> some View {
        if store.library.projects.isEmpty {
            EmptyState(symbol: "folder.badge.plus", message: "No projects yet. Add a folder to get started.", actionTitle: "Add Folder") { store.sheet = .addProject }
        } else if projects.isEmpty {
            EmptyState(symbol: "magnifyingglass", message: "No projects match.", actionTitle: "Clear filter") { filter = ""; scope = 0 }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(projects) { p in row(p, w).id(p.id) }
                    }
                    .padding(6)
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { move(1, proxy); return .handled }
                .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
                .onKeyPress(.return) { if let s = selected { store.openProject(s) }; return .handled }
            }
        }
    }

    private func move(_ d: Int, _ proxy: ScrollViewProxy) {
        guard !projects.isEmpty else { return }
        let i = projects.firstIndex { $0.id == selected } ?? 0
        let n = projects[max(0, min(projects.count - 1, i + d))]
        store.selectedProjectInList = n.id
        proxy.scrollTo(n.id)
    }

    private func row(_ p: Project, _ w: Cols) -> some View {
        let g = store.git[p.id]
        let n = store.changeCount(p.id)
        let on = p.id == selected
        let state = g?.isRepo == false ? "No git" : (n == 0 ? "Clean" : "\(n) changed") + ((g?.ahead ?? 0) > 0 ? " ↑\(g!.ahead)" : "")
        let res = [("SSH", store.library.links.count(of: .host, for: p.id)), ("DB", store.library.links.count(of: .database, for: p.id)), ("DK", store.library.links.count(of: .docker, for: p.id))].filter { $0.1 > 0 }
        return HStack(spacing: 8) {
            ProjectMark(project: p, size: 30).frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.name).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                    if p.isPinned { Text("PINNED").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.text3) }
                }
                Text(p.framework).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            .frame(width: w.name, alignment: .leading)
            Text(p.path).font(Typo.mono(11.5)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                .frame(width: w.location, alignment: .leading)
            Text(g?.isRepo == false ? "–" : "⎇ \(g?.branch ?? "…")").font(Typo.mono(11.5)).foregroundStyle(Theme.body).lineLimit(1)
                .frame(width: w.branch, alignment: .leading)
            Text(state).font(Typo.ui(12)).foregroundStyle(n == 0 ? Theme.green : Theme.amber).frame(width: 110, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(res, id: \.0) { r in
                    Text("\(r.1) \(r.0)").font(Typo.ui(10.5)).foregroundStyle(Theme.text2)
                        .fixedSize()
                        .padding(.horizontal, 6).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white(0.05)))
                }
            }
            .frame(width: 120, alignment: .leading)
            Text(RelativeTime.long(p.lastOpened)).font(Typo.ui(12)).foregroundStyle(Theme.text3).frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .rowBackground(selected: on, radius: 8)
        .onTapGesture(count: 2) { store.openProject(p.id) }
        .simultaneousGesture(TapGesture().onEnded { store.selectedProjectInList = p.id; store.inspector = .project(p.id); listFocused = true })
        .contextMenu { ProjectContextMenu(project: p) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.name), \(p.framework), \(state)")
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Open") { store.openProject(p.id) }
    }
}
