import SwiftUI

/// What's selected on the Docker screen.
enum DockerSelection: Hashable {
    case container(ResourceID)
    case stack(ResourceID)
    case network(DockerNetwork)
    case volume(DockerVolume)
    case image(DockerImage)

    var hostID: ResourceID? {
        switch self {
        case .network(let n): n.hostID
        case .volume(let v): v.hostID
        case .image(let i): i.hostID
        case .container, .stack: nil
        }
    }
}

/// Portainer-style details for one Docker object, read with `docker … inspect`,
/// with the actions that object supports.
struct DockerDetailView: View {
    @Environment(AppStore.self) private var store
    let selection: DockerSelection
    @State private var inspect: [String: Any] = [:]
    @State private var raw = ""
    @State private var stats: [String: String] = [:]
    @State private var users: [String] = []
    @State private var error: String?
    @State private var loading = true
    @State private var showRaw = false
    @State private var revealSecrets = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                EmptyState(symbol: "exclamationmark.triangle", message: error, actionTitle: "Retry") { Task { await load() } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sections
                        InspectorSection(title: "Raw inspect") {
                            Button(showRaw ? "Hide JSON" : "Show JSON") { showRaw.toggle() }.buttonStyle(.hand).font(Typo.ui(12)).foregroundStyle(Theme.text2)
                            if showRaw {
                                Text(raw).font(Typo.mono(10.5)).foregroundStyle(Theme.body).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .island()
        .task(id: selection) { await load() }
        .task(id: selection) { await pollStats() }
    }

    // MARK: Loading

    private var host: SSHHost? {
        switch selection {
        case .container(let id): store.dockerTarget(id)?.hostID.flatMap(store.host)
        case .stack(let id): store.stack(id)?.hostID.flatMap(store.host)
        default: selection.hostID.flatMap(store.host)
        }
    }

    private var isSample: Bool {
        switch selection {
        case .container(let id): store.dockerTarget(id)?.isSample ?? false
        case .stack(let id): store.stack(id)?.isSample ?? false
        default: store.dockerInventory["sample"].map { inv in
            inv.networks.contains { if case .network(let n) = selection { return n == $0 }; return false }
                || inv.volumes.contains { if case .volume(let v) = selection { return v == $0 }; return false }
                || inv.images.contains { if case .image(let i) = selection { return i == $0 }; return false }
        } ?? false
        }
    }

    private var service: DockerService { isSample ? store.services.mock.docker : store.services.live.docker }

    private func docker(_ args: [String], timeout: TimeInterval = 20) async throws -> String {
        try await service.run(args, host: host, timeout: timeout)
    }

    private func load() async {
        loading = true
        error = nil
        inspect = [:]
        users = []
        do {
            switch selection {
            case .container(let id):
                guard let c = store.dockerTarget(id) else { throw ServiceError("Container not found") }
                raw = try await docker(["container", "inspect", c.name])
            case .stack(let id):
                guard store.stack(id) != nil else { throw ServiceError("Stack not found") }
                raw = ""
            case .network(let n):
                raw = try await docker(["network", "inspect", n.name])
                users = []
            case .volume(let v):
                raw = try await docker(["volume", "inspect", v.name])
                users = try await docker(["ps", "-a", "--filter", "volume=\(v.name)", "--format", "{{.Names}}"]).split(separator: "\n").map(String.init)
            case .image(let i):
                let ref = i.tag.isEmpty || i.tag == "<none>" ? i.id.components(separatedBy: "/").dropFirst().first ?? i.repository : "\(i.repository):\(i.tag)"
                raw = try await docker(["image", "inspect", ref])
                users = try await docker(["ps", "-a", "--filter", "ancestor=\(ref)", "--format", "{{.Names}}"]).split(separator: "\n").map(String.init)
            }
            if let data = raw.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let first = arr.first {
                inspect = first
                if let pretty = try? JSONSerialization.data(withJSONObject: first, options: [.prettyPrinted, .sortedKeys]) {
                    raw = String(decoding: pretty, as: UTF8.self)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// Live CPU and memory for running containers, every 3 seconds while shown.
    private func pollStats() async {
        guard case .container(let id) = selection else { return }
        while !Task.isCancelled {
            if let c = store.dockerTarget(id), c.state == .running,
               let out = try? await docker(["stats", "--no-stream", "--format", "{{json .}}", c.name], timeout: 10),
               let d = out.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                stats = obj.compactMapValues { $0 as? String }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    // MARK: Header and actions

    private var title: (String, String, String) {
        switch selection {
        case .container(let id):
            let c = store.dockerTarget(id)
            return ("shippingbox", c?.name ?? id, c?.image ?? "")
        case .stack(let id):
            let s = store.stack(id)
            return ("square.stack.3d.down.right", s?.name ?? id, s?.status ?? "")
        case .network(let n): return ("point.3.connected.trianglepath.dotted", n.name, "\(n.driver) network")
        case .volume(let v): return ("externaldrive", v.name, "\(v.driver) volume")
        case .image(let i): return ("square.stack.3d.up", "\(i.repository):\(i.tag)", i.size)
        }
    }

    private var header: some View {
        let t = title
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: t.0).font(.system(size: 15)).foregroundStyle(Theme.cyan)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9).fill(Theme.cyan.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.1).font(Typo.ui(14, .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Text(t.2).font(Typo.mono(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", label: "Close details", iconSize: 10) { store.dockerSelection = nil }
            }
            actions
        }
        .padding(14).hairlineBottom()
    }

    @ViewBuilder private var actions: some View {
        switch selection {
        case .container(let id):
            if let c = store.dockerTarget(id) {
                let running = c.state == .running, paused = c.state == .paused
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if running {
                            SubtleButton(title: "Stop", symbol: "stop.fill", height: 26) { store.dockerAction(.stop, id) }
                            SubtleButton(title: "Restart", symbol: "arrow.triangle.2.circlepath", height: 26) { store.dockerAction(.restart, id) }
                            SubtleButton(title: "Pause", symbol: "pause.fill", height: 26) { act(["pause", c.name], "Paused \(c.name)") }
                        } else if paused {
                            SubtleButton(title: "Resume", symbol: "play.fill", height: 26) { act(["unpause", c.name], "Resumed \(c.name)") }
                        } else {
                            SubtleButton(title: "Start", symbol: "play.fill", height: 26) { store.dockerAction(.start, id) }
                        }
                        SubtleButton(title: "Logs", symbol: "text.alignleft", height: 26) { store.openDockerLogs(id, project: nil) }
                        SubtleButton(title: "Shell", symbol: "terminal", height: 26) { store.openDockerShell(id, project: nil) }.disabled(!running)
                        MenuButton(items: {
                            [MenuSpec(title: "Kill") { confirmAct("Kill \(c.name)?", "Sends SIGKILL. Unsaved work in the container is lost.", ["kill", c.name], "Killed \(c.name)") },
                             MenuSpec(title: "Copy ID") { store.copyToPasteboard(inspect["Id"] as? String ?? c.name, label: "container id") },
                             .separator,
                             MenuSpec(title: "Attach to Project", children: store.attachToProjectMenu(resource: id, kind: .docker)),
                             .separator,
                             MenuSpec(title: "Remove…") {
                                confirmAct("Remove \(c.name)?", "Deletes the container\(running ? " (stopping it first)" : ""). Volumes are kept.", ["rm", "-f", c.name], "Removed \(c.name)") { store.dockerSelection = nil }
                             }]
                        }) { moreButton }
                    }
                }
            }
        case .stack(let id):
            if let s = store.stack(id) {
                HStack(spacing: 6) {
                    if s.isRunning {
                        SubtleButton(title: "Restart", symbol: "arrow.triangle.2.circlepath", height: 26) { store.composeAction(.restart, s) }
                        SubtleButton(title: "Stop", symbol: "stop.fill", height: 26) { store.composeAction(.stop, s) }
                    } else {
                        SubtleButton(title: "Up", symbol: "play.fill", height: 26) { store.composeAction(.up, s) }.disabled(s.configFiles.isEmpty)
                    }
                    SubtleButton(title: "Logs", symbol: "text.alignleft", height: 26) { store.openComposeLogs(s) }
                    MenuButton(items: {
                        [MenuSpec(title: "Pull Images") { store.composeAction(.pull, s) },
                         MenuSpec(title: "Attach to Project", children: store.attachToProjectMenu(resource: s.id, kind: .stack, stack: s)),
                         .separator,
                         MenuSpec(title: "Down…") { store.composeAction(.down, s) }]
                    }) { moreButton }
                }
            }
        case .network(let n):
            HStack(spacing: 6) {
                SubtleButton(title: "Remove…", symbol: "trash", height: 26, destructive: true) {
                    confirmAct("Remove network \(n.name)?", "Containers still attached will block this.", ["network", "rm", n.name], "Removed \(n.name)") { store.dockerSelection = nil }
                }
                .disabled(["bridge", "host", "none"].contains(n.name))
            }
        case .volume(let v):
            HStack(spacing: 6) {
                SubtleButton(title: "Remove…", symbol: "trash", height: 26, destructive: true) {
                    confirmAct("Remove volume \(v.name)?", "The data in it is deleted for good.", ["volume", "rm", v.name], "Removed \(v.name)") { store.dockerSelection = nil }
                }
                .disabled(!users.isEmpty)
                .help(users.isEmpty ? "Delete this volume" : "In use by \(users.joined(separator: ", "))")
            }
        case .image(let i):
            let ref = "\(i.repository):\(i.tag)"
            HStack(spacing: 6) {
                SubtleButton(title: "Pull", symbol: "arrow.down.circle", height: 26) { act(["pull", ref], "Pulled \(ref)", timeout: 600) }
                    .disabled(i.repository == "<none>")
                SubtleButton(title: "Remove…", symbol: "trash", height: 26, destructive: true) {
                    confirmAct("Remove image \(ref)?", "Containers using it must be removed first.", ["image", "rm", i.repository == "<none>" ? (inspect["Id"] as? String ?? ref) : ref], "Removed \(ref)") { store.dockerSelection = nil }
                }
            }
        }
    }

    private var moreButton: some View {
        Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text2)
            .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 8).fill(Theme.control)).contentShape(Rectangle())
    }

    private func act(_ args: [String], _ done: String, timeout: TimeInterval = 60, then: (() -> Void)? = nil) {
        Task {
            do {
                _ = try await docker(args, timeout: timeout)
                store.toast(.success, done)
                then?()
                await store.refreshDocker()
                await store.refreshDockerInventory()
                await load()
            } catch {
                store.toast(.error, "docker \(args.prefix(2).joined(separator: " ")) failed", detail: error.localizedDescription)
            }
        }
    }

    /// Destructive actions always ask; on a production host the button says so.
    private func confirmAct(_ title: String, _ message: String, _ args: [String], _ done: String, then: (() -> Void)? = nil) {
        let prod = host?.tag.isProduction ?? false
        store.confirm(title, message + (prod ? " This is on \(host!.name), a production host." : ""), confirm: prod ? "Run on Production" : "Remove") {
            act(args, done, then: then)
        }
    }

    // MARK: Sections

    @ViewBuilder private var sections: some View {
        switch selection {
        case .container: containerSections
        case .stack(let id): stackSections(id)
        case .network: networkSections
        case .volume: volumeSections
        case .image: imageSections
        }
    }

    private func dict(_ k: String, in d: [String: Any]? = nil) -> [String: Any] { (d ?? inspect)[k] as? [String: Any] ?? [:] }
    private func str(_ v: Any?) -> String {
        switch v {
        case let s as String: s
        case let a as [Any]: a.map { "\($0)" }.joined(separator: " ")
        case let n as NSNumber: n.stringValue
        default: "–"
        }
    }

    @ViewBuilder private var containerSections: some View {
        let state = dict("State"), config = dict("Config"), net = dict("NetworkSettings")
        InspectorSection(title: "Overview") {
            FactRow(key: "Status", value: str(state["Status"]), mono: false)
            FactRow(key: "Started", value: str(state["StartedAt"]))
            FactRow(key: "Image", value: str(config["Image"]))
            FactRow(key: "Command", value: str(config["Cmd"]))
            FactRow(key: "Entrypoint", value: str(config["Entrypoint"]))
            FactRow(key: "Workdir", value: str(config["WorkingDir"]))
            FactRow(key: "Restarts", value: str(inspect["RestartCount"] ?? state["RestartCount"]))
        }
        if !stats.isEmpty {
            InspectorSection(title: "Live stats") {
                FactRow(key: "CPU", value: stats["CPUPerc"] ?? "–")
                FactRow(key: "Memory", value: "\(stats["MemUsage"] ?? "–") (\(stats["MemPerc"] ?? "–"))")
                FactRow(key: "Network", value: stats["NetIO"] ?? "–")
                FactRow(key: "Disk I/O", value: stats["BlockIO"] ?? "–")
                FactRow(key: "Processes", value: stats["PIDs"] ?? "–")
            }
        }
        let ports = dict("Ports", in: net)
        InspectorSection(title: "Ports") {
            if ports.isEmpty { none }
            ForEach(ports.keys.sorted(), id: \.self) { k in
                let maps = (ports[k] as? [[String: Any]] ?? []).map { "\(str($0["HostIp"])):\(str($0["HostPort"]))" }
                FactRow(key: k, value: maps.isEmpty ? "not published" : maps.joined(separator: ", "))
            }
        }
        let networks = dict("Networks", in: net)
        InspectorSection(title: "Networks") {
            if networks.isEmpty { none }
            ForEach(networks.keys.sorted(), id: \.self) { k in FactRow(key: k, value: str(dict(k, in: networks)["IPAddress"]), keyWidth: 150) }
        }
        let mounts = inspect["Mounts"] as? [[String: Any]] ?? []
        InspectorSection(title: "Mounts") {
            if mounts.isEmpty { none }
            ForEach(Array(mounts.enumerated()), id: \.offset) { _, m in
                FactRow(key: str(m["Destination"]), value: "\(str(m["Name"] ?? m["Source"]))\((m["RW"] as? Bool) == false ? " (read-only)" : "")", keyWidth: 150)
            }
        }
        let env = config["Env"] as? [String] ?? []
        InspectorSection(title: "Environment") {
            if env.isEmpty { none }
            ForEach(env, id: \.self) { e in
                let parts = e.split(separator: "=", maxSplits: 1).map(String.init)
                let key = parts.first ?? e
                let secret = ["PASS", "SECRET", "TOKEN", "KEY", "PWD", "CREDENTIAL"].contains { key.uppercased().contains($0) }
                FactRow(key: key, value: secret && !revealSecrets ? "•••••" : (parts.count > 1 ? parts[1] : ""), keyWidth: 150)
            }
            if env.contains(where: { e in ["PASS", "SECRET", "TOKEN", "KEY", "PWD"].contains { e.uppercased().hasPrefix($0) || e.uppercased().contains($0 + "=") || e.uppercased().contains("_" + $0) } }) {
                Button(revealSecrets ? "Hide secret values" : "Show secret values") { revealSecrets.toggle() }
                    .buttonStyle(.hand).font(Typo.ui(11.5)).foregroundStyle(Theme.text2)
            }
        }
        let labels = dict("Labels", in: config)
        if !labels.isEmpty {
            InspectorSection(title: "Labels") {
                ForEach(labels.keys.sorted(), id: \.self) { k in FactRow(key: k, value: str(labels[k]), keyWidth: 200) }
            }
        }
    }

    @ViewBuilder private func stackSections(_ id: ResourceID) -> some View {
        if let s = store.stack(id) {
            let containers = store.allDocker.filter { $0.composeProject == s.name && $0.hostID == s.hostID }
            InspectorSection(title: "Services") {
                if containers.isEmpty { none }
                ForEach(containers) { c in
                    Button { store.dockerSelection = .container(c.id) } label: {
                        HStack(spacing: 8) {
                            StatusDot(color: c.state.color, size: 6)
                            Text(c.composeService.ifEmpty(c.name)).font(Typo.row).foregroundStyle(Theme.text)
                            Text(c.image).font(Typo.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                            Spacer()
                            Text(c.statusText.ifEmpty(c.state.rawValue)).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.meta)
                        }
                        .rowHeight(28).contentShape(Rectangle())
                    }
                    .buttonStyle(.hand)
                }
            }
            InspectorSection(title: "Compose files") {
                if s.configFiles.isEmpty { none }
                ForEach(s.configFiles, id: \.self) { f in
                    HStack {
                        Text((f as NSString).abbreviatingWithTildeInPath).font(Typo.mono(11)).foregroundStyle(Theme.body).lineLimit(1).truncationMode(.head)
                        Spacer()
                        if s.hostID == nil {
                            LinkButton(title: "Edit") { store.sheet = .editFile(.local((f as NSString).expandingTildeInPath)) }
                        }
                    }
                    .rowHeight(26)
                }
            }
            let inv = store.dockerInventory[s.hostID ?? (s.isSample ? "sample" : "local")]
            InspectorSection(title: "Networks and volumes") {
                let nets = inv?.networks.filter { $0.composeProject == s.name } ?? []
                let vols = inv?.volumes.filter { $0.composeProject == s.name } ?? []
                if nets.isEmpty && vols.isEmpty { none }
                ForEach(nets) { n in FactRow(key: "Network", value: n.name) }
                ForEach(vols) { v in FactRow(key: "Volume", value: v.name) }
            }
            InspectorSection(title: "Projects") {
                let ps = store.library.links.projects(for: s.id).compactMap(store.project)
                Text(ps.isEmpty ? "Not attached to a project." : ps.map(\.name).joined(separator: ", ")).font(Typo.ui(12)).foregroundStyle(Theme.text2)
            }
        }
    }

    @ViewBuilder private var networkSections: some View {
        let ipam = (dict("IPAM")["Config"] as? [[String: Any]])?.first ?? [:]
        InspectorSection(title: "Overview") {
            FactRow(key: "Driver", value: str(inspect["Driver"]))
            FactRow(key: "Scope", value: str(inspect["Scope"]))
            FactRow(key: "Subnet", value: str(ipam["Subnet"]))
            FactRow(key: "Gateway", value: str(ipam["Gateway"]))
            FactRow(key: "Internal", value: (inspect["Internal"] as? Bool) == true ? "Yes" : "No", mono: false)
        }
        let containers = dict("Containers")
        InspectorSection(title: "Containers") {
            if containers.isEmpty { none }
            ForEach(containers.keys.sorted(), id: \.self) { k in
                let c = dict(k, in: containers)
                FactRow(key: str(c["Name"]), value: str(c["IPv4Address"]), keyWidth: 150)
            }
        }
    }

    @ViewBuilder private var volumeSections: some View {
        InspectorSection(title: "Overview") {
            FactRow(key: "Driver", value: str(inspect["Driver"]))
            FactRow(key: "Mountpoint", value: str(inspect["Mountpoint"]))
            FactRow(key: "Created", value: str(inspect["CreatedAt"]))
            FactRow(key: "Scope", value: str(inspect["Scope"]))
        }
        usedBy
    }

    @ViewBuilder private var imageSections: some View {
        let config = dict("Config")
        InspectorSection(title: "Overview") {
            FactRow(key: "ID", value: String(str(inspect["Id"]).replacingOccurrences(of: "sha256:", with: "").prefix(12)))
            FactRow(key: "Tags", value: str(inspect["RepoTags"]))
            FactRow(key: "Created", value: str(inspect["Created"]))
            FactRow(key: "Size", value: (inspect["Size"] as? NSNumber).map { ByteCountFormatter.string(fromByteCount: $0.int64Value, countStyle: .file) } ?? "–")
            FactRow(key: "Platform", value: "\(str(inspect["Os"]))/\(str(inspect["Architecture"]))")
            FactRow(key: "Command", value: str(config["Cmd"]))
            FactRow(key: "Entrypoint", value: str(config["Entrypoint"]))
            FactRow(key: "Ports", value: dict("ExposedPorts", in: config).keys.sorted().joined(separator: ", ").ifEmpty("–"))
        }
        usedBy
    }

    private var usedBy: some View {
        InspectorSection(title: "Used by") {
            if users.isEmpty { Text("No containers.").font(Typo.ui(12)).foregroundStyle(Theme.text3) }
            ForEach(users, id: \.self) { name in
                Button {
                    if let c = store.allDocker.first(where: { $0.name == name && $0.hostID == host?.id }) { store.dockerSelection = .container(c.id) }
                } label: {
                    HStack { Text(name).font(Typo.row).foregroundStyle(Theme.text); Spacer(); Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.meta) }
                        .rowHeight(26).contentShape(Rectangle())
                }
                .buttonStyle(.hand)
            }
        }
    }

    private var none: some View { Text("None").font(Typo.ui(12)).foregroundStyle(Theme.text3) }
}
