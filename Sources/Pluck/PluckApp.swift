import SwiftUI

@main
struct PluckApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate
    @AppStorage(Prefs.showMenuBarIcon) private var showMenuBarIcon = true

    private var manager: DownloadManager { app.manager }
    private var updater: Updater { app.updater }
    private var appUpdater: AppUpdater { app.appUpdater }
    private var toolsUpdater: HelperToolsUpdater { app.toolsUpdater }

    var body: some Scene {
        Window("Pluck", id: "main") {
            ContentView()
                .environment(manager)
                .environment(appUpdater)
                .environment(toolsUpdater)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 680, height: 520)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appUpdater.dismissedVersion = nil
                    Task { await appUpdater.check() }
                }
            }
            CommandGroup(replacing: .appSettings) {
                SettingsCommand()
            }
            CommandGroup(replacing: .newItem) {
                Button("Download Links from File…") { manager.chooseLinkFile() }
                Button("Convert Files…") { manager.chooseFilesToConvert() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Download Link from Clipboard") {
                    let links = Links.extract(from: NSPasteboard.general)
                    if links.isEmpty { NSSound.beep() } else { manager.add(links) }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environment(manager)
        } label: {
            MenuBarIcon()
                .environment(manager)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(manager)
                .environment(updater)
                .environment(appUpdater)
                .environment(toolsUpdater)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct SettingsCommand: View {
    @Environment(\.openPluckSettings) private var openSettings

    var body: some View {
        Button("Settings…") { openSettings() }
            .keyboardShortcut(",", modifiers: .command)
    }
}

enum Clipboard {
    /// Returns the clipboard contents if it looks like a web link.
    static func videoURL() -> String? {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return raw
    }
}
