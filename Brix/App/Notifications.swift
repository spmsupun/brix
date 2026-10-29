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
        if store.isWatching(sessionID) { return }
        guard let center else { return }
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["session": sessionID]
            if sound { content.sound = .default }
            center.add(UNNotificationRequest(identifier: "\(sessionID)-\(UUID().uuidString)", content: content, trigger: nil)) { error in
                if let error {
                    Task { @MainActor in store.toast(.error, "Notification failed", detail: error.localizedDescription) }
                }
            }
        }
        // Asked per app, not per library: a new build (Brix Dev, a signed
        // release) starts with no permission even when the library was asked.
        center.getNotificationSettings { settings in
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
        // Always show an in-app toast too, so nothing is missed when banners are off.
        store.toast(.info, title, detail: body.components(separatedBy: "\n").first, session: sessionID)
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
        completionHandler([.banner, .sound])
    }
}
