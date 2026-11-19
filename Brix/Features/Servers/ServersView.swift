import SwiftUI

extension AppStore {
    /// Opens a terminal tailing the main system log on a host.
    func tailSystemLog(_ hostID: ResourceID) {
        guard let h = host(hostID) else { return }
        guardProduction(h.tag, name: h.name, verb: "Connect to") { [weak self] in
            guard let self else { return }
            let cmd = "sudo -n tail -n 200 -F /var/log/syslog 2>/dev/null || tail -n 200 -F /var/log/messages"
            let s = newTerminal(project: nil, host: hostID, title: "\(h.name.components(separatedBy: " ").first?.lowercased() ?? "host") logs", kind: .logs, command: cmd, attach: false)
            if s.isSampleSession, let i = sessions.firstIndex(where: { $0.id == s.id }) {
                sessions[i].lines += MockData.apiLogTranscript.dropFirst()
            }
            hostStatus[hostID] = .connected
            focusedSessionID = s.id
            route = .terminals
        }
    }
}
