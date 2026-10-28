import SwiftUI
import AppKit

@main
struct BrixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// One store for the app's lifetime. SwiftUI can create the App value more
    /// than once, so the store lives in a static instead of being built per init.
    @MainActor private static let sharedStore = AppStore()
    @State private var store = BrixApp.sharedStore

    var body: some Scene {
        WindowGroup("Brix", id: "main") {
            RootView()
                .environment(store)
                .environment(\.services, store.services)
                .frame(minWidth: Metrics.minWindow.width, minHeight: Metrics.minWindow.height)
                .onAppear {
                    delegate.store = store
                    store.applyAppearance()
                    store.restoreSessionsAtLaunch()
                    DebugSnapshot.run(store: store)
                    // Launch timing: writes the time the first window appeared, then quits.
                    if let mark = ProcessInfo.processInfo.environment["BRIX_LAUNCH_MARK"] {
                        try? "\(Date().timeIntervalSince1970)".write(toFile: mark, atomically: true, encoding: .utf8)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1480, height: 920)
        .commands { BrixCommands(store: store) }

        Settings {
            CustomizeView(inSettingsWindow: true)
                .environment(store)
                .environment(\.services, store.services)
                .frame(width: 980, height: 720)
                .themed(store.settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A tool that exits before reading its stdin would otherwise kill Brix with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        AgentNotifier.shared.install()
        PerfMonitor.shared.start()
    }

    /// The close button hides the window; terminals and agents keep running and
    /// clicking the Dock icon brings it back. ⌘Q quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Shows the main window even when its close button hid it, and activates Brix.
    @MainActor
    static func bringToFront() {
        NSApp.unhide(nil)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        // activate() only asks; from a notification click Brix should come forward regardless.
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { store?.markWatchedSeen() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            store?.saveNow()
            TerminalRegistry.shared.stopAll()
        }
    }
}

/// Puts the traffic lights in the middle of the 52pt toolbar, matching the design.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = ChromeView()
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor(Theme.base)
            window.minSize = NSSize(width: Metrics.minWindow.width, height: Metrics.minWindow.height)
            if let close = window.standardWindowButton(.closeButton) {
                close.target = self
                close.action = #selector(hideWindow)
            }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification]
            for n in names {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutButtons() }
                })
            }
            DispatchQueue.main.async { self.layoutButtons() }
        }

        @objc func hideWindow() {
            (NSApp.delegate as? AppDelegate)?.store?.saveNow()
            window?.orderOut(nil)
        }

        func layoutButtons() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let container = close.superview?.superview else { return }
            let height = Metrics.toolbar
            var f = container.frame
            f.size.height = height
            f.origin.y = window.frame.height - height
            container.frame = f
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (i, t) in types.enumerated() {
                guard let b = window.standardWindowButton(t) else { continue }
                b.setFrameOrigin(NSPoint(x: 17 + CGFloat(i) * 20, y: (height - b.frame.height) / 2))
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
