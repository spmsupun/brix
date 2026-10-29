import SwiftUI

struct SSHView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    @State private var query = ""
    @State private var env: EnvTag?

    private var hosts: [SSHHost] {
        store.library.hosts.filter { h in
            (env == nil || h.tag == env) && (query.isEmpty || FuzzyMatcher.score(query, h.name + " " + h.address) != nil)
        }
    }

    private var selected: SSHHost? {
        store.selectedHost.flatMap(store.host) ?? store.library.hosts.first
    }

    var body: some View {
        if store.library.hosts.isEmpty {
            EmptyState(symbol: "globe", message: "No SSH hosts yet. Brix uses your ~/.ssh config, keys and agent.", actionTitle: "Add SSH Host") { store.sheet = .editHost(nil) }
                .island()
        } else {
            HStack(spacing: gap) {
                list.frame(width: 360)
                if let h = selected { HostDetail(host: h) } else { Spacer() }
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    SearchField(placeholder: "Search connections", text: $query, height: 30)
                    IconButton(symbol: "plus", label: "New connection", size: 30, iconSize: 12, color: Theme.text2) { store.sheet = .editHost(nil) }
                    IconButton(symbol: "dot.radiowaves.left.and.right", label: "Ping all servers", size: 30, iconSize: 12, color: Theme.text2) {
                        store.ping(store.library.hosts.map(\.id))
                    }
                    IconButton(symbol: "server.rack", label: "Server health", size: 30, iconSize: 12, color: Theme.text2) { store.go(.servers) }
                    IconButton(symbol: "square.and.arrow.down", label: "Import from JetBrains, VS Code or ~/.ssh/config", size: 30, iconSize: 12, color: Theme.text2) { store.sheet = .importConnections }
                }
                FlowLayout(spacing: 6) {
                    Chip(title: "All", dot: Theme.text2, isOn: env == nil) { env = nil }
                    ForEach([EnvTag.prod, .stage, .dev, .personal], id: \.self) { t in
                        Chip(title: t.name, dot: t.color, isOn: env == t) { env = env == t ? nil : t }
                    }
                }
            }
            .padding(12)
            .hairlineBottom()
            if hosts.isEmpty {
                EmptyState(symbol: "magnifyingglass", message: "No connections match.", actionTitle: "Clear filters") { query = ""; env = nil }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(hosts) { h in row(h) }
                    }
                    .padding(6)
                }
            }
        }
        .island()
    }

    private func row(_ h: SSHHost) -> some View {
        let status = store.hostStatus[h.id] ?? .disconnected
        let on = h.id == selected?.id
        return HStack(spacing: 11) {
            ServerOSIcon(host: h, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(h.name).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    TagPill(tag: h.tag)
                }
                Text(h.address).font(Typo.mono(11)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(status == .connecting ? "…" : (h.lastConnected.map { RelativeTime.short($0) } ?? "never")).font(Typo.ui(11)).foregroundStyle(Theme.text3)
                PingBadge(hostID: h.id)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .rowBackground(selected: on, radius: 8)
        .onTapGesture { store.selectedHost = h.id; store.inspector = .host(h.id) }
        .onTapGesture(count: 2) { store.connect(h.id) }
        .contextMenu { HostContextMenu(host: h) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(h.name), \(h.tag.name), \(status.label)")
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }
}

struct HostDetail: View {
    @Environment(AppStore.self) private var store
    let host: SSHHost

    private func title(_ h: SSHHost, status: ConnectionStatus, metrics m: HostMetrics?) -> some View {
        HStack(spacing: 14) {
            ServerOSIcon(host: h, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(h.name).font(Typo.ui(16, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    TagPill(tag: h.tag)
                }
                HStack(spacing: 6) {
                    StatusDot(color: status.color, size: 6)
                    Text([status.label, m?.os ?? h.os, m.map { "up \($0.uptime)" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Typo.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
                }
            }
            .fixedSize()
        }
    }

    private func actions(_ h: SSHHost, status: ConnectionStatus) -> some View {
        HStack(spacing: 8) {
            SubtleButton(title: "Browse Files", symbol: "folder") {
                store.guardProduction(h.tag, name: h.name, verb: "Browse files on") { store.go(.remoteFiles(h.id)) }
            }
            SubtleButton(title: "Edit") { store.sheet = .editHost(h) }
            SubtleButton(title: store.pinging.contains(h.id) ? "Pinging…" : "Ping", symbol: "dot.radiowaves.left.and.right") { store.ping([h.id]) }
                .help(store.hostPing[h.id].map { "Last: \($0.error ?? $0.label), \(RelativeTime.short($0.at)) ago" } ?? "Time a connection to port \(h.port)")
            SubtleButton(title: "Duplicate") { store.duplicateHost(h.id) }
            MenuButton(items: {
                [MenuSpec(title: "Copy SSH Command") { store.copyToPasteboard(h.sshCommand, label: "SSH command") },
                 MenuSpec(title: status.isLive ? "Disconnect" : "Test Connection") {
                     if status.isLive { store.disconnect(h.id) } else { store.connect(h.id, openShell: false) }
                 },
                 .separator,
                 MenuSpec(title: "Remove…") { store.requestRemoveHost(h.id) }]
            }) {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.text2)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.control))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlStroke))
            }
            .accessibilityLabel("More actions")
            AccentButton(title: status == .connecting ? "Connecting…" : "Open Terminal", shortcut: "↩", isLoading: status == .connecting) { store.connect(h.id) }
                .disabled(status == .connecting)
                .keyboardShortcut(.return, modifiers: [])
        }
        .fixedSize()
    }

    var body: some View {
        let h = host
        let status = store.hostStatus[h.id] ?? .disconnected
        let m = store.hostMetrics[h.id]
        let sessions = store.sessions.filter { $0.hostID == h.id }
        VStack(spacing: 0) {
            // Buttons move under the name when the pane is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    title(h, status: status, metrics: m)
                    Spacer(minLength: 8)
                    actions(h, status: status)
                }
                VStack(alignment: .leading, spacing: 12) {
                    title(h, status: status, metrics: m)
                    actions(h, status: status)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .hairlineBottom()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Connection").font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3).padding(.bottom, 6)
                            detailRow("Host", h.host)
                            detailRow("User", h.user)
                            detailRow("Port", "\(h.port)")
                            detailRow("Auth", HostAuthText.describe(h, keychainHas: store.keychain.has(Keychain.hostAccount(h.id))))
                            detailRow("Last connected", h.lastConnected.map { RelativeTime.long($0) + " ago" } ?? "Never")
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Rectangle().fill(Theme.divider).frame(width: 1)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Health").font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3)
                            if let m {
                                healthRow("CPU", m.cpu, Theme.green)
                                healthRow("Memory", m.memory, Theme.amber)
                                healthRow("Disk", m.disk, Theme.blue)
                                Text("Load \(m.load)").font(Typo.mono(11)).foregroundStyle(Theme.text3)
                            } else {
                                Text(status.isLive ? "Collecting metrics…" : "Connect to see CPU, memory and disk.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .hairlineBottom()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Open sessions").font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3)
                        if sessions.isEmpty {
                            Text("No sessions on this host.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
                        }
                        ForEach(sessions) { s in
                            Button { store.focusedSessionID = s.id; store.route = .terminals } label: {
                                HStack(spacing: 10) {
                                    StatusDot(color: s.state.color, size: 6)
                                    Text(s.title).font(Typo.ui(13, .medium)).foregroundStyle(Theme.text)
                                    Text(s.process).font(Typo.mono(11)).foregroundStyle(Theme.text3).lineLimit(1)
                                    Spacer()
                                    Text(RelativeTime.short(s.startedAt)).font(Typo.ui(11)).foregroundStyle(Theme.text3)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.editor))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.divider))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        Text("Linked projects").font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3).padding(.top, 10)
                        let projects = store.library.links.projects(for: h.id).compactMap(store.project)
                        if projects.isEmpty { Text("Not linked to any project.").font(Typo.ui(12)).foregroundStyle(Theme.text3) }
                        FlowLayout(spacing: 6) {
                            ForEach(projects) { p in
                                Button { store.openProject(p.id) } label: {
                                    HStack(spacing: 6) {
                                        ProjectMark(project: p, size: 16)
                                        Text(p.name).font(Typo.ui(12)).foregroundStyle(Theme.text)
                                    }
                                    .padding(.leading, 4).padding(.trailing, 9).frame(height: 26)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white(0.04)))
                                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if !h.notes.isEmpty {
                            Text("Notes").font(Typo.ui(11, .semibold)).foregroundStyle(Theme.text3).padding(.top, 10)
                            Text(h.notes).font(Typo.ui(12.5)).foregroundStyle(Theme.body).lineSpacing(3)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .island()
    }

    private func detailRow(_ k: String, _ v: String) -> some View {
        HStack(spacing: 0) {
            Text(k).font(Typo.row).foregroundStyle(Theme.text3).frame(width: 120, alignment: .leading)
            Text(v).font(Typo.mono(12)).foregroundStyle(Theme.text).lineLimit(1).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .hairlineBottom(Color.white(0.04))
    }

    private func healthRow(_ label: String, _ v: Double, _ c: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).font(Typo.ui(12)).foregroundStyle(Theme.text2).frame(width: 60, alignment: .leading)
            MeterBar(label: label, value: v, color: c, showLabel: false)
            Text("\(Int((v * 100).rounded()))%").font(Typo.ui(12)).monospacedDigit().foregroundStyle(Theme.text).frame(width: 36, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.4), value: v)
    }
}

/// The last ping: green when quick, amber when slow, red with no reply.
struct PingBadge: View {
    @Environment(AppStore.self) private var store
    let hostID: ResourceID

    var body: some View {
        if store.pinging.contains(hostID) {
            ProgressView().controlSize(.mini)
        } else if let r = store.hostPing[hostID] {
            let color = r.ms == nil ? Theme.red : r.ms! < 150 ? Theme.green : Theme.amber
            Text(r.label).font(Typo.mono(10.5, .medium)).foregroundStyle(color)
                .help(r.error.map { "No reply: \($0)" } ?? "Port answered in \(r.label), \(RelativeTime.short(r.at)) ago")
        }
    }
}
