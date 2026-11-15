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
    /// The preset last chosen (its look is `style`, changed since perhaps).
    private(set) var presetID: String? { didSet { save() } }
    /// The brand's own colours, the main one first (from its logo, or picked); nil: none yet.
    var colours: [MotionColor]? { didSet { save() } }

    var palette: BrandPalette { colours.map(BrandPalette.init(colours:)) ?? .neutral }

    private init() {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "brandKitStyle").flatMap { try? JSONDecoder().decode(MotionStyle.self, from: $0) }
        var style = saved ?? MotionStyle()
        placements = defaults.data(forKey: "brandKitPlacements").flatMap { try? JSONDecoder().decode([String: MotionPlacement].self, from: $0) } ?? [:]
        colours = defaults.data(forKey: "brandKitColours").flatMap { try? JSONDecoder().decode([MotionColor].self, from: $0) }
        // Saved before there were presets: the built-in pink was the app's, no one's brand (now
        // neutral), and the look it had is closest to Gradient.
        if Self.isLegacyPink(style.accent), Self.isLegacyPink(style.accent2) {
            style.accent = BrandPalette.neutral.primary
            style.accent2 = BrandPalette.neutral.secondary
        }
        presetID = defaults.string(forKey: "brandKitPreset") ?? (saved != nil ? "gradient" : nil)
        self.style = style
    }

    /// The look of a preset in the brand's colours.
    func apply(_ preset: MotionPreset) {
        presetID = preset.id
        style = preset.style(palette)
    }

    /// The old default accents (1.0 0.36 0.42 and 0.93 0.13 0.38).
    static func isLegacyPink(_ c: MotionColor) -> Bool {
        [(1.0, 0.36, 0.42), (0.93, 0.13, 0.38)].contains { abs(c.r - $0.0) < 0.02 && abs(c.g - $0.1) < 0.02 && abs(c.b - $0.2) < 0.02 }
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
        defaults.set(presetID, forKey: "brandKitPreset")
        defaults.set(colours.flatMap { try? JSONEncoder().encode($0) }, forKey: "brandKitColours")
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
    /// Where the last Fusion title went (in Resolve's titles, or saved).
    @State private var fusionDone: URL?
    @State private var problem: String?
    /// The kind of graphic the presets show.
    @AppStorage("brandPackCategory") private var category = MotionTemplate.Category.lowerThird
    /// One group of presets, or all ("").
    @AppStorage("brandPackGroup") private var group = ""
    @AppStorage("brandPackFavouritesOnly") private var favouritesOnly = false
    /// Favourite presets' ids, comma separated.
    @AppStorage("brandPackFavourites") private var favourites = ""
    /// The preset under the pointer, shown large on the stage.
    @State private var hovered: MotionPreset?

    /// What's behind the graphics that go over a picture, in the preview only.
    enum Backdrop: String, CaseIterable, Identifiable {
        case picture, checker, black
        var id: String { rawValue }
        var label: String {
            switch self {
            case .picture: String(localized: "Over a picture")
            case .checker: String(localized: "See-through")
            case .black: String(localized: "On black")
            }
        }
    }

    private var template: MotionTemplate { MotionTemplate.all.first { $0.id == templateID } ?? .slab }
    private var placement: MotionPlacement { kit.placement(template) }
    /// What the stage shows: the preset under the pointer, else what's chosen.
    private var shownTemplate: MotionTemplate { hovered?.layout(category) ?? template }
    private var shownStyle: MotionStyle { hovered?.style(kit.palette) ?? kit.style }

    // Layout board ToolBrand: the templates, the stage, and a 320 pt inspector.
    var body: some View {
        HStack(spacing: Design.Studio.panelGap) {
            gallery.frame(width: 300).frame(maxHeight: .infinity).studioPanel()
            VStack(spacing: 14) {
                stage
                transport
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .studioPanel()
            inspector
        }
        .frame(minWidth: 960)
        .onChange(of: templateID) { started = .now; scrub = 0; playing = true }
        .onChange(of: category) {
            guard template.category != category else { return }
            templateID = (MotionPreset.named(kit.presetID)?.layout(category) ?? MotionTemplate.all.first { $0.category == category } ?? .slab).id
        }
        .onChange(of: hovered) { started = .now }
        .onAppear {
            category = template.category
            if let url = Self.openFile { Self.openFile = nil; loadLogo(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.openNotification)) { note in
            if let url = note.object as? URL { Self.openFile = nil; loadLogo(url) }
        }
    }

    // MARK: - The templates

    private var gallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Brand Pack").font(Design.Studio.pageTitle).foregroundStyle(Design.Studio.text)
                StudioSegmented(options: MotionTemplate.Category.allCases.map { (value: $0, title: LocalizedStringKey($0.label)) },
                                selection: $category, symbols: MotionTemplate.Category.allCases.map(\.symbol), fill: true)
                HStack(spacing: 6) {
                    LogoKitMenu(title: "Style", shown: MotionPreset.Group(rawValue: group)?.label ?? String(localized: "All Styles"), selection: $group) {
                        Text("All Styles").tag("")
                        ForEach(MotionPreset.Group.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Spacer(minLength: 0)
                    Button { favouritesOnly.toggle() } label: {
                        Image(systemName: favouritesOnly ? "star.fill" : "star").font(.system(size: 12)).frame(width: 28, height: 28).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(favouritesOnly ? Design.Brand.pink : Design.Studio.textQuiet)
                    .help("Favourites only")
                    .accessibilityLabel(Text("Favourites only"))
                    .accessibilityAddTraits(favouritesOnly ? .isSelected : [])
                }
                presetGrid
                VStack(alignment: .leading, spacing: 1) {
                    Text("Layout").font(Design.Studio.hint).foregroundStyle(Design.Studio.textFaint)
                        .padding(.horizontal, 10).padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(MotionTemplate.all.filter { $0.category == category }) { item in
                        let on = item.id == templateID
                        Button { templateID = item.id } label: {
                            Text(item.name).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(on ? Design.Studio.raised : .clear, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 20)
        }
        .scrollIndicators(.never)
    }

    // MARK: - Presets

    private var favouriteIDs: Set<String> { Set(favourites.split(separator: ",").map(String.init)) }

    private var shownPresets: [MotionPreset] {
        MotionPreset.all.filter { (group.isEmpty || $0.group.rawValue == group) && (!favouritesOnly || favouriteIDs.contains($0.id)) }
    }

    private var presetGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: format.aspect < 1 ? 3 : 2)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(shownPresets) { preset in presetTile(preset) }
        }
        .onHover { if !$0 { hovered = nil } }
        .overlay {
            if shownPresets.isEmpty {
                Text("No favourites yet").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).padding(.vertical, 20)
            }
        }
    }

    private func presetTile(_ preset: MotionPreset) -> some View {
        let on = preset.id == kit.presetID
        let favourite = favouriteIDs.contains(preset.id)
        return Button { choose(preset) } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    if let image = thumbnail(preset) { Image(decorative: image, scale: 2).resizable() } else { Design.Studio.backdrop }
                }
                .aspectRatio(format.aspect, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(on ? Design.Brand.pink : Design.Studio.line, lineWidth: on ? 2 : 1)
                }
                Text(preset.name).font(Design.Studio.hint).foregroundStyle(on ? Design.Studio.text : Design.Studio.textQuiet).lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button { toggleFavourite(preset) } label: {
                Image(systemName: favourite ? "star.fill" : "star").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(favourite ? Design.Brand.pink : .white.opacity(hovered == preset ? 0.9 : 0))
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .help(favourite ? "Remove from Favourites" : "Add to Favourites")
            .accessibilityLabel(Text(favourite ? "Remove from Favourites" : "Add to Favourites"))
        }
        .onHover { inside in
            if inside { hovered = preset } else if hovered == preset { hovered = nil }
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func choose(_ preset: MotionPreset) {
        kit.apply(preset)
        templateID = preset.layout(category).id
        hovered = nil
    }

    private func toggleFavourite(_ preset: MotionPreset) {
        var ids = favouriteIDs
        if ids.contains(preset.id) { ids.remove(preset.id) } else { ids.insert(preset.id) }
        favourites = MotionPreset.all.map(\.id).filter(ids.contains).joined(separator: ",")
    }

    /// A still of the preset's layout for this kind of graphic, in the brand's colours, with the
    /// logo and the texts typed (cached until any of them change).
    private func thumbnail(_ preset: MotionPreset) -> CGImage? {
        let template = preset.layout(category)
        let placement = kit.placement(template)
        let key = "\(preset.id)|\(template.id)|\(format.rawValue)|\(kit.palette.hashValue)|\(logoFile?.path ?? "")|\(placement.hashValue)" as NSString
        if let image = Self.thumbnails.object(forKey: key) { return image }
        let width = 260.0, scale = width / canvas.width
        guard let context = CGContext(data: nil, width: Int(width), height: Int(canvas.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // A dim picture behind the ones that go over video.
        context.setFillColor(MotionTemplate.pictureStandIn.cg)
        context.fill(CGRect(origin: .zero, size: canvas))
        template.render(t: MotionPreset.stillTime(template, placement: placement, logoPlan: logo == nil ? nil : logoPlan), in: context, canvas: canvas,
                        style: preset.style(kit.palette), placement: MotionPreset.stillPlacement(template, placement), logo: logo, logoPlan: logoPlan)
        guard let image = context.makeImage() else { return nil }
        Self.thumbnails.setObject(image, forKey: key)
        return image
    }

    private static let thumbnails = NSCache<NSString, CGImage>()

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
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
            // Drag the graphic where it goes.
            .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
                let x = Ease.clamp(drag.location.x / size.width), y = Ease.clamp(1 - drag.location.y / size.height)
                kit.change(template) { $0.x = x; $0.y = y }
            })
            .help("Drag to move it")
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    @ViewBuilder private var backdropView: some View {
        if shownTemplate.fullFrame && shownStyle.background != nil {
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
        let length = kit.placement(shownTemplate).duration
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
        shownTemplate.render(t: t, in: context, canvas: canvas, style: shownStyle, placement: kit.placement(shownTemplate), logo: logo, logoPlan: logoPlan)
        return context.makeImage()
    }

    /// Play or pause, where it is, the scrub bar, the length, the format and what's behind.
    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                if playing { scrub = loopTime(.now); playing = false } else { started = .now.addingTimeInterval(-scrub); playing = true }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 12)).frame(width: 28, height: 28).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Design.Studio.text)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(Text(playing ? "Pause" : "Play"))
            TimelineView(.animation(paused: !playing)) { timeline in
                let t = playing ? loopTime(timeline.date) : scrub
                HStack(spacing: 12) {
                    Text(verbatim: seconds(t)).frame(minWidth: 34, alignment: .leading)
                    ScrubBar(value: Binding(get: { t }, set: { scrub = $0; playing = false }), range: 0...max(placement.duration, 0.1))
                    Text(verbatim: seconds(placement.duration))
                }
                .font(Design.Studio.hint.monospacedDigit())
                .foregroundStyle(Design.Studio.textQuiet)
            }
            LogoKitMenu(title: "Format", shown: format.label.components(separatedBy: " ").first ?? format.label, selection: $format) {
                ForEach(Deliverables.Format.allCases) { Text($0.label).tag($0) }
            }
            if !template.fullFrame || kit.style.background == nil {
                LogoKitMenu(title: "Behind", shown: backdrop.label, selection: $backdrop) {
                    ForEach(Backdrop.allCases) { Text($0.label).tag($0) }
                }
                .help("What the preview shows behind it (the export is see-through)")
            }
        }
    }

    private func seconds(_ t: Double) -> String { t.formatted(.number.precision(.fractionLength(1))) + " s" }

    // MARK: - Settings

    private var colours: [(title: LocalizedStringKey, path: WritableKeyPath<MotionStyle, MotionColor>, help: LocalizedStringKey)] {
        [("Accent", \.accent, ""), ("Blend", \.accent2, "The accent's partner: gradients run from one to the other"),
         ("Plates", \.secondary, ""), ("Text", \.text, "")]
    }

    /// Whether the size, place or timing differ from how the template comes.
    private var layoutChanged: Bool {
        var fresh = template.placement
        fresh.texts = placement.texts
        return fresh != placement
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
                    LogoKitFold(Text("Text"), key: "brandFoldText") {
                        VStack(spacing: 6) {
                            ForEach(template.fields) { field in
                                TextField(field.label, text: textBinding(field.key), prompt: Text(verbatim: field.placeholder).foregroundStyle(Design.Studio.textQuiet),
                                          axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .font(Design.Studio.body)
                                    .foregroundStyle(Design.Studio.text)
                                    .lineLimit(1...4)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .frame(minHeight: 30)
                                    .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                            }
                        }
                        .padding(.top, 4)
                        if template.category == .logo { logoRow }
                    }
                    LogoKitFold(Text("Brand"), key: "brandFoldBrand") {
                        fontRow("Titles", font: Binding(get: { kit.style.titleFont }, set: { kit.style.titleFont = $0 }))
                        SliderRow(title: "Weight", value: Binding(get: { kit.style.titleWeight }, set: { kit.style.titleWeight = $0 }), range: 0...1)
                        fontRow("Text", font: Binding(get: { kit.style.bodyFont }, set: { kit.style.bodyFont = $0 }))
                        HStack(alignment: .top) {
                            ForEach(colours.indices, id: \.self) { index in
                                let item = colours[index]
                                if index > 0 { Spacer(minLength: 0) }
                                VStack(spacing: 5) {
                                    LogoKitWell(title: item.title, colour: colorBinding(Binding(get: { kit.style[keyPath: item.path] },
                                                                                                 set: { kit.style[keyPath: item.path] = $0 })))
                                    Text(item.title).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                                }
                                .help(Text(item.help))
                            }
                        }
                        .padding(.vertical, 6)
                        StudioField(label: "Background") {
                            if kit.style.background != nil {
                                LogoKitWell(title: "Background", colour: colorBinding(Binding(get: { kit.style.background ?? .ink }, set: { kit.style.background = $0 })))
                            }
                            Toggle("Background", isOn: Binding(get: { kit.style.background != nil },
                                                               set: { kit.style.background = $0 ? (kit.style.background ?? MotionColor(r: 0.06, g: 0.06, b: 0.07)) : nil }))
                                .toggleStyle(StudioSwitchStyle())
                        }
                        .help("Behind titles, chapters and cards; off: see-through")
                        if kit.style.background != nil {
                            StudioField(label: "Moving light") {
                                Toggle("Moving light", isOn: Binding(get: { kit.style.moving }, set: { kit.style.moving = $0 })).toggleStyle(StudioSwitchStyle())
                            }
                            .help("The colours drift behind the cards, with light passing over")
                            StudioField(label: "Grain") {
                                Toggle("Grain", isOn: Binding(get: { kit.style.grain }, set: { kit.style.grain = $0 })).toggleStyle(StudioSwitchStyle())
                            }
                            .help("Film grain over the cards")
                        }
                        SliderRow(title: "Glow", value: Binding(get: { kit.style.glow }, set: { kit.style.glow = $0 }), range: 0...1)
                        SliderRow(title: "Corners", value: Binding(get: { kit.style.roundness }, set: { kit.style.roundness = $0 }), range: 0...1)
                    }
                    LogoKitFold(Text("Place"), key: "brandFoldPlace", accessory: layoutChanged ? AnyView(resetButton) : nil) {
                        SliderRow(title: "Size", value: placementBinding(\.scale), range: 0.4...2.5,
                                  shown: String(format: "%.0f%%", placement.scale * 100))
                        StudioField(label: "Position") { positionGrid }
                        if template.canAlign {
                            StudioField(label: "Align") {
                                StudioSegmented(options: [(value: MotionAlign.left, title: "Left" as LocalizedStringKey), (value: .center, title: "Centre"), (value: .right, title: "Right")], selection: placementBinding(\.align))
                            }
                        }
                    }
                    LogoKitFold(Text("Timing"), key: "brandFoldTiming", open: false) {
                        SliderRow(title: "Length", value: placementBinding(\.duration), range: 2...(template.id == "progress" ? 600 : 20),
                                  shown: Format.duration(placement.duration))
                        SliderRow(title: "Speed", value: placementBinding(\.speed), range: 0.5...2, shown: String(format: "%.1f×", placement.speed))
                    }
                }
            }
            .scrollIndicators(.never)
            exportRow.padding(.top, 14)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .studioPanel()
    }

    private var resetButton: some View {
        Button { kit.resetLayout(template) } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 11)) }
            .buttonStyle(.plain)
            .foregroundStyle(Design.Studio.textQuiet)
            .help("Reset Layout")
            .accessibilityLabel(Text("Reset Layout"))
    }

    private var logoRow: some View {
        StudioField(label: "Logo") {
            if loadingLogo { PlumSpinner() }
            if logo != nil {
                Button("Use Its Colours") { useLogoColours() }
                    .buttonStyle(.plain)
                    .font(Design.Studio.body)
                    .foregroundStyle(Design.Studio.textQuiet)
            }
            Button { chooseLogo() } label: {
                Text(verbatim: logoFile?.lastPathComponent ?? String(localized: "Add a Logo…")).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140)
            }
            .buttonStyle(StudioFlatButtonStyle())
            .help("The logo animates as the Logo Animator would; its colours can become the brand's")
        }
    }

    /// Frame rate, Export all and Fusion; Export; the format note and how the export goes.
    private var exportRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                LogoKitMenu(title: "Frame Rate", shown: "\(frameRate) fps", selection: $frameRate) {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                .padding(.leading, 8)
                Spacer(minLength: 0)
                Button("Export all…") { export(MotionTemplate.all.filter { $0.category != .logo || logo != nil || $0.id == "sting" }) }
                    .buttonStyle(StudioFlatButtonStyle())
                    .disabled(exporting != nil)
                    .help("Every template, each as its own file")
                fusionMenu
            }
            Button { export([template]) } label: {
                Label("Export…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
            .disabled(exporting != nil)
            Text(template.fullFrame && kit.style.background != nil ? "MP4 with its background" : "ProRes 4444 with transparency")
                .font(Design.Studio.hint)
                .foregroundStyle(Design.Studio.textFaint)
                .frame(maxWidth: .infinity)
            if let exporting {
                StudioProgress(share: exporting)
            } else if let fusionDone {
                LogoKitDone(text: fusionDone.path.hasPrefix(FusionExport.resolveTitles.path)
                            ? Text("In Resolve’s Titles, under Pluck") : Text("Saved \(fusionDone.lastPathComponent)"), file: fusionDone)
            } else if let done {
                LogoKitDone(text: Text("Saved \(done.lastPathComponent)"), file: done)
            }
            if let problem { LogoKitProblem(text: problem) }
        }
    }

    /// The templates as Fusion titles: built from Resolve's own nodes, so text, fonts, colours,
    /// place and size stay editable there.
    private var fusionMenu: some View {
        Menu {
            Button("Add to DaVinci Resolve") { addToResolve([template]) }
                .disabled(!FusionExport.hasResolve || !FusionExport.supports(template))
            Button("Add All to DaVinci Resolve") { addToResolve(MotionTemplate.all) }
                .disabled(!FusionExport.hasResolve)
            Divider()
            Button("Save as Fusion Title…") { saveFusion() }
                .disabled(!FusionExport.supports(template))
        } label: {
            HStack(spacing: 6) {
                Text("Fusion")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(Design.Studio.body)
            .foregroundStyle(Design.Studio.text)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("As a Fusion title for DaVinci Resolve: text, fonts, colours, place and size stay editable there")
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
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(on ? Design.Brand.pink : Design.Studio.line)
                                .frame(width: 18, height: 12)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
        .help("Where it sits. Or drag it on the picture.")
    }

    // MARK: - Pieces

    private static let fonts: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()

    private func fontRow(_ title: LocalizedStringKey, font: Binding<String>) -> some View {
        StudioField(label: title) {
            LogoKitMenu(title: title, shown: font.wrappedValue, selection: font) {
                ForEach(Self.fonts, id: \.self) { Text($0).font(.custom($0, size: 13)).tag($0) }
            }
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
                // The presets take the logo's colours at once (the look chosen changes with Use Its Colours).
                kit.colours = BrandPalette.colours(of: loaded)
                // Still in the neutral colours (no brand's yet): the look takes the logo's now.
                if kit.style.accent == BrandPalette.neutral.primary { kit.apply(MotionPreset.named(kit.presetID) ?? MotionPreset.all[0]) }
            } catch {
                problem = error.localizedDescription
            }
            loadingLogo = false
        }
    }

    /// The logo's colours as the brand's: the chosen preset in them, or (with none chosen) its
    /// accent and a second that reads under text.
    private func useLogoColours() {
        guard let logo else { return }
        kit.colours = BrandPalette.colours(of: logo)
        if let preset = MotionPreset.named(kit.presetID) { kit.apply(preset); return }
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

    private func addToResolve(_ templates: [MotionTemplate]) {
        problem = nil
        do {
            var last: URL?
            for template in templates where FusionExport.supports(template) {
                last = try FusionExport.install(template, style: kit.style, placement: kit.placement(template), canvas: canvas, fps: Double(frameRate))
            }
            fusionDone = templates.count == 1 ? last : FusionExport.resolveTitles
        } catch {
            problem = error.localizedDescription
        }
    }

    private func saveFusion() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pluck \(template.name).setting"
        panel.allowedContentTypes = [UTType(filenameExtension: "setting") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        problem = nil
        do {
            try FusionExport.write(template, style: kit.style, placement: kit.placement(template), canvas: canvas, fps: Double(frameRate), to: url)
            fusionDone = url
        } catch {
            problem = error.localizedDescription
        }
    }

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

/// An inspector slider row as on the board: a quiet 84 pt name, a plum-filled track with a white
/// dot, and the value (when it has one to show) on the right.
private struct SliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var shown = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).frame(width: 84, alignment: .leading)
            ScrubBar(value: $value, range: range)
            Text(verbatim: shown).font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
                .frame(width: 36, alignment: .trailing)
        }
        .frame(height: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: shown.isEmpty ? value.formatted(.percent.precision(.fractionLength(0))) : shown))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}

/// StudioSlider's shape with the board's plum fill: a 3 pt track, plum up to a 12 pt white dot.
private struct ScrubBar: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let x = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span) * width
            ZStack(alignment: .leading) {
                Capsule().fill(Design.Studio.line).frame(height: Design.Studio.sliderTrack)
                Capsule().fill(LinearGradient(colors: [Design.Brand.pink, Design.Brand.violet], startPoint: .leading, endPoint: .trailing))
                    .frame(width: x, height: Design.Studio.sliderTrack)
                Circle().fill(Design.Studio.text).frame(width: Design.Studio.sliderDot, height: Design.Studio.sliderDot)
                    .offset(x: x - Design.Studio.sliderDot / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                value = range.lowerBound + Double(min(max(drag.location.x / width, 0), 1)) * span
            })
        }
        .frame(height: 12)
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
