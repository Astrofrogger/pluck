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
                .studio(app)
                .environment(updater)
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
                OpenInEditorCommand()
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

        #if STUDIO
        Window("Derush Footage", id: "derush") {
            DerushView()
                .environment(app.ai)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1040, height: 720)

        Window("Live Recorder", id: "liveRecorder") {
            LiveRecorderView()
                .environment(app.ai)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 980, height: 720)

        Window("Logo Animator", id: "logoAnimator") {
            LogoAnimatorView()
                .environment(app.ai)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 760, height: 860)

        Window("Brand Pack", id: "brandPack") {
            BrandPackView()
                .environment(manager)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 820, height: 860)

        Window("Delivery Check", id: "deliveryCheck") {
            DeliveryCheckView()
                .environment(manager)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1080, height: 760)

        Window("Edit Anywhere", id: "officeRender") {
            OfficeRenderView()
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 720, height: 760)

        Window("Fit Music to Length", id: "musicFit") {
            MusicFitView()
                .environment(app.ai)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 680, height: 520)

        WindowGroup("Pluck Player", for: PlayerTarget.self) { $target in
            if let target {
                PlayerView(target: target)
                    .environment(app.ai)
            }
        }
        .defaultSize(width: 1100, height: 640)
        #endif

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
            if panel.runModal() == .OK, let url = panel.url { openWindow(value: EditorTarget(path: url.path)) }
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
