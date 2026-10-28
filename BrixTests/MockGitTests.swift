import XCTest
@testable import Brix

final class MockGitTests: XCTestCase {
    private let project = MockData.projects[0] // atlas-web

    private func service() -> MockGitService { MockGitService(delay: 0) }

    func testInitialState() async throws {
        let s = try await service().status(project)
        XCTAssertEqual(s.staged.count, 2)
        XCTAssertEqual(s.unstaged.count, 5)
        XCTAssertEqual(s.ahead, 2)
    }

    func testStageAndUnstage() async throws {
        let g = service()
        var s = try await g.stage(project, paths: ["src/app/checkout/page.tsx"])
        XCTAssertEqual(s.staged.count, 3)
        XCTAssertTrue(s.staged.contains { $0.path == "src/app/checkout/page.tsx" })
        s = try await g.unstage(project, paths: ["src/app/checkout/page.tsx"])
        XCTAssertEqual(s.staged.count, 2)
    }

    func testStagingUntrackedBecomesAdded() async throws {
        let s = try await service().stage(project, paths: ["src/app/checkout/success/page.tsx"])
        XCTAssertEqual(s.staged.first { $0.path.hasSuffix("success/page.tsx") }?.status, .A)
    }

    func testCommitMovesStagedIntoHistory() async throws {
        let g = service()
        let s = try await g.commit(project, message: "Add Apple Pay")
        XCTAssertTrue(s.staged.isEmpty)
        XCTAssertEqual(s.unstaged.count, 5)
        XCTAssertEqual(s.commits.first?.message, "Add Apple Pay")
        XCTAssertEqual(s.commits.first?.files.count, 2)
        XCTAssertEqual(s.ahead, 3)
    }

    func testCommitRequiresMessageAndStagedFiles() async throws {
        let g = service()
        do { _ = try await g.commit(project, message: "  "); XCTFail("Empty message should throw") } catch {}
        _ = try await g.unstage(project, paths: ["src/lib/stripe/intent.ts", "src/components/PaymentForm.tsx"])
        do { _ = try await g.commit(project, message: "x"); XCTFail("Nothing staged should throw") } catch {}
    }

    func testPushClearsAhead() async throws {
        let s = try await service().push(project)
        XCTAssertEqual(s.ahead, 0)
        XCTAssertTrue(s.commits.allSatisfy(\.isPushed))
    }

    func testDiscardRemovesOnlyUnstaged() async throws {
        let s = try await service().discard(project, paths: ["package.json", "src/components/PaymentForm.tsx"])
        XCTAssertFalse(s.changes.contains { $0.path == "package.json" })
        XCTAssertTrue(s.staged.contains { $0.path == "src/components/PaymentForm.tsx" }, "Staged changes survive discard")
    }

    func testBranches() async throws {
        let g = service()
        var s = try await g.createBranch(project, name: "feat/new")
        XCTAssertEqual(s.branch, "feat/new")
        s = try await g.switchBranch(project, to: "main")
        XCTAssertEqual(s.branch, "main")
        s = try await g.deleteBranch(project, name: "feat/new")
        XCTAssertFalse(s.branches.contains { $0.name == "feat/new" })
        do { _ = try await g.deleteBranch(project, name: "main"); XCTFail("Can't delete current branch") } catch {}
        do { _ = try await g.createBranch(project, name: "has space"); XCTFail("Spaces are invalid") } catch {}
    }

    func testSuggestedMessage() {
        let m = CommitMessageWriter.suggest(for: [GitFileChange(path: "src/a.ts", status: .A, add: 1, del: 0, staged: true)])
        XCTAssertEqual(m, "Add a")
    }

    func testMockTerminalCommands() async {
        let t = MockTerminalService()
        let s = MockData.sessions[2]
        let git = MockData.git["atlas-web"]
        let status = await t.respond(to: "git status", session: s, project: project, host: nil, git: git)
        XCTAssertEqual(status.first?.plain, "On branch feat/checkout-v2")
        let missing = await t.respond(to: "frobnicate", session: s, project: project, host: nil, git: git)
        XCTAssertEqual(missing.first?.plain, "zsh: command not found: frobnicate")
    }

    func testSSHMockBastionTimesOut() async {
        let ssh = MockSSHService()
        ssh.delay = 0
        do { _ = try await ssh.test(MockData.hosts.first { $0.id == "bastion" }!, password: nil); XCTFail("Bastion should time out") } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        let ok = try? await ssh.test(MockData.hosts[0], password: nil)
        XCTAssertNotNil(ok)
    }

    func testProdReplicaTimesOut() async {
        let db = MockDatabaseService()
        db.delay = 0
        let replica = MockData.databases.first { $0.id == "atlas_prod_replica" }!
        do { _ = try await db.test(replica, password: nil); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("timeout"))
        }
    }

    func testMockRowsPageLazily() async throws {
        let db = MockDatabaseService()
        db.delay = 0
        let c = MockData.databases[0]
        let audit = DBObject(schema: "public", name: "audit_log", kind: .table, rowEstimate: 771_000)
        let r = try await db.rows(c, object: audit, filter: "", sort: nil, page: 10_000, pageSize: 50, password: nil)
        XCTAssertEqual(r.rows.count, 50)
        XCTAssertEqual(r.totalRows, 771_000)
    }
}
