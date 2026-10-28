import AppKit
import SwiftUI

/// Home: the build site (buddy and project towers), then what needs you since
/// your last visit, usage and this Mac, and servers and Docker.
struct HomeOverview: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap
    /// When you last left Home; "since your last visit" counts from here.
    @State private var since: Date?

    var body: some View {
        let space = max(gap, 6)
        VStack(spacing: space) {
            BuildSite().frame(height: 450)
            GeometryReader { geo in
                // Columns 1.45 : 1 : 1, as designed.
                let unit = (geo.size.width - space * 2) / 3.45
                HStack(alignment: .top, spacing: space) {
                    SinceLastVisit(since: since ?? Date().addingTimeInterval(-86_400)).frame(width: unit * 1.45)
                    VStack(spacing: space) {
                        UsageLimits()
                        ThisMac().frame(maxHeight: .infinity)
                    }
                    .frame(width: unit)
                    ServersAndDocker().frame(width: unit)
                }
                .frame(height: geo.size.height)
            }
        }
        .onAppear { since = store.library.lastHomeVisit }
        .onDisappear { store.library.lastHomeVisit = Date() }
        .task {
            // Today's totals for every project, for tower captions.
            for p in store.library.projects where store.dayStats[p.id] == nil {
                store.dayStats[p.id] = await store.svc(p).activity.dayStats(p)
            }
        }
    }
}

// MARK: - Build site

private let siteBackground = Color.dyn(0x0C0C0E, 0xF4F4F6)
private let receiptPaper = Color.dyn(0x161618, 0xFFFFFF)

struct BuildSite: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    @State private var towerScroll = ScrollGrab.Holder()

    var body: some View {
        // The site itself is static; the buddy, cranes, beacons and the glowing
        // brick animate through KeyframeLoop, in the render layer.
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                grid(geo.size)
                header.padding(.horizontal, 22).padding(.top, 18)
                ground(geo.size)
                towers(geo.size)
                BuddyScene(mood: mood, accent: accent)
                    .frame(width: 200, height: 190)
                    .position(x: 40 + 100, y: geo.size.height - 70 - 95)
                bubble
                    .frame(maxWidth: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .alignmentGuide(.leading) { _ in -196 }
                    .alignmentGuide(.top) { d in -(geo.size.height - 236 - d.height) }
            }
        }
        .background(siteBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your build site")
    }

    private var mood: BuddyMood { store.moodPreview ?? store.buddyMood }

    private func grid(_ s: CGSize) -> some View {
        Canvas { ctx, size in
            var p = Path()
            stride(from: 0, through: size.width, by: 28).forEach { x in p.move(to: CGPoint(x: x + 0.5, y: 0)); p.addLine(to: CGPoint(x: x + 0.5, y: size.height)) }
            stride(from: 0, through: size.height, by: 28).forEach { y in p.move(to: CGPoint(x: 0, y: y + 0.5)); p.addLine(to: CGPoint(x: size.width, y: y + 0.5)) }
            ctx.stroke(p, with: .color(Color.white(0.035)), lineWidth: 1)
        }
    }

    private func ground(_ s: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white(0.14)).frame(width: s.width, height: 2).offset(y: s.height - 72)
            Canvas { ctx, size in
                // 135° stripes, 10pt on and 10pt off.
                var p = Path()
                var x = -size.height
                while x < size.width + size.height {
                    p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                    p.addLine(to: CGPoint(x: x + size.height + 14.14, y: 0)); p.addLine(to: CGPoint(x: x + 14.14, y: size.height)); p.closeSubpath()
                    x += 28.28
                }
                ctx.fill(p, with: .color(Color.white(0.025)))
            }
            .frame(width: s.width, height: 70)
            .offset(y: s.height - 70)
        }
        .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Date().formatted(.dateTime.weekday(.wide).day().month(.wide))) · \(greeting)")
                    .font(Typo.ui(12)).foregroundStyle(Theme.text3)
                Text("Your build site").font(Typo.ui(24, .heavy)).tracking(-0.36).foregroundStyle(Theme.text)
                Text("Every brick is a commit. Cranes are agents at work.").font(Typo.ui(13)).foregroundStyle(Theme.text2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                let cranes = store.sessions.filter { $0.kind == .agent && $0.state == .running }.count
                HStack(spacing: 6) {
                    LiveDot(color: cranes > 0 ? Theme.green : Theme.disabled)
                    Text("\(cranes) crane\(cranes == 1 ? "" : "s") working")
                }
                .font(Typo.ui(11.5)).foregroundStyle(Theme.body)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Capsule().fill(Theme.base.opacity(0.7)))
                .overlay(Capsule().strokeBorder(Theme.controlStroke))
                let waiting = store.waitingSessions.count
                if waiting > 0 {
                    Button { if let s = store.waitingSessions.first { store.reveal(session: s.id) } } label: {
                        Text("! \(waiting) waiting for you").font(Typo.ui(11.5, .semibold)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Capsule().fill(Theme.amber))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return name.isEmpty ? part : "\(part), \(name)"
    }

    // MARK: Bubble

    private var bubble: some View {
        Text(bubbleText)
            .font(Typo.ui(12, .semibold)).lineSpacing(2.4)
            .foregroundStyle(Color(hex: 0x09090B))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 3, bottomTrailingRadius: 12, topTrailingRadius: 12)
                .fill(Color(hex: 0xF4F4F5)))
            .shadow(color: .black(0.4), radius: 12, y: 10)
            .accessibilityLabel("Brix buddy: \(bubbleText)")
    }

    private var bubbleText: String {
        let agents = store.sessions.filter { $0.kind == .agent }
        func place(_ s: [TerminalSession]) -> String {
            let names = Set(s.compactMap { $0.projectID.flatMap(store.project)?.name })
            return names.count == 1 ? names.first! : "the site"
        }
        switch mood {
        case .waiting:
            let w = store.waitingSessions
            return w.count == 1 ? "An agent on \(place(w)) is waiting for your answer." : "\(w.count) agents are waiting for your answers."
        case .shipped:
            let n = store.dayStats.values.reduce(0) { $0 + $1.commits }
            return n > 0 ? "\(n) commit\(n == 1 ? "" : "s") shipped. The tower grew!" : "Shipped! The tower grew!"
        case .working:
            let r = agents.filter { $0.state == .running }
            if r.isEmpty { return "The cranes are up. I’m helping stack!" }
            return r.count == 1 ? "A crane is up on \(place(r)). I’m helping stack!" : "\(r.count) cranes are up on \(place(r)). I’m helping stack!"
        case .idle:
            return "Site’s quiet. Give an agent a job?"
        }
    }

    // MARK: Towers

    /// Most active first: working and waiting agents, today's commits, uncommitted changes.
    private var activeProjects: [Project] {
        let projects = store.library.projects.filter { store.git[$0.id]?.isRepo == true || $0.isSample }
        func score(_ p: Project) -> Int {
            let agents = store.sessions.filter { $0.projectID == p.id && $0.kind == .agent && ($0.state == .running || $0.state == .needsInput) }.count
            return agents * 1000 + (store.dayStats[p.id]?.commits ?? 0) * 10 + store.changeCount(p.id)
        }
        return projects.sorted { score($0) > score($1) || (score($0) == score($1) && $0.lastOpened > $1.lastOpened) }
    }

    /// Every tower, side by side right of the buddy; scrolls sideways when they
    /// don't fit. The buddy, its bubble and the header stay where they are.
    @ViewBuilder private func towers(_ s: CGSize) -> some View {
        let start = max(s.width * 0.40, 400)
        let shown = activeProjects
        if shown.isEmpty {
            Text("No projects with git yet. Add one and every commit lays a brick here.")
                .font(Typo.ui(12)).foregroundStyle(Theme.text3)
                .position(x: (start + s.width) / 2, y: s.height - 110)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 24) {
                    ForEach(shown) { p in TowerView(project: p, accent: accent).frame(width: 150) }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 72)
                .frame(minWidth: s.width - start, maxHeight: .infinity, alignment: .bottomLeading)
                .background(ScrollGrab(holder: towerScroll))
                .contentShape(Rectangle())
                // A mouse drag slides the towers (the trackpad and wheel already scroll).
                .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { v in towerScroll.drag(v.translation.width) }
                    .onEnded { _ in towerScroll.end() })
            }
            // Towers fade out under the buddy's side rather than cut off.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                         .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: s.width - start, height: s.height)
            .offset(x: start)
        }
    }
}

// MARK: - Tower

private struct TowerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: Project
    let accent: Color

    private static let brickH: CGFloat = 14, gap: CGFloat = 3

    private struct Row: Identifiable { let id: Int; let today: Bool; let scaffold: Bool }

    /// Floors are commits: every commit today, older history compressed, then
    /// dashed scaffolding for uncommitted work.
    private var rows: [Row] {
        let commits = store.git[project.id]?.commits ?? []
        let today = commits.filter { Calendar.current.isDateInToday($0.date) }.count
        let older = commits.count - today
        let olderRows = older == 0 ? 0 : min(max(1, Int((Double(older).squareRoot() * 1.6).rounded())), 10)
        let built = min(today + olderRows, 13)
        let scaffold = min(Int((Double(store.changeCount(project.id)) / 3).rounded(.up)), 3, max(0, 13 - built))
        return (0..<(built + scaffold)).map { r in Row(id: r, today: r >= built - min(today, built) && r < built, scaffold: r >= built) }
    }

    private var agents: [TerminalSession] { store.sessions.filter { $0.projectID == project.id && $0.kind == .agent } }

    var body: some View {
        let rows = rows
        let working = agents.filter { $0.state == .running }
        let waiting = agents.contains { $0.state == .needsInput }
        let built = rows.filter { !$0.scaffold }.count
        let height = CGFloat(rows.count) * (Self.brickH + Self.gap)
        Button { store.route = .projectHome(project.id) } label: {
            ZStack(alignment: .bottom) {
                // One crane per working agent: the first on the right, the second mirrored on the left.
                ForEach(Array(working.prefix(2).enumerated()), id: \.element.id) { i, _ in
                    Crane(towerHeight: height, accent: accent, delay: Double(i) * 1.5)
                        .frame(width: 4, height: height + 110)
                        .scaleEffect(x: i == 0 ? 1 : -1, y: 1)
                        .offset(x: i == 0 ? 30 : -30)
                }
                VStack(spacing: Self.gap) {
                    ForEach(rows.reversed()) { r in
                        HStack(spacing: Self.gap) {
                            brick(r)
                            brick(r)
                        }
                        .background { if r.id == built - 1 && !working.isEmpty { glow } }
                        .offset(x: r.id % 2 == 1 ? 9 : -9)
                        .transition(.asymmetric(insertion: .offset(y: -90).combined(with: .opacity), removal: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .easeIn(duration: 0.6), value: rows.count)
                .frame(width: 100, alignment: .bottom)
                if waiting {
                    Beacon().frame(width: 18, height: 18).offset(y: -(height + 8))
                }
            }
            .frame(width: 100, height: max(height, 1), alignment: .bottom)
            .overlay(alignment: .top) {
                VStack(spacing: 2) {
                    // A repository inside a project shows that project above its name.
                    if let parent = project.parentID.flatMap(store.project) {
                        Text(parent.name).font(Typo.ui(10, .medium)).foregroundStyle(Theme.meta).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(project.hue.color).frame(width: 8, height: 8)
                        Text(project.name).font(Typo.ui(12.5, .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    }
                    Text(caption).font(Typo.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                .frame(width: 150)
                .offset(y: max(height, 1) + 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 100, height: max(height, 1))
        .handCursor()
        .help("Open \(project.name)")
        .accessibilityLabel("\(project.name) tower: \(built) floors, \(working.count) agents working\(waiting ? ", one waiting" : "")")
    }

    private func brick(_ r: Row) -> some View {
        let hue = project.hue.color
        return RoundedRectangle(cornerRadius: 3)
            .fill(r.scaffold ? Color.clear : (r.today ? hue : hue.opacity(0.35)))
            .overlay(alignment: .bottom) {
                if !r.scaffold { Rectangle().fill(Color.black.opacity(r.today ? 0.22 : 0.25)).frame(height: 3).clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)) }
            }
            .overlay {
                if r.scaffold { RoundedRectangle(cornerRadius: 3).strokeBorder(hue.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])) }
            }
            .frame(width: 32, height: Self.brickH)
    }

    /// newbrick: the top row glows, peaking halfway through 3s.
    private var glow: some View {
        KeyframeLoop(keyframes: Keyframes(stops: [(0, [0]), (0.5, [1]), (1, [0])], duration: 3), still: [0],
                     pose: { v in LayerPose(opacity: v[0]) }) {
            RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.45)).blur(radius: 6).padding(8)
        }
        .padding(-10)
    }

    private var caption: String {
        let ci = store.runningPipelines(project.id)
        if ci > 0 { return ci == 1 ? "pipeline running" : "\(ci) pipelines running" }
        let a = agents.filter { $0.state == .running || $0.state == .needsInput }.count
        let day = store.dayStats[project.id]
        if a > 0 {
            let lines = (day?.add ?? 0) > 0 ? " · +\(Self.short(day!.add)) today" : ""
            return "\(a) agent\(a == 1 ? "" : "s")\(lines)"
        }
        let changes = store.changeCount(project.id)
        if changes > 0 { return "\(Self.short(changes)) uncommitted" }
        if let e = store.events(project: project.id, limit: 1).first {
            return "quiet · \(e.kind == .deploy ? "deployed" : e.kind == .commit ? "committed" : "active") \(RelativeTime.ago(e.date))"
        }
        return "quiet"
    }

    static func short(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
}

/// Striped mast, jib and counterweight; the cable lowers an accent brick onto the tower (3s loop).
private struct Crane: View {
    let towerHeight: CGFloat
    let accent: Color
    var delay: Double = 0

    var body: some View {
        let fall: Double = 92
        let cable = Keyframes(stops: [(0, [0]), (0.7, [fall]), (0.85, [fall]), (1, [fall])], duration: 3, delay: delay, curve: .easeIn)
        let load = Keyframes(stops: [(0, [0, 0]), (0.12, [fall * 0.12 / 0.7, 1]), (0.7, [fall, 1]), (0.85, [fall, 0]), (1, [fall, 0])], duration: 3, delay: delay, curve: .easeIn)
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                // Mast: 7pt amber, 3pt brown.
                var y = size.height
                var amber = true
                while y > 0 {
                    let h: CGFloat = amber ? 7 : 3
                    ctx.fill(Path(CGRect(x: 0, y: max(0, y - h), width: 4, height: min(h, y))), with: .color(amber ? Color(hex: 0xFBBF24) : Color(hex: 0xB45309)))
                    y -= h; amber.toggle()
                }
            }
            .frame(width: 4, height: towerHeight + 110)
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0xFBBF24)).frame(width: 96, height: 4).offset(x: -62)
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0x52525B)).frame(width: 14, height: 10).offset(x: 18, y: 4)
            // Grown with a transform, not a frame, so the window never re-lays out.
            KeyframeLoop(keyframes: cable, still: [fall], anchor: .top, pose: { v in LayerPose(sy: max(0.001, v[0] / fall)) }) {
                Rectangle().fill(Color.white.opacity(0.55))
            }
            .frame(width: 1, height: fall)
            .offset(x: -28, y: 4)
            KeyframeLoop(keyframes: load, still: [fall, 1], pose: { v in LayerPose(ty: v[0], opacity: v[1]) }) {
                RoundedRectangle(cornerRadius: 2).fill(accent)
            }
            .frame(width: 26, height: 12)
            .offset(x: -41, y: 4)
        }
        .frame(width: 4, height: towerHeight + 110, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// Amber light on top of a tower whose agent is waiting.
private struct Beacon: View {
    var body: some View {
        let k = Keyframes(stops: [(0, [1, 0, 0.6]), (0.5, [0.55, 10, 0]), (1, [1, 0, 0.6])], duration: 1.2)
        ZStack {
            KeyframeLoop(keyframes: k, still: [1, 0, 0], pose: { v in LayerPose(sx: (18 + 2 * v[1]) / 18, sy: (18 + 2 * v[1]) / 18, opacity: v[2]) }) {
                Circle().fill(Theme.amber)
            }
            KeyframeLoop(keyframes: k, still: [1, 0, 0], pose: { v in LayerPose(opacity: v[0]) }) {
                Circle().fill(Theme.amber)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

// MARK: - Buddy

/// The Brix buddy and its props, in a 200 × 190 box standing on the ground.
struct BuddyScene: View {
    let mood: BuddyMood
    let accent: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            if mood == .working { bricks }
            if mood == .idle { zz }
            if mood == .shipped { confetti }
            if mood == .waiting { bang }
            KeyframeLoop(keyframes: motion, still: [0, 0, 1, 1], anchor: .bottom,
                         pose: { v in LayerPose(ty: v[0], rotate: v[1], sx: v[2], sy: v[3]) }) {
                BuddyFigure(mood: mood, accent: accent, eyes: false)
                    .overlay {
                        if mood != .idle {
                            // Eyes blink every 4s, about their own centre line.
                            KeyframeLoop(keyframes: Keyframes(stops: [(0, [1]), (0.92, [1]), (0.95, [0.1]), (1, [1])], duration: 4), still: [1],
                                         anchor: UnitPoint(x: 0.5, y: 29.0 / 66), pose: { b in LayerPose(sy: b[0]) }) {
                                BuddyEyes(mood: mood)
                            }
                        }
                    }
            }
            .frame(width: 96, height: 99)
            .id(mood)
            .offset(x: 34, y: 190 - 99)
        }
        .frame(width: 200, height: 190, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// The mood's body motion, anchored at the feet: [translateY, rotate°, scaleX, scaleY].
    private var motion: Keyframes {
        switch mood {
        case .working: Keyframes(stops: [(0, [0, 0, 1, 1]), (0.25, [-6, -3, 1, 1]), (0.75, [-2, 3, 1, 1]), (1, [0, 0, 1, 1])], duration: 0.9, curve: .easeInOut)
        case .waiting: Keyframes(stops: [(0, [0, 0, 1, 1]), (0.3, [-16, 0, 1, 1]), (0.5, [0, 0, 1, 1]), (0.65, [-7, 0, 1, 1]), (1, [0, 0, 1, 1])], duration: 1.4, curve: .easeInOut)
        case .shipped: Keyframes(stops: [(0, [0, 0, 1, 1]), (0.2, [2, 0, 1.06, 0.92]), (0.45, [-26, 0, 0.96, 1.06]), (0.7, [0, 0, 1.04, 0.95]), (1, [0, 0, 1, 1])], duration: 1.2, curve: .easeInOut)
        case .idle: Keyframes(stops: [(0, [0, 0, 1, 1]), (0.5, [0, 0, 1.02, 0.97]), (1, [0, 0, 1, 1])], duration: 3.2, curve: .easeInOut)
        }
    }

    /// Three bricks dropping one by one onto a little pile (2.4s, 0 / 0.6 / 1.2s).
    private var bricks: some View {
        let colors: [UInt32] = [0xFB923C, 0xF97316, 0xFB923C]
        return ZStack(alignment: .bottomLeading) {
            ForEach(0..<3, id: \.self) { i in
                KeyframeLoop(keyframes: Keyframes(stops: [(0, [-90, 0]), (0.3, [-63, 1]), (0.6, [0, 1]), (1, [0, 1])], duration: 2.4, delay: Double(i) * 0.6, rest: [0, 1]),
                             still: [0, 1], pose: { k in LayerPose(ty: k[0], opacity: k[1]) }) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: colors[i]))
                }
                .frame(width: i == 0 ? 48 : 40, height: 13)
                .offset(x: i == 1 ? 8 : 0, y: -CGFloat(i) * 16)
            }
        }
        .frame(width: 48, height: 45, alignment: .bottomLeading)
        .offset(x: 132, y: 190 - 1 - 45)
    }

    private var zz: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<2, id: \.self) { i in
                KeyframeLoop(keyframes: Keyframes(stops: [(0, [0, 0, 0]), (0.3, [5.4, -11.4, 1]), (1, [18, -38, 0])], duration: 2.6, delay: Double(i) * 1.2, rest: [0, 0, 1]),
                             still: [0, 0, 1], pose: { k in LayerPose(tx: k[0], ty: k[1], opacity: k[2]) }) {
                    Text("z").font(.system(size: i == 0 ? 17 : 13, weight: .heavy)).foregroundStyle(Theme.text3).fixedSize()
                }
                .frame(width: 14, height: 22)
                .offset(x: CGFloat(i) * 11)
            }
        }
        .offset(x: 124, y: 48)
    }

    private var confetti: some View {
        let colors: [Color] = [accent, Color(hex: 0xA78BFA), Color(hex: 0x22D3EE), Color(hex: 0xFB923C), Color(hex: 0xF472B6)]
        return ZStack(alignment: .topLeading) {
            ForEach(0..<14, id: \.self) { i in
                KeyframeLoop(keyframes: Keyframes(stops: [(0, [-40, 0, 0]), (0.15, [-4, 39, 1]), (1, [200, 260, 0])], duration: 1.6 + Double(i % 4) * 0.25, delay: Double(i) * 0.12, rest: [0, 0, 1]),
                             still: [Double(i * 37 % 120), Double(i * 40), 1], pose: { k in LayerPose(ty: k[0], rotate: k[1], opacity: k[2]) }) {
                    RoundedRectangle(cornerRadius: 1).fill(colors[i % 5])
                }
                .frame(width: 6, height: 9)
                .offset(x: CGFloat(10 + (i * 13) % 176))
            }
        }
    }

    private var bang: some View {
        KeyframeLoop(keyframes: Keyframes(stops: [(0, [1]), (0.5, [1.15]), (1, [1])], duration: 0.8), still: [1], pose: { k in LayerPose(sx: k[0], sy: k[0]) }) {
            Text("!").font(.system(size: 17, weight: .heavy)).foregroundStyle(Color(hex: 0x09090B))
                .frame(width: 28, height: 28).background(Circle().fill(Theme.amber))
        }
        .frame(width: 28, height: 28)
        .offset(x: 118, y: 38)
    }
}

/// The buddy, drawn from the design's 64 × 66 artwork at 96 × 99.
struct BuddyFigure: View {
    let mood: BuddyMood
    let accent: Color
    var blink: Double = 1
    /// false leaves the eyes to BuddyEyes, so they can blink on their own.
    var eyes = true

    var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 64, y: size.height / 66)
            let ink = Color(hex: 0x09090B)
            if mood == .working {
                var hat = Path()
                hat.move(to: CGPoint(x: 14, y: 14)); hat.addQuadCurve(to: CGPoint(x: 50, y: 14), control: CGPoint(x: 32, y: -2)); hat.closeSubpath()
                ctx.fill(hat, with: .color(Color(hex: 0xFBBF24)))
                ctx.fill(Path(roundedRect: CGRect(x: 10, y: 12, width: 44, height: 4), cornerRadius: 2), with: .color(Color(hex: 0xF59E0B)))
            }
            ctx.fill(Path(roundedRect: CGRect(x: 6, y: 16, width: 52, height: 40), cornerRadius: 9), with: .color(accent))
            var seam = Path(); seam.move(to: CGPoint(x: 6, y: 33)); seam.addLine(to: CGPoint(x: 58, y: 33))
            ctx.stroke(seam, with: .color(.black.opacity(0.18)), lineWidth: 2)
            var joints = Path()
            for (x, y0, y1) in [(30.0, 16.0, 33.0), (20, 33, 56), (44, 33, 56)] { joints.move(to: CGPoint(x: x, y: y0)); joints.addLine(to: CGPoint(x: x, y: y1)) }
            ctx.stroke(joints, with: .color(.black.opacity(0.14)), lineWidth: 2)
            if mood == .idle {
                var closed = Path()
                closed.move(to: CGPoint(x: 19, y: 30)); closed.addQuadCurve(to: CGPoint(x: 29, y: 30), control: CGPoint(x: 24, y: 33))
                closed.move(to: CGPoint(x: 35, y: 30)); closed.addQuadCurve(to: CGPoint(x: 45, y: 30), control: CGPoint(x: 40, y: 33))
                ctx.stroke(closed, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else if eyes {
                let ry: CGFloat = mood == .waiting ? 6.5 : 5.5
                let shift: CGFloat = mood == .working ? 2 : 0
                for cx in [24.0, 40.0] {
                    var eye = ctx
                    eye.translateBy(x: cx, y: 29); eye.scaleBy(x: 1, y: blink); eye.translateBy(x: -cx, y: -29)
                    eye.fill(Path(ellipseIn: CGRect(x: cx - 5, y: 29 - ry, width: 10, height: ry * 2)), with: .color(.white))
                    eye.fill(Path(ellipseIn: CGRect(x: cx + shift - 2.4, y: 30 - 2.4, width: 4.8, height: 4.8)), with: .color(ink))
                }
            }
            var mouth = Path()
            switch mood {
            case .working: mouth.move(to: CGPoint(x: 26, y: 41)); mouth.addQuadCurve(to: CGPoint(x: 38, y: 41), control: CGPoint(x: 32, y: 45))
            case .waiting: mouth.move(to: CGPoint(x: 28, y: 42)); mouth.addQuadCurve(to: CGPoint(x: 36, y: 42), control: CGPoint(x: 32, y: 39))
            case .shipped: mouth.move(to: CGPoint(x: 24, y: 39)); mouth.addQuadCurve(to: CGPoint(x: 40, y: 39), control: CGPoint(x: 32, y: 49)); mouth.closeSubpath()
            case .idle: mouth.move(to: CGPoint(x: 28, y: 42)); mouth.addLine(to: CGPoint(x: 36, y: 42))
            }
            if mood == .shipped { ctx.fill(mouth, with: .color(ink)) }
            ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for x in [14.0, 40.0] {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 56, width: 10, height: 6), cornerRadius: 3), with: .color(ink.opacity(0.65)))
            }
        }
    }
}

/// The buddy's open eyes alone, in the same 64 × 66 artwork space.
struct BuddyEyes: View {
    let mood: BuddyMood
    var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 64, y: size.height / 66)
            let ry: CGFloat = mood == .waiting ? 6.5 : 5.5
            let shift: CGFloat = mood == .working ? 2 : 0
            for cx in [24.0, 40.0] {
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 5, y: 29 - ry, width: 10, height: ry * 2)), with: .color(.white))
                ctx.fill(Path(ellipseIn: CGRect(x: cx + shift - 2.4, y: 30 - 2.4, width: 4.8, height: 4.8)), with: .color(Color(hex: 0x09090B)))
            }
        }
    }
}

/// Lets a mouse drag move the enclosing horizontal scroll view, which SwiftUI's
/// ScrollView only does for the trackpad and wheel on the Mac.
struct ScrollGrab: NSViewRepresentable {
    final class Holder {
        weak var scroll: NSScrollView?
        weak var anchor: NSView?
        private var origin: CGFloat?

        func drag(_ dx: CGFloat) {
            if scroll == nil { scroll = anchor?.enclosingScrollView }
            guard let sv = scroll, let doc = sv.documentView else { return }
            let start = origin ?? sv.contentView.bounds.origin.x
            origin = start
            let maxX = max(0, doc.frame.width - sv.contentView.bounds.width)
            sv.contentView.scroll(to: NSPoint(x: min(max(0, start - dx), maxX), y: sv.contentView.bounds.origin.y))
            sv.reflectScrolledClipView(sv.contentView)
        }

        func end() { origin = nil }
    }

    let holder: Holder

    func makeNSView(context: Context) -> NSView { Finder(holder: holder) }
    func updateNSView(_ v: NSView, context: Context) {}

    private final class Finder: NSView {
        let holder: Holder
        init(holder: Holder) { self.holder = holder; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            holder.anchor = self
            holder.scroll = enclosingScrollView
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
