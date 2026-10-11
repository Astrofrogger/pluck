import SwiftUI
import UniformTypeIdentifiers

/// Brand Pack's window: a logo in; lower thirds, a title card and an end card out, in the
/// logo's colours.
struct BrandPackView: View {
    /// A logo to load as soon as the window opens (screenshots).
    @MainActor static var openFile: URL?
    @Environment(DownloadManager.self) private var manager
    @State private var logo: LogoAnimation?
    @State private var logoFile: URL?
    @State private var loading = false
    @State private var problem: String?
    @AppStorage("brandPackPeople") private var people = "Lowie Sobry, Director"
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
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "rectangle.3.group", title: Text("Brand Pack"),
                        subtitle: Text("Lower thirds, a title card and an end card in your logo’s colours, animated and ready for the edit."),
                        subtitleIsName: false)
            HStack(alignment: .top, spacing: Design.Spacing.section) {
                VStack(alignment: .leading, spacing: Design.Spacing.controls) {
                    preview
                        .aspectRatio(format.aspect, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 360)
                    Picker("", selection: $showing) {
                        ForEach(Showing.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: showing) { started = .now }
                    HStack {
                        Button(logo == nil ? "Choose Logo…" : "Change Logo…") { chooseLogo() }
                        if let logoFile { Text(logoFile.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minWidth: 380)
                Form {
                    Section("Lower thirds") {
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $people)
                                .font(.body)
                                .frame(height: 90)
                                .onChange(of: people) { started = .now }
                            Text("One per line: name, role. Each becomes its own file.").font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Style", selection: $style) {
                            ForEach(BrandPack.LowerThirdStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .onChange(of: style) { started = .now; showing = .lowerThird }
                    }
                    Section("Title card") {
                        TextField("Title", text: $title, prompt: Text(verbatim: "Curiosity Festival 2026"))
                        TextField("Subtitle", text: $subtitle, prompt: Text(verbatim: "Aftermovie"))
                    }
                    Section("End card") {
                        TextField("Line under the logo", text: $line, prompt: Text(verbatim: "wideopen.be"))
                    }
                    Section {
                        Picker("Font", selection: $font) {
                            ForEach(Self.fonts, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("Background", selection: $background) {
                            ForEach(Backdrop.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Format", selection: $format) {
                            ForEach(Deliverables.Format.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Frame rate", selection: $frameRate) {
                            ForEach([25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                        }
                    } footer: {
                        Text("The background is for the title and end cards; lower thirds are always transparent.")
                    }
                }
                .formStyle(.grouped)
                .frame(minWidth: 400)
            }
            HStack {
                if let exporting {
                    ProgressView(value: exporting).frame(width: 200)
                    Text("Making the brand pack…").foregroundStyle(.secondary)
                } else if let done {
                    Label("Saved \(done.lastPathComponent)", systemImage: "checkmark.circle").foregroundStyle(.green)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([done]) }
                }
                Spacer()
                Text("Runs on this Mac.").font(.caption).foregroundStyle(.secondary)
                Button("Export…") { export() }
                    .buttonStyle(.borderedProminent)
                    .disabled(logo == nil || exporting != nil)
            }
        }
        .padding(Design.Spacing.window)
        .frame(minWidth: 920, minHeight: 680)
        .onAppear {
            if let url = Self.openFile {
                Self.openFile = nil
                load(url)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { if let url = await providers.first?.load(URL.self) { load(url) } }
            return true
        }
    }

    // MARK: - Preview

    @ViewBuilder private var preview: some View {
        ZStack {
            Checkerboard().clipShape(.rect(cornerRadius: Design.Radius.box))
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
            } else {
                VStack(spacing: 8) {
                    Image(systemName: loading ? "hourglass" : "square.and.arrow.down")
                        .font(.system(size: 32)).foregroundStyle(dropTargeted ? .blue : .secondary)
                        .accessibilityHidden(true)
                    Text(loading ? "Taking the logo apart…" : "Drop a logo here: PNG, SVG, PDF or JPG")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(.rect(cornerRadius: Design.Radius.box))
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
                let loaded = try await Task.detached { try LogoAnimation(contentsOf: url) }.value
                logo = loaded
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
