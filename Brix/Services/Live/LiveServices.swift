import Foundation

enum LiveServices {
    static func make() -> ServiceSet {
        ServiceSet(git: LiveGitService(), files: LiveFileService(), terminal: MockTerminalService(), agent: LiveAgentService(),
                   ssh: LiveSSHService(), metrics: LiveMetricsService(), db: LiveDatabaseService(), docker: LiveDockerService())
    }
}

// MARK: - SSH

/// Builds `ssh` invocations so ~/.ssh/config and the agent apply.
enum SSHCommand {
    static func args(_ h: SSHHost, batch: Bool, extra: [String] = []) -> [String] {
        var a = ["-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15"]
        if batch { a += ["-o", "BatchMode=yes"] }
        if h.port != 22 { a += ["-p", "\(h.port)"] }
        if h.auth == .key, !h.keyPath.isEmpty { a += ["-i", (h.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        if h.auth == .password { a += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no"] }
        return a + extra + ["\(h.user)@\(h.host)"]
    }

    /// The command line a terminal runs for an interactive shell on the host.
    static func interactive(_ h: SSHHost, remoteCommand: String? = nil) -> [String] {
        var a = args(h, batch: false, extra: remoteCommand == nil ? [] : ["-t"])
        if let remoteCommand { a.append(remoteCommand) }
        return ["/usr/bin/ssh"] + a
    }

    /// SSH_ASKPASS helper so a Keychain password can be supplied without a TTY.
    /// The secret is passed only in the child's environment, never on disk.
    static func askpassEnv(password: String) throws -> [String: String] {
        let dir = Persistence.supportDirectory
        let script = dir.appendingPathComponent("askpass.sh")
        if !FileManager.default.fileExists(atPath: script.path) {
            try "#!/bin/sh\nprintf '%s\\n' \"$BRIX_ASKPASS_SECRET\"\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        return ["SSH_ASKPASS": script.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0", "BRIX_ASKPASS_SECRET": password]
    }

    static func run(_ h: SSHHost, password: String?, remote: String, timeout: TimeInterval = 20, verbose: Bool = false) async throws -> ProcessOutput {
        var env: [String: String] = [:]
        if h.auth == .password {
            guard let password, !password.isEmpty else { throw ServiceError("No password stored in the Keychain for \(h.name)") }
            env = try askpassEnv(password: password)
        }
        let extra = verbose ? ["-v"] : []
        return try await ProcessRunner.run("/usr/bin/ssh", args(h, batch: h.auth != .password, extra: extra) + [remote], env: env, timeout: timeout)
    }
}

final class LiveSSHService: SSHService {
    func test(_ host: SSHHost, password: String?) async throws -> String {
        guard !host.host.isEmpty, !host.user.isEmpty else { throw ServiceError("Enter a host and user") }
        let start = Date()
        let r = try await SSHCommand.run(host, password: password, remote: "echo brix-ok", timeout: 15, verbose: true)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        guard r.ok, r.stdout.contains("brix-ok") else {
            let last = r.stderr.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("debug1:") && !$0.hasPrefix("OpenSSH") }.last
            throw ServiceError(last?.trimmingCharacters(in: .whitespaces) ?? "ssh exited with status \(r.status)")
        }
        let version = r.stderr.split(separator: "\n").first { $0.contains("remote software version") }
            .flatMap { $0.components(separatedBy: "remote software version ").last } ?? "SSH"
        return "\(version) · \(ms) ms"
    }

    func connect(_ host: SSHHost) async throws {
        // Interactive sessions run ssh in a PTY; nothing to verify up front.
    }
}

final class LiveMetricsService: MetricsService {
    static let script = """
    . /etc/os-release 2>/dev/null; echo "OS=${PRETTY_NAME:-$(uname -sr)}"; \
    echo "LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg | tr -d '{}')"; \
    echo "CPUS=$(nproc 2>/dev/null || sysctl -n hw.ncpu)"; \
    free -b 2>/dev/null | awk '/Mem:/{printf "MEM=%.4f\\n", $3/$2}'; \
    df -P / | awk 'NR==2{gsub("%","",$5); printf "DISK=%.4f\\n", $5/100}'; \
    echo "UP=$(uptime -p 2>/dev/null || uptime | sed 's/.*up \\([^,]*\\),.*/\\1/')"
    """

    var passwordLookup: ((SSHHost) -> String?)?

    func metrics(_ host: SSHHost) async throws -> HostMetrics {
        let r = try await SSHCommand.run(host, password: passwordLookup?(host), remote: Self.script, timeout: 15)
        guard r.ok else { throw ServiceError(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "metrics failed") }
        return Self.parse(r.stdout)
    }

    static func parse(_ out: String) -> HostMetrics {
        var kv: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let p = line.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { kv[p[0]] = p[1].trimmingCharacters(in: .whitespaces) }
        }
        let load = kv["LOAD"] ?? ""
        let cpus = Double(kv["CPUS"] ?? "1") ?? 1
        let l1 = Double(load.split(separator: " ").first ?? "0") ?? 0
        return HostMetrics(cpu: min(1, l1 / max(cpus, 1)), memory: Double(kv["MEM"] ?? "0") ?? 0, disk: Double(kv["DISK"] ?? "0") ?? 0,
                           load: load, uptime: (kv["UP"] ?? "").replacingOccurrences(of: "up ", with: ""), os: kv["OS"] ?? "")
    }
}

// MARK: - Docker

final class LiveDockerService: DockerService {
    static func shell(_ c: DockerTarget, host: SSHHost?) -> String {
        let inner = "docker exec -it \(c.name) sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
        return wrap(inner, host: host)
    }

    static func follow(_ c: DockerTarget, host: SSHHost?) -> String {
        wrap("docker logs --tail 200 -f \(c.name)", host: host)
    }

    static func wrap(_ cmd: String, host: SSHHost?) -> String {
        guard let host else { return cmd }
        return SSHCommand.interactive(host, remoteCommand: cmd).map { $0.contains(" ") ? ProcessRunner.shellQuote($0) : $0 }.joined(separator: " ")
    }

    var passwordLookup: ((SSHHost) -> String?)?

    private func docker(_ args: [String], host: SSHHost?, timeout: TimeInterval = 20) async throws -> String {
        if let host {
            let remote = (["docker"] + args).map { $0.contains(" ") || $0.contains("{") ? ProcessRunner.shellQuote($0) : $0 }.joined(separator: " ")
            let r = try await SSHCommand.run(host, password: passwordLookup?(host), remote: remote, timeout: timeout)
            guard r.ok else { throw ServiceError(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return r.stdout
        }
        return try await ProcessRunner.check("docker", args, timeout: timeout)
    }

    struct PSRow: Decodable {
        var Names: String
        var Image: String
        var Ports: String
        var State: String
        var Status: String
        var Labels: String?
    }

    static func parsePS(_ out: String, hostID: ResourceID?) -> [DockerTarget] {
        out.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8), let r = try? JSONDecoder().decode(PSRow.self, from: d) else { return nil }
            let state: ContainerState = switch r.State {
            case "running": .running
            case "restarting": .restarting
            case "paused": .paused
            default: .exited
            }
            let compose = r.Labels?.split(separator: ",").first { $0.hasPrefix("com.docker.compose.project=") }
                .map { String($0.dropFirst("com.docker.compose.project=".count)) } ?? ""
            let service = r.Labels?.split(separator: ",").first { $0.hasPrefix("com.docker.compose.service=") }
                .map { String($0.dropFirst("com.docker.compose.service=".count)) }
            let ports = r.Ports.components(separatedBy: ", ").compactMap { p -> String? in
                guard let arrow = p.range(of: "->") else { return nil }
                return ":" + (p[..<arrow.lowerBound].split(separator: ":").last.map(String.init) ?? "")
            }
            var t = DockerTarget(id: "\(hostID ?? "local")/\(r.Names)", name: r.Names, image: r.Image,
                                 ports: Array(NSOrderedSet(array: ports)).compactMap { $0 as? String }.joined(separator: " "),
                                 hostID: hostID, composeProject: compose, state: state, startedAt: nil)
            t.statusText = r.Status
            if let service { t.composeService = service }
            return t
        }
    }

    func list(hosts: [SSHHost]) async throws -> [DockerTarget] {
        var all: [DockerTarget] = []
        var errors: [String] = []
        do {
            all += Self.parsePS(try await docker(["ps", "-a", "--format", "{{json .}}"], host: nil), hostID: nil)
        } catch {
            errors.append("Local: \(error.localizedDescription)")
        }
        for h in hosts {
            do {
                all += Self.parsePS(try await docker(["ps", "-a", "--format", "{{json .}}"], host: h), hostID: h.id)
            } catch {
                errors.append("\(h.name): \(error.localizedDescription)")
            }
        }
        if all.isEmpty, !errors.isEmpty { throw ServiceError(errors.joined(separator: "\n")) }
        return all
    }

    func inventory(host: SSHHost?) async throws -> DockerInventory {
        let hid = host?.id
        async let stacks = docker(["compose", "ls", "-a", "--format", "json"], host: host)
        async let networks = docker(["network", "ls", "--format", "{{json .}}"], host: host)
        async let volumes = docker(["volume", "ls", "--format", "{{json .}}"], host: host)
        async let images = docker(["image", "ls", "--format", "{{json .}}"], host: host)
        // Stacks need Compose v2; an engine without it still lists the rest.
        let s = (try? await stacks).map { DockerParse.stacks($0, hostID: hid) } ?? []
        return DockerInventory(stacks: s, networks: DockerParse.networks(try await networks, hostID: hid),
                               volumes: DockerParse.volumes(try await volumes, hostID: hid), images: DockerParse.images(try await images, hostID: hid))
    }

    func run(_ args: [String], host: SSHHost?, timeout: TimeInterval) async throws -> String {
        try await docker(args, host: host, timeout: timeout)
    }

    static func composeArgs(_ stack: ComposeStack) -> [String] {
        ["compose"] + stack.configFiles.flatMap { ["-f", $0] } + ["-p", stack.name]
    }

    func compose(_ action: ComposeAction, _ stack: ComposeStack, host: SSHHost?) async throws {
        let tail: [String] = switch action {
        case .up: ["up", "-d"]
        case .down: ["down"]
        case .restart: ["restart"]
        case .stop: ["stop"]
        case .pull: ["pull"]
        }
        _ = try await docker(Self.composeArgs(stack) + tail, host: host, timeout: 300)
    }

    func composeLogsCommand(_ stack: ComposeStack, host: SSHHost?) -> String {
        Self.wrap((["docker"] + Self.composeArgs(stack) + ["logs", "--tail", "200", "-f"]).map { $0.contains(" ") ? ProcessRunner.shellQuote($0) : $0 }.joined(separator: " "), host: host)
    }

    func perform(_ action: DockerAction, on c: DockerTarget, host: SSHHost?) async throws -> DockerTarget {
        _ = try await docker([action.rawValue, c.name], host: host, timeout: 60)
        let out = try await docker(["ps", "-a", "--filter", "name=^/\(c.name)$", "--format", "{{json .}}"], host: host)
        guard let updated = Self.parsePS(out, hostID: c.hostID).first else { throw ServiceError("\(c.name) disappeared") }
        return updated
    }

    func logs(_ c: DockerTarget, host: SSHHost?) async throws -> [String] {
        let r: String
        if let host {
            r = try await docker(["logs", "--tail", "300", c.name], host: host)
        } else {
            let out = try await ProcessRunner.run("docker", ["logs", "--tail", "300", c.name], timeout: 20)
            guard out.ok else { throw ServiceError(out.stderr) }
            r = out.stdout + out.stderr // docker logs writes container stderr to stderr
        }
        return r.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    func shellCommand(_ c: DockerTarget, host: SSHHost?) -> String { Self.shell(c, host: host) }
    func followLogsCommand(_ c: DockerTarget, host: SSHHost?) -> String { Self.follow(c, host: host) }
}

// MARK: - Agent

/// Agents run as their real CLI inside a PTY. Prompts typed in
/// the composer go straight to the process, so `reply` is not used.
final class LiveAgentService: AgentService {
    func reply(to prompt: String, session: TerminalSession, project: Project?) async -> AgentReply {
        AgentReply(lines: [], plan: nil, touched: nil, state: .running, lastOutput: session.lastOutput, progress: session.progress)
    }
}
