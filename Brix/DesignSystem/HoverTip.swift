import AppKit
import SwiftUI

/// A tooltip card in the app's own style, for rows with more to say than one
/// line. Its content is built only when it shows, so a row costs nothing extra
/// on each redraw (`.help` builds its text every time).
struct HoverTipContent {
    var title: String
    var tag: EnvTag? = nil
    var lines: [String] = []
}

extension View {
    func hoverTip(_ content: @escaping () -> HoverTipContent) -> some View {
        modifier(HoverTipModifier(content: content))
    }
}

private struct HoverTipModifier: ViewModifier {
    let content: () -> HoverTipContent
    @State private var id = UUID()

    func body(content view: Content) -> some View {
        view
            .onHover { inside in
                if inside { HoverTipWindow.shared.schedule(id, content) } else { HoverTipWindow.shared.cancel(id) }
            }
            .onDisappear { HoverTipWindow.shared.cancel(id) }
    }
}

/// One floating panel shared by every row, shown beside the pointer.
@MainActor
final class HoverTipWindow {
    static let shared = HoverTipWindow()

    private var owner: UUID?
    private var pending: Task<Void, Never>?
    private var hiddenAt = Date.distantPast
    private var monitor: Any?
    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = .floating
        return p
    }()

    private init() {
        // Switching apps isn't an event the monitor sees: drop the card, and any
        // that's waiting, so it doesn't come back when you return.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HoverTipWindow.shared.dismiss() }
        }
    }

    func schedule(_ id: UUID, _ make: @escaping () -> HoverTipContent) {
        pending?.cancel()
        owner = id
        // Sliding from one row to the next while a card is up swaps it at once, as macOS does.
        let quick = panel.isVisible || Date().timeIntervalSince(hiddenAt) < 0.3
        // A click, scroll or key press puts it away, as with system tooltips, and
        // stops one still waiting to show.
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { e in
                HoverTipWindow.shared.dismiss()
                return e
            }
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(quick ? 0 : 550))
            guard !Task.isCancelled, let self, self.owner == id else { return }
            self.show(make())
        }
    }

    func cancel(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        pending?.cancel()
        hide()
    }

    private func show(_ tip: HoverTipContent) {
        let host = NSHostingView(rootView: HoverTipCard(tip: tip))
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        // Below and right of the pointer, kept on its screen.
        let mouse = NSEvent.mouseLocation
        var origin = CGPoint(x: mouse.x + 14, y: mouse.y - size.height - 16)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame {
            if origin.x + size.width > screen.maxX { origin.x = mouse.x - size.width - 8 }
            if origin.y < screen.minY { origin.y = mouse.y + 16 }
            origin.x = max(origin.x, screen.minX)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    /// Put away by input or by leaving the app: the next hover waits the full delay.
    private func dismiss() {
        owner = nil
        pending?.cancel()
        hide()
        hiddenAt = .distantPast
    }

    private func hide() {
        if panel.isVisible { hiddenAt = Date() }
        panel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct HoverTipCard: View {
    let tip: HoverTipContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(tip.title).font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                if let t = tip.tag { TagPill(tag: t, size: 8.5, filled: false) }
            }
            if !tip.lines.isEmpty {
                Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 3)
                ForEach(Array(tip.lines.enumerated()), id: \.offset) { _, l in line(l) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.sheet))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
    }

    /// "Key: value" lines show the key dimmer.
    private func line(_ l: String) -> some View {
        let parts = l.split(separator: ":", maxSplits: 1)
        let keyed = parts.count == 2 && parts[0].count <= 14 && parts[1].hasPrefix(" ")
        return (keyed ? Text(parts[0] + ":").foregroundColor(Theme.text3) + Text(parts[1]).foregroundColor(Theme.body)
                      : Text(l).foregroundColor(Theme.body))
            .font(Typo.ui(11.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}
