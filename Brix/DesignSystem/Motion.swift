import SwiftUI
import AppKit

/// CSS-style keyframe animation sampled from a clock, so SwiftUI can play the
/// design's exact keyframes (stops, values and timing curve per segment).
struct Keyframes {
    enum Curve {
        case linear, ease, easeIn, easeOut, easeInOut
        var points: (Double, Double, Double, Double) {
            switch self {
            case .linear: (0, 0, 1, 1)
            case .ease: (0.25, 0.1, 0.25, 1)
            case .easeIn: (0.42, 0, 1, 1)
            case .easeOut: (0, 0, 0.58, 1)
            case .easeInOut: (0.42, 0, 0.58, 1)
            }
        }
    }

    /// (stop 0…1, values) pairs, in order, starting at 0 and ending at 1.
    let stops: [(Double, [Double])]
    let duration: Double
    var delay: Double = 0
    var curve: Curve = .ease
    /// Values shown before the first run starts (CSS fill-mode none: the element's own style).
    var rest: [Double]? = nil

    func values(at t: Double) -> [Double] {
        if t < delay { return rest ?? stops[0].1 }
        let p = ((t - delay).truncatingRemainder(dividingBy: duration)) / duration
        guard let i = stops.lastIndex(where: { $0.0 <= p }), i + 1 < stops.count else { return stops.last!.1 }
        let (a, va) = stops[i], (b, vb) = stops[i + 1]
        let k = Self.bezier(curve.points, x: (p - a) / max(b - a, 0.0001))
        return zip(va, vb).map { $0 + ($1 - $0) * k }
    }

    /// y for x on a cubic Bézier timing curve (Newton steps, then bisection).
    static func bezier(_ c: (Double, Double, Double, Double), x: Double) -> Double {
        let (x1, y1, x2, y2) = c
        func bx(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t }
        func by(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<20 {
            let v = bx(t) - x
            if abs(v) < 1e-5 { break }
            if v > 0 { hi = t } else { lo = t }
            t = (lo + hi) / 2
        }
        return by(t)
    }
}

/// Animations stop while every Brix window is hidden or covered.
@MainActor
final class WindowVisibility {
    static let shared = WindowVisibility()
    private(set) var visible = true
    private var observers: [NSObjectProtocol] = []

    func start(_ onChange: @escaping @MainActor (Bool) -> Void) {
        guard observers.isEmpty else { return }
        let update = { [weak self] in
            MainActor.assumeIsolated {
                let v = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
                guard let self, v != self.visible else { return }
                self.visible = v
                onChange(v)
            }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in update() })
        }
    }
}

/// One pose of a looping layer: CSS transform parts and opacity.
struct LayerPose: Equatable {
    var tx: Double = 0
    var ty: Double = 0
    var rotate: Double = 0
    var sx: Double = 1
    var sy: Double = 1
    var opacity: Double = 1
}

/// Plays CSS-style keyframes with Core Animation: the content is drawn once and
/// its layer moves in the render server, so a running animation costs the app
/// no per-frame work. Same semantics as CSS: per-segment timing curve, infinite
/// loop, and before a delay the content rests in its own pose. With Reduce
/// Motion it shows `still`.
struct KeyframeLoop<Content: View>: NSViewRepresentable {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let keyframes: Keyframes
    var still: [Double]? = nil
    /// Point the rotation and scale happen about, in the content's unit space.
    var anchor: UnitPoint = .center
    /// Turns a keyframe's values into a pose.
    let pose: ([Double]) -> LayerPose
    @ViewBuilder let content: () -> Content

    final class Coordinator { var key = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let box = LoopBox()
        box.wantsLayer = true
        let host = NSHostingView(rootView: AnyView(content().environment(store)))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = box.bounds
        host.wantsLayer = true
        box.addSubview(host)
        return box
    }

    func updateNSView(_ box: NSView, context: Context) {
        guard let host = box.subviews.first as? NSHostingView<AnyView> else { return }
        host.rootView = AnyView(content().environment(store))
        let animate = !reduceMotion
        let key = "\(animate)|\(keyframes.stops.map(\.1))|\(keyframes.duration)|\(keyframes.delay)|\(anchor)|\(String(describing: still))"
        guard key != context.coordinator.key || host.layer?.animation(forKey: "loop") == nil else { return }
        context.coordinator.key = key
        // Wait for a real size: the anchor and the layer's centre depend on it.
        // AppKit drops a layer's animations when its view leaves the window
        // (switching screens, scrolling a lazy list), which froze spinners
        // mid-turn. The box starts the loop again when it's back.
        (box as? LoopBox)?.restart = { [weak host] in
            guard let host, host.layer?.animation(forKey: "loop") == nil, host.layer?.animation(forKey: "stilltransform") == nil else { return }
            apply(to: host, animate: animate, tries: 20)
        }
        DispatchQueue.main.async { apply(to: host, animate: animate, tries: 20) }
    }

    private func apply(to host: NSView, animate: Bool, tries: Int) {
        guard let layer = host.layer else { return }
        let size = host.bounds.size
        // Not laid out yet: the centre isn't known, so wait for a size (up to 1 s).
        if size == .zero, tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { apply(to: host, animate: animate, tries: tries - 1) }
            return
        }
        layer.removeAllAnimations()
        let k = keyframes
        // A layer-backed view's layer turns about its corner (anchorPoint 0,0),
        // not its centre, so the offset is from there; y follows the superlayer.
        let ap = layer.anchorPoint
        let down = layer.superlayer?.isGeometryFlipped ?? true
        let ax = (anchor.x - ap.x) * size.width
        let ay = ((down ? anchor.y : 1 - anchor.y) - ap.y) * size.height
        func transform(_ v: [Double]) -> CATransform3D {
            let p = pose(v)
            var t = CATransform3DMakeTranslation(p.tx + ax, p.ty + ay, 0)
            t = CATransform3DRotate(t, p.rotate * .pi / 180, 0, 0, 1)
            t = CATransform3DScale(t, p.sx, p.sy, 1)
            return CATransform3DTranslate(t, -ax, -ay, 0)
        }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        func hold(_ v: [Double], until: CFTimeInterval?, key: String) {
            let p = pose(v)
            for (path, value) in [("transform", NSValue(caTransform3D: transform(v)) as Any), ("opacity", p.opacity as Any)] {
                let a = CABasicAnimation(keyPath: path)
                a.fromValue = value; a.toValue = value
                a.beginTime = now
                a.duration = until ?? 1e9
                a.fillMode = .forwards
                a.isRemovedOnCompletion = until != nil
                layer.add(a, forKey: key + path)
            }
        }
        guard animate else { hold(still ?? k.rest ?? k.stops[0].1, until: nil, key: "still"); return }
        if k.delay > 0 { hold(k.rest ?? k.stops[0].1, until: k.delay, key: "rest") }
        let c = k.curve.points
        let curve = CAMediaTimingFunction(controlPoints: Float(c.0), Float(c.1), Float(c.2), Float(c.3))
        // Core Animation blends matrices, and a turn of 360° is the same matrix
        // as 0°, so a spin between those stops never moved. Spins are cut into
        // 30° steps (sampled through the curve), which it blends correctly.
        let turn = zip(k.stops, k.stops.dropFirst()).map { abs(pose($1.1).rotate - pose($0.1).rotate) }.max() ?? 0
        let stops: [(Double, [Double])] = turn > 90
            ? (0...max(2, Int(turn / 30))).map { i in let t = Double(i) / Double(max(2, Int(turn / 30))); return (t, k.values(at: k.delay + t * k.duration * 0.999999)) }
            : k.stops
        let timing = turn > 90 ? CAMediaTimingFunction(name: .linear) : curve
        let times = stops.map { NSNumber(value: $0.0) }
        let group = CAAnimationGroup()
        let move = CAKeyframeAnimation(keyPath: "transform")
        move.values = stops.map { NSValue(caTransform3D: transform($0.1)) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = stops.map { pose($0.1).opacity }
        for a in [move, fade] {
            a.keyTimes = times
            a.timingFunctions = Array(repeating: timing, count: max(1, stops.count - 1))
            a.duration = k.duration
        }
        group.animations = [move, fade]
        group.duration = k.duration
        group.repeatCount = .infinity
        group.beginTime = now + k.delay
        layer.add(group, forKey: "loop")
    }
}

/// KeyframeLoop's container: restarts the loop when it's shown in a window again.
final class LoopBox: FlippedBox {
    var restart: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.restart?() } }
    }
}

/// Top-left origin, like SwiftUI.
class FlippedBox: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A status dot whose ring pulses outward (the design's `.live`), on Core Animation.
struct LiveDot: View {
    var color: Color = Theme.green
    var size: CGFloat = 6
    var ring: CGFloat = 6

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background {
                KeyframeLoop(keyframes: Keyframes(stops: [(0, [0, 0.5]), (1, [Double(ring), 0])], duration: 1.6, curve: .easeOut), still: [0, 0],
                             pose: { v in LayerPose(sx: (Double(size) + 2 * v[0]) / Double(size), sy: (Double(size) + 2 * v[0]) / Double(size), opacity: v[1]) }) {
                    Circle().fill(color)
                }
                .frame(width: size, height: size)
            }
            .accessibilityHidden(true)
    }
}

/// An agent is working: three balls that spread into a triangle and gather
/// again while the group turns. All Core Animation: no per-frame work in the
/// app, unlike SwiftUI's repeatForever, which redrew the window every frame.
struct WorkingSpinner: View {
    var color: Color = Theme.green
    var size: CGFloat = 12

    var body: some View {
        let s = max(size, 12)
        KeyframeLoop(keyframes: Keyframes(stops: [(0, [0]), (1, [360])], duration: 1.6, curve: .easeInOut), still: [0],
                     pose: { v in LayerPose(rotate: v[0]) }) {
            ZStack {
                ball(0, -1, s)
                ball(-0.87, 0.5, s)
                ball(0.87, 0.5, s)
            }
            .frame(width: s, height: s)
        }
        .frame(width: s, height: s)
        .accessibilityLabel("Working")
    }

    /// One ball: from the centre out to its corner of the triangle and back.
    private func ball(_ dx: Double, _ dy: Double, _ s: CGFloat) -> some View {
        let reach = Double(s) / 3
        return KeyframeLoop(keyframes: Keyframes(stops: [(0, [0.25]), (0.5, [1]), (1, [0.25])], duration: 0.8, curve: .easeInOut), still: [1],
                            pose: { v in LayerPose(tx: dx * reach * v[0], ty: dy * reach * v[0]) }) {
            Circle().fill(color)
        }
        .frame(width: s / 3, height: s / 3)
    }
}

/// A pipeline is running: a small spinning ring in the accent's amber, with the
/// count when more than one runs.
struct PipelineBadge: View {
    let count: Int
    var label = true

    var body: some View {
        HStack(spacing: 4) {
            KeyframeLoop(keyframes: Keyframes(stops: [(0, [0]), (1, [360])], duration: 1, curve: .linear), still: [0],
                         pose: { v in LayerPose(rotate: v[0]) }) {
                Circle().trim(from: 0, to: 0.7).stroke(Theme.amber, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            .frame(width: 10, height: 10)
            if label {
                Text(count > 1 ? "CI ×\(count)" : "CI").font(Typo.ui(10.5, .semibold)).foregroundStyle(Theme.amber)
            }
        }
        .help(count == 1 ? "A pipeline is running" : "\(count) pipelines are running")
        .accessibilityLabel(count == 1 ? "A pipeline is running" : "\(count) pipelines are running")
    }
}
