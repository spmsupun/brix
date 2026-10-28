import SwiftUI

/// Compose stacks, networks, volumes and images, grouped by engine.
struct DockerInventoryList: View {
    @Environment(AppStore.self) private var store
    let tab: String
    let query: String

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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(groups) { e in
                        HStack(spacing: 8) {
                            Image(systemName: e.id == "local" || e.id == "sample" ? "laptopcomputer" : "globe").font(.system(size: 11)).foregroundStyle(Theme.text2)
                            Text(e.title).font(Typo.ui(12, .semibold)).foregroundStyle(Theme.body)
                            if let t = e.tag { TagPill(tag: t, size: 8.5) }
                        }
                        .padding(.horizontal, 10).frame(height: 32).padding(.top, 4)
                        rows(e)
                    }
                }
                .padding(6)
            }
        }
    }

    @ViewBuilder private func rows(_ e: Engine) -> some View {
        switch tab {
        case "stacks":
            let items = e.inv.stacks.filter { match($0.name) }
            if items.isEmpty { empty("No compose stacks") }
            ForEach(items) { stackRow(store.stack($0.id) ?? $0) }
        case "networks":
            let items = e.inv.networks.filter { match($0.name + " " + $0.composeProject) }
            if items.isEmpty { empty("No networks") }
            ForEach(items) { n in
                simpleRow(icon: "point.3.connected.trianglepath.dotted", n.name, n.driver, n.scope, n.composeProject.isEmpty ? "–" : "compose · \(n.composeProject)", select: .network(n))
            }
        case "volumes":
            let items = e.inv.volumes.filter { match($0.name + " " + $0.composeProject) }
            if items.isEmpty { empty("No volumes") }
            ForEach(items) { v in
                simpleRow(icon: "externaldrive", v.name, v.driver, "", v.composeProject.isEmpty ? "–" : "compose · \(v.composeProject)", select: .volume(v))
            }
        default:
            let items = e.inv.images.filter { match($0.repository + ":" + $0.tag) }
            if items.isEmpty { empty("No images") }
            ForEach(items) { i in simpleRow(icon: "square.stack.3d.up", "\(i.repository):\(i.tag)", i.size, i.created, "", select: .image(i)) }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Typo.ui(12)).foregroundStyle(Theme.text3).padding(.horizontal, 12).frame(height: 30)
    }

    private func simpleRow(icon: String, _ name: String, _ a: String, _ b: String, _ c: String, select: DockerSelection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.text3).frame(width: 16)
            Text(name).font(Typo.mono(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Text(a).font(Typo.ui(11.5)).foregroundStyle(Theme.text2).frame(width: 90, alignment: .leading)
            Text(b).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).frame(width: 110, alignment: .leading)
            Text(c).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).frame(width: 180, alignment: .leading)
        }
        .padding(.horizontal, 10).rowHeight(34)
        .rowBackground(selected: store.dockerSelection == select, radius: 8)
        .onTapGesture { store.dockerSelection = select }
        .contextMenu {
            Button("Details") { store.dockerSelection = select }
            Button("Copy Name") { store.copyToPasteboard(name, label: "name") }
        }
    }

    private func stackRow(_ s: ComposeStack) -> some View {
        let busy = store.dockerBusy.contains(s.id)
        let projects = store.library.links.projects(for: s.id).compactMap(store.project)
        let containers = store.allDocker.filter { $0.composeProject == s.name && $0.hostID == s.hostID }
        return HStack(spacing: 10) {
            StatusDot(color: s.isRunning ? Theme.green : Theme.disabled, size: 7, ring: s.isRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(Typo.ui(13, .medium)).foregroundStyle(Theme.text)
                Text(s.configFiles.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ").ifEmpty("No compose file reported"))
                    .font(Typo.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(containers.filter { $0.state == .running }.count) of \(containers.count) running").font(Typo.ui(11.5)).foregroundStyle(Theme.text2).frame(width: 110, alignment: .leading)
            Text(s.status).font(Typo.ui(11.5)).foregroundStyle(s.isRunning ? Theme.green : Theme.text3).lineLimit(1).truncationMode(.tail).frame(width: 90, alignment: .leading)
            Text(projects.isEmpty ? "–" : projects.map(\.name).joined(separator: ", ")).font(Typo.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1).frame(width: 130, alignment: .leading)
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
        .onTapGesture { store.dockerSelection = .stack(s.id) }
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
