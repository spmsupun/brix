import Foundation
import SwiftUI

struct ServiceError: LocalizedError, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Protocols

protocol GitService: AnyObject {
    func status(_ project: Project) async throws -> GitRepoState
    func stage(_ project: Project, paths: [String]) async throws -> GitRepoState
    func unstage(_ project: Project, paths: [String]) async throws -> GitRepoState
    func discard(_ project: Project, paths: [String]) async throws -> GitRepoState
    func commit(_ project: Project, message: String) async throws -> GitRepoState
    func fetch(_ project: Project) async throws -> GitRepoState
    func pull(_ project: Project) async throws -> GitRepoState
    func push(_ project: Project) async throws -> GitRepoState
    func diff(_ project: Project, change: GitFileChange) async throws -> FileDiff
    func commitDetail(_ project: Project, hash: String) async throws -> GitCommit
    func switchBranch(_ project: Project, to name: String) async throws -> GitRepoState
    func createBranch(_ project: Project, name: String) async throws -> GitRepoState
    func deleteBranch(_ project: Project, name: String) async throws -> GitRepoState
    func suggestMessage(_ project: Project, staged: [GitFileChange]) async -> String
}

protocol FileService: AnyObject {
    func tree(_ project: Project) async throws -> [FileNode]
    func read(_ project: Project, path: String) async -> FileContent
    func info(_ project: Project, path: String) async -> FileInfo
    func create(_ project: Project, path: String, isDirectory: Bool) async throws
    func rename(_ project: Project, from: String, to: String) async throws
    /// Starts watching the project folder. Returns a token; release it to stop.
    /// `onChange(files)`: files is false when only Git's own data changed.
    func watch(_ project: Project, onChange: @escaping (_ files: Bool) -> Void) -> AnyObject?
}

/// Mock terminals answer typed commands. Live terminals run in a PTY
/// (see LiveTerminal) and do not go through this protocol.
protocol TerminalService: AnyObject {
    func respond(to command: String, session: TerminalSession, project: Project?, host: SSHHost?, git: GitRepoState?) async -> [TermLine]
}

struct AgentReply {
    var lines: [TermLine]
    var plan: [PlanItem]?
    var touched: [FileTouch]?
    var state: SessionState
    var lastOutput: String
    var progress: Double
}

protocol AgentService: AnyObject {
    func reply(to prompt: String, session: TerminalSession, project: Project?) async -> AgentReply
}

protocol SSHService: AnyObject {
    /// Returns a short success description (server version, latency).
    func test(_ host: SSHHost, password: String?) async throws -> String
    func connect(_ host: SSHHost) async throws
}

protocol MetricsService: AnyObject {
    func metrics(_ host: SSHHost) async throws -> HostMetrics
}

struct DBTestResult: Equatable {
    var version: String
    var latencyMs: Double
}

protocol DatabaseService: AnyObject {
    func test(_ c: DatabaseConnection, password: String?) async throws -> DBTestResult
    func schema(_ c: DatabaseConnection, password: String?) async throws -> DBSchemaTree
    func tableDetail(_ c: DatabaseConnection, object: DBObject, password: String?) async throws -> TableDetail
    func rows(_ c: DatabaseConnection, object: DBObject, filter: String, sort: (column: String, ascending: Bool)?, page: Int, pageSize: Int, password: String?) async throws -> QueryResult
    func execute(_ c: DatabaseConnection, sql: String, password: String?) async throws -> QueryResult
    /// One page of a table with a raw WHERE and ORDER BY, plus the total count.
    /// `columns`: the table's columns if already known, so they aren't read again.
    func page(_ c: DatabaseConnection, object: DBObject, where: String, orderBy: String, page: Int, pageSize: Int, columns: [DBColumn]?, password: String?) async throws -> QueryResult
    /// Several statements in one transaction.
    /// `expect[i]`: rows statement i must touch, or nil; a mismatch rolls everything back.
    func executeBatch(_ c: DatabaseConnection, sqls: [String], expect: [Int?], password: String?) async throws -> QueryResult
    /// Stops whatever is running on the connection.
    /// `owner`: only stop that tab's query; nil stops whatever runs.
    func cancel(_ c: DatabaseConnection, owner: String?, password: String?) async
}

enum DockerAction: String {
    case start, stop, restart
}

protocol DockerService: AnyObject {
    func list(hosts: [SSHHost]) async throws -> [DockerTarget]
    func perform(_ action: DockerAction, on c: DockerTarget, host: SSHHost?) async throws -> DockerTarget
    func logs(_ c: DockerTarget, host: SSHHost?) async throws -> [String]
    /// Command run in a terminal for "shell" and "logs -f".
    func shellCommand(_ c: DockerTarget, host: SSHHost?) -> String
    func followLogsCommand(_ c: DockerTarget, host: SSHHost?) -> String
    /// Compose stacks, networks, volumes and images on one engine.
    func inventory(host: SSHHost?) async throws -> DockerInventory
    func compose(_ action: ComposeAction, _ stack: ComposeStack, host: SSHHost?) async throws
    /// `docker compose logs -f` for a terminal.
    func composeLogsCommand(_ stack: ComposeStack, host: SSHHost?) -> String
    /// Any docker command, for inspect and the detail view's actions.
    func run(_ args: [String], host: SSHHost?, timeout: TimeInterval) async throws -> String
}

// MARK: - Registry

struct ServiceSet {
    var git: GitService
    var files: FileService
    var terminal: TerminalService
    var agent: AgentService
    var ssh: SSHService
    var metrics: MetricsService
    var db: DatabaseService
    var docker: DockerService
    var activity: ActivityService = LiveActivityService()

    static func mock() -> ServiceSet {
        ServiceSet(git: MockGitService(), files: MockFileService(), terminal: MockTerminalService(), agent: MockAgentService(),
                   ssh: MockSSHService(), metrics: MockMetricsService(), db: MockDatabaseService(), docker: MockDockerService(),
                   activity: MockActivityService())
    }
}

/// Sample resources run on mocks; everything the user adds runs on live services.
final class Services {
    let mock: ServiceSet
    let live: ServiceSet

    init(mock: ServiceSet = .mock(), live: ServiceSet? = nil) {
        self.mock = mock
        self.live = live ?? LiveServices.make()
    }

    func set(sample: Bool) -> ServiceSet { sample ? mock : live }
}

private struct ServicesKey: EnvironmentKey {
    static let defaultValue = Services(live: .mock())
}

extension EnvironmentValues {
    var services: Services {
        get { self[ServicesKey.self] }
        set { self[ServicesKey.self] = newValue }
    }
}
