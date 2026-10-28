import SwiftUI

struct RecentFilesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    @State private var filter = ""
    @State private var project: ProjectID?
    @State private var selected: String?

    private var files: [RecentFile] {
        var seen = Set<String>()
        return store.library.recentFiles
            .filter { store.project($0.project) != nil && seen.insert($0.id).inserted }
            .filter { project == nil || $0.project == project }
            .filter { filter.isEmpty || FuzzyMatcher.score(filter, $0.path) != nil }
            .sorted { $0.openedAt > $1.openedAt }
    }

    var body: some View {
        HStack(spacing: gap) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    SearchField(placeholder: "Filter files", text: $filter, height: 30).frame(width: 260)
                    MenuButton(items: {
                        [MenuSpec(title: "All projects", checked: project == nil) { project = nil }, .separator]
                        + store.sortedProjects.map { p in MenuSpec(title: p.name, checked: project == p.id) { project = p.id } }
                    }) {
                        HStack(spacing: 6) {
                            if let p = project.flatMap(store.project) { ProjectMark(project: p, size: 16) }
                            Text(project.flatMap(store.project)?.name ?? "All projects").font(Typo.ui(12)).foregroundStyle(Theme.text)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3)
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Project filter")
                    Spacer()
                    if !store.library.recentFiles.isEmpty {
                        SubtleButton(title: "Clear History") {
                            store.confirm("Clear recent files?", "Files are not touched, only the list.", confirm: "Clear") { store.library.recentFiles = [] }
                        }
                    }
                }
                .padding(.leading, 16).padding(.trailing, 12).frame(height: 52).hairlineBottom()
                if files.isEmpty {
                    EmptyState(symbol: "clock", message: store.library.recentFiles.isEmpty ? "Files you open in any project show up here." : "No files match.",
                               actionTitle: store.library.recentFiles.isEmpty ? "All Projects" : "Clear filters") {
                        if store.library.recentFiles.isEmpty { store.route = .projects } else { filter = ""; project = nil }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(files) { f in row(f) }
                        }
                        .padding(6)
                    }
                }
            }
            .island()
            if let sel = selected, let f = files.first(where: { $0.id == sel }) {
                InspectorDetails(selection: .file(f.project, f.path)).frame(width: 300).island()
            }
        }
    }

    private func row(_ f: RecentFile) -> some View {
        let p = store.project(f.project)
        let name = (f.path as NSString).lastPathComponent
        let on = selected == f.id
        return HStack(spacing: 12) {
            Image(systemName: FileKinds.isImage(name) ? "photo" : "doc.text").font(.system(size: 13)).foregroundStyle(FileKinds.iconColor(for: name))
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7).fill(Color.white(0.04)))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Typo.ui(13, .medium)).foregroundStyle(Theme.text)
                Text((f.path as NSString).deletingLastPathComponent.ifEmpty("/")).font(Typo.mono(11)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer()
            if let p {
                HStack(spacing: 6) {
                    ProjectMark(project: p, size: 18)
                    Text(p.name).font(Typo.ui(12)).foregroundStyle(Theme.text2)
                }
                .frame(width: 170, alignment: .leading)
            }
            Text(RelativeTime.long(f.openedAt)).font(Typo.ui(12)).foregroundStyle(Theme.text3).frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 10).frame(height: 48)
        .rowBackground(selected: on, radius: 8)
        .onTapGesture(count: 2) { open(f) }
        .simultaneousGesture(TapGesture().onEnded { selected = f.id })
        .contextMenu {
            Button("Open") { open(f) }
            Button("Copy Relative Path") { store.copyToPasteboard(f.path, label: "relative path") }
            Button("Remove from Recents") { store.library.recentFiles.removeAll { $0.id == f.id } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) in \(p?.name ?? "")")
        .accessibilityAction(named: "Open") { open(f) }
    }

    private func open(_ f: RecentFile) {
        store.openProject(f.project)
        store.workspace(for: f.project).open(f.path)
    }
}
