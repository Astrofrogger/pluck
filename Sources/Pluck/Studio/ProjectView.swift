import AVKit
import SwiftUI

/// A project in the Editor: the picture with its titles, the transport, the tools, a timeline
/// of clips with music and titles under them, and the inspector (the clip, the story, titles,
/// export). Keys work like an editing program's: Space, ← →, ⌘B, ⌫, ⌘D, ⌘Z.
struct ProjectView: View {
    @Bindable var model: ProjectModel
    @Environment(DownloadManager.self) private var manager
    @AppStorage("editorSidebar") private var sidebarShown = true
    @AppStorage("editorSidebarWidth") private var sidebarWidth = 300.0
    @AppStorage("projectSidebarTab") private var tab = ProjectInspector.Tab.clip
    @State private var zoom = 1.0
    @State private var dropTargeted = false
    @Environment(\.editMedia) private var media
    /// How much taller than its least the timeline is (drag the line above it).
    @AppStorage("editTimelineGrow") private var timelineGrow = 30.0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if let media { media }
                VStack(spacing: Design.Spacing.controls) {
                    picture.frame(maxWidth: .infinity, maxHeight: .infinity)
                    transport
                }
                .padding([.horizontal, .top], Design.Spacing.window)
                .padding(.bottom, Design.Spacing.controls)
                if sidebarShown {
                    ResizeHandle(width: $sidebarWidth, range: 280...560, edge: .trailing)
                    ProjectInspector(model: model, tab: $tab)
                        .frame(width: sidebarWidth)
                        .clipped()
                }
            }
            HeightHandle(grow: $timelineGrow, range: 0...360)
            VStack(spacing: Design.Spacing.controls) {
                VStack(spacing: 4) {
                    ProjectToolbar(model: model, zoom: $zoom, addMedia: addMedia, addMusic: addMusic)
                    ProjectTimeline(model: model, zoom: $zoom, grow: timelineGrow)
                }
                .simultaneousGesture(TapGesture().onEnded { focused = true })
                // Only when something needs doing (a save that failed, files offline).
                if model.saveProblem != nil || !model.missing.isEmpty { footer }
            }
            .padding(.horizontal, Design.Spacing.inset)
            .padding(.top, Design.Spacing.controls)
            .padding(.bottom, Design.Spacing.inset)
        }
        // (With the media beside it, all of it fits the smallest window.)
        .frame(minWidth: 460 + (sidebarShown ? sidebarWidth : 0), minHeight: 520)
        .toolbar {
            // The edit going out: to DaVinci Resolve, or exported.
            ToolbarItemGroup(placement: .primaryAction) {
                if ProjectResolve.isAvailable {
                    Button {
                        ProjectResolve.sendAndShow(model)
                    } label: {
                        if model.sendingToResolve {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Send to DaVinci", systemImage: "arrow.up.forward.app")
                        }
                    }
                    .disabled(model.project.clips.isEmpty || model.sendingToResolve)
                    .help("Send to DaVinci Resolve: a new timeline in the project open there, with the subtitles (files already there aren’t imported again)")
                }
                Button {
                    withAnimation(.snappy) { tab = .export; sidebarShown = true }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
                }
                .disabled(model.project.clips.isEmpty)
                .keyboardShortcut("e", modifiers: .command)
                .help("Export (⌘E)")
            }
            ToolbarItem {
                Button { withAnimation(.snappy) { sidebarShown.toggle() } } label: { Label("Sidebar", systemImage: "sidebar.right") }
                    .help("Show or hide the sidebar (⌥⌘S)")
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
        }
        .navigationTitle(model.project.name)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: key)
        .onAppear { focused = true }
        .task {
            // Tests: -PluckScreenshotAspect <9:16> reframes the project.
            if ScreenshotMode.scene == "project", let aspect = UserDefaults.standard.string(forKey: "PluckScreenshotAspect") {
                try? await Task.sleep(for: .seconds(2))
                await model.setAspect(aspect)
            }
            // Tests: -PluckScreenshotFitBeat YES fits the cuts to the beat once the beats are found.
            if ScreenshotMode.scene == "project", UserDefaults.standard.bool(forKey: "PluckScreenshotFitBeat") {
                for _ in 0..<60 where model.timelineBeats.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
                model.fitToBeat()
            }
        }
        .task {
            // Tests: -PluckScreenshotRelink <folder> finds the missing files there.
            if ScreenshotMode.scene == "project", let folder = UserDefaults.standard.string(forKey: "PluckScreenshotRelink") {
                try? await Task.sleep(for: .seconds(3))
                _ = await model.relink(in: URL(fileURLWithPath: folder))
            }
        }
        .task(id: model.project.clips.count) {
            // Screenshots: -PluckScreenshotExport YES exports once the clips are in, with a title and music.
            guard ScreenshotMode.scene == "project", UserDefaults.standard.bool(forKey: "PluckScreenshotExport"),
                  model.project.clips.count >= 2, model.exports.finished.isEmpty, !model.exports.isRunning else { return }
            if model.project.titles.isEmpty { model.addTitle(at: 1) }
            if model.project.music.isEmpty, let song = UserDefaults.standard.string(forKey: "PluckScreenshotMusic") {
                await model.addMusic(URL(fileURLWithPath: song))
            }
            try? await Task.sleep(for: .seconds(2))
            // -PluckScreenshotExportEach YES: each clip as a file of its own.
            if UserDefaults.standard.bool(forKey: "PluckScreenshotExportEach") {
                model.exports.runEach(model.project, settings: EditorRenderSettings(), audioOnly: false, size: model.renderSize,
                                      fps: model.frameRate, lengths: model.knownLengths, manager: manager)
            } else {
                model.exports.run(model.project, settings: EditorRenderSettings(), audioOnly: false, size: model.renderSize,
                                  fps: model.frameRate, lengths: model.knownLengths, manager: manager)
            }
        }
        .task {
            // Tests: -PluckScreenshotSaveFrame <file.png> saves the frame at the playhead there.
            if ScreenshotMode.scene == "project", let file = UserDefaults.standard.string(forKey: "PluckScreenshotSaveFrame") {
                try? await Task.sleep(for: .seconds(8))
                model.saveFrame(to: URL(fileURLWithPath: file))
            }
        }
        .onDisappear { model.player.pause() }
        .onChange(of: Stabilizer.shared.finished) { _, _ in model.refresh() }
    }

    // MARK: - Picture

    private var picture: some View {
        ZStack {
            Color.black
            if model.project.clips.isEmpty {
                VStack(spacing: Design.Spacing.section) {
                    DropZone(symbol: "rectangle.stack.badge.plus", text: Text("Drop videos here, or drag them from Media"), targeted: dropTargeted)
                    Button("Add Media…", systemImage: "plus", action: addMedia)
                        .buttonStyle(BrandButtonStyle())
                }
                .padding(Design.Spacing.window)
                .frame(maxWidth: 520)
            } else {
                ZStack {
                    ProjectPlayerSurface(player: model.player)
                    TitleOverlay(model: model)
                    if model.project.subtitlesOn == true { ProjectSubtitleOverlay(model: model) }
                    if !model.isPlaying, sidebarShown, tab == .clip, let (index, _) = model.clip(at: model.time), model.project.clips.indices.contains(index) {
                        let clip = model.project.clips[index]
                        ViewerControlsOverlay(look: clip.look ?? ClipLook(), pictureSize: model.pictureSizes[clip.path], frameSize: model.renderSize) { record, body in
                            model.selected = [clip.id]
                            model.set(clip.id, record: record) { clip in
                                var look = clip.look ?? ClipLook()
                                body(&look)
                                look.reframed = nil   // placed by hand now
                                clip.look = look.isDefault ? nil : look
                            }
                        }
                    }
                }
                .aspectRatio(model.renderSize.width / max(model.renderSize.height, 1), contentMode: .fit)
            }
            if let preparing = model.preparing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(preparing).foregroundStyle(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial, in: .rect(cornerRadius: Design.Radius.box))
            }
        }
        .clipped()
        .contentShape(.rect)
        .onTapGesture { model.togglePlay(); focused = true }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var files: [URL] = []
                for provider in providers {
                    if let url = await provider.load(URL.self), url.isFileURL { files.append(url) }
                }
                await model.add(files)
                AppDelegate.shared?.ai.imported(files)
            }
            return true
        }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: Design.Spacing.controls) {
            // The side labels give way first when the viewer is narrow (the controls never do).
            Text("^[\(model.project.clips.count) clip](inflect: true)").font(.callout).foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            GlassGroup(spacing: Design.Spacing.controls) {
                HStack(spacing: Design.Spacing.controls) {
                    Button { model.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                        .buttonStyle(BarButtonStyle()).help("To the start")
                    Button { model.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                        .buttonStyle(BarButtonStyle()).help("Back one frame (←)")
                    Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                        .buttonStyle(BarButtonStyle(prominent: true)).help("Play or pause (Space)")
                    Button { model.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                        .buttonStyle(BarButtonStyle()).help("Forward one frame (→)")
                    Button { model.seek(to: model.duration) } label: { Image(systemName: "forward.end.fill") }
                        .buttonStyle(BarButtonStyle()).help("To the end")
                }
            }
            Text(model.timecode(model.time, full: true))
                .font(.system(size: 20, weight: .medium).monospacedDigit())
                .fixedSize()
            Spacer(minLength: 8)
            Text(Format.duration(model.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .help("The length of the edit")
                .lineLimit(1)
                .layoutPriority(-1)
        }
    }

    private var footer: some View {
        HStack(spacing: Design.Spacing.controls) {
            if let problem = model.saveProblem {
                ProblemLabel(text: problem)
                Button("Try Again") { model.save(now: true) }.buttonStyle(.link)
            }
            if !model.missing.isEmpty {
                ProblemLabel(text: String(AttributedString(localized: "^[\(model.missing.count) file](inflect: true) offline").characters))
                    .help(model.missing.map { ($0 as NSString).lastPathComponent }.sorted().joined(separator: "\n"))
                Button("Relink…") { relink() }.buttonStyle(.link)
            }
            Spacer(minLength: 8)
        }
    }

    /// Finds the missing files in a folder the user picks.
    private func relink() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Relink")
        panel.message = String(localized: "Choose the folder the missing files are in now.")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { _ = await model.relink(in: folder) }
    }

    // MARK: - Adding

    private func addMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio]
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        let files = panel.urls
        Task { await model.add(files) }
        AppDelegate.shared?.ai.imported(files)
    }

    private func addMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addMusic(url) }
    }

    // MARK: - Keys

    private func key(_ press: KeyPress) -> KeyPress.Result {
        if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
        let shift = press.modifiers.contains(.shift)
        let option = press.modifiers.contains(.option), command = press.modifiers.contains(.command)
        // With ⌥ the typed character changes (⌥I is a dead key, ⌥O is ø): the key itself.
        let letter = (option ? NSApp.currentEvent?.charactersIgnoringModifiers : nil)?.lowercased() ?? press.characters.lowercased()
        if option, !command {
            switch letter {
            case "i": model.clearIn(); return .handled
            case "o": model.clearOut(); return .handled
            case "x": model.clearRange(); return .handled
            default: break
            }
        }
        if command, !option {
            // Zoom in and out of the timeline, as in the Editor; clips copied and pasted.
            switch letter {
            case "c" where !shift: return model.copySelection() ? .handled : .ignored
            case "x" where !shift: model.cutSelection(); return .handled
            case "v" where !shift: return model.paste() ? .handled : .ignored
            case "=", "+": zoom = min(zoom * 1.5, max(min(model.duration / 2, 400), 1)); return .handled
            case "-": zoom = max(zoom / 1.5, 1); return .handled
            case "0": zoom = 1; return .handled
            default: break
            }
        }
        // ⇧F: the frame at the playhead, held.
        if shift, !command, !option, letter == "f" { model.freezeFrame(); return .handled }
        switch press.key {
        case .space: model.togglePlay()
        case .leftArrow: model.step(frames: shift ? -Int(model.frameRate) : -1)
        case .rightArrow: model.step(frames: shift ? Int(model.frameRate) : 1)
        case .home: model.seek(to: 0)
        case .end: model.seek(to: model.duration)
        // Edit to edit, and shuttling, as in the Editor.
        case .upArrow: model.jumpToEdit(forward: false)
        case .downArrow: model.jumpToEdit(forward: true)
        case "j": model.shuttle(-1)
        case "k": model.shuttle(0)
        case "l": model.shuttle(1)
        case .delete, .deleteForward:
            // A title, a song or clips, whichever is selected.
            if let title = model.selectedTitle { model.removeTitle(title) }
            else if let song = model.project.music.first(where: { model.selected.contains($0.id) }) { model.removeMusic(song.id); model.selected = [] }
            else { let chosen = model.selected; model.delete(chosen); model.removeItems(chosen) }
        default:
            switch Shortcuts.shared.action(for: press, in: .edit) {
            case .editSplit: model.split(at: model.time)
            case .editBlade: model.tool = .blade
            case .editSelect: model.tool = .select
            case .editDuplicate: model.duplicate(model.selected)
            case .editRedo: model.redo()
            case .editUndo: model.undo()
            case .editSnapping: model.snapping.toggle()
            case .editTitle: model.addTitle(at: model.time)
            case .editMarkIn: model.markIn()
            case .editMarkOut: model.markOut()
            case .editMarker: model.addMarker()
            default: return .ignored
            }
        }
        return .handled
    }
}

/// The project's picture, without the player's own controls.
private struct ProjectPlayerSurface: NSViewRepresentable {
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

/// The title on screen, as it's burned in.
private struct TitleOverlay: View {
    @Bindable var model: ProjectModel

    var body: some View {
        GeometryReader { geometry in
            if let title = model.title(at: model.time) {
                let style = model.project.titleStyle
                SubtitleText(text: style.shown(title.text), style: style, fontSize: style.fontSize(height: geometry.size.height),
                             factor: geometry.size.height / 1080)
                    .frame(maxWidth: geometry.size.width * 0.9)
                    .position(x: style.x * geometry.size.width, y: style.y * geometry.size.height)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The subtitle line at the playhead, as it will be burned in.
private struct ProjectSubtitleOverlay: View {
    @Bindable var model: ProjectModel

    var body: some View {
        GeometryReader { geometry in
            if let line = model.subtitle(at: model.time) {
                let style = model.project.subtitleLook
                SubtitleText(text: style.shown(line.text), style: style, fontSize: style.fontSize(height: geometry.size.height),
                             factor: geometry.size.height / 1080)
                    .frame(maxWidth: geometry.size.width * 0.9)
                    .position(x: style.x * geometry.size.width, y: style.y * geometry.size.height)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TranscriptStore.didSave)) { _ in model.transcriptsChanged() }
    }
}

// MARK: - Toolbar

/// The tools over a project's timeline.
private struct ProjectToolbar: View {
    @Bindable var model: ProjectModel
    @Binding var zoom: Double
    let addMedia: () -> Void
    let addMusic: () -> Void

    var body: some View {
        // With words beside the main tools when there's room, symbols alone when not.
        ViewThatFits(in: .horizontal) {
            row(words: true)
            row(words: false)
        }
        .padding(.horizontal, 4)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(.fill.quaternary))
    }

    private func row(words: Bool) -> some View {
        HStack(spacing: 2) {
            HStack(spacing: 0) {
                tool("cursorarrow", "Selection tool: click a clip to select it, drag to move it (A)", on: model.tool == .select) { model.tool = .select }
                tool("scissors", "Blade tool: click a clip to cut it there (B)", on: model.tool == .blade) { model.tool = .blade }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(.black.opacity(0.25)))
            divider
            tool("square.split.1x2", "Split at the Playhead (⌘B)", words ? "Split" : nil) { model.split(at: model.time) }
            tool("pause.rectangle", "Freeze Frame: hold the frame at the playhead (⇧F)", words ? "Freeze" : nil) { model.freezeFrame() }
                .disabled(model.project.clips.isEmpty)
            tool("bookmark", "Add a Marker at the Playhead (M)", words ? "Marker" : nil) { model.addMarker() }
            tool("trash", "Delete (⌫)") { let chosen = model.selected; model.delete(chosen); model.removeItems(chosen) }
                .disabled(model.selected.isEmpty)
            tool("arrow.uturn.backward", "Undo (⌘Z)") { model.undo() }
                .disabled(!model.canUndo)
            tool("arrow.uturn.forward", "Redo (⇧⌘Z)") { model.redo() }
                .disabled(!model.canRedo)
            divider
            tool("film.stack", "Add Videos…", words ? "Video" : nil) { addMedia() }
            tool("music.note", "Add Music…", words ? "Music" : nil) { addMusic() }
            tool("textformat", "Add a Title at the Playhead (⌘T)", words ? "Title" : nil) { model.addTitle(at: model.time) }
            divider
            tool("point.forward.to.point.capsulepath", "Snapping (N)", on: model.snapping) { model.snapping.toggle() }
            if !model.timelineBeats.isEmpty {
                tool("metronome", "Fit the Cuts to the Beat") { model.fitToBeat() }
                    .disabled(model.project.clips.count < 2)
            }
            Menu {
                Picker("Frame", selection: Binding(get: { model.project.aspect ?? "" }, set: { value in
                    Task { await model.setAspect(value.isEmpty ? nil : value) }
                })) {
                    Text("As the Clips").tag("")
                    Text("Vertical (9:16)").tag("9:16")
                    Text("Square (1:1)").tag("1:1")
                    Text("Portrait (4:5)").tag("4:5")
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "aspectratio")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("The frame’s shape: each clip is filled and framed on its subject")
            tool("camera", "Save the Frame at the Playhead as a Picture", words ? "Still" : nil) { model.saveFrame() }
                .disabled(model.project.clips.isEmpty)
            Spacer(minLength: 4)
            Image(systemName: "minus.magnifyingglass").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { log(zoom) }, set: { zoom = exp($0) }), in: 0...log(max(min(model.duration / 2, 400), 1.01)))
                .controlSize(.mini)
                .frame(minWidth: 50, maxWidth: 110)
                .help("Zoom the timeline (⌘+ and ⌘−)")
                .accessibilityLabel(Text("Zoom"))
            Image(systemName: "plus.magnifyingglass").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var divider: some View { Divider().frame(height: 16).padding(.horizontal, 4) }

    private func tool(_ symbol: String, _ label: LocalizedStringKey, _ title: LocalizedStringKey? = nil, on: Bool = false,
                      action: @escaping () -> Void) -> some View {
        ProjectToolButton(symbol: symbol, label: label, title: title, on: on, action: action)
    }
}

private struct ProjectToolButton: View {
    let symbol: String
    let label: LocalizedStringKey
    /// A word beside the symbol, when there's room.
    var title: LocalizedStringKey?
    let on: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                if let title { Text(title).font(.callout).lineLimit(1).fixedSize() }
            }
                .foregroundStyle(on ? Design.Brand.chosen : AnyShapeStyle(.primary))
                .padding(.horizontal, title == nil ? 0 : 7)
                .frame(minWidth: 30, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: Design.Radius.small)
                    .fill(on ? Design.Brand.chosenFill : AnyShapeStyle(hovering && isEnabled ? Color.primary.opacity(0.08) : .clear)))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}
