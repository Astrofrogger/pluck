import AVKit
import SwiftUI

/// The Editor: a video or song in a player with a timeline under it, like an editing program.
/// Cut it with the blade, take parts out, mark a range with I and O, check it with J, K and L,
/// and export the edit (or each part) in any of Pluck's formats.
struct EditorView: View {
    let target: EditorTarget
    @Environment(DownloadManager.self) private var manager
    @State private var model: EditorModel
    /// Made here (its own window), or kept by a tab of the Studio window, which closes it.
    private let ownsModel: Bool
    @State private var zoom = 1.0
    @Environment(\.editMedia) private var media
    @AppStorage("editTimelineGrow") private var timelineGrow = 80.0
    @AppStorage("editorSidebarTab") private var sidebarTab = EditorSidebar.Tab.ai
    @AppStorage("editorSidebar") private var sidebarShown = true
    @AppStorage("editorSidebarWidth") private var sidebarWidth = 300.0
    @FocusState private var focused: Bool

    init(target: EditorTarget, model: EditorModel? = nil) {
        self.target = target
        ownsModel = model == nil
        _model = State(initialValue: model ?? EditorModel(file: target.file))
    }

    private var exports: EditorExports { model.exports }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if let media { media }
                VStack(spacing: Design.Spacing.controls) {
                    picture
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    transport
                }
                .padding([.horizontal, .top], Design.Spacing.window)
                .padding(.bottom, Design.Spacing.controls)
                if sidebarShown {
                    ResizeHandle(width: $sidebarWidth, range: 280...560, edge: .trailing)
                    EditorSidebar(model: model)
                        .frame(width: sidebarWidth)
                        .clipped()
                        .transition(.move(edge: .trailing))
                }
            }
            HeightHandle(grow: $timelineGrow, range: 0...360)
            VStack(spacing: Design.Spacing.controls) {
                VStack(spacing: 4) {
                    EditorToolbar(model: model, zoom: $zoom)
                    EditorTimeline(model: model, zoom: $zoom, grow: timelineGrow)
                }
                // Working on the timeline: the keys are the Editor's again.
                .simultaneousGesture(TapGesture().onEnded { focused = true })
                exportBar
            }
            .padding(Design.Spacing.window)
        }
        .frame(minWidth: (ownsModel ? 760 : 550) + (sidebarShown ? sidebarWidth : 0), minHeight: 520)
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
        .onDisappear { if ownsModel { model.close() } else { model.player.pause() } }
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
            } else if model.duration == 0 {
                // Still reading the file (a busy or slow drive can take a while).
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Opening…").foregroundStyle(.secondary)
                }
            } else if model.hasVideo {
                ZStack {
                    PlayerSurface(player: model.player)
                    if model.showSubtitles, !model.subtitles.isEmpty {
                        SubtitleOverlay(model: model)
                    }
                    #if STUDIO
                    if !model.isPlaying, sidebarShown, sidebarTab == .picture {
                        ViewerControlsOverlay(look: model.look ?? ClipLook(), pictureSize: model.pixelSize, frameSize: model.pixelSize) { record, body in
                            model.changeLook(record: record, body)
                        }
                    }
                    #endif
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
        .clipped()
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
                    .lineLimit(1)
                    .fixedSize()
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
                if let progress = exports.progress {
                    ExportProgress(value: progress) { exports.stop() }.frame(width: 200)
                } else if let output = exports.output {
                    DoneLabel(text: Text(output.lastPathComponent), file: output)
                } else if let problem = exports.problem {
                    ProblemLabel(text: problem).lineLimit(1)
                } else if exports.handedOver {
                    Label("In the download list", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            // While the Export tab is open, its own button does it.
            if !(sidebarShown && sidebarTab == .export) {
                Button("Export…", systemImage: "square.and.arrow.up") {
                    withAnimation(.snappy) {
                        sidebarTab = .export
                        sidebarShown = true
                    }
                }
                .buttonStyle(BrandButtonStyle())
                .disabled(model.duration == 0 || exports.isRunning || (model.isEdited && model.keptParts.isEmpty))
                .keyboardShortcut("e", modifiers: .command)
                .help("Choose what to export and how, in the sidebar (⌘E)")
            }
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

    // MARK: - Keys

    /// The keys editors know: Space, J K L, ← → for frames (⇧ for seconds), I and O, ⌥X, ↑ ↓, ⌘+ ⌘−.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        // While typing (a subtitle, a search), the keys are the text's, not the Editor's.
        if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
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
            #if STUDIO
            switch Shortcuts.shared.action(for: press, in: .edit) {
            case .editMarkIn: model.markIn(); return .handled
            case .editMarkOut: model.markOut(); return .handled
            case .editSnapping: model.snapping.toggle(); return .handled
            case .editSplit: model.cut(at: model.time); return .handled
            case .editBlade: model.tool = .blade; return .handled
            case .editSelect: model.tool = .select; return .handled
            case .editUndo: model.undo(); return .handled
            case .editRedo: model.redo(); return .handled
            default: break
            }
            #endif
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
            case "z" where command && press.modifiers.contains(.shift): model.redo()
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
