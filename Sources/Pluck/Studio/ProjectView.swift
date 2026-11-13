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
    /// The inspector's tab, as saved (also by 3.8.0, whose tabs map onto today's).
    @AppStorage("projectSidebarTab") private var savedTab = ProjectInspector.Tab.clip.rawValue
    private var tab: ProjectInspector.Tab {
        get { ProjectInspector.Tab.saved(savedTab) }
        nonmutating set { savedTab = newValue.rawValue }
    }
    @State private var zoom = 1.0
    @State private var dropTargeted = false
    /// The panel with the project's media and the libraries: shown or not, where, how wide, which tab.
    @AppStorage("studioMediaShown") private var panelShown = true
    @AppStorage("studioMediaWidth") private var panelWidth = Design.Sidebar.width
    @AppStorage("editPanelPosition") private var panelPosition = EditPanelPosition.bottom
    @AppStorage("editLibraryTab") private var libraryTab = EditLibraryTab.media
    /// How tall the timeline's row is without the extra height dragged onto it (for sharing out the room).
    @State private var baseHeight = 230.0
    /// The inspector was just asked for (Export, ⌥⌘S): it stays, even if the picture gets smaller.
    @State private var keepInspector = false
    /// How much taller than its least the timeline is (drag the line above it).
    @AppStorage("editTimelineGrow") private var timelineGrow = 30.0
    @FocusState private var focused: Bool
    @State private var recorder = VoiceOverRecorder()
    @State private var voiceOverShown = false
    @AppStorage("voiceOverMuteTimeline") private var muteTimeline = false
    @AppStorage("projectTextPart") private var textPart = "transcript"

    private func followChoice() {
        let chosen = model.chosen
        tab = ProjectInspector.Tab.following(tab, chosen)
        if chosen == .title { textPart = "titles" }
    }

    var body: some View {
        GeometryReader { page in
            let fit = EditLayout.fit(page: page.size, position: panelPosition, panelWidth: panelWidth, inspectorWidth: sidebarWidth,
                                     timelineHeight: baseHeight + timelineGrow + Self.transportHeight, panelShown: panelShown,
                                     inspectorShown: sidebarShown, keepInspector: keepInspector)
            // The extra height the timeline keeps (it gives some up when the picture needs it).
            let grow = max(0, timelineGrow - (baseHeight + timelineGrow + Self.transportHeight - fit.timeline))
            switch panelPosition {
            case .bottom:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        viewer
                        if fit.inspectorShown { inspector }
                    }
                    HeightHandle(grow: $timelineGrow, range: 0...360)
                    // The row is as tall as the timeline needs; the panel beside it takes that height.
                    HStack(alignment: .top, spacing: 0) {
                        if fit.panelShown { sidePanel }
                        timelineColumn(grow: grow)
                    }
                    .frame(height: baseHeight + grow)
                }
            case .top:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        if fit.panelShown { sidePanel }
                        viewer
                        if fit.inspectorShown { inspector }
                    }
                    HeightHandle(grow: $timelineGrow, range: 0...360)
                    timelineColumn(grow: grow)
                }
            case .fullHeight:
                HStack(spacing: 0) {
                    if fit.panelShown { sidePanel }
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            viewer
                            if fit.inspectorShown { inspector }
                        }
                        HeightHandle(grow: $timelineGrow, range: 0...360)
                        timelineColumn(grow: grow)
                    }
                }
            }
        }
        // Side panels give way before the picture gets small (EditLayout), so this fits the smallest window.
        .frame(minWidth: 460, minHeight: 520)
        .toolbar {
            // The edit going out: to DaVinci Resolve, or exported.
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                    .help("Undo (⌘Z)")
                Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!model.canRedo)
                    .help("Redo (⇧⌘Z)")
                if ProjectResolve.isAvailable {
                    let label = Group {
                        if model.sendingToResolve {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Send to DaVinci", systemImage: "arrow.up.forward.app")
                        }
                    }
                    if model.project.resolveTimeline != nil {
                        // Sent before: the edit can come back from that timeline too.
                        Menu {
                            Button("Update from DaVinci") { ProjectResolve.updateAndShow(model) }
                        } label: {
                            label
                        } primaryAction: {
                            ProjectResolve.sendAndShow(model)
                        }
                        .disabled(model.sendingToResolve)
                        .help("Send to DaVinci Resolve as a new timeline; or bring back the markers, order and trims from the timeline it was sent to")
                    } else {
                        Button { ProjectResolve.sendAndShow(model) } label: { label }
                            .disabled(model.project.clips.isEmpty || model.sendingToResolve)
                            .help("Send to DaVinci Resolve: a new timeline in the project open there, with the subtitles (files already there aren’t imported again)")
                    }
                }
                Button {
                    withAnimation(.snappy) { tab = .export; sidebarShown = true; keepInspector = true }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .medium))
                        Text("Export")
                    }
                    .font(Design.Studio.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(Design.Brand.deep, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.project.clips.isEmpty)
                .keyboardShortcut("e", modifiers: .command)
                .help("Export (⌘E)")
            }.studioFlat()
            // ⌥⌘S still shows or hides the inspector (no button: the reference's title bar has none).
            ToolbarItem {
                Button("") { withAnimation(.snappy) { sidebarShown.toggle(); keepInspector = sidebarShown } }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .opacity(0)
                    .frame(width: 0)
                    .accessibilityHidden(true)
            }.studioFlat()
        }
        .navigationTitle("")
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: key)
        // A title chosen on the timeline opens its words (Text), a look its colour (Colour).
        .onChange(of: model.selected) { followChoice() }
        .onChange(of: model.selectedTitle) { followChoice() }
        .onAppear {
            focused = true
            // The media panel beside it hands on the keys that put its media in (it keeps the focus).
            Self.forward = key
            // The Scopes window follows what's on screen.
            ScopeHub.shared.follow(model.player, name: model.project.name)
        }
        .onChange(of: ObjectIdentifier(model)) { ScopeHub.shared.follow(model.player, name: model.project.name) }
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
            // Screenshots: -PluckScreenshotVoiceOver bar|countdown|recording shows the bar in that
            // state (the microphone stays off).
            if ScreenshotMode.scene == "project", let state = UserDefaults.standard.string(forKey: "PluckScreenshotVoiceOver") {
                try? await Task.sleep(for: .seconds(3))
                voiceOverShown = true
                recorder.refreshInputs()
                recorder.level = 0.6
                recorder.startedAt = Date().addingTimeInterval(-12)
                if state == "countdown" { recorder.state = .countingDown(2) }
                if state == "recording" { recorder.state = .recording(since: 0) }
                if state == "denied" { recorder.state = .failed(String(localized: "Microphone is off for Pluck. Allow it in System Settings ▸ Privacy & Security ▸ Microphone.")) }
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
            // Tests: -PluckScreenshotSelectClip YES selects the first clip (its inspector shown).
            if ScreenshotMode.scene == "project", UserDefaults.standard.bool(forKey: "PluckScreenshotSelectClip") {
                try? await Task.sleep(for: .seconds(4))
                if let first = model.project.clips.first { model.selected = [first.id] }
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

    // MARK: - Parts of the page

    /// The transport and the space around the picture, counted with the timeline's row.
    private static let transportHeight = 90.0

    /// The picture (a 16:9 area, as large as fits) and the transport under it.
    private var viewer: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "\(model.project.name) · \(Self.rate(model.frameRate)) fps · ")
                    + Text("^[\(model.project.clips.count) clip](inflect: true)")
            }
            .font(Design.Studio.body)
            .foregroundStyle(Design.Studio.textQuiet)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 34)
            picture
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                .padding(.horizontal, 8)
            transport
                .padding(.horizontal, 14)
                .frame(height: 48)
            if voiceOverShown || recorder.isActive {
                VoiceOverBar(recorder: recorder, model: model, muteTimeline: $muteTimeline) {
                    withAnimation(.snappy) { voiceOverShown = false }
                    recorder.state = .idle
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Design.Studio.panel, in: Self.panel)
        .clipShape(Self.panel)
    }

    /// "25", "23.976", "29.97".
    private static func rate(_ fps: Double) -> String {
        fps.rounded() == fps ? String(Int(fps)) : String(format: "%.3g", fps)
    }

    private static let panel = RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous)

    private var inspector: some View {
        HStack(spacing: 0) {
            ResizeHandle(width: $sidebarWidth, range: 280...560, edge: .trailing)
            ProjectInspector(model: model, tab: Binding(get: { tab }, set: { tab = $0 }))
                .frame(width: sidebarWidth)
                .background(Design.Studio.panel, in: Self.panel)
                .clipShape(Self.panel)
        }
    }

    private var sidePanel: some View {
        HStack(spacing: 0) {
            EditSidePanel(model: model, tab: $libraryTab, position: $panelPosition)
                .frame(width: panelWidth)
                .background(Design.Studio.panel, in: Self.panel)
                .clipShape(Self.panel)
            ResizeHandle(width: $panelWidth, range: Design.Sidebar.widthRange, edge: .leading)
        }
        .transition(.move(edge: .leading))
    }

    private func timelineColumn(grow: Double) -> some View {
        VStack(spacing: Design.Spacing.controls) {
            VStack(spacing: 4) {
                ProjectToolbar(model: model, zoom: $zoom, addMedia: addMedia, addMusic: addMusic)
                ProjectTimeline(model: model, zoom: $zoom, grow: grow)
            }
            .simultaneousGesture(TapGesture().onEnded { focused = true })
            // Only when something needs doing (a save that failed, files offline).
            if model.saveProblem != nil || !model.missing.isEmpty { footer }
        }
        .padding(.horizontal, Design.Spacing.inset)
        .padding(.top, Design.Spacing.controls)
        .padding(.bottom, Design.Spacing.inset)
        .background(Design.Studio.panel, in: Self.panel)
        .clipShape(Self.panel)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: Double.self) { $0.size.height } action: { baseHeight = max($0 - grow, 0) }
    }

    // MARK: - Picture

    private var picture: some View {
        ZStack {
            Color.clear
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
        HStack(spacing: 6) {
            Text(model.timecode(model.time, full: true))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .frame(width: 120, alignment: .leading)
                .help("The playhead; the edit is \(Format.duration(model.duration)) long")
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                transportButton("backward.frame.fill", "Back one frame (←). Home: to the start") { model.step(frames: -1) }
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Design.Studio.text)
                        .frame(width: 36, height: 32)
                        .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Play or pause (Space)")
                .disabled(recorder.isActive)
                transportButton("forward.frame.fill", "Forward one frame (→). End: to the end") { model.step(frames: 1) }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button {
                    if recorder.isActive { Task { await recorder.stop() } } else { withAnimation(.snappy) { voiceOverShown.toggle() } }
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(recorder.isActive || voiceOverShown ? Design.Brand.pink : Design.Studio.textQuiet)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Record a voice-over")
            }
            .frame(width: 120, alignment: .trailing)
        }
    }

    private func transportButton(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Design.Studio.text)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text(help))
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

    /// The shown project's keys, for the media panel.
    @MainActor static var forward: ((KeyPress) -> KeyPress.Result)?

    private func key(_ press: KeyPress) -> KeyPress.Result {
        if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
        // Recording: Space or Esc ends the take, nothing else plays the timeline.
        if recorder.isActive {
            if press.key == .space || press.key == .escape { Task { await recorder.stop() } }
            return .handled
        }
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
        // ⌥← and ⌥→ nudge the selected items, songs and titles a frame (⇧: five frames). With none
        // of those selected, the arrows step the playhead as before.
        if option, !command, press.key == .leftArrow || press.key == .rightArrow {
            let frames = (press.key == .leftArrow ? -1 : 1) * (shift ? 5 : 1)
            let ids = model.selected.union(model.selectedTitle.map { [$0] } ?? [])
            if model.nudge(ids, frames: frames) { return .handled }
        }
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
            // Clips, items on the tracks (titles too), looks, songs or a plain title, whichever is selected.
            model.deleteSelection()
        default:
            switch Shortcuts.shared.action(for: press, in: .edit) {
            case .editSplit: model.split(at: model.time)
            case .editBlade: model.tool = .blade
            case .editSelect: model.tool = .select
            case .editTrim: model.tool = .trim
            case .editAppend, .editInsert, .editOverwrite, .editPlaceOnTop, .editReplace:
                // From what's chosen in the media panel.
                guard let source = MediaSelection.shared.source else { NSSound.beep(); return .handled }
                let action = Shortcuts.shared.action(for: press, in: .edit)
                Task {
                    switch action {
                    case .editAppend: await model.append(source)
                    case .editInsert: await model.insert(source)
                    case .editOverwrite: await model.overwrite(source)
                    case .editPlaceOnTop: await model.placeOnTop(source)
                    default: await model.replace(source)
                    }
                }
            case .editTrimStart: model.trimStartToPlayhead()
            case .editTrimEnd: model.trimEndToPlayhead()
            case .editDuplicate: model.duplicate(model.selected)
            case .editRedo: model.redo()
            case .editUndo: model.undo()
            case .editSnapping: model.snapping.toggle()
            case .editPanelPosition: withAnimation(.snappy) { panelPosition = panelPosition.next; panelShown = true }
            case .editLibraryNext: withAnimation(.snappy) { libraryTab = libraryTab.next; panelShown = true }
            case .editTitle: model.addTitle(at: model.time)
            case .editMarkIn: model.markIn()
            case .editMarkOut: model.markOut()
            case .editMarker: model.addMarker()
            case .editFavourite: if !MediaFavourites.shared.toggleCurrent(in: model) { return .ignored }
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
    @AppStorage("projectPacing") private var pacing = false
    @AppStorage("projectPacingLong") private var pacingLong = 8.0
    @AppStorage("projectPacingShort") private var pacingShort = 10
    @State private var marksShown = false

    var body: some View {
        // Narrow (the smallest window with the media beside): icons only, without the length and zoom.
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .frame(height: 38)
    }

    /// As in the layout reference: the tools, then the edits at the playhead, then Add, Marks and Pacing;
    /// the length and the zoom on the right.
    private func row(compact: Bool) -> some View {
        HStack(spacing: 2) {
            tool("cursorarrow", "Selection tool: click a clip to select it, drag to move it (A)", on: model.tool == .select) { model.tool = .select }
            tool("scissors", "Blade tool: click a clip to cut it there (B)", on: model.tool == .blade) { model.tool = .blade }
            tool("arrow.left.and.line.vertical.and.arrow.right", "Trim tool: drag a cut to move it between two clips, or the middle of a clip to show another part of it (T)",
                 on: model.tool == .trim) { model.tool = .trim }
            tool("point.forward.to.point.capsulepath", "Snapping (N)", on: model.snapping) { model.snapping.toggle() }
            divider
            tool("square.split.1x2", "Split at the Playhead (⌘B)") { model.split(at: model.time) }
            tool("pause.rectangle", "Freeze Frame: hold the frame at the playhead (⇧F)") { model.freezeFrame() }
                .disabled(model.project.clips.isEmpty)
            tool("bookmark", "Add a Marker at the Playhead (M)") { model.addMarker() }
            tool("trash", "Delete (⌫)") { model.deleteSelection() }
                .disabled(model.selected.isEmpty && model.selectedTitle == nil)
            divider
            Menu {
                Button("Videos…", systemImage: "film.stack") { addMedia() }
                Button("Music…", systemImage: "music.note") { addMusic() }
                Button("Title at the Playhead (⌘T)", systemImage: "textformat") { model.addTitle(at: model.time) }
                Button("Look", systemImage: "camera.filters") { model.addAdjustmentHere() }
                    .help("A look over the clips chosen, between in and out, or for 5 s from the playhead")
                Divider()
                Button("Still: Save the Frame as a Picture", systemImage: "camera") { model.saveFrame() }
                    .disabled(model.project.clips.isEmpty)
            } label: {
                textLabel("plus", "Add", menu: true, compact: compact)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add videos, music, a title, a look, or save a still")
            Button { marksShown.toggle() } label: { textLabel("bookmark", "Marks", on: marksShown, compact: compact) }
                .buttonStyle(.plain)
                .help("Markers: the list, and what was found in the clip (M adds one)")
                .popover(isPresented: $marksShown, arrowEdge: .bottom) {
                    ProjectMarksPanel(model: model)
                        .frame(width: 320, height: 420)
                        .padding(.top, 12)
                }
            // Right-click for the two thresholds.
            Button { pacing.toggle() } label: { textLabel("gauge.with.dots.needle.33percent", "Pacing", on: pacing, compact: compact) }
                .buttonStyle(.plain)
                .help("Show long shots, very short clips and jump cuts (right-click for the thresholds)")
                .contextMenu {
                    Picker("Long shot after", selection: $pacingLong) {
                        ForEach([4.0, 6, 8, 10, 12, 15, 20], id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    Picker("Short clip under", selection: $pacingShort) {
                        ForEach([4, 6, 8, 10, 12, 16, 24], id: \.self) { Text("\($0) frames").tag($0) }
                    }
                }
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
                Image(systemName: "aspectratio").font(.system(size: 13, weight: .medium)).foregroundStyle(Design.Studio.textQuiet)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("The frame’s shape: each clip is filled and framed on its subject")
            Spacer(minLength: 8)
            if !compact {
                Text("\(Format.duration(model.duration)) total").font(Design.Studio.body.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
                    .padding(.trailing, 8)
                    .lineLimit(1)
                Image(systemName: "minus.magnifyingglass").font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet)
                StudioSlider(value: Binding(get: { log(zoom) }, set: { zoom = exp($0) }), range: 0...log(max(min(model.duration / 2, 400), 1.01)), label: "Zoom")
                    .frame(width: 96)
                    .help("Zoom the timeline (⌘+ and ⌘−)")
                Image(systemName: "plus.magnifyingglass").font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet)
            }
        }
    }

    /// A raised text button of the bar ("Add ⌄", "Marks"); plum when it's on.
    private func textLabel(_ symbol: String, _ title: LocalizedStringKey, on: Bool = false, menu: Bool = false, compact: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            if !compact { Text(title) }
            if menu { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet) }
        }
        .font(Design.Studio.body)
        .foregroundStyle(on ? Design.Brand.pink : Design.Studio.text)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
        .contentShape(.rect)
        .accessibilityLabel(Text(title))
    }

    private var divider: some View { Rectangle().fill(Design.Studio.line).frame(width: 1, height: 18).padding(.horizontal, 6) }

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
                .foregroundStyle(on ? Design.Studio.text : Design.Studio.textQuiet)
                .padding(.horizontal, title == nil ? 0 : 7)
                .frame(minWidth: 28, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: Design.Studio.controlRadius, style: .continuous)
                    .fill(on ? AnyShapeStyle(Design.Studio.raised) : AnyShapeStyle(hovering && isEnabled ? Design.Studio.raised.opacity(0.6) : .clear)))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}
