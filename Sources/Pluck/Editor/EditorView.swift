import AVKit
import SwiftUI

/// The Editor: a video or song in a player with a timeline under it, like an editing program.
/// Cut it with the blade, take parts out, mark a range with I and O, check it with J, K and L,
/// and export the edit (or each part) in any of Pluck's formats.
struct EditorView: View {
    let target: EditorTarget
    @Environment(DownloadManager.self) private var manager
    @State private var model: EditorModel
    @State private var zoom = 1.0
    @State private var exported = false
    @State private var exportShown = false
    @State private var exporting: Double?
    @State private var joined: URL?
    @State private var exportProblem: String?
    @AppStorage("editorSidebar") private var sidebarShown = true
    @FocusState private var focused: Bool

    init(target: EditorTarget) {
        self.target = target
        _model = State(initialValue: EditorModel(file: target.file))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                picture
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: Design.Spacing.controls) {
                    transport
                    VStack(spacing: 4) {
                        EditorToolbar(model: model, zoom: $zoom)
                        EditorTimeline(model: model, zoom: $zoom)
                    }
                    exportBar
                }
                .padding(Design.Spacing.window)
            }
            if sidebarShown {
                Divider()
                EditorSidebar(model: model)
                    .frame(width: 300)
                    .clipped()
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(minWidth: sidebarShown ? 1040 : 760, minHeight: 580)
        .toolbar {
            ToolbarItem {
                Button {
                    withAnimation(.snappy) { sidebarShown.toggle() }
                } label: {
                    Label("Sidebar", systemImage: "sidebar.right")
                }
                .help("Show or hide the sidebar (⌥⌘S)")
                .keyboardShortcut("s", modifiers: [.command, .option])
            }
        }
        .navigationTitle(target.file.lastPathComponent)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: key)
        .task {
            focused = true
            await model.load(ffmpeg: manager.tool("ffmpeg"), ffprobe: manager.tool("ffprobe"))
        }
        .onDisappear { model.close() }
    }

    // MARK: - Picture

    @ViewBuilder private var picture: some View {
        ZStack {
            Color.black
            if let preparing = model.preparing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(preparing).foregroundStyle(.secondary)
                }
            } else if let problem = model.problem {
                ProblemLabel(text: problem).padding()
            } else if model.hasVideo {
                ZStack {
                    PlayerSurface(player: model.player)
                    if model.showSubtitles, !model.subtitles.isEmpty {
                        SubtitleOverlay(model: model)
                    }
                }
                .aspectRatio(model.aspect, contentMode: .fit)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 54)).foregroundStyle(.secondary)
                    Text(target.file.deletingPathExtension().lastPathComponent).font(.title3).foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .onTapGesture { model.togglePlay(); focused = true }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: Design.Spacing.controls) {
            readout(Text("In"), model.inPoint, symbol: "arrow.right.to.line") { model.inPoint.map { model.seek(to: $0) } }
            Spacer(minLength: 8)
            GlassGroup(spacing: Design.Spacing.controls) {
                HStack(spacing: Design.Spacing.controls) {
                    Button { model.seek(to: model.rangeStart) } label: { Image(systemName: "backward.end.fill") }
                        .buttonStyle(BarButtonStyle())
                        .help("Go to the start of the range (↑)")
                    Button { model.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                        .buttonStyle(BarButtonStyle())
                        .help("Back one frame (←)")
                    Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                        .buttonStyle(BarButtonStyle(prominent: true))
                        .help("Play or pause (Space)")
                    Button { model.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                        .buttonStyle(BarButtonStyle())
                        .help("Forward one frame (→)")
                    Button { model.seek(to: model.rangeEnd) } label: { Image(systemName: "forward.end.fill") }
                        .buttonStyle(BarButtonStyle())
                        .help("Go to the end of the range (↓)")
                }
            }
            Text(model.timecode(model.time))
                .font(.system(size: 20, weight: .medium).monospacedDigit())
                .fixedSize()
                .accessibilityLabel(Text("Playhead"))
            Spacer(minLength: 8)
            readout(Text("Out"), model.outPoint, symbol: "arrow.left.to.line") { model.outPoint.map { model.seek(to: $0) } }
        }
    }

    private func readout(_ title: Text, _ value: Double?, symbol: String, go: @escaping () -> Void) -> some View {
        Button(action: go) {
            VStack(alignment: .leading, spacing: 1) {
                title.font(.caption).foregroundStyle(.secondary)
                Text(value.map(model.timecode) ?? "––:––:––").font(.callout.monospacedDigit())
            }
        }
        .buttonStyle(.plain)
        .disabled(value == nil)
        .help(value == nil ? Text("Set with I or O at the playhead") : Text("Go there"))
    }

    // MARK: - Export

    private var exportBar: some View {
        HStack(spacing: Design.Spacing.controls) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.callout.monospacedDigit())
                    .lineLimit(1)
                if let exporting {
                    ProgressView(value: exporting).frame(width: 180)
                } else if let joined {
                    DoneLabel(text: Text(joined.lastPathComponent), file: joined)
                } else if let exportProblem {
                    Text(exportProblem).font(.caption).foregroundStyle(.orange).lineLimit(1)
                } else if exported {
                    Label("In the download list", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            Button("Export…", systemImage: "square.and.arrow.up") { exportShown = true }
                .buttonStyle(BarCapsuleButtonStyle())
                .disabled(model.duration == 0 || exporting != nil || (model.isEdited && model.keptParts.isEmpty))
                .keyboardShortcut("e", modifiers: .command)
                .help("Choose what to export and how (⌘E)")
        }
        .sheet(isPresented: $exportShown) {
            EditorExportSheet(model: model) { run($0) }
        }
    }

    /// "Edit 1:23:10 · 4 parts", "Range 0:12:24" or "Whole file 3:21:14".
    private var summary: String {
        if model.isEdited {
            let parts = model.keptParts.count
            return String(AttributedString(localized: "Edit \(model.timecode(model.editLength)) · ^[\(parts) part](inflect: true)").characters)
        }
        return model.hasRange
            ? String(localized: "Range \(model.timecode(model.rangeEnd - model.rangeStart))")
            : String(localized: "Whole file \(model.timecode(model.duration))")
    }

    private func run(_ choice: EditorExportChoice) {
        joined = nil
        exportProblem = nil
        let gifOrOriginal = choice.format == .gif || choice.format == .original
        // Joined into one file, or with subtitles drawn in: the Editor writes it itself.
        if (model.isEdited && !choice.each || choice.burn) && !gifOrOriginal {
            exportJoined(choice)
            return
        }
        // Each part (or the range, or the whole file) through Pluck's conversions.
        let clips: [ClipRange?] = model.isEdited
            ? model.keptParts.map { ClipRange(start: $0.lowerBound, end: $0.upperBound) }
            : [model.clip]
        for clip in clips {
            let preset: Conversion.Preset = choice.format.preset == .trim && clip == nil ? .mp4 : choice.format.preset
            manager.convert([target.file], preset: preset, percent: preset == .compress ? 50 : nil, clip: clip)
        }
        if choice.srt { writeSRT(for: model.isEdited ? model.keptParts : [model.rangeStart...model.rangeEnd], next: nil) }
        withAnimation { exported = true }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { exported = false }
        }
    }

    /// The kept parts (or the range) as one file, with the subtitles drawn in if chosen, next to
    /// the downloads, and added to the list.
    private func exportJoined(_ choice: EditorExportChoice) {
        guard let ffmpeg = manager.tool("ffmpeg") else { exportProblem = Converting.Failure.noFFmpeg.localizedDescription; return }
        let folder = UserDefaults.standard.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory() + "/Downloads"
        let audioOnly = choice.format == .audio || !model.hasVideo
        let suffix = model.isEdited ? String(localized: " (edit)") : (choice.burn ? String(localized: " (subtitled)") : String(localized: " (part)"))
        let output = Converting.outputURL(folder: folder, name: target.file.deletingPathExtension().lastPathComponent + suffix,
                                          fileExtension: audioOnly ? "m4a" : "mp4")
        let parts = model.isEdited ? model.keptParts : [model.rangeStart...model.rangeEnd]
        var assFile: URL?
        if choice.burn, !audioOnly {
            let ass = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-editor-\(UUID().uuidString).ass")
            let text = EditorSubtitleFiles.ass(model.subtitlesForEdit(parts), style: model.subtitleStyle,
                                               width: Int(model.pixelSize.width), height: Int(model.pixelSize.height))
            if (try? text.write(to: ass, atomically: true, encoding: .utf8)) != nil { assFile = ass }
        }
        let video = model.hasVideo, audio = model.hasAudio, file = target.file
        exporting = 0
        Task {
            let done = await EditorExport.joined(parts, of: file, video: video, audio: audio, to: output, ffmpeg: ffmpeg,
                                                 quality: choice.format.quality, subtitles: assFile) { value in
                Task { @MainActor in exporting = value }
            }
            if let assFile { try? FileManager.default.removeItem(at: assFile) }
            exporting = nil
            if done {
                joined = output
                if choice.srt { writeSRT(for: parts, next: output) }
                _ = manager.addLocalFiles([output])
                manager.saveHistory()
            } else {
                try? FileManager.default.removeItem(at: output)
                exportProblem = String(localized: "The edit couldn’t be written.")
            }
        }
    }

    /// The subtitles for what's exported as an .srt file: next to the exported file, or in the
    /// downloads folder.
    private func writeSRT(for parts: [ClosedRange<Double>], next output: URL?) {
        let folder = UserDefaults.standard.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory() + "/Downloads"
        let url = output?.deletingPathExtension().appendingPathExtension("srt")
            ?? Converting.outputURL(folder: folder, name: target.file.deletingPathExtension().lastPathComponent, fileExtension: "srt")
        try? EditorSubtitleFiles.srt(model.subtitlesForEdit(parts)).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Keys

    /// The keys editors know: Space, J K L, ← → for frames (⇧ for seconds), I and O, ⌥X, ↑ ↓, ⌘+ ⌘−.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift), option = press.modifiers.contains(.option), command = press.modifiers.contains(.command)
        switch press.key {
        case .space: model.togglePlay()
        case .leftArrow: shift ? model.step(seconds: -1) : model.step(frames: -1)
        case .rightArrow: shift ? model.step(seconds: 1) : model.step(frames: 1)
        case .upArrow: model.seek(to: model.rangeStart)
        case .downArrow: model.seek(to: model.rangeEnd)
        case .home: model.seek(to: 0)
        case .end: model.seek(to: model.duration)
        case .delete, .deleteForward: model.removeSelected()
        default:
            switch press.characters.lowercased() {
            case "j": model.shuttle(-1)
            case "k": model.shuttle(0)
            case "l": model.shuttle(1)
            case "i" where option: model.inPoint = nil
            case "o" where option: model.outPoint = nil
            case "i": model.markIn()
            case "o": model.markOut()
            case "x" where option, "≈": model.clearRange()
            case "n": model.snapping.toggle()
            case "b" where command: model.cut(at: model.time)
            case "b": model.tool = .blade
            case "a": model.tool = .select
            case "z" where command: model.undo()
            case "=" where command, "+" where command: zoom = min(zoom * 1.6, max(1, min(model.duration / 2, 200)))
            case "-" where command: zoom = max(zoom / 1.6, 1)
            case "0" where command: zoom = 1
            default: return .ignored
            }
        }
        return .handled
    }
}

/// The video, without the player's own controls (the Editor has its own).
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
