import SwiftUI

@main
struct PluckApp: App {
    @State private var manager = DownloadManager()
    @State private var updater = Updater()
    @State private var appUpdater = AppUpdater()
    @State private var toolsUpdater = HelperToolsUpdater()
    @AppStorage(Prefs.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        Window("Pluck", id: "main") {
            ContentView()
                .environment(manager)
                .environment(appUpdater)
                .environment(toolsUpdater)
                .task {
                    updater.startAutomaticChecks()
                    toolsUpdater.startAutomaticChecks()
                    appUpdater.startAutomaticChecks()
                }
                .onChange(of: updater.status) { toolsChanged() }
                .onChange(of: toolsUpdater.status) { toolsChanged() }
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
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Download Link from Clipboard") {
                    if let url = Clipboard.videoURL() { manager.add(url) }
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

        Settings {
            SettingsView()
                .environment(manager)
                .environment(updater)
                .environment(appUpdater)
                .environment(toolsUpdater)
        }
    }

    /// Lets queued downloads start once first-run setup of yt-dlp and ffmpeg has finished.
    private func toolsChanged() {
        manager.toolsInstalling = updater.isBusy || toolsUpdater.isBusy
        manager.refreshVersion()
        manager.pump()
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
