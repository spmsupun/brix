import SwiftUI

/// The 52pt window toolbar from the Toolbar artboard.
struct BrixToolbar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            // Space for the traffic lights (positioned by WindowChrome).
            Color.clear.frame(width: 62, height: 1)
            IconButton(symbol: "sidebar.left", label: "Toggle sidebar", shortcut: "⌃⌘S", size: 28, iconSize: 14, color: Theme.text2) {
                store.settings.sidebarHidden.toggle()
            }
            titleArea
            Spacer(minLength: 20)
            searchPill
            Spacer(minLength: 20)
            if let ws = store.currentWorkspace, case .workspace = store.route {
                presetControl(ws)
            }
            dockToggles
            NoticesButton()
            addMenu
        }
        .padding(.leading, 0)
        .padding(.trailing, 12)
        .frame(height: Metrics.toolbar)
        .background(WindowDragArea())
    }

    @ViewBuilder private var titleArea: some View {
        if let p = store.currentProject {
            projectSwitcher(p)
        } else {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 8, height: 8).rotationEffect(.degrees(45))
                Text(store.route.title).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
            }
            .padding(.leading, 4)
        }
    }

    private func projectSwitcher(_ p: Project) -> some View {
        MenuButton(items: { projectMenu(p) }) {
            HStack(spacing: 8) {
                ProjectMark(project: p, size: 20)
                Text(p.name).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                if let branch = store.git[p.id]?.branch, !branch.isEmpty {
                    Text("/").foregroundStyle(Theme.offline)
                    Text("⎇ \(branch)").font(Typo.mono(11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.text3)
            }
            .padding(.leading, 6).padding(.trailing, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlStroke))
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Switch project, current \(p.name)")
        .tip("Switch project", "⇧⌘[ ⇧⌘]")
    }

    private func projectMenu(_ current: Project) -> [MenuSpec] {
        // Top-level projects only: a sub-repo is reached through its parent.
        let top = current.parentID ?? current.id
        let open = store.library.openProjects.compactMap(store.project).filter { $0.parentID == nil }
        var items: [MenuSpec] = [.header("Open projects")]
        for p in open {
            items.append(MenuSpec(title: p.name, checked: p.id == top) { store.openProject(p.id) })
        }
        items.append(.separator)
        items.append(.header("All projects"))
        for p in store.sortedProjects where p.parentID == nil && !open.contains(where: { $0.id == p.id }) {
            items.append(MenuSpec(title: p.name) { store.openProject(p.id) })
        }
        items.append(.separator)
        items.append(MenuSpec(title: "Close \(current.name)") { store.closeProject(current.id) })
        items.append(MenuSpec(title: "Project Settings…") { store.route = .projectSettings(current.id) })
        items.append(MenuSpec(title: "Open Project…", key: "⌘O") { store.sheet = .addProject })
        return items
    }

    private var searchPill: some View {
        Button { store.paletteScopeToProject = false; store.paletteOpen = true } label: {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .semibold))
                Text("Search projects, files, hosts, actions…").font(Typo.ui(13)).lineLimit(1)
                Spacer(minLength: 0)
                KeyCap(text: "⌘K")
            }
            .foregroundStyle(Theme.text3)
            .padding(.leading, 11).padding(.trailing, 6)
            .frame(minWidth: 220, idealWidth: 440, maxWidth: 440)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.controlStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hand)
        .layoutPriority(-1)
        .accessibilityLabel("Search, command palette")
        .tip("Command palette", "⌘K")
        .guideAnchor(.search)
    }

    private func presetControl(_ ws: WorkspaceStore) -> some View {
        let current = BuiltinPreset(rawValue: ws.layout.presetName ?? "")
        let custom = store.library.customPresets.first { $0.id == ws.layout.presetName }
        return HStack(spacing: 2) {
            ForEach(BuiltinPreset.shown) { p in
                let on = p == current
                Button { ws.apply(p) } label: {
                    Text(p.label)
                        .font(Typo.ui(11.5, .semibold))
                        .foregroundStyle(on ? Theme.text : Theme.text3)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.segmentedOn : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hand)
                .tip("\(p.label) layout", p.shortcut)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            MenuButton(items: {
                var items: [MenuSpec] = store.library.customPresets.map { c in
                    MenuSpec(title: c.name, checked: c.id == ws.layout.presetName) { ws.apply(custom: c) }
                }
                if !items.isEmpty { items.append(.separator) }
                items.append(MenuSpec(title: "Save Current Layout…") { store.sheet = .savePreset(ws.projectID) })
                items.append(MenuSpec(title: "Reset “\(ws.activePresetName)” for This Project", enabled: ws.layout.presetName != nil) { ws.resetArrangement() })
                items.append(MenuSpec(title: "Manage Layouts…") { store.customizeTab = "layout"; store.go(.customize) })
                return items
            }) {
                HStack(spacing: 4) {
                    Text(custom?.name ?? (current == nil ? "Custom" : "Layouts")).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
                }
                .font(Typo.ui(11.5, .semibold))
                .foregroundStyle(custom != nil || current == nil ? Theme.text : Theme.text3)
                .padding(.horizontal, 9).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(custom != nil || current == nil ? Theme.segmentedOn : .clear))
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Saved layouts")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layout preset")
    }

    private var dockToggles: some View {
        let ws = store.currentWorkspace
        return HStack(spacing: 2) {
            dockToggle(.left, ws, symbol: "rectangle.lefthalf.inset.filled", label: "Toggle left dock")
            dockToggle(.bottom, ws, symbol: "rectangle.bottomhalf.inset.filled", label: "Toggle bottom dock")
            dockToggle(.right, ws, symbol: "rectangle.righthalf.inset.filled", label: "Toggle right dock")
        }
    }

    private func dockToggle(_ side: DockSide, _ ws: WorkspaceStore?, symbol: String, label: String) -> some View {
        let on = ws?.layout.isVisible(side) ?? false
        return IconButton(symbol: symbol, label: label, size: 28, iconSize: 14, color: on ? Theme.text : Theme.offline) {
            guard let ws else { return }
            if ws.layout.panels(side).isEmpty {
                store.popover = PopoverRequest(kind: .addPanel(side), anchor: .zero, projectID: ws.projectID, centred: true)
            } else {
                ws.layout.toggleCollapsed(side)
            }
        }
        .disabled(ws == nil)
        .opacity(ws == nil ? 0.6 : 1)
    }

    private var addMenu: some View {
        MenuButton(items: {
            var items: [MenuSpec] = [
                MenuSpec(title: "Project Folder…", symbol: "folder.badge.plus", key: "⌘O") { store.sheet = .addProject },
                MenuSpec(title: "New Terminal", symbol: "terminal", key: "⌘T") {
                    if let id = store.currentProjectID { store.newTerminal(project: id) } else { store.newTerminal(project: nil, attach: false); store.route = .terminals }
                },
                MenuSpec(title: "New Agent Session…", symbol: "sparkle", key: "⌥⌘T") { store.startAgent(project: nil) },
                .separator,
                MenuSpec(title: "SSH Host…", symbol: "globe") { store.sheet = .editHost(nil) },
                MenuSpec(title: "Database…", symbol: "cylinder.split.1x2") { store.sheet = .editDatabase(nil) },
                MenuSpec(title: "Docker Target…", symbol: "shippingbox") { store.sheet = .addDocker },
                MenuSpec(title: "Import from JetBrains / VS Code…", symbol: "square.and.arrow.down") { store.sheet = .importConnections }
            ]
            if let id = store.currentProjectID {
                items += [.separator, MenuSpec(title: "Add Panel…", symbol: "rectangle.badge.plus") {
                    store.popover = PopoverRequest(kind: .addPanel(.right), anchor: .zero, projectID: id, centred: true)
                }]
            }
            return items
        }) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(accent))
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Add")
        .tip("Add project, terminal, host or database")
        .guideAnchor(.new)
    }
}

/// The bell: agent alerts you may have missed, newest first.
private struct NoticesButton: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    @State private var open = false

    var body: some View {
        let unread = store.unreadNotices
        IconButton(symbol: unread > 0 ? "bell.badge" : "bell", label: unread > 0 ? "Notifications, \(unread) unread" : "Notifications",
                   size: 28, iconSize: 14, color: unread > 0 ? Theme.text : Theme.text2, active: open) { open.toggle() }
            .overlay(alignment: .topTrailing) {
                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)").font(.system(size: 9, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.onAccent).padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(accent)).offset(x: 5, y: -4)
                        .allowsHitTesting(false)
                }
            }
            .popover(isPresented: $open, arrowEdge: .bottom) { NoticeList { open = false } }
    }
}

private struct NoticeList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let close: () -> Void
    @State private var page = 0

    var body: some View {
        let notices = store.library.notices
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Notifications").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button("Mark all read") { store.markNoticesRead() }.buttonStyle(.hand).font(Typo.ui(11.5)).foregroundStyle(Theme.text2)
                    .disabled(store.unreadNotices == 0)
                Button("Clear") { store.library.notices.removeAll() }.buttonStyle(.hand).font(Typo.ui(11.5)).foregroundStyle(Theme.text2)
                    .disabled(notices.isEmpty)
            }
            .padding(.horizontal, 14).frame(height: 44).hairlineBottom()
            if notices.isEmpty {
                Text("Nothing yet. When an agent finishes or needs you, it shows up here.")
                    .font(Typo.ui(12)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                    .padding(24).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(PageBar.slice(notices, page: page)) { n in row(n) }
                        PageBar(page: $page, total: notices.count)
                    }
                    .padding(6)
                }
                .frame(maxHeight: 440)
            }
        }
        .frame(width: 360)
        .background(Theme.sheet)
    }

    private func row(_ n: AgentNotice) -> some View {
        let gone = store.session(n.sessionID) == nil
        return Button {
            if let i = store.library.notices.firstIndex(where: { $0.id == n.id }) { store.library.notices[i].read = true }
            guard !gone else { return }
            close()
            store.reveal(session: n.sessionID)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(n.read ? Color.clear : accent).frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(n.title).font(Typo.ui(12.5, n.read ? .regular : .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(RelativeTime.long(n.date) + " ago").font(Typo.ui(11)).foregroundStyle(Theme.meta).fixedSize()
                    }
                    Text(gone ? "Session closed · \(n.body)" : n.body).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(2)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hand)
        .rowBackground(selected: false, radius: 8)
        .contextMenu {
            Button(n.read ? "Mark as Unread" : "Mark as Read") {
                if let i = store.library.notices.firstIndex(where: { $0.id == n.id }) { store.library.notices[i].read.toggle() }
            }
            Button("Delete") { store.library.notices.removeAll { $0.id == n.id } }
        }
        .accessibilityLabel("\(n.read ? "" : "Unread, ")\(n.title), \(n.body)")
    }
}
