import Foundation
import UserNotifications
import AppKit

/// macOS notifications for agent sessions that finish or need input.
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotifier()
    weak var store: AppStore?
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes when the process has no bundle (unit tests).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func install() {
        center?.delegate = self
    }

    /// Asks for permission on first use only.
    @MainActor
    func notify(title: String, body: String, sessionID: String, sound: Bool, store: AppStore) {
        self.store = store
        // You're already looking at this session: nothing to tell you.
        if store.isWatching(sessionID) { PerfMonitor.shared.note("notify skipped, watching \(sessionID)"); return }
        // Kept in the notification list, so a missed one can be read later.
        store.recordNotice(title: title, body: body.components(separatedBy: "\n").first ?? body, session: sessionID)
        // The in-app notice and sound never depend on macOS notifications.
        store.toast(.info, title, detail: body.components(separatedBy: "\n").first, session: sessionID)
        if sound { Self.chime(store.settings) }
        guard let center else { return }
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["session": sessionID]
            // No macOS sound: Brix plays its own below, so there's one sound even
            // when macOS has Brix's banners or sounds turned off.
            center.add(UNNotificationRequest(identifier: "\(sessionID)-\(UUID().uuidString)", content: content, trigger: nil)) { error in
                PerfMonitor.shared.note("notify sent \(sessionID) sound=\(sound) error=\(error?.localizedDescription ?? "none")")
                if let error {
                    Task { @MainActor in store.toast(.error, "Notification failed", detail: error.localizedDescription) }
                }
            }
        }
        // Asked per app, not per library: a new build (Brix Dev, a signed
        // release) starts with no permission even when the library was asked.
        center.getNotificationSettings { settings in
            PerfMonitor.shared.note("notify settings \(Self.describe(settings))")
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in if granted { send() } }
            case .denied:
                Task { @MainActor in
                    guard !store.library.notificationsAsked else { return }
                    store.library.notificationsAsked = true
                    store.toast(.info, "Notifications are off for Brix", detail: "Turn them on in System Settings > Notifications > Brix to hear when agents finish.")
                }
            default:
                send()
            }
        }
    }

    /// Brix's own sound for a finished or waiting agent. A system sound, played by
    /// Brix itself, so it doesn't depend on macOS notification settings.
    @MainActor
    static func chime(_ settings: AppSettings) {
        // A copy: playing a shared named sound again while it plays does nothing.
        guard let sound = NSSound(named: settings.notifySoundName)?.copy() as? NSSound ?? NSSound(named: "Glass") else { return NSSound.beep() }
        sound.volume = Float(min(max(settings.notifyVolume, 0), 1))
        if !sound.play() { NSSound.beep() }
    }

    /// The sounds macOS ships, for the picker in Settings.
    static let sounds: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        let list = names.map { ($0 as NSString).deletingPathExtension }.sorted()
        return list.isEmpty ? ["Glass"] : list
    }()

    /// "allowed, banners on, sound off": what macOS lets Brix do right now.
    static func describe(_ s: UNNotificationSettings) -> String {
        let auth = switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral: "allowed"
        case .denied: "off"
        default: "not asked yet"
        }
        return "\(auth), banners \(s.alertSetting == .enabled ? "on" : "off"), sound \(s.soundSetting == .enabled ? "on" : "off")"
    }

    /// Settings > Notifications: sends one notification now and says what macOS allows.
    @MainActor
    func test(store: AppStore) {
        guard let center else { return }
        let send = {
            let content = UNMutableNotificationContent()
            content.title = "Brix test notification"
            content.body = "Brix notifications and sounds are working."
            center.add(UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil)) { error in
                if let error { Task { @MainActor in store.toast(.error, "Notification failed", detail: error.localizedDescription) } }
            }
        }
        center.getNotificationSettings { settings in
            let state = Self.describe(settings)
            PerfMonitor.shared.note("notify test, settings \(state)")
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in if granted { send() } }
                return
            }
            send()
            Task { @MainActor in
                if store.settings.notifySound { Self.chime(store.settings) }
                let fix = settings.authorizationStatus == .denied || settings.soundSetting != .enabled
                store.toast(fix ? .error : .info, "macOS: notifications \(state)",
                            detail: fix ? "Turn them on in System Settings > Notifications > \(Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Brix"). A Focus mode also silences them."
                                        : "No sound? Check Focus (Do Not Disturb) in Control Center.")
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["session"] as? String
        Task { @MainActor in
            AppDelegate.bringToFront()
            if let id { self.store?.reveal(session: id) }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
