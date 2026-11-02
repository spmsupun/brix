import Foundation
import Network

/// A server's reachability: how long a TCP connection to its SSH port takes.
/// No login, nothing sent, so it is safe for any server, Production included.
struct PingResult: Equatable {
    var ms: Double?
    var error: String?
    var at: Date

    var label: String { ms.map { "\(Int($0.rounded())) ms" } ?? "no reply" }
}

enum HostPing {
    /// Pings a saved server. One imported from ~/.ssh/config is looked up the
    /// way ssh would (`ssh -G alias`), since its alias isn't a DNS name.
    static func ping(_ h: SSHHost) async -> PingResult {
        guard let alias = h.alias,
              let out = try? await ProcessRunner.run("/usr/bin/ssh", ["-G", "--", alias], timeout: 5), out.ok else {
            return await ping(host: h.host, port: h.port)
        }
        let kv = Dictionary(out.stdout.split(separator: "\n").compactMap { line -> (String, String)? in
            let p = line.split(separator: " ", maxSplits: 1).map(String.init)
            return p.count == 2 ? (p[0], p[1]) : nil
        }, uniquingKeysWith: { a, _ in a })
        return await ping(host: kv["hostname"] ?? h.host, port: kv["port"].flatMap(Int.init) ?? h.port)
    }

    static func ping(host: String, port: Int, timeout: TimeInterval = 3) async -> PingResult {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), !host.isEmpty else {
            return PingResult(error: "Invalid address", at: Date())
        }
        let start = Date()
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let once = OnceFlag()
            @Sendable func finish(_ r: PingResult) { if once.claim() { conn.cancel(); cont.resume(returning: r) } }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(PingResult(ms: Date().timeIntervalSince(start) * 1000, at: Date()))
                case .failed(let e), .waiting(let e): finish(PingResult(error: e.localizedDescription, at: Date()))
                case .cancelled: finish(PingResult(error: "Cancelled", at: Date()))
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(PingResult(error: "No reply in \(Int(timeout)) s", at: Date())) }
        }
    }
}
