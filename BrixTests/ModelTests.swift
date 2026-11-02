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

    func testIgnoresAccentsAndWidth() {
        XCTAssertNotNil(FuzzyMatcher.score("ecole", "école"))
        XCTAssertNotNil(FuzzyMatcher.score("ECOLE", "École"))
        XCTAssertNotNil(FuzzyMatcher.score("école", "ecole"))
        XCTAssertNotNil(FuzzyMatcher.score("ab", "ａｂ"))
        XCTAssertEqual(FuzzyMatcher.score("ecole", "école"), FuzzyMatcher.score("ecole", "ecole"))
    }
}

@MainActor
final class PaletteRankTests: XCTestCase {
    private func item(_ group: String, _ title: String, boost: Int = 0) -> CommandItem {
        CommandItem(id: "\(group):\(title)", group: group, title: title, sub: "", glyph: "", action: {}, boost: boost)
    }

    func testGroupsMatchExactlyNotByPrefix() {
        let items = [item("DATABASES", "orders db"), item("SERVERS", "dev"), item("DATA", "users table"), item("FILES IN WEB", "a.ts")]
        // DATABASES is its own group, after SERVERS; it isn't DATA.
        XCTAssertEqual(CommandCatalog.rank(items, query: "").map(\.group), ["FILES IN WEB", "DATA", "SERVERS", "DATABASES"])
    }

    func testGroupsNeverInterleave() {
        let items = [item("FILES IN A", "x1", boost: 1), item("FILES IN B", "x2", boost: 3), item("FILES IN A", "x3", boost: 5)]
        XCTAssertEqual(CommandCatalog.rank(items, query: "").map(\.group), ["FILES IN A", "FILES IN A", "FILES IN B"])
        let ranked = CommandCatalog.rank(items, query: "x").map(\.group)
        XCTAssertEqual(ranked.firstIndex(of: "FILES IN B").map { ranked[$0...].contains("FILES IN A") }, false)
    }
}

@MainActor
final class AgentTimeTests: XCTestCase {
    func testRunOverMidnightIsSplitBetweenDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 23))!
        let end = cal.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 1, minute: 30))!
        let parts = AppStore.splitByDay(from: start, to: end, calendar: cal)
        XCTAssertEqual(parts.map(\.seconds), [3600, 5400])
        XCTAssertEqual(parts.map { cal.component(.day, from: $0.day) }, [1, 2])
        XCTAssertTrue(AppStore.splitByDay(from: end, to: start, calendar: cal).isEmpty)
    }
}

@MainActor
final class FileEditorWriteTests: XCTestCase {
    func testSaveKeepsSymlinkAndExecutableBit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("run.sh")
        try "echo hi".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let link = dir.appendingPathComponent("link.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let resolved = FileEditorSheet.resolved(link.path)
        try FileEditorSheet.writeKeepingMode("echo bye", to: resolved)
        XCTAssertNotNil(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "echo bye")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: resolved.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }
}

final class NestedRepoRemovalTests: XCTestCase {
    @MainActor
    func testRemovingParentForgetsHiddenChildren() {
        let store = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                             keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"), loadFromDisk: false)
        let root = "/tmp/brix-mono-\(UUID().uuidString)"
        func project(_ id: String, _ path: String, parent: String? = nil) -> Project {
            var p = Project(id: id, name: id, path: path, language: "", framework: "", hue: .violet, isPinned: false, lastOpened: Date())
            p.parentID = parent
            return p
        }
        store.library.projects = [project("mono", root), project("mono-web", root + "/web", parent: "mono"), project("mono-api", root + "/api", parent: "mono")]
        store.removeProject("mono-web")
        XCTAssertEqual(store.library.dismissedRepos, [root + "/web"])
        store.removeProject("mono")
        XCTAssertTrue(store.library.projects.isEmpty)
        // Neither the one removed alone nor the one removed with the parent stays hidden.
        XCTAssertTrue(store.library.dismissedRepos.isEmpty)
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

    func testPorcelainInSubfolderRenameAndConflict() {
        let raw = [
            "# branch.head main",
            "1 .M N... 100644 100644 100644 aaa bbb sub/a.txt",
            "1 .M N... 100644 100644 100644 aaa bbb a.txt",
            "2 R. N... 100644 100644 100644 aaa bbb R100 sub/new.txt", "sub/old.txt",
            "2 R. N... 100644 100644 100644 aaa bbb R100 sub/moved.txt", "other/moved.txt",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc sub/c.txt",
            "? sub/n.txt", "? other/x.txt", ""
        ].joined(separator: "\0")
        let s = LiveGitService.parseStatus(raw, prefix: "sub/")
        XCTAssertEqual(s.entries.map(\.path), ["a.txt", "new.txt", "moved.txt", "c.txt", "n.txt"], "Only the project's own files, relative to it")
        XCTAssertEqual(s.entries[1].origPath, "old.txt")
        XCTAssertEqual(s.entries[2].origPath, ":/other/moved.txt", "A source outside the project is a top-level pathspec")
        XCTAssertTrue(s.entries[3].conflict)
        XCTAssertFalse(s.entries[0].conflict)
    }

    func testCommitFilesFromRawNumstat() {
        let raw = "\0:100644 100644 01e79c3 01e79c3 R100\0old.txt\0sub/new.txt\0:000000 100644 0000000 c600332 A\0sub/ünï.txt\0"
            + "0\t0\t\0old.txt\0sub/new.txt\0" + "1\t0\tsub/ünï.txt\0"
        let f = LiveGitService.parseShowFiles(raw)
        XCTAssertEqual(f.map(\.path), ["sub/new.txt", "sub/ünï.txt"])
        XCTAssertEqual(f[0].origPath, "old.txt")
        XCTAssertEqual(f[1].status, .A)
        XCTAssertEqual(f[1].add, 1)
    }

    func testDockerCommandsQuoteEveryArgument() {
        let c = DockerTarget(id: "x", name: "web$(id)", image: "", ports: "", hostID: nil, state: .running)
        XCTAssertTrue(LiveDockerService.shell(c, host: nil).hasPrefix("'docker' 'exec' '-it' 'web$(id)' "))
        XCTAssertEqual(LiveDockerService.follow(c, host: nil), "'docker' 'logs' '--tail' '200' '-f' 'web$(id)'")
        let h = SSHHost(id: "h", name: "h", host: "example.com", user: "deploy", tag: .dev)
        let remote = LiveDockerService.follow(c, host: h)
        XCTAssertTrue(remote.contains("'deploy@example.com'"))
        XCTAssertTrue(remote.hasSuffix(ProcessRunner.shellQuote("'docker' 'logs' '--tail' '200' '-f' 'web$(id)'")), "The remote command is quoted again for the local shell")
        let stack = ComposeStack(id: "s", name: "site", hostID: nil, configFiles: ["x;id", "~/a b/compose.yaml"])
        XCTAssertEqual(LiveDockerService().composeLogsCommand(stack, host: nil),
                       "'docker' 'compose' '-f' 'x;id' '-f' ~/'a b/compose.yaml' '-p' 'site' 'logs' '--tail' '200' '-f'")
        XCTAssertTrue(LiveDockerService.isValidName("atlas-api_1.web"))
        XCTAssertFalse(LiveDockerService.isValidName("web$(id)"))
        XCTAssertFalse(LiveDockerService.isValidName("-rm"))
        XCTAssertFalse(LiveDockerService.isValidName(""))
    }

    func testSSHArgsShareOneConnectionAndEndOptions() {
        var h = SSHHost(id: "h", name: "h", host: "10.0.0.5", user: "deploy", tag: .dev)
        let a = SSHCommand.args(h, batch: true)
        XCTAssertTrue(a.contains("ControlMaster=auto"))
        XCTAssertLessThan(SSHCommand.controlPath.replacingOccurrences(of: "%C", with: String(repeating: "x", count: 40)).utf8.count + 17, 104,
                          "Socket path (plus ssh's temporary suffix) fits in sun_path")
        XCTAssertEqual(Array(a.suffix(2)), ["--", "deploy@10.0.0.5"])
        h.alias = "web-prod"
        XCTAssertEqual(SSHCommand.args(h, batch: true).last, "deploy@web-prod", "Imported hosts connect through their ~/.ssh/config alias")
        XCTAssertTrue(SSHCommand.invalidPart("-oProxyCommand=x"))
        XCTAssertTrue(SSHCommand.invalidPart("a b"))
        XCTAssertFalse(SSHCommand.invalidPart("deploy"))
    }

    func testAskpassAnswersOnlyPasswordPrompts() async throws {
        func ask(_ prompt: String) async throws -> ProcessOutput {
            try await ProcessRunner.run("/bin/sh", ["-c", SSHCommand.askpassScript, "askpass", prompt], env: ["BRIX_ASKPASS_SECRET": "s3cret"])
        }
        let pw = try await ask("deploy@10.0.0.5's password: ")
        XCTAssertEqual(pw.stdout, "s3cret\n")
        let hostKey = try await ask("Are you sure you want to continue connecting (yes/no/[fingerprint])? ")
        XCTAssertFalse(hostKey.ok)
        XCTAssertEqual(hostKey.stdout, "", "A host key question never gets the password")
    }

    func testRemoteSaveRefusesAChangedFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brix-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("conf.txt").path, upload = dir.appendingPathComponent(".conf.txt.up").path
        try "old\n".write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file)
        let stamp = try await ProcessRunner.check("/bin/sh", ["-c", RemoteFiles.stampCommand(file)]).trimmingCharacters(in: .whitespacesAndNewlines)

        try "new\n".write(toFile: upload, atomically: true, encoding: .utf8)
        let stale = try await ProcessRunner.run("/bin/sh", ["-c", RemoteFiles.replaceCommand(file, with: upload, stamp: "1 1")])
        XCTAssertEqual(stale.status, 5)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "old\n", "A file changed since it was read is left alone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: upload))

        try "new\n".write(toFile: upload, atomically: true, encoding: .utf8)
        let ok = try await ProcessRunner.run("/bin/sh", ["-c", RemoteFiles.replaceCommand(file, with: upload, stamp: stamp)])
        XCTAssertTrue(ok.ok, ok.stderr)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "new\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int), 0o640, "Keeps the file's mode")
        XCTAssertFalse(ok.stdout.isEmpty, "Prints the new stamp for the next save")
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
        // Keywords in strings and comments aren't writes.
        XCTAssertFalse(AppStore.isWrite("SELECT 'delete' as w"))
        XCTAssertFalse(AppStore.isWrite("/* delete */ select 1"))
        XCTAssertFalse(AppStore.isWrite("select 1 -- ; delete"))
        XCTAssertTrue(AppStore.isWrite("select 1 /*! ; delete from t */", kind: .mysql), "MySQL runs /*! … */")
    }

    func testAgentPolicy() {
        let check = { (a: AgentDBAccess, sql: String, k: DBKind) in AgentDBPolicy.check(a, sql: sql, production: false, kind: k) }
        XCTAssertEqual(check(.read, "SELECT 'delete' as w", .postgres), .allow)
        XCTAssertEqual(check(.read, "select * from t", .mysql), .allow)
        // Transactions and settings: never, at any level.
        for sql in ["BEGIN READ WRITE", "start transaction", "commit", "SET GLOBAL read_only = 0", "set default_transaction_read_only = off", "select 1; rollback"] {
            if case .deny = check(.write, sql, .postgres) {} else { XCTFail(sql) }
        }
        if case .deny = check(.read, "select set_config('default_transaction_read_only', 'off', false)", .postgres) {} else { XCTFail("set_config") }
        if case .deny = check(.write, "select pg_terminate_backend(42)", .postgres) {} else { XCTFail("pg_terminate_backend") }
        if case .deny = check(.read, "select U&\"\\0070g_read_file\"('x')", .postgres) {} else { XCTFail("U& escapes") }
        // Anything not known to read asks at write level and is refused at read.
        for sql in ["DO $$ BEGIN DELETE FROM t; END $$", "CALL purge()", "COPY t FROM '/tmp/x'", "LOAD DATA INFILE 'x' INTO TABLE t", "KILL 12", "FLUSH TABLES", "PURGE BINARY LOGS TO 'x'"] {
            let k: DBKind = sql.hasPrefix("DO") || sql.hasPrefix("CALL") || sql.hasPrefix("COPY") ? .postgres : .mysql
            XCTAssertEqual(check(.write, sql, k), .ask, sql)
            if case .deny = check(.read, sql, k) {} else { XCTFail(sql) }
        }
        XCTAssertEqual(AgentDBPolicy.check(.write, sql: "CALL purge()", production: true, kind: .postgres), .deny("Production databases are read-only for agents."))
        if case .deny = check(.read, "select * from t into/**/outfile '/tmp/x'", .mysql) {} else { XCTFail("into outfile behind a comment") }
        if case .deny = check(.read, "with d as (delete from t returning *) select * from d", .postgres) {} else { XCTFail("data-changing WITH") }
    }

    func testAgentMasking() {
        XCTAssertTrue(AgentDBPolicy.sensitive("password_hash"))
        XCTAssertTrue(AgentDBPolicy.sensitive("passwordHash"))
        XCTAssertTrue(AgentDBPolicy.sensitive("refresh_token"))
        XCTAssertTrue(AgentDBPolicy.sensitive("totp_seed"))
        XCTAssertTrue(AgentDBPolicy.sensitive("session_id"))
        XCTAssertFalse(AgentDBPolicy.sensitive("rootpage"), "otp only as a whole part")
        XCTAssertFalse(AgentDBPolicy.sensitive("passenger"))
        let users = ["users": ["id", "email", "password_hash", "token"]]
        let m = { (cols: [String], sql: String) in AgentDBPolicy.masks(cols, sql: sql, known: users) }
        XCTAssertEqual(m(["id", "email", "password_hash"], "select * from users"), [false, false, true])
        XCTAssertEqual(m(["p"], "select password_hash as p from users"), [true], "an alias")
        XCTAssertEqual(m(["id"], "select password_hash as id from users"), [true], "an alias named like a plain column")
        XCTAssertEqual(m(["e"], "select email||password_hash as e from users"), [true], "an expression")
        XCTAssertEqual(m(["p"], "select p from (select password_hash p from users) s"), [true], "through a subquery")
        XCTAssertEqual(m(["u"], "select u from users u"), [true], "a whole row")
        XCTAssertEqual(m(["row_to_json"], "select row_to_json(u) from users u"), [true])
        XCTAssertEqual(m(["string_agg"], "select string_agg(token, ',') from users"), [true])
        XCTAssertEqual(m(["id"], "select id from users union select password_hash from users"), [true])
        XCTAssertEqual(m(["id", "email"], "select id, email from users where id > 3"), [false, false], "plain columns still show")
        // Nothing sensitive within reach: counts and expressions show.
        let orders = ["orders": ["id", "status", "total"]]
        XCTAssertEqual(AgentDBPolicy.masks(["status", "n"], sql: "select status, count(*) n from orders o group by status", known: orders), [false, false])
        XCTAssertEqual(AgentDBPolicy.masks(["a"], sql: "select a from pg_authid a", known: [:]), [true], "a table Brix doesn't know")
        XCTAssertEqual(AgentDBPolicy.masks(["rootpage"], sql: "select rootpage from sqlite_master", known: ["sqlite_master": ["type", "name", "rootpage"]]), [false])
        XCTAssertEqual(AgentDBPolicy.masks(["id"], sql: "select id from t", known: nil), [true], "unknown tables mask everything")
    }

    func testAgentGatewayRequests() {
        let req = { (s: String) in AgentDBGateway.parse(Data(s.utf8)) }
        XCTAssertEqual(req("POST /query HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc")?.body, Data("abc".utf8))
        XCTAssertNil(req("POST /query HTTP/1.1\r\nContent-Length: 5\r\n\r\nabc"), "more to come")
        XCTAssertEqual(req("POST /query HTTP/1.1\r\nContent-Length: -1\r\n\r\nabc")?.path, "", "a negative length is a bad request, not a crash")
        XCTAssertEqual(req("POST /query HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n")?.path, "")
        // Approval prompts show all of the SQL, padding squeezed.
        XCTAssertEqual(AgentDBPolicy.reviewable("select 1" + String(repeating: "\n", count: 500) + String(repeating: " ", count: 500) + "; drop table t"), "select 1\n ; drop table t")
        XCTAssertEqual(AgentDBPolicy.reviewable("a\u{200B}b"), "a\u{FFFD}b")
        XCTAssertNil(AgentDBPolicy.reviewable(String(repeating: "x ", count: 1500)))
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
        let json = #"{"projects":"oops","hosts":[]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Library.self, from: Data(json.utf8)))
    }

    /// One entry this build can't read is left out; the rest of the library loads.
    func testBadEntriesAreSkippedOneByOne() throws {
        let json = #"""
        {"projects": [{"id": "web", "name": "web", "path": "~/web"}, {"id": 1}],
         "hosts": [{"id": "h1", "name": "box", "host": "10.0.0.1", "tag": "qa"}],
         "databases": [{"id": "d1", "name": "pg", "kind": "postgres"}, {"id": "d2", "name": "redis", "kind": "redis"}],
         "docker": [{"id": "c1", "name": "web"}, {"name": "no-id"}],
         "stacks": [{"id": "s1", "name": "shop"}],
         "customPresets": [{"id": "p1", "name": "Mine"}],
         "links": {"pairs": [{"project": "web", "resource": "h1", "kind": "host"}, {"project": "web", "resource": "x", "kind": "queue"}]}}
        """#
        let lib = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        XCTAssertEqual(lib.projects.map(\.id), ["web"])
        XCTAssertEqual(lib.hosts.map(\.id), ["h1"])
        XCTAssertEqual(lib.databases.map(\.id), ["d1"])
        XCTAssertEqual(lib.docker.map(\.id), ["c1"])
        XCTAssertEqual(lib.stacks.map(\.id), ["s1"])
        XCTAssertEqual(lib.customPresets.map(\.id), ["p1"])
        XCTAssertEqual(lib.links.pairs.map(\.resource), ["h1"])
        XCTAssertEqual(lib.skippedOnLoad, 4, "the unknown link counts too, so a copy of the file is kept")
        let saved = try JSONSerialization.jsonObject(with: Persistence.encoder.encode(lib)) as? [String: Any]
        XCTAssertEqual(saved?["schemaVersion"] as? Int, Library.currentSchema)
        XCTAssertNil(saved?["skippedOnLoad"])
        XCTAssertNil((saved?["links"] as? [String: Any])?["skippedOnLoad"])
    }

    /// An agent settings.json can't read is counted, and the file is kept aside before it's saved without it.
    @MainActor
    func testUnreadableAgentKeepsSettingsCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brix-settings-\(UUID().uuidString)")
        let persistence = Persistence(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"accent":"lime","agents":[42]}"#.utf8).write(to: persistence.url("settings.json"))
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: persistence.url("settings.json")))
        XCTAssertEqual(settings.skippedOnLoad, 1)
        XCTAssertNil((try JSONSerialization.jsonObject(with: Persistence.encoder.encode(settings)) as? [String: Any])?["skippedOnLoad"])
        _ = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: persistence, keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("settings.partial-") })
    }

    /// A tag Brix doesn't know is Production, never Development.
    func testUnknownTagIsProduction() throws {
        let h = try JSONDecoder().decode(SSHHost.self, from: Data(#"{"id":"h","name":"box","host":"1.2.3.4","tag":"qa"}"#.utf8))
        XCTAssertEqual(h.tag, .prod)
        let d = try JSONDecoder().decode(DatabaseConnection.self, from: Data(#"{"id":"d","name":"db","kind":"mysql","tag":"PROD-EU"}"#.utf8))
        XCTAssertEqual(d.tag, .prod)
        XCTAssertEqual(try JSONDecoder().decode([EnvTag].self, from: Data(#"["dev","staging"]"#.utf8)), [.dev, .prod])
        XCTAssertEqual(EnvTag(file: "qa", guessFrom: "box"), .prod)
        XCTAssertEqual(EnvTag(file: nil, guessFrom: "box"), .dev)
    }

    func testAgentsLoadOneByOne() throws {
        let json = #"{"agents":[{"id":"mine","name":"Mine","command":"mine --fast"},{"name":"broken"},{"id":"bare"}]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(Array(s.agents.map(\.id).prefix(2)), ["mine", "bare"])
        XCTAssertTrue(s.agents.contains { $0.id == "claude" }, "builtins still added")
    }

    func testProjectIDsAreSlugs() {
        XCTAssertEqual(Project.makeID("Client/Web") { _ in false }, "client-web")
        XCTAssertEqual(Project.makeID("../../etc") { _ in false }, "etc")
        XCTAssertEqual(Project.makeID("Café  Ünïcode!") { _ in false }, "cafe-unicode")
        XCTAssertEqual(Project.makeID("...") { _ in false }, "project")
        let taken: Set = ["web", "web-2"]
        XCTAssertEqual(Project.makeID("Web") { taken.contains($0) }, "web-3")
        XCTAssertEqual(Project.makeID("api", prefix: "shop-") { _ in false }, "shop-api")
        // Ids from older builds still name one file inside workspaces/.
        XCTAssertEqual(Persistence.safeName("workspaces/client/web.json"), "workspaces/client%2Fweb.json")
        XCTAssertEqual(Persistence.safeName("workspaces/../x.json"), "workspaces/%2E.%2Fx.json")
        XCTAssertEqual(Persistence.safeName("workspaces/shop.json"), "workspaces/shop.json")
        XCTAssertEqual(Persistence.safeName("library.json"), "library.json")
    }

    /// Confirmations queue: a second one waits for the first, each runs its own
    /// action or onCancel exactly once.
    @MainActor
    func testConfirmationsQueueInOrder() {
        let store = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                             keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"), loadFromDisk: false)
        var log: [String] = []
        store.confirm("A", "", confirm: "OK", onCancel: { log.append("A no") }) { log.append("A yes") }
        store.confirm("B", "", confirm: "OK", onCancel: { log.append("B no") }) { log.append("B yes") }
        store.confirmation = Confirmation(title: "C", message: "", confirmTitle: "OK", action: { log.append("C yes") }, onCancel: { log.append("C no") })
        XCTAssertEqual(store.confirmations.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(store.confirmation?.title, "A", "the oldest shows first")
        let a = store.confirmations[0].id
        store.answerConfirmation(a, confirmed: true)
        store.answerConfirmation(a, confirmed: false) // the alert closing afterwards
        XCTAssertEqual(store.confirmations.map(\.title), ["B", "C"])
        store.answerConfirmation(store.confirmations[0].id, confirmed: false)
        store.confirmation = nil // dismissed without a button: still a no
        XCTAssertEqual(log, ["A yes", "B no", "C no"])
        XCTAssertTrue(store.confirmations.isEmpty)
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
        XCTAssertEqual(store.confirmations.first?.title, "Start with an empty library?")
        // Nothing is saved over it until the user chooses.
        store.saveNow()
        XCTAssertEqual(try String(contentsOf: persistence.url("library.json"), encoding: .utf8), #"{"projects":"oops"}"#)
        // Another failed launch doesn't add an identical copy.
        _ = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: dir), keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("library.unreadable-") }.count, 1)
        // Starting empty is the user's call; then saving resumes.
        store.answerConfirmation(store.confirmations[0].id, confirmed: true)
        store.saveNow()
        XCTAssertNotEqual(try String(contentsOf: persistence.url("library.json"), encoding: .utf8), #"{"projects":"oops"}"#)
    }

    /// A library saved by a newer Brix isn't saved over by this one unasked.
    @MainActor
    func testNewerLibraryIsNotSavedOverUnasked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brix-newer-\(UUID().uuidString)")
        let persistence = Persistence(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = #"{"schemaVersion":99,"projects":[],"futureThing":[1]}"#
        try Data(raw.utf8).write(to: persistence.url("library.json"))
        let store = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: persistence, keychain: Keychain(service: "com.brix.tests.\(UUID().uuidString)"))
        XCTAssertEqual(store.confirmations.first?.title, "Save your library with this version?")
        store.saveNow()
        XCTAssertEqual(try String(contentsOf: persistence.url("library.json"), encoding: .utf8), raw)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("library.partial-") })
    }

    func testOldRestoredCopiesArePruned() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brix-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let old = "library.restored-\(Int(now.timeIntervalSince1970) - 31 * 86_400).json", recent = "library.restored-\(Int(now.timeIntervalSince1970) - 86_400).json"
        for f in [old, recent, "library.unreadable-1.json"] { try Data("{}".utf8).write(to: dir.appendingPathComponent(f)) }
        AppStore.pruneRestored(in: dir, now: now)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), [recent, "library.unreadable-1.json"])
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
        XCTAssertEqual(reader.read(url)?.items, [PlanItem(title: "Write tests", done: false, active: true), PlanItem(title: "Ship it", done: false)])
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(line(#"{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}"#).utf8))
        try h.close()
        XCTAssertEqual(reader.read(url)?.items.first, PlanItem(title: "Write tests", done: true))
    }

    /// An approved plan-mode plan shows until the agent makes tasks and drops the old tasks; a rejected one changes nothing.
    func testPlanModePlan() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        func line(_ content: String) -> String { #"{"type":"assistant","message":{"content":[\#(content)]}}"# + "\n" }
        var text = line(#"{"type":"tool_result","content":"Task #1 created successfully: Old"}"#)
        // Rejected: nothing changes.
        text += line(##"{"type":"tool_use","id":"p1","name":"ExitPlanMode","input":{"plan":"# Nope"}}"##)
        text += line(#"{"type":"tool_result","tool_use_id":"p1","is_error":true,"content":"The user doesn't want to proceed"}"#)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let reader = AgentTranscripts.PlanReader()
        XCTAssertEqual(reader.read(url), AgentPlan(items: [PlanItem(title: "Old", done: false)], doc: ""))
        text += line(##"{"type":"tool_use","id":"p2","name":"ExitPlanMode","input":{"plan":"# Deploy\n\n1. Ship it"}}"##)
        text += line(#"{"type":"tool_result","tool_use_id":"p2","content":"User has approved your plan."}"#)
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(reader.read(url), AgentPlan(items: [], doc: "# Deploy\n\n1. Ship it"))
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(line(#"{"type":"tool_result","content":"Task #2 created successfully: Ship it"}"#).utf8))
        try h.close()
        XCTAssertEqual(reader.read(url)?.items, [PlanItem(title: "Ship it", done: false)])
    }
}

final class ChatHistoryTests: XCTestCase {
    /// A transcript becomes chat items: your messages, replies, tool cards with
    /// their results; side chains, meta notes and tagged command echoes are left out.
    @MainActor
    func testHistoryFromTranscript() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"fix the bug"}}"#,
            #"{"type":"user","uuid":"u0","isMeta":true,"message":{"role":"user","content":"caveat"}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/p/a.swift"}}]}}"#,
            #"{"type":"assistant","uuid":"a9","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"}]}}"#,
            #"{"type":"user","uuid":"u3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"line 1"}]}}"#,
            #"{"type":"user","uuid":"u4","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"aGk="}},{"type":"text","text":"see this"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let items = try XCTUnwrap(ClaudeChat.history(url, cwd: "/p"))
        XCTAssertEqual(items.map(\.text), ["fix the bug", "Looking.", "a.swift", "see this"])
        XCTAssertEqual(items[2].result, "line 1")
        XCTAssertEqual(items[3].images.map(\.data), [Data("hi".utf8)])
        XCTAssertEqual(ClaudeChat.history(url, cwd: "/p", limit: 2)?.map(\.text), ["a.swift", "see this"])
        XCTAssertNil(ClaudeChat.history(url.appendingPathExtension("missing"), cwd: "/p"))
    }
}

final class ChatHelperTests: XCTestCase {
    /// Only Claude's own tagged echoes are hidden in a resumed history; your text starting with "<" shows.
    func testShownUserText() {
        XCTAssertEqual(ClaudeChat.shownUserText("  <div> won't centre  "), "<div> won't centre")
        XCTAssertNil(ClaudeChat.shownUserText("<command-name>/clear</command-name>"))
        XCTAssertNil(ClaudeChat.shownUserText("<system-reminder>x</system-reminder>"))
        XCTAssertNil(ClaudeChat.shownUserText("<local-command-stdout>ok</local-command-stdout>"))
        XCTAssertEqual(ClaudeChat.shownUserText("<bash-input>ls</bash-input>\n<bash-stdout>a</bash-stdout><bash-stderr></bash-stderr>\n\nwhat's in a?"), "what's in a?")
        XCTAssertNil(ClaudeChat.shownUserText("<bash-input>ls</bash-input>\n<bash-stdout>a</bash-stdout><bash-stderr></bash-stderr>"))
        XCTAssertNil(ClaudeChat.shownUserText("   "))
    }

    /// A full path to the CLI is still Claude; PATH lookups keep the full path.
    func testBinaryName() {
        let a = AgentConfig(id: "x", name: "Mine", command: "/opt/homebrew/bin/claude --model opus")
        XCTAssertEqual(a.binary, "claude")
        XCTAssertEqual(a.executable, "/opt/homebrew/bin/claude")
        XCTAssertEqual(AgentConfig(id: "y", name: "C", command: "codex").binary, "codex")
    }

    /// Tool output kept for a card stops at 20k characters; short output is untouched.
    func testCapped() {
        XCTAssertEqual(ClaudeChat.capped("short"), "short")
        let c = ClaudeChat.capped(String(repeating: "a", count: 25_000))
        XCTAssertTrue(c.hasPrefix(String(repeating: "a", count: 20_000) + "\n…"))
        XCTAssertLessThan(c.count, 20_100)
    }

    /// A missing CLI says which one and how to install it, not "code 127".
    func testMissingBinaryMessage() {
        let m = ClaudeChat.exitMessage(127, stderr: "zsh:1: command not found: claude", command: "claude --session-id x")
        XCTAssertTrue(m.hasPrefix("Couldn't find claude."))
        XCTAssertTrue(m.contains("claude.ai/install.sh"))
        XCTAssertEqual(ClaudeChat.exitMessage(1, stderr: "boom", command: "claude"), "Claude Code exited with code 1:\nboom")
    }

    /// Edit and Resend brings images back numbered after the composer's own, tags in the text to match.
    func testRenumbered() {
        let imgs = [ClaudeChat.Attachment(data: Data([1]), mediaType: "image/png", number: 1),
                    ClaudeChat.Attachment(data: Data([2]), mediaType: "image/png", number: 3),
                    ClaudeChat.Attachment(data: Data([3]), mediaType: "image/png", number: 0)]
        let r = ClaudeChat.renumbered("[Image #1] vs [Image #3], not [Image #9]", imgs, from: 2)
        XCTAssertEqual(r.text, "[Image #4] [Image #2] vs [Image #3], not [Image #9]")
        XCTAssertEqual(r.images.map(\.number), [2, 3, 4])
    }
}

final class ChatProtocolTests: XCTestCase {
    /// Permission choices read like the terminal's, and say which ones are saved to a file.
    func testSuggestions() {
        let rule = ClaudeChat.suggestion(["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "mkdir newdir *"]], "behavior": "allow", "destination": "localSettings"], cwd: "/p")
        XCTAssertEqual(rule?.label, "Yes, and don't ask again for Bash(mkdir newdir *) (saved in .claude/settings.local.json)")
        XCTAssertEqual(rule?.saved, true)
        let mode = ClaudeChat.suggestion(["type": "setMode", "mode": "acceptEdits", "destination": "session"], cwd: "/p")
        XCTAssertEqual(mode?.label, "Yes, and switch to accept edits for this session")
        XCTAssertEqual(mode?.saved, false)
        XCTAssertNil(ClaudeChat.suggestion(["type": "removeRules"], cwd: "/p"))
    }

    func testCommandOutputAndNotices() {
        XCTAssertEqual(ClaudeChat.commandOutput("<local-command-stdout>Set model to `sonnet`</local-command-stdout>"), "Set model to `sonnet`")
        XCTAssertNil(ClaudeChat.commandOutput("plain text"))
        XCTAssertEqual(ClaudeChat.notice(["subtype": "api_retry", "attempt": 2, "max_retries": 10])?.text, "API error, retrying (2 of 10)")
        XCTAssertEqual(ClaudeChat.notice(["subtype": "compact_boundary", "compact_metadata": ["pre_tokens": 154000]])?.text, "Conversation compacted, 154k tokens before")
        XCTAssertNil(ClaudeChat.notice(["subtype": "hook_started"]))
    }
}

final class ChatSessionOpsTests: XCTestCase {
    /// Rewind and fork rebuild the launch line: the conversation flags come off, the rest stays.
    func testLaunchLineHelpers() {
        let id = "0b5f2d3e-1111-2222-3333-444455556666"
        let cmd = "claude --resume \(id) --resume-session-at \(id) --fork-session --append-system-prompt 'x y'"
        XCTAssertEqual(ClaudeChat.base(cmd), "claude --append-system-prompt 'x y'")
        XCTAssertEqual(ClaudeChat.base("claude --session-id \(id)"), "claude")
        XCTAssertEqual(ClaudeChat.flag("--resume", in: cmd), id)
        XCTAssertNil(ClaudeChat.flag("--model", in: cmd))
    }

    /// A fork's history stops at its cut; each message knows Claude's message before it.
    @MainActor
    func testHistoryCut() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"first"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"one"}]}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":"second"}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"content":[{"type":"text","text":"two"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let all = try XCTUnwrap(ClaudeChat.history(url, cwd: "/p"))
        XCTAssertEqual(all.map(\.text), ["first", "one", "second", "two"])
        XCTAssertNil(all[0].before)
        XCTAssertEqual(all[2].before, "a1")
        XCTAssertEqual(all[2].uuid, "u2")
        XCTAssertEqual(ClaudeChat.history(url, cwd: "/p", until: "a1")?.map(\.text), ["first", "one"])
    }
}

final class ChatMemoryTests: XCTestCase {
    /// #note appends in place: a linked CLAUDE.md stays linked, and one that isn't UTF-8 is left alone.
    @MainActor
    func testAddMemoryKeepsTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppStore(services: Services(mock: .mock(), live: .mock()), persistence: Persistence(directory: dir.appendingPathComponent("lib")),
                             keychain: Keychain(service: "brix-test-\(UUID().uuidString)"), loadFromDisk: false)
        let chat = ClaudeChat(sessionID: "s", cwd: dir.path, store: store)
        let target = dir.appendingPathComponent("AGENTS.md")
        try "# Rules".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("CLAUDE.md"), withDestinationURL: target)
        XCTAssertNil(chat.addMemory("use tabs"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# Rules\n- use tabs\n")
        XCTAssertNotNil(try FileManager.default.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("CLAUDE.md").path))

        let latin = Data([0x63, 0x61, 0x66, 0xE9])  // "café" in Latin-1
        try latin.write(to: target)
        XCTAssertNotNil(chat.addMemory("x"))
        XCTAssertEqual(try Data(contentsOf: target), latin)
    }
}

final class ChatDiffTests: XCTestCase {
    /// An edit's unchanged lines at either end are context; only the change is marked.
    func testDiffKeepsContext() {
        let d = ClaudeChat.Diff(old: "a\nb\nc", new: "a\nB\nx\nc")
        XCTAssertEqual(DiffBlock.lines(d).map { $0.0 + $0.1 }, [" a", "-b", "+B", "+x", " c"])
        XCTAssertEqual(DiffBlock.lines(ClaudeChat.Diff(old: "", new: "n")).map { $0.0 + $0.1 }, ["+n"])
        XCTAssertEqual(DiffBlock.lines(ClaudeChat.Diff(old: "same", new: "same")).map { $0.0 + $0.1 }, [" same"])
    }
}

final class ClaudeSymlinkFolderTests: XCTestCase {
    /// A project folder under ~/.claude/projects that is a symlink still lists its sessions.
    func testListsSessionsThroughASymlinkedFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent(".claude/projects")
        let real = root.appendingPathComponent("-Users-me-old")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("-Users-me-app"), withDestinationURL: real)
        try #"{"type":"user","entrypoint":"cli","cwd":"/Users/me/app","message":{"role":"user","content":"hi"}}"#
            .write(to: real.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentTranscripts.claudeSessions(projectPath: "/Users/me/app", home: home.path).count, 1)
    }
}

final class ChatImageLabelTests: XCTestCase {
    /// Each image follows its "[Image #N]" label, in the order attached; the text comes last.
    func testImagesFollowTheirLabels() {
        var a = ClaudeChat.Attachment(data: Data([1]), mediaType: "image/png"); a.number = 1
        var b = ClaudeChat.Attachment(data: Data([2]), mediaType: "image/png"); b.number = 3
        let parts = ClaudeChat.content("[Image #1] red, [Image #3] yellow", images: [a, b])
        XCTAssertEqual(parts.map { $0["type"] as? String }, ["text", "image", "text", "image", "text"])
        XCTAssertEqual(parts[0]["text"] as? String, "[Image #1]")
        XCTAssertEqual((parts[1]["source"] as? [String: Any])?["data"] as? String, Data([1]).base64EncodedString())
        XCTAssertEqual(parts[2]["text"] as? String, "[Image #3]")
        XCTAssertEqual((parts[3]["source"] as? [String: Any])?["data"] as? String, Data([2]).base64EncodedString())
        XCTAssertEqual(parts[4]["text"] as? String, "[Image #1] red, [Image #3] yellow")
        // An untagged image (number 0) goes without a label.
        XCTAssertEqual(ClaudeChat.content("", images: [ClaudeChat.Attachment(data: Data([1]), mediaType: "image/png")]).count, 1)
        XCTAssertTrue(ClaudeChat.isImageLabel("[Image #12]"))
        XCTAssertFalse(ClaudeChat.isImageLabel("[Image #1] make it red"))
    }
}
