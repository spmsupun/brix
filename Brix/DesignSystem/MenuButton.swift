import SwiftUI
import AppKit

/// A native NSMenu item description.
struct MenuSpec {
    var title: String
    var symbol: String? = nil
    var key: String? = nil
    var checked = false
    var enabled = true
    var children: [MenuSpec] = []
    var kind: Kind = .item
    /// Drawn in red (Close Pane, Delete…).
    var destructive = false
    var action: () -> Void = {}

    enum Kind { case item, separator, header }

    static let separator = MenuSpec(title: "", kind: .separator)
    static func header(_ t: String) -> MenuSpec { MenuSpec(title: t, kind: .header) }
}

final class ClosureMenuItem: NSMenuItem {
    var handler: () -> Void = {}
    @objc func fire() { handler() }
}

enum NativeMenu {
    static func build(_ specs: [MenuSpec]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for s in specs {
            switch s.kind {
            case .separator:
                menu.addItem(.separator())
            case .header:
                if #available(macOS 14.0, *) {
                    menu.addItem(.sectionHeader(title: s.title))
                } else {
                    let h = NSMenuItem(title: s.title, action: nil, keyEquivalent: "")
                    h.isEnabled = false
                    menu.addItem(h)
                }
            case .item:
                let item = ClosureMenuItem(title: s.title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
                item.target = item
                item.handler = s.action
                item.isEnabled = s.enabled
                item.state = s.checked ? .on : .off
                if let sym = s.symbol { item.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil) }
                if s.key != nil || s.destructive {
                    // The key is shown as a hint only; the real shortcut lives in the menu bar.
                    item.toolTip = s.key
                    let attr = NSMutableAttributedString(string: s.title, attributes: s.destructive ? [.foregroundColor: NSColor.systemRed] : [:])
                    if let key = s.key {
                        attr.append(NSAttributedString(string: "\t\(key)", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
                    }
                    item.attributedTitle = attr
                }
                if !s.children.isEmpty { item.submenu = build(s.children) }
                menu.addItem(item)
            }
        }
        return menu
    }

    static func popUp(_ specs: [MenuSpec], in view: NSView) {
        let menu = build(specs)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
    }
}

/// Captures the NSView behind a SwiftUI control so a native menu can anchor to it.
struct AnchorView: NSViewRepresentable {
    let onMake: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onMake(v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class AnchorBox {
    weak var view: NSView?
}

/// A custom-styled button that opens a native menu.
struct MenuButton<Label: View>: View {
    let items: () -> [MenuSpec]
    @ViewBuilder let label: () -> Label
    @State private var anchor = AnchorBox()

    var body: some View {
        Button {
            if let v = anchor.view { NativeMenu.popUp(items(), in: v) }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .background(AnchorView { anchor.view = $0 })
    }
}

/// An NSView whose background drags the window (used behind the toolbar).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
