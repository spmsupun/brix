import SwiftUI

enum Route: Hashable, Codable {
    case overview, projects, recentFiles, terminals, git, databases, docker, ssh, servers, dbConnections, customize
    case workspace(ProjectID)
    case projectSettings(ProjectID)
    case projectHome(ProjectID)
    case remoteFiles(ResourceID)

    var title: String {
        switch self {
        case .overview: "Overview"
        case .projects: "Projects"
        case .recentFiles: "Recent Files"
        case .terminals: "Terminals"
        case .git: "Git"
        case .databases: "Databases"
        case .docker: "Docker"
        case .ssh: "SSH Connections"
        case .servers: "Servers"
        case .dbConnections: "Database"
        case .customize: "Customize"
        case .workspace: "Workspace"
        case .projectSettings: "Project Settings"
        case .projectHome: "Project"
        case .remoteFiles: "Server Files"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .projects: "square.stack.3d.up"
        case .recentFiles: "clock"
        case .terminals: "terminal"
        case .git: "arrow.triangle.branch"
        case .databases: "cylinder.split.1x2"
        case .docker: "shippingbox"
        case .ssh: "globe"
        case .servers: "server.rack"
        case .dbConnections: "link"
        case .customize: "slider.horizontal.3"
        case .workspace, .projectSettings, .projectHome: "folder"
        case .remoteFiles: "externaldrive.connected.to.line.below"
        }
    }

    /// ⌘1–7 main sections.
    static let numbered: [Route] = [.overview, .projects, .terminals, .git, .databases, .docker, .ssh]

    var projectID: ProjectID? {
        switch self {
        case .workspace(let id), .projectSettings(let id), .projectHome(let id): id
        default: nil
        }
    }
}

/// Everything the user saves, minus secrets. Persisted as library.json.
struct Library: Codable {
    var projects: [Project] = []
    var hosts: [SSHHost] = []
    var databases: [DatabaseConnection] = []
    var docker: [DockerTarget] = []
    var links = ProjectLinks()
    var recentFiles: [RecentFile] = []
    var customPresets: [CustomPreset] = []
    var defaultLayout: DockLayout = .preset(.code)
    var queryHistory: [QueryHistoryEntry] = []
    var hasOnboarded = false
    var openProjects: [ProjectID] = []
    var notificationsAsked = false
    /// Terminals not tied to a project (Terminals screen), restarted on launch.
    var globalSessions: [SessionDescriptor] = []
    /// Compose stacks the user attached to projects.
    var stacks: [ComposeStack] = []
    var globalTree = PaneTree()
    /// The user dragged projects into their own order (pinned still go first).
    var manualProjectOrder = false
    /// Live wire: what agents, builds and the user did, newest first.
    var activity: [ActivityEvent] = []
    /// Results of Run tasks started from Brix, newest first.
    var builds: [BuildRecord] = []
    /// Daily totals for sparklines, keyed "metric|id|yyyy-MM-dd".
    var daily: [String: Double] = [:]
    /// When Home was last left, for "since your last visit".
    var lastHomeVisit: Date?
    /// Nested repositories the user removed; not added back on the next scan.
    var dismissedRepos: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // User data: a missing key defaults, but corrupt data throws so the caller
        // can keep the file instead of silently saving an empty library over it.
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        hosts = try c.decodeIfPresent([SSHHost].self, forKey: .hosts) ?? []
        databases = try c.decodeIfPresent([DatabaseConnection].self, forKey: .databases) ?? []
        docker = try c.decodeIfPresent([DockerTarget].self, forKey: .docker) ?? []
        links = try c.decodeIfPresent(ProjectLinks.self, forKey: .links) ?? ProjectLinks()
        customPresets = try c.decodeIfPresent([CustomPreset].self, forKey: .customPresets) ?? []
        // Convenience state: fall back to defaults.
        recentFiles = (try? c.decode([RecentFile].self, forKey: .recentFiles)) ?? []
        defaultLayout = (try? c.decode(DockLayout.self, forKey: .defaultLayout)) ?? .preset(.code)
        queryHistory = (try? c.decode([QueryHistoryEntry].self, forKey: .queryHistory)) ?? []
        hasOnboarded = (try? c.decode(Bool.self, forKey: .hasOnboarded)) ?? false
        openProjects = (try? c.decode([ProjectID].self, forKey: .openProjects)) ?? []
        notificationsAsked = (try? c.decode(Bool.self, forKey: .notificationsAsked)) ?? false
        globalSessions = (try? c.decode([SessionDescriptor].self, forKey: .globalSessions)) ?? []
        stacks = try c.decodeIfPresent([ComposeStack].self, forKey: .stacks) ?? []
        globalTree = (try? c.decode(PaneTree.self, forKey: .globalTree)) ?? PaneTree()
        manualProjectOrder = (try? c.decode(Bool.self, forKey: .manualProjectOrder)) ?? false
        activity = (try? c.decode([ActivityEvent].self, forKey: .activity)) ?? []
        builds = (try? c.decode([BuildRecord].self, forKey: .builds)) ?? []
        daily = (try? c.decode([String: Double].self, forKey: .daily)) ?? [:]
        lastHomeVisit = try? c.decode(Date.self, forKey: .lastHomeVisit)
        dismissedRepos = (try? c.decode(Set<String>.self, forKey: .dismissedRepos)) ?? []
    }

    static var sample: Library {
        var l = Library()
        l.projects = MockData.projects
        l.hosts = MockData.hosts
        l.databases = MockData.databases
        l.docker = MockData.docker
        l.links = MockData.links
        l.hasOnboarded = true
        l.recentFiles = [
            RecentFile(project: "atlas-web", path: "src/components/PaymentForm.tsx", openedAt: MockData.ago(5 * 60)),
            RecentFile(project: "atlas-web", path: "src/app/checkout/page.tsx", openedAt: MockData.ago(9 * 60)),
            RecentFile(project: "atlas-web", path: "src/lib/stripe/intent.ts", openedAt: MockData.ago(14 * 60)),
            RecentFile(project: "atlas-api", path: "internal/payments/handler.go", openedAt: MockData.ago(3600)),
            RecentFile(project: "atlas-api", path: "migrations/0012_payment_intents.sql", openedAt: MockData.ago(4000)),
            RecentFile(project: "billing-service", path: "app/Services/InvoiceTotals.php", openedAt: MockData.ago(86400)),
            RecentFile(project: "ml-pipelines", path: "flows/daily_rollup.py", openedAt: MockData.ago(2 * 86400)),
            RecentFile(project: "atlas-web", path: "CLAUDE.md", openedAt: MockData.ago(3 * 86400))
        ]
        l.queryHistory = [
            QueryHistoryEntry(sql: "select u.plan,\n       count(distinct b.user_id) as buyers,\n       sum(p.amount_cents) / 100.0 as revenue\nfrom bookings b\njoin users u on u.id = b.user_id\njoin payments p on p.booking_id = b.id\nwhere b.created_at > now() - interval '7 days'\n  and p.status = 'succeeded'\ngroup by u.plan\norder by revenue desc;", connectionID: "atlas_dev", ranAt: Date(), rows: 4, ms: 38),
            QueryHistoryEntry(sql: "select * from users where plan = 'enterprise' limit 50;", connectionID: "atlas_dev", ranAt: MockData.ago(14 * 60), rows: 50, ms: 18),
            QueryHistoryEntry(sql: "select status, count(*) from bookings group by status;", connectionID: "atlas_dev", ranAt: MockData.ago(31 * 60), rows: 4, ms: 42),
            QueryHistoryEntry(sql: "update payments set status = 'succeeded' where id = 90412;", connectionID: "atlas_dev", ranAt: MockData.ago(7200), rows: 1, ms: 6),
            QueryHistoryEntry(sql: "select * from bookigns limit 10;", connectionID: "atlas_dev", ranAt: MockData.ago(10800), rows: 0, ms: 0, error: "relation does not exist"),
            QueryHistoryEntry(sql: "explain analyze select * from audit_log where created_at > now() - interval '1 day';", connectionID: "atlas_dev", ranAt: MockData.ago(86400), rows: 9, ms: 233)
        ]
        l.openProjects = ["atlas-web"]
        return l
    }
}

struct Toast: Identifiable, Equatable {
    enum Kind { case success, error, info, progress }
    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String? = nil
}

/// Native alert for destructive and production actions.
struct Confirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmTitle: String
    var destructive = true
    /// The user has to type this exactly to confirm (a Production database's name).
    var typeToConfirm: String? = nil
    var action: () -> Void
    var onCancel: (() -> Void)? = nil
}

enum ActiveSheet: Identifiable {
    case addProject
    case editHost(SSHHost?)
    case editDatabase(DatabaseConnection?)
    case addDocker
    /// nil saves the default layout from Customize.
    case savePreset(ProjectID?)
    case chooseAgent(ProjectID)
    case importConnections
    case editFile(FileRef)
    case editAgent(AgentConfig?)
    case newFile(ProjectID, isDirectory: Bool, parent: String)
    case renameFile(ProjectID, path: String)
    case newBranch(ProjectID)
    case renameSession(String)
    case renamePanel(ProjectID, String)

    var id: String {
        switch self {
        case .addProject: "addProject"
        case .editHost(let h): "host-\(h?.id ?? "new")"
        case .editDatabase(let d): "db-\(d?.id ?? "new")"
        case .addDocker: "docker"
        case .savePreset(let p): "preset-\(p ?? "default")"
        case .chooseAgent(let p): "agent-\(p)"
        case .importConnections: "import"
        case .editFile(let f): "file-\(f.id)"
        case .editAgent(let a): "edit-agent-\(a?.id ?? "new")"
        case .newFile(let p, let d, let parent): "new-\(p)-\(d)-\(parent)"
        case .renameFile(let p, let path): "rename-\(p)-\(path)"
        case .newBranch(let p): "branch-\(p)"
        case .renameSession(let s): "session-\(s)"
        case .renamePanel(let p, let id): "panel-\(p)-\(id)"
        }
    }
}

enum InspectorSelection: Equatable {
    case none
    case file(ProjectID, String)
    case project(ProjectID)
    case session(String)
    case host(ResourceID)
    case table(ResourceID, DBObject)
    case commit(ProjectID, String)
}

/// Grid of agent/terminal panes in the "Agents & Terminals" centre mode.
struct PaneTab: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var panes: [String]
    var vertical = false
}

/// Enough to recreate a live terminal after relaunch.
struct SessionDescriptor: Codable, Hashable {
    var id: String
    var title: String
    var kind: SessionKind
    var hostID: ResourceID?
    var cwd: String
    var command: String?
    var agentID: String?
    /// Agent conversation id for resume (Claude Code session id, Codex session id).
    var externalID: String?
    var task: String?
}

extension SessionDescriptor {
    init(_ s: TerminalSession) {
        self.init(id: s.id, title: s.title, kind: s.kind, hostID: s.hostID, cwd: s.cwd, command: s.kind == .agent ? "agent" : nil,
                  agentID: s.agentID, externalID: s.externalID, task: s.task.isEmpty ? nil : s.task)
    }
}

enum DiffMode: String, Codable { case unified, split }

/// Per-project workspace state, persisted to workspaces/<id>.json.
struct WorkspaceState: Codable {
    var layout: DockLayout
    var openFiles: [String] = []
    var activeFile: String? = nil
    var splitFile: String? = nil
    var expanded: Set<String> = []
    var selection: String? = nil
    /// Split groups of terminal and agent tabs in the centre.
    var panes = PaneTree()
    var panelSession: [String: String] = [:]
    var sessions: [SessionDescriptor] = []
    var diffMode: DiffMode = .unified
    var reviewFile: String? = nil
    var markdownRendered = true
    /// This project's own arrangement for each layout it has used (docks and
    /// tiles), keyed by preset name, so switching Code ↔ Agent comes back as left.
    var presetArrangements: [String: CustomPreset] = [:]

    init(layout: DockLayout) { self.layout = layout }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = (try? c.decode(DockLayout.self, forKey: .layout)) ?? .preset(.code)
        openFiles = (try? c.decode([String].self, forKey: .openFiles)) ?? []
        activeFile = try? c.decode(String.self, forKey: .activeFile)
        splitFile = try? c.decode(String.self, forKey: .splitFile)
        expanded = (try? c.decode(Set<String>.self, forKey: .expanded)) ?? []
        selection = try? c.decode(String.self, forKey: .selection)
        if let tree = try? c.decode(PaneTree.self, forKey: .panes) {
            panes = tree
        } else {
            // Files from before split groups.
            let old = try? decoder.container(keyedBy: LegacyKeys.self)
            let tabs = (try? old?.decode([PaneTab].self, forKey: .paneTabs)) ?? []
            panes = PaneTree(legacy: tabs, active: (try? old?.decode(String.self, forKey: .activePaneTab)) ?? nil)
        }
        panelSession = (try? c.decode([String: String].self, forKey: .panelSession)) ?? [:]
        sessions = (try? c.decode([SessionDescriptor].self, forKey: .sessions)) ?? []
        diffMode = (try? c.decode(DiffMode.self, forKey: .diffMode)) ?? .unified
        reviewFile = try? c.decode(String.self, forKey: .reviewFile)
        markdownRendered = (try? c.decode(Bool.self, forKey: .markdownRendered)) ?? true
        presetArrangements = (try? c.decode([String: CustomPreset].self, forKey: .presetArrangements)) ?? [:]
    }

    private enum LegacyKeys: String, CodingKey { case paneTabs, activePaneTab }
}

/// A custom popover drawn above all islands (dock menu, Add panel menu).
struct PopoverRequest: Identifiable {
    enum Kind: Equatable {
        case dock(String)
        case addPanel(DockSide)
        /// Add Panel menu adding into a pane of the tiled centre.
        case addTab(String)
    }
    let id = UUID()
    var kind: Kind
    /// Anchor in the root coordinate space.
    var anchor: CGRect
    var projectID: ProjectID?
    /// Centre in the window instead of anchoring (used by toolbar and menus).
    var centred = false
}
