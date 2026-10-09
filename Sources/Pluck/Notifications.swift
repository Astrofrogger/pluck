import AppKit
import UserNotifications

/// Notifications for finished downloads. Clicking one plays the file; its button shows it in
/// Finder. (macOS hides buttons under "Options" as soon as there are two, so there's just one.)
enum Notifications {
    static let fileCategory = "pluck.file"
    static let filesCategory = "pluck.files"
    static let filesKey = "files"
    private static let reveal = "reveal"

    static func registerActions() {
        let reveal = UNNotificationAction(identifier: reveal, title: String(localized: "Show in Finder"), options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: fileCategory, actions: [reveal], intentIdentifiers: []),
            UNNotificationCategory(identifier: filesCategory, actions: [reveal], intentIdentifiers: []),
        ])
    }

    /// Asks for permission the first time something is downloaded, when the request makes sense
    /// (asking at launch is easy to miss, especially when Pluck starts in the menu bar).
    @MainActor private static var asked = false
    @MainActor static func requestPermissionIfNeeded() {
        guard !asked, Bundle.main.bundleIdentifier != nil,
              UserDefaults.standard.bool(forKey: Prefs.notify) else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// False when macOS has notifications for Pluck turned off (System Settings → Notifications).
    static func areAllowed() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus != .denied
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Clicking a notification for one file plays it; for several, it brings Pluck forward.
    @MainActor static func handle(action: String, userInfo: [AnyHashable: Any]) {
        let files = (userInfo[filesKey] as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        switch action {
        case reveal:
            if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
        case UNNotificationDefaultActionIdentifier where files.count == 1:
            NSWorkspace.shared.open(files[0])
        default:
            AppDelegate.openMainWindow?()
        }
    }
}
