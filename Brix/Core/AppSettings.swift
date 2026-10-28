import SwiftUI
import AppKit

enum IslandSpacing: String, Codable, CaseIterable, Identifiable {
    case seamless, islands, airy
    var id: String { rawValue }
    var gap: CGFloat {
        switch self {
        case .seamless: 1
        case .islands: 6
        case .airy: 10
        }
    }
    var label: String { rawValue.capitalized }
}

enum Density: String, Codable, CaseIterable, Identifiable {
    case compact, comfortable, large
    var id: String { rawValue }
    /// Extra row height and text size for each density.
    var extra: CGFloat {
        switch self {
        case .compact: 0
        case .comfortable: 6
        case .large: 12
        }
    }
    var textBump: CGFloat {
        switch self {
        case .compact: 0
        case .comfortable: 1
        case .large: 2.5
        }
    }
    var label: String { rawValue.capitalized }
}

enum UIFontChoice: String, Codable, CaseIterable, Identifiable {
    case system, rounded, helvetica, avenir, inter, gillSans, serif, mono
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "SF Pro"
        case .rounded: "SF Rounded"
        case .helvetica: "Helvetica Neue"
        case .avenir: "Avenir Next"
        case .inter: "Inter"
        case .gillSans: "Gill Sans"
        case .serif: "New York"
        case .mono: "SF Mono"
        }
    }
    var design: Font.Design {
        switch self {
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        default: .default
        }
    }
    /// A named sans family, or nil for the system font in `design`.
    var family: String? {
        switch self {
        case .helvetica: "Helvetica Neue"
        case .avenir: "Avenir Next"
        case .inter: "Inter"
        case .gillSans: "Gill Sans"
        default: nil
        }
    }
    /// Choices that can be used on this Mac (Inter only when installed).
    static var available: [UIFontChoice] {
        allCases.filter { c in c.family.map { NSFontManager.shared.availableMembers(ofFontFamily: $0) != nil } ?? true }
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }
}

enum SidebarPosition: String, Codable, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum SidebarStyle: String, Codable, CaseIterable, Identifiable {
    case full, rail
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct AppSettings: Codable, Equatable {
    var accent: AccentChoice = .lime
    var spacing: IslandSpacing = .islands
    var density: Density = .compact
    var sidebarPosition: SidebarPosition = .left
    var sidebarStyle: SidebarStyle = .full
    var sidebarWidth: CGFloat = Metrics.sidebarFull
    var sidebarHidden = false
    var terminalFontSize: CGFloat = 12
    var notifyFinished = true
    var notifyNeedsInput = true
    var badgeDock = true
    var notifySound = false
    var collapsedSections: Set<String> = []
    var appearance: AppearanceMode = .dark
    /// Projects expanded in the sidebar tree.
    var expandedProjects: Set<String> = []
    /// Coding agents the user can start, in menu order.
    var agents: [AgentConfig] = AgentConfig.builtins
    /// Agent started without asking; nil asks every time.
    var defaultAgent: String?
    /// Plan and files column beside an agent session.
    var agentSidePanel = true
    /// The message box under agent sessions (typing in the terminal still works).
    var agentComposer = true
    /// Tool window bars on the workspace edges.
    var showToolStrips = true
    var uiFont: UIFontChoice = .system
    /// Family for code, terminals and SQL; empty means SF Mono.
    var codeFont = ""

    init() {}

    // Tolerant decoding so new settings never wipe old files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.defaults
        accent = (try? c.decode(AccentChoice.self, forKey: .accent)) ?? d.accent
        spacing = (try? c.decode(IslandSpacing.self, forKey: .spacing)) ?? d.spacing
        density = (try? c.decode(Density.self, forKey: .density)) ?? d.density
        sidebarPosition = (try? c.decode(SidebarPosition.self, forKey: .sidebarPosition)) ?? d.sidebarPosition
        sidebarStyle = (try? c.decode(SidebarStyle.self, forKey: .sidebarStyle)) ?? d.sidebarStyle
        sidebarWidth = (try? c.decode(CGFloat.self, forKey: .sidebarWidth)) ?? d.sidebarWidth
        // 232 was the old default; the project tree is designed at 288.
        if sidebarWidth == 232 { sidebarWidth = d.sidebarWidth }
        sidebarHidden = (try? c.decode(Bool.self, forKey: .sidebarHidden)) ?? d.sidebarHidden
        terminalFontSize = (try? c.decode(CGFloat.self, forKey: .terminalFontSize)) ?? d.terminalFontSize
        notifyFinished = (try? c.decode(Bool.self, forKey: .notifyFinished)) ?? d.notifyFinished
        notifyNeedsInput = (try? c.decode(Bool.self, forKey: .notifyNeedsInput)) ?? d.notifyNeedsInput
        badgeDock = (try? c.decode(Bool.self, forKey: .badgeDock)) ?? d.badgeDock
        notifySound = (try? c.decode(Bool.self, forKey: .notifySound)) ?? d.notifySound
        collapsedSections = (try? c.decode(Set<String>.self, forKey: .collapsedSections)) ?? d.collapsedSections
        appearance = (try? c.decode(AppearanceMode.self, forKey: .appearance)) ?? d.appearance
        expandedProjects = (try? c.decode(Set<String>.self, forKey: .expandedProjects)) ?? d.expandedProjects
        agents = AgentConfig.mergingBuiltins((try? c.decode([AgentConfig].self, forKey: .agents)) ?? d.agents)
        defaultAgent = try? c.decode(String.self, forKey: .defaultAgent)
        agentSidePanel = (try? c.decode(Bool.self, forKey: .agentSidePanel)) ?? d.agentSidePanel
        agentComposer = (try? c.decode(Bool.self, forKey: .agentComposer)) ?? d.agentComposer
        showToolStrips = (try? c.decode(Bool.self, forKey: .showToolStrips)) ?? d.showToolStrips
        uiFont = (try? c.decode(UIFontChoice.self, forKey: .uiFont)) ?? d.uiFont
        codeFont = (try? c.decode(String.self, forKey: .codeFont)) ?? d.codeFont
    }

    static let defaults = AppSettings()
}
