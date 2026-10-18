import SwiftUI
import UniformTypeIdentifiers

/// Logo Animator: a logo in, a smooth animated version out, built from the logo's own shapes.
struct LogoAnimatorView: View {
    @Environment(AIStudio.self) private var studio
    @State private var file: URL?
    @State private var animation: LogoAnimation?
    @State private var problem: String?
    @AppStorage("logoStyle") private var style: LogoAnimation.Style = .automatic
    @AppStorage("logoFormat") private var format: Deliverables.Format = .landscape
    @AppStorage("logoBackground") private var background: Background = .transparent
    /// The custom background colour, kept as hex.
    @AppStorage("logoColour") private var colourHex = "000000"
    private var colour: Binding<Color> {
        Binding {
            let value = Int(colourHex, radix: 16) ?? 0
            return Color(.sRGB, red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
        } set: { new in
            let c = NSColor(new).usingColorSpace(.sRGB) ?? .black
            colourHex = String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                               Int((c.blueComponent * 255).rounded()))
        }
    }
    @AppStorage("logoFrameRate") private var frameRate = 60
    @AppStorage("logoOutput") private var output: LogoOutput = .intro
    /// 1: HD, 2: 4K.
    @AppStorage("logoResolution") private var resolution = 1
    @AppStorage("logoFile") private var fileKind: LogoFile = .automatic
    @AppStorage("logoSound") private var sound: LogoSound = .none
    /// The logo with its symbol above its name, for tall formats (nil if it's stacked already).
    @State private var stackedAnimation: LogoAnimation?
    @AppStorage("logoOutro") private var outro: LogoAnimation.Outro = .none
    /// The video's length in seconds; 0 is automatic (as long as the animation needs).
    @AppStorage("logoLength") private var length = 0.0
    @State private var started = Date.now
    @State private var exporting: Double?
    @State private var exportTask: Task<Void, Never>?
    @State private var done: URL?
    @State private var dropTargeted = false
    /// Why Automatic plays what it plays (the director's reason).
    @State private var advice: LogoDirector.Advice?
    /// The animation designed for this logo, and which idea it is (Another Idea).
    @State private var design: LogoAnimation.Design?
    /// What's been changed in the design (kept with the logo), and the part chosen in the preview.
    @State private var edits = LogoDesignEdits()
    @State private var selectedPart: Int?
    /// The last changes that still ended on the logo (a change that doesn't is undone).
    @State private var goodEdits = LogoDesignEdits()
    @State private var editUndone = false
    /// A logo to open when the window appears, or (already open) when this is posted
    /// (screenshot mode).
    @MainActor static var openFile: URL?
    static let openNotification = Notification.Name("PluckOpenLogo")
    /// Taking a logo apart can take a few seconds (a badge with a lot of text): in the background.
    @State private var loading = false

    enum Background: String, CaseIterable, Identifiable {
        case transparent, black, white, colour
        var id: String { rawValue }

        var label: String {
            switch self {
            case .transparent: String(localized: "Transparent (ProRes 4444)")
            case .black: String(localized: "Black")
            case .white: String(localized: "White")
            case .colour: String(localized: "Colour…")
            }
        }
    }

    /// For SVG and PDF: whether the logo is drawn from the file's own shapes.
    private var sourceNote: String {
        guard let file, ["svg", "pdf"].contains(file.pathExtension.lowercased()), let animation else { return "" }
        return animation.vectorLogo != nil
            ? String(localized: "Drawn from the file’s own shapes: sharp at any size.")
            : String(localized: "Drawn from a picture of the file: it uses text, gradients or effects Pluck doesn’t read as shapes.")
    }

    private var backgroundColour: CGColor? {
        switch background {
        case .transparent: nil
        case .black: CGColor(gray: 0, alpha: 1)
        case .white: CGColor(gray: 1, alpha: 1)
        case .colour: NSColor(colour.wrappedValue).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 0, alpha: 1)
        }
    }

    var body: some View {
        ToolPage {
            if animation == nil {
                ToolWelcome(symbol: "wand.and.stars", title: Text("Logo Animator"),
                            subtitle: Text("Takes your logo apart into its shapes and animates them in, smooth and refined."))
                DropZone(text: loading ? Text("Taking the logo apart…") : Text("Drop a logo here: PNG, SVG, PDF or JPG."),
                         targeted: dropTargeted, busy: loading)
                Button("Choose Logo…", systemImage: "photo", action: choose)
                    .buttonStyle(BarCapsuleButtonStyle())
                    .disabled(loading)
                    .frame(maxWidth: .infinity)
                if let problem { ProblemLabel(text: problem) }
            } else {
                preview
                    .aspectRatio(format.aspect, contentMode: .fit)
                    .frame(maxHeight: 420)
                    .frame(maxWidth: .infinity)
                actionBar
                if let problem { ProblemLabel(text: problem) }
                cards
            }
            PageNote(text: Text("Runs on this Mac."), symbol: "desktopcomputer")
        }
        .frame(minWidth: 620, minHeight: 600)
        .task {
            if let file = Self.openFile {
                Self.openFile = nil
                load(file)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.openNotification)) { note in
            if let url = note.object as? URL { Self.openFile = nil; load(url) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            // The file arrives off the main thread: loaded through the helper the main window uses.
            guard let provider = providers.first else { return false }
            Task {
                if let url = await provider.load(URL.self), url.isFileURL { load(url) }
            }
            return true
        }
    }

    /// The logo in use and what to do with it, like the main window's bar.
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassGroup(spacing: Design.Spacing.controls) {
                HStack(spacing: Design.Spacing.controls) {
                    FileCapsule(file: file, symbol: "photo")
                        .help(sourceNote)
                    Button("Change…", action: choose)
                        .buttonStyle(GlassCapsuleButtonStyle())
                    Button("Save as SVG", action: saveVector)
                        .buttonStyle(GlassCapsuleButtonStyle())
                        .help("The logo as a vector file: traced colour by colour into smooth curves")
                    Button("Export", systemImage: "square.and.arrow.up", action: export)
                        .buttonStyle(BarCapsuleButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(exporting != nil)
                }
            }
            if let exporting {
                HStack(spacing: Design.Spacing.controls) {
                    ProgressView(value: exporting)
                    Button("Stop") { exportTask?.cancel() }
                        .buttonStyle(GlassCapsuleButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
            } else if let done {
                DoneLabel(text: Text(done.lastPathComponent), file: done)
            }
        }
    }

    @ViewBuilder private var cards: some View {
        Card {
            CardHeader(symbol: "sparkles", title: Text("Animation"), subtitle: animationDetail)
            CardField(label: Text("Style")) {
                HStack(spacing: Design.Spacing.controls) {
                    if usesDesign {
                        Button("Another Idea", systemImage: "dice") {
                            // A new idea starts again from it, without the changes to the last one.
                            edits = LogoDesignEdits(feel: edits.feel, seed: edits.seed + 1)
                            selectedPart = nil
                        }
                        .buttonStyle(GlassCapsuleButtonStyle())
                        .help("Another animation designed for this logo")
                    }
                    Picker("Animation", selection: $style) {
                        ForEach(LogoAnimation.Style.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                }
            }
            .onChange(of: style) { restart() }
            .onChange(of: edits) { redesign() }
            .onChange(of: output) { redesign() }
            .onChange(of: format) { redesign() }
            if usesDesign, let animation = shownAnimation, let design {
                CardField(label: Text("Feel")) {
                    Picker("Feel", selection: Binding(get: { edits.feel ?? animation.profile.personality(mood: nil) }, set: { edits.feel = $0 })) {
                        ForEach(LogoProfile.Personality.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Calm: unhurried and gentle. Premium: slow, settling with care. Playful: quick and springy. Bold: fast and sharp.")
                }
                CardField(label: Text("Timing")) {
                    LogoTimingStrip(animation: animation, design: design, edits: $edits, selected: $selectedPart)
                        .frame(maxWidth: 340)
                }
            }
            CardField(label: Text("Outro")) {
                Picker("Outro", selection: $outro) {
                    ForEach(LogoAnimation.Outro.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
            }
            .onChange(of: outro) { restart() }
            CardField(label: Text("Length")) {
                Picker("Length", selection: $length) {
                    Text(automaticLength).tag(0.0)
                    Divider()
                    ForEach([3.0, 4, 5, 6, 8, 10, 15, 20], id: \.self) { seconds in
                        Text(Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .abbreviated))).tag(seconds)
                    }
                }
                .fixedSize()
            }
            .onChange(of: length) { restart() }
            if let plan, plan.speed > 1.01 {
                Text("The moves play a little faster to fit.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if usesDesign, let animation = shownAnimation, let selectedPart, animation.elements.indices.contains(selectedPart) {
            LogoPartCard(animation: animation, part: selectedPart, edits: $edits) { self.selectedPart = nil }
        }
        Card {
            CardHeader(symbol: "film", title: Text("Video"), subtitle: animation.map { Text($0.profile.summary) })
            CardField(label: Text("Output")) {
                Picker("Output", selection: $output) {
                    ForEach(LogoOutput.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(output.help)
            }
            CardField(label: Text("Format")) {
                HStack(spacing: Design.Spacing.controls) {
                    Picker("Size", selection: $resolution) {
                        Text("HD").tag(1)
                        Text("4K").tag(2)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("HD (1920 pixels across in landscape) or 4K (3840)")
                    Picker("Format", selection: $format) {
                        ForEach(Deliverables.Format.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    .help(isTall && stackedAnimation != nil ? String(localized: "Tall formats put the symbol above the name") : String(localized: "The shape of the video"))
                }
            }
            if output != .still {
                CardField(label: Text("File")) {
                    Picker("File", selection: $fileKind) {
                        ForEach(LogoFile.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    .help(fileKind.help)
                }
            }
            CardField(label: Text("Background")) {
                HStack {
                    if background == .colour {
                        ColorPicker("Colour", selection: colour, supportsOpacity: false)
                    }
                    Picker("Background", selection: $background) {
                        ForEach(Background.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                }
            }
            CardField(label: Text("Frame rate")) {
                Picker("Frame rate", selection: $frameRate) {
                    ForEach([25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                .fixedSize()
            }
            if output != .still && output != .loop && fileKind.resolved(transparent: background == .transparent).carriesSound {
                CardField(label: Text("Sound")) {
                    Picker("Sound", selection: $sound) {
                        ForEach(LogoSound.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    .help(sound.help)
                }
            }
            Button("Export Motion Kit…", systemImage: "square.stack.3d.up") { exportKit() }
                .buttonStyle(GlassCapsuleButtonStyle())
                .disabled(exporting != nil)
                .help("Reveal, Intro, Sting and Loop videos and the Still, in one folder")
        }
    }

    /// What the chosen animation does (for Automatic: why it chose it).
    /// Tall formats show the logo stacked (symbol above name) when it can be.
    private var isTall: Bool { format == .vertical || format == .portrait }
    private var shownAnimation: LogoAnimation? { isTall ? stackedAnimation ?? animation : animation }

    /// Whether the designed animation plays: chosen, or Automatic when it suits the logo well.
    private var usesDesign: Bool {
        guard let design, design.valid else { return false }
        return style == .designed || (style == .automatic && design.score >= 0.75)
    }

    private var animationDetail: Text {
        if editUndone {
            Text("That change wouldn’t end on the logo exactly, so it was undone.")
        } else if usesDesign, let design {
            Text(design.name)
        } else if style == .designed {
            Text("This logo is too detailed to take apart, so Automatic plays.")
        } else if style == .automatic, let animation {
            Text(advice?.reason ?? animation.suggestedStyle.detail)
        } else {
            Text(style.detail)
        }
    }

    /// Intro, hold and outro for the chosen settings.
    private var plan: LogoAnimation.Plan? { plan(for: output, design: design) }

    /// The video for an output: the loop on its own; otherwise the design (or style) at the
    /// output's length (or the chosen one).
    private func plan(for output: LogoOutput, design: LogoAnimation.Design?) -> LogoAnimation.Plan? {
        guard let shown = shownAnimation else { return nil }
        if output == .loop { return shown.loopPlan() }
        let chosen = length > 0 ? length : output == .still ? nil : output.length
        let ending = output == .still ? LogoAnimation.Outro.none : outro
        if usesDesign, let design { return shown.plan(.custom(design.spec), outro: ending, length: chosen) }
        return shown.plan(style == .designed ? .automatic : style, outro: ending, length: chosen)
    }

    /// The design with its changes (the same changes always give the same animation), kept
    /// with the logo.
    private func redesign() {
        guard let animation = shownAnimation, let file else { return }
        let wanted = edits, pace = output.pace
        Task {
            let made = await Task.detached(priority: .userInitiated) { animation.design(edits: wanted, pace: pace) }.value
            guard wanted == edits, pace == output.pace else { return }
            // A change whose last frame isn't the logo is undone (it can't be shown or exported).
            if let made, !made.valid, wanted != goodEdits {
                editUndone = true
                edits = goodEdits
                return
            }
            editUndone = false
            goodEdits = wanted
            design = made
            restart()
            Task.detached(priority: .utility) { LogoDesignStore.save(wanted, for: file) }
        }
    }

    private var automaticLength: String {
        // The output's own length (a loop: one turn of it).
        let natural = output == .loop ? shownAnimation?.loopPlan().total : output == .still ? nil : output.length
        guard let natural else { return String(localized: "Automatic") }
        let seconds = natural.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "Automatic (\(seconds) s)")
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            // A checkerboard shows what's transparent.
            if background == .transparent {
                Checkerboard().clipShape(.rect(cornerRadius: Design.Radius.card, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Color(cgColor: backgroundColour ?? CGColor(gray: 0, alpha: 1)))
            }
            if let animation = shownAnimation, let plan {
                TimelineView(.animation) { context in
                    // The whole video, then a short pause before it plays again (a loop: no pause; a still: its last frame).
                    let loop = plan.total + (output == .loop ? 0 : 0.8)
                    let t = output == .still ? plan.total : context.date.timeIntervalSince(started).truncatingRemainder(dividingBy: loop)
                    let size = CGSize(width: 640, height: 640 / format.aspect)
                    if let frame = animation.frame(at: min(t, plan.total), plan: plan, size: size, background: nil) {
                        Image(decorative: frame, scale: 1).resizable().interpolation(.high)
                    }
                }
                // Click a part to change it (when the design plays); the chosen one is outlined.
                if usesDesign {
                    GeometryReader { geometry in
                        let canvas = CGSize(width: 640, height: 640 / format.aspect)
                        let scale = geometry.size.width / canvas.width
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture { location in
                                selectedPart = animation.part(at: CGPoint(x: location.x / scale, y: location.y / scale), canvas: canvas)
                            }
                        if let selectedPart, animation.elements.indices.contains(selectedPart) {
                            let box = animation.box(of: selectedPart, canvas: canvas)
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Design.Brand.gradient, lineWidth: 2)
                                .frame(width: box.width * scale + 8, height: box.height * scale + 8)
                                .position(x: box.midX * scale, y: box.midY * scale)
                                .allowsHitTesting(false)
                        }
                    }
                    .help("Click a part to change how it moves")
                }
            } else if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Taking the logo apart…")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: dropTargeted ? 3 : 0)
        }
        .accessibilityLabel(String(localized: "Animation preview"))
    }

    private func restart() { started = .now }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .svg, .pdf, .tiff, .heic, .image]
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private func load(_ url: URL) {
        problem = nil
        done = nil
        advice = nil
        animation = nil
        design = nil
        stackedAnimation = nil
        edits = LogoDesignEdits()
        selectedPart = nil
        file = url
        loading = true
        Task {
            do {
                // The logo, with the changes made to its design the last time it was open.
                let tall = isTall, pace = output.pace
                let (loaded, stacked, saved, designed) = try await Task.detached(priority: .userInitiated) { () -> (LogoAnimation, LogoAnimation?, LogoDesignEdits, LogoAnimation.Design?) in
                    let animation = try LogoAnimation(contentsOf: url)
                    let stacked = animation.stacked()
                    let saved = LogoDesignStore.load(for: url) ?? LogoDesignEdits()
                    return (animation, stacked, saved, (tall ? stacked ?? animation : animation).design(edits: saved, pace: pace))
                }.value
                guard file == url else { return }
                animation = loaded
                stackedAnimation = stacked
                edits = saved
                goodEdits = saved
                design = designed
                // Tests: -PluckScreenshotPart <n> shows the Part card for that part.
                if ScreenshotMode.scene == "logo", let part = UserDefaults.standard.object(forKey: "PluckScreenshotPart") as? Int ?? Int(UserDefaults.standard.string(forKey: "PluckScreenshotPart") ?? "") {
                    selectedPart = part
                }
                loading = false
                restart()
                // The director looks at the logo and picks Automatic's style.
                let advice = await LogoDirector.advise(loaded)
                guard file == url else { return }
                self.advice = advice
                animation?.directed = advice.style
                if style == .automatic { restart() }
            } catch {
                guard file == url else { return }
                loading = false
                file = nil
                problem = error.localizedDescription
            }
        }
    }

    /// The logo traced into a vector file, next to the logo.
    private func saveVector() {
        guard let animation, let file else { return }
        let name = file.deletingPathExtension().lastPathComponent + " " + String(localized: "vector")
        let output = Converting.outputURL(folder: file.deletingLastPathComponent().path, name: name, fileExtension: "svg")
        problem = nil
        done = nil
        Task {
            let svg = await Task.detached(priority: .userInitiated) { animation.svg() }.value
            do {
                try svg.write(to: output, atomically: true, encoding: .utf8)
                done = output
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func export() {
        guard let shown = shownAnimation, let file, let plan, let ffmpeg = studio.toolPath("ffmpeg") else { return }
        let folder = file.deletingLastPathComponent()
        let name = file.deletingPathExtension().lastPathComponent + " " + output.label + " \(format.tag)" + (resolution == 2 ? " 4K" : "")
        let size = CGSize(width: format.size.width * resolution, height: format.size.height * resolution)
        let rate = frameRate, colour = backgroundColour, output = output, sound = sound, kind = fileKind
        let feel = edits.feel ?? shown.profile.personality()
        exporting = 0
        done = nil
        exportTask = Task {
            do {
                done = try await Self.write(output, shown, plan: plan, folder: folder, name: name, size: size, frameRate: rate,
                                            background: colour, file: kind, sound: sound, feel: feel, ffmpeg: ffmpeg) { value in
                    Task { @MainActor in exporting = value }
                }
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
            exporting = nil
            exportTask = nil
        }
        // Screenshot mode: -PluckScreenshotExportStop <seconds> presses Stop that long into the export.
        let stop = UserDefaults.standard.double(forKey: "PluckScreenshotExportStop")
        if stop > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + stop) { exportTask?.cancel() }
        }
    }
}

extension LogoAnimatorView {
    /// Writes one output: a still (PNG and SVG), or a video in the chosen file (with its sound).
    /// Returns what was written.
    static func write(_ output: LogoOutput, _ shown: LogoAnimation, plan: LogoAnimation.Plan, folder: URL, name: String, size: CGSize,
                      frameRate: Int, background: CGColor?, file: LogoFile, sound: LogoSound, feel: LogoProfile.Personality,
                      ffmpeg: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if output == .still {
            let png = Converting.outputURL(folder: folder.path, name: name, fileExtension: "png")
            try await Task.detached(priority: .userInitiated) {
                guard let image = shown.frame(at: plan.total, plan: plan, size: size, background: background),
                      let destination = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw LogoAnimation.Failure() }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw LogoAnimation.Failure() }
                try shown.svg().write(to: png.deletingPathExtension().appendingPathExtension("svg"), atomically: true, encoding: .utf8)
            }.value
            progress(1)
            return png
        }
        let kind = file.resolved(transparent: background == nil)
        let target = kind == .pngSequence ? Converting.outputFolder(in: folder, name: name)
            : Converting.outputURL(folder: folder.path, name: name, fileExtension: kind.fileExtension)
        // The sound, made for this video: the hit where the hero lands.
        var audio: URL?
        if sound != .none, output != .loop, kind.carriesSound {
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-logo-\(UUID().uuidString).wav")
            try sound.write(to: wav, length: plan.total, resolve: shown.resolveTime(of: plan), feel: feel)
            audio = wav
        }
        defer { if let audio { try? FileManager.default.removeItem(at: audio) } }
        try await shown.export(to: target, plan: plan, size: size, frameRate: frameRate, background: background, ffmpeg: ffmpeg,
                               file: kind, audio: audio, progress: progress)
        return target
    }

    /// Every output in one folder: Reveal, Intro, Sting and Loop videos and the Still.
    func exportKit() {
        guard let shown = shownAnimation, let file, let ffmpeg = studio.toolPath("ffmpeg") else { return }
        let base = file.deletingPathExtension().lastPathComponent
        let folder = Converting.outputFolder(in: file.deletingLastPathComponent(), name: base + " " + String(localized: "motion kit"))
        let size = CGSize(width: format.size.width * resolution, height: format.size.height * resolution)
        let rate = frameRate, colour = backgroundColour, sound = sound, kind = fileKind, edits = edits, uses = usesDesign
        let feel = edits.feel ?? shown.profile.personality()
        // Each output's plan, its design made at that output's pace.
        let outputs = LogoOutput.allCases
        let plans = outputs.compactMap { output -> (LogoOutput, LogoAnimation.Plan)? in
            let design = uses ? shown.design(edits: edits, pace: output.pace) : nil
            return plan(for: output, design: design?.valid == true ? design : nil).map { (output, $0) }
        }
        exporting = 0
        done = nil
        exportTask = Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (n, (output, plan)) in plans.enumerated() {
                    let share = 1 / Double(plans.count)
                    _ = try await Self.write(output, shown, plan: plan, folder: folder, name: base + " " + output.label + " \(format.tag)",
                                             size: size, frameRate: rate, background: colour, file: kind, sound: sound, feel: feel,
                                             ffmpeg: ffmpeg) { value in
                        Task { @MainActor in exporting = (Double(n) + value) * share }
                    }
                }
                done = folder
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: folder)
            } catch {
                problem = error.localizedDescription
            }
            exporting = nil
            exportTask = nil
        }
    }
}

/// The grey checkerboard that stands for transparency.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let square = 12.0
            for row in 0..<Int(size.height / square) + 1 {
                for column in 0..<Int(size.width / square) + 1 {
                    let light = (row + column) % 2 == 0
                    context.fill(Path(CGRect(x: Double(column) * square, y: Double(row) * square, width: square, height: square)),
                                 with: .color(light ? Color(white: 0.82) : Color(white: 0.68)))
                }
            }
        }
    }
}
