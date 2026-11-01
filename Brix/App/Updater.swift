import AppKit
import Observation
import Sparkle

/// In-app updates through Sparkle. Scheduled checks run in the background and never
/// pop a window: a found update shows as a pill in the toolbar and a notice in the
/// bell, and Sparkle's own window (release notes, Install and Relaunch) opens only
/// when the user clicks one of those or chooses Check for Updates.
@MainActor @Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()
    /// The notice's session id; the bell opens the update instead of a session.
    static let noticeID = "brix-update"

    /// The version a background check found and the user hasn't looked at yet.
    private(set) var available: String?
    /// Observed, so the Check for Updates menu item enables once Sparkle starts.
    private var controller: SPUStandardUpdaterController?
    @ObservationIgnored weak var store: AppStore?

    /// Off in Brix Dev and test runs: they aren't the released app.
    var enabled: Bool { controller != nil }

    func start(store: AppStore) {
        self.store = store
        guard controller == nil, Bundle.main.bundleIdentifier == "com.spmsupun.brix", DebugSnapshot.directory == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    /// Opens Sparkle's window: checks now, or shows the update already found.
    func check() { controller?.checkForUpdates(nil) }

    var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    // MARK: Gentle reminders

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A background check found an update: Brix shows it, Sparkle doesn't.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            guard !handleShowingUpdate else { return }
            available = version
            // One notice per version, however many checks find it, even after the bell is cleared.
            let key = "brix.updateNotified"
            guard let store, UserDefaults.standard.string(forKey: key) != version else { return }
            UserDefaults.standard.set(version, forKey: key)
            store.recordNotice(title: "Brix \(version) is available", body: "Click to see what's new and install it.", session: Self.noticeID)
        }
    }

    /// A later check found nothing (the release was pulled, or Brix was updated another way).
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { available = nil }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { available = nil }
    }
}
