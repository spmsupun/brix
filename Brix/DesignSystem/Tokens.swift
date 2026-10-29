import SwiftUI
import AppKit

// Design tokens from design/DESIGN.md. Every colour in the app comes from here.
// Each token has a dark and a light value; AppKit resolves them against the
// window's appearance, so switching theme needs no re-render bookkeeping.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    /// Parses "#RRGGBB". Falls back to tertiary text for malformed input.
    init(hexString: String) {
        let s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if let v = UInt32(s, radix: 16), s.count == 6 {
            self.init(hex: v)
        } else {
            self = Theme.text3
        }
    }

    /// A dark-theme value and its light-theme counterpart.
    static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in NSColor(hex: ap.isDark ? dark : light) })
    }

    /// Translucent "ink": white on dark surfaces, black on light ones.
    static func white(_ alpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in NSColor(white: ap.isDark ? 1 : 0, alpha: alpha) })
    }
    /// Shadows and scrims, lighter in the light theme.
    static func black(_ alpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in NSColor(white: 0, alpha: ap.isDark ? alpha : alpha * 0.35) })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// This colour as it looks under `appearance` (for layers and SwiftTerm,
    /// which don't resolve dynamic colours themselves).
    func resolved(for appearance: NSAppearance) -> NSColor {
        var out = self
        appearance.performAsCurrentDrawingAppearance { out = self.usingColorSpace(.sRGB) ?? self }
        return out
    }
}

extension NSFont {
    /// The user's code font (Customize → Code font), SF Mono when unset or missing.
    static func code(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let family = UIScale.shared.codeFamily
        if !family.isEmpty, let f = NSFontManager.shared.font(withFamily: family, traits: weight >= .semibold ? .boldFontMask : [],
                                                              weight: weight >= .semibold ? 9 : 5, size: size) {
            return f
        }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Installed fixed-width families for the code font picker.
    static var monospacedFamilies: [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") }.sorted()
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

enum Theme {
    // Surfaces
    static let base = Color.dyn(0x09090B, 0xE9E9EC)
    static let island = Color.dyn(0x121214, 0xF8F8F9)
    static let editor = Color.dyn(0x0E0E10, 0xFFFFFF)
    static let terminal = Color.dyn(0x0B0B0D, 0xFFFFFF)
    static let terminalHeader = Color.dyn(0x111113, 0xF4F4F5)
    static let input = Color.dyn(0x0C0C0E, 0xFFFFFF)
    static let sheet = Color.dyn(0x161618, 0xFAFAFB)
    static let popover = Color.dyn(0x18181B, 0xFFFFFF)
    static let menu = Color.dyn(0x1A1A1D, 0xFFFFFF)
    /// Tiled centre: pane island and its tab strip.
    static let pane = Color.dyn(0x141417, 0xFAFAFB)
    static let tileStrip = Color.dyn(0x0C0C0E, 0xE9E9EC)
    /// Strip above a terminal body, light enough that the dark active tab stands out.
    static let tileStripLight = Color.dyn(0x1A1A1E, 0xDCDCE0)
    static let well = Color.dyn(0x0F0F12, 0xF1F1F3)
    static let hover = Color.white(0.045)
    static let selected = Color.white(0.07)
    static let selectedStroke = Color.white(0.06)
    static let segmentedOn = Color.white(0.10)
    static let control = Color.white(0.05)
    static let controlStroke = Color.white(0.08)

    // Lines
    static let border = Color.white(0.07)
    static let divider = Color.white(0.06)
    static let highlight = Color.white(0.04)
    static let popoverBorder = Color.white(0.11)

    // Text
    static let text = Color.dyn(0xF4F4F5, 0x18181B)
    static let text2 = Color.dyn(0xA1A1AA, 0x52525B)
    static let body = Color.dyn(0xD4D4D8, 0x27272A)
    static let text3 = Color.dyn(0x8A8A93, 0x6B6B74)
    static let meta = Color.dyn(0x74747E, 0x84848D)
    static let lineNumber = Color.dyn(0x3F3F46, 0xA8A8B0)
    static let disabled = Color.dyn(0x52525B, 0xA1A1AA)
    static let grip = Color.dyn(0x4A4A52, 0xB4B4BB)
    static let offline = Color.dyn(0x5E5E66, 0xA1A1AA)
    /// Text and icons on accent fills: near-black on the bright dark-theme accents,
    /// white on the deeper light-theme ones.
    static let onAccent = Color.dyn(0x09090B, 0xFFFFFF)

    // Status
    static let green = Color.dyn(0x4ADE80, 0x16A34A)
    static let amber = Color.dyn(0xFBBF24, 0xD97706)
    static let red = Color.dyn(0xF87171, 0xDC2626)
    static let blue = Color.dyn(0x60A5FA, 0x2563EB)
    static let cyan = Color.dyn(0x22D3EE, 0x0891B2)
    static let violet = Color.dyn(0xA78BFA, 0x7C3AED)
    static let orange = Color.dyn(0xFB923C, 0xEA580C)
    static let pink = Color.dyn(0xF472B6, 0xDB2777)
    static let agentText = Color.dyn(0xC4B5FD, 0x6D28D9)
    static let pgBlue = Color.dyn(0x93B4FF, 0x2563EB)

    // Syntax
    static let synKeyword = Color.dyn(0xB4A1FF, 0x7C3AED)
    static let synString = Color.dyn(0xC3E88D, 0x15803D)
    static let synType = Color.dyn(0x7DD3FC, 0x0369A1)
    static let synFunction = Color.dyn(0xF4F4F5, 0x18181B)
    static let synNumber = Color.dyn(0xF5A97F, 0xC2410C)
    static let synComment = Color.dyn(0x5C5C66, 0x9A9AA3)
    static let synPunct = Color.dyn(0x8A8A93, 0x6B6B74)
    static let synTag = Color.dyn(0xF9A8D4, 0xBE185D)
    static let diffAddText = Color.dyn(0xD9F99D, 0x166534)
    static let diffDelText = Color.dyn(0xFECACA, 0x991B1B)
}

enum Metrics {
    static let toolbar: CGFloat = 52
    static let statusBar: CGFloat = 26
    static let panelHeader: CGFloat = 36
    static let tabBar: CGFloat = 38
    static let minWindow = CGSize(width: 1100, height: 700)
    /// Below this window width the sidebar shows as the icon rail.
    static let autoRailWidth: CGFloat = 1280
    static let sidebarFull: CGFloat = 288
    static let sidebarRail: CGFloat = 56
    static let sidebarRange: ClosedRange<CGFloat> = 190...360
    static let islandRadius: CGFloat = 10
    static let sheetRadius: CGFloat = 14
    static let popoverRadius: CGFloat = 12
}

/// Text size offset for the density setting. Observable, so every view that
/// builds a font through `Typo` redraws when density changes.
@Observable final class UIScale {
    static let shared = UIScale()
    var bump: CGFloat = 0
    var design: Font.Design = .default
    /// A named interface family (Helvetica Neue, Avenir Next…); nil uses the system font.
    var family: String?
    /// Code font family; empty is SF Mono.
    var codeFamily = ""
}

enum Typo {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let f = UIScale.shared.family { return .custom(f, size: size + UIScale.shared.bump).weight(weight) }
        return .system(size: size + UIScale.shared.bump, weight: weight, design: UIScale.shared.design)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let family = UIScale.shared.codeFamily
        if !family.isEmpty, NSFont(name: family, size: size) != nil || NSFontManager.shared.availableMembers(ofFontFamily: family) != nil {
            return .custom(family, size: size + UIScale.shared.bump).weight(weight)
        }
        return .system(size: size + UIScale.shared.bump, weight: weight, design: .monospaced)
    }
    static var body: Font { ui(13) }
    static var row: Font { ui(12.5) }
    static var secondary: Font { ui(12) }
    static var meta: Font { ui(11) }
    static var panelTitle: Font { ui(11, .semibold) }
    static var sectionTitle: Font { ui(10.5, .semibold) }
    static var pageTitle: Font { ui(17, .semibold) }
}

enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case lime, violet, cyan, amber, pink, blue
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .lime: Color.dyn(0xC8F560, 0x65A30D)
        case .violet: Color.dyn(0xA78BFA, 0x7C3AED)
        case .cyan: Color.dyn(0x22D3EE, 0x0891B2)
        case .amber: Color.dyn(0xFBBF24, 0xD97706)
        case .pink: Color.dyn(0xF472B6, 0xDB2777)
        case .blue: Color.dyn(0x60A5FA, 0x2563EB)
        }
    }
    var label: String { rawValue.capitalized }
}

/// Project identity hue. Stored by name so persisted data stays readable.
enum ProjectHue: String, Codable, CaseIterable, Identifiable {
    case violet, cyan, orange, pink, blue, green, amber, red
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .violet: Theme.violet
        case .cyan: Theme.cyan
        case .orange: Theme.orange
        case .pink: Theme.pink
        case .blue: Theme.blue
        case .green: Theme.green
        case .amber: Theme.amber
        case .red: Theme.red
        }
    }
}

enum EnvTag: String, Codable, CaseIterable, Identifiable {
    case prod, stage, dev, personal, local
    var id: String { rawValue }
    var label: String {
        switch self {
        case .prod: "PROD"
        case .stage: "STAGE"
        case .dev: "DEV"
        case .personal: "PERSONAL"
        case .local: "LOCAL"
        }
    }
    var name: String {
        switch self {
        case .prod: "Production"
        case .stage: "Staging"
        case .dev: "Development"
        case .personal: "Personal"
        case .local: "Local"
        }
    }
    var color: Color {
        switch self {
        case .prod: Theme.red
        case .stage: Theme.amber
        case .dev: Theme.blue
        case .personal: Theme.violet
        case .local: Theme.cyan
        }
    }
    var isProduction: Bool { self == .prod }
}

// MARK: - Environment

private struct AccentKey: EnvironmentKey { static let defaultValue = AccentChoice.lime.color }
private struct IslandGapKey: EnvironmentKey { static let defaultValue: CGFloat = 6 }
private struct DensityKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    var accent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
    var islandGap: CGFloat {
        get { self[IslandGapKey.self] }
        set { self[IslandGapKey.self] = newValue }
    }
    /// Extra row height: 0 compact, 6 comfortable. Use `.rowHeight(_:)`.
    var rowExtra: CGFloat {
        get { self[DensityKey.self] }
        set { self[DensityKey.self] = newValue }
    }
}

private struct RowHeight: ViewModifier {
    @Environment(\.rowExtra) private var extra
    let base: CGFloat
    func body(content: Content) -> some View { content.frame(height: base + extra) }
}

extension View {
    /// Fixed row height that grows in the comfortable density.
    func rowHeight(_ base: CGFloat) -> some View { modifier(RowHeight(base: base)) }
}
