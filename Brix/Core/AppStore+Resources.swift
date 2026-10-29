import SwiftUI
import AppKit

extension AppStore {
    // MARK: Projects

    struct DetectedProject: Equatable {
        var name: String
        var path: String
        var language: String
        var framework: String
        var isGitRepo: Bool
        var branch: String
        var hue: ProjectHue
    }

    enum AddProjectError: LocalizedError, Equatable {
        case missing, notFolder, duplicate(String)
        var errorDescription: String? {
            switch self {
            case .missing: "That folder doesn't exist."
            case .notFolder: "Pick a folder, not a file."
            case .duplicate(let n): "This folder is already added as \(n)."
            }
        }
    }

    func validateNewProject(url: URL) -> AddProjectError? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return .missing }
        guard isDir.boolValue else { return .notFolder }
        let std = url.standardizedFileURL.path
        if let p = library.projects.first(where: { URL(fileURLWithPath: $0.expandedPath).standardizedFileURL.path == std }) {
            return .duplicate(p.name)
        }
        return nil
    }

    /// Reads manifests to guess language and framework.
    nonisolated static func detect(url: URL) -> DetectedProject {
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: url.appendingPathComponent(f).path) }
        func read(_ f: String) -> String { (try? String(contentsOf: url.appendingPathComponent(f), encoding: .utf8)) ?? "" }
        var language = "Unknown", framework = "Folder"
        if has("package.json") {
            let pkg = read("package.json")
            language = has("tsconfig.json") ? "TypeScript" : "JavaScript"
            let fws: [(String, String)] = [("\"next\"", "Next.js"), ("\"nuxt\"", "Nuxt"), ("\"@sveltejs/kit\"", "SvelteKit"), ("\"astro\"", "Astro"), ("\"react\"", "React"), ("\"vue\"", "Vue"), ("\"express\"", "Express"), ("\"@nestjs/core\"", "NestJS")]
            let fw = fws.first { pkg.contains($0.0) }?.1 ?? "Node.js"
            framework = "\(fw) · \(language)"
        } else if has("go.mod") {
            language = "Go"
            let mod = read("go.mod")
            let ver = mod.split(separator: "\n").first { $0.hasPrefix("go ") }.map { String($0.dropFirst(3)) } ?? ""
            let fw = mod.contains("go-chi/chi") ? " · chi" : (mod.contains("gin-gonic") ? " · Gin" : (mod.contains("labstack/echo") ? " · Echo" : ""))
            framework = "Go \(ver)\(fw)".trimmingCharacters(in: .whitespaces)
        } else if has("composer.json") {
            language = "PHP"
            let c = read("composer.json")
            framework = c.contains("laravel/framework") ? "Laravel · PHP" : (c.contains("symfony/") ? "Symfony · PHP" : "PHP")
        } else if has("pyproject.toml") || has("requirements.txt") || has("setup.py") {
            language = "Python"
            let t = read("pyproject.toml") + read("requirements.txt")
            let fws: [(String, String)] = [("django", "Django"), ("fastapi", "FastAPI"), ("flask", "Flask"), ("prefect", "Prefect")]
            framework = "Python" + (fws.first { t.lowercased().contains($0.0) }.map { " · \($0.1)" } ?? "")
        } else if has("Package.swift") {
            language = "Swift"; framework = "Swift Package"
        } else if (try? fm.contentsOfDirectory(atPath: url.path))?.contains(where: { $0.hasSuffix(".xcodeproj") }) == true {
            language = "Swift"; framework = "Xcode project"
        } else if has("Cargo.toml") {
            language = "Rust"; framework = "Cargo"
        } else if has("Gemfile") {
            language = "Ruby"; framework = read("Gemfile").contains("rails") ? "Rails · Ruby" : "Ruby"
        } else if has("pom.xml") || has("build.gradle") || has("build.gradle.kts") {
            language = "Java/Kotlin"; framework = has("pom.xml") ? "Maven" : "Gradle"
        } else if has(".zshrc") || has("Brewfile") {
            language = "Shell"; framework = "zsh · Homebrew"
        }
        var branch = ""
        let head = (try? String(contentsOf: url.appendingPathComponent(".git/HEAD"), encoding: .utf8)) ?? ""
        if head.hasPrefix("ref: refs/heads/") { branch = String(head.dropFirst("ref: refs/heads/".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let isGit = has(".git")
        let hues = ProjectHue.allCases
        let hue = hues[abs(url.lastPathComponent.hashValue) % hues.count]
        let home = NSHomeDirectory()
        let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        return DetectedProject(name: url.lastPathComponent, path: path, language: language, framework: framework, isGitRepo: isGit, branch: isGit ? (branch.isEmpty ? "detached" : branch) : "", hue: hue)
    }

    @discardableResult
    func addProject(_ d: DetectedProject, pinned: Bool, preset: BuiltinPreset, hosts: Set<ResourceID>, databases: Set<ResourceID>, docker: Set<ResourceID>) -> Project {
        var id = d.name.lowercased().replacingOccurrences(of: " ", with: "-")
        while project(id) != nil { id += "-\(Int.random(in: 2...99))" }
        let p = Project(id: id, name: d.name, path: d.path, language: d.language, framework: d.framework, hue: d.hue,
                        isPinned: pinned, lastOpened: Date(), defaultPreset: preset.rawValue)
        library.projects.append(p)
        hosts.forEach { library.links.link(id, $0, kind: .host) }
        databases.forEach { library.links.link(id, $0, kind: .database) }
        docker.forEach { library.links.link(id, $0, kind: .docker) }
        library.hasOnboarded = true
        refreshGit(id)
        // A folder that already carries Brix settings brings its connections and layout along.
        if !loadProjectFile(id, announce: false) {
            toast(.success, "Added \(p.name)", detail: p.framework)
        }
        Task { await discoverSubProjects(id) }
        return self.project(id) ?? p
    }

    /// Finds git repositories inside a project's folder (a monorepo's frontend,
    /// backend…) and adds each as a project nested under it. They don't write
    /// brix.json unless turned on, so nothing appears in those repos unasked.
    func discoverSubProjects(_ id: ProjectID) async {
        guard let parent = project(id), parent.parentID == nil, !parent.isSample else { return }
        let root = parent.url
        let found: [DetectedProject] = await Task.detached(priority: .utility) {
            ProjectScan.scan(root).subProjects.filter(\.isGitRepo).map { AppStore.detect(url: root.appendingPathComponent($0.path)) }
        }.value
        let known = Set(library.projects.map { ($0.expandedPath as NSString).standardizingPath }).union(library.dismissedRepos)
        let hues = ProjectHue.allCases
        var added: [String] = []
        for (i, d) in found.enumerated() where !known.contains(((d.path as NSString).expandingTildeInPath as NSString).standardizingPath) {
            var cid = "\(parent.id)-\(d.name.lowercased().replacingOccurrences(of: " ", with: "-"))"
            while project(cid) != nil { cid += "-\(Int.random(in: 2...99))" }
            var p = Project(id: cid, name: d.name, path: d.path, language: d.language, framework: d.framework,
                            hue: hues[(hues.firstIndex(of: parent.hue).map { $0 + i + 1 } ?? i) % hues.count],
                            isPinned: false, lastOpened: parent.lastOpened, defaultPreset: parent.defaultPreset)
            p.parentID = parent.id
            p.syncsSettingsFile = false
            library.projects.append(p)
            refreshGit(cid)
            added.append(d.name)
        }
        if !added.isEmpty {
            toast(.info, "\(parent.name) holds \(added.count) repositor\(added.count == 1 ? "y" : "ies")", detail: added.joined(separator: ", "))
        }
    }

    /// "platform › frontend" for a repository inside a project, else the name.
    func fullName(_ p: Project) -> String {
        p.parentID.flatMap(project).map { "\($0.name) › \(p.name)" } ?? p.name
    }

    func children(of id: ProjectID) -> [Project] {
        library.projects.filter { $0.parentID == id }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func updateProject(_ p: Project) {
        guard let i = library.projects.firstIndex(where: { $0.id == p.id }) else { return }
        library.projects[i] = p
    }

    func togglePin(_ id: ProjectID) {
        guard let i = library.projects.firstIndex(where: { $0.id == id }) else { return }
        library.projects[i].isPinned.toggle()
        toast(.info, library.projects[i].isPinned ? "Pinned \(library.projects[i].name)" : "Unpinned \(library.projects[i].name)")
    }

    func requestRemoveProject(_ id: ProjectID) {
        guard let p = project(id) else { return }
        confirm("Remove \(p.name)?", "Brix forgets the project, its layout and links. Files on disk are not touched.", confirm: "Remove") { [weak self] in
            self?.removeProject(id)
        }
    }

    func removeProject(_ id: ProjectID) {
        guard let p = project(id) else { return }
        // Its nested repositories go with it; one removed on its own stays removed.
        for c in library.projects where c.parentID == id { removeProject(c.id) }
        if p.parentID != nil, project(p.parentID!) != nil { library.dismissedRepos.insert((p.expandedPath as NSString).standardizingPath) }
        closeProject(id)
        for s in sessions where s.projectID == id { closeSession(s.id, confirmRunning: false) }
        library.projects.removeAll { $0.id == id }
        library.links.removeProject(id)
        library.recentFiles.removeAll { $0.project == id }
        workspaces[id] = nil
        git[id] = nil
        persistence.delete("workspaces/\(id).json")
        if route.projectID == id { route = .projects }
        toast(.info, "Removed \(p.name)")
    }

    // MARK: Links

    func setLink(_ project: ProjectID, _ resource: ResourceID, kind: ResourceKind, linked: Bool) {
        if kind == .docker, linked, !library.docker.contains(where: { $0.id == resource }),
           let found = discoveredDocker.first(where: { $0.id == resource }) {
            library.docker.append(found)
        }
        library.links.set(project, resource, kind: kind, linked: linked)
    }

    // MARK: Hosts

    func saveHost(_ h: SSHHost, password: String?) {
        if let password, !password.isEmpty {
            do { try keychain.set(password, for: Keychain.hostAccount(h.id)) } catch {
                toast(.error, "Couldn't save password to the Keychain", detail: error.localizedDescription)
                return
            }
        }
        if let i = library.hosts.firstIndex(where: { $0.id == h.id }) {
            library.hosts[i] = h
            toast(.success, "Saved \(h.name)")
        } else {
            library.hosts.append(h)
            hostStatus[h.id] = .disconnected
            toast(.success, "Added \(h.name)", detail: h.address)
        }
    }

    func duplicateHost(_ id: ResourceID) {
        guard var h = host(id) else { return }
        h.id = UUID().uuidString
        h.name += " copy"
        h.isSample = false
        library.hosts.append(h)
        hostStatus[h.id] = .disconnected
        selectedHost = h.id
        toast(.success, "Duplicated \(h.name)")
    }

    func requestRemoveHost(_ id: ResourceID) {
        guard let h = host(id) else { return }
        let used = library.links.projects(for: id).count
        confirm("Remove \(h.name)?", used > 0 ? "It is linked to \(used) project\(used == 1 ? "" : "s"). Links and its Keychain password are removed too." : "Its Keychain password is removed too.", confirm: "Remove") { [weak self] in
            guard let self else { return }
            library.hosts.removeAll { $0.id == id }
            library.links.removeResource(id)
            do { try keychain.delete(Keychain.hostAccount(id)) } catch { toast(.error, "Couldn't remove the Keychain password", detail: error.localizedDescription) }
            hostStatus[id] = nil
            if selectedHost == id { selectedHost = library.hosts.first?.id }
            toast(.info, "Removed \(h.name)")
        }
    }

    func hostPassword(_ h: SSHHost) -> String? {
        h.auth == .password ? (try? keychain.get(Keychain.hostAccount(h.id))) ?? nil : nil
    }

    /// Connect: tests reachability, then opens a server shell. Production asks first.
    func connect(_ id: ResourceID, openShell: Bool = true, project: ProjectID? = nil) {
        guard let h = host(id) else { return }
        guardProduction(h.tag, name: h.name, verb: "Connect to") { [weak self] in
            self?.performConnect(h, openShell: openShell, project: project)
        }
    }

    private func performConnect(_ h: SSHHost, openShell: Bool, project: ProjectID?) {
        hostStatus[h.id] = .connecting
        Task {
            do {
                if h.isSample {
                    try await svc(h).ssh.connect(h)
                } else {
                    try await svc(h).ssh.connect(h)
                }
                hostStatus[h.id] = .connected
                if let i = library.hosts.firstIndex(where: { $0.id == h.id }) { library.hosts[i].lastConnected = Date() }
                if openShell { openServerShell(h.id, project: project) }
                if h.isSample { toast(.success, "Connected to \(h.name)", detail: h.address) }
                if let m = try? await svc(h).metrics.metrics(h) {
                    hostMetrics[h.id] = m
                    rememberOS(h.id, m.os)
                }
            } catch {
                hostStatus[h.id] = .error(error.localizedDescription.contains("timed out") ? "timeout" : "failed")
                toast(.error, "Couldn't connect to \(h.name)", detail: error.localizedDescription)
            }
        }
    }

    /// Keeps the operating system a host reported, for its icon.
    func rememberOS(_ id: ResourceID, _ os: String) {
        let clean = os.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = library.hosts.firstIndex(where: { $0.id == id }), library.hosts[i].os != clean else { return }
        library.hosts[i].os = clean
    }

    func disconnect(_ id: ResourceID) {
        for s in sessions where s.hostID == id { closeSession(s.id, confirmRunning: false) }
        hostStatus[id] = .disconnected
        if let h = host(id) { toast(.info, "Disconnected \(h.name)") }
    }

    func copyToPasteboard(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast(.success, "Copied \(label)")
    }

    // MARK: Databases

    func saveDatabase(_ d: DatabaseConnection, password: String?) {
        if let password, !password.isEmpty {
            do { try keychain.set(password, for: Keychain.dbAccount(d.id)) } catch {
                toast(.error, "Couldn't save password to the Keychain", detail: error.localizedDescription)
                return
            }
        }
        // Host or database may have changed: the tree is read again.
        schemaCache[d.id] = nil
        if let i = library.databases.firstIndex(where: { $0.id == d.id }) {
            library.databases[i] = d
            toast(.success, "Saved \(d.name)")
        } else {
            library.databases.append(d)
            dbStatus[d.id] = .disconnected
            toast(.success, "Added \(d.name)", detail: d.endpoint)
        }
    }

    func duplicateDatabase(_ id: ResourceID) {
        guard var d = database(id) else { return }
        d.id = UUID().uuidString
        d.name += "_copy"
        d.isSample = false
        library.databases.append(d)
        selectedDatabase = d.id
        toast(.success, "Duplicated \(d.name)")
    }

    func requestRemoveDatabase(_ id: ResourceID) {
        guard let d = database(id) else { return }
        confirm("Delete \(d.name)?", "Removes the saved connection, its links and Keychain password. The database itself is not touched.", confirm: "Delete") { [weak self] in
            guard let self else { return }
            library.databases.removeAll { $0.id == id }
            library.links.removeResource(id)
            do { try keychain.delete(Keychain.dbAccount(id)) } catch { toast(.error, "Couldn't remove the Keychain password", detail: error.localizedDescription) }
            dbStatus[id] = nil
            if selectedDatabase == id { selectedDatabase = library.databases.first?.id }
            toast(.info, "Deleted \(d.name)")
        }
    }

    func dbPassword(_ d: DatabaseConnection) -> String? {
        (try? keychain.get(Keychain.dbAccount(d.id))) ?? nil
    }

    func testDatabase(_ d: DatabaseConnection, password: String? = nil) async -> Result<DBTestResult, ServiceError> {
        dbStatus[d.id] = .connecting
        do {
            let r = try await svc(d).db.test(d, password: password ?? dbPassword(d))
            if library.databases.contains(where: { $0.id == d.id }) { dbStatus[d.id] = .connected }
            if let i = library.databases.firstIndex(where: { $0.id == d.id }) {
                library.databases[i].lastUsed = Date()
                if library.databases[i].serverVersion != r.version { library.databases[i].serverVersion = r.version }
            }
            return .success(r)
        } catch {
            let msg = (error as? ServiceError)?.message ?? error.localizedDescription
            if library.databases.contains(where: { $0.id == d.id }) {
                dbStatus[d.id] = .error(msg.lowercased().contains("timeout") ? "timeout" : "failed")
            }
            return .failure(ServiceError(msg))
        }
    }

    /// Databases on the server (after connecting), for the form's Database menu.
    func listDatabases(_ d: DatabaseConnection, password: String?) async -> [String] {
        let sql: String
        switch d.kind {
        case .postgres: sql = "select datname from pg_database where datallowconn and not datistemplate order by 1"
        case .mysql: sql = "show databases"
        case .sqlite: return []
        }
        var probe = d
        probe.readOnly = true
        guard let r = try? await svc(probe).db.execute(probe, sql: sql, password: password) else { return [] }
        let hidden: Set<String> = d.kind == .mysql ? ["information_schema", "mysql", "performance_schema", "sys"] : []
        return r.rows.compactMap { $0.first ?? nil }.filter { !hidden.contains($0) }
    }

    /// Tables on the connection, for the live status pill.
    func tableCount(_ d: DatabaseConnection, password: String?) async -> Int? {
        guard let tree = try? await svc(d).db.schema(d, password: password) else { return nil }
        return tree.schemas.values.reduce(0) { $0 + $1.filter { $0.kind == .table }.count }
    }

    /// SQL that changes data or schema.
    nonisolated static func isWrite(_ sql: String) -> Bool {
        let stripped = sql.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.joined(separator: " ").lowercased()
        let words = ["insert", "update", "delete", "drop", "alter", "truncate", "create", "grant", "revoke", "replace", "merge", "vacuum", "reindex"]
        return words.contains { w in stripped.range(of: "\\b\(w)\\b", options: .regularExpression) != nil }
    }

    /// Runs a query. Writes against read-only or production databases need an
    /// explicit confirmation first.
    func runQuery(_ sql: String, on d: DatabaseConnection, completion: @escaping (Result<QueryResult, ServiceError>) -> Void) {
        let run: (DatabaseConnection) -> Void = { [weak self] conn in
            guard let self else { return }
            Task {
                do {
                    let r = try await self.svc(conn).db.execute(conn, sql: sql, password: self.dbPassword(conn))
                    self.library.queryHistory.insert(QueryHistoryEntry(sql: sql, connectionID: conn.id, ranAt: Date(), rows: r.totalRows, ms: r.elapsedMs), at: 0)
                    self.trimHistory()
                    self.dbStatus[conn.id] = .connected
                    completion(.success(r))
                } catch {
                    let msg = (error as? ServiceError)?.message ?? error.localizedDescription
                    self.library.queryHistory.insert(QueryHistoryEntry(sql: sql, connectionID: conn.id, ranAt: Date(), rows: 0, ms: 0, error: msg.components(separatedBy: "\n").first), at: 0)
                    self.trimHistory()
                    completion(.failure(ServiceError(msg)))
                }
            }
        }
        if Self.isWrite(sql), d.effectiveReadOnly {
            let unlock = {
                var unlocked = d
                unlocked.writeUnlocked = true
                run(unlocked)
            }
            let cancel = { completion(.failure(ServiceError("Cancelled. \(d.name) is read-only."))) }
            if d.tag.isProduction {
                // Production: type the database name to write.
                confirmation = Confirmation(title: "Write to Production?", message: "\(d.name) is a Production database. This statement changes data.",
                                            confirmTitle: "Run write", typeToConfirm: d.database.isEmpty ? d.name : d.database, action: unlock, onCancel: cancel)
            } else {
                confirm("Write to \(d.name)?", "\(d.name) is read-only. This statement changes data. Run it anyway?", confirm: "Run write", destructive: true,
                        onCancel: cancel, action: unlock)
            }
        } else {
            run(d)
        }
    }

    private func trimHistory() {
        if library.queryHistory.count > 200 { library.queryHistory.removeLast(library.queryHistory.count - 200) }
    }

    // MARK: Docker

    func refreshDocker() async {
        let liveHosts = library.hosts.filter { !$0.isSample && hostStatus[$0.id] == .connected }
        var merged: [DockerTarget] = []
        if library.docker.contains(where: \.isSample) {
            merged += (try? await services.mock.docker.list(hosts: [])) ?? []
        }
        do {
            merged += try await services.live.docker.list(hosts: liveHosts)
            dockerError = nil
        } catch {
            dockerError = error.localizedDescription
        }
        discoveredDocker = merged
        // Saved targets pick up the latest runtime state.
        for (i, t) in library.docker.enumerated() {
            if let fresh = merged.first(where: { $0.id == t.id }) {
                library.docker[i].state = fresh.state
                library.docker[i].startedAt = fresh.startedAt
                library.docker[i].statusText = fresh.statusText
            }
        }
    }

    func dockerAction(_ action: DockerAction, _ id: ResourceID) {
        guard let c = dockerTarget(id) else { return }
        let host = c.hostID.flatMap(self.host)
        let go = { [weak self] in
            guard let self else { return }
            dockerBusy.insert(id)
            let progress = toast(.progress, "\(action.rawValue.capitalized)ing \(c.name)…")
            Task {
                do {
                    let svc = c.isSample ? self.services.mock.docker : self.services.live.docker
                    let updated = try await svc.perform(action, on: c, host: host)
                    if let i = self.library.docker.firstIndex(where: { $0.id == id }) { self.library.docker[i] = updated.withSample(c.isSample) }
                    if let i = self.discoveredDocker.firstIndex(where: { $0.id == id }) { self.discoveredDocker[i] = updated.withSample(c.isSample) }
                    self.finish(progress, .success, "\(c.name) \(action == .stop ? "stopped" : (action == .start ? "started" : "restarted"))")
                } catch {
                    self.finish(progress, .error, "Couldn't \(action.rawValue) \(c.name)", detail: error.localizedDescription)
                }
                self.dockerBusy.remove(id)
            }
        }
        if let host, host.tag.isProduction {
            guardProduction(host.tag, name: c.name, verb: action.rawValue.capitalized, action: go)
        } else {
            go()
        }
    }

    func addDockerTarget(_ t: DockerTarget, project: ProjectID?) {
        if !library.docker.contains(where: { $0.id == t.id }) { library.docker.append(t) }
        if let project { library.links.link(project, t.id, kind: .docker) }
        toast(.success, "Saved \(t.name)")
    }
}

extension DockerTarget {
    func withSample(_ s: Bool) -> DockerTarget { var c = self; c.isSample = s; return c }
}

extension AppStore {
    /// Times a TCP connection to each server's SSH port, all at once.
    func ping(_ ids: [ResourceID]) {
        for id in ids where !pinging.contains(id) {
            guard let h = host(id) else { continue }
            pinging.insert(id)
            Task {
                let r = h.isSample ? PingResult(ms: Double.random(in: 18...140), at: Date()) : await HostPing.ping(host: h.host, port: h.port)
                hostPing[id] = r
                pinging.remove(id)
            }
        }
    }
}
