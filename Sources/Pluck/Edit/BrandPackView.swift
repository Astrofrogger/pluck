import SwiftUI
import UniformTypeIdentifiers

/// Brand Pack's window: a logo in; lower thirds, a title card and an end card out, in the
/// logo's colours.
struct BrandPackView: View {
    /// A logo to load as soon as the window opens (screenshots).
    @MainActor static var openFile: URL?
    static let openNotification = Notification.Name("PluckBrandPackOpen")
    @Environment(DownloadManager.self) private var manager
    @State private var logo: LogoAnimation?
    @State private var logoFile: URL?
    /// The end card's logo animation: the Logo Animator's saved design for this logo, if any.
    @State private var endMotion: (plan: LogoAnimation.Plan, feel: LogoProfile.Personality)?
    @AppStorage("brandPackSound") private var endSound: LogoSound = .none
    @State private var loading = false
    @State private var problem: String?
    @AppStorage("brandPackPeople") private var people = "Alex Morgan, Director"
    @AppStorage("brandPackTitle") private var title = ""
    @AppStorage("brandPackSubtitle") private var subtitle = ""
    @AppStorage("brandPackLine") private var line = ""
    @AppStorage("brandPackFont") private var font = "Helvetica Neue"
    @AppStorage("brandPackStyle") private var style = BrandPack.LowerThirdStyle.plate
    @AppStorage("brandPackBackground") private var background = Backdrop.automatic
    @AppStorage("brandPackFormat") private var format: Deliverables.Format = .landscape
    @AppStorage("brandPackFrameRate") private var frameRate = 25
    @State private var showing = Showing.lowerThird
    @State private var started = Date.now
    @State private var exporting: Double?
    @State private var done: URL?
    @State private var dropTargeted = false

    enum Showing: String, CaseIterable, Identifiable {
        case lowerThird, title, endCard
        var id: String { rawValue }
        var label: String {
            switch self {
            case .lowerThird: String(localized: "Lower Third")
            case .title: String(localized: "Title Card")
            case .endCard: String(localized: "End Card")
            }
        }
    }

    enum Backdrop: String, CaseIterable, Identifiable {
        case automatic, brand, white, black, transparent
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: String(localized: "Automatic (the logo reads on it)")
            case .brand: String(localized: "Brand colour")
            case .white: String(localized: "White")
            case .black: String(localized: "Black")
            case .transparent: String(localized: "Transparent (ProRes 4444)")
            }
        }
    }

    private static let fonts: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }.sorted()

    var body: some View {
        ToolPage {
            if logo == nil {
                ToolWelcome(symbol: "rectangle.3.group", title: Text("Brand Pack"),
                            subtitle: Text("Lower thirds, a title card and an end card in your logo’s colours, animated and ready for the edit."))
                dropZone
                if let problem { ProblemLabel(text: problem) }
            } else {
                preview
                    .aspectRatio(format.aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                actionBar
                if let problem { ProblemLabel(text: problem) }
                cards
            }
            PageNote(text: Text("Runs on this Mac."), symbol: "desktopcomputer")
        }
        .frame(minWidth: 620, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $showing) {
                    ForEach(Showing.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(logo == nil)
                .help("Which graphic the preview plays")
            }
        }
        .onChange(of: showing) { started = .now }
        .onAppear {
            if let url = Self.openFile {
                Self.openFile = nil
                load(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.openNotification)) { note in
            if let url = note.object as? URL { Self.openFile = nil; load(url) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { if let url = await providers.first?.load(URL.self) { load(url) } }
            return true
        }
    }

    /// Before there's a logo: a place to drop one, and the button to choose one.
    private var dropZone: some View {
        VStack(spacing: Design.Spacing.section) {
            DropZone(text: loading ? Text("Taking the logo apart…") : Text("Drop a logo here: PNG, SVG, PDF or JPG"),
                     targeted: dropTargeted, busy: loading)
            Button("Choose Logo…", systemImage: "photo") { chooseLogo() }
                .buttonStyle(BarCapsuleButtonStyle())
                .disabled(loading)
        }
    }

    /// The logo in use, and the main action, like the main window's bar.
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassGroup(spacing: Design.Spacing.controls) {
                HStack(spacing: Design.Spacing.controls) {
                    FileCapsule(file: logoFile, symbol: "photo")
                    Button("Change…") { chooseLogo() }
                        .buttonStyle(GlassCapsuleButtonStyle())
                    Button("Export…", systemImage: "square.and.arrow.up") { export() }
                        .buttonStyle(BarCapsuleButtonStyle())
                        .disabled(exporting != nil)
                }
            }
            if let exporting {
                HStack(spacing: Design.Spacing.controls) {
                    ProgressView(value: exporting).frame(maxWidth: 240)
                    Text("Making the brand pack…").font(.callout).foregroundStyle(.secondary)
                }
            } else if let done {
                DoneLabel(text: Text("Saved \(done.lastPathComponent)"), file: done)
            }
        }
    }

    @ViewBuilder private var cards: some View {
        Card {
            CardHeader(symbol: "person.text.rectangle", title: Text("Lower thirds"),
                       subtitle: Text("One per line: name, role. Each becomes its own file."))
            TextEditor(text: $people)
                .textBox(height: 96)
                .onChange(of: people) { started = .now; showing = .lowerThird }
            CardField(label: Text("Style")) {
                Picker("Style", selection: $style) {
                    ForEach(BrandPack.LowerThirdStyle.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
            }
            .onChange(of: style) { started = .now; showing = .lowerThird }
        }
        Card {
            CardHeader(symbol: "textformat.size", title: Text("Title card"))
            TextField("Title", text: $title, prompt: Text(verbatim: "Curiosity Festival 2026"))
                .capsuleField()
                .onChange(of: title) { showing = .title }
            TextField("Subtitle", text: $subtitle, prompt: Text(verbatim: "Aftermovie"))
                .capsuleField()
                .onChange(of: subtitle) { showing = .title }
        }
        Card {
            CardHeader(symbol: "flag.checkered", title: Text("End card"))
            TextField("Line under the logo", text: $line, prompt: Text(verbatim: "example.com"))
                .capsuleField()
                .onChange(of: line) { showing = .endCard }
            CardField(label: Text("Sound")) {
                Picker("Sound", selection: $endSound) {
                    ForEach(LogoSound.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                .help(endSound.help)
            }
        }
        Card {
            CardHeader(symbol: "paintpalette", title: Text("Look"),
                       subtitle: Text("The background is for the title and end cards; lower thirds are always transparent."))
            CardField(label: Text("Font")) {
                Picker("Font", selection: $font) {
                    ForEach(Self.fonts, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
            }
            CardField(label: Text("Background")) {
                Picker("Background", selection: $background) {
                    ForEach(Backdrop.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
            }
            CardField(label: Text("Format")) {
                Picker("Format", selection: $format) {
                    ForEach(Deliverables.Format.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
            }
            CardField(label: Text("Frame rate")) {
                Picker("Frame rate", selection: $frameRate) {
                    ForEach([25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                .fixedSize()
            }
        }
    }

    // MARK: - Preview

    @ViewBuilder private var preview: some View {
        ZStack {
            Checkerboard()
            if let pack {
                let graphic = previewGraphic
                let canvas = CGSize(width: Double(format.size.width) / 2, height: Double(format.size.height) / 2)
                TimelineView(.animation) { context in
                    let length = pack.length(graphic)
                    // Plays, holds a second, and plays again.
                    let t = context.date.timeIntervalSince(started).truncatingRemainder(dividingBy: length + 1)
                    if let frame = Self.frame(pack, graphic, at: min(t, length), canvas: canvas) {
                        Image(decorative: frame, scale: 1).resizable().interpolation(.high)
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: Design.Radius.card, style: .continuous))
    }

    private static func frame(_ pack: BrandPack, _ graphic: BrandPack.Graphic, at t: Double, canvas: CGSize) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        pack.draw(graphic, at: t, in: context, canvas: canvas)
        return context.makeImage()
    }

    // MARK: - The pack

    private var pack: BrandPack? {
        guard let logo else { return nil }
        var pack = BrandPack(logo: logo, font: font, lowerThirdStyle: style, background: nil)
        pack.endMotion = endMotion
        pack.endSound = endSound
        switch background {
        case .automatic: pack.background = pack.contrasting
        case .brand: pack.background = pack.brand
        case .white: pack.background = CGColor(gray: 1, alpha: 1)
        case .black: pack.background = CGColor(gray: 0, alpha: 1)
        case .transparent: pack.background = nil
        }
        return pack
    }

    private var lowerThirds: [BrandPack.Graphic] {
        people.split(separator: "\n").compactMap { row in
            let parts = row.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { return nil }
            return .lowerThird(name: name, role: parts.count > 1 ? parts[1] : "")
        }
    }

    private var titleGraphic: BrandPack.Graphic {
        .title(title: title.isEmpty ? String(localized: "Your Title") : title, subtitle: subtitle)
    }

    private var previewGraphic: BrandPack.Graphic {
        switch showing {
        case .lowerThird: lowerThirds.first ?? .lowerThird(name: String(localized: "Name"), role: String(localized: "Role"))
        case .title: titleGraphic
        case .endCard: .endCard(line: line)
        }
    }

    // MARK: - Actions

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .svg, .pdf, .tiff, .heic]
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private func load(_ url: URL) {
        loading = true
        problem = nil
        Task {
            do {
                let (loaded, motion) = try await Task.detached { () -> (LogoAnimation, (plan: LogoAnimation.Plan, feel: LogoProfile.Personality)) in
                    let logo = try LogoAnimation(contentsOf: url)
                    return (logo, logo.suggestedMotion(savedFor: url))
                }.value
                logo = loaded
                endMotion = motion
                logoFile = url
                started = .now
            } catch {
                problem = error.localizedDescription
            }
            loading = false
        }
    }

    private func export() {
        guard let pack, let logoFile, let ffmpeg = manager.tool("ffmpeg") else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save Here")
        panel.message = String(localized: "Choose where the brand pack goes. Pluck makes a folder for it there.")
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let name = Folders.sanitize(logoFile.deletingPathExtension().lastPathComponent + String(localized: " brand pack"))
        let folder = Converting.outputFolder(in: parent, name: name)
        var graphics = lowerThirds
        if !title.isEmpty { graphics.append(.title(title: title, subtitle: subtitle)) }
        graphics.append(.endCard(line: line))
        let size = CGSize(width: format.size.width, height: format.size.height)
        let rate = frameRate
        exporting = 0
        done = nil
        Task {
            do {
                _ = try await pack.export(graphics, to: folder, size: size, frameRate: rate, ffmpeg: ffmpeg) { value in
                    Task { @MainActor in exporting = value }
                }
                done = folder
            } catch {
                problem = error.localizedDescription
            }
            exporting = nil
        }
    }
}

/// The grey checkerboard behind transparent graphics.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let square = 14.0
            for y in stride(from: 0.0, to: size.height, by: square) {
                for x in stride(from: 0.0, to: size.width, by: square) where (Int(x / square) + Int(y / square)) % 2 == 0 {
                    context.fill(Path(CGRect(x: x, y: y, width: square, height: square)), with: .color(.gray.opacity(0.25)))
                }
            }
        }
        .background(.gray.opacity(0.12))
    }
}
