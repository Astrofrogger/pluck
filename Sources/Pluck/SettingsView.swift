import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Format", systemImage: "slider.horizontal.3") { FormatSettingsView() }
            Tab("Downloads", systemImage: "arrow.down.circle") { DownloadSettings() }
            Tab("Advanced", systemImage: "terminal") { AdvancedSettings() }
        }
        .frame(width: 480)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.downloadPath) private var downloadPath = ""
    @AppStorage(Prefs.maxConcurrent) private var maxConcurrent = 3
    @AppStorage(Prefs.notify) private var notify = true
    @AppStorage(Prefs.askLocation) private var askLocation = false
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

    /// Installed browsers, plus the current choice even if it has since been uninstalled.
    private var browsers: [CookieBrowser] {
        CookieBrowser.allCases.filter { $0.isInstalled || $0.rawValue == cookiesBrowser }
    }

    var body: some View {
        Form {
            Section {
                Picker("Use cookies from", selection: $cookiesBrowser) {
                    Text("None").tag("none")
                    Divider()
                    ForEach(browsers) { browser in
                        Label {
                            Text(browser.isInstalled ? browser.name : "\(browser.name) (not installed)")
                        } icon: {
                            if let url = browser.appURL {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            }
                        }
                        .tag(browser.rawValue)
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
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
        case .idle, .upToDate:
            EmptyView()
        }
    }
}
