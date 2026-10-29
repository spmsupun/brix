import SwiftUI

/// Runtime view of every SSH host: status, OS, uptime, load, CPU/memory/disk.
struct ServersView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    @State private var selected: ResourceID?
    @AppStorage("servers.detailWidth") private var detailWidth: Double = 360

    private var current: SSHHost? { (selected ?? store.selectedHost).flatMap(store.host) ?? store.library.hosts.first }

    var body: some View {
        if store.library.hosts.isEmpty {
            EmptyState(symbol: "server.rack", message: "No servers yet. Add an SSH host to see its health here.", actionTitle: "Add SSH Host") { store.sheet = .editHost(nil) }
                .island()
        } else {
            HStack(spacing: 0) {
                list.frame(minWidth: 300)
                if let h = current {
                    ResizeHandle(axis: .horizontal, thickness: gap) { detailWidth = min(max(detailWidth - $0, 280), 640) }
                    ServerDetail(host: h).frame(width: detailWidth)
                }
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Servers").font(Typo.panelTitle).tracking(0.4).foregroundStyle(Theme.text2)
                CountPill(text: "\(store.library.hosts.count)")
                Spacer()
                // Connected servers update every 5 s; the rest on Check health.
                let busy = !store.healthChecking.isDisjoint(with: store.library.hosts.map(\.id))
                SubtleButton(title: "Check health", symbol: "waveform.path.ecg", height: 26, isLoading: busy) {
                    store.checkHealth(store.library.hosts.map(\.id))
                }
                .disabled(busy)
                .help("Logs in to each server over SSH, reads CPU, memory, disk and load, and logs out. Read-only. Connected servers also update every 5 s.")
            }
            .padding(.horizontal, 14).frame(height: Metrics.panelHeader).hairlineBottom()
            GeometryReader { geo in
                let cols = ServerColumns(width: geo.size.width)
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("Host").frame(maxWidth: .infinity, alignment: .leading)
                        if cols.os { Text("OS").frame(width: 120, alignment: .leading) }
                        if cols.uptime { Text("Uptime").frame(width: 80, alignment: .leading) }
                        if cols.load { Text("Load").frame(width: 100, alignment: .leading) }
                        Text("CPU").frame(width: cols.bar, alignment: .leading)
                        Text("Memory").frame(width: cols.bar, alignment: .leading)
                        Text("Disk").frame(width: cols.bar, alignment: .leading)
                    }
                    .font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3)
                    .padding(.horizontal, 16).frame(height: 30).hairlineBottom()
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(store.library.hosts) { h in row(h, cols: cols) }
                        }
                        .padding(6)
                    }
                }
            }
        }
        .island()
    }

    private func row(_ h: SSHHost, cols: ServerColumns) -> some View {
        let status = store.hostStatus[h.id] ?? .disconnected
        // Live while connected, else the last Check health reading.
        let m = status.isLive || store.healthAt[h.id] != nil ? store.hostMetrics[h.id] : nil
        let on = h.id == current?.id
        return HStack(spacing: 10) {
            HStack(spacing: 9) {
                StatusDot(color: status.color, size: 7, ring: status == .connected)
                Text(h.name).font(Typo.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle).help(h.name)
                TagPill(tag: h.tag, size: 8.5)
                if store.healthChecking.contains(h.id) { ProgressView().controlSize(.mini) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if cols.os { Text(m?.os ?? h.os.ifEmpty("–")).font(Typo.ui(12)).foregroundStyle(Theme.text2).lineLimit(1).frame(width: 120, alignment: .leading) }
            if cols.uptime { Text(m?.uptime ?? "–").font(Typo.ui(12)).foregroundStyle(Theme.text2).lineLimit(1).frame(width: 80, alignment: .leading) }
            if cols.load { Text(m?.load ?? "–").font(Typo.mono(11)).foregroundStyle(Theme.text2).lineLimit(1).frame(width: 100, alignment: .leading) }
            bar(m?.cpu, Theme.green, width: cols.bar)
            bar(m?.memory, Theme.amber, width: cols.bar)
            bar(m?.disk, (m?.disk ?? 0) > 0.8 ? Theme.red : Theme.blue, width: cols.bar)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .rowBackground(selected: on, radius: 8)
        .clickable().onTapGesture { selected = h.id; store.selectedHost = h.id; store.inspector = .host(h.id) }
        .contextMenu {
            Button("Open Shell") { store.connect(h.id) }
            Button("Tail Logs") { store.tailSystemLog(h.id) }
            Button("Edit…") { store.sheet = .editHost(h) }
            Divider()
            Button(status.isLive ? "Disconnect" : "Connect") { if status.isLive { store.disconnect(h.id) } else { store.connect(h.id, openShell: false) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(h.name), \(status.label)\(m.map { ", CPU \(Int($0.cpu * 100)) percent" } ?? "")")
        .animation(.easeOut(duration: 0.4), value: m)
    }

    private func bar(_ v: Double?, _ c: Color, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            if let v {
                if width >= 90 { MeterBar(label: "", value: v, color: c, showLabel: false).frame(width: 46) }
                Text("\(Int((v * 100).rounded()))%").font(Typo.ui(11)).monospacedDigit().foregroundStyle(Theme.text)
            } else {
                Text("–").font(Typo.ui(11)).foregroundStyle(Theme.meta)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Which server columns fit; the host name and the three meters always stay.
private struct ServerColumns {
    var os = false, uptime = false, load = false
    var bar: CGFloat = 90

    init(width: CGFloat) {
        bar = width >= 560 ? 90 : 48
        load = width >= 700
        uptime = width >= 790
        os = width >= 920
    }
}

private struct ServerDetail: View {
    @Environment(AppStore.self) private var store
    let host: SSHHost

    var body: some View {
        let h = host
        let status = store.hostStatus[h.id] ?? .disconnected
        let containers = store.allDocker.filter { $0.hostID == h.id }
        let recent = store.sessions.filter { $0.hostID == h.id }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(h.name).font(Typo.ui(15, .semibold)).foregroundStyle(Theme.text)
                        TagPill(tag: h.tag)
                    }
                    HStack(spacing: 6) {
                        StatusDot(color: status.color, size: 6)
                        Text(status.label + " · " + h.address).font(Typo.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(16).hairlineBottom()
            HStack(spacing: 6) {
                AccentButton(title: "Open Shell", fullWidth: true) { store.connect(h.id) }
                SubtleButton(title: "Tail Logs", fullWidth: true) { store.tailSystemLog(h.id) }
                SubtleButton(title: "Edit", fullWidth: true) { store.sheet = .editHost(h) }
            }
            .padding(12).hairlineBottom()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HostInspector(hostID: h.id)
                    InspectorSection(title: "Docker containers · \(containers.count)") {
                        if containers.isEmpty { Text("No containers known on this host.").font(Typo.ui(12)).foregroundStyle(Theme.text3) }
                        ForEach(containers) { c in
                            HStack(spacing: 8) {
                                DockerRow(container: c, projectID: nil)
                                if c.state == .running {
                                    IconButton(symbol: "arrow.triangle.2.circlepath", label: "Restart \(c.name)", iconSize: 11) { store.dockerAction(.restart, c.id) }
                                }
                            }
                        }
                    }
                    InspectorSection(title: "Recent sessions") {
                        if recent.isEmpty { Text("No sessions yet.").font(Typo.ui(12)).foregroundStyle(Theme.text3) }
                        ForEach(recent) { s in
                            Button { store.focusedSessionID = s.id; store.route = .terminals } label: {
                                HStack {
                                    StatusDot(color: s.state.color, size: 6)
                                    Text(s.title).font(Typo.row).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(RelativeTime.short(s.startedAt)).font(Typo.ui(11)).foregroundStyle(Theme.text3)
                                }
                                .frame(height: 26).contentShape(Rectangle())
                            }
                            .buttonStyle(.hand)
                        }
                    }
                }
            }
        }
        .island()
    }
}

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
