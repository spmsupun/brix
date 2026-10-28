import SwiftUI

/// Containers and compose services, grouped by Local and by SSH host.
struct DockerView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var loading = false

    private struct Group: Identifiable {
        var id: String
        var title: String
        var tag: EnvTag?
        var items: [DockerTarget]
    }

    private var groups: [Group] {
        let all = store.allDocker.filter { query.isEmpty || FuzzyMatcher.score(query, $0.name + " " + $0.image) != nil }
        var out = [Group(id: "local", title: "Local", tag: .local, items: all.filter { $0.hostID == nil })]
        for h in store.library.hosts {
            let items = all.filter { $0.hostID == h.id }
            if !items.isEmpty { out.append(Group(id: h.id, title: h.name, tag: h.tag, items: items)) }
        }
        return out.filter { !$0.items.isEmpty }
    }

    @Environment(\.islandGap) private var gap
    /// The detail pane is open, so the list drops its wide columns.
    private var compact: Bool { store.dockerSelection != nil }

    var body: some View {
        HStack(spacing: gap) {
            list
            if let sel = store.dockerSelection {
                DockerDetailView(selection: sel).frame(width: 440)
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SegmentedControl(options: [("containers", "Containers"), ("stacks", compact ? "Stacks" : "Compose Stacks"), ("networks", "Networks"), ("volumes", "Volumes"), ("images", "Images")],
                                 selection: Bindable(store).dockerTab, height: 26, fontSize: 12)
                if !compact { SearchField(placeholder: "Filter", text: $query, height: 30).frame(minWidth: 140, maxWidth: 220) }
                if let e = store.dockerTab == "containers" ? store.dockerError : store.dockerInventoryError {
                    Label(e.components(separatedBy: "\n").first ?? e, systemImage: "exclamationmark.triangle").font(Typo.ui(11.5)).foregroundStyle(Theme.amber).lineLimit(1)
                        .help(e)
                }
                Spacer()
                SubtleButton(title: "Refresh", symbol: "arrow.clockwise", isLoading: loading) { refresh() }
                AccentButton(title: "Add Target", symbol: "plus") { store.sheet = .addDocker }
            }
            .padding(.leading, 16).padding(.trailing, 12).frame(height: 52).hairlineBottom()
            if store.dockerTab != "containers" {
                DockerInventoryList(tab: store.dockerTab, query: query)
            } else {
            HStack(spacing: 10) {
                Color.clear.frame(width: 7)
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                if !compact {
                    Text("Image").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Ports").frame(width: 90, alignment: .leading)
                }
                Text("Status").frame(width: 120, alignment: .leading)
                if !compact { Text("Projects").frame(width: 130, alignment: .leading) }
                Text("Actions").frame(width: 150, alignment: .trailing)
            }
            .font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3)
            .padding(.horizontal, 16).frame(height: 30).hairlineBottom()
            if groups.isEmpty {
                EmptyState(symbol: "shippingbox", message: query.isEmpty ? "No containers found. Start Docker locally, or connect a host that runs Docker." : "No containers match.",
                           actionTitle: query.isEmpty ? "Refresh" : "Clear filter") { if query.isEmpty { refresh() } else { query = "" } }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(groups) { g in
                            HStack(spacing: 8) {
                                Image(systemName: g.id == "local" ? "laptopcomputer" : "globe").font(.system(size: 11)).foregroundStyle(Theme.text2)
                                Text(g.title).font(Typo.ui(12, .semibold)).foregroundStyle(Theme.body)
                                if let t = g.tag { TagPill(tag: t, size: 8.5) }
                                Text("\(g.items.filter { $0.state == .running }.count) of \(g.items.count) running").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                            }
                            .padding(.horizontal, 10).frame(height: 32).padding(.top, 4)
                            ForEach(g.items) { c in row(c) }
                        }
                    }
                    .padding(6)
                }
            }
            }
        }
        .island()
        .task { refresh() }
    }

    private func refresh() {
        loading = true
        Task {
            await store.refreshDocker()
            await store.refreshDockerInventory()
            loading = false
        }
    }

    private func row(_ c: DockerTarget) -> some View {
        let busy = store.dockerBusy.contains(c.id)
        let projects = store.library.links.projects(for: c.id).compactMap(store.project)
        return HStack(spacing: 10) {
            StatusDot(color: c.state.color, size: 7, ring: c.state == .running)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(Typo.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                if !c.composeProject.isEmpty { Text("compose · \(c.composeProject)").font(Typo.ui(10.5)).foregroundStyle(Theme.text3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text(c.image).font(Typo.mono(11)).foregroundStyle(Theme.text2).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(c.ports.ifEmpty("–")).font(Typo.mono(11)).foregroundStyle(Theme.text2).lineLimit(1).frame(width: 90, alignment: .leading)
            }
            Text(c.uptimeText).font(Typo.ui(12)).foregroundStyle(c.state == .running ? Theme.green : Theme.text3).lineLimit(1).frame(width: 120, alignment: .leading)
            if !compact { HStack(spacing: -5) {
                ForEach(projects.prefix(4)) { p in ProjectMark(project: p, size: 20).background(RoundedRectangle(cornerRadius: 6).fill(Theme.island).padding(-2)) }
                if projects.isEmpty { Text("–").font(Typo.ui(11)).foregroundStyle(Theme.meta) }
            }
            .frame(width: 130, alignment: .leading) }
            HStack(spacing: 2) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    if c.state == .running {
                        IconButton(symbol: "stop.fill", label: "Stop \(c.name)", iconSize: 10) { store.dockerAction(.stop, c.id) }
                        IconButton(symbol: "arrow.triangle.2.circlepath", label: "Restart \(c.name)", iconSize: 11) { store.dockerAction(.restart, c.id) }
                    } else {
                        IconButton(symbol: "play.fill", label: "Start \(c.name)", iconSize: 10) { store.dockerAction(.start, c.id) }
                    }
                    IconButton(symbol: "text.alignleft", label: "Logs", iconSize: 11) { store.openDockerLogs(c.id, project: nil) }
                    IconButton(symbol: "terminal", label: "Shell", iconSize: 11) { store.openDockerShell(c.id, project: nil) }
                        .disabled(c.state != .running)
                    MenuButton(items: { linkMenu(c) }) {
                        Image(systemName: "link").font(.system(size: 11)).foregroundStyle(Theme.text3).frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Link to a project")
                }
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .rowBackground(selected: store.dockerSelection == .container(c.id), radius: 8)
        .onTapGesture { store.dockerSelection = .container(c.id) }
        .contextMenu {
            Button("Details") { store.dockerSelection = .container(c.id) }
            Button("Start") { store.dockerAction(.start, c.id) }.disabled(c.state == .running)
            Button("Stop") { store.dockerAction(.stop, c.id) }.disabled(c.state != .running)
            Button("Restart") { store.dockerAction(.restart, c.id) }
            Divider()
            Button("Logs") { store.openDockerLogs(c.id, project: nil) }
            Button("Shell") { store.openDockerShell(c.id, project: nil) }.disabled(c.state != .running)
            Divider()
            Menu("Attach to Project") {
                ForEach(store.sortedProjects) { p in
                    let on = store.library.links.isLinked(p.id, c.id)
                    Button { store.setLink(p.id, c.id, kind: .docker, linked: !on) } label: { Text(on ? "✓ \(p.name)" : p.name) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(c.name), \(c.uptimeText)")
    }

    private func linkMenu(_ c: DockerTarget) -> [MenuSpec] {
        [.header("Link to project")] + store.sortedProjects.map { p in
            let linked = store.library.links.isLinked(p.id, c.id)
            return MenuSpec(title: p.name, checked: linked) {
                store.setLink(p.id, c.id, kind: .docker, linked: !linked)
                store.toast(.success, linked ? "Unlinked \(c.name) from \(p.name)" : "Linked \(c.name) to \(p.name)")
            }
        }
    }
}
