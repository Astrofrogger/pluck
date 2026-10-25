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
            #if STUDIO
            StudioWindow()
                .environment(manager)
                .studio(app)
                .environment(updater)
                .environment(appUpdater)
                .environment(toolsUpdater)
            #else
            ContentView()
                .updatePrompt(appUpdater)
                .environment(manager)
                .studio(app)
                .environment(updater)
                .environment(appUpdater)
                .environment(toolsUpdater)
            #endif
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: Edition.isStudio ? 1280 : 680, height: Edition.isStudio ? 820 : 520)
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
                OpenInEditorCommand()
                #if STUDIO
                Button("Play Clip or Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.prompt = String(localized: "Play")
                    if panel.runModal() == .OK, let url = panel.url { RawFormats.show(url) }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                #endif
                #if STUDIO
                Divider()
                QuickExportCommand(manager: manager)
                ExportSubtitlesCommand()
                SendToResolveCommand()
                UpdateFromResolveCommand()
                #endif
            }
            #if STUDIO
            CommandMenu("Tools") {
                ToolsMenuItems()
            }
            #else
            CommandGroup(before: .windowList) {
                LibraryCommand()
            }
            #endif
            CommandGroup(after: .pasteboard) {
                #if STUDIO
                PhotoSettingsCommands()
                #endif
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

        // Basic Pluck's Editor and Library windows: Pluck Studio has everything in its main window.
        #if !STUDIO
        WindowGroup("Editor", for: EditorTarget.self) { $target in
            if let target {
                EditorView(target: target)
                    .environment(manager)
                    .studio(app)
            }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 780)

        Window("Library", id: "library") {
            LibraryView()
                .studio(app)
        }
        .defaultSize(width: 1100, height: 700)
        #endif

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(manager)
                .studio(app)
                .environment(updater)
                .environment(appUpdater)
                .environment(toolsUpdater)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

#if !STUDIO
private struct LibraryCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Library") { openWindow(id: "library") }
            .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}
#endif

/// File → Open in Editor…: a video or song in the Editor.
private struct OpenInEditorCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open in Editor…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.movie, .audio]
            panel.prompt = String(localized: "Open")
            if panel.runModal() == .OK, let url = panel.url { EditorTarget(path: url.path).open(openWindow) }
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
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
