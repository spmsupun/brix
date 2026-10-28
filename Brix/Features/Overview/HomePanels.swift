import SwiftUI

/// Island header used by the Home panels: 38pt, small title, optional trailing.
private struct PanelTop<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Typo.ui(11, .semibold)).tracking(0.44).foregroundStyle(Theme.text2)
            trailing()
        }
        .padding(.horizontal, 14).frame(height: 38).hairlineBottom()
    }
}

// MARK: - Since your last visit

/// What needs you: agents waiting, failed builds, unreachable servers,
/// unpushed commits, and agents that finished while you were away.
struct SinceLastVisit: View {
    @Environment(AppStore.self) private var store
    let since: Date

    struct Item: Identifiable {
        enum Tone { case waiting, failed, push, done, running }
        let id: String
        let tone: Tone
        let title: String
        let sub: String
        let action: String
        let perform: () -> Void
        var needsYou: Bool { tone != .done && tone != .running }
    }

    private var items: [Item] {
        var out: [Item] = []
        for s in store.waitingSessions {
            let p = s.projectID.flatMap(store.project).map(store.fullName) ?? "Terminals"
            let ask = s.lastOutput.split(separator: "\n").last.map(String.init) ?? "asked a question"
            out.append(Item(id: "w-\(s.id)", tone: .waiting, title: "\(store.displayTitle(s)) is waiting for your answer",
                            sub: "\(p) · \(ask)", action: "Answer") { store.reveal(session: s.id) })
        }
        // The latest failure per project, if it's still the latest result there.
        var seen = Set<ProjectID>()
        for b in store.builds() where !seen.contains(b.projectID) && b.kind != .run {
            seen.insert(b.projectID)
            guard !b.ok, let p = store.project(b.projectID) else { continue }
            out.append(Item(id: "b-\(b.id)", tone: .failed, title: "\(b.task) failed in \(store.fullName(p))",
                            sub: "\(RelativeTime.ago(b.date)) · took \(AppStore.duration(b.duration))", action: "Fix with agent") { fix(b, p) })
        }
        for p in store.library.projects {
            for r in store.failedPipelines(p.id).prefix(2) {
                out.append(Item(id: "ci-\(r.id)", tone: .failed, title: "\(r.workflowName) failed in \(store.fullName(p))",
                                sub: "\(r.headBranch) · \(r.displayTitle) · \(RelativeTime.ago(r.updatedAt))", action: "Open") {
                    if let u = URL(string: r.url), u.scheme == "https" { NSWorkspace.shared.open(u) }
                })
            }
            let running = store.runningPipelines(p.id)
            if running > 0 {
                out.append(Item(id: "cir-\(p.id)", tone: .running, title: running == 1 ? "A pipeline is running in \(store.fullName(p))" : "\(running) pipelines are running in \(store.fullName(p))",
                                sub: "GitHub Actions · updates every 15 seconds", action: "View") { store.route = .projectHome(p.id) })
            }
        }
        for h in store.library.hosts {
            guard case .error(let why) = store.hostStatus[h.id] ?? .disconnected else { continue }
            out.append(Item(id: "h-\(h.id)", tone: .failed, title: "\(h.name) is unreachable", sub: why, action: "Check") {
                store.connect(h.id, openShell: false)
            })
        }
        for p in store.library.projects where !p.isSample {
            guard let g = store.git[p.id], g.isRepo, g.ahead > 0 else { continue }
            out.append(Item(id: "p-\(p.id)", tone: .push, title: "\(store.fullName(p)) has \(g.ahead) commit\(g.ahead == 1 ? "" : "s") not pushed",
                            sub: "\(g.branch) · ahead of \(g.remote) by \(g.ahead)", action: "Push") { store.push(p.id) })
        }
        let done = store.sessions.filter { $0.kind == .agent && ($0.state == .finished || ($0.state == .idle && !$0.touched.isEmpty)) }
        if let first = done.first {
            let files = Set(done.flatMap { $0.touched.map(\.path) }).count
            out.append(Item(id: "done", tone: .done, title: done.count == 1 ? "\(store.displayTitle(first)) finished" : "\(done.count) agents finished",
                            sub: "\(store.displayTitle(first)) is ready to review\(files > 0 ? " · \(files) file\(files == 1 ? "" : "s")" : "")",
                            action: "Review") { store.reveal(session: first.id) })
        }
        return out
    }

    var body: some View {
        let all = items
        let need = all.filter(\.needsYou).count
        VStack(spacing: 0) {
            PanelTop(title: "Since your last visit") {
                Text(RelativeTime.ago(since)).font(Typo.ui(11)).foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
                if need > 0 {
                    Text("\(need) need\(need == 1 ? "s" : "") you").font(Typo.ui(10, .bold)).foregroundStyle(Color(hex: 0x09090B))
                        .padding(.horizontal, 7).padding(.vertical, 1).background(Capsule().fill(Theme.amber))
                }
            }
            if all.isEmpty {
                EmptyState(symbol: "checkmark.seal", message: "All clear. Nothing needs you right now.")
            } else {
                ScrollView {
                    VStack(spacing: 2) { ForEach(all) { row($0) } }.padding(6)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .island()
    }

    private func row(_ i: Item) -> some View {
        let (glyph, fg, bg): (String, Color, Color) = switch i.tone {
        case .waiting: ("!", Color(hex: 0x09090B), Theme.amber)
        case .failed: ("✕", Theme.red, Theme.red.opacity(0.12))
        case .push: ("↑", Theme.violet, Theme.violet.opacity(0.14))
        case .done: ("✓", Theme.green, Theme.green.opacity(0.12))
        case .running: ("◌", Theme.amber, Theme.amber.opacity(0.12))
        }
        return HStack(spacing: 12) {
            Text(glyph).font(.system(size: 13, weight: .black)).foregroundStyle(fg)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 8).fill(bg))
            VStack(alignment: .leading, spacing: 2) {
                Text(i.title).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(i.sub).font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(i.action, action: i.perform)
                .buttonStyle(HomeActionStyle(primary: i.tone == .waiting))
        }
        .padding(.horizontal, 10).frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 9).fill(i.tone == .waiting ? Theme.amber.opacity(0.07) : .clear))
    }

    /// An agent looks at the failure: runs the task, reads the error, fixes it.
    private func fix(_ b: BuildRecord, _ p: Project) {
        let cmd = store.svc(p).activity.runTasks(p).first { $0.name == b.task }?.command ?? b.task
        let prompt = "`\(cmd)` failed. Run it, read the error, and fix the cause. Keep the change small."
        store.openProject(p.id)
        store.startAgent(project: p.id) { s in
            let ws = store.workspace(for: p.id)
            ws.attach(session: s, preferAgentGrid: true)
            ws.focus(session: s.id)
            Task {
                if s.isLive { try? await Task.sleep(nanoseconds: 2_500_000_000) }
                store.sendInput(s.id, prompt)
            }
        }
    }
}

struct HomeActionStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.ui(12, primary ? .bold : .semibold))
            .foregroundStyle(primary ? Color(hex: 0x09090B) : Theme.text)
            .padding(.horizontal, 12).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(primary ? Theme.amber : Color.white(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(primary ? .clear : Color.white(0.09)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Usage and limits

struct UsageLimits: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent

    var body: some View {
        let providers = store.settings.agents.filter { $0.enabled && !(store.agentUsage[$0.id] ?? []).isEmpty }
        VStack(spacing: 0) {
            PanelTop(title: "Usage & limits") {
                Spacer(minLength: 0)
                Text("per agent provider").font(Typo.ui(11)).foregroundStyle(Theme.text3)
            }
            VStack(spacing: 0) {
                if providers.isEmpty {
                    Text("No plan usage found. Turn on usage for an agent in Settings → Agents.")
                        .font(Typo.ui(12)).foregroundStyle(Theme.text3).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(providers) { a in
                    ForEach(store.agentUsage[a.id] ?? [], id: \.label) { w in row(a, w) }
                }
                if let note = projection(providers) {
                    Text(note).font(Typo.ui(11.5)).foregroundStyle(Color(hex: 0xFCD34D)).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.amber.opacity(0.08)))
                        .padding(.horizontal, 6).padding(.top, 4)
                }
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
        }
        .island()
    }

    private func row(_ a: AgentConfig, _ w: UsageWindow) -> some View {
        let c = w.percent >= 90 ? Theme.red : w.percent >= 70 ? Theme.amber : (a.binary == "claude" ? Color(hex: 0xE07B53) : accent)
        return HStack(spacing: 10) {
            Text("\(a.name.components(separatedBy: " ").first ?? a.name) \(w.label)").font(Typo.ui(12.5)).foregroundStyle(Theme.text).lineLimit(1).frame(width: 74, alignment: .leading)
            GeometryReader { g in
                Capsule().fill(Color.white(0.07))
                    .overlay(alignment: .leading) { Capsule().fill(c).frame(width: g.size.width * min(max(w.percent, 0), 100) / 100) }
            }
            .frame(height: 6)
            Text("\(Int(w.percent))%").font(Typo.mono(11.5)).foregroundStyle(Theme.text).frame(width: 34, alignment: .trailing)
            Text(w.resetsAt.map(resetText) ?? "").font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 6).frame(height: 30)
        .help(AgentUsageChips.tip(a, [w]))
    }

    private func resetText(_ d: Date) -> String {
        let s = d.timeIntervalSinceNow
        if s <= 0 { return "resets now" }
        if s < 3600 { return "resets in \(Int(s) / 60)m" }
        if s < 86_400 { return "resets in \(Int(s) / 3600)h \(Int(s) % 3600 / 60)m" }
        let f = DateFormatter()
        f.dateFormat = "EEE H:mm"
        return "resets " + f.string(from: d)
    }

    /// From the last days' highest readings: when the 7-day window reaches 80% at
    /// this pace. Shown only with two or more days of readings, and only if
    /// that happens before the window resets.
    private func projection(_ providers: [AgentConfig]) -> String? {
        for a in providers {
            guard let w = (store.agentUsage[a.id] ?? []).first(where: { $0.label.lowercased().contains("7") }), w.percent < 80,
                  let reset = w.resetsAt else { continue }
            let days = store.week("usage", a.id)
            guard let firstDay = days.firstIndex(where: { $0 > 0 }), days.count - 1 - firstDay >= 1 else { continue }
            let span = Double(days.count - 1 - firstDay)
            let rate = (w.percent - days[firstDay]) / span
            guard rate > 0 else { continue }
            let when = Date().addingTimeInterval((80 - w.percent) / rate * 86_400)
            guard when < reset else { continue }
            let f = DateFormatter()
            f.dateFormat = "EEEE"
            return "At today’s pace you’ll reach 80% of the \(a.name.components(separatedBy: " ").first ?? a.name) 7-day limit by \(f.string(from: when))."
        }
        return nil
    }
}

// MARK: - This Mac

struct ThisMac: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    @State private var stats: MacStats?
    @State private var hogs: [(name: String, path: String, bytes: Int64)] = []
    @State private var sampler = MacStats.Sampler()

    var body: some View {
        VStack(spacing: 0) {
            PanelTop(title: "This Mac") {
                Spacer(minLength: 0)
                if let s = stats {
                    Text([s.chip, s.memoryTotal > 0 ? "\(Int((s.memoryTotal / 1_073_741_824).rounded())) GB" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
            }
            if let s = stats {
                VStack(spacing: 0) {
                    let agents = store.sessions.filter { $0.kind == .agent && $0.state == .running }.count
                    meter("CPU", s.cpu ?? 0, Theme.green, s.cpu.map { "\(Int($0 * 100))%\(agents > 0 ? " · \(agents) agent\(agents == 1 ? "" : "s")" : "")" } ?? "…")
                    let mem = s.memoryTotal > 0 ? s.memoryUsed / s.memoryTotal : 0
                    meter("Memory", mem, mem >= 0.85 ? Theme.red : mem >= 0.75 ? Theme.amber : Theme.green,
                          "\(gb(s.memoryUsed)) / \(gb(s.memoryTotal)) GB", warn: mem >= 0.75)
                    if s.appMemory > 0, s.memoryTotal > 0 {
                        // Brix's own share, so it's clear what the app itself costs.
                        meter("Brix", s.appMemory / s.memoryTotal, accent,
                              ByteCountFormatter.string(fromByteCount: Int64(s.appMemory), countStyle: .memory))
                    }
                    let used = s.diskTotal > 0 ? 1 - s.diskFree / s.diskTotal : 0
                    meter("Storage", used, used >= 0.9 ? Theme.red : Theme.blue, "\(gb(s.diskFree)) GB free", warn: used >= 0.9)
                    if let b = s.battery {
                        meter("Battery", Double(b) / 100, b <= 20 ? Theme.red : Theme.green, "\(b)%\(s.charging ? " · charging" : "")", warn: b <= 20)
                    }
                    if !hogs.isEmpty {
                        HStack(spacing: 8) {
                            Text("Top: " + hogs.prefix(3).map { "\($0.name) \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))" }.joined(separator: " · "))
                                .font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let xcode = hogs.first(where: { $0.name == "Xcode build cache" }), xcode.bytes > 500_000_000 {
                                Button("Clear \(ByteCountFormatter.string(fromByteCount: xcode.bytes, countStyle: .file))") { clear(xcode) }
                                    .buttonStyle(HomeActionStyle())
                                    .help("Move Xcode's build cache (DerivedData) to the Trash. Xcode rebuilds it as needed.")
                            }
                        }
                        .padding(.horizontal, 6).frame(height: 30)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            }
            Spacer(minLength: 0)
        }
        .island()
        .task {
            // Two samples a moment apart give the first CPU reading.
            let s = sampler
            _ = s.read()
            stats = s.read()
            hogs = await Task.detached(priority: .background) { MacStats.hogs() }.value
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if store.windowVisible { stats = s.read() }
            }
        }
    }

    private func gb(_ bytes: Double) -> String { String(Int((bytes / 1_073_741_824).rounded())) }

    private func meter(_ label: String, _ value: Double, _ color: Color, _ text: String, warn: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label).font(Typo.ui(12.5)).foregroundStyle(Theme.text).frame(width: 64, alignment: .leading)
            GeometryReader { g in
                Capsule().fill(Color.white(0.07))
                    .overlay(alignment: .leading) { Capsule().fill(color).frame(width: g.size.width * min(max(value, 0), 1)) }
            }
            .frame(height: 6)
            Text(text).font(Typo.ui(11.5)).foregroundStyle(warn ? color : Theme.text2).lineLimit(1).frame(width: 118, alignment: .trailing)
        }
        .padding(.horizontal, 6).frame(height: 30)
    }

    private func clear(_ hog: (name: String, path: String, bytes: Int64)) {
        store.confirm("Move Xcode's build cache to the Trash?", "Frees about \(ByteCountFormatter.string(fromByteCount: hog.bytes, countStyle: .file)). Xcode rebuilds it on the next build, which takes longer once.", confirm: "Move to Trash") {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: hog.path), resultingItemURL: nil)
                hogs.removeAll { $0.path == hog.path }
                store.toast(.success, "Moved the build cache to the Trash")
            } catch {
                store.toast(.error, "Couldn't move the build cache", detail: error.localizedDescription)
            }
        }
    }
}

// MARK: - Servers and Docker

struct ServersAndDocker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent

    private struct Row: Identifiable {
        let id: String
        let name: String
        let tag: EnvTag?
        let local: Bool
        let dot: Color
        let sub: String
        let subColor: Color
        let action: String?
        let perform: () -> Void
        let rank: Int
    }

    private var rows: [Row] {
        var out: [Row] = []
        let open = Set(store.library.openProjects)
        for h in store.library.hosts {
            let st = store.hostStatus[h.id] ?? .disconnected
            let m = store.hostMetrics[h.id]
            switch st {
            case .error(let why):
                out.append(Row(id: h.id, name: h.name, tag: h.tag, local: false, dot: Theme.red, sub: "unreachable · \(why)", subColor: Theme.red,
                               action: "Reconnect", perform: { store.connect(h.id, openShell: false) }, rank: 0))
            case .connected, .idle:
                let sub = [m.map { "up \($0.uptime)" }, m.map { "CPU \(Int($0.cpu * 100))%" }].compactMap { $0 }.joined(separator: " · ")
                out.append(Row(id: h.id, name: h.name, tag: h.tag, local: false, dot: Theme.green, sub: sub.isEmpty ? "connected" : sub, subColor: Theme.text3,
                               action: nil, perform: {}, rank: 1))
            case .connecting:
                out.append(Row(id: h.id, name: h.name, tag: h.tag, local: false, dot: Theme.blue, sub: "connecting…", subColor: Theme.text3,
                               action: nil, perform: {}, rank: 1))
            case .disconnected:
                let linked = store.library.links.projects(for: h.id).contains { open.contains($0) }
                out.append(Row(id: h.id, name: h.name, tag: h.tag, local: false, dot: Theme.disabled,
                               sub: linked ? "disconnected · linked to an open project" : "disconnected", subColor: Theme.text3,
                               action: linked ? "Connect" : nil, perform: { store.connect(h.id, openShell: false) }, rank: linked ? 2 : 3))
            }
        }
        if store.dockerVisible {
            let local = store.allDocker.filter { $0.hostID == nil }
            let running = local.filter { $0.state == .running }.count
            let restarting = local.filter { $0.state == .restarting }
            let sub = "\(running) running" + (restarting.isEmpty ? "" : " · \(restarting.count) restarting (\(restarting.prefix(2).map(\.name).joined(separator: ", ")))")
            out.append(Row(id: "docker-local", name: "Docker · this Mac", tag: nil, local: true, dot: restarting.isEmpty ? Theme.green : Theme.amber,
                           sub: store.dockerInstalled ? sub : "not installed", subColor: restarting.isEmpty ? Theme.text3 : Theme.amber,
                           action: "Open", perform: { store.go(.docker) }, rank: restarting.isEmpty ? 1 : 0))
        }
        return out.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element)
    }

    var body: some View {
        let all = rows
        VStack(spacing: 0) {
            PanelTop(title: "Servers & Docker") {
                Spacer(minLength: 0)
                Button("Manage →") { store.go(.ssh) }.buttonStyle(.plain).font(Typo.ui(11.5)).foregroundStyle(accent)
            }
            if all.isEmpty {
                EmptyState(symbol: "server.rack", message: "No servers yet. Add one, or import them from ~/.ssh/config.", actionTitle: "Add Server") { store.sheet = .editHost(nil) }
            } else {
                ScrollView {
                    VStack(spacing: 0) { ForEach(all) { row($0) } }.padding(6)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .island()
    }

    private func row(_ r: Row) -> some View {
        HStack(spacing: 10) {
            Circle().fill(r.dot).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.name).font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if let t = r.tag { TagPill(tag: t, size: 8.5, filled: false) }
                    if r.local { Text("LOCAL").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.cyan) }
                }
                Text(r.sub).font(Typo.ui(11)).foregroundStyle(r.subColor).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let a = r.action {
                Button(a, action: r.perform).buttonStyle(MiniButtonStyle())
            }
        }
        .padding(.horizontal, 8).frame(height: 46)
        .contentShape(Rectangle())
        .onTapGesture { if !r.local { store.selectedHost = r.id; store.go(.ssh) } }
    }
}

private struct MiniButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.ui(11.5, .semibold)).foregroundStyle(Theme.text)
            .padding(.horizontal, 9).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white(0.09)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
