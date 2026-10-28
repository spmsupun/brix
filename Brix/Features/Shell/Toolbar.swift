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
        var items: [MenuSpec] = [.header("Open projects")]
        for id in store.library.openProjects {
            guard let p = store.project(id) else { continue }
            items.append(MenuSpec(title: p.name, checked: p.id == current.id) { store.openProject(p.id) })
        }
        items.append(.separator)
        items.append(.header("All projects"))
        for p in store.sortedProjects where !store.library.openProjects.contains(p.id) {
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
        .buttonStyle(.plain)
        .layoutPriority(-1)
        .accessibilityLabel("Search, command palette")
        .tip("Command palette", "⌘K")
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
                .buttonStyle(.plain)
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
    }
}
