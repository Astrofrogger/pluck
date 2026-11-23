import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Social Cutdowns' page: the edit with each format's crop on it, the three formats side by side,
/// the shots underneath (flagged where text or a logo gets cut), and the shot's own settings.
struct SocialCutdownsView: View {
    typealias Format = SocialCutdowns.Format
    @Environment(AIStudio.self) private var studio
    /// A video to open when the page appears (screenshot mode).
    @MainActor static var openFile: URL?
    /// Shows the Captions settings on the page once the edit is in (screenshot mode: a popover isn't in an off-screen picture).
    @MainActor static var showCaptionsOnOpen = false
    @State private var captionsInline = false

    @State private var session = CutdownSession.shared
    // The work lives in the shared session (it outlasts the page); these read and write it.
    private var source: URL? { get { session.source } nonmutating set { session.source = newValue } }
    private var analysis: SocialCutdowns.Analysis? { get { session.analysis } nonmutating set { session.analysis = newValue } }
    private var plans: [Format: [SocialCutdowns.ShotPlan]] { get { session.plans } nonmutating set { session.plans = newValue } }
    private var edits: [Double: SocialCutdowns.ShotEdit] { get { session.edits } nonmutating set { session.edits = newValue } }
    private var status: String? { get { session.status } nonmutating set { session.status = newValue } }
    private var share: Double? { get { session.share } nonmutating set { session.share = newValue } }
    private var problem: String? { get { session.problem } nonmutating set { session.problem = newValue } }
    private var player: AVPlayer { session.player }
    private var time: Double { get { session.time } nonmutating set { session.time = newValue } }
    @State private var playing = false
    @State private var editing: Format = .vertical
    @State private var picking = false
    @State private var dragStart: Double?
    @State private var dropping = false
    @State private var width: CGFloat = 1000
    @State private var showCaptions = false
    @State private var design = CaptionDesign.load(CaptionDesign.shortsKey)
    private var cues: [Transcript.Cue]? { get { session.cues } nonmutating set { session.cues = newValue } }
    private var folder: URL? { get { session.folder } nonmutating set { session.folder = newValue } }
    @State private var queue = CutdownQueue.shared
    private var task: Task<Void, Never>? { get { session.task } nonmutating set { session.task = newValue } }
    @AppStorage("cutdownsLeftOut") private var leftOut = ""
    @AppStorage("cutdownsCaptions") private var captionsOn = false
    @AppStorage("cutdownsPlatform") private var platform: SocialCutdowns.Platform = .tiktok
    @AppStorage("cutdownsBrand") private var brandID = ""
    @AppStorage("cutdownsReplaceLogo") private var replaceLogo = false
    @AppStorage("cutdownsProRes") private var proRes = false
    @Environment(DownloadManager.self) private var manager

    private var brand: BrandProfile? { BrandProfiles.shared.profile(UUID(uuidString: brandID)) }
    private var chosen: [Format] { SocialCutdowns.formats.filter { !leftOut.split(separator: ",").contains(Substring($0.rawValue)) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if captionsInline {
                captionSettings.studioBox()
            } else if let analysis {
                editor(analysis)
            } else if status == nil {
                StudioEmptyState(symbol: "rectangle.portrait.on.rectangle.portrait", title: "Drop a finished edit here",
                                 line: "9:16, 1:1 and 4:5 versions that follow the subject.",
                                 targeted: dropping, button: "Choose Video…", action: choose)
                    .studioDropZone(targeted: dropping)
                    .onTapGesture(perform: choose)
            }
            if let status { statusRow(Text(session.item?.aiStatus ?? status)) }
            if let problem {
                HStack(spacing: 12) {
                    StudioTile(symbol: "exclamationmark.triangle", colour: Design.Studio.bad, size: 32)
                    Text(problem).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                    Spacer()
                    Button { self.problem = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet)
                        .accessibilityLabel(Text("Close"))
                }
            }
            if !queue.jobs.isEmpty { queueList }
            if analysis == nil { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .studioPanel()
        .onAppear { if let url = Self.openFile { Self.openFile = nil; open(url) } }
        .onChange(of: analysis != nil) { if analysis != nil, Self.showCaptionsOnOpen { Self.showCaptionsOnOpen = false; captionsInline = true; _ = fileItem() } }
        .onDisappear { player.pause() }
        .onChange(of: edits) { replan(); session.saveSoon() }
        .onChange(of: replaceLogo) { replan() }
        .onChange(of: brandID) { findLogo() }
        .onChange(of: design) { design.save(CaptionDesign.shortsKey) }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                guard let url = await providers.first?.load(URL.self),
                      let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) else { return }
                open(url)
            }
            return true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if let source {
                StudioChip(text: Text(verbatim: source.lastPathComponent), symbol: "film")
                Button("Change…", action: choose).buttonStyle(StudioFlatButtonStyle())
            }
            Spacer()
            if analysis != nil {
                Menu {
                    Button("No brand") { brandID = "" }
                    ForEach(BrandProfiles.shared.all) { profile in
                        Button(profile.name) { brandID = profile.id.uuidString }
                    }
                    if brand != nil {
                        Divider()
                        Toggle("Move the logo to the brand’s place", isOn: $replaceLogo)
                    }
                } label: {
                    StudioMenuLabel(title: brand?.name ?? String(localized: "No brand"))
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()

                Button { showCaptions = true } label: {
                    Label("Captions", systemImage: captionsOn ? "captions.bubble.fill" : "captions.bubble")
                }
                .buttonStyle(StudioFlatButtonStyle())
                .popover(isPresented: $showCaptions, arrowEdge: .bottom) { captionSettings }

                Menu {
                    Picker("Overlay", selection: $platform) {
                        ForEach(SocialCutdowns.Platform.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    StudioMenuLabel(title: platform.label)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()

                Menu {
                    Button("Next to the edit") { folder = nil }
                    Button("Choose Folder…", action: chooseFolder)
                } label: {
                    StudioMenuLabel(title: folder?.lastPathComponent ?? String(localized: "Next to the edit"))
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()

                // Finishing choices, kept out of the way of Render.
                Menu {
                    Picker("Format", selection: $proRes) {
                        Text(verbatim: "H.264").tag(false)
                        Text(verbatim: "ProRes 422 HQ").tag(true)
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Send to DaVinci Resolve", action: sendToResolve)
                        .disabled(chosen.isEmpty || task != nil)
                        .help(Text("A timeline per format, the reframe as keyframes"))
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(Design.Studio.textQuiet)
                        .frame(width: 28, height: 28).contentShape(.rect)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel(Text("More"))

                Button("Render", action: render)
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .disabled(chosen.isEmpty || task != nil)
            }
        }
        .studioToolTitle("Social Cutdowns")
    }

    private var captionSettings: some View {
        Form {
            Toggle("Burn in captions", isOn: $captionsOn).disabled(!LocalAI.canTranscribe)
            if captionsOn, LocalAI.canTranscribe, let item = session.item {
                SpokenLanguagePicker(item: item, languages: $session.languages, language: Binding(get: { session.language }, set: { new in
                    // Captions in another language: transcribed again when rendering.
                    if session.language != nil, new != session.language { cues = nil; session.transcriptID = nil }
                    session.language = new
                    session.saveSoon()
                }))
            }
            if captionsOn { CaptionDesignEditor(design: $design, forShorts: false) }
            if !LocalAI.canTranscribe {
                Text("Captions need Apple Intelligence’s speech recognition on this Mac.").font(.caption).foregroundStyle(.secondary)
            } else if brand != nil {
                Text("In the brand’s font and colour.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { if captionsOn { _ = fileItem() } }
        .onChange(of: captionsOn) { if captionsOn { _ = fileItem() } }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Editor

    private func editor(_ analysis: SocialCutdowns.Analysis) -> some View {
        let aspect = Double(analysis.width) / Double(analysis.height)
        let units = aspect + SocialCutdowns.formats.reduce(0) { $0 + $1.aspect }
        let height = max(160, min(360, (width - 56 - 12 * 3) / units))
        let shot = analysis.shot(at: time)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                sourceView(analysis, shot: shot, size: CGSize(width: height * aspect, height: height))
                ForEach(SocialCutdowns.formats, id: \.self) { format in
                    preview(format, analysis, height: height)
                }
            }
            transport(analysis)
            timeline(analysis, current: shot)
            if let shot { inspector(analysis, shot: shot) }
        }
    }

    private func plan(_ format: Format, at t: Double) -> SocialCutdowns.ShotPlan? {
        plans[format].flatMap { SocialCutdowns.centre($0, at: t) }
    }

    private func sourceView(_ analysis: SocialCutdowns.Analysis, shot: SocialCutdowns.Shot?, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            CutdownPlayerLayer(player: player)
            // What has to stay in: text and the logo.
            ForEach(Array(((shot?.graphics ?? []) + (analysis.logo.map { [$0] } ?? [])).enumerated()), id: \.offset) { _, rect in
                Rectangle()
                    .strokeBorder(Design.Studio.warn, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: rect.width * size.width, height: rect.height * size.height)
                    .offset(x: rect.minX * size.width, y: rect.minY * size.height)
                    .allowsHitTesting(false)
            }
            ForEach(chosen, id: \.self) { format in
                if let plan = plan(format, at: time), plan.framing == .follow {
                    cropBox(format, analysis: analysis, plan: plan, size: size)
                }
            }
            if picking {
                Text("Click the subject").font(Design.Studio.hint).foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(height: 22).background(.black.opacity(0.6), in: .capsule)
                    .padding(8).allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(coordinateSpace: .local) { point in
            guard picking, let shot else { return }
            pick(CGPoint(x: point.x / size.width, y: point.y / size.height), in: shot, analysis: analysis)
        }
    }

    /// One format's crop on the source: plum and draggable when it's the one being edited.
    private func cropBox(_ format: Format, analysis: SocialCutdowns.Analysis, plan: SocialCutdowns.ShotPlan, size: CGSize) -> some View {
        let f = SocialCutdowns.cropFraction(width: analysis.width, height: analysis.height, format: format)
        let centre = plan.centre(at: time)
        let selected = format == editing
        return Rectangle()
            .strokeBorder(selected ? AnyShapeStyle(Design.Brand.pink) : AnyShapeStyle(Color.white.opacity(0.45)), lineWidth: selected ? 2 : 1)
            .contentShape(.rect)
            .frame(width: f * size.width, height: size.height)
            .offset(x: (centre - f / 2) * size.width)
            .allowsHitTesting(selected && !picking)
            .gesture(DragGesture().onChanged { drag in
                guard let shot = analysis.shot(at: time) else { return }
                let start = dragStart ?? centre
                dragStart = start
                edits[shot.start, default: .init()].locks[format] = min(max(start + drag.translation.width / size.width, f / 2), 1 - f / 2)
            }.onEnded { _ in dragStart = nil })
    }

    private func preview(_ format: Format, _ analysis: SocialCutdowns.Analysis, height: CGFloat) -> some View {
        let box = CGSize(width: height * format.aspect, height: height)
        let full = height * Double(analysis.width) / Double(analysis.height)
        let f = SocialCutdowns.cropFraction(width: analysis.width, height: analysis.height, format: format)
        let plan = plan(format, at: time)
        let included = chosen.contains(format)
        let safe = SocialCutdowns.safeArea(format)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                (plan?.framing == .bars ? Color.black : Design.Studio.raised)
                if plan?.framing ?? .follow == .follow {
                    CutdownPlayerLayer(player: player)
                        .frame(width: full, height: height)
                        .offset(x: -((plan?.centre(at: time) ?? 0.5) - f / 2) * full)
                } else {
                    CutdownPlayerLayer(player: player)
                        .frame(width: box.width, height: box.width * Double(analysis.height) / Double(analysis.width))
                        .frame(width: box.width, height: box.height)
                }
                if format == .vertical {
                    ForEach(Array(platform.zones.enumerated()), id: \.offset) { _, zone in
                        Rectangle().fill(.white.opacity(0.12))
                            .frame(width: zone.width * box.width, height: zone.height * box.height)
                            .offset(x: zone.minX * box.width, y: zone.minY * box.height)
                    }
                }
                Rectangle()
                    .strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: safe.width * box.width, height: safe.height * box.height)
                    .offset(x: safe.minX * box.width, y: safe.minY * box.height)
            }
            .frame(width: box.width, height: box.height, alignment: .topLeading)
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(format == editing ? AnyShapeStyle(Design.Brand.pink) : AnyShapeStyle(Color.clear), lineWidth: 2)
            }
            .opacity(included ? 1 : 0.35)
            .contentShape(.rect)
            .onTapGesture { editing = format }
            .allowsHitTesting(!picking)

            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { included }, set: { include(format, $0) })) { EmptyView() }
                    .toggleStyle(StudioSwitchStyle()).labelsHidden()
                Text(verbatim: format.tag.replacingOccurrences(of: "x", with: ":"))
                    .font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                Spacer(minLength: 0)
                if plan?.flagged == true {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Design.Studio.warn)
                        .help(Text("Text or a logo is cut off here"))
                }
            }
            .frame(width: box.width)
        }
    }

    private func transport(_ analysis: SocialCutdowns.Analysis) -> some View {
        HStack(spacing: 10) {
            Button {
                if playing { player.pause() } else { player.play() }
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .buttonStyle(StudioFlatButtonStyle())
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(playing ? Text("Pause") : Text("Play"))
            Text(verbatim: "\(Pluck.Format.duration(time)) / \(Pluck.Format.duration(analysis.duration))")
                .font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
            Spacer()
        }
    }

    /// The shots as blocks across the edit's length; drag or click to move the playhead.
    private func timeline(_ analysis: SocialCutdowns.Analysis, current: SocialCutdowns.Shot?) -> some View {
        GeometryReader { geometry in
            let k = geometry.size.width / max(analysis.duration, 0.001)
            ZStack(alignment: .topLeading) {
                ForEach(analysis.shots) { shot in
                    let plan = plans[editing]?.first { $0.start == shot.start }
                    let edited = edits[shot.start] != nil
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(shot == current ? Design.Studio.line : Design.Studio.raised)
                        .overlay(alignment: .leading) {
                            HStack(spacing: 3) {
                                if plan?.flagged == true { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Design.Studio.warn) }
                                if plan?.locked == true { Image(systemName: "lock.fill") }
                                if let framing = plan?.framing, framing != .follow { Image(systemName: "rectangle.center.inset.filled") }
                                if edited, plan?.locked != true { Image(systemName: "scope") }
                            }
                            .font(.system(size: 9)).foregroundStyle(Design.Studio.textQuiet).padding(.leading, 5)
                        }
                        .clipped()
                        .frame(width: max((shot.end - shot.start) * k - 2, 1), height: 30)
                        .offset(x: shot.start * k)
                }
                Rectangle().fill(Design.Brand.pink).frame(width: 2, height: 38).offset(x: time * k - 1, y: -4)
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                seek(min(max(drag.location.x / k, 0), analysis.duration - 0.01))
            })
        }
        .frame(height: 30)
        .padding(.vertical, 4)
    }

    private func inspector(_ analysis: SocialCutdowns.Analysis, shot: SocialCutdowns.Shot) -> some View {
        let plan = plans[editing]?.first { $0.start == shot.start }
        let number = (analysis.shots.firstIndex(of: shot) ?? 0) + 1
        return HStack(spacing: 10) {
            Text("Shot \(number) of \(analysis.shots.count)").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            StudioChip(text: Text(verbatim: editing.tag.replacingOccurrences(of: "x", with: ":")))
            Picker("Framing", selection: Binding(
                get: { plan?.framing ?? .follow },
                set: { edits[shot.start, default: .init()].framing[editing] = $0 })) {
                ForEach(SocialCutdowns.Framing.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button {
                if plan?.locked == true {
                    edits[shot.start, default: .init()].locks[editing] = nil
                } else {
                    edits[shot.start, default: .init()].locks[editing] = plan?.centre(at: time) ?? 0.5
                }
            } label: {
                Label(plan?.locked == true ? "Unlock" : "Lock", systemImage: plan?.locked == true ? "lock.open" : "lock")
            }
            .buttonStyle(StudioFlatButtonStyle())
            Button { picking.toggle() } label: { Label("Pick Subject", systemImage: "scope") }
                .buttonStyle(StudioFlatButtonStyle(prominent: picking))
            if edits[shot.start] != nil {
                Button { edits[shot.start] = nil } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(StudioFlatButtonStyle())
                    .help(Text("Back to automatic"))
                    .accessibilityLabel(Text("Back to automatic"))
            }
            Spacer()
            if plan?.flagged == true {
                Label("Text or a logo is cut off", systemImage: "exclamationmark.triangle.fill")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
            }
        }
    }

    // MARK: - Queue

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Renders").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                Spacer()
                if queue.busy {
                    Button("Stop") { queue.stop() }.buttonStyle(StudioFlatButtonStyle())
                } else {
                    Button("Clear") { queue.clearFinished() }.buttonStyle(StudioFlatButtonStyle())
                }
            }
            ForEach(queue.jobs) { job in
                HStack(spacing: 12) {
                    switch job.state {
                    case .waiting: StudioTile(symbol: "clock", colour: Design.Studio.textQuiet, size: 28)
                    case .running: PlumSpinner().frame(width: 28)
                    case .done: StudioTile(symbol: "checkmark", colour: Design.Studio.good, size: 28)
                    case .failed: StudioTile(symbol: "exclamationmark.triangle", colour: Design.Studio.bad, size: 28)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: job.name).font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                        switch job.state {
                        case .running(let share): StudioProgress(share: share)
                        case .failed(let message): Text(message).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(2)
                        default: EmptyView()
                        }
                    }
                    Spacer()
                    if case .done(let url) = job.state {
                        Button("Check") { check(url) }
                            .buttonStyle(StudioFlatButtonStyle())
                            .help(Text("Open in Delivery Check"))
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                            .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet)
                            .help(Text("Show in Finder")).accessibilityLabel(Text("Show in Finder"))
                    }
                }
                .padding(10)
                .studioBox()
            }
        }
    }

    private func statusRow(_ text: Text) -> some View {
        HStack(spacing: 12) {
            PlumSpinner()
            text.font(Design.Studio.body).foregroundStyle(Design.Studio.text)
            if let share { StudioProgress(share: share).frame(maxWidth: 240) }
            Spacer()
        }
        .padding(12)
        .studioBox()
    }

    // MARK: - Actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
    }

    private func open(_ url: URL) {
        // The same edit again (coming back to the page): keep what's there.
        if url == source, analysis != nil || task != nil { return }
        task?.cancel()
        source = url
        analysis = nil
        plans = [:]
        edits = [:]
        cues = nil
        session.transcriptID = nil
        session.item = nil
        session.languages = []
        session.language = nil
        problem = nil
        player.pause()
        playing = false
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if session.observer == nil {
            session.observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in
                MainActor.assumeIsolated { CutdownSession.shared.time = t.seconds.isFinite ? t.seconds : 0 }
            }
        }
        // Worked on before (and unchanged since): back as it was left.
        if let saved = SocialCutdowns.Saved.load(url) {
            analysis = saved.analysis
            edits = saved.edits
            session.language = saved.language.map(Locale.init(identifier:))
            if let id = saved.transcriptID, let transcript = TranscriptStore.load(id), transcript.filePath == url.path {
                session.transcriptID = id
                cues = transcript.cues()
            }
            replan()
            return
        }
        let ffmpeg = studio.toolPath("ffmpeg"), brand = brand
        task = Task {
            status = String(localized: "Looking at every shot…")
            share = 0
            do {
                let result = try await SocialCutdowns.analyse(url, ffmpeg: ffmpeg, brand: brand) { value in
                    Task { @MainActor in CutdownSession.shared.share = value }
                }
                guard !Task.isCancelled else { return }
                analysis = result
                replan()
                session.saveSoon()
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
            }
            // A cancelled (replaced) run mustn't clear the new run's state.
            guard !Task.isCancelled else { return }
            status = nil
            share = nil
            task = nil
        }
    }

    /// This edit as an item in Pluck's list (the transcript is kept with it).
    private func fileItem() -> DownloadItem? {
        if let item = session.item { return item }
        guard let source else { return nil }
        let found = manager.items.first { $0.existingFile?.path == source.path } ?? manager.addLocalFiles([source]).first
        session.item = found
        return found
    }

    private func sendToResolve() {
        guard let analysis else { return }
        let formats = chosen, plans = plans
        let out = folder ?? analysis.file.deletingLastPathComponent()
        task = Task {
            status = String(localized: "Building the timeline in DaVinci Resolve…")
            do {
                let names = try await SocialCutdowns.sendToResolve(analysis, plans: plans, formats: formats, folder: out)
                if names.isEmpty { problem = String(localized: "DaVinci Resolve couldn’t import the file.") }
            } catch {
                problem = error.localizedDescription
            }
            status = nil
            task = nil
        }
    }

    private func check(_ url: URL) {
        DeliveryCheckView.openFile = url
        NotificationCenter.default.post(name: DeliveryCheckView.openNotification, object: url)
        StudioNavigator.shared.open(windowID: "deliveryCheck")
    }

    private func replan() {
        guard let analysis else { return }
        let hideLogo = replaceLogo && analysis.logo != nil
        for format in SocialCutdowns.formats {
            let placed = hideLogo && brand.flatMap { SocialCutdowns.logoPlacement($0, format: format) } != nil
            plans[format] = SocialCutdowns.plan(analysis, format: format, edits: edits, ignoreLogo: placed)
        }
    }

    private func findLogo() {
        guard let file = analysis?.file, let duration = analysis?.duration else { return }
        let brand = brand
        Task {
            let logo = await SocialCutdowns.findLogo(brand, in: file, duration: duration)
            guard analysis?.file == file else { return }
            analysis?.logo = logo
            replan()
        }
    }

    private func seek(_ t: Double) {
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func include(_ format: Format, _ on: Bool) {
        var out = Set(leftOut.split(separator: ",").map(String.init))
        if on { out.remove(format.rawValue) } else { out.insert(format.rawValue) }
        leftOut = out.sorted().joined(separator: ",")
    }

    private func pick(_ point: CGPoint, in shot: SocialCutdowns.Shot, analysis: SocialCutdowns.Analysis) {
        picking = false
        let at = time
        status = String(localized: "Following the subject…")
        Task {
            if let path = await SocialCutdowns.track(analysis, shot: shot, time: at, point: point) {
                var edit = edits[shot.start] ?? .init()
                edit.path = path
                edit.locks = [:]
                edits[shot.start] = edit
            }
            status = nil
        }
    }

    private func render() {
        guard let analysis else { return }
        guard let ffmpeg = studio.toolPath("ffmpeg") else { problem = Converting.Failure.noFFmpeg.localizedDescription; return }
        let formats = chosen, brand = brand, edits = edits, replace = replaceLogo, proRes = proRes
        let out = folder ?? analysis.file.deletingLastPathComponent()
        let look = SocialCutdowns.branded(design, brand)
        let name = analysis.file.deletingPathExtension().lastPathComponent
        task = Task {
            var lines: [Transcript.Cue]?
            if captionsOn, LocalAI.canTranscribe {
                if let cues {
                    lines = cues
                } else if #available(macOS 26, *), let item = fileItem() {
                    status = String(localized: "Transcribing…")
                    do {
                        // The saved transcript when it's in this language; else a new one, kept with the edit.
                        let transcript = try await studio.existingOrNewTranscript(for: item, file: analysis.file, language: session.language)
                        lines = transcript.cues()
                        cues = lines
                        session.transcriptID = transcript.id
                        session.saveSoon()
                    } catch {
                        // Asked for captions: nothing is rendered without them.
                        problem = error.localizedDescription
                        status = nil
                        task = nil
                        return
                    }
                    item.aiStatus = nil
                    item.aiProgress = nil
                    status = nil
                }
            }
            for format in formats {
                let logo = replace && analysis.logo != nil ? brand.flatMap { SocialCutdowns.logoPlacement($0, format: format) } : nil
                let job = SocialCutdowns.Render(format: format,
                                                plans: SocialCutdowns.plan(analysis, format: format, edits: edits, ignoreLogo: logo != nil),
                                                cues: lines, design: look, logo: logo, folder: out, proRes: proRes)
                queue.add("\(name) · \(format.tag.replacingOccurrences(of: "x", with: ":"))") { progress in
                    try await SocialCutdowns.render(analysis, job, ffmpeg: ffmpeg, progress: progress)
                }
            }
            task = nil
        }
    }
}

/// The player's picture, as many times as needed (each preview shows the same player).
private struct CutdownPlayerLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resize
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
