import SwiftUI

/// Containers grouped by Local and by SSH host, and inside those by compose
/// project: each project folds open like an accordion, standalone containers
/// sit beside them, most recently active first.
struct DockerView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var loading = false
    @State private var open: Set<String> = []
    @State private var page = 0
    @AppStorage("docker.detailWidth") private var detailWidth: Double = 440

    private struct Engine: Identifiable {
        var id: String
        var title: String
        var tag: EnvTag?
        var units: [DockerUnit]
        var running: Int
        var total: Int
    }

    private var engines: [Engine] {
        let all = store.allDocker.filter { query.isEmpty || FuzzyMatcher.score(query, $0.name + " " + $0.image + " " + $0.composeProject) != nil }
        var out = [Engine(id: "local", title: "Local", tag: .local, units: DockerUnit.group(all.filter { $0.hostID == nil }),
                          running: all.filter { $0.hostID == nil && $0.state == .running }.count, total: all.filter { $0.hostID == nil }.count)]
        for h in store.library.hosts {
            let items = all.filter { $0.hostID == h.id }
            if !items.isEmpty {
                out.append(Engine(id: h.id, title: h.name, tag: h.tag, units: DockerUnit.group(items),
                                  running: items.filter { $0.state == .running }.count, total: items.count))
            }
        }
        return out.filter { !$0.units.isEmpty }
    }

    @Environment(\.islandGap) private var gap

    var body: some View {
        HStack(spacing: 0) {
            list.frame(minWidth: 360)
            if let sel = store.dockerSelection {
                ResizeHandle(axis: .horizontal, thickness: gap) { detailWidth = min(max(detailWidth - $0, 320), 760) }
                DockerDetailView(selection: sel).frame(width: detailWidth)
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            DockerToolbar(query: $query, loading: loading, refresh: refresh)
            if store.dockerTab != "containers" {
                DockerInventoryList(tab: store.dockerTab, query: query)
            } else {
                GeometryReader { geo in
                    let cols = DockerColumns(width: geo.size.width)
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Color.clear.frame(width: 18)
                            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                            if cols.image { Text("Image").frame(maxWidth: .infinity, alignment: .leading) }
                            if cols.ports { Text("Ports").frame(width: 90, alignment: .leading) }
                            if cols.status { Text("Status").frame(width: 120, alignment: .leading) }
                            if cols.projects { Text("Projects").frame(width: 110, alignment: .leading) }
                            Text("Actions").frame(width: cols.actionsWidth, alignment: .trailing)
                        }
                        .font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3)
                        .padding(.horizontal, 16).frame(height: 30).hairlineBottom()
                        content(cols)
                    }
                }
            }
        }
        .island()
        .task { refresh() }
        .onChange(of: query) { page = 0 }
    }

    @ViewBuilder private func content(_ cols: DockerColumns) -> some View {
        let groups = engines
        if groups.isEmpty {
            EmptyState(symbol: "shippingbox", message: query.isEmpty ? "No containers found. Start Docker locally, or connect a host that runs Docker." : "No containers match.",
                       actionTitle: query.isEmpty ? "Refresh" : "Clear filter") { if query.isEmpty { refresh() } else { query = "" } }
        } else {
            let units = groups.reduce(0) { $0 + $1.units.count }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    // One page across all engines, so a long Local list doesn't bury the hosts.
                    let shown = Set(PageBar.slice(groups.flatMap { e in e.units.map { "\(e.id)|\($0.id)" } }, page: page))
                    ForEach(groups) { e in
                        let units = e.units.filter { shown.contains("\(e.id)|\($0.id)") }
                        if !units.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: e.id == "local" ? "laptopcomputer" : "globe").font(.system(size: 11)).foregroundStyle(Theme.text2)
                                Text(e.title).font(Typo.ui(12, .semibold)).foregroundStyle(Theme.body)
                                if let t = e.tag { TagPill(tag: t, size: 8.5) }
                                Text("\(e.running) of \(e.total) running").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                            }
                            .padding(.horizontal, 10).frame(height: 32).padding(.top, 4)
                            ForEach(units) { u in unit(u, cols: cols) }
                        }
                    }
                    PageBar(page: $page, total: units)
                }
                .padding(6)
            }
        }
    }

    @ViewBuilder private func unit(_ u: DockerUnit, cols: DockerColumns) -> some View {
        if let name = u.compose {
            let isOpen = open.contains(u.id) || !query.isEmpty
            DockerStackHeader(name: name, containers: u.containers, open: isOpen, cols: cols) { toggle(u.id) }
            if isOpen {
                ForEach(u.containers) { c in DockerContainerRow(c: c, cols: cols, indent: 18) }
            }
        } else if let c = u.containers.first {
            DockerContainerRow(c: c, cols: cols, indent: 0)
        }
    }

    private func toggle(_ id: String) {
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
    }

    private func refresh() {
        loading = true
        Task {
            await store.refreshDocker()
            await store.refreshDockerInventory()
            loading = false
        }
    }
}

/// A compose project with its containers, or one standalone container.
struct DockerUnit: Identifiable {
    var id: String
    var compose: String?
    var containers: [DockerTarget]
    var lastActive: Date

    /// Compose projects and standalone containers, most recently active first.
    static func group(_ items: [DockerTarget], now: Date = Date()) -> [DockerUnit] {
        let byProject = Dictionary(grouping: items.filter { !$0.composeProject.isEmpty }, by: \.composeProject)
        let stacks = byProject.map { name, cs in
            DockerUnit(id: "compose:\(name)", compose: name,
                       containers: cs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                       lastActive: cs.map { $0.lastActive(now: now) }.max() ?? .distantPast)
        }
        let single = items.filter { $0.composeProject.isEmpty }.map {
            DockerUnit(id: $0.id, compose: nil, containers: [$0], lastActive: $0.lastActive(now: now))
        }
        return (stacks + single).sorted {
            $0.lastActive != $1.lastActive ? $0.lastActive > $1.lastActive : $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }
}

/// Which columns fit the list's width; the name column always stays.
struct DockerColumns {
    var image = false, ports = false, status = false, projects = false
    var actionsWidth: CGFloat = 130

    init(width: CGFloat) {
        status = width >= 470
        ports = width >= 700
        image = width >= 820
        projects = width >= 960
        actionsWidth = width >= 470 ? 130 : 96
    }
}

/// Tabs, filter and actions; drops to two rows when the column is narrow.
private struct DockerToolbar: View {
    @Environment(AppStore.self) private var store
    @Binding var query: String
    let loading: Bool
    let refresh: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                tabs
                SearchField(placeholder: "Filter", text: $query, height: 30).frame(minWidth: 140, maxWidth: 220)
                error
                Spacer(minLength: 8)
                buttons
            }
            .padding(.leading, 16).padding(.trailing, 12).frame(height: 52)
            VStack(alignment: .leading, spacing: 8) {
                tabs
                HStack(spacing: 8) {
                    SearchField(placeholder: "Filter", text: $query, height: 28).frame(maxWidth: .infinity)
                    buttons
                }
                error
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .hairlineBottom()
    }

    private var tabs: some View {
        SegmentedControl(options: [("containers", "Containers"), ("stacks", "Stacks"), ("networks", "Networks"), ("volumes", "Volumes"), ("images", "Images")],
                         selection: Bindable(store).dockerTab, height: 26, fontSize: 12)
            .fixedSize()
    }

    @ViewBuilder private var error: some View {
        if let e = store.dockerTab == "containers" ? store.dockerError : store.dockerInventoryError {
            Label(e.components(separatedBy: "\n").first ?? e, systemImage: "exclamationmark.triangle").font(Typo.ui(11.5)).foregroundStyle(Theme.amber).lineLimit(1)
                .help(e)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            SubtleButton(title: "Refresh", symbol: "arrow.clockwise", isLoading: loading) { refresh() }
            AccentButton(title: "Add", symbol: "plus") { store.sheet = .addDocker }
        }
        .fixedSize()
    }
}

/// The folding row for one compose project: name, how many run, and stack actions.
struct DockerStackHeader: View {
    @Environment(AppStore.self) private var store
    let name: String
    let containers: [DockerTarget]
    let open: Bool
    let cols: DockerColumns
    let toggle: () -> Void

    var body: some View {
        let running = containers.filter { $0.state == .running }.count
        let stack = containers.first.flatMap { store.stack(ComposeStack.makeID(name, hostID: $0.hostID)) }
        let last = containers.map { $0.lastActive() }.max() ?? .distantPast
        HStack(spacing: 10) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3)
                .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 8)
            StatusDot(color: running > 0 ? Theme.green : Theme.disabled, size: 7, ring: running > 0)
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                Text(name).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Text("\(running) of \(containers.count) running").font(Typo.ui(11)).foregroundStyle(running > 0 ? Theme.green : Theme.text3).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if cols.status {
                Text(running > 0 ? "Active now" : last == .distantPast ? "–" : "Active " + Self.relative(last))
                    .font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).frame(width: 120, alignment: .leading)
            }
            HStack(spacing: 2) {
                if let stack {
                    if store.dockerBusy.contains(stack.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        if running > 0 {
                            IconButton(symbol: "arrow.triangle.2.circlepath", label: "Restart \(name)", iconSize: 11) { store.composeAction(.restart, stack) }
                            IconButton(symbol: "stop.fill", label: "Stop \(name)", iconSize: 10) { store.composeAction(.stop, stack) }
                        } else {
                            IconButton(symbol: "play.fill", label: "Up \(name)", iconSize: 10) { store.composeAction(.up, stack) }.disabled(stack.configFiles.isEmpty)
                        }
                        IconButton(symbol: "text.alignleft", label: "Logs", iconSize: 11) { store.openComposeLogs(stack) }
                        IconButton(symbol: "info.circle", label: "Stack details", iconSize: 11) { store.dockerSelection = .stack(stack.id) }
                    }
                }
            }
            .frame(width: cols.actionsWidth, alignment: .trailing)
        }
        .padding(.horizontal, 10).frame(height: 40)
        .rowBackground(selected: stack.map { store.dockerSelection == .stack($0.id) } ?? false, radius: 8)
        .clickable().onTapGesture(perform: toggle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(running) of \(containers.count) running, \(open ? "expanded" : "collapsed")")
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

/// One container: status, image and ports when there's room, and its actions.
struct DockerContainerRow: View {
    @Environment(AppStore.self) private var store
    let c: DockerTarget
    let cols: DockerColumns
    var indent: CGFloat = 0

    var body: some View {
        let busy = store.dockerBusy.contains(c.id)
        let projects = store.library.links.projects(for: c.id).compactMap(store.project)
        HStack(spacing: 10) {
            Color.clear.frame(width: 8)
            StatusDot(color: c.state.color, size: 7, ring: c.state == .running)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.composeService.isEmpty ? c.name : c.composeService).font(Typo.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                // Status moves under the name when its column doesn't fit.
                Text(cols.status ? c.name : c.uptimeText).font(Typo.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if cols.image { Text(c.image).font(Typo.mono(11)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading) }
            if cols.ports { Text(c.ports.ifEmpty("–")).font(Typo.mono(11)).foregroundStyle(Theme.text2).lineLimit(1).frame(width: 90, alignment: .leading) }
            if cols.status {
                Text(c.uptimeText).font(Typo.ui(12)).foregroundStyle(c.state == .running ? Theme.green : Theme.text3).lineLimit(1).truncationMode(.tail)
                    .frame(width: 120, alignment: .leading).help(c.uptimeText)
            }
            if cols.projects {
                HStack(spacing: -5) {
                    ForEach(projects.prefix(4)) { p in ProjectMark(project: p, size: 20).background(RoundedRectangle(cornerRadius: 6).fill(Theme.island).padding(-2)) }
                    if projects.isEmpty { Text("–").font(Typo.ui(11)).foregroundStyle(Theme.meta) }
                }
                .frame(width: 110, alignment: .leading)
            }
            HStack(spacing: 2) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    if c.state == .running {
                        IconButton(symbol: "stop.fill", label: "Stop \(c.name)", iconSize: 10) { store.dockerAction(.stop, c.id) }
                        if cols.status { IconButton(symbol: "arrow.triangle.2.circlepath", label: "Restart \(c.name)", iconSize: 11) { store.dockerAction(.restart, c.id) } }
                    } else {
                        IconButton(symbol: "play.fill", label: "Start \(c.name)", iconSize: 10) { store.dockerAction(.start, c.id) }
                    }
                    IconButton(symbol: "text.alignleft", label: "Logs", iconSize: 11) { store.openDockerLogs(c.id, project: nil) }
                    IconButton(symbol: "terminal", label: "Shell", iconSize: 11) { store.openDockerShell(c.id, project: nil) }
                        .disabled(c.state != .running)
                    if cols.status {
                        MenuButton(items: { linkMenu }) {
                            Image(systemName: "link").font(.system(size: 11)).foregroundStyle(Theme.text3).frame(width: 24, height: 24).contentShape(Rectangle())
                        }
                        .accessibilityLabel("Link to a project")
                    }
                }
            }
            .frame(width: cols.actionsWidth, alignment: .trailing)
        }
        .padding(.leading, 10 + indent).padding(.trailing, 10)
        .frame(height: 44)
        .rowBackground(selected: store.dockerSelection == .container(c.id), radius: 8)
        .clickable().onTapGesture { store.dockerSelection = .container(c.id) }
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

    private var linkMenu: [MenuSpec] {
        [.header("Link to project")] + store.sortedProjects.map { p in
            let linked = store.library.links.isLinked(p.id, c.id)
            return MenuSpec(title: p.name, checked: linked) {
                store.setLink(p.id, c.id, kind: .docker, linked: !linked)
                store.toast(.success, linked ? "Unlinked \(c.name) from \(p.name)" : "Linked \(c.name) to \(p.name)")
            }
        }
    }
}
