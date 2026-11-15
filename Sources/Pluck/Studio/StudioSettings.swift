import SwiftUI

// Pluck Studio's Settings window: sections down the left, grouped cards on the right, in the
// Studio panels (basic Pluck keeps its own tabbed Settings, SettingsView). Same settings, same keys.

enum StudioSettingsPane: String, CaseIterable, Identifiable {
    // Raw values shared with SettingsTab, so openPluckSettings(.advanced) lands on the same place.
    case general, format, downloads, photo, review, ai, keys, advanced, updates, support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .format: String(localized: "Format")
        case .downloads: String(localized: "Downloads")
        case .photo: String(localized: "Photos")
        case .review: String(localized: "Review")
        case .ai: String(localized: "AI")
        case .keys: String(localized: "Keys")
        case .advanced: String(localized: "Advanced")
        case .updates: String(localized: "Updates")
        case .support: String(localized: "Support")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .format: "slider.horizontal.3"
        case .downloads: "arrow.down.circle"
        case .photo: "camera"
        case .review: "paperplane"
        case .ai: "sparkles"
        case .keys: "keyboard"
        case .advanced: "terminal"
        case .updates: "arrow.triangle.2.circlepath"
        case .support: "heart"
        }
    }

    /// The settings on the pane, for the filter field (the names as they show).
    private var keywords: [String] {
        switch self {
        case .general: [String(localized: "Save to"), String(localized: "Always ask where to save"), String(localized: "Simultaneous downloads"),
                        String(localized: "Notify when downloads finish in the background"), String(localized: "Download copied link from any app"),
                        String(localized: "Shortcut"), String(localized: "Menu Bar"), String(localized: "Show Pluck in the menu bar"),
                        String(localized: "Open Pluck at login"), String(localized: "Start in the menu bar only (no window)")]
        case .format: [String(localized: "Video"), String(localized: "Audio"), String(localized: "Max resolution"), String(localized: "Codec"),
                       String(localized: "Container"), String(localized: "Prefer 60 fps when available"), String(localized: "Quality")]
        case .downloads: [String(localized: "Apple Music"), String(localized: "Add finished downloads to Apple Music"), String(localized: "Embed"),
                          String(localized: "Thumbnail as cover art"), String(localized: "Subtitles (video only)"), String(localized: "Lyrics for songs"),
                          String(localized: "Remove sponsor segments (SponsorBlock)"), String(localized: "File names"),
                          String(localized: "Put albums and playlists in their own folder"), String(localized: "Title, artist & description")]
        case .photo: [String(localized: "Write ratings and edits to XMP sidecars"), String(localized: "Use Lightroom edits"), String(localized: "Styles"),
                      String(localized: "Catalog"), String(localized: "Camera Raw"), String(localized: "Show RED clips as one item in Finder")]
        case .review: [String(localized: "Name in comments"), String(localized: "Review Copies"), String(localized: "Host published reviews for paired Macs"), "NAS"]
        case .ai: [String(localized: "Transcribe new videos automatically"), String(localized: "Look at new downloads"),
                   String(localized: "Transcripts & search"), String(localized: "Stem model"), String(localized: "Model"), String(localized: "On this Mac")]
        case .keys: ShortcutAction.allCases.map(\.title) + [String(localized: "Restore All Keys")]
        case .advanced: [String(localized: "Use cookies from"), String(localized: "Tools"), String(localized: "Keep yt-dlp and ffmpeg up to date automatically"),
                         String(localized: "Use yt-dlp nightly builds"), String(localized: "Custom yt-dlp path"), "yt-dlp", "ffmpeg", "Deno"]
        case .updates: [String(localized: "Check for Pluck updates automatically"), String(localized: "Pluck Updates"), Edition.name]
        case .support: [String(localized: "Support on Buy Me a Coffee"), String(localized: "Star Pluck on GitHub")]
        }
    }

    func matches(_ query: String) -> Bool {
        ([title] + keywords).contains { $0.localizedStandardContains(query) }
    }
}

struct StudioSettingsView: View {
    @AppStorage("settingsTab") private var stored = StudioSettingsPane.general.rawValue
    @State private var query = ""
    @FocusState private var searching: Bool

    private var pane: StudioSettingsPane { StudioSettingsPane(rawValue: stored) ?? .general }
    private var shown: [StudioSettingsPane] {
        query.isEmpty ? StudioSettingsPane.allCases : StudioSettingsPane.allCases.filter { $0.matches(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 188)
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
                    Text(pane.title).font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
                        .accessibilityAddTraits(.isHeader)
                    content
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(pane)
            .studioPanel()
            .padding(Design.Studio.panelGap)
            .padding(.leading, -Design.Studio.panelGap)
        }
        // No title bar (PluckApp): the window buttons sit over the sidebar, on the backdrop.
        .ignoresSafeArea(.container, edges: .top)
        .background { Design.Studio.backdrop.ignoresSafeArea() }
        .preferredColorScheme(.dark)
        .tint(Design.Brand.pink)
        .frame(minWidth: 720, idealWidth: 820, maxWidth: 1200, minHeight: 460, idealHeight: 580, maxHeight: 960)
        .navigationTitle("Settings")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet)
                TextField(text: $query, prompt: Text("Find a setting").foregroundStyle(Design.Studio.textQuiet)) { Text("Find a setting") }
                    .textFieldStyle(.plain)
                    .font(Design.Studio.body)
                    .focused($searching)
                    .onSubmit { if let first = shown.first { stored = first.rawValue } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Design.Studio.textQuiet) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Design.Studio.panel, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            .padding(.bottom, 8)
            // ⌘F goes to the filter, as in the main window.
            .background { Button("") { searching = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true) }

            ForEach(shown) { item in
                let on = item == pane
                Button { stored = item.rawValue } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol).font(.system(size: 12))
                            .foregroundStyle(on ? Design.Brand.pink : Design.Studio.textQuiet)
                            .frame(width: 18)
                        Text(item.title).foregroundStyle(on ? Design.Studio.text : Design.Studio.textQuiet)
                        Spacer(minLength: 0)
                    }
                    .font(Design.Studio.body)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(on ? Design.Brand.chosenFill : AnyShapeStyle(Color.clear),
                                in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
            if shown.isEmpty {
                Text("No matches").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Studio.panelGap)
        .padding(.top, 38)
        .padding(.bottom, Design.Studio.panelGap)
        // The arrow keys walk the sections (also while typing in the filter).
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            let list = shown
            guard !list.isEmpty else { return .ignored }
            let index = list.firstIndex(of: pane) ?? -1
            let next = press.key == .downArrow ? min(index + 1, list.count - 1) : max(index - 1, 0)
            stored = list[next].rawValue
            return .handled
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .general: StudioGeneralSettings()
        case .format: StudioFormatSettings()
        case .downloads: StudioDownloadSettings()
        case .photo: StudioPhotoSettings()
        case .review: DeliverSettings()
        case .ai: AISettings()
        case .keys: ShortcutSettings()
        case .advanced: StudioAdvancedSettings()
        case .updates: StudioUpdateSettings()
        case .support: StudioSupportSettings()
        }
    }
}

// MARK: - Pieces

/// A group of settings: a small title (its explanation in a tooltip on the ⓘ), the rows in a dark box.
struct SettingsCard<Content: View>: View {
    var title: Text?
    var info: String?
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey? = nil, info: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title.map { Text($0) }
        self.info = info
        self.content = content()
    }

    init(text: Text, info: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = text
        self.info = info
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 6) {
                    title.font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text).accessibilityAddTraits(.isHeader)
                    if let info { InfoMark(text: info) }
                }
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .studioBox()
        }
    }
}

/// ⓘ with the explanation as its tooltip (and what VoiceOver reads).
private struct InfoMark: View {
    let text: String

    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Design.Studio.textFaint)
            .help(text)
            .accessibilityLabel(Text(verbatim: text))
    }
}

/// One setting: its name on the left (a line under it only for a status), the control on the right.
struct SettingRow<Control: View>: View {
    let title: Text
    var help: String?
    var detail: Text?
    @ViewBuilder var control: Control
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: LocalizedStringKey, help: String? = nil, detail: Text? = nil, @ViewBuilder control: () -> Control) {
        self.init(text: Text(title), help: help, detail: detail, control: control)
    }

    init(text: Text, help: String? = nil, detail: Text? = nil, @ViewBuilder control: () -> Control) {
        self.title = text
        self.help = help
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    title.font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                    if let help { InfoMark(text: help) }
                }
                if let detail {
                    detail.font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(minHeight: 38)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A setting that's on or off: the Studio switch on the right.
struct SettingSwitch: View {
    let title: Text
    var help: String?
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, help: String? = nil, isOn: Binding<Bool>) {
        self.title = Text(title)
        self.help = help
        _isOn = isOn
    }

    init(text: Text, help: String? = nil, isOn: Binding<Bool>) {
        self.title = text
        self.help = help
        _isOn = isOn
    }

    var body: some View {
        SettingRow(text: title, help: help) {
            Toggle(isOn: $isOn) { title }.toggleStyle(StudioSwitchStyle())
        }
    }
}

/// A choice from a list: Studio's grey menu button showing what's chosen.
struct SettingMenu<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    @ViewBuilder var options: Options

    var body: some View {
        Menu {
            Picker(selection: $selection) { options } label: { EmptyView() }.pickerStyle(.inline)
        } label: { StudioMenuLabel(title: title) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// A short line in a card: a problem to fix, or what to do next.
struct SettingNote<Trailing: View>: View {
    let text: Text
    var symbol = "exclamationmark.triangle.fill"
    var colour = Design.Studio.warn
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Label { text.foregroundStyle(Design.Studio.textQuiet) } icon: { Image(systemName: symbol).foregroundStyle(colour) }
                .font(Design.Studio.hint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

extension SettingNote where Trailing == EmptyView {
    init(text: Text, symbol: String = "exclamationmark.triangle.fill", colour: Color = Design.Studio.warn) {
        self.init(text: text, symbol: symbol, colour: colour) { EmptyView() }
    }
}

extension View {
    /// A text field in a settings row: plain text on the raised grey.
    func settingField(width: CGFloat) -> some View {
        textFieldStyle(.plain)
            .font(Design.Studio.body)
            .foregroundStyle(Design.Studio.text)
            .padding(.horizontal, 8)
            .frame(width: width, height: 26)
            .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
    }

    /// The small grey button in a settings row.
    func settingButton() -> some View { buttonStyle(StudioFlatButtonStyle(height: 26)) }
}

/// A plain symbol button in a row (reset to the standard key).
struct RowIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet)
                .frame(width: 22, height: 22).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }
}

// MARK: - General

private struct StudioGeneralSettings: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
            SettingsCard {
                SettingRow("Save to") {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: downloadPath)).resizable().frame(width: 16, height: 16)
                        Text((downloadPath as NSString).abbreviatingWithTildeInPath)
                            .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .trailing)
                        Button("Choose…", action: chooseFolder).settingButton()
                    }
                }
                SettingSwitch("Always ask where to save", isOn: $askLocation)
                SettingRow("Simultaneous downloads") {
                    SettingMenu(title: "\(maxConcurrent)", selection: $maxConcurrent) {
                        ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                SettingSwitch("Notify when downloads finish in the background", isOn: $notify)
                    .onChange(of: notify) { _, on in
                        if on { Notifications.requestPermissionIfNeeded() }
                        Task { notificationsAllowed = await Notifications.areAllowed() }
                    }
                if notify, !notificationsAllowed {
                    SettingNote(text: Text("Notifications are turned off for Pluck in System Settings."), symbol: "bell.slash") {
                        Button("Turn On…") { Notifications.openSystemSettings() }.settingButton()
                    }
                }
            }

            SettingsCard {
                SettingSwitch("Download copied link from any app", help: String(localized: "Works without switching to Pluck."), isOn: $globalShortcut)
                    .onChange(of: globalShortcut) { _, enabled in applyShortcut(enabled) }
                    .onAppear {
                        shortcut = AppDelegate.shared?.shortcut.combo ?? .stored
                        shortcutTaken = AppDelegate.shared?.shortcut.isTaken ?? false
                    }
                if globalShortcut {
                    let message = shortcutMessage ?? (shortcutTaken ? String(localized: "Another app already uses this shortcut.") : nil)
                    SettingRow("Shortcut", help: String(localized: "Click the shortcut, then press the keys you want."),
                               detail: message.map { Text($0).foregroundColor(Design.Studio.bad) }) {
                        HStack(spacing: 6) {
                            if shortcut != .default {
                                RowIconButton(symbol: "arrow.counterclockwise", help: String(localized: "Reset to \(KeyCombo.default.display)")) {
                                    changeShortcut(.default)
                                }
                            }
                            ShortcutRecorder(combo: shortcut, onRecord: changeShortcut)
                        }
                    }
                }
            }

            SettingsCard("Menu Bar", info: String(localized: "Closing the window keeps Pluck running in the menu bar. Choose Quit Pluck to stop it.")) {
                SettingSwitch("Show Pluck in the menu bar", isOn: $showMenuBarIcon)
                SettingSwitch("Open Pluck at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in setLoginItem(enabled) }
                SettingSwitch("Start in the menu bar only (no window)", isOn: $startInMenuBar)
                    .disabled(!showMenuBarIcon)
                if loginNeedsApproval {
                    SettingNote(text: Text("macOS needs your OK in Login Items before Pluck can open at login.")) {
                        Button("Open Login Items…") { LoginItem.openSystemSettings() }.settingButton()
                    }
                } else if let loginError {
                    SettingNote(text: Text(loginError), colour: Design.Studio.bad)
                }
            }
            .onAppear {
                openAtLogin = LoginItem.isEnabled
                loginNeedsApproval = LoginItem.needsApproval
            }
        }
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

// MARK: - Format

private struct StudioFormatSettings: View {
    private var format = FormatSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
            SettingsCard {
                SettingRow("Download") {
                    StudioSegmented(options: [(MediaKind.video, "Video"), (MediaKind.audio, "Audio only")], selection: format.$kind)
                }
            }
            SettingsCard("Video") {
                SettingRow("Max resolution") {
                    SettingMenu(title: format.resolution.label, selection: format.$resolution) {
                        ForEach(Resolution.allCases) { Text($0.label).tag($0) }
                    }
                }
                SettingRow("Codec") {
                    SettingMenu(title: format.codec.label, selection: format.$codec) {
                        ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                    }
                }
                .disabled(format.container == .webm)
                SettingRow("Container") {
                    SettingMenu(title: format.container.label, selection: format.$container) {
                        ForEach(VideoContainer.allCases) { Text($0.label).tag($0) }
                    }
                }
                SettingSwitch("Prefer 60 fps when available", isOn: format.$prefer60fps)
            }
            .disabled(format.kind != .video)
            SettingsCard("Audio", info: String(localized: "Also used for Spotify links. Pluck picks the best audio on offer and only converts when needed. FLAC and WAV can’t add quality the source doesn’t have; each download shows what it got.")) {
                SettingRow(text: Text(String(localized: "Format"))) {
                    SettingMenu(title: format.audioFormat.label, selection: format.$audioFormat) {
                        ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                    }
                }
                SettingRow("Quality") {
                    SettingMenu(title: format.audioBitrate.label, selection: format.$audioBitrate) {
                        ForEach(AudioBitrate.allCases) { Text($0.label).tag($0) }
                    }
                }
                .disabled(!format.audioFormat.supportsBitrate)
            }
        }
    }
}

// MARK: - Downloads

private struct StudioDownloadSettings: View {
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

    /// One switch per file type, stored as "m4a,mp3".
    private func importsType(_ ext: String) -> Binding<Bool> {
        Binding(get: { musicImportTypes.split(separator: ",").contains(Substring(ext)) },
                set: { on in
                    var types = Set(musicImportTypes.split(separator: ",").map(String.init))
                    if on { types.insert(ext) } else { types.remove(ext) }
                    musicImportTypes = MusicLibrary.types.map(\.ext).filter(types.contains).joined(separator: ",")
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
            SettingsCard("Apple Music", info: musicImportAll
                         ? String(localized: "Every song Pluck downloads is added. Apple Music can’t import FLAC, Opus or WebM, so those get a copy made for it: FLAC as Apple Lossless, the others as AAC. The originals stay where they are.")
                         : String(localized: "Pluck copies finished files of the chosen types, videos included, into Music’s “Automatically Add to Music” folder; the originals stay where they are. Apple Music can’t import FLAC, Opus or WebM files.")) {
                SettingSwitch("Add finished downloads to Apple Music", isOn: $musicImport)
                if musicImport {
                    SettingRow("Add") {
                        StudioSegmented(options: [(true, "All songs"), (false, "Only these file types")], selection: $musicImportAll)
                    }
                    if !musicImportAll {
                        ForEach(MusicLibrary.types, id: \.ext) { type in
                            SettingSwitch(text: Text(verbatim: type.label), isOn: importsType(type.ext)).padding(.leading, 16)
                        }
                    }
                    if !musicFolderFound {
                        SettingNote(text: Text("Open the Music app once, so it creates the folder Pluck adds songs to."))
                    }
                }
            }
            .task(id: musicImport) { musicFolderFound = MusicLibrary.folder != nil }

            SettingsCard("Embed", info: String(localized: "Lyrics come from LRCLIB, a free lyrics database: Pluck sends it the artist and title. They’re added to MP3, M4A and FLAC files when the artist is known (Spotify, Apple Music, YouTube Music).")) {
                SettingSwitch("Title, artist & description", isOn: $embedMetadata)
                SettingSwitch("Thumbnail as cover art", isOn: $embedThumbnail)
                SettingSwitch("Subtitles (video only)", isOn: $embedSubtitles)
                SettingSwitch("Lyrics for songs", isOn: $lyrics)
            }
            SettingsCard {
                SettingSwitch("Remove sponsor segments (SponsorBlock)", isOn: $removeSponsors)
            }
            SettingsCard("Files", info: filesInfo) {
                SettingRow("File names") {
                    SettingMenu(title: fileNaming.label, selection: $fileNaming) {
                        ForEach(FileNaming.allCases) { Text($0.label).tag($0) }
                    }
                }
                if fileNaming == .custom {
                    SettingRow("Custom name", detail: Text("Placeholders: \(FileNaming.tokens.map(\.token).joined(separator: " "))")) {
                        TextField("Custom name", text: $customFileName, prompt: Text(verbatim: "{artist} - {title}")).settingField(width: 220)
                    }
                    SettingRow("Preview") {
                        if let preview = FileNaming.preview(customFileName) {
                            Text(preview).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text("Use at least one placeholder").font(Design.Studio.body).foregroundStyle(Design.Studio.bad)
                        }
                    }
                }
                SettingSwitch("Put albums and playlists in their own folder", isOn: $playlistFolders)
            }
        }
    }

    private var filesInfo: String? {
        switch fileNaming {
        case .custom: nil // (the placeholders show under the name)
        case .automatic: String(localized: "Music is named “Artist - Title” when the artist is known, everything else by its title.")
        default: String(localized: "Albums go into Artist/Album, playlists into a folder with their name, when you download two or more items.")
        }
    }
}

// MARK: - Photos

private struct StudioPhotoSettings: View {
    @AppStorage("photoWriteXMP") private var writeXMP = false
    @AppStorage("photoUseLightroomEdits") private var useLightroomEdits = false
    @AppStorage("redClipsAsItems") private var redClipsAsItems = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
            SettingsCard {
                SettingSwitch("Write ratings and edits to XMP sidecars",
                              help: String(localized: "A small .xmp file next to each photo, which Lightroom and Capture One read. Ratings and labels from those apps are always read."),
                              isOn: $writeXMP)
                    .onChange(of: writeXMP) { _, on in if on { PhotoCatalog.shared.writeAllSidecars() } }
                SettingSwitch("Use Lightroom edits",
                              help: String(localized: "A photo Pluck hasn’t edited starts from the Lightroom edit in its sidecar (close, not the same: the engines differ)"),
                              isOn: $useLightroomEdits)
            }
            PhotoStyleSettings()
            SettingsCard("Camera Raw", info: String(localized: "Each .RDC folder shows as one clip with a thumbnail: the space bar plays the whole take with its sound, and a double-click plays it in Pluck. To see the files in it, right-click and choose Show Package Contents. Finder may need a moment, or a new login, to show it.")) {
                SettingSwitch("Show RED clips as one item in Finder", isOn: $redClipsAsItems)
                    .onChange(of: redClipsAsItems) { _, on in RedClipFolders.apply(on) }
            }
        }
    }
}

// MARK: - Advanced

private struct StudioAdvancedSettings: View {
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
        VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
            SettingsCard {
                SettingRow("Use cookies from", help: String(localized: "Lets yt-dlp access age-restricted or members-only videos you can already watch in that browser. With YouTube Premium, it also gets the higher-quality audio (about 256 kbps instead of 128–136).")) {
                    SettingMenu(title: CookieBrowser(rawValue: cookiesBrowser)?.name ?? String(localized: "None"), selection: $cookiesBrowser) {
                        Text("None").tag("none")
                        Section("Installed") {
                            ForEach(installed) { browser in
                                Label {
                                    Text(browser.access == .blockedByMacOS
                                         ? String(localized: "\(browser.name) (blocked by macOS)") : browser.name)
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
                }
                if let cookiesProblem { SettingNote(text: Text(cookiesProblem)) }
            }

            SettingsCard("Tools", info: autoUpdate
                         ? String(localized: "Pluck keeps its own copies of the official yt-dlp release and a signed static ffmpeg build, plus the Deno runtime YouTube needs, checks for updates daily, and verifies every download against its published checksum.")
                         : String(localized: "Using the yt-dlp and ffmpeg installed on this Mac. Keep them current with “brew upgrade yt-dlp ffmpeg”.")) {
                SettingSwitch("Keep yt-dlp and ffmpeg up to date automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) {
                        updater.startAutomaticChecks()
                        toolsUpdater.startAutomaticChecks()
                        manager.refreshVersion()
                    }
                SettingSwitch("Use yt-dlp nightly builds", isOn: $nightly)
                    .disabled(!autoUpdate)
                    .onChange(of: nightly) { Task { await updater.check(force: true) } }
                SettingRow(text: Text(verbatim: "yt-dlp")) {
                    HStack(spacing: 8) {
                        if let progress = updater.progress {
                            Text(Updater.progressText(String(localized: "Downloading"), done: progress.done, total: progress.total))
                                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).monospacedDigit()
                        }
                        statusIcon(updater.status)
                        if let version = manager.ytdlpVersion {
                            Text(version).monospacedDigit().foregroundStyle(Design.Studio.textQuiet)
                        } else {
                            Text("Not found").foregroundStyle(Design.Studio.bad)
                        }
                        // An update that broke downloads: the one before, until a newer one comes.
                        if autoUpdate, updater.canGoBack, !updater.isBusy, let previous = updater.previousVersion {
                            Button("Use \(previous)") {
                                updater.goBack()
                                manager.refreshVersion()
                            }
                            .settingButton()
                            .help("Go back to the yt-dlp from before the last update. This release is skipped; the next one installs as usual.")
                        }
                    }
                    .font(Design.Studio.body)
                }
                SettingRow(text: Text(verbatim: "ffmpeg")) {
                    HStack(spacing: 8) {
                        if let progress = toolsUpdater.progress {
                            Text(Updater.progressText(progress.tool, done: progress.done, total: progress.total))
                                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).monospacedDigit()
                        }
                        statusIcon(toolsUpdater.status)
                        if autoUpdate, HelperToolsUpdater.ffmpegInstalled, let version = toolsUpdater.ffmpegVersion {
                            Text(version).monospacedDigit().foregroundStyle(Design.Studio.textQuiet)
                        } else if !manager.ffmpegMissing {
                            Text("Installed on this Mac").foregroundStyle(Design.Studio.textQuiet)
                        } else {
                            Text("Not found").foregroundStyle(Design.Studio.bad)
                        }
                    }
                    .font(Design.Studio.body)
                }
                if autoUpdate {
                    SettingRow(text: Text(verbatim: "Deno"), help: String(localized: "JavaScript runtime yt-dlp needs for YouTube")) {
                        Group {
                            if HelperToolsUpdater.isInstalled("deno"), let version = toolsUpdater.denoVersion {
                                Text(version).monospacedDigit()
                            } else {
                                Text("Not installed yet")
                            }
                        }
                        .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    }
                    SettingRow("Last checked") {
                        HStack(spacing: 8) {
                            Text(updater.lastChecked.map { $0.formatted(.relative(presentation: .named)) } ?? String(localized: "Never"))
                                .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                            if updater.isBusy || toolsUpdater.isBusy {
                                // A slow or stuck download can always be stopped (and carries on where it stopped next time).
                                Button("Stop") {
                                    updater.stop()
                                    toolsUpdater.stop()
                                }
                                .settingButton()
                            } else {
                                Button("Check Now") {
                                    Task { await updater.check() }
                                    Task { await toolsUpdater.check() }
                                }
                                .settingButton()
                            }
                        }
                    }
                }
            }

            SettingsCard {
                SettingRow("Custom yt-dlp path", help: String(localized: "Overrides both of the above when set.")) {
                    TextField("Custom yt-dlp path", text: $ytdlpPath, prompt: Text("None"))
                        .settingField(width: 240)
                        .onSubmit { manager.refreshVersion() }
                }
            }
        }
        .onAppear { manager.refreshVersion() }
    }

    /// Why the chosen browser's cookies can't be used, if they can't.
    private var cookiesProblem: String? {
        guard cookiesBrowser != "none", let browser = CookieBrowser(rawValue: cookiesBrowser) else { return nil }
        if !browser.isInstalled {
            return String(localized: "That browser isn’t installed on this Mac, so cookies are skipped until you pick another.")
        }
        return browser.accessProblem
    }

    @ViewBuilder
    private func statusIcon(_ status: Updater.Status) -> some View {
        switch status {
        case .checking:
            PlumSpinner()
        case .downloading:
            HStack(spacing: 6) {
                PlumSpinner()
                Text("Updating…").foregroundStyle(Design.Studio.textQuiet)
            }
        case .updated:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Design.Studio.good).help("Just updated")
                .accessibilityLabel("Just updated")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Design.Studio.warn).help(message)
                .accessibilityLabel("Update failed: \(message)")
        case .idle, .upToDate:
            EmptyView()
        }
    }
}

// MARK: - Updates

private struct StudioUpdateSettings: View {
    @AppStorage(Prefs.appAutoUpdate) private var appAutoUpdate = true
    @State private var confirmSwitch = false
    @Environment(AppUpdater.self) private var appUpdater

    var body: some View {
        SettingsCard("Pluck Updates") {
            SettingSwitch("Check for Pluck updates automatically", isOn: $appAutoUpdate)
                .onChange(of: appAutoUpdate) { appUpdater.startAutomaticChecks() }
            SettingRow(text: Text("Version \(appUpdater.currentVersion)")) {
                HStack(spacing: 8) {
                    Group {
                        switch appUpdater.status {
                        case .checking: PlumSpinner()
                        case .installing: EmptyView()
                        case .upToDate: Text("Up to date").foregroundStyle(Design.Studio.textQuiet)
                        case .available where appUpdater.readyForQuit != nil:
                            Text("\(appUpdater.readyForQuit ?? "") installs when you quit").foregroundStyle(Design.Studio.textQuiet)
                        case .available: Text("\(appUpdater.release?.version ?? "") available").foregroundStyle(Design.Brand.pink)
                        case .failed(let message):
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Design.Studio.warn).help(message)
                                .accessibilityLabel("Update check failed: \(message)")
                        case .idle: EmptyView()
                        }
                    }
                    .font(Design.Studio.body)
                    if appUpdater.status == .installing {
                        EmptyView()
                    } else if appUpdater.status == .available {
                        Button("Install & Relaunch") { Task { await appUpdater.installAndRelaunch() } }
                            .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 26))
                    } else {
                        Button("Check Now") {
                            appUpdater.dismissedVersion = nil
                            Task { await appUpdater.check() }
                        }
                        .settingButton()
                        .disabled(appUpdater.status == .checking)
                    }
                }
            }
            if appUpdater.status == .installing { UpdateBar(card: false).padding(.horizontal, 14).padding(.vertical, 6) }
            SettingRow(text: Text(Edition.name), help: String(localized: "With local AI, the editing tools and Edit Anywhere.")) {
                Button("Switch to Pluck…") { confirmSwitch = true }
                    .settingButton()
                    .disabled(appUpdater.status == .installing)
            }
            .confirmationDialog("Switch to Pluck?", isPresented: $confirmSwitch) {
                Button("Download and Relaunch") { Task { await appUpdater.switchEdition() } }
            } message: {
                Text("Pluck leaves out the AI and editing tools and Edit Anywhere. Your downloads, Library and settings stay; you can switch back any time.")
            }
        }
    }
}

// MARK: - Support

private struct StudioSupportSettings: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
            SettingsCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "heart.fill").font(.system(size: 17)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Design.Brand.deep, in: .rect(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Help Pluck keep growing").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                            .accessibilityAddTraits(.isHeader)
                        Text("Pluck is free, independent and built in my spare time. If you’d like to chip in, a coffee directly helps me keep improving it.")
                            .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            if let url = SupportLinks.buyMeACoffee { openURL(url) }
                        } label: {
                            Label("Support on Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                        }
                        .buttonStyle(StudioFlatButtonStyle(prominent: true))
                        .help(SupportLinks.buyMeACoffee?.absoluteString ?? String(localized: "Buy Me a Coffee link not set up yet"))
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
            SettingsCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "star.fill").font(.system(size: 17)).foregroundStyle(Design.Studio.warn)
                        .frame(width: 40, height: 40)
                        .background(Design.Studio.raised, in: .rect(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Money is never expected. A star on GitHub helps more people discover Pluck and makes a real difference too.")
                            .font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { openURL(SupportLinks.gitHub) } label: { Label("Star Pluck on GitHub", systemImage: "star") }
                            .buttonStyle(StudioFlatButtonStyle())
                            .help(SupportLinks.gitHub.absoluteString)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
            Text("Thank you for using Pluck. \u{2665}\u{FE0E}").font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
        }
    }
}
