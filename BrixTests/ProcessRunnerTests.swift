import XCTest
@testable import Brix

final class ProcessRunnerTests: XCTestCase {
    /// 200 tools at once: blocking reads used to hold three GCD workers each, so
    /// past about 20 at once every worker waited and nothing finished.
    func testManyToolsAtOnceAllFinish() async throws {
        let outputs = try await withThrowingTaskGroup(of: String.self) { g in
            for i in 0..<200 { g.addTask { try await ProcessRunner.check("/bin/echo", ["run \(i)"], timeout: 20) } }
            return try await g.reduce(into: [String]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(outputs).count, 200)
    }

    func testTimeoutStillReturns() async {
        do {
            _ = try await ProcessRunner.run("/bin/sleep", ["30"], timeout: 1)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue("\(error)".contains("timed out"), "\(error)")
        }
    }

    func testPipesAreCloseOnExec() {
        let p = ProcessRunner.pipe()
        XCTAssertNotEqual(fcntl(p.fileHandleForReading.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertNotEqual(fcntl(p.fileHandleForWriting.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)
    }
}

extension ProcessRunnerTests {
    /// The tool exits but a background child keeps its output open: the timeout still answers.
    func testExitWithOutputHeldOpenTimesOut() async {
        let started = Date()
        do {
            _ = try await ProcessRunner.run("/bin/sh", ["-c", "sleep 30 & echo hi"], timeout: 1)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue("\(error)".contains("timed out"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}

final class FolderWatcherTests: XCTestCase {
    func testBuildOutputAndGitDataDoNotRewalkTheTree() {
        let root = "/p"
        XCTAssertEqual(FolderWatcher.kind("/p/src/a.swift", root: root), true)
        XCTAssertEqual(FolderWatcher.kind("/p/build", root: root), true)
        XCTAssertNil(FolderWatcher.kind("/p/build.noindex/dd/x.o", root: root))
        XCTAssertNil(FolderWatcher.kind("/p/web/node_modules/a/b.js", root: root))
        XCTAssertEqual(FolderWatcher.kind("/p/.git/index", root: root), false)
        XCTAssertEqual(FolderWatcher.kind("/p/dist/app.js", root: root), false)
        XCTAssertEqual(FolderWatcher.kind("/p/mod/.git/HEAD", root: root), false)
        XCTAssertEqual(FolderWatcher.kind("/private/p/src/a.swift", root: root), true)
        XCTAssertNil(FolderWatcher.kind("/private/p/x.noindex/a", root: root))
    }
}
