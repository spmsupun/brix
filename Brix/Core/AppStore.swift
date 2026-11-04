import SwiftUI
import Observation

@MainActor
@Observable
final class AppStore {
    let services: Services
    let persistence: Persistence
    let keychain: Keychain

    var library = Library() { didSet { scheduleSave() } }
    var settings = AppSettings() {
        didSet {
            scheduleSave()
            if settings.appearance != oldValue.appearance || settings.density != oldValue.density
                || settings.uiFont != oldValue.uiFont || settings.codeFont != oldValue.codeFont { applyAppearance() }
        }
    }

    var route: Route = .overview
    var workspaces: [ProjectID: WorkspaceStore] = [:]

    // Runtime state
    var git: [ProjectID: GitRepoState] = [:]
    var gitBusy: Set<String> = []
    var hostStatus: [ResourceID: ConnectionStatus] = [:]
    var hostMetrics: [ResourceID: HostMetrics] = [:]
    /// Last reachability check per server, and the ones being checked now.
    var hostPing: [ResourceID: PingResult] = [:]
    var pinging: Set<ResourceID> = []
    /// One-off health reads (CPU, memory, disk) without opening a shell.
    var healthChecking: Set<ResourceID> = []
    var healthError: [ResourceID: String] = [:]
    var healthAt: [ResourceID: Date] = [:]
    var dbStatus: [ResourceID: ConnectionStatus] = [:]
    var discoveredDocker: [DockerTarget] = []
    var dockerBusy: Set<ResourceID> = []
    var dockerError: String?
    var sessions: [TerminalSession] = []
    /// When each agent's current turn started (agent time).
    var runningSince: [String: Date] = [:]
    /// Run tasks in flight, by session id.
    var runningTasks: [String: (task: RunTask, project: ProjectID, started: Date)] = [:]
    /// brix-db session tokens → Brix session ids.
    @ObservationIgnored var gatewaySessions: [String: String] = [:]
    /// GitHub pull requests and pipelines per project.
    var github: [ProjectID: GitHubState] = [:]
    /// A refresh that failed while older data is still shown.
    var githubErrors: [ProjectID: GitHubState] = [:]
    @ObservationIgnored var githubChecked: [ProjectID: Date] = [:]
    @ObservationIgnored var githubTask: Task<Void, Never>?
    /// Project overview data kept between visits, so returning is instant.
    @ObservationIgnored var homeCache: [ProjectID: ProjectHomeData] = [:]
    /// Section Project Settings opens on next (then cleared).
    var projectSettingsSection: String?
    /// A Brix window is on screen; animations pause when none is.
    var windowVisible = true
    /// Development aid: forces the buddy's mood in snapshots.
    var moodPreview: BuddyMood?
    /// Last successful build or push (the buddy's shipped mood).
    var lastShipped: Date?
    /// Today's git totals per project (receipt), refreshed with git.
    var dayStats: [ProjectID: DayStats] = [:]

    // UI state
    var toasts: [Toast] = []
    /// Confirmations in the order they were asked; the first is the one on screen.
    var confirmations: [Confirmation] = []
    /// Set for a moment after one closes, so the next presents once it has gone.
    private var confirmationGap: UUID?
    /// The confirmation on screen. Setting one queues it behind any already
    /// waiting; setting nil cancels the one showing.
    var confirmation: Confirmation? {
        get { confirmationGap == nil ? confirmations.first : nil }
        set {
            if let newValue { confirmations.append(newValue) } else if let c = confirmations.first { answerConfirmation(c.id, confirmed: false) }
        }
    }
    var sheet: ActiveSheet?
    /// The first-launch guide's current step; nil when it isn't showing.
    var guideStep: Int?
    var paletteOpen = false
    var paletteScopeToProject = false
    var inspector: InspectorSelection = .none
    var selectedHost: ResourceID?
    var selectedDatabase: ResourceID?
    var selectedProjectInList: ProjectID?
    var pendingQuery: (connection: ResourceID, sql: String)?
    var focusedSessionID: String?
    /// Sessions drawn on screen right now (any panel, card or pane), by count.
    @ObservationIgnored var onScreen: [String: Int] = [:]
    var popover: PopoverRequest?
    /// Tabs on the global Terminals screen.
    var terminalTree = PaneTree()
    /// Schemas loaded by the database browser, used by ⌘K.
    var schemaCache: [ResourceID: DBSchemaTree] = [:]
    /// The Databases screen: tabs, consoles and staged edits.
    @ObservationIgnored let dataWorkspace = DataWorkspace()
    var draggingPanel: String?
    /// "layout" or "agents" on the Customize screen.
    var customizeTab = "layout"
    /// Resolved executable per agent id; nil when not installed.
    var agentPaths: [String: String] = [:]
    var agentUsage: [String: [UsageWindow]] = [:]
    /// Where the agent picked in ChooseAgentSheet goes; nil means the agent grid.
    var agentCompletion: ((TerminalSession) -> Void)?
    /// Last write error per project for `brix.json`.
    var projectFileErrors: [ProjectID: String] = [:]
    /// Projects whose brix.json connections are waiting on the user's answer.
    @ObservationIgnored var projectFilesAsking: Set<ProjectID> = []
    /// Global terminals from last run have been restarted (saving waits for that).
    var globalRestored = false
    /// Production sessions from last run not reopened at launch; kept in the saved list.
    @ObservationIgnored var heldGlobalSessions: [SessionDescriptor] = []
    /// Tests and previews never start real processes on load.
    var restoreDisabled = false
    /// Keep projects' brix.json up to date. Off in Brix Dev, which works in the
    /// same repositories as the installed Brix.
    @ObservationIgnored var writesProjectFiles = !Persistence.isDevBuild
    /// Window is narrower than Metrics.autoRailWidth.
    var windowNarrow = false
    /// User expanded the sidebar while the window is narrow.
    var sidebarForcedFull = false
    /// Docker stacks, networks, volumes and images per engine ("local", "sample" or a host id).
    var dockerInventory: [String: DockerInventory] = [:]
    var dockerInventoryError: String?
    /// Containers, stacks, networks, volumes or images on the Docker screen.
    var dockerTab = "containers"
    var dockerSelection: DockerSelection?
    /// Last folder shown in each host's file explorer.
    var remoteFilesPath: [ResourceID: String] = [:]
    /// Each SSH host's last listing in the file browser, so switching away and back
    /// shows it straight away instead of loading again.
    /// Agents restored at launch that are still reloading their conversation. A resumed
    /// agent looks busy, then idle, which isn't new work: no Done badge or notice for it.
    @ObservationIgnored var resuming: Set<String> = []
    @ObservationIgnored var remoteFilesListing: [ResourceID: (path: String, entries: [RemoteEntry], history: [String], at: Date)] = [:]
    /// Development aid: shows a tab drag frozen over a pane (snapshot checks).
    var tileDragPreview: (tab: String, target: PaneDropTarget, at: CGPoint)?
    /// The docker CLI is on this Mac (checked at launch and on refresh).
    var dockerInstalled = ProcessRunner.which("docker") != nil
    /// Show Docker in navigation: installed here, or targets already saved.
    var dockerVisible: Bool { dockerInstalled || !library.docker.isEmpty }
    /// Databases with a dump or restore running.
    var dbBusy: Set<ResourceID> = []

    private var saveTask: Task<Void, Never>?
    private var loaded = false
    /// Set while the saved library couldn't be read (or only partly); library.json
    /// isn't written until the user chooses to save over it. The status bar shows it.
    private(set) var saveBlocked = false
    /// Why, for the status bar and the question on quit.
    @ObservationIgnored private(set) var saveBlockedReason = ""
    /// Asks whether to save over library.json; nil when there's nothing to offer.
    @ObservationIgnored private var saveBlockedAsk: (() -> UUID)?
    @ObservationIgnored private var saveBlockedAskID: UUID?
    var canUnblockSave: Bool { saveBlockedAsk != nil }
    /// Set when settings.json couldn't be read or kept aside; it isn't overwritten this run.
    private var settingsSaveBlocked = false
    var gitErrors: [ProjectID: String] = [:]
    /// Git status reads in flight, and those asked for again meanwhile.
    @ObservationIgnored var gitRefreshing: Set<ProjectID> = []
    @ObservationIgnored var gitRefreshAgain: Set<ProjectID> = []
    private var timers: [Task<Void, Never>] = []

    init(services: Services = Services(), persistence: Persistence = .standard, keychain: Keychain = .standard, loadFromDisk: Bool = true) {
        self.services = services
        self.persistence = persistence
        self.keychain = keychain
        wireLiveServices()
        if loadFromDisk { load() }
        loaded = true
    }

    // MARK: Persistence

    func load() {
        do {
            if let lib = try persistence.load(Library.self, from: "library.json") {
                library = lib
                let n = lib.skippedOnLoad, newer = lib.schemaVersion > Library.currentSchema
                if n > 0 || newer {
                    // The next save leaves out what this build couldn't read (or doesn't
                    // know, for a newer Brix's file) for good, so keep the file as it was.
                    let kept = keepCopy(of: "library.json", as: "library.partial-")
                    if n > 0 {
                        toast(.error, "Left out \(n) saved item\(n == 1 ? "" : "s") Brix couldn't read",
                              detail: kept.map { "The library as it was is kept as \($0) in Brix's folder." } ?? "Brix couldn't keep a copy of the file as it was.")
                    }
                    // Without a copy, or with a newer Brix's file, nothing is saved over it unasked.
                    if kept == nil || newer {
                        saveBlocked = true
                        let why = newer ? "Your library was saved by a newer Brix; saving here drops what this version doesn't know."
                                        : "Brix left out \(n) item\(n == 1 ? "" : "s") it couldn't read and couldn't keep a copy of the file."
                        saveBlockedReason = why
                        saveBlockedAsk = { [weak self] in
                            self?.confirm("Save your library with this version?", "\(why)\(kept.map { " A copy is kept as \($0)." } ?? "") Until you choose, Brix doesn't save over library.json.",
                                          confirm: "Save Here", destructive: true,
                                          onCancel: { [weak self] in
                                              self?.toast(.info, "Your library isn't saved this run", detail: "library.json is left as it is.")
                                          }) { [weak self] in self?.unblockSave() } ?? UUID()
                        }
                        reviewLibrarySave()
                    }
                }
            }
        } catch {
            // Keep the unreadable file for recovery, and save nothing over it until the user chooses.
            saveBlocked = true
            saveBlockedReason = "Brix couldn't read your saved library (\(error.localizedDescription))."
            if let backup = keepCopy(of: "library.json", as: "library.unreadable-") {
                saveBlockedAsk = { [weak self] in
                    self?.confirm("Start with an empty library?",
                                  "Brix couldn't read your saved library (\(error.localizedDescription)). A copy is kept as \(backup) and offered back when Brix can read it. Until you choose, Brix doesn't save over the file.",
                                  confirm: "Start Empty", destructive: true,
                                  onCancel: { [weak self] in
                                      self?.toast(.info, "Your library isn't saved this run", detail: "library.json is left as it is. Quit Brix to restore or fix it.")
                                  }) { [weak self] in self?.unblockSave() } ?? UUID()
                }
                reviewLibrarySave()
            } else {
                saveBlockedReason += " It couldn't be backed up either, so it's left as it is until you restart."
                toast(.error, "Couldn't read or back up your saved library", detail: "Brix won't save your library until you restart. \(error.localizedDescription)")
            }
        }
        do {
            if let s = try persistence.load(AppSettings.self, from: "settings.json") {
                settings = s
                // The next save leaves out the agents this build couldn't read, so keep the file as it was.
                if s.skippedOnLoad > 0 {
                    let kept = keepCopy(of: "settings.json", as: "settings.partial-")
                    settingsSaveBlocked = kept == nil
                    toast(.error, "Left out \(s.skippedOnLoad) agent\(s.skippedOnLoad == 1 ? "" : "s") Brix couldn't read from settings",
                          detail: kept.map { "The settings as they were are kept as \($0) in Brix's folder." } ?? "Brix couldn't keep a copy, so settings aren't saved this run.")
                }
            }
        } catch {
            // Defaults from here on; the file is kept aside first, or left alone.
            let kept = keepCopy(of: "settings.json", as: "settings.unreadable-")
            settingsSaveBlocked = kept == nil
            toast(.error, "Couldn't read settings", detail: (kept.map { "Using defaults. The old file is kept as \($0). " } ?? "Using defaults; settings aren't saved this run. ") + error.localizedDescription)
        }
        bootstrapRuntime()
    }

    /// The status bar's "Not saving" chip: asks again (unless already asking), or says why.
    func reviewLibrarySave() {
        guard saveBlocked else { return }
        guard let ask = saveBlockedAsk else { toast(.error, "Brix isn't saving your library", detail: saveBlockedReason); return }
        if let id = saveBlockedAskID, confirmations.contains(where: { $0.id == id }) { return }
        saveBlockedAskID = ask()
    }

    /// The user chose to save over library.json.
    func unblockSave() {
        saveBlocked = false
        saveBlockedAsk = nil
        scheduleSave()
    }

    /// Copies a data file aside before it's replaced and returns the copy's name.
    /// A copy with the same contents is reused, so each failed launch doesn't add another.
    func keepCopy(of name: String, as prefix: String) -> String? {
        guard let data = try? Data(contentsOf: persistence.url(name)) else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: persistence.directory.path)) ?? []
        if let same = names.first(where: { $0.hasPrefix(prefix) && (try? Data(contentsOf: persistence.url($0))) == data }) { return same }
        let copy = "\(prefix)\(Int(Date().timeIntervalSince1970)).json"
        do { try data.write(to: persistence.url(copy), options: .withoutOverwriting) } catch { return nil }
        return copy
    }

    /// Debounced save so rapid edits (resizes, typing) don't thrash the disk.
    func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        // Each file on its own, so one that fails doesn't stop the rest.
        var failed: [String] = []
        if !saveBlocked {
            var lib = library
            lib.schemaVersion = Library.currentSchema
            if globalRestored {
                lib.globalSessions = sessions.filter { $0.projectID == nil && $0.isLive && $0.state != .finished && $0.state != .failed }.map(SessionDescriptor.init)
                    + heldGlobalSessions
                var tree = terminalTree
                tree.retain(Set(lib.globalSessions.map(\.id)))
                lib.globalTree = tree
            }
            do { try persistence.save(lib, to: "library.json") } catch { failed.append("library.json: \(error.localizedDescription)") }
        }
        if !settingsSaveBlocked {
            do { try persistence.save(settings, to: "settings.json") } catch { failed.append("settings.json: \(error.localizedDescription)") }
        }
        for ws in workspaces.values {
            do { try ws.save() } catch { failed.append("\(project(ws.projectID)?.name ?? ws.projectID) layout: \(error.localizedDescription)") }
        }
        if !failed.isEmpty { toast(.error, "Couldn't save", detail: failed.joined(separator: "\n")) }
        writeProjectFiles()
    }

    /// Theme and density are process-wide: AppKit menus and sheets follow
    /// NSApp.appearance, and every `Typo` font reads UIScale.
    func applyAppearance() {
        NSApp?.appearance = settings.appearance.nsAppearance
        UIScale.shared.bump = settings.density.textBump
        UIScale.shared.design = settings.uiFont.design
        UIScale.shared.family = settings.uiFont.family
        UIScale.shared.codeFamily = settings.codeFont
        TerminalRegistry.shared.applyTheme(fontSize: settings.terminalFontSize, accent: settings.accent)
    }

    func bootstrapRuntime() {
        applyAppearance()
        refreshAgentPaths()
        sessions.removeAll { $0.isSampleSession }
        if library.projects.contains(where: \.isSample) {
            sessions += MockData.sessions.map { var s = $0; s.isSampleSession = true; return s }
            for (k, v) in MockData.hostStatus where library.hosts.contains(where: { $0.id == k }) { hostStatus[k] = v }
            for (k, v) in MockData.dbStatus where library.databases.contains(where: { $0.id == k }) { dbStatus[k] = v }
            for (k, v) in MockData.metrics where library.hosts.contains(where: { $0.id == k }) { hostMetrics[k] = v }
        }
        for p in library.projects { refreshGit(p.id) }
        // Repositories added inside existing projects since last time.
        if !restoreDisabled {
            Task { for p in library.projects where p.parentID == nil && !p.isSample { await discoverSubProjects(p.id) } }
        }
        startTimers()
        WindowVisibility.shared.start { [weak self] v in self?.windowVisible = v }
        if !restoreDisabled { startGitHubPolling() }
        AgentDBGateway.shared.start(store: self)
        if !restoreDisabled { Task { @MainActor [weak self] in try? await Task.sleep(nanoseconds: 1_500_000_000); self?.offerRecovery(); self?.offerDevCopy() } }
        updateDockBadge()
    }

    func loadSampleWorkspace() {
        guard !library.projects.contains(where: \.isSample) else { return }
        let sample = Library.sample
        // Merge so anything the user already added is kept. A sample entry whose id
        // a real one already has is left out, and never linked to the real one.
        var lib = library
        let projects = sample.projects.filter { p in !lib.projects.contains { $0.id == p.id } }
        let hosts = sample.hosts.filter { h in !lib.hosts.contains { $0.id == h.id } }
        let dbs = sample.databases.filter { d in !lib.databases.contains { $0.id == d.id } }
        let docker = sample.docker.filter { c in !lib.docker.contains { $0.id == c.id } }
        lib.projects += projects
        lib.hosts += hosts
        lib.databases += dbs
        lib.docker += docker
        let added = Set(projects.map(\.id)), addedResources = Set(hosts.map(\.id) + dbs.map(\.id) + docker.map(\.id))
        lib.links.pairs.formUnion(sample.links.pairs.filter { added.contains($0.project) && addedResources.contains($0.resource) })
        lib.recentFiles += sample.recentFiles.filter { added.contains($0.project) }
        lib.queryHistory += sample.queryHistory.filter { q in dbs.contains { $0.id == q.connectionID } }
        lib.hasOnboarded = true
        if lib.openProjects.isEmpty { lib.openProjects = sample.openProjects.filter(added.contains) }
        library = lib
        if let mock = services.mock.git as? MockGitService { mock.states = MockData.git }
        bootstrapRuntime()
        let count = { (n: Int, what: String) in "\(n) \(what)\(n == 1 ? "" : "s")" }
        toast(.success, "Sample workspace loaded", detail: "\(count(projects.count, "project")), \(count(hosts.count, "host")), \(count(dbs.count, "database"))")
    }

    func removeSampleWorkspace() {
        let projectIDs = Set(library.projects.filter(\.isSample).map(\.id))
        for id in projectIDs { closeProject(id) }
        library.projects.removeAll(where: \.isSample)
        let hostIDs = library.hosts.filter(\.isSample).map(\.id)
        let dbIDs = library.databases.filter(\.isSample).map(\.id)
        let dockerIDs = library.docker.filter(\.isSample).map(\.id)
        library.hosts.removeAll(where: \.isSample)
        library.databases.removeAll(where: \.isSample)
        library.docker.removeAll(where: \.isSample)
        for id in hostIDs + dbIDs + dockerIDs { library.links.removeResource(id) }
        for id in projectIDs { library.links.removeProject(id); persistence.delete("workspaces/\(id).json"); workspaces[id] = nil }
        library.recentFiles.removeAll { projectIDs.contains($0.project) }
        library.queryHistory.removeAll { dbIDs.contains($0.connectionID) }
        sessions.removeAll(where: \.isSampleSession)
        route = .overview
        toast(.info, "Sample workspace removed")
    }

    // MARK: Toasts and confirmations

    @discardableResult
    func toast(_ kind: Toast.Kind, _ title: String, detail: String? = nil, session: String? = nil) -> UUID {
        let t = Toast(kind: kind, title: title, detail: detail, sessionID: session)
        toasts.append(t)
        if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
        if kind != .progress {
            let id = t.id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: kind == .error ? 6_000_000_000 : 3_500_000_000)
                self?.toasts.removeAll { $0.id == id }
            }
        }
        return t.id
    }

    func dismissToast(_ id: UUID) { toasts.removeAll { $0.id == id } }

    /// Replaces a progress toast with its outcome.
    func finish(_ id: UUID, _ kind: Toast.Kind, _ title: String, detail: String? = nil) {
        dismissToast(id)
        toast(kind, title, detail: detail)
    }

    /// Asks after any confirmation already showing or waiting, never in place of it.
    @discardableResult
    func confirm(_ title: String, _ message: String, confirm: String, destructive: Bool = true, onCancel: (() -> Void)? = nil, action: @escaping () -> Void) -> UUID {
        let c = Confirmation(title: title, message: message, confirmTitle: confirm, destructive: destructive, action: action, onCancel: onCancel)
        confirmations.append(c)
        return c.id
    }

    /// Closes a confirmation and runs its action, or its onCancel for anything
    /// but a yes (a Cancel button, Esc, a dismissed alert). Each runs once: a
    /// confirmation already answered is ignored. The next one then shows.
    func answerConfirmation(_ id: UUID, confirmed: Bool) {
        guard let i = confirmations.firstIndex(where: { $0.id == id }) else { return }
        let c = confirmations.remove(at: i)
        if i == 0, !confirmations.isEmpty {
            let gap = UUID()
            confirmationGap = gap
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                if self?.confirmationGap == gap { self?.confirmationGap = nil }
            }
        }
        if confirmed { c.action() } else { c.onCancel?() }
    }

    /// Runs `action` directly for non-production resources; asks first otherwise.
    func guardProduction(_ tag: EnvTag, name: String, verb: String, action: @escaping () -> Void) {
        if tag.isProduction {
            confirm("\(verb) \(name)?", "\(name) is tagged Production. Make sure this is what you want.", confirm: verb, destructive: false, action: action)
        } else {
            action()
        }
    }

    // MARK: Navigation

    func go(_ r: Route) {
        route = r
        switch r {
        case .workspace(let id):
            openProject(id)
        case .projects:
            if let id = selectedProjectInList { inspector = .project(id) }
        default:
            break
        }
    }

    var currentProjectID: ProjectID? { route.projectID }
    var currentProject: Project? { currentProjectID.flatMap(project) }
    var currentWorkspace: WorkspaceStore? { currentProjectID.flatMap { workspaces[$0] } }

    func openProject(_ id: ProjectID) {
        guard let p = project(id) else {
            toast(.error, "Project not found")
            return
        }
        if !library.openProjects.contains(id) { library.openProjects.append(id) }
        let ws = workspace(for: id)
        if let i = library.projects.firstIndex(where: { $0.id == id }) { library.projects[i].lastOpened = Date() }
        if route != .workspace(id) { route = .workspace(id) }
        ws.activate()
        if !p.isSample, !FileManager.default.fileExists(atPath: p.expandedPath) {
            toast(.error, "Folder is missing", detail: p.path)
        }
    }

    func closeProject(_ id: ProjectID) {
        do { try workspaces[id]?.save() } catch { toast(.error, "Couldn't save the layout", detail: error.localizedDescription) }
        library.openProjects.removeAll { $0 == id }
        if route.projectID == id { route = library.openProjects.last.map { .workspace($0) } ?? .projects }
    }

    func switchProject(_ offset: Int) {
        let open = library.openProjects
        guard !open.isEmpty else { return }
        let idx = currentProjectID.flatMap { open.firstIndex(of: $0) } ?? -1
        let next = (idx + offset + open.count) % open.count
        openProject(open[next])
    }

    func workspace(for id: ProjectID) -> WorkspaceStore {
        if let ws = workspaces[id] { return ws }
        let ws = WorkspaceStore(projectID: id, app: self)
        workspaces[id] = ws
        return ws
    }

    // MARK: Lookup

    func project(_ id: ProjectID) -> Project? { library.projects.first { $0.id == id } }
    func host(_ id: ResourceID) -> SSHHost? { library.hosts.first { $0.id == id } }
    func database(_ id: ResourceID) -> DatabaseConnection? { library.databases.first { $0.id == id } }
    func dockerTarget(_ id: ResourceID) -> DockerTarget? { allDocker.first { $0.id == id } }
    func session(_ id: String) -> TerminalSession? { sessions.first { $0.id == id } }

    func svc(_ p: Project) -> ServiceSet { services.set(sample: p.isSample) }
    func svc(_ h: SSHHost) -> ServiceSet { services.set(sample: h.isSample) }
    func svc(_ d: DatabaseConnection) -> ServiceSet { services.set(sample: d.isSample) }

    var sortedProjects: [Project] {
        if library.manualProjectOrder {
            return library.projects.filter(\.isPinned) + library.projects.filter { !$0.isPinned }
        }
        return library.projects.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.lastOpened > b.lastOpened
        }
    }

    /// Sidebar drag: puts a project where the user dropped it among the visible order.
    func moveProject(from: Int, to: Int) {
        var order = sortedProjects
        guard order.indices.contains(from), order.indices.contains(to) else { return }
        order.reorder(from: from, onto: to)
        library.projects = order
        library.manualProjectOrder = true
    }

    var allDocker: [DockerTarget] {
        var seen = Set(library.docker.map(\.id))
        return library.docker + discoveredDocker.filter { seen.insert($0.id).inserted }
    }

    func linkedHosts(_ p: ProjectID) -> [SSHHost] { library.links.resources(of: .host, for: p).compactMap(host) }
    func linkedDatabases(_ p: ProjectID) -> [DatabaseConnection] { library.links.resources(of: .database, for: p).compactMap(database) }
    func linkedDocker(_ p: ProjectID) -> [DockerTarget] { library.links.resources(of: .docker, for: p).compactMap(dockerTarget) }

    func resourceName(_ id: ResourceID) -> String? {
        host(id)?.name ?? database(id)?.name ?? dockerTarget(id)?.name
    }

    func changeCount(_ p: ProjectID) -> Int { git[p]?.changedFileCount ?? 0 }

    var waitingSessions: [TerminalSession] { sessions.filter { $0.kind == .agent && $0.state == .needsInput } }

    // MARK: Timers (metrics refresh, sample agent progress)

    func startTimers() {
        timers.forEach { $0.cancel() }
        timers = [
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await self?.refreshPlans()
                }
            },
            Task { [weak self] in
                // Server metrics log in to each connected server (over the shared
                // SSH connection), so every 30 s and only while a window shows them.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if self?.windowVisible == true { await self?.refreshMetrics() }
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    await self?.refreshSessionNames()
                }
            },
            Task { [weak self] in
                // Projects opened this session refresh when their files or .git
                // change (folder watcher), and on launch, on the Git screen and with
                // Refresh. The rest catch commits made outside Brix once a day:
                // every 45 s was about 180 git runs for 31 repositories.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 86_400_000_000_000)
                    guard let self else { return }
                    for p in self.library.projects where !p.isSample && self.workspaces[p.id]?.watchesFiles != true { self.refreshGit(p.id) }
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshAgentUsage()
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
            },
            Task { [weak self] in
                // The sample atlas-web agent moves through its plan, then asks for input.
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await self?.advanceSampleAgent()
            }
        ]
    }

    static let unreachable = "unreachable"

    func refreshMetrics() async {
        // A connected host that stops answering shows as unreachable (with the
        // reason in healthError) and is tried again, back to connected when it answers.
        for h in library.hosts where hostStatus[h.id] == .connected || hostStatus[h.id] == .idle || hostStatus[h.id] == .error(Self.unreachable) {
            guard h.isSample || hostStatus[h.id] != .idle else { continue }
            do {
                let m = try await svc(h).metrics.metrics(h)
                hostMetrics[h.id] = m; healthAt[h.id] = Date(); healthError[h.id] = nil; rememberOS(h.id, m.os)
                if hostStatus[h.id] == .error(Self.unreachable) { hostStatus[h.id] = .connected }
            } catch {
                healthError[h.id] = error.localizedDescription
                if hostStatus[h.id] == .connected { hostStatus[h.id] = .error(Self.unreachable) }
            }
        }
    }

    func advanceSampleAgent() async {
        guard let i = sessions.firstIndex(where: { $0.id == "s-claude-aw" && $0.state == .running }) else { return }
        var s = sessions[i]
        if let j = s.plan.firstIndex(where: { !$0.done }) { s.plan[j].done = true }
        s.lines += [
            TermLine([MockData.span("⏺ ", Theme.green), MockData.span("Update", Theme.text, bold: true), MockData.span("(src/components/PaymentForm.tsx)", Theme.text3), MockData.span("  +12", Theme.green)]),
            TermLine([MockData.span("⏺ ", Theme.text), MockData.span("Wallet buttons render when Apple Pay is available.")]),
            TermLine([MockData.span("  Should I add the success route and its tests next?")]),
            TermLine([MockData.span("▍", Theme.amber)])
        ]
        s.progress = 0.75
        s.lastOutput = "Wallet buttons render when Apple Pay is available.\nAdd the success route next?"
        sessions[i] = s
        setSessionState(s.id, .needsInput)
    }

    // MARK: Live service wiring

    private func wireLiveServices() {
        let kc = keychain
        let lookup: (SSHHost) -> String? = { h in try? kc.get(Keychain.hostAccount(h.id)) }
        (services.live.metrics as? LiveMetricsService)?.passwordLookup = lookup
        (services.live.docker as? LiveDockerService)?.passwordLookup = lookup
        if let db = services.live.db as? LiveDatabaseService {
            db.hostPasswordLookup = lookup
            db.tunnelHostLookup = { [weak self] id in self?.host(id) }
        }
        if let files = services.live.files as? LiveFileService {
            files.gitStatusProvider = { [weak self] p in
                Dictionary(self?.git[p.id]?.changes.map { ($0.path, $0.status) } ?? [], uniquingKeysWith: { a, b in a == .U ? b : a })
            }
        }
    }
}

