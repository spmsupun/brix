import XCTest
import Network
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

    /// On the timeout the output so far comes back, and a child the tool started is stopped too.
    func testTimeoutReturnsPartialOutputAndStopsChildren() async throws {
        do {
            _ = try await ProcessRunner.run("/bin/sh", ["-c", "sleep 30 & echo $!; sleep 30"], timeout: 1)
            XCTFail("expected a timeout")
        } catch let t as ProcessTimeout {
            let child = try XCTUnwrap(pid_t(t.partial.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), t.partial.stdout)
            XCTAssertTrue(t.localizedDescription.contains("timed out"))
            let gone = await Self.exits(child)
            XCTAssertTrue(gone, "the background child outlived the timeout")
        }
    }

    /// Cancelling the calling task stops the tool.
    func testCancellationStopsTheTool() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("brix-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let started = Date()
        let task = Task { try await ProcessRunner.run("/bin/sh", ["-c", "echo $$ > '\(file.path)'; exec sleep 30"], timeout: 60) }
        var pid: pid_t?
        while pid == nil, Date().timeIntervalSince(started) < 5 {
            pid = (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let p = try XCTUnwrap(pid)
        let gone = await Self.exits(p)
        XCTAssertTrue(gone, "the tool kept running")
    }

    /// Output past the cap is dropped, not kept in memory.
    func testOutputIsCapped() async throws {
        let r = try await ProcessRunner.run("/bin/sh", ["-c", "head -c \(ProcessRunner.outputCap + 100_000) /dev/zero"], timeout: 20)
        XCTAssertEqual(r.stdout.utf8.count, ProcessRunner.outputCap)
        XCTAssertTrue(r.stderr.contains("dropped"), r.stderr)
        XCTAssertTrue(r.ok)
    }

    /// Waits up to 3 s for a process to be gone.
    private static func exits(_ pid: pid_t) async -> Bool {
        for _ in 0..<30 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
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

final class HostPingTests: XCTestCase {
    /// Against this Mac only: a listening port answers, a closed one doesn't.
    func testOpenAndClosedPorts() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 3)
        defer { listener.cancel() }
        let open = await HostPing.ping(host: "127.0.0.1", port: Int(listener.port!.rawValue))
        XCTAssertNotNil(open.ms, "\(open)")
        XCTAssertNil(open.error)
        let closed = await HostPing.ping(host: "127.0.0.1", port: 1, timeout: 2)
        XCTAssertNil(closed.ms)
        XCTAssertNotNil(closed.error)
    }
}
