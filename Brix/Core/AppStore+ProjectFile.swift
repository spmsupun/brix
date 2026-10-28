import Foundation

extension AppStore {
    /// The file contents for a project, from the library and its open workspace.
    /// `existing` supplies the layout when the workspace hasn't been loaded yet.
    func projectFile(for p: Project, existing: ProjectFile?) -> ProjectFile {
        let hosts = linkedHosts(p.id)
        let hostName = { (id: ResourceID?) in id.flatMap(self.host)?.name }
        let root = p.url
        return ProjectFile(
            name: p.name, language: p.language, framework: p.framework, hue: p.hue.rawValue, mark: p.mark, iconSymbol: p.iconSymbol,
            iconPath: p.iconPath.map { Self.relativeIfInside($0, root: root) }, github: p.githubRepo, defaultPreset: p.defaultPreset,
            agent: p.agentID, notes: p.notes.isEmpty ? nil : p.notes, envVarNames: p.envVarNames.isEmpty ? nil : p.envVarNames,
            layout: workspaces[p.id]?.state.layout ?? existing?.layout,
            hosts: hosts.map(\.fileEntry),
            databases: linkedDatabases(p.id).map { $0.fileEntry(tunnelName: hostName($0.tunnelHostID)) },
            docker: linkedDocker(p.id).map { .init(name: $0.name, image: $0.image.isEmpty ? nil : $0.image, composeProject: $0.composeProject.isEmpty ? nil : $0.composeProject,
                                                   composeService: $0.composeService.isEmpty ? nil : $0.composeService, host: hostName($0.hostID)) },
            stacks: linkedStacks(p.id).map { .init(name: $0.name, host: hostName($0.hostID), configFiles: $0.configFiles.map { f in Self.relativeIfInside(f, root: root) }) },
            composeFiles: ProjectFile.composeNames.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        )
    }

    /// Writes `brix.json` when its contents changed. Called from every save.
    func writeProjectFiles() {
        for p in library.projects where !p.isSample && p.keepsSettingsFile {
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

    /// Resolves a host name from the file: one just loaded, else any host with that name.
    private func hostID(named loaded: [String: ResourceID]) -> (String) -> ResourceID? {
        { name in loaded[name] ?? self.library.hosts.first { $0.name == name }?.id }
    }

    /// Applies a project's `brix.json`: settings, layout, and its hosts,
    /// databases and Docker targets (reusing ones already in Brix with the same address).
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
        if let v = file.github { p.githubRepo = v.isEmpty ? nil : v }
        if let v = file.defaultPreset, BuiltinPreset(rawValue: v) != nil { p.defaultPreset = v }
        p.agentID = file.agent ?? p.agentID
        if let v = file.notes { p.notes = v }
        if let v = file.envVarNames { p.envVarNames = v }
        updateProject(p)

        var added = 0
        var hostIDs: [String: ResourceID] = [:]
        for e in file.hosts ?? [] {
            let h = library.hosts.first { $0.matches(e) } ?? {
                added += 1
                let h = SSHHost(entry: e)
                library.hosts.append(h)
                hostStatus[h.id] = .disconnected
                return h
            }()
            hostIDs[e.name] = h.id
            library.links.link(id, h.id, kind: .host)
        }
        for e in file.databases ?? [] {
            guard let kind = DBKind(rawValue: e.kind) else { continue }
            let d = library.databases.first { $0.matches(e) } ?? {
                added += 1
                var d = DatabaseConnection(id: "db-\(UUID().uuidString.prefix(8).lowercased())", name: e.name, kind: kind, tag: e.tag.flatMap(EnvTag.init) ?? EnvTag.guess(e.name))
                d.host = e.host ?? "localhost"
                d.port = e.port ?? kind.defaultPort
                d.database = e.database ?? ""
                d.user = e.user ?? ""
                d.filePath = e.filePath ?? ""
                d.sslMode = e.sslMode.flatMap(SSLMode.init) ?? .prefer
                d.tunnelHostID = e.tunnelHost.flatMap(hostID(named: hostIDs))
                d.readOnly = e.readOnly ?? false
                // A file from a repo shouldn't hand agents rows by default.
                // A file from a repo shouldn't hand agents rows by default, and never
                // write access (its tag could be wrong): the user raises it in the form.
                d.agentAccess = min(e.agentAccess.flatMap(AgentDBAccess.init) ?? .schema, .read)
                library.databases.append(d)
                dbStatus[d.id] = .disconnected
                return d
            }()
            library.links.link(id, d.id, kind: .database)
        }
        for e in file.docker ?? [] {
            let hostID = e.host.flatMap(hostID(named: hostIDs))
            let c = library.docker.first { $0.name == e.name && $0.hostID == hostID } ?? {
                added += 1
                var c = DockerTarget(id: "dk-\(UUID().uuidString.prefix(8).lowercased())", name: e.name, image: e.image ?? "", ports: "", hostID: hostID, state: .exited)
                c.composeProject = e.composeProject ?? ""
                c.composeService = e.composeService ?? ""
                library.docker.append(c)
                return c
            }()
            library.links.link(id, c.id, kind: .docker)
        }
        for e in file.stacks ?? [] {
            let hostID = e.host.flatMap(hostID(named: hostIDs))
            var s = ComposeStack(id: ComposeStack.makeID(e.name, hostID: hostID), name: e.name, hostID: hostID)
            s.configFiles = (e.configFiles ?? []).map { $0.hasPrefix("/") || $0.hasPrefix("~") ? $0 : p.url.appendingPathComponent($0).path }
            if !library.stacks.contains(where: { $0.id == s.id }) { added += 1 }
            setStackLink(id, s, linked: true)
        }
        if let layout = file.layout {
            workspace(for: id).state.layout.apply(layout)
            workspace(for: id).state.layout.presetName = layout.presetName
        }
        if announce || added > 0 {
            toast(.success, "Loaded \(p.name) settings from \(ProjectFile.relativePath)",
                  detail: added > 0 ? "Added \(added) connection\(added == 1 ? "" : "s"). Passwords aren't kept in the file; enter them when you first connect." : nil)
        }
        return true
    }
}
