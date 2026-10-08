import AppKit
import ServiceManagement

/// Owns the app's long-lived state so it keeps running with no windows open: Pluck lives on in the
/// menu bar after its window closes, hiding its Dock icon until a window opens again.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = DownloadManager()
    let updater = Updater()
    let appUpdater = AppUpdater()
    let toolsUpdater = HelperToolsUpdater()

    /// Set by a view that can open SwiftUI windows (the menu bar icon is always around).
    static var openMainWindow: (() -> Void)?
    /// Whether the main window has already been through its first appearance this launch.
    static var didHandleLaunchWindow = false

    private var showsMenuBarIcon: Bool { UserDefaults.standard.bool(forKey: Prefs.showMenuBarIcon) }

    /// Start silently in the menu bar when asked to (and there's a menu bar icon to come back to).
    static var startsHidden: Bool {
        UserDefaults.standard.bool(forKey: Prefs.startInMenuBar) && UserDefaults.standard.bool(forKey: Prefs.showMenuBarIcon)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater.onStatusChange = { [weak self] in self?.toolsChanged() }
        toolsUpdater.onStatusChange = { [weak self] in self?.toolsChanged() }
        updater.startAutomaticChecks()
        toolsUpdater.startAutomaticChecks()
        appUpdater.startAutomaticChecks()

        if Self.startsHidden { NSApp.setActivationPolicy(.accessory) }

        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateActivationPolicy(closing: nil) }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.updateActivationPolicy(closing: window) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !showsMenuBarIcon
    }

    /// Relaunching Pluck from Finder, Spotlight or the Dock while it's running brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.openMainWindow?() }
        return true
    }

    /// A Dock icon only while a real window (main or Settings) is open.
    private func updateActivationPolicy(closing: NSWindow?) {
        let hasWindow = NSApp.windows.contains { window in
            window !== closing && window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        }
        if hasWindow {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
        } else if showsMenuBarIcon, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Lets queued downloads start once first-run setup of yt-dlp, ffmpeg and Deno has finished.
    private func toolsChanged() {
        manager.toolsInstalling = updater.isBusy || toolsUpdater.isBusy
        manager.refreshVersion()
        manager.pump()
    }
}

/// "Open at login", backed by the system's Login Items list.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
