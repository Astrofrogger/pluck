import SwiftUI
import UniformTypeIdentifiers

/// Raw Player's page: drop a camera raw clip, watch it, and change its raw settings as it plays.
struct RawPlayerView: View {
    /// A clip to open as soon as the page appears (screenshots, the Library, Offload).
    @MainActor static var openFile: URL?
    static let openNotification = Notification.Name("PluckRawPlayerOpen")

    @State private var player = RawPlayer()
    /// A folder of footage being browsed (clips open from it, and Esc goes back to it).
    @State private var folder: RawFolder?
    /// The clip last open from the folder, for going forward to it again.
    @State private var lastClip: URL?
    @State private var dropping = false
    @State private var showMeta = false
    @AppStorage("rawExportCodec") private var exportCodec = RawExport.Codec.proresHQ.rawValue
    @AppStorage("rawExportScale") private var exportScale = 1
    @AppStorage("rawTimecodeMode") private var timecodeMode = RawPlayer.TimecodeMode.source.rawValue
    @AppStorage("rawLUTFolders") private var lutFoldersText = ""
    @State private var goingTo = false
    @State private var goTo = ""
    @State private var lutGroups: [(group: String, files: [URL])] = []
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if player.info == nil, let folder {
                RawBrowserView(folder: folder, open: { player.open($0) }) {
                    folder.close()
                    self.folder = nil
                    player.eject()
                }
            } else if player.info == nil {
                ToolPage {
                    ToolWelcome(symbol: "play.rectangle", title: Text("Player"),
                                subtitle: Text("Play camera raw, pro formats and image sequences, with timecode, LUTs and sound. Raw clips take ISO, white balance and exposure from the raw data."))
                    DropZone(symbol: "film", text: Text(dropText), targeted: dropping, busy: player.opening)
                    HStack {
                        if let problem = player.problem { ProblemLabel(text: problem) }
                        Spacer()
                        Button("Open Folder…", systemImage: "square.grid.2x2") { chooseFolder() }
                            .buttonStyle(GlassCapsuleButtonStyle())
                            .help("Every clip in a folder and the folders in it, as thumbnails to skim")
                        Button("Choose Clip…", systemImage: "folder") { choose() }
                            .buttonStyle(GlassCapsuleButtonStyle())
                    }
                    PageNote(text: Text("Decoded on this Mac with the camera makers’ own decoders."), symbol: "desktopcomputer")
                }
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        viewer
                        RawTransportBar(player: player, goingTo: $goingTo, goTo: $goTo, timecodeMode: $timecodeMode, saveFrame: saveFrame)
                    }
                    Divider()
                    sidebar.frame(width: 290)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { player.togglePlay(); return .handled }
        .onKeyPress(.escape) {
            guard folder != nil, player.info != nil else { return .ignored }
            player.eject()
            return .handled
        }
        // The previous and next clip of the folder.
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard let folder, let url = player.url, press.modifiers.contains(.command) else { return .ignored }
            let clips = folder.allClips.map(\.url)
            guard let at = clips.firstIndex(of: url) else { return .ignored }
            let to = at + (press.key == .downArrow ? 1 : -1)
            guard clips.indices.contains(to) else { return .ignored }
            player.open(clips[to])
            return .handled
        }
        .onKeyPress(.leftArrow) { player.step(-1); return .handled }
        .onKeyPress(.rightArrow) { player.step(1); return .handled }
        .onKeyPress(.home) { player.stop(); player.show(0); return .handled }
        .onKeyPress(.end) { player.stop(); player.show(player.frames - 1); return .handled }
        // In and out (⌥ clears), J K L, ⌘J to go to a time.
        .onKeyPress(keys: ["i", "o", "j", "k", "l", "m"]) { press in
            let option = press.modifiers.contains(.option)
            switch press.characters.lowercased() {
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
        // While a clip of a folder plays, the window's back button goes back to the folder.
        .onChange(of: folder != nil && player.info != nil, initial: true) { _, inClip in
            StudioNavigator.shared.toolBack = inClip ? (folder?.url.lastPathComponent ?? "", { player.eject() }) : nil
        }
        // ...and forward again to the clip that was open.
        .onChange(of: player.url) { old, new in if new == nil, folder != nil, let old { lastClip = old } }
        .onChange(of: folder?.url) { lastClip = nil }
        .onChange(of: "\(folder != nil && player.info == nil)\(lastClip?.path ?? "")", initial: true) {
            StudioNavigator.shared.toolForward = folder != nil && player.info == nil ? lastClip.map { clip in { player.open(clip) } } : nil
        }
        .onChange(of: timecodeMode, initial: true) { _, mode in player.timecodeMode = RawPlayer.TimecodeMode(rawValue: mode) ?? .source }
        .task(id: lutFoldersText) { loadLUTs() }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task { if let url = await providers.first?.load(URL.self) { openAny(url) } }
            return true
        }
        .onAppear {
            focused = true
            if let url = Self.openFile { Self.openFile = nil; openAny(url) }
            // Tests: -PluckScreenshotExport <file.mov> exports it once it's open.
            if ScreenshotMode.scene == "raw", let out = UserDefaults.standard.string(forKey: "PluckScreenshotExportTo") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    let url = URL(fileURLWithPath: out)
                    player.export(to: url, codec: url.pathExtension == "mp4" ? .h264 : .proresHQ, scale: 1)
                }
            }
            // Tests: -PluckScreenshotLook <log>, -PluckScreenshotLUT <file.cube>, -PluckScreenshotRange <in>-<out>.
            if ScreenshotMode.scene == "raw" {
                let defaults = UserDefaults.standard
                Task {
                    for _ in 0..<40 where player.info == nil { try? await Task.sleep(for: .milliseconds(250)) }
                    if let look = defaults.string(forKey: "PluckScreenshotLook").flatMap(RawLook.init(rawValue:)) { player.settings.look = look }
                    if let lut = defaults.string(forKey: "PluckScreenshotLUT") { player.settings.lut = lut }
                    // -PluckScreenshotPlayScale <1|2|4|8>: plays at that size.
                    if defaults.integer(forKey: "PluckScreenshotPlayScale") > 0 { player.playScale = defaults.integer(forKey: "PluckScreenshotPlayScale") }
                    if let range = defaults.string(forKey: "PluckScreenshotRange")?.split(separator: "-").compactMap({ Int($0) }), range.count == 2 {
                        player.show(range[0]); player.markIn(); player.show(range[1]); player.markOut(); player.show(range[0])
                    }
                }
            }
            // Tests: -PluckScreenshotOpenFirst YES opens a browsed folder's first clip (and with
            // -PluckScreenshotBack YES goes back to the folder 3 seconds later, as the back button).
            if ScreenshotMode.scene == "raw", UserDefaults.standard.bool(forKey: "PluckScreenshotOpenFirst") {
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
            if ScreenshotMode.scene == "raw", let log = UserDefaults.standard.string(forKey: "PluckScreenshotLog") {
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
            if ScreenshotMode.scene == "raw", UserDefaults.standard.bool(forKey: "PluckScreenshotPlay") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    player.play()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.openNotification)) { note in
            if let url = note.object as? URL { Self.openFile = nil; openAny(url) }
        }
        .onDisappear {
            StudioNavigator.shared.toolBack = nil
            StudioNavigator.shared.toolForward = nil
            player.close()
            folder?.close()
        }
    }

    private var dropText: String {
        let names = ["r3d": "R3D", "braw": "BRAW", "crm": "CRM"].filter { RawHelperSource.formats.contains($0.key) }.map(\.value).sorted()
        return String(localized: "Drop a clip or a folder: \((names + ["CinemaDNG", "ProRes RAW", "ProRes", "H.264", "MXF", "DPX", "EXR"]).formatted(.list(type: .or))).")
    }

    // MARK: - The picture

    private var viewer: some View {
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
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.url?.lastPathComponent ?? "").font(.headline).lineLimit(1).truncationMode(.middle)
                        Text("\(info.formatName) · \(info.width)×\(info.height) · \(info.fps.formatted(.number.precision(.fractionLength(0...3)))) fps")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if info.isRaw {
                    Picker("Look", selection: $player.settings.look) {
                        ForEach(RawLook.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Video: ready to watch (Rec.709). As Shot: as the camera was set. Log: flat, for grading.")
                    }
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
        VStack(alignment: .leading, spacing: 4) {
            if let camera = info.camera { row(Text("Camera"), camera) }
            row(Text("Frames"), "\(info.frames)")
            if player.isPlaying, player.playbackRate > 0 {
                row(Text("Playing"), String(localized: "\(Int(player.playbackRate.rounded())) of \(Int(info.fps.rounded())) fps"))
            }
            if !info.meta.isEmpty {
                DisclosureGroup(isExpanded: $showMeta) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(info.meta.keys.sorted(), id: \.self) { key in
                            row(Text(verbatim: key), info.meta[key] ?? "")
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("All Metadata").font(.callout)
                }
            }
        }
        .font(.caption)
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

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.item]
        panel.prompt = String(localized: "Play")
        if panel.runModal() == .OK, let url = panel.url { openAny(url) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Open")
        if panel.runModal() == .OK, let url = panel.url { openAny(url) }
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
