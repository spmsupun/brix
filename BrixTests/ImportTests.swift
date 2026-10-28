import XCTest
@testable import Brix

final class ImportTests: XCTestCase {
    func testSSHConfigSkipsWildcardsAndGitAliases() {
        let cfg = """
        Host *
          ServerAliveInterval 60
        Host web-prod web
          HostName 10.0.0.5
          Port 2222
          User deploy
          IdentityFile ~/.ssh/web_key
        Host github.com-work
          HostName github.com
          IdentityFile ~/.ssh/work
        Host box
          HostName box.local
        """
        let hosts = ConfigImporter.sshConfig(cfg)
        XCTAssertEqual(hosts.map(\.name), ["web-prod", "box"])
        XCTAssertEqual(hosts[0].host, "10.0.0.5")
        XCTAssertEqual(hosts[0].port, 2222)
        XCTAssertEqual(hosts[0].user, "deploy")
        XCTAssertEqual(hosts[0].auth, .key)
        XCTAssertEqual(hosts[0].tag, .prod)
        XCTAssertEqual(hosts[1].auth, .agent)
    }

    func testJetBrainsSSHConfigs() {
        let xml = """
        <application><component name="SshConfigs"><configs>
          <sshConfig host="10.1.1.1" id="abc" keyPath="$USER_HOME$/.ssh/dev.pem" port="2222" customName="App DEV" nameFormat="CUSTOM" username="ubuntu" />
          <sshConfig authType="PASSWORD" host="10.2.2.2" id="def" port="22" username="root" />
        </configs></component></application>
        """
        let r = ConfigImporter.jetbrainsSSH(Data(xml.utf8))
        XCTAssertEqual(r.map(\.ref), ["abc", "def"])
        XCTAssertEqual(r[0].host.name, "App DEV")
        XCTAssertEqual(r[0].host.keyPath, "~/.ssh/dev.pem")
        XCTAssertEqual(r[0].host.port, 2222)
        XCTAssertEqual(r[1].host.auth, .password)
        XCTAssertEqual(r[1].host.name, "root@10.2.2.2")
    }

    func testJetBrainsDataSourcesWithTunnel() {
        let main = """
        <project version="4"><component name="DataSourceManagerImpl" format="xml" multifile-model="true">
          <data-source source="LOCAL" name="shop@prod" uuid="u1">
            <driver-ref>postgresql</driver-ref>
            <jdbc-url>jdbc:postgresql://db.internal:5433/shop</jdbc-url>
          </data-source>
          <data-source source="LOCAL" name="cache" uuid="u2">
            <jdbc-url>jdbc:mysql://localhost/app</jdbc-url>
          </data-source>
          <data-source source="LOCAL" name="local.db" uuid="u3">
            <jdbc-url>jdbc:sqlite:/tmp/x.db</jdbc-url>
          </data-source>
        </component></project>
        """
        let local = """
        <project version="4"><component name="dataSourceStorageLocal">
          <data-source name="shop@prod" uuid="u1">
            <user-name>reader</user-name>
            <ssh-properties><enabled>true</enabled><ssh-config-id>abc</ssh-config-id></ssh-properties>
          </data-source>
        </component></project>
        """
        let r = ConfigImporter.jetbrainsDataSources(main: Data(main.utf8), local: Data(local.utf8))
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r[0].db.kind, .postgres)
        XCTAssertEqual(r[0].db.host, "db.internal")
        XCTAssertEqual(r[0].db.port, 5433)
        XCTAssertEqual(r[0].db.database, "shop")
        XCTAssertEqual(r[0].db.user, "reader")
        XCTAssertEqual(r[0].db.tag, .prod)
        XCTAssertEqual(r[0].tunnelRef, "abc")
        XCTAssertEqual(r[1].db.kind, .mysql)
        XCTAssertEqual(r[1].db.port, 3306)
        XCTAssertNil(r[1].tunnelRef)
        XCTAssertEqual(r[2].db.kind, .sqlite)
        XCTAssertEqual(r[2].db.filePath, "/tmp/x.db")
    }

    func testVSCodeSQLToolsWithComments() {
        let settings = """
        {
          // editor stuff
          "editor.fontSize": 13, /* block */
          "url": "http://example.com//not-a-comment",
          "sqltools.connections": [
            { "name": "Local PG", "driver": "PostgreSQL", "server": "localhost", "port": 5432, "database": "app", "username": "me", "password": "pw", },
            { "name": "Lite", "driver": "SQLite", "database": "/tmp/a.sqlite" },
            { "name": "Mongo", "driver": "MongoDB" },
          ],
        }
        """
        let r = ConfigImporter.vscodeSQLTools(settings)
        XCTAssertEqual(r.map(\.db.name), ["Local PG", "Lite"])
        XCTAssertEqual(r[0].db.user, "me")
        XCTAssertEqual(r[0].password, "pw")
        XCTAssertEqual(r[1].db.filePath, "/tmp/a.sqlite")
        XCTAssertNil(r[1].password)
    }

    func testDedupeKeepsFirstSource() {
        let h = SSHHost(id: "a", name: "one", host: "1.2.3.4", user: "u", tag: .dev)
        var h2 = h
        h2.id = "b"
        h2.name = "two"
        let out = ConfigImporter.dedupe([ImportCandidate(id: "1", item: .host(h), source: "JetBrains"), ImportCandidate(id: "2", item: .host(h2), source: "ssh")])
        XCTAssertEqual(out.map(\.id), ["1"])
    }

    @MainActor func testProjectFileRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("shop")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "services: {}".write(to: folder.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let kc = Keychain(service: "com.brix.tests.\(UUID().uuidString)")

        // First Mac: project with a host, a tunnelled database and an agent choice.
        let a = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: root.appendingPathComponent("a")), keychain: kc, loadFromDisk: false)
        let p = a.addProject(AppStore.detect(url: folder), pinned: false, preset: .agent, hosts: [], databases: [], docker: [])
        let host = SSHHost(id: "h1", name: "Shop Prod", host: "10.0.0.9", user: "deploy", port: 2200, tag: .prod)
        a.library.hosts.append(host)
        var db = DatabaseConnection(id: "d1", name: "shop_db", kind: .postgres, tag: .prod)
        db.host = "127.0.0.1"; db.database = "shop"; db.user = "app"; db.tunnelHostID = "h1"
        a.library.databases.append(db)
        a.library.links.link(p.id, "h1", kind: .host)
        a.library.links.link(p.id, "d1", kind: .database)
        var updated = a.project(p.id)!
        updated.agentID = "codex"
        a.updateProject(updated)
        a.writeProjectFiles()

        let file = try XCTUnwrap(try ProjectFile.read(a.project(p.id)!))
        XCTAssertEqual(file.agent, "codex")
        XCTAssertEqual(file.hosts?.first?.host, "10.0.0.9")
        XCTAssertEqual(file.databases?.first?.tunnelHost, "Shop Prod")
        XCTAssertEqual(file.composeFiles, ["compose.yaml"])
        let raw = try String(contentsOf: ProjectFile.url(for: a.project(p.id)!), encoding: .utf8)
        XCTAssertFalse(raw.lowercased().contains("password\""), "no password field is ever written")

        // Writing again without changes leaves the file alone.
        let before = try FileManager.default.attributesOfItem(atPath: ProjectFile.url(for: p).path)[.modificationDate] as? Date
        a.writeProjectFiles()
        let after = try FileManager.default.attributesOfItem(atPath: ProjectFile.url(for: p).path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)

        // Second Mac: adding the folder recreates the connections and links.
        let b = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: root.appendingPathComponent("b")), keychain: kc, loadFromDisk: false)
        let q = b.addProject(AppStore.detect(url: folder), pinned: false, preset: .code, hosts: [], databases: [], docker: [])
        XCTAssertEqual(b.project(q.id)?.agentID, "codex")
        XCTAssertEqual(b.linkedHosts(q.id).map(\.host), ["10.0.0.9"])
        let bdb = try XCTUnwrap(b.linkedDatabases(q.id).first)
        XCTAssertEqual(bdb.database, "shop")
        XCTAssertEqual(bdb.tunnelHostID, b.linkedHosts(q.id).first?.id)
        XCTAssertEqual(bdb.tag, .prod)

        // Loading twice doesn't duplicate anything.
        b.loadProjectFile(q.id, announce: false)
        XCTAssertEqual(b.library.hosts.count, 1)
        XCTAssertEqual(b.library.databases.count, 1)
    }

    func testSameArrangementIgnoresIdsAndSizes() {
        var a = DockLayout.preset(.code)
        let b = DockLayout.preset(.code)
        a.leftWidth = 400
        XCTAssertTrue(a.sameArrangement(as: b))
        a.centre = .review
        XCTAssertFalse(a.sameArrangement(as: b))
    }
}

extension ImportTests {
    @MainActor func testUnreadableProjectFileIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".brix"), withIntermediateDirectories: true) // legacy location
        defer { try? FileManager.default.removeItem(at: root) }
        let url = folder.appendingPathComponent(ProjectFile.relativePath)
        try "{ <<<<<<< HEAD".write(to: url, atomically: true, encoding: .utf8)
        let s = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: root.appendingPathComponent("s")),
                         keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"), loadFromDisk: false)
        let p = s.addProject(AppStore.detect(url: folder), pinned: false, preset: .code, hosts: [], databases: [], docker: [])
        s.writeProjectFiles()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ <<<<<<< HEAD")
        XCTAssertNotNil(s.projectFileErrors[p.id])
    }
}

extension ImportTests {
    func testTabReorderSemantics() {
        var a = ["a", "b", "c", "d"]
        a.reorder(from: 0, onto: 2)   // drag right: lands after the target
        XCTAssertEqual(a, ["b", "c", "a", "d"])
        a.reorder(from: 3, onto: 0)   // drag left: lands before the target
        XCTAssertEqual(a, ["d", "b", "c", "a"])
        a.reorder(from: 1, onto: 9)   // out of range is ignored
        XCTAssertEqual(a, ["d", "b", "c", "a"])
    }
}

extension ImportTests {
    @MainActor func testLegacyProjectFileMigratesToBrixJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".brix"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"agent":"codex","notes":"kept"}"#.write(to: folder.appendingPathComponent(ProjectFile.legacyPath), atomically: true, encoding: .utf8)
        let s = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: root.appendingPathComponent("s")),
                         keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"), loadFromDisk: false)
        let p = s.addProject(AppStore.detect(url: folder), pinned: false, preset: .code, hosts: [], databases: [], docker: [])
        XCTAssertEqual(s.project(p.id)?.agentID, "codex")
        s.writeProjectFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("brix.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".brix").path), "old folder removed once migrated")
        XCTAssertEqual(try ProjectFile.read(s.project(p.id)!)?.notes, "kept")
    }

    func testDockerParsers() {
        let stacks = DockerParse.stacks(#"[{"Name":"shop","Status":"running(3)","ConfigFiles":"/a/compose.yaml,/a/override.yaml"}]"#, hostID: nil)
        XCTAssertEqual(stacks.first?.configFiles, ["/a/compose.yaml", "/a/override.yaml"])
        XCTAssertEqual(stacks.first?.id, "stack:local/shop")
        XCTAssertTrue(stacks.first?.isRunning == true)
        let nets = DockerParse.networks(#"{"ID":"1","Name":"shop_default","Driver":"bridge","Scope":"local","Labels":"com.docker.compose.project=shop,x=y"}"#, hostID: "h")
        XCTAssertEqual(nets.first?.composeProject, "shop")
        XCTAssertEqual(LiveDockerService.composeArgs(stacks[0]), ["compose", "-f", "/a/compose.yaml", "-f", "/a/override.yaml", "-p", "shop"])
    }

    func testAgentResumeCommands() {
        let claude = AgentConfig.builtins.first { $0.id == "claude" }!
        let id = "3f2a8c1e-0000-4000-8000-123456789abc"
        XCTAssertEqual(claude.launchCommand(resourceNames: [], sessionID: id), "claude --session-id \(id)")
        XCTAssertEqual(claude.launchCommand(resourceNames: [], sessionID: id, resume: true), "claude --resume \(id)")
        let codex = AgentConfig.builtins.first { $0.id == "codex" }!
        XCTAssertEqual(codex.launchCommand(resourceNames: [], sessionID: id, resume: true), "codex resume \(id)")
        // Anything that isn't a plain id never reaches the shell.
        XCTAssertEqual(claude.launchCommand(resourceNames: [], sessionID: "x; rm -rf ~", resume: true), "claude")
    }

    func testClaudeFolderEncoding() {
        XCTAssertEqual(AgentTranscripts.claudeFolderName("/Users/me/projects/my app.v2"), "-Users-me-projects-my-app-v2")
    }
}

extension ImportTests {
    func testIDENames() {
        XCTAssertEqual(ConfigImporter.prettyIDE("PhpStorm2026.2"), "PhpStorm 2026.2")
        XCTAssertEqual(ConfigImporter.prettyIDE("IntelliJIdea2025.3"), "IntelliJIdea 2025.3")
    }

    /// Real sqlite3: dump a database with the app's arguments, then restore it into a new file.
    @MainActor func testSQLiteDumpAndRestoreRoundTrip() async throws {
        guard let sqlite = ProcessRunner.which("sqlite3") else { throw XCTSkip("sqlite3 not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.db").path, dst = dir.appendingPathComponent("dst.db").path, file = dir.appendingPathComponent("out.sql").path
        _ = try await ProcessRunner.check(sqlite, [src, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t(name) VALUES ('a'),('b');"])
        var d = DatabaseConnection(id: "x", name: "x", kind: .sqlite, tag: .local)
        d.filePath = src
        let e = AppStore.DBEndpoint(host: "", port: 0, tunnel: nil, env: [:])
        _ = try await ProcessRunner.check(sqlite, AppStore.dumpArgs(d, e, to: file, custom: false))
        XCTAssertTrue(try String(contentsOfFile: file, encoding: .utf8).contains("CREATE TABLE t"))
        d.filePath = dst
        _ = try await ProcessRunner.check(sqlite, AppStore.restoreArgs(d, e, from: file, custom: false))
        let count = try await ProcessRunner.check(sqlite, [dst, "SELECT count(*) FROM t;"])
        XCTAssertEqual(count.trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }
}

extension ImportTests {
    func testAgentWorkingDetection() {
        XCTAssertTrue(BrixTerminalView.screenShowsWork("✻ Thinking… (12s · ↓ 300 tokens · esc to interrupt)"))
        XCTAssertTrue(BrixTerminalView.screenShowsWork("• Working (5s • Esc to interrupt)"))
        XCTAssertFalse(BrixTerminalView.screenShowsWork("❯ Try \"edit ModelTests.swift\"\n⏵⏵ auto mode on (shift+tab to cycle)"))
        XCTAssertTrue(BrixTerminalView.screenShowsWork("✶ Cogitating… (4s)"))
        XCTAssertFalse(BrixTerminalView.screenShowsWork("* Cogitated for 4s · done 4:24 PM"))
        XCTAssertTrue(BrixTerminalView.screenAsksInput("Do you want to make this edit to Sidebar.swift?\n❯ 1. Yes\n  2. No\nEsc to cancel"))
        XCTAssertFalse(BrixTerminalView.screenAsksInput("● Hi. What need doing?\n❯ \n⏵⏵ auto mode on (shift+tab to cycle)"))
        // Text in the chat doesn't count: only a spinner row or a choice list does.
        XCTAssertFalse(BrixTerminalView.screenShowsWork("  ⎿ Loading… done\nBuilding… the app"))
        XCTAssertFalse(BrixTerminalView.screenAsksInput("● Do you want to add tests next? Would you like to deploy?\n❯ "))
        XCTAssertEqual(BrixTerminalView.bottom(["a", "", "b", "c"], lines: 2), "b\nc")
    }
}

extension ImportTests {
    func testRemoteListParsing() {
        let out = "/home/ubuntu\nd\t4096\t1793100000.5\t755\tapp\nf\t220\t1793000000\t644\t.bashrc\nl\t7\t0\t777\tcurrent\nf\t12\t0\t644\tnotes with\ttab\n"
        let r = RemoteFiles.parseList(out)
        XCTAssertEqual(r.path, "/home/ubuntu")
        XCTAssertEqual(r.entries.map(\.name), ["app", ".bashrc", "current", "notes with\ttab"])
        XCTAssertTrue(r.entries[0].isDirectory)
        XCTAssertTrue(r.entries[2].isLink)
        XCTAssertEqual(r.entries[1].size, 220)
        XCTAssertNil(r.entries[2].modified)
    }

    func testRemoteQuotingAndPaths() {
        XCTAssertEqual(RemoteFiles.q("it's"), "'it'\\''s'")
        XCTAssertEqual(RemoteFiles.cdTarget("~"), "cd")
        XCTAssertEqual(RemoteFiles.cdTarget("~/a b"), "cd ~/'a b'")
        XCTAssertEqual(RemoteFiles.cdTarget("/var/www"), "cd -- '/var/www'")
        XCTAssertEqual(RemoteFiles.parent("/var/www"), "/var")
        XCTAssertEqual(RemoteFiles.parent("/var"), "/")
        XCTAssertEqual(RemoteFiles.join("/", "etc"), "/etc")
        let h = SSHHost(id: "h", name: "box", host: "10.0.0.1", user: "deploy", port: 2222, auth: .key, keyPath: "~/.ssh/k", tag: .dev)
        let a = RemoteFiles.scpArgs(h, recursive: true)
        XCTAssertTrue(a.contains("-P") && a.contains("2222") && a.contains("-r") && a.contains("BatchMode=yes"))
        XCTAssertFalse(a.contains("-p"), "scp's port flag is -P")
    }

    /// The listing script runs here against a real folder, with the system shell.
    func testRemoteListCommandRunsLocally() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hi".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await ProcessRunner.check("/bin/sh", ["-c", RemoteFiles.listCommand(dir.path)])
        let r = RemoteFiles.parseList(out)
        XCTAssertEqual(Set(r.entries.map(\.name)), ["sub", "a.txt"])
        XCTAssertEqual(r.entries.first?.name, "sub", "folders first")
    }

    func testServerOSDetection() {
        XCTAssertEqual(ServerOS("Ubuntu 22.04.4 LTS"), .ubuntu)
        XCTAssertEqual(ServerOS("Amazon Linux 2023"), .amazon)
        XCTAssertEqual(ServerOS("Debian GNU/Linux 12 (bookworm)"), .debian)
        XCTAssertEqual(ServerOS("Darwin 24.1.0"), .macos)
        XCTAssertEqual(ServerOS(""), .unknown)
        XCTAssertEqual(ServerOS("Some Linux"), .linux)
    }

    @MainActor func testManualProjectOrder() {
        let s = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                         keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"), loadFromDisk: false)
        s.loadSampleWorkspace()
        let before = s.sortedProjects.map(\.id)
        s.moveProject(from: 0, to: before.count - 1)
        let after = s.sortedProjects.map(\.id)
        XCTAssertTrue(s.library.manualProjectOrder)
        XCTAssertEqual(Set(after), Set(before))
        // Pinned projects stay above the rest.
        let pinned = s.library.projects.filter(\.isPinned).map(\.id)
        XCTAssertEqual(Array(after.prefix(pinned.count)).sorted(), pinned.sorted())
    }
}

final class ActivityTests: XCTestCase {
    func testDayLogTotalsCommitsFilesAndLines() {
        let out = "\u{1e}abc\n\n3\t1\tA.swift\n2\t0\tB.swift\n\u{1e}def\n\n5\t5\tA.swift\n-\t-\timage.png\n"
        let s = LiveActivityService.parseDayLog(out)
        XCTAssertEqual(s.commits, 2)
        XCTAssertEqual(s.files, ["A.swift", "B.swift", "image.png"])
        XCTAssertEqual(s.add, 10)
        XCTAssertEqual(s.del, 6)
        XCTAssertEqual(LiveActivityService.parseDayLog(""), DayStats())
    }

    func testRunTasksFromBuildScriptAndPackageJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brix-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "#!/bin/sh\ncase $1 in test) echo t;; esac\n".write(to: dir.appendingPathComponent("build.sh"), atomically: true, encoding: .utf8)
        try #"{"scripts":{"dev":"next dev","test":"vitest"}}"#.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)
        let t = RunTaskDetector.detect(dir)
        XCTAssertEqual(t.map(\.command), ["./build.sh", "./build.sh test", "pnpm dev", "pnpm test"])
        XCTAssertEqual(t.map(\.kind), [.build, .test, .run, .test])
    }

    func testKeyframesFollowStopsDelayAndLoop() {
        // The design's drop: -90 → 0 by 60%, holding after; before the delay the rest pose.
        let k = Keyframes(stops: [(0, [-90]), (0.6, [0]), (1, [0])], duration: 2.4, delay: 0.6, curve: .linear, rest: [0])
        XCTAssertEqual(k.values(at: 0.3)[0], 0)
        XCTAssertEqual(k.values(at: 0.6)[0], -90, accuracy: 0.001)
        XCTAssertEqual(k.values(at: 0.6 + 0.72)[0], -45, accuracy: 0.5)
        XCTAssertEqual(k.values(at: 0.6 + 2.0)[0], 0, accuracy: 0.001)
        XCTAssertEqual(k.values(at: 0.6 + 2.4 + 0.72)[0], -45, accuracy: 0.5)
        XCTAssertEqual(Keyframes.bezier(Keyframes.Curve.easeInOut.points, x: 0.5), 0.5, accuracy: 0.01)
    }
}

final class GitHubAndLayoutTests: XCTestCase {
    func testRepoFromRemoteURLs() {
        XCTAssertEqual(GitHub.repo(fromRemote: "https://github.com/supun/brix.git"), "supun/brix")
        XCTAssertEqual(GitHub.repo(fromRemote: "https://github.com/supun/brix"), "supun/brix")
        XCTAssertEqual(GitHub.repo(fromRemote: "git@github.com:org/repo.git"), "org/repo")
        // ssh host aliases for picking a deploy key
        XCTAssertEqual(GitHub.repo(fromRemote: "git@github.com-360softy:softy/app.git"), "softy/app")
        XCTAssertEqual(GitHub.repo(fromRemote: "ssh://git@github.com/org/repo.git"), "org/repo")
        XCTAssertNil(GitHub.repo(fromRemote: "git@gitlab.com:org/repo.git"))
    }

    func testChecksFold() {
        typealias C = GitHubPR.Check
        XCTAssertEqual(GitHubPR.fold([]), .none)
        XCTAssertEqual(GitHubPR.fold([C(conclusion: "SUCCESS"), C(conclusion: "SKIPPED")]), .passing)
        XCTAssertEqual(GitHubPR.fold([C(conclusion: "SUCCESS"), C(status: "IN_PROGRESS")]), .pending)
        XCTAssertEqual(GitHubPR.fold([C(status: "IN_PROGRESS"), C(conclusion: "FAILURE")]), .failing)
        XCTAssertEqual(GitHubPR.fold([C(state: "SUCCESS")]), .passing)
    }

    @MainActor
    func testEachLayoutRemembersThisProjectsArrangement() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brix-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: dir),
                             keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"), loadFromDisk: false)
        store.loadSampleWorkspace()
        let ws = store.workspace(for: "atlas-web")
        ws.apply(.code)
        ws.open("README.md")
        ws.splitActivePane(vertical: false)
        let codeTree = ws.state.panes
        ws.apply(.agent)
        XCTAssertNotEqual(ws.state.panes.groups.count, 0)
        ws.apply(.code)
        XCTAssertEqual(ws.state.panes.groups.count, codeTree.groups.count, "Code comes back as this project left it")
        XCTAssertTrue(ws.state.panes.allTabs.contains(GridItemID.file("README.md")))
        ws.resetArrangement()
        XCTAssertNil(ws.state.presetArrangements["code"], "Reset forgets this project's Code arrangement")
    }
}

final class DatabaseURLTests: XCTestCase {
    func testParsesConnectionURLs() {
        let p = DatabaseConnection.parse(url: "postgres://app:s%40cret@db.example.com:6432/shop?sslmode=require")
        XCTAssertEqual(p, DatabaseConnection.URLParts(flavor: .postgres, host: "db.example.com", port: 6432, database: "shop", user: "app", password: "s@cret", ssl: .require))
        XCTAssertEqual(DatabaseConnection.parse(url: "mysql://root@localhost/app")?.flavor, .mysql)
        XCTAssertNil(DatabaseConnection.parse(url: "mysql://root@localhost/app")?.port)
        XCTAssertEqual(DatabaseConnection.parse(url: "postgresql://u:p@ep-x-1.eu-west-2.aws.neon.tech/neondb?sslmode=require")?.flavor, .neon)
        XCTAssertEqual(DatabaseConnection.parse(url: "postgres://u@aws-0-eu.pooler.supabase.com:6543/postgres")?.flavor, .supabase)
        XCTAssertEqual(DatabaseConnection.parse(url: "mysql://u:p@aws.connect.psdb.cloud/db?ssl=true")?.ssl, .require)
        XCTAssertNil(DatabaseConnection.parse(url: "redis://localhost:6379"))
        XCTAssertEqual(DBFlavor.cockroach.kind, .postgres)
        XCTAssertEqual(DBFlavor.tidb.defaultPort, 4000)
    }
}

extension GitHubAndLayoutTests {
    func testParsesSignedInAccountsActiveFirst() {
        let status = """
        github.com
          ✓ Logged in to github.com account first-one (keyring)
          - Active account: false
          - Git operations protocol: ssh
          ✓ Logged in to github.com account work-acct (keyring)
          - Active account: true
          ✓ Logged in to github.com account third (keyring)
          - Active account: false
        """
        XCTAssertEqual(GitHub.parseAccounts(status), ["work-acct", "first-one", "third"])
        XCTAssertEqual(GitHub.parseAccounts("You are not logged into any GitHub hosts."), [])
        XCTAssertTrue(GitHub.notVisible("GraphQL: Could not resolve to a Repository with the name 'x/y'. (repository)"))
        XCTAssertFalse(GitHub.notVisible("error connecting to api.github.com"))
    }
}

final class DBPasteTests: XCTestCase {
    func testURLEnvCommandAndCompose() {
        let u = DBPaste.parse("DATABASE_URL=postgres://atlas:pw@localhost:5432/atlas_dev")
        XCTAssertEqual(u?.flavor, .postgres); XCTAssertEqual(u?.database, "atlas_dev"); XCTAssertEqual(u?.user, "atlas"); XCTAssertEqual(u?.password, "pw")

        let laravel = DBPaste.parse("""
        DB_CONNECTION=mysql
        DB_HOST=127.0.0.1
        DB_PORT=3307
        DB_DATABASE=shop  # local copy
        DB_USERNAME=root
        DB_PASSWORD="se cret"
        """)
        XCTAssertEqual(laravel?.flavor, .mysql); XCTAssertEqual(laravel?.port, 3307); XCTAssertEqual(laravel?.database, "shop"); XCTAssertEqual(laravel?.password, "se cret")

        let psql = DBPaste.parse("psql -h db.local -p 6432 -U app -d orders")
        XCTAssertEqual(psql?.host, "db.local"); XCTAssertEqual(psql?.port, 6432); XCTAssertEqual(psql?.user, "app"); XCTAssertEqual(psql?.database, "orders")
        XCTAssertEqual(DBPaste.parse("psql 'postgresql://u:p@h:5433/d'")?.port, 5433)

        let my = DBPaste.parse("mysql -h 10.0.0.5 -P 3306 -uadmin -psecret inventory")
        XCTAssertEqual(my?.flavor, .mysql); XCTAssertEqual(my?.user, "admin"); XCTAssertEqual(my?.password, "secret"); XCTAssertEqual(my?.database, "inventory")

        let compose = DBPaste.parse("""
        db:
          image: postgres:16
          ports:
            - "5433:5432"
          environment:
            POSTGRES_USER: atlas
            POSTGRES_PASSWORD: pw
            POSTGRES_DB: atlas_dev
        """)
        XCTAssertEqual(compose?.flavor, .postgres); XCTAssertEqual(compose?.port, 5433); XCTAssertEqual(compose?.user, "atlas")
        XCTAssertEqual(compose?.database, "atlas_dev"); XCTAssertEqual(compose?.dockerContainer, "db")

        XCTAssertNil(DBPaste.parse("hello world"))
        XCTAssertEqual(DBPaste.masked("postgres://a:pw@h/d", password: "pw"), "postgres://a:••••••@h/d")
    }

    func testDockerPSFindsDatabaseContainers() {
        let out = "cv-backend-db\tpostgres:16\t0.0.0.0:5433->5432/tcp, :::5433->5432/tcp\nweb\tnginx:1.27\t0.0.0.0:80->80/tcp\nshop-db\tmariadb:11\t3306/tcp\n"
        let c = DBDiscovery.parseDockerPS(out)
        XCTAssertEqual(c.map(\.dockerContainer), ["cv-backend-db", "shop-db"])
        XCTAssertEqual(c[0].port, 5433)
        XCTAssertNil(c[1].port)
        XCTAssertEqual(c[1].flavor, .mariadb)
    }
}

final class CompatibilityTests: XCTestCase {
    /// A connection saved by an older Brix (before these fields existed) still loads.
    func testOldDatabaseConnectionDecodes() throws {
        let old = #"{"id":"x","name":"atlas","kind":"postgres","host":"localhost","port":5432,"database":"a","user":"u","filePath":"","sslMode":"prefer","tag":"dev","readOnly":false,"isSample":false,"writeUnlocked":false}"#
        let d = try JSONDecoder().decode(DatabaseConnection.self, from: Data(old.utf8))
        XCTAssertEqual(d.name, "atlas")
        XCTAssertEqual(d.agentAccess, .schema)
        XCTAssertEqual(d.route, .direct)
        let oldProject = #"{"id":"p","name":"p","path":"~/p","language":"","framework":"","hue":"violet","isPinned":false,"lastOpened":0}"#
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: Data(oldProject.utf8)).name, "p")
    }
}

extension CompatibilityTests {
    func testMergeKeepsNewestAndAddsTheRest() {
        var a = Library(); var b = Library()
        a.projects = [Project(id: "p", name: "new name", path: "~/p", language: "", framework: "", hue: .violet, isPinned: false, lastOpened: Date())]
        b.projects = [Project(id: "p", name: "old name", path: "~/p", language: "", framework: "", hue: .violet, isPinned: false, lastOpened: Date()),
                      Project(id: "q", name: "q", path: "~/q", language: "", framework: "", hue: .green, isPinned: false, lastOpened: Date())]
        b.hosts = [SSHHost(id: "h", name: "dev", host: "dev.local", user: "u", tag: .dev)]
        let m = AppStore.merge([a, b])
        XCTAssertEqual(m.projects.map(\.name), ["new name", "q"])
        XCTAssertEqual(m.hosts.map(\.id), ["h"])
    }
}

extension DBPasteTests {
    func testContainerEnvFillsCredentials() {
        let pg = DBDiscovery.parseDockerPS("shop-db-1\tpostgis/postgis:17-3.5\t0.0.0.0:5433->5432/tcp\n")[0]
        let p = DBDiscovery.applyContainerEnv("PATH=/usr/bin\nPOSTGRES_USER=shop\nPOSTGRES_PASSWORD=s3cret\nPOSTGRES_DB=shop\n", to: pg)
        XCTAssertEqual([p.user, p.password, p.database, "\(p.port ?? 0)"], ["shop", "s3cret", "shop", "5433"])
        let my = DBDiscovery.parseDockerPS("db\tmariadb:lts\t0.0.0.0:3307->3306/tcp\n")[0]
        let root = DBDiscovery.applyContainerEnv("MARIADB_ROOT_PASSWORD=r\nMARIADB_DATABASE=gac\n", to: my)
        XCTAssertEqual([root.user, root.password, root.database], ["root", "r", "gac"])
        let app = DBDiscovery.applyContainerEnv("MYSQL_ROOT_PASSWORD=r\nMYSQL_USER=app\nMYSQL_PASSWORD=a\n", to: my)
        XCTAssertEqual([app.user, app.password], ["app", "a"])
    }
}
