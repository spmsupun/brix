import Foundation

extension AppStore {
    /// Every stack known: attached ones first, then ones Docker reports.
    var allStacks: [ComposeStack] {
        var out = library.stacks
        for s in dockerInventory.values.flatMap(\.stacks) {
            if let i = out.firstIndex(where: { $0.id == s.id }) {
                out[i].status = s.status
                out[i].configFiles = s.configFiles
            } else {
                out.append(s)
            }
        }
        return out
    }

    func stack(_ id: ResourceID) -> ComposeStack? { allStacks.first { $0.id == id } }

    func linkedStacks(_ p: ProjectID) -> [ComposeStack] { library.links.resources(of: .stack, for: p).compactMap(stack) }

    /// Attaching keeps a copy in the library so the link survives Docker being off.
    func setStackLink(_ project: ProjectID, _ s: ComposeStack, linked: Bool) {
        if linked, !library.stacks.contains(where: { $0.id == s.id }) { library.stacks.append(s) }
        library.links.set(project, s.id, kind: .stack, linked: linked)
        if !linked, library.links.projects(for: s.id).isEmpty { library.stacks.removeAll { $0.id == s.id } }
    }

    /// Stacks, networks, volumes and images for local Docker and connected hosts.
    func refreshDockerInventory() async {
        dockerInstalled = ProcessRunner.which("docker") != nil
        var engines: [(key: String, host: SSHHost?, svc: DockerService)] = []
        if library.docker.contains(where: \.isSample) { engines.append(("sample", nil, services.mock.docker)) }
        engines.append(("local", nil, services.live.docker))
        for h in library.hosts where !h.isSample && hostStatus[h.id] == .connected { engines.append((h.id, h, services.live.docker)) }
        var errors: [String] = []
        for e in engines {
            do {
                dockerInventory[e.key] = try await e.svc.inventory(host: e.host)
            } catch {
                dockerInventory[e.key] = nil
                errors.append("\(e.host?.name ?? "Local"): \(error.localizedDescription)")
            }
        }
        dockerInventoryError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func composeAction(_ action: ComposeAction, _ s: ComposeStack) {
        let host = s.hostID.flatMap(self.host)
        let run = { [weak self] in
            guard let self else { return }
            dockerBusy.insert(s.id)
            Task {
                do {
                    try await (s.isSample ? self.services.mock.docker : self.services.live.docker).compose(action, s, host: host)
                    self.toast(.success, "\(action.label): \(s.name)")
                    if action == .up {
                        for p in self.library.projects where self.library.links.isLinked(p.id, s.id) {
                            self.record(ActivityEvent(date: Date(), kind: .deploy, projectID: p.id, actor: "You", text: "deployed \(s.name) to",
                                                      target: host?.name ?? "local Docker", meta: "docker compose up", tone: .good))
                        }
                        self.lastShipped = Date()
                    }
                } catch {
                    self.toast(.error, "Couldn't run compose \(action.rawValue) on \(s.name)", detail: error.localizedDescription)
                }
                self.dockerBusy.remove(s.id)
                await self.refreshDocker()
                await self.refreshDockerInventory()
            }
        }
        let prod = host?.tag.isProduction ?? false
        if action == .down || action == .stop || prod {
            confirm("\(action.label) \(s.name)\(host.map { " on \($0.name)" } ?? "")?",
                    action == .down ? "Stops and removes the stack's containers and networks. Volumes are kept." : "Runs docker compose \(action.rawValue).",
                    confirm: action.label, destructive: action == .down || prod, action: run)
        } else {
            run()
        }
    }

    func openComposeLogs(_ s: ComposeStack) {
        let host = s.hostID.flatMap(self.host)
        let cmd = (s.isSample ? services.mock.docker : services.live.docker).composeLogsCommand(s, host: host)
        let t = newTerminal(project: library.links.projects(for: s.id).first, title: "\(s.name) logs", kind: .logs, command: cmd, attach: false)
        route = .terminals
        focusedSessionID = t.id
    }

    /// "Attach" menu for a project: every host, database and stack, with checkmarks.
    func attachResourceMenu(project p: ProjectID) -> [MenuSpec] {
        var items: [MenuSpec] = []
        if !library.hosts.isEmpty {
            items.append(MenuSpec(title: "SSH Hosts", children: library.hosts.map { h in
                let on = library.links.isLinked(p, h.id)
                return MenuSpec(title: h.name, checked: on) { [weak self] in self?.setLink(p, h.id, kind: .host, linked: !on) }
            }))
        }
        if !library.databases.isEmpty {
            items.append(MenuSpec(title: "Databases", children: library.databases.map { d in
                let on = library.links.isLinked(p, d.id)
                return MenuSpec(title: d.name, checked: on) { [weak self] in self?.setLink(p, d.id, kind: .database, linked: !on) }
            }))
        }
        let stacks = allStacks
        if !stacks.isEmpty {
            items.append(MenuSpec(title: "Compose Stacks", children: stacks.map { s in
                let on = library.links.isLinked(p, s.id)
                return MenuSpec(title: s.name + (s.hostID.flatMap(host).map { " · \($0.name)" } ?? ""), checked: on) { [weak self] in self?.setStackLink(p, s, linked: !on) }
            }))
        }
        if items.isEmpty { items.append(MenuSpec(title: "Add an SSH host, database or Docker first") {}) }
        return items
    }

    /// "Attach to project" menu for one resource.
    func attachToProjectMenu(resource id: ResourceID, kind: ResourceKind, stack: ComposeStack? = nil) -> [MenuSpec] {
        let projects = sortedProjects
        guard !projects.isEmpty else { return [MenuSpec(title: "No projects yet") {}] }
        return [.header("Attach to project")] + projects.map { p in
            let on = library.links.isLinked(p.id, id)
            return MenuSpec(title: p.name, checked: on) { [weak self] in
                if let stack { self?.setStackLink(p.id, stack, linked: !on) } else { self?.setLink(p.id, id, kind: kind, linked: !on) }
            }
        }
    }
}
