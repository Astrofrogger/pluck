import CoreImage
import ImageIO
import SwiftUI

/// The Photo page's inspector: the photo's details and rating, the adjustments, the film
/// (spektrafilm: stock, paper, camera, print and every other setting), and the export. With
/// several photos selected, a change applies to all of them.
struct PhotoInspector: View {
    @Binding var tab: Tab
    /// The photos being edited (the selection).
    let paths: [String]
    /// The one shown (its settings fill the controls).
    let focus: String?
    @State private var catalog = PhotoCatalog.shared
    @State private var editing = PhotoEditing.shared
    @State private var naming = false
    @State private var showingLooks = false
    @AppStorage(Prefs.favouriteFilm) private var favouriteFilm = ""

    /// The film on the photo shown, or "Off".
    private var filmName: String {
        guard record.filmOn else { return String(localized: "Off") }
        return FilmEngine.shared.films.first { $0.id == record.film.film }?.name ?? record.film.film
    }
    @State private var presetName = ""

    enum Tab: String, CaseIterable, Identifiable {
        case info, adjust, detail, masks, heal, film, history, export
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .info: "info.circle"
            case .adjust: "slider.horizontal.3"
            case .detail: "camera.aperture"
            case .masks: "circle.dashed.inset.filled"
            case .heal: "bandage"
            case .film: "film"
            case .history: "clock.arrow.circlepath"
            case .export: "square.and.arrow.up"
            }
        }
        var title: LocalizedStringKey {
            switch self {
            case .info: "Info"
            case .adjust: "Adjust"
            case .detail: "Detail"
            case .masks: "Masks"
            case .heal: "Heal"
            case .film: "Film"
            case .history: "History"
            case .export: "Export"
            }
        }
    }

    static let labels = ["red", "orange", "yellow", "green", "blue", "purple"]

    static func labelTitle(_ name: String) -> String {
        switch name {
        case "red": String(localized: "Red")
        case "orange": String(localized: "Orange")
        case "yellow": String(localized: "Yellow")
        case "green": String(localized: "Green")
        case "blue": String(localized: "Blue")
        default: String(localized: "Purple")
        }
    }

    static func labelColor(_ name: String) -> Color {
        switch name {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "blue": .blue
        default: .purple
        }
    }

    private var shown: String? { focus.flatMap { paths.contains($0) ? $0 : nil } ?? paths.first }
    private var record: PhotoRecord { shown.map(catalog.record) ?? PhotoRecord() }

    var body: some View {
        HStack(spacing: 0) {
        VStack(spacing: 0) {
            if paths.count > 1 {
                HStack { Spacer(); syncChip }.padding(.horizontal, 14).padding(.top, 10)
            }
            if paths.isEmpty {
                Text("Select a photo.").font(Design.Studio.body).foregroundStyle(.secondary).padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Cropping: the crop's own panel (its shape and Straighten are on the bar over the photo).
                        if editing.cropping, let shown {
                            PhotoPerspectivePanel(path: shown, record: record)
                        } else {
                        switch tab {
                        case .info: info
                        case .adjust: adjust
                        case .detail: detailTab
                        case .masks: masks
                        case .heal:
                            if let shown {
                                StudioSegmented(options: [(0, LocalizedStringKey("Spots")), (1, LocalizedStringKey("Eyes")), (2, LocalizedStringKey("Liquify"))],
                                                selection: Binding(get: { editing.healMode }, set: { editing.healMode = $0 }))
                                    .padding(.horizontal, 8).padding(.bottom, 4)
                                if editing.healMode == 2 { PhotoLiquifyPanel(path: shown, record: record) }
                                else if editing.healMode == 1 { PhotoEyesPanel(path: shown, record: record) }
                                else { PhotoHealPanel(path: shown, record: record, several: paths.count > 1) }
                            }
                        case .film: PhotoFilmPanel(paths: editTargets, record: record)
                        case .history: if let shown { PhotoHistoryPanel(path: shown) }
                        case .export: PhotoExportPanel(paths: paths)
                        }
                        }
                    }
                    .panelColumn()
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                }
                // Screenshots: -PluckScreenshotPhotoWatermark YES scrolls to the watermark.
                .task {
                    guard ScreenshotMode.scene != nil, UserDefaults.standard.bool(forKey: "PluckScreenshotPhotoWatermark") else { return }
                    try? await Task.sleep(for: .seconds(3))
                    proxy.scrollTo("watermark", anchor: .top)
                }
                }
            }
        }
        tabStrip
        }
        .onChange(of: tab) { _, now in
            if now != .masks { editing.selectedMask = nil; editing.hoverMask = nil }
            if now != .heal { editing.selectedSpot = nil }
            if now != .adjust {
                editing.mixerTargeting = false; editing.pointPicking = false; editing.pointOverlay = false
                editing.focusPicking = false; editing.showDepth = false
            }
        }
        .onChange(of: tab, initial: true) { editing.healing = tab == .heal }
        .onDisappear { editing.healing = false }
    }

    /// The tools, as icons down the right edge: Adjust, Detail, Masks, Heal, Film, Looks, Info (Crop is in the title row: the
    /// owner, 2026-11-13); at the foot,
    /// the scope shown over Adjust, and Export.
    private var tabStrip: some View {
        VStack(spacing: 4) {
            Button("") { tab = .adjust; editing.findingTool = true }
                .keyboardShortcut("f")
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            stripButton(.adjust)
            stripButton(.detail)
            stripButton(.masks)
            stripButton(.heal)
            stripButton(.film)
            presetsMenu
            stripButton(.history)
            stripButton(.info)
            Spacer(minLength: 8)
            scopeMenu
            stripButton(.export)
        }
        .padding(.vertical, 10)
        .frame(width: 44)
        .overlay(alignment: .leading) { Rectangle().fill(Design.Studio.raised).frame(width: 1) }
    }

    private func stripButton(_ item: Tab) -> some View {
        stripIcon(item.symbol, on: tab == item) { tab = item }
            .help(Text(item.title))
            .accessibilityLabel(Text(item.title))
            .accessibilityAddTraits(tab == item ? .isSelected : [])
    }

    private func stripIcon(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? Color.white : Design.Studio.textQuiet)
                .frame(width: 28, height: 28)
                .background(on ? AnyShapeStyle(Design.Brand.deep) : AnyShapeStyle(Color.clear),
                            in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Which scope sits over Adjust (histogram, waveform, parade, vectorscope).
    @AppStorage("photoScopeKind") private var scopeKind = "histogram"
    @Environment(\.openWindow) private var openWindow
    private var scopeMenu: some View {
        Menu {
            Picker("Scope", selection: $scopeKind) {
                Text("Histogram").tag("histogram")
                ForEach(ScopeKind.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Open Scopes Window (⌥⌘K)") { openWindow(id: "scopes") }
        } label: {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Design.Studio.textQuiet)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Scope")
        .accessibilityLabel(Text("Scope"))
    }

    /// "Editing 12": changes reach all selected photos; click to change only the one shown.
    private var syncChip: some View {
        let on = editing.syncAll
        return Button { editing.syncAll.toggle() } label: {
            Text(on ? "Editing \(paths.count)" : "Editing 1")
                .font(Design.Studio.hint.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(on ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(.quaternary)))
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(on ? Text("Changes reach all \(paths.count) selected photos. Click to change only the photo shown.")
                 : Text("Changes reach only the photo shown. Click to change all \(paths.count) selected photos."))
        .accessibilityValue(Text(on ? "All selected photos" : "Only the photo shown"))
    }

    private func change(_ body: @escaping (inout PhotoRecord) -> Void) {
        editing.edit(paths, shown: shown, body)
    }

    /// The photos an edit reaches (all selected, or only the one shown while sync is off).
    private var editTargets: [String] { editing.targets(paths, shown: shown) }

    // MARK: - Info

    private var info: some View {
        VStack(alignment: .leading, spacing: 14) {
            SidebarSection(title: Text("Rating")) {
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { star in
                        Button { catalog.update(paths) { $0.rating = $0.rating == star ? 0 : star } } label: {
                            Image(systemName: star <= record.rating ? "star.fill" : "star")
                                .font(.system(size: 16))
                                .foregroundStyle(star <= record.rating ? Color.yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Picker("Flag", selection: Binding(get: { record.flag }, set: { flag in catalog.update(paths) { $0.flag = flag } })) {
                        Image(systemName: "flag.fill").tag(PhotoRecord.Flag.pick).help("Pick (P)")
                        Image(systemName: "minus").tag(PhotoRecord.Flag.none).help("Not flagged (U)")
                        Image(systemName: "xmark").tag(PhotoRecord.Flag.reject).help("Reject (X)")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 110)
                }
                .padding(.horizontal, 8)
            }
            SidebarSection(title: Text("Label")) {
                HStack(spacing: 8) {
                    Button { catalog.update(paths) { $0.label = nil } } label: {
                        Image(systemName: "circle.slash").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    ForEach(Self.labels, id: \.self) { name in
                        Button { catalog.update(paths) { $0.label = name } } label: {
                            Circle().fill(Self.labelColor(name)).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 2).opacity(record.label == name ? 1 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
            if let shown { PhotoDetails(path: shown) }
            PhotoMetaSection(paths: paths, record: record)
            if let shown { PhotoTagsSection(path: shown) }
            SidebarSection(title: Text("Settings")) {
                HStack(spacing: 8) {
                    Button("Copy") { PhotoPasteboard.copied = record }
                        .help("Copy this photo’s adjustments and film")
                    Menu("Paste") {
                        Button("Choose What to Paste…") { choosingPaste = true }
                    } primaryAction: {
                        paste(PasteGroup.chosen)
                    }
                    .fixedSize()
                    .disabled(PhotoPasteboard.copied == nil)
                    .help("Give the selected photos the copied adjustments and film (or choose which)")
                    Spacer()
                    Button("Reset", role: .destructive) { change { $0.adjust = PhotoAdjustments(); $0.filmOn = false; $0.film = FilmSettings() } }
                }
                .controlSize(.small)
                .padding(.horizontal, 8)
                if paths.count > 1 {
                    HStack {
                        Button("Match Exposure") { matchExposure() }
                            .help("Gives the selected photos this one’s brightness")
                        if matching { ProgressView().controlSize(.small) }
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 8)
                }
            }
            if let shown, paths.count == 1 {
                SidebarSection(title: Text("Snapshots")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(record.snapshots.reversed()) { snapshot in
                            HStack {
                                Button { catalog.restore(snapshot, on: shown) } label: {
                                    Label(snapshot.name, systemImage: "camera.metering.center.weighted").lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .help("Go back to this look")
                                Spacer()
                                Button { catalog.deleteSnapshot(snapshot.id, of: shown) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                            .font(Design.Studio.body)
                        }
                        Button("Keep This Look", systemImage: "plus") { catalog.takeSnapshot(of: shown) }
                            .buttonStyle(.link).font(Design.Studio.body)
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .sheet(isPresented: $choosingPaste) {
            PasteChooser(count: paths.count) { groups in paste(groups) }
        }
    }

    /// Part (or all) of the copied settings onto the selected photos.
    private func paste(_ groups: Set<PasteGroup>) {
        PhotoPasteboard.paste(groups, to: paths)
    }

    /// The selected photos as bright as the one shown: each one's middle (faces weighed most)
    /// put where this one's is.
    private func matchExposure() {
        guard let shown else { return }
        let targets = paths.filter { $0 != shown }
        let reference = catalog.record(shown)
        let records = Dictionary(uniqueKeysWithValues: targets.map { ($0, catalog.record($0)) })
        matching = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [String: Double] in
                guard let middle = PhotoRender.middle(shown, record: reference) else { return [:] }
                let goal = middle + reference.adjust.exposure
                var exposures: [String: Double] = [:]
                for (path, record) in records {
                    if let own = PhotoRender.middle(path, record: record) { exposures[path] = ((goal - own) * 20).rounded() / 20 }
                }
                return exposures
            }.value
            for (path, exposure) in found {
                catalog.update([path]) { $0.adjust.exposure = min(max(exposure, -5), 5); $0.edited = .now }
            }
            matching = false
        }
    }

    @State private var choosingPaste = false
    @State private var matching = false

    // MARK: - Adjust

    private var adjust: some View {
        let raw = shown.map(PhotoRender.isRaw) ?? false
        return VStack(alignment: .leading, spacing: 10) {
            if !editing.histogram.isEmpty {
                PhotoScopeView(bins: editing.histogram, data: editing.scopes) { path, share in
                    // Exposure moves in stops (the width is 4), the rest in their own range.
                    let scale = path == \PhotoAdjustments.exposure ? 4.0 : 200.0
                    change { $0.adjust[keyPath: path] = min(max($0.adjust[keyPath: path] + share * scale, path == \PhotoAdjustments.exposure ? -5 : -100),
                                                         path == \PhotoAdjustments.exposure ? 5 : 100) }
                }
            }
            HStack(spacing: 6) {
                // (Classic is As Shot on a photo that isn't RAW.)
                let profile = record.adjust.profile.map { !raw && $0 == .adobe ? .asShot : $0 } ?? PhotoEngine.Profile.starting(record.adjust, isRaw: raw)
                Menu {
                    Picker("Profile", selection: Binding(get: { profile }, set: { value in change { $0.adjust.profile = value } })) {
                        ForEach(PhotoEngine.Profile.choices(raw: raw, process: record.adjust.process, chosen: record.adjust.profile)) { Text($0.name(process: record.adjust.process)).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Auto", systemImage: "wand.and.stars") { autoTone() }
                } label: {
                    InspectorPair(name: "Profile", value: Text(profile.name(process: record.adjust.process)))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("The starting point: how the light becomes a picture, the same for every camera")
                Button { tab = .film } label: {
                    InspectorPair(name: "Film", value: Text(verbatim: filmName), star: record.filmOn && record.film.film == favouriteFilm)
                }
                .buttonStyle(.plain)
                .help("Film")
            }
            .padding(.horizontal, 8)
            if let look = record.adjust.lookName, record.adjust.lookTable != nil {
                // A creative profile from Lightroom: how much of it.
                slider(LocalizedStringKey(look), \.lookAmount, 0...200, neutral: 100, format: "%.0f")
            }
            // (Process 4 changed only RAWs; process 5 changes a JPEG's profiles too, so a JPEG on 3 or 4 is offered it.)
            if record.adjust.process < PhotoAdjustments.currentProcess {
                // Edited with the first engine: kept as it was until asked.
                HStack(spacing: 8) {
                    Label("Earlier engine", systemImage: "clock.arrow.circlepath").font(Design.Studio.hint).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Update") {
                        // (Each photo's own: change reaches editTargets in this order.)
                        var raws = editTargets.map(PhotoRender.isRaw).makeIterator()
                        change { $0.adjust = $0.adjust.updated(isRaw: raws.next() ?? raw) }
                    }
                    .help("Develop with the current engine, as Lightroom does: wider colour, its tone curve and brightness. The profile stays, but the look changes.")
                }
                .controlSize(.small)
                .padding(.horizontal, 8)
            }
            // Shown with ⌘F (or while it has words), so it's there without taking room.
            if editing.findingTool || !editing.toolQuery.isEmpty { ToolSearchField() }
            let jumps = ToolJump.allCases.filter { $0.matches(editing.toolQuery) }
            if !jumps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(jumps, id: \.self) { jump in
                        Button { go(jump) } label: { Label(jump.title, systemImage: jump.symbol) }
                            .buttonStyle(.link)
                    }
                }
                .font(Design.Studio.body)
                .padding(.horizontal, 8)
            }
            AdjustFold(title: "Negative", section: .negative, adjust: record.adjust, reset: { resetSection(.negative) }) {
                PhotoNegativeControls(path: shown, record: record, change: change)
            }
            AdjustFold(title: "Light", section: .light, adjust: record.adjust, open: true, reset: { resetSection(.light) }) {
                slider("Exposure", \.exposure, -5...5, format: "%+.2f", clipping: true)
                slider("Contrast", \.contrast, -100...100)
                slider("Highlights", \.highlights, -100...100, clipping: true)
                slider("Shadows", \.shadows, -100...100, clipping: true)
                slider("Whites", \.whites, -100...100, clipping: true)
                slider("Blacks", \.blacks, -100...100, clipping: true)
                if record.adjust.process >= 6 {
                    slider("Highlight Roll-off", \.rolloffAmount, -100...100)
                    HStack(spacing: 8) {
                        Text("Tone Engine").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                        Spacer(minLength: 0)
                        StudioSegmented(ground: Design.Studio.panel, options: [(false, LocalizedStringKey("AgX")), (true, LocalizedStringKey("Basic"))], selection: Binding(
                            get: { record.adjust.toneEngine == .basic },
                            set: { basic in change { $0.adjust.toneEngine = basic ? .basic : nil } }))
                            .fixedSize()
                    }
                    .padding(.horizontal, Design.Sidebar.rowPadding)
                    .help("AgX keeps each colour's hue into white; Basic is punchier, its colours drifting in bright light")
                }
            }
            AdjustFold(title: "Colour", section: .colour, adjust: record.adjust, open: true, reset: { resetSection(.colour) }) {
                if raw, let path = shown {
                    let kelvin = PhotoEngine.kelvin(record.adjust, asShot: PhotoRender.asShotKelvin(path))
                    slider("Temperature", \.temperature, -100...100, label: "\(Int((kelvin / 50).rounded() * 50)) K", track: .temperature)
                } else {
                    slider("Temperature", \.temperature, -100...100, track: .temperature)
                }
                slider("Tint", \.tint, -100...100, track: .tint)
                slider("Vibrance", \.vibrance, -100...100, track: .saturation)
                slider("Saturation", \.saturation, -100...100, track: .saturation)
            }
            AdjustFold(title: "Presence", section: .presence, adjust: record.adjust, reset: { resetSection(.presence) }) {
                slider("Texture", \.texture, -100...100)
                slider("Clarity", \.clarity, -100...100)
                slider("Dehaze", \.dehaze, -100...100)
                slider("Smooth Skin", \.skinAmount, 0...100)
                slider("Vignette", \.vignette, -100...100)
                if record.adjust.vignette != 0 {
                    slider("Midpoint", \.vignetteMidpoint, 0...100, neutral: 50)
                    slider("Feather", \.vignetteFeather, 0...100, neutral: 50)
                    slider("Roundness", \.vignetteRoundness, 0...100, neutral: 100)
                    slider("Highlights", \.vignetteHighlights, 0...100)
                }
            }
            AdjustFold(title: "Colour Mixer", section: .mixer, adjust: record.adjust, reset: { resetSection(.mixer) }) {
                ColorMixerEditor(mixer: record.adjust.mixer, points: record.adjust.process >= 5 && !record.filmOn) { mixer in change { $0.adjust.mixer = mixer } }
            }
            AdjustFold(title: "Curves", section: .curves, adjust: record.adjust, reset: { resetSection(.curves) }) {
                CurvesEditor(curves: record.adjust.curves, part: .tone) { curves in change { $0.adjust.curves = curves } }
            }
            // (Process 5 without film, as before: these work on the shown picture.)
            if record.adjust.process >= 5 && !record.filmOn {
                AdjustFold(title: "Colour curves", section: .colourCurves, adjust: record.adjust, reset: { resetSection(.colourCurves) }) {
                    CurvesEditor(curves: record.adjust.curves, colour: true, start: .hueHue, part: .colour) { curves in change { $0.adjust.curves = curves } }
                }
                AdjustFold(title: "Colour Warper", section: .warper, adjust: record.adjust, reset: { resetSection(.warper) }) {
                    CurvesEditor(curves: record.adjust.curves, colour: true, warper: true, part: .warper) { curves in change { $0.adjust.curves = curves } }
                }
            }
            AdjustFold(title: "Colour Wheels", section: .wheels, adjust: record.adjust, reset: { resetSection(.wheels) }) {
                ColorWheelsEditor(wheels: record.adjust.wheels, path: shown, process: record.adjust.process) { wheels in change { $0.adjust.wheels = wheels } }
            }
            AdjustFold(title: "Calibration", section: .calibration, adjust: record.adjust, reset: { resetSection(.calibration) }) {
                slider("Shadows Tint", \.calibration.shadowTint, -100...100, track: .tint)
                let primaries: [(LocalizedStringKey, WritableKeyPath<Calibration, Double>, WritableKeyPath<Calibration, Double>, Color)] = [
                    ("Red Primary", \.redHue, \.redSaturation, .red), ("Green Primary", \.greenHue, \.greenSaturation, .green),
                    ("Blue Primary", \.blueHue, \.blueSaturation, .blue),
                ]
                ForEach(primaries.indices, id: \.self) { i in
                    let (title, hue, saturation, colour) = primaries[i]
                    Text(title).font(Design.Studio.hint).foregroundStyle(.secondary)
                        .padding(.horizontal, Design.Sidebar.rowPadding).padding(.top, 4)
                    slider("Hue", (\PhotoAdjustments.calibration).appending(path: hue), -100...100)
                    slider("Saturation", (\PhotoAdjustments.calibration).appending(path: saturation), -100...100, track: .colour(colour))
                }
            }
            // Glow and grain for a photo without film (the film makes its own).
            if !record.filmOn {
                AdjustFold(title: "Effects", section: .effects, adjust: record.adjust, reset: { resetSection(.effects) }) {
                    if record.adjust.process >= 5 { GlowControls(adjust: record.adjust) { edit in change { edit(&$0.adjust) } } }
                    slider("Grain", \.grain, 0...100)
                    if record.adjust.grain > 0 {
                        slider("Size", \.grainSize, 0...100, neutral: 25)
                        slider("Roughness", \.grainRoughness, 0...100, neutral: 50)
                    }
                }
            }
            AdjustFold(title: "Depth", section: .depth, adjust: record.adjust, reset: { resetSection(.depth) }) {
                PhotoDepthControls(adjust: record.adjust) { edit in
                    change { var d = $0.adjust.depth ?? PhotoDepthEffects(); edit(&d); $0.adjust.depth = d }
                }
            }
            Button("Reset Adjustments") { change { $0.adjust = PhotoAdjustments() } }
                .buttonStyle(.link)
                .padding(.horizontal, 8)
        }
    }

    /// Masks: their own place, so it's always clear which one is being shaped.
    @ViewBuilder private var masks: some View {
        if record.adjust.process >= 2, let shown, paths.count == 1 {
            PhotoMaskPanel(path: shown, record: record)
        } else if paths.count > 1 {
            Text("Masks are made one photo at a time.").font(Design.Studio.body).foregroundStyle(.secondary).padding(.horizontal, 8)
        } else {
            masksSection
        }
    }

    private var masksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(PhotoMask.Kind.allCases, id: \.self) { kind in
                    Button(kind == .subject ? "Select Subject" : "Select Background", systemImage: kind.symbol) {
                        change { $0.adjust.masks.append(PhotoMask(kind: kind)) }
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            ForEach(record.adjust.masks) { mask in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Label(mask.kind.title, systemImage: mask.kind.symbol).font(Design.Studio.body.weight(.medium))
                        Spacer()
                        Button { change { $0.adjust.masks.removeAll { $0.id == mask.id } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    maskSlider("Exposure", mask, \.exposure, -3...3, "%+.2f")
                    maskSlider("Contrast", mask, \.contrast, -100...100, "%+.0f")
                    maskSlider("Saturation", mask, \.saturation, -100...100, "%+.0f")
                    maskSlider("Warmth", mask, \.warmth, -100...100, "%+.0f")
                    maskSlider("Clarity", mask, \.clarity, -100...100, "%+.0f")
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Design.Radius.small).fill(Color.primary.opacity(0.04)))
            }
        }
    }

    private func maskSlider(_ title: LocalizedStringKey, _ mask: PhotoMask, _ path: WritableKeyPath<PhotoMask, Double>,
                            _ range: ClosedRange<Double>, _ format: String) -> some View {
        let value = mask[keyPath: path]
        return HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).lineLimit(1).frame(width: Design.Sidebar.sliderLabel, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { new in
                change { record in if let i = record.adjust.masks.firstIndex(where: { $0.id == mask.id }) { record.adjust.masks[i][keyPath: path] = new } }
            }), in: range)
            Text(String(format: format, value)).font(Design.Studio.hint.monospacedDigit()).foregroundStyle(value == 0 ? .tertiary : .primary)
                .frame(width: 44, alignment: .trailing)
        }
        .font(Design.Studio.body)
        .controlSize(.small)
        .padding(.horizontal, Design.Sidebar.rowPadding)
        .frame(minHeight: Design.Sidebar.sliderHeight)
    }

    /// Lightroom's Auto, from the photo developed plain, for each photo being edited.
    private func autoTone() {
        let targets = editTargets
        Task {
            for path in targets {
                let record = catalog.record(path)
                let found: PhotoAdjustments
                if record.adjust.process >= 2 {
                    guard let measured = await Task.detached(priority: .userInitiated, operation: { PhotoRender.auto(path, record: record) }).value
                    else { continue }
                    found = measured
                } else {
                    var plain = PhotoRecord()
                    plain.adjust.process = 1
                    plain.adjust.profile = record.adjust.profile
                    guard let picture = await PhotoRender.quick(path, record: plain, maxSize: 512) else { continue }
                    found = PhotoEngine.auto(picture)
                }
                catalog.update([path]) { record in
                    record.adjust.exposure = found.exposure
                    record.adjust.highlights = found.highlights
                    record.adjust.shadows = found.shadows
                    record.adjust.whites = found.whites
                    record.adjust.blacks = found.blacks
                    record.adjust.vibrance = found.vibrance
                    record.edited = .now
                }
            }
        }
    }

    private var portraitPhoto: Bool { shown.map(PhotoRender.isPortrait) ?? false }

    @State private var film = FilmEngine.shared

    @AppStorage("photoDenoiseAI") private var denoiseAI = false

    /// Denoise, as Lightroom's: a switch, Standard (non-local means) or AI (a network trained on real camera
    /// noise, an optional download), and an Amount. The noise is worked out once per photo; the Amount is live.
    private var denoise: some View {
        let busy = paths.filter(editing.denoising.contains).count
        let on = record.denoise > 0
        let ready = shown.map { PhotoRender.hasClean($0, record: record) } ?? false
        let modelMissing = denoiseAI && film.denoiser != .ready
        return VStack(alignment: .leading, spacing: 6) {
            if film.denoiseEngine != .ready {
                switch film.denoiseEngine {
                case .installing:
                    ProgressView(value: film.denoiseProgress)
                    Text("Getting the denoise engine…").font(Design.Studio.hint).foregroundStyle(.secondary)
                case .failed(let message):
                    ProblemLabel(text: message)
                    Button("Try Again") { film.installDenoiseEngine() }
                default:
                    Text("Removes noise at full size, done once per photo. Runs on this Mac.").font(Design.Studio.hint).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Get Denoise (\(FilmEngine.denoiseEngineDownloadMB) MB)", systemImage: "arrow.down") { film.installDenoiseEngine() }
                }
            } else if busy > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Removing noise from ^[\(busy) photo](inflect: true)…").font(Design.Studio.body).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Toggle("Denoise", isOn: Binding(get: { on }, set: { new in
                        if new { editing.denoise(editTargets, ai: denoiseAI) } else { change { $0.denoise = 0 } }
                    }))
                    .toggleStyle(.checkbox)
                    .font(Design.Studio.body)
                    .disabled(modelMissing && !on)
                    Spacer()
                    Picker("Denoise", selection: Binding(get: { denoiseAI }, set: { ai in
                        denoiseAI = ai
                        if on, !(ai && film.denoiser != .ready) { editing.denoise(editTargets, ai: ai) }
                    })) {
                        Text("Standard").tag(false)
                        Text("AI").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if modelMissing {
                    aiOffer
                } else if denoiseAI, film.denoiserUpdate {
                    // Version 1 (no RAW part) keeps working until this.
                    Button("Update AI Denoise (\(FilmEngine.denoiserUpdateMB) MB)", systemImage: "arrow.down") { film.installDenoiser() }
                        .help("Cleans RAW photos from the sensor’s own data: crisper detail, cleaner shadows.")
                    if let problem = film.denoiserProblem { ProblemLabel(text: problem) }
                }
                if !modelMissing, on {
                    // Mixed live with the photo as it's drawn: never worked out again.
                    AdjustSlider(title: "Amount", value: Double(record.denoise), range: 0...100, neutral: 50, format: "%.0f") { new in
                        // (At least 1: 0 is off, which the checkbox does, and would take the slider away mid-drag.)
                        change { $0.denoise = max(1, Int(new.rounded())) }
                    }
                    .padding(.horizontal, -Design.Sidebar.rowPadding)
                    .disabled(!ready)
                    if ready {
                        Text("Compare at 100%.").font(Design.Studio.hint).foregroundStyle(.secondary)
                    }
                }
            }
            if let problem = editing.denoiseProblem { ProblemLabel(text: problem) }
        }
        .controlSize(.small)
        .padding(.horizontal, Design.Sidebar.rowPadding)
        .padding(.top, 4)
        .onAppear {
            film.checkDenoiser()
            if on { denoiseAI = record.denoiseAI }
        }
        // A photo denoised before version 2 (or whose decoder settings changed) is worked out again, once.
        // (And once the AI denoiser's RAW part arrives: a RAW is cleaned from its mosaic then.)
        .task(id: "\(shown ?? "")|\(record.denoise > 0)|\(record.denoiseAI)|\(PhotoRender.RawSettings(record.adjust).key)|\(film.denoiseEngine == .ready)|\(film.denoiser == .ready)|\(film.denoiserUpdate)") {
            if on { denoiseAI = record.denoiseAI }
            guard on, film.denoiseEngine == .ready, !record.denoiseAI || film.denoiser == .ready else { return }
            editing.analyse(editTargets)
        }
    }

    @ViewBuilder private var aiOffer: some View {
        switch film.denoiser {
        case .installing:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: film.denoiserProgress)
                Text("Getting the AI denoiser…").font(Design.Studio.hint).foregroundStyle(.secondary)
            }
        case .failed(let message):
            ProblemLabel(text: message)
            Button("Try Again") { film.installDenoiser() }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text("A network trained on real camera noise, like Lightroom’s. Runs on this Mac’s GPU.")
                    .font(Design.Studio.hint).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Label("\(FilmEngine.denoiserDownloadMB) MB download", systemImage: "arrow.down.circle")
                    Label("\(FilmEngine.denoiserDiskMB) MB on disk", systemImage: "internaldrive")
                }
                .font(Design.Studio.hint).foregroundStyle(.secondary)
                Button("Get AI Denoise", systemImage: "arrow.down") { film.installDenoiser() }
                    .buttonStyle(BrandButtonStyle(large: false))
            }
        }
    }

    private var autoButton: some View {
        Button("Auto", systemImage: "wand.and.stars") { autoTone() }
            .fixedSize()
            .help("Exposure, highlights, shadows, whites and blacks for this photo")
    }

    private var presetsMenu: some View {
        HStack(spacing: 8) {
            stripIcon("square.grid.2x2", on: showingLooks) { showingLooks = true }
            .help("Looks: profiles and presets, as pictures of this photo")
            .accessibilityLabel(Text("Looks"))
            .onAppear { if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotLooks") { showingLooks = true } }
            .popover(isPresented: $showingLooks, arrowEdge: .leading) {
                if let shown {
                    PhotoLooks(path: shown, record: record) { look, lightroom in
                        if let lightroom {
                            var raws = editTargets.map(PhotoRender.isRaw).makeIterator()
                            change { $0.adjust = LightroomPresets.adjustments(lightroom, base: $0.adjust.current(isRaw: raws.next() ?? false)).0 }
                        } else {
                            change { $0.adjust = look.adjust; $0.filmOn = look.filmOn; $0.film = look.film }
                        }
                    } save: {
                        showingLooks = false
                        presetName = ""
                        naming = true
                    }
                }
            }
        }
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { catalog.savePreset(named: name, from: record) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps these adjustments and the film, to use on other photos. Masks of the sky, subject, people and faces are found again on each photo; brushed areas aren’t kept.")
        }
    }

    /// The Detail tab (the owner, 2026-11-13): sharpening, noise and denoise, and the lens's corrections.
    @ViewBuilder private var detailTab: some View {
        let raw = shown.map(PhotoRender.isRaw) ?? false
            AdjustFold(title: "Detail", section: .detail, adjust: record.adjust, reset: { resetSection(.detail) }) {
                slider("Sharpen", \.sharpen, 0...100)
                if record.adjust.process >= 5, record.adjust.sharpen > 0 { slider("Masking", \.sharpenMask, 0...100, format: "%.0f") }
                // Lightroom's manual noise reduction. A denoised RAW is decoded without it (Denoise does it instead).
                if !raw || record.denoise == 0 {
                    Text("Noise").font(Design.Studio.hint).foregroundStyle(.secondary)
                        .padding(.horizontal, Design.Sidebar.rowPadding).padding(.top, 4)
                    if raw, record.adjust.process >= 5, let shown {
                        // (Process 5: starts at the amount the ISO asks for; 0 is none, the decoder's too.)
                        let auto = PhotoRender.autoLuminance(iso: PhotoRender.iso(PhotoCatalog.file(of: shown)))
                        AdjustSlider(title: "Luminance", value: PhotoRender.luminance(record.adjust, path: shown), range: 0...100,
                                     neutral: auto) { new in change { $0.adjust.noise = new; $0.adjust.noiseSet = true } }
                    } else {
                        slider("Luminance", \.noise, 0...100)
                    }
                    if raw { slider("Colour", \.colorNoise, 0...100, neutral: PhotoAdjustments.defaultColorNoise) }
                }
                if raw { slider("Moiré", \.moire, 0...100) }
                denoise
            }
        if let shown { PhotoLensPanel(path: shown, record: record) }
        if PhotoUpscale.isSupported, let shown { PhotoSuperResolutionRow(path: shown) }
    }

    private func slider(_ title: LocalizedStringKey, _ path: WritableKeyPath<PhotoAdjustments, Double>, _ range: ClosedRange<Double>,
                        neutral: Double = 0, format: String = "%+.0f", label: String? = nil, track: AdjustSlider.Track = .plain,
                        clipping: Bool = false) -> some View {
        AdjustSlider(title: title, value: record.adjust[keyPath: path], range: range, neutral: neutral, format: format, label: label, track: track,
                     clipping: clipping) { new in change { $0.adjust[keyPath: path] = new } }
    }

    /// A tool found by the search that lives elsewhere: there.
    private func go(_ jump: ToolJump) {
        editing.toolQuery = ""
        switch jump {
        case .crop: editing.cropping = true
        case .detail: tab = .detail
        case .masks: tab = .masks
        case .film: tab = .film
        case .looks: showingLooks = true
        case .export: tab = .export
        case .auto: autoTone()
        }
    }

    private func resetSection(_ section: AdjustSection) {
        change { section.reset(&$0.adjust) }
        if editing.peek == section { editing.peek = nil }
    }
}

// MARK: - Details

/// Process 5's Glow (Effects): how much, how far, and how it's laid on the picture (shown once there's some).
struct GlowControls: View {
    let adjust: PhotoAdjustments
    let change: (@escaping (inout PhotoAdjustments) -> Void) -> Void

    var body: some View {
        AdjustSlider(title: "Glow", value: adjust.glow, range: 0...100, format: "%.0f") { v in change { $0.glow = v } }
        if adjust.glow > 0 {
            AdjustSlider(title: "Size", value: adjust.glowSize, range: 0...100, neutral: 50, format: "%.0f") { v in change { $0.glowSize = v } }
            HStack(spacing: 8) {
                Text("Blend").foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Picker("Blend", selection: Binding(get: { adjust.glowMode }, set: { mode in change { $0.glowMode = mode } })) {
                    ForEach(PhotoAdjustments.GlowMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .font(Design.Studio.body)
            .controlSize(.small)
            .padding(.horizontal, Design.Sidebar.rowPadding)
            .frame(minHeight: 26)
        }
    }
}

/// What the camera wrote: the file, its size, the camera and lens, the exposure.
/// What Vision saw in the photo, as quiet chips: a click finds the photos with it, its menu makes it a keyword.
struct PhotoTagsSection: View {
    let path: String
    @State private var catalog = PhotoCatalog.shared
    @State private var editing = PhotoEditing.shared
    @AppStorage("photoView") private var view = PhotoPage.ViewMode.grid

    var body: some View {
        if let tags = catalog.tags(of: path), !tags.words.isEmpty {
            SidebarSection(title: Text("Found in the photo")) {
                FlowLayout(spacing: 6) {
                    if let faces = tags.faces, faces > 0 { chip(Text("^[\(faces) face](inflect: true)"), finds: "face", keyword: nil) }
                    ForEach(tags.labels, id: \.self) { chip(Text(verbatim: $0), finds: $0, keyword: $0) }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func chip(_ text: Text, finds word: String, keyword: String?) -> some View {
        Button { editing.search = word; view = .grid } label: { StudioChip(text: text) }
            .buttonStyle(.plain)
            .help("Find photos with this")
            .contextMenu { if let keyword { Button("Add as Keyword") { add(keyword) } } }
    }

    private func add(_ word: String) {
        var meta = catalog.record(path).meta ?? PhotoMeta()
        guard !meta.keywords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return }
        meta.keywords.append(word)
        catalog.setMeta([path: meta])
    }
}

struct PhotoDetails: View {
    let path: String
    @State private var lines: [(String, String)] = []

    var body: some View {
        SidebarSection(title: Text("Details")) {
            ForEach(lines, id: \.0) { line in
                HStack {
                    Text(line.0).foregroundStyle(.secondary)
                    Spacer()
                    Text(line.1).lineLimit(1).truncationMode(.middle)
                }
                .font(Design.Studio.hint)
                .padding(.horizontal, 8)
                .frame(minHeight: 20)
            }
        }
        .task(id: path) { lines = Self.read(path) }
    }

    /// "Z8 · 24-70 at 35 mm · ƒ/8 · 1/250 s · ISO 64": camera, lens and exposure on one line.
    nonisolated static func summary(_ path: String) -> String {
        let url = URL(fileURLWithPath: PhotoCatalog.file(of: path))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return "" }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        var parts: [String] = []
        if let model = tiff?[kCGImagePropertyTIFFModel] as? String { parts.append(model) }
        let focal = (exif?[kCGImagePropertyExifFocalLength] as? Double).map { "\(Int($0)) mm" }
        if let lens = exif?[kCGImagePropertyExifLensModel] as? String {
            parts.append(focal.map { String(localized: "\(lens) at \($0)") } ?? lens)
        } else if let focal { parts.append(focal) }
        if let number = exif?[kCGImagePropertyExifFNumber] as? Double { parts.append(String(format: "ƒ/%g", number)) }
        if let time = exif?[kCGImagePropertyExifExposureTime] as? Double {
            parts.append(time >= 1 ? String(format: "%.1f s", time) : "1/\(Int((1 / time).rounded()))")
        }
        if let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { parts.append("ISO \(iso)") }
        return parts.joined(separator: " · ")
    }

    nonisolated static func read(_ path: String) -> [(String, String)] {
        let url = URL(fileURLWithPath: PhotoCatalog.file(of: path))
        var lines: [(String, String)] = [(String(localized: "File"), url.lastPathComponent)]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return lines }
        if let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            lines.append((String(localized: "Size"), "\(width) × \(height)"))
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        if let model = tiff?[kCGImagePropertyTIFFModel] as? String { lines.append((String(localized: "Camera"), model)) }
        if let lens = exif?[kCGImagePropertyExifLensModel] as? String { lines.append((String(localized: "Lens"), lens)) }
        var exposure: [String] = []
        if let focal = exif?[kCGImagePropertyExifFocalLength] as? Double { exposure.append("\(Int(focal)) mm") }
        if let number = exif?[kCGImagePropertyExifFNumber] as? Double { exposure.append(String(format: "ƒ/%.1f", number)) }
        if let time = exif?[kCGImagePropertyExifExposureTime] as? Double {
            exposure.append(time >= 1 ? String(format: "%.1f s", time) : "1/\(Int((1 / time).rounded())) s")
        }
        if let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if !exposure.isEmpty { lines.append((String(localized: "Exposure"), exposure.joined(separator: " · "))) }
        if let date = exif?[kCGImagePropertyExifDateTimeOriginal] as? String { lines.append((String(localized: "Taken"), date)) }
        return lines
    }
}

// MARK: - Film

/// spektrafilm: downloaded here when asked (with the size and a progress bar), then the film
/// stock, the paper, the camera and print settings, the film's grain and halation, and every
/// other setting spektrafilm has.
private struct PhotoFilmPanel: View {
    let paths: [String]
    let record: PhotoRecord
    @State private var engine = FilmEngine.shared
    @State private var catalog = PhotoCatalog.shared
    @AppStorage("photoFilmAdvanced") private var advancedOpen = false
    @AppStorage(Prefs.favouriteFilm) private var favouriteFilm = ""

    var body: some View {
        if FilmTables.shared.isAvailable {
            // The film's tables come with Pluck: the film data is only for the advanced settings, offered when one is changed.
            VStack(alignment: .leading, spacing: 10) {
                if needsPack { packOffer }
                controls
            }
        } else {
            switch engine.state {
            case .notInstalled: offer
            case .installing: installing
            case .failed: failed
            case .ready: controls
            }
        }
        credit
    }

    /// A setting the shipped tables can't do is changed, the film data isn't here yet, and this photo's own tables
    /// aren't made already (in memory or on disk).
    private var needsPack: Bool {
        guard engine.state != .ready, record.filmOn, !FilmRoute.ready(record.film) else { return false }
        if case .tables(let key) = FilmRoute.of(record.film), FilmAdvanced.onDisk(key) { return false }
        return true
    }

    @ViewBuilder private var failed: some View {
        if case .failed(let message) = engine.state {
            VStack(alignment: .leading, spacing: 10) {
                ProblemLabel(text: message)
                Button("Try Again") { engine.install() }.buttonStyle(BrandButtonStyle(large: false))
            }
            .padding(.horizontal, 8)
        }
    }

    @ViewBuilder private var packOffer: some View {
        switch engine.state {
        case .installing: installing
        case .failed: failed
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text("This setting needs the film data.").font(Design.Studio.body.weight(.semibold))
                HStack(spacing: 14) {
                    Label("\(FilmEngine.downloadMB) MB download", systemImage: "arrow.down.circle")
                    Label("\(FilmEngine.diskMB) MB on disk", systemImage: "internaldrive")
                }
                .font(Design.Studio.hint)
                .foregroundStyle(.secondary)
                Button("Download the Films", systemImage: "arrow.down") { engine.install() }
                    .buttonStyle(BrandButtonStyle(large: false))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 6)
        }
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "film.stack").font(.system(size: 28)).foregroundStyle(Design.Brand.gradient)
            Text("Real film, simulated").font(.title3.weight(.semibold))
            Text("spektrafilm develops your photo the way film does: the stock, the paper it’s printed on, grain and halation, from measured data.")
                .font(Design.Studio.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Label("\(FilmEngine.downloadMB) MB download", systemImage: "arrow.down.circle")
                Label("\(FilmEngine.diskMB) MB on disk", systemImage: "internaldrive")
            }
            .font(Design.Studio.hint)
            .foregroundStyle(.secondary)
            Button("Download the Films", systemImage: "arrow.down") { engine.install() }
                .buttonStyle(BrandButtonStyle())
            Text("The film and paper data, checked as it downloads, kept in Pluck’s own folder. Remove it any time in Settings.")
                .font(Design.Studio.hint).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 6)
    }

    private var installing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Downloading the films").font(Design.Studio.body.weight(.semibold))
            ProgressView(value: engine.progress).progressViewStyle(.linear)
            HStack {
                Text(engine.stage)
                Spacer()
                Text(engine.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }
            .font(Design.Studio.hint)
            .foregroundStyle(.secondary)
            Text("About \(FilmEngine.downloadMB) MB.").font(Design.Studio.hint).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 6)
    }

    private var credit: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Film modelling powered by spektrafilm by Andrea Volpato. The film colour tables in Pluck are made from that data (CC BY-SA 4.0).")
            HStack(spacing: 4) {
                Link("spektrafilm", destination: URL(string: "https://github.com/andreavolpato/spektrafilm")!)
                Text(verbatim: "· GPLv3 · data CC BY-SA 4.0")
            }
        }
        .font(Design.Studio.hint)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    // MARK: Controls

    private func change(_ body: @escaping (inout PhotoRecord) -> Void) {
        catalog.update(paths) { record in
            body(&record)
            record.edited = .now
        }
    }

    /// A setting's value: as changed for this photo, else the film's default.
    private func value(_ key: String) -> Double {
        switch record.film.changed[key] {
        case .number(let v)?: return v
        case .flag(let on)?: return on ? 1 : 0
        default: return engine.schema[key]?.value ?? FilmRoute.standard(key) ?? 0
        }
    }

    private func set(_ key: String, _ value: Double) {
        change { $0.film.changed[key] = .number(value) }
    }

    /// The settings with a place of their own above; the rest are under Advanced.
    private static let shown: Set<String> = ["exposure_ev", "push_pull_stops", "film_format_mm", "scan_film", "print_exposure_ev",
                                             "print_auto_exposure", "print_contrast", "filter_y", "filter_m", "preflash_exposure",
                                             "grain_on", "grain_amount", "grain_granularity", "grain_blur", "halation_on",
                                             "halation_amount", "halation_scale", "scatter_amount", "diffusion_on",
                                             "diffusion_filter_family", "diffusion_strength", "diffusion_scale", "diffusion_warmth",
                                             "scan_usm_amount", "scan_blur", "glare_percent", "couplers_amount"]

    private var controls: some View {
        filmControls
            // Menus neutral, as Profile in Adjust: plum is for what's chosen in the work.
            .tint(Design.Studio.text)
    }

    private var filmControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Develop on Film").font(Design.Studio.sectionTitle)
                Spacer()
                Toggle("Develop on Film", isOn: Binding(get: { record.filmOn }, set: { on in change { $0.turnFilm(on, engine: engine) } }))
                    .labelsHidden()
                    .toggleStyle(StudioSwitchStyle())
            }
            .padding(.horizontal, Design.Sidebar.rowPadding)
            .frame(height: Design.Sidebar.foldHeight)

            FoldSection(title: "Stock", key: "film-stock") {
                filmRow("Film") {
                    Picker("Film", selection: Binding(get: { record.film.film }, set: { id in
                        change { $0.useFilm(id, engine: engine) }
                    })) {
                        Section("Colour Negative") { ForEach(engine.films.filter { $0.type == "negative" && $0.use != "cine" && $0.bw != true }) { stock($0) } }
                        Section("Slide") { ForEach(engine.films.filter { $0.type == "positive" && $0.bw != true }) { stock($0) } }
                        Section("Cinema") { ForEach(engine.films.filter { $0.use == "cine" && $0.type != "positive" && $0.bw != true }) { stock($0) } }
                        Section("Black & White") { ForEach(engine.films.filter { $0.bw == true }) { stock($0) } }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    let favourite = favouriteFilm == record.film.film
                    Button { favouriteFilm = favourite ? "" : record.film.film } label: {
                        Image(systemName: favourite ? "star.fill" : "star").foregroundStyle(favourite ? Design.Brand.pink : .secondary)
                            .frame(width: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(favourite ? "Favourite" : "Set as Favourite")
                    .accessibilityLabel(favourite ? "Favourite" : "Set as Favourite")
                }
                if value("scan_film") < 0.5 {
                    filmRow("Paper") {
                        Picker("Paper", selection: Binding(get: { record.film.paper }, set: { id in change { $0.film.paper = id; $0.filmOn = true } })) {
                            ForEach(engine.papers) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        // (The film row's star sits here: the two menus line up.)
                        Color.clear.frame(width: 18, height: 1)
                    }
                }
                filmToggle("Scan the Film", key: "scan_film")
                    .help("Look at the film itself (a slide on a light box) instead of a print from it")
            }
            FoldSection(title: "Camera", key: "film-camera") {
                filmSlider("Exposure", key: "exposure_ev", range: -4...4, format: "%+.1f EV")
                filmSlider("Push / Pull", key: "push_pull_stops", range: -3...3, format: "%+.1f")
                    .help("Shot at a different speed and developed to match: more contrast pushed, less pulled")
                filmRow("Format") {
                    Picker("Format", selection: Binding(get: { value("film_format_mm") }, set: { set("film_format_mm", $0) })) {
                        Text("35 mm").tag(36.0)
                        Text("645").tag(56.0)
                        Text("6×6").tag(60.0)
                        Text("6×7").tag(70.0)
                        Text("4×5").tag(127.0)
                    }
                    .labelsHidden()
                }
                .help("Bigger film: finer grain and smaller halation for the same picture")
            }
            if value("scan_film") < 0.5 {
                FoldSection(title: "Print", key: "film-print") {
                    filmSlider("Exposure", key: "print_exposure_ev", range: -3...3, format: "%+.2f EV")
                    filmToggle("Auto Exposure", key: "print_auto_exposure")
                    filmSlider("Contrast", key: "print_contrast", range: 0.5...2, format: "%.2f")
                    filmSlider("Warm / Cool", key: "filter_y", range: -60...60, format: "%+.0f")
                    filmSlider("Magenta / Green", key: "filter_m", range: -60...60, format: "%+.0f")
                    filmSlider("Pre-flash", key: "preflash_exposure", range: 0...2, format: "%.2f")
                        .help("A little light on the paper before printing: softer, lifted shadows")
                }
            }
            FoldSection(title: "Grain", key: "film-grain") {
                filmToggle("Grain", key: "grain_on")
                if value("grain_on") > 0.5 {
                    filmSlider("Amount", key: "grain_amount", range: 0...4, format: "%.2f")
                    filmSlider("Size", key: "grain_granularity", range: 0...3, format: "%.2f")
                    filmSlider("Softness", key: "grain_blur", range: 0.2...4, format: "%.2f")
                }
            }
            FoldSection(title: "Halation", key: "film-halation") {
                filmToggle("Halation", key: "halation_on")
                if value("halation_on") > 0.5 {
                    filmSlider("Strength", key: "halation_amount", range: 0...4, format: "%.2f")
                    filmSlider("Size", key: "halation_scale", range: 0.2...4, format: "%.2f")
                    filmSlider("Scatter", key: "scatter_amount", range: 0...1, format: "%.2f")
                }
                filmSlider("Couplers", key: "couplers_amount", range: 0...1, format: "%.2f")
                    .help("The film’s colour couplers: richer colour and local contrast")
                if value("couplers_amount") > 0 {
                    filmSlider("Edge Effect", key: "couplers_edge", range: 0...1, format: "%.2f")
                        .help("How much the couplers sharpen edges, as on real film. Lower keeps their colour with softer edges.")
                }
            }
            FoldSection(title: "Diffusion Filter", key: "film-diffusion", open: false) {
                filmToggle("Filter", key: "diffusion_on")
                if value("diffusion_on") > 0.5 {
                    filmRow("Type") {
                        Picker("Type", selection: Binding(get: { value("diffusion_filter_family") }, set: { set("diffusion_filter_family", $0) })) {
                            Text("Black Pro-Mist").tag(0.0)
                            Text("Glimmerglass").tag(1.0)
                            Text("Pro-Mist").tag(2.0)
                            Text("CineBloom").tag(3.0)
                        }
                        .labelsHidden()
                    }
                    filmSlider("Strength", key: "diffusion_strength", range: 0...2, format: "%.2f")
                    filmSlider("Size", key: "diffusion_scale", range: 0.2...4, format: "%.2f")
                    filmSlider("Warmth", key: "diffusion_warmth", range: -1.5...1.5, format: "%+.2f")
                }
            }
            FoldSection(title: "Scanner", key: "film-scanner", open: false) {
                filmSlider("Sharpness", key: "scan_usm_amount", range: 0...2, format: "%.2f")
                filmSlider("Softness", key: "scan_blur", range: 0...4, format: "%.2f")
                filmSlider("Glare", key: "glare_percent", range: 0...1, format: "%.2f")
                    .help("The light of the room the print is seen in, lifting the blacks")
            }
            Fold(title: Text("Advanced"), detail: nil, open: $advancedOpen) {
                ForEach(engine.schema.keys.filter { !Self.shown.contains($0) }.sorted(), id: \.self) { key in
                    if let setting = engine.schema[key] { advancedRow(key, setting) }
                }
            }
            HStack {
                Button("Reset Film Settings") { change { $0.film.changed = [:] } }
                    .buttonStyle(StudioFlatButtonStyle())
                Spacer()
            }
            .padding(.horizontal, 8)
        }
    }

    /// A stock in the Film menu, the favourite starred.
    private func stock(_ film: FilmEngine.Profile) -> some View {
        Group { if film.id == favouriteFilm { Label(film.name, systemImage: "star.fill") } else { Text(film.name) } }.tag(film.id)
    }

    private func filmRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            // (The same columns as the sliders: their names line up.)
            Text(title).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).frame(width: Design.Sidebar.sliderLabel, alignment: .leading)
            HStack(spacing: 8) { content() }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(Design.Studio.body)
        .controlSize(.small)
        .padding(.horizontal, Design.Sidebar.rowPadding)
        .frame(minHeight: Design.Sidebar.sliderHeight)
    }

    private func filmSlider(_ title: LocalizedStringKey, key: String, range: ClosedRange<Double>, format: String) -> some View {
        let current = value(key)
        let standard = engine.schema[key]?.value ?? FilmRoute.standard(key) ?? 0
        return AdjustSlider(title: title, value: current, range: min(range.lowerBound, current)...max(range.upperBound, current),
                            neutral: standard, format: format) { new in
            if abs(new - standard) < 0.0001 { change { $0.film.changed[key] = nil } } else { set(key, new) }
        }
    }

    private func filmToggle(_ title: LocalizedStringKey, key: String) -> some View {
        filmRow(title) {
            Toggle(title, isOn: Binding(get: { value(key) > 0.5 }, set: { set(key, $0 ? 1 : 0) }))
                .toggleStyle(StudioSwitchStyle()).labelsHidden()
        }
    }

    /// Any other setting: a dial over darktable's range for it.
    @ViewBuilder private func advancedRow(_ key: String, _ setting: FilmEngine.Setting) -> some View {
        let name = FilmDial.words(key)
        switch setting.kind {
        case .flag:
            HStack(spacing: 8) {
                Text(name).font(Design.Studio.hint).foregroundStyle(record.film.changed[key] == nil ? .secondary : .primary).lineLimit(1)
                Spacer()
                Toggle(name, isOn: Binding(get: { value(key) > 0.5 }, set: { set(key, $0 ? 1 : 0) })).toggleStyle(StudioSwitchStyle()).labelsHidden()
            }
            .padding(.horizontal, 8).frame(minHeight: 22)
        case .number, .choice:
            let current = value(key)
            AdjustSlider(title: LocalizedStringKey(name), value: current, range: min(setting.min, current)...max(setting.max, current),
                         neutral: setting.value, format: abs(current) < 10 ? "%.2f" : "%.0f") { new in
                let new = setting.kind == .choice ? new.rounded() : new
                if abs(new - setting.value) < 0.0001 { change { $0.film.changed[key] = nil } } else { set(key, new) }
            }
            .help(key)
        }
    }
}

/// A section that folds open and shut.
private struct Fold<Content: View>: View {
    let title: Text
    var detail: Text?
    @Binding var open: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    title.font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                    detail?.font(Design.Studio.body.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Design.Studio.textFaint)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, Design.Sidebar.rowPadding)
                .frame(height: Design.Sidebar.foldHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open { content }
        }
    }
}

// MARK: - Export

private struct PhotoExportPanel: View {
    let paths: [String]
    @State private var catalog = PhotoCatalog.shared
    @AppStorage("photoExportSettings") private var stored = Data()
    @AppStorage("photoExportFolder") private var folderPath = ""
    @State private var editing = PhotoEditing.shared
    @State private var saved = PhotoExportPreset.saved
    @State private var naming = false
    @State private var presetName = ""
    /// The ticked presets' names (a JSON list): one Export makes a file per photo for each.
    @AppStorage("photoExportChosenPresets") private var chosenStored = ""
    private var done: Int { editing.exportDone }
    private var running: Bool { editing.exporting }
    private var total: Int { editing.exportTotal }

    private var settings: PhotoExportSettings {
        get { (try? JSONDecoder().decode(PhotoExportSettings.self, from: stored)) ?? PhotoExportSettings() }
        nonmutating set { stored = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    private func binding<T>(_ path: WritableKeyPath<PhotoExportSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: path] }, set: { value in var s = settings; s[keyPath: path] = value; settings = s })
    }

    private var folder: URL {
        folderPath.isEmpty ? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck", isDirectory: true)
            : URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    private var chosen: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(chosenStored.utf8))) ?? [] }
        nonmutating set { chosenStored = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "" }
    }

    /// The ticked presets that still exist, in the menu's order.
    private var ticked: [PhotoExportPreset] {
        let names = chosen
        var seen = Set<String>()
        return (PhotoExportPreset.builtIn + saved).filter { names.contains($0.name) && seen.insert($0.name).inserted }
    }

    private func tick(_ preset: PhotoExportPreset) -> Binding<Bool> {
        Binding(get: { chosen.contains(preset.name) },
                set: { on in var names = chosen.filter { $0 != preset.name }; if on { names.append(preset.name) }; chosen = names })
    }

    private func size(_ settings: PhotoExportSettings) -> String {
        settings.longSide > 0 ? "\(settings.longSide) px" : String(localized: "Full Size")
    }

    private var watermark: Binding<PhotoWatermark> {
        Binding(get: { settings.watermark ?? PhotoWatermark() },
                set: { value in var s = settings; s.watermark = value; settings = s })
    }

    private func mark<T>(_ path: WritableKeyPath<PhotoWatermark, T>) -> Binding<T> {
        Binding(get: { watermark.wrappedValue[keyPath: path] },
                set: { value in var m = watermark.wrappedValue; m[keyPath: path] = value; watermark.wrappedValue = m })
    }

    private var presetTitle: String {
        (PhotoExportPreset.builtIn + saved).first { $0.settings == settings }?.name ?? String(localized: "Custom")
    }

    var body: some View {
        let s = settings
        let onFilm = paths.contains { catalog.record($0).filmOn }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Menu {
                    ForEach(PhotoExportPreset.builtIn) { preset in Button(preset.name) { settings = preset.settings } }
                    if !saved.isEmpty {
                        Divider()
                        ForEach(saved) { preset in Button(preset.name) { settings = preset.settings } }
                    }
                    Divider()
                    Button("Save as Preset…") { presetName = ""; naming = true }
                    if !saved.isEmpty {
                        Menu("Delete") {
                            ForEach(saved) { preset in
                                Button(preset.name) { saved.removeAll { $0.id == preset.id }; PhotoExportPreset.saved = saved }
                            }
                        }
                    }
                } label: {
                    Label(presetTitle, systemImage: "slider.horizontal.below.square.and.square.filled")
                }
                .fixedSize()
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            SidebarSection(title: Text("Presets")) {
                ForEach(PhotoExportPreset.builtIn + saved) { preset in
                    row(LocalizedStringKey(preset.name)) {
                        Text(verbatim: size(preset.settings)).font(Design.Studio.hint.monospacedDigit()).foregroundStyle(.tertiary)
                        Toggle(preset.name, isOn: tick(preset)).labelsHidden().toggleStyle(.checkbox)
                    }
                }
                .help("Tick presets to make a file per photo for each, in one go. With none ticked, the settings below are used.")
            }
            SidebarSection(title: Text("File")) {
                row("Format") {
                    Picker("Format", selection: binding(\.format)) { ForEach(PhotoRender.Format.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                }
                if s.format == .jpeg || s.format == .heic {
                    row("Quality") {
                        Slider(value: binding(\.quality), in: 0.5...1)
                        Text(s.quality, format: .percent.precision(.fractionLength(0))).font(Design.Studio.hint.monospacedDigit()).frame(width: 40)
                    }
                }
                row("Size") {
                    Picker("Size", selection: binding(\.longSide)) {
                        Text("Full Size").tag(0)
                        Text("4096 px").tag(4096)
                        Text("2048 px").tag(2048)
                        Text("1080 px").tag(1080)
                    }
                    .labelsHidden()
                }
                row("Colour") {
                    Picker("Colour", selection: binding(\.space)) {
                        Text("sRGB").tag(PhotoExportSettings.Space.srgb)
                        Text("Display P3").tag(PhotoExportSettings.Space.p3)
                    }
                    .labelsHidden()
                    .help("sRGB for the web and most screens; Display P3 for Apple screens and print")
                }
                if editing.proof.on {
                    row("Proof") {
                        Toggle("Use proof profile", isOn: $editing.proof.useForExport)
                            .toggleStyle(.checkbox)
                            .disabled(!editing.proof.canExport)
                            .help(editing.proof.canExport ? "Save in the soft proof’s profile: \(editing.proof.title)" : "Only RGB profiles can be saved in")
                    }
                }
                row("Sharpen") {
                    Picker("Sharpen", selection: binding(\.sharpen)) {
                        Text("None").tag(PhotoExportSettings.Sharpen.none)
                        Text("For Screens").tag(PhotoExportSettings.Sharpen.screen)
                        Text("For Print").tag(PhotoExportSettings.Sharpen.print)
                    }
                    .labelsHidden()
                }
                if s.format.canBeHDR {
                    row("HDR") {
                        Toggle("HDR", isOn: binding(\.hdr)).labelsHidden().toggleStyle(StudioSwitchStyle())
                            .help("Bright highlights on HDR screens (a gain map); looks as usual everywhere else")
                    }
                    if s.hdr, onFilm {
                        Text("Photos on film are saved without HDR.").font(Design.Studio.hint).foregroundStyle(.tertiary).padding(.horizontal, 8)
                    }
                }
            }
            SidebarSection(title: Text("Names and Info")) {
                row("Names") {
                    Picker("Names", selection: binding(\.naming)) {
                        Text("As the Photo").tag(PhotoExportSettings.Naming.original)
                        Text("New Name").tag(PhotoExportSettings.Naming.custom)
                    }
                    .labelsHidden()
                }
                if s.naming == .custom {
                    row("Name") {
                        TextField("Wedding", text: binding(\.name)).textFieldStyle(.roundedBorder)
                    }
                    Text(verbatim: s.fileName(for: paths.first ?? "photo", number: 0) + "." + s.format.fileExtension)
                        .font(Design.Studio.hint).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
                row("Metadata") {
                    Picker("Metadata", selection: binding(\.metadata)) {
                        Text("All").tag(PhotoExportSettings.Metadata.all)
                        Text("All but Location").tag(PhotoExportSettings.Metadata.noLocation)
                        Text("None").tag(PhotoExportSettings.Metadata.none)
                    }
                    .labelsHidden()
                }
                row("Suffix") {
                    TextField("-web", text: binding(\.suffix)).textFieldStyle(.roundedBorder)
                        .help("Added to every file name, before the extension")
                }
                row("Subfolder") {
                    TextField("Web", text: binding(\.subfolder)).textFieldStyle(.roundedBorder)
                        .help("A folder inside the export folder for these files. With several presets ticked, a preset without one uses its own name.")
                }
                row("Folder") {
                    Button(folder.lastPathComponent) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
                    }
                    .help(folder.path)
                }
            }
            watermarkSection(s).id("watermark")
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    export()
                } label: {
                    Label("Export ^[\(paths.count) Photo](inflect: true)", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(BrandButtonStyle())
                .disabled(running)
                if ticked.count > 1 {
                    Text("^[\(paths.count * ticked.count) file](inflect: true)").font(Design.Studio.hint).foregroundStyle(.secondary)
                }
                if running {
                    ProgressView(value: Double(done), total: Double(max(total, 1))).controlSize(.small)
                    Text("\(done) of \(total)").font(Design.Studio.hint).foregroundStyle(.secondary)
                } else if let problem = editing.exportProblem {
                    Text(problem).font(Design.Studio.hint).foregroundStyle(.orange)
                } else if let lastFolder = editing.exportFolder {
                    Button("Show in Finder") { NSWorkspace.shared.open(lastFolder) }.buttonStyle(.link).font(Design.Studio.hint)
                }
                if onFilm {
                    Text("Photos on film are developed at full size: that takes a while each.").font(Design.Studio.hint).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
        }
        .alert("Save Export Preset", isPresented: $naming) {
            TextField("Name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { saved.append(PhotoExportPreset(name: name, settings: settings)); PhotoExportPreset.saved = saved }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            // Screenshots: -PluckScreenshotPhotoExport YES exports the selection straight away.
            if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotPhotoExport"), !running, done == 0 {
                try? await Task.sleep(for: .seconds(2))
                export()
            }
        }
    }

    @ViewBuilder private func watermarkSection(_ s: PhotoExportSettings) -> some View {
        SidebarSection(title: Text("Watermark")) {
            row("Watermark") {
                Toggle("Watermark", isOn: Binding(get: { s.watermark != nil }, set: { on in var n = settings; n.watermark = on ? PhotoWatermark() : nil; settings = n }))
                    .labelsHidden().toggleStyle(StudioSwitchStyle())
                    .help("A line of text or a logo over every exported photo")
            }
            if let m = s.watermark {
                row("Mark") {
                    Picker("Mark", selection: mark(\.kind)) {
                        Text("Text").tag(PhotoWatermark.Kind.text)
                        Text("Logo").tag(PhotoWatermark.Kind.image)
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
                if m.kind == .text {
                    row("Text") { TextField("© Northwind", text: mark(\.text)).textFieldStyle(.roundedBorder) }
                    row("Font") {
                        Picker("Font", selection: mark(\.font)) { ForEach(PhotoWatermark.fonts, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                    }
                } else {
                    row("Logo") {
                        Button(m.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "Choose…")) {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.image]
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url { mark(\.imagePath).wrappedValue = url.path }
                        }
                        .help(m.imagePath ?? "")
                    }
                }
                row("Place") {
                    positionGrid(mark(\.position))
                }
                row("Size") { Slider(value: mark(\.size), in: 0.02...0.12) }
                row("Opacity") { Slider(value: mark(\.opacity), in: 0.1...1) }
                if let path = paths.first {
                    WatermarkPreview(path: path, mark: m)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
            }
        }
    }

    /// Nine places to pick from, like the photo.
    private func positionGrid(_ place: Binding<PhotoWatermark.Position>) -> some View {
        let order: [[PhotoWatermark.Position]] = [[.topLeft, .top, .topRight], [.left, .center, .right], [.bottomLeft, .bottom, .bottomRight]]
        return VStack(spacing: 3) {
            ForEach(order, id: \.first) { line in
                HStack(spacing: 3) {
                    ForEach(line) { spot in
                        Button { place.wrappedValue = spot } label: {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(place.wrappedValue == spot ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: 16, height: 11)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: spot.rawValue))
                    }
                }
            }
        }
    }

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            HStack(spacing: 6) { content() }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(Design.Studio.body)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(minHeight: 26)
    }

    private func export() {
        let started = Date.now
        let targets = paths, folder = self.folder
        // One job per photo and ticked preset, photo by photo. The mark in the panel goes on every preset; a
        // preset without a subfolder gets its own name when several are ticked.
        let current = self.settings
        let presets = ticked
        var variants = [current]
        if !presets.isEmpty {
            // Two presets never write the same file (they'd run at once and one would be lost):
            // the later gets its name as a folder, or a number after its suffix.
            var used: Set<String> = []
            variants = presets.enumerated().map { number, preset in
                var s = preset.settings
                if let mark = current.watermark { s.watermark = mark }
                if presets.count > 1, s.subfolder.isEmpty, s.suffix.isEmpty { s.subfolder = preset.name }
                func key() -> String { "\(s.subfolder.lowercased())|\(s.suffix.lowercased())|\(s.format.fileExtension)" }
                if used.contains(key()), s.subfolder.isEmpty { s.subfolder = preset.name }
                if used.contains(key()) { s.suffix += "-\(number + 1)" }
                used.insert(key())
                return s
            }
        }
        let jobs = targets.enumerated().flatMap { index, path in variants.map { (path: path, settings: $0, number: index) } }
        let editing = editing
        // The soft proof's profile, when asked for (RGB only), made now so the export doesn't wait on it.
        let proof: PhotoProof? = editing.proof.on && editing.proof.useForExport && editing.proof.canExport ? editing.proof : nil
        editing.exporting = true
        editing.exportDone = 0
        editing.exportTotal = jobs.count
        editing.exportProblem = nil
        let records = Dictionary(uniqueKeysWithValues: targets.map { ($0, catalog.record($0)) })
        // Several at a time, each on its own film engine process (previews keep the first one).
        let lanes = min(FilmEngine.exportWorkers, jobs.count)
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            await withTaskGroup(of: (lane: Int, failure: String?).self) { group in
                var queue = jobs[...]
                func next(_ lane: Int) {
                    guard let job = queue.popFirst() else { return }
                    group.addTask {
                        do {
                            _ = try await PhotoRender.export(job.path, record: records[job.path] ?? PhotoRecord(), to: folder, settings: job.settings,
                                                             number: job.number, worker: lane + 1, proof: proof)
                            return (lane, nil)
                        } catch {
                            return (lane, error.localizedDescription)
                        }
                    }
                }
                for lane in 0..<lanes { next(lane) }
                // A finished photo's process takes the next one.
                for await result in group {
                    if let failure = result.failure { editing.exportProblem = failure }
                    editing.exportDone += 1
                    next(result.lane)
                }
            }
            editing.exporting = false
            // The film's in-between images for these sizes aren't needed any more.
            FilmHalation.purge()
            editing.exportFolder = folder
            AppDelegate.shared?.manager.notify(
                title: editing.exportProblem == nil ? String(localized: "Photos exported") : String(localized: "Photos exported, with problems"),
                body: editing.exportProblem ?? String(AttributedString(localized: "^[\(jobs.count) file](inflect: true) in \(folder.lastPathComponent)").characters),
                files: [folder])
            if ScreenshotMode.scene != nil {
                // Tests: how long it took.
                try? "\(jobs.count) photos in \(Int(Date.now.timeIntervalSince(started))) s".write(
                    to: folder.appendingPathComponent("export-time.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}

/// The shown photo (small) with the watermark over it, as it will come out.
private struct WatermarkPreview: View {
    let path: String
    let mark: PhotoWatermark
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(height: 120)
        .clipShape(.rect(cornerRadius: Design.Radius.small))
        .task(id: "\(path)|\(mark.hashValue)") {
            let path = path, mark = mark
            image = await Task.detached(priority: .userInitiated) { Self.render(path, mark) }.value
        }
    }

    private nonisolated static func render(_ path: String, _ mark: PhotoWatermark) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: PhotoCatalog.file(of: path)) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 640,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let marked = PhotoWatermark.apply(CIImage(cgImage: thumb), mark)
        guard let out = PhotoEngine.context.createCGImage(marked, from: marked.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }
}

/// A raised button in two parts: a quiet name on the left, the value on the right ("Profile  Standard").
private struct InspectorPair: View {
    let name: LocalizedStringKey
    let value: Text
    var star = false

    var body: some View {
        HStack(spacing: 6) {
            Text(name).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).fixedSize()
            Spacer(minLength: 6)
            value.foregroundStyle(Design.Studio.text).lineLimit(1)
            if star {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Design.Brand.pink).accessibilityLabel("Favourite")
            }
        }
        .font(Design.Studio.body)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
        .contentShape(.rect)
    }
}
