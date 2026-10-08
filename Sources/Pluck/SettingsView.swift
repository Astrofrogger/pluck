import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, format, downloads, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .format: "Format"
        case .downloads: "Downloads"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .format: "slider.horizontal.3"
        case .downloads: "arrow.down.circle"
        case .advanced: "terminal"
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
            }
        }
        .frame(width: 480, height: 400)
        .scenePadding()
        .navigationTitle("Settings")
        .toolbar {
            // One toolbar item per tab, so each is its own control for VoiceOver.
            ToolbarItemGroup(placement: .principal) {
                ForEach(SettingsTab.allCases) { item in
                    SettingsTabButton(tab: item, isSelected: item == tab) { tab = item }
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
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

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
    @AppStorage(Prefs.askLocation) private var askLocation = false
    @AppStorage(Prefs.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Prefs.startInMenuBar) private var startInMenuBar = false
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
    }

    private func setLoginItem(_ enabled: Bool) {
        guard enabled != LoginItem.isEnabled else { return }
        do {
            try LoginItem.set(enabled)
            loginError = nil
        } catch {
            loginError = "Couldn’t change the login item: \(error.localizedDescription)"
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
        panel.prompt = "Choose"
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
                Picker("Format", selection: format.$audioFormat) {
                    ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                }
                Picker("Quality", selection: format.$audioBitrate) {
                    ForEach(AudioBitrate.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!format.audioFormat.supportsBitrate)
            } header: {
                Text("Audio")
            } footer: {
                Text("Also used for Spotify links. FLAC and WAV store the source losslessly but can’t add quality that isn’t there.")
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
    @AppStorage(Prefs.removeSponsors) private var removeSponsors = false
    @AppStorage(Prefs.allowPlaylists) private var allowPlaylists = false

    var body: some View {
        Form {
            Section("Embed") {
                Toggle("Title, artist & description", isOn: $embedMetadata)
                Toggle("Thumbnail as cover art", isOn: $embedThumbnail)
                Toggle("Subtitles (video only)", isOn: $embedSubtitles)
            }
            Section {
                Toggle("Download entire playlist when a link points to one", isOn: $allowPlaylists)
                Toggle("Remove sponsor segments (SponsorBlock)", isOn: $removeSponsors)
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
                            Text(updater.lastChecked.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
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
            return "That browser isn’t installed on this Mac, so cookies are skipped until you pick another."
        }
        return "Lets yt-dlp access age-restricted or members-only videos you can already watch in that browser."
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
