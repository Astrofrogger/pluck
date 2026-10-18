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
                Picker("Animation", selection: $style) {
                    ForEach(LogoAnimation.Style.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
            }
            .onChange(of: style) { restart() }
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
        Card {
            CardHeader(symbol: "film", title: Text("Video"), subtitle: animation.map { Text(summary($0)) })
            CardField(label: Text("Format")) {
                Picker("Format", selection: $format) {
                    ForEach(Deliverables.Format.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
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
        }
    }

    /// What the chosen animation does (for Automatic: why it chose it).
    private var animationDetail: Text {
        if style == .automatic, let animation {
            Text(advice?.reason ?? animation.suggestedStyle.detail)
        } else {
            Text(style.detail)
        }
    }

    /// Intro, hold and outro for the chosen settings.
    private var plan: LogoAnimation.Plan? {
        animation?.plan(style, outro: outro, length: length > 0 ? length : nil)
    }

    private var automaticLength: String {
        guard let natural = animation?.plan(style, outro: outro).total else { return String(localized: "Automatic") }
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
            if let animation, let plan {
                TimelineView(.animation) { context in
                    // The whole video, then a short pause before it plays again.
                    let loop = plan.total + 0.8
                    let t = context.date.timeIntervalSince(started).truncatingRemainder(dividingBy: loop)
                    let size = CGSize(width: 640, height: 640 / format.aspect)
                    if let frame = animation.frame(at: min(t, plan.total), plan: plan, size: size, background: nil) {
                        Image(decorative: frame, scale: 1).resizable().interpolation(.high)
                    }
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

    private func summary(_ animation: LogoAnimation) -> String {
        if animation.plateCount > 0, animation.letterCount > 0 {
            return String(AttributedString(localized: "Found ^[\(animation.letterCount) letter](inflect: true) in ^[\(animation.plateCount) box](inflect: true).").characters)
        }
        return switch (animation.symbolCount + animation.plateCount, animation.letterCount) {
        case (0, let letters): String(AttributedString(localized: "Found a wordmark of ^[\(letters) letter](inflect: true).").characters)
        case (let shapes, 0): String(AttributedString(localized: "Found a symbol of ^[\(shapes) shape](inflect: true).").characters)
        case (let shapes, let letters):
            String(AttributedString(localized: "Found a symbol of ^[\(shapes) shape](inflect: true) and ^[\(letters) letter](inflect: true).").characters)
        }
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
        file = url
        loading = true
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try LogoAnimation(contentsOf: url) }.value
                guard file == url else { return }
                animation = loaded
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
        guard let animation, let file, let plan, let ffmpeg = studio.toolPath("ffmpeg") else { return }
        let transparent = background == .transparent
        let name = file.deletingPathExtension().lastPathComponent + " " + String(localized: "animated") + " \(format.tag)"
        let output = Converting.outputURL(folder: file.deletingLastPathComponent().path, name: name, fileExtension: transparent ? "mov" : "mp4")
        let size = CGSize(width: format.size.width, height: format.size.height)
        let rate = frameRate, colour = backgroundColour
        exporting = 0
        done = nil
        exportTask = Task {
            do {
                try await animation.export(to: output, plan: plan, size: size, frameRate: rate, background: colour, ffmpeg: ffmpeg) { value in
                    Task { @MainActor in exporting = value }
                }
                done = output
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
