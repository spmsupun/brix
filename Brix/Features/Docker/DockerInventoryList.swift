import SwiftUI

/// Compose stacks, networks, volumes and images, grouped by engine.
struct DockerInventoryList: View {
    @Environment(AppStore.self) private var store
    let tab: String
    let query: String
    @State private var page = 0
    @State private var open: Set<String> = []

    private struct Engine: Identifiable {
        var id: String
        var title: String
        var tag: EnvTag?
        var inv: DockerInventory
    }

    private var engines: [Engine] {
        store.dockerInventory.keys.sorted { a, b in a == "local" || (a == "sample" && b != "local") }.compactMap { k in
            guard let inv = store.dockerInventory[k] else { return nil }
            if k == "local" { return Engine(id: k, title: "Local", tag: .local, inv: inv) }
            if k == "sample" { return Engine(id: k, title: "Sample", tag: nil, inv: inv) }
            guard let h = store.host(k) else { return nil }
            return Engine(id: k, title: h.name, tag: h.tag, inv: inv)
        }
    }

    private func match(_ text: String) -> Bool { query.isEmpty || FuzzyMatcher.score(query, text) != nil }

    var body: some View {
        let groups = engines
        if groups.isEmpty {
            EmptyState(symbol: "shippingbox", message: store.dockerInventoryError ?? "Loading Docker…")
        } else {
            GeometryReader { geo in
                let cols = DockerColumns(width: geo.size.width)
                // One page across all engines, of whatever this tab lists.
                let all = groups.flatMap { e in keys(e).map { "\(e.id)|\($0)" } }
                let shown = Set(PageBar.slice(all, page: page))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(groups) { e in
                            let mine = keys(e).filter { shown.contains("\(e.id)|\($0)") }
                            if !mine.isEmpty || all.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: e.id == "local" || e.id == "sample" ? "laptopcomputer" : "globe").font(.system(size: 11)).foregroundStyle(Theme.text2)
                                    Text(e.title).font(Typo.ui(12, .semibold)).foregroundStyle(Theme.body)
                                    if let t = e.tag { TagPill(tag: t, size: 8.5) }
                                }
                                .padding(.horizontal, 10).frame(height: 32).padding(.top, 4)
                                rows(e, Set(mine), cols: cols)
                            }
                        }
                        PageBar(page: $page, total: all.count)
                    }
                    .padding(6)
                }
            }
            .onChange(of: query) { page = 0 }
            .onChange(of: tab) { page = 0 }
        }
    }

    /// Stacks, most recently active first (from their containers).
    private func stacks(_ e: Engine) -> [ComposeStack] {
        let now = Date()
        func last(_ s: ComposeStack) -> Date { containers(s).map { $0.lastActive(now: now) }.max() ?? .distantPast }
        let found: [ComposeStack] = e.inv.stacks.filter { match($0.name) }.map { store.stack($0.id) ?? $0 }
        let dated: [(stack: ComposeStack, last: Date)] = found.map { ($0, last($0)) }
        let sorted = dated.sorted { a, b in
            a.last != b.last ? a.last > b.last : a.stack.name.localizedStandardCompare(b.stack.name) == .orderedAscending
        }
        return sorted.map(\.stack)
    }

    private func containers(_ s: ComposeStack) -> [DockerTarget] {
        store.allDocker.filter { $0.composeProject == s.name && $0.hostID == s.hostID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The ids this tab lists for an engine, in order (for paging).
    private func keys(_ e: Engine) -> [String] {
        switch tab {
        case "stacks": stacks(e).map(\.id)
        case "networks": e.inv.networks.filter { match($0.name + " " + $0.composeProject) }.map(\.id)
        case "volumes": e.inv.volumes.filter { match($0.name + " " + $0.composeProject) }.map(\.id)
        default: e.inv.images.filter { match($0.repository + ":" + $0.tag) }.map(\.id)
        }
    }

    @ViewBuilder private func rows(_ e: Engine, _ shown: Set<String>, cols: DockerColumns) -> some View {
        switch tab {
        case "stacks":
            let items = stacks(e).filter { shown.contains($0.id) }
            if items.isEmpty { empty("No compose stacks") }
            ForEach(items) { s in
                let isOpen = open.contains(s.id) || !query.isEmpty
                stackRow(s, open: isOpen, cols: cols)
                if isOpen {
                    let cs = containers(s)
                    if cs.isEmpty { empty("No containers").padding(.leading, 28) }
                    ForEach(cs) { c in DockerContainerRow(c: c, cols: cols, indent: 18) }
                }
            }
        case "networks":
            let items = e.inv.networks.filter { shown.contains($0.id) }
            if items.isEmpty { empty("No networks") }
            ForEach(items) { n in
                simpleRow(icon: "point.3.connected.trianglepath.dotted", n.name, n.driver, n.scope, n.composeProject.isEmpty ? "–" : "compose · \(n.composeProject)", select: .network(n), cols: cols)
            }
        case "volumes":
            let items = e.inv.volumes.filter { shown.contains($0.id) }
            if items.isEmpty { empty("No volumes") }
            ForEach(items) { v in
                simpleRow(icon: "externaldrive", v.name, v.driver, "", v.composeProject.isEmpty ? "–" : "compose · \(v.composeProject)", select: .volume(v), cols: cols)
            }
        default:
            let items = e.inv.images.filter { shown.contains($0.id) }
            if items.isEmpty { empty("No images") }
            ForEach(items) { i in simpleRow(icon: "square.stack.3d.up", "\(i.repository):\(i.tag)", i.size, i.created, "", select: .image(i), cols: cols) }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Typo.ui(12)).foregroundStyle(Theme.text3).padding(.horizontal, 12).frame(height: 30)
    }

    private func simpleRow(icon: String, _ name: String, _ a: String, _ b: String, _ c: String, select: DockerSelection, cols: DockerColumns) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.text3).frame(width: 16)
            Text(name).font(Typo.mono(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                .help(name)
            if cols.status { Text(a).font(Typo.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1).frame(width: 90, alignment: .leading) }
            if cols.ports { Text(b).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).frame(width: 110, alignment: .leading) }
            if cols.image { Text(c).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).frame(width: 180, alignment: .leading) }
        }
        .padding(.horizontal, 10).rowHeight(34)
        .rowBackground(selected: store.dockerSelection == select, radius: 8)
        .clickable().onTapGesture { store.dockerSelection = select }
        .contextMenu {
            Button("Details") { store.dockerSelection = select }
            Button("Copy Name") { store.copyToPasteboard(name, label: "name") }
        }
    }

    private func stackRow(_ s: ComposeStack, open isOpen: Bool, cols: DockerColumns) -> some View {
        let busy = store.dockerBusy.contains(s.id)
        let projects = store.library.links.projects(for: s.id).compactMap(store.project)
        let containers = containers(s)
        return HStack(spacing: 10) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3)
                .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 8)
            StatusDot(color: s.isRunning ? Theme.green : Theme.disabled, size: 7, ring: s.isRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(Typo.ui(13, .medium)).foregroundStyle(Theme.text)
                Text(s.configFiles.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ").ifEmpty("No compose file reported"))
                    .font(Typo.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if cols.status {
                Text("\(containers.filter { $0.state == .running }.count) of \(containers.count) running").font(Typo.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1).frame(width: 110, alignment: .leading)
            }
            if cols.ports {
                Text(s.status).font(Typo.ui(11.5)).foregroundStyle(s.isRunning ? Theme.green : Theme.text3).lineLimit(1).truncationMode(.tail).frame(width: 90, alignment: .leading)
            }
            if cols.projects {
                Text(projects.isEmpty ? "–" : projects.map(\.name).joined(separator: ", ")).font(Typo.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1).frame(width: 130, alignment: .leading)
            }
            HStack(spacing: 2) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    if s.isRunning {
                        IconButton(symbol: "arrow.triangle.2.circlepath", label: "Restart \(s.name)", iconSize: 11) { store.composeAction(.restart, s) }
                        IconButton(symbol: "stop.fill", label: "Stop \(s.name)", iconSize: 10) { store.composeAction(.stop, s) }
                    } else {
                        IconButton(symbol: "play.fill", label: "Up \(s.name)", iconSize: 10) { store.composeAction(.up, s) }
                            .disabled(s.configFiles.isEmpty)
                    }
                    IconButton(symbol: "text.alignleft", label: "Logs", iconSize: 11) { store.openComposeLogs(s) }
                    MenuButton(items: { store.attachToProjectMenu(resource: s.id, kind: .stack, stack: s) }) {
                        Image(systemName: "link").font(.system(size: 11)).foregroundStyle(Theme.text3).frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Attach \(s.name) to a project")
                }
            }
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 10).rowHeight(46)
        .rowBackground(selected: store.dockerSelection == .stack(s.id), radius: 8)
        .clickable().onTapGesture {
            // Opens the stack's containers and shows its details.
            if open.contains(s.id) { open.remove(s.id) } else { open.insert(s.id) }
            store.dockerSelection = .stack(s.id)
        }
        .contextMenu {
            Button("Details") { store.dockerSelection = .stack(s.id) }
            Button("Up (detached)") { store.composeAction(.up, s) }.disabled(s.configFiles.isEmpty)
            Button("Restart") { store.composeAction(.restart, s) }
            Button("Stop") { store.composeAction(.stop, s) }
            Button("Pull Images") { store.composeAction(.pull, s) }
            Button("Down…", role: .destructive) { store.composeAction(.down, s) }
            Divider()
            Button("Logs") { store.openComposeLogs(s) }
            if let f = s.configFiles.first, s.hostID == nil {
                Button("Reveal Compose File") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (f as NSString).expandingTildeInPath)]) }
            }
            Divider()
            Menu("Attach to Project") {
                ForEach(store.sortedProjects) { p in
                    let on = store.library.links.isLinked(p.id, s.id)
                    Button { store.setStackLink(p.id, s, linked: !on) } label: { Text(on ? "✓ \(p.name)" : p.name) }
                }
            }
        }
    }
}
