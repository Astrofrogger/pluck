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
    @State private var colour = Color.black
    @AppStorage("logoFrameRate") private var frameRate = 60
    @AppStorage("logoOutro") private var outro: LogoAnimation.Outro = .none
    /// The video's length in seconds; 0 is automatic (as long as the animation needs).
    @AppStorage("logoLength") private var length = 0.0
    @State private var started = Date.now
    @State private var exporting: Double?
    @State private var done: URL?
    @State private var dropTargeted = false

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

    private var backgroundColour: CGColor? {
        switch background {
        case .transparent: nil
        case .black: CGColor(gray: 0, alpha: 1)
        case .white: CGColor(gray: 1, alpha: 1)
        case .colour: NSColor(colour).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 0, alpha: 1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "wand.and.stars", title: Text("Logo Animator"), subtitle: Text("Takes your logo apart into its shapes and animates them in, smooth and refined."), subtitleIsName: false)

            preview
                .frame(maxWidth: .infinity)
                .aspectRatio(format.aspect, contentMode: .fit)
                .frame(maxHeight: 340)
                .frame(maxWidth: .infinity)

            if let animation {
                Text(summary(animation)).font(.callout).foregroundStyle(.secondary)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Form {
                Picker(selection: $style) {
                    ForEach(LogoAnimation.Style.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Animation")
                    Text(style == .automatic && animation != nil ? animation!.suggestedStyle.detail : style.detail)
                }
                .onChange(of: style) { restart() }
                Picker("Format", selection: $format) {
                    ForEach(Deliverables.Format.allCases) { Text($0.label).tag($0) }
                }
                HStack {
                    Picker("Background", selection: $background) {
                        ForEach(Background.allCases) { Text($0.label).tag($0) }
                    }
                    if background == .colour {
                        ColorPicker("Colour", selection: $colour, supportsOpacity: false).labelsHidden()
                    }
                }
                Picker("Outro", selection: $outro) {
                    ForEach(LogoAnimation.Outro.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: outro) { restart() }
                Picker(selection: $length) {
                    Text(automaticLength).tag(0.0)
                    Divider()
                    ForEach([3.0, 4, 5, 6, 8, 10, 15, 20], id: \.self) { seconds in
                        Text(Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .abbreviated))).tag(seconds)
                    }
                } label: {
                    Text("Length")
                    if let plan, plan.speed > 1.01 {
                        Text("The moves play a little faster to fit.")
                    }
                }
                .onChange(of: length) { restart() }
                Picker("Frame rate", selection: $frameRate) {
                    ForEach([25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            if let exporting {
                ProgressView(value: exporting)
            }
            if let done {
                HStack {
                    Label(done.lastPathComponent, systemImage: "checkmark.circle").foregroundStyle(.green)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([done]) }
                }
            }

            HStack {
                Label("Runs on this Mac.", systemImage: "lock.shield").noteStyle()
                Spacer()
                Button(file == nil ? "Choose Logo…" : "Change Logo…", action: choose)
                Button("Export", action: export)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(animation == nil || exporting != nil)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(minWidth: 620, minHeight: 640)
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
                Checkerboard().clipShape(RoundedRectangle(cornerRadius: Design.Radius.thumbnail))
            } else {
                RoundedRectangle(cornerRadius: Design.Radius.thumbnail).fill(Color(cgColor: backgroundColour ?? CGColor(gray: 0, alpha: 1)))
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
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down").font(.title).accessibilityHidden(true)
                    Text("Drop a logo here: PNG, SVG, PDF or JPG.")
                }
                .foregroundStyle(.secondary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.thumbnail).strokeBorder(dropTargeted ? Color.accentColor : .secondary.opacity(0.3), lineWidth: dropTargeted ? 3 : 1))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            // The file arrives off the main thread: loaded through the helper the main window uses.
            guard let provider = providers.first else { return false }
            Task {
                if let url = await provider.load(URL.self), url.isFileURL { load(url) }
            }
            return true
        }
        .accessibilityLabel(animation == nil ? String(localized: "Logo drop area") : String(localized: "Animation preview"))
    }

    private func summary(_ animation: LogoAnimation) -> String {
        switch (animation.symbolCount, animation.letterCount) {
        case (0, let letters): String(localized: "Found a wordmark of \(letters) letters.")
        case (let shapes, 0): String(localized: "Found a symbol of \(shapes) shapes.")
        case (let shapes, let letters): String(localized: "Found a symbol of \(shapes) shapes and \(letters) letters.")
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
        do {
            animation = try LogoAnimation(contentsOf: url)
            file = url
            restart()
        } catch {
            problem = error.localizedDescription
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
        Task {
            do {
                try await animation.export(to: output, plan: plan, size: size, frameRate: rate, background: colour, ffmpeg: ffmpeg) { value in
                    Task { @MainActor in exporting = value }
                }
                done = output
            } catch {
                problem = error.localizedDescription
            }
            exporting = nil
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
