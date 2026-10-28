import SwiftUI
import AppKit

/// Drag target that lives in the gap between islands. Shows a resize cursor
/// and a subtle accent line on hover.
struct ResizeHandle: View {
    enum Axis { case horizontal, vertical }
    /// `.line` lights the whole edge; `.grip` shows a short 2pt grip (tiled centre).
    enum Style { case line, grip }

    let axis: Axis
    var thickness: CGFloat = 8
    var style: Style = .line
    let onDrag: (CGFloat) -> Void
    var onEnd: () -> Void = {}
    /// Double-click (tiled centre: equalise the split's panes).
    var onDoubleClick: (() -> Void)? = nil

    @Environment(\.accent) private var accent
    @State private var hovering = false
    @State private var dragging = false
    @State private var last: CGFloat = 0

    private var cursor: NSCursor { axis == .horizontal ? .resizeLeftRight : .resizeUpDown }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: axis == .horizontal ? thickness : nil, height: axis == .vertical ? thickness : nil)
            .overlay {
                if style == .grip {
                    if hovering || dragging {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(dragging ? accent : Color.white(0.22))
                            .frame(width: axis == .horizontal ? 2 : 28, height: axis == .vertical ? 2 : 28)
                    }
                } else if hovering || dragging {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(accent.opacity(0.55))
                        .frame(width: axis == .horizontal ? 2 : nil, height: axis == .vertical ? 2 : nil)
                        .padding(axis == .horizontal ? .vertical : .horizontal, 10)
                }
            }
            .onTapGesture(count: 2) { onDoubleClick?() }
            .contentShape(Rectangle())
            // Three layers, because terminals and text views next to the gap set
            // their own cursors: SwiftUI's pointer style (macOS 15), an AppKit
            // cursor rect, and a re-set on every pointer move over the handle.
            // None use push/pop, so the cursor can't get stuck when a handle goes away.
            .modifier(ResizePointer(axis: axis))
            .background(CursorArea(cursor: cursor))
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !hovering { hovering = true }
                    cursor.set()
                case .ended:
                    hovering = false
                    if !dragging { NSCursor.arrow.set() }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if !dragging {
                            // Other views' cursor rects (text, terminals) would swap the
                            // cursor back as the pointer crosses them mid-drag.
                            NSApp.keyWindow?.disableCursorRects()
                            dragging = true
                        }
                        cursor.set()
                        let t = axis == .horizontal ? v.translation.width : v.translation.height
                        onDrag(t - last)
                        last = t
                    }
                    .onEnded { _ in
                        dragging = false
                        last = 0
                        NSApp.keyWindow?.enableCursorRects()
                        NSApp.keyWindow?.resetCursorRects()
                        if !hovering { NSCursor.arrow.set() }
                        onEnd()
                    }
            )
            // If the handle goes away mid-drag, onEnded never runs: restore cursors here.
            .onDisappear {
                if dragging {
                    dragging = false
                    NSApp.keyWindow?.enableCursorRects()
                    NSApp.keyWindow?.resetCursorRects()
                }
            }
            .accessibilityLabel(axis == .horizontal ? "Resize width" : "Resize height")
            .accessibilityAddTraits(.allowsDirectInteraction)
    }
}

private struct ResizePointer: ViewModifier {
    let axis: ResizeHandle.Axis
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
        } else {
            content
        }
    }
}

/// Shows `cursor` while the pointer is over this view, via a cursor rect.
struct CursorArea: NSViewRepresentable {
    let cursor: NSCursor
    func makeNSView(context: Context) -> CursorView { CursorView(cursor: cursor) }
    func updateNSView(_ v: CursorView, context: Context) {
        if v.cursor !== cursor { v.cursor = cursor; v.window?.invalidateCursorRects(for: v) }
    }

    final class CursorView: NSView {
        var cursor: NSCursor
        init(cursor: NSCursor) { self.cursor = cursor; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }
        // SwiftUI moves the view when panes resize; a stale rect would sit in the old place.
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            window?.invalidateCursorRects(for: self)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }
    }
}
