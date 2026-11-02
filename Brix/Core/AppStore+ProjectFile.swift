import Foundation

extension AppStore {
    /// The file contents for a project, from the library and its open workspace.
    /// `existing` supplies the layout when the workspace hasn't been loaded yet.
    func projectFile(for p: Project, existing: ProjectFile?) -> ProjectFile {
        let dbs = linkedDatabases(p.id), docker = linkedDocker(p.id), stacks = linkedStacks(p.id)
        // Servers the databases, containers and stacks go through come along, so
        // their references resolve when the file is loaded elsewhere.
        var hosts = linkedHosts(p.id)
        for id in dbs.compactMap(\.tunnelHostID) + docker.compactMap(\.hostID) + stacks.compactMap(\.hostID) where !hosts.contains(where: { $0.id == id }) {
            if let h = host(id) { hosts.append(h) }
        }
        let hostName = { (id: ResourceID?) in id.flatMap(self.host)?.name }
        let root = p.url
        // Project notes stay on this Mac: the file is shared with everyone who clones the repo.
        var file = ProjectFile(
            name: p.name, language: p.language, framework: p.framework, hue: p.hue.rawValue, mark: p.mark, iconSymbol: p.iconSymbol,
            iconPath: p.iconPath.map { Self.relativeIfInside($0, root: root) }, github: p.githubRepo, defaultPreset: p.defaultPreset,
            agent: p.agentID, envVarNames: p.envVarNames.isEmpty ? nil : p.envVarNames,
            layout: workspaces[p.id]?.state.layout ?? existing?.layout,
            hosts: hosts.map(\.fileEntry),
            databases: dbs.map { $0.fileEntry(tunnelName: hostName($0.tunnelHostID)) },
            docker: docker.map { .init(name: $0.name, image: $0.image.isEmpty ? nil : $0.image, composeProject: $0.composeProject.isEmpty ? nil : $0.composeProject,
                                       composeService: $0.composeService.isEmpty ? nil : $0.composeService, host: hostName($0.hostID)) },
            stacks: stacks.map { .init(name: $0.name, host: hostName($0.hostID), configFiles: $0.configFiles.map { f in Self.relativeIfInside(f, root: root) }) },
            composeFiles: ProjectFile.composeNames.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        )
        // The user hasn't taken the file's connections: what it lists stays as it
        // is, rather than Brix's view of the project (which leaves them out).
        if p.holdsFileConnections == true, let existing {
            file.hosts = existing.hosts
            file.databases = existing.databases
            file.docker = existing.docker
            file.stacks = existing.stacks
            file.agent = existing.agent
            file.github = existing.github
        }
        return file
    }

    /// Writes `brix.json` when its contents changed. Called from every save.
    func writeProjectFiles() {
        // Brix Dev works in the same repositories as the installed Brix; only the
        // installed app writes their brix.json.
        guard writesProjectFiles else { return }
        // A file whose connections are being asked about is left alone until answered.
        for p in library.projects where !p.isSample && p.keepsSettingsFile && !projectFilesAsking.contains(p.id) {
            guard FileManager.default.fileExists(atPath: p.expandedPath) else { continue }
            let url = ProjectFile.url(for: p)
            do {
                // A file that exists but doesn't parse (a bad hand edit, a merge
                // conflict) is left alone rather than overwritten.
                let existing = try ProjectFile.read(p)
                let data = try Persistence.encoder.encode(projectFile(for: p, existing: existing))
                if (try? Data(contentsOf: url)) == data { continue }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                ProjectFile.removeLegacy(p)
                projectFileErrors[p.id] = nil
            } catch {
                // One toast per project until it succeeds again, not one per save.
                if projectFileErrors[p.id] == nil {
                    toast(.error, "Not saving \(p.name)/\(ProjectFile.relativePath)", detail: "The file couldn't be read or written, so it was left as is. \(error.localizedDescription)")
                }
                projectFileErrors[p.id] = error.localizedDescription
            }
        }
    }

    /// Paths inside the project are stored relative, so the file works on any Mac.
    static func relativeIfInside(_ path: String, root: URL) -> String {
        let full = (path as NSString).expandingTildeInPath
        return full.hasPrefix(root.path + "/") ? String(full.dropFirst(root.path.count + 1)) : path
    }

    /// Applies a project's `brix.json`: settings and layout at once; its hosts,
    /// databases, Docker targets and stacks only after the user agrees, since the
    /// file may come from a repository someone else wrote.
    @discardableResult
    func loadProjectFile(_ id: ProjectID, announce: Bool = true) -> Bool {
        guard var p = project(id), !p.isSample else { return false }
        let file: ProjectFile
        do {
            guard let f = try ProjectFile.read(p) else {
                if announce { toast(.info, "No \(ProjectFile.relativePath) in \(p.name)") }
                return false
            }
            file = f
        } catch {
            toast(.error, "Couldn't read \(p.name)/\(ProjectFile.relativePath)", detail: error.localizedDescription)
            return false
        }
        if let v = file.name, !v.isEmpty { p.name = v }
        if let v = file.language { p.language = v }
        if let v = file.framework { p.framework = v }
        if let v = file.hue.flatMap(ProjectHue.init) { p.hue = v }
        if let v = file.mark { p.mark = v.isEmpty ? nil : v }
        if let v = file.iconSymbol { p.iconSymbol = v.isEmpty ? nil : v }
        if let v = file.iconPath { p.iconPath = v.isEmpty ? nil : v }
        // Clearing the repository is harmless; naming one waits for the user's yes.
        if file.github == "" { p.githubRepo = nil }
        if let v = file.defaultPreset, BuiltinPreset(rawValue: v) != nil { p.defaultPreset = v }
        if let v = file.envVarNames { p.envVarNames = v }
        updateProject(p)
        if let layout = file.layout {
            workspace(for: id).state.layout.apply(layout)
            workspace(for: id).state.layout.presetName = layout.presetName
        }

        let plan = projectFileImport(file, for: p)
        if !plan.skipped.isEmpty {
            toast(.error, "Skipped \(plan.skipped.count) entr\(plan.skipped.count == 1 ? "y" : "ies") in \(p.name)/\(ProjectFile.relativePath)",
                  detail: plan.skipped.prefix(4).joined(separator: "; "))
        }
        guard !plan.lines.isEmpty else {
            holdFileConnections(id, false)
            if announce { toast(.success, "Loaded \(p.name) settings from \(ProjectFile.relativePath)") }
            return true
        }
        // Until the user agrees, the file isn't written at all, and after a no (or a
        // quit before answering) its connections stay in it as they are.
        holdFileConnections(id, true)
        projectFilesAsking.insert(id)
        let list = plan.lines.prefix(12).joined(separator: "\n") + (plan.lines.count > 12 ? "\nand \(plan.lines.count - 12) more" : "")
        confirm("Use the connections in \(p.name)/\(ProjectFile.relativePath)?",
                "\(list)\n\nThis file comes with the repository. Continue only if you trust whoever wrote it: Brix will connect to these when you use them. Passwords are never in the file.",
                confirm: "Add and Link", destructive: false,
                onCancel: { [weak self] in
                    self?.projectFilesAsking.remove(id)
                    self?.toast(.info, "Nothing from \(ProjectFile.relativePath) was added",
                                detail: "Its settings and layout were loaded; its connections are left in the file as they are. Reload it from Project Settings to be asked again.")
                }) { [weak self] in
            self?.projectFilesAsking.remove(id)
            // Worked out again, in case Brix changed while the question waited; applied
            // only if it's still exactly what the user agreed to.
            guard let self, let now = self.project(id).map({ self.projectFileImport(file, for: $0) }), now == plan else {
                self?.toast(.info, "Nothing from \(ProjectFile.relativePath) was added", detail: "Brix changed while you were asked. Reload it from Project Settings.")
                return
            }
            self.applyProjectFileImport(now, to: id, name: p.name)
            self.holdFileConnections(id, false)
        }
        return true
    }

    private func holdFileConnections(_ id: ProjectID, _ hold: Bool) {
        guard var p = project(id), (p.holdsFileConnections == true) != hold else { return }
        p.holdsFileConnections = hold ? true : nil
        updateProject(p)
    }

    /// What a brix.json would add to Brix and link to its project.
    struct ProjectFileImport: Equatable {
        var newHosts: [SSHHost] = []
        var newDatabases: [DatabaseConnection] = []
        var newDocker: [DockerTarget] = []
        var newStacks: [ComposeStack] = []
        /// Resources and stacks already in Brix, to link (each kept exactly as it is).
        var links: [(ResourceID, ResourceKind)] = []
        var linkStacks: [ComposeStack] = []
        /// The default agent, GitHub repository and notes the file sets, when they differ.
        var agent: String?
        var github: String?
        var notes: String?
        /// One line per change, for the confirmation.
        var lines: [String] = []
        /// Entries left out, with the reason.
        var skipped: [String] = []

        /// Everything that would be applied. Ids made up for new entries differ each
        /// time the file is worked out, so they're compared by position.
        static func == (a: Self, b: Self) -> Bool {
            let x = a.canonical, y = b.canonical
            return x.newHosts == y.newHosts && x.newDatabases == y.newDatabases && x.newDocker == y.newDocker && x.newStacks == y.newStacks
                && x.links.map(\.0) == y.links.map(\.0) && x.links.map(\.1) == y.links.map(\.1) && x.linkStacks == y.linkStacks
                && x.agent == y.agent && x.github == y.github && x.notes == y.notes && x.lines == y.lines
        }

        private var canonical: Self {
            var c = self, ids: [ResourceID: ResourceID] = [:]
            for i in c.newHosts.indices { ids[c.newHosts[i].id] = "new-host-\(i)"; c.newHosts[i].id = "new-host-\(i)" }
            let map = { (id: ResourceID?) in id.map { ids[$0] ?? $0 } }
            for i in c.newDatabases.indices { c.newDatabases[i].id = "new-db-\(i)"; c.newDatabases[i].tunnelHostID = map(c.newDatabases[i].tunnelHostID) }
            for i in c.newDocker.indices { c.newDocker[i].id = "new-dk-\(i)"; c.newDocker[i].hostID = map(c.newDocker[i].hostID) }
            for i in c.newStacks.indices {
                c.newStacks[i].hostID = map(c.newStacks[i].hostID)
                c.newStacks[i].id = ComposeStack.makeID(c.newStacks[i].name, hostID: c.newStacks[i].hostID)
            }
            return c
        }
    }

    /// Works out what the file holds without changing anything. A resource already in
    /// Brix is matched by its full address (server, port, user, database, route) and
    /// only linked: its tag and agent access are never touched by the file.
    func projectFileImport(_ file: ProjectFile, for p: Project) -> ProjectFileImport {
        var plan = ProjectFileImport()
        let linked = Set(library.links.pairs.filter { $0.project == p.id }.map(\.resource))
        // The file's own host names, each resolved to a server by address. A
        // reference from a database, container or stack only reaches these.
        var byName: [String: SSHHost] = [:]
        for e in file.hosts ?? [] {
            guard Self.validName(e.name), Self.validArg(e.host), Self.validArg(e.user) else {
                plan.skipped.append("server \"\(Self.shown(e.name))\": unsafe name, address or user"); continue
            }
            if let h = library.hosts.first(where: { $0.matches(e) }) ?? plan.newHosts.first(where: { $0.matches(e) }) {
                byName[e.name] = h
                if library.hosts.contains(where: { $0.id == h.id }), !linked.contains(h.id), !plan.links.contains(where: { $0.0 == h.id }) {
                    plan.links.append((h.id, .host))
                    plan.lines.append("Link server \(Self.describe(h))")
                }
            } else {
                let h = SSHHost(entry: e)
                byName[e.name] = h
                plan.newHosts.append(h)
                plan.lines.append("Add server \(Self.describe(h))")
            }
        }
        // nil: no host named; .some(nil): named but not one of the file's servers.
        let resolve = { (name: String?) -> ResourceID?? in name.map { byName[$0]?.id } }
        for e in file.databases ?? [] {
            let what = "database \"\(Self.shown(e.name))\""
            guard let kind = DBKind(rawValue: e.kind), Self.validName(e.name) else { plan.skipped.append("\(what): unknown kind or empty name"); continue }
            guard kind == .sqlite || ([e.host, e.user, e.database].allSatisfy { ($0 ?? "").isEmpty || Self.validArg($0!) }) else {
                plan.skipped.append("\(what): unsafe address, user or database name"); continue
            }
            let tunnel = resolve(e.tunnelHost)
            if case .some(nil) = tunnel { plan.skipped.append("\(what): its SSH tunnel host isn't one of the file's servers"); continue }
            let tunnelID = tunnel ?? nil
            let tunnelName = tunnelID.flatMap { id in byName.values.first { $0.id == id }?.name }
            if let d = library.databases.first(where: { $0.matches(e, tunnel: tunnelID) }) {
                if !linked.contains(d.id), !plan.links.contains(where: { $0.0 == d.id }) {
                    plan.links.append((d.id, .database))
                    plan.lines.append("Link database \(Self.describe(d, via: d.tunnelHostID.flatMap(host)?.name))")
                }
                continue
            }
            if plan.newDatabases.contains(where: { $0.matches(e, tunnel: tunnelID) }) { continue }
            var d = DatabaseConnection(id: "db-\(UUID().uuidString.prefix(8).lowercased())", name: e.name, kind: kind,
                                       tag: EnvTag(file: e.tag, guessFrom: e.name + " " + (e.host ?? "")))
            d.host = e.host ?? "localhost"
            d.port = e.port ?? kind.defaultPort
            d.database = e.database ?? ""
            d.user = e.user ?? ""
            d.filePath = e.filePath ?? ""
            d.sslMode = e.sslMode.flatMap(SSLMode.init) ?? .prefer
            d.tunnelHostID = tunnelID
            d.readOnly = e.readOnly ?? false
            // A file from a repo shouldn't hand agents rows by default, and never
            // write access (its tag could be wrong): the user raises it in the form.
            d.agentAccess = min(e.agentAccess.flatMap(AgentDBAccess.init) ?? .schema, .read)
            plan.newDatabases.append(d)
            plan.lines.append("Add database \(Self.describe(d, via: tunnelName))")
        }
        for e in file.docker ?? [] {
            let what = "container \"\(Self.shown(e.name))\""
            guard Self.validDockerName(e.name) else { plan.skipped.append("\(what): not a valid Docker name"); continue }
            let ref = resolve(e.host)
            if case .some(nil) = ref { plan.skipped.append("\(what): its host isn't one of the file's servers"); continue }
            let hostID = ref ?? nil
            let on = hostID.flatMap { id in byName.values.first { $0.id == id }?.name }.map { "on \($0)" } ?? "local"
            if let c = library.docker.first(where: { $0.name == e.name && $0.hostID == hostID }) {
                if !linked.contains(c.id), !plan.links.contains(where: { $0.0 == c.id }) {
                    plan.links.append((c.id, .docker))
                    plan.lines.append("Link container \(c.name) (\(on))")
                }
                continue
            }
            if plan.newDocker.contains(where: { $0.name == e.name && $0.hostID == hostID }) { continue }
            var c = DockerTarget(id: "dk-\(UUID().uuidString.prefix(8).lowercased())", name: e.name, image: e.image ?? "", ports: "", hostID: hostID, state: .exited)
            c.composeProject = e.composeProject ?? ""
            c.composeService = e.composeService ?? ""
            plan.newDocker.append(c)
            plan.lines.append("Add container \(c.name) (\(on))")
        }
        for e in file.stacks ?? [] {
            let what = "stack \"\(Self.shown(e.name))\""
            guard Self.validDockerName(e.name) else { plan.skipped.append("\(what): not a valid Docker name"); continue }
            let ref = resolve(e.host)
            if case .some(nil) = ref { plan.skipped.append("\(what): its host isn't one of the file's servers"); continue }
            let hostID = ref ?? nil
            let on = hostID.flatMap { id in byName.values.first { $0.id == id }?.name }.map { "on \($0)" } ?? "local"
            let sid = ComposeStack.makeID(e.name, hostID: hostID)
            if let s = library.stacks.first(where: { $0.id == sid }) {
                if !linked.contains(sid), !plan.linkStacks.contains(where: { $0.id == sid }) {
                    plan.linkStacks.append(s)
                    plan.lines.append("Link stack \(s.name) (\(on))")
                }
                continue
            }
            if plan.newStacks.contains(where: { $0.id == sid }) { continue }
            var s = ComposeStack(id: sid, name: e.name, hostID: hostID)
            s.configFiles = (e.configFiles ?? []).map { $0.hasPrefix("/") || $0.hasPrefix("~") ? $0 : p.url.appendingPathComponent($0).path }
            plan.newStacks.append(s)
            plan.lines.append("Add stack \(s.name) (\(on))" + (s.configFiles.isEmpty ? "" : " from \(s.configFiles.map { Self.shownPath($0, root: p.url) }.joined(separator: ", "))"))
        }
        if let a = file.agent, a != p.agentID {
            plan.agent = a
            plan.lines.append("Start \(Self.shown(settings.agents.first { $0.id == a }?.name ?? a)) as this project's agent")
        }
        if let g = file.github, !g.isEmpty, g != p.githubRepo {
            plan.github = g
            plan.lines.append("Use GitHub repository \(Self.shown(g))")
        }
        if let n = file.notes, n != p.notes {
            plan.notes = n
            plan.lines.append(p.notes.isEmpty ? "Set the project's notes" : "Replace the project's notes")
        }
        return plan
    }

    /// Adds and links what the user agreed to.
    func applyProjectFileImport(_ plan: ProjectFileImport, to id: ProjectID, name: String) {
        for h in plan.newHosts {
            library.hosts.append(h)
            hostStatus[h.id] = .disconnected
            library.links.link(id, h.id, kind: .host)
        }
        for d in plan.newDatabases {
            library.databases.append(d)
            dbStatus[d.id] = .disconnected
            library.links.link(id, d.id, kind: .database)
        }
        for c in plan.newDocker {
            library.docker.append(c)
            library.links.link(id, c.id, kind: .docker)
        }
        for (rid, kind) in plan.links { library.links.link(id, rid, kind: kind) }
        for s in plan.newStacks + plan.linkStacks { setStackLink(id, s, linked: true) }
        if var p = project(id), plan.agent != nil || plan.github != nil || plan.notes != nil {
            if let v = plan.agent { p.agentID = v }
            if let v = plan.github { p.githubRepo = v }
            if let v = plan.notes { p.notes = v }
            updateProject(p)
        }
        let added = plan.newHosts.count + plan.newDatabases.count + plan.newDocker.count + plan.newStacks.count
        toast(.success, "Loaded \(name) settings from \(ProjectFile.relativePath)",
              detail: added > 0 ? "Added \(added) connection\(added == 1 ? "" : "s"). Passwords aren't kept in the file; enter them when you first connect." : nil)
    }

    // MARK: Checks on values from the file

    /// A display name: not empty, no line breaks or control characters.
    nonisolated static func validName(_ s: String) -> Bool {
        !s.trimmingCharacters(in: .whitespaces).isEmpty && s.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
    }

    /// A host, user or database name that goes on a command line: not empty, no
    /// leading "-" (it would read as an option) and no whitespace.
    nonisolated static func validArg(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && s.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
    }

    /// Docker's own rule for container and project names.
    nonisolated static func validDockerName(_ s: String) -> Bool {
        s.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", options: .regularExpression) != nil
    }

    /// A name from the file as shown in a message.
    private static func shown(_ s: String) -> String { AgentConfig.promptSafe(s) }

    /// A path from the file as shown: relative inside the project, and its end kept when long.
    private static func shownPath(_ path: String, root: URL) -> String {
        let rel = relativeIfInside(path, root: root)
        return rel.count > 64 ? "…" + shown(String(rel.suffix(63))) : shown(rel)
    }

    private static func describe(_ h: SSHHost) -> String {
        "\(shown(h.name)) (\(h.address), \(h.tag.label))"
    }

    private static func describe(_ d: DatabaseConnection, via tunnel: String?) -> String {
        let at = d.kind == .sqlite ? d.filePath : "\(d.user.isEmpty ? "" : d.user + "@")\(d.host):\(d.port)/\(d.database)"
        return "\(shown(d.name)) (\(d.kind.label) \(at)\(tunnel.map { " via \(shown($0))" } ?? ""), \(d.tag.label))"
    }
}
