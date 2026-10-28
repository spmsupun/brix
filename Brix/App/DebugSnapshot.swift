import AppKit
import SwiftUI

/// Development aid: `BRIX_SNAPSHOT_DIR=/path open Brix.app` renders each main
/// screen of the window to PNG, then quits. Draws the app's own view
/// hierarchy, so no screen-recording permission is needed.
@MainActor
enum DebugSnapshot {
    static var directory: String? { ProcessInfo.processInfo.environment["BRIX_SNAPSHOT_DIR"] }

    struct Step {
        var name: String
        var setup: (AppStore) -> Void
    }

    static func steps() -> [Step] {
        var s: [Step] = [
            Step(name: "Main") { $0.route = .overview },
            Step(name: "Projects") { $0.selectedProjectInList = "atlas-web"; $0.go(.projects) },
            Step(name: "ProjectWorkspace") { st in st.openProject("atlas-web"); st.workspace(for: "atlas-web").apply(.code) },
            Step(name: "WorkspaceAgent") { st in st.openProject("atlas-web"); st.workspace(for: "atlas-web").apply(.agent) },
            Step(name: "Git") { st in st.openProject("atlas-web"); st.workspace(for: "atlas-web").apply(.review) },
            Step(name: "CommandPalette") { st in st.openProject("atlas-web"); st.workspace(for: "atlas-web").apply(.code); st.paletteOpen = true },
            Step(name: "Terminals") { st in st.paletteOpen = false; st.route = .terminals },
            Step(name: "SSH") { st in st.selectedHost = "dev"; st.route = .ssh },
            Step(name: "SSHSheet") { st in st.selectedHost = "dev"; st.route = .ssh; st.sheet = .editHost(st.host("dev")) },
            Step(name: "Database") { st in st.sheet = nil; st.selectedDatabase = "atlas_dev"; st.route = .databases },
            Step(name: "Servers") { $0.route = .servers },
            Step(name: "Docker") { $0.route = .docker },
            Step(name: "DBConnections") { $0.route = .dbConnections },
            Step(name: "RecentFiles") { $0.route = .recentFiles },
            Step(name: "GitGlobal") { $0.route = .git },
            Step(name: "Customize") { $0.sheet = nil; $0.customizeTab = "layout"; $0.route = .customize },
            Step(name: "CustomizeAgents") { $0.customizeTab = "agents"; $0.route = .customize },
            Step(name: "AgentPicker") { st in st.openProject("atlas-web"); st.workspace(for: "atlas-web").apply(.agent); st.sheet = .chooseAgent("atlas-web") },
            Step(name: "HomeWorking") { st in
                st.sheet = nil; st.route = .overview; st.moodPreview = .working
                // Two agents in atlas-web: one working (crane), one waiting (beacon).
                if let i = st.sessions.firstIndex(where: { $0.id == "s-claude-aw" }) { st.sessions[i].state = .running }
                let extra = st.newTerminal(project: "atlas-web", title: "Claude Code", kind: .agent, attach: false)
                if let i = st.sessions.firstIndex(where: { $0.id == extra.id }) { st.sessions[i].state = .needsInput; st.sessions[i].task = "fix-tab-seam" }
            },
            Step(name: "HomeWaiting") { st in st.moodPreview = .waiting },
            Step(name: "HomeShipped") { st in st.moodPreview = .shipped },
            Step(name: "HomeIdle") { st in st.moodPreview = .idle },
            Step(name: "ProjectOverviewB") { st in st.moodPreview = nil; st.route = .projectHome("atlas-web") },
            Step(name: "DBProjectTree") { st in
                st.sheet = nil
                st.settings.expandedProjects.insert("atlas-web")
                guard let d = st.database("atlas_dev") else { return }
                st.dataWorkspace.expanded.insert("atlas-web|c:atlas_dev")
                st.loadTree(d)
                st.openTable(d, DBObject(schema: "public", name: "users", kind: .table, rowEstimate: 12_500), project: "atlas-web")
                st.workspace(for: "atlas-web").layout.add(.record, to: .right)
            },
            Step(name: "DBProjectRow") { st in
                if let id = st.dataWorkspace.lastInProject["atlas-web"] { st.dataWorkspace.update(id) { $0.selection = DWCell(row: 2, col: 1) } }
            },
            Step(name: "DBLibraryTree") { st in
                UserDefaults.standard.set(true, forKey: "sidebar.dbTree")
                st.dataWorkspace.expanded.insert("lib|c:billing")
                if let d = st.database("billing") { st.loadTree(d) }
                st.route = .dbConnections
            },
            Step(name: "DBLibraryTreeOff") { _ in UserDefaults.standard.set(false, forKey: "sidebar.dbTree") },
            Step(name: "DataUsers") { st in
                st.sheet = nil
                st.route = .databases
                if let d = st.database("atlas_dev") {
                    st.dataWorkspace.expanded.insert("c:atlas_dev")
                    st.loadTree(d)
                    st.openTable(d, DBObject(schema: "public", name: "users", kind: .table, rowEstimate: 12_500))
                }
            },
            Step(name: "DataPending") { st in
                guard let id = st.dataWorkspace.active else { return }
                st.stageCell(id, row: 1, col: 2, value: "Liam Okafor-Reid")
                st.toggleDelete(id, row: 3)
                st.addRow(id)
                st.stageCell(id, row: 50, col: 1, value: "new.person@acme.io")
                st.dataWorkspace.update(id) { $0.selection = DWCell(row: 1, col: 2); $0.whereText = "plan IN ('pro', 'team')"; $0.orderText = "created_at DESC" }
            },
            Step(name: "DataConsole") { st in
                guard let d = st.database("atlas_dev") else { return }
                let sql = """
                -- Revenue by plan · last 14 days
                SELECT u.plan,
                       count(DISTINCT o.user_id)  AS buyers,
                       sum(o.total_cents) / 100.0 AS revenue
                FROM orders o
                JOIN users u ON u.id = o.user_id
                WHERE o.created_at >= now() - interval '14 days'
                GROUP BY u.plan
                ORDER BY revenue DESC;

                SELECT count(*) FROM users WHERE last_login_at IS NULL;
                """
                if let id = st.newConsole(d, sql: sql) {
                    st.dataWorkspace.update(id) { $0.caret = 60 }
                    st.runConsole(id, .caret)
                    _ = st.suggest(console: id.uuidString, sql: "  AND o.status = 'paid'")
                }
            },
            Step(name: "DataProd") { st in
                var prod = DatabaseConnection(id: "snap_prod", name: "prod-replica", kind: .postgres, host: "db-ro.atlas.io", port: 5432, database: "gac", user: "readonly", tag: .prod)
                prod.readOnly = true
                prod.isSample = true
                prod.queryTimeout = 30
                prod.agentAccess = .schema
                if st.database("snap_prod") == nil { st.library.databases.append(prod) }
                if let p = st.dataProject { st.setLink(p.id, prod.id, kind: .database, linked: true) }
                if let id = st.newConsole(prod, sql: "-- Bookings by status\nSELECT status, count(*)\nFROM bookings\nGROUP BY status\nORDER BY 2 DESC;") {
                    st.dataWorkspace.update(id) { $0.title = "weekly_bookings.sql"; $0.caret = 30; $0.resultView = .chart }
                    st.runConsole(id, .caret)
                }
            },
            Step(name: "DataProdWrite") { st in
                guard let id = st.dataWorkspace.active else { return }
                st.dataWorkspace.update(id) { $0.sql = "DELETE FROM bookings WHERE id = 1;"; $0.caret = 5; $0.resultView = .grid }
                st.runConsole(id, .caret)
            },
            Step(name: "DataBack") { st in
                if let t = st.dataWorkspace.tabs.first(where: { $0.title == "users" }) { st.show(t) }
            },
            Step(name: "DBForm") { st in st.route = .overview; st.sheet = .editDatabase(nil) },
            Step(name: "Accounts") { st in st.sheet = nil; st.customizeTab = "accounts"; st.route = .customize },
            Step(name: "ProjectGeneral") { st in st.projectSettingsSection = "General"; st.route = .projectSettings("atlas-web") },
            Step(name: "StatusWaiting") { st in
                for i in st.sessions.indices where st.sessions[i].kind == .agent && st.sessions[i].state == .running { st.sessions[i].state = .idle }
                st.route = .overview
            },
            Step(name: "StatusIdle") { st in st.sessions.removeAll { $0.kind == .agent } },
            Step(name: "ProjectTree") { st in
                st.sheet = nil
                st.settings.expandedProjects = ["atlas-web"]
                st.route = .projectHome("atlas-web")
            },
            Step(name: "ProjectHome") { st in st.sheet = nil; st.route = .projectHome("atlas-web") },
            Step(name: "DockerStacks") { st in st.dockerTab = "stacks"; st.route = .docker },
            Step(name: "DockerNetworks") { st in st.dockerTab = "networks"; st.route = .docker },
            Step(name: "DockerDetail") { st in st.dockerTab = "containers"; st.dockerSelection = .container(st.allDocker.first?.id ?? ""); st.route = .docker },
            Step(name: "AgentGrid") { st in st.dockerSelection = nil; st.openProject("atlas-web"); st.workspace(for: "atlas-web").apply(.agent) },
            Step(name: "TiledWorkspace") { st in tiledWorkspace(st) },
            Step(name: "TiledRestore") { st in
                st.openProject("atlas-web")
                st.workspace(for: "atlas-web").state.layout.centre = .agents
                st.renameSession("s-dev-aw", to: "build")
                dumpTree(st, "tree-2.json")
            },
            Step(name: "TiledResized") { st in
                // The bottom divider moved on its own: same call the divider's drag makes.
                let ws = st.workspace(for: "atlas-web")
                if case .split(_, true, let rows, _)? = ws.state.panes.root, rows.count == 2, case .split(let bottom, _, _, _) = rows[1] {
                    ws.state.panes.setWeights(split: bottom, [40, 60])
                }
                dumpTree(st, "tree-resized.json")
            },
            Step(name: "DropLeft") { st in preview(st, .left) },
            Step(name: "DropRight") { st in preview(st, .right) },
            Step(name: "DropTop") { st in preview(st, .top) },
            Step(name: "DropBottom") { st in preview(st, .bottom) },
            Step(name: "DropCentre") { st in preview(st, nil) },
            Step(name: "DropApplied") { st in
                st.tileDragPreview = nil
                let ws = st.workspace(for: "atlas-web")
                if let g = ws.state.panes.group(of: "s-dev-aw")?.id { ws.state.panes.drop("s-zsh-aw", on: .edge(group: g, .bottom)) }
                dumpTree(st, "tree-dropped.json")
            },
            Step(name: "RemoteFilesSample") { st in st.route = .remoteFiles("dev") },
            Step(name: "Large") { st in st.settings.density = .large; st.settings.uiFont = .avenir; st.route = .customize },
            Step(name: "Rail") { st in st.settings.sidebarStyle = .rail; st.openProject("atlas-web") },
            Step(name: "ProjectResources") { $0.settings.sidebarStyle = .full; $0.route = .projectSettings("atlas-web") }
        ]
        if let live = ProcessInfo.processInfo.environment["BRIX_SNAPSHOT_LIVE"] {
            // Adds a real folder as a project and opens a live PTY terminal in it.
            s.append(Step(name: "LiveWorkspace") { st in
                let url = URL(fileURLWithPath: live)
                let p = st.project(url.lastPathComponent.lowercased()) ?? st.addProject(AppStore.detect(url: url), pinned: false, preset: .code, hosts: [], databases: [], docker: [])
                st.openProject(p.id)
                let s = st.newTerminal(project: p.id, command: "echo brix-live-ok; git status -sb | head -5")
                st.workspace(for: p.id).state.panelSession[st.workspace(for: p.id).layout.bottom.first?.id ?? ""] = s.id
                st.workspace(for: p.id).open("README.md")
            })
            s.append(Step(name: "LiveReview") { st in
                if let p = st.library.projects.first(where: { !$0.isSample }) { st.workspace(for: p.id).apply(.review) }
            })
        }
        if let multi = ProcessInfo.processInfo.environment["BRIX_SNAPSHOT_MULTI"] {
            s.append(Step(name: "MultiAdd") { st in
                let url = URL(fileURLWithPath: multi)
                let p = st.addProject(AppStore.detect(url: url), pinned: true, preset: .code, hosts: [], databases: [], docker: [])
                st.settings.expandedProjects.insert(p.id)
                st.route = .projectHome(p.id)
            })
            s.append(Step(name: "MultiTree") { st in
                if let p = st.library.projects.first(where: { $0.path.hasSuffix(URL(fileURLWithPath: multi).lastPathComponent) && $0.parentID == nil }) {
                    st.route = .projectHome(p.id)
                    for c in st.children(of: p.id) { st.settings.expandedProjects.insert(c.id) }
                }
            })
            s.append(Step(name: "MultiHome") { st in
                st.sheet = nil
                st.route = .overview
                // One repo a commit ahead, for "Since your last visit".
                if let c = st.library.projects.first(where: { $0.parentID != nil && $0.name == "frontend" }), var g = st.git[c.id] {
                    g.ahead = 3
                    st.git[c.id] = g
                }
            })
            s.append(Step(name: "MultiResources") { st in
                if let p = st.library.projects.first(where: { $0.path.hasSuffix(URL(fileURLWithPath: multi).lastPathComponent) && $0.parentID == nil }) {
                    st.setLink(p.id, "atlas_dev", kind: .database, linked: true)
                    st.setLink(p.id, "dev", kind: .host, linked: true)
                    st.settings.collapsedSections.insert("\(p.id)#res")
                }
            })
            s.append(Step(name: "MultiFolded") { st in
                if let p = st.library.projects.first(where: { $0.path.hasSuffix(URL(fileURLWithPath: multi).lastPathComponent) && $0.parentID == nil }) {
                    st.settings.collapsedSections.insert("\(p.id)#repos")
                }
            })
            // Switch one repo's branch on disk and start an agent in another (a stand-in
            // session, no agent process), to watch the chip, the count and the order change.
            if let switchRepo = ProcessInfo.processInfo.environment["BRIX_SNAPSHOT_MULTI_SWITCH"] {
                s.append(Step(name: "MultiSwitch") { st in
                    let dir = URL(fileURLWithPath: multi).appendingPathComponent(switchRepo).path
                    _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/git"), arguments: ["-C", dir, "checkout", "-q", "-b", "feat/very-long-branch-name-for-chip"]).waitUntilExit()
                    for c in st.library.projects where c.parentID != nil { st.refreshGit(c.id) }
                    if let agentRepo = ProcessInfo.processInfo.environment["BRIX_SNAPSHOT_MULTI_AGENT"],
                       let c = st.library.projects.first(where: { $0.parentID != nil && $0.path.hasSuffix("/" + agentRepo) }) {
                        st.sessions.append(TerminalSession(id: "s-snap-agent", projectID: c.id, title: "Claude Code", kind: .agent, cwd: c.path,
                                                           state: .running, process: "claude", startedAt: Date().addingTimeInterval(-360),
                                                           lastOutput: "refactoring booking API"))
                    }
                })
            }
        }
        if let repo = ProcessInfo.processInfo.environment["BRIX_SNAPSHOT_REPO"] {
            // A throwaway git repo: one commit before, one after, to watch the site react.
            s.append(Step(name: "CommitBefore") { st in
                let url = URL(fileURLWithPath: repo)
                let p = st.project(url.lastPathComponent.lowercased()) ?? st.addProject(AppStore.detect(url: url), pinned: true, preset: .code, hosts: [], databases: [], docker: [])
                st.moodPreview = nil
                st.route = .overview
                st.refreshGit(p.id)
            })
            s.append(Step(name: "CommitAfter") { st in
                guard let p = st.library.projects.first(where: { $0.path.hasSuffix(URL(fileURLWithPath: repo).lastPathComponent) }) else { return }
                Task {
                    try? "change \(Date())\n".write(toFile: repo + "/notes.txt", atomically: true, encoding: .utf8)
                    _ = try? await ProcessRunner.run("git", ["-C", repo, "add", "-A"])
                    _ = try? await ProcessRunner.run("git", ["-C", repo, "commit", "-m", "Add notes"])
                    st.dayStats[p.id] = nil
                    st.refreshGit(p.id)
                }
            })
            s.append(Step(name: "CommitProject") { st in
                if let p = st.library.projects.first(where: { $0.path.hasSuffix(URL(fileURLWithPath: repo).lastPathComponent) }) { st.route = .projectHome(p.id) }
            })
        }
        if let dbFile = ProcessInfo.processInfo.environment["BRIX_SNAPSHOT_GATEWAY"] {
            // A project with a SQLite database, and a file of the brix-db environment for each access level.
            s.append(Step(name: "Gateway") { st in
                let dir = URL(fileURLWithPath: dbFile).deletingLastPathComponent()
                let p = st.project("gw") ?? st.addProject(AppStore.DetectedProject(name: "gw", path: dir.path, language: "", framework: "", isGitRepo: false, branch: "", hue: .green),
                                                         pinned: false, preset: .code, hosts: [], databases: [], docker: [])
                for access in AgentDBAccess.allCases {
                    var d = DatabaseConnection(id: "gw-\(access.rawValue)", name: "db_\(access.rawValue)", kind: .sqlite, tag: access == .write ? .local : .dev)
                    d.filePath = dbFile
                    d.agentAccess = access
                    st.saveDatabase(d, password: nil)
                    st.setLink(p.id, d.id, kind: .database, linked: true)
                }
                var prod = DatabaseConnection(id: "gw-prod", name: "db_prod", kind: .sqlite, tag: .prod)
                prod.filePath = dbFile; prod.agentAccess = .write
                st.saveDatabase(prod, password: nil)
                st.setLink(p.id, prod.id, kind: .database, linked: true)
                let env = AgentDBGateway.shared.environment(project: p.id, session: "test")
                let lines = env.filter { $0.key != "PATH" }.map { "export \($0.key)='\($0.value)'" } + ["export PATH=\"\(AgentDBGateway.binDir.path):$PATH\""]
                try? lines.joined(separator: "\n").write(toFile: (directory ?? "/tmp") + "/gateway.env", atomically: true, encoding: .utf8)
            })
        }
        if let only = ProcessInfo.processInfo.environment["BRIX_SNAPSHOT_ONLY"] {
            let names = Set(only.split(separator: ",").map(String.init))
            s = s.filter { names.contains($0.name) }
        }
        return s
    }

    /// The TiledWorkspace artboard on the sample project: top row Claude Code + zsh
    /// beside a build terminal (50/50), bottom row Explorer and Editor (26/74).
    static func tiledWorkspace(_ st: AppStore) {
        st.openProject("atlas-web")
        let ws = st.workspace(for: "atlas-web")
        st.renameSession("s-dev-aw", to: "build")
        let sid = { "s-\(UUID().uuidString.prefix(6))" }
        var a = TabGroup.make(["s-claude-aw", "s-zsh-aw"]); a.active = "s-claude-aw"
        let b = TabGroup.make(["s-dev-aw"])
        let c = TabGroup.make([GridItemID.panel(.explorer)])
        let d = TabGroup.make([GridItemID.file("src/components/PaymentForm.tsx")])
        var t = PaneTree()
        t.root = .split(id: sid(), vertical: true, children: [
            .split(id: sid(), vertical: false, children: [.group(a), .group(b)], weights: [50, 50]),
            .split(id: sid(), vertical: false, children: [.group(c), .group(d)], weights: [26, 74])
        ], weights: [55, 45])
        t.focusedGroup = a.id
        if let p = ws.state.layout.allPanels.first(where: { $0.kind == .explorer }) { ws.state.layout.hide(p.id) }
        for side in DockSide.allCases { for p in ws.state.layout.panels(side) { ws.state.layout.hide(p.id) } }
        ws.state.layout.centre = .agents
        ws.state.panes = t
        if !ws.state.openFiles.contains("src/components/PaymentForm.tsx") { ws.state.openFiles.append("src/components/PaymentForm.tsx") }
        st.saveNow()
        dumpTree(st, "tree-1.json")
    }

    static func dumpTree(_ st: AppStore, _ name: String) {
        guard let dir = directory else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(st.workspace(for: "atlas-web").state.panes).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    }

    /// Freezes a drag of the zsh tab over the build pane, aimed at one zone.
    static func preview(_ st: AppStore, _ edge: PaneEdge?) {
        let ws = st.workspace(for: "atlas-web")
        guard let g = ws.state.panes.group(of: "s-dev-aw")?.id else { return }
        // Window points: the build pane is the top-right one at 1440 × 900.
        let target: PaneDropTarget = edge.map { .edge(group: g, $0) } ?? .center(group: g)
        let at: CGPoint = switch edge {
        case .left?: CGPoint(x: 900, y: 300)
        case .right?: CGPoint(x: 1290, y: 300)
        case .top?: CGPoint(x: 1094, y: 150)
        case .bottom?: CGPoint(x: 1094, y: 440)
        case nil: CGPoint(x: 1093, y: 295)
        }
        st.tileDragPreview = (tab: "s-zsh-aw", target: target, at: at)
    }

    static func run(store: AppStore) {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !store.library.projects.contains(where: \.isSample) { store.loadSampleWorkspace() }
        let steps = steps()
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            let size = ProcessInfo.processInfo.environment["BRIX_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap { Double($0) } ?? []
            if let w = NSApp.windows.first(where: { $0.isVisible }) {
                w.setContentSize(size.count == 2 ? NSSize(width: size[0], height: size[1]) : NSSize(width: 1440, height: 900))
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for step in steps {
                step.setup(store)
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                capture(name: step.name, dir: dir)
            }
            // Frames of the window as the screen shows it, Core Animation included.
            if let n = ProcessInfo.processInfo.environment["BRIX_SNAPSHOT_FRAMES"].flatMap(Int.init),
               let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "Brix" }) ?? NSApp.mainWindow {
                for i in 0..<n {
                    if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/frame\(i).png"))
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            if let hold = ProcessInfo.processInfo.environment["BRIX_SNAPSHOT_HOLD"].flatMap(Double.init) {
                try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            }
            store.sheet = nil
            // Session states and their last output, for checking restores.
            let report = store.sessions.map { s in
                "\(s.title) | \(s.kind) | \(s.state) | ext=\(s.externalID ?? "-") | " + (TerminalRegistry.shared.view(s.id)?.recentLines.suffix(6).joined(separator: " / ") ?? "")
            }.joined(separator: "\n")
            try? report.write(toFile: "\(dir)/sessions.txt", atomically: true, encoding: .utf8)
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        }
    }

    static func capture(name: String, dir: String) {
        // Sheets are child windows; capture the frontmost one when present.
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.className.contains("AppKitWindow") || $0.title == "Brix" }) ?? NSApp.mainWindow,
              let view = main.contentView?.superview ?? main.contentView else { return }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        guard let rep else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let sheet = main.attachedSheet, let sv = sheet.contentView {
            if let srep = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) {
                sv.cacheDisplay(in: sv.bounds, to: srep)
                try? srep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)-sheet.png"))
            }
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
