import Carbon.HIToolbox
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, format, downloads, advanced, support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .format: String(localized: "Format")
        case .downloads: String(localized: "Downloads")
        case .advanced: String(localized: "Advanced")
        case .support: String(localized: "Support")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .format: "slider.horizontal.3"
        case .downloads: "arrow.down.circle"
        case .advanced: "terminal"
        case .support: "heart"
        }
    }
}

/// Settings lives in a regular window with the main window's unified toolbar (no title), so the
/// window buttons sit in the same place; the tabs (icon above, name below) are its centre item.
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab: SettingsTab = .general

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings()
            case .format: FormatSettingsView()
            case .downloads: DownloadSettings()
            case .advanced: AdvancedSettings()
            case .support: SupportSettings()
            }
        }
        .frame(width: 480, height: 400)
        .scenePadding()
        .navigationTitle("Settings")
        .toolbar {
            // One toolbar item per tab, so each is its own control for VoiceOver.
            ToolbarItemGroup(placement: .principal) {
                ForEach(SettingsTab.allCases) { item in
                    SettingsTabButton(tab: item, selection: $tab)
                }
            }
        }
    }
}

/// Opens the Settings window and brings Pluck forward (it may be running as a menu bar app).
struct OpenSettingsAction {
    let openWindow: OpenWindowAction

    func callAsFunction() {
        openWindow(id: "settings")
        NSApp.activate()
    }
}

extension EnvironmentValues {
    var openPluckSettings: OpenSettingsAction { OpenSettingsAction(openWindow: openWindow) }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    /// Read here rather than passed in as a Bool: toolbar items don't always redraw when the
    /// toolbar's own inputs change, which left the highlight stuck on an old tab.
    @Binding var selection: SettingsTab
    @State private var hovering = false

    private var isSelected: Bool { selection == tab }
    private func action() { selection = tab }

    var body: some View {
        Button(action: action) {
            // Kept compact so the glass capsule around the tabs has room to breathe
            // without making the toolbar taller (which would move the window buttons).
            VStack(spacing: 1) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: .regular))
                    .frame(height: 16)
                Text(tab.title)
                    .font(.system(size: 10))
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(minWidth: 54)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)
            .background {
                Capsule(style: .continuous)
                    .fill(.primary.opacity(isSelected ? 0.10 : hovering ? 0.05 : 0))
            }
            .padding(.horizontal, 2)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(tab.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.downloadPath) private var downloadPath = ""
    @AppStorage(Prefs.maxConcurrent) private var maxConcurrent = 3
    @AppStorage(Prefs.notify) private var notify = true
    @State private var notificationsAllowed = true
    @AppStorage(Prefs.askLocation) private var askLocation = false
    @AppStorage(Prefs.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Prefs.startInMenuBar) private var startInMenuBar = false
    @AppStorage(Prefs.globalShortcut) private var globalShortcut = true
    @State private var shortcutTaken = false
    @State private var shortcut = KeyCombo.stored
    @State private var shortcutMessage: String?
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginNeedsApproval = LoginItem.needsApproval
    @State private var loginError: String?
    @AppStorage(Prefs.appAutoUpdate) private var appAutoUpdate = true
    @Environment(AppUpdater.self) private var appUpdater

    var body: some View {
        Form {
            LabeledContent("Save to") {
                HStack {
                    Label {
                        Text((downloadPath as NSString).abbreviatingWithTildeInPath)
                            .truncationMode(.middle)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: downloadPath))
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    .lineLimit(1)
                    Button("Choose…", action: chooseFolder)
                }
            }
            Toggle("Always ask where to save", isOn: $askLocation)
            Picker("Simultaneous downloads", selection: $maxConcurrent) {
                ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle("Notify when downloads finish in the background", isOn: $notify)
                .onChange(of: notify) { _, on in
                    if on { Notifications.requestPermissionIfNeeded() }
                    Task { notificationsAllowed = await Notifications.areAllowed() }
                }
            if notify, !notificationsAllowed {
                HStack {
                    Label("Notifications are turned off for Pluck in System Settings.", systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Turn On…") { Notifications.openSystemSettings() }
                }
            }
            Toggle(isOn: $globalShortcut) {
                Text("Download copied link from any app")
                Text("Works without switching to Pluck.")
            }
            .toggleStyle(.switch)
            .onChange(of: globalShortcut) { _, enabled in applyShortcut(enabled) }
            .onAppear {
                shortcut = AppDelegate.shared?.shortcut.combo ?? .stored
                shortcutTaken = AppDelegate.shared?.shortcut.isTaken ?? false
            }
            if globalShortcut {
                LabeledContent {
                    HStack(spacing: 6) {
                        ShortcutRecorder(combo: shortcut, onRecord: changeShortcut)
                        if shortcut != .default {
                            Button { changeShortcut(.default) } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Reset to \(KeyCombo.default.display)")
                            .accessibilityLabel("Reset to \(KeyCombo.default.display)")
                        }
                    }
                } label: {
                    Text("Shortcut")
                    if let message = shortcutMessage ?? (shortcutTaken ? String(localized: "Another app already uses this shortcut.") : nil) {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("Click the shortcut, then press the keys you want.")
                    }
                }
            }

            Section {
                Toggle("Show Pluck in the menu bar", isOn: $showMenuBarIcon)
                Toggle("Open Pluck at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in setLoginItem(enabled) }
                Toggle("Start in the menu bar only (no window)", isOn: $startInMenuBar)
                    .disabled(!showMenuBarIcon)
            } header: {
                Text("Menu Bar")
            } footer: {
                Group {
                    if loginNeedsApproval {
                        HStack {
                            Text("macOS needs your OK in Login Items before Pluck can open at login.")
                            Button("Open Login Items…") { LoginItem.openSystemSettings() }
                                .buttonStyle(.link)
                        }
                    } else if let loginError {
                        Text(loginError)
                    } else {
                        Text("Closing the window keeps Pluck running in the menu bar. Choose Quit Pluck to stop it.")
                    }
                }
                .foregroundStyle(.secondary)
            }
            .onAppear {
                openAtLogin = LoginItem.isEnabled
                loginNeedsApproval = LoginItem.needsApproval
            }

            Section("Pluck Updates") {
                Toggle("Check for Pluck updates automatically", isOn: $appAutoUpdate)
                    .onChange(of: appAutoUpdate) { appUpdater.startAutomaticChecks() }
                LabeledContent("Version \(appUpdater.currentVersion)") {
                    HStack(spacing: 8) {
                        switch appUpdater.status {
                        case .checking, .installing: ProgressView().controlSize(.small)
                        case .upToDate: Text("Up to date").foregroundStyle(.secondary)
                        case .available: Text("\(appUpdater.release?.version ?? "") available").foregroundStyle(.tint)
                        case .failed(let message):
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
                                .accessibilityLabel("Update check failed: \(message)")
                        case .idle: EmptyView()
                        }
                        if appUpdater.status == .available {
                            Button("Install & Relaunch") { Task { await appUpdater.installAndRelaunch() } }
                        } else {
                            Button("Check Now") {
                                appUpdater.dismissedVersion = nil
                                Task { await appUpdater.check() }
                            }
                            .disabled(appUpdater.status == .checking)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Back from System Settings? Show whether notifications are allowed now.
        .task { notificationsAllowed = await Notifications.areAllowed() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notificationsAllowed = await Notifications.areAllowed() }
        }
    }

    private func applyShortcut(_ enabled: Bool) {
        AppDelegate.shared?.shortcut.update(enabled: enabled)
        shortcutTaken = AppDelegate.shared?.shortcut.isTaken ?? false
        shortcutMessage = nil
    }

    private func changeShortcut(_ combo: KeyCombo) {
        guard let manager = AppDelegate.shared?.shortcut else { return }
        shortcutMessage = manager.change(to: combo)
        shortcut = manager.combo
        shortcutTaken = manager.isTaken
    }

    private func setLoginItem(_ enabled: Bool) {
        guard enabled != LoginItem.isEnabled else { return }
        do {
            try LoginItem.set(enabled)
            loginError = nil
        } catch {
            loginError = String(localized: "Couldn’t change the login item: \(error.localizedDescription)")
        }
        openAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
        loginNeedsApproval = LoginItem.needsApproval
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: downloadPath)
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            downloadPath = url.path
        }
    }
}

private struct FormatSettingsView: View {
    private var format = FormatSettings()

    var body: some View {
        Form {
            Picker("Download", selection: format.$kind) {
                Text("Video").tag(MediaKind.video)
                Text("Audio only").tag(MediaKind.audio)
            }
            .pickerStyle(.segmented)

            Section("Video") {
                Picker("Max resolution", selection: format.$resolution) {
                    ForEach(Resolution.allCases) { Text($0.label).tag($0) }
                }
                Picker("Codec", selection: format.$codec) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                }
                .disabled(format.container == .webm)
                Picker("Container", selection: format.$container) {
                    ForEach(VideoContainer.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Prefer 60 fps when available", isOn: format.$prefer60fps)
            }
            .disabled(format.kind != .video)

            Section {
                Picker(String(localized: "Format"), selection: format.$audioFormat) {
                    ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                }
                Picker("Quality", selection: format.$audioBitrate) {
                    ForEach(AudioBitrate.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!format.audioFormat.supportsBitrate)
            } header: {
                Text("Audio")
            } footer: {
                Text("Also used for Spotify links. Pluck picks the best audio on offer and only converts when needed. FLAC and WAV can’t add quality the source doesn’t have; each download shows what it got.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DownloadSettings: View {
    @AppStorage(Prefs.embedMetadata) private var embedMetadata = true
    @AppStorage(Prefs.embedThumbnail) private var embedThumbnail = true
    @AppStorage(Prefs.embedSubtitles) private var embedSubtitles = false
    @AppStorage(Prefs.lyrics) private var lyrics = true
    @AppStorage(Prefs.removeSponsors) private var removeSponsors = false
    @AppStorage(Prefs.fileNaming) private var fileNaming: FileNaming = .automatic
    @AppStorage(Prefs.customFileName) private var customFileName = "{artist} - {title}"
    @AppStorage(Prefs.playlistFolders) private var playlistFolders = true
    @AppStorage(Prefs.musicImport) private var musicImport = false
    @AppStorage(Prefs.musicImportTypes) private var musicImportTypes = MusicLibrary.defaultTypes
    @AppStorage(Prefs.musicImportAll) private var musicImportAll = true
    @State private var musicFolderFound = true

    /// One checkbox per file type, stored as "m4a,mp3".
    private func importsType(_ ext: String) -> Binding<Bool> {
        Binding(get: { musicImportTypes.split(separator: ",").contains(Substring(ext)) },
                set: { on in
                    var types = Set(musicImportTypes.split(separator: ",").map(String.init))
                    if on { types.insert(ext) } else { types.remove(ext) }
                    musicImportTypes = MusicLibrary.types.map(\.ext).filter(types.contains).joined(separator: ",")
                })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Add finished downloads to Apple Music", isOn: $musicImport)
                if musicImport {
                    Picker("Add", selection: $musicImportAll) {
                        Text("All songs").tag(true)
                        Text("Only these file types").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                }
                if musicImport, !musicImportAll {
                    LabeledContent("File types") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(MusicLibrary.types, id: \.ext) { type in
                                Toggle(type.label, isOn: importsType(type.ext))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                if musicImport {
                    if !musicFolderFound {
                        Label("Open the Music app once, so it creates the folder Pluck adds songs to.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Apple Music")
            } footer: {
                Text(musicImportAll
                     ? "Every song Pluck downloads is added. Apple Music can’t import FLAC, Opus or WebM, so those get a copy made for it: FLAC as Apple Lossless, the others as AAC. The originals stay where they are."
                     : "Pluck copies finished files of the chosen types, videos included, into Music’s “Automatically Add to Music” folder; the originals stay where they are. Apple Music can’t import FLAC, Opus or WebM files.")
                    .foregroundStyle(.secondary)
            }
            .task(id: musicImport) { musicFolderFound = MusicLibrary.folder != nil }

            Section {
                Toggle("Title, artist & description", isOn: $embedMetadata)
                Toggle("Thumbnail as cover art", isOn: $embedThumbnail)
                Toggle("Subtitles (video only)", isOn: $embedSubtitles)
                Toggle("Lyrics for songs", isOn: $lyrics)
            } header: {
                Text("Embed")
            } footer: {
                Text("Lyrics come from LRCLIB, a free lyrics database: Pluck sends it the artist and title. They’re added to MP3, M4A and FLAC files when the artist is known (Spotify, Apple Music, YouTube Music).")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Remove sponsor segments (SponsorBlock)", isOn: $removeSponsors)
            }
            Section {
                Picker("File names", selection: $fileNaming) {
                    ForEach(FileNaming.allCases) { Text($0.label).tag($0) }
                }
                if fileNaming == .custom {
                    TextField("Custom name", text: $customFileName, prompt: Text(verbatim: "{artist} - {title}"))
                    LabeledContent("Preview") {
                        if let preview = FileNaming.preview(customFileName) {
                            Text(preview).foregroundStyle(.secondary)
                        } else {
                            Text("Use at least one placeholder").foregroundStyle(.red)
                        }
                    }
                }
                Toggle("Put albums and playlists in their own folder", isOn: $playlistFolders)
            } header: {
                Text("Files")
            } footer: {
                Group {
                    if fileNaming == .custom {
                        Text("Placeholders: \(FileNaming.tokens.map(\.token).joined(separator: " "))")
                    } else if fileNaming == .automatic {
                        Text("Music is named “Artist - Title” when the artist is known, everything else by its title.")
                    } else {
                        Text("Albums go into Artist/Album, playlists into a folder with their name, when you download two or more items.")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(Updater.self) private var updater
    @Environment(HelperToolsUpdater.self) private var toolsUpdater
    @AppStorage(Prefs.cookiesBrowser) private var cookiesBrowser = "none"
    @AppStorage(Prefs.ytdlpPath) private var ytdlpPath = ""
    @AppStorage(Prefs.autoUpdate) private var autoUpdate = true
    @AppStorage(Prefs.nightly) private var nightly = false

    private var installed: [CookieBrowser] { CookieBrowser.allCases.filter(\.isInstalled) }
    private var notInstalled: [CookieBrowser] { CookieBrowser.allCases.filter { !$0.isInstalled } }

    var body: some View {
        Form {
            Section {
                Picker("Use cookies from", selection: $cookiesBrowser) {
                    Text("None").tag("none")
                    Section("Installed") {
                        ForEach(installed) { browser in
                            Label {
                                Text(browser.name)
                            } icon: {
                                if let url = browser.appURL {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                }
                            }
                            .tag(browser.rawValue)
                        }
                    }
                    if !notInstalled.isEmpty {
                        Section("Not Installed") {
                            ForEach(notInstalled) { Text($0.name).tag($0.rawValue) }
                        }
                    }
                }
            } footer: {
                Text(cookiesFooter).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep yt-dlp and ffmpeg up to date automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) {
                        updater.startAutomaticChecks()
                        toolsUpdater.startAutomaticChecks()
                        manager.refreshVersion()
                    }
                Toggle("Use yt-dlp nightly builds", isOn: $nightly)
                    .disabled(!autoUpdate)
                    .onChange(of: nightly) { Task { await updater.check(force: true) } }
                LabeledContent("yt-dlp") {
                    HStack(spacing: 8) {
                        statusIcon(updater.status)
                        if let version = manager.ytdlpVersion {
                            Text(version).monospacedDigit()
                        } else {
                            Text("Not found").foregroundStyle(.red)
                        }
                    }
                }
                LabeledContent("ffmpeg") {
                    HStack(spacing: 8) {
                        statusIcon(toolsUpdater.status)
                        if autoUpdate, HelperToolsUpdater.ffmpegInstalled, let version = toolsUpdater.ffmpegVersion {
                            Text(version).monospacedDigit()
                        } else if !manager.ffmpegMissing {
                            Text("Installed on this Mac").foregroundStyle(.secondary)
                        } else {
                            Text("Not found").foregroundStyle(.red)
                        }
                    }
                }
                if autoUpdate {
                    LabeledContent("Deno") {
                        if HelperToolsUpdater.isInstalled("deno"), let version = toolsUpdater.denoVersion {
                            Text(version).monospacedDigit()
                        } else {
                            Text("Not installed yet").foregroundStyle(.secondary)
                        }
                    }
                    .help("JavaScript runtime yt-dlp needs for YouTube")
                    LabeledContent("Last checked") {
                        HStack {
                            Text(updater.lastChecked.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "Never"))
                                .foregroundStyle(.secondary)
                            Button("Check Now") {
                                Task { await updater.check() }
                                Task { await toolsUpdater.check() }
                            }
                            .disabled(updater.isBusy || toolsUpdater.isBusy)
                        }
                    }
                }
            } header: {
                Text("Tools")
            } footer: {
                Text(autoUpdate
                     ? "Pluck keeps its own copies of the official yt-dlp release and a signed static ffmpeg build, plus the Deno runtime YouTube needs, checks for updates daily, and verifies every download against its published checksum."
                     : "Using the yt-dlp and ffmpeg installed on this Mac. Keep them current with “brew upgrade yt-dlp ffmpeg”.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Custom yt-dlp path", text: $ytdlpPath, prompt: Text("None"))
                    .onSubmit { manager.refreshVersion() }
            } footer: {
                Text("Overrides both of the above when set.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { manager.refreshVersion() }
    }

    private var cookiesFooter: String {
        if cookiesBrowser != "none", CookieBrowser(rawValue: cookiesBrowser)?.isInstalled == false {
            return String(localized: "That browser isn’t installed on this Mac, so cookies are skipped until you pick another.")
        }
        return String(localized: "Lets yt-dlp access age-restricted or members-only videos you can already watch in that browser. With YouTube Premium, it also gets the higher-quality audio (about 256 kbps instead of 128–136).")
    }

    @ViewBuilder
    private func statusIcon(_ status: Updater.Status) -> some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating…").foregroundStyle(.secondary)
            }
        case .updated:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Just updated")
                .accessibilityLabel("Just updated")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
                .accessibilityLabel("Update failed: \(message)")
        case .idle, .upToDate:
            EmptyView()
        }
    }
}

/// Click, then press a key combination. Esc cancels. The current global shortcut is paused while
/// recording, so pressing it doesn't start a download.
private struct ShortcutRecorder: View {
    let combo: KeyCombo
    let onRecord: (KeyCombo) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? String(localized: "Type shortcut…") : combo.display)
                .foregroundStyle(recording ? Color.accentColor : Color.primary)
                .frame(minWidth: 96)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(recording ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.fill.tertiary))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(recording ? Color.accentColor : Color.clear, lineWidth: 1)
                }
                .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Click, then press the new shortcut. Esc cancels.")
        .accessibilityLabel("Shortcut")
        .accessibilityValue(recording ? String(localized: "Recording") : combo.display)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        AppDelegate.shared?.shortcut.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
                stop()
                return nil
            }
            let combo = KeyCombo(event: event)
            stop()
            onRecord(combo)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        AppDelegate.shared?.shortcut.setSuspended(false)
    }
}
