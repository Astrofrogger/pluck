import SwiftUI
import UniformTypeIdentifiers

/// The brand's look (fonts, colours) and each template's own settings (texts, place, size,
/// timing), kept between launches.
@MainActor
@Observable
final class BrandKit {
    static let shared = BrandKit()

    var style: MotionStyle { didSet { save() } }
    private(set) var placements: [String: MotionPlacement] { didSet { save() } }

    private init() {
        let defaults = UserDefaults.standard
        style = defaults.data(forKey: "brandKitStyle").flatMap { try? JSONDecoder().decode(MotionStyle.self, from: $0) } ?? MotionStyle()
        placements = defaults.data(forKey: "brandKitPlacements").flatMap { try? JSONDecoder().decode([String: MotionPlacement].self, from: $0) } ?? [:]
    }

    func placement(_ template: MotionTemplate) -> MotionPlacement { placements[template.id] ?? template.placement }

    func change(_ template: MotionTemplate, _ body: (inout MotionPlacement) -> Void) {
        var placement = placement(template)
        body(&placement)
        placements[template.id] = placement
    }

    /// Back to how the template comes (its texts kept).
    func resetLayout(_ template: MotionTemplate) {
        let texts = placement(template).texts
        var fresh = template.placement
        fresh.texts = texts
        placements[template.id] = fresh
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(style), forKey: "brandKitStyle")
        defaults.set(try? JSONEncoder().encode(placements), forKey: "brandKitPlacements")
    }
}

/// Brand Pack: motion templates (lower thirds, titles and chapters, logo stings and end cards,
/// social overlays) in the brand's fonts and colours. Every template plays live while its
/// texts, fonts, colours, size, place and timing change; drag it on the picture to move it.
struct BrandPackView: View {
    /// A logo to load as soon as the page opens (screenshots).
    @MainActor static var openFile: URL?
    static let openNotification = Notification.Name("PluckBrandPackOpen")
    @Environment(DownloadManager.self) private var manager
    @State private var kit = BrandKit.shared
    @State private var logo: LogoAnimation?
    @State private var logoPlan: LogoAnimation.Plan?
    @State private var logoFile: URL?
    @State private var loadingLogo = false
    @AppStorage("brandPackTemplate") private var templateID = MotionTemplate.slab.id
    @AppStorage("brandPackFormat") private var format: Deliverables.Format = .landscape
    @AppStorage("brandPackFrameRate") private var frameRate = 25
    @AppStorage("brandPackBackdrop") private var backdrop = Backdrop.picture
    @State private var playing = true
    @State private var started = Date.now
    @State private var scrub = 0.0
    @State private var exporting: Double?
    @State private var done: URL?
    @State private var problem: String?

    /// What's behind the graphics that go over a picture, in the preview only.
    enum Backdrop: String, CaseIterable, Identifiable {
        case picture, checker, black
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .picture: "Over a Picture"
            case .checker: "See-Through"
            case .black: "Black"
            }
        }
    }

    private var template: MotionTemplate { MotionTemplate.all.first { $0.id == templateID } ?? .slab }
    private var placement: MotionPlacement { kit.placement(template) }

    var body: some View {
        HSplitView {
            gallery.frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
            VStack(spacing: 0) {
                stage
                transport
            }
            .frame(minWidth: 440)
            inspector.frame(minWidth: 270, idealWidth: 300, maxWidth: 340)
        }
        .frame(minWidth: 960, minHeight: 600)
        .onChange(of: templateID) { started = .now; scrub = 0; playing = true }
        .onAppear { if let url = Self.openFile { Self.openFile = nil; loadLogo(url) } }
        .onReceive(NotificationCenter.default.publisher(for: Self.openNotification)) { note in
            if let url = note.object as? URL { Self.openFile = nil; loadLogo(url) }
        }
    }

    // MARK: - The templates

    private var gallery: some View {
        List(selection: Binding(get: { Optional(templateID) }, set: { if let id = $0 { templateID = id } })) {
            ForEach(MotionTemplate.Category.allCases) { category in
                Section(category.label) {
                    ForEach(MotionTemplate.all.filter { $0.category == category }) { item in
                        Text(item.name).tag(item.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - The picture

    private var canvas: CGSize { CGSize(width: Double(format.size.width), height: Double(format.size.height)) }

    private var stage: some View {
        GeometryReader { geo in
            let fit = min(geo.size.width / format.aspect, geo.size.height)
            let size = CGSize(width: fit * format.aspect, height: fit)
            ZStack {
                backdropView
                TimelineView(.animation(paused: !playing)) { timeline in
                    let t = playing ? loopTime(timeline.date) : scrub
                    if let frame = render(at: t, width: size.width * 2) {
                        Image(decorative: frame, scale: 2).resizable().interpolation(.high)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: Design.Radius.thumbnail))
            .contentShape(.rect)
            // Drag the graphic where it goes.
            .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
                let x = Ease.clamp(drag.location.x / size.width), y = Ease.clamp(1 - drag.location.y / size.height)
                kit.change(template) { $0.x = x; $0.y = y }
            })
            .help("Drag to move it")
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .padding(16)
    }

    @ViewBuilder private var backdropView: some View {
        if template.fullFrame && kit.style.background != nil {
            Color.clear
        } else {
            switch backdrop {
            case .picture:
                LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.48), Color(red: 0.20, green: 0.22, blue: 0.26)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            case .checker: BrandCheckerboard()
            case .black: Color.black
            }
        }
    }

    private func loopTime(_ date: Date) -> Double {
        let length = placement.duration
        // Plays, holds a moment on the last frame, plays again.
        return min(date.timeIntervalSince(started).truncatingRemainder(dividingBy: length + 0.8), length)
    }

    private func render(at t: Double, width: Double) -> CGImage? {
        let scale = width / canvas.width
        let w = Int(canvas.width * scale), h = Int(canvas.height * scale)
        guard w > 0, h > 0, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        template.render(t: t, in: context, canvas: canvas, style: kit.style, placement: placement, logo: logo, logoPlan: logoPlan)
        return context.makeImage()
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                if playing { scrub = loopTime(.now); playing = false } else { started = .now.addingTimeInterval(-scrub); playing = true }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            Slider(value: Binding(get: { playing ? 0 : scrub }, set: { scrub = $0; playing = false }), in: 0...max(placement.duration, 0.1))
                .controlSize(.small)
            Picker("Format", selection: $format) {
                ForEach(Deliverables.Format.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if !template.fullFrame || kit.style.background == nil {
                Picker("Behind", selection: $backdrop) {
                    ForEach(Backdrop.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("What the preview shows behind it (the export is see-through)")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Settings

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Text") {
                    ForEach(template.fields) { field in
                        TextField(field.label, text: textBinding(field.key), prompt: Text(verbatim: field.placeholder), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                    }
                    if template.category == .logo { logoRow }
                }
                section("Brand") {
                    fontRow("Titles", font: Binding(get: { kit.style.titleFont }, set: { kit.style.titleFont = $0 }))
                    labelled("Weight") { Slider(value: Binding(get: { kit.style.titleWeight }, set: { kit.style.titleWeight = $0 }), in: 0...1) }
                    fontRow("Text", font: Binding(get: { kit.style.bodyFont }, set: { kit.style.bodyFont = $0 }))
                    HStack(spacing: 12) {
                        colorWell("Accent", Binding(get: { kit.style.accent }, set: { kit.style.accent = $0 }))
                        colorWell("Blend", Binding(get: { kit.style.accent2 }, set: { kit.style.accent2 = $0 }))
                            .help("The accent's partner: gradients run from one to the other")
                        colorWell("Plates", Binding(get: { kit.style.secondary }, set: { kit.style.secondary = $0 }))
                        colorWell("Text", Binding(get: { kit.style.text }, set: { kit.style.text = $0 }))
                    }
                    HStack(spacing: 8) {
                        Toggle("Background", isOn: Binding(get: { kit.style.background != nil },
                                                           set: { kit.style.background = $0 ? (kit.style.background ?? MotionColor(r: 0.06, g: 0.06, b: 0.07)) : nil }))
                            .toggleStyle(.checkbox)
                            .help("Behind titles, chapters and cards; off: see-through")
                        if kit.style.background != nil {
                            ColorPicker("Background", selection: colorBinding(Binding(get: { kit.style.background ?? .ink }, set: { kit.style.background = $0 })),
                                        supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                    if kit.style.background != nil {
                        HStack(spacing: 14) {
                            Toggle("Moving light", isOn: Binding(get: { kit.style.moving }, set: { kit.style.moving = $0 }))
                                .help("The colours drift behind the cards, with light passing over")
                            Toggle("Grain", isOn: Binding(get: { kit.style.grain }, set: { kit.style.grain = $0 }))
                                .help("Film grain over the cards")
                        }
                        .toggleStyle(.checkbox)
                        .font(.callout)
                    }
                    labelled("Glow") { Slider(value: Binding(get: { kit.style.glow }, set: { kit.style.glow = $0 }), in: 0...1) }
                    labelled("Corners") { Slider(value: Binding(get: { kit.style.roundness }, set: { kit.style.roundness = $0 }), in: 0...1) }
                }
                section("Place") {
                    labelled("Size") {
                        Slider(value: placementBinding(\.scale), in: 0.4...2.5)
                        Text(String(format: "%.0f%%", placement.scale * 100)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                    HStack(alignment: .top) {
                        positionGrid
                        Spacer()
                        if template.canAlign {
                            Picker("Align", selection: placementBinding(\.align)) {
                                ForEach(MotionAlign.allCases) { Image(systemName: $0.symbol).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    Text("Or drag it on the picture.").font(.caption).foregroundStyle(.secondary)
                }
                section("Timing") {
                    labelled("Length") {
                        Slider(value: placementBinding(\.duration), in: 2...(template.id == "progress" ? 600 : 20))
                        Text(Format.duration(placement.duration)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                    labelled("Speed") {
                        Slider(value: placementBinding(\.speed), in: 0.5...2)
                        Text(String(format: "%.1f×", placement.speed)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
                HStack {
                    Button("Reset Layout") { kit.resetLayout(template) }
                        .buttonStyle(.link)
                    Spacer()
                    Picker("Frame Rate", selection: $frameRate) {
                        ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
                exportRow
            }
            .padding(16)
        }
    }

    private var logoRow: some View {
        HStack(spacing: 8) {
            if loadingLogo { ProgressView().controlSize(.small) }
            Button(logoFile == nil ? "Add a Logo…" : logoFile!.lastPathComponent) { chooseLogo() }
                .lineLimit(1)
                .help("The logo animates as the Logo Animator would; its colours can become the brand's")
            if logo != nil {
                Button("Use Its Colours") { useLogoColours() }
                    .buttonStyle(.link)
            }
        }
    }

    private var exportRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Export…", systemImage: "square.and.arrow.up") { export([template]) }
                    .buttonStyle(BarCapsuleButtonStyle())
                    .disabled(exporting != nil)
                Button("Export All…") { export(MotionTemplate.all.filter { $0.category != .logo || logo != nil || $0.id == "sting" }) }
                    .buttonStyle(GlassCapsuleButtonStyle())
                    .disabled(exporting != nil)
                    .help("Every template, each as its own file")
            }
            if let exporting {
                ProgressView(value: exporting)
            } else if let done {
                DoneLabel(text: Text("Saved \(done.lastPathComponent)"), file: done)
            }
            if let problem { ProblemLabel(text: problem) }
            Text(template.fullFrame && kit.style.background != nil ? "MP4 with its background." : "ProRes 4444 with transparency, for over the picture.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Nine places: the corners, the edges' middles and the centre.
    private var positionGrid: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach([0.85, 0.5, 0.14], id: \.self) { y in
                GridRow {
                    ForEach([0.07, 0.5, 0.93], id: \.self) { x in
                        let on = abs(placement.x - x) < 0.04 && abs(placement.y - y) < 0.04
                        Button {
                            kit.change(template) { p in
                                p.x = x
                                p.y = y
                                if template.canAlign { p.align = x < 0.3 ? .left : x > 0.7 ? .right : .center }
                            }
                        } label: {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(on ? Color.accentColor : Color.primary.opacity(0.15))
                                .frame(width: 16, height: 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .help("Where it sits")
    }

    // MARK: - Pieces

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func labelled<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 56, alignment: .leading).foregroundStyle(.secondary)
            content()
        }
        .font(.callout)
        .controlSize(.small)
    }

    private static let fonts: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()

    private func fontRow(_ title: LocalizedStringKey, font: Binding<String>) -> some View {
        labelled(title) {
            Picker(title, selection: font) {
                ForEach(Self.fonts, id: \.self) { Text($0).font(.custom($0, size: 13)).tag($0) }
            }
            .labelsHidden()
        }
    }

    private func colorWell(_ title: LocalizedStringKey, _ color: Binding<MotionColor>) -> some View {
        VStack(spacing: 3) {
            ColorPicker(title, selection: colorBinding(color), supportsOpacity: false).labelsHidden()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func colorBinding(_ color: Binding<MotionColor>) -> Binding<Color> {
        Binding(get: { Color(cgColor: color.wrappedValue.cg) },
                set: { new in if let cg = NSColor(new).usingColorSpace(.sRGB)?.cgColor { color.wrappedValue = MotionColor(cg) } })
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { placement.texts[key] ?? "" }, set: { value in kit.change(template) { $0.texts[key] = value } })
    }

    private func placementBinding<T>(_ path: WritableKeyPath<MotionPlacement, T>) -> Binding<T> {
        Binding(get: { placement[keyPath: path] }, set: { value in kit.change(template) { $0[keyPath: path] = value } })
    }

    // MARK: - Logo

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .svg, .pdf, .tiff, .heic]
        if panel.runModal() == .OK, let url = panel.url { loadLogo(url) }
    }

    private func loadLogo(_ url: URL) {
        loadingLogo = true
        problem = nil
        Task {
            do {
                let (loaded, plan) = try await Task.detached { () -> (LogoAnimation, LogoAnimation.Plan) in
                    let logo = try LogoAnimation(contentsOf: url)
                    return (logo, logo.suggestedMotion(savedFor: url).plan)
                }.value
                logo = loaded
                logoPlan = plan
                logoFile = url
                started = .now
            } catch {
                problem = error.localizedDescription
            }
            loadingLogo = false
        }
    }

    /// The logo's colours as the brand's: its accent, and a second that reads under text.
    private func useLogoColours() {
        guard let logo else { return }
        let pack = BrandPack(logo: logo, font: kit.style.titleFont, lowerThirdStyle: .plate, background: nil)
        kit.style.accent = MotionColor(pack.brand)
        // Its partner: the logo's next colour, or the accent a little deeper.
        let brand = MotionColor(pack.brand)
        kit.style.accent2 = pack.palette.dropFirst().map(MotionColor.init).first { abs($0.luminance - brand.luminance) < 0.35 && $0 != brand }
            ?? MotionColor(r: brand.r * 0.85, g: brand.g * 0.55, b: min(brand.b * 1.1 + 0.08, 1))
        let main = pack.palette.first.map(MotionColor.init) ?? .ink
        kit.style.secondary = main.luminance < 0.35 ? main : MotionColor(r: 0.09, g: 0.09, b: 0.11)
    }

    // MARK: - Export

    private func export(_ templates: [MotionTemplate]) {
        guard let ffmpeg = manager.tool("ffmpeg") else { problem = Converting.Failure.noFFmpeg.localizedDescription; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save Here")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let style = kit.style, size = canvas, rate = frameRate, logo = logo, plan = logoPlan
        let jobs = templates.map { ($0, kit.placement($0)) }
        exporting = 0
        done = nil
        problem = nil
        Task {
            do {
                var last: URL?
                for (index, (template, placement)) in jobs.enumerated() {
                    let transparent = !(template.fullFrame && style.background != nil)
                    let name = Folders.sanitize(template.name + " " + format.label.components(separatedBy: " ").first!.replacingOccurrences(of: ":", with: "x"))
                    let url = Converting.outputURL(folder: folder.path, name: name, fileExtension: transparent ? "mov" : "mp4")
                    try await LogoAnimation.writeVideo(to: url, size: size, frameRate: rate, length: placement.duration, transparent: transparent,
                                                       motionBlur: 3, ffmpeg: ffmpeg, progress: { value in
                        Task { @MainActor in exporting = (Double(index) + value) / Double(jobs.count) }
                    }) { t, context in
                        template.render(t: t, in: context, canvas: size, style: style, placement: placement, logo: logo, logoPlan: plan)
                    }
                    last = url
                }
                done = jobs.count == 1 ? last : folder
                AppDelegate.shared?.manager.notify(title: String(localized: "Brand pack ready"),
                                                   body: jobs.count == 1 ? (last?.lastPathComponent ?? "") : folder.lastPathComponent,
                                                   files: last.map { [$0] } ?? [])
            } catch {
                problem = error.localizedDescription
            }
            exporting = nil
        }
    }
}

/// The grey checkerboard behind see-through graphics.
private struct BrandCheckerboard: View {
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
