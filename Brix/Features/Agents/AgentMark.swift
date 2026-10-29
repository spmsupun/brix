import SwiftUI

/// An agent's logo. Uses the real artwork where it's on this Mac (the Claude
/// app's own mark, or an image the user picked), else a simple drawn mark.
/// Spins only while the agent is actually working on something.
struct AgentMark: View {
    let agent: AgentConfig?
    var size: CGFloat = 14
    /// Kept for callers; the mark no longer moves (the spinner beside it says
    /// "working"). It used a TimelineView that redrew every frame on the main thread.
    var working = false

    var body: some View {
        glyph
            .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var style: AgentLogo { AgentLogo(binary: agent?.binary) }

    @ViewBuilder private var glyph: some View {
        if let img = AgentLogoImages.image(for: agent) {
            Image(nsImage: img.image)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .foregroundStyle(img.tint ?? Theme.text)
        } else {
            switch style {
            case .claude:
                ClaudeBurst().fill(Color(hex: 0xD97757))
            case .codex:
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Theme.text)
                    Text(">_").font(.system(size: size * 0.48, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.island)
                }
            case .gemini:
                FourPointStar().fill(LinearGradient(colors: [Color(hex: 0x4F8BF7), Color(hex: 0x9B72F2), Color(hex: 0xD96570)], startPoint: .bottomLeading, endPoint: .topTrailing))
            case .opencode:
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(Theme.text, lineWidth: max(1, size * 0.11))
                    RoundedRectangle(cornerRadius: 1).fill(Theme.text).frame(width: size * 0.34, height: size * 0.34)
                }
            case .other:
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Theme.violet.opacity(0.18))
                    Text(String((agent?.name ?? "A").prefix(1)).uppercased()).font(.system(size: size * 0.58, weight: .bold)).foregroundStyle(Theme.violet)
                }
            }
        }
    }
}

/// Logo images found on disk, loaded once per path.
@MainActor
enum AgentLogoImages {
    struct Logo {
        var image: NSImage
        /// Template images (single-colour marks) are tinted; app icons are not.
        var tint: Color?
    }
    private static var cache: [String: Logo?] = [:]

    /// Known places the real marks live when the vendor's app is installed.
    static let installed: [String: (path: String, tint: Color?)] = [
        "claude": ("/Applications/Claude.app/Contents/Resources/TrayIconTemplate@3x.png", Color(hex: 0xD97757)),
        "codex": ("/Applications/Codex.app/Contents/Resources/AppIcon.icns", nil)
    ]

    static func image(for agent: AgentConfig?) -> Logo? {
        guard let agent else { return nil }
        if !agent.iconPath.isEmpty { return load((agent.iconPath as NSString).expandingTildeInPath, tint: nil) }
        guard let known = installed[agent.binary] else { return nil }
        return load(known.path, tint: known.tint)
    }

    private static func load(_ path: String, tint: Color?) -> Logo? {
        let key = path + (tint == nil ? "" : "#t")
        if let hit = cache[key] { return hit }
        var logo: Logo?
        if FileManager.default.fileExists(atPath: path), let img = NSImage(contentsOfFile: path) {
            if tint != nil { img.isTemplate = true }
            logo = Logo(image: img, tint: tint)
        }
        cache[key] = logo
        return logo
    }
}

enum AgentLogo {
    case claude, codex, gemini, opencode, other
    init(binary: String?) {
        switch binary {
        case "claude": self = .claude
        case "codex": self = .codex
        case "gemini": self = .gemini
        case "opencode": self = .opencode
        default: self = .other
        }
    }
}

/// Radiating rays, like Claude's spark.
struct ClaudeBurst: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let rays = 11
        for i in 0..<rays {
            let a = Double(i) / Double(rays) * 2 * .pi - .pi / 2
            let len = r.width / 2 * (i.isMultiple(of: 2) ? 1 : 0.78)
            let w = r.width * 0.075
            let dir = CGVector(dx: cos(a), dy: sin(a))
            let n = CGVector(dx: -dir.dy, dy: dir.dx)
            let tip = CGPoint(x: c.x + dir.dx * len, y: c.y + dir.dy * len)
            let base = CGPoint(x: c.x + dir.dx * r.width * 0.06, y: c.y + dir.dy * r.width * 0.06)
            p.move(to: CGPoint(x: base.x + n.dx * w, y: base.y + n.dy * w))
            p.addLine(to: CGPoint(x: tip.x + n.dx * w * 0.6, y: tip.y + n.dy * w * 0.6))
            p.addQuadCurve(to: CGPoint(x: tip.x - n.dx * w * 0.6, y: tip.y - n.dy * w * 0.6),
                           control: CGPoint(x: tip.x + dir.dx * w, y: tip.y + dir.dy * w))
            p.addLine(to: CGPoint(x: base.x - n.dx * w, y: base.y - n.dy * w))
            p.closeSubpath()
        }
        p.addEllipse(in: CGRect(x: c.x - r.width * 0.11, y: c.y - r.width * 0.11, width: r.width * 0.22, height: r.width * 0.22))
        return p
    }
}

/// Four-pointed sparkle with concave sides, like Gemini's.
struct FourPointStar: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let pts = [CGPoint(x: c.x, y: r.minY), CGPoint(x: r.maxX, y: c.y), CGPoint(x: c.x, y: r.maxY), CGPoint(x: r.minX, y: c.y)]
        p.move(to: pts[0])
        for i in 1...4 { p.addQuadCurve(to: pts[i % 4], control: c) }
        p.closeSubpath()
        return p
    }
}

extension AppStore {
    /// The agent behind a session, by id or by the process it runs.
    func agent(for s: TerminalSession) -> AgentConfig? {
        agent(s.agentID) ?? settings.agents.first { $0.binary == s.process }
    }

    /// Session name shown in tabs and headers: a rename, the agent's own title,
    /// the first task, then the agent's name.
    private static let unnamedShell: Set<String> = ["zsh", "bash", "Terminal"]

    func displayTitle(_ s: TerminalSession) -> String {
        if s.kind == .shell, s.hostID == nil, Self.unnamedShell.contains(s.title) {
            // An unnamed local terminal: what it's running, else "Terminal",
            // "Terminal 2", … in the order they were opened in the project.
            if s.state == .running, !["zsh", "bash", "login"].contains(s.process) { return s.process }
            let peers = sessions.filter { $0.kind == .shell && $0.hostID == nil && $0.projectID == s.projectID && Self.unnamedShell.contains($0.title) }
            let n = (peers.firstIndex { $0.id == s.id } ?? 0) + 1
            return n == 1 ? "Terminal" : "Terminal \(n)"
        }
        guard s.kind == .agent else { return s.title }
        let agentName = agent(for: s)?.name ?? "Agent"
        if s.title != agentName, s.title != "Claude Code" { return s.title }
        if let n = s.sessionName, !n.isEmpty { return n }
        if !s.task.isEmpty { return s.task }
        return agentName
    }
}

/// Icon for any session: the agent's mark (animated while working) or a terminal/globe.
struct SessionIcon: View {
    @Environment(AppStore.self) private var store
    let session: TerminalSession?
    var size: CGFloat = 12

    var body: some View {
        if let s = session, s.kind == .agent {
            AgentMark(agent: store.agent(for: s), size: size, working: s.state == .running)
        } else {
            Image(systemName: session?.isRemote == true ? "globe" : "terminal")
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .frame(width: size, height: size)
        }
    }
}
