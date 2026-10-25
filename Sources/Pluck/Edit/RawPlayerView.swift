import SwiftUI
import UniformTypeIdentifiers

/// The Library's player: what the sidebar chose (a folder's clips to skim, or a clip playing with
/// its folder to go back to), and a clip's raw settings changed as it plays.
struct RawPlayerView: View {
    enum Source: Hashable {
        /// A folder of the Library (or any folder): its clips.
        case folder(URL)
        /// These clips, under a name.
        case clips(String, [URL])
        /// A clip opened from Finder or the Dock: playing, its folder behind it.
        case file(URL)
        /// Only this clip (a Finder pane's: Esc goes back to the pane's folder).
        case clip(URL)
    }

    /// For `.clip`: back to the folder, and the clip before or after (the pane shows it).
    var close: (() -> Void)?
    var openClip: ((URL) -> Void)?
    var playlist: [URL] = []

    let source: Source
    /// The Library's search field, looking through the folder's clips.
    var search = ""
    /// Which side of the Library it's on (copies go to the other).
    var pane = 0

    @State private var player = RawPlayer()
    /// A folder of footage being browsed (clips open from it, and Esc goes back to it).
    @State private var folder: RawFolder?
    /// The clip last open from the folder, for going forward to it again.
    @State private var lastClip: URL?
    @State private var showMeta = false
    @AppStorage("rawExportCodec") private var exportCodec = RawExport.Codec.proresHQ.rawValue
    @AppStorage("rawExportScale") private var exportScale = 1
    @AppStorage("rawTimecodeMode") private var timecodeMode = RawPlayer.TimecodeMode.source.rawValue
    @AppStorage("rawLUTFolders") private var lutFoldersText = ""
    @AppStorage("rawScopesShown") private var scopesShown = false
    @AppStorage("rawScopeKind") private var scopeKind = ScopeKind.waveform.rawValue
    @State private var goingTo = false
    @State private var goTo = ""
    @State private var lutGroups: [(group: String, files: [URL])] = []
    @FocusState private var focused: Bool
    @State private var nowPlaying: PlayerNowPlaying?
    /// In the Library: the folder browsing began at (going up stops there), and whether every
    /// clip in the folders inside shows at once.
    @State private var root: URL?
    @AppStorage("browserEveryClip") private var everyClip = false

    private var keyed: some View {
        Group {
            if player.info == nil, let folder {
                browser(folder)
            } else if player.info == nil {
                if let problem = player.problem { ContentUnavailableView("Can’t Play This", systemImage: "exclamationmark.triangle", description: Text(problem)) }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        viewer
                        if player.falseColour { FalseColourLegend().padding(.vertical, 6) }
                        RawTransportBar(player: player, goingTo: $goingTo, goTo: $goTo, timecodeMode: $timecodeMode, saveFrame: saveFrame)
                    }
                    Divider()
                    sidebar.frame(width: 290)
                }
            }
        }
        .frame(minWidth: 320, minHeight: 360)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { player.togglePlay(); return .handled }
        .onKeyPress(.escape) {
            if case .clip = source { close?(); return close == nil ? .ignored : .handled }
            guard let folder else { return .ignored }
            if player.info != nil { player.eject(); return .handled }
            // A folder up, as far as where browsing began.
            guard let up = parent(of: folder.url) else { return .ignored }
            browse(up)
            return .handled
        }
        // The previous and next clip of the folder.
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            return neighbour(press.key == .downArrow ? 1 : -1) ? .handled : .ignored
        }
        .onKeyPress(.leftArrow) { player.step(-1); return .handled }
        .onKeyPress(.rightArrow) { player.step(1); return .handled }
        .onKeyPress(.home) { player.stop(); player.show(0); return .handled }
        .onKeyPress(.end) { player.stop(); player.show(player.frames - 1); return .handled }
        // In and out (⌥ clears), J K L, ⌘J to go to a time.
        // (Not filtered by `keys`: with ⌥ the typed character is another one, so the key itself is looked at.)
        .onKeyPress { press in
            let option = press.modifiers.contains(.option)
            switch Shortcut.typedKey(press) {
            case "i": option ? player.clearIn() : player.markIn()
            case "o": option ? player.clearOut() : player.markOut()
            case "j" where press.modifiers.contains(.command): goTo = player.label(player.index); goingTo = true
            case "j": player.step(-1)
            case "k": player.stop()
            case "l": player.play()
            case "m": player.muted.toggle()
            default: return .ignored
            }
            return .handled
        }
        // False colour (⌥F, or the key chosen in Settings ▸ Keys).
        .onKeyPress { press in
            guard Shortcuts.shared.shortcut(.rawFalseColour).matches(press) else { return .ignored }
            player.falseColour.toggle()
            return .handled
        }
        // Grab Still and Compare (⌥G, ⌥C, or the keys chosen in Settings ▸ Keys).
        .onKeyPress { press in
            if Shortcuts.shared.shortcut(.rawGrabStill).matches(press) { player.grabStill(); return .handled }
            if Shortcuts.shared.shortcut(.rawCompare).matches(press), player.stillB != nil { player.compare = player.compare.next; return .handled }
            return .ignored
        }
    }

    var body: some View {
        keyed
        // The window's back and forward buttons: from a clip to its folder, up a folder, and on
        // to the clip again (the side the sidebar chooses for, when the Library is split).
        .onChange(of: navigationKey, initial: true) { claimNavigation() }
        .onChange(of: everyClip) { if let url = folder?.url, root != nil { browse(url) } }
        // The folder this side shows, for copies from the other side.
        .onChange(of: folder?.url, initial: true) { _, url in LibraryPanes.shared.here[pane] = root == nil ? nil : url }
        // A copy into what's shown is done: shown again, with it.
        .onReceive(NotificationCenter.default.publisher(for: OffloadCenter.finishedNotification)) { note in
            guard let here = folder?.url.standardizedFileURL.path, player.info == nil, root != nil,
                  let targets = note.object as? [String] else { return }
            if targets.contains(where: { $0 == here || ($0 as NSString).deletingLastPathComponent == here }) { browse(folder!.url) }
        }
        // ...and forward again to the clip that was open.
        .onChange(of: player.url) { old, new in if new == nil, folder != nil, let old { lastClip = old } }
        .onChange(of: folder?.url) { lastClip = nil }

        // Now Playing and the keyboard's media keys; the clip in File ▸ Open Recent and the Dock.
        .modifier(PlayerSystemState(player: player, nowPlaying: nowPlaying))
        .onChange(of: search) { _, words in folder?.search = words }
        .onChange(of: timecodeMode, initial: true) { _, mode in player.timecodeMode = RawPlayer.TimecodeMode(rawValue: mode) ?? .source }
        .task(id: lutFoldersText) { loadLUTs() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { if let url = await providers.first?.load(URL.self) { openAny(url) } }
            return true
        }
        .onAppear { appeared() }
        .onDisappear {
            nowPlaying?.stop()
            nowPlaying = nil
            StudioNavigator.shared.toolBack = nil
            StudioNavigator.shared.toolForward = nil
            player.close()
            folder?.close()
        }
    }

    // MARK: - The picture

    private var viewer: some View {
        ZStack {
            ZStack {
                RawFrameView(player: player)
                RawProblemOverlay(player: player)
            }
            .contentShape(.rect)
            .onTapGesture(count: 2) { player.togglePlay() }
            .onTapGesture { focused = true }
            // Drag the picture out: this frame as a full-size PNG, named for the clip and its time.
            .onDrag {
                let provider = NSItemProvider()
                let name = (player.url?.deletingPathExtension().lastPathComponent ?? "Frame") + " " + player.label(player.index).replacingOccurrences(of: ":", with: "-")
                provider.suggestedName = name
                provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { done in
                    Task { @MainActor in
                        do { done(try await player.frameFile(), false, nil) } catch { done(nil, false, error) }
                    }
                    return nil
                }
                return provider
            }
            .help("Drag the picture out to save this frame (full size, PNG)")
            // Over the picture, so dragging the line isn't dragging the picture out.
            CompareSplitStrip(player: player)
        }
    }

    // MARK: - Settings

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Spacing.section) {
                if let info = player.info {
                    if let folder {
                        Button { player.eject() } label: {
                            Label(folder.url.lastPathComponent, systemImage: "square.grid.2x2")
                        }
                        .buttonStyle(GlassCapsuleButtonStyle())
                        .help("Back to the folder (Esc). ⌘↑ and ⌘↓ go to the previous and next clip.")
                    } else if case .clip(let url) = source, let close {
                        Button(action: close) {
                            Label(FileManager.default.displayName(atPath: url.deletingLastPathComponent().path), systemImage: "chevron.backward")
                        }
                        .buttonStyle(GlassCapsuleButtonStyle())
                        .help("Back to the folder (Esc). ⌘↑ and ⌘↓ go to the previous and next clip.")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.url?.lastPathComponent ?? "").font(.headline).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: "\(info.formatName) · \(info.width)×\(info.height)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // The frame rate first: what it plays at, and how it was shot.
                    VStack(alignment: .leading, spacing: 4) {
                        RawFrameRateView(info: info)
                        if player.isPlaying, player.playbackRate > 0 {
                            row(Text("Playing"), String(localized: "\(Int(player.playbackRate.rounded())) of \(Int(info.fps.rounded())) fps")).font(.caption)
                        }
                    }
                    scopesPanel
                    if info.isRaw {
                    Picker("Look", selection: $player.settings.look) {
                        ForEach(RawLook.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Video: ready to watch (Rec.709). As Shot: as the camera was set. Log: flat, for grading.")
                    }
                    CardField(label: Text("False Colour")) {
                        Toggle("False Colour", isOn: $player.falseColour)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .help("Shows the picture in colours by brightness (IRE): purple crushed, blue shadows, green 18 % grey, pink skin, yellow near clip, red clipped. The scopes still measure the real picture (⌥F).")
                    compareControls
                    lutMenu
                    settings(info)
                    Button("Back to As Shot") { player.resetSettings() }
                        .buttonStyle(.link)
                        .disabled(player.settings == RawSettings(look: player.settings.look))
                    Divider()
                    export(info)
                    Divider()
                    clipInfo(info)
                }
            }
            .padding(Design.Spacing.inset)
        }
    }

    /// Waveform, parade or vectorscope of the picture; nothing is analysed while it's hidden.
    private var scopesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scopes").font(.headline)
                Spacer()
                Button { scopesShown.toggle() } label: {
                    Image(systemName: scopesShown ? "chevron.down" : "chevron.right").frame(width: 16)
                }
                .buttonStyle(.plain)
                .help("Waveform, RGB parade and vectorscope of the picture (Rec.709). Nothing is measured while hidden.")
            }
            if scopesShown {
                Picker("Scope", selection: $scopeKind) {
                    ForEach(ScopeKind.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                LiveScopesView(feed: player.scopes, kind: ScopeKind(rawValue: scopeKind) ?? .waveform)
            }
        }
        .onChange(of: scopesShown, initial: true) { _, shown in
            player.scopes.enabled = shown
            if shown { if let image = player.currentImage { player.scopes.offer(image, playing: false) } } else { player.scopes.clear() }
        }
        .onDisappear { player.scopes.enabled = false }
    }

    @ViewBuilder private func settings(_ info: RawClipInfo) -> some View {
        if !info.isos.isEmpty {
            CardField(label: Text("ISO")) {
                Picker("ISO", selection: Binding(get: { player.settings.iso ?? info.iso ?? info.isos[0] }, set: { player.settings.iso = $0 })) {
                    ForEach(info.isos, id: \.self) { Text("\($0)").tag($0) }
                }
                .fixedSize()
            }
        }
        if let range = info.kelvinRange {
            slider(Text("White Balance"), value: Binding(get: { player.settings.kelvin ?? info.kelvin ?? 5600 }, set: { player.settings.kelvin = $0.rounded() }),
                   range: range, step: 50, text: { "\(Int($0)) K" }, log: true)
        }
        if let range = info.tintRange {
            slider(Text("Tint"), value: Binding(get: { player.settings.tint ?? info.tint ?? 0 }, set: { player.settings.tint = $0.rounded() }),
                   range: range, step: 1, text: { $0 > 0 ? "+\(Int($0))" : "\(Int($0))" })
        }
        if let range = info.exposureRange {
            slider(Text("Exposure"), value: Binding(get: { player.settings.exposure ?? info.exposure ?? 0 }, set: { player.settings.exposure = ($0 * 10).rounded() / 10 }),
                   range: range, step: 0.1, text: { String(format: "%+.1f", $0) })
        }
    }

    /// A labelled slider; white balance moves evenly in mireds, as cameras do.
    private func slider(_ label: Text, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        text: @escaping (Double) -> String, log: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                label
                Spacer()
                Text(text(value.wrappedValue)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if log {
                // In mireds (1e6/K): warm and cool take the same room.
                let low = 1e6 / range.upperBound, high = 1e6 / range.lowerBound
                Slider(value: Binding(get: { high + low - 1e6 / value.wrappedValue }, set: { value.wrappedValue = 1e6 / (high + low - $0) }), in: low...high)
                    .controlSize(.small)
            } else {
                Slider(value: value, in: range, step: step).controlSize(.small)
            }
        }
    }

    /// The clip as an ordinary movie, with these settings.
    @ViewBuilder private func export(_ info: RawClipInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export").font(.headline)
            HStack {
                Picker("Format", selection: $exportCodec) {
                    ForEach(RawExport.Codec.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden()
                Picker("Size", selection: $exportScale) {
                    Text(verbatim: "\(info.width)×\(info.height)").tag(1)
                    Text(verbatim: "\(info.width / 2 / 2 * 2)×\(info.height / 2 / 2 * 2)").tag(2)
                    Text(verbatim: "\(info.width / 4 / 2 * 2)×\(info.height / 4 / 2 * 2)").tag(4)
                }
                .labelsHidden()
                .fixedSize()
            }
            .controlSize(.small)
            if let progress = player.exportProgress {
                ExportProgress(value: progress) { player.stopExport() }
            } else {
                Button("Export Movie…", systemImage: "square.and.arrow.up") { exportMovie() }
                    .help("Writes the clip as an ordinary movie with these raw settings, for the Editor, DaVinci Resolve or Final Cut Pro")
            }
            if Resolve.isInstalled, let url = player.url {
                Button("Send to DaVinci", systemImage: "arrow.up.forward.app") { Resolve.sendClipsAndShow([url]) }
                    .help("Imports the clip itself into the project open in DaVinci Resolve, with the sound the camera recorded beside it linked to it")
            }
            if let file = player.exported {
                DoneLabel(text: Text(file.lastPathComponent), file: file).font(.caption)
            } else if let problem = player.exportProblem {
                ProblemLabel(text: problem).font(.caption)
            }
        }
    }

    private func exportMovie() {
        let codec = RawExport.Codec(rawValue: exportCodec) ?? .proresHQ
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (player.url?.deletingPathExtension().lastPathComponent ?? "Clip") + "." + codec.fileExtension
        panel.allowedContentTypes = [codec == .h264 ? .mpeg4Movie : .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.export(to: url, codec: codec, scale: exportScale)
    }

    @ViewBuilder private func clipInfo(_ info: RawClipInfo) -> some View {
        RawClipDetailsView(info: info, showAll: $showMeta)
    }

    private func row(_ label: Text, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            label.foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled).lineLimit(3)
        }
    }

    // MARK: - LUTs

    private var lutFolders: [String] {
        (RawLUT.resolveFolders + lutFoldersText.split(separator: "\n").map(String.init)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    private func loadLUTs() {
        let folders = lutFolders
        Task {
            lutGroups = await Task.detached(priority: .utility) { folders.flatMap { RawLUT.luts(in: $0) } }.value
        }
    }

    /// A LUT over the picture: from the LUT folders (DaVinci Resolve's and any added), or chosen.
    private var lutMenu: some View {
        CardField(label: Text("LUT")) {
            Menu {
                Button("None") { player.settings.lut = nil }
                ForEach(Array(lutGroups.enumerated()), id: \.offset) { _, group in
                    Menu(group.group) {
                        ForEach(group.files, id: \.self) { file in
                            Button(file.deletingPathExtension().lastPathComponent) { player.settings.lut = file.path }
                        }
                    }
                }
                Divider()
                Button("Choose LUT…") { chooseLUT() }
                Button("Add LUT Folder…") { addLUTFolder() }
            } label: {
                Text(player.settings.lut.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? String(localized: "None"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 170)
            .help("A LUT over the picture. For a camera’s log-to-video LUT, choose the Log look.")
        }
    }

    /// Hold this frame as B (also from another clip, in the folder's menu) and look at it against A.
    private var compareControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardField(label: Text("Compare")) {
                Picker("Compare", selection: $player.compare) {
                    ForEach(CompareMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(player.stillB == nil)
            }
            .help("Compares this picture (A) with a held still (B): a line to drag (B on its left), or side by side. Grab a still from this clip, or right-click another clip in the folder to compare with the one you left (⌥C).")
            HStack(spacing: 8) {
                Button("Grab Still") { player.grabStill() }
                    .buttonStyle(.link)
                    .help("Holds the picture now as B, in its real colours, to compare with (⌥G).")
                if player.loadingStill { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                if player.stillB != nil {
                    Button("Clear") { player.clearStill() }.buttonStyle(.link)
                }
            }
            if let name = player.stillBName, player.stillB != nil {
                Text(verbatim: "B · " + name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func chooseLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url, LUTFile.read(url.path) != nil { player.settings.lut = url.path }
    }

    private func addLUTFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        lutFoldersText = (lutFoldersText.split(separator: "\n").map(String.init) + [url.path]).joined(separator: "\n")
    }

    private func saveFrame() {
        let panel = NSSavePanel()
        let base = player.url?.deletingPathExtension().lastPathComponent ?? "Frame"
        panel.nameFieldStringValue = "\(base) \(player.label(player.index).replacingOccurrences(of: ":", with: "-")).tiff"
        panel.allowedContentTypes = [.tiff]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await player.saveFrame(to: url) } catch { NSSound.beep() }
        }
    }

    /// The page shown: Now Playing, and what to show (the source, a clip asked for, or where it was left).
    private func appeared() {
        focused = true
        let media = PlayerNowPlaying(player: player)
        media.neighbour = { _ = neighbour($0) }
        media.start()
        nowPlaying = media
        switch source {
        case .folder(let url):
            root = url
            browse(url)
            // Tests: -PluckScreenshotEnter <folder> goes into a folder in it.
            if ScreenshotMode.scene == "footage", let name = UserDefaults.standard.string(forKey: "PluckScreenshotEnter") {
                Task { try? await Task.sleep(for: .seconds(2)); browse(url.appendingPathComponent(name, isDirectory: true)) }
            }
        case .clips(let name, let urls): folder = RawFolder(url: URL(fileURLWithPath: "/" + name), clips: urls)
        case .clip(let url):
            player.open(url)
        case .file(let url):
            root = url.deletingLastPathComponent()
            browse(url.deletingLastPathComponent())
            player.open(url)
        }
        folder?.search = search
        // Tests: -PluckScreenshotExport <file.mov> exports it once it's open.
        if ScreenshotMode.rawScene, let out = UserDefaults.standard.string(forKey: "PluckScreenshotExportTo") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                let url = URL(fileURLWithPath: out)
                player.export(to: url, codec: url.pathExtension == "mp4" ? .h264 : .proresHQ, scale: 1)
            }
        }
        // Tests: -PluckScreenshotLook <log>, -PluckScreenshotLUT <file.cube>, -PluckScreenshotRange <in>-<out>.
        if ScreenshotMode.rawScene {
            let defaults = UserDefaults.standard
            Task {
                for _ in 0..<40 where player.info == nil { try? await Task.sleep(for: .milliseconds(250)) }
                if let look = defaults.string(forKey: "PluckScreenshotLook").flatMap(RawLook.init(rawValue:)) { player.settings.look = look }
                if let lut = defaults.string(forKey: "PluckScreenshotLUT") { player.settings.lut = lut }
                // -PluckScreenshotFalseColour YES: the picture in false colour.
                if defaults.bool(forKey: "PluckScreenshotFalseColour") { player.falseColour = true }
                // -PluckScreenshotCompare split|sideBySide: a still grabbed with the Log look from the first frame, against the clip as shot later.
                if let mode = defaults.string(forKey: "PluckScreenshotCompare").flatMap(CompareMode.init(rawValue:)) {
                    player.settings.look = .log
                    player.show(0)
                    for _ in 0..<80 where player.currentImage == nil { try? await Task.sleep(for: .milliseconds(250)) }
                    try? await Task.sleep(for: .seconds(2))
                    player.grabStill()
                    player.settings.look = .video
                    player.show(min(60, max(player.frames - 1, 0)))
                    try? await Task.sleep(for: .milliseconds(300))
                    player.compare = mode
                    player.splitAt = 0.45
                }
                // -PluckScreenshotPlayScale <1|2|4|8>: plays at that size.
                if defaults.integer(forKey: "PluckScreenshotPlayScale") > 0 { player.playScale = defaults.integer(forKey: "PluckScreenshotPlayScale") }
                if let range = defaults.string(forKey: "PluckScreenshotRange")?.split(separator: "-").compactMap({ Int($0) }), range.count == 2 {
                    player.show(range[0]); player.markIn(); player.show(range[1]); player.markOut(); player.show(range[0])
                }
            }
        }
        // Tests: -PluckScreenshotOpenFirst YES opens a browsed folder's first clip (and with
        // -PluckScreenshotBack YES goes back to the folder 3 seconds later, as the back button).
        if ScreenshotMode.rawScene, UserDefaults.standard.bool(forKey: "PluckScreenshotOpenFirst") {
            Task {
                for _ in 0..<40 where (folder?.allClips.isEmpty ?? true) { try? await Task.sleep(for: .milliseconds(250)) }
                guard let first = folder?.allClips.dropFirst().first else { return }
                player.open(first.url)
                guard UserDefaults.standard.bool(forKey: "PluckScreenshotBack") else { return }
                try? await Task.sleep(for: .seconds(3))
                // As the window's back button does.
                StudioNavigator.shared.goBack()
                // -PluckScreenshotForward YES: and forward to the clip again 3 seconds later.
                guard UserDefaults.standard.bool(forKey: "PluckScreenshotForward") else { return }
                try? await Task.sleep(for: .seconds(3))
                StudioNavigator.shared.goForward()
            }
        }
        // Tests: -PluckScreenshotLog <file>: what opened (or why not), the first picture, an export's end.
        if ScreenshotMode.rawScene, let log = UserDefaults.standard.string(forKey: "PluckScreenshotLog") {
            Task {
                func note(_ line: String) {
                    let old = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
                    try? (old + line + "\n").write(toFile: log, atomically: true, encoding: .utf8)
                }
                for _ in 0..<240 where player.info == nil && player.problem == nil { try? await Task.sleep(for: .milliseconds(250)) }
                if let info = player.info {
                    note("open \(info.format) \(info.width)x\(info.height) fps \(info.fps) frames \(info.frames) tc \(info.timecode ?? "-") codec \(info.codecName ?? "-") audio \(info.audioChannels)")
                } else {
                    note("problem \(player.problem ?? "timed out")")
                    return
                }
                for _ in 0..<80 where player.currentImage == nil && player.problem == nil { try? await Task.sleep(for: .milliseconds(250)) }
                note(player.currentImage.map { "picture \($0.width)x\($0.height)" } ?? "no picture \(player.problem ?? "")")
                guard UserDefaults.standard.string(forKey: "PluckScreenshotExportTo") != nil else { return }
                for _ in 0..<40 where player.exportProgress == nil && player.exported == nil && player.exportProblem == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                for _ in 0..<2400 where player.exportProgress != nil { try? await Task.sleep(for: .milliseconds(250)) }
                note(player.exported.map { "exported \($0.lastPathComponent)" } ?? "export problem \(player.exportProblem ?? "none started")")
            }
        }
        // Tests: -PluckScreenshotPlay YES plays once it's open.
        if ScreenshotMode.rawScene, UserDefaults.standard.bool(forKey: "PluckScreenshotPlay") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                player.play()
                // -PluckScreenshotLog <file> too: the frames shown a second over 8 seconds of playback (after 4 to settle).
                if let log = UserDefaults.standard.string(forKey: "PluckScreenshotLog") {
                    try? await Task.sleep(for: .seconds(4))
                    var rates: [Double] = []
                    for _ in 0..<8 { try? await Task.sleep(for: .seconds(1)); rates.append(player.playbackRate) }
                    let line = String(format: "playing rate %.2f of %.2f fps (scopes %@, analysed %d, %.0f ms each)\n", rates.reduce(0, +) / 8, player.info?.fps ?? 0,
                                      player.scopes.enabled ? "on" : "off", player.scopes.analysed,
                                      player.scopes.spent / Double(max(player.scopes.analysed, 1)) * 1000)
                    let old = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
                    try? (old + line).write(toFile: log, atomically: true, encoding: .utf8)
                }
            }
        }
        }

    private func browser(_ folder: RawFolder) -> some View {
        let browsing = root != nil
        let inLibrary: Bool? = browsing ? FootageFolders.shared.folder(containing: folder.url.path) != nil : nil
        let panes = LibraryPanes.shared
        let across: (() -> Void)? = browsing ? panes.other(pane).map { other in { panes.copy([folder.url], into: other) } } : nil
        let reference = player.reference
        return RawBrowserView(folder: folder, open: { player.open($0) },
                              compareName: reference?.url.deletingPathExtension().lastPathComponent,
                              compareWith: reference.map { ref in { player.open(ref.url, at: ref.index, settings: ref.settings, compareWith: $0) } },
                              enter: browsing ? { browse($0) } : nil, crumbs: crumbs, everyClip: browsing ? $everyClip : nil,
                              inLibrary: inLibrary, addToLibrary: { FootageFolders.shared.add(folder.url) },
                              copyAcross: across, copyIn: browsing ? { panes.copy($0, into: $1) } : nil)
    }

    /// Shows a folder (in the Library: a folder at a time, as Finder does, or every clip under it).
    private func browse(_ url: URL) {
        folder?.close()
        let opened = RawFolder(url: url, oneLevel: !everyClip)
        opened.search = search
        folder = opened
    }

    /// The folder above, while that's still inside where browsing began.
    private func parent(of url: URL) -> URL? {
        guard let root, url.standardizedFileURL.path != root.standardizedFileURL.path,
              url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) else { return nil }
        return url.deletingLastPathComponent()
    }

    private var navigationKey: String {
        let panes = LibraryPanes.shared
        return "\(folder?.url.path ?? "")|\(player.info != nil)|\(lastClip?.path ?? "")|\(panes.split)|\(panes.active)"
    }

    private func claimNavigation() {
        // A pane's clip: the pane's back button and history.
        if case .clip = source { return }
        let panes = LibraryPanes.shared
        guard !panes.split || panes.active == pane else { return }
        let inClip = folder != nil && player.info != nil
        StudioNavigator.shared.toolBack = inClip ? (folder?.url.lastPathComponent ?? "", { player.eject() }) : upStep
        StudioNavigator.shared.toolForward = folder != nil && player.info == nil ? lastClip.map { clip in { player.open(clip) } } : nil
    }

    private var upStep: (title: String, action: () -> Void)? {
        guard let here = folder?.url, let up = parent(of: here) else { return nil }
        return (up.lastPathComponent, { browse(up) })
    }

    /// From where browsing began to here.
    private var crumbs: [URL] {
        guard let root, var at = folder?.url else { return [] }
        var list: [URL] = []
        while true {
            list.insert(at, at: 0)
            guard let up = parent(of: at) else { break }
            at = up
        }
        return list.first?.standardizedFileURL.path == root.standardizedFileURL.path ? list : []
    }

    /// The clip before or after the one playing, in the folder being browsed.
    private func neighbour(_ by: Int) -> Bool {
        if case .clip = source, let url = player.url, let at = playlist.firstIndex(of: url) {
            guard playlist.indices.contains(at + by) else { return false }
            openClip?(playlist[at + by])
            return true
        }
        guard let folder, let url = player.url else { return false }
        let clips = folder.allClips.map(\.url)
        guard let at = clips.firstIndex(of: url), clips.indices.contains(at + by) else { return false }
        player.open(clips[at + by])
        return true
    }

    /// A clip plays; a folder of clips opens as thumbnails.
    private func openAny(_ url: URL) {
        if url.hasDirectoryPath && !RawFolderScan.isClipFolder(url) {
            folder?.close()
            player.eject()
            folder = RawFolder(url: url)
        } else {
            player.open(url)
        }
    }
}

/// The false colour bands under the picture: a swatch and a short name each.
private struct FalseColourLegend: View {
    /// The band (an index into FalseColour.bands) and its name.
    private static let items: [(name: LocalizedStringKey, band: Int)] = [
        ("Crushed", 0), ("Shadows", 1), ("Low", 2), ("18 % grey", 3), ("Skin +1", 4), ("Bright", 5), ("Near clip", 6), ("Clipped", 7),
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(Self.items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: Design.Radius.badge)
                        .fill(Color(cgColor: FalseColour.bands[item.band].color))
                        .frame(width: 12, height: 12)
                    Text(item.name).font(.caption2).lineLimit(1)
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Design.Spacing.window)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A problem over the picture (its own view, so it alone watches for one).
private struct RawProblemOverlay: View {
    let player: RawPlayer

    var body: some View {
        if let problem = player.problem {
            ProblemLabel(text: problem).padding(8).background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
        }
    }
}

/// The slider, time and buttons under the picture: the only part that changes with every frame.
private struct RawTransportBar: View {
    @Bindable var player: RawPlayer
    @Binding var goingTo: Bool
    @Binding var goTo: String
    @Binding var timecodeMode: String
    let saveFrame: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if player.frames > 1 {
                Slider(value: Binding(get: { Double(player.index) }, set: { player.stop(); player.show(Int($0)) }),
                       in: 0...Double(max(player.frames - 1, 1)))
                    .controlSize(.small)
                    .background(alignment: .bottomLeading) { rangeBar }
            }
            HStack(spacing: Design.Spacing.controls) {
                Button { goTo = player.label(player.index); goingTo = true } label: {
                    Text(verbatim: player.label(player.index)).font(.callout.monospacedDigit()).foregroundStyle(.primary)
                }
                .labelStyle(.titleOnly)
                .help("Go to a time or frame (⌘J), or show the time another way")
                .popover(isPresented: $goingTo, arrowEdge: .top) { goToPanel }
                if player.inPoint != nil || player.outPoint != nil {
                    Text(verbatim: "\(player.label(player.range.lowerBound)) – \(player.label(player.range.upperBound))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help("In and out (I and O; ⌥I and ⌥O clear them)")
                }
                Spacer()
                Button("Previous Frame", systemImage: "backward.frame.fill") { player.step(-1) }
                Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.togglePlay() }
                    .font(.title3)
                    .disabled(player.frames < 2)
                Button("Next Frame", systemImage: "forward.frame.fill") { player.step(1) }
                Spacer()
                Picker("While Playing", selection: Binding(get: { player.playScale }, set: { player.playScale = $0 })) {
                    Text("Play at Best Size (\(sizeName(player.autoScale)))").tag(0)
                    Divider()
                    Text("Play at Full Size").tag(1); Text("Play at ½ Size").tag(2); Text("Play at ¼ Size").tag(4); Text("Play at ⅛ Size").tag(8)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("The size frames are decoded at while playing; a paused frame is always full size. Best Size plays as large as keeps up.")
                if player.hasAudio {
                    Button(player.muted ? "Sound On" : "Mute", systemImage: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { player.muted.toggle() }
                        .help("The clip’s sound (M)")
                }
                Button("Save Frame…", systemImage: "camera") { saveFrame() }
                    .help("Saves this frame at full size as a 16-bit TIFF")
                Text(verbatim: player.label(max(player.frames - 1, 0))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, Design.Spacing.window)
        .padding(.vertical, 10)
    }

    /// The in-to-out part under the slider.
    @ViewBuilder private var rangeBar: some View {
        if player.inPoint != nil || player.outPoint != nil, player.frames > 1 {
            GeometryReader { geometry in
                let width = geometry.size.width, last = Double(max(player.frames - 1, 1))
                let a = Double(player.range.lowerBound) / last * width, b = Double(player.range.upperBound) / last * width
                Capsule().fill(Design.Brand.gradient).frame(width: max(b - a, 2), height: 3).offset(x: a, y: geometry.size.height - 1)
            }
            .allowsHitTesting(false)
        }
    }

    /// Go to a time or a frame, and how time is shown.
    private var goToPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Go To", text: $goTo)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .frame(width: 200)
                .onSubmit { if player.jump(to: goTo) { goingTo = false } else { NSSound.beep() } }
            Picker("Show", selection: $timecodeMode) {
                ForEach(RawPlayer.TimecodeMode.allCases) { mode in
                    if mode != .timeOfDay || player.info?.absoluteTimecode != nil { Text(mode.label).tag(mode.rawValue) }
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        .padding(12)
    }

    private func sizeName(_ scale: Int) -> String {
        switch scale {
        case 1: String(localized: "full")
        case 2: "½"
        case 4: "¼"
        case 8: "⅛"
        default: "1/\(scale)"
        }
    }
}

/// What macOS is told as the clip changes: Now Playing, and the clip among the recent files.
private struct PlayerSystemState: ViewModifier {
    let player: RawPlayer
    let nowPlaying: PlayerNowPlaying?

    func body(content: Content) -> some View {
        content
            .onChange(of: "\(player.url?.path ?? "")\(player.isPlaying)\(player.info?.frames ?? 0)") { nowPlaying?.update() }
            .onChange(of: player.index) { if !player.isPlaying { nowPlaying?.update() } }
            .onChange(of: player.url) { _, url in if let url { NSDocumentController.shared.noteNewRecentDocumentURL(url) } }
    }
}
