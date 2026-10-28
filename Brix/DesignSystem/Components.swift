import SwiftUI
import AppKit

// MARK: - Island

struct IslandModifier: ViewModifier {
    var fill: Color = Theme.island
    var radius: CGFloat = Metrics.islandRadius
    var stroke: Color = Theme.border

    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .overlay(alignment: .top) {
                // 1px top inner highlight
                Rectangle().fill(Theme.highlight).frame(height: 1).padding(.horizontal, radius / 2).padding(.top, 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func island(_ fill: Color = Theme.island, radius: CGFloat = Metrics.islandRadius, stroke: Color = Theme.border) -> some View {
        modifier(IslandModifier(fill: fill, radius: radius, stroke: stroke))
    }

    /// Popover/menu surface: sheet colour, 10-11% border, deep shadow.
    func popoverSurface(_ fill: Color = Theme.popover, radius: CGFloat = Metrics.popoverRadius) -> some View {
        self
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.popoverBorder))
            .shadow(color: .black(0.65), radius: 30, y: 20)
    }

    func hairlineBottom(_ color: Color = Theme.divider) -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(color).frame(height: 1) }
    }

    func hairlineTop(_ color: Color = Theme.divider) -> some View {
        overlay(alignment: .top) { Rectangle().fill(color).frame(height: 1) }
    }

    /// Tooltip with a shortcut hint, e.g. help("New terminal", "⌘T").
    func tip(_ text: String, _ shortcut: String? = nil) -> some View {
        help(shortcut.map { "\(text)  \($0)" } ?? text)
    }
}

// MARK: - Grip

struct Grip: View {
    var body: some View {
        Canvas { ctx, _ in
            for row in 0..<3 {
                for col in 0..<2 {
                    let rect = CGRect(x: 1.3 + Double(col) * 5, y: 1.8 + Double(row) * 4, width: 2.4, height: 2.4)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Theme.grip))
                }
            }
        }
        .frame(width: 10, height: 14)
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

struct IconButton: View {
    let symbol: String
    let label: String
    var shortcut: String? = nil
    var size: CGFloat = 24
    var iconSize: CGFloat = 12.5
    var color: Color = Theme.text3
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // Grows with the Comfortable and Large densities like the text does.
            Image(systemName: symbol)
                .font(.system(size: iconSize + UIScale.shared.bump * 0.8, weight: .medium))
                .foregroundStyle(active ? Theme.text : (hovering ? Theme.text : color))
                .frame(width: size + UIScale.shared.bump * 2, height: size + UIScale.shared.bump * 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.white(0.08) : (hovering ? Theme.hover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .tip(label, shortcut)
    }
}

struct AccentButton: View {
    let title: String
    var symbol: String? = nil
    var shortcut: String? = nil
    var height: CGFloat = 30
    var fullWidth = false
    var isLoading = false
    let action: () -> Void
    @Environment(\.accent) private var accent
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isLoading {
                    ProgressView().controlSize(.mini).tint(Theme.onAccent)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                }
                Text(title).font(Typo.ui(12.5, .semibold)).lineLimit(1).fixedSize()
                if let shortcut {
                    Text(shortcut).font(Typo.ui(10.5)).opacity(0.55).fixedSize()
                }
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 13)
            .frame(height: height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(enabled ? 1 : 0.4)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(title, shortcut)
    }
}

struct SubtleButton: View {
    let title: String
    var symbol: String? = nil
    var shortcut: String? = nil
    var height: CGFloat = 30
    var fullWidth = false
    var destructive = false
    var isLoading = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                }
                Text(title).font(Typo.ui(12, .medium)).lineLimit(1).fixedSize()
                if let shortcut {
                    Text(shortcut).font(Typo.ui(10.5)).foregroundStyle(Theme.text3).fixedSize()
                }
            }
            .foregroundStyle(destructive ? Theme.red : Theme.text)
            .padding(.horizontal, 11)
            .frame(height: height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering && enabled ? Color.white(0.08) : Theme.control))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlStroke))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tip(title, shortcut)
    }
}

/// Small text link such as "All terminals →".
struct LinkButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.accent) private var accent
    var body: some View {
        Button(action: action) {
            Text(title).font(Typo.ui(11.5)).foregroundStyle(accent)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Small pieces

struct TagPill: View {
    let tag: EnvTag
    var size: CGFloat = 9
    var filled = true
    var body: some View {
        Text(tag.label)
            .font(.system(size: size, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(tag.color)
            .padding(.horizontal, filled ? 5 : 0)
            .padding(.vertical, filled ? 2 : 0)
            .background(RoundedRectangle(cornerRadius: 4).fill(filled ? tag.color.opacity(0.12) : .clear))
            .fixedSize()
            .accessibilityLabel(tag.name)
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 7
    var ring = false
    var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if pulse && !reduceMotion {
            // Core Animation pulse: a SwiftUI repeatForever animation here re-rendered
            // the whole window every frame while any session was running.
            LiveDot(color: color, size: size, ring: ring ? 4 : 3)
        } else {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .overlay {
                    if ring {
                        Circle().stroke(color.opacity(0.2), lineWidth: 3).frame(width: size + 3, height: size + 3)
                    }
                }
        }
    }
}

struct ProjectMark: View {
    let initials: String
    let hue: Color
    var size: CGFloat = 20
    var symbol: String? = nil
    var image: NSImage? = nil

    /// The project's own mark: its image, its symbol, or its initials.
    init(project p: Project, size: CGFloat = 20) {
        self.init(initials: p.initials, hue: p.hue.color, size: size, symbol: p.iconSymbol, image: ProjectIcons.image(for: p))
    }

    init(initials: String, hue: Color, size: CGFloat = 20, symbol: String? = nil, image: NSImage? = nil) {
        self.initials = initials
        self.hue = hue
        self.size = size
        self.symbol = symbol
        self.image = image
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(hue)
            } else {
                Text(initials).font(.system(size: max(7.5, size * 0.4), weight: .heavy)).foregroundStyle(hue)
            }
        }
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).fill(hue.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).strokeBorder(hue.opacity(0.38)))
            .accessibilityHidden(true)
    }
}

/// Project icon images, loaded once per path.
@MainActor
enum ProjectIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(for p: Project) -> NSImage? {
        guard let raw = p.iconPath, !raw.isEmpty else { return nil }
        let path = raw.hasPrefix("/") || raw.hasPrefix("~") ? (raw as NSString).expandingTildeInPath : p.url.appendingPathComponent(raw).path
        if let img = cache[path] { return img }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = img
        return img
    }

    static func forget(_ p: Project) { cache.removeAll() }
}

/// Small square badge with letters, e.g. "SSH", "PG", "DK".
struct KindBadge: View {
    let text: String
    var color: Color = Theme.text2
    var tint: Color = Color.white(0.06)
    var size: CGFloat = 22
    var body: some View {
        Text(text)
            .font(.system(size: size > 23 ? 9 : 8.5, weight: .heavy))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(tint))
            .accessibilityHidden(true)
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Typo.ui(10.5, .medium))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white(0.1)))
    }
}

struct CountPill: View {
    let text: String
    var color: Color = Theme.text2
    var tint: Color = Color.white(0.06)
    var body: some View {
        Text(text)
            .font(Typo.ui(10, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint))
    }
}

struct Chip: View {
    let title: String
    var dot: Color? = nil
    var isOn: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(title).font(Typo.ui(11.5, .medium))
            }
            .foregroundStyle(isOn ? Theme.text : Theme.text2)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(isOn ? Color.white(0.10) : .clear))
            .overlay(Capsule().strokeBorder(isOn ? Color.white(0.14) : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Uppercase section heading used inside islands ("AGENTS & SESSIONS").
struct SectionTitle: View {
    let text: String
    var color: Color = Theme.text2
    var body: some View {
        Text(text.uppercased())
            .font(Typo.sectionTitle)
            .tracking(0.6)
            .foregroundStyle(color)
    }
}

/// Island header row: 36pt, title, trailing content, bottom divider.
struct IslandHeader<Trailing: View>: View {
    let title: String
    var count: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            SectionTitle(text: title)
            if let count { CountPill(text: count) }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.panelHeader)
        .hairlineBottom()
    }
}

extension IslandHeader where Trailing == EmptyView {
    init(title: String, count: String? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

struct FactRow: View {
    let key: String
    let value: String
    var mono = true
    var keyWidth: CGFloat = 96
    var valueColor: Color = Theme.text
    var body: some View {
        HStack(spacing: 0) {
            Text(key).font(Typo.row).foregroundStyle(Theme.text3).frame(width: keyWidth, alignment: .leading)
            Text(value)
                .font(mono ? Typo.mono(11.5) : Typo.row)
                .foregroundStyle(valueColor)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(height: 28)
    }
}

struct MeterBar: View {
    let label: String
    let value: Double // 0...1
    var color: Color
    var showLabel = true
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showLabel {
                HStack {
                    Text(label).font(Typo.meta).foregroundStyle(Theme.text3)
                    Spacer()
                    Text("\(Int((value * 100).rounded()))%").font(Typo.mono(11)).foregroundStyle(Theme.text)
                        .monospacedDigit()
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white(0.06))
                    Capsule().fill(color).frame(width: max(2, geo.size.width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(Int(value * 100)) percent")
    }
}

// MARK: - Search field

struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var shortcut: String? = nil
    var height: CGFloat = 28
    var fill: Color = Theme.input
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
            field
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.meta)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            } else if let shortcut {
                Text(shortcut).font(Typo.ui(10)).foregroundStyle(Theme.meta)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 7).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.divider))
    }

    @ViewBuilder private var field: some View {
        let tf = TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Typo.ui(12))
            .foregroundStyle(Theme.text)
            .accessibilityLabel(placeholder)
        if let focus { tf.focused(focus) } else { tf }
    }
}

// MARK: - Text input

struct BXTextField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var mono = false
    var secure = false
    var error: String? = nil
    @FocusState private var focused: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty {
                Text(label).font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
            }
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(mono ? Typo.mono(12) : Typo.ui(12.5))
            .foregroundStyle(Theme.text)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(error != nil ? Theme.red : (focused ? accent : Theme.controlStroke)))
            .shadow(color: focused ? accent.opacity(0.2) : .clear, radius: 0)
            .accessibilityLabel(label.isEmpty ? placeholder : label)
            if let error {
                Text(error).font(Typo.ui(11)).foregroundStyle(Theme.red)
            }
        }
    }
}

// MARK: - Segmented control

struct SegmentedControl<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var height: CGFloat = 24
    var fill: Color = Color.white(0.04)
    var fontSize: CGFloat = 11.5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button { selection = value } label: {
                    Text(label)
                        .font(Typo.ui(fontSize, .semibold))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(on ? Theme.text : Theme.text3)
                        .padding(.horizontal, 9)
                        .frame(height: height)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.segmentedOn : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }
}

// MARK: - Switch

struct BXSwitchStyle: ToggleStyle {
    @Environment(\.accent) private var accent
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            Spacer(minLength: 0)
            Button { configuration.isOn.toggle() } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? accent : Color.white(0.12))
                    Circle().fill(configuration.isOn ? Theme.onAccent : Theme.text2)
                        .frame(width: 14, height: 14)
                        .padding(3)
                }
                .frame(width: 34, height: 20)
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle")
            .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
    }
}

extension ToggleStyle where Self == BXSwitchStyle {
    static var bx: BXSwitchStyle { BXSwitchStyle() }
}

// MARK: - Empty state

struct EmptyState: View {
    let symbol: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.text3)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.white(0.04)))
            Text(message)
                .font(Typo.ui(12))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            if let actionTitle, let action {
                SubtleButton(title: actionTitle, height: 26, action: action)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row helpers

/// Hover/selection background used by list rows.
struct RowBackground: ViewModifier {
    var selected: Bool
    var tint: Color? = nil
    var radius: CGFloat = 7
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(selected ? (tint?.opacity(0.12) ?? Theme.selected) : (hovering ? Theme.hover : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(selected ? (tint?.opacity(0.22) ?? Theme.selectedStroke) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension View {
    func rowBackground(selected: Bool, tint: Color? = nil, radius: CGFloat = 7) -> some View {
        modifier(RowBackground(selected: selected, tint: tint, radius: radius))
    }
}

/// Inline git status letter: M A D U.
struct GitStatusLetter: View {
    let status: GitStatus?
    var body: some View {
        if let status {
            Text(status.rawValue)
                .font(Typo.mono(10, .semibold))
                .foregroundStyle(status.color)
                .accessibilityLabel(status.name)
        }
    }
}

struct AddDel: View {
    let add: Int
    let del: Int
    var size: CGFloat = 10.5
    var body: some View {
        HStack(spacing: 5) {
            if add > 0 { Text("+\(add)").foregroundStyle(Theme.green) }
            if del > 0 { Text("−\(del)").foregroundStyle(Theme.red) }
        }
        .font(Typo.mono(size))
    }
}

// MARK: - Thin scroll bar

/// Where a scroll view's content sits. Written while scrolling and read only by
/// the bar, so the list itself isn't redrawn as it scrolls.
@Observable @MainActor
final class ScrollMetrics {
    var content: CGRect = .zero
    var viewport: CGFloat = 0
    @ObservationIgnored let space = UUID()
}

private struct ContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

extension View {
    /// On a scroll view's content: reports its position to `metrics`.
    func reportsScrollPosition(_ metrics: ScrollMetrics) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: ContentFrameKey.self, value: g.frame(in: .named(metrics.space))) })
            .onPreferenceChange(ContentFrameKey.self) { r in Task { @MainActor in metrics.content = r } }
    }

    /// On the scroll view: a 3pt bar at the right edge, shown only when the content overflows.
    func thinScrollBar(_ metrics: ScrollMetrics) -> some View {
        coordinateSpace(name: metrics.space)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { metrics.viewport = $0 }
            .overlay(alignment: .topTrailing) { ThinScrollBar(metrics: metrics) }
    }
}

private struct ThinScrollBar: View {
    let metrics: ScrollMetrics
    var body: some View {
        let total = metrics.content.height, view = metrics.viewport
        if total > view + 1, view > 0 {
            let h = max(24, view * view / total)
            let progress = min(1, max(0, -metrics.content.minY / (total - view)))
            Capsule().fill(Color.white(0.16))
                .frame(width: 3, height: h)
                .offset(x: -2, y: (view - h) * progress)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Cursor

extension View {
    /// The pointing-hand cursor while over this view (things you can click that
    /// don't look like buttons). Popped on exit and when the view goes away.
    func handCursor() -> some View { modifier(HandCursor()) }
}

private struct HandCursor: ViewModifier {
    @State private var inside = false
    func body(content: Content) -> some View {
        content
            .onHover { over in
                guard over != inside else { return }
                inside = over
                if over { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if inside { inside = false; NSCursor.pop() } }
    }
}

// MARK: - Middle click

extension View {
    /// Runs `action` on a middle-button click inside this view (closes tabs).
    func onMiddleClick(_ action: @escaping () -> Void) -> some View {
        overlay(MiddleClickCatcher(action: action).allowsHitTesting(false))
    }
}

private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> MiddleClickView {
        let v = MiddleClickView()
        v.action = action
        return v
    }
    func updateNSView(_ v: MiddleClickView, context: Context) { v.action = action }
}

/// SwiftUI has no middle-click gesture, so this watches mouse-up events for
/// button 2 that land inside its visible bounds. It never takes clicks itself.
final class MiddleClickView: NSView {
    var action: (() -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] e in
            // Bounds too: inside SwiftUI, visibleRect can report the whole window, which
            // let the first view registered take every middle click (closing the wrong tab).
            guard let self, e.buttonNumber == 2, e.window === self.window, !self.isHiddenOrHasHiddenAncestor else { return e }
            let p = self.convert(e.locationInWindow, from: nil)
            guard self.bounds.contains(p), self.visibleRect.contains(p) else { return e }
            self.action?()
            return nil
        }
    }
}
