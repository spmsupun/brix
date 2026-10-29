import XCTest
@testable import Brix

final class LinkTests: XCTestCase {
    func testLinkUnlinkAndSharedCounts() {
        var l = ProjectLinks()
        l.link("web", "dev", kind: .host)
        l.link("api", "dev", kind: .host)
        l.link("web", "db1", kind: .database)
        XCTAssertTrue(l.isLinked("web", "dev"))
        XCTAssertEqual(l.projects(for: "dev"), ["api", "web"])
        XCTAssertEqual(l.count(of: .host, for: "web"), 1)
        XCTAssertEqual(l.resources(of: .database, for: "web"), ["db1"])
        l.unlink("web", "dev")
        XCTAssertFalse(l.isLinked("web", "dev"))
        XCTAssertEqual(l.projects(for: "dev"), ["api"])
    }

    func testLinkingTwiceIsIdempotent() {
        var l = ProjectLinks()
        l.link("web", "dev", kind: .host)
        l.link("web", "dev", kind: .host)
        XCTAssertEqual(l.pairs.count, 1)
    }

    func testDeletingResourceCleansUpLinks() {
        var l = MockData.links
        XCTAssertEqual(l.projects(for: "dev").count, 2)
        l.removeResource("dev")
        XCTAssertTrue(l.projects(for: "dev").isEmpty)
        XCTAssertTrue(l.isLinked("atlas-web", "staging"), "Other links survive")
    }

    func testRemovingProjectCleansUpLinks() {
        var l = MockData.links
        l.removeProject("atlas-web")
        XCTAssertFalse(l.pairs.contains { $0.project == "atlas-web" })
        XCTAssertEqual(l.projects(for: "dev"), ["atlas-api"])
    }

    func testSampleCountsMatchDesign() {
        let l = MockData.links
        XCTAssertEqual(l.count(of: .host, for: "atlas-web"), 3)
        XCTAssertEqual(l.count(of: .database, for: "atlas-web"), 2)
        XCTAssertEqual(l.count(of: .docker, for: "atlas-web"), 4)
    }

    @MainActor
    func testStoreRemoveHostCascades() {
        let store = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                             keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"), loadFromDisk: false)
        store.loadSampleWorkspace()
        store.requestRemoveHost("dev")
        store.confirmation?.action()
        XCTAssertNil(store.host("dev"))
        XCTAssertTrue(store.library.links.projects(for: "dev").isEmpty)
    }
}

final class FuzzyTests: XCTestCase {
    func testMatchesSubsequence() {
        XCTAssertNotNil(FuzzyMatcher.score("pf", "PaymentForm.tsx"))
        XCTAssertNil(FuzzyMatcher.score("xyz", "PaymentForm.tsx"))
        XCTAssertEqual(FuzzyMatcher.score("", "anything"), 0)
    }

    func testPrefixAndWordStartsRankHigher() {
        let prefix = FuzzyMatcher.score("pay", "payments")!
        let middle = FuzzyMatcher.score("pay", "repayments")!
        XCTAssertGreaterThan(prefix, middle)
        let camel = FuzzyMatcher.score("pf", "PaymentForm.tsx")!
        let scattered = FuzzyMatcher.score("pf", "pnpm-lock-file.json")!
        XCTAssertGreaterThanOrEqual(camel, scattered - 2)
    }

    func testConsecutiveBeatsScattered() {
        XCTAssertGreaterThan(FuzzyMatcher.score("intent", "intent.ts")!, FuzzyMatcher.score("intent", "i-n-t-e-n-t.ts")!)
    }

    func testShorterCandidateWinsTies() {
        XCTAssertGreaterThan(FuzzyMatcher.score("page", "page.tsx")!, FuzzyMatcher.score("page", "page-with-a-very-long-name-indeed.tsx")!)
    }
}

final class KeychainTests: XCTestCase {
    func testSetGetUpdateDelete() throws {
        let kc = Keychain(service: "com.brix.tests.\(UUID().uuidString)")
        let account = "ssh:test"
        defer { try? kc.delete(account) }
        XCTAssertNil(try kc.get(account))
        try kc.set("first", for: account)
        XCTAssertEqual(try kc.get(account), "first")
        try kc.set("second", for: account)
        XCTAssertEqual(try kc.get(account), "second")
        XCTAssertTrue(kc.has(account))
        try kc.delete(account)
        XCTAssertNil(try kc.get(account))
        XCTAssertNoThrow(try kc.delete(account), "Deleting a missing item is fine")
    }
}

final class ParserTests: XCTestCase {
    func testPorcelainV2() {
        let raw = [
            "# branch.oid 9f1c2ab", "# branch.head feat/x", "# branch.upstream origin/feat/x", "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 aaa bbb src/a.ts",
            "1 .M N... 100644 100644 100644 aaa bbb src/b.ts",
            "1 MM N... 100644 100644 100644 aaa bbb src/c.ts",
            "2 R. N... 100644 100644 100644 aaa bbb R100 src/new name.ts", "src/old.ts",
            "? notes.md", ""
        ].joined(separator: "\0")
        let s = LiveGitService.parseStatus(raw)
        XCTAssertEqual(s.branch, "feat/x")
        XCTAssertEqual(s.ahead, 2)
        XCTAssertEqual(s.behind, 1)
        XCTAssertEqual(s.entries.map(\.path), ["src/a.ts", "src/b.ts", "src/c.ts", "src/new name.ts", "notes.md"])
        XCTAssertEqual(s.entries[0].staged, .M); XCTAssertNil(s.entries[0].worktree)
        XCTAssertNil(s.entries[1].staged); XCTAssertEqual(s.entries[1].worktree, .M)
        XCTAssertEqual(s.entries[2].staged, .M); XCTAssertEqual(s.entries[2].worktree, .M)
        XCTAssertEqual(s.entries[4].worktree, .U)
    }

    func testNumstat() {
        let raw = "3\t1\tsrc/a.ts\0-\t-\timg.png\0"
        let m = LiveGitService.parseNumstat(raw)
        XCTAssertEqual(m["src/a.ts"]?.0, 3)
        XCTAssertEqual(m["src/a.ts"]?.1, 1)
        XCTAssertEqual(m["img.png"]?.0, 0)
    }

    func testUnifiedDiff() {
        let text = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
        """
        let d = LiveGitService.parseDiff(text, path: "x")
        XCTAssertEqual(d.add, 1)
        XCTAssertEqual(d.del, 1)
        XCTAssertEqual(d.lines.map(\.kind), [.hunk, .context, .del, .add, .context])
        XCTAssertEqual(d.lines[2].old, 2)
        XCTAssertEqual(d.lines[3].new, 2)
    }

    func testGutterMarksFromDiff() {
        let d = MockData.paymentFormDiff
        let marks = WorkspaceStore.marks(from: d, status: .M)
        XCTAssertTrue(marks.contains { $0.lines.contains(3) && $0.status == .M }, "Delete then add is a modification")
        XCTAssertTrue(marks.contains { $0.lines.contains(42) && $0.status == .A }, "Pure additions are green")
    }

    @MainActor func testWriteDetection() {
        XCTAssertTrue(AppStore.isWrite("update payments set status = 'x' where id = 1"))
        XCTAssertTrue(AppStore.isWrite("  DELETE FROM users"))
        XCTAssertTrue(AppStore.isWrite("-- comment\ndrop table t"))
        XCTAssertFalse(AppStore.isWrite("select * from updates_log"))
        XCTAssertFalse(AppStore.isWrite("-- update everything later\nselect 1"))
    }

    func testSQLFormatter() {
        let f = SQLFormatter.format("select a, b from t where x = 'a, b' and y = 2 order by a")
        XCTAssertTrue(f.contains("\nfrom t"))
        XCTAssertTrue(f.contains("\nwhere"))
        XCTAssertTrue(f.contains("\n  and y = 2"))
        XCTAssertTrue(f.contains("'a, b'"), "Strings are left alone")
    }

    func testMetricsParse() {
        let m = LiveMetricsService.parse("OS=Ubuntu 24.04 LTS\nLOAD=0.50 0.40 0.30\nCPUS=2\nMEM=0.6100\nDISK=0.4800\nUP=up 3 days, 2 hours\n")
        XCTAssertEqual(m.os, "Ubuntu 24.04 LTS")
        XCTAssertEqual(m.cpu, 0.25, accuracy: 0.001)
        XCTAssertEqual(m.memory, 0.61, accuracy: 0.001)
        XCTAssertEqual(m.uptime, "3 days, 2 hours")
    }

    func testDockerPSParse() {
        let line = #"{"Names":"web-1","Image":"nginx:1.27","Ports":"0.0.0.0:8080->80/tcp, :::8080->80/tcp","State":"running","Status":"Up 2 hours","Labels":"com.docker.compose.project=site,com.docker.compose.service=web"}"#
        let t = LiveDockerService.parsePS(line, hostID: nil)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].name, "web-1")
        XCTAssertEqual(t[0].state, .running)
        XCTAssertEqual(t[0].ports, ":8080")
        XCTAssertEqual(t[0].composeProject, "site")
    }

    func testCSVEscaping() {
        let csv = DataGrid.csv(columns: [DBColumn(name: "a", type: ""), DBColumn(name: "b", type: "")], rows: [["x,y", nil], ["say \"hi\"", "z"]])
        XCTAssertEqual(csv, "a,b\n\"x,y\",\n\"say \"\"hi\"\"\",z\n")
    }

    func testAgentLaunchCommandHasNamesNotSecrets() {
        let claude = AgentConfig.builtins.first { $0.id == "claude" }!
        let cmd = claude.launchCommand(resourceNames: ["Development Server", "atlas_dev"])
        XCTAssertTrue(cmd.hasPrefix("claude --append-system-prompt "))
        XCTAssertTrue(cmd.contains("Development Server"))
        XCTAssertFalse(cmd.lowercased().contains("password"))
        // Other CLIs don't take the flag, so they start plain.
        let codex = AgentConfig.builtins.first { $0.id == "codex" }!
        XCTAssertEqual(codex.launchCommand(resourceNames: ["atlas_dev"]), "codex")
    }

    func testAgentListKeepsUserOrderAndAddsNewBuiltins() {
        let custom = AgentConfig(id: "custom-1", name: "Aider", command: "aider")
        let merged = AgentConfig.mergingBuiltins([custom, AgentConfig.builtins[1]])
        XCTAssertEqual(merged.first?.id, "custom-1")
        XCTAssertEqual(merged.count, AgentConfig.builtins.count + 1)
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count)
    }

    func testCodexUsageParsing() {
        let future = Date().timeIntervalSince1970 + 3600
        let w = AgentUsageReader.parseCodex(["primary": ["used_percent": 3.0, "window_minutes": 10080, "resets_at": future],
                                             "secondary": ["used_percent": 40.0, "window_minutes": 300, "resets_at": 1]])
        XCTAssertEqual(w.map(\.label), ["7d", "5h"])
        XCTAssertEqual(w[0].percent, 3)
        XCTAssertEqual(w[1].percent, 0, "a window that already reset reads as zero")
    }

    func testClaudeUsageReadsCachedLimits() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        let dir = home.appendingPathComponent(".claude/state")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let future = Int(Date().timeIntervalSince1970) + 3600
        try #"{"five_hour":{"used_percentage":12,"resets_at":\#(future)},"seven_day":{"used_percentage":19,"resets_at":\#(future)}}"#
            .write(to: dir.appendingPathComponent("rate-limits.json"), atomically: true, encoding: .utf8)
        let w = AgentUsageReader.claude(home: home.path)
        XCTAssertEqual(w.map(\.label), ["5h", "7d"])
        XCTAssertEqual(w.map(\.percent), [12, 19])
    }

    @MainActor func testProjectDetection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("detect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"dependencies":{"next":"15.0.0","react":"19"}}"#.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
        let d = AppStore.detect(url: dir)
        XCTAssertEqual(d.language, "TypeScript")
        XCTAssertEqual(d.framework, "Next.js · TypeScript")
        XCTAssertFalse(d.isGitRepo)
    }
}

final class PersistenceSafetyTests: XCTestCase {
    func testCorruptProjectsThrowInsteadOfEmptying() {
        let json = #"{"projects":[{"id":1}],"hosts":[]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Library.self, from: Data(json.utf8)))
    }

    func testMissingKeysDefault() throws {
        let lib = try JSONDecoder().decode(Library.self, from: Data("{}".utf8))
        XCTAssertTrue(lib.projects.isEmpty)
        XCTAssertFalse(lib.hasOnboarded)
    }

    @MainActor
    func testUnreadableLibraryIsBackedUp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brix-corrupt-\(UUID().uuidString)")
        let persistence = Persistence(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"projects":"oops"}"#.utf8).write(to: persistence.url("library.json"))
        let store = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: persistence, keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("library.unreadable-") }, "The unreadable file is kept")
        XCTAssertTrue(store.toasts.contains { $0.kind == .error })
    }
}

final class LiveSQLiteTests: XCTestCase {
    func testSchemaRowsAndReadOnlyGuard() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("brix-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: nil))
        let svc = LiveDatabaseService()
        var c = DatabaseConnection(id: "t", name: "t.sqlite", kind: .sqlite, filePath: path, tag: .local)
        _ = try await svc.execute(c, sql: "create table users (id integer primary key, email text not null, note text)", password: nil)
        _ = try await svc.execute(c, sql: "insert into users (email, note) values ('a@x.io', null), ('b@x.io', 'hi')", password: nil)
        let tree = try await svc.schema(c, password: nil)
        let users = try XCTUnwrap(tree.schemas["main"]?.first { $0.name == "users" })
        let rows = try await svc.rows(c, object: users, filter: "", sort: ("email", false), page: 0, pageSize: 50, password: nil)
        XCTAssertEqual(rows.totalRows, 2)
        XCTAssertEqual(rows.rows.first?[1], "b@x.io")
        XCTAssertNil(rows.rows.last?[2], "NULL comes back as nil")
        let detail = try await svc.tableDetail(c, object: users, password: nil)
        XCTAssertTrue(detail.columns.first { $0.name == "id" }?.isPK ?? false)
        c.readOnly = true
        do {
            _ = try await svc.execute(c, sql: "delete from users", password: nil)
            XCTFail("Read-only connection must refuse writes")
        } catch {}
        c.writeUnlocked = true
        let r = try await svc.execute(c, sql: "delete from users where id = 1", password: nil)
        XCTAssertEqual(r.message, "1 row affected")
    }
}

final class AgentHistoryFilterTests: XCTestCase {
    /// Headless `claude -p` runs stay out of the session list, like Claude Code's /resume.
    func testHeadlessClaudeRunsAreHidden() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func session(_ entrypoint: String) throws -> URL {
            let url = dir.appendingPathComponent("\(entrypoint).jsonl")
            try #"{"type":"user","entrypoint":"\#(entrypoint)","cwd":"/p","message":{"role":"user","content":"hi"}}"#.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        XCTAssertNotNil(AgentTranscripts.claudeEntry(try session("cli")))
        XCTAssertNotNil(AgentTranscripts.claudeEntry(try session("claude-desktop")))
        XCTAssertNil(AgentTranscripts.claudeEntry(try session("sdk-cli")))
    }
}

final class ClaudeLiveSessionTests: XCTestCase {
    /// A /resume inside Claude changes the id in ~/.claude/sessions/<pid>.json; Brix follows it.
    func testReadsTheConversationAProcessIsOn() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"pid":4242,"sessionId":"8d0a95ca-2908-45cb-aba1-6ad45edb6c42"}"#.write(to: dir.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
        try #"{"pid":7,"sessionId":"../../etc"}"#.write(to: dir.appendingPathComponent("7.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentTranscripts.claudeLiveSessionID(pid: 4242, home: home.path), "8d0a95ca-2908-45cb-aba1-6ad45edb6c42")
        XCTAssertNil(AgentTranscripts.claudeLiveSessionID(pid: 7, home: home.path))
        XCTAssertNil(AgentTranscripts.claudeLiveSessionID(pid: 99, home: home.path))
    }
}

final class DockerLastActiveTests: XCTestCase {
    func testReadsAgeFromDockerStatus() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        XCTAssertEqual(DockerTarget.ago("Exited (0) 8 days ago", now: now), now.addingTimeInterval(-8 * 86_400))
        XCTAssertEqual(DockerTarget.ago("Exited (137) About an hour ago", now: now), now.addingTimeInterval(-3600))
        XCTAssertEqual(DockerTarget.ago("Exited (255) 2 hours ago", now: now), now.addingTimeInterval(-7200))
        XCTAssertNil(DockerTarget.ago("Created", now: now))
        XCTAssertEqual(PageBar.slice(Array(0..<60), page: 2).first, 50)
        XCTAssertEqual(PageBar.slice(Array(0..<60), page: 9).first, 50, "a page past the end shows the last page")
        XCTAssertEqual(PageBar.slice([Int](), page: 3).count, 0)
    }
}

final class DockerAgoEdgeTests: XCTestCase {
    func testUnknownCountIsNotNow() {
        XCTAssertNil(DockerTarget.ago("Exited (0) several days ago", now: Date()))
    }
}

final class ClaudePlanTests: XCTestCase {
    /// Tasks come from TaskCreate results and TaskUpdate calls, read again as the file grows.
    func testReadsTasksAndFollowsAppends() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        func line(_ content: String) -> String { #"{"type":"assistant","message":{"content":[\#(content)]}}"# + "\n" }
        var text = line(#"{"type":"tool_use","name":"TaskCreate","input":{"subject":"Write tests"}}"#)
        text += line(#"{"type":"tool_result","content":"Task #1 created successfully: Write tests"}"#)
        text += line(#"{"type":"tool_result","content":"Task #2 created successfully: Ship it"}"#)
        text += line(#"{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"in_progress"}}"#)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let reader = AgentTranscripts.PlanReader()
        XCTAssertEqual(reader.read(url), [PlanItem(title: "Write tests", done: false, active: true), PlanItem(title: "Ship it", done: false)])
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(line(#"{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}"#).utf8))
        try h.close()
        XCTAssertEqual(reader.read(url)?.first, PlanItem(title: "Write tests", done: true))
    }
}
