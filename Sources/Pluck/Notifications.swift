import AppKit
import UserNotifications

/// Notifications for finished downloads. Clicking one plays the file; its button shows it in
/// Finder. (macOS hides buttons under "Options" as soon as there are two, so there's just one.)
enum Notifications {
    static let fileCategory = "pluck.file"
    static let filesCategory = "pluck.files"
    static let filesKey = "files"
    private static let reveal = "reveal"
    // Review (§13.4, §13.9, §13.15).
    static let newVersionCategory = "DELIVER_NEW_VERSION", deadlineCategory = "DELIVER_DEADLINE", hostUpdateCategory = "DELIVER_HOST_UPDATE"
    static let shareAction = "deliverShare", notNowAction = "deliverNotNow"

    static func registerActions() {
        let reveal = UNNotificationAction(identifier: reveal, title: String(localized: "Show in Finder"), options: [])
        var categories: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: fileCategory, actions: [reveal], intentIdentifiers: []),
            UNNotificationCategory(identifier: filesCategory, actions: [reveal], intentIdentifiers: []),
        ]
        #if STUDIO
        let share = UNNotificationAction(identifier: shareAction, title: String(localized: "Share with client"), options: [])
        let notNow = UNNotificationAction(identifier: notNowAction, title: String(localized: "Not now"), options: [])
        categories.insert(UNNotificationCategory(identifier: newVersionCategory, actions: [share, notNow], intentIdentifiers: []))
        categories.insert(UNNotificationCategory(identifier: deadlineCategory, actions: [], intentIdentifiers: []))
        categories.insert(UNNotificationCategory(identifier: hostUpdateCategory, actions: [], intentIdentifiers: []))
        #endif
        UNUserNotificationCenter.current().setNotificationCategories(categories)
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
        #if STUDIO
        // A new version found in a watched render folder: nothing happens without OK (§13.4).
        if let found = userInfo[DeliverWatch.foundKey] as? String {
            if action == shareAction { DeliverWatch.shared.accept(found) } else { DeliverWatch.shared.later(found) }
            if action == UNNotificationDefaultActionIdentifier { AppDelegate.showMainWindow() }
            return
        }
        // A client's comment or approval: the asset on the Deliver page, at that comment.
        if let asset = (userInfo[DeliverNotify.assetKey] as? String).flatMap(UUID.init(uuidString:)) {
            StudioNavigator.shared.showReview(asset: asset, version: (userInfo[DeliverNotify.versionKey] as? String).flatMap(UUID.init(uuidString:)),
                                              comment: (userInfo[DeliverNotify.commentKey] as? String).flatMap(UUID.init(uuidString:)))
            AppDelegate.showMainWindow()
            return
        }
        #endif
        let files = (userInfo[filesKey] as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        switch action {
        case reveal:
            if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
        case UNNotificationDefaultActionIdentifier where files.count == 1:
            NSWorkspace.shared.open(files[0])
        default:
            AppDelegate.showMainWindow()
        }
    }
}
